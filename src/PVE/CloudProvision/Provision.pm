package PVE::CloudProvision::Provision;

# Create and reinstall cloud servers.
#
# Both start with a clone of a template on the node the server lives on:
#
#   - template on this node: qm clone
#   - template and target storage shared: qm clone --target (on the template's node)
#   - else: qm clone on the template's node, then qm migrate (offline, the disks go
#     to the target storage)
#
# A create clones straight to the new VMID and then applies the requested
# settings. A reinstall clones to a staging VMID next to the server, then swaps:
# the staged disks are renamed to the server's VMID, the server's config becomes
# the template's config plus the settings kept from the server (NICs, CPU,
# memory, cloud-init, data disks, ...) and the old system disks are freed. The
# server's VMID never goes away, so its routed IPs, traffic counters, firewall
# rules, permissions, pool, backup/replication jobs stay as they are.
#
# Long running steps (clone, migrate, resize, start, stop, destroy) run the qm CLI,
# over ssh for other nodes, so their output ends up in the task log. Config
# changes go through PVE::API2::Qemu->update_vm in-process. The API has checked
# the permissions of the caller before, the worker acts as root@pam.

use strict;
use warnings;

use URI::Escape;

use PVE::Cluster;
use PVE::Exception qw(raise_param_exc);
use PVE::INotify;
use PVE::RPCEnvironment;
use PVE::SSHInfo;
use PVE::Storage;
use PVE::Tools qw(run_command);

use PVE::API2::Qemu;
use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::Drive;
use PVE::QemuServer::Network;

use PVE::API2::RoutedIP::VM;
use PVE::RoutedIP::Config;

use PVE::API2::TrafficD::VM;
use PVE::TrafficD::Config;

use PVE::CloudProvision::Config;
use PVE::CloudProvision::Spec;
use PVE::CloudProvision::Templates;

my $QM = '/usr/sbin/qm';

# drive slots tried for an added cloud-init drive
my @CLOUDINIT_SLOTS = (qw(ide2 ide0 ide1 ide3), map { "sata$_" } 0 .. 5);

sub nodename {
    return PVE::INotify::nodename();
}

## helpers

# Run qm on a node, output to the task log.
sub run_qm {
    my ($node, @args) = @_;

    my $local = $node eq nodename();
    my $cmd = [$QM, @args];
    if (!$local) {
        my $info = PVE::SSHInfo::get_ssh_info($node);
        $cmd = [PVE::SSHInfo::ssh_info_to_command($info)->@*, '--', map { PVE::Tools::shellquote($_) } @$cmd];
    }

    print '$ ' . ($local ? '' : "[$node] ") . join(' ', 'qm', @args) . "\n";
    run_command(
        $cmd,
        outfunc => sub { print "$_[0]\n" },
        errfunc => sub { print STDERR "$_[0]\n" },
    );
}

sub guest_node {
    my ($vmid) = @_;
    PVE::Cluster::cfs_update();
    my $guest = (PVE::Cluster::get_vmlist()->{ids} // {})->{$vmid};
    return $guest ? $guest->{node} : undef;
}

# wait until the config of $vmid is on $node (after clone --target, migrate)
sub wait_for_config {
    my ($vmid, $node) = @_;

    for (my $i = 0; $i < 30; $i++) {
        my $where = guest_node($vmid);
        return if defined($where) && $where eq $node && -f PVE::QemuConfig->config_file($vmid, $node);
        sleep(1);
    }
    die "VM $vmid did not show up on node '$node'\n";
}

sub destroy_guest {
    my ($vmid) = @_;

    my $node = guest_node($vmid) // return;
    run_qm($node, 'destroy', $vmid, '--purge', '1', '--skiplock', '1');
}

# 'disk', 'cdrom', 'cloudinit' or undef (no drive)
sub drive_kind {
    my ($key, $value) = @_;

    return 'disk' if $key =~ m/^unused\d+$/;
    return undef if !PVE::QemuServer::Drive::is_valid_drivename($key);
    my $drive = PVE::QemuServer::Drive::parse_drive($key, $value)
        // die "unable to parse drive '$key'\n";
    return 'cloudinit' if PVE::QemuServer::Drive::drive_is_cloudinit($drive);
    return 'cdrom' if PVE::QemuServer::Drive::drive_is_cdrom($drive);
    return 'disk';
}

sub drive_volid {
    my ($key, $value) = @_;
    return $value if $key =~ m/^unused\d+$/;
    my $drive = PVE::QemuServer::Drive::parse_drive($key, $value) // return undef;
    return $drive->{file};
}

sub drive_size {
    my ($storecfg, $key, $value) = @_;

    my $drive = PVE::QemuServer::Drive::parse_drive($key, $value) // return undef;
    return $drive->{size} if $drive->{size};
    return eval { PVE::Storage::volume_size_info($storecfg, $drive->{file}, 5) };
}

sub storage_of {
    my ($key, $value) = @_;
    my $volid = drive_volid($key, $value) // return undef;
    my ($sid) = PVE::Storage::parse_volume_id($volid, 1);
    return $sid;
}

# disks from the template (replaced by a reinstall), when nothing was recorded:
# the boot disk plus EFI vars and TPM state
sub fallback_system_disks {
    my ($conf) = @_;

    my $res = [];
    my $boot = PVE::CloudProvision::Templates::boot_disk($conf);
    push @$res, $boot if defined($boot);
    push @$res, grep { defined($conf->{$_}) } qw(efidisk0 tpmstate0);
    return $res;
}

sub free_cloudinit_slot {
    my ($conf) = @_;
    for my $key (@CLOUDINIT_SLOTS) {
        return $key if !defined($conf->{$key});
    }
    die "no free IDE/SATA slot for the cloud-init drive\n";
}

# the effective routed IP gateways of a NIC: { 4 => ip, 6 => ip }
sub routed_gateways {
    my ($opts, $rnic) = @_;

    my $res = {};
    for my $gw (PVE::RoutedIP::Config::nic_gateways($opts, $rnic)->@*) {
        $res->{ PVE::CloudProvision::Spec::cidr_family($gw->[0]) } = $gw->[0];
    }
    return $res;
}

# cloud-init ipconfigX of a requested NIC
sub request_ipconfig {
    my ($nic, $opts) = @_;

    my $rnic = {
        cidr => $nic->{cidr},
        map { $_ => $nic->{$_} } grep { defined($nic->{$_}) } qw(gateway4 gateway6),
    };
    return PVE::CloudProvision::Spec::nic_ipconfig($nic, routed_gateways($opts, $rnic));
}

# Derive the cloud-init ipconfigX of the network devices from their current routed IPs
# again, also those changed since (a reinstall keeps changed ones), record them as
# derived and regenerate the cloud-init drive: the guest applies them at its next boot.
# A derived ipconfigX of a device without routed IPs any more is removed, as a reinstall
# does. Runs as a worker; returns { netX => ipconfig }.
sub sync_ipconfig_worker {
    my ($vmid) = @_;

    PVE::RPCEnvironment::get()->set_user('root@pam');

    my $meta = PVE::CloudProvision::Config::load_meta($vmid);
    my $state = ($meta // {})->{state} // '';
    die "VM $vmid is being created or reinstalled\n" if $state eq 'creating' || $state eq 'reinstalling';

    my $conf = PVE::QemuConfig->load_config($vmid);
    my $routed = PVE::RoutedIP::Config::load_vm_config($vmid);
    my $opts = PVE::RoutedIP::Config::effective_options();
    my $auto_old = ($meta // {})->{'auto-ipconfig'} // {};
    my $auto = {};
    my $param = {};
    my @delete;
    for my $net (sort { ($a =~ s/^net//r) <=> ($b =~ s/^net//r) } grep { m/^net\d+$/ } keys %$conf) {
        my ($i) = $net =~ m/(\d+)$/;
        my $cur = $conf->{"ipconfig$i"};
        my $rnic = $routed->{nics}->{$net};
        my $value = $rnic
            ? PVE::CloudProvision::Spec::nic_ipconfig($rnic, routed_gateways($opts, $rnic))
            : undef;
        if (defined($value)) {
            print "ipconfig$i: $value\n";
            $auto->{$net} = $value;
            $param->{"ipconfig$i"} = $value if !defined($cur) || $cur ne $value;
        } elsif (defined($cur) && defined($auto_old->{$net}) && $auto_old->{$net} eq $cur) {
            print "ipconfig$i: removed, $net has no routed IPs\n";
            push @delete, "ipconfig$i";
        }
    }
    update_config($vmid, $param, \@delete);

    if (PVE::QemuConfig->has_cloudinit(PVE::QemuConfig->load_config($vmid))) {
        print "regenerating the cloud-init drive\n";
        PVE::API2::Qemu->cloudinit_update({ node => nodename(), vmid => $vmid });
    } else {
        print "no cloud-init drive: the guest config is used when one is added\n";
    }

    PVE::CloudProvision::Config::update_meta($vmid, sub {
        my ($m) = @_;
        return undef if !$m; # not a cloud server of this plugin: no state to keep
        $m->{'auto-ipconfig'} = $auto;
        return $m;
    });
    return $auto;
}

# update_vm logs the change itself ('update VM ...', password hidden)
sub update_config {
    my ($vmid, $param, $delete) = @_;

    return if !scalar(keys %$param) && !scalar(@$delete);

    my $call = {%$param};
    $call->{delete} = join(',', @$delete) if @$delete;

    PVE::API2::Qemu->update_vm({ %$call, node => nodename(), vmid => $vmid, skiplock => 1 });
}

sub resize_disk {
    my ($vmid, $key, $size) = @_;
    run_qm(nodename(), 'disk', 'resize', $vmid, $key, $size, '--skiplock', '1');
}

## dependencies (pve-routedip, pve-trafficd)

# Remove what pve-routedip and pve-trafficd still have for a VMID whose guest is
# gone, so a new server starts without old routes, counters and limits.
sub purge_dependency_configs {
    my ($vmid) = @_;

    PVE::RoutedIP::Config::lock_config(sub {
        return if guest_node($vmid);
        return if !PVE::RoutedIP::Config::has_vm_config($vmid);
        print "removing old routed IP config of VMID $vmid\n";
        PVE::RoutedIP::Config::delete_vm_config($vmid);
    });

    PVE::TrafficD::Config::lock_config(sub {
        return if guest_node($vmid);
        my $conf = PVE::TrafficD::Config::load_vm_config($vmid);
        return if !scalar(keys $conf->{nics}->%*);
        print "removing old traffic accounting of VMID $vmid\n";
        $conf->{nics} = {};
        PVE::TrafficD::Config::write_vm_config($vmid, $conf);
    });
}

sub apply_dependencies {
    my ($vmid, $nics) = @_;

    for my $net (sort { ($a =~ s/^net//r) <=> ($b =~ s/^net//r) } keys %$nics) {
        my $nic = $nics->{$net};
        if (my $settings = PVE::CloudProvision::Spec::routedip_settings($nic)) {
            print "routed IPs of $net: $settings->{cidr}\n";
            PVE::API2::RoutedIP::VM->update_nic({
                %$settings, node => nodename(), vmid => $vmid, net => $net,
            });
        }
        if (my $settings = PVE::CloudProvision::Spec::trafficd_settings($nic)) {
            print "traffic accounting of $net"
                . (defined($settings->{quota}) ? ", quota $settings->{quota}" : '') . "\n";
            PVE::API2::TrafficD::VM->update_nic({ %$settings, vmid => $vmid, net => $net });
        }
    }
}

## request validation (API side, before forking)

sub parse_request_nics {
    my ($param) = @_;

    my $nics = {};
    for my $i (0 .. $PVE::CloudProvision::Spec::MAX_NETS - 1) {
        my $net = "net$i";
        next if !defined($param->{$net});

        my $nic = eval { PVE::CloudProvision::Spec::parse_nic($param->{$net}) };
        raise_param_exc({ $net => $@ }) if $@;

        if (scalar($nic->{cidr}->@*)) {
            $nic->{cidr} = eval { PVE::RoutedIP::Config::parse_cidr_list(join(';', $nic->{cidr}->@*)) };
            raise_param_exc({ $net => $@ }) if $@;
        }
        for my $gw (qw(gateway4 gateway6)) {
            next if !defined($nic->{$gw});
            my $format = "pve-routedip-$gw";
            eval { PVE::JSONSchema::check_format($format, $nic->{$gw}) };
            raise_param_exc({ $net => "$gw: $@" }) if $@;
            $nic->{$gw} = PVE::RoutedIP::Config::canonical_ip($nic->{$gw});
        }
        if (defined($nic->{quota})) {
            eval { PVE::TrafficD::Config::parse_size($nic->{quota}) };
            raise_param_exc({ $net => "quota: $@" }) if $@;
        }

        my $qemu_net = PVE::CloudProvision::Spec::qemu_net($nic);
        {
            local $SIG{__WARN__} = sub { };
            PVE::QemuServer::Network::parse_net($qemu_net, 1)
                or raise_param_exc({ $net => "invalid network device '$qemu_net'" });
        }

        $nics->{$net} = $nic;
    }
    return $nics;
}

# routed CIDRs must not overlap with each other or with routed IPs in the cluster
sub check_routed_conflicts {
    my ($vmid, $nics) = @_;

    my @mine;
    for my $net (sort keys %$nics) {
        push @mine, map { [$net, $_] } $nics->{$net}->{cidr}->@*;
    }
    return if !@mine;

    for my $i (0 .. $#mine) {
        for my $j ($i + 1 .. $#mine) {
            raise_param_exc({
                $mine[$j]->[0] => "$mine[$j]->[1] overlaps with $mine[$i]->[1] ($mine[$i]->[0])",
            })
                if PVE::RoutedIP::Config::cidr_overlap($mine[$i]->[1], $mine[$j]->[1]);
        }
    }

    my $all = PVE::RoutedIP::Config::load_all_vm_configs();
    my $vmlist = PVE::Cluster::get_vmlist();
    for my $net (sort keys %$nics) {
        my $cidrs = $nics->{$net}->{cidr};
        next if !@$cidrs;
        eval {
            PVE::RoutedIP::Config::check_cidr_conflicts($vmid, $net, $cidrs, $all, $vmlist);
        };
        if (my $err = $@) {
            my $msg = ref($err) && $err->{errors} ? join('; ', values $err->{errors}->%*) : $err;
            raise_param_exc({ $net => $msg });
        }
    }
}

my sub images_storage_on {
    my ($storecfg, $sid, $node) = @_;
    my $scfg = PVE::Storage::storage_check_enabled($storecfg, $sid, $node, 1) or return 0;
    return $scfg->{content}->{images} ? 1 : 0;
}

# template_info of a template that can be cloned now
my sub usable_template {
    my ($vmid, $storecfg) = @_;

    my $info = eval {
        my $info = PVE::CloudProvision::Templates::template_info($vmid, $storecfg);
        PVE::QemuConfig->check_lock($info->{conf});
        $info;
    };
    raise_param_exc({ template => $@ }) if $@;
    return $info;
}

# guest settings of a create request passed to update_vm as they are
our @CREATE_QEMU_KEYS = qw(
    description tags onboot cores sockets cpu memory balloon
    ciuser cipassword sshkeys nameserver searchdomain ciupgrade
);

# Validate a create request. $vmid may be undef (assigned later).
sub create_plan {
    my ($param) = @_;

    my $node = nodename();
    my $storecfg = PVE::Storage::config();

    my $info = usable_template($param->{template}, $storecfg);

    my $full = $param->{full} // 1;
    my $clone = eval {
        PVE::CloudProvision::Templates::clone_plan($info, $node, $param->{storage}, $full, $storecfg);
    };
    raise_param_exc({ $full ? 'storage' : 'full' => $@ }) if $@;

    # where the system disk ends up
    my $storage = $full ? ($param->{storage} // $info->{storage}) : $info->{storage};

    if (defined(my $size = $param->{disksize})) {
        raise_param_exc({ disksize => "linked clones keep the size of the template's disk" })
            if !$full;
        my $cur = $info->{'disk-size'} // 0;
        raise_param_exc({
            disksize => "smaller than the template's disk (" . PVE::JSONSchema::format_size($cur) . ")",
        })
            if $size * 1024**3 < $cur;
    }

    my $datadisks = [];
    for my $i (0 .. $PVE::CloudProvision::Spec::MAX_DATA_DISKS - 1) {
        my $key = "datadisk$i";
        next if !defined($param->{$key});
        my $disk = eval { PVE::CloudProvision::Spec::parse_datadisk($param->{$key}) };
        raise_param_exc({ $key => $@ }) if $@;
        $disk->{storage} //= $storage;
        raise_param_exc({ $key => "storage '$disk->{storage}' is not available for VM images on node '$node'" })
            if !images_storage_on($storecfg, $disk->{storage}, $node);
        push @$datadisks, $disk;
    }

    my $nics = parse_request_nics($param);
    check_routed_conflicts($param->{vmid} // 0, $nics);

    my $qemu = {};
    $qemu->{$_} = $param->{$_} for grep { defined($param->{$_}) } @CREATE_QEMU_KEYS;

    if (defined(my $keys = $qemu->{sshkeys})) {
        eval { PVE::Tools::validate_ssh_public_keys(URI::Escape::uri_unescape($keys)) };
        raise_param_exc({ sshkeys => $@ }) if $@;
    }

    return {
        vmid => $param->{vmid},
        node => $node,
        template => $info,
        clone => $clone,
        full => $full ? 1 : 0,
        storage => $storage,
        name => $param->{name},
        pool => $param->{pool},
        disksize => $param->{disksize},
        datadisks => $datadisks,
        nics => $nics,
        qemu => $qemu,
        start => $param->{start} // 1,
    };
}

# storages and bridges a create/reinstall uses (for permission checks)
sub plan_storages {
    my ($plan) = @_;
    my %res;
    $res{ $plan->{storage} } = 1 if defined($plan->{storage});
    $res{ $plan->{clone}->{storage} } = 1 if defined($plan->{clone}->{storage});
    $res{ $_->{storage} } = 1 for ($plan->{datadisks} // [])->@*;
    return [sort keys %res];
}

sub plan_qemu_nets {
    my ($plan) = @_;
    my $nics = $plan->{nics} // {};
    return { map { $_ => PVE::CloudProvision::Spec::qemu_net($nics->{$_}) } keys %$nics };
}

## create

# Clone template $info to $newid on $node according to $clone (see clone_plan).
# $$created is set once the guest exists (on whichever node).
sub stage_clone {
    my ($info, $newid, $node, $clone, $opts, $created) = @_;

    my @args = ('clone', $info->{vmid}, $newid, '--full', $clone->{storage} ? 1 : 0);
    push @args, '--storage', $clone->{storage} if $clone->{storage};
    push @args, '--target', $clone->{target} if $clone->{target};
    push @args, '--name', $opts->{name} if defined($opts->{name});
    push @args, '--pool', $opts->{pool} if defined($opts->{pool});
    run_qm($clone->{node}, @args);
    $$created = 1 if $created;

    if ($clone->{migrate}) {
        my @margs = ('migrate', $newid, $node);
        push @margs, '--targetstorage', $clone->{targetstorage} if $clone->{targetstorage};
        run_qm($clone->{node}, @margs);
    }

    wait_for_config($newid, $node);
}

# the settings of a fresh clone for a create request
sub configure_new {
    my ($vmid, $plan) = @_;

    my $conf = PVE::QemuConfig->load_config($vmid);
    my $storecfg = PVE::Storage::config();
    my $param = { $plan->{qemu}->%* };
    my @delete;

    # the template's notes describe the template, not the server (a reinstall keeps
    # the server's notes)
    push @delete, 'description' if !defined($param->{description}) && defined($conf->{description});

    my $system = [];
    PVE::QemuConfig->foreach_volume(
        $conf,
        sub {
            my ($key) = @_;
            push @$system, $key if (drive_kind($key, $conf->{$key}) // '') eq 'disk';
        },
    );
    my $bootdisk = PVE::CloudProvision::Templates::boot_disk($conf);

    my $nics = $plan->{nics};
    my $auto = {};
    if (scalar(keys %$nics)) {
        my $opts = PVE::RoutedIP::Config::effective_options();
        for my $key (sort keys %$conf) {
            if ($key =~ m/^net(\d+)$/) {
                push @delete, $key if !$nics->{$key};
            } elsif ($key =~ m/^ipconfig(\d+)$/) {
                push @delete, $key if !$nics->{"net$1"};
            }
        }
        for my $net (sort keys %$nics) {
            my $nic = $nics->{$net};
            my ($i) = $net =~ m/(\d+)$/;
            $param->{$net} = PVE::CloudProvision::Spec::qemu_net($nic);
            my $ipconfig = request_ipconfig($nic, $opts) // next;
            $param->{"ipconfig$i"} = $ipconfig;
            $auto->{$net} = $ipconfig if !defined($nic->{ip}) && !defined($nic->{ip6});
        }
    }

    my %used = map { $_ => 1 } keys %$conf;
    if (!PVE::QemuConfig->has_cloudinit($conf)) {
        my $slot = free_cloudinit_slot($conf);
        $param->{$slot} = "$plan->{storage}:cloudinit";
        $used{$slot} = 1;
    }

    if (scalar($plan->{datadisks}->@*)) {
        my $bus = PVE::CloudProvision::Spec::drive_bus($bootdisk // '') // 'scsi';
        my $sysdrive = $bootdisk ? PVE::QemuServer::Drive::parse_drive($bootdisk, $conf->{$bootdisk}) : {};
        for my $disk ($plan->{datadisks}->@*) {
            my $key = PVE::CloudProvision::Spec::free_drive_key($bus, \%used);
            $used{$key} = 1;
            my $value = "$disk->{storage}:$disk->{size}";
            $value .= ",discard=on" if ($sysdrive->{discard} // '') eq 'on';
            $value .= ",iothread=1" if $sysdrive->{iothread} && $bus =~ m/^(?:scsi|virtio)$/;
            $param->{$key} = $value;
        }
    }

    my $final = { %$conf, %$param };
    delete $final->{$_} for @delete;
    my $boot = PVE::CloudProvision::Spec::boot_order($final, $bootdisk);
    $param->{boot} = $boot if defined($boot) && $boot ne ($conf->{boot} // '');

    update_config($vmid, $param, \@delete);

    if (defined($plan->{disksize}) && defined($bootdisk)) {
        my $cur = drive_size($storecfg, $bootdisk, $conf->{$bootdisk}) // 0;
        resize_disk($vmid, $bootdisk, "$plan->{disksize}G") if $plan->{disksize} * 1024**3 > $cur;
    }

    return { system => $system, auto => $auto };
}

sub create_worker {
    my ($plan, $upid) = @_;

    PVE::RPCEnvironment::get()->set_user('root@pam');

    my $vmid = $plan->{vmid};
    my $node = nodename();
    my $info = $plan->{template};
    my $created = 0;

    eval {
        purge_dependency_configs($vmid);

        print "creating cloud server $vmid from template $info->{vmid} ($info->{name}) of node"
            . " '$info->{node}'\n";
        stage_clone(
            $info, $vmid, $node, $plan->{clone},
            { name => $plan->{name}, pool => $plan->{pool} }, \$created,
        );

        my $res = configure_new($vmid, $plan);
        apply_dependencies($vmid, $plan->{nics});

        PVE::CloudProvision::Config::update_meta($vmid, sub {
            return {
                state => 'ready',
                template => $info->{vmid} + 0,
                'template-name' => $info->{name},
                created => time(),
                'system-disks' => $res->{system},
                'auto-ipconfig' => $res->{auto},
                task => $upid,
            };
        });
    };
    if (my $err = $@) {
        print "create failed, cleaning up\n";
        if ($created) {
            eval { destroy_guest($vmid) };
            warn $@ if $@;
        }
        eval { purge_dependency_configs($vmid) };
        warn $@ if $@;
        eval { PVE::CloudProvision::Config::update_meta($vmid, sub { undef }) };
        warn $@ if $@;
        die "create failed: $err";
    }

    print "cloud server $vmid created\n";
    run_qm($node, 'start', $vmid) if $plan->{start};
}

## reinstall

# guest settings with pending (not yet applied) changes of other than drives
sub effective_config {
    my ($conf) = @_;

    my $pending = $conf->{pending} // {};
    my $res = { map { $_ => $conf->{$_} } grep { $_ ne 'pending' } keys %$conf };
    for my $key (keys %$pending) {
        next if $key eq 'delete';
        die "VM has pending changes of '$key', apply or revert them first\n"
            if (drive_kind($key, $pending->{$key}) // '') ne '';
        $res->{$key} = $pending->{$key};
    }
    for my $key (keys PVE::QemuConfig->parse_pending_delete($pending->{delete})->%*) {
        die "VM has a pending removal of '$key', apply or revert it first\n"
            if PVE::QemuServer::Drive::is_valid_drivename($key) || $key =~ m/^unused\d+$/;
        delete $res->{$key};
    }
    return $res;
}

sub check_reinstallable {
    my ($vmid, $conf) = @_;

    die "VM $vmid is a template\n" if PVE::QemuConfig->is_template($conf);
    PVE::QemuConfig->check_lock($conf);
    die "VM $vmid has snapshots, remove them first\n" if scalar(keys(($conf->{snapshots} // {})->%*));
    die "VM $vmid is protected\n" if $conf->{protection};
    effective_config($conf);

    require PVE::HA::Config;
    die "VM $vmid is HA managed with state 'started', set it to 'stopped' or 'ignored' first\n"
        if PVE::HA::Config::vm_is_ha_managed($vmid, 'started');
}

sub reinstall_plan {
    my ($param) = @_;

    my $vmid = $param->{vmid};
    my $node = nodename();
    my $storecfg = PVE::Storage::config();

    my $conf = PVE::QemuConfig->load_config($vmid);
    check_reinstallable($vmid, $conf);

    my $meta = PVE::CloudProvision::Config::load_meta($vmid) // {};

    my $template = $param->{template} // $meta->{template}
        // raise_param_exc({ template => "VM $vmid has no recorded template, select one" });
    my $info = usable_template($template, $storecfg);

    my $system = $meta->{'system-disks'};
    $system = fallback_system_disks($conf) if !$system || !grep { defined($conf->{$_}) } @$system;
    die "VM $vmid has no system disk to replace\n" if !grep { defined($conf->{$_}) } @$system;

    my $full = $param->{full} // 1;
    my $storage = $param->{storage};
    if ($full && !defined($storage)) {
        # the new system disk goes where the old one is, if possible
        my ($old_boot) = grep { defined($conf->{$_}) } @$system;
        my $sid = storage_of($old_boot, $conf->{$old_boot});
        $storage = $sid if defined($sid) && images_storage_on($storecfg, $sid, $node);
    }

    my $clone = eval {
        PVE::CloudProvision::Templates::clone_plan($info, $node, $storage, $full, $storecfg);
    };
    raise_param_exc({ $full ? 'storage' : 'full' => $@ }) if $@;

    my $overrides = {};
    $overrides->{$_} = $param->{$_} for grep { defined($param->{$_}) } qw(ciuser cipassword sshkeys);
    if (defined(my $keys = $overrides->{sshkeys})) {
        eval { PVE::Tools::validate_ssh_public_keys(URI::Escape::uri_unescape($keys)) };
        raise_param_exc({ sshkeys => $@ }) if $@;
    }

    return {
        vmid => $vmid,
        node => $node,
        template => $info,
        clone => $clone,
        full => $full ? 1 : 0,
        storage => $full ? ($storage // $info->{storage}) : $info->{storage},
        system => $system,
        overrides => $overrides,
        start => $param->{start},
    };
}

# what the reinstall keeps, for the record (cloud-init password masked)
sub saved_settings {
    my ($vmid, $conf) = @_;

    my %carry = map { $_ => 1 } @PVE::CloudProvision::Spec::CARRY_KEYS;
    my $groups = join('|', @PVE::CloudProvision::Spec::CARRY_GROUPS);
    my $config = {};
    for my $key (keys %$conf) {
        next if !$carry{$key} && $key !~ m/^(?:$groups)\d+$/;
        $config->{$key} = $key eq 'cipassword' ? '**********' : $conf->{$key};
    }

    my $routed = PVE::RoutedIP::Config::load_vm_config($vmid);
    my $traffic = PVE::TrafficD::Config::load_vm_config($vmid);

    return {
        config => $config,
        routedip => {
            map { $_ => PVE::RoutedIP::Config::print_nic($routed->{nics}->{$_}) } keys $routed->{nics}->%*
        },
        trafficd => {
            map { $_ => PVE::TrafficD::Config::print_nic($traffic->{nics}->{$_}) } keys $traffic->{nics}->%*
        },
    };
}

sub staging_name {
    my ($vmid) = @_;
    return "cloudprovision-staging-$vmid";
}

# a staging guest left behind by an aborted reinstall
sub remove_stale_staging {
    my ($vmid, $staging) = @_;

    return if !defined($staging);
    my $node = guest_node($staging) // return;
    my $conf = eval { PVE::QemuConfig->load_config($staging, $node) } // return;
    return if ($conf->{name} // '') ne staging_name($vmid);

    print "removing staging VM $staging of an earlier reinstall\n";
    destroy_guest($staging);
}

sub reserve_staging_vmid {
    my ($vmid) = @_;

    my $staging;
    PVE::CloudProvision::Config::update_meta($vmid, sub {
        my ($meta) = @_;
        my $ids = PVE::Cluster::get_vmlist()->{ids} // {};
        my $dc = PVE::Cluster::cfs_read_file('datacenter.cfg');
        $staging = PVE::CloudProvision::Config::next_free_vmid(
            $ids, PVE::CloudProvision::Config::load_all_meta(), $dc->{'next-id'} // {},
        );
        $meta->{staging} = $staging;
        return $meta;
    });
    return $staging;
}

# Move the staged disks to the server and give it the new config (see
# PVE::CloudProvision::Spec::reinstall_config). Frees the old system disks.
sub swap_disks {
    my ($vmid, $staging, $system) = @_;

    my $storecfg = PVE::Storage::config();
    my ($res, @free);

    PVE::QemuConfig->lock_config($vmid, sub {
        PVE::QemuConfig->lock_config($staging, sub {
            my $old = PVE::QemuConfig->load_config($vmid);
            die "VM $vmid lost its 'create' lock\n" if ($old->{lock} // '') ne 'create';
            my $staged = PVE::QemuConfig->load_config($staging);
            my $current = effective_config($old);

            my $merge = PVE::CloudProvision::Spec::reinstall_config($current, $staged, $system, \&drive_kind);
            my $conf = $merge->{conf};

            # sizes of the old system disks, the new ones grow to them
            my $old_boot = (grep { defined($old->{$_}) } @$system)[0];
            my $old_size = defined($old_boot) ? drive_size($storecfg, $old_boot, $old->{$old_boot}) : undef;

            for my $key ($merge->{moves}->@*) {
                my $drive = PVE::QemuServer::Drive::parse_drive($key, $staged->{$key});
                my $volid = PVE::Storage::rename_volume($storecfg, $drive->{file}, $vmid);
                print "moved $key: $drive->{file} -> $volid\n";
                $drive->{file} = $volid;
                $conf->{$key} = PVE::QemuServer::Drive::print_drive($drive);
                delete $staged->{$key};
                PVE::QemuConfig->write_config($staging, $staged);
            }

            my $bootdisk = PVE::CloudProvision::Templates::boot_disk($conf);
            my $boot = PVE::CloudProvision::Spec::boot_order($conf, $bootdisk);
            if (defined($boot)) {
                $conf->{boot} = $boot;
            } else {
                delete $conf->{boot};
            }

            for my $key ($merge->{free}->@*) {
                my $volid = drive_volid($key, $old->{$key});
                push @free, $volid if defined($volid) && $volid ne 'none';
            }

            my $cloudinit_storage;
            if (defined(my $key = $merge->{cloudinit})) {
                $cloudinit_storage = storage_of($key, $staged->{$key});
            }

            $conf->{lock} = 'create';
            PVE::QemuConfig->write_config($vmid, $conf);

            $res = {
                system => $merge->{moves},
                bootdisk => $bootdisk,
                'old-size' => $old_size,
                cloudinit => $merge->{cloudinit},
                'cloudinit-storage' => $cloudinit_storage,
            };
        });
    });

    for my $volid (@free) {
        my ($sid, $volname) = PVE::Storage::parse_volume_id($volid, 1);
        if (!defined($sid)) {
            print "keeping '$volid' (not a storage volume)\n";
            next;
        }
        my $owner = eval { (PVE::Storage::parse_volname($storecfg, $volid))[2] };
        if (!defined($owner) || $owner ne $vmid) {
            print "keeping '$volid' (not owned by VM $vmid)\n";
            next;
        }
        print "removing old volume $volid\n";
        eval { PVE::Storage::vdisk_free($storecfg, $volid) };
        warn "unable to remove '$volid' - $@" if $@;
    }

    return $res;
}

# after the swap: cloud-init drive, cloud-init settings, system disk size
sub configure_reinstalled {
    my ($vmid, $plan, $swap, $meta) = @_;

    my $conf = PVE::QemuConfig->load_config($vmid);
    my $storecfg = PVE::Storage::config();
    my $param = { $plan->{overrides}->%* };
    my @delete;

    my $slot = $swap->{cloudinit} // free_cloudinit_slot($conf);
    my $cistorage = $swap->{'cloudinit-storage'} // $plan->{storage};
    $param->{$slot} = "$cistorage:cloudinit";

    # ipconfigX set from the routed IPs follow them, changed ones stay
    my $routed = PVE::RoutedIP::Config::load_vm_config($vmid);
    my $opts = PVE::RoutedIP::Config::effective_options();
    my $auto_old = $meta->{'auto-ipconfig'} // {};
    my $auto = {};
    for my $net (grep { m/^net\d+$/ } sort keys %$conf) {
        my ($i) = $net =~ m/(\d+)$/;
        my $cur = $conf->{"ipconfig$i"};
        next if defined($cur) && !(defined($auto_old->{$net}) && $auto_old->{$net} eq $cur);

        my $rnic = $routed->{nics}->{$net};
        my $value = $rnic
            ? PVE::CloudProvision::Spec::nic_ipconfig($rnic, routed_gateways($opts, $rnic))
            : undef;
        if (defined($value)) {
            $auto->{$net} = $value;
            $param->{"ipconfig$i"} = $value if !defined($cur) || $cur ne $value;
        } elsif (defined($cur)) {
            push @delete, "ipconfig$i";
        }
    }

    update_config($vmid, $param, \@delete);

    my $bootdisk = $swap->{bootdisk};
    if (defined($bootdisk) && defined(my $want = $swap->{'old-size'})) {
        my $cur = drive_size($storecfg, $bootdisk, $conf->{$bootdisk}) // 0;
        resize_disk($vmid, $bootdisk, $want) if $want > $cur;
    }

    return $auto;
}

sub reinstall_worker {
    my ($plan, $upid) = @_;

    PVE::RPCEnvironment::get()->set_user('root@pam');

    my $vmid = $plan->{vmid};
    my $node = nodename();
    my $info = $plan->{template};

    my $old;
    PVE::QemuConfig->lock_config($vmid, sub {
        $old = PVE::QemuConfig->load_config($vmid);
        check_reinstallable($vmid, $old);
        $old->{lock} = 'create';
        PVE::QemuConfig->write_config($vmid, $old);
    });
    my $was_running = PVE::QemuServer::check_running($vmid) ? 1 : 0;

    my $previous = eval { PVE::CloudProvision::Config::load_meta($vmid) } // {};
    eval { remove_stale_staging($vmid, $previous->{staging}) };
    warn $@ if $@;

    my $meta = PVE::CloudProvision::Config::update_meta($vmid, sub {
        my ($meta) = @_;
        $meta //= {};
        delete $meta->{staging};
        $meta->{state} = 'reinstalling';
        $meta->{task} = $upid;
        $meta->{saved} = saved_settings($vmid, effective_config($old));
        delete $meta->{error};
        return $meta;
    });

    print "reinstalling VM $vmid with template $info->{vmid} ($info->{name}) of node"
        . " '$info->{node}'\n";

    my ($staging, $staged, $swapped);
    eval {
        if ($was_running) {
            print "stopping VM $vmid\n";
            run_qm($node, 'stop', $vmid, '--skiplock', '1');
        }

        $staging = reserve_staging_vmid($vmid);
        stage_clone($info, $staging, $node, $plan->{clone}, { name => staging_name($vmid) }, \$staged);

        my $swap = swap_disks($vmid, $staging, $plan->{system});
        $swapped = 1;
        PVE::CloudProvision::Config::update_meta($vmid, sub {
            my ($meta) = @_;
            $meta->{'system-disks'} = $swap->{system};
            return $meta;
        });

        destroy_guest($staging);
        $staged = 0;

        my $auto = configure_reinstalled($vmid, $plan, $swap, $meta);

        PVE::CloudProvision::Config::update_meta($vmid, sub {
            my ($meta) = @_;
            $meta //= {};
            $meta->{state} = 'ready';
            $meta->{template} = $info->{vmid} + 0;
            $meta->{'template-name'} = $info->{name};
            $meta->{reinstalled} = time();
            $meta->{'auto-ipconfig'} = $auto;
            delete $meta->{staging};
            return $meta;
        });
    };
    my $err = $@;

    if ($err && $staged) {
        eval { destroy_guest($staging) };
        warn $@ if $@;
    }
    eval { PVE::QemuConfig->remove_lock($vmid, 'create') };
    warn $@ if $@;

    if ($err) {
        eval {
            PVE::CloudProvision::Config::update_meta($vmid, sub {
                my ($meta) = @_;
                $meta //= {};
                $meta->{state} = 'error';
                $meta->{error} = "$err" =~ s/\s+$//r;
                delete $meta->{staging};
                return $meta;
            });
        };
        warn $@ if $@;
        if (!$swapped && $was_running) {
            print "starting the unchanged VM $vmid again\n";
            eval { run_qm($node, 'start', $vmid) };
            warn $@ if $@;
        }
        die "reinstall failed: $err";
    }

    print "VM $vmid reinstalled\n";
    run_qm($node, 'start', $vmid) if $plan->{start} // $was_running;
}

1;

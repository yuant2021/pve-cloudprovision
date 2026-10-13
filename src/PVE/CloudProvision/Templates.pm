package PVE::CloudProvision::Templates;

# QEMU templates of the cluster and how to clone them to a node.

use strict;
use warnings;

use PVE::Cluster;
use PVE::QemuConfig;
use PVE::QemuServer::Drive;
use PVE::Storage;

# the boot disk: first disk of the boot order, else the first disk by bus
sub boot_disk {
    my ($conf) = @_;

    for my $key (PVE::QemuServer::Drive::get_bootdisks($conf)->@*) {
        next if !$conf->{$key};
        my $drive = PVE::QemuServer::Drive::parse_drive($key, $conf->{$key}) or next;
        next if PVE::QemuServer::Drive::drive_is_cdrom($drive);
        return $key;
    }
    return PVE::QemuServer::Drive::resolve_first_disk($conf, 0);
}

# memory in MiB of a config value ('2048', 'current=2048')
sub memory_mib {
    my ($value) = @_;
    return 512 if !defined($value);
    return $1 + 0 if $value =~ m/(?:^|current=)(\d+)/;
    return 512;
}

# Details of a template, die if $vmid is no QEMU template.
sub template_info {
    my ($vmid, $storecfg, $vmlist) = @_;

    $vmlist //= PVE::Cluster::get_vmlist();
    my $guest = ($vmlist->{ids} // {})->{$vmid} or die "VM $vmid does not exist\n";
    die "VM $vmid is not a QEMU virtual machine\n" if $guest->{type} ne 'qemu';

    my $conf = PVE::QemuConfig->load_config($vmid, $guest->{node});
    die "VM $vmid is not a template\n" if !PVE::QemuConfig->is_template($conf);

    $storecfg //= PVE::Storage::config();

    my ($disks, $storages, $shared) = ([], {}, 1);
    PVE::QemuConfig->foreach_volume(
        $conf,
        sub {
            my ($key, $drive) = @_;
            return if PVE::QemuServer::Drive::drive_is_cdrom($drive, 1);
            return if PVE::QemuServer::Drive::drive_is_cloudinit($drive);
            my ($sid) = PVE::Storage::parse_volume_id($drive->{file}, 1);
            if (!defined($sid)) {
                $shared = 0;
            } else {
                $storages->{$sid} = 1;
                my $scfg = PVE::Storage::storage_config($storecfg, $sid, 1);
                $shared = 0 if !$scfg || !$scfg->{shared};
            }
            push @$disks, { key => $key, volid => $drive->{file}, size => $drive->{size} };
        },
    );

    my $boot = boot_disk($conf);
    my ($boot_entry) = grep { defined($boot) && $_->{key} eq $boot } @$disks;
    $boot_entry //= $disks->[0];

    my $cloudinit = PVE::QemuConfig->has_cloudinit($conf);

    my $info = {
        vmid => $vmid + 0,
        node => $guest->{node},
        name => $conf->{name} // "VM $vmid",
        ostype => $conf->{ostype},
        cores => ($conf->{cores} // 1) + 0,
        sockets => ($conf->{sockets} // 1) + 0,
        memory => memory_mib($conf->{memory}),
        cloudinit => $cloudinit ? 1 : 0,
        shared => (scalar(@$disks) && $shared) ? 1 : 0,
        disks => [map { $_->{key} } @$disks],
        conf => $conf,
    };
    $info->{$_} = $conf->{$_} for grep { defined($conf->{$_}) } qw(description tags bios machine cpu);
    $info->{'cloudinit-drive'} = $cloudinit if $cloudinit;
    if ($boot_entry) {
        $info->{'boot-disk'} = $boot_entry->{key};
        $info->{'disk-size'} = $boot_entry->{size} + 0 if defined($boot_entry->{size});
        ($info->{storage}) = PVE::Storage::parse_volume_id($boot_entry->{volid}, 1);
    }

    return $info;
}

# VMIDs of all QEMU templates in the cluster
sub template_vmids {
    my ($vmlist) = @_;

    $vmlist //= PVE::Cluster::get_vmlist();
    my $ids = $vmlist->{ids} // {};
    my $props = PVE::Cluster::get_guest_config_property('template') // {};

    my @res;
    for my $vmid (keys %$props) {
        my $guest = $ids->{$vmid} or next;
        next if $guest->{type} ne 'qemu';
        my $value = $props->{$vmid}->{template} // next;
        push @res, $vmid + 0 if $value =~ m/^(?:1|yes|on|true)$/i;
    }
    return [sort { $a <=> $b } @res];
}

# template_info of all templates, $filter($vmid) selects
sub list {
    my ($filter) = @_;

    my $vmlist = PVE::Cluster::get_vmlist();
    my $storecfg = PVE::Storage::config();

    my $res = [];
    for my $vmid (template_vmids($vmlist)->@*) {
        next if $filter && !$filter->($vmid);
        my $info = eval { template_info($vmid, $storecfg, $vmlist) };
        if (my $err = $@) {
            warn "template $vmid: $err";
            next;
        }
        push @$res, $info;
    }
    return $res;
}

my sub images_storage_on {
    my ($storecfg, $sid, $node) = @_;
    my $scfg = PVE::Storage::storage_check_enabled($storecfg, $sid, $node, 1) or return undef;
    return $scfg->{content}->{images} ? $scfg : undef;
}

# How to get a clone of template $info onto $node. qm clone only runs on the node
# of the template, so a template on local storage of another node is cloned
# there and migrated (offline, disks to the target storage).
#
# Returns { node => where to clone, storage => clone storage (full clone),
# target => clone --target node, migrate => 1, targetstorage => storage on $node }
sub clone_plan {
    my ($info, $node, $storage, $full, $storecfg) = @_;

    $storecfg //= PVE::Storage::config();
    my $tnode = $info->{node};

    if (!$full) {
        die "parameter 'storage' not allowed for linked clones\n" if defined($storage);
        return { node => $tnode } if $tnode eq $node;
        die "a linked clone of template $info->{vmid} on node '$tnode' can only be created on"
            . " other nodes if all its disks are on shared storage\n"
            if !$info->{shared};
        for my $key ($info->{disks}->@*) {
            my $drive = PVE::QemuServer::Drive::parse_drive($key, $info->{conf}->{$key});
            my ($sid) = PVE::Storage::parse_volume_id($drive->{file});
            die "storage '$sid' of template $info->{vmid} is not available on node '$node'\n"
                if !PVE::Storage::storage_check_enabled($storecfg, $sid, $node, 1);
        }
        return { node => $tnode, target => $node };
    }

    $storage //= $info->{storage} // die "template $info->{vmid} has no disk\n";
    my $scfg = images_storage_on($storecfg, $storage, $node)
        or die "storage '$storage' is not available for VM images on node '$node'\n";

    return { node => $tnode, storage => $storage } if $tnode eq $node;

    if ($scfg->{shared} && $info->{shared} && images_storage_on($storecfg, $storage, $tnode)) {
        return { node => $tnode, storage => $storage, target => $node };
    }

    # clone on the template's node, then migrate
    my $clone_storage = images_storage_on($storecfg, $storage, $tnode) ? $storage : $info->{storage};
    die "storage '$clone_storage' is not available for VM images on node '$tnode'\n"
        if !images_storage_on($storecfg, $clone_storage, $tnode);

    my $plan = { node => $tnode, storage => $clone_storage, migrate => 1 };
    my $cscfg = PVE::Storage::storage_config($storecfg, $clone_storage);
    $plan->{targetstorage} = $storage
        if !$cscfg->{shared} || !images_storage_on($storecfg, $clone_storage, $node);
    return $plan;
}

1;

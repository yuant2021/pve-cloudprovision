package PVE::API2::CloudProvision::VM;

# /nodes/{node}/qemu/{vmid}/cloudprovision: state of a cloud server, reinstall, ipconfig sync
#
# Requests go to the node the guest is on, whatever {node} says, so callers do
# not have to follow migrations.

use strict;
use warnings;

use PVE::Cluster;
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Tools qw(extract_param);

use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::Network;

use PVE::RoutedIP::Config;
use PVE::TrafficD::Config;

use PVE::API2::CloudProvision;
use PVE::CloudProvision::Config;
use PVE::CloudProvision::Provision;

use base qw(PVE::RESTHandler);

# node of the guest, if online
sub guest_node {
    my ($rpcenv, $proxyto, $param) = @_;

    my $guest = (PVE::Cluster::get_vmlist()->{ids} // {})->{ $param->{vmid} } or return 'localhost';
    my $node = $guest->{node};
    return 'localhost' if $node eq PVE::INotify::nodename();

    my $members = PVE::Cluster::get_members() // {};
    return 'localhost' if !$members->{$node} || !$members->{$node}->{online};
    return $node;
}

my $confdesc = PVE::QemuServer::json_config_properties({});

__PACKAGE__->register_method({
    name => 'info',
    path => '',
    method => 'GET',
    proxyto_callback => \&guest_node,
    description => "Cloud server state of a VM and its network devices with routed IPs, guest"
        . " IP config and traffic accounting.",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => {
        type => 'object',
        properties => {
            $PVE::API2::CloudProvision::server_properties->%*,
            managed => {
                type => 'boolean',
                description => "Created (or reinstalled) by pve-cloudprovision.",
            },
            'system-disks' => {
                type => 'array',
                items => { type => 'string' },
                optional => 1,
                description => "Disks a reinstall replaces (the others are kept).",
            },
            saved => {
                type => 'object',
                optional => 1,
                description => "Settings the last reinstall kept: guest config, pve-routedip and"
                    . " pve-trafficd lines.",
            },
            nics => {
                type => 'array',
                items => {
                    type => 'object',
                    properties => {
                        net => { type => 'string' },
                        model => { type => 'string', optional => 1 },
                        macaddr => { type => 'string', optional => 1 },
                        bridge => { type => 'string', optional => 1 },
                        tag => { type => 'integer', optional => 1 },
                        rate => { type => 'number', optional => 1 },
                        cidr => { type => 'string', optional => 1, description => "Routed IPs." },
                        'tap-only' => { type => 'boolean', optional => 1 },
                        ipconfig => { type => 'string', optional => 1 },
                        'ipconfig-auto' => {
                            type => 'boolean',
                            optional => 1,
                            description => "ipconfig follows the routed IPs on reinstall.",
                        },
                        traffic => { type => 'boolean', description => "Traffic is counted." },
                        quota => { type => 'integer', optional => 1, renderer => 'bytes' },
                    },
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $vmid = $param->{vmid};
        my $conf = PVE::QemuConfig->load_config($vmid);
        my $meta = PVE::CloudProvision::Config::load_meta($vmid);
        my $routed = PVE::RoutedIP::Config::load_vm_config($vmid);
        my $traffic = PVE::TrafficD::Config::load_vm_config($vmid);

        my $res = {
            PVE::API2::CloudProvision::server_entry(
                $vmid, $meta // {}, { node => PVE::INotify::nodename() }, $conf->{name},
            )->%*,
            managed => $meta ? 1 : 0,
        };
        if ($meta) {
            $res->{'system-disks'} = $meta->{'system-disks'} if $meta->{'system-disks'};
            $res->{saved} = $meta->{saved} if $meta->{saved};
        }

        my $auto = ($meta // {})->{'auto-ipconfig'} // {};
        my $nics = [];
        for my $net (sort { ($a =~ s/^net//r) <=> ($b =~ s/^net//r) } grep { m/^net\d+$/ } keys %$conf) {
            my ($i) = $net =~ m/(\d+)$/;
            my $entry = { net => $net, traffic => 0 };
            if (my $qnet = PVE::QemuServer::Network::parse_net($conf->{$net}, 1)) {
                $entry->{$_} = $qnet->{$_} for grep { defined($qnet->{$_}) } qw(model macaddr bridge);
                $entry->{$_} = $qnet->{$_} + 0 for grep { defined($qnet->{$_}) } qw(tag rate);
            }
            if (my $rnic = $routed->{nics}->{$net}) {
                $entry->{cidr} = join(';', $rnic->{cidr}->@*);
                $entry->{'tap-only'} = $rnic->{'tap-only'} ? 1 : 0;
            }
            if (defined(my $ipconfig = $conf->{"ipconfig$i"})) {
                $entry->{ipconfig} = $ipconfig;
                $entry->{'ipconfig-auto'} = (defined($auto->{$net}) && $auto->{$net} eq $ipconfig) ? 1 : 0;
            }
            if (my $tnic = $traffic->{nics}->{$net}) {
                if (!$tnic->{deleted}) {
                    $entry->{traffic} = 1;
                    $entry->{quota} = $tnic->{quota} if defined($tnic->{quota});
                }
            }
            push @$nics, $entry;
        }
        $res->{nics} = $nics;

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'reinstall',
    path => 'reinstall',
    method => 'POST',
    protected => 1,
    proxyto_callback => \&guest_node,
    description => "Reinstall the operating system: save the current settings, re-create the VM"
        . " from a (new) template and restore them. The system disks are replaced by the"
        . " template's, data disks, network devices with their MAC addresses, CPU, memory,"
        . " cloud-init settings, routed IPs, traffic counters, firewall rules, pool and jobs of"
        . " the VMID stay. A running VM is stopped and started again.",
    permissions => {
        description => "'VM.Allocate', 'VM.Config.Disk', 'VM.Config.Cloudinit' and"
            . " 'VM.PowerMgmt' on the VM, 'VM.Clone' on the template and"
            . " 'Datastore.AllocateSpace' on the storage.",
        check => ['perm', '/vms/{vmid}', ['VM.Allocate', 'VM.Config.Disk', 'VM.Config.Cloudinit',
            'VM.PowerMgmt']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            template => get_standard_option('pve-vmid', {
                optional => 1,
                description => "VMID of the template (default: the one of the last create/reinstall).",
            }),
            storage => get_standard_option('pve-storage-id', {
                optional => 1,
                description => "Storage of the new system disks (default: the one of the current"
                    . " system disk).",
            }),
            full => {
                type => 'boolean',
                optional => 1,
                default => 1,
                description => "Full clone of the template's disks.",
            },
            ciuser => { $confdesc->{ciuser}->%*, optional => 1 },
            cipassword => { $confdesc->{cipassword}->%*, optional => 1 },
            sshkeys => { $confdesc->{sshkeys}->%*, optional => 1 },
            start => {
                type => 'boolean',
                optional => 1,
                description => "Start the VM afterwards (default: if it was running).",
            },
        },
    },
    returns => { type => 'string', description => "UPID of the reinstall task." },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        extract_param($param, 'node');

        my $plan = PVE::CloudProvision::Provision::reinstall_plan($param);

        my $template = $plan->{template};
        $rpcenv->check($authuser, "/vms/$template->{vmid}", ['VM.Clone']);
        PVE::QemuServer::check_mapping_access($rpcenv, $authuser, $template->{conf});
        for my $sid (PVE::CloudProvision::Provision::plan_storages($plan)->@*) {
            $rpcenv->check($authuser, "/storage/$sid", ['Datastore.AllocateSpace']);
        }

        return $rpcenv->fork_worker('cpreinstall', $plan->{vmid}, $authuser, sub {
            my ($upid) = @_;
            PVE::CloudProvision::Provision::reinstall_worker($plan, $upid);
        });
    },
});

__PACKAGE__->register_method({
    name => 'sync_ipconfig',
    path => 'ipconfig',
    method => 'POST',
    protected => 1,
    proxyto_callback => \&guest_node,
    description => "Derive the cloud-init IP config (ipconfigX) of every network device from its"
        . " current routed IPs again, also ipconfigX changed since, and regenerate the cloud-init"
        . " drive. The guest applies it at its next boot; the changed config makes cloud-init treat"
        . " that boot as a new instance (e.g. the password is set again, new SSH host keys).",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Config.Cloudinit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => { type => 'string', description => "UPID of the task." },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $vmid = $param->{vmid};
        PVE::QemuConfig->load_config($vmid); # the VM exists (on this node)

        return $rpcenv->fork_worker('cpipconfig', $vmid, $authuser, sub {
            PVE::CloudProvision::Provision::sync_ipconfig_worker($vmid);
        });
    },
});

1;

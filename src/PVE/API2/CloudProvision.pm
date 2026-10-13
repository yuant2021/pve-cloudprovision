package PVE::API2::CloudProvision;

# /nodes/{node}/cloudprovision: create cloud servers on the node, list the
# templates and cloud servers of the cluster
#
# Registered from the PVE::API2::Nodes wrapper. Nothing goes below /cluster:
# PVE::API2::Cluster loads PVE::API2::Nodes (bulk actions) before it is complete.

use strict;
use warnings;

use PVE::Cluster;
use PVE::Exception qw(raise_param_exc);
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Storage;
use PVE::Tools qw(extract_param);

use PVE::QemuServer;

use PVE::CloudProvision::Config;
use PVE::CloudProvision::Provision;
use PVE::CloudProvision::Spec;
use PVE::CloudProvision::Templates;

use base qw(PVE::RESTHandler);

my $registered;

# called by the PVE::API2::Nodes wrapper module
sub register_api {
    return if $registered;
    $registered = 1;

    require PVE::API2::Qemu;
    require PVE::API2::CloudProvision::VM;

    PVE::API2::Nodes::Nodeinfo->register_method({
        subclass => 'PVE::API2::CloudProvision',
        path => 'cloudprovision',
    });
    PVE::API2::Qemu->register_method({
        subclass => 'PVE::API2::CloudProvision::VM',
        path => '{vmid}/cloudprovision',
    });
}

## schema

our $template_properties = {
    vmid => get_standard_option('pve-vmid'),
    node => get_standard_option('pve-node', { description => "Node the template is on." }),
    name => { type => 'string' },
    description => { type => 'string', optional => 1 },
    tags => { type => 'string', optional => 1 },
    ostype => { type => 'string', optional => 1 },
    bios => { type => 'string', optional => 1 },
    machine => { type => 'string', optional => 1 },
    cpu => { type => 'string', optional => 1, description => "CPU type of the template." },
    cores => { type => 'integer' },
    sockets => { type => 'integer' },
    memory => { type => 'integer', description => "Memory in MiB." },
    'boot-disk' => { type => 'string', optional => 1, description => "Drive key of the boot disk." },
    'disk-size' => {
        type => 'integer',
        optional => 1,
        renderer => 'bytes',
        description => "Size of the boot disk in bytes, the minimum system disk size.",
    },
    storage => { type => 'string', optional => 1, description => "Storage of the boot disk." },
    disks => {
        type => 'array',
        items => { type => 'string' },
        description => "Drive keys of the template's disks (cloned to a server).",
    },
    cloudinit => { type => 'boolean', description => "The template has a cloud-init drive." },
    'cloudinit-drive' => { type => 'string', optional => 1 },
    shared => { type => 'boolean', description => "All disks are on shared storage." },
    direct => {
        type => 'boolean',
        description => "A server on this node is cloned directly (with the template's storage)."
            . " Otherwise it is cloned on the template's node and migrated.",
    },
};

our $server_properties = {
    vmid => get_standard_option('pve-vmid'),
    node => { type => 'string', optional => 1, description => "Node the server is on." },
    name => { type => 'string', optional => 1 },
    template => {
        type => 'integer',
        optional => 1,
        description => "Template of the last create/reinstall.",
    },
    'template-name' => { type => 'string', optional => 1 },
    state => {
        type => 'string',
        enum => ['creating', 'reinstalling', 'ready', 'error'],
        optional => 1,
    },
    error => { type => 'string', optional => 1, description => "Error of the last failed reinstall." },
    task => { type => 'string', optional => 1, description => "UPID of the last create/reinstall." },
    created => { type => 'integer', optional => 1, renderer => 'timestamp' },
    reinstalled => { type => 'integer', optional => 1, renderer => 'timestamp' },
    orphan => { type => 'boolean', optional => 1, description => "The guest does not exist." },
};

sub server_entry {
    my ($vmid, $meta, $guest, $name) = @_;

    my $entry = { vmid => $vmid + 0 };
    $entry->{$_} = $meta->{$_}
        for grep { defined($meta->{$_}) } qw(template-name state error task);
    $entry->{$_} = $meta->{$_} + 0 for grep { defined($meta->{$_}) } qw(template created reinstalled);
    if ($guest) {
        $entry->{node} = $guest->{node};
        $entry->{name} = $name if defined($name);
    } else {
        $entry->{orphan} = 1;
    }
    return $entry;
}

my $confdesc = PVE::QemuServer::json_config_properties({});

my sub qemu_option {
    my ($key, $description) = @_;
    my $schema = { $confdesc->{$key}->%*, optional => 1 };
    $schema->{description} = $description if defined($description);
    return $schema;
}

my $create_properties = {
    node => get_standard_option('pve-node'),
    vmid => get_standard_option('pve-vmid', {
        optional => 1,
        description => "VMID of the new server (default: the next free one).",
    }),
    template => get_standard_option('pve-vmid', { description => "VMID of the template." }),
    name => {
        type => 'string',
        format => 'dns-name',
        optional => 1,
        description => "Name of the server, also its hostname (cloud-init). Default 'vm<VMID>'.",
    },
    pool => {
        type => 'string',
        format => 'pve-poolid',
        optional => 1,
        description => "Add the server to this pool.",
    },
    storage => get_standard_option('pve-storage-id', {
        optional => 1,
        description => "Storage for the disks of the template (full clone). Default: the storage"
            . " of the template's boot disk.",
    }),
    full => {
        type => 'boolean',
        optional => 1,
        default => 1,
        description => "Full clone. A linked clone shares the template's disks (template on this"
            . " node or on shared storage).",
    },
    disksize => {
        type => 'integer',
        minimum => 1,
        optional => 1,
        description => "Size of the system disk (the template's boot disk) in GiB. It can only grow.",
    },
    start => {
        type => 'boolean',
        optional => 1,
        default => 1,
        description => "Start the server after it was created.",
    },
    description => qemu_option('description'),
    tags => qemu_option('tags'),
    onboot => qemu_option('onboot'),
    cores => qemu_option('cores', "CPU cores per socket (default: the template's)."),
    sockets => qemu_option('sockets', "CPU sockets (default: the template's)."),
    cpu => qemu_option('cpu', "CPU type (default: the template's)."),
    memory => qemu_option('memory', "Memory in MiB (default: the template's)."),
    balloon => qemu_option('balloon'),
    ciuser => qemu_option('ciuser'),
    cipassword => qemu_option('cipassword'),
    sshkeys => qemu_option('sshkeys'),
    nameserver => qemu_option('nameserver'),
    searchdomain => qemu_option('searchdomain'),
    ciupgrade => qemu_option('ciupgrade'),
};

for my $i (0 .. $PVE::CloudProvision::Spec::MAX_NETS - 1) {
    $create_properties->{"net$i"} = {
        type => 'string',
        format => 'pve-cloudprovision-nic',
        optional => 1,
        description => "Network device: PVE settings, routed IPs (pve-routedip), guest IP"
            . " config (cloud-init) and traffic accounting (pve-trafficd). If any is given, they"
            . " replace the template's network devices.",
    };
}
for my $i (0 .. $PVE::CloudProvision::Spec::MAX_DATA_DISKS - 1) {
    $create_properties->{"datadisk$i"} = {
        type => 'string',
        format => 'pve-cloudprovision-datadisk',
        optional => 1,
        description => "Additional empty disk on the bus of the system disk. A reinstall keeps"
            . " data disks.",
    };
}

## create helpers

# privileges on the new guest
my @CREATE_PRIVS = qw(VM.Allocate VM.Config.Disk VM.Config.CPU VM.Config.Memory
    VM.Config.Network VM.Config.Cloudinit VM.Config.Options);

sub check_create_permissions {
    my ($rpcenv, $authuser, $plan) = @_;

    $rpcenv->check_pool_exist($plan->{pool}) if defined($plan->{pool});

    my @privs = @CREATE_PRIVS;
    push @privs, 'VM.PowerMgmt' if $plan->{start};
    $rpcenv->check_vm_perm($authuser, $plan->{vmid}, $plan->{pool}, \@privs);

    my $template = $plan->{template};
    $rpcenv->check($authuser, "/vms/$template->{vmid}", ['VM.Clone']);
    PVE::QemuServer::check_mapping_access($rpcenv, $authuser, $template->{conf});

    for my $sid (PVE::CloudProvision::Provision::plan_storages($plan)->@*) {
        $rpcenv->check($authuser, "/storage/$sid", ['Datastore.AllocateSpace']);
    }
    PVE::QemuServer::check_bridge_access(
        $rpcenv, $authuser, PVE::CloudProvision::Provision::plan_qemu_nets($plan),
    );

    # routes and traffic quotas are host resources (like pve-routedip/pve-trafficd)
    if (grep {
        PVE::CloudProvision::Spec::routedip_settings($_)
            || PVE::CloudProvision::Spec::trafficd_settings($_)
    } values $plan->{nics}->%*) {
        $rpcenv->check($authuser, '/', ['Sys.Modify']);
    }
}

# reserve the requested or the next free VMID
my sub reserve_vmid {
    my ($vmid, $node, $template) = @_;

    return PVE::CloudProvision::Config::lock_config(sub {
        my $ids = PVE::Cluster::get_vmlist()->{ids} // {};
        my $all = PVE::CloudProvision::Config::load_all_meta();

        if (defined($vmid)) {
            raise_param_exc({ vmid => "VM $vmid already exists" }) if $ids->{$vmid};
            raise_param_exc({ vmid => "VMID $vmid is reserved by another create or reinstall" })
                if PVE::CloudProvision::Config::reservation_active($all->{$vmid})
                || grep { $_ && defined($_->{staging}) && $_->{staging} == $vmid } values %$all;
        } else {
            my $dc = PVE::Cluster::cfs_read_file('datacenter.cfg');
            $vmid = PVE::CloudProvision::Config::next_free_vmid($ids, $all, $dc->{'next-id'} // {});
        }

        PVE::CloudProvision::Config::write_meta($vmid, {
            state => 'creating',
            reserved => time(),
            node => $node,
            template => $template + 0,
        });
        return $vmid;
    });
}

## methods

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Directory index.",
    permissions => { user => 'all' },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => { name => { type => 'string' } },
        },
        links => [{ rel => 'child', href => "{name}" }],
    },
    code => sub {
        return [{ name => 'templates' }, { name => 'servers' }];
    },
});

__PACKAGE__->register_method({
    name => 'templates',
    path => 'templates',
    method => 'GET',
    description => "List all QEMU templates of the cluster. Each one can be used on every node: a"
        . " template on local storage of another node is cloned there and migrated.",
    permissions => {
        description => "Only templates with 'VM.Clone' or 'VM.Audit' permission are listed.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object', properties => $template_properties },
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $node = $param->{node};
        $node = PVE::INotify::nodename() if $node eq 'localhost';
        my $storecfg = PVE::Storage::config();

        my $res = [];
        for my $info (PVE::CloudProvision::Templates::list(sub {
            $rpcenv->check_any($authuser, "/vms/$_[0]", ['VM.Clone', 'VM.Audit'], 1);
        })->@*) {
            my $plan = eval { PVE::CloudProvision::Templates::clone_plan($info, $node, undef, 1, $storecfg) };
            $info->{direct} = ($plan && !$plan->{migrate}) ? 1 : 0;
            delete $info->{conf};
            push @$res, $info;
        }
        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'servers',
    path => 'servers',
    method => 'GET',
    description => "List the cloud servers of the cluster (VMs created by pve-cloudprovision).",
    permissions => {
        description => "Only servers with 'VM.Audit' permission are listed.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object', properties => $server_properties },
    },
    code => sub {
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $guests = PVE::Cluster::get_vmlist()->{ids} // {};
        my $names = PVE::Cluster::get_guest_config_property('name') // {};
        my $all = PVE::CloudProvision::Config::load_all_meta();

        my $res = [];
        for my $vmid (sort { $a <=> $b } keys %$all) {
            my $meta = $all->{$vmid} or next;
            next if !$rpcenv->check($authuser, "/vms/$vmid", ['VM.Audit'], 1);
            my $guest = $guests->{$vmid};
            next if !$guest && PVE::CloudProvision::Config::reservation_active($meta);
            push @$res, server_entry($vmid, $meta, $guest, ($names->{$vmid} // {})->{name});
        }
        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'create',
    path => '',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Create a cloud server from a template: clone it (on the template's node and"
        . " migrate it here if the template is on local storage of another node), apply the CPU,"
        . " memory, disk and network settings, set up routed IPs (pve-routedip), traffic"
        . " accounting (pve-trafficd) and the guest network through cloud-init.",
    permissions => {
        description => "'VM.Allocate' and 'VM.Config.*' on /vms/{vmid} (or on the pool),"
            . " 'VM.PowerMgmt' to start it, 'VM.Clone' on the template, 'Datastore.AllocateSpace'"
            . " on the storages, 'SDN.Use' on the bridges, and 'Sys.Modify' on / for routed IPs"
            . " and traffic accounting.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => $create_properties,
    },
    returns => { type => 'string', description => "UPID of the create task." },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $node = extract_param($param, 'node');

        my $plan = PVE::CloudProvision::Provision::create_plan($param);

        my $vmid = reserve_vmid($param->{vmid}, $node, $plan->{template}->{vmid});
        $plan->{vmid} = $vmid;
        $plan->{name} //= "vm$vmid";

        my $upid = eval {
            check_create_permissions($rpcenv, $authuser, $plan);
            # the check while validating the request ran without the VMID
            PVE::CloudProvision::Provision::check_routed_conflicts($vmid, $plan->{nics});

            $rpcenv->fork_worker('cpcreate', $vmid, $authuser, sub {
                my ($upid) = @_;
                PVE::CloudProvision::Provision::create_worker($plan, $upid);
            });
        };
        if (my $err = $@) {
            eval { PVE::CloudProvision::Config::update_meta($vmid, sub { undef }) };
            warn $@ if $@;
            die $err;
        }
        return $upid;
    },
});

1;

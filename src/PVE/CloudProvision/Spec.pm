package PVE::CloudProvision::Spec;

# Request formats of pve-cloudprovision and the pure helpers built on them: the
# NIC and data disk property strings, the guest address derived from routed
# CIDRs, drive keys, boot order and the config merge of a reinstall.
#
# Nothing in here touches the cluster, storage or qemu-server, see
# PVE::CloudProvision::Provision for that.

use strict;
use warnings;

use Socket qw(AF_INET AF_INET6 inet_ntop inet_pton);

use PVE::JSONSchema;
use PVE::Tools;

our $MAX_NETS = 32; # like qemu-server
our $MAX_DATA_DISKS = 8;

our @DIRECTIONS = qw(both in out max); # pve-trafficd

## NIC

my $nic_fmt = {
    bridge => {
        type => 'string',
        format => 'pve-bridge-id',
        default_key => 1,
        description => "Bridge (or SDN VNet) the network device is attached to.",
    },
    model => {
        type => 'string',
        pattern => '[a-z][a-z0-9_\-]*',
        description => "Network card model.",
        default => 'virtio',
        optional => 1,
    },
    macaddr => {
        type => 'string',
        format => 'mac-addr',
        description => "MAC address, random by default.",
        optional => 1,
    },
    tag => {
        type => 'integer',
        minimum => 1,
        maximum => 4094,
        description => "VLAN tag.",
        optional => 1,
    },
    firewall => {
        type => 'boolean',
        description => "Protect the device with the PVE firewall.",
        optional => 1,
    },
    mtu => {
        type => 'integer',
        minimum => 1,
        maximum => 65520,
        description => "MTU (1 means the MTU of the bridge).",
        optional => 1,
    },
    queues => {
        type => 'integer',
        minimum => 0,
        maximum => 64,
        description => "Number of packet queues.",
        optional => 1,
    },
    rate => {
        type => 'number',
        minimum => 0,
        description => "Rate limit in MB/s (the rate of the PVE network device).",
        optional => 1,
    },
    cidr => {
        type => 'string',
        pattern => '[0-9A-Fa-f:./;]+',
        format_description => 'CIDR[;CIDR...]',
        description => "IPv4/IPv6 addresses or networks of any prefix length routed to the device"
            . " (pve-routedip). The first one of each family also sets the guest address"
            . " through cloud-init: a host route (/32, /128) is used as is, of a network the"
            . " first address after the network address.",
        optional => 1,
    },
    'tap-only' => {
        type => 'boolean',
        description => "pve-routedip tap-only mode: the tap device is not inserted into the"
            . " bridge, it becomes a point-to-point link to the guest.",
        optional => 1,
    },
    'rp-filter' => {
        type => 'boolean',
        description => "pve-routedip strict reverse path filter (IPv4, tap-only only).",
        optional => 1,
    },
    gateway4 => {
        type => 'string',
        format => 'ipv4',
        description => "pve-routedip host side IPv4 gateway of this device (default: the cluster"
            . " wide one). Also the guest's IPv4 gateway.",
        optional => 1,
    },
    gateway6 => {
        type => 'string',
        format => 'ipv6',
        description => "pve-routedip host side IPv6 gateway of this device (default: the cluster"
            . " wide one). Also the guest's IPv6 gateway.",
        optional => 1,
    },
    ip => {
        type => 'string',
        format => 'pve-ipv4-config',
        format_description => 'IPv4Format/CIDR',
        description => "Guest IPv4 config (cloud-init) instead of the one derived from 'cidr':"
            . " 'dhcp', 'manual' or an address in CIDR notation.",
        optional => 1,
    },
    gw => {
        type => 'string',
        format => 'ipv4',
        description => "Guest IPv4 gateway for a static 'ip' (default: the routed IP gateway if"
            . " the device has routed IPv4).",
        optional => 1,
    },
    ip6 => {
        type => 'string',
        format => 'pve-ipv6-config',
        format_description => 'IPv6Format/CIDR',
        description => "Guest IPv6 config (cloud-init) instead of the one derived from 'cidr':"
            . " 'auto', 'dhcp', 'manual' or an address in CIDR notation.",
        optional => 1,
    },
    gw6 => {
        type => 'string',
        format => 'ipv6',
        description => "Guest IPv6 gateway for a static 'ip6' (default: the routed IP gateway if"
            . " the device has routed IPv6).",
        optional => 1,
    },
    traffic => {
        type => 'boolean',
        description => "Count the traffic of the device (pve-trafficd). Implied by 'quota',"
            . " 'quota-rate' and 'direction'.",
        optional => 1,
    },
    quota => {
        type => 'string',
        pattern => '\d+(?:\.\d+)?\s*(?:[KMGTPkmgtp](?:i|iB|ib|B|b)?)?',
        format_description => 'SIZE',
        description => "Traffic quota of the counting period (pve-trafficd): bytes, or with unit"
            . " K, M, G, T, P (1024) or KB, MB, GB, TB, PB (1000). When reached, the device is"
            . " limited to 'quota-rate'.",
        optional => 1,
    },
    'quota-rate' => {
        type => 'number',
        minimum => 0.001,
        description => "Rate limit in MB/s once the quota is reached (default: pve-trafficd's"
            . " cluster wide setting).",
        optional => 1,
    },
    direction => {
        type => 'string',
        enum => [@DIRECTIONS],
        description => "Traffic counted against the quota (default: pve-trafficd's cluster wide"
            . " setting).",
        optional => 1,
    },
};

PVE::JSONSchema::register_format('pve-cloudprovision-nic', $nic_fmt);

sub nic_format {
    return $nic_fmt;
}

# Parse a NIC property string. 'cidr' becomes a list (of the given strings, the
# canonical form is up to pve-routedip).
sub parse_nic {
    my ($value) = @_;

    my $nic = PVE::JSONSchema::parse_property_string($nic_fmt, $value);
    $nic->{model} //= 'virtio';
    $nic->{cidr} = [PVE::Tools::split_list($nic->{cidr} // '')];

    die "'gw' requires a static 'ip'\n"
        if defined($nic->{gw}) && !static_config($nic->{ip});
    die "'gw6' requires a static 'ip6'\n"
        if defined($nic->{gw6}) && !static_config($nic->{ip6});

    return $nic;
}

sub static_config {
    my ($value) = @_;
    return defined($value) && $value =~ m!/!;
}

# keys of the qemu-server network device
my @QEMU_NET_KEYS = qw(bridge tag firewall rate mtu queues);

# the netX value of the guest config ($nic: parsed NIC)
sub qemu_net {
    my ($nic) = @_;

    my $res = $nic->{model};
    $res .= "=" . uc($nic->{macaddr}) if defined($nic->{macaddr});
    for my $key (@QEMU_NET_KEYS) {
        next if !defined($nic->{$key});
        my $value = $nic->{$key};
        $value = $value ? 1 : 0 if $key eq 'firewall';
        $res .= ",$key=$value";
    }
    return $res;
}

sub routed {
    my ($nic) = @_;
    return scalar($nic->{cidr}->@*) > 0;
}

# pve-routedip settings of a NIC (update_nic parameters), undef if not routed
sub routedip_settings {
    my ($nic) = @_;

    return undef if !routed($nic);

    my $res = { cidr => join(';', $nic->{cidr}->@*) };
    $res->{$_} = $nic->{$_} ? 1 : 0 for grep { defined($nic->{$_}) } qw(tap-only rp-filter);
    $res->{$_} = $nic->{$_} for grep { defined($nic->{$_}) } qw(gateway4 gateway6);
    return $res;
}

# pve-trafficd settings of a NIC (update_nic parameters), undef if not counted
sub trafficd_settings {
    my ($nic) = @_;

    my $res = {};
    $res->{quota} = $nic->{quota} if defined($nic->{quota});
    $res->{rate} = $nic->{'quota-rate'} if defined($nic->{'quota-rate'});
    $res->{direction} = $nic->{direction} if defined($nic->{direction});

    return $res if $nic->{traffic} || scalar(keys %$res);
    return undef;
}

## guest addresses

sub cidr_family {
    my ($cidr) = @_;
    return $cidr =~ m/:/ ? 6 : 4;
}

# The address a guest configures for a routed CIDR: a host route (/32, /128) is
# the address itself, of a network the first address after the network address.
sub guest_address {
    my ($cidr) = @_;

    my ($ip, $len) = $cidr =~ m!^([0-9A-Fa-f:.]+)(?:/(\d{1,3}))?$!
        or die "invalid CIDR '$cidr'\n";

    my ($af, $max) = cidr_family($ip) == 6 ? (AF_INET6, 128) : (AF_INET, 32);
    my $packed = inet_pton($af, $ip) // die "invalid address '$ip'\n";
    $len //= $max;
    die "invalid prefix length in '$cidr'\n" if $len > $max;

    return inet_ntop($af, $packed) if $len == $max;

    # clear the host bits, then add one
    my $bits = unpack('B*', $packed);
    substr($bits, $len) =~ tr/1/0/;
    my @bytes = unpack('C*', pack('B*', $bits));
    for (my $i = $#bytes; $i >= 0; $i--) {
        if ($bytes[$i] < 255) {
            $bytes[$i]++;
            last;
        }
        $bytes[$i] = 0;
    }

    return inet_ntop($af, pack('C*', @bytes));
}

# The cloud-init ipconfigX value of a NIC, undef if there is nothing to set.
# $gateways: { 4 => ip, 6 => ip } the effective routed IP gateways of the NIC.
#
# Per family: explicit 'ip'/'ip6' first, else the guest address of the first
# routed CIDR of that family as host address with the routed IP gateway.
sub nic_ipconfig {
    my ($nic, $gateways) = @_;

    my %first;
    for my $cidr ($nic->{cidr}->@*) {
        $first{ cidr_family($cidr) } //= $cidr;
    }

    my @parts;
    for my $family (4, 6) {
        my ($ipkey, $gwkey) = $family == 4 ? ('ip', 'gw') : ('ip6', 'gw6');
        my ($ip, $gw) = ($nic->{$ipkey}, $nic->{$gwkey});

        if (defined($ip)) {
            $gw //= $gateways->{$family} if $first{$family} && static_config($ip);
        } elsif (my $cidr = $first{$family}) {
            $ip = guest_address($cidr) . ($family == 4 ? '/32' : '/128');
            $gw //= $gateways->{$family};
        }

        next if !defined($ip);
        push @parts, "$ipkey=$ip";
        push @parts, "$gwkey=$gw" if defined($gw) && static_config($ip);
    }

    return @parts ? join(',', @parts) : undef;
}

## data disks

my $datadisk_fmt = {
    size => {
        type => 'integer',
        minimum => 1,
        default_key => 1,
        description => "Size in GiB.",
    },
    storage => {
        type => 'string',
        format => 'pve-storage-id',
        description => "Storage (default: the one of the system disk).",
        optional => 1,
    },
};

PVE::JSONSchema::register_format('pve-cloudprovision-datadisk', $datadisk_fmt);

sub parse_datadisk {
    my ($value) = @_;
    return PVE::JSONSchema::parse_property_string($datadisk_fmt, $value);
}

## drives and boot order

my $DRIVE_RE = qr/^(ide|sata|scsi|virtio)(\d+)$/;
my %BUS_MAX = (ide => 4, sata => 6, scsi => 31, virtio => 16); # qemu-server

sub drive_bus {
    my ($key) = @_;
    return $key =~ $DRIVE_RE ? $1 : undef;
}

# first free drive key of a bus, $used: hash of keys in use
sub free_drive_key {
    my ($bus, $used) = @_;

    my $max = $BUS_MAX{$bus} // die "unknown bus '$bus'\n";
    for my $i (0 .. $max - 1) {
        return "$bus$i" if !$used->{"$bus$i"};
    }
    die "no free $bus slot\n";
}

# The boot order of $conf restricted to devices it has, the system disk first
# if nothing remains.
sub boot_order {
    my ($conf, $bootdisk) = @_;

    my $boot = $conf->{boot} // '';
    my $order = $boot =~ m/(?:^|,)order=([^,]*)/ ? $1 : undef;
    return $boot if !defined($order) && $boot ne ''; # legacy format, leave alone

    my @devs = grep { defined($conf->{$_}) } PVE::Tools::split_list($order // '');
    @devs = ($bootdisk) if !@devs && defined($bootdisk);

    return @devs ? 'order=' . join(';', @devs) : undef;
}

## reinstall

# settings of the server kept over the ones of the new template (the template's
# value stays where the server has none, except for the staged clone's identity)
our @CARRY_KEYS = qw(
    name description tags onboot startup hookscript protection
    cores sockets vcpus cpu cpulimit cpuunits affinity numa memory balloon shares
    ciuser cipassword sshkeys nameserver searchdomain citype ciupgrade cicustom
    smbios1
);
my %STAGED_IDENTITY = map { $_ => 1 } qw(name description);

# indexed settings: the set of the server replaces the one of the template
our @CARRY_GROUPS = qw(net ipconfig numa hostpci usb);

my $carry_group_re = '^(?:' . join('|', @CARRY_GROUPS) . ')\d+$';
$carry_group_re = qr/$carry_group_re/;

# never taken over from either config
my %SKIP_KEYS = map { $_ => 1 } qw(digest lock pending snapshots parent snaptime vmstate
    special-sections template);

# The config of a reinstalled server.
#
#   $old       current config of the server
#   $staged    config of the staged clone of the new template
#   $system    drive keys of $old that came from the old template (replaced)
#   $kind      sub($key, $value) -> 'disk', 'cdrom', 'cloudinit' or undef (no drive)
#
# Returns { conf, moves, free, cloudinit } where 'conf' still references the
# staged disks listed in 'moves' (keys of $staged and conf), 'free' are the keys
# of $old whose volumes go away (system disks, cloud-init drive) and 'cloudinit'
# is the key of the template's cloud-init drive, which is not part of 'conf'.
sub reinstall_config {
    my ($old, $staged, $system, $kind) = @_;

    my %system = map { $_ => 1 } @$system;
    my $conf = {};
    my ($moves, $free, $cloudinit) = ([], [], undef);

    for my $key (sort keys %$staged) {
        next if $SKIP_KEYS{$key} || $STAGED_IDENTITY{$key} || $key =~ m/^unused\d+$/;
        next if $key =~ $carry_group_re;

        my $type = $kind->($key, $staged->{$key});
        if (!defined($type)) {
            $conf->{$key} = $staged->{$key};
        } elsif ($type eq 'cloudinit') {
            $cloudinit = $key;
        } else {
            $conf->{$key} = $staged->{$key};
            push @$moves, $key if $type eq 'disk';
        }
    }

    # the template's cloud-init drive is added back later, keep its slot free
    my %used = map { $_ => 1 } keys %$conf;
    $used{$cloudinit} = 1 if defined($cloudinit);

    for my $key (@CARRY_KEYS) {
        $conf->{$key} = $old->{$key} if defined($old->{$key});
    }
    for my $key (sort keys %$old) {
        $conf->{$key} = $old->{$key} if $key =~ $carry_group_re;
    }

    my @data;
    for my $key (sort keys %$old) {
        next if $SKIP_KEYS{$key};
        my $type = $kind->($key, $old->{$key}) or next;
        if ($type eq 'cloudinit' || ($type eq 'disk' && $system{$key})) {
            push @$free, $key;
        } elsif ($type eq 'disk' && $key !~ m/^unused\d+$/) {
            push @data, $key;
        }
        # cdroms (ISO images) are the template's business, unused volumes below
    }

    for my $key (@data) {
        my $target = $key;
        if ($used{$key}) {
            my $bus = drive_bus($key) // die "cannot relocate data disk '$key'\n";
            $target = free_drive_key($bus, \%used);
        }
        $used{$target} = 1;
        $conf->{$target} = $old->{$key};
    }

    my $i = 0;
    for my $key (sort { ($a =~ s/\D//gr) <=> ($b =~ s/\D//gr) } grep { m/^unused\d+$/ } keys %$old) {
        $conf->{ "unused" . $i++ } = $old->{$key};
    }

    return { conf => $conf, moves => $moves, free => $free, cloudinit => $cloudinit };
}

1;

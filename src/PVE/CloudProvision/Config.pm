package PVE::CloudProvision::Config;

# Cluster wide state of the cloud servers, one JSON file per VMID in the cluster
# file system: /etc/pve/cloudprovision/<vmid>.json
#
#   template        VMID of the template of the last create/reinstall
#   template-name   its name at that time
#   created         UNIX time of the create
#   reinstalled     UNIX time of the last reinstall
#   system-disks    drive keys that came from the template (replaced by a reinstall)
#   auto-ipconfig   { netX => value } the cloud-init ipconfigX values derived from
#                   the routed IPs; a reinstall derives them again unless the
#                   ipconfigX was changed since
#   state           'creating', 'reinstalling', 'ready' or 'error'
#   task            UPID of the current or last create/reinstall
#   error           error of the last failed one
#   staging         VMID of the staged clone of a reinstall in progress
#   saved           settings a reinstall in progress saved before replacing disks
#   reserved        UNIX time a create reserved the VMID (state 'creating')
#
# Files of guests that do not exist (anymore) are left alone: a create with the
# same VMID replaces them.

use strict;
use warnings;

use JSON;

use PVE::Tools;

our $CFG_DIR = '/etc/pve/cloudprovision';

# a VMID reserved by a create is free again after this long without the guest
# showing up (the clone creates the guest config within seconds)
our $RESERVATION_TIMEOUT = 600;

my $json = JSON->new->utf8->canonical->pretty;

sub meta_path {
    my ($vmid) = @_;
    ($vmid) = ($vmid // '') =~ m/^(\d+)$/ or die "invalid VMID\n";
    return "$CFG_DIR/$vmid.json";
}

sub load_meta {
    my ($vmid) = @_;

    my $path = meta_path($vmid);
    return undef if !-f $path;

    my $raw = PVE::Tools::file_get_contents($path);
    my $meta = eval { $json->decode($raw) };
    die "unable to parse '$path' - $@" if $@;
    die "invalid content in '$path'\n" if ref($meta) ne 'HASH';
    return sanitize_meta($meta);
}

# Check (and untaint, the daemons run in taint mode) the fields that end up in
# commands: invalid ones are dropped.
sub sanitize_meta {
    my ($meta) = @_;

    for my $key (qw(template staging created reinstalled reserved)) {
        next if !defined($meta->{$key});
        my ($value) = $meta->{$key} =~ m/^(\d+)$/;
        if (defined($value)) {
            $meta->{$key} = $value + 0;
        } else {
            delete $meta->{$key};
        }
    }
    if (defined(my $disks = $meta->{'system-disks'})) {
        $meta->{'system-disks'} = [map { m/^([a-z]+\d+)$/ ? $1 : () } ref($disks) eq 'ARRAY' ? @$disks : ()];
    }
    return $meta;
}

sub write_meta {
    my ($vmid, $meta) = @_;

    my $path = meta_path($vmid);
    mkdir($CFG_DIR) if !-d $CFG_DIR;
    PVE::Tools::file_set_contents($path, $json->encode($meta));
}

sub delete_meta {
    my ($vmid) = @_;
    my $path = meta_path($vmid);
    unlink($path) or $!{ENOENT} or die "unable to delete '$path' - $!\n";
}

sub configured_vmids {
    my $res = [];
    return $res if !-d $CFG_DIR;
    PVE::Tools::dir_glob_foreach($CFG_DIR, '(\d+)\.json', sub { push @$res, $_[1] + 0 });
    return [sort { $a <=> $b } @$res];
}

sub load_all_meta {
    my $res = {};
    for my $vmid (configured_vmids()->@*) {
        $res->{$vmid} = eval { load_meta($vmid) };
        warn $@ if $@;
    }
    return $res;
}

# cluster wide lock for all writes
sub lock_config {
    my ($code, @param) = @_;

    require PVE::Cluster;
    my $res = PVE::Cluster::cfs_lock_domain('cloudprovision', 10, $code, @param);
    die $@ if $@;
    return $res;
}

# Read-modify-write the state of one server under the lock. $code gets the
# current state (undef if none) and returns the new one (undef: delete).
sub update_meta {
    my ($vmid, $code) = @_;

    return lock_config(sub {
        my $meta = $code->(load_meta($vmid));
        if (defined($meta)) {
            write_meta($vmid, $meta);
        } else {
            delete_meta($vmid);
        }
        return $meta;
    });
}

sub reservation_active {
    my ($meta, $now) = @_;

    return 0 if !$meta || ($meta->{state} // '') ne 'creating';
    return ($meta->{reserved} // 0) + $RESERVATION_TIMEOUT > ($now // time());
}

# Free VMID in the datacenter's next-id range, skipping guests, active create
# reservations and staging VMIDs of reinstalls. Call with the lock held.
sub next_free_vmid {
    my ($ids, $all_meta, $range) = @_;

    my $lower = $range->{lower} // 100;
    my $upper = $range->{upper} // (1000 * 1000);
    my $now = time();

    my %staging = map { $_->{staging} => 1 } grep { $_ && defined($_->{staging}) } values %$all_meta;

    for (my $vmid = $lower; $vmid < $upper; $vmid++) {
        next if defined($ids->{$vmid}) || $staging{$vmid};
        next if reservation_active($all_meta->{$vmid}, $now);
        return $vmid;
    }
    die "unable to get any free VMID in range [$lower, $upper]\n";
}

1;

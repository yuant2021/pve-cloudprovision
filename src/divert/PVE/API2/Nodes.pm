package PVE::API2::Nodes;

# Installed by pve-cloudprovision. The PVE::API2::Nodes module of pve-manager is
# diverted (dpkg-divert) to the path below; load it unchanged and register the
# pve-cloudprovision API paths. Removing pve-cloudprovision restores the original.

use strict;
use warnings;

BEGIN {
    my $orig = '/usr/share/perl5/PVE/API2/Nodes.pm.pve-cloudprovision-orig';
    my $res = do $orig;
    die "unable to load $orig - $@" if $@;
    die "unable to load $orig - $!\n" if !defined($res);
}

eval {
    require PVE::API2::CloudProvision;
    PVE::API2::CloudProvision::register_api();
};
warn "pve-cloudprovision: unable to register API - $@" if $@;

1;

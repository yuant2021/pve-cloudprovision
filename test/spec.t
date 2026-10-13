#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use PVE::CloudProvision::Config;
use PVE::CloudProvision::Spec;

subtest 'guest address of a routed CIDR' => sub {
    my $cases = [
        ['203.0.113.7/32', '203.0.113.7'],
        ['203.0.113.0/29', '203.0.113.1'],
        ['203.0.113.7/29', '203.0.113.1'], # host bits are cleared first
        ['203.0.113.0/31', '203.0.113.1'],
        ['10.0.0.0/8', '10.0.0.1'],
        ['0.0.0.0/0', '0.0.0.1'],
        ['203.0.113.7', '203.0.113.7'],
        ['2001:db8:10::5/128', '2001:db8:10::5'],
        ['2001:db8:10::/64', '2001:db8:10::1'],
        ['2001:db8::/127', '2001:db8::1'],
        ['2001:db8:ab00::/40', '2001:db8:ab00::1'],
        ['::/0', '::1'],
    ];
    for my $case (@$cases) {
        my ($cidr, $addr) = @$case;
        is(PVE::CloudProvision::Spec::guest_address($cidr), $addr, "$cidr -> $addr");
    }
    for my $bad ('203.0.113.0/33', '2001:db8::/129', 'foo', '203.0.113.300/32') {
        eval { PVE::CloudProvision::Spec::guest_address($bad) };
        ok($@, "$bad rejected");
    }
};

my $gateways = { 4 => '169.254.0.1', 6 => 'fe80::1' };

my sub ipconfig {
    my ($nic) = @_;
    $nic->{cidr} //= [];
    return PVE::CloudProvision::Spec::nic_ipconfig($nic, $gateways);
}

subtest 'cloud-init ipconfig from routed IPs' => sub {
    is(
        ipconfig({ cidr => ['203.0.113.10/32', '2001:db8:10::/64'] }),
        'ip=203.0.113.10/32,gw=169.254.0.1,ip6=2001:db8:10::1/128,gw6=fe80::1',
        'host route as is, first address of a network',
    );
    is(
        ipconfig({ cidr => ['2001:db8:20::/48', '198.51.100.0/28', '203.0.113.10/32', '2001:db8:10::7/128'] }),
        'ip=198.51.100.1/32,gw=169.254.0.1,ip6=2001:db8:20::1/128,gw6=fe80::1',
        'first CIDR of each family',
    );
    is(ipconfig({ cidr => ['2001:db8::/64'] }), 'ip6=2001:db8::1/128,gw6=fe80::1', 'IPv6 only');
    is(ipconfig({ cidr => [] }), undef, 'nothing routed, nothing set');
};

subtest 'explicit guest IP config wins' => sub {
    is(
        ipconfig({ cidr => ['203.0.113.0/29'], ip => '203.0.113.5/32' }),
        'ip=203.0.113.5/32,gw=169.254.0.1',
        'explicit address, routed gateway',
    );
    is(
        ipconfig({ cidr => ['203.0.113.0/29'], ip => '203.0.113.5/29', gw => '203.0.113.6' }),
        'ip=203.0.113.5/29,gw=203.0.113.6',
        'explicit gateway',
    );
    is(ipconfig({ cidr => ['203.0.113.0/29'], ip => 'dhcp' }), 'ip=dhcp', 'dhcp has no gateway');
    is(ipconfig({ ip => '192.168.1.5/24' }), 'ip=192.168.1.5/24', 'not routed: no implied gateway');
    is(
        ipconfig({ cidr => ['203.0.113.10/32'], ip6 => 'auto' }),
        'ip=203.0.113.10/32,gw=169.254.0.1,ip6=auto',
        'families are independent',
    );
};

subtest 'NIC property string' => sub {
    my $nic = PVE::CloudProvision::Spec::parse_nic(
        'vmbr0,cidr=203.0.113.10;2001:db8::/64,tap-only=1,rate=12.5,quota=1T,tag=20',
    );
    is($nic->{bridge}, 'vmbr0', 'bridge is the default key');
    is($nic->{model}, 'virtio', 'default model');
    is_deeply($nic->{cidr}, ['203.0.113.10', '2001:db8::/64'], 'CIDR list');
    is(
        PVE::CloudProvision::Spec::qemu_net($nic),
        'virtio,bridge=vmbr0,tag=20,rate=12.5',
        'qemu-server network device',
    );
    is_deeply(
        PVE::CloudProvision::Spec::routedip_settings($nic),
        { cidr => '203.0.113.10;2001:db8::/64', 'tap-only' => 1 },
        'pve-routedip settings',
    );
    is_deeply(
        PVE::CloudProvision::Spec::trafficd_settings($nic),
        { quota => '1T' },
        'pve-trafficd settings',
    );

    my $plain = PVE::CloudProvision::Spec::parse_nic(
        'bridge=vmbr1,model=e1000,macaddr=bc:24:11:00:00:01,firewall=0',
    );
    is(
        PVE::CloudProvision::Spec::qemu_net($plain),
        'e1000=BC:24:11:00:00:01,bridge=vmbr1,firewall=0',
        'model with MAC address',
    );
    is(PVE::CloudProvision::Spec::routedip_settings($plain), undef, 'not routed');
    is(PVE::CloudProvision::Spec::trafficd_settings($plain), undef, 'not counted');
    is_deeply(
        PVE::CloudProvision::Spec::trafficd_settings(PVE::CloudProvision::Spec::parse_nic('vmbr1,traffic=1')),
        {},
        'counted without quota',
    );

    for my $bad ('vmbr0,gw=192.0.2.1', 'vmbr0,ip=dhcp,gw=192.0.2.1', 'vmbr0,ip6=auto,gw6=fe80::2', 'vmbr0,quota=lots') {
        eval { PVE::CloudProvision::Spec::parse_nic($bad) };
        ok($@, "'$bad' rejected");
    }
};

subtest 'drive slots and boot order' => sub {
    is(PVE::CloudProvision::Spec::free_drive_key('scsi', { scsi0 => 1, scsi1 => 1, scsi3 => 1 }), 'scsi2');
    eval { PVE::CloudProvision::Spec::free_drive_key('ide', { map { ("ide$_" => 1) } 0 .. 3 }) };
    like($@, qr/no free ide slot/, 'full bus');

    my $conf = { scsi0 => 'x', net0 => 'y' };
    is(PVE::CloudProvision::Spec::boot_order({ %$conf, boot => 'order=scsi0;ide2;net0' }, 'scsi0'),
        'order=scsi0;net0', 'missing devices dropped');
    is(PVE::CloudProvision::Spec::boot_order({ %$conf, boot => 'order=ide2' }, 'scsi0'),
        'order=scsi0', 'boot disk if nothing is left');
    is(PVE::CloudProvision::Spec::boot_order({ %$conf, boot => 'cdn' }, 'scsi0'), 'cdn', 'legacy format kept');
};

# drive classification as qemu-server does it, by value
my $kind = sub {
    my ($key, $value) = @_;
    return 'disk' if $key =~ m/^unused\d+$/;
    return undef if $key !~ m/^(?:ide|sata|scsi|virtio)\d+$|^efidisk0$|^tpmstate0$/;
    return 'cloudinit' if $value =~ m/cloudinit/;
    return 'cdrom' if $value =~ m/media=cdrom/;
    return 'disk';
};

subtest 'reinstall keeps the server settings over the template' => sub {
    my $old = {
        name => 'web1',
        description => 'customer 42',
        cores => 4,
        memory => 4096,
        cpu => 'host',
        smbios1 => 'uuid=11111111-1111-1111-1111-111111111111',
        net0 => 'virtio=BC:24:11:00:00:01,bridge=vmbr0',
        net1 => 'virtio=BC:24:11:00:00:02,bridge=vmbr1',
        ipconfig0 => 'ip=203.0.113.10/32,gw=169.254.0.1',
        scsi0 => 'local-lvm:vm-100-disk-0,size=20G',
        scsi1 => 'local-lvm:vm-100-disk-1,size=50G',
        efidisk0 => 'local-lvm:vm-100-disk-2,size=4M',
        ide2 => 'local-lvm:vm-100-cloudinit,media=cdrom',
        ide0 => 'local:iso/rescue.iso,media=cdrom',
        unused3 => 'local-lvm:vm-100-disk-3',
        boot => 'order=scsi0;net0',
        digest => 'abc',
    };
    my $staged = {
        name => 'cloudprovision-staging-100',
        description => 'template notes',
        cores => 1,
        memory => 1024,
        ostype => 'l26',
        bios => 'ovmf',
        vmgenid => 'new-genid',
        smbios1 => 'uuid=22222222-2222-2222-2222-222222222222',
        net0 => 'virtio=BC:24:11:FF:FF:FF,bridge=vmbr0',
        ipconfig0 => 'ip=dhcp',
        scsi0 => 'local-lvm:vm-900-disk-0,size=3G',
        scsi1 => 'local-lvm:vm-900-disk-1,size=1G',
        efidisk0 => 'local-lvm:vm-900-disk-2,size=4M',
        ide2 => 'local-lvm:vm-900-cloudinit,media=cdrom',
        sata0 => 'none,media=cdrom',
        boot => 'order=scsi0;ide2;net0',
    };

    my $res = PVE::CloudProvision::Spec::reinstall_config($old, $staged, ['scsi0', 'efidisk0'], $kind);
    my $conf = $res->{conf};

    is($conf->{$_}, $old->{$_}, "$_ kept") for qw(name description cores memory cpu smbios1 net0 net1 ipconfig0);
    is($conf->{$_}, $staged->{$_}, "$_ from the template") for qw(ostype bios vmgenid scsi0 efidisk0 sata0 boot);
    is($conf->{scsi1}, $staged->{scsi1}, 'template disk takes its slot');
    is($conf->{scsi2}, $old->{scsi1}, 'data disk moved to a free slot');
    is($conf->{unused0}, $old->{unused3}, 'unused volume kept');
    ok(!defined($conf->{ide0}), 'old ISO not taken over');
    ok(!defined($conf->{ide2}), 'cloud-init drive left out');
    ok(!defined($conf->{digest}), 'no digest');
    is($res->{cloudinit}, 'ide2', "template's cloud-init slot");
    is_deeply([sort $res->{moves}->@*], ['efidisk0', 'scsi0', 'scsi1'], 'staged disks to move');
    is_deeply([sort $res->{free}->@*], ['efidisk0', 'ide2', 'scsi0'], 'old system disks and cloud-init drive go');
};

subtest 'template values where the server has none' => sub {
    my $old = { name => 'db1', net0 => 'virtio,bridge=vmbr0', scsi0 => 'local-lvm:vm-101-disk-0' };
    my $staged = {
        name => 'cloudprovision-staging-101',
        description => 'template notes',
        cpu => 'x86-64-v3',
        cores => 2,
        net0 => 'virtio,bridge=vmbr9',
        net1 => 'virtio,bridge=vmbr9',
        ipconfig1 => 'ip=dhcp',
        virtio0 => 'local-lvm:vm-901-disk-0',
    };
    my $res = PVE::CloudProvision::Spec::reinstall_config($old, $staged, ['scsi0'], $kind);
    my $conf = $res->{conf};

    is($conf->{cpu}, 'x86-64-v3', 'template CPU type');
    is($conf->{cores}, 2, 'template cores');
    ok(!defined($conf->{description}), 'no template notes');
    is($conf->{net0}, $old->{net0}, "server's NICs");
    ok(!defined($conf->{net1}) && !defined($conf->{ipconfig1}), "template's other NICs gone");
    is($res->{cloudinit}, undef, 'template without cloud-init drive');
    is_deeply($res->{free}, ['scsi0'], 'old system disk on another bus goes');
};

subtest 'VMID allocation' => sub {
    my $now = time();
    my $ids = { 100 => {}, 101 => {} };
    my $meta = {
        102 => { state => 'creating', reserved => $now },
        103 => { state => 'creating', reserved => $now - $PVE::CloudProvision::Config::RESERVATION_TIMEOUT - 1 },
        100 => { state => 'reinstalling', staging => 104 },
    };
    is(PVE::CloudProvision::Config::next_free_vmid($ids, $meta, {}), 103, 'skips guests, reservations, staging');
    is(PVE::CloudProvision::Config::next_free_vmid($ids, {}, { lower => 200 }), 200, 'next-id range');
    eval { PVE::CloudProvision::Config::next_free_vmid($ids, $meta, { lower => 100, upper => 103 }) };
    like($@, qr/unable to get any free VMID/, 'range exhausted');
};

done_testing();

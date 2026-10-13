#!/usr/bin/perl -T

# pvedaemon runs in taint mode: values read back from a server's state file end
# up in qm commands (template, staging VMID), so load_meta has to untaint them.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Scalar::Util qw(tainted);
use Test::More;

use PVE::CloudProvision::Config;

my ($dir) = tempdir(CLEANUP => 1) =~ m/^(.*)$/;
$PVE::CloudProvision::Config::CFG_DIR = $dir;

open(my $fh, '>', "$dir/100.json") or die "$!\n";
print {$fh} '{"template": 9000, "staging": "105", "created": "yesterday",'
    . ' "system-disks": ["scsi0", "efidisk0", "../etc/passwd"], "state": "ready"}';
close($fh);

my $meta = PVE::CloudProvision::Config::load_meta(100);

is($meta->{template}, 9000, 'template kept');
ok(!tainted($meta->{template}), 'template untainted');
is($meta->{staging}, 105, 'staging VMID kept');
ok(!tainted($meta->{staging}), 'staging VMID untainted');
ok(!exists($meta->{created}), 'invalid time dropped');
is_deeply($meta->{'system-disks'}, ['scsi0', 'efidisk0'], 'invalid drive key dropped');
ok(!grep({ tainted($_) } $meta->{'system-disks'}->@*), 'drive keys untainted');
is($meta->{state}, 'ready', 'other fields as stored');
is(PVE::CloudProvision::Config::load_meta(101), undef, 'no state file');

done_testing();

package PVE::CLI::pve_cloudprovision;

use strict;
use warnings;

use JSON;
use URI::Escape;

use PVE::CLIFormatter;
use PVE::CLIHandler;
use PVE::INotify;
use PVE::RPCEnvironment;
use PVE::Tools;

use PVE::API2::CloudProvision;
use PVE::API2::CloudProvision::VM;

use base qw(PVE::CLIHandler);

my $nodename = PVE::INotify::nodename();

sub setup_environment {
    PVE::RPCEnvironment->setup_default_cli_env();
}

# like qm: --sshkeys takes a file, --cipassword can be prompted for
sub param_mapping {
    my ($name) = @_;

    my $sshkeys = ['sshkeys', sub { return uri_escape(PVE::Tools::file_get_contents($_[0])) }];
    my $cipassword = PVE::CLIHandler::get_standard_mapping('pve-password', { name => 'cipassword' });

    my $mapping = {
        create => [$sshkeys, $cipassword],
        reinstall => [$sshkeys, $cipassword],
    };
    return $mapping->{$name};
}

my $upid_exit = sub {
    my ($upid) = @_;
    my $status = PVE::Tools::upid_read_status($upid);
    exit(PVE::Tools::upid_status_is_error($status) ? -1 : 0);
};

my $print_templates = sub {
    my ($data, $schema, $options) = @_;
    for my $entry (@$data) {
        $entry->{disks} = join(',', $entry->{disks}->@*) if ref($entry->{disks});
    }
    PVE::CLIFormatter::print_api_result(
        $data,
        $schema,
        ['vmid', 'name', 'node', 'ostype', 'cores', 'memory', 'disk-size', 'storage', 'cloudinit', 'shared', 'direct'],
        $options,
    );
};

my $print_servers = sub {
    my ($data, $schema, $options) = @_;
    PVE::CLIFormatter::print_api_result(
        $data,
        $schema,
        ['vmid', 'name', 'node', 'state', 'template', 'template-name', 'created', 'reinstalled', 'error'],
        $options,
    );
};

my $print_info = sub {
    my ($data, $schema, $options) = @_;
    if (($options->{'output-format'} // 'text') ne 'text') {
        PVE::CLIFormatter::print_api_result($data, $schema, undef, $options);
        return;
    }
    print JSON->new->utf8->canonical->pretty->encode($data);
};

our $cmddef = {
    templates => [
        'PVE::API2::CloudProvision', 'templates', [], { node => $nodename }, $print_templates,
        $PVE::RESTHandler::standard_output_options,
    ],
    list => [
        'PVE::API2::CloudProvision', 'servers', [], { node => $nodename }, $print_servers,
        $PVE::RESTHandler::standard_output_options,
    ],
    create => ['PVE::API2::CloudProvision', 'create', ['template'], { node => $nodename }, $upid_exit],
    show => [
        'PVE::API2::CloudProvision::VM', 'info', ['vmid'], { node => $nodename }, $print_info,
        $PVE::RESTHandler::standard_output_options,
    ],
    reinstall => ['PVE::API2::CloudProvision::VM', 'reinstall', ['vmid'], { node => $nodename }, $upid_exit],
};

1;

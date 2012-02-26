#!/usr/bin/env perl

# WARNING - Do not edit this file unless you have the perl
#           dependencies installed which are noted in the README, otherwise
#           the Makefile in this directory will try to rebuild the server script
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use File::Spec;

use Plack::Runner;
use Plack::App::File;
use Plack::Builder;
use Plack::Loader;
use Cwd qw/ abs_path /;
use File::stat;
use File::Find;
use Try::Tiny qw/ try catch /;
# Load AnyEvent correctly in PP mode.
BEGIN { $ENV{PERL_ANYEVENT_MODEL} = 'Perl' }
use AnyEvent;
BEGIN { AnyEvent::detect() }
use Scalar::Util qw/ refaddr /;
use state51::MonitoringJS::Updater;
use Web::Hippie;
use Devel::StackTrace::AsHTML;
use AnyEvent::Util qw/ close_all_fds_except /;

my $orig_name = $0;
$0 = "MonitoringJS-Async";

my $restart_interval = 60;

my $mtime_init = stat($orig_name)->mtime;
my $auto_restart = AnyEvent->timer(
    after => $restart_interval,
    interval => $restart_interval,
    cb => sub {
        my $mtime_now = stat($orig_name)->mtime;
        if ($mtime_now ne $mtime_init) {
            warn("Has been upgraded, restarting at " . time() . "\n");
            close_all_fds_except(0, 1, 2);
            exec $orig_name;
        }
    },
);

# Work out where the root is, no matter where we were run
use constant ROOT =>
    abs_path(
        -d File::Spec->catdir($Bin, "js")
        ? $Bin
      : -d File::Spec->catdir($Bin, "..", "js")
        ? File::Spec->catdir($Bin, "..")
      : die("Cannot find js/ folder for app root")
    );

# All of the bollocks below works out if we should serve a minified
# aka deployment version of the index (index.html), or the test version:
# maint/app.html as the main index.
# We do this once, at startup, as re-writing the index.html (for deployment)
# is fine as we (and apache!) serve that every time..

# Find the newest js or CSS file's mtime
my $youngest = 0;
my $wanted = sub {
    return if -d $File::Find::name;
    my $time = stat($File::Find::name)->mtime;
    $youngest = $time if $time > $youngest;
};
find($wanted, map { File::Spec->catdir(ROOT, $_) } qw/ js css /);
{   # Find app.html's mtime
    local $File::Find::name = File::Spec->catdir(ROOT, "maint", "app.html");
    $wanted->();
}

# Find mtime for minified version
my $minified_mtime = stat(File::Spec->catdir(ROOT, 'index.html'))->mtime;

# And use the minified version if possible, or the multi-file version if
# the application has been edited.
my @index =
    $minified_mtime > $youngest
    ? ("index.html")
    : ("maint", "app.html");

# Helper function to locate a file
sub file {
    Plack::App::File->new(file => File::Spec->catdir(ROOT, @_))
}

my %update_handles; # Hippie handles to push to
my $production_log = "/var/log/nagios3/nagios.log"; # For deployment
my $nagios_log_file = -r $production_log # Doesn't exist on my mac
    ? $production_log                    # so we just use the test one
    : File::Spec->catdir(ROOT, "testdata", "nagios.log");
warn "Nagios log file is $nagios_log_file\n";

my $updater = state51::MonitoringJS::Updater->new(
    filename => $nagios_log_file,
    on_read => sub {
        my $line = shift;
        foreach my $handle (values %update_handles) {
            try {
                $handle->send_msg($line);
            }
            catch {
                warn("Failed to send to handle $handle - forcing disconnect: $_\n");
                delete $update_handles{refaddr($handle)};
            };
        }
    },
)->run;

# Build the app coderef
my $app = builder {
    mount "/favicon.ico"                => file("favicon.ico");
    mount "/puppet/nodes/"              => file(qw/testdata mongodb_nodes.json/);
    mount "/puppet/nagios_host_groups/" => file(qw/testdata mongodb_nagios_host_groups.json/);
    mount "/nagios-api/state"           => file(qw/testdata nagios-api-state.json/);
    mount "/topbar.json"                => file(qw/testdata topbar.json/);
    mount "/"                           => file(@index);
    mount "/dev"                        => file("maint", "app.html");
    mount "/js"                         => Plack::App::File->new(root => File::Spec->catdir(ROOT, "js"));
    mount "/css"                        => Plack::App::File->new(root => File::Spec->catdir(ROOT, "css"));
    mount "/img"                        => Plack::App::File->new(root => File::Spec->catdir(ROOT, "img"));
    mount "/test"                       => file(qw/test index.html/);
    mount "/test/vendor/qunit.js"       => file(qw/test vendor qunit.js/);
    mount "/test/vendor/qunit.css"      => file(qw/test vendor qunit.css/);
    mount "/test/model.js"              => file(qw/test model.js/);
    mount "/test/view.js"              => file(qw/test view.js/);
    mount "/test/collections.js"        => file(qw/test collections.js/);
    mount '/_hippie' => builder {
        enable "+Web::Hippie";
        sub {
            my $env = shift;
            my $interval = $env->{'hippie.args'} || 5;
            my $h = $env->{'hippie.handle'};

            if ($env->{PATH_INFO} eq '/init') {
                $update_handles{refaddr($h)} = $h;
            }
            elsif ($env->{PATH_INFO} eq '/message') {
                my $msg = $env->{'hippie.message'};
                warn "==> got msg from client: ".Dumper($msg);
            }
            else {
                return [ '400', [ 'Content-Type' => 'text/plain' ], [ "" ] ]
                    unless $h;

                if ($env->{PATH_INFO} eq '/error') {
                    warn "==> disconnecting $h";
                    delete $update_handles{refaddr($h)};
                }
                else {
                    die "unknown hippie message";
                }
            }
            return [ '200', [ 'Content-Type' => 'application/hippie' ], [ "" ] ]
        }
    };
};

# Use Plack::Runner here so we can be directly run with perl
# as a perl script. The caller magic also allows us to be used
# as a psgi script, as we don't run anything when require'd
use Fliggy::Server;
$ENV{PLACK_SERVER} = "Fliggy";

unless (caller()) {
    my $runner = Plack::Runner->new;
    $runner->parse_options(@ARGV);
    $runner->run($app);
}

# And return the app as the final value to be a valid psgi.
return $app;


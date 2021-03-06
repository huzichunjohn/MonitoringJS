package state51::MonitoringJS::Updater;
use strict;
use warnings;
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Util qw/ portable_pipe fh_nonblocking /;
use Moo;

has filename => (
    is => 'ro',
    required => 1,
);

has on_read => (
    is => 'ro',
    required => 1,
);

sub run {
    my $self = shift;
    $self->_bind_hdl;
    return $self;
}

sub _bind_hdl {
    my $self = shift;
    my $r;
    my $child_pid = open($r, "-|", "tail", "-F", $self->filename)
       // die "can't fork: $!";
    $self->{hdl} = AnyEvent->io (
        fh => $r,
        poll => "r",
        cb => sub {
            my $data = parse_from_line(scalar <$r>)
                or return;
            $self->on_read->($data);
        },
    );
}

sub parse_from_line {
    my $line = shift;
    #[1329682622] SERVICE ALERT: jobcentre;RABBIT_FD;OK;SOFT;2;20
    my ($timestamp) = $line =~ m/\[(\d+)\]\s+SERVICE ALERT: /
        or do { warn "Unparseable line $line\n"; return (); };
    # FIXME - WTF do these fields mean?!?
    my ($host, $service, $status, $soft, $number, $message)
        = $line =~ /(\w+);(\w+);(\w+);(\w+);(\w+);(.*)$/;
    return {
        type => 'nagios_service_alert',
        hostname => $host,
        service => $service,
        last_check => $timestamp,
        plugin_output => $message,
        current_state => $status,
    };
}

1;


#!/usr/bin/perl -w

sub logmsg { print STDERR "C $$: @_\n" }

use Socket;
#use strict;
my ($rendezvous, $line);

$rendezvous = shift || '/tmp/catsock';
socket(SOCK, PF_UNIX, SOCK_STREAM, 0)       || die "socket: $!";

if (!($ok = connect(SOCK, sockaddr_un($rendezvous)))) {
  logmsg "socket: $!";
  # No connection; start the primary server
  unless ($pid = fork) {
    die "Couldn't fork: $!" unless defined $pid;
    # Child...
    exec "./server.pl";
  }
}

# Poll with linear backoff until server starts up
for ($i = 0; $i < 10 || die "connect: $!"; $i++) {
  close SOCK;
  socket(SOCK, PF_UNIX, SOCK_STREAM, 0)       || die "socket: $!";
  $ok ||= connect(SOCK, sockaddr_un($rendezvous));
  last if $ok;
  sleep $i;
}
while (defined($line = <SOCK>)) {
  logmsg $line;
}

exit;

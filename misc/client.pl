#!/usr/bin/perl -w

# Client test program

# Figure out queue directory based on args (domain/list/function)

# Generate a unique temporary filename.

# Copy message into file.

# Now we're safe; even if something bombs the message has been saved and
# will be picked up.

# Make sure server is active.

# Send message to server somehow.



# Test version:

# Start server if necessary.

# Say hello.

# Get result, exit.


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
  $ok ||= connect(SOCK, sockaddr_un($rendezvous));
  last if $ok;
  sleep $i;
}
while (defined($line = <SOCK>)) {
  logmsg $line;
}

exit;

#!/usr/bin/perl -w
use Socket;
use POSIX;
use IO::Socket;
$|=1;

sub logmsg { print STDERR "S $$: @_\n" }
sub out { syswrite($_[0], $_[1], length($_[1])) }
sub in  { sysread($_[0], $_, 1024); $_ };

my $NAME = '/tmp/catsock';
my $MAX_KIDS = 5;
my $uaddr = sockaddr_un($NAME);
my $proto = getprotobyname('tcp');

# Become a daemon
$pid = fork;
exit if $pid;
die "Couldn't fork: $!" unless defined($pid);
POSIX::setsid() or die "Can't start a new session: $!";

$SIG{CHLD} = 'IGNORE';
$SIG{PIPE} = 'IGNORE';

socket(Server,PF_UNIX,SOCK_STREAM,0)        || die "socket: $!";
unlink($NAME);
bind  (Server, $uaddr)                      || die "bind: $!";
listen(Server,SOMAXCONN)                    || die "listen: $!";

logmsg "server started on $NAME";

# Loop until we exit explicitly
MAIN:
while (1) {

  # Select on the Socket, time out after a while
  $rin = $win = $ein = ''; vec($rin,fileno(Server),1) = 1; $ein = $rin | $win;
  unless (select($rout=$rin, $wout=$win, $eout=$ein, 20)) {
    logmsg "Timed out";
    last;
  }

  # Got a connection, accept it
  accept(Client,Server);
  logmsg "Got connection";

  # Compress the child list
  @child = grep { defined } @child;

  # Find a child that can read or start a new one
  undef $use_child;
 PICK:
  for ($i = 0; $i < @child; $i++) {
    # Ping a child; if we fail while writing, it's dead.  If the response
    # doesn't come back soon, it's busy.  Note that we have to exclude
    # buffered ping responses here, so we send along the time.
    logmsg "Checking $i";
    $ping = 'Ping ' . time;
    unless (out($child[$i], $ping)) {
      logmsg "$i is dead";
      $child[$i]->close;
      undef $child[$i];
      next PICK;
    }

    # We want to get a response, but there may be buffered responses to
    # previous pings that the client didn't answer immediately.
  PING:
    while(1) {
      $rin = $win = $ein = ''; vec($rin,fileno($child[$i]),1) = 1; $ein = $rin | $win;
      $nfound = select($rout=$rin, $wout=$win, $eout=$ein, 0);
      if ($nfound && $rout) {
	$line = in($child[$i]);
	unless (defined($line) && (length($line))) {
	  logmsg "Weird; got an empty line from $i";
	  $child[$i]->close;
	  undef $child[$i];
	  next PICK;
	}

	# If the response has Exiting anywhere, the client is gone
	if ($line =~ /Exiting/) {
	  logmsg "$i has exited";
	  $child[$i]->close;
	  undef $child[$i];
	  next PICK;
	}

	# If we got the ping back, we're set
	elsif ($line =~ /$ping$/) {
	  logmsg "$i pinged successfully";
	  last PING;
	}
	else {
	  logmsg "$i had stale response";
	  next PING;
	}
      }
      else {
	logmsg "$i is busy";
	next PICK;
      }
    }
    logmsg "Using child $i";
    $use_child = $i;
    last PICK;
  }
  if (!defined($use_child) && @child < $MAX_KIDS) {
    $i = scalar(@child);
    logmsg "Starting new runner $i";

    # Setup a pipe set for the child
    $child[$i]  = new IO::Handle; $child[$i]->autoflush(1);
    $parent[$i] = new IO::Handle; $parent[$i]->autoflush(1);
    socketpair($child[$i], $parent[$i], AF_UNIX, SOCK_STREAM, PF_UNSPEC) || die "Socketpair: $!";

    # Start a runner
    if (!($pid = fork)) {
      die "Cannot fork: $!" unless defined $pid;

      logmsg "Starting runner";
      $child[$i]->close;
      close Client; # Otherwise the runner holds it open

      # Redirect stdin and out so the runner is simple
      *STDIN->fdopen(fileno($parent[$i]), 'r');
      *STDOUT->fdopen(fileno($parent[$i]),'w');
      exec "./runner.pl $i";
      # Never get here...
    }
    else {
      # Parent...
      $parent[$i]->close;

      # Get back the greeting
      $rin = $win = $ein = ''; vec($rin,fileno($child[$i]),1) = 1; $ein = $rin | $win;
      if(select($rout=$rin, $wout=$win, $eout=$ein, 5)) {
	$line = in($child[$i]);
	logmsg "Runner is awake";
	$use_child = $i;
      }
      else {
	# The child never said hello...
	print Client "Problems starting queue runner; queueing";
	close Client;
	next;
      }
    }
  }
  if (!defined($use_child)) {
    print Client "Excessive load; queueing";
    close Client;
    next;
  }

  # Tell the client to go.
  unless (out($child[$use_child], "Parent $$ sending")) {
    # It was alive just a second ago, but now it's dead.  So we just
    # pretend we have high load.
    print Client "Excessive load; queueing";
    close Client;
    next;
  }

  # Get the response back from the client
  $line = in($child[$use_child]);
  
  # Hand it back to the client
  print Client $line;
  close Client;
}

# Out of while() loop; time to die.
logmsg "Shutting down";
exit;

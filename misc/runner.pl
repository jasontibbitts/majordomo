#!/usr/bin/perl -w

# Program to do something.

# Input and output go back to the script which called us.  Standard error,
# who knows?

# Runner starts up, sends "Starting" so the server knows it worked.

# When the runner is awaiting input, it spits out "ready".

$| = 1;

sub logmsg { print STDERR "R($ARGV[0]) $$: @_\n" }
sub out { syswrite(STDOUT, $_[0], length($_[0]));}
sub in  { sysread(STDIN, $_, 1024); $_};

out('Starting');

# Loop forever
while (1) {
  # Select on standard input, which is our signal to go.
  $rin = $win = $ein = ''; vec($rin,fileno(STDIN),1) = 1; $ein = $rin | $win;
  $nfound = select($rout=$rin, $wout=$win, $eout=$ein, 10);
  unless ($nfound) {
    logmsg "Timed out";
    last;
  }

  $line = in();
  if ($line =~ /(Ping \d+)$/) {
    # The server is pinging us to see if we're alive.  Return the ping and
    # wait again.  This lets the server know that we're are just sitting
    # here.  We chop off all but the last bit because the server may have
    # pinged us multiple times.
    out($line);
    next;
  }

  logmsg "Read undef??? $nfound, $rout, $wout, $eout" unless defined $line;

  out("Runner $$ sending");
  logmsg "Sleeping...";
  sleep 5;
  logmsg "Awake!";
}
logmsg "Exiting";
out('Exiting');
exit;

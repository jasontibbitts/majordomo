#!/usr/bin/perl

# This script will run the bounce parsing engine over a number of files.
# Each file must contain one message including all of the headers.


use lib "blib/lib";

use MIME::Parser;
use Mj::Log;
use Mj::BounceParser;

$debug  = 0;
$noskip = 0;

# Quiet some warnings;
$msgno = $type = $user = 0;

# Open a log
$::log = new Mj::Log;

if ($debug) {
  $::log->add(method      => 'handle',
	      id          => 'test',
	      handle      => \*STDERR,
	      level       => 5000,
	      subsystem   => 'mail',
	      log_entries => 1,
	      log_exits   => 1,
	      log_args    => 1,
	     );
}

# Grab counts
opendir(DIR, "t/bounces") or die "Can't find bounces: $!";
$count = 0;
while(defined($file = readdir(DIR))) {
  $count++ if $file =~ /^\d+$/;
}

# Tell the test suite how many tests we have
print "1..$count\n";

$parser = new MIME::Parser;
$parser->output_dir('/tmp');

rewinddir(DIR);

$count = 1;
BOUNCE:
while(defined($file = readdir(DIR))) {
  next unless $file =~ /^\d+$/;

  # Read the description file
  unless (open(DESC, "t/bounces/$file.desc")) {
    print "not ok $count (couldn't find description file: $!)\n";
    next BOUNCE;
  }
  $ehandler = <DESC>; chomp $ehandler;
  #  ($ehandler, $etype) = split('\t+', $line);
  $i = 0;
  while(defined($line = <DESC>)) {
    chomp $line;
    $expect[$i++] = [split('\t+', $line)];
  }
  close(DESC);

  if ($ehandler =~ /^skip/) {
    $ehandler =~ s/^skip\s+//;
    unless ($noskip) {
      print "ok $count #Skip";
      next BOUNCE;
    }
  }

  open BOUNCE, "t/bounces/$file" or die("Can't open $file: $!");
  $ent = $parser->read(\*BOUNCE);
  close BOUNCE;

  ($type, $msgno, $user, $handler, $data) =
    Mj::BounceParser::parse($ent,
			    'test',
			    '+',
			   );
  # Now compare the parsed out put with what we expect

  # First, check that the right handler was used and the right type was
  # detected.
  if ($ehandler ne $handler) {
    print "not ok $count (expected handler $ehandler, got $handler)\n";
    next BOUNCE;
  }
#    if ($etype ne $type) {
#      print "not ok $count (expected type $etype, got $type)\n";
#      next BOUNCE;
#    }

  # If we weren't expected to find any users, make sure that we didn't get any
  if ($expect[0][0] eq 'none') {
    if (keys(%$data)) {
      print "not ok $count (parsed users where none were expected)\n";
    }
    else {
      print "ok $count (expected no users and found none)\n";
    }
    next BOUNCE;
  }

  # Now make sure we parsed out everything properly
  for ($i=0; $i<@expect; $i++) {
    $euser = $expect[$i][0];
    $estatus = $expect[$i][1];
    $ediag = $expect[$i][2]; # Might be undefined

    # Must have seen the user
    unless ($data->{$euser}) {
      print "not ok $count (expected to see $euser, but didn't)\n";
      next BOUNCE;
    }

    # Status must be correct
    unless ($data->{$euser}{status} eq $estatus) {
      print "not ok $count (expected status $estatus, found $data->{$euser}{status})\n";
      next BOUNCE;
    }

    # Diagnostic must be correct, if one is exepcted
    if ($ediag && $data->{$euser}{diag} ne $ediag) {
      print "not ok $count (expected diagnostic $ediag, found $data->{$euser}{diag})\n";
      next BOUNCE;
    }

    # Remove this user from the data hash
    delete $data->{$euser};
  }

  # Now make sure that no more users were found than were expected
  if (keys(%$data)) {
    print "not ok $count (found ". scalar(keys(%$data)). " more users than expected: ".join(" ", keys(%$data)).")\n";
    next BOUNCE;
  }

  # Everything was OK
  print "ok $count\n";
  $count++;
}

#!/usr/bin/perl

# This script will run the bounce parsing engine over a number of files.
# Each file must contain one message including all of the headers.

# You can call this from an uninstalled Majordomo installation by using
# something like the following:

# perl -I blib/lib misc/parsebounce.pl interesting-bounces/*

# assuming that you are in the top directory of the Majordomo source tree
# and that you have freshly done a make.  There is no need to do a make
# install to run this tool.

use MIME::Parser;
use Bf::Parser;
use Mj::FakeLog;

#$Mj::FakeLog::verbose = 1;

$parser = new MIME::Parser;
$total  = 0;
$parsed = 0;
$users  = 0;
$gotuser = 0;
$usefuldiag = 0;

for $file (@ARGV) {
  open FILE, $file or die("Can't open $file: $!");
  $ent = $parser->read(\*FILE);
  close FILE;

  $total++;
  print "Parsing $file...\n";

  ($type, $msgno, $user, $data) =
    Bf::Parser::parse($ent,
		      'test',
		      '+',
		     );

  if ($type eq 'M') {
    print "Parsed this bounce: message #$msgno.\n";
    $parsed++;
    if ($user) {
      if ($data->{$user}) {
	$status = $data->{$user}{status};
	$diag   = $data->{$user}{diag} || 'unknown';
      }
      else {
	$status = 'bounce';
	$diag   = 'unknown';
      }
      $data = {$user => {status => $status, diag => $diag}};
    }

    if (keys %$data) {
      $gotuser++;
    }

    # Now plow through the data from the parsers
    for $i (keys %$data) {
      $users++;
      if ($data->{$i}{diag} &&
	  $data->{$i}{diag} ne 'unknown' &&
	  $data->{$i}{diag} !~ /250 /)
	{
	  $usefuldiag++;
	}
      $status = $data->{$i}{status};
      if ($status eq 'unknown' || $status eq 'warning' || $status eq 'failure') {
	print "  User:       $i\n";
	print "  Status:     $data->{$i}{status}\n";
	print "  Diagnostic: $data->{$i}{diag}\n\n";
      }
    }
  }
  else {
    print "Couldn't parse this bounce.\n\n";
  }
  $ent->purge;
}

$pct = 100 * ($parsed / $total);
print "Parsed $parsed ($pct\%) of $total bounces.\n";
if ($parsed) {
  $pct = 100 * ($gotuser / $parsed);
  print "Parsed out a user in $gotuser ($pct%) of $parsed parsed bounces.\n";
  if ($users) {
    $pct = 100 * ($usefuldiag / $users);
    print "Found a \"useful\" diagnostic for $usefuldiag ($pct%)\n  of $users total users extracted.\n";
  }
}

#!/usr/bin/perl
use MIME::Parser;
use Bf::Parser;
use Mj::FakeLog;

$parser = new MIME::Parser;
$ent = $parser->read(\*STDIN);

($type, $msgno, $user, $data) =
  Bf::Parser::parse($ent,
		    $ARGV[0] || 'test',
		    $ARGV[1] || '+',
		   );

if ($type eq 'M') {
  print "Parsed this bounce: message #$msgno.\n";
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

  # Now plow through the data from the parsers
  for $i (keys %$data) {
    $status = $data->{$i}{status};
    if ($status eq 'unknown' || $status eq 'warning' || $status eq 'failure') {
      print "  User:       $i\n";
      print "  Status:     $data->{$i}{status}\n";
      print "  Diagnostic: $data->{$i}{diag}\n\n";
    }
  }
}
else {
  print "Couldn't parse this bounce.\n";
}
$ent->purge;

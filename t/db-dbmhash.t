#!/usr/bin/perl -w
use Mj::SimpleDB;
use Mj::Log;
use Majordomo;
use Safe;
$Majordomo::safe = new Safe;
$Majordomo::safe->permit_only(qw(const leaveeval null pushmark return rv2sv stub));

$NUM = $ENV{COUNT} || 100;

$::log = new Mj::Log;
$::log->add   
    (   
     method      => 'handle',
     id          => 'text',
     handle      => \*STDERR,
     filename    => '/dev/null',
     level       => 0,
#    level       => 500,
     subsystem   => 'mail',
     log_entries => 1,
     log_exits   => 1,
     log_args    => 1,
    );

$count = 1;

print "1..22\n";

# 1
# Allocate a text SimpleDB
$db = new Mj::SimpleDB(filename => "testdb.$$",
		       backend  =>'db',
		       fields   => [qw(a b c d)],
		      );
okif($db);

# 2
# Store a key
($ok, undef) = $db->add("", "test1",
			{a => "001",
			 b => "",
			 c => "group1",
			 d => "   "
			});
okif($ok);

# 3
# Store another key
($ok, undef) = $db->add("", "testb",
			{a => "z01",
			 b => "",
			 c => "group2",
			 d => " "
			});
okif($ok);

# 4
# Delete a ficticious key
($ok, $data) = $db->remove("", "urgh");
okunless($ok);

# 5, 6, 7, 8, 9
# Delete a real key
($key, $data) = $db->remove("", "test1");
okeq("test1", $key);
okeq("001",   $data->{a});
okeq("",      $data->{b});
okeq("group1",$data->{c});
okeq("   ",   $data->{d});

# 10
# Add some keys
$ok = 1;
for (my $i = 0; $i < $NUM; $i++) {
  ($tok, undef) = $db->add("", "test$i",
			   {a => "zzzz$i",
			    b => "",
			    c => 'bigunz',
			    d => 'whitespace is fun!(*&*&#$$###      ',
			   });
  
  $ok = 0 unless $tok;
  $hash{"test$i"} = 1;
}
okif($ok);

# 11, 12 Delete one of them; note that we have no guarantees about which
# one we'll get
($key, $data, $oops) = $db->remove('regexp', '/test\d/');
okif($key =~ /test\d/);
okunless($oops);
delete $hash{$key};

# 13
# Alter one of them
($key) = $db->replace('', 'test1', 'c', 'wumpus');
okeq('test1', $key);

# 14, 15, 16
# Make sure we changed it
$data = $db->lookup('test1');
okif($data);
okeq('zzzz1',  $data->{a});
okeq('wumpus', $data->{c});

# 17
# Alter them all
@stuff = $db->replace('regexp,allmatching', '/test/', 'c', 'oink');
oke(scalar @stuff, $NUM);

# 18, 19, 20
# Delete the lot
$ok = 1;
$i = 1;
@stuff = $db->remove('regexp,allmatching', '/test\d/');
while (($key, $data) = splice @stuff, 0, 2) {
  # Note that we might not get them back in any particular order
  $ok = 0 unless $hash{$key};
  delete $hash{$key};
  $ok = 0 if $data->{c} ne 'oink';
  $i++;
}
okif($ok);
oke(scalar keys %hash, 0);
oke($NUM, $i);

# 21, 22
# Delete the one straggler
($key, $data) = $db->remove('', 'testb');
okeq('testb', $key);
okeq('oink',  $data->{c});

# Call the destructors
undef $db;

sub okif {
  if (shift) {
    print "ok $count\n";
  }
  else {
    print "not ok $count\n";
  }
  $count++;
}

sub okunless {
  if (shift) {
    print "not ok $count\n";
  }
  else {
    print "ok $count\n";
  }
  $count++;
}

sub okeq {
  if (shift eq shift) {
    print "ok $count\n";
  }
  else {
    print "not ok $count\n";
  }
  $count++;
}

sub oke {
  if (shift == shift) {
    print "ok $count\n";
  }
  else {
    print "not ok $count\n";
  }
  $count++;
}

END {
  unlink ".Ltestdb.$$";
  unlink "testdb.$$.D";
}

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

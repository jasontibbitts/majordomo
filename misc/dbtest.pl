#!/usr/bin/perl -w

use DB_File;
unlink 'blah';
#$type = new DB_File::BTREEINFO;
$type = new DB_File::HASHINFO;
#$type->{compare} = sub {$_[1] cmp $_[0]};
$db = tie %db, 'DB_File', 'blah', O_RDWR|O_CREAT, 0666, $type;

die "aargh, $!" unless $db;

$a = 'aaa';
$b = 'asdfasd';
for (1..10) {
  $status = $db->put($a++, $b++);
}

$key = $value = '';
for ($status = $db->seq($key, $value, R_FIRST) ;
     $status == 0 ;
     $status = $db->seq($key, $value, R_NEXT) )
  {
    print "$key -> $value\n";
    if ($key =~ /[bhi]$/) {
      print "  nuke $key\n";
      $status = $db->del($key, R_CURSOR);
      print "  status $status\n";
      push @new, $key, $value;
    }
  }

while (($key, $value) = splice(@new, 0, 2)) {
  print "  add in $key.new\n";
  $status = $db->put("$key.new", "$value.new");
  print "  status $status\n";
}

print "------------\n";

$key = $value = '';
for ($status = $db->seq($key, $value, R_FIRST) ;
     $status == 0 ;
     $status = $db->seq($key, $value, R_NEXT) )
  {
    print "$key -> $value\n";
  }

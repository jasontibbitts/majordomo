#!/usr/bin/perl -w

use DB_File;
#unlink 'blah';
$type = new DB_File::BTREEINFO;
#$type = new DB_File::HASHINFO;
$type->{compare} = sub {$_[1] cmp $_[0]};
print "Trying as Btree.\n";
$db = tie %db, 'DB_File', $ARGV[0], O_RDWR|O_CREAT, 0666, $type;

# unless ($db) {
#   # Try another
#   #$type = new DB_File::BTREEINFO;
#   $type = new DB_File::HASHINFO;
#   #$type->{compare} = sub {$_[1] cmp $_[0]};
#   print "Trying as Hash.\n";
#   $db = tie %db, 'DB_File', $ARGV[0], O_RDONLY, 0666, $type;
# }

# die "Can't open: $!" unless $db;

$a = 'aaa';
$b = 'asdfasd';
for (1..10) {
  $status = $db->put($a++, $b++);
}

# undef $db; untie %db;

# $type = new DB_File::BTREEINFO;
# #$type = new DB_File::HASHINFO;
# #$type->{compare} = sub {$_[1] cmp $_[0]};
# $db = tie %db, 'DB_File', 'blah', O_RDWR|O_CREAT, 0666, $type;

# die "BLAH $!" unless $db;




#$key = $value = '';
# for ($status = $db->seq($key, $value, R_FIRST) ;
#      $status == 0 ;
#      $status = $db->seq($key, $value, R_NEXT) )
#   {
#     print "$key -> $value\n";
#     if ($key %10000 = 1) {#$key =~ /[bhi]$/) {


# #      print "  replace $key\n";
# #      $db->put("new.$key", "$value.new", R_CURSOR);
#       print "  nuke $key\n";
#       $status = $db->del($key);
#       print "  status $status\n";
#       push @new, $key, $value;
#     }
#   }

# while (($key, $value) = splice(@new, 0, 2)) {
#   print "  add in $key.new\n";
#   $status = $db->put("$key.new", "$value.new");
#   print "  status $status\n";
# }

# print "------------\n";

# start();
# while (defined($i = get())) {
#   print "got $i\n";
# }
# end();

# print "-------------
# start();
# while (defined($i = get())) {
#   print "got $i\n";
# }
# end();


$key = $value = '';
for ($status = $db->seq($key, $value, R_FIRST) ;
     $status == 0 ;
     $status = $db->seq($key, $value, R_NEXT) )
  {
    print "$key\n  $value\n";
  }




# sub start {
#   # Lock
# }

# sub get {
#   my($key, $value) = (0, 0);

#   if ($getting) {
#     $status = $db->seq($key, $value, R_NEXT);
#   }

#   else {
#     $status = $db->seq($key,$value, R_FIRST);
#     $getting = 1;
#   }
#   return undef unless $status == 0;
#   $key;
# }

# sub end {
#   $getting = 0;
#   # unlock 
# }

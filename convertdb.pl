# Find and convert all text databases to DB_File databases.  Note that this
# isn't really pretty; it assumes things about the way SimpleDB::DB does
# stuff without actually using the module.  It also guesses (using the
# filename) whether or not it needs to use a comparison function.  Any of
# this could break if the actual Majordomo source changes.

# As such, it should be used to upgrade once from pre-DB-supporting
# revisions and then put aside.  The decision about which database backend
# to use should be made only once at initial install time and should not be
# changed.

use File::Find;
use DB_File;
use strict;
print "$ARGV[0]\n";

find(\&wanted, $ARGV[0]);

sub addrcompare {
  reverse($_[0]) cmp reverse($_[1]);
}

sub wanted {
  my (%db, $db, $dbinfo, $gid, $key, $line, $mode, $name, $status, $type,
      $uid, $val);

  # Only want files starting with _ or X (for auxiliary lists) and ending
  # with .T
  return unless $_ =~ /^([X_])(.*)\.T$/;
  $type = "$1";
  $name = "$2";

  # Get permissions and ownership for the text file
  ($mode, $uid, $gid) = (stat("$type$name.T"))[2,4,5];

  print "Converting $File::Find::name ";

  # Use BTree and comparison function if the file is appropriately named
  if ($type eq 'X' || $name eq 'subscribers' || $name eq 'register') {
    $dbinfo = new DB_File::BTREEINFO;
    $dbinfo->{compare} = \&addrcompare;
    print "as a BTree.\n";
  }
  # Otherwise use a simple hash
  else {
    $dbinfo = new DB_File::HASHINFO;
    print "as a Hash.\n";
  }

  # Create the new database
  $db = tie %db, 'DB_File', "$type$name.D", O_RDWR|O_CREAT, 0666, $dbinfo;
  die "Can't open database: $!" unless $db;

  open TEXT, "<$type$name.T";

  # Do the copy
  while (defined($line = <TEXT>)) {
    chomp $line;
    ($key, $val) = split("\001", $line, 2);
    print ".";
    $status = $db->put($key, $val);
    warn "\nProblem! Status = $status" unless $status == 0;
  }
  print "\n";
  close TEXT;

  # Move the old database out of the way
  rename "$type$name.T", "$type$name.T.old";

  # Set the permissions and mode correctly on the new database
  chmod($mode,      "$type$name.D");
  chown($uid, $gid, "$type$name.D");

  undef $db; untie %db; undef $dbinfo;
}


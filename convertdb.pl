#!/usr/bin/perl -w

use File::Find;
use DB_File;
use strict;
use Getopt::Std;

my (%opts, @btrees, @hashes, $dir);
getopts('t', \%opts);

@btrees = qw(parser posts register subscribers);
@hashes = qw(aliases bounce dup_id dup_partial dup_sum latchkeys tokens);
$dir = $ARGV[0];

unless (defined $dir and length $dir) {
  &usage;
  exit;
}

die "$dir is not a directory." unless (-d $dir);

if ($opts{'t'}) {
  find(\&db_to_text, $dir);
}
else {
  find(\&text_to_db, $dir);
}

sub addrcompare {
  reverse($_[0]) cmp reverse($_[1]);
}

sub text_to_db {
  my (%db, $db, $dbinfo, $gid, $key, $line, $mode, $name, $status, $type,
      $uid, $val);

  # Only want files starting with _ or X (for auxiliary lists) and ending
  # with .T
  return unless $_ =~ /^([X_])(.*)\.T$/;
  $type = $1;
  $name = $2;

  # Get permissions and ownership for the text file
  ($mode, $uid, $gid) = (stat("$type$name.T"))[2,4,5];

  # Use BTree and comparison function if the file is appropriately named
  if ($type eq 'X' || grep { $_ eq $name } @btrees) {
    $dbinfo = new DB_File::BTREEINFO;
    $dbinfo->{compare} = \&addrcompare;
    print "Converting text->btree $File::Find::name \n";
  }
  # Otherwise use a simple hash
  elsif (grep { $_ eq $name } @hashes) {
    $dbinfo = new DB_File::HASHINFO;
    print "Converting text->hash $File::Find::name \n";
  }
  else {
    print "Skipping $File::Find::name \n";
    return;
  }

  # Create the new database
  rename "$type$name.D", "$type$name.D.old";
  $db = tie %db, 'DB_File', "$type$name.D", O_RDWR|O_CREAT, 0666, $dbinfo;
  die "Can't open database: $!" unless $db;

  open TEXT, "<$type$name.T";

  # Do the copy
  while (defined($line = <TEXT>)) {
    chomp $line;
    ($key, $val) = split("\001", $line, 2);
    $status = $db->put($key, $val);
    warn "\nProblem! Status = $status" unless $status == 0;
  }
  close TEXT;

  # Move the old database out of the way
  rename "$type$name.T", "$type$name.T.old";

  # Set the permissions and mode correctly on the new database
  chmod($mode,      "$type$name.D");
  chown($uid, $gid, "$type$name.D");

  undef $db; untie %db; undef $dbinfo;
}

sub db_to_text {
  my (%db, $db, $dbinfo, $gid, $key, $line, $mode, $name, $status, $type,
      $uid, $val);

  # Only want files starting with _ or X (for auxiliary lists) and ending
  # with .D
  return unless $_ =~ /^([X_])(.*)\.D$/;
  $type = $1;
  $name = $2;

  # Get permissions and ownership for the text file
  ($mode, $uid, $gid) = (stat("$type$name.D"))[2,4,5];

  # Use BTree and comparison function if the file is appropriately named
  if ($type eq 'X' || grep { $_ eq $name } @btrees) {
    $dbinfo = new DB_File::BTREEINFO;
    $dbinfo->{compare} = \&addrcompare;
    print "Converting btree->text $File::Find::name \n";
  }
  # Otherwise use a simple hash
  elsif (grep { $_ eq $name } @hashes) {
    $dbinfo = new DB_File::HASHINFO;
    print "Converting hash->text $File::Find::name \n";
  }
  else {
    print "Skipping $File::Find::name \n";
    return;
  }

  # Open the old database
  $db = tie %db, 'DB_File', "$type$name.D", O_RDONLY, 0666, $dbinfo;
  die "Can't open database: $!" unless $db;

  # Create the new database
  rename "$type$name.T", "$type$name.T.old";
  open TEXT, ">$type$name.T";

  # Do the copy
  while (($key, $val) = each %db)
        {
                print TEXT "$key\001$val\n" ;
        }

  close TEXT;

  # Move the old database out of the way
  rename "$type$name.D", "$type$name.D.old";

  # Set the permissions and mode correctly on the new database
  chmod($mode,      "$type$name.T");
  chown($uid, $gid, "$type$name.T");

  undef $db; untie %db; undef $dbinfo;
}

sub usage {
  print <<EOM;
Usage:
  convertdb.pl [-t] DIRECTORY

This script will change the format of Majordomo 2 databases.  The
directory given should be the top-level directory where your Majordomo 2
domains are installed.

If the "-t" switch is used, the databases will be converted from DB_File
format to Text format.  Otherwise, the databases will be converted from
Text format to DB_File format.

This script should be run as root or as the majordomo user.

EOM

}


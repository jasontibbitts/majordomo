#!/usr/bin/perl -w

use File::Find;
use DB_File;
use strict;
use Getopt::Std;

my ($cnts, $cntf, %opts, @btrees, @hashes, $dir, $doingwhat);

getopts('dtpc', \%opts);
$cnts = $cntf = 0; # skipped and processed file counter
$| = 1;

# this part is scary because it may be out of synch with Mj2 source code:
@btrees = qw(parser posts register subscribers);
@hashes = qw(aliases bounce dup_id dup_partial dup_sum latchkeys tokens);

$dir = $ARGV[0];
&usage("directory containing list data is required") unless (defined $dir and length $dir);
&usage("$dir is not a directory") unless (-d $dir);

# better stroking for 'just print what needs done' mode
$doingwhat = "Converting";
if ($opts{'p'}) {
  $doingwhat = "Would convert";
}

if ($opts{'c'}) {
  &usage("only one option switch is allowed") if($opts{'t'} || $opts{'d'});
  find(\&cleanup, $dir);
}
elsif ($opts{'t'}) {
  &usage("only one option switch is allowed") if($opts{'c'} || $opts{'d'});
  find(\&db_to_text, $dir);
}
elsif ($opts{'d'}) {
  &usage("only one option switch is allowed") if($opts{'t'} || $opts{'c'});
  find(\&text_to_db, $dir);
}
else {
  &usage("one option switch of -t|-d|-c is required");
}

print "Done: $cntf files were changed.\n";
print "ERROR: $cnts files were skipped.\n" if($cnts);
exit 0;

########################################################################
# end of main
########################################################################

sub addrcompare {
  reverse($_[0]) cmp reverse($_[1]);
}


sub cleanup {
  # Only want files starting with _ or X (for auxiliary lists) and ending
  # with .T.old or .D.old
  return unless $_ =~ /^[X_].*\.[DT]\.old$/;

  # ignore permissions and ownership for the file
  # ($mode, $uid, $gid) = (stat("$type$name.$ext"))[2,4,5];

  if ($opts{'p'}) {
    print "rm $File::Find::name\n";
  }
  else {
    print "unlink $File::Find::name\n";
    # NOTE: stroking and unlink args are different on purpose!
    unlink($_) or die("Cannot unlink $File::Find::name:  $!");
  }
  $cntf++;
} # end of cleanup 


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
    print "$doingwhat text->btree $File::Find::name \n";
    return if ($opts{'p'});
    $dbinfo = new DB_File::BTREEINFO;
    $dbinfo->{compare} = \&addrcompare;
  }
  # Otherwise use a simple hash
  elsif (grep { $_ eq $name } @hashes) {
    print "$doingwhat text->hash  $File::Find::name \n";
    return if ($opts{'p'});
    $dbinfo = new DB_File::HASHINFO;
  }
  else {
    print "Skipping $File::Find::name \n";
    $cnts++;
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
  $cntf++;
} # end of text_to_db 


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
    print "$doingwhat btree->text $File::Find::name \n";
    return if ($opts{'p'});
    $dbinfo = new DB_File::BTREEINFO;
    $dbinfo->{compare} = \&addrcompare;
  }
  # Otherwise use a simple hash
  elsif (grep { $_ eq $name } @hashes) {
    print "$doingwhat  hash->text $File::Find::name \n";
    return if ($opts{'p'});
    $dbinfo = new DB_File::HASHINFO;
  }
  else {
    print "Skipping $File::Find::name \n";
    $cnts++;
    return;
  }

  # Open the old database
  $db = tie %db, 'DB_File', "$type$name.D", O_RDONLY, 0666, $dbinfo;
  die "Can't open database: $!" unless $db;

  # Create the new database
  rename ("$type$name.T", "$type$name.T.old");
  open (TEXT, ">$type$name.T") or
    die ("Cannot open $type$name.T:  $!");

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
  $cntf++;
} # end of db_to_text 


sub usage {
  print <<EOM;

-----------------------------------------------------------------
convertdb.pl - $cntf files (ERROR: $_[0])
-----------------------------------------------------------------

Usage:
  convertdb.pl -t|-d|-c [-p] DIRECTORY
Called as:
  $0 @ARGV

If the "-p" switch is used, nothing will happen but a list of files
that WOULD BE converted or deleted (without -p) will be printed.
Exactly one of the switches -t, -d, or -c is required.

This script will change the format of Majordomo 2 databases. It only
operates on files starting with "X" or "_" and ending with ".T", ".D",
".T.old", or ".D.old". The directory given should be the top-level
directory where your Majordomo 2 domains are installed (e.g. the dir
that contains ALIASES, LIB, QUEUE, SITE, and virtual domain dirs).

If the "-t" switch is used, the databases will be converted from
DB_File format to Text format.  With the "-d" switch the databases
will be converted from Text format to DB_File format.

If the "-c" switch is used, no conversion will happen but all the old
files left over from either type of conversion will be cleaned up. In
other words, "-c" will delete all [X_]*.[TD].old files in the tree.
If both "-c" and "-p" switches are specified, a list of "rm" commands
will be printed but no action will be taken.

Text files have filename.T extensions, DB_File files have filename.D
extensions. Regardless of which direction you are going (T->D or D->T)
the input files will be renamed with ".old" extensions appended onto
the original file name. Pre-existing files with the same name as an
output file will also be renamed with ".old" extensions. No warnings
are issued about existing files.

This script should be run as root or as the majordomo user.

Back up the target DIRECTORY first or risk total annihilation.

EOM
exit 1;
}

# end of file convertdb.pl

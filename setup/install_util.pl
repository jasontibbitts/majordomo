# This file contains routines used by the postinstall script to do basic
# file copying and ownership manipulation.

# the whatnext variable is used in chownmod, 
#  and needs to persist across calls.
use vars (qw($quiet $whatnext));
$whatnext = "ask";

# Copies or links a file from one directory to another, preserving
# ownership and permissions.
use File::Copy "cp";
sub copy_file {
  my $script = shift;
  my $source = shift;
  my $dest   = shift;
  my $link   = shift;

  if ($link) {
    link "$source/$script", "$dest/$script" ||
      die "Can't make link in $dest, $!.";
  }
  else {
    cp("$source/$script", "$dest/$script") ||
      die "Can't copy $source/$script to $dest/$script, $!.";
    # Set the owner and mode on the copied file
    chownmod((stat("$source/$script"))[4,5], (stat(_))[2], "$dest/$script");
  }
}

sub dot () {
  print "." unless $quiet;
}

# chown and chmod a directory or a file, complete with stroking and error handling
# NOTE: this is the ONLY call to chown or chmod which should be used for Mj2 installing
#       so failed commands can be transcripted and handled later by the installer
# (older implementations didn't check chmod status, always died on first failure, etc)
sub chownmod {
  my $uid = shift; # if missing, or non-numeric, don't call chown
  my $gid = shift; # if missing, or non-numeric, don't call chown
  my $mod = shift; # if missing, or non-numeric, don't call chmod
  my @fil = @_;

  my ($cntmod, $cntown);
  $cntown = $cntmod = 1;
  $cntown = chown($uid, $gid, @fil) if(defined($uid) && defined($gid) && ($uid =~ /[0-9]/) && ($uid !~ /[^0-9]/) && ($gid =~ /[0-9]/) && ($gid !~ /[^0-9]/));
  $cntmod = chmod($mod, @fil)       if(defined($mod) && ($mod =~ /[0-9]/) && ($mod !~ /[^0-9]/));
  if(!$cntown || !$cntmod) {
    if($whatnext eq "ask") {
      print "\nERROR! Trying to change owner to user $uid, group $gid, permission $mod\n";
      print "       chown=$cntown, chmod=$cntmod, file(s)=@fil\n";
      print "You can abort the install, ignore all such failures, or list failures and continue.\n";
      print "What would you like to do next ? [abort/ignore/list] ";
      $whatnext = <STDIN>;
      if   ($whatnext =~ /^i/i) { $whatnext = "ignore"; }
      elsif($whatnext =~ /^l/i) { $whatnext = "list"; }
      else                      { die("Failed to chown or chmod @fil"); }
    }
    if($whatnext eq "list") {
      print "\n# FAILED COMMAND: please issue these commands from an authorized account:\n";
      my $tmpfil;
      foreach $tmpfil ( @fil ) {
        print "  chown $uid $tmpfil\n" if(defined($uid) && defined($gid));
        print "  chgrp $gid $tmpfil\n" if(defined($uid) && defined($gid));
        print "  chmod $mod $tmpfil\n" if(defined($mod) && ($mod =~ /[0-9]/) && ($mod !~ /[^0-9]/));
      }
    }
  } # if there was a problem
}

# Recursively chown and chmod a directory, calling chownmod to do the work
sub rchown {
  my $uid = shift;
  my $gid = shift;
  my $mod = shift;
  my $dmod = shift;
  my ($dh, $dir);

  for $dir (@_) {
    dot;
    $dir =~ s!/$!!;
    
    $dh = DirHandle->new($dir);
    chownmod($uid, $gid, $dmod, $dir);
    for my $i ($dh->read) {
      next if $i eq '.' || $i eq '..';
      chownmod($uid, $gid, $mod, "$dir/$i");
      if (-d "$dir/$i") {
	rchown($uid, $gid, $mod, $dmod, "$dir/$i");
      }
    }
  }
}

# Recursively copy one directory to another, not paying attention to
# ownership or permisions.
sub rcopy {
  my $src = shift;
  my $dst = shift;
  my $dot = shift;
  my ($dh, $i);

  $src =~ s!/$!!; # Strip trailing slash
  $dst =~ s!/$!!; # Strip trailing slash

  $dh = DirHandle->new($src);
  for $i ($dh->read) {
    next if $i eq '.' || $i eq '..' || $i eq 'CVS';
    if (-d "$src/$i") {
      unless (-d "$dst/$i") {
	mkdir("$dst/$i", 0700)
	  or die "Can't make directory $dst/$i: $!";
	dot if $dot;
      }
      rcopy("$src/$i", "$dst/$i", $dot);
    }
    else {
      cp("$src/$i", "$dst/$i")
	or die "Can't copy to $dst/$i: $!";
      dot if $dot;
    }
  }
}

# Make a directory and immediately change its owner and mode.  Note that
# the owner and mode are changed even if the directory already exists.
# Don't call this for directories that aren't intended to be owned solely
# by Majordomo.  (Which would be foolish anyway, because we wouldn't be
# able to make any reasonable guess at what the permissions should be.)

# Make sure all of the created directory's parents exist as well. -DS

use File::Basename ();

sub safe_mkdir {
  my $dir  = shift;
  my $mode = shift;
  my $uid  = shift;
  my $gid  = shift;

  # dirname will not return the last element of a directory tree even if
  # it ends in a "/".  Use this to create all the parents.
  my $parent = File::Basename::dirname($dir);
  safe_mkdir($parent, $mode, $uid, $gid) unless (-d $parent);

  unless (-d $dir) {
    mkdir $dir, $mode or die "Can't make $dir, $!";
  }
  chownmod($uid, $gid, $mode, $dir);
}

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

# This file contains routines used by the postinstall script to do basic
# file copying and ownership manipulation.

use vars (qw($erroraction $quiet));
$erroraction = 'abort';

# Copies or links a file from one directory to another, preserving
# ownership and permissions.
use File::Copy "cp";
sub copy_file {
  my $script = shift;
  my $source = shift;
  my $dest   = shift;
  my $link   = shift;
  my ($ddev, $sdev);

  if ($link) {
    ($ddev) = stat $dest;
    ($sdev) = stat $source;
    unless (defined $ddev) {
      die "Unable to access $dest:  $!";
    }
    unless (defined $sdev) {
      die "Unable to access $source:  $!";
    }

    unlink "$dest/$script" if -e "$dest/$script";

    if ($sdev == $ddev) {
      link("$source/$script", "$dest/$script") ||
        die "Can't make link in $dest, $!.";
    }
    else {
      symlink("$source/$script", "$dest/$script") ||
        die "Can't make symlink in $dest, $!.";
    }
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

# Change the owner, group, and permissions of a group of files or
# directories.
sub chownmod {
  my $uid = shift; # if missing, or non-numeric, don't call chown
  my $gid = shift; # if missing, or non-numeric, don't call chown
  my $mod = shift; # if missing, or non-numeric, don't call chmod
  my @fil = @_;

  my ($cntmod, $cntown, $tmpfil, $whatnext);
  $cntown = $cntmod = 1;

  $cntown = chown($uid, $gid, @fil) 
    if (defined ($uid) && ($uid =~ /^[0-9]+$/) && 
        defined ($gid) && ($gid =~ /^[0-9]+$/));

  if (!$cntown) {
    $whatnext = 
      get_enum(retr_msg('no_chown', $lang, 'UID' => $uid, 'GID' => $gid,
                        'FILE' => $fil[0], 'ERROR' => $!), 
               $erroraction, [qw(abort ignore list)]);

    if ($whatnext eq 'abort') {
      exit 1;
    }
    elsif ($whatnext eq 'list') {
      print "\n";
      for $file (@fil) {
        print  "  chown $uid $file\n" 
          if (defined ($uid) && ($uid =~ /^[0-9]+$/));

        print  "  chgrp $gid $file\n" 
          if (defined ($gid) && ($gid =~ /^[0-9]+$/));
      }
      print "\n";
      $erroraction = 'list';
      ask_continue();
    }
    else {
      $erroraction = 'ignore';
    }
  }
   
  $cntmod = chmod($mod, @fil)       
    if (defined ($mod) && ($mod =~ /^[0-9]+$/));

  if (!$cntmod) {
    $whatnext = 
      get_enum(retr_msg('no_chmod', $lang, 'MODE' => sprintf("%lo", $mod),
                        'FILE' => $fil[0], 'ERROR' => $!), 
               $erroraction, [qw(abort ignore list)]);

    if ($whatnext eq 'abort') {
      exit 1;
    }
    elsif ($whatnext eq 'list') {
      print "\n";
      for $file (@fil) {
        printf ("  chmod %lo $file\n", $mod);
      }
      print "\n";
      $erroraction = 'list';
      ask_continue();
    }
    else {
      $erroraction = 'ignore';
    }
  }
}

# Recursively chown and chmod a directory, calling chownmod to do the work
sub rchown {
  my $uid = shift;
  my $gid = shift;
  my $mod = shift;
  my $dmod = shift;
  my ($dh, $dir, $i);

  for $dir (@_) {
    dot;
    $dir =~ s!/$!!;
    
    $dh = DirHandle->new($dir);
    die qq(Cannot open directory "$dir": $!) unless $dh;
    chownmod($uid, $gid, $dmod, $dir);
    for $i ($dh->read) {
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
    mkdir ($dir, $mode) or die qq(Cannot create directory "$dir": $!);
  }
  chownmod($uid, $gid, $mode, $dir);
}

=head1 COPYRIGHT

Copyright (c) 1999, 2002 Jason Tibbitts for The Majordomo Development
Group.  All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the license detailed in the LICENSE file of the
Majordomo2 distribution.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the Majordomo2
LICENSE file for more detailed information.

=cut

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

# This file contains routines used by the postinstall script to do basic
# setup and domain creation functions.
# Copies or links a file from one directory to another, preserving
# ownership and permissions.
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
    chown((stat("$source/$script"))[4,5], "$dest/$script");
    chmod((stat(_))[2], "$dest/$script");
  }
}

sub dot () {
  print "." unless $quiet;
}

# Recursively chown a directory
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
    chown($uid, $gid, $dir) || die("Couldn't chown $dir, $!");
    chmod($dmod, $dir);
    for my $i ($dh->read) {
      next if $i eq '.' || $i eq '..';
      chown($uid, $gid, "$dir/$i") || die("Couldn't chown $dir/$i, $!");
      chmod($mod, "$dir/$i") || die("Couldn't chmod $dir/$i, $!");
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
  my ($i);

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

# Make a directory and immediately change its owner and mode
sub safe_mkdir {
  my $dir  = shift;
  my $mode = shift;
  my $uid  = shift;
  my $gid  = shift;
  unless (-d $dir) {
    mkdir $dir, $mode or die "Can't make $dir, $!";
    chown ($uid, $gid, $dir) or die "Can't chown $dir, $!";
    chmod ($mode, $dir) or die "Can't chmod $dir, $!";
  }
}

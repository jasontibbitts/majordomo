# This file contains routines used by the postinstall script to do initial
# site and domain setup.

$msg0 = <<EOM;

What is the default global password for domain \$DOM?
EOM

$msg4 = <<EOM;

Your master site password must be known for some of the installation
 process, but it is insecure to store it anywhere outside of Majordomo.
 Thus you must enter it now.  If you have not yet set a password, choose
 one and enter it below.

What is the site password?
EOM

# Create the necessary directories for an entire installation.
sub create_dirs {
  my $l    = shift;
  my $uid  = shift;
  my $gid  = shift;
  my $um   = shift;
  my $doms = shift;
  my $tmp  = shift;
  my($i);

  print "Making directories:" unless $quiet;
  print "$l, $tmp, $uid, $gid\n" if $verb;

  safe_mkdir($l,           0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir($tmp,         0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$tmp/locks", 0777 & ~oct($um), $uid, $gid);dot;

  safe_mkdir("$l/LIB",        0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/SITE",       0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/SITE/files", 0777 & ~oct($um), $uid, $gid);dot;

  if ($config->{maintain_mtaconfig}) {
    safe_mkdir("$l/ALIASES", 0755 & ~oct($um), $uid, $gid);dot;
  }

  for $i (@$doms) {
    create_dirs_dom($l, $i, $uid, $gid, $um);
  }
  print "ok.\n" unless $quiet;
}

# Make the directories required for a specific domain.
sub create_dirs_dom {
  my $l   = shift;
  my $d   = shift;
  my $uid = shift;
  my $gid = shift;
  my $um  = shift;

  printf "ok.\nMaking directories for %s, mode %lo.\n", $d, (0777 & ~oct($um))
    if $verb;
  safe_mkdir("$l/$d",                    0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/$d/GLOBAL",             0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/$d/GLOBAL/sessions",    0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/$d/GLOBAL/files",       0777 & ~oct($um), $uid, $gid);dot;
}

# Do basic configuration for a domain
sub do_config {
  my $dom = shift;
  my(@args, $arg, $errcount, $i, $ignore, $msg, $pw);

  # Prompt for the site password if necessary
  $pw = $config->{'site_password'};
  unless ($pw) {
    $pw = get_str($msg4);
    $config->{'site_password'} = $pw;
  }

  print "Configuring $dom:" unless $quiet;

  # Build the command line
  @args = ("$config->{'install_dir'}/bin/mj_shell", "-d", "$dom", "-F",
	   "$config->{wtmpdir}/inst.$$");

  # Build the command file
  open FILE, ">$config->{wtmpdir}/inst.$$";
#  print FILE "approve $config->{site_password} configset GLOBAL master_password = $pw\n";
  print FILE "default password $pw\n";

  # Make the necessary directories in the GLOBAL filespace
  print FILE "put-dir GLOBAL /spool Spooled Files\n";
  print FILE "put-dir GLOBAL /public Public Files\n";
  close FILE;
  # Make sure the file can be read by the Majordomo user.  XXX This is a
  # slight security hole.  We're root, so we should play with chowning the
  # file.
  chmod(0644, "$config->{wtmpdir}/inst.$$");dot;

  $cmdline = join(' ', @args);
  open SHELL, "$cmdline|" or die "Error executing $args[0], $?";
  while (<SHELL>) {
    print if $verb;
    dot if /^>>>> / && !$verb;
    if (/^\*\*\*\* /) {
      print unless $verb;
      $errcount++;
    }
  }
  close SHELL;
  unlink "$config->{wtmpdir}/inst.$$";

  if ($errcount) {
    print "\nWarning: there were unexpected errors!\nInstallation may be incorrect!\n";
  }
  else {
    print "ok.\n" unless $quiet;
  }
}

 
# Write out a file containing defaults for all of the various config
# variables; some of these defaults are chosen from the installer's
# responses to the configurator.
sub do_default_config {
  my $dom = shift;
  my(@args, $arg, $errcount, $i, $ignore, $msg, $owner, $pw);

  # Prompt for the password if necessary
  $pw = $config->{'domain'}{$dom}{'master_password'};
  unless ($pw) {
    ($msg = $msg0) =~ s/\$DOM/$dom/;
    $pw = get_str($msg);
    $config->{'domain'}{$dom}{'master_password'} = $pw;
  }
  print "Setting configuration defaults for $dom:" unless $quiet;

  # Figure out what the owner address should be
  if ($config->{'domain'}{$dom}{whoami} =~ /(.*)\@(.*)/) {
    $owner = "$1-owner\@$2";
  }
  else {
    $owner = "$config->{'domain'}{$dom}{whoami}-owner";
  }

  # Open the master defaults file, in lib/mj_cf_defs.pl
  open MASTER, 'lib/mj_cf_defs.pl';

  # Open the file in $listsdir/LIB/cf_defs_$dom.pl
  open DEFS, ">$config->{lists_dir}/LIB/cf_defs_$dom.pl";

  while (defined($_ = <MASTER>)) {
    # Do substitutions
    s!(^ \'whereami\'.*)DEFAULT(.*)!$1$dom$2!;
    s!(^ \'master_password\'.*)DEFAULT(.*)!$1$config->{'domain'}{$dom}{master_password}$2!;
    s!(^ \'whoami\'.*)DEFAULT(.*)!$1$config->{'domain'}{$dom}{whoami}$2!;
    s!(^ \'whoami_owner\'.*)DEFAULT(.*)!$1$owner$2!;
    s!(^ \'owners\'.*)DEFAULT(.*)!$1$config->{'domain'}{$dom}{owner}$2!;
    
    for $i (qw(tmpdir site_name)) {
      $arg = $config->{'domain'}{$dom}{$i} || $config->{$i};
      s!(^ \'$i\'.*)DEFAULT(.*)!$1$arg$2!;
    }
    print DEFS $_;
  }
  close MASTER;
  close DEFS;

  # Change ownership and permissions
  chown (scalar getpwnam($config->{'uid'}),
	 scalar getgrnam($config->{'gid'}),
	 "$config->{'lists_dir'}/LIB/cf_defs_$dom.pl")
    or die "Can't chown $config->{'lists_dir'}/LIB/cf_defs_$dom.pl: $!";
  dot;

  chmod ((0777 & ~oct($config->{'umask'}), "$config->{'lists_dir'}/LIB/cf_defs_$dom.pl"))
    or die "Can't chmod $config->{'lists_dir'}/LIB/cf_defs_$dom.pl: $!";
  print "ok.\n" unless $quiet;
}

# Dump out the initial site config
sub do_site_config {
  my($data, $mtaopts);

  # Prompt for the site password if necessary
  $pw = $config->{'site_password'};
  unless ($pw) {
    $pw = get_str($msg4);
    $config->{'site_password'} = $pw;
  }

  print "Configuring site-wide parameters:";

  # Figure out what to stash in the MTA options
  $mtaopts = {};
  if ($config->{'mta'} eq 'sendmail') {
    $mtaopts->{'maintain_config'} = 1
      if $config->{'maintain_mtaconfig'};
    $mtaopts->{'maintain_vut'} = 1
      if $config->{'sendmail_maintain_vut'};
  }

  # Build up the Data hash.
  $data = {
	   'site_password'      => $pw,
	   'install_dir'        => $config->{'install_dir'},
	   'mta'                => $config->{'mta'},
	   'mta_options'        => $mtaopts,
	   'cgi_bin'            => $config->{'cgi_bin'},
	  };

  # Open the site config file
  open SITE, ">$config->{'lists_dir'}/SITE/config.pl"
    or die "Couldn't open site config file $config->{'lists_dir'}/SITE/config.pl: $!";
  dot;

  # Print out the data hash
  print SITE Dumper($data)
    or die "Couldn't populate site config file $config->{'lists_dir'}/SITE/config.pl: $!";
  dot;

  # Close the file
  close SITE;
  dot;

  # Change ownership and permissions
  chown (scalar getpwnam($config->{'uid'}),
	 scalar getgrnam($config->{'gid'}),
	 "$config->{'lists_dir'}/SITE/config.pl")
    or die "Can't chown $config->{'lists_dir'}/SITE/config.pl: $!";
  dot;

  chmod ((0777 & ~oct($config->{'umask'}), "$config->{'lists_dir'}/SITE/config.pl"))
    or die "Can't chmod $config->{install_dir}/majordomo.crontab, $!";

  print ".ok.\n" unless $quiet;
}

# Copy all of the stock response files into their site-wide directory
sub install_response_files {
  my ($gid, $uid);

  print "Installing stock response files:" unless $quiet;

  rcopy("files", "$config->{'lists_dir'}/SITE/files", 1);
  
  $uid = getpwnam($config->{'uid'});
  $gid = getgrnam($config->{'gid'});
  $um  = oct($config->{'umask'});
  rchown($uid, $gid, 0666 & ~$um, 0777 & ~$um,
	 "$config->{'lists_dir'}/SITE/files");
  print "ok.\n" unless $quiet;
}

# Make symlinks from a protected directory to our alias files
sub make_alias_symlinks {
  my $dom = shift;
  my $dir = shift;

  symlink("$config->{lists_dir}/ALIASES/mj-alias-$dom", "$dir/mj-alias-$dom");

  if ($config->{sendmail_maintain_vut}) {
    symlink("$config->{lists_dir}/ALIASES/mj-vut-$dom", "$dir/mj-vut-$dom");
  }
}

# Set the appropriate permissions on all of the scripts.
sub set_script_perms {
  my $sidscripts = shift;
  my $scripts    = shift;
  print "Setting permissions:" unless $quiet;
  $id = $config->{'install_dir'};
  if ($config->{wrappers}) {
    for my $i (@$sidscripts) {
      push @$scripts, ".$i";
    }
  }
  map {$_ = "$id/bin/$_" unless /\//} @$sidscripts, @$scripts;

  $uid = getpwnam($config->{'uid'});
  $gid = getgrnam($config->{'gid'});

  # Properly set ownerships on everything.
  chown($uid, $gid, @$sidscripts, @$scripts) || die "Couldn't change ownership: $!";
  dot;
  chown($uid, $gid, $id);dot;

  # Change permissions on the top-level installation directory, but make
  # sure that anyone can look in it to run programs.
  chmod((0777 & ~oct($config->{'umask'})) | 0555, $id);dot;
  rchown($uid, $gid, 0644, 0755, "$id/bin", "$id/man", "$id/lib");dot;

  # Make executables setuid; the scripts must be readable while the the
  # wrappers need only be executable.
  if ($config->{'wrappers'}) {
    chmod(06511, @$sidscripts) || die "Couldn't change mode: $!";
  }
  else {
    chmod(06555, @$sidscripts) || die "Couldn't change mode: $!";
  }
  dot;
  chmod(0555, @$scripts);dot;
  print "ok\n" unless $quiet;
}

# Give a suggested crontab
sub suggest_crontab {
  my $dom = shift;
  return <<"EOM";

# Daily and hourly triggers for $dom
0 0 * * * $config->{'install_dir'}/bin/mj_trigger -d $dom -t daily
0 * * * * $config->{'install_dir'}/bin/mj_trigger -d $dom -t hourly
EOM
}


# Suggest MTA configuration by passing create-list-regen to the shell
# interface.  This may actually do MTA setup or it may make suggestions.
sub suggest_mta {
  my $dom   = shift;
  my $nhead = shift;
  my $pw;

  # Prompt for the site password if necessary
  $pw = $config->{'site_password'};
  unless ($pw) {
    $pw = get_str($msg4);
    $config->{'site_password'} = $pw;
  }

  my @args = ("$config->{'install_dir'}/bin/mj_shell", "-d", "$dom", "-p",
	      "$pw", "createlist-regen" . ($nhead ? "-noheader" : ''));

#  print "(@args)\n";
  system(@args) == 0 or die "Error executing $args[0], $?";
}

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***


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

  # We need to make sure the top level lists directory and the ALIASES
  # directory have permissions open enough to allow the MTA to read them.
  if ($config->{maintain_mtaconfig}) {
    if ($config->{mta_umask}) {
      safe_mkdir($l,           0777 & ~(oct($um) & oct($config->{mta_umask})),
		 $uid, $gid); dot;
      safe_mkdir("$l/ALIASES", 0755 & ~(oct($um) & oct($config->{mta_umask})),
		 $uid, $gid); dot;
    }
    else {
      safe_mkdir($l,           0777 & ~oct($um), $uid, $gid);dot;
      safe_mkdir("$l/ALIASES", 0755 & ~oct($um), $uid, $gid);dot;
    }
  }
  else {
    safe_mkdir($l,           0777 & ~oct($um), $uid, $gid);dot;
    safe_mkdir("$l/ALIASES", 0755 & ~oct($um), $uid, $gid);dot;
  }

  safe_mkdir($tmp,         0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$tmp/locks", 0777 & ~oct($um), $uid, $gid);dot;

  safe_mkdir("$l/LIB",        0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/SITE",       0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/SITE/files", 0777 & ~oct($um), $uid, $gid);dot;


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

  printf "ok.\nMaking directories for %s, mode %lo.", $d, (0777 & ~oct($um));
  safe_mkdir("$l/$d",                    0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/$d/GLOBAL",             0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/$d/GLOBAL/sessions",    0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/$d/GLOBAL/spool",       0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/$d/GLOBAL/files",       0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/$d/GLOBAL/files/public",0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/$d/DEFAULT",             0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/$d/DEFAULT/files",       0777 & ~oct($um), $uid, $gid);dot;
  safe_mkdir("$l/$d/DEFAULT/files/public",0777 & ~oct($um), $uid, $gid);dot;

  # Make the dotfiles so they show up properly in an index
  open DF, ">$l/$d/GLOBAL/files/.spool"
    or die "Can't open $l/$d/GLOBAL/files/.spool: $!";
  print DF "Spooled Files\nd\n\n\n\n\n";
  close DF;
  dot;
  chownmod(scalar getpwnam($config->{'uid'}), scalar getgrnam($config->{'gid'}),
           (0777 & ~oct($config->{'umask'})), "$l/$d/GLOBAL/files/.spool");
  dot;
  
  open DF, ">$l/$d/GLOBAL/files/.public"
    or die "Can't open $l/$d/GLOBAL/files/.public: $!";
  print DF "Public Files\nd\n\n\n\n\n";
  close DF;
  dot;
  chownmod(scalar getpwnam($config->{'uid'}), scalar getgrnam($config->{'gid'}),
           (0777 & ~oct($config->{'umask'})), "$l/$d/GLOBAL/files/.public");
  dot;
}

# Write out a file containing defaults for all of the various config
# variables; some of these defaults are chosen from the installer's
# responses to the configurator.
sub do_default_config {
  my $dom = shift;
  my(@args, $arg, $dset, $gset, $i, $list, $msg, $owner, $pw, 
     $subs, $tag, $tmp, $var);

  # Prompt for the password if necessary
  $pw = $config->{'domain'}{$dom}{'master_password'};
  unless ($pw) {
    ($msg = $msg0) =~ s/\$DOM/$dom/;
    $pw = get_str($msg);
    $config->{'domain'}{$dom}{'master_password'} = $pw;
  }
  print "Setting configuration defaults for $dom..." unless $quiet;

  # Figure out what the owner address should be
  if ($config->{'domain'}{$dom}{whoami} =~ /(.*)\@(.*)/) {
    $owner = "$1-owner\@$2";
  }
  else {
    $owner = "$config->{'domain'}{$dom}{whoami}-owner";
  }

  # Open the master defaults file, in lib/mj_cf_defs.pl
  # open MASTER, 'lib/mj_cf_defs.pl';
  require 'lib/mj_cf_defs.pl';
  require 'lib/mj_cf_data.pl';

  $subs = {
           'addr_xforms'     => $config->{ignore_case} ? "ignore case" : '',
           'master_password' => $config->{'domain'}{$dom}{master_password},
           'owners'          => $config->{'domain'}{$dom}{owner},
           'resend_host'     => $config->{'domain'}{$dom}{whereami},
           'sender'          => $owner,
           'site_name'       => $config->{'domain'}{$dom}{site_name} 
                                 || $config->{site_name},
           'tmpdir'          => $config->{'domain'}{$dom}{tmpdir} 
                                 || $config->{tmpdir},
           'whereami'        => $config->{'domain'}{$dom}{whereami},
           'whoami'          => $config->{'domain'}{$dom}{whoami},
           'whoami_owner'    => $owner,
  };

  if ($config->{cgi_bin}) {
    $subs->{'confirm_url'} = "$config->{'cgi_url'}mj_confirm?d=$dom&t=\$TOKEN";
    $subs->{'wwwadm_url'} = "$config->{'cgi_url'}mj_wwwadm/domain=$dom";
    $subs->{'wwwusr_url'} = "$config->{cgi_url}mj_wwwusr/domain=$dom";
  }
  else {
    $subs->{'confirm_url'} = "no server configured";
    $subs->{'wwwadm_url'} = "no server configured";
    $subs->{'wwwusr_url'} = "no server configured";
  }

  # The system defaults configuration files
  # must be available for use before they can be parsed.
  # Use Data::Dumper to save the raw data to a configuration
  # file.   The data will be parsed by createlist-regen,
  # which will be run (in most cases) when the aliases are
  # updated.
  use Data::Dumper;
  $list = "GLOBAL";
  $gset->{'raw'} = eval $Mj::Config::default_string;
  open GCF, ">$config->{'lists_dir'}/$dom/GLOBAL/C_install";
  print GCF Dumper $gset;
  close GCF;
  &chownmod(scalar getpwnam($config->{'uid'}),	
            scalar getgrnam($config->{'gid'}),
            (0777 & ~oct($config->{'umask'})), 
            "$config->{'lists_dir'}/$dom/GLOBAL/C_install");
  
  $list = "DEFAULT";
  $dset->{'raw'} = eval $Mj::Config::default_string;
  open GCF, ">$config->{'lists_dir'}/$dom/DEFAULT/C_install";
  print GCF Dumper $dset;
  close GCF;
  &chownmod(scalar getpwnam($config->{'uid'}),	
            scalar getgrnam($config->{'gid'}),
            (0777 & ~oct($config->{'umask'})), 
            "$config->{'lists_dir'}/$dom/DEFAULT/C_install");
  
  print "ok.\n" unless $quiet;
}

sub gen_tag {
  my $chr = 'ABCDEFGHIJKLMNPQRSTUVWXYZ';
  my $pw;

  for my $i (1..6) {
    $pw .= substr($chr, rand(length($chr)), 1);
  }
  $pw;
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
  $mtaopts->{'maintain_config'} = 1
    if $config->{'maintain_mtaconfig'};
  $mtaopts->{'maintain_vut'} = 1
    if $config->{'sendmail_maintain_vut'};
  $mtaopts->{'qmail_path'} = $config->{'qmail_path'}
    if $config->{'qmail_path'};

  # Build up the Data hash.
  $data = {
	   'site_password'      => $pw,
	   'install_dir'        => $config->{'install_dir'},
	   'database_backend'   => $config->{'database_backend'},
	   'mta'                => $config->{'mta'},
	   'mta_options'        => $mtaopts,
	   'mta_separator'      => $config->{'mta_separator'},
	   'cgi_bin'            => $config->{'cgi_bin'},
	   'cgi_url'            => $config->{'cgi_url'},
	   'queue_mode'         => $config->{'queue_mode'},
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
  chownmod(scalar getpwnam($config->{'uid'}),	scalar getgrnam($config->{'gid'}),
           (0777 & ~oct($config->{'umask'})), "$config->{'lists_dir'}/SITE/config.pl");
  print ".ok.\n" unless $quiet;
}

# Run commands to create configuration templates.
sub install_config_templates {
  my ($config, $domain) = @_;
  my (@args, $pw, $tmp);

  $pw = $config->{'site_password'};
  unless ($pw) {
    $pw = get_str($msg4);
    $config->{'site_password'} = $pw;
  }

  while (1) {
    $tmp = "tmp.$$." . &gen_tag;
    last unless (-f $tmp);
  }

  open CONFIG, "< setup/config_commands" || return;
  open PW, ">$tmp" || return;
  print PW "default password $pw\n\n";
  while (<CONFIG>) {
    print PW $_;
  }
  close CONFIG;
  close PW;

  print "Installing configuration templates for $domain..." unless $quiet;

  open(TMP, ">&STDOUT");
  open(STDOUT, ">/dev/null");
  @args = ("$config->{'install_dir'}/bin/mj_shell", '-u', 
           'mj2_install@example.com', '-d', $domain, '-F', $tmp);

  if (system(@args)) {
    die "Error executing $args[0], $?";
  }

  close STDOUT;
  open(STDOUT, ">&TMP");
  unlink $tmp;

  print "ok.\n" unless $quiet;
}


# Copy all of the stock response files into their site-wide directory
sub install_response_files {
  my ($gid, $uid);

  print "Installing stock response files:" unless $quiet;

  rcopy("files", "$config->{'lists_dir'}/SITE/files", 1);
  
  $uid = getpwnam($config->{'uid'});
  $gid = getgrnam($config->{'gid'});
  $um  = oct($config->{'umask'});
  rchown($uid, $gid, 0666 & ~$um, 0777 & ~$um, "$config->{'lists_dir'}/SITE/files");
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
  chownmod($uid, $gid, "", @$sidscripts, @$scripts);
  dot;
  chownmod($uid, $gid, "", $id);
  dot;

  # Change permissions on the top-level installation directory, but make
  # sure that anyone can look in it to run programs.
  die "Can't change permission, directory does not exist!\n  $id\n  $id/bin\n  $id/man\n  $id/lib"
    if(!(-d "$id") || !(-d "$id/bin") || !(-d "$id/man") || !(-d "$id/lib"));
  chownmod("", "", (0777 & ~oct($config->{'umask'})) | 0555, $id);
  dot;
  rchown($uid, $gid, 0644, 0755, "$id/bin", "$id/man", "$id/lib");
  dot;

  # Make executables setuid; the scripts must be readable while the the
  # wrappers need only be executable.
  if ($config->{'wrappers'}) {
    chownmod("", "", 06511, @$sidscripts);
  }
  else {
    chownmod("", "", 06555, @$sidscripts);
  }
  dot;
  chownmod("", "", 0555, @$scripts);
  dot;
  print "ok\n" unless $quiet;
}

# Give a suggested crontab
sub suggest_crontab {
  return <<"EOM";

# Remove old lock files
30 0 * * * $config->{'install_dir'}/bin/mj_trigger -t lock
# Hourly trigger
20 * * * * $config->{'install_dir'}/bin/mj_trigger -t hourly
EOM
}

sub mta_setup {
  no strict 'refs';
  my $nhead = 0;
  require "setup/mta_$config->{mta}.pl";

  # First do the generalized setup
  &{"setup_$config->{mta}"}($config);

  # Then do the per-domain setup and build the mj-domains file.
  # 3/21/2000 - SRE - added "or die" to trap missing ALIASES directory (print to closed filehandle)
  open DOMAINS, ">$config->{lists_dir}/ALIASES/mj-domains" or die "ERROR! Can't open ".$config->{lists_dir}."/ALIASES/mj-domains";
  for my $i (@_) {
    print DOMAINS "$i\n";
    &{"setup_$config->{mta}_domain"}($config, $i, $nhead);
    $nhead = 1;
  }
  close DOMAINS;
}

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***


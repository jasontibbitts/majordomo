# This file contains routines used by the postinstall script to do initial
# site and domain setup.

use vars(qw($config $lang $quiet $verb));

# Create the necessary directories for an entire installation.
use File::Basename;
use File::Copy qw(mv);
sub create_dirs {
  my $l    = shift;
  my $uid  = shift;
  my $gid  = shift;
  my $um   = shift;
  my $doms = shift;
  my $tmp  = shift;
  my($i);

  print retr_msg('making_dirs', $lang) unless $quiet;
  print "$l, $tmp, $uid, $gid\n" if $verb;

  # We need to make sure the top level lists directory and the ALIASES
  # directory have permissions open enough to allow the MTA to read them.
  if ($config->{maintain_mtaconfig}) {
    if ($config->{mta_umask}) {
      safe_mkdir($l,           0777 & ~(oct($um) & oct($config->{mta_umask})),
		 $uid, $gid); dot();
      safe_mkdir("$l/ALIASES", 0755 & ~(oct($um) & oct($config->{mta_umask})),
		 $uid, $gid); dot();
    }
    else {
      safe_mkdir($l,           0777 & ~oct($um), $uid, $gid);dot();
      safe_mkdir("$l/ALIASES", 0755 & ~oct($um), $uid, $gid);dot();
    }
  }
  else {
    safe_mkdir($l,           0777 & ~oct($um), $uid, $gid);dot();
    safe_mkdir("$l/ALIASES", 0755 & ~oct($um), $uid, $gid);dot();
  }

  safe_mkdir($tmp,         0777 & ~oct($um), $uid, $gid);dot();
  safe_mkdir("$tmp/locks", 0777 & ~oct($um), $uid, $gid);dot();

  safe_mkdir("$config->{'install_dir'}/scripts", 0777 & ~oct($um), 
             $uid, $gid);dot();
  safe_mkdir("$l/LIB",        0777 & ~oct($um), $uid, $gid);dot();
  safe_mkdir("$l/SITE",       0777 & ~oct($um), $uid, $gid);dot();
  safe_mkdir("$l/SITE/files", 0777 & ~oct($um), $uid, $gid);dot();
  safe_mkdir("$config->{'install_dir'}/lib/setup", 0777 & ~oct($um), 
             $uid, $gid);dot();

  unless (-d dirname($config->{majordomocf})) {
    safe_mkdir(dirname($config->{majordomocf}), 0777 & ~oct($um), $uid, $gid);dot();
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

  print "ok.\n";
  print retr_msg('making_dirs_domain', $lang, 'DOMAIN' => $d, 
                 'UMASK' => sprintf("%lo", (0777 & ~oct($um))));

  safe_mkdir("$l/$d",                    0777 & ~oct($um), $uid, $gid);dot();
  safe_mkdir("$l/$d/GLOBAL",             0777 & ~oct($um), $uid, $gid);dot();
  safe_mkdir("$l/$d/GLOBAL/sessions",    0777 & ~oct($um), $uid, $gid);dot();
  safe_mkdir("$l/$d/GLOBAL/spool",       0777 & ~oct($um), $uid, $gid);dot();
  safe_mkdir("$l/$d/GLOBAL/files",       0777 & ~oct($um), $uid, $gid);dot();
  safe_mkdir("$l/$d/GLOBAL/files/public",0777 & ~oct($um), $uid, $gid);dot();
  safe_mkdir("$l/$d/DEFAULT",             0777 & ~oct($um), $uid, $gid);dot();
  safe_mkdir("$l/$d/DEFAULT/files",       0777 & ~oct($um), $uid, $gid);dot();
  safe_mkdir("$l/$d/DEFAULT/files/public",0777 & ~oct($um), $uid, $gid);dot();

  # Make the dotfiles so the public directories show up properly in an index
  open DF, ">$l/$d/GLOBAL/files/.public"
    or die "Can't open $l/$d/GLOBAL/files/.public: $!";
  print DF retr_msg('public_dir', $lang);
  close DF;
  dot();
  chownmod($uid, $gid, (0777 & ~oct($um)), "$l/$d/GLOBAL/files/.public");
  dot();

  open DF, ">$l/$d/DEFAULT/files/.public"
    or die "Can't open $l/$d/DEFAULT/files/.public: $!";
  print DF retr_msg('public_dir', $lang);
  close DF;
  dot();
  chownmod($uid, $gid, (0777 & ~oct($um)), "$l/$d/DEFAULT/files/.public");
  dot();
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
    $msg = retr_msg('domain_password', $lang, 'DOMAIN' => $dom);
    $pw = get_passwd($msg);
    $config->{'domain'}{$dom}{'master_password'} = $pw;
  }
  print retr_msg('config_defaults', $lang, 'DOMAIN' => $dom)
    unless $quiet;

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
	   'addr_strict_domain_check' => $config->{domain}{$dom}{addr_strict_domain_check},
	   'addr_xforms'     => $config->{ignore_case} ? "ignore case" : '',
           'master_password' => $config->{'domain'}{$dom}{master_password},
           'mta'             => $config->{'mta'},
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
    $subs->{'confirm_url'} = "$config->{'cgi_url'}mj_confirm/domain=$dom?t=\$TOKEN";
    $subs->{'wwwadm_url'} = "$config->{'cgi_url'}mj_wwwadm/domain=$dom";
    $subs->{'wwwusr_url'} = "$config->{'cgi_url'}mj_wwwusr/domain=$dom";
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

# Dump out the initial site config
sub do_site_config {
  my($data, $mtaopts, $pw);

  # Prompt for the site password if necessary
  $pw = $config->{'site_password'};
  unless ($pw) {
    $pw = get_passwd(retr_msg('site_password', $lang));
    $config->{'site_password'} = $pw;
  }
  require Digest::SHA1;
  $pw = Digest::SHA1::sha1_base64($pw);

  print retr_msg('config_site', $lang) unless $quiet;

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
	   'mta'                => $config->{'mta'},
	   'mta_options'        => $mtaopts,
	   'mta_separator'      => $config->{'mta_separator'},
	   'cgi_bin'            => $config->{'cgi_bin'},
	   'cgi_url'            => $config->{'cgi_url'},
	   'queue_mode'         => $config->{'queue_mode'},
	  };
  if ($config->{'database_backend'} ne 'sql') {
    $data->{'database_backend'} = $config->{'database_backend'};
  } else {
    $data->{'database_backend'} = $config->{'database'};
  }

  # Open the site config file
  open SITE, ">$config->{'lists_dir'}/SITE/config.pl"
    or die "Cannot open site config file $config->{'lists_dir'}/SITE/config.pl: $!";
  dot();

  # Print out the data hash
  print SITE Dumper($data)
    or die "Cannot populate site config file $config->{'lists_dir'}/SITE/config.pl: $!";
  dot();

  # Close the file
  close SITE;
  dot();

  # Change ownership and permissions
  chownmod(scalar getpwnam($config->{'uid'}),	
           scalar getgrnam($config->{'gid'}),
           (0777 & ~oct($config->{'umask'})), 
           "$config->{'lists_dir'}/SITE/config.pl");
  print ".ok.\n" unless $quiet;
}

# Run commands to create configuration templates.
sub install_config_templates {
  my ($config, $domain) = @_;
  my (@args, $pw, $tmpfh, $tmpfile);

  $pw = $config->{'site_password'};
  unless ($pw) {
    $pw = get_passwd(retr_msg('site_password', $lang));
    $config->{'site_password'} = $pw;
  }

  ($tmpfile, $tmpfh) = tempfile();

  open CONFIG, "< setup/config_commands" || return;
  print $tmpfh "default password $pw\n\n";
  while (<CONFIG>) {
    print $tmpfh $_;
  }
  close CONFIG;
  close $tmpfh;

  print retr_msg('config_templates', $lang, 'DOMAIN' => $domain)
    unless $quiet;

  open(TMP, ">&STDOUT");
  open(STDOUT, ">/dev/null");
  @args = ("$config->{'install_dir'}/bin/mj_shell", '-u',
           'mj2_install@example.com', '-d', $domain, '-F', $tmpfile);

  if (system(@args)) {
    die "Error executing $args[0]: $?";
  }

  close STDOUT;
  open(STDOUT, ">&TMP");
  unlink $tmpfile;

  print "ok.\n" unless $quiet;
}


# Copy all of the stock response files into their site-wide directory
sub install_response_files {
  my ($gid, $uid, $um);

  print retr_msg('response_files', $lang) unless $quiet;

  rcopy("files", "$config->{'lists_dir'}/SITE/files", 1);
  rcopy("setup", "$config->{'install_dir'}/lib/setup", 1);
  copy_file(".mj_config", ".", "$config->{'install_dir'}/lib", 0);

  $uid = getpwnam($config->{'uid'});
  $gid = getgrnam($config->{'gid'});
  $um  = oct($config->{'umask'});
  rchown($uid, $gid, 0666 & ~$um, 0777 & ~$um, 
         "$config->{'lists_dir'}/SITE/files");
  rchown($uid, $gid, 0666 & ~$um, 0777 & ~$um, 
         "$config->{'install_dir'}/lib/setup");

  print "ok.\n" unless $quiet;
}

# Make symlinks from a protected directory to our alias files
sub make_alias_symlinks {
  my $dom = shift;
  my $dir = shift;

  unlink "$dir/mj-alias-$dom" if (-e "$dir/mj-alias-$dom");
  symlink("$config->{lists_dir}/ALIASES/mj-alias-$dom", "$dir/mj-alias-$dom") ||
    warn retr_msg('no_symlink', $lang, 'SOURCE' => "$dir/mj-alias-$dom",
                  'DEST' => "$config->{lists_dir}/ALIASES/mj-alias-$dom",
                  'ERROR' => $!);

  if ($config->{sendmail_maintain_vut}) {
    unlink "$dir/mj-vut-$dom" if (-e "$dir/mj-vut-$dom");
    symlink("$config->{lists_dir}/ALIASES/mj-vut-$dom", "$dir/mj-vut-$dom") ||
    warn retr_msg('no_symlink', $lang, 'SOURCE' => "$dir/mj-vut-$dom",
                  'DEST' => "$config->{lists_dir}/ALIASES/mj-vut-$dom",
                  'ERROR' => $!);
  }
}

# Set the appropriate permissions on all of the scripts.
sub set_script_perms {
  my $sidscripts = shift;
  my $scripts    = shift;
  my ($dir, $gid, $id, $uid);

  print retr_msg('script_perms', $lang) unless $quiet;
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
  dot();
  chownmod($uid, $gid, "", $id);
  dot();

  # Change permissions on the top-level installation directory, but make
  # sure that anyone can look in it to run programs.
  for $dir ($id, "$id/bin", "$id/lib", "$id/man") {
    die "Cannot locate the directory at\n  $dir\nto change permissions.\n"
      unless (-d $dir);
  }
  chownmod("", "", (0777 & ~oct($config->{'umask'})) | 0555, $id);
  dot();
  rchown($uid, $gid, 0644, 0755, "$id/bin", "$id/man", "$id/lib");
  dot();

  # Make executables setuid; the scripts must be readable while the the
  # wrappers need only be executable.
  if ($config->{'wrappers'}) {
    chownmod("", "", 06511, @$sidscripts);
  }
  else {
    chownmod("", "", 06555, @$sidscripts);
  }
  dot();
  chownmod("", "", 0555, @$scripts);
  dot();
  print "ok\n" unless $quiet;
}

# Give a suggested crontab
sub suggest_crontab {
  return retr_msg('crontab', $lang, 
                  'INSTALL_DIR' => $config->{'install_dir'});
}

sub mta_setup {
  no strict 'refs';
  my ($df, $gid, $i, $nhead, $uid);
  require "setup/mta_$config->{mta}.pl";

  # First do the generalized setup
  &{"setup_$config->{mta}"}($config);

  $df = "$config->{lists_dir}/ALIASES/mj-domains";
  open (DOMAINS, "> $df.$$") 
    or die "Cannot open $df.$$: $!";

  $nhead = 0;
  for $i (@_) {
    print DOMAINS "$i\n";
    &{"setup_$config->{mta}_domain"}($config, $i, $nhead);
    $nhead = 1;
  }
  close DOMAINS;

  mv ("$df.$$", $df) 
    or die "Cannot replace $df: $!";

  $uid = getpwnam($config->{'uid'});
  $gid = getgrnam($config->{'gid'});
  chownmod($uid, $gid, "", $df);
}

use IO::File;
sub tempfile {
  my $chr = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890_';
  my $base = "/tmp/mji.$$.";
  my($handle, $name);

  # Try to open a file ten times
  for (my $i = 0; $i < 10; $i++) {

    # Append ten random characters
    $name = $base;
    for (my $j = 0; $i < 10; $i++) {
      $name .= substr($chr, rand(length($chr)), 1);
    }
    $handle = new IO::File($name, O_CREAT | O_EXCL | O_RDWR, 0600);
    return ($name, $handle) if $handle;
  }
  die "Cannot open a temporary file after ten tries: $!";
}

sub read_mj_config {
  my $lang = shift;
  my $msg;
  require 'setup/query_util.pl';

  $config = eval { require ".mj_config" };

  if (defined $config &&
      defined $config->{'install_dir'} &&
      -r ("$config->{'install_dir'}/lib/.mj_config")) {
    unless (defined $lang and length $lang) {
      $lang = $config->{'language'};
    }
    $msg = retr_msg('mj_config_installed', $lang, 'LIBDIR' =>
                    "$config->{'install_dir'}/lib");
    if (get_bool($msg, 0)) {
      $config = do "$config->{'install_dir'}/lib/.mj_config";
      save_mj_config($config) if (defined $config);
    }
  }

  $config;
}

use Data::Dumper;
sub save_mj_config {
  my $config = shift;

  open(CONFIG, ">.mj_config") || die ("Cannot create .mj_config: $!");
  print CONFIG Dumper($config);
  close CONFIG;
  if ($config->{save_passwords}) {
    chmod 0600, '.mj_config';
  }
}

=head1 COPYRIGHT

Copyright (c) 1999, 2002, 2003, 2004 Jason Tibbitts for The Majordomo
Development Group.  All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the license detailed in the LICENSE file of the
Majordomo2 distribution.

This program is distributed in the hope that it will be useful, but WITHOUT 
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the Majordomo2 LICENSE file for more
detailed information.

=cut

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***


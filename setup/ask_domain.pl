sub ask_domain {
  my($config, $i) = @_;
  my $hdr = "Configuring the domain: $i.";
  $config->{'domain'}{$i} ||= {};
  my $cfg = $config->{'domain'}{$i};

  #---- Ask for global configuration information:
  #---- Actual Internet domain
  $msg = <<EOM;
$hdr

What is the actual Internet domain name?

EOM
  $def = $cfg->{'whereami'} || $i;
  $cfg->{'whereami'} = get_str($msg, $def);
  
  #---- Ask for the actual address that Majordomo will receive mail at
  $msg = <<EOM;
$hdr

What address will the Majordomo at $i receive mail at?
 This is normally "majordomo" but if you are running a Majordomo1
  installation you may want to run Majordomo2 at an address like "mj2".
EOM
  $def = $cfg->{whoami} || 'majordomo';
  $cfg->{whoami} = get_str($msg, $def);

  #---- owner address, for alias construction
  $msg = <<EOM;
$hdr

What is the email address of the owner of this Majordomo installation?
EOM
  $def = $cfg->{'owner'};
  # XXX Should probably have a get_addr routine, but we might have
  # problems requiring Mj::Addr.pm.
  $cfg->{'owner'} = get_str($msg, $def);
  
  #---- name of majordomo
  $msg = <<EOM;
$hdr

What is the name of Majordomo installation at $i?
 The installation can be given a name that is used as a title for reports,
   the output of the lists command, and elsewhere.
EOM
  $def = $cfg->{'site_name'};
  $cfg->{'site_name'} = get_str($msg, $def);
  
  #---- Get global password
  $msg = <<EOM;
$hdr

Please choose a password.
  Each domain is given a single global password that can be used for all
    list functions.  This password is independent of the individual list
    passwords.
EOM
  $def = $cfg->{'master_password'};
  if ($config->{save_passwords}) {
    until ($cfg->{'master_password'} ne "") {
      $cfg->{'master_password'} = get_str($msg, $def);
    }
  } else {
    delete $cfg->{'master_password'};
  }

  #---- Ask if there are old (1.x) lists to convert
  $msg = <<EOM;
$hdr

Do you have Majordomo 1.x lists to convert?
 Majordomo2 can convert your old lists into the new format for you using
  the convertlist.pl script.

EOM
  $def = defined($cfg->{'old_lists'}) ? $cfg->{'old_lists'} : 0;
  $cfg->{'old_lists'} = get_bool($msg, $def);

  if ($cfg->{'old_lists'}) {

    #---- Ask for location of old (1.x) lists
    $msg = <<EOM;
$hdr

Where are the Majordomo 1.x lists for $i stored?
 You can enter the path to the directory here, or you can specify it using
  the -o option to convertlist.pl.

EOM
    $def = $cfg->{'old_lists_dir'};
    $cfg->{'old_lists_dir'} = get_dir($msg, $def, 1);

    #---- Ask for location of majordomo.cf.
    $msg = <<EOM;
$hdr

What is the full path to the Majordomo 1.x configuration file for lists in
  $i?
 The file is usually named majordomo.cf and is generally in the same place
  as the Majordomo1 wrapper and scripts, but some configurations place it
  elsewhere or give it a different name.

EOM
    $def = $cfg->{'old_majordomo_cf'};
    $cfg->{'old_majordomo_cf'} = get_file($msg, $def, 1);
  }

  #---- Ask for qmail information
  if ($config->{'mta'} eq 'qmail') {
    ask_qmail_domain($config, $i);
  }
}

=head1 COPYRIGHT

Copyright (c) 1999 Jason Tibbitts for The Majordomo Development
Group.  All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the license detailed in the LICENSE file of the
Majordomo2 distribution.

his program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the Majordomo2 LICENSE file for more
detailed information.

=cut

1;

#
### Local Variables: ***
### cperl-indent-level:2 ***
### cperl-label-offset:-1 ***
### indent-tabs-mode: nil ***
### End: ***

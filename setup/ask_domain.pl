sub ask_domain {
  my($confg, $i) = @_;

  #---- Ask for global configuration information:
  #---- name of majordomo
  $msg = <<EOM;

What is the name of Majordomo installation at $i?
 The installation can be given a name that is used as a title for reports,
   the output of the lists command, and elsewhere.
EOM
  $def = $config->{'domain'}{$i}{'site_name'};
  $config->{'domain'}{$i}{'site_name'} = get_str($msg, $def);
  
    #---- Ask for the actual address that Majordomo will receive mail at
  $msg = <<EOM;

What address will the Majordomo at $i receive mail at?
 This is normally "majordomo" but if you are running a Majordomo1
  installation you may want to run Majordomo2 at an address like "mj2".
EOM
  $def = $config->{domain}{$i}{whoami} || 'majordomo';
  $config->{domain}{$i}{whoami} = get_str($msg, $def);
  
  #---- owner address, for alias construction
  $msg = <<EOM;

What is the email address of the owner of this Majordomo installation?
EOM
  $def = $config->{'domain'}{$i}{'owner'};
  # XXX Should probably have a get_addr routine, but we might have
  # problems requiring Mj::Addr.pm.
  $config->{'domain'}{$i}{'owner'} = get_str($msg, $def);
  
  #---- Get global password
  $msg = <<EOM;

Please choose a password.
  Each domain is given a single global password that can be used for all
    list functions.  This password is independent of the individual list
    passwords.
EOM
  $def = $config->{'domain'}{$i}{'master_password'};
  if ($config->{save_passwords}) {
    $config->{'domain'}{$i}{'master_password'} = get_str($msg, $def);
  } else {
    delete $config->{'domain'}{$i}{'master_password'};
  }
  
  #---- Ask for location of old (1.x) lists
  $msg = <<EOM;

Where are the Majordomo 1.x lists for $i stored?
  If you have lists that were maintained by Majordomo 1.x, you can convert
    them for use by Majordomo 2.0.  You will be given the option to do this
    during the "make postinstall" step at the end of the installation.
  If you have no 1.x lists to convert, enter nothing.
EOM
  $def = $config->{'domain'}{$i}{'old_lists_dir'};
  $config->{'domain'}{$i}{'old_lists_dir'} = get_dir($msg, $def, 1);
  
  # Try to get list of lists; for each list found, ask enough questions
  # about it to enable a conversion.
  
  print "\nSorry, old list conversion not yet implemented.  Use:\n";
  print "mj_shell -p password createlist list owner\@address\n";
  print "mj_shell -p password -f old_list_file subscribe=quiet,noinform new_list\n";
  print "To convert lists.\n";
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

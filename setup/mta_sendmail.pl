sub ask_sendmail {
  $config = shift;

    #---- Ask if aliases should be maintained
    $msg = <<EOM;
Mail Handling Setup

Should Majordomo maintain your aliases automatically?
 Majordomo can automatically maintain your Sendmail aliases for you.  You
  still have to do some manual setup (see README.SENDMAIL) but this only
  needs to be done once; after that you can add lists without doing any
  configuration whatsoever.
 If you say no, Majordomo  will provide you with information to paste into
  your aliases file when you add new lists.
EOM
    $def = $config->{'maintain_mtaconfig'} || 1;
    $config->{'maintain_mtaconfig'} = get_bool($msg, $def);

    #---- Ask about virtuser files as well
    $msg = <<EOM;
Mail Handling Setup

Should Majordomo maintain VirtUserTable files as well?
 Majordomo can also automatically maintain VirtUserTable files for handling
  virtual domains.  If you answer 'yes', these files will be generated and
  the aliases will be adjusted appropriately.
EOM
    $def = $config->{'sendmail_maintain_vut'} || 0;
    $config->{'sendmail_maintain_vut'} = get_bool($msg, $def);

    #---- Ask about making links
    $msg = <<EOM;
Mail Handling Setup

Should Majordomo make links to alias and virtuser files?
 Some Sendmail versions will complain about permission problems with
  Majordomo-generated alias files; this attempts to work around that by
  making some symbolic links.
EOM
    $def = $config->{'sendmail_make_symlinks'} || 0;
    $config->{'sendmail_make_symlinks'} = get_bool($msg, $def);

    if ($config->{'sendmail_make_symlinks'}) {
      #---- Ask about link location
      $msg = <<EOM;
Mail Handling Setup

Where should these links be made?
 This needs to be a root-owned directory with sufficiently restrictive
  permissions to appease Sendmail.
EOM
      $def = $config->{'sendmail_symlink_location'} ||
        (-d "/etc/mail" && "/etc/mail") ||
	(-d "/etc" && "/etc") || '';  
      $config->{'sendmail_symlink_location'} = get_dir($msg, $def);
    }

  # Technically we should ask about this, but I really doubt that anyone
  # ever changes it from the default.
  $config->{mta_separator} = '+';
}

sub setup_sendmail {};

sub setup_sendmail_domain {
  my($config, $dom, $nhead) = @_;

  # Do sendmail configuration by calling createlist-regen.

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

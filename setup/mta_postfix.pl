sub ask_postfix {
  $config = shift;

    #---- Ask if aliases should be maintained
    $msg = <<EOM;
Mail Handling Setup

Should Majordomo maintain your aliases automatically?
 Majordomo can automatically maintain your postfix aliases for you.  You
  still have to do some manual setup (see README.POSTFIX) but this only
  needs to be done once; after that you can add lists without doing any
  configuration whatsoever.
 If you say no, Majordomo  will provide you with information to paste into
  your aliases file when you add new lists.  Saying 'yes' is highly
  recommended
EOM
    $def = $config->{'maintain_mtaconfig'} || 1;
    $config->{'maintain_mtaconfig'} = get_bool($msg, $def);

    #---- Ask about virtuser files as well
    $msg = <<EOM;
Mail Handling Setup

Should Majordomo maintain virtual_maps files as well?
 Majordomo can also automatically maintain virtual_maps files for handling
  virtual domains.  If you answer 'yes', these files will be generated and
  the aliases will be adjusted appropriately.  Saying 'yes' is highly
  recommended.
EOM
    $def = $config->{'sendmail_maintain_vut'} || 0;
    $config->{'sendmail_maintain_vut'} = get_bool($msg, $def);

  # Technically we should ask about this, but I really doubt that anyone
  # ever changes it from the default.
  $config->{mta_separator} = '+';
}

sub setup_postfix {};

sub setup_postfix_domain {
  my($config, $dom) = @_;

  require "setup/mta_sendmail.pl";
  setup_sendmail_domain($config, $dom, 1);
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

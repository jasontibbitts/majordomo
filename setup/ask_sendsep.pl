sub ask_sendsep {
  $config = shift;
  $def = shift;

  #---- Ask for the "mailbox separator"
  $msg = <<EOM;

What does your MTA use as the mailbox separator?
 Majordomo needs to know how it can add additional uninterpreted data to
  the local part of an address.  This is generally a configuration option
  of your MTA.

 For example, if the separator is '+', mail sent to the address 'foo+bar'
  will reach the user 'foo'.  If it is '-', then mail to 'foo-bar' reaches
  'foo'.

 Majordomo uses this to attach data about the message and the recipient to
  the envelope, so that when bounces are received some useful information
  about the source of the bounce can be discerned.
EOM
  $config->{mta_separator} = get_str($msg, $def);
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


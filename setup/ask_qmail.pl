sub ask_qmail_domain {
  my($config, $dom) = @_;

  $msg = <<EOM;

What is the qmail alias directory for this domain?
    Majordomo will create a .qmail-default file in this directory.
EOM
  $def = $config->{'domain'}{$i}{'aliasdir'};
  $config->{'domain'}{$i}{'aliasdir'} = get_str($msg, $def);
}

sub ask_qmail {
  my($config) = @_;

  $msg = <<EOM;



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

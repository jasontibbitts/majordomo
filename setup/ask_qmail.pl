sub ask_qmail {
  my($comfig, $dom) = @_;

  $msg = <<EOM;

What is the qmail alias directory for this domain?
    Majordomo will create .qmail files in this directory for lists (and 
    the Majordomo aliases) in this Majordomo installation.
EOM
  $def = $config->{'domain'}{$i}{'aliasdir'};
  $config->{'domain'}{$i}{'aliasdir'} = get_str($msg, $def);

  $msg = <<EOM;

What virtual domain prefix should Majordomo prepend to aliases in this
domain?
    If you leave this value blank, Majordomo will create files of the 
    form .qmail-testlist-owner.  A value of foo would create files such
    as .qmail-foo-testlist, .qmail-foo-testlist-owner, etc.
EOM
  $def = $config->{'domain'}{$i}{'aliasprefix'};
  $config->{'domain'}{$i}{'aliasprefix'} = get_str($msg, $def);
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

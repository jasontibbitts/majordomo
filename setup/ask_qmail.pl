sub ask_qmail {
  my($config) = @_;

  $msg = <<EOM;

Should Majordomo maintain .qmail-default files automatically?
 Majordomo can hook into the .qmail-default mechanism and can maintain the
  necessary .qmail-default files for you.  Note that if you have other
  (non-Majordomo) entries in any of your .qmail-default files, Majordomo
  will _not_ overwrite them; it will instead warn you and leave the files
  unchanged.
EOM
  $def = (defined $config->{'maintain_mtaconfig'} ?
	  $config->{'maintain_mtaconfig'} : 1);
  $config->{'maintain_mtaconfig'} = get_bool($msg, $def);

  $msg = <<EOM;

What is the path to the qmail binaries?
EOM
  $def = ($config->{'qmail_path'} ||
	  (-d '/var/qmail/bin' && '/var/qmail/bin') ||
	  (-d '/usr/sbin'      && '/usr/sbin'));
  $config->{'qmail_path'} = get_dir($msg, $def);
}

sub ask_qmail_domain {
  my($config, $dom) = @_;

  $msg = <<EOM;

What is the qmail directory for $dom?
 Majordomo will create an appropriate configuration file in this directory.
EOM
  $def = $config->{'domain'}{$dom}{'qmaildir'};
  $config->{'domain'}{$dom}{'qmaildir'} = get_dir($msg, $def);

  $msg = <<EOM;

What is the name of the qmail default file for $dom?
EOM
  $def = $config->{'domain'}{$dom}{'qmailfile'};
  $config->{'domain'}{$dom}{'qmailfile'} = get_file($msg, $def);
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

sub ask_exim {
  my $config = shift;
  my ($def, $msg);

    #---- Ask if aliases should be maintained
  $msg = <<EOM;
Should Majordomo maintain your aliases automatically?
 Majordomo can automatically maintain your Exim aliases for you.  You
  still have to do some manual setup (see README.EXIM) but this only
  needs to be done once; after that you can add lists without doing any
  configuration whatsoever.
 If you say no, Majordomo  will provide you with information to paste into
  your aliases file when you add new lists.
EOM
  $def = $config->{'maintain_mtaconfig'} || 1;
  $config->{'maintain_mtaconfig'} = get_bool($msg, $def);

  # Since it is up to us tp specify this, don't bother asking the user
  # about it.
  $config->{mta_separator} = '+';

  # Exim also needs slightly more liberal permissions on the directory
  # where aliases are kept.
  $config->{mta_umask} = "066";
}

sub setup_exim {};

# Do domain-specific Exim configuration.  Really all we need to do is call
# createlist-regen to make the alias files and suggest the appropriate
# stuff to paste into the Exim configuration file.
sub setup_exim_domain {
  my ($config, $dom) = @_;
  my $whereami = $config->{'domain'}{$dom}->{'whereami'};

  require "setup/mta_sendmail.pl";
  setup_sendmail_domain($config, $dom);

  # Now just suggest some info
  if ($dom eq $whereami) {
    print <<EOM;

---------------------------------------------------------------------------
The following director should be placed in the Directors section of your
Exim configuration file:

majordomo_aliases:
    driver = aliasfile
    pipe_transport = address_pipe
    suffix = \"$config->{mta_separator}*\"
    suffix_optional
    user = $config->{uid}
    domains = lsearch;$config->{lists_dir}/ALIASES/mj-domains
    file = $config->{lists_dir}/ALIASES/mj-alias-\${domain}
    search_type = lsearch

Improvements to this description are welcomed.
---------------------------------------------------------------------------

EOM
  } 
  else {
  
    print <<EOM;

---------------------------------------------------------------------------
The following director should be placed in the Directors section of your
Exim configuration file:

majordomo_aliases_$dom:
    driver = aliasfile
    pipe_transport = address_pipe
    suffix = \"$config->{mta_separator}*\"
    suffix_optional
    user = $config->{uid}
    domains = $whereami
    file = $config->{lists_dir}/ALIASES/mj-alias-$dom
    search_type = lsearch

Improvements to this description are welcomed.
---------------------------------------------------------------------------

EOM
  }
}

=head1 COPYRIGHT

Copyright (c) 1999, 2002 Jason Tibbitts for The Majordomo Development
Group.  All rights reserved.

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
### cperl-label-offset:-1 ***
### indent-tabs-mode: nil ***
### End: ***

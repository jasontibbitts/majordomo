sub ask_exim {
  my $config = shift;
  my ($def, $msg);

  #---- Determine version number
  $msg = retr_msg('exim_version', $lang);
  $def = $config->{'exim_version'} || get_exim_version();
  $config->{'exim_version'} = get_enum($msg, $def, [qw(3 4)]);

  #---- Ask if aliases should be maintained
  $msg = retr_msg('maintain_aliases', $lang, 'MTA' => 'EXIM');
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

  #---- Suggest routers or directors for the exim configuration file.
  if ($config->{'exim_version'} eq '4') {
    # If the majordomo domain and internet domain are identical,
    # suggest a generic router.
    if ($dom eq $whereami) {
      print retr_msg('exim_router', $lang, 
                     'LISTS_DIR' => $config->{'lists_dir'}, 
                     'SEPARATOR' => $config->{'mta_separator'},
                     'UID' => $config->{'uid'},
                    );
    } 
    else {
      print retr_msg('exim_router_custom', $lang, 
                     'DOMAIN'    => $dom,
                     'LISTS_DIR' => $config->{'lists_dir'}, 
                     'SEPARATOR' => $config->{'mta_separator'},
                     'UID'       => $config->{'uid'},
                     'WHEREAMI'  => $whereami,
                    );
    }

  }
  else {
    if ($dom eq $whereami) {
      print retr_msg('exim_director', $lang, 
                     'LISTS_DIR' => $config->{'lists_dir'}, 
                     'SEPARATOR' => $config->{'mta_separator'},
                     'UID' => $config->{'uid'},
                    );
    } 
    else {
      print retr_msg('exim_director_custom', $lang, 
                     'DOMAIN'    => $dom,
                     'LISTS_DIR' => $config->{'lists_dir'}, 
                     'SEPARATOR' => $config->{'mta_separator'},
                     'UID'       => $config->{'uid'},
                     'WHEREAMI'  => $whereami,
                    );
    }
  }
}

sub get_exim_version {
  my ($i, $verstr);
  for $i ('/usr/sbin/exim', '/usr/lib/exim') {
    if (-x $i) {
      $verstr = `$i -bV`;
      if ($verstr && $verstr =~ /version ([34])/) {
	return $1;
      }
    }
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

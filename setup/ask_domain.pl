sub ask_domain {
  my ($config, $dom) = @_;
  my ($cfg, $def, $msg, $strict, $tld, $tmp);

  $config->{'domain'}{$dom} ||= {};
  $cfg = $config->{'domain'}{$dom};

  #---- Ask for global configuration information:

  #---- Actual Internet domain
  $msg = retr_msg('internet_domain', $lang, 'DOMAIN' => $dom);
  $def = $cfg->{'whereami'} || $dom;
  $cfg->{'whereami'} = get_str($msg, $def);

  #---- Strict checking (Intranet use)
  $cfg->{whereami} =~ /([^.]*)$/;
  $tld = $1;
  $msg = retr_msg('strict_domain_checks', $lang, 'DOMAIN' => $dom);
  $def = $cfg->{'addr_strict_domain_check'} ||
    $Mj::Addr::top_level_domains{$tld} ? 1 : 0;
  $strict = get_bool($msg, $def);
  $cfg->{'addr_strict_domain_check'} = $strict;

  #---- The Majordomo server address
  $msg = retr_msg('server_address', $lang, 'DOMAIN' => $dom,
                  'WHEREAMI' => $cfg->{'whereami'});
  $def = $cfg->{'whoami'} || 'majordomo';
  $cfg->{'whoami'} = get_addr($msg, $def, $cfg->{'whereami'}, $strict);

  #---- The domain owner's address
  $tmp = $cfg->{'whoami'};
  $tmp =~ s/\@[\w+.-]+$//;

  $msg = retr_msg('domain_owner', $lang, 'DOMAIN' => $dom,
                  'WHEREAMI' => $cfg->{'whereami'},
                  'WHOAMI' => $tmp);
  $def = $cfg->{'owner'};
  $cfg->{'owner'} = get_addr($msg, $def, $cfg->{'whereami'}, $strict);

  #---- A brief title for the domain
  $msg = retr_msg('site_name', $lang, 'DOMAIN' => $dom);
  $def = $cfg->{'site_name'};
  $cfg->{'site_name'} = get_str($msg, $def);

  #---- Get global password
  $msg = retr_msg('domain_password', $lang, 'DOMAIN' => $dom);
  $def = $cfg->{'master_password'};
  if ($config->{'save_passwords'}) {
    $cfg->{'master_password'} = get_passwd($msg, $def);
  } 
  else {
    delete $cfg->{'master_password'};
  }

  #---- Ask if there are old (1.x) lists to convert
  $msg = retr_msg('mj1_convert', $lang, 'DOMAIN' => $dom);
  $def = defined($cfg->{'old_lists'}) ? $cfg->{'old_lists'} : 0;
  $cfg->{'old_lists'} = get_bool($msg, $def);

  if ($cfg->{'old_lists'}) {
    #---- Ask for location of old (1.x) lists
    $msg = retr_msg('mj1_dir', $lang, 'DOMAIN' => $dom);
    $def = $cfg->{'old_lists_dir'};
    $cfg->{'old_lists_dir'} = get_dir($msg, $def, 1);

    #---- Ask for location of majordomo.cf.
    $msg = retr_msg('mj1_config', $lang, 'DOMAIN' => $dom);
    $def = $cfg->{'old_majordomo_cf'};
    $cfg->{'old_majordomo_cf'} = get_file($msg, $def, 1);
  }

  #---- Ask for qmail information
  if ($config->{'mta'} eq 'qmail') {
    ask_qmail_domain($config, $dom);
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

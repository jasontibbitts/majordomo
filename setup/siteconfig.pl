# Site configuration update script

use DirHandle;
use Data::Dumper;
require "setup/ask_basic.pl";
require "setup/ask_domain.pl";
require "setup/query_util.pl";
require "setup/install_util.pl";
require "setup/setup_func.pl";
use vars qw($config $lang $nosep $sepclear);

$config = eval { require ".mj_config" };
die retr_msg('no_mj_config', $lang)
  unless $config;

$| = 1;
my $file = "$config->{'install_dir'}/SITE/config.pl";

ask_lang($config);

#---- Ask about clearing screen
ask_clear($config);

#---- Explain what is about to happen
sep();
print retr_msg('update_siteconfig', $lang, 'FILE' => $file);
ask_continue();

#---- Repeat the basic questions
ask_site_config($config);

#---- Save the .mj_config file
save_mj_config($config);

#---- Save the site configuration file
if (get_bool(retr_msg('save_config_pl', $lang, 'FILE' => $file), 1)) {
  do_site_config();
}

exit;


sub ask_site_config {
  my $config = shift;
  my (@backends, $db, $def, $msg);

  #---- Get site password
  if ($config->{save_passwords}) {
    $msg = retr_msg('site_password', $lang);
    $def = $config->{'site_password'};
    $config->{'site_password'} = get_passwd($msg, $def);
  }
  else {
    # The password will be requested during when the software
    # is installed.
    delete $config->{'site_password'};
  }

  #---- Ask for MTA
  $msg = retr_msg('mta', $lang);
  $def = ($config->{'mta'} ||
          (-x '/var/qmail/bin/qmail-inject' && 'qmail')    ||
          (-x '/usr/sbin/qmail-inject'      && 'qmail')    ||
          (-x '/usr/sbin/exim'              && 'exim')     ||
          (-x '/usr/lib/exim'               && 'exim')     ||
          # Sendmail goes last because most MTAs have some sendmail-like
          # wrapper there
          (-x '/usr/lib/sendmail'           && 'sendmail') ||
          (-x '/usr/sbin/sendmail'          && 'sendmail') ||
          'none'
         );
  $config->{'mta'} = get_enum($msg, $def, [qw(none sendmail exim qmail postfix)]);

  if ($config->{'mta'} eq 'sendmail') {
    require "setup/mta_sendmail.pl";
    ask_sendmail($config);
  }
  elsif ($config->{'mta'} eq 'exim') {
    require "setup/mta_exim.pl";
    ask_exim($config);
  }
  elsif ($config->{'mta'} eq 'postfix') {
    require "setup/mta_postfix.pl";
    ask_postfix($config);
  }
  elsif ($config->{'mta'} eq 'qmail') {
    require "setup/mta_qmail.pl";
    ask_qmail($config);
  }
}


=head1 COPYRIGHT

Copyright (c) 2003 Jason Tibbitts for The Majordomo Development Group.
All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the license detailed in the LICENSE file of the
Majordomo2 distribution.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the Majordomo2
LICENSE file for more detailed information.

=cut

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

use Config;
use vars (qw($lang $nosep $sepclear));
$lang ||= 'en';

sub ask_continue {
  local $sepclear = 0;
  local $nosep = 1;
  print get_str(retr_msg('continue', $lang));
}

sub ask_clear {
  my $config = shift;

  $nosep = 1; $sepclear = 0;
  $msg = retr_msg('clear_screen', $lang);
  $def = defined($config->{'sepclear'}) ? $config->{'sepclear'} : 0;
  $config->{'sepclear'} = get_bool($msg, $def);
  $sepclear = $config->{'sepclear'}; $nosep = 0;
}

sub ask_lang {
  my $config = shift;

  my $def = $config->{'language'} || 'en';

  # If additional translations are added, the English "language" file
  # should be modified to prompt for that language.
  $lang = $config->{'language'} = 
    get_enum(retr_msg('language', 'en'), $def, [qw(en fr)]);
}

sub ask_basic {
  my $config = shift;
  my (@backends, $db, $def, $i, $msg, $tmpgid, $tmpnam, $tmppwd, $tmpuid);

  #---- Ask about clearing screen
  ask_clear($config);

  #---- Ask for the location of the perl executable
  $msg = retr_msg('perl_path', $lang);
  $def = $config->{startperl};
  unless ($def) {
    $def = $Config{startperl};
    $def =~ s/[\#\!]*\s*(\S+).*/$1/;
    unless (-x $def) {
      $msg .= retr_msg('startperl', $lang);
      $def = '';
    }
  }

  # Get an existing executable without searching $PATH, force existing.
  $config->{startperl} = get_file($msg, $def, 1, 1, 0, 1);

  #---- Ask for majordomo.cf location
  $msg = retr_msg('site_config', $lang);
  $def = $config->{majordomocf} || '/etc/majordomo/majordomo.cf';
  $config->{majordomocf} = get_file($msg, $def, 0, 0, 0, 0);

  #---- Ask for UID
  ($tmpnam,$tmppwd,$tmpuid,$tmpgid) = getpwnam($ENV{USER}) 
    if (defined $ENV{USER});
  $tmpnam = $tmpuid = 'unknown' unless (defined ($tmpnam));

  $msg = retr_msg('user_id', $lang, 'USER' => $tmpnam, 'UID' => $tmpuid);
  $def = $config->{'uid'} ||
    (getpwnam("majordom") && "majordom") ||
      (getpwnam("lists") && "lists");
  $config->{'uid'} = get_uid($msg, $def);

  #---- Ask for GID
  if (defined($tmpgid)) { $tmpnam = getgrgid($tmpgid);   }
  else                  { $tmpnam = $tmpgid = 'unknown'; }

  $msg = retr_msg('group_id', $lang, 'GROUP' => $tmpnam, 'GID' => $tmpgid);
  $def = $config->{'gid'} ||
    (getgrnam("majordom") && "majordom") ||
      (getgrnam("lists") && "lists");
  $config->{gid} = get_gid($msg, $def);

  #---- Ask about wrappers
  $msg = retr_msg('wrappers', $lang, 'UID' => $config->{'uid'});
  $def = defined($config->{'wrappers'}) ? $config->{'wrappers'} : 1;
  $config->{'wrappers'} = get_bool($msg, $def);

  #---- Ask for umask
  $msg = retr_msg('umask', $lang, 'UID' => $config->{'uid'},
                  'GID' => $config->{'gid'});
  $def = $config->{'umask'} || '077';
  $config->{'umask'} = get_enum($msg, $def, [qw(077 027 007 002 000)]);

  #---- Ask for insecure stored passwords
  $msg = retr_msg('save_passwords', $lang);
  $def = $config->{save_passwords};
  $config->{save_passwords} = get_bool($msg, $def);
  unless ($config->{save_passwords}) {
    # Just in case, clean out any stored passwords.
    for $i (@{$config->{'domains'}}, keys(%{$config->{'domain'}})) {
      warn qq(Clearing the password for the "$i" domain.);
      delete $config->{'domain'}{$i}{'master_password'};
    }
  }

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

  #---- Ask about database storage mechanism
  @backends = ('text');
  $msg = retr_msg('database', $lang);
  $msg .= retr_msg('database_text', $lang);
  $db = 'text';

  if ($have{'DBI'} && ($have{'DBD::Pg'} || $have{'DBD::mysql'})) {
    $db = 'sql';
    unshift @backends, 'sql';
    $msg .= retr_msg('database_sql', $lang);
  }
 
  if ($have{'DB_File'}) {
    $db = 'db';
    unshift @backends, 'db';
    $msg .= retr_msg('database_db_file', $lang);
  }

  if (defined $config->{'database_backend'}) {
    $def = $config->{'database_backend'};
  } 
  else {
    $def = $db;
  }

  $config->{'database_backend'} = get_enum($msg, $def, [@backends]);

  # Ask for RDBMS specifics if necessary
  if ($config->{'database_backend'} eq 'sql')
  {
    $db = $config->{'database_backend'};

    if($have{'DBD::Pg'}) {
      if(!defined($type)) { 
        $type = 'pgsql' 
      };
      unshift @sql_type, 'pgsql';
      $sql_msg .= retr_msg('database_pgsql', $lang);
    }

    if($have{'DBD::mysql'}) {
      if(!defined($type)) { 
        $type = 'mysql' 
      };
      unshift @sql_type, 'mysql';
      $sql_msg .= retr_msg('database_mysql', $lang);
    }

    if(defined $config->{'database'}->{'type'}) {
     $def = $config->{'database'}->{'type'};
    } else {
     $def = $type;
    }

    $config->{'database'}->{'type'} = get_enum($sql_msg, $def, [@sql_type]);

    $msg = retr_msg('dbms_host', $lang, 'DB' => $db);
    $def = $config->{database}->{srvr} || "localhost"; 
    $config->{database}->{srvr} = get_str($msg, $def);

    $msg = retr_msg('dbms_port', $lang, 'DB' => $db, 
                    'HOST' => $config->{database}->{srvr});

    if ($db eq 'pgsql') {
      $def = 5432;
    }
    else {
      $def = 3306;
    }
 
    $def = $config->{database}->{port} || $def; 
    $config->{database}->{port} = get_str($msg, $def);

    $msg = retr_msg('dbms_name', $lang, 'DB' => $db);
    $def = $config->{database}->{name} || "majordomo"; 
    $config->{database}->{name} = get_str($msg, $def);

    $msg = retr_msg('dbms_user', $lang, 'DB' => $db);
    $def = $config->{database}->{user} || "majordomo"; 
    $config->{database}->{user} = get_str($msg, $def);

    $msg = retr_msg('dbms_password', $lang, 'DB' => $db, 
                    'USER' => $config->{database}->{user});
    $def = $config->{database}->{pass} || ""; 
    $config->{database}->{pass} = get_str($msg, $def);
  }

  #---- Ask for default install location
  $msg = retr_msg('install_dir', $lang);
  $def = $config->{'install_dir'} || "/usr/local/majordomo";
  $config->{'install_dir'} = get_dir($msg, $def);

  #---- Ask for list directory
  $msg = retr_msg('lists_dir', $lang);
  $def = $config->{'lists_dir'} || "/usr/local/majordomo/lists";
  $config->{'lists_dir'} = get_dir($msg, $def);

  #---- Ask for writable temporary dir
  $msg = retr_msg('wtmp_dir', $lang);
  $def = $config->{'wtmpdir'} || "/tmp";
  $config->{'wtmpdir'} = get_dir($msg, $def);

  #---- Ask for secure temporary dir
  $msg = retr_msg('tmp_dir', $lang);
  $def = $config->{'tmpdir'} || "$config->{'install_dir'}/tmp";
  $config->{'tmpdir'} = get_dir($msg, $def);
  $config->{'lockdir'} = "$config->{'tmpdir'}/locks";

  #---- Ask for cgi-bin directory
  $msg = retr_msg('cgi_bin', $lang);
  $def = $config->{cgi_bin} ||
    (-d "/home/www/cgi-bin" && "/home/www/cgi-bin") ||
    (-d "/home/httpd/cgi-bin" && "/home/httpd/cgi-bin") || '';
  $config->{cgi_bin} = get_dir($msg, $def, 1);

  if ($config->{cgi_bin}) {
    #---- Ask if we can link to cgi-bin
    $msg = retr_msg('cgi_link', $lang);
    $def = $config->{cgi_link} || 0;
    $config->{cgi_link} = get_bool($msg, $def);

    #---- Ask for the URL of programs in cgi-bin
    $msg = retr_msg('cgi_url', $lang);
    $def = $config->{cgi_url} || '';
    $config->{cgi_url} = get_str($msg, $def);
    $config->{cgi_url} .= '/' unless $config->{cgi_url} =~ m!/$!;
  }

  #---- Ask about queueing
  $msg = retr_msg('mail_mode', $lang);
  $def = defined($config->{queue_mode}) ?
    $config->{queue_mode} : 1;
  $config->{queue_mode} = get_bool($msg, $def);
  if ($config->{queue_mode}) {
    require "setup/ask_queueing.pl";
    ask_queueing($config);
  }

  #---- Ask about case smashing
  $msg = retr_msg('address_case', $lang);
  $def = $config->{ignore_case};
  $config->{ignore_case} = get_bool($msg, $def);

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

  #---- Ask for virtual domains
  $msg = retr_msg('virtual_domains', $lang);
  $def = $config->{'domains'} || 
         [$Net::Config::NetConfig{'inet_domain'}] || undef;
  $config->{'domains'} = get_list($msg, $def, 1);

  require "setup/ask_domain.pl";
  for $i (@{$config->{'domains'}}) {
    ask_domain($config, $i);
  }
  sep();
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

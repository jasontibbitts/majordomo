# Domain creation script for Majordomo

# Basic functions:
#   1. Create the list hierarchy if necessary.
#   2. Make sure the permissions and ownerships are proper.
#   3. Convert 1.x lists.
#   (etc.  Perhaps spit out aliases?)

use DirHandle;
use Data::Dumper;
require "setup/ask_basic.pl";
require "setup/ask_domain.pl";
require "setup/query_util.pl";
require "setup/install_util.pl";
require "setup/setup_func.pl";
use vars qw($config $lang $nosep $sepclear);
my (@domains, $dom, $install, $newdomain);

$config = eval { require ".mj_config" };
die retr_msg('no_mj_config', $lang)
  unless $config;

$| = 1;

#---- Ask about clearing screen
ask_clear($config);

while (1) {

  if (@{$config->{'domains'}}) {
    @domains = @{$config->{'domains'}};
  }
  else { 
    @domains = &get_domains;
  }

  if (@domains) {
    print retr_msg('supported_domains', $lang);
    for $dom (@domains) {
      print "  $dom\n";
    }
    print "\n";
    ask_continue();
  }

  $newdomain = get_str(retr_msg('domain_name', $lang));
  exit 0 unless $newdomain;

  if ($newdomain =~ /[^A-Za-z0-9\.\-]/) {
    print retr_msg('invalid_domain', $lang, 'DOMAIN' => $newdomain);
    ask_continue();
    next;
  }

  ($dom) = grep { lc $_ eq lc $newdomain } @domains;
  if (defined $dom) {
    print retr_msg('existing_domain', $lang, 'DOMAIN' => $dom);
    $newdomain = $dom;
    ask_continue();
  }

  ask_domain($config, $newdomain);

  $install = 
    get_bool(retr_msg('install_domain', $lang, 'DOMAIN' => $newdomain), 1);

  if ($install) {

    # Create list directories and such
    create_dirs_dom(
                $config->{'lists_dir'},
                $newdomain,
                scalar getpwnam($config->{'uid'}),
                scalar getgrnam($config->{'gid'}),
                $config->{'umask'},
               );
    print ".ok\n";

    do_default_config($newdomain);
    install_config_templates($config, $newdomain);

    # Give some basic MTA configuration
    mta_append($newdomain);

    if ($config->{sendmail_make_symlinks}) {
      make_alias_symlinks($newdomain,
                          $config->{sendmail_symlink_location});
      &dot;
      print ".ok\n";
    }
  }

  # save the values in the configuration file.
  open(CONFIG, ">.mj_config") || die ("Cannot create .mj_config: $!");
  print CONFIG Dumper($config);
  close CONFIG;
  if ($config->{save_passwords}) {
    chmod 0600, '.mj_config';
  }
}

exit;

sub mta_append {
  no strict 'refs';
  my $nhead = 0;
  my @domains = get_domains();
  require "setup/mta_$config->{mta}.pl";

  # First do the generalized setup
  &{"setup_$config->{mta}"}($config);

  open DOMAINS, ">> $config->{lists_dir}/ALIASES/mj-domains" 
    or die "Cannot open $config->{lists_dir}/ALIASES/mj-domains:\n$!";

  for my $i (@_) {
    &{"setup_$config->{mta}_domain"}($config, $i, $nhead);
    $nhead = 1;

    unless (grep { lc $_ eq lc $i } @domains) {
      print DOMAINS "$i\n";
    }

    unless (grep { lc $_ eq lc $i } @{$config->{'domains'}}) {
      push (@{$config->{'domains'}}, $i);
    }
  }
  close DOMAINS;
}

sub get_domains {
  my @out;

  unless (open (DOMAINS, "< $config->{lists_dir}/ALIASES/mj-domains")) {
    warn "Cannot open $config->{lists_dir}/ALIASES/mj-domains.\n$!";
    return;
  }

  while (<DOMAINS>) {
    chomp $_;
    push @out, $_ if (defined $_ and length $_);
  }

  close DOMAINS;

  @out;
}

=head1 COPYRIGHT

Copyright (c) 2002 Jason Tibbitts for The Majordomo Development Group.
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

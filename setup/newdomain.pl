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
use vars qw($config);
my (@domains, $newdomain);

$config = eval { require ".mj_config" };
die "Can't add a domain unless Makefile.PL has been run!"
  unless $config;

$| = 1;


my ($msg88) = <<EOM;
Add a Domain

  Enter a single domain name.  The name may only include letters
  (upper or lower case), digits, period (.), or hyphen (-).  
  Enter a blank line to exit the program.

EOM

while (1) {

  if (@{$config->{'domains'}}) {
    printf "The following domains are currently supported:\n  %s",
      join "\n  ", @{$config->{'domains'}};
  }
  elsif (@domains = &get_domains) {
    printf "The following domains are currently supported:\n  %s",
      join "\n  ", @{$config->{'domains'}};
  }

  $newdomain = get_str ($msg88, '');
  exit 0 unless $newdomain;

  if ($newdomain =~ /[^A-Za-z0-9\.\-]/) {
    print qq(\n**** The domain "$newdomain" is not legitimate.\n);
    print qq(**** Only letters, digits, period, and hyphen are allowed.\n\n);
    next;
  }

  if (grep { lc $_ eq lc $newdomain } @domains) {
    print qq(\n**** The domain "$newdomain" is already supported.\n\n);
    next;
  }

  ask_domain($config, $newdomain);

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

  # save the values in the configuration file.
  open(CONFIG, ">.mj_config") || die("Can't create .mj_config: $!");
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
  require "setup/mta_$config->{mta}.pl";

  # First do the generalized setup
  &{"setup_$config->{mta}"}($config);

  open DOMAINS, ">> $config->{lists_dir}/ALIASES/mj-domains" 
    or die "Cannot open $config->{lists_dir}/ALIASES/mj-domains";

  for my $i (@_) {
    print DOMAINS "$i\n";
    &{"setup_$config->{mta}_domain"}($config, $i, $nhead);
    $nhead = 1;
    push @{$config->{'domains'}}, $i;
  }
  close DOMAINS;
}

sub get_domains {
  my (@out);

  open DOMAINS, "< $config->{lists_dir}/ALIASES/mj-domains" 
    or die "Cannot open $config->{lists_dir}/ALIASES/mj-domains.\n";

  while (<DOMAINS>) {
    chomp $_;
    push @out, $_ if ($_);
  }

  close DOMAINS;

  @out;
}

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

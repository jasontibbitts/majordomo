#
use strict;
use Getopt::Std;
use Fcntl;
use Data::Dumper;
require "./setup/query_util.pl";
use vars qw(%opts $mjcfg);

$SIG{__WARN__} = sub {print STDERR "--== $_[0]"};


my %munge = (
	     admin_passwd      => \&fix_passwd,
	     approve_passwd    => undef,
	     debug             => \&fix_debug,
	     digest_archive    => undef,
	     digest_issue      => undef,
	     digest_maxdays    => undef,
	     digest_maxlines   => undef,
	     digest_name       => undef,
	     digest_rm_footer  => undef,
	     digest_rm_fronter => undef,
	     digest_volume     => undef,
	     digest_work_dir   => undef,
	     strip             => undef,
	    );


# Pull in configuration
$mjcfg = eval { require ".mj_config"};

unless ($mjcfg) {
  print STDERR "This program should be run after Majordomo has been installed.\n";
  exit 1;
}

# Check args for directory and list name to convert.
getopts('cd:gm:o:', \%opts);

if ($opts{g}) {
  print STDERR "Conversion of global configuration parameters not yet supported.";
  exit 1;
}

convert_some_lists();

exit 0;

#---- Subroutines

sub convert_some_lists {
  # No parameters; %opts and $mjcfg are globals
  my ($list);

  $opts{d} ||= $mjcfg->{domains}[0];
  $opts{o} ||= $mjcfg->{domain}{$opts{d}}{old_lists_dir};

  unless ($opts{o} && -d $opts{o}) {
    print STDERR "Can't find directory containing old lists.\n";
    exit 1;
  }

  unless (@ARGV) {
    print STDERR "No lists specified for conversion.\n";
    exit 1;
  }

  for $list (@ARGV) {
    unless (-f "$opts{o}/$list") {
      print STDERR "Can't find list $list to convert.\n";
      exit 1;
    }
    unless (-r "$opts{o}/$list") {
      print STDERR "Found old list $list but can't read it.\n";
      exit 1;
    }
  }

  for $list (@ARGV) {
    convert_list($list);
  }
}

sub convert_list {
  my $list = shift;
  my(%config, @args, $editor, $err, $file, $flags, $i, $id, $j, $msg,
     $owner, $pid, $pw, $val, $var);

  print "Converting $list\n";

  # Check to see if list exists already.  Prompt to exit or create it.
  # (Don't want to overwrite existing lists.)  Note that we do the bad
  # thing and just poke inside the list directories directly.
  if (-d "$mjcfg->{lists_dir}/$opts{d}/$list") {
    $msg = <<EOM;
The list $list already exists.  This process can continue, but note that
existing configuration changes may be overwritten.

Continue?
EOM
    return unless get_bool($msg);
  }

  $msg = <<EOM;
What is the email address of the owner of $list?
 In Majordomo1 this was written into the aliases but under Majordomo2 it is
  simply a configuration variable.

EOM
  $owner = get_str($msg);

  # Locate and load old config file.  Convert variables where necessary.
  %config = load_old("$opts{o}/$list.config");

  # Iterate over the keys, performing conversion or deletion if necessary.
  for $i (sort keys %config) {
    if (exists $munge{$i}) {
      if (defined $munge{$i}) {
	warn "munging $i";
	($var, $val) = &{$munge{$i}}($i, $config{$i});
	delete $config{$i};
	$config{$var} = $val;
      }
      else {
	warn "deleting $i";
	delete $config{$i};
      }
    }
  }

  # Figure out what default_flags should be based on reply_to and
  # subject_prefix.
  $flags = 'S';
  if (length $config{reply_to} > 0) {
    $flags .= 'R';
  }
  else {
    $msg = <<EOM;

You do not have the reply_to variable set.  Majordomo2 allows users to
choose to receive messages with a Reply-To: header.  Would you like the
default settings to enable you to turn on reply_to and then allow users to
choose to begin receiving it if they so desire?

EOM
    unless (get_bool($msg, 1)) {
      $flags .= 'R';
    }
  }
  if (length $config{subject_prefix} > 0) {
    $flags .= 'P';
  }
  else {
    $msg = <<EOM;

You do not have the subject_prefis variable set.  Majordomo2 allows users
to choose to receive messages with a subject prefix.  Would you like the
default settings to enable you to set a subject prefix and then allow users
to choose to begin receiving it if they so desire?

EOM
    unless (get_bool($msg, 1)) {
      $flags .= 'P';
    }
  }

  $config{default_flags} = $flags;


  # Produce command file containing createlist command, configset commands
  # and a mass subscribe command (with quiet flags)

  # Open the command file
  $file = "$mjcfg->{wtmpdir}/convertlist.$$";
  sysopen CMD, $file, O_RDWR|O_CREAT|O_EXCL, 0600
    or die "Can't open $file, $!";

  @args = ("$mjcfg->{'install_dir'}/bin/mj_shell", "-d", "$opts{d}", "-F",
	   "-", "-f", "$opts{o}/$list");
#  @args = ("$mjcfg->{'install_dir'}/bin/mj_shell", "-d", "$opts{d}", "-F",
#	   "$file", "-f", "$opts{o}/$list");

  print CMD "# mj_shell will be called with the following arguments:\n";
  print CMD "# @args\n\n";

  # Pull out the password or prompt for it if necessary
  $pw = $mjcfg->{'site_password'};
  unless ($pw) {
    $msg = "What is the site password?\n";
    $pw = get_str($msg);
  }

  print CMD "default password $mjcfg->{site_password}\n";

  print CMD "createlist $list $owner\n";

  $id = 'AA';
  for $i (sort keys %config) {
    if (ref($config{$i}) eq 'ARRAY') {
      print CMD "configset $list $i << END$id\n";
      for $j (@{$config{$i}}) {
	print CMD "$j\n";
      }
      print CMD "END$id\n\n";
      $id++;
    }
    else {
      print CMD "configset $list $i = $config{$i}\n";
    }
  }

  print CMD "\nsubscribe-noinform-nowelcome $list <\@1\n";
  close CMD;


  # Offer to edit it
  $editor = $ENV{EDITOR} || $ENV{VISUAL} || '/bin/vi';
  if (get_bool("Do you want to edit the command file before executing it?\n", 1)) {
    $err = system($editor, $file);
  }

  return if $err && get_bool("The editor indicated an error; continue?\n", 1);

  # Pass it to mj_shell.
  $pid = open(SHELL, "|-");

  if ($pid) {
    # in parent
    open CMD, "<$file";
    while (defined($_ = <CMD>)) {
      print SHELL $_;
    }
    close CMD;
    close CHILD;
  }
  else {
    # in chiild
    exec (@args) or die "Error executing $args[0], $!";
  }

  # Done.
}



sub load_old {
  my $file = shift;
  my (%cf, $key, $op, $val);
  print "Loading $file\n";

  unless (-r $file) {
    print STDERR "$file does not exist or is unreadable; using default configuration.\n";
    return;
  }

  open CF, $file or die "Can't open $file: $!";
  while (defined ($_ = <CF>)) {
    next if /^\s*($|\#)/;
    chomp;
    s/#.*//;
    s/\s+$//;
    ($key, $op, $val) = split(" ", $_, 3);
    $key = lc($key);
    
    if ($op eq "\<\<") {
      $cf{$key} = [];
      while (defined($_ = <CF>)) {
	chomp;
	next unless $_;
	s/^-//;
	last if $_ eq $val;
	push @{$cf{$key}}, $_;
      }
    }
    else {
      $cf{$key} = $val;
    }
  }
  %cf;
}

sub fix_debug {
  my($var, $val) = @_;
  return ($var, 0) if lc($val) eq 'no';
  ($var, 500);
}

sub fix_passwd {
  my($dummy, $val) = @_;
  ('master_password', $val);
}

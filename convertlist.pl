#
use strict;
use Getopt::Std;
use Fcntl;
use Data::Dumper;
require "./setup/query_util.pl";
use vars qw(%opts $mjcfg);

$SIG{__WARN__} = sub {print STDERR "--== $_[0]"};

my %delete = (
	      approve_passwd    => 1,
	      digest_archive    => 1,
	      digest_issue      => 1,
	      digest_maxdays    => 1,
	      digest_maxlines   => 1,
	      digest_name       => 1,
	      digest_rm_footer  => 1,
	      digest_rm_fronter => 1,
	      digest_volume     => 1,
	      digest_work_dir   => 1,
	      mungedomain       => 1,
	      strip             => 1,
	     );

#	     admin_passwd      => \&fix_passwd,
#	     debug             => \&fix_debug,


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

  my(%config, @args, @rest, $aux, $editor, $err, $file, $filecount, $flags,
     $i, $id, $j, $msg, $owner, $pid, $pw, $val, $var);

  $filecount = 1;
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
  load_old("$opts{o}/$list.config", \%config);

  # Iterate over the keys, performing conversion or deletion if necessary.
  for $i (sort keys %config) {
    if ($delete{$i}) {
      warn "deleting $i";
      delete $config{$i};
    }
  }
  munge(\%config);

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

You do not have the subject_prefix variable set.  Majordomo2 allows users
to choose to receive messages with a subject prefix.  Would you like the
default settings to enable you to set a subject prefix and then allow users
to choose to begin receiving it if they so desire?

EOM
    unless (get_bool($msg, 1)) {
      $flags .= 'P';
    }
  }

  $config{default_flags} = $flags;

  if (length $config{mungedomain}) {
    $msg = <<EOM;

The list $list has the mungedomain variable set.  Majordomo2 supports a
mechanism for performing the equivalent functionality and more through the
addr_xforms variable, but note that this variable is set globally, not per
list and so it will not be set here.

Press enter to continue.
EOM
    get_str($msg);
  }

  # Open the command file
  $file = "$mjcfg->{wtmpdir}/convertlist.$$";
  sysopen CMD, $file, O_RDWR|O_CREAT|O_EXCL, 0600
    or die "Can't open $file, $!";

  @args = ("$mjcfg->{'install_dir'}/bin/mj_shell", "-d", "$opts{d}", "-F",
	   "-");

# "-f", "$opts{o}/$list");
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

  # Pick apart the restrict_post variable and build auxlists.
  if (length $config{restrict_post}) {
    @rest = split(/[:,\s]/, $config{restrict_post});
    $config{restrict_post} = [];
    for $i (@rest) {

      # Name of this list: just put it in
      if ($i eq $list) {
	push @{$config{restrict_post}}, $i;
	next;
      }

      # Something that looks like a digest list; ignore it for now
      if ($i eq "$list-digest") {
	next;
      }

      # Something that doesn't look like a separate list.  It might be a
      # file that "lives" under another list, but it's easier to ignore
      # that fact for now.
      if ($i =~ /\.(.*)$/) {
	$msg = <<EOM;

The old restrict_post variable includes: $i.
This does not look like the name of another list, so we can set up an
 auxiliary list and add the contents of this file to it.
Do you want to do this?

EOM
	next unless get_bool($msg, 1);
	$msg = <<EOM;

What do you want to name this auxiliary list?

EOM
	$aux = get_str($i, $1);
	print CMD "auxadd $list $aux <\@$filecount\n";
	$filecount++;
	push @args, ('-f', "$opts{o}/$i");
	push @{$config{restrict_post}}, $aux;
	next;
      }

      # Anything else references another list.  Just warn about it.
      $msg = <<EOM;

The old restrict_post variable includes: $i.

This looks like a separate list, so it will not be automatically placed in
 the new restrict_post variable.  If you had created a separate list for
 this solely to enable the list owner to manage the restriction list
 remotely, then you can just as well use an auxiliary list for that
 purpose.

You will need to do this manually.  Press enter to continue.

EOM
      get_str($msg);
      next;
    }
  }

  # Now dump out the configuration.
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

#   # Pass it to mj_shell.
#   $pid = open(SHELL, "|-");

#   if ($pid) {
#     # in parent
#     open CMD, "<$file";
#     while (defined($_ = <CMD>)) {
#       print SHELL $_;
#     }
#     close CMD;
#     close CHILD;
#     wait $pid;
#   }
#   else {
#     # in chiild
#     exec (@args) or die "Error executing $args[0], $!";
#   }

  unlink $file;

  # Done.
}



sub load_old {
  my($file, $hash) = @_;
  my ($key, $op, $val);
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
      $hash->{$key} = [];
      while (defined($_ = <CF>)) {
	chomp;
	next unless $_;
	s/^-//;
	last if $_ eq $val;
	push @{$hash->{$key}}, $_;
      }
    }
    else {
      $hash->{$key} = $val;
    }
  }
  1;
}

sub munge {
  my $cf = shift;

  if (exists $cf->{debug}) {
    $a = $cf->{debug};
    if (lc($a) eq 'no') {
      $cf->{debug} = 0;
    }
    else {
      $cf->{debug} = 500;
    }
  }

  if (exists $cf->{admin_passwd}) {
    $cf->{master_password} = $cf->{admin_passwd};
    delete $cf->{admin_passwd};
  }

  if (exists $cf->{mungedomain}) {
    $a = $cf->{mungedomain};
    if (lc($a) eq 'yes') {
      push @{$cf->{addr_xforms}}, 'mungedomain';
    }
    delete $cf->{mungedomain};
  }
}

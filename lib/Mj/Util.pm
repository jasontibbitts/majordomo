=head1 NAME

Mj::Util.pm - Various utility functions that don't belong elsewhere

=head1 DESCRIPTION

A set of utility functions that don't belong in other modules.

=head1 SYNOPSIS

blah

=cut

package Mj::Util;
use Mj::Log;
require Exporter;
@ISA = qw(Exporter);
@EXPORT_OK = qw(process_rule str_to_time time_to_str);

use AutoLoader 'AUTOLOAD';

$VERSION = "0.0";
use strict;
use vars(qw(%args %memberof $current $skip));

1;
__END__

=head2 process_rule

Runs an individual rule (from access_rules or bounce_rules) and returns the
result action.

The caller is expected to fill in %memberof and supply appropriate %args
and rules code.  Named arguments:

name - the name of the variable being run (for error string)
code - the actual compiled rule code
args - the arguments for the rule code
memberof - the memberof hash, containing info on what list:sublist pairs
  the user is on.
request - the request that this rule refers to.  For bounce_rules, this
  should be _bounce.  (Used to look up request data from CommandProps.)
current - list of lists indicating whether the current time matches
  a time specification.

=cut
use Safe;
use Mj::CommandProps qw(action_terminal rules_var);
sub process_rule {
  my %params = @_;

  my $log = new Log::In 70;

  my @permitted_ops = qw(
     anonlist  aelem    const  enter  eq
     ge        gt       helem  le
     leaveeval lt       ne     not
     null      pushmark refgen return
     rv2av     rv2sv    seq    sne
    );

  my (@final_actions, $actions, $arg, $cpt, $func, $i, $ok, $saw_terminal, $value);
  local(%args, %memberof, $current, $skip);

  # Initialize the safe compartment
  $cpt = new Safe;
  $cpt->permit_only(@permitted_ops);
  $cpt->share(qw(%args %memberof $current $skip));

  # Set up the shared variables
  %memberof = %{$params{memberof}};
  %args     = %{$params{args}};
  $current  = $params{current} || [];
  $skip     = 0;

  # Run the rule.  Loop until a terminal action is seen
 RULE:
  while (1) {
    $actions = $cpt->reval($params{code});
    warn "Error found when running $params{name} code:\n$@" if $@;

    # The first element of the action array is the ID of the matching
    # rule.  If we have to rerun the rules, we will want to skip to the
    # next one.
    $actions ||= [0, 'ignore'];
    $skip = shift @{$actions};

    # Now go over the actions we received.  We must process 'set' and
    # 'unset' here so that they'll take effect if we have to rerun the
    # rules.  Other actions are pushed into @final_actions.  If we hit a
    # terminal action we stop rerunning rules.
  ACTION:
    for $i (@{$actions}) {
      ($func, $arg) = split(/[=-]/, $i, 2);
      # Remove enclosing parentheses
      if ($arg) {
	$arg =~ s/^\((.*)\)$/$1/;
	$i = "$func-$arg";
      }

      if ($func eq 'set') {
	# Set a variable.
	($arg, $value) = split(/[=-]/, $arg, 2);
	if ($arg and ($ok = rules_var($params{request}, $arg))) {
	  if ($value and $arg eq 'delay') {
	    my ($time) = time;
	    $args{'delay'} = str_to_time($value) || $time + 1;
	    $args{'delay'} -= $time;
	  }
	  elsif ($value and $ok > 1) {
	    $args{$arg} = $value;
	  }
	  else {
	    $args{$arg} ||= 1;
	  }
	}
	next ACTION;
      }
      elsif ($func eq 'unset') {
	# Unset a variable.
	if ($arg and rules_var($params{request}, $arg)) {
	  $args{$arg} = 0;
	}
	next ACTION;
      }
      elsif ($func eq 'reason') {
	if ($arg) {
	  $arg =~ s/^\"(.*)\"$/$1/;
	  $args{'reasons'} = "$arg\002" . $args{'reasons'};
	}
	next ACTION;
      }

      # We'll process the function later.
      push @final_actions, $i;

      $saw_terminal ||= action_terminal($func);
    }

    # We need to stop if we saw a terminal action in the results of the
    # last rule
    last RULE if $saw_terminal;
  }
  for $i (keys %args) {
    $params{'args'}->{$i} = $args{$i};
  }
  @final_actions;
}

=head2 str_to_time(string)

This converts a string to a number of seconds since 1970 began.

=cut
sub str_to_time {
  my $arg = shift;
  my $log = new Log::In 150, $arg;
  my ($time) = 0;

  # Treat a plain number as a count of seconds.
  if ($arg =~ /^(\d+)$/) {
    return time + $arg;
  }

  if ($arg =~ /(\d+)h(ours?)?/) {
    $time += (3600 * $1);
  }
  if ($arg =~ /(\d+)d(ays?)?/) {
    $time += (86400 * $1);
  }
  if ($arg =~ /(\d+)w(eeks?)?/) {
    $time += (86400 * 7 * $1);
  }
  if ($arg =~ /(\d+)m(onths?)?/) {
    $time += (86400 * 30 * $1);
  }
  if ($arg =~ /(\d+)y(ears?)?/) {
    $time += (86400 * 365 * $1);
  }
  if ($time) {
    $time += time;
  }
  else {
    # We try calling Date::Manip::ParseDate
    $time = _str_to_time_dm($arg);
  }
  $time;
}

=head2 _str_to_time_dm(string)

Calls Date::Manip to convert a string to a time; this is in a separate
function because it takes forever to load up Date::Manip.  Autoloading is
good.

This not exported; str_to_time calls it as a fallback when its simple
methods don't work.

=cut
use Date::Manip;
sub _str_to_time_dm {
  my $arg = shift;
  $Date::Manip::PersonalCnf="";
  return UnixDate(ParseDate($arg),"%s");
}

=head2 time_to_str(time)

Converts a time in seconds to an abbreviation.
For example, a time of 90000 seconds
would produce a string "1d1h" (for one day, one hour).

=cut
sub time_to_str {
  my $arg = shift;
  my $long = shift || 0;
  return $long ? "0 hours" : "0h" unless ($arg and $arg > 0);
  my ($i, $out);
  $out = '';

  $i = int($arg / (7 * 86400));
  $arg %= (7 * 86400);
  $out .= $long ? ($i > 1)? "$i weeks " : "1 week " : "${i}w" if $i;
  $i = int($arg / 86400);
  $arg %= (86400);
  $out .= $long ? ($i > 1)? "$i days " : "1 day " : "${i}d" if $i;
  $i = int(($arg + 1800) / 3600);
  $arg %= (3600);
  $out .= $long ? ($i > 1)? "$i hours" : "1 hour" : "${i}h" if $i;
  unless ($out) {
    if ($long) {
      $i = int(($arg + 30) / 60);
      $out = ($i > 1)? "$i minutes" : "1 minute";
    }
    else {
      $out = "0h";
    }
  }

  $out;
}

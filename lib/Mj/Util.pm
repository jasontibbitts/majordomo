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
@EXPORT_OK = qw(ep_convert ep_recognize gen_pw in_clock process_rule 
                re_match str_to_time time_to_str);

use AutoLoader 'AUTOLOAD';

$VERSION = "0.0";
use strict;
use vars(qw(%args %memberof $current $safe $skip));
$Mj::Util::safe = '';

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

=head2 ep_convert (string)

Convert a string to an "encrypted" form.  At present this is
an SHA-1 message digest.

=cut
use Digest::SHA1 qw(sha1_base64);
sub ep_convert {
  my $str = shift || '';
 
  return sha1_base64($str);
}

=head2 ep_recognize (string)

Returns a true or false value, depending upon whether or not a
string appears to be an encrypted password, in this case an
SHA-1 digest.

=cut
sub ep_recognize {
  my $str = shift || '';

  return ($str =~ m#^[A-Za-z0-9+/=]{27}$#);
}

=head2 gen_pw (length)

Generate a password randomly.

The new password will be at least six characters long.

=cut
sub gen_pw {
  my $length = shift || 6;
  $length = 6 if ($length < 6);

  my $log = new Log::In 200;

  my $chr = 'ABCDEFGHIJKLMNPQRSTUVWXYZabcdefghijkmnpqrstyvwxyz23456789';
  my $pw;

  for my $i (1..$length) {
    $pw .= substr($chr, rand(length($chr)), 1);
  }
  $pw;
}

=head2 in_clock(clock, time)

This determines if a given time (defaulting to the current time) falls
within the range of times given in clock, which is expected to be in the
format returned by Mj::Config::_str_to_clock.

A clock is a list of lists:

[
 flag: day of week (w), day of month (m), free date (a)
 start
 end
]

Start and end can be equivalent; since the granularity is one hour, this
gives a range of exactly one hour.

=cut
sub in_clock {
  my $clock = shift;
  my $time  = shift || time;
  my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = localtime($time);
  $mday--; # Clock values start at 0

  for my $i (@$clock) {
    # Handle hour of day
    if ($i->[0] eq 'a') {
      return 1 if $hour  >= $i->[1] && $hour  <= $i->[2];
    }
    elsif ($i->[0] eq 'w') {
      # Handle day/hour of week
      my $whour = $wday*24 + $hour;
      return 1 if $whour >= $i->[1] && $whour <= $i->[2];
    }
    elsif ($i->[0] =~ /^m(\d{0,2})/) {
      # Handle day/hour of month
      unless (length $1 and ($mon + 1 != $1)) {
        my $mhour = $mday*24 + $hour;
        return 1 if $mhour >= $i->[1] && $mhour <= $i->[2];
      }
    }
    elsif ($i->[0] eq 'y') {
      # Handle day/hour of year
      my $yhour = $yday*24 + $hour;
      return 1 if $yhour >= $i->[1] && $yhour <= $i->[2];
    }
    # Else things are really screwed
  }
  # None of the intervals include the time, so no match.
  0;
}

=head2 re_match (pattern, string, arr)

This expects a safe compartment to already be set up, and matches a
string against a regular expression within that safe compartment.  The
special 'ALL' regexp is also accepted, and always matches.

If called in an array context, also returns any errors encountered
while compiling the match code, so that this can be used as a general
regexp syntax checker.

If the optional third argument arr is true, the match is done in an array
context and the match array is returned.

=cut
sub re_match {
  my    $re = shift;
  local $_  = shift;
  my    $arr= shift;
#  my $log  = new Log::In 200, "$re, $_";
  my (@match, $match, $warn);
  return 1 if $re eq 'ALL';

  unless (ref $safe eq 'Safe') {
    eval ("use Safe");
    $safe = new Safe;
    $safe->permit_only(qw(const leaveeval not null pushmark return rv2sv stub));
  }

  # Hack; untaint things.  That's why we're running inside a safe
  # compartment. XXX Try it without the untainting; it has a speed penalty.
  # Routines that need it can untaint as appropriate before calling.
  $_ =~ /(.*)/;
  $_ = $1;
  $re =~ /(.*)/;
  $re = $1;

  if ($arr) {
    # Return the match array
    local($^W) = 0;
    @match = $safe->reval($re);
    return @match;
  }

  local($^W) = 0;
  $match = $safe->reval("$re");
  $warn = $@;
  $::log->message(10, 'info', "re_match error: $warn string: $_\nregexp: $re") 
    if $warn;   #XLANG

  if (wantarray) {
    return ($match, $warn);
  }
#  $log->out('matched') if $match;
  return $match;
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

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

@EXPORT_OK = qw(clean_html condense enriched_to_hyper ep_convert
                ep_recognize find_thread_root gen_pw in_clock n_build
                n_defaults n_validate plain_to_hyper process_rule re_match
                reconstitute reflow_plain shell_hook sort_msgs str_to_bool
                str_to_time str_to_offset time_to_str);

use AutoLoader 'AUTOLOAD';

$VERSION = "0.0";
use strict;
use vars(qw(%args %memberof %notify_var %rt2ht %yes %no @notify_fields $current $safe $skip));
$Mj::Util::safe = '';

%Mj::Util::notify_var =
  (
   'approvals'  => 'integer',
   'attach'     => 'bool',
   'bounce'     => 'integer',
   'chainfile'  => 'filename',
   'expire'     => 'string',
   'file'       => 'filename',
   'fulfill'    => 'bool',
   'group'      => 'string',
   'pool'       => 'integer',
   'remind'     => 'timespan',
  );

@Mj::Util::notify_fields = 
  qw(approvals attach bounce file fulfill group pool remind 
     chainfile expire);

%Mj::Util::rt2ht =
  (
   'bigger'     => '',
   'bold'       => '',
   'center'     => { 
                     'start' => 'p align=center',
                     'end'   => 'p',
                   },
   'color'      => '',
   'excerpt'    => { 
                     'start' => 'blockquote',
                     'end'   => 'blockquote',
                   },
   'fixed'      => '',
   'flushboth'  => { 
                     'start' => 'p align=both',
                     'end'   => 'p',
                   },
   'flushleft'  => { 
                     'start' => 'p align=left',
                     'end'   => 'p',
                   },
   'flushright' => { 
                     'start' => 'p align=right',
                     'end'   => 'p',
                   },
   'fontfamily' => '',
   'italic'     => '',
   'lang'       => '',
   'nofill'     => { 
                     'start' => 'pre',
                     'end'   => 'pre',
                   },
   'paraindent' => { 
                     'start' => 'blockquote',
                     'end'   => 'blockquote',
                   },
   'smaller'    => '',
   'underline'  => '',
  );

# Attempt to be multi-lingual
%Mj::Util::yes = (
        1                => 1,
        'y'              => 1,
        'yes'            => 1,
        'yeah'           => 1,
        'hell yeah'      => 1,
        'si'             => 1,             # Spanish
        'hai'            => 1,             # Japanese
        'ii'             => 1,             # "
        'ha'             => 1,             # Japanese (formal)
        'oui'            => 1,             # French
        'damn straight'  => 1,             # Texan
        'darn tootin'    => 1,
        'shore nuf'      => 1,
        'ayuh'           => 1,             # Maine
        'on'             => 1,
        'true'           => 1,
       );

%Mj::Util::no = (
       ''               => 1,
       0                => 1,
       'n'              => 1,
       'no'             => 1,
       'iie'            => 1,     # Japanese
       'iya'            => 1,
       'hell no'        => 1,     # New Yorker
       'go die'         => 1,
       'nyet'           => 1,
       'nai'            => 1,
       'no way'         => 1,
       'as if'          => 1,
       'in your dreams' => 1,
       'off'            => 1,
       'false'          => 1,
      );

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
     anonlist  aelem    const  enter     eq        ge       
     gt        helem    le     leaveeval lt        ne     
     negate    not      null   pushmark  refgen    return    
     rv2av     rv2sv    seq    sne       stringify
    );

  my (@final_actions, @replies, $actions, $arg, $cpt, $func, $i, 
      $ok, $saw_terminal, $value);
  local (%args, %memberof, $current, $skip);

  # Initialize the safe compartment
  $cpt = new Safe;
  $cpt->permit_only(@permitted_ops);
  $cpt->share(qw(%args %memberof $current $skip));

  # Set up the shared variables
  %memberof = %{$params{memberof}};
  %args     = %{$params{args}};
  $current  = $params{current} || [];
  $skip     = 0;
  $saw_terminal = 0;

  # Run the rule.  Loop until a terminal action is seen
 RULE:
  while (1) {
    $actions = $cpt->reval($params{code});
    # XLANG
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
          # set=varname should set a boolean variable to a true value
          # if no value is supplied explicitly.
          if ($ok eq 'bool' and ! defined $value) {
            $value = 1;
          }
	  if ($value and ($ok eq 'timespan')) {
	    my ($time) = time;
	    $args{$arg} = str_to_time($value) || $time + 1;
	    $args{$arg} -= $time;
	  }
	  elsif ($value and ($ok ne 'bool')) {
	    $args{$arg} = $value;
	  }
	  else {
            # obtain boolean value with double-negation.
	    $args{$arg} = !!$value;
	  }
	}
      }
      elsif ($func eq 'unset') {
	# Unset a variable.
	if ($arg and ($ok = rules_var($params{request}, $arg))) {
          if ($ok eq 'bool') {
            $args{$arg} = 0;
          }
          else {
            $args{$arg} = '';
          }
	}
      }
      elsif ($func eq 'notify') {
        push @{$args{'notify'}}, $arg;
      }
      elsif ($func eq 'reason') {
	if ($arg) {
	  $arg =~ s/^\"(.*)\"$/$1/;
	  $args{'reasons'} = "$arg\003" . $args{'reasons'};
	}
      }
      elsif ($func eq 'reply' or $func eq 'replyfile') {
        # Replies should always be run last, to prevent
        # being overridden by default files for terminal
        # actions.
        push @replies, $i;
      }
      else {
        # We'll process the function later.
        push (@final_actions, $i) unless ($i eq 'ignore');
      }

      $saw_terminal ||= action_terminal($func);
    }

    # We need to stop if we saw a terminal action in the results of the
    # last rule
    last RULE if $saw_terminal;
  }
  for $i (keys %args) {
    $params{'args'}->{$i} = $args{$i};
  }
  unless ($saw_terminal) { 
    # Make certain that a terminal action is present.
    unshift @final_actions, 'default';
  }
  if (scalar @replies) {
    push @final_actions, @replies;
  }
  @final_actions;
}

=head2 n_build(notify, default1, default2)

Create a notification hashref using an access rule and 
default values.

=cut
sub n_build {
  my ($notify, $d1, $d2) = @_;
  my ($i, $j, $r, $result, $rule, $s, $use_d2);
  my $log = new Log::In 350;

  $d2 ||= '';
  unless (ref($d2) eq 'HASH') {
    $use_d2 = -1;
  }
  else {
    $use_d2 = 0;
  }

  $s = $d1;
  $result = [];

  # Use the default values to fill in each element of the
  # notify array.  Use the d2 defaults for the 2nd and succeeding 
  # elements if d2 was supplied.
  for ($i = 0; $i < scalar @$notify ; $i++) {

    # Turn each rule into a hashref.
    $r = n_validate($notify->[$i]);
    unless (defined($r) and ref $r eq 'HASH') {
      $log->message(1, 'info', "_build_notify error: $r");
      $r = {};
    }

    # Supply default values for missing elements.
    for $j (keys %notify_var) {
      unless (exists $r->{$j}) {
        $r->{$j} = $s->{$j};
      }
    }
    $result->[$i] = $r;

    # use Data::Dumper;  $log->message(1, 'debug', Dumper $r);

    # Use the second set of defaults for succeeding rules. 
    if ($i == 1 and $use_d2 == 0) {
      $s = $d2;
    }
  }

  # If there are no valid notify directives, add the default values
  # immediately and return.
  unless (ref($notify) eq 'ARRAY' and scalar @$notify) {
    push (@$result, $d1) if (ref $d1 eq 'HASH');
  }
  unless (ref($notify) eq 'ARRAY' and (scalar(@$notify) > 1)) {
    push (@$result, $d2) if (ref $d2 eq 'HASH');
  }

  $result;
}

=head2 n_defaults(type, command)

Construct a hashref of default values corresponding to
the way a request is held (confirm, consult, or delay).

=cut
sub n_defaults {
  my ($type, $command) = @_;
  my ($defaults);

  $command =~ s/_(start|chunk|done)$//;

  $defaults = {
                'approvals'     => 1,
                'attach'        => 0,
                'bounce'        => 1,
                'chainfile'     => 'repl_confirm',
                'expire'        => -1,
                'file'          => 'confirm',
                'fulfill'       => 0,
                'group'         => 'victim',
                'pool'          => -1,
                'remind'        => -1,
              };

  if ($type eq 'consult') {
    $defaults->{'attach'} = 1 if ($command && $command eq 'post');
    $defaults->{'bounce'} = 0;
    $defaults->{'chainfile'} = 'repl_chain';
    $defaults->{'file'}   = 'consult';
    $defaults->{'group'}  = 'moderators';
  }
  elsif ($type eq 'delay') {
    $defaults->{'bounce'}  = 0;
    $defaults->{'chainfile'} = 'repl_delay';
    $defaults->{'file'}    = 'delay';
    $defaults->{'fulfill'} = 1;
  }
  elsif ($type eq 'probe') {
    $defaults->{'attach'} = 1;
    $defaults->{'bounce'} = -1;
    $defaults->{'file'}   = 'bounceprobe';
    $defaults->{'remind'} = 0;
  }

  $defaults;
}

=head2 n_validate(rule)

Validate the contents of a "notify" action in an access rule.
Returns a hashref containing the values

=cut
sub n_validate {
  my $str = shift || '';
  my (@grp, @tmp, $i, $mess, $ok, $struct, $tmp, $var, $val);
  my $log = new Log::In 350, $str;

  @grp = ('moderators', 'none', 'requester', 'victim');
  $mess = '';
  $struct = {};

  @tmp = split /\s*,\s*/, $str;

  for $i (@tmp) {
    if ($i =~ /^([^=]+)=([^=]+)$/) {
      $var = $1;
      $val = $2;
      unless (exists $notify_var{$var}) {
        $tmp = join " ", sort(keys(%notify_var));
        return (0, qq(The variable "$var" was not recognized.\n) .
                   qq(Supported variables include:\n  $tmp\n));
      }
      if ($notify_var{$var} eq 'timespan') {
        $val = str_to_time($val);
        $val -= time;
      }
      $struct->{$var} = $val;
    }
    elsif ($i =~ /^[\w.-]+$/) {
      # most likely a group name
      unless (grep {$_ eq $i} @grp) {
        $mess .= qq(Make sure that the auxiliary list "$i" exists.\n);
      }
      $struct->{'group'} = $i;
    }
    else {
      return (0, qq(The notify variable "$i" was not recognized.));
    }
  }

  if (length $mess) {
    return (-1, $mess, $struct);
  }
  return (1, '', $struct);
}

=head2 condense(datahash, fieldlist)

Convert a hashref of data to packed form.

=cut
sub condense {
  my ($data, $fields, $sep) = @_;
  my (@tmp, $field, $str, $word);
  $sep = "\002" unless (defined $sep);

  return unless (ref($data) eq 'HASH' and ref($fields) eq 'ARRAY');

  for $field (@$fields) {
    $word = $data->{$field};
    $word = '' unless (defined $word);
    $word =~ s/$sep/ /g if (length $sep);
    push @tmp, $word;
  }

  $str = join $sep, @tmp;
}
    
=head2 reconstitute(string, fieldlist)

Convert a packed data string into a hashref

=cut
sub reconstitute {
  my ($str, $fields, $sep) = @_;
  my (@tmp, $data, $i);
  $sep = "\002" unless (defined $sep);

  return unless (ref($fields) eq 'ARRAY');

  $i = 0;
  $data = {};
  @tmp = split $sep, $str;
  for ($i = 0; $i < scalar(@tmp) ; $i++) {
    $data->{$fields->[$i]} = $tmp[$i];
  }

  $data;
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
    $safe->permit_only(qw(const leaveeval not null pushmark 
                          return rv2sv stub));
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

=head2 str_to_offset(string)

This converts a string to a number of seconds.  If it doesn''t recognize the
string, it will return undef.

=cut
sub str_to_offset {
  my $arg       = shift;
  my $future    = shift || 0;
  my $as_string = shift || 0;
  my $basetime  = shift || time;
  my $log = new Log::In 150, $arg;
  my (@days, @desc, @lt, $cal, $elapsed, $i, $leapyear, $time, $tmp);

  return unless (defined($arg) and $arg =~ /\S/);
 
  @lt = localtime($basetime);

  # Seconds that have elapsed so far today.
  $elapsed = $lt[0] + $lt[1] * 60 + $lt[2] * 3600;

  # Is this a leap year?  Determine the number of days per month
  $tmp = $lt[5];
  $leapyear = 1;
  @days = (31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
  if ($tmp % 4 or ! $tmp % 400) {
    $leapyear = 0;
    $days[1] = 28;
  }
  
  # Treat a plain number as a count of seconds.
  if ($arg =~ /^(\d+)$/) {
    $tmp = ($arg > 1) ? "s" : "";
    return ($as_string) ? "$arg second$tmp" : $arg;
  }

  if ($arg =~ /(\d+)s(econds?)?/) {
    $time += $1;
    $tmp = ($1 > 1) ? "s" : "";
    unshift @desc, "$1 second$tmp";
  }
  if ($arg =~ /(\d+)mi(nutes?)?/) {
    $time += 60 * $1;
    $tmp = ($1 > 1) ? "s" : "";
    unshift @desc, "$1 minute$tmp";
  }
  if ($arg =~ /(\d+)h(ours?)?/) {
    $time += (3600 * $1);
    $tmp = ($1 > 1) ? "s" : "";
    unshift @desc, "$1 hour$tmp";
  }
  if ($arg =~ /(\d+)d(ays?)?/) {
    $time += (86400 * $1);
    $tmp = ($1 > 1) ? "s" : "";
    unshift @desc, "$1 day$tmp";
  }
  if ($arg =~ /(\d+)w(eeks?)?/) {
    $time += (86400 * 7 * $1);
    $tmp = ($1 > 1) ? "s" : "";
    unshift @desc, "$1 week$tmp";
  }
  if ($arg =~ /(\d+)m(onths?)?([^i]|$)/) {
    $time += (86400 * 30 * $1);
    $tmp = ($1 > 1) ? "s" : "";
    unshift @desc, "$1 month$tmp";
  }
  if ($arg =~ /(\d+)y(ears?)?/) {
    $time += (86400 * 365 * $1);
    $tmp = ($1 > 1) ? "s" : "";
    unshift @desc, "$1 year$tmp";
  }

  $cal = 0;
  if ($arg =~ /(\d+)c(alendar)?d(ays?)?/) {
    if ($1) {
      if ($future) {
        # from the beginning of the day.
        $time -= $elapsed;
      }
      else {
        # from the end of the day.
        $time -= 86400 - $elapsed;
      }
    }
    $time += (86400 * $1);
    $tmp = ($1 > 1) ? "s" : "";
    unshift @desc, "$1 calendar day$tmp";
    $cal = 1;
  }
  if ($arg =~ /(\d+)c(alendar)?w(eeks?)?/) {
    if ($1) {
      if ($future) {
        # from the beginning of the week.
        $time -= $elapsed + $lt[6] * 86400;
      }
      else {
        # from the end of the week.
        $time -= 86400 - $elapsed + (6 - $lt[6]) * 86400;
      }
    }
    $time += (86400 * 7 * $1);
    $tmp = ($1 > 1) ? "s" : "";
    unshift @desc, "$1 calendar week$tmp";
    $cal = 1;
  }
  if ($arg =~ /(\d+)c(alendar)?m(onths?)?/) {
    if ($1) {
      if ($future) {
        # from the beginning of the month.
        $time -= $elapsed + ($lt[3] - 1) * 86400;
      }
      else {
        # from the end of the month.
        $time -= 86400 - $elapsed + ($days[$lt[4]] - $lt[3]) * 86400;
      }
    }

    for ($i = $1; $i > 0; $i--) {
      if ($future) {
        $tmp = ($lt[4] + $i) % 12;
      }
      else {
        $tmp = ($lt[4] - $i) % 12;
      }
      $time += (86400 * $days[$tmp]);
    }
    $tmp = ($1 > 1) ? "s" : "";
    unshift @desc, "$1 calendar month$tmp";
    $cal = 1;
  }
  if ($arg =~ /(\d+)c(alendar)?y(ears?)?/) {
    if ($1) {
      if ($future) {
        # beginning of the year.
        $time -= $elapsed + $lt[7] * 86400;
      }
      else {
        # end of the year.
        $time -= 86400 - $elapsed + (365 + $leapyear - $lt[7]) * 86400;
      }
    }
    for ($i = $1; $i > 0; $i--) {
      if ($future) {
        $tmp = $lt[5] + $i + 1899;
      }  
      else {
        $tmp = $lt[5] - $i + 1901;
      }

      if ($tmp % 4 or ! $tmp % 400) {
        $time += (86400 * 365);
      }
      else {
        $time += (86400 * 366);
      }
    }
    $tmp = ($1 > 1) ? "s" : "";
    unshift @desc, "$1 calendar year$tmp";
    $cal = 1;
  }

  if ($arg =~ /(\d+)(am|pm)/i) {
    $tmp = $1;
    $i = $2;
    push @desc, "at $1 $2";
    $tmp = 12 if ($tmp > 12);
    $tmp = 0 if ($tmp == 12);
    $tmp += 12 if ($i =~ /pm/i);

    if ($cal) {
      if ($future) {
        $time += $tmp * 3600;
      }
      else {
        $time += (24 - $tmp) * 3600;
      }
    }
    else {
      if ($future) {
        $i = ($tmp - $lt[2]) * 3600 -  $lt[1] * 60 - $lt[0];
      }
      else {
        $i = ($lt[2] - $tmp) * 3600 + $lt[1] * 60 + $lt[0];
      }
      $i += 86400 if ($i < 0);
      $time += $i;
    }
  }

  unless (defined $time) {
    # We try calling Date::Manip::ParseDate
    $time = _str_to_time_dm($arg);
    $time -= time if (defined $time);
  }

  if ($as_string) {
    join(" ", @desc);
  }
  else {
    $time;
  }
}

=head2 str_to_time(string)

This converts a string to a number of seconds since 1970 began.


=cut
sub str_to_time {
  my $arg = shift;
  my $log = new Log::In 150, $arg;
  my $time = &str_to_offset($arg, 1);

  $time += time if (defined $time);
  return $time;
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

=head2 str_to_bool(string)

This function attempts to determine if a string represents
a positive or negative value.  It returns 1 for positive
values, 0 for negative values, and -1 for unknown values.

=cut
sub str_to_bool {
  my $str = shift;

  return 0 unless (defined $str);
  return 1 if ($yes{$str});
  return 0 if ($no{$str});
  return -1;
}

=head2 enriched_to_hyper(text_file)

This function converts a file from enriched text to HTML
without regard for fonts or colors. 

=cut
use Mj::FileRepl;
sub enriched_to_hyper {
  my $txtfile = shift;
  my $log = new Log::In 350;
  return unless (-f $txtfile);

  my ($et, $line, $repl, $st, $tag, $tmp);
  
  $repl = new Mj::FileRepl($txtfile);
  return unless ($repl);

  while (defined($line = $repl->{'oldhandle'}->getline)) {
    # Convert blank lines into paragraphs.
    if ($line =~ /^\s*$/) {
      $repl->{'newhandle'}->print("<p>\n");
      next;
    }

    # Delete parameter values.
    $line =~ s#<param>[^<]*</param>##i;
    $line =~ s/&/&amp;/g;
    $line =~ s/"/&quot;/g;
    $line =~ s/<</&lt;/g;

    # Replace tags.
    for $tag (keys %rt2ht) {
      if (ref $rt2ht{$tag} eq 'HASH') {
        $line =~ s#<$tag>#<$rt2ht{$tag}->{'start'}>#gi;
        $line =~ s#</$tag>#</$rt2ht{$tag}->{'end'}>#gi;
      }
      else {
        $line =~ s#<(/)?$tag>##gi;
      }
    }
    $repl->{'newhandle'}->print($line);
  }

  $repl->commit;
}

=head2 plain_to_hyper(text_file)

This function converts a plain text file into a simple HTML file.

=cut
use Mj::FileRepl;
use Mj::Format;
sub plain_to_hyper {
  my $txtfile = shift;
  my $log = new Log::In 350;
  return unless (-f $txtfile);

  my ($line, $repl);
  
  $repl = new Mj::FileRepl($txtfile);
  return unless ($repl);
  
  while (defined($line = $repl->{'oldhandle'}->getline)) {
    if ($line =~ /^\s*$/) {
      $repl->{'newhandle'}->print("<p>\n");
    }
    else {
      $repl->{'newhandle'}->print("<br>" . Mj::Format::escape($line));
    }
  }

  $repl->commit;
}

=head2 clean_html (file, attributes, elements, tags)

This function removes unwanted elements and attributes from 
an HTML file.

=cut
use Mj::FileRepl;
use HTML::Parser;
sub clean_html {
  my ($file, $attr, $elem, $tags) = @_;
  my $log = new Log::In 350;
  my ($line, $parser, $repl);

  return unless (-f $file);
  return unless ((ref $elem eq 'ARRAY' and scalar @$elem) or
                 (ref $attr eq 'ARRAY' and scalar @$attr) or
                 (ref $tags eq 'ARRAY' and scalar @$tags));

  
  $repl = new Mj::FileRepl($file);
  return unless $repl;

  # Ideas borrowed from HTML::Parser example code.
  $parser = 
    HTML::Parser->new(
      api_version     => 3,
      start_h         => [
                          sub {
                            my ($pos, $text) = @_;
                            my ($changes, $key, $key_len, $key_off, 
                                $next, $val_len, $val_off);
                            $changes = 0;

                            while (scalar @$pos >= 4) {
                              ($key_off, $key_len, $val_off, $val_len) 
                                = splice @$pos, -4;
                              $key = lc substr($text, $key_off, $key_len);
                              last unless (length $key);

                              # Find position of next attribute
                              if ($val_off) {
                                $next =  $val_off + $val_len;
                              }
                              else {
                                $next =  $key_off + $key_len;
                              }

                              if (grep {lc $_ eq $key} @$attr) {
                                substr($text, $key_off, $next - $key_off) = "";
                                $changes++;
                              }
                            }

                            # Remove trailing white space
                            $text =~ s/^(<\w+)\s+>$/$1>/ if $changes;
                            $repl->{'newhandle'}->print($text);
                          },
                          "tokenpos, text",
                         ],
      comment_h       => ["", ""],
      declaration_h   => [
                          sub {
                            my ($type, $text) = @_;
                            $repl->{'newhandle'}->print($text)
                              if $type eq "doctype";
                          },
                          "tagname, text",
                         ],
      default_h       => [
                          sub { 
                            my $text = shift;
                            $repl->{'newhandle'}->print($text);
                          },  
                          "text"
                         ],
      process_h       => ["", ""],
      ignore_tags     => $tags,
      ignore_elements => $elem,
    );

  return unless $parser;
  return unless $parser->parse_file($repl->{'oldhandle'});

  $repl->commit;
}

=head2 reflow_plain(text_file, width, long_lines_only)

This function uses the Text::Reflow module to reformat a body part.
Quoted parts of messages are taken into account.

The width of the formatted text will be no longer than "width," which is
72 characters by default.  Indented paragraphs and separators will not
be altered.

If long_lines_only is set, only paragraphs with lines longer than the
width will be reformatted; otherwise, all unindented paragraphs will
be reformatted.

=cut
use Mj::FileRepl;
use Text::Reflow qw(reflow_array);
sub reflow_plain {
  my $txtfile = shift;
  my $width = shift || 72;
  my $llo = shift || 0;
  my $log = new Log::In 350, "$txtfile, $width";
  return unless (-f $txtfile);

  my (@lines, $i, $line, $long, $oq, $out, $qb, $qc, $quote, 
      $quotepattern, $repl, $separator, $size);
  
  $repl = new Mj::FileRepl($txtfile);
  return unless ($repl);
  
  # Quote patterns based upon Text::Autoformat.
  $qc = qq/[|:-]/;
  $qb = qq/(?:$qc(?![a-z])|[a-z]*>+)/;
  $quotepattern = qq/(?:(?i)(?:$qb(?:[ \\t]*$qb)*))/;
  $separator = q/(?:[-_]{2,}|[=#*]{3,}|[+~]{4,})/;
  $quote = $oq = '';
  $long = 0;

  while (defined($line = $repl->{'oldhandle'}->getline)) {
    $line =~ s/[ \t]+$//;
    $size = length($line);
    $line =~ s/^\s*($quotepattern\s?)//i;
    $quote = $1 || '';

    # A separator or quote change will cause all stored lines to
    # be reformatted and printed.
    if ($line =~ /^\s*$separator$/ or $line =~ /^\s*$/ or ($quote ne $oq)) {
      if (scalar(@lines)) {
        # reflow if the paragraph contained a long line, or
        # if the long_lines_only option is turned off.
        if ($long or !$llo) {
          $out = reflow_array(\@lines, 'maximum' => $width, 
                              'indent' => $oq, 'frenchspacing' => 'y',
                              'noreflow' => '\S(\t|    )');
        }
        else {
          map { $_ = $oq . $_ } @lines;
          $out = \@lines;
        }

        for $i (@$out) {
          $repl->{'newhandle'}->print($i);
        }
      }

      $long = 0;
      # Print separators without modification.
      if ($quote eq $oq) {
        $repl->{'newhandle'}->print("$quote$line");
        @lines = ();
      }
      else {
        @lines = ($line);
        $long = 1 if ($size > $width);
      }
    }
    else {
      push @lines, $line;
      $long = 1 if ($size > $width);
    }

    $oq = $quote;
  }

  # Reformat any leftover lines.
  if ($long or !$llo) {
    $out = reflow_array(\@lines, 'maximum' => $width, 'indent' => $oq,
                        'frenchspacing' => 'y', 
                        'noreflow' => '\S(\t|    )');
  }
  else {
    map { $_ = $oq . $_ } @lines;
    $out = \@lines;
  }

  for $i (@$out) {
    $repl->{'newhandle'}->print($i);
  }

  $repl->commit;
}

sub sort_msgs {
  my ($msgs, $mode, $re_pattern) = @_;
  return unless (ref($msgs) eq 'ARRAY' and scalar(@$msgs));
  my (@msgs, @refs, $ct, $data, $i, $j, $key, $order, $re_mods, $subj);
  my $log = new Log::In 350, $mode;

  @msgs = @$msgs;
  if ($mode =~ /author/) {
    for ($i = 0 ; $i <= $#msgs; $i++) {
      $msgs[$i]->[1]->{'from'} = lc $msgs[$i]->[1]->{'from'};
    }
    @msgs = sort {
                   lc $a->[1]->{'from'} cmp lc $b->[1]->{'from'};
                 } @msgs;
  }
  elsif ($mode =~ /date/) {
    @msgs =
      sort { $a->[1]->{'date'} <=> $b->[1]->{'date'} } @msgs;
  }
  elsif ($mode =~ /subject/) {
    $re_pattern =~ s!^/(.*)/([ix]*)$!$1!;
    $re_mods = $2 || '';
    $re_mods .= 's';

    for ($i = 0 ; $i <= $#msgs; $i++) {
      (undef, $j) =
        re_match("/^($re_pattern)?\\s*(.*)\$/$re_mods",
                 $msgs[$i]->[1]->{'subject'}, 1);
      $msgs[$i]->[1]->{'Subject'} = $j;
    }

    @msgs = 
      sort {
             $a->[1]->{'Subject'} cmp $b->[1]->{'Subject'};
           } @msgs;
  }
  elsif ($mode =~ /thread/) {
    eval ("use Mj::Util qw(find_thread_root);");
    $ct = 0; 
    $order = length(scalar(@msgs));
    $subj = {};
    $re_pattern =~ s!^/(.*)/([ix]*)$!$1!;
    $re_mods = $2 || '';
    $re_mods .= 's';

    for $i (@msgs) {
      if (defined ($i->[1]->{'msgid'})) {
        $key = $i->[1]->{'msgid'};
      }
      else {
        $key = $i->[0];
      }
      @refs = split ("\002", $i->[1]->{'refs'});
      $j = $i->[1]->{'subject'};
      (undef, $j) =
        re_match("/^($re_pattern)?\\s*(.*)\$/$re_mods", $j, 1);
     
      $data->{$key} = 
        {
         'posn' => sprintf ("%.${order}d", $ct),
         'refs' => [ @refs ],
         'subject' => $j,
        };
      $ct++;
    }
    for $i (sort { 
                   $data->{$a}->{'posn'} cmp $data->{$b}->{'posn'} 
                 } keys %$data) {
      &find_thread_root($data, $i, [], $subj);
    }

    @msgs =
      sort {
            my ($k1, $k2);
            if (defined ($a->[1]->{'msgid'})) {
              $k1 = $a->[1]->{'msgid'};
            }
            else {
              $k1 = $a->[0];
            }
            if (defined ($b->[1]->{'msgid'})) {
              $k2 = $b->[1]->{'msgid'};
            }
            else {
              $k2 = $b->[0];
            }

            if ($data->{$k1}->{'root'} eq $data->{$k2}->{'root'}) {
              return ($data->{$k1}->{'level'} cmp
                      $data->{$k2}->{'level'});
            }
            else {
              return ($data->{$k1}->{'root'} cmp
                      $data->{$k2}->{'root'});
            }
      } @msgs;
  }

  if ($mode =~ /reverse/) {
    @msgs = reverse @msgs;
  }

  @msgs;
}

=head2 find_thread_root(msgs, id, seen, subj)

This function finds a reference/subject-based thread root within
a collection of messages.  Previously seen messages are recorded
to prevent cycles.  The message "root" (top of the thread) and
"level" (path of the thread) are recorded in a way that makes the
result easy to sort lexically.

=cut
sub find_thread_root {
  my ($msgs, $id, $seen, $subj) = @_;
  my ($curl, $curr, $i, $l, $r, $s);
  return ("-1", 0) unless (exists $msgs->{$id});

  $s = $msgs->{$id}->{'subject'};

  if (exists $msgs->{$id}->{'root'}) {
    # fall through
  }
  elsif (grep { $_ eq $id } @$seen) {
    return ("-1", 0);
  }
  elsif (! scalar @{$msgs->{$id}->{'refs'}}) {
    if (exists $subj->{$s}) {
      $msgs->{$id}->{'root'} = $msgs->{$subj->{$s}}->{'root'};
      $msgs->{$id}->{'level'} = $msgs->{$subj->{$s}}->{'level'} . "Z";
    }
    else {
      $msgs->{$id}->{'root'} = "$msgs->{$id}->{'posn'}";
      $msgs->{$id}->{'level'} = "0";
    }
  }
  else {
    $curl = "0"; $curr = $msgs->{$id}->{'posn'};
    for $i (@{$msgs->{$id}->{'refs'}}) {
      next if ($i eq $id);
      ($r, $l) = &find_thread_root($msgs, $i, $seen, $subj);
      next if ($r eq "-1");
      if ($curl eq '0' or
          ($r lt $curr) or ($r eq $curr and $l gt $curl)) {
        $curr = "$r";
        $curl = "$l";
      }
    }
    $msgs->{$id}->{'root'} = "$curr";
    $msgs->{$id}->{'level'} = "$curl" . $msgs->{$id}->{'posn'};
  }

  unless (exists $subj->{$s}) {
    $subj->{$s} = "$id";
  }
  push @$seen, $id;
  return ($msgs->{$id}->{'root'}, $msgs->{$id}->{'level'});
}

=head2 shell_hook

Implements a method of adding hooks implemented with shell scripts.

In this, the simplest incarnation, we just look for an executable with a
given name in a known location.  The environment needs to be sanitized.

Argument passing needs to go via the environment.  Input to the script
should go via the environment, command line, or a file in a known location.
Output can go via the script's stdout.  Note that command line and
environment are not secure channels; they can be seen by third parties just
by running ps (at least with some operating systems).

Takes named arguments:

name: the name of the hook, used to determine what script to exec

env: hash of environment variables.  These are the only variables the
  process will see, unless it's a shell script and the shell adds its own.

actsub: a subroutine to be called once per line of returned output from the
  script.

cmdargs: array of command line arguments to pass

Could add attempts at calling scripts with domain and possibly list name
appended.

=cut

use Symbol;
sub shell_hook {
  my %args = @_;
  my $log  = new Log::In 120, "$args{name}";
  my($fh, $pid, $scriptdir, $scriptname);

  # Make sure the script exists

  # XXX Ouch!  This is nasty
  $scriptdir  = "$::LIBDIR/../scripts";
  $scriptname = "$scriptdir/$args{name}";
  return unless -x "$scriptname";

  $args{env}     = {} unless $args{env};
  $args{cmdargs} = [] unless $args{cmdargs};

  # Do the fork/exec
  $fh  = gensym();
  $pid = open($fh, "-|");
  if ($pid) { # parent
    while (<$fh>) { &{$args{actsub}}($_) if $args{actsub}; };
    close $fh or warn "Error $? when closing script";
  }
  else { # child
    local %ENV = %{$args{env}};
    exec("$scriptname", @{$args{cmdargs}}) || exit;
  }
}

=head1 COPYRIGHT

Copyright (c) 2000-2001 Jason Tibbitts for The Majordomo Development
Group.  All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the license detailed in the LICENSE file of the
Majordomo2 distribution.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the Majordomo2 LICENSE file for
more detailed information.

=cut

1;
#^L
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

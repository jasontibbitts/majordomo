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
@EXPORT_OK = qw(condense enriched_to_hyper ep_convert ep_recognize 
                gen_pw in_clock n_build n_defaults n_validate 
                plain_to_hyper process_rule re_match reconstitute
                reflow_plain str_to_time time_to_str);

use AutoLoader 'AUTOLOAD';

$VERSION = "0.0";
use strict;
use vars(qw(%args %memberof %notify_var %rt2ht $current $safe $skip));
$Mj::Util::safe = '';

%Mj::Util::notify_var =
  (
   'approvals'  => 'integer',
   'attach'     => 'bool',
   'bounce'     => 'integer',
   'file'       => 'string',
   'fulfill'    => 'bool',
   'group'      => 'string',
   'pool'       => 'integer',
   'remind'     => 'timespan',
  );

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
     anonlist  aelem    const  enter  
     eq        ge       gt     helem  le
     leaveeval lt       ne     not
     null      pushmark refgen
     return    rv2av    rv2sv  seq    sne
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
	next ACTION;
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
	next ACTION;
      }
      elsif ($func eq 'notify') {
        push @{$args{'notify'}}, $arg;
	next ACTION;
      }
      elsif ($func eq 'reason') {
	if ($arg) {
	  $arg =~ s/^\"(.*)\"$/$1/;
	  $args{'reasons'} = "$arg\003" . $args{'reasons'};
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

=head2 n_defaults(type)

Construct a hashref of default values corresponding to
the way a request is held (confirm, consult, or delay).

=cut
sub n_defaults {
  my ($type, $command) = @_;
  my ($defaults);

  $defaults = {
                'approvals'     => 1,
                'attach'        => 0,
                'bounce'        => 1,
                'file'          => 'confirm',
                'fulfill'       => 0,
                'group'         => 'victim',
                'pool'          => -1,
                'remind'        => -1,
              };

  if ($type eq 'consult') {
    $defaults->{'attach'} = 1 if $command && $command eq 'post';
    $defaults->{'bounce'} = 0;
    $defaults->{'file'}   = 'consult';
    $defaults->{'group'}  = 'moderators';
  }
  elsif ($type eq 'delay') {
    $defaults->{'bounce'}  = 0;
    $defaults->{'file'}    = 'delay';
    $defaults->{'fulfill'} = 1;
  }
  elsif ($type eq 'probe') {
    $defaults->{'attach'} = 1;
    $defaults->{'bounce'} = -1;
    $defaults->{'file'}   = 'bounceprobe';
  }

  $defaults;
}

=head2 n_validate(rule)

Validate the contents of a "notify" action in an access rule.
Returns a hashref containing the values

=cut
sub n_validate {
  my ($str) = shift;
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

=head2 str_to_time(string)

This converts a string to a number of seconds since 1970 began.


=cut
sub str_to_time {
  my $arg = shift;
  my $log = new Log::In 150, $arg;
  my $time = 0;

  # Treat a plain number as a count of seconds.
  if ($arg =~ /^(\d+)$/) {
    return time + $arg;
  }

  if ($arg =~ /(\d+)s(econds?)?/) {
    $time += $1;
  }
  if ($arg =~ /(\d+)mi(nutes?)?/) {
    $time += 60 * $1;
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
use Mj::Format qw(escape);
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
      $repl->{'newhandle'}->print("<br>" . &escape($line));
    }
  }

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

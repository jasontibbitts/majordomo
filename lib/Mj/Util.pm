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
@EXPORT_OK = qw(process_rule);

#use AutoLoader 'AUTOLOAD';

$VERSION = "0.0";
use strict;
use vars(qw(%args %memberof $current $skip));

1;
#__END__

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
	$i = "$func=$arg";
      }

      if ($func eq 'set') {
	# Set a variable.
	($arg, $value) = split(/[=-]/, $arg, 2);
	if ($arg and ($ok = rules_var($params{request}, $arg))) {
	  if ($value and $arg eq 'delay') {
	    my ($time) = time;
	    $args{'delay'} = Mj::List::_str_to_time($value) || $time + 1;
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

=head1 NAME

Mj::Log - A simple timing oriented logging system, used in Majordomo

=head1 SYNOPSIS

Require (or use) this package:

  require Mj::Log;

Allocate a Log object:

  $log = new Mj::Log;

Add a logging destination:

  $id = $log->add(
    method      => 'syslog',
    id          => 'blah',
    level       => 500,
    subsystem   => 'mail',
    log_entries => 1,
    log_exits   => 1,
    log_args    => 1,
  );

Log a subroutine:
  
  $log->in(50);
  # Do stuff
  $log->out;

Log a message:

  $log->message(50, "mail", "blah, blah");

Log destinations are closed at destroy time, or you can explicitly delete()
them.

=head1 DESCRIPTION

A logging package featuring multiple logging destinations and the
generation of exact timings.  Timed sections of code are wrapped in a
$log->in - $log->out pair and timings are automatically generated and sent
to a set of destinations.  Support for logging levels is implemented, with
various levels being sent to various logging destinations.

Support for directing various intervals of levels to various destinations
is planned, if it can be done without serious speed penalty.
Set::IntegerRange will be used.

=cut

require 5.003_19;
package Mj::Log;

# This gets Time::HiRes if available, or uses crappy resolution timers if
# not
BEGIN {eval {require Time::HiRes; import Time::HiRes qw(time);}}

# Pragmas
use strict;
use vars qw($VERSION $log_entries $log_level);

# Modules
use Symbol;
use Carp;

# Public Globals
$VERSION = 2.0;

=head1 Public Functions

=head2 new()

This just allocates the reference without doing anything further.

=cut
sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};

  my ($id, $method, $tmp);
  
  $self->{states} = [];
  bless ($self, $class);
  return $self;
}

sub DESTROY {
  my $self = shift;

  for my $i (@{$self->{dests}}) {
    if ($i->{'handle'}) {
      close $i->{'handle'};
    }
    else {
      Sys::Syslog::closelog();
    }
  }
}

=head2 add

This adds one or more logging destinations to the log object.  Call with a
hash; possible parameters are:

  method      - Logging method to use: syslog, handle, or file.
  id          - A short string to use as an identifier in the logs.
  level       - The maximum level that will be logged to this destination
  subsystem   - With syslog, what subsystem should be used.  Defaults to
               "mail".
  filename    - With 'file' logging, what file should be used?
  handle      - With 'handle' logging, what handle should be used?
  log_entries - Should function entries be logged?
  log_exits   - Should function exits be logged? These include the time spent
                in the function.
  log_args    - Should function arguments be logged?

=cut
sub add {
  my $self = shift;
  my %dest = @_;

  $dest{method}      ||= 'syslog';
  $dest{id}          ||= "";
  $dest{level}       = 10 unless defined $dest{level};
  $dest{subsystem}   ||= 'mail';
  $dest{log_entries} ||= 0;
  $dest{log_exits}   ||= 1;
  $dest{log_args}    ||= 0;

  # Open the log destination
  if ($dest{'method'} eq 'file') {
    unless ($dest{'filename'}) { 
      confess "Trying to add file destination with no filename.";
    }
    $dest{'handle'} = gensym();
    open ($dest{'handle'}, ">> $dest{'filename'}") ||
      confess "Can't open $dest{'filename'} to write the log!";
  }
  elsif ($dest{'method'} eq 'handle') {
    # Nothing to do.
  }
  elsif ($dest{'method'} eq 'syslog') {
    # In perl 5.004, the syslog module will not export setlogsock 
    # if _PATH_LOG is not defined.
    require Sys::Syslog;
    Sys::Syslog::setlogsock('unix');
    Sys::Syslog::openlog($dest{id}, 'pid', $dest{subsystem});
  }
  else {
    confess("add called with invalid method $dest{method}");
  }
  
  $dest{'active'} = 1;

  # Store the hash our private list
  push @{$self->{dests}}, {%dest};

  # Return the length of the array; this gives a unique ID.
  return $#{$self->{'dests'}};
}

=head2 set_level(level, id)

This sets the logging level for a certain destination ID, or all IDs if $id
is not defined.

=cut
sub set_level {
  my $self  = shift;
  my $level = shift;
  my $dest  = shift;
  my(@tmp, $i);

  if (defined $dest) {
    @tmp = ($dest);
  }
  else {
    @tmp = (0..$#{$self->{'dests'}});
  }

  for $i (@tmp) {
    $self->{'dests'}[$i]{'level'} = $level;
  }
}

=head2 delete(id)

This deactivates a logging destination and closes an open file or syslog
connection.

=cut
sub delete {
  my $self = shift;
  my $id   = shift;

  if ($self->{'dests'}[$id]{'active'}) {
    $self->{'dests'}[$id]{'active'} = 0;
  }
  else {
    confess "delete called on an inactive destination!";
  }
  if ($self->{dests}[$id]{method} eq 'file') {
    close $self->{dests}[$id]{handle};
  }
  elsif ($self->{dests}[$id]{method} eq 'handle') {
    # Nothing to do
  }
  elsif ($self->{dests}[$id]{method} eq 'syslog') {
    Sys::Syslog::closelog();
  }
}

=head2 message(level, priority, message, arg)

This logs a single message.

=cut
sub message {
  my $self    = shift;

  my $level   = shift;
  my $prio    = shift;
  my $message = shift;
  my $arg     = shift;
  my $state   = shift;
  my $string;

  confess("log with no message!") unless $message;
  
  for my $i (@{$self->{dests}}) {
    next unless $i->{active};
    if ($level <= $i->{level} &&
	(
	 (!defined $state)                        ||
	 ($state eq 'entry' && $i->{log_entries}) ||
	 ($state eq 'exit'  && $i->{log_exits})
	)
       )
      {
	if ($arg && $i->{log_args}) {
	  $string = "$message: $arg";
	}
	else {
	  $string = $message;
	}
	if ($i->{method} =~ /^(file|handle)$/) {
          print {$i->{handle}} ("[$$]",'.'x($#{$self->{'state'}}+1),
		       "$string\n");
	}
	else {
	  Sys::Syslog::syslog($prio, $string);
	}
      }
  }
}

=head2 startup_time()

This logs a message containing information on how much CPU time has been
spent so far on the job.  It is intended to be called as early as possible
to account for startup time.

=cut
sub startup_time {
  my $self = shift;

  my($user, $system) = (times)[0..1];
  
  $user = sprintf("%.3f", $user);
  $system = sprintf("%.3f", $system);
  $self->message(6, "info", "Compilation took " . $user . "u, " . $system . "s");
}

=head2 in(level, arg, priority, message)

This logs a message to destinations which log entries and saves the time.
It should be paired with a call to out.

priority defaults to "info" while message defaults to the name of the
calling subroutine.

=cut
sub in {
  my $self = shift;

  my $level = shift;
  my $arg = shift;
  my $prio = shift || "info";
  my $message = shift || (caller(1))[3];

  $self->message($level, $prio, $message, $arg, "entry");
  unshift @{$self->{state}}, [$level, $prio, $message, time()];
}

=head2 out(extra)

This removes the state saved by a call to in(), computes the elapsed time
and logs the message given to in() with extra attached to all destination
which log exits.

=cut
sub out {
  my $self = shift;

  my $extra = shift || "done";
  my $state = shift @{$self->{state}};

  unless ($state) {
    confess "Log::out called without corresponding Log::in, stopped";
  }
  
  my ($level, $prio, $message, $arg) = @{$state}[0..2];
  my $elapsed = time() - @{$state}[3];
  
  $elapsed = sprintf("%.3f", $elapsed);
  
  $self->message($level, $prio, "$message..$extra, took $elapsed sec", undef, "exit");
}

=head2 elapsed

Return the elapsed time since in() was called

=cut
sub elapsed {
  my $self = shift;
  my $state = $self->{'state'}->[-1];
  return unless $state;

  time - $state->[3];
}

=head2 abort(message)

This logs an emergency message then aborts the running program with a
backtrace.

=cut
sub abort {
  my $self = shift;
  my $message = shift;

  $self->message(1, "warning", $message);

  # Complain where abort was called, not here.
  $Carp::CarpLevel = 1; 
  confess $message;
}

=head2 complain(message)

This logs a warning message and prints a backtrace.  It does not abort the
program.

XXX This and abort should do something else to inform the list
owner/majordomo owner, perhaps by stuffing the warnings in a file that
would get mailed to the owner later.

=cut
sub complain {
  my $self = shift;
  my $message = shift;

  $self->message(1, "warning", $message);
  carp $message;
}


=head1 Sneaky Log::In object

This is a cute trick to eliminate the need to log out of a scope.  Instead,
allocate a Log::In object and the corresponding call to Log::out will
happen automatically when the current scope is exited.  If out() is called
with a string, that string will be used as the Log::out value instead of
the default.

This may have speed penalties; that hasn't been investigated.  It does
conveniently get around the need to store an output value, then log out,
then return the value (and checking for wantarray).
'

=cut
package Log::In;

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};
  bless $self, $class;
  $::log->in(shift, shift, shift||"info", shift||(caller(1))[3]);
  $self;
}

sub out {
  my $self = shift;
  $self->{'msg'} = shift;
}

sub abort {
  my $self = shift;
  $::log->abort(shift);
}

sub complain {
  my $self = shift;
  $::log->complain(shift);
}

sub message {
  my $self = shift;
  $::log->message(@_);
}

sub DESTROY {
  my $self = shift;
#warn " ".(caller(2))[3];
  $::log->out($self->{'msg'});
}

=head1 COPYRIGHT

Copyright (c) 1997, 1998 Jason Tibbitts for The Majordomo Development
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

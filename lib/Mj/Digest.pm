=head1 NAME

Mj::Digest.pm - Majordomo digest object

=head1 SYNOPSIS

  $digest = new Mj::Digest parameters;

=head1 DESCRIPTION

This contains code for the Digest object, which encapsulates all message
digesting functionality for Majordomo.

A digest is a collection of messages enclosed in a single message;
internally, Majordomo represents a digest as an object to which message
numbers (derived from the Archive object) are associated; when certain
conditions arise, some number of those messages are removed from the pool
and turned into a digest message which is sent to the proper recipients.

=cut

package Mj::Digest;

use Mj::Log;
use strict;
use vars qw($VAR1);
use AutoLoader 'AUTOLOAD';
1;
__END__

=head2 new(archive, dir, digestdata)

This creates a digest object.  dir is the place where the digest will store
its state file (volume, issue, spooled messages, etc).  archive is an
archive object already created that digest will use to do its message
retrieval.  The data hash should contain all of the data necessary to
operate the trigger decision mechanism and the build mechanism (generally
passed directly from the List object).  It will not be modified.

digestdata should contain the parsed version of the 'digests' variable,
containing hashrefs keyed on the digest name (and an additional
'default_digest' key).  Each of those hashrefs conains:

  desc    - digest description
  index   - the index style (subject, subject_author, etc.)
  maxage  - maximum age of oldest message in the digest
  maxmsg  - maximum number of messages in a digest
  maxsize - maximum size of a digest
  minage  - minimum age of the newest message in the digest
  minmsg  - minimum number of messages in a digest
  minsize - minimum size of a digest (in bytes)
  newmsg  - true if an incoming message can trigger digest delivery
  separate- minimum time between digests
  sort    - how the messages are sorted (author date numeric subject thread)
  type    - digest format (index, mime, or text)
  times   - array of clock values

The digest keeps state in a file (in $dir) called _digests.  This is a
Data::Dumped hashref with one key per named digest.  Each subhash contains:

  messages - a list of [message name, data] pairs waiting to be sent.
  lastrun  - the last time this digest was pushed.
  bytecount- sum of 'bytes' from all message data.
  newest   - the time of the most recent message.
  oldest   - the time of the least recent message.

We must be very careful with the data file; it cannot be cached because
hosing it results in duplicates or dropped messages.  This it must be
locked, read, manipulated, saved, erased from memory and unlocked.

=cut
sub new {
  my $type  = shift;
  my $arc   = shift;
  my $dir   = shift;
  my $data  = shift;
  my $class = ref($type) || $type;
  my $log   = new Log::In 150, "$dir";
  my $self  = {};
  bless $self, $class;

  # Open state file if it exists

  $self->{'archive'}  = $arc;
  $self->{'dir'}      = $dir;
  $self->{'decision'} = $data;
  $self->{'digests'}  = [];

  for my $i (keys(%$data)) {
    push (@{$self->{'digests'}}, $i) 
      unless ($i eq 'default_digest');
  }
  return $self;
}

=head2 add(message, messagedata)

This adds a message to the digest''s message pool.  The information in the
messagedata hashref is used by the decision algorithm.

messagedata is the hash returned from Archive::add, containing the follwing
keys of possible importance:

  bytes
  lines
  body_lines
  quoted
  date
  from
  subject
  refs

Returns what trigger returns.

=cut
sub add {
  my $self = shift;
  my $mess = shift;
  my $data = shift;
  my $log = new Log::In 250, "$mess";
  my (%out, $i, $state);

  $state = $self->_open_state;

  for $i (@{$self->{digests}}) {
    # Initialize some defaults if necessary
    unless ($state->{$i}) {
      $state->{$i}{messages} = [];
      $state->{$i}{lastrun}  = 0;
      $state->{$i}{bytecount}= 0;
      $state->{$i}{newest}   = 0;
    }
    # Update the state information
    push @{$state->{$i}{messages}}, [$mess, $data];
    $state->{$i}{bytecount} += $data->{bytes};
    $state->{$i}{newest} = $data->{date} if $data->{date} > $state->{$i}{newest};
    if ($state->{$i}{oldest}) {
      $state->{$i}{oldest} = $data->{date} if $data->{date} < $state->{$i}{oldest};
    }
    else {
      $state->{$i}{oldest} = $data->{date};
    }
  }

  # Trigger a run?
  %out = $self->trigger(undef, undef, $state, 1);

  $self->_close_state($state, 1);
  %out;
}

=head2 volume(number)

This sets the volume number of the digest.  If number is not defined, the
existing number is simply incremented.

=cut
# sub volume {
#   my $self = shift;
#   my $num  = shift;
  
#   if (defined $num) {
#     $self->{'state'}{'volume'} = $num;
#   }
#   else {
#     $self->{'state'}{'volume'}++;
#   }
#   1;
# }

=head2 trigger(digests, force, state))

This triggers the decision algorithm by running through the provided
listref of digests (or, if undefined, all defined digests) and running
'decide' (unless $force is true, in which case a digest is forced).  It
also opens and closes the state file if necessary.

Returns a hash keyed on digest names of lists of [article, data] lists.

=cut
sub trigger {
  my $self    = shift;
  my $digests = shift;
  my $force   = shift;
  my $state   = shift;
  my $newmsg  = shift || 0;
  my $log = new Log::In 250;
  my (%out, @msgs, $change, $close, $i, $push, $run);

  unless ($state) {
    $state = $self->_open_state;
    $close = 1;
  }

  $run = $digests;
  $run ||= $self->{digests};

  for $i (@{$run}) {
    unless ($state->{$i}) {
      $state->{$i}{messages} = [];
      $state->{$i}{lastrun}  = 0;
      $state->{$i}{bytecount}= 0;
      $state->{$i}{newest}   = 0;
      $change = 1;
    }
    $push = $force || 
      $self->decide($state->{$i}, $self->{decision}{$i}, $newmsg);
    $change ||= $push;
    if ($push) {
      @msgs = $self->choose($state->{$i}, $self->{decision}{$i});
      if (@msgs) {
	$out{$i} = [@msgs];
      }
    }
  }
  if ($close) {
    $self->_close_state($state, $change);
  }
  return %out;
}

=head2 decide(state, decision parameters)

This takes the state and decision parameters for a single digest and
decides if the digest should be delivered.  It returns 1 if a digest 
should be delivered.

=cut
use Mj::Util qw(in_clock str_to_offset);
sub decide {
  my $self = shift;
  my $s    = shift; # Digest state
  my $p    = shift; # Decision parameters
  my $nm   = shift; # Was the decision triggered by an incoming message?
  my $log  = new Log::In 250;
  my $time = time;

  $log->out('no');

  if ($nm and ! $p->{'newmsg'}) {
    $log->out('no, a new message cannot trigger this digest.');
    return 0;
  }

  # Check time; bail if not right time
  unless (Mj::Util::in_clock($p->{'times'})) {
    $log->out('no, it is not the correct time.');
    return 0;
  }

  # Check time difference; bail if a digest was 'recently' pushed.
  if ($p->{separate} && $s->{lastrun} &&
      ($time - $s->{lastrun}) < str_to_offset($p->{separate}, 0, 0, $s->{lastrun})) 
  {
    $log->out('no, a digest was issued too recently.');
    return 0;
  }

  # Check oldest message, push digest if too old (maxage)
  if ($p->{maxage} && exists($s->{oldest}) &&
      ($time - $s->{oldest}) > str_to_offset($p->{maxage}, 0, 0)) {
    $log->out('yes');
    return 1;
  }

  # Check sizes; bail if not enough messages or not enough bytes (minsize,
  # minmsg)
  unless (!$p->{minsize} || $s->{bytecount} >= $p->{minsize}) {
    $log->out('no, the messages are not large enough.');
    return 0;
  }

  unless (!$p->{minmsg} || scalar(@{$s->{messages}}) >= $p->{minmsg}) {
    $log->out('no, there are not enough messages.');
    return 0;
  }

  # Check newest message; bail if not old enough (minage)
  unless (!$p->{minage} || 
          ($time - $s->{newest}) >= str_to_offset($p->{minage}, 0, 0)) 
  {
    $log->out('no, the newest message is too recent.');
    return 0;
  }

  # We found no reason _not_ to push a digest
  $log->out('yes');
  1;
}

=head2 choose(state, decision parameters)

This chooses messages to be built into a digest and returns them, in order,
as [name, data] pairs.  The return value is suitable for passing to
Digest::Build::build.

This currently only shifts articles out of the waiting article list until
the digest gets too large or we run out of messages.

=cut
sub choose {
  my $self = shift;
  my $s    = shift;
  my $d    = shift;
  my $log  = new Log::In 250;
  my $mm   = $d->{maxmsg}  || 200;  # Some just-beyond-reasonable maxima
  my $ms   = $d->{maxsize} || 2**22;
  my $msgs = $s->{messages};
  my (@out, $bcnt, $mcnt);

  # Shouldn't happen, but bail if we have no messages to choose from
  return unless @$msgs;

  # We always push at least one message
  $mcnt = 1; $bcnt = $msgs->[0][1]{bytes}; push @out, shift @$msgs;

  # Loop until we're out of messages or the next message would exceed our
  # size limits
  while (@$msgs && $mcnt < $mm && ($msgs->[0][1]{bytes} + $bcnt) <= $ms) {
    $mcnt++; $bcnt += $msgs->[0][1]{bytes}; push @out, shift @$msgs;
  }

  # Recalculate bytecount, oldest, newest.
  $s->{lastrun} = time;
  $s->{bytecount} = 0; $s->{oldest} = 0;  $s->{newest} = 0;
  for my $i (@$msgs) {
    $s->{bytecount} += $i->[1]{bytes};
    $s->{newest} = $i->[1]{date} if $i->[1]{date} > $s->{newest};
    if ($s->{oldest}) {
      $s->{oldest} = $i->[1]{date} if $i->[1]{date} < $s->{oldest};
    }
    else {
      $s->{oldest} = $i->[1]{date};
    }
  }

  @out;
}

=head2 examine(digest_listref, stateonly)

  Return data concerning the rules and pending messages
  for a group of digests.

  If the stateonly argument is true, the decision parameters
  for each digest will not be returned.

=cut
sub examine {
  my $self = shift;
  my $digest = shift;
  my $stateonly = shift || 0;
  my $log = new Log::In 200, $digest;
  my ($data, $i, $j, $state);
  $state = $self->_open_state;
  $self->_close_state($state, 0);
  $data = {};

  for $i (@$digest) {
    next unless (exists $self->{'decision'}{$i});
    if ($stateonly) {
      $data->{$i} = {};
    }
    else {
      $data->{$i} = $self->{'decision'}{$i};
    }
    if (exists $state->{$i}) {
      for $j (keys %{$state->{$i}}) {
        $data->{$i}->{$j} = $state->{$i}->{$j}
          unless (exists $data->{$i}->{$j});
      }
    }
  }
  return $data;
}  

=head2 sync(data)

Replace the data for one or more digests.

=cut
sub sync {
  my $self = shift;
  my $data = shift;
  my $log = new Log::In 200;
  my ($i, $j, $state);

  $state = $self->_open_state;
  for $i (keys %$data) {
    if (exists $data->{$i}->{'messages'}) {
      $data->{$i}->{'oldest'} = 0;
      $data->{$i}->{'newest'} = 0;
      $data->{$i}->{'bytecount'} = 0;
      for $j (@{$data->{$i}->{'messages'}}) {
        $data->{$i}->{'oldest'} = $j->[1]->{'date'}
          if (!$data->{$i}->{'oldest'} or 
              $j->[1]->{'date'} < $data->{$i}->{'oldest'});
        $data->{$i}->{'newest'} = $j->[1]->{'date'}
          if (!$data->{$i}->{'newest'} or 
              $j->[1]->{'date'} > $data->{$i}->{'newest'});
        $data->{$i}->{'bytecount'} += $j->[1]->{'bytes'};
      }
    }
    if (exists $state->{$i}) {
      for $j (keys %{$data->{$i}}) {
        $state->{$i}->{$j} = $data->{$i}->{$j};
      }
    }
  }
  $self->_close_state($state, 1);
}

=head2 _open_state, _close_state(data, dirty)

These manage the file holding the digest state.  This file is handled
carefully; the open routine loads it and returns a reference to it, keeping
it locked all the while.  The close routine writes it back if it was dirty
and unlocks it.

=cut
use Mj::FileRepl;
sub _open_state {
  my $self = shift;
  my $file = "$self->{'dir'}/_digests";
  my $log = new Log::In 200, "$file";

  unless (-f $file) {
    open DIGEST, ">>$file";
    close DIGEST;
  }

  $self->{'datafh'} = new Mj::FileRepl($file);
  return {} unless (-s $file);
  do $file;
  $VAR1;
}

use Data::Dumper;
sub _close_state {
  my $self = shift;
  my $data = shift;
  my $dirty= shift;
  my $log = new Log::In 200;

  unless ($dirty) {
    $self->{'datafh'}->abandon;
    return;
  }
  
  {
    local $Data::Dumper::Purity = 1;
    $self->{'datafh'}->print(Dumper($data));
  }
  $self->{'datafh'}->commit;
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
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***


=head1 NAME

Mj::Deliver::Dest - Delivery destination

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This is an overly complicated chunk of code implementing a 'destination',
which is a group of hosts that addresses are sent to, along with data
describing those hosts and how the addresses should be grouped.  The main
function is to take addresses as they arrive and break them into groups of
some size.  There are four ways to group:

 by number of addresses
 by number of domains (requires sorting)
 by absolute batch size (requires passing through a sorter object to get the
   count first)
 by a more complicated algorithm that takes domains that appear frequently
   and gives them their own batches, then groups the rest by number of
   domains (requires sorting)

Several of these methods require that the addresses be passed to the
destination sorted in domain order; the sorter object exists for this
purpose in the event that the database backend does not deliver the
addresses in a sorted manner.  The sorter object also delivers the size of
the batch which is useful in dividing things evenly into a number of
equally sized batches.

=cut

package Mj::Deliver::Dest;
use Mj::Log;

=head2 new(arghashref, force_single)

This creates a destination object, which will accept addresses and pass
them off to various envelopes for delivery.

Arghash should be a ref to the hash parsed out of the the delivery_rules
variable.

If force_single is true, the batching parameters in passed arguments will
be ignored and instead only one address per envelope will be used.

During its operation, a destination will pick up a bunch of members.  Most
of them are:

 sender      - the sender of the messages
 file        - the file containing the message data
 method      - the batching method
 size        - the batch size
 subsize     - the sub-batch size
 hostlist    - the list of initially active hosts, randomized
 backuplist  - a list of backup hosts
 hostdata    - a hash (keyed by hostname) of all data about each host
 activehosts - the hosts that envelopes can be opened on.  If a host fails,
   it is removed from this array and the backups are added.  When this gets
   empty, localhost is added and we go into emergency mode.
 currenthost - the index into activehosts of the host we''re currently
   dealing with
 failures    - a count of the failures we''ve had
 emergency   - a flag; are we in emergency mode?
 envelopes   - a list of currently open envelopes
 count       - a count of addresses in the batch
 subcount    - a count of addresses in the sub-batch
 lastdom     - the last domain added to this destination
 stragglers  - a list of straggler addresses
 addrs       - the main address accumulation list
 deferred    - addresses which fail temporarily during RCPT TO.
 failed      - addresses which fail permanently during RCPT TO.

TODO:

Batched SMTP:

Instead of storing things to RAM, write our side of the SMTP transaction
out to files and then just dump the file to the MTA.

=cut
sub new {
  my $type   = shift;
  my $class  = ref($type) || $type;
  my $data   = shift;
  my $file   = shift;
  my $sender = shift;
  my $lhost  = shift || '';
  my $single = shift;
  my $log   = new Log::In 150;
  my (@tmp1, $code, $fail, $i, $mess, $val);

  my $self = {};
  bless $self, $class;

  # Pull in sender and file
  $self->{'sender'} = $sender;
  $self->{'origsender'} = $sender;
  $self->{'file'}   = $file || $data->{'file'};

  # Figure out method and args;
  if ($single) {
    $self->{'method'} = 'maxaddrs';
    $self->{'size'} = 1;
  }
  elsif ($data->{'minseparate'}) {
    $self->{'method'} = 'minseparate';
    $self->{'size'} = $data->{'minseparate'} || 10;
    $self->{'subsize'} = $data->{'maxdomains'} || 20;
  }
  elsif ($data->{'maxdomains'}) {
    $self->{'method'} = 'maxdomains';
    $self->{'size'} = $data->{'maxdomains'} || 20;
  }
  elsif ($data->{'maxaddrs'}) {
    $self->{'method'} = 'maxaddrs';
    $self->{'size'} = $data->{'maxaddrs'} || 20;
  }
  # This covers $data->{'numbatches'} or none specified.
  else {
    $self->{'method'} = 'maxaddrs';

    # Don't want to load POSIX here just to get ceil(), so fake it with a
    # cheap approximation.
    $self->{'size'} =
      int(1+(($data->{'total'} || 2**30) / ($data->{'numbatches'} || 1)));
  }

  # Build host list; pick a random ordering
  $data->{'hosts'} ||= {'localhost' => {}};
  @tmp1 = keys %{$data->{'hosts'}};
  if (@tmp1) {
    for ($i=0; @tmp1; $i++) {
      push(@{$self->{'hostlist'}}, splice(@tmp1, rand @tmp1, 1));

      # Copy the host parameters into the object
      $self->{'hostdata'}{$self->{'hostlist'}[$i]} =
	$data->{'hosts'}{$self->{'hostlist'}[$i]};
    }
  }
  else {
    $self->{'hostlist'} = ['localhost'];
  }

  # Build backup list
  @tmp1 = keys %{$data->{'backup'}};
  if (@tmp1) {
    for ($i=0; @tmp1; $i++) {
      push(@{$self->{'backuplist'}}, splice(@tmp1, rand @tmp1, 1));

      # Copy the host parameters into the object
      $self->{'hostdata'}{$self->{'backuplist'}[$i]} =
	$data->{'backup'}{$self->{'backuplist'}[$i]};
    }
  }
  else {
    $self->{'backuplist'} = ['localhost'];
  }

  # List of hosts used in delivery rotation
  $self->{'activehosts'} = [@{$self->{'hostlist'}}];

  # The index of the host we're currently sending to.
  $self->{'currenthost'} = 0;

  # The number of failed connections.  This indicates the number of badly
  # failed connections, such as general permanent SMTP errors or socket
  # timeouts.
  $self->{'failures'} = 0;

  # Are we in emergency mode?  We get there if we can't deliver anywhere
  # else; we'll try to connect to localhost for quite a while, and then we
  # just puke and die.
  $self->{'emergency'} = 0;

  # A list of currently opened envelopes, in correspondence to the list of
  # active hosts.
  $self->{'envelopes'} = [];

  # These counts keep track of the numbers of addresses/domains sent so we
  # know when to mail an envelope.
  $self->{'lhost'}      = $lhost;
  $self->{'batch'}      = 0;
  $self->{'count'}      = 0;
  $self->{'subcount'}   = 0;
  $self->{'lastdom'}    = '';
  $self->{'stragglers'} = [];
  $self->{'addrs'}      = [];
  $self->{'deferred'}   = [];
  $self->{'failed'}     = [];

  $self;
}

sub DESTROY {
  my $self = shift;
  my $log  = new Log::In 150;
  $self->flush;
}

use AutoLoader 'AUTOLOAD';
1;
__END__

=head2 make_envelope(currenthost)

This is broken out so that Mj::Deliver::Envelope can be autoloaded.

=cut
use Mj::Deliver::Envelope;
sub make_envelope {
  my $self = shift;
  my $ch   = shift;
  my $host = $self->{'activehosts'}[$ch];
  my $log  = new Log::In 540, "$ch, $host";

  return
    Mj::Deliver::Envelope->new(
			       'sender' => $self->{'sender'},
			       'file'   => $self->{'file'},
			       'host'   => $host,
                               'local'  => $self->{'lhost'},
                               'personal' => ($self->{'size'} == 1),
			       %{$self->{'hostdata'}{$host}},
			      );
}


=head2 make_qqenvelope(currenthost)

This is broken out so that Mj::Deliver::QQEnvelope can be autoloaded.

=cut
use Mj::Deliver::QQEnvelope;
sub make_qqenvelope {
  my $self = shift;
  my $ch   = shift;
  my $host = $self->{'activehosts'}[$ch];

  return
    Mj::Deliver::QQEnvelope->new(
				 'sender' => $self->{'sender'},
				 'file'   => $self->{'file'},
				 'host'   => $host,
				 %{$self->{'hostdata'}{$host}},
				);
}

use Mj::Deliver::BSMTPEnvelope;
sub make_bsmtpenvelope {
  my $self = shift;
  my $ch   = shift;
  my $host = $self->{'activehosts'}[$ch];
  my $log  = new Log::In 140, "$ch, $host";

  return
    Mj::Deliver::BSMTPEnvelope->new(
				    'sender' => $self->{'sender'},
				    'file'   => $self->{'file'},
				    'local'  => $self->{'lhost'},
				    'personal' => ($self->{'size'} == 1),
				    %{$self->{'hostdata'}{$host}},
				   );
}


=head2 sendenvelope

This opens an envelope if necessary, sends the currently active addresses
and deals with error returns and such.  This has lots of nasty side
effects; the idea is to do whatever is required to get the envelope sent
including killing hosts and incrementing the current host number.  The
calling function can currently assume this succeeds; if it fails, it
aborts.

=cut
sub sendenvelope {
  my $self = shift;
  my $log  = new Log::In 150;
  my(%data, $ch, $host, $i, $ok);

  $ch = $self->{'currenthost'};

  # We'll loop until we get it delivered, or we die trying; the continue
  # block gets executed to nuke hosts, deal with emergencies and sleep if
  # we get a failure any time before we send the envelope.
  while (1) {
    $host = $self->{'activehosts'}[$ch];
    if ($self->{'hostdata'}{$host}) {
      %data = %{$self->{'hostdata'}{$host}};
    }

    unless ($self->{'envelopes'}[$ch]) {
      if (lc($host) eq '@qmail') {
	$self->{'envelopes'}[$ch] = $self->make_qqenvelope($ch);
      }
      elsif (lc($host) eq '@bsmtp') {
	$self->{'envelopes'}[$ch] = $self->make_bsmtpenvelope($ch);
      }
      else {
	$self->{'envelopes'}[$ch] = $self->make_envelope($ch);
      }
    }

    # If that failed, continue and try again
    next unless $self->{'envelopes'}[$ch];

    # We're guaranteed to have an envelope.  Address it and fall through to
    # error processing if we couldn't.
    $self->{envelopes}[$ch]->sender($self->{sender});
    $ok = $self->{'envelopes'}[$ch]->address($self->{'addrs'},
                                             $self->{'deferred'},
                                             $self->{'failed'});
    # Return now if no addresses remain to be processed.
    return 0 if (!@{$self->{'addrs'}});
    if ($ok == 0) {
      undef $self->{'envelopes'}[$ch];
      next;
    }


    if ($ok < 0) {
      # Some addresses were processed successfully, but the envelope
      # is not addressed.  This could happen if we reached a recipient
      # limit, sent the message and reinitialized.
      return 1;
    }

    # We addressed the envelope OK, so we can send it
    $ok = $self->{'envelopes'}[$ch]->send;
    last if $ok;

    # We fall off the block and do error processing here.
  }

  # This catches any errors in the sending process; if wa fail at any point
  # we retry, nuke and activate backups, or go into emergency mode.  We
  # also sleep for a while.
  continue {
    $i++;
    if ($self->{'emergency'} && $i > 25) {
      warn "Could not deliver, even in emergency mode!";
      $log->abort("Could not deliver, even in emergency mode!");
    }

    # We try three times...
    if ($i > 3) {
      # This host is hosed; delete it from the active list and shrink the
      # envelope list as well.
      splice(@{$self->{'activehosts'}}, $ch, 1);
      splice(@{$self->{'envelopes'}},   $ch, 1);

      # Activate the backups if we haven't done so already.
      if ($self->{'failures'} == 0) {
	push(@{$self->{'activehosts'}}, @{$self->{'backuplist'}});
	$log->complain("Activating backup delivery hosts!");
      }

      # Start the counter at zero again
      $i = 0 unless $self->{'emergency'};
      $self->{'failures'}++;

      # Fix the host pointer if we deleted the end of the list.  This could
      # cause us to stop failing if we don't have to open another envelope,
      # hence the while loop condition.  Note that a zero modulus is
      # illegal.
      $ch = $ch % (@{$self->{'activehosts'}} || 1);

      # Shift into emergency mode if we're out of hosts; make sure we
      # always have localhost in the list if we've emptied it.
      unless (@{$self->{'activehosts'}}) {
	$self->{'activehosts'} = ['localhost'];
	$log->complain("Going into emergency delivery mode!")
	  unless $self->{'emergency'};
	$self->{'emergency'} ||= 1;
      }
    }
    if ($i > 7 && $self->{'emergency'} == 1) {
      # We've tried just the emergency destination several times now and
      # we're still not getting through.  So now we stuff all of the hosts
      # back in, go into 'super emergency' mode, and try them all again
      $self->{'activehosts'} =
        [@{$self->{'hostlist'}}, @{$self->{'backuplist'}}, 'localhost'];
      $log->complain("Going into super-emergency delivery mode!")
	unless $self->{'emergency'} == 2;
      $self->{'emergency'} = 2;
    }

    # Wait a while, waiting longer the more we fail.
    sleep ((10 * $i * $self->{'emergency'}) + 2 + rand(5));
  }

  # We delivered an envelope OK, so move to the next host
  $ch = ($ch + 1) % @{$self->{'activehosts'}};

  $self->{'currenthost'} = $ch;
  1;
}

=head2 add(addr)

This adds an address to the destination.  If the batching parameters
dictate that the batch should be sent, the sendenvelope function is called
automatically.  Note that the sendenvelope function deals with
$self->{'addrs'} implicitly.  Ugh, more side effects.

The second argument is used to extract a domain for use as a sort key; this
allows domains to sort together because of transforms even though they
normally wouldn't.  It is acceptable to leave it undefined.

=cut
sub add {
  my $self  = shift;
  my $addr  = shift;
  my $dom   = shift || $addr; # Actually the canonical address
  my $flush = shift;
#  my $log   = new Log::In 200, "$addr, $dom";
  my($ch, $env, $host, $i, $ok, $sendit);

  # Extract that domain from the canonical address
  $dom =~ s/.*@//;

  # Maxaddrs; always split batches after N addresses
  if ($self->{'method'} eq 'maxaddrs') {
    push @{$self->{'addrs'}}, $addr;
    $self->{'count'}++;
    if ($self->{'count'} >= $self->{'size'}) {
      $self->batch;
    }
  }

  # Maxdomains; only increment count when the domain changes.
  elsif ($self->{'method'} eq 'maxdomains') {
    push @{$self->{'addrs'}}, $addr;
#    print "  $addr\n";
    if ($dom ne $self->{'lastdom'}) {
      $self->{'count'}++;
      $self->{'lastdom'} = $dom;
      if ($self->{'count'} >= $self->{'size'}) {
	$self->batch;
      }
    }
  }

  # Minseparate; automatically separate out recurring hosts
  elsif ($self->{'method'} eq 'minseparate') {

    # Did the domain change?
    if ($dom ne $self->{'lastdom'}) {

#     print "Domain changed!\n";

      # Did we get enough to make a separate batch?
      if ($self->{'count'} < $self->{'size'}) {

#	print "Didnt get enough...\n";

	# Stuff what we've collected into the straggler list. This zeroes
	# the count but doesn't doesn't start a new batch.

	push @{$self->{'stragglers'}}, @{$self->{'addrs'}};
#	print "Pushing to stragglers...\n";
	$self->{'addrs'} = [];
	$self->{'count'} = 0;
	$self->{'subcount'}++;

	# Do we need to push out the stragglers?
	if ($self->{'subcount'} >= $self->{'subsize'}) {
	  $self->{'addrs'} = $self->{'stragglers'};
	  $self->{stragglers} = [];
	  $self->{subcount} = 0;
	  $self->batch;
	}
      }
      else {
#	print "Got enough...\n";

	# Yep; send them out
	$self->batch;
      }

      # Now we note the new domain and add the address
      $self->{'lastdom'} = $dom;
      push @{$self->{'addrs'}}, $addr;
#     print "  $addr\n";
      $self->{'count'}++;
    }

    # Else the domain didn't change
    else {
      push @{$self->{'addrs'}}, $addr;
      $self->{'count'}++;
#      print "  $addr\n";

    }
  }
}

=head2 batch

This ends the current batch and starts a new one.

Zero count.  Move addrs.

=cut
sub batch {
  my $self = shift;
  my $log  = new Log::In 150;

  $self->{count} = 0;
  $self->{batches}[$self->{batch}]{sender} = $self->{sender};
  $self->{batches}[$self->{batch}]{addrs}  = $self->{addrs};
  $self->{batch}++;
  $self->{addrs} = [];
}



=head2 flush

This causes all remaining addresses to be sent.  If sorting is active, the
list is sorted and pushed out.

=cut
use Symbol;
sub flush {
  my $self = shift;
  my $log  = new Log::In 150;
  my ($addr, $batch, @tmp);

  if (@{$self->{'stragglers'}}) {
    if (@{$self->{'addrs'}} >= $self->{'size'}) {
      # Stragglers must go in a separate batch
      $self->batch;
    }
    # Otherwise stragglers can go in the same batch
    push @{$self->{'addrs'}}, @{$self->{'stragglers'}};
    $self->{stragglers} = [];
  }
  if (@{$self->{'addrs'}}) {
    $self->batch;
  }

  # Now all accumulated addresses are stored in batches.  We can loop over
  # all batches and call sendenvelope on each
  for $batch (@{$self->{batches}}) {
    $self->{sender} = $batch->{sender};
    $self->{addrs}  = $batch->{addrs};
    $self->sendenvelope;
  }
  $self->{addrs}   = [];
  $self->{batches} = [];

  # deferred addresses failed temporarily during RCPT TO.
  # They are processed last to minimize delays for mail delivered to
  # other recipients.  To lower retry times, each address
  # is done individually.
  if (@{$self->{'deferred'}}) {
    # avoid infinite loop; sendenvelope may change the "deferred" list.
    @tmp = @{$self->{'deferred'}};
    while (@tmp) {
      $addr = shift @tmp;
      $self->{'addrs'} = [$addr->[0]];
      $self->sendenvelope;
    }
    $self->{'deferred'} = [];
    $self->{'addrs'} = [];
  }
  # failed addresses either received a permanent error during
  # RCPT TO or were deferred and failed during the retry.
  # Report the problem to the sender.
  if (@{$self->{'failed'}}) {
    $self->_gen_bounces;
    $self->{failed} = [];
  }
}

=head2 sender

Set the sender separate from instantiation; to allow the sender to be
changed after the fact.  This will force a new batch.  Note that since a
dest caches all of its envelopes, this requires that each envelope''s
sender be changed.  These changes only take effect _after_ the next
envelope init.

=cut
sub sender {
  my $self   = shift;
  my $sender = shift;

  if (@{$self->{addrs}}) {
    $self->batch;
  }

  if (@{$self->{stragglers}}) {
    $self->{addrs} = $self->{stragglers};
    $self->batch;
    $self->{stragglers} = [];
  }

  $self->{sender} = $sender;
  for my $env (@{$self->{envelopes}}) {
    $env->sender($sender) if (defined $env);
  }
}

=head2 _gen_bounces

Generate a bounce for each address that failed during the SMTP transaction.
This is necessary because, having rejected the RCPT, the receiving MTA
obviously isn't going to generate a bounce.

The bounce format vaguely resembles that of Exim; it is close enough that
the bounce parser will process it as such, which is good enough for
automatic bounce processing to work.

=cut
sub _gen_bounces {
  my $self = shift;
  my $log   = new Log::In 140;
  my($ch, $dest, $fh, $file, $i, $sender);

  # We don't want to bouce recursively
  return if $self->{data}{nobounces};

  for $i (@{$self->{failed}}) {

    # Never send bounces to example.com
    next if $i->[1] =~ /example\.com$/;

    # Never send bounces to the bouncing address
    next if $i->[0] eq $i->[1];

    $file = "$self->{'file'}.flr";
    $sender = $i->[1];

    # XXX temporary file has original file name with ".flr" appended
    $fh = gensym();
    return unless (open $fh, ">$file");

    # create an error message resembling an exim bounce.
    print $fh <<EOM;
To: $sender
From: $sender
Subject: Majordomo Delivery Error

This message was created automatically by mail delivery software.
A Majordomo message could not be delivered to the following addresses:

EOM

    print $fh "  $i->[0]:\n";
    if ($i->[2]) {
      print $fh "    $i->[2] $i->[3]\n";
    }
    else {
      print $fh "    554 Connection timed out\n";
      print $fh "    (Probably from a DNS lookup)\n";
    }
    print $fh "-- Original message omitted --\n";
    close($fh)
      or $::log->abort("Unable to close file $self->{'file'}: $!");

    # Create a new Dest object to send the bounces
    $dest = new Mj::Deliver::Dest({ %{$self->{data}},
				    'nobounces' => 1,
				  },
				  $file,
				  '',
				  $self->{lhost},
				 );
    $dest->add($sender);
    undef $dest;

    # Delete the file
    unlink $file;
  }
  $self->{failed} = [];
}


=head1 COPYRIGHT

Copyright (c) 1997-2002 Jason Tibbitts for The Majordomo Development
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


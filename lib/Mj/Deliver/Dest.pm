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

=cut
sub new {
  my $type   = shift;
  my $class  = ref($type) || $type;
  my $data   = shift;
  my $file   = shift;
  my $single = shift;
  my $log   = new Log::In 150;
  my (@tmp1, $code, $fail, $i, $mess, $val);

  my $self = {};
  bless $self, $class;

  # Pull in sender and file
  $self->{'sender'} = $data->{'sender'};
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
  # This covers $data->{'numbatches'}, $data->{'nobatch'}, and none
  # specified
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
  $self->{'count'}      = 0;
  $self->{'subcount'}   = 0;
  $self->{'lastdom'}    = '';
  $self->{'stragglers'} = [];
  $self->{'addrs'}      = [];

  $self;
}

sub DESTROY {
  my $self = shift;
  my $log  = new Log::In 150;
  $self->flush if scalar @{$self->{'addrs'}};
}

use AutoLoader 'AUTOLOAD';
1;
__END__

=head2 openenvelope

This opens an envelope to the given host (as an index into the activehosts
array) if necessary.  This is kind of gross, since it has a simple return
but lots of side effects.  This is necessary because killing a host changes
the activehosts array, which might change the whole reason we''re trying to
open an envelope... Besides, this is really separate to cut down on the
size of the add function.

We must exit with the current host, because we might have changed it.

If host eq '@qmail', open a QQEnvelope.  If host eq '@sendmail', open a
SMEnvelope (not implemented).

A system of retries is in place so that we don''t give up on delivery
unless we absolutely have to.  We try three times to connect to any host,
and if we do not succeed, then we remove it from consideration.  After any
one host fails, we activate all of the backup hosts.  After all hosts and
backup hosts have failed, wwe go into emergency mode where we try to talk
to the XMTP server running on our machine.  We wait progressively longer
amounts of time to make a connection.  If we continue to be unable to make
a connection, we activate all of the hosts and backups and the local host
and keep trying.  If this fails several times (with progressively longer
amounts of waiting), we finally abort.

=cut
# use Data::Dumper;
# sub openenvelope {
#   my $self = shift;
#   my $log  = new Log::In 150;
#   my($ch, %data, $host, $i, $j);

#   $ch = $self->{'currenthost'};
#   $i = 0;
#   while (!$self->{'envelopes'}[$ch]) {
#     $host = $self->{'activehosts'}[$ch];
    
#     if ($self->{'hostdata'}{$host}) {
#       %data = %{$self->{'hostdata'}{$host}};
#     }

#     if (lc($host) eq '@qmail') {
#       $self->make_qqenvelope($ch);
#     }
#     else {
#       $self->make_envelope($ch);
#     }

#     # If we got an envelope, we're done
#     last if $self->{'envelopes'}[$ch];

#     # Else we have a problem...
#     $i++;
#     if ($self->{'emergency'} && $i > 10) {
#       $log->abort("Could not deliver, even in emergency mode!");
#     }

#     # We try three times...
#     if ($i > 3) {
#       # This host is hosed; delete it from the active list and shrink the
#       # envelope list as well.
#       splice(@{$self->{'activehosts'}}, $ch, 1);
#       splice(@{$self->{'envelopes'}},   $ch, 1);

#       # Activate the backups if we haven't done so already.
#       if ($self->{'failures'} == 0) {
# 	push(@{$self->{'activehosts'}}, @{$self->{'backuplist'}});
# 	$log->complain("Activating backup delivery hosts!");
#       }

#       # Start the counter at zero again
#       $i = 0 unless $self->{'emergency'};
#       $self->{'failures'}++;
      
#       # Fix the host pointer if we deleted the end of the list.  This could
#       # cause us to stop failing if we don't have to open another envelope,
#       # hence the while loop condition.  Note that a zero modulus is
#       # illegal.
#       $ch = $ch % (@{$self->{'activehosts'}} || 1);

#       # Shift into emergency mode if we're out of hosts; make sure we
#       # always have localhost in the list if we've emptied it.
#       unless (@{$self->{'activehosts'}}) {
# 	$self->{'activehosts'} = ['localhost'];
# 	$log->complain("Going into emergency delivery mode!")
# 	  unless $self->{'emergency'};
# 	$self->{'emergency'} ||= 1;
#       }
#     }
#     if ($i > 7 && $self->{'emergency'} == 1) {
#       # We've tried just the emergency destination several times now and
#       # we're still not getting through.  So now we stuff all of the hosts
#       # back in, go into 'super emergency' mode, and try them all again
#       $self->{'activehosts'} = 
# 	[@{$self->{'hostlist'}}, @{$self->{'backuplist'}}, 'localhost'];      
#       $log->complain("Going into super-emergency delivery mode!")
# 	unless $self->{'emergency'} == 2;
#       $self->{'emergency'} = 2;
#     }
    
#     # Wait a while, waiting longer the more we fail
#     sleep 10*$i*$self->{'emergency'} + 5;
#   }

#   print Dumper $self;
#   $ch;
# }

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
			       %{$self->{'hostdata'}{$host}},
			      );
  1;
}


=head2 make_qqenvelops(currenthost)

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
  my(%data, $ch, $i, $ok);

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
      else {
	$self->{'envelopes'}[$ch] = $self->make_envelope($ch);
      }
    }
    
    # If that failed, continue and try again
    next unless $self->{'envelopes'}[$ch];

    # We're guaranteed to have an envelope.  Address it and fall through to
    # error processing of we couldn't.
    $ok = $self->{'envelopes'}[$ch]->address($self->{'addrs'});
    next if $ok == 0;

    if ($ok < 0 && @{$self->{'addrs'}} == 1) {
      # We only had one address and it had a non-fatal error (meaning that
      # there was a problem with just that address, but no real problems
      # with the transaction), so we quit without sending anything and
      # without changing the current host XXX What happens if we have more
      # than one address and receive a non-fatal error?  Currently we're
      # just assuming that one of them succeeded, but what we really care
      # about is whether or not one or more of them made it through.
      # Otherwise we're sending an unaddressed envelope.  We could have the
      # address method return a count of successfully sent addresses.
      return 1;
    }

    # We addressed the envelope OK, so we can send it
    $ok = $self->{'envelopes'}[$ch]->send;
    last if $ok;

    # We fall off the block and do error processing here.
  }

  # This catches any errors in the sending process; if wa fail at any point
  # we retry, nuke and acrivate backups, or go into emergency mode.  We
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

=cut
sub add {
  my $self  = shift;
  my $addr  = shift;
  my $dom   = shift; # Actually the canonical address
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
      $self->sendenvelope;
      $self->{'count'} = 0;
      $self->{'addrs'} = [];
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
	$self->sendenvelope;
#	print "Sending...\n";
	$self->{'count'} = 0;
	$self->{'addrs'} = [];
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

	# Nope; stuff what we've collected into the straggler list
	push @{$self->{'stragglers'}}, @{$self->{'addrs'}};
#	print "Pushing to stragglers...\n";
	$self->{'addrs'} = [];
	$self->{'count'} = 0;
	$self->{'subcount'}++;

	# Do we need to push out the stragglers?
	if ($self->{'subcount'} >= $self->{'subsize'}) {
	  $self->{'addrs'} = $self->{'stragglers'};
	  $self->sendenvelope;
#	  print "Sending stragglers...\n";
	  $self->{'subcount'} = 0;
	  $self->{'addrs'} = [];
	  $self->{'stragglers'} = [];
	}
      }
      else {

#	print "Got enough...\n";

	# Yep; send them out
	$self->sendenvelope;
#	print "Sending separates...\n";
	$self->{'addrs'} = [];
	$self->{'count'} = 0;
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

=head2 flush

This causes all remaining addresses to be sent.  If sorting is active, the
list is sorted and pushed out.

=cut
sub flush {
  my $self = shift;
  my $log  = new Log::In 150;

  if (@{$self->{'stragglers'}}) {
    if (@{$self->{'addrs'}} >= $self->{'size'}) {
      $self->sendenvelope;
#      print "Flushing stragglers...\n";
      $self->{'addrs'} = $self->{'stragglers'};
      $self->{'stragglers'} = [];
    }
    else {
      push @{$self->{'addrs'}}, @{$self->{'stragglers'}};
    }
  }
  if (@{$self->{'addrs'}}) {
    $self->sendenvelope;
#    print "Flushing addrs...\n";
    $self->{'addrs'} = [];
  }
}

=head2 sender

Set the sender separate from instantiation; to allow the sender to be
changed after the fact.  Note that since a dest caches all of its
envelopes, this requires that each envelope''s sender be changed.  These
changes only take effect _after_ the next envelope init.

=cut
sub sender {
  my $self   = shift;
  my $sender = shift;

  $self->{sender} = $sender;
  for my $env (@{$self->{envelopes}}) {
    $env->sender($sender);
  }
}

=head1 COPYRIGHT

Copyright (c) 1997, 1998 Jason Tibbitts for The Majordomo Development
Group.  All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the license detailed in the LICENSE file of the
Majordomo2 distribution.

his program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the Majordomo2 LICENSE file for more
detailed information.

=cut

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***


=head1 NAME

Mj::Deliver - The main Majordomo mail distribution function

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This provides the functionality that distributes mail efficiently to
members of a mailing list.  This functionality is internally provided by a
collection of objects which handle mail delivery.  Everything is done
either by speaking SMTP or communicating directly with the qmail queueing
system, so Majordomo is freed from the impossible-to-secure outgoing alias,
from calling sendmail, and from having to deliver mail on the same machine
that Majordomo runs on.

At the lowest level is the Connection object, which encapsulates a
bidirectional communication channel.

Above that is the SMTP object, which implements SMTP (and some of ESMTP) on
a Connection.

Above that is an Envelope, which contains an SMTP object and which keeps
track of its state.

Parallel to the Envelope is the QQEnvelope, which communicates with the
internal qmail queueing mechanism.

The list will be scanned only once and deliveries to each class will happen
in parallel; thus, when a set of messages is available to be delivered, one
large set of classes should be built up and passed to this routine all at
once.

=cut

package Mj::Deliver;
use strict;
use Mj::Log;
use Safe;
use Mj::Deliver::Dest;
use Mj::Deliver::Sorter;
use Mj::Deliver::Prober;

=head2 deliver(arghash)

This routine delivers mail to a set of addresses extracted from the
subscriber database of a list.  It does so by making various network
connections and speaking SMTP.

This routine takes the following named arguments:

  list    - ref to list object 
  sender  - base part of message sender
  classes - a hashref: each key is an extended class name; each value is a
            hashref with the following keys:
            file    - the name of the file to mail
            exclude - a hashrtef of canonical addresses (the values are not
                      used but should be true) that mail won''t be sent to.
  rules   - hashref containing parsed delivery rules
  chunk   - size of various structures
  seqnum  - message sequence number
  manip   - do extended sender manipulation
  probe   - do bounce probe
  sendsep - extended sender separator
  regexp  - regular expression matching addresses to probe
  buckets - total number of different probe groups
  bucket  - the group to probe
  probeall- do a _complete_ probe

listref is a list object (not the name of a list).  Only the iterator
methods get_start, get_done and get_matching_chunk are required but the
object must return reasonable values for the various fields.

sender is the envelope sender.  For bounce probing, this will be augmented
in some fashion.

file is the name of a file containing the complete message (headers and
all)

class is the address class to deliver to.

rules is a hashref of parsed delivery rules.  A simple set of default rules
will be used if not provided.

chunk controls the size of some internal lists.

The exclude hash contains keys of addresses in canonical form; mail will
not be sent to them even if they otherwise match.  (The values are unused
but should be true.) This is to allow people not to receive their own
messages, or for those who receive a copy via CC to not receive one via the
list.  Run these through alias processing before calling this routine.

sendsep should be set to a single character, used to separate the user from
the "mailbox argument".  This is '+' for sendmail and '-' for qmail.

manip indicates that extended sender manipulation should be done.  This
currently amounts to adding information about the message sequence number.

probe is a flag indicating whether or not a bounce probe is done.  Doing a
bounce probe entails using a modified 'rules' which places only one address
per envelope.  The sender address for these envelopes will be unique,
enabling the source of any bounces to be pinpointed exactly.

regexp indicates that all matching addresses will be probed.

seqnum, if present, allows the message number to be used in the extended
sender information.

buckets and bucket control bucket-based probing.  This breaks the addresses
up into groups by a checksum, then probes one of the groups.  buckets sets
the total number of groups, while bucket selects the group to probe.

=cut
use Bf::Sender;
sub deliver {
  my %args = @_;
  my $log  = new Log::In 150;

  my (@data, $addr, $canon, $classes, $datref, $dests, $eclass, $error, $i,
      $j, $matcher, $ok, $probeit, $probes );

  my $rules  = $args{rules};
  my $list   = $args{list};

  # Allocate destinations and probers and do some other setup stuff
  ($classes, $dests, $probes) = _setup($rules, %args);

  $matcher = sub {
    shift;
    return 1 if $classes->{(shift)->{class}};
    0;
  };

  ($ok, $error) = $list->get_start;
  return ($ok, $error) unless $ok;
  
  while (1) {
    @data = $list->get_matching_chunk($args{chunk}, $matcher);
    last unless @data;
    
    # Add each address to the appropriate destination.
  ADDR:
    while (($canon, $datref) = splice(@data, 0, 2)) {
      $eclass = _eclass($datref);

      # Stupid autovivification
      next unless $args{classes}{$eclass};
      next if $args{classes}{$eclass}{exclude}{$canon};

      $addr = $datref->{'stripaddr'};
      # Do we probe? XXX Also check bounce status and probe
      # possibly-bouncing addresses.
      $probeit =
	($args{probe} &&
	 ($args{probeall} ||
	  ($args{regexp} && Majordomo::re_match($args{regexp}, $addr)) ||
	  (defined $args{bucket} &&
	   $args{bucket} == (unpack("%16C*", $addr) % $args{buckets})
	  )));

      for ($i=0; $i<@$rules; $i++) {
	if (Majordomo::_re_match($rules->[$i]{'re'}, $addr)) {
	  if ($probeit) {
	    if ($eclass eq 'all') {
	      for $j (keys %{$args{classes}}) {
		$probes->{$j}[$i]->add($addr, $canon);
	      }
	    }
	    else {
	      $probes->{$eclass}[$i]->add($addr, $canon);
	    }
	  }
	  else {
	    if ($eclass eq 'all') {
	      for $j (keys %{$args{classes}}) {
		$dests->{$j}[$i]->add($addr, $canon);
	      }
	    }
	    else {
	      $dests->{$eclass}[$i]->add($addr, $canon);
	    }
	  }
	  next ADDR;
	}
      }
    }
  }
  
  # Close the iterator.
  ($ok, $error) = $list->get_done;
  return ($ok, $error);

  # Rely on destruction to flush the destinations
}

=head2 _setup

Properly allocates destinations and probers for each of the classes.

=cut
sub _setup {
  my $rules = shift;
  my %args= @_;
  my $log = new Log::In 150;
  my ($i, $j, $classes, $dests, $probes);
  $classes = {all => 1}; $dests = {}; $probes = {};

  # Deal with extended sender manipulation if requested
  if ($args{manip}) {
    $args{sender} = Bf::Sender::M_regular_sender($args{sender}, $args{sendsep},
						 $args{seqnum});
  }

  # Move the sender into the rules; this makes the calling sequence a bit
  # simpler
  for ($i=0; $i<@{$rules}; $i++) {
    $rules->[$i]{'data'}{'sender'} = $args{sender};
  }

  # Loop over all of the classes.
  for $i (keys %{$args{classes}}) {
    # Get the base class and stuff it in a hash for quick lookups.
    $i =~ /([^-]+).*/;
    $classes->{$1} = 1;

    # If we're doing any normal delivery (i.e. we're not probing or we're
    # doing incremental or regexp probing), allocate the destinations; if
    # we're sorting, allocate sorters instead
    if (!$args{'probe'} || defined($args{'bucket'}) || $args{'regexp'}) {
      for ($j=0; $j<@{$rules}; $j++) {
	if (exists $rules->[$j]{'data'}{'sort'}) {
	  $dests->{$i}[$j] =
	    new Mj::Deliver::Sorter($rules->[$j]{'data'},
				    $args{classes}{$i}{file},
				   );
	}
	# Need a non-sorting Sorter to count the addresses for numbatches
	elsif ($rules->[$j]{'data'}{'numbatches'} &&
	       $rules->[$j]{'data'}{'numbatches'} > 1)
	  {
	    $dests->{$i}[$j] =
	      new Mj::Deliver::Sorter($rules->[$j]{'data'},
				      $args{classes}{$i}{file},
				      'nosort',
				     );
	  }
	# Nothing special, so allocate a plain destination
	else {
	  $dests->{$i}[$j] =
	    new Mj::Deliver::Dest($rules->[$j]{'data'},
				  $args{classes}{$i}{file},
				 );
	}
      }
    }
  
    # If we're probing, allocate a separate set of destinations for the probes
    if ($args{probe}) {
      for ($j=0; $j<@{$rules}; $j++) {
	$probes->{$i}[$j] =
	  new Mj::Deliver::Prober($rules->[$j]{'data'},
				  $args{classes}{$i}{file},
				  $args{seqnum},
				  $args{sendsep},
				 );
      }
    }
  }
  ($classes, $dests, $probes);
}

=head2 _eclass

This returns the extended class for a given piece of subscriber data.

=cut
sub _eclass {
  my $data = shift;
  my ($class, $flags);

  $class = $data->{class};

  # First deal with 'each'; this is the common case, so it comes first.
  # Use the 'P' and 'R' flags to determine the class name.
  if ($class eq 'each') {
    $flags = $data->{flags};
    return "each-" . (index($flags, 'P')<0 ? 'noprefix-' : 'prefix-') .
      (index($flags, 'R')<0 ? 'noreplyto' : 'replyto');
  }

  # 'digest' just uses the two class arguments
  if ($class eq 'digest') {
    return "digest-$data->{classarg}-$data->{classarg2}";
  }

  # Everything else goes through unchanged
  return $class;
}

# sub _re_match {
#   my $safe = shift;
#   my $re   = shift;
#   my $addr = shift;
# #  my $log  = new Log::In 200, "$re, $addr";
#   my $match;
#   return 1 if $re eq 'ALL';

# #   # Hack; untaint $addr
# #   $addr =~ /./;
# #   $addr = $1;

#   $match = $safe->reval("'$addr' =~ $re");
#   $::log->complain("_re_match error: $@") if $@;
#   return $match;
# }

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

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

=cut

package Mj::Deliver;
use Mj::Log;
use Safe;
use Mj::Deliver::Dest;
use Mj::Deliver::Sorter;
use Mj::Deliver::Prober;

=head2 deliver(arghash)

This routine delivers mail to a set of addresses extracted from the
subscriber database of a list.  It does so by making various network
connections and speaking SMTP.

This routine takes the following named arguments (R indicates that the
argument is required, P indicates that the argument only makes sense if
'probe' is true):

R list    - ref to list object 
R sender  - base part of message sender
R file    - file to mail
R class   - address class to mail to
  rules   - hashref containing parsed delivery rules
  chunk   - size of various structures
  exclude - listref of addresses _not_ to send to
  seqnum  - message sequence number
  manip   - do extended sender manipulation
  probe   - do bounce probe
P sendsep - extended sender separator
P regexp  - regular expression matching addresses to probe
P buckets - total number of different probe groups
P bucket  - the group to probe
P probeall- do a _complete_ probe

listref is a list object (not the name of a list).  Only the iterator
methods get_start, get_done and get_matching_chunk are required.

sender is the envelope sender.  For bounce probing, this will be augmented
in some fashion.

file is the name of a file containing the complete message (headers and
all)

class is the address class to deliver to.

rules is a hashref of parsed delivery rules.  A simple set of default rules
will be used if not provided.

chunk controls the size of some internal lists.

The exclude list is a list of addresses in canonical form; mail will not be
sent to them even if they otherwise match.  This is to allow people not to
receive their own messages, or for those who receive a copy via CC to not
receive one via the list.  Run these through alias processing before
calling this routine.

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
  my $log  = new Log::In 150, "$args{list}, $args{file}, $args{class}";

  my (%exclude, @addrs, @data, @dests, @probes, $addr, $canon, $datref, $i,
      $n, $ok, $error, $probeit);

  my $file   = $args{file};
  my $sender = $args{sender};
  my $rules  = $args{rules};
  my $class  = $args{class};
  my $list   = $args{list};
  my $chunk  = $args{chunk};

  my $safe = new Safe;
  $safe->permit_only(qw(const leaveeval null pushmark return rv2sv stub));
#  $safe->share('$addr');

  # Make a hash so we can tell if an address is to be excluded quickly
  for $i (@{$args{exclude}}) {
    $exclude{$i} = 1;
  }

  # Deal with extended sender manipulation
  if ($args{manip}) {
    $sender = Bf::Sender::M_regular_sender($sender, $args{sendsep}, $args{seqnum});
  }
    
  # Fill in a bit of info
  for ($i=0; $i<@{$rules}; $i++) {
    $rules->[$i]{'data'}{'sender'} = $sender;
    $rules->[$i]{'data'}{'file'}   = $file;
  }

  # If we're doing any normal delivery (i.e. we're not probing or we're
  # doing incremental or regexp probing), allocate the destinations; if
  # we're sorting, allocate sorters instead
  if (!$args{'probe'} || defined($args{'bucket'}) || $args{'regexp'}) {
    for ($i=0; $i<@{$rules}; $i++) {
      if (exists $rules->[$i]{'data'}{'sort'}) {
	$dests[$i] = new Mj::Deliver::Sorter $rules->[$i]{'data'};
      }
      
      # Need a non-sorting Sorter to count the addresses for numbatches
      elsif ($rules->[$i]{'data'}{'numbatches'} &&
	     $rules->[$i]{'data'}{'numbatches'} > 1)
	{
	  $dests[$i] = new Mj::Deliver::Sorter $rules->[$i]{'data'}, 'nosort';
	}
      else {
	$dests[$i] = new Mj::Deliver::Dest $rules->[$i]{'data'};
      }
    }
  }
  
  # If we're probing, allocate a separate set of destinations for the probes
  if ($args{probe}) {
    for ($i=0; $i<@{$rules}; $i++) {
      $probes[$i] =
	new Mj::Deliver::Prober($rules->[$i]{'data'},
				$args{seqnum},
				$args{sendsep},
			       );
    }
  }

  ($ok, $error) = $list->get_start;
  return ($ok, $error) unless $ok;
  
  while (1) {
    @data = $list->get_matching_chunk($chunk, 'class', $class);
    last unless @data;
    
    # Add each address to the appropriate destination.
  ADDR:
    while (($canon, $datref) = splice(@data, 0, 2)) {
      next if $exclude{$canon};
      $addr = $datref->{'stripaddr'};

      # Do we probe?
      $probeit =
	($args{probe} &&
	 ($args{probeall} ||
	  ($args{regexp} && _re_match($safe, $args{regexp}, $addr)) ||
	  (defined $args{bucket} &&
	   $args{bucket} == (unpack("%16C*", $addr) % $args{buckets})
	  )));

      for ($i=0; $i<@$rules; $i++) {
	# Eval the RE in a Safe compartment, or look for ALL
	if (_re_match($safe, $rules->[$i]{'re'}, $addr)) {
	  $probeit ? $probes[$i]->add($addr, $canon) : $dests[$i]->add($addr, $canon);
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

sub _re_match {
  my $safe = shift;
  my $re   = shift;
  my $addr = shift;
#  my $log  = new Log::In 200, "$re, $addr";
  my $match;
  return 1 if $re eq 'ALL';

#   # Hack; untaint $addr
#   $addr =~ /./;
#   $addr = $1;

  $match = $safe->reval("'$addr' =~ $re");
  $::log->complain("_re_match error: $@") if $@;
  return $match;
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

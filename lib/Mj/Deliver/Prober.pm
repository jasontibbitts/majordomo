=head1 NAME

Mj::Deliver::Prober - Bounce probing object

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This is an object that takes addresses, generates an appropriate sender
from them, and passes them an Mj::Deliver::Dest for delivery.

=cut

package Mj::Deliver::Prober;
use Mj::Log;
use Mj::Deliver::Dest;
use Bf::Sender;

=head2 new(arghash)

This creates a prober object.

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;
  my $data  = shift;
  my $file  = shift;
  my $sender= shift;
  my $snum  = shift;
  my $sep   = shift;
  my $lhost = shift;
  my $log   = new Log::In 150, "$sender, $snum, $sep";

  my $self = {};
  bless $self, $class;

  $self->{'data'}    = $data;
  $self->{'dest'}    = Mj::Deliver::Dest->new($self->{'data'}, $file, 
                                              '', $lhost, 'single');
  $self->{'sender'}  = $sender;
  $self->{'seqnum'}  = $snum;
  $self->{'sendsep'} = $sep;
  $self->{'addrs'} = [];
  $self;
}

sub DESTROY {
  1;
}

=head2 add

This adds an address and domain to the object.

=cut
sub add {
  my $self  = shift;
  my $addr  = shift;
  my $canon = shift;
#  my $log   = new Log::In 150, "$addr, $dom";

  # Generate an appropriate sender.
  my $sender =
    Bf::Sender::any_probe_sender($self->{sender},
			       $self->{sendsep},
			       $self->{seqnum},
			       $addr,
			      );

  # Set the dest's sender
  $self->{'dest'}->sender($sender);

  # Add the addr to the Dest.
  $self->{'dest'}->add($addr, $canon);

  # Flush the dest.  (It will flush anyway, and we want it to happen now to
  # keep things simple because we're playing around with the sender.)
  $self->{'dest'}->flush;
}

=head2 flush

This is a noop.  We don''t ever keep any unflushed addresses around.

=cut
sub flush {
  1;
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


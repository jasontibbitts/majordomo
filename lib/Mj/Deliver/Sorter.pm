=head1 NAME

Mj::Deliver::Sorter - Address list sorting object

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This is an object that takes addresses, optionally sorts them, and passes
them to an Mj::Deliver::Dest for delivery when it''s destroyed.

=cut

package Mj::Deliver::Sorter;
use Mj::Log;
use Mj::Deliver::Dest;

=head2 new(arghash, nosort)

This creates a sorter object.  If nosort is true, the data will not be
sorted but its size will be computed anyway.

=cut
sub new {
  my $type   = shift;
  my $class  = ref($type) || $type;
  my %args   = @_;
  my $log    = new Log::In 150;

  my $self = {};
  bless $self, $class;

  $self->{'data'}   = $args{data};
  $self->{'file'}   = $args{file};
  $self->{'lhost'}  = $args{lhost};
  $self->{'sender'} = $args{sender};
  $self->{'nosort'} = $args{nosort};
  $self->{'addrs'}  = [];
  $self;
}

sub DESTROY {
  my $self = shift;
  my $log  = new Log::In 150;
  $self->flush;
}

=head2 add

This adds an address and domain to the object.

=cut
sub add {
  my $self  = shift;
  my $addr  = shift;
  my $dom   = shift; # Actually the canonical address
#  my $log   = new Log::In 150, "$addr, $dom";

  # Extract that domain from the canonical address
  $dom =~ s/.*@//;

  # Stuff the address and reversed domain for safe keeping.  We reverse the
  # domain because it saves time in sorting (we only reverse once) and the
  # order doesn't matter for exact string comparisons.
  push @{$self->{'addrs'}}, [$addr, lc scalar reverse $dom ];
}

=head2 flush

This actualy performs the sorting (if desired), allocates an
Mj::Deliver::Dest, and runs the sorted (and sized) list through it.

=cut
sub flush {
  my $self = shift;
  my $log  = new Log::In 150;
  my($dest);

  unless ($self->{'nosort'}) {
    $self->{'addrs'} = [ sort  { $a->[1] cmp $b->[1] } @{$self->{'addrs'}} ];
  }

  $self->{'data'}{'total'} = scalar(@{$self->{'addrs'}});
#  print "Allocating Dest\n";
  $dest = Mj::Deliver::Dest->new(data   => $self->{'data'},
                                 file   => $self->{'file'},
                                 sender => $self->{'sender'},
                                 lhost  => $self->{'lhost'}
				);
#  print "Allocated Dest\n";

  for (my $i=0; $i < @{$self->{'addrs'}}; $i++) {
    $dest->add(@{$self->{'addrs'}[$i]});
  }
  $self->{'addrs'} = [];

  # Rely on destruction to flush $dest
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


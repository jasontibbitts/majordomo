=head1 NAME

Mj::AlistList.pm - An object containing address aliases and equivalencies.

=head1 DESCRIPTION

This encapsulates a simple database of aliases, linking one address to
another so that they will compare as equivalent for all intents and
purposes.

Many have been interested in linking this alias functionality into some
other database that their site offers.  This should be a relatively simple
task.  If it is assumed that such a database will only be a source of
additional aliases, then the only routine that needs additional
intelligence is the lookup routine.  This should perform a query to the
database server somewhere in that routine.  There are probably other areas
that I neglected to consider, like what happens when removing aliases.  (A
lookup may see that there is an alias to remove when in reality it isn''t
removable.)

What about global aliases?  What about sharing aliases between lists?

=head1 SYNOPSIS

blah

=cut

package Mj::AliasList;
use Mj::SimpleDB;
use strict;
use vars qw($AUTOLOAD);

my @fields = qw(target fullsource fulltarget changetime);

=head2 new(path)

This allocates an AliasList by making a SimpleDB object with the fields we
use.  We use delegation (a 'using' relationship instead of an 'is a'
relationship) because of the nultiplexing nature of SimpleDB.

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;

  my $path = shift;
  my $back = shift;

  my $ref = new Mj::SimpleDB $path, $back, \@fields;
  bless {delegate => $ref}, $class;
}

sub AUTOLOAD {
  no strict 'refs';
  my $self = shift;
  $AUTOLOAD =~ s/.*://;
  $self->{delegate}->$AUTOLOAD(@_);
}

=head2 add

This adds an alias.  We need to check several extra conditions in order to
prevent cycles and chains.

There are possible problems here.  If a user subscribes to a list, then
aliases their address to something which is not subscribed, they may be
unable to unsubscribe (or post, etc.).  A solution is to limit aliasing
_to_ addresses which are already subscribed (but not here).  Unsubscription
should remove any existing aliases.

add a -> b :  a -> c? fail, already aliased (for any c)
              b -> c? fail, chain

=cut
sub add {
  my $self = shift;
  my $mode = shift;
  my $key  = shift;
  my $args = shift;
  my ($data);
 
  $::log->in(120, "$key");

  # Perform all operations on the real SimpleDB backend.
  $self = $self->{delegate};
  
  # If the source is aliased to anything, die.
  if ($data = $self->lookup($key)) {
    $::log->out("failed");
    return (0, "$args->{'fullsource'} is already aliased (to $data->{'target'}).\n");
  }
  
  $data = $self->lookup($args->{'target'});

  # If the target is aliased to anything but itself, die.
  if ((defined $data) && $data->{'target'} ne $args->{'target'}) {
    $::log->out("failed");
    return (0, "$args->{'target'} is aliased to $data->{'target'}; chains not allowed.\n");
  }
  
  # Add the key to the database; we can force this because we already did
  # the lookup earlier.
  $self->add("force", $key, $args);
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
### mode:cperl ***
### cperl-indent-level:2 ***
### End: ***

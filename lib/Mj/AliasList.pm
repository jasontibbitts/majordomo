=head1 NAME

Mj::AliasList.pm - An object containing address aliases and equivalencies.

=head1 DESCRIPTION

This encapsulates a simple database of aliases, linking one address to
another so that they will compare as equivalent for all intents and
purposes.  The main purpose of an alias is to allow people to 
issue commands or post messages from more than one e-mail address.

Each alias has a source and a target.  For example, if jane@example.org
issues an alias command for the address jane@example.edu:

  default user jane@example.org  
  alias jane@example.edu

The address "jane@example.edu" is the source, and the address
"jane@example.org" is the target.

Whenever a new alias is created, two entries are added to the alias
database.  The key of the first entry is the xformed address of the
source; the key of the second ("bookkeeping") entry is the xformed
address of the target.  Each of the two entries has identical data.

The following data are stored for each alias:

  target      - The target address
  stripsource - The source address, with any comments removed
  striptarget - The target address, with any comments removed
  changetime  - The time at which the data was last changed

Many have been interested in linking this alias functionality into some
other database that their site offers.  This should be a relatively simple
task.  If it is assumed that such a database will only be a source of
additional aliases, then the only routine that needs additional
intelligence is the lookup routine.  This should perform a query to the
database server somewhere in that routine.  There are probably other areas
that I neglected to consider, like what happens when removing aliases.  (A
lookup may see that there is an alias to remove when in reality it isn''t
removable.)


=head1 SYNOPSIS

blah

=cut

package Mj::AliasList;
use Mj::SimpleDB;
use strict;
use vars qw($AUTOLOAD);

my @fields = qw(target stripsource striptarget changetime);

=head2 new(path)

This allocates an AliasList by making a SimpleDB object with the fields we
use.  We use delegation (a 'using' relationship instead of an 'is a'
relationship) because of the multiplexing nature of SimpleDB.

=cut
sub new {
  my ( $type, %args ) = @_;
  my $class = ref($type) || $type;

  my $ref = new Mj::SimpleDB(%args, fields => \@fields );

  bless {delegate => $ref}, $class;
}

sub AUTOLOAD {
  no strict 'refs';
  my $self = shift;
  $AUTOLOAD =~ s/.*://;
  $self->{delegate}->$AUTOLOAD(@_) if ref $self->{delegate};
}

=head2 add

This adds an alias.  We need to check several extra conditions in order to
prevent cycles and chains.

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
    return (0, "$args->{'stripsource'} is already aliased (to $data->{'target'}).\n");
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

Copyright (c) 1997, 1998, 2002, 2004 Jason Tibbitts for The Majordomo
Development Group.  All rights reserved.

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
### mode:cperl ***
### cperl-indent-level:2 ***
### End: ***

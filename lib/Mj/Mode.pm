=head1 NAME

Mj::Mode - Mode object for Majordomo

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This implements a Mode object, which provides structure and error checking
for Majordomo mode strings.

=cut

package Mj::Mode;
use strict;

#use Mj::Log;
use overload 
  '=='   => \&match,
  'eq'   => \&match,
  '""'   => \&stringify;

=head2 new(template, modestr)

This allocates and returns an Mj::Mode object using the given template and
the given string as the mode.  If the passed value is already an Mj::Mode
object, it will just be returned.  This lets you do

  $mode = new Mj::Mode($mode)

without worring about whether you were passed a mode object or a plain string.

The string does not have to be a valid mode, but various calls will return
the empty string if it is not.  If having a valid mode is important, a call
to the 'valid' method should be made shortly afterwards calling this
function.

Class layout:

template - the structure describing the allowed modes.
modes    - hashref of modes as keys

Note that this object does not preserve the order of the individual modes
in a mode string.

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;
  my $self  = {};
  $self->{'template'} = shift;
  my $val   = shift;

  # Bail if creating a Mode from a Mode
  return $val if ref($val) eq 'Mj::Mode';

  $self->{'string'} = $val;
  return undef unless $self->{'full'};

  bless $self, $class;

  # Parse apart the mode string 
}

=head2 stringify

Returns the canonical string representation of the mode.

=cut
sub stringify {
  my $self = shift;
  return join('-', keys($self->{'modes'}));
}

=head1 COPYRIGHT

Copyright (c) 2000 Jason Tibbitts for The Majordomo Development Group.  All
rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the license detailed in the LICENSE file of the
Majordomo2 distribution.

his program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the Majordomo2 LICENSE file for more
detailed information.

=cut

1;


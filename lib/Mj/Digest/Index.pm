=head1 NAME

Mj::Digest::Index.pm - Majordomo Index digest building routines

=head1 SYNOPSIS

Mj::Digest::MIME

=head1 DESCRIPTION

This module implements an Index digest object. (That is, one which includes
only an index of messages instead of the messages themselves.)  Call 'new'
to allocate the object and pass in interesting parameters like index
format, headers and such.  Then call add to pass in each message and call
done to get the complete digest in a file.

=cut

package Mj::Digest::Index;

use strict;
use Mj::Log;
use MIME::Entity;

=head2 new

Allocates an Index digest.

The following args are required:

  subject - the subject of the digest message.  Do appropriate
            substitutions before calling this function.
  indexfn - funcref to a function which generates an index line.

index_header, index_fronter, fronter, footer

=cut
sub new {
  my $type = shift;
  my %args = @_;
  my $class= ref($type) || $type;
  my $log  = new Log::In 150;
  my $self = {};
  bless $self, $class;

  $self->{'indexfn'} = $args{'indexfn'};
  $self->{'count'} = 0;
  $self->{'index'} = $args{'index_header'} || '';
  $self->{'subject'} = $args{'subject'} || '';
  $self;
}

=head2 DESTROY

The entity must be purged so that the necessary tempfiles are released.

=cut
sub DESTROY {
  my $self = shift;
  $self->{'top'}->purge;
}

=head2 add

Adds a MIME::Entity to the digest object.

Takes a MIME::Entity, the message number and the archive index data.

=cut
sub add {
  my $self = shift;
  my %args = @_;
  my $log  = new Log::In 200, "$args{msg}";
  
  $self->{count}++;
  
  # Generate the index entry;
  $self->{'index'} .= &{$self->{'indexfn'}}('index', $args{'msg'}, $args{'data'});
}

=head2 done

Generates the digest and returns a filename containing it.  Be sure to
delete this file when finished.

=cut
sub done {
  my $self = shift;
  my ($fh, $file, $index);

  $self->{top} = build MIME::Entity
    (Type     => 'text/plain',
     Subject  => $self->{subject},
     Data     => $self->{'index'},
     Filename => undef,
     # More fields here
    );

  $file = Majordomo::tempname();
  $fh = new IO::File ">$file";

  $self->{top}->print($fh);
  $fh->close;
  $file;
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

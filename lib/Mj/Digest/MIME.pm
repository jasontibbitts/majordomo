=head1 NAME

Mj::Digest::MIME.pm - Majordomo MIME digest building routines

=head1 SYNOPSIS

Mj::Digest::MIME

=head1 DESCRIPTION

This module implements an RFC2046 MIME digest object with an index in the
suggested format (a multipart/mixed containing a text/plain part and a
multipart/digest part).  Call 'new' to allocate the object and pass in
interesting parameters like index format, headers and such.  Then call add
to pass in each message and call done to get the complete digest in a file.

=cut

package Mj::Digest::MIME;

use strict;
use Mj::Log;
use MIME::Entity;

=head2 new

Allocates a MIME digest.

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

  $self->{top} = build MIME::Entity
    (Type     => 'multipart/mixed',
     Subject  => $args{'subject'} || '',
     Filename => undef,
     # More fields here
    );
  $self->{digest} = build MIME::Entity
    (Type     => 'multipart/digest',
     Filename => undef,
    );
  $self->{indexfn} = $args{indexfn};
  $self->{count} = 0;
  $self->{index} = $args{index_header} || '';
  $self;
}

=head2 DESTROY

The entity must be purged so that the necessary tempfiles are released.

=cut
sub DESTROY {
  my $self = shift;
  $self->{top}->purge;
}

=head2 add

Adds a MIME::Entity to the digest object.

Takes a MIME::Entity, the message number and the archive index data.

=cut
sub add {
  my $self = shift;
  my %args = @_;
  my $log  = new Log::In 200, "$args{msg}";
  my ($ent);

  $self->{count}++;

  $ent = build MIME::Entity
    (Type        => 'message/rfc822',
     Description => $args{msg},
     Path        => $args{file},
     Filename    => undef,
    );

  $self->{digest}->add_part($ent);

  # Generate the index entry;
  $self->{index} .=
    &{$self->{indexfn}}('mime', $args{msg}, $args{data}, $ent);

  return $ent;
}

=head2 done

Generates the digest and returns a filename containing it.  Be sure to
delete this file when finished.

=cut
sub done {
  my $self = shift;
  my ($fh, $file, $index);

  $index = build MIME::Entity
    (Type        => 'text/plain',
     Desctiption => 'Index',
     Data        => $self->{index},
    );
  $self->{top}->add_part($index);
  $self->{top}->add_part($self->{digest});

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

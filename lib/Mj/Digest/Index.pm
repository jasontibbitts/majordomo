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

  footer        text placed at the end of the digest
  from          e-mail address of the sender
  headers       e-mail headers to be added to the digest
  indexfn       reference to a function which generates an index line
  postindex     text placed after the index of messages
  preindex      text placed before the index of messages
  subject       the subject of the digest message
  to            e-mail address of the recipient

=cut
sub new {
  my $type = shift;
  my %args = @_;
  my $class= ref($type) || $type;
  my $log  = new Log::In 150;
  my $self = {};
  my($fh, $i);
  bless $self, $class;

  $self->{'indexfn'} = $args{'indexfn'};
  $self->{'count'}   = 0;
  $self->{'subject'} = $args{'subject'} || '';
  $self->{'from'}    = $args{'from'};
  $self->{'to'}      = $args{'to'};
  $self->{'headers'} = $args{'headers'};

  # Pull in the index.
  $self->{'index'} = "";
  if ($args{preindex}) {
    $fh = new IO::File "<$args{preindex}{name}";
    while (defined($i = <$fh>)) {
      $self->{'index'} .= $i;
    }
  }

  # Save text matter for later use
  $self->{preindex}  = $args{preindex};
  $self->{postindex} = $args{postindex};
  $self->{footer}    = $args{footer};

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
use Date::Format;
sub done {
  my $self = shift;
  my ($fh, $file, $i, $index);

  # Pull in postindex data
  if ($self->{postindex}{name}) {
    $fh = new IO::File "<$self->{postindex}{name}";
    while (defined($i = <$fh>)) {
      $self->{'index'} .= $i;
    }
    $fh->close;
  }

  $self->{top} = build MIME::Entity
    (Type     => 'text/plain',
     Subject  => $self->{subject},
     From     => $self->{'from'},
     To       => $self->{'to'},
     Date     => time2str("%a, %d %b %Y %T %z", time),
     Encoding => '8bit',
     Filename => undef,
     Data     => $self->{'index'},
     # More fields here
    );

  for $i (@{$self->{headers}}) {
    $self->{top}->head->add($i->[0], $i->[1]);
  }

  $file = Majordomo::tempname();
  $fh = new IO::File ">$file";
  $::log->abort("Unable to open file $file: $!") unless ($fh);

  $self->{top}->print($fh);
  $fh->close()
    or $::log->abort("Unable to close file $file: $!");
  $file;
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
### cperl-indent-level:2 ***
### End: ***

=head1 NAME

Mj::Digest.pm - Majordomo digest object

=head1 SYNOPSIS

  $digest = new Mj::Digest parameters;

=head1 DESCRIPTION

This contains code for the Digest object, which encapsulates all message
digesting functionality for Majordomo.

A digest is a collection of messages enclosed in a single message;
internally, Majordomo represents digests as an object to which message
numbers (derived from the Archive object) are associated; when certain
conditions arise, some number of those messages are removed from the pool
and turned into a digest message which is sent to the proper recipients.

=cut

package Mj::Digest;
use AutoLoader 'AUTOLOAD';

use Mj::File;
use Mj::Log;
use strict;

1;
__END__

=head2 new(archive, dir, datahashref)

This creates a digest object.  dir is the place where the digest will store
its state file (volume, issue, pooled messages, etc).  archive is an
archive object already created that digest will use to do its message
retrieval.  The data hash should contain all of the data necessary to
operate the trigger decision mechanism and the build mechanism (generally
passed directly from the List object).  It will not be modified.

=cut
sub new {
  my $type  = shift;
  my $arc   = shift;
  my $dir   = shift;
  my $data  = shift;
  my $class = ref($type) || $type;
  my $log   = new Log::In 150, "$dir";
  my $self  = {};
  bless $self, $class;

  # Open state file if it exists

  return $self;
}

=head2 add(message, datehashref)

This adds a message to the digest''s message pool.  The information in the
data hash is used by the decision algorithm.

=cut
sub add {
   
}

=head2 volume(number)

This sets the volume number of the digest.  If number is not defined, the
existing number is simply incremented.

=cut
sub volume {
  my $self = shift;
  my $num  = shift;
  
  if (defined $num) {
    $self->{'state'}{'volume'} = $num;
  }
  else {
    $self->{'state'}{'volume'}++;
  }
  1;
}

=head2 trigger

This causes the digest to decide whether or not it should generate a
digest message.

=cut
sub trigger {

}

=head2 build

This actually builds the digest, given a list of message numbers.

First the index block is created, then this is passed to the individual
build_start methods.  Then each message is extracted form the archive and
passed to the build_one methods.  Then the build_done methods are called,
and the resultant filenames are passed out for eventual delivery.

=cut
;

=head2 build_mime_start

=cut
;

=head2 build_mime_one

=cut
;

=head2 build_mime_done

This builds a MIME-style digest.

=cut
;

=head2 build_1153_start
=head2 build_1153_one
=head2 build_1153_done

This builds an rfc1153 (old) style digest.

=cut

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


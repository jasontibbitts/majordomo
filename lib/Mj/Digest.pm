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

use IO::File;
use Mj::Log;
use strict;

#use AutoLoader 'AUTOLOAD';
1;
#__END__

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

  $self->{'archive'} = $arc;
  $self->{'dir'}     = $dir;
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

=head2 build(%args)

This actually builds the digest, given a list of message numbers.


 type     => the type of digest to build: MIME, 1153, HTML, index
 subject  => the subject header to be used
 messages => a listref of messages to build the digest out of 

=cut
sub build {





}

=head2 build_mime

This builds a MIME digest.  These have the following structure:

  multipart/mixed
    text/plain       - Index
    multipart/digest - Messages
      message/rfc822
      message/rfc822
      ...

=cut
use MIME::Entity;
use Data::Dumper;
sub build_mime {
  my $self = shift; 
  my %args = @_;
  my (@msgs, $count, $data, $digest, $file, $func, $i, $index, $indexf,
      $indexh, $tmp, $top);
  
  $count = 0;
  $top = build MIME::Entity
    (Type     => 'multipart/mixed',
     Subject  => $args{'subject'} || '',
     Filename => undef,
     # More fields here
    );
  $digest = build MIME::Entity
    (Type     => 'multipart/digest',
     Filename => undef,
    );

  $indexf = Majordomo::tempname();
  $indexh = new IO::File ">$indexf";
  $indexh->print($args{'index_header'}) if $args{'index_header'};

  # Extract all messages from the archive into files, building them into
  # entities and generating the index file.
  for $i (@{$args{'messages'}}) {
    ($data, $file) = $self->{'archive'}->get_to_file($i);
    unless ($data) {
      $indexh->print("  Message $i not in archive.\n");
      next;
    }
    $count++;
    {
      no strict 'refs';
      $func = "idx_$args{'index_line'}";
      $indexh->print(&$func($data));
    }
    $tmp = build MIME::Entity
      (Type        => 'message/rfc822',
       Description => "$i",
       Path        => $file,
       Filename    => undef,
      );
    $digest->add_part($tmp);
  }

  $indexh->print($args{'index_footer'}) if $args{'index_footer'};

  # Build index entry.
  $indexh->close;
  $index = build MIME::Entity
    (Type        => 'text/plain',
     Description => 'Index',
     Path        => $indexf,
     Filename    => undef,
    );
  $top->add_part($index);
  $top->add_part($digest);
  ($top, $count);
}

=head2 build_1153_start
=head2 build_1153_one
=head2 build_1153_done

This builds an rfc1153 (old) style digest.

=cut

=head2 idx_default

This formats an index line containing just the subject indented by two
spaces.

=cut
sub idx_default {
  my $data = shift;

  return "  $data->{'subject'}\n";
}

=head2 idx_wasilko

This formats an index line like the following:

  Today's your birthday, friend...                 [Mike Matthews <matthewm>]
  Chantal Kreviazuk                       ["J." Wermont <jwermont@sonic.net>]
  Re: Musical Tidbits from Ice Magazine  [Philip David Morgan <philipda@li.n]
  Re: Chantal Kreviazuk                                    [FAMarcus@aol.com]

Original code by Jeff Wasilko. '

=cut
sub idx_wasilko {
  my $data = shift;
  my ($from, $subj, $width);

  $subj = $data->{'subject'};
  if (length($subj) > 40) {
    return "  $subj\n" . (' ' x int(74-length($data->{'from'}))) .
      "[$data->{'from'}]\n";
  }

  $from = substr($data->{'from'},0,71-length($subj));
  $width = length($from) + length($subj);
  return "  $subj " . (' ' x int(71 - $width)) . "[$from]\n";
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


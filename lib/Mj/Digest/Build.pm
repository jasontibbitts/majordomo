=head1 NAME

Mj::Digest::Build.pm - Majordomo digest building routines

=head1 SYNOPSIS

Mj::Digest::Build::build(parameters);

=head1 DESCRIPTION

This module contains routines that are used to build digests.  These are
functions, not methods, and expect to be called with all necessary
parameters.  These generally include an Archive object and a list of
article names to be extracted from that object.

=cut

package Mj::Digest::Build;

use IO::File;
use Mj::Log;
use strict;

use AutoLoader 'AUTOLOAD';
1;
__END__

=head2 build

This builds a set of digests of various types from a list of messages.
Note that this is a function, not a method.

This returns a list of filenames containing the requested digests.  The
files pair with the respective entries in the passed 'types' array in
order.

Arguments taken:

  types - listref of types (MIME, text, index)
  messages - listref of message names (from archives).
  archive - ref to an archive object where the messages can be retrieved

usual digest data

=cut
use Mj::Digest::MIME;
use Mj::Digest::Index;
use Mj::Digest::Text;
sub build {
  my %args = @_;
  my $log = new Log::In 150;
  my (%legal, @digests, @files, $data, $file, $i, $idxfn,
      $idxfnref, $j, $msg, $parser, @nukes);

  %legal = ('mime' => 'MIME',
	    'text' => 'Text',
	    'index'=> 'Index',
	    );

  # Allow 'type' as a scalar argument instaed of 'types'
  if ($args{type} && !$args{types}) {
    $args{types} = [$args{type}];
  }

  # Figure out the name of the index function and get a ref to it for
  # callbacks.
  $idxfn    = "idx_$args{index_line}";
  $idxfnref = \&{$idxfn};

  # Set up the list of digests to be created
  for $i (@{$args{types}}) {
    next unless $legal{$i};
    my $obj = "Mj::Digest::$legal{$i}";
    push @digests, new $obj
      (subject      => $args{subject},
       indexfn      => $idxfnref,
       preindex     => $args{files}{$i}{'preindex'},
       postindex    => $args{files}{$i}{'postindex'},
       footer       => $args{files}{$i}{'footer'},
       tmpdir       => $args{tmpdir},
       from         => $args{from},
       to           => $args{to},
       headers      => $args{headers},
      );
  }

  # Loop over messages;
  for $i (@{$args{messages}}) {
    if (ref($i)) {
      $msg  = $i->[0];
      $data = $i->[1];
    }
    else {
      $msg = $i;
      $data = undef;
    }
    # Extract the message from the archives
    ($data, $file) = $args{'archive'}->get_to_file($msg, undef, $data);

    # Skip nonexistent messages (e.g., messages that were deleted from
    # the archive).
    next unless $data;

    # It is necessary to remove temporary files, since the
    # digest objects will not be accessed outside the
    # scope of this function.
    push @nukes, $file;

    # Loop over @digests.  Note that currently we ignore 
    # the parsed entities returned by the add method.
    for $j (@digests) {
      $j->add(file => $file, msg => $msg, data => $data);
    }
  }

  # Done all messages; finish off each digest and get the filenames
  for $i (@digests) {
    push @files, $i->done;
  }

  unlink @nukes;

  @files;
}

=head2 idx_subject

This formats an index line containing just the subject indented by two
spaces.

=cut
sub idx_subject {
  my ($type, $msg, $data) = @_;
  my $sub = $data->{'subject'};
  $sub = '(no subject)' unless defined $sub && length $sub;

  if ($type eq 'index') {
    return sprintf("  %-10s: %s\n", $msg, $sub);
  }
  return "  $sub\n";
}


=head2 idx_subject_author

This formats an index line like the following:

  Today's your birthday, friend...                 [Mike Matthews <matthewm>]
  Chantal Kreviazuk                       ["J." Wermont <jwermont@sonic.net>]
  Re: Musical Tidbits from Ice Magazine  [Philip David Morgan <philipda@li.n]
  Re: Chantal Kreviazuk                                    [FAMarcus@aol.com]

Original code by Jeff Wasilko. '

The idea here is to try to show things on one line, but break otherwise.
The original truncated the From: header; this just breaks the line instead.
(There is no requirement that index entries take only one line.)

=cut
sub idx_subject_author {
  my ($type, $msg, $data) = @_;
  my ($from, $sub, $width);

  $sub = $data->{'subject'};
  $sub = '(no subject)' unless length $sub;
  if ($type eq 'index') {
    $sub = sprintf("%-10s: %s", $msg, $sub);
  }
  $from = $data->{'from'};

  if (length("$sub $from") > 72) {
    return "  $sub\n" . (' ' x int(74-length($from))) . "[$from]\n";
  }

  $width = length($from) + length($sub);
  return "  $sub " . (' ' x int(71 - $width)) . "[$from]\n";
}
=head2 idx_subject_name

This formats an index line like the following:

  Today's your birthday, friend...                            (Mike Matthews)
  Chantal Kreviazuk                                            ("J." Wermont)
  Re: Musical Tidbits from Ice Magazine                 (Philip David Morgan)
  Re: Chantal Kreviazuk                                            (FAMarcus)

The format is identical to the subject_author format, but the address of
the author is omitted.

The idea here is to try to show things on one line, but break otherwise.
The original truncated the From: header; this just breaks the line instead.

=cut
use Mj::Addr;
sub idx_subject_name {
  my ($type, $msg, $data) = @_;
  my ($addr, $from, $sub, $tmp, $width);

  $sub = $data->{'subject'};
  $sub = '(no subject)' unless length $sub;
  if ($type eq 'index') {
    $sub = sprintf("%-10s: %s", $msg, $sub);
  }

  $addr = new Mj::Addr($data->{'from'});

  if ($addr and $addr->isvalid) {
    $from = $addr->comment;
    # use the local part of the address if no comment is available.
    unless ($from) {
      $from = $addr->strip;
      $from =~ s/([^\@]+)\@.+/$1/;
    }
  }

  unless (defined $from) {
    $from = "unknown";
  }

  if (length("$sub $from") > 72) {
    return "  $sub\n" . (' ' x int(74-length($from))) . "($from)\n";
  }

  $width = length($from) + length($sub);
  return "  $sub " . (' ' x int(71 - $width)) . "($from)\n";
}

=head2 idx_numbered

This produces the same format regardless of the digest type.
Each entry consists of two lines.  The first contains the 
message number and subject.  The second contains the address
of the author.

  200008/12: Today's your birthday, friend...                 
    Mike Matthews <matthewm>

=cut
sub idx_numbered {
  my ($type, $msg, $data) = @_;
  return sprintf "  %-10s: %s\n    %s\n", 
                  $msg || '???',
                  $data->{'subject'} || '(no subject)',
                  $data->{'from'} || '(unknown)';

}

=head2 idx_numbered_name

This produces the same format regardless of the digest type.
Each entry consists of two lines.  The first contains the 
message number and subject.  The second contains the name
of the author.

  200008/12: Today's your birthday, friend...                 
    Mike Matthews

=cut
sub idx_numbered_name {
  my ($type, $msg, $data) = @_;
  my ($addr, $from);

  $addr = new Mj::Addr($data->{'from'});

  if ($addr and $addr->isvalid) {
    $from = $addr->comment;
    # use the local part of the address if no comment is available.
    unless ($from) {
      $from = $addr->strip;
      $from =~ s/([^\@]+)\@.+/$1/;
    }
  }

  unless (defined $from) {
    $from = "unknown";
  }
  return sprintf "  %-10s: %s\n    %s\n", 
                  $msg || '???',
                  $data->{'subject'} || '(no subject)',
                  $from;
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

=head1 NAME

Mj::Digest::Text.pm - Majordomo Text digest building routines

=head1 SYNOPSIS

Mj::Digest::Text

=head1 DESCRIPTION

This module implements an RFC1153 Text digest object.  Call 'new' to
allocate the object and pass in interesting parameters like index format,
headers and such.  Then call add to pass in each message and call done to
get the complete digest in a file.

Note that to make things simpler the actual entities are stored up until
the end so that everything can be generated in a single file.  Only the
index is updated with each call to add.

=cut

package Mj::Digest::Text;

use strict;
use Mj::Log;
use IO::File;
use Mj::MIMEParser;

=head2 new

Allocates a MIME digest.

The following args are required:

  subject - the subject of the digest message.  Do appropriate
            substitutions before calling this function.
  indexfn - funcref to a function which generates an index line.

index_header, index_fronter, fronter, footer

=cut
use Date::Format;
sub new {
  my $type = shift;
  my %args = @_;
  my $class= ref($type) || $type;
  my $log  = new Log::In 150;
  my $self = {};
  my($fh, $i);
  bless $self, $class;

  $self->{top} = build MIME::Entity
    (Type     => 'text/plain',
     Subject  => $args{'subject'} || '',
     From     => $args{'from'},
     To       => $args{'to'},
     Date     => time2str("%a, %d %b %Y %T %z", time),
     Filename => undef,
     Encoding => '8bit',
     Data     => '',
     # More fields here
    );

  for $i (@{$args{headers}}) {
    $self->{top}->head->add($i->[0], $i->[1]);
  }

  $self->{body} = $self->{top}->open('w');
  $self->{from}      = $args{from};
  $self->{indexfn}   = $args{indexfn};
  $self->{subject}   = $args{subject};
  $self->{postindex} = $args{postindex};
  $self->{footer}    = $args{footer};
  $self->{count} = 0;
  $self->{ents} = [];

  # Read in the pre-index file
  if ($args{'preindex'}{'name'}) {
    my $fh = new IO::File "<$args{preindex}{name}";
    while (defined($i = <$fh>)) {
      $self->{body}->print($i);
    }
  }

  # Make a MIME parser
  $self->{parser} = new Mj::MIMEParser;
  $self->{parser}->output_dir($args{tmpdir});
  $self->{parser}->output_prefix("mjdigest");

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

Adds a message contained in a file to the digest object.

Takes a filename, the message number and the archive index data.

This parses the file into a MIME::Entity and goes through it, extracting
text and message/rfc822 pieces and placing them in the message.  This will
still screw up character sets and such, but at least MIME documents won''t
come out as complete garbage.

=cut
sub add {
  my $self = shift;
  my %args = @_;
  my $log  = new Log::In 200, "$args{msg}";

  $self->{count}++;

  # Store the file
  push @{$self->{files}}, $args{file};

  # Generate the index entry;
  $self->{body}->print(&{$self->{indexfn}}('mime', $args{msg}, $args{data}));
}

=head2 done

Generates the digest and returns a filename containing it.  Be sure to
delete this file when finished.

=cut
sub done {
  my $self = shift;
  my ($ent, $fh, $file, $i, $j);

  # Print index_footer
  if ($self->{postindex}{name}) {
    $fh = new IO::File "<$self->{postindex}{name}";
    while (defined($i = <$fh>)) {
      $self->{body}->print($i);
    }
    $fh->close;
  }

  # Print preamble separator
  $self->{body}->print("\n", '-'x70, "\n\n");

  # Loop over files
  for $i (@{$self->{files}}) {
    $fh = new IO::File($i);
    $ent = $self->{parser}->read($fh);

    # Extract necessary fields from the header
    for $j (qw(Date From To Cc Subject Message-ID Keywords Summary)) {
      if ($ent->head->get($j)) {
        $self->{body}->print("$j: ". $ent->head->get($j));
      }
    }
    # Header separator
    $self->{body}->print("\n");

    get_text($ent, $self->{body});

    # Print a separator
    $self->{body}->print("\n". '-'x30, "\n\n");

    # Clean up
    $ent->purge;
  }

  # Deal with the footer.
  if ($self->{footer}{name}) {
    $self->{body}->print("From: $self->{from}\n");
    $self->{body}->print("Subject: $self->{footer}{data}{description}\n\n");

    $fh = new IO::File "<$self->{footer}{name}";
    while (defined($i = <$fh>)) {
      $self->{body}->print($i);
    }
    $fh->close;
    $self->{body}->print("\n". '-'x30, "\n\n");
  }

  # Print ending matter
  $self->{body}->print("End of $self->{subject}\n**********\n");

  # Open a file and print out 
  $file = Majordomo::tempname();
  $fh = new IO::File ">$file";
  $::log->abort("Unable to open file $file: $!") unless ($fh);

  $self->{top}->print($fh);
  $fh->close()
    or $::log->abort("Unable to close file $file: $!");
  $file;
}

=head2 get_text

This extracts text parts from a MIME::Entity and prints their bodies to a
supplied filehandle.  This will call itself to recursively process complex
entities.

=cut
sub get_text {
  my $ent = shift;
  my $fh  = shift;
  my ($body, $i, $type);

  # If we have a multipart, parse it recursively
  if ($ent->parts) {
    for $i ($ent->parts) {
      get_text($i, $fh);
    }
    return;
  }

  $type = lc($ent->effective_type);
  if ($type eq 'text' || $type eq 'text/plain') {
    dump_body($ent, $fh);
  }
  elsif ($type eq 'message/rfc822') {
    $fh->print("---- Begin Included Message ----\n\n");
    dump_body($ent, $fh);
    $fh->print("\n----- End Included Message -----\n");
  }
  else {
    $fh->print("\n\n[Attachment of type $type removed.]\n");
  }
}

=head2 dump_body

This prints the body of an entity verbatim to a filehandle, excaping only
lines of 30 dashes.

=cut
sub dump_body {
  my $ent = shift;
  my $fh  = shift;
  my ($body, $line);

  $body = $ent->open('r');
  while (defined($line = $body->getline)) {
    if ($line eq '-'x30 . "\n") {
      $fh->print(" " . "-" x 29 . "\n");
    }
    else {
      $fh->print($line);
    }
  }
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

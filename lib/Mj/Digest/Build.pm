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

#use AutoLoader 'AUTOLOAD';
1;
#__END__

=head2 build

This builds a digest.  It looks at the passed arguments and calls the
appropriate build routine.

=cut
sub build {
  my %args = @_;

  my $func = lc("build_$args{'type'}");
  {
    no strict 'refs';
    &$func(@_);
  }
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
    ($data, $file) = $args{'archive'}->get_to_file($i);
    unless ($data) {
      $indexh->print("  Message $i not in archive.\n");
      next;
    }
    $count++;
    {
      no strict 'refs';
      $func = "idx_$args{'index_line'}";
      $indexh->print(&$func($args{'type'}, $i, $data));
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

=head2 build_index

This builds an 'index' digest.  This is a digest that includes no messages,
but instead just contains an index of messages and numbers so that the user
can choose which messages to retrieve.

=cut
sub build_index {
  my %args = @_;
  my (@msgs, $count, $data, $func, $i, $index, $indexf,
      $indexh, $tmp);
  
  $count = 0;
  $indexf = Majordomo::tempname();
  $indexh = new IO::File ">$indexf";
  $indexh->print($args{'index_header'}) if $args{'index_header'};

  # Extract all messages from the archive into files, building them into
  # entities and generating the index file.
  for $i (@{$args{'messages'}}) {
    $data = $args{'archive'}->get_data($i);
    unless ($data) {
      $indexh->print("  Message $i not in archive.\n");
      next;
    }
    $count++;
    {
      no strict 'refs';
      $func = "idx_$args{'index_line'}";
      $indexh->print(&$func($args{'type'}, $i, $data));
    }
  }

  $indexh->print($args{'index_footer'}) if $args{'index_footer'};

  # Build index entry.
  $indexh->close;
  $index = build MIME::Entity
    (Type        => 'text/plain',
     Description => $args{'subject'} || '',
     Path        => $indexf,
     Filename    => undef,
    );
  ($index, $count);
}


=head2 idx_default

This formats an index line containing just the subject indented by two
spaces.

=cut
sub idx_default {
  my ($type, $msg, $data) = @_;
  my $sub = $data->{'subject'};
  $sub = '(no subject)' unless length $sub;

  if ($type eq 'index') {
    return sprintf("  %-10s: %s\n", $msg, $sub);
  }
  return "  $sub\n";
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
  my ($type, $msg, $data) = @_;
  my ($from, $sub, $width);

  $sub = $data->{'subject'};
  $sub = '(no subject)' unless length $sub;

  if (length($sub) > 40) {
    return "  $sub\n" . (' ' x int(74-length($data->{'from'}))) .
      "[$data->{'from'}]\n";
  }

  $from = substr($data->{'from'},0,71-length($sub));
  $width = length($from) + length($sub);
  return "  $sub " . (' ' x int(71 - $width)) . "[$from]\n";
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


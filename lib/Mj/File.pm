=head1 NAME

Mj::File  - Majordomo file operations

=head1 SYNOPSIS

blah


=head1 DESCRIPTION

This implements an implicitly locked file object.

=cut

use strict;
use IO::File;
use Mj::Lock;

package Mj::File;
use vars qw($AUTOLOAD $VERSION);
$VERSION = "1.0";

=head1 Mj::File functions

These functions implement the Mj::File class.

=head2 new

Allocates an Mj::File object.  If given parameters, calls open.

=cut
sub new {
  my $type = shift;
  my $class = ref($type) || $type;

  $::log->in(150);

  my $self = {};
  $self->{'handle'} = new IO::File;
  bless $self, $class;

  if (@_) {
    $self->open(@_)
      or return undef;
  }

  $::log->out;

  $self;
}

=head2 DESTROY

A simple destructor.  If the File is open, close it.

=cut
sub DESTROY {
  my $self = shift;
  if ($self->{'open'}) {
    $self->close;
  }
  1;
}

=head2 AUTOLOAD

This implements all other IO::File methods by proxy.  Tricky, tricky.  We
can''t just inherit, because the internal storage mechanism of IO::* is not
a hash, and since we have to store object data somewhere...

=cut
sub AUTOLOAD {
  my $self = shift;
  my $name = $AUTOLOAD;
  $name =~ s/.*://; 
#  $::log->in(200, "$name");

  unless ($self->{'handle'}->can($name)) {
    $::log->abort("Attempting to call unimplemented function by proxy");
  }

  $self->{'handle'}->$name(@_);

#  if (wantarray) {
#    my @out = $self->{'handle'}->$name(@_);
#    $::log->out;
#    @out;
#  }
#  else {
#    my $out = $self->{'handle'}->$name(@_);
#    $::log->out;
#    $out;
#  }
}

=head2 open(name, mode)

This locks and opens a file.  If the mode begins with 'U', no locking is
done.

=cut
sub open {
  my $self   = shift;
  my $name   = shift;
  my $mode   = shift || "<";
  my $lname  = shift || $name;
  my ($lmode, $handle, $nolock);

  $::log->in(110, "$name, $mode");

  if (substr($mode, 0, 1) eq 'U') {
    $mode = substr($mode, 1);
    $nolock = 1;
  }

  if    ($mode =~ /rw/i) { $mode = "+<";}
  elsif ($mode =~ /^r/i) { $mode = "<" ;}
  elsif ($mode =~ /^a/i) { $mode = ">>";}
  elsif ($mode =~ /^t/i) { $mode = ">" ;}

  $lmode = "shared";
  if ($mode =~ /[>+]/) {
    $lmode = "exclusive";
  }

  $self->{lock} = new Mj::Lock($lname, $lmode) unless $nolock;

  # We have a lock now; the file is ours to do with as we please.
  $self->{handle}->open("$mode $name") || $::log->abort("Couldn't open $name, $!");
  $self->{'open'} = 1;
  $::log->out;
  1;
}

=head2 close

Closes a previously opened handle.

=cut
sub close {
  my $self = shift;
  
  $::log->in(120);
  unless ($self->{'open'}) {
    log_abort("Mj::File::close called on unopened handle");
  }
  
  $self->{handle}->close || $::log->abort("Couldn't close $self, $!");
  $self->{'open'} = 0;

  $self->{lock}->unlock if $self->{lock};

  delete $self->{lock};

  $::log->out;
  1;
}

=head2 commit

This is just an alias for close, so that a replaced file and an opened file
can be closed in the same manner.

=cut
sub commit {
  my $self = shift;
  $self->close;
}

=head2 search(...)

Goes through a file line-by-line, looking for a match.  If given a string,
uses that string as a regexp.  If given a list, uses each element as a
regexp and searches for any match.  If given a coderef, calls the
subroutine once per line with the line as the argument and stops searching
when that sub returns a defined value.  Returns undef if no match is found
(i.e. if it runs off the end of the file).  Call repeatedly to return all
matching lines from a file.

=cut
use Mj::Util qw(re_match);
sub search {
  my $self = shift;
  my ($line, $re, $sub, $temp);
  
  if (ref $_[0] eq 'CODE') {
    $sub = shift;
    while ($line = $self->{'handle'}->getline) {
      chomp;
      $temp = &$sub($line);
      if (defined $temp) {
	return $temp;
      }
    }
    return undef;
  }
  
  # Else we have an array of regexps.
  while ($line = $self->{'handle'}->getline) {
    for $re (@_) {
      if (re_match($re, $line)) {
	return $line;
      }
    }
  }
  return undef;
}

=head1 COPYRIGHT

Copyright (c) 1997, 1998 Jason Tibbitts for The Majordomo Development
Group.  All rights reserved.

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

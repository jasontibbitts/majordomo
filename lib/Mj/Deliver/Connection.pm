=head1 NAME

Mj::Deliver::Connection - Low level connection object

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

A Connection is a thin layer above a network socket.  It exists to allow
the possibility of communicating with something other than a socket using
the same interface.  An earlier version of this code supported executing a
program with the Connection object encapsulating its input and output.

This class also encapsulates a simple buffered IO mechanism over unbuffered
sysread and syswrite.  This enables us to use select calls to provide real
timeouts on socket reads.  (The buffered writes are still used, right now.)

=cut

package Mj::Deliver::Connection;
use strict;
use IO::Socket;
use IO::Select;
use Mj::Log;

=head2 new(host, port, timeout)

A simple constructor.  Right now we only bother to implement connections
via sockets; connections to programs are very useful, but more difficult to
implement.  This opens the connection, sets the output handle to autoflush
node, and returns.

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;

  my $self = {};
  bless $self, $class;

  $self->{'host'}      = shift;
  $self->{'port'}      = shift || 25;
  $self->{'timeout'}   = shift || 60;
  $self->{'outhandle'} = new IO::Socket::INET
    PeerAddr => $self->{'host'},
    PeerPort => $self->{'port'},
    Proto    => 'tcp',
    Timeout  => $self->{'timeout'};
  unless ($self->{'outhandle'}) {
    warn $@ if $@;
    return undef;
  }
  $self->{'outhandle'}->autoflush(1);
  $self->{'outsel'} = new IO::Select $self->{'outhandle'};
  $self->{buffer} = '';
  return $self;
}

=head2 print(string)

This outputs a string to the connection.

=cut
sub print {
  my $self   = shift;
  my $string = shift;

  return unless $self->{'outsel'}->can_write($self->{'timeout'});
  $self->{'outhandle'}->print($string);
}

=head2 getline

This grabs a line from the connection, timing out (and returning undef)
appropriately.  If tomult is specified, it linearly scales the timeout.

Because select and getline (and buffered input in general) don''t mix, we
maintain our own buffer and read a chunk off of the socket whenever it is
necessary.

There was support for a separate input handle, but the support for
communicating with a pair of filehandles has been scrapped.  (That was the
original reason for this module, but...)

=cut
sub getline {
  my $self = shift;
  my $tomult = shift || 1;
  my ($len);
  
  while(!length($self->{buffer}) || $self->{buffer} !~ /\n/) {
    return undef
      unless $self->{outsel}->can_read($self->{timeout}*$tomult);
    $len = $self->{outhandle}->sysread($self->{buffer}, 1024,
				       length($self->{buffer}));
    return undef unless $len;
  }
  $self->{buffer} =~ s/^([^\n]*\n)//;
  $1;
}

=head2 fileno

This returns the filenumber of the input side of the connection, for use in
building a select vector.

=cut
sub fileno {
  my $self = shift;
  my $handle = $self->{'inhandle'} || $self->{'outhandle'};
  $handle->fileno;
}

=head2 input_pending

Select on the handle to see if it has something waiting to process.  Useful
for building a simple polling routine.

=cut
sub input_pending {
  my $self = shift;
  return $self->{'outsel'}->can_read(0);
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

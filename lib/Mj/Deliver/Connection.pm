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
use Symbol;
use Socket;
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
  my ($proto, $sock, $sin, $iaddr, $tmp);

  my $self = {};
  bless $self, $class;

  $self->{'host'}      = shift;
  $self->{'port'}      = shift || 25;
  $self->{'timeout'}   = shift || 60;
  $proto = getprotobyname('tcp');

  $sock = gensym;
  $tmp = socket($sock, PF_INET, SOCK_STREAM, $proto);
  unless ($tmp) {
    warn $@ if $@;
    return;
  }

  $iaddr = inet_aton($self->{'host'});
  unless ($iaddr) {
    warn $@ if $@;
    return;
  }

  $sin = sockaddr_in($self->{'port'}, $iaddr);
  unless ($sin) {
    warn $@ if $@;
    return;
  }

  # Autoflush the socket
  $tmp = select;
  select $sock;
  $| = 1;  
  select $tmp;

  $tmp = connect ($sock, $sin);
  unless ($tmp) {
    warn $@ if $@;
    return;
  }

  $self->{'outhandle'} = $sock;
  $self->{'buffer'} = '';

  return $self;
}

=head2 print(string)

This outputs a string to the connection.

=cut
sub print {
  my $self   = shift;
  my $string = shift;
  my ($win, $ein);

  $win = '';
  vec($win, fileno($self->{'outhandle'}), 1) = 1;
  $ein = $win;

  return unless (select(undef, $win, $ein, $self->{'timeout'}) > 0);
  print {$self->{'outhandle'}} $string;
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
  my ($len, $ein, $rin, $eout, $rout, $tmp);

  $tmp = fileno($self->{'outhandle'});
  $rin = '';
  vec($rin, $tmp, 1) = 1;
  $ein = $rin;

  while(!length($self->{buffer}) || $self->{buffer} !~ /\n/) {
    return unless (select($rout=$rin, undef, $eout=$ein, 
                   $self->{'timeout'}*$tomult) > 0);
    $len = sysread($self->{'outhandle'}, $self->{'buffer'}, 1024,
				       length($self->{'buffer'}));
    return undef unless $len;
  }
  $self->{'buffer'} =~ s/^([^\n]*\n)//;
  $1;
}

=head2 fileno

This returns the filenumber of the input side of the connection, for use in
building a select vector.

=cut
# sub fileno {
  # my $self = shift;
  # my $handle = $self->{'inhandle'} || $self->{'outhandle'};
  # $handle->fileno;
# }

=head2 input_pending

Select on the handle to see if it has something waiting to process.  Useful
for building a simple polling routine.

=cut
# sub input_pending {
  # my $self = shift;
  # return $self->{'outsel'}->can_read(0);
# }

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

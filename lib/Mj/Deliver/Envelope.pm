=head1 NAME

Mj::Deliver::Envelope - Implement an Envelope on top of SMTP

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

An Envelope is a message, a sender, and a list of addresses.  You can make
an Envelope fully in the constructor, or you can build it piece by piece.

An envelope opens its connection immediately and adds the addresses as you
send them.  You can send an envelope, then another set of addresses to it
and send it again; it will keep the same connection open for efficiency.

Note that all addresses passed to these functions must be stripped of all
comments.  They will be passed unaltered into the SMTP stream, so any
syntax improprieties may result in unpredictable (i.e. bad) behavior.

=cut

package Mj::Deliver::Envelope;
use IO::File;
use Mj::Log;
use Mj::Deliver::SMTP;
use strict;

=head2 new

This builds an Envelope.  You must call it with at least 'sender' so that
it can begin the transaction (since the connection is opened here).  If you
need to supply your local hostname or a port, you must do it through the
constructor.

Arguments:

  host    - the remote host to connect to
  port    - the remote port to connect to
  timeout - timeout on connection opens and socket communications
  local   - the name of the local host
  sender  - the address to show in the From_ line.  Bounces will go here.
  file    - the file containing the message text (headers and body) to send
  addrs   - a listref containing the addresses to send to

host, port, timeout and local have reasonable defaults supplied by the SMTP
object.  sender has no default.  You can specify a file (or change the file
being used) and add addresses later.

This will return undef if the SMTP greeting handshake, setup or initial
addressing fails.

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;
  my %args  = @_;
  my ($code, $mess, $ok, $val);
  my $log = new Log::In 545, "$args{host}";

  my $self = {};
  bless $self, $class;

  $self->{'smtp'} = new Mj::Deliver::SMTP
    (
     'host'    => $args{'host'},
     'port'    => $args{'port'}    || undef,
     'timeout' => $args{'timeout'} || undef,
     'local'   => $args{'local'}   || undef,
    );

  return undef unless $self->{'smtp'};

  unless ($args{'sender'}) {
    warn "Must provide a sender when opening an envelope; using bogus default.";
    $args{'sender'} = 'misconfigured@example.com';
  }

  $self->{'sender'} = $args{'sender'};

  return undef unless $self->init;
  
  if (defined $args{'file'}) {
    $self->file($args{'file'});
  }
  
  $args{'addresses'} ||= $args{'addrs'};
  if (defined $args{'addresses'}) {
    $ok = $self->address($args{'addresses'});
    return undef if $ok < 0;
  }

  $self;
}

=head2 file(filename)

Sets the filename that will be sent as part of the envelope.

=cut

sub file {
  my $self = shift;
  $self->{'file'} = shift;
};

=head2 sender(sender)

Sets the sender that will be used to initialize the envelope.

=cut
sub sender {
  my $self = shift;
  $self->{'sender'} = shift;
}

=head2 init

This initialiazes the Envelope; after opening and after an RSET command,
the connection needs to be told the sender and any ESMTP flags need to be
sent.  Note that this does not deal with the greeting; that happens once
when the connection is opened.

=cut
sub init {
  my $self = shift;
  return 1 if $self->{'initialized'};
  my($val, $code, $mess) = $self->{'smtp'}->MAIL($self->{'sender'});
  return 0 unless $val;
  $self->{'initialized'} = 1;
  1;
}

=head2 address(scalar or listref)

Adds addresses to the envelope.  Returns 1 if the address was accepted
without error, returns -1 if the addresses caused an error, but not one of
such severity that the connection must be aborted, and returns 0 if there
was a serious error.

Note that this returns 0 upon the first fatal error, but will otherwise
only return the code of the last address.

Note also that in the event that the remote host reports that it cannot
accept any more RCPT lines, the envelope is sent and a new one is opened.
This is not necessarily a good thing because it doesn't take into account
load distribution and such, but at this level we don't know about any of
that.  We just need to get the message sent and the alternative (passing
out a count of what we could send) is somewhat distasteful.

=cut
sub address {
  my $self = shift;
  my $addr = shift;
  my $log = new Log::In 150, "$addr";
  my ($code, $good, $i, $mess, $val);
  
  unless (ref $addr) {
    $addr = [$addr];
  }

  $good = 0;

  unless ($self->{'initialized'}) {
    return 0 unless $self->init;
  }

  for $i (@{$addr}) {
    ($val, $code, $mess) = $self->{'smtp'}->RCPT($i,1);

    # If we got a bad error, just return null
    return 0 if !$val;

    if ($val == -2) {
      # We can't send any more RCPTs, so we send ourselves and start over.
      $self->send;
      ($val, $code, $mess) = $self->{'smtp'}->RCPT($i,1);
    }
    $self->{'addressed'} = 1 if $val > 0;
  }

  return $val;
}

=head2 send

This sends the Envelope on its way by attaching the data from the file.
This will abort (i.e. terminate the running program) if the Envelope has
not yet been addressed, if a file has not been specified or if the file is
in some way unreadable.

This returns true if the message was sent and false if it was not (due to
some kind of error on the remote host).

=cut
sub send {
  my $self = shift;
  my $log = new Log::In 150;
  my $fh = new IO::File;
  my ($code, $line, $mess, $ok, $val);

  $log->abort("Sending unaddressed envelope") unless $self->{'addressed'};
  $log->abort("Sending empty envelope")       unless $self->{'file'};

  # If we can't open the file, we really are hosed
  open $fh, $self->{'file'} ||
    $log->abort("Failed to open envelope data file: $!");

  ($val, $code, $mess) = $self->{'smtp'}->DATA;

  # DATA must return 354
  unless (defined $code && $code == 354) {
    return 0;
  }

  while (defined ($line = $fh->getline)) {
    $ok = $self->{'smtp'}->senddata($line);
    return 0 unless $ok;
  }

  # Finish up and reset the connection
  ($val, $code, $mess) = $self->{'smtp'}->enddata;
  return 0 unless $val;

  # We assume RSET won't fail.  RFC821 says that it can't fail, but it can
  # have error responses.  Things must be pretty hosed for an RSET to
  # fail...
  ($val, $code, $mess) = $self->{'smtp'}->RSET;

  $self->{'initialized'} = 0;
  return 1;
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

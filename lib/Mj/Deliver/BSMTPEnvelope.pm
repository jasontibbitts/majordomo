=head1 NAME

Mj::Deliver::BSMTPEnvelope - Implement an Envelope on top of BSMTP

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

An Envelope is a message, a sender, and a list of addresses.  You can make
an Envelope fully in the constructor, or you can build it piece by piece.

For BSMTP, all that is important is that the outgoing SMTP commands, plus
the normally escaped DATA, be appended to a file.

=cut

package Mj::Deliver::BSMTPEnvelope;
use Symbol;
use Mj::Log;
use strict;

=head2 new

This builds an Envelope.  You must call it with at least 'sender' so that
it can begin the batch (since the file is opened here).

Arguments:

  local   - the name of the local host
  sender  - the address to show in the From_ line.  Bounces will go here.
  file    - the file containing the message text (headers and body) to send
  addrs   - a listref containing the addresses to send to
  ofile   - the file in which to store the batch

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;
  my %args  = @_;
  my ($code, $mess, $ok, $val);
  my $log = new Log::In 545, "$args{host}";

  my $self = {};
  bless $self, $class;

  unless (defined $args{'sender'}) {
    warn "Must provide a sender when opening an envelope; using bogus default.";
    $args{'sender'} = 'misconfigured@example.com';
  }

  $self->{ofile}      = $args{ofile};
  $self->{'sender'}   = $args{'sender'};
  $self->{'personal'} = $args{'personal'};

  # Open the FH
  $self->{fh} = gensym();

  unless (open($self->{fh}, ">> $self->{ofile}")) {
    $log->complain("Can't open $self->{ofile}: $!");
    return undef;
  }

  print {$self->{fh}} "HELO $args{local}\r\n";
  $self->init;

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

=head2 DESTROY

When the time comes, close the batch (and call the MTA?)

=cut
sub DESTROY {
  my $self = shift;
  print {$self->{fh}} "QUIT\r\n";
  close $self->{fh};

  # Call MTA here

  # Delete file here
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
  print {$self->{fh}} "MAIL FROM: <$self->{sender}>\r\n";
  $self->{'initialized'} = 1;
  $self->{'addressed'} = 0;
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
  my $deferred = shift;
  my $failed = shift;
  my $log = new Log::In 150;
  my ($i);

  unless (ref $addr) {
    $addr = [$addr];
  }
  return 0 unless (@{$addr});

  # If a message is meant to be sent to one recipient, keep the recipient
  # address for later use.
  if ($self->{'personal'}) {
    $self->{'rcpt'} = $addr->[0];
  }

  $self->init;

  for $i (@$addr) {
    print {$self->{fh}} "RCPT TO: <$i>\r\n";
  }

  $self->{addressed} = 1;

  1;
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
  my $fh = gensym();
  my ($line, $sentnl);

  $log->abort("Sending unaddressed envelope") unless $self->{'addressed'};
  $log->abort("Sending empty envelope")       unless $self->{'file'};

  # If we can't open the file, we really are hosed
  open ($fh, $self->{'file'}) ||
    $log->abort("Failed to open envelope data file: $!");

  print {$self->{fh}} "DATA\r\n";

  while (defined ($line = <$fh>)) {
    # If a message is personal (a probe), substitute for $MSGRCPT.
    if ($self->{'personal'} and $self->{'rcpt'}) {
      # Don't substitute after backslashed $'s
      $line =~ s/([^\\]|^)\$\QMSGRCPT\E(\b|$)/$1$self->{'rcpt'}/g;
    }

    if ($line =~ /\n$/so) {
      $sentnl = 1;
    }
    else {
      $sentnl = 0;
    }

    $line =~ s/\n/\015\012/sgo;
    $line =~ s/^\./../;
    print {$self->{fh}} $line;
  }
  close $fh;

  # Finish the DATA phase
  if (!$sentnl) {
    print {$self->{fh}} "\r\n";
  }
  print {$self->{fh}} ".\r\n";

  # Now reset the session
  print {$self->{fh}} "RSET\r\n";

  undef $self->{'rcpt'} if $self->{'personal'};
  $self->{'initialized'} = 0;
  return 1;
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
### cperl-indent-level:2 ***
### End: ***

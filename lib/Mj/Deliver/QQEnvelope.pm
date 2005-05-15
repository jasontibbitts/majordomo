=head1 NAME

Mj::Deliver::QQEnvelope - Implement an Envelope on top of qmail

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This is an object that is call compatible with the Envelope object.  It
consists of a sender, recipients and a message.  When the envelope is sent
it uses the qmail-queue program to inject the message into the local mail
system.

Thanks to Ryan Tadlock for this code.

=cut

package Mj::Deliver::QQEnvelope;
use strict;
# I need tmpnam and open from posix, I probably can work around their
# absence but I haven't put the code together yet.
use POSIX;
use IO::File;
use Mj::Log;

=head2 new

This builds an Envelope.  You must call it with at least 'sender' so that
it can begin the transaction.

Arguments:

  sender  - the address to show in the From_ line.  Bounces will go here.
  file    - the file containing the message text (headers and body) to send
  addrs   - a listref containing the addresses to send to
  personal- if true, when this string is encountered it will be replaced
            with the address of the current recipient.

Sender has no default.  You can specify a file and add addresses later.

=cut

sub new {
  my $type  = shift;
  my $class = ref($type) || $type;  
  my %args  = @_;
  my $log   = new Log::In 150;
  my ($addfile);
  
  my $self = {};
  bless $self, $class;
  $addfile = POSIX::tmpnam;
  $self->{'addname'} = $addfile;

  # This isn't really necessary but I want to maintain call compatibility
  # with the Envelope object.
  unless (defined $args{'sender'}) {
    $log->abort("Must provide a sender when opening an envelope");  
  }

  $self->{'sender'} = $args{'sender'};
  $self->{'qmail_path'} = $args{'qmail_path'};
  $self->{'personal'} = $args{'personal'};

  if (defined $args{'file'}) {
    $self->file($args{'file'});
  }
  
  $args{'addresses'} ||= $args{'addrs'};
  if (defined $args{'addresses'}) {
    $self->address($args{'addresses'});
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

sub sender {
  my $self = shift;
  my $log  = new Log::In 150;
  my $verpsender;

  $self->{'sender'} = $verpsender = shift;

  # make the address file now using name concocted in new
  $self->{'addfile'} = new IO::File ">$self->{'addname'}";
  unless (defined $self->{'addfile'}) {
      $log->abort("Unable to open tempfile $self->{'addname'}");
  }
  # VERP all single and digest messages not already tagged
  if($verpsender =~ m{\+(M\d+|DV\d+N\d+)\@}) {
      $verpsender =~ s/\@/=@/;
      $verpsender .= "-\@[]";
  }
  $self->{'addfile'}->print("F" , $verpsender , "\00");
}

=head2 address(scalar or listref)

Adds addresses to the envelope.  Returns true if some addresses were accepted.

=cut

sub address {
  my $self = shift;
  my $addr = shift;
  my($good, $i);
  
  $good = 0;
  
  unless (ref $addr) {
    $addr = [$addr];
  }

  # If a message is meant to be sent to one recipient, keep the recipient
  # address for later use.
  if ($self->{'personal'}) {
    $self->{'rcpt'} = $addr->[0];
  }

  # Unlike SMTP, we don't have to worry about addresses being rejected
  # here, so we're OK if we add even one address.
  for $i (@{$addr}) {
    $good = 1;
    $self->{'addfile'}->print("T" , $i , "\00") ;
  }
  
  $self->{'addressed'} = 1 if $good;
  return $good;
};

=head2 send

This sends the Envelope on its way by attaching the data from the file.
This will abort (i.e. terminate the running program) if the Envelope has
not yet been addressed, if a file has not been specified or if the file is
in some way unreadable.

It writes the envelope data to a temporary file, then runs qmail-queue.
Normally, it opens the file and passes the file descriptor to qmail-queue,
but if personal is set, it reads the file and passes its through a pipe
so it can expand $MSGRCPT in the file.

=cut

sub send {
  my $self = shift;
  my $log  = new Log::In 150;
  my ($addfile, $fd1, $fd2, $pid, $qp);
  local (*FH, *PR, *PW);      # local files for personal var expansion
  
  $log->abort("Sending unaddressed envelope") unless $self->{'addressed'};
  $log->abort("Sending empty envelope")       unless $self->{'file'};
  $self->{'addfile'}->print("\00");
  $self->{'addfile'}->close()
    or $::log->abort("Unable to close file $self->{'addname'}: $!");

  # we have to filter this for $MSGRCPT if it's personal
  if ($self->{'personal'}) {
      open (FH, $self->{'file'}) ||
	  $log->abort("Failed to open envelope data file: $!");
      pipe PR, PW or
      	  $log->abort("Failed to open message pipe: $!");
  }

  if ($pid = fork()) {
      # If a message is personal (a probe), substitute for $MSGRCPT.
    if ($self->{'personal'}) {
	close PR;
	my ($line);
	while (defined ($line = <FH>)) {
	    # Don't substitute after backslashed $'s
	    $line =~ s/([^\\]|^) \Q$self->{personal}\E (\b|$ )/ $1 $self->{'rcpt'} /gx;
            print PW $line or
		$log->abort("Failed writing to message pipe: $!");
        }
	close FH; close PW;
    }
    waitpid $pid, 0;
    unlink $self->{'addname'};
  }
  elsif (defined $pid) {
    close STDIN;
    close STDOUT;
    if($self->{'personal'}) {
	$fd1 = POSIX::dup (fileno PR);
	close PR; close PW; close FH;
    } else {
	$fd1 = POSIX::open ($self->{'file'});
    }
    $fd2 = POSIX::open ($self->{'addname'});
    unless (($fd1 == 0) && ($fd2 == 1) ) {
      $log->abort("Unable to produce proper file descriptors");
    }

    $qp = $self->{'qmail_path'};
    if (-d $qp and -x $qp)  {
      $ENV{PATH} = "$qp:/bin:/usr/bin:/var/qmail/bin/";
    }
    else {  
      $ENV{PATH} = "/bin:/usr/bin:/var/qmail/bin/";
    }
    exec "qmail-queue";
  }
  else {
    # The fork failed so I will abort
    $log->abort("Unable to fork");
  }
  1;
}

=head2 DESTROY

This is the method to clean up for the object.  It currently just removes
any temp files left behind.

=cut

sub DESTROY {
  my $self = shift;
  
  if (defined $self->{'addname'}) {
    if (-e $self->{'addname'}){
      unlink $self->{'addname'} ;
    }
  }
  1;
}

=head1 COPYRIGHT

Copyright (c) 1997, 1998, 2002, 2004 Jason Tibbitts for The Majordomo
Development Group.  All rights reserved.

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

=head1 NAME

Mj::Deliver::SMTP - The SMTP protocol

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This talks SMTP over a Connection.

Why not Net::SMTP?  Well, it doesn't implement SMTP over a pair of
filehandles connected to something which speaks SMTP on standard in/out and
it didn't (at the time this code was begun) do any ESMTP.  Plus it's easier
to have my own handling of exceptional SMTP return codes.  It also doesn't
do the kind of logging that I want.  Finally, it doesn't quite handle what
I need in terms of dealing with failures on RCPT that aren't fatal to the
connection.

=cut

package Mj::Deliver::SMTP;
use Mj::Log;
use Mj::Deliver::Connection;
use strict;

=head2 new

This opens a connection, waits for and processes the greeting from the
remote end and sends the HELO.  After this is done, the transaction is in
the same state as it would be after an RSET, ready for an envelope to be
opened.

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;
  my %args = @_;
  my ($ok, $code, $message);
  my $self = {};
  bless $self, $class;

  $self->{'host'}    = $args{'host'}    || 'localhost';
  $self->{'port'}    = $args{'port'}    || 25;
  $self->{'timeout'} = $args{'timeout'} || 60;
  $self->{'local'}   = $args{'local'};
  unless (defined $self->{'local'}) {
    require Net::Domain;
    $self->{'local'} = Net::Domain::hostfqdn();
  }
  $self->{'sentnl'}  = 0;
  $self->{'esmtp'} = $args{'esmtp'} || 0;
  $self->{'dsn'} = 0;
  $self->{'pipelining'} = 0;
  $self->{'connection'} =
    new Mj::Deliver::Connection($self->{'host'},
				$self->{'port'},
				$self->{'timeout'},
			       );
  return unless $self->{'connection'};

  # Eat the greeting, and make sure it was OK.  (We fail on greeting
  # timeouts.)
  ($ok) = $self->getresp;
  return unless defined $ok && $ok > 0;

  if ($self->{'esmtp'}) {
    ($ok, $code, $message) = $self->EHLO($self->{'local'});
    # return on 421 or timeout.
    return if (! defined $code or $code == 421);
    # set ESMTP variables on success
    if ($ok) {
      $self->ONEX()
        if ($args{'onex'} and $message =~ /ONEX/);
      $self->{'dsn'} = 1 
        if ($args{'dsn'} and $message =~ /DSN/);
      $self->{'pipelining'} = 1 
        if ($args{'pipelining'} and $message =~ /PIPELINING/);
      return $self;
    }
    # fall through and do HELO on 5xx error.
  }
  # The standard (RFC1869) says that we can't depend on the greeting
  # returning anything special if the host supports ESMTP.
  ($ok) = $self->HELO($self->{'local'});
  return unless defined $ok && $ok > 0;

  $self;
}

=head2 send(command)

Send a command over the connection.  This expects to terminate the command
line itself.  You must still parse the server''s response.

=cut
sub send {
  my $self = shift;
  my $comm = shift;

  $::log->message(551, "debug", ">>>$comm");
  $self->{'connection'}->print("$comm\r\n");
}

=head2 getresp(ignore_non_fatal_errors, timeout_multiplier, pipelining)

Get the complete SMTP response to a command.  This parses out the error
codes and handles continued lines properly.

If the optional parameter $ignore is true, getresp will return -1 when
encountering an error which is non-fatal.  This happens when an RCPT
generates an error indicating that the address is somehow illegal; the
transaction can continue but the address should not be retried.

If $tomult is supplied, it will be used to scale the read timeout.

If $pipeline is non-zero, the subroutine will return immediately
unless a response has been received.

Returns a list:

  flag   - true if command succeeded, false if failed, -n if non-fatal
           failure
  code   - the actual SMTP return code
  string - the complete SMTP response

n is 2 for the particular error indicating that the envelope will take no
more addresses, and 1 otherwise.

Will return the empty list if a socket read timed out.

=cut
sub getresp {
  my $self   = shift;
  my $ignore = shift || 0;
  my $tomult = shift;
  $tomult = 1 unless defined $tomult;
  my $log = new Log::In 550, "$ignore, $tomult";
  my ($code, $error, $message, $multi, $resp, $text);

  $message = "";

  while (1) {
    $resp = $self->{'connection'}->getline($tomult);
    # Guard against read timeouts
    unless (defined $resp) {
      warn "Timed out getting response?" if ($tomult);
      return;
    }
      
    $resp =~ s/\r\n$//;
    $::log->message(550, "debug", "<<<$resp");
    ($code, $multi, $text) = ($resp =~ /(\d{3})(.)(.*)/);
    $message .= "$text\n";
    last if $multi eq " ";
  }
  if ($ignore && $code =~ /^(55[013])|(45[012])$/) {
    if ($code == 452) {
      $error = -2;
    }
    else {
      $error = -1;
    }
  }
  elsif ($code =~ /^[45]../) {
    $error = 0;
  }
  elsif ($code =~ /^[123]../) {
    $error = 1;
  }
  else {
    # Completely illegal SMTP response.  What to do?
    $::log->abort("Illegal SMTP response: $resp");
  }
     
  ($error, $code, $message);
}

=head2 hexchar

Encode characters for DSN ORCPT option.

=cut

sub hexchar {
  my $string = shift;
  my $encoded = "";
  my $i = 0;
  my $letter;

  while ($i < length $string) {
    $letter = substr $string, $i, 1;
    if ($letter =~ /[\000-\040\177-\377\+=]/) {
        $letter = "+" . uc sprintf "%lx", ord $letter;
    }
    $encoded .= $letter;
    $i++;
  }

  $encoded;
}


=head2 senddata

Send a single line of SMTP '.' escaped data.

=cut
sub senddata {
  my $self   = shift;
  my $string = shift;
  if ($string =~ /\n$/so) {
    $self->{'sentnl'} = 1;
  }
  else {
    $self->{'sentnl'} = 0;
  }

  $string =~ s/\n/\015\012/sgo;
  $string =~ s/^\./../;
#  $::log->message(551, "debug", ">>>$string");
  $self->{'connection'}->print("$string");
}

=head2 transact

Perform a complete SMTP command transaction.

=cut
sub transact {
  my $self = shift;
  return 0 unless $self->send(shift);
  $self->getresp(@_);
}

=head2 SMTP commands

These implement the various SMTP and ESMTP commands that we care about:

DATA, EHLO, HELO, MAIL, ONEX, RCPT, RSET, QUIT, ".".

Note that RCPT allows five times the normal timeout value, because some
MTAs will wait for a DNS lookup to complete before returning.

=cut
sub DATA { shift->transact("DATA"                    )}
sub EHLO { shift->transact("EHLO ".shift             )}
sub HELO { shift->transact("HELO ".shift             )}
sub MAIL { shift->transact("MAIL FROM: <".shift().">")}
sub ONEX { shift->transact("ONEX"                    )}
sub RCPT { 
  my $self = shift;
  my $recip = shift;
  my $encrcpt = hexchar($recip);
  my $cmd = "RCPT TO: <$recip>";
  if ($self->{'dsn'}) {
    $cmd .= " ORCPT=rfc822;$encrcpt";
  }
  $self->transact($cmd, 1, $self->{'pipelining'}? 0 : 5);
}
sub RSET { shift->transact("RSET"                    )}
sub QUIT { shift->transact("QUIT"                    )}

sub enddata {
  my $self = shift;

  # If we didn't end the last line with a newline, we need to add one
  # now or we may hang forever.
  unless ($self->{'sentnl'}) {
    $self->send('');
  }
  $self->transact(".")
}

1;
#
### Local Variables: ***
### mode:cperl ***
### cperl-indent-level:2 ***
### End: ***

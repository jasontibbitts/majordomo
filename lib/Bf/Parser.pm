=head1 NAME

Bf::Parser.pm - Functions for taking apart bounce messages.

=head1 DESCRIPTION

blah

=head1 SYNOPSIS

blah

=cut

package Bf::Parser;
use Mj::Log;
$VERSION = "0.0";
use strict;

=head2 parse

Takes an eneity and tries to determine whether or not it's a bounce.  If
so, it also tries to get as much useful information about the bounce as
posible.

Takes:

  A parsed entity containing the potential bounce message.
  The list name.
  The MTA's sender separator, for parsing the To: header.

Returns:

  type - type of message this was identified to be, as a single letter (M
    for list message, C for confirmation token, etc.)
  msgno   - the message number of the bouncing message, if known
  address - address (if any) extracted from an envelope VERP.
  data    - a hashref of data, one key per user 

We are supposed to give enough information to the calling layer so that it
can make a reasonable decision about what to do with the bounce.

If we can get a message number, pass it back.  There can only be one per
bounce, so that covers it.  If we could parse the bounce message to get
info, we need to communicate that.  Otherwise, we could only find the
address from the munged envelope and so the upper level needs to start
probing this address every run for some time.

If we can obtain disposition information (warning, failure, etc.) by
parsing a bounce, we must return it.  Otherwise the calling layer won't
know if we're just seeing warnings that it should just ignore.

A bounce can contain information about multiple addresses.  We have to pass
information about all of them.  This is more common than it may seem at
first.  The dispositions might not be the same for all addresses.

So we must return information gleaned from the envelope (message number,
poster) along with information from the parsed bounce, if any.

Technically, if there is no message number in the envelope then the message
is not a bounce.  Modulo really broken MTAs out there, of course.

A bounce could be in response to a post or to something like a confirmation
message.  For a post, the type will be M and a message number will be
included.  Other information will be present for other kinds of bounces.

=cut

sub parse {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $list = shift;
  my $sep  = shift;

  my ($data, $hints, $info, $msgno, $ok, $to, $type, $user);

  # Try to identify the bounce by parsing it
  $data = {}; $hints = {};
  $ok or ($ok = parse_dsn       ($ent, $data, $hints));
  $ok or ($ok = parse_exim      ($ent, $data, $hints));
  $ok or ($ok = parse_qmail     ($ent, $data, $hints));
  $ok or ($ok = parse_exchange  ($ent, $data, $hints));
  $ok or ($ok = parse_yahoo     ($ent, $data, $hints));
  $ok or ($ok = parse_sendmail  ($ent, $data, $hints));
  $ok or ($ok = parse_softswitch($ent, $data, $hints));

  # Look for useful bits in the To: header (assuming we even have one)
  $to = $ent->head->get('To');
  $to ||= '';

  # Look at the left hand side.  We expect to see the list name, followed
  # by '-owner', followed by the MTA-dependent separator followed by some
  # stuff.
  ($info) = $to =~ /\Q$list\E-owner\Q$sep\E([^@]+)\@/;

  # We might not have a special envelope
  if (!defined($info)) {

    # But if we did manage to parse a bounce, we should return something
    # useful anyway.
    if ($ok) {
      $type = 'M';
      $msgno = 'unknown';
    }
    else {
      $type = '';
    }
  }

  # We know the message is special.  Look for:
  # M\d{1,5}
  # M\d{1,5}=user=host
  # various other special types which we don't use right now.
  elsif ($info =~ /M(\d{1,5})=([^=]+)=([^=]+)/i) {
    $type   = 'M';
    $msgno  = $1;
    $user   = "$3\@$2";
  }
  elsif ($info =~ /M(\d{1,5})/i) {
    $type   = 'M';
    $msgno  = $1;
    $user   = undef;
  }
  else {
    $type = '';
  }

  return ($type, $msgno, $user, $data);
}

=head2 parse_dsn

Attempt to identify an RFC1894 DSN, as sent by Sendmail and Zmailer.

Returns:

  a flag; if true, we found a bounce of the appropriate format.  This does
  not mean that we have any bouncing address, only that there's no reason
  to check other formats.

The passed $data hashref is modified to contain data on each user found in
the bounce (including the status (faulure, warning, etc.) and any
user-readable diagnostic information present.  Note that this has may
contain users that are not actually subscribed, or could even contain
gueses at the bouncing address obtained by applying heuristics.  Don't
assume that every address returned here will be a subscriber to any list.

=cut

sub parse_dsn {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my $hints= shift;
  my (@status, $action, $diag, $fh, $i, $line, $nodiag, $ok, $to, $type,
      $user);

  # Check the Content-Type
  $type = $ent->head->get('content-type');

  # We can quit now if we don't have a type of multipart/report and a
  # subtype of delivery-status
  unless ($type &&
	  $type =~ m!multipart/report!i &&
	  $type =~ m!report-type=delivery-status!i)
    {
      $log->out('Wrong MIME type');
      return 0;
    }

  # So we must have a DSN.  The second part has the info we want.
  $type = $ent->parts(1)->mime_type;
  if ($type !~ m!message/delivery-status!i) {
    # Weird, the second part is always supposed to be of this type.  But
    # nothing else is going to be able to parse this message, so just
    # assume that we couldn't find a bouncing address.
    $log->out('Busted DSN?');
    return 1;
  }

  # Pull apart the delivery-status part, which consists of groups of
  # header-like lines followed by blank lines.  The first contains info
  # about the message, the following groups contain information about each
  # bouncing address in the DSN.  The standard doesn't seem to allow
  # continuation lines, so this is pretty simple.
  $fh = $ent->parts(1)->bodyhandle->open('r');

 REC:
  for ($i = 0; 1; $i++) {

    # Eat any blank lines at the start of the block
    while (1) {
      $line = $fh->getline;
      last REC unless defined $line;
      last unless $line =~ /^\s*$/;
    }
    # Now parse the block, until the end of the part or until the next
    # blank line.  We pull a new line in at the end of the block because we
    # know $line is non-blank after the previous loop
    while (1) {
      chomp $line;
      $line =~ /([^:]+):\s*(.*)/;
      $status[$i] = {} unless $status[$i];
      $status[$i]->{lc($1)} = $2;
      $line = $fh->getline;
      last REC unless defined $line;
      next REC if $line =~ /^\s*$/;
    }
  }

  # Some bounces (from some versions of Netscape Messaging server, at
  # least) look like legal DSNs but don't actually have the per-user
  # description block.  We call a special parser in another functuon to
  # deal with these, then return what that parser gave us.
  if (@status < 2) {
    $ok = check_dsn_netscape($ent, $data);
    return $ok;
  }

  # There's lots of info here, but we only want couple of things:
  # Original-Recipient: lines if we can get them, Final-Recipient: lines
  # otherwise, Action: fields, and Diagnostic-Code: if present. And we
  # don't want anything from the first group of status entries.
  for ($i = 1; $i < @status; $i++) {
    if ($status[$i]->{'original-recipient'}) {
      $user = $status[$i]->{'original-recipient'};
    }
    else {
      $user = $status[$i]->{'final-recipient'};
    }
    $user =~ s/.*?;\s*(.*?)\s*/$1/;
    $user =~ s/^<(.*)>$/$1/;
    if (lc($status[$i]->{'action'}) eq 'failed') {
      $action = 'failure';
    }
    elsif (lc($status[$i]->{'action'}) eq 'delayed') {
      $action = 'warning';
    }
    else {
      $action = 'none';
    }
    $data->{$user}{'status'} = $action;

    $diag = $status[$i]->{'diagnostic-code'};
    if ($diag) {
	$diag =~ s/^\s*SMTP;\s*//;
	$data->{$user}{'diag'} = $diag;
	# Sometimes we get diagnostics that say "250 OK" or some similar
	# stupidity.
	if ($diag =~ /250/) {
	  $nodiag = 1;
	}
      }
    else {
      $data->{$user}{'diag'} = "unknown";
      $nodiag = 1;
    }
  }

  # We may need to plow through the human-readable portion of the DSN to
  # get useful diagnostics
  if ($nodiag) {
    check_dsn_diags($ent, $data);
  }
  return 1;
}

=head2 parse_exchange

Attempts to parse the bounces issued by Microsoft Exchange Server.  These
bounces don't contain much useful information, but we try to get what we
acan.  It happens very often that the extracted address has little to do
with the actual recipient.

The subject of these bounces always starts with "Undeliverable:", so we use
that to descriminate.

The bounce itself may be in a single part, a multipart with the bounce
message attached, or in some multipart/alternative brokenness.  We try to
parse all three by opening the first text part we can find.

Then we have to parse the body, which contains information on teh bounced
message, followed by:

did not reach the following recipient(s):

Amanda_Weissert@roy-talman.com on Thu, 6 Jan 2000 14:26:09 -0600
    The recipient name is not recognized

followed by something understandable only to Exchange.

=cut
sub parse_exchange {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my $hints= shift;
  my ($bh, $diag, $line, $subj, $user);

  $subj = $ent->head->get('subject');
  unless ($subj =~ /undeliverable:/i) {
    $log->out("Wrong subject");
    return 0;
  }

  if ($ent->parts) {
    if ($ent->parts(0)->parts) {
      if ($ent->parts(0)->parts(0)->parts) {
	# Jeez; forget it.
	return 0;
      }
      $bh = $ent->parts(0)->parts(0)->bodyhandle->open('r');
    }
    else {
      $bh = $ent->parts(0)->bodyhandle->open('r');
    }
  }
  else {
    $bh = $ent->bodyhandle->open('r');
  }

  # We eat the message until we see the first line of the bounce block
  while (1) {
    $line = $bh->getline;
    return 0 unless defined $line;
    chomp $line;
    last if $line =~ /did not reach the following/i;
  }

  # Skip some whitespace
  while (1) {
    $line = $bh->getline;
    return 0 unless defined $line;
    last if $line !~ /^\s*$/;
  }

  # $line should now contain the address
  return 0 unless $line =~ /^\s*([^\s\@]+\@[^\s\@]+)\s+on/i;
  $user = $1;

  # The next line should contain the diagnostic
  $line = $bh->getline;
  return 0 unless defined $line;
  $line =~ /^\s*(.*)$/;
  $diag = $1;

  $data->{$user}{'status'} = 'failure';
  $data->{$user}{'diag'}   = $diag;

  1;
}

=head2 parse_exim

Attempts to parse the bounces issued by the Exim MTA.  These bounces come
from Mailer-Daemon and look like the following:

This message was created automatically by mail delivery software.

A message that you sent could not be delivered to one or more of its
recipients. The following address(es) failed:

  asdfasd@lists.math.uh.edu:
    unknown local-part "asdfasd" in domain "lists.math.uh.edu"
    Another line of diagnostics, just to make it difficult.
  hurl@lists.math.uh.edu:
    unknown local-part "hurl" in domain "lists.math.uh.edu"

------ This is a copy of the message, including all the headers. ------

followed by the entire message.

The indentation is important.  Two spaces = address followed by colon.
Four spaces = diagnostic.

Failure is indicated by the string "could not be delivered"; a warning has
"has not yet been delivered".  Warnings also have a different in-body
format, having addresses indented by two spaces, not followed by a colon
and with no following diagnostic.

=cut
sub parse_exim {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my $hints= shift;
  my ($bh, $diag, $line, $ok, $status, $user);

  return 0 if $ent->parts;
  $ok = 0;
  $bh = $ent->bodyhandle->open('r');

  # We eat the message until we see the trademark Exim bounce line
  while (1) {
    $line = $bh->getline;
    return 0 unless defined $line;
    chomp $line;
    next if $line =~ /^\s*$/;
    last if (lc($line) eq 
	     'this message was created automatically by mail delivery software.');
  }

  # We've just seen the line, so we know we have an Exim-format bounce.
  # Eat stuff until we see an address:
  $status = 'unknown';
  while (1) {
    $line = $bh->getline;
    last unless defined $line;
    chomp $line;
    next if $line =~ /^\s*$/;

    # Look for the line indicating that we have a warning
    if ($line =~ /has not yet been delivered/i) {
      $status = 'warning';
      next;
    }

    if ($line =~ /could not be delivered/i) {
      $status = 'failure';
      next;
    }

    # Stop before we get into the bounced message
    if ($line =~ /^-/) {
      if ($user) {
	$ok = 1;
	$data->{$user}{'status'} = $status;
	$data->{$user}{'diag'}   = $diag;
      }
      last;
    }

    # If we have a user, we've ended the previous diag block (if any), so
    # save that data and clear it out for a new block.
    if ($line =~ /^  (\S.*):\s*$/) {
      if ($user) {
	$data->{$user}{'status'} = $status;
	$data->{$user}{'diag'}   = $diag;
      }
      $diag = '';
      $user = $1;
    }
    elsif ($line =~ /^ {4}(.*)$/) {
      $diag .= $1;
    }
    # In warnings, we just get a list of addresses indented by two spaces
    elsif ($status eq 'warning' && $line =~ /^  (\S.*\@.*)\s*$/) {
      $data->{$1}{'status'} = $status;
      $data->{$1}{'diag'}   = 'none included in bounce';
      $ok = 1;
      next;
    }
  }

  $ok;
}

=head2 parse_sendmail

Attempts to parse the bounces issued by older versions of Sendmail.

We read until we get to:

   ----- The following addresses had permanent fatal errors -----

One address per line follows until the next blank line.

After the users are extracted, we call check_dsn_diags to make use of
the logic there for pulling diagnostics out of the SMTP transaction.

=cut
sub parse_sendmail {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($bh, $line, $ok, $user);

  return 0 if $ent->parts;
  $bh = $ent->bodyhandle->open('r');
  return 0 unless $bh;

  while (1) {
    $line = $bh->getline;
    return 0 if !defined($line) || $line =~ /^\s*-+\s+original message/i;
    last if $line =~ /^\s*-+\s*the following addresses had permanent fatal errors/i;
  }

  while (defined($line = $bh->getline)) {
    last if $line =~ /^\s*$/;
    if ($line =~ /^\s*<(.*)>\s*$/) {
      $data->{$1}{'status'} = 'failure';
      $data->{$1}{'diag'}   = 'unknown';
      $ok = 1;
    }
  }
  if ($ok) {
    check_dsn_diags($ent, $data);
  }
  $ok;
}

=head2 parse_softswitch

Attempts to parse the bounces issued by Soft-Switch LMS.  Subject contains
"Delivery Report (failure)", bounces are single-part and body has:

This report relates to your message: Majordomo res...
        of Thu, 23 Dec 1999 16:33:44 +0100

Your message was not delivered to   xxxx@yyyy.es
        for the following reason:
        Recipient's Mailbox unavailable
        Originator could not be auto-registered.

This routine was written with two bounces as examples.  It may not be
correct for all versions or in general.

=cut
sub parse_softswitch {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($bh, $diag, $failure, $line, $ok, $user);

  return 0 if $ent->parts;

  $bh = $ent->bodyhandle->open('r');
  return 0 unless $bh;

  while (defined($line = $bh->getline)) {
    next if $line =~ /^\s*$/;
    last if $line =~ /^\s*this report relates to/i;
    return 0;
  }

  while (defined($line = $bh->getline)) {
    return 0 if $line =~ /^\s*\*/;
    if ($line =~ /^\s*your message was not delivered to\s+(.*)\s*$/i) {
      $user = $1; $diag = '';
      $line = $bh->getline;
      return 0 unless $line =~ /\s*for the following/i;
      last;
    }
  }
  while (defined($line = $bh->getline)) {
    return 0 if $line =~ /^\s*\*/;
    last if $line =~ /^\s*$/;
    chomp $line; $line =~ s/^\s+//; $line =~ s/\s+$//;
    $diag .= ' ' if $diag;
    $diag .= $line;
  }
  $data->{$user}{'status'} = 'failure';
  $data->{$user}{'diag'}   = $diag;

  1;
}

=head2 parse_qmail

Attempts to parse the bounces issued by qmail.  These bounces look like this:

Hi. This is (site specific text)
I'm afraid I wasn't able to deliver your message to the following addresses.
This is a permanent error; I've given up. Sorry it didn't work out.

<www.pintu28@netzero.com>:
Sorry, no mailbox here by that name. (#5.1.1)

--- Below this line is a copy of the message.

There is no useful identifying information in the header.  We pull down the
first non-blank like, look for "Hi", then look for "permanent error" to
make sure it's not a warning.  (What does a warning look like, anyway?)

=cut
sub parse_qmail {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($bh, $diag, $failure, $line, $ok, $user);

  $ok = 0;

  # Qmail mails only single-part bounces
  return 0 if $ent->parts;

  # The first non-blank line must contain the qmail greeting.
  $bh = $ent->bodyhandle->open('r');
  return 0 unless $bh;
  while (defined($line = $bh->getline)) {
    next if $line =~ /^\s*$/;
    last if $line =~ /^\s*hi.*this is/i;
    return 0;
  }

  # Now look for two things: a line containing "permanent error" which
  # tells us that we're processing a set of failures, and an address in
  # angle brackets.
  while (defined($line = $bh->getline)) {
    if ($line =~ /permanent error/i) {
      $failure = 1;
      next;
    }
    if ($line =~ /^<(.*)>:$/) {
      $user = $1;
      $line = $bh->getline;
      return 0 unless defined $line;
      chomp $line;
      $data->{$user}{'diag'} = $line;
      $data->{$user}{'status'} = $failure? 'failure' : 'warning';
      $ok = 1;
    }
    if ($line =~ /---.*copy of the message/i) {
      last;
    }
  }
  return $ok;
}

=head2 parse_yahoo

Attempts to parse the bounces issued by Yahoo as of 2000.05.20.

These bounces come from MAILER-DAEMON@yahoo.com, have a subject of "failure
delivery" and have a body looking like:

Message from  yahoo.com.
Unable to deliver message to the following address(es).

<someone@yahoo.com>:
User is over the quota.  You can try again later.


--- Original message follows.

followed by a truncated version of the original message.

=cut

sub parse_yahoo {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my (%ok_from, %ok_subj, $bh, $line, $ok);

  %ok_from = ('mailer-daemon@yahoo.com' => 1);
  %ok_subj = ('failure delivery'         => 1);
  $ok = 0;

  # First check the From: and Subject: headers to see if we understand this
  # bounce
  my $f = lc($ent->head->get('from'));
  my $s = lc($ent->head->get('subject'));
  chomp $f; chomp $s;
  return 0 unless $ok_from{lc($f)};
  return 0 unless $ok_subj{lc($s)};
  return 0 if $ent->parts; # Must be able to open the body

  # Now run through the body.  We look for an address in brackets and, on
  # the next line, the diagnostic.  We assume that we've failed; I don't
  # believe that yahoo ever issues warnings.
  $bh = $ent->bodyhandle->open('r');
  return 0 unless $bh;
  while (defined($line = $bh->getline)) {
    chomp $line;

    # Bail if we're getting into the bounced message
    return $ok if lc($line) eq '--- original message follows.';

    # If we have an address...
    if ($line =~ /<(.*)>:/) {
      $ok = 1;
      $data->{$1}{'status'} = 'failure';

      # The next line holds the diagnostic
      $line = $bh->getline;
      chomp($line);
      $data->{$1}{'diag'} = $line;
    }
  }
  $ok;
}

=head2 check_dsn_diags

Does extra parsing for bounces where we could extract bouncing addresses
but didn't get useful diagnostics.  This uncludes DSns not including the
optional diagnostic-code-field and those who include the field but indlude
a string like "250 OK" or "250 Message accepted for delivery" instead of
something useful.

These MTAs all seem to be some version of Sendmail and all seem to include
some useful data at the end of the human-readable portion of the DSN, in a
block that looks like:

   ----- Transcript of session follows -----
... while talking to XXXX.net.:
>>> RCPT To:<yyyy@XXXX.NET>
<<< 553 <yyyy@XXXX.NET>... Users mailbox is currently disabled
550 <yyyy@XXXX.NET>... User unknown

We look for lines like:

<<< 553 <yyyy@XXXX.NET>... Users mailbox is currently disabled
550 <yyyy@XXXX.NET>... User unknown
550 yyyy@XXXX.NET... User unknown

and we also look for bare user names.  These are matched against the users
that DSN parsing found but couldn't extract diagnostic information for.

This function returns no useful value.

=cut
sub check_dsn_diags {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($diag, $fh, $i, $line, $ok, $type, $user);

  if ($ent->parts) {
    # Check the type of the first part; it should be plain text
    $type = $ent->parts(0)->mime_type;
    if ($type !~ m!text/plain!i) {
      return 0;
    }

    $fh = $ent->parts(0)->bodyhandle->open('r');
  }
  else {
    $fh = $ent->bodyhandle->open('r');
  }

  while (1) {
    $line = $fh->getline;
    return unless defined $line;
    last if $line =~ /transcript of session follows/i;
  }

  # We try to find a line that looks like an SMTP response, since that will
  # proably have the most accurate error message.  Look for the following,
  # in order:

  # <<< 552 <address>... Mailbox Full
  # 550 <address>... User Unknown
  # <<< 552 address... Mailbox Full
  # <<< 552 address Mailbox Full
  # 550 address... User unknown

  # Note that when the address is in brackets, we don't have to be explicit
  # about the three dots and whitespace, but if we don't have the brackets
  # then we require the exact format.  The order was chosen to reduce false
  # positives.
  while (defined($line = $fh->getline)) {
    $line =~ s/^\s*//; $line =~ s/\s*$//;
    next unless $line;
    if ($line =~ /^<<<\s*\d{3}\s*<(.*)>[\s\.]*(.*)$/i ||
	$line =~ /^\d{3}\s*<(.*)>[\s\.]*(.*)$/i       ||
	$line =~ /^<<<\s*\d{3}\s*(.*)\.{3}\s*(.*)$/i  ||
	$line =~ /^<<<\s*\d{3}\s*([^\s]*)\s+(.*)$/i   ||
	$line =~ /^\d{3}\s*([^\s]*)\.{3}\s*(.*)$/i
       )
      {
	$user = $1; $diag = $2;
      }
    # Another pattern, but with the order reversed
    elsif ($line =~ /^\s*\d{3}\s*(.*)\s*to\s*<(.*)>/i) {
      $user = $2; $diag = $1;
    }
    if ($user) {
      for $i (keys %$data) {
	if ((lc($i) eq lc($user) || $i =~ /^\Q$user\E@/i) &&
	    (
	     $data->{$i}{'diag'} eq 'unknown' ||
	     $data->{$i}{'diag'} =~ /250/     ||
	     !defined($data->{$i}{'diag'})
	    ))
	  {
	    $data->{$i}{'diag'} = $diag;
	  }
      }
    }
  }
}

=head2 check_dsn_netscape

Does extra parsing for bounces that come from some versions of Netscape
Messaging Server (4.15 and 4.03, at least).  These look just like DSNs but
don't contain any per-user delivery status blocks (making them illegal
according to RFC1894.  The DSN parser will call us explicitly when it sees
that it needs to.

To parse it, we have to plow through the human-readable portion to find
users and diagnostics.  But note that this idiotic software uses different
bounce formats when it recognizes different SMTP errors, so we have to
parse a bunch of different kinds of bounces.  Here are the things we look
for:

1) Lines like the following:

User quota exceeded: SMTP <xxxx@yyyy.net>

We match with (.*): [sl]mtp <(.*)>.

2) A block like

    Recipient: <xxxx@yyyy.net>
    Reason:    <xxxx@yyyy.net>... Relaying denied

We match against /^\s*recipient:\s*<(.*)>\s*$/i, and then pull in the
following line.

3) A block with the diagnostic first, like:

     DNS for host yyyy.net is mis-configured
The following recipients did not receive this message:
     <xxxx@yyyy.net>

We keep the previous line around and when we hit the second line we know to
save away the diagnostics and pull out addresses until the next blank.

4) A variant of the first, without as much identifying information:

User quota exceeded: xxxx@yyyy.com

Parsed with /^([^:]+):\s+(.*)\s*$/

5) A variant of #3:

This Message was undeliverable due to the following reason:

The following destination addresses were unknown (please check
the addresses and re-mail the message):

SMTP <xxxx@yyyy.net>

=cut
sub check_dsn_netscape {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my $hints= shift;
  my ($fh, $diag, $format3, $format5, $line, $ok, $oline, $type, $user);

  # Check the type of the first part; it should be plain text
  $type = $ent->parts(0)->mime_type;
  if ($type !~ m!text/plain!i) {
    return 0;
  }

  $fh = $ent->parts(0)->bodyhandle->open('r');
  $format5=0;
 LINE:
  while (1) {
    $oline = $line; $line = $fh->getline; last unless defined $line;
    if ($line =~ /(.*): [sl]mtp <(.*)>$/i) {
#      warn "format 1";
      $user = $2;
      $diag = $1;
    }

    elsif ($line =~ /^\s*recipient:\s*<(.*)>\s*$/i) {
#      warn "format 2";
      $user = $1;
      $line = $fh->getline;
      last unless defined $line;
      chomp $line;
      $line =~ s/^\s*reason:\s*//i;
      $diag = $line;
    }

    elsif ($line =~ /following recipients did not receive/i) {
#      warn "format 3";
      $diag = $oline;
      chomp $diag; $diag =~ s/^\s*//;
      $line = $fh->getline;
      last unless defined $line;
      if ($line =~ /^\s*<(.*)>\s*$/) {
	$user = $1;
	$format3 = 1;
      }
      else {
	undef $diag; undef $user;
      }
    }
    elsif ($format3) {
      if ($line =~ /^\s*<(.*)>\s*$/) {
	$user = $1;
      }
      else {
	undef $diag; undef $user; undef $format3;
      }
    }

    elsif ($line =~ /^([^:]+):\s+(.+)\s*$/) {
#      warn "format 4";
      $user = $2; $diag = $1;
    }

    # The fifth format; first look for the start of the diagnostic
    elsif ($line =~ /the following destination addresses/i) {
#      warn "format 5";
      $diag = $line;
      chomp $diag; $diag =~ s/^\s*//;
      $format5 = 1;
    }
    # Parsing the rest of the diagnostic
    elsif ($format5 == 1) {
      if ($line =~ /^\s*$/) {
	$format5=2;
      }
      chomp $line;
      $diag .= " $line";
    }
    # Parsing the addresses
    elsif ($format5 == 2) {
      last if $line =~ /^\s*$/;
      if ($line =~ /^\s*smtp\s*<(.*)>\s*$/i) {
	$user = 1;
      }
      else {
	next;
      }
    }

    if ($user) {
      $data->{$user}{'status'} = 'failure';
      $data->{$user}{'diag'}   = $diag;
      $ok = 1;
    }
  }
  $ok;
}

=head1 COPYRIGHT

Copyright (c) 2000 Jason Tibbitts for The Majordomo Development Group.  All
rights reserved.

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
### cperl-label-offset:-1 ***
### End: ***

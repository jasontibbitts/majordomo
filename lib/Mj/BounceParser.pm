=head1 NAME

Mj::BounceParser.pm - Functions for taking apart bounce messages.

=head1 DESCRIPTION

A set of routines for parsing bounces.

MTAs whose bounces are parsed:
  Any which properly support DSNs.
  Exim
  Qmail (and Yahoo)
  Postfix
  MS Exchange
  Classic Sendmail
  Compuserve
  Lotus
  Post.Office
  SoftSwitch
  Netscape Mail Server's broken DSNs
  SMTP32

MTAs whose bounces aren't parsed:
  Mercury
  SLMail
  Bigfoot TOE mail
  EMWAC SMTPRS

These are all doable (though not easy), but rare enough that the difficulty
currently outweighs the benefit.  If you're getting a lot of them, let me
know or implement a parser yourself.

MTAs whose bounces aren't boing to be parsed:
  MMDF (who came up with these bounces?)
  Any broken enough to not bother including any mention of the recipient
   address.


=head1 SYNOPSIS

blah

=cut

package Mj::BounceParser;
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
  my $ent  = shift;
  my $list = shift;
  my $sep  = shift;
  my $log  = new Log::In 50, "$list, $sep";

  my ($data, $hints, $info, $msgno, $ok, $to, $type, $user);

  # Try to identify the bounce by parsing it
  $data = {}; $hints = {};
  $ok or ($ok = parse_dsn       ($ent, $data, $hints));
  $ok or ($ok = parse_exim      ($ent, $data, $hints));
  $ok or ($ok = parse_postfix   ($ent, $data, $hints));
  $ok or ($ok = parse_qmail     ($ent, $data, $hints));
  $ok or ($ok = parse_exchange  ($ent, $data, $hints));
  $ok or ($ok = parse_sendmail  ($ent, $data, $hints));
  $ok or ($ok = parse_compuserve($ent, $data, $hints));
  $ok or ($ok = parse_msn       ($ent, $data, $hints));
  $ok or ($ok = parse_lotus     ($ent, $data, $hints));
  $ok or ($ok = parse_postoffice($ent, $data, $hints));
  $ok or ($ok = parse_softswitch($ent, $data, $hints));
  $ok or ($ok = parse_smtp32    ($ent, $data, $hints));

  # XXX Remove parse_compuserve2 once it is verified that no more bounces
  # are being produced in that format.
  $ok or ($ok = parse_compuserve2($ent, $data, $hints));

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
  # T.*
  # various other special types which we don't use right now.
  elsif ($info =~ /^M(\d{0,5})=([^=]+)=([^=]+)/i) {
    $type   = 'M';
    $msgno  = $1;
    $user   = "$3\@$2";
  }
  elsif ($info =~ /^M(\d{1,5})/i) {
    $type   = 'M';
    $msgno  = $1;
    $user   = undef;
  }
  elsif ($info =~ /^T(.*)/i) {
    $type  = 'T';
    $msgno = $1;
    $user  = undef;
  }
  else {
    $type = '';
  }

  return ($type, $msgno, $user, $ok, $data);
}

=head2 parse_compuserve

Attempts to parse bounces issued by Compuserve. These bounces look like
this:

Receiver not found: 5of7


Your message could not be delivered as addressed.

Plus a chatty explanation which we ignore.

=cut
sub parse_compuserve {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($bh, $diag, $from, $line, $ok, $user);

  # The message must come from postmaster@compuserve.com
  $from = $ent->head->get('from'); chomp $from;
  return unless $from =~ /postmaster\@compuserve.com/i;

  # Compuserve only sends single-part bounces
  return if $ent->parts;

  $bh = $ent->bodyhandle->open('r');
  return unless $bh;

  # Each of the initial non-blank lines contains a message and user
  while (1) {
    $line = $bh->getline;
    last unless defined $line;
    chomp $line;
    last if $line =~ /^\s*$/;
    last unless $line =~ /^(.*)\s*:\s*(.*)$/;
    $user = "$2\@compuserve.com"; $diag = $1;
    $data->{$user}{'diag'} = $diag;
    $data->{$user}{'status'} = 'failure';
    $ok = 'Compuserve';
  }

  $ok;
}

=head2 parse_compuserve2

Attempts to parse the bounces that used to be issued by Compuserve.  These
bounces look like this:

Your message could not be delivered due to the following:

Invalid receiver address: xxxx@compuserve.com
Invalid receiver address: yyyy@compuserve.com

An explanation follows, but we ignore it.

=cut
sub parse_compuserve2 {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($bh, $diag, $from, $line, $ok, $user);

  # The message must come from postmaster@compuserve.com
  $from = $ent->head->get('from'); chomp $from;
  return unless $from =~ /postmaster\@compuserve.com/i;

  # Compuserve only sends single-part bounces
  return if $ent->parts;

  # The first non-blank line must contain the "greeting"
  $bh = $ent->bodyhandle->open('r');
  return unless $bh;
  while (defined($line = $bh->getline)) {
    next if $line =~ /^\s*$/;
    last if $line =~ /^\s*your message could not be delivered due to the following:\s*/i;
    return;
  }

  # Skip blanks; expect all other lines to match the diag: address format.
  # If not, stop parsing.
  while (defined($line = $bh->getline)) {
    next if $line =~ /^\s*$/;
    if ($line =~ /^([^:]+):\s*(.*?)\s*$/) {
      $user = $2; $diag = $1;
      $data->{$user}{'diag'} = $diag;
      $data->{$user}{'status'} = 'failure';
      $ok = 'Compuserve (old)';
    }
    else {
     last;
    }
  }
  $ok;
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
      return;
    }

  # So we must have a DSN.  The second part has the info we want.
  $type = $ent->parts(1)->mime_type;
  if ($type !~ m!message/delivery-status!i) {
    # Weird, the second part is always supposed to be of this type.  But
    # nothing else is going to be able to parse this message, so just
    # assume that we couldn't find a bouncing address.
    $log->out('Busted DSN?');
    return 'Broken DSN';
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
    return 'DSN + diag extraction';
  }
  'DSN';
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
    return;
  }

  if ($ent->parts) {
    if ($ent->parts(0)->parts) {
      if ($ent->parts(0)->parts(0)->parts) {
	# Jeez; forget it.
	return;
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
    return unless defined $line;
    chomp $line;
    last if $line =~ /did not reach the following/i;
  }

  # Skip some whitespace
  while (1) {
    $line = $bh->getline;
    return unless defined $line;
    last if $line !~ /^\s*$/;
  }

  # $line should now contain the address
  return unless $line =~ /^\s*([^\s\@]+\@[^\s\@]+)\s+on/i;
  $user = $1;

  # The next line should contain the diagnostic
  $line = $bh->getline;
  return unless defined $line;
  $line =~ /^\s*(.*)$/;
  $diag = $1;

  $data->{$user}{'status'} = 'failure';
  $data->{$user}{'diag'}   = $diag;

  'Exchange';
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

Exim also conveniently includes an X-Failed-Recipients: header.  We still
want to parse the body to extract a diagnostic, but it is possible that
someone will install a custom bounce format so we use the header as a
fallback.

=cut
sub parse_exim {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my $hints= shift;
  my ($bh, $diag, $i, $line, $ok, $status, $user);

  # Check for X-Failed-Recipients: headers
  for $i ($ent->head->get('X-Failed-Recipients')) {
    chomp $i;
    $data->{$i}{diag}   = 'unknown';
    $data->{$i}{status} = 'failure';
    $ok = 'Exim';
  }

  return $ok if $ent->parts;
  $bh = $ent->bodyhandle->open('r');

  # We eat the message until we see the trademark Exim bounce line
  while (1) {
    $line = $bh->getline;
    return $ok unless defined $line;
    chomp $line;
    next if $line =~ /^\s*$/;
    last if $line =~ /^\s*this message was created automatically by mail delivery software/i;
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
	$ok = 'Exim';
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
      $ok = 'Exim';
      next;
    }
  }

  $ok;
}

=head2 parse_lotus

Attempts to parse the bounces issued by Lotus SMTP MTA (v1.2, at least).
These bounces look like this:

------- Failure Reasons  --------

User  not listed in public Name & Address Book
xxxx@notes.yyyy.com


------- Returned Message --------

Examples of warnings from this MTA are welcomed.

=cut
sub parse_lotus {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($bh, $diag, $line, $ok, $user);

  # Lotus mails only single-part bounces
  return if $ent->parts;

  # The first non-blank line must contain the greeting
  $bh = $ent->bodyhandle->open('r');
  return unless $bh;
  while (1) {
    $line = $bh->getline;
    return unless defined $line;
    next if $line =~ /^\s*$/;
    last if $line =~ /^-+\s+failure reasons/i;
    return;
  }

  # Next non-blank line is the diag, next line is the user
  while (defined($line = $bh->getline)) {
    next if $line =~ /^\s*$/; chomp $line;
    $diag = $line;
    $line = $bh->getline;
    return unless $line;
    chomp $line;
    $user = $line;

    $data->{$user}{'diag'}   = $diag;
    $data->{$user}{'status'} = 'failure';
    last; # Never seen more than one bouncing user per bounce
  }

  'Lotus';
}

=head2 parse_msn

Attempts to parse the bounces issued by MSN.  These bounces are multipart;
the first part is flat and looks like this:

------Transcript of session follows -------
XXXX@email.msn.com
The user's email name is not found.
Possible additional lines.

These headers are also present:

From: Postmaster<Postmaster@email.msn.com>
Subject: Nondeliverable mail

MSN does not (to the best of my knowledge) issue warnings.

=cut
sub parse_msn {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($bh, $diag, $line, $ok, $user);

  # Check the subject
  return unless $ent->head->get('Subject') =~ /nondeliverable mail/i;

  # MSN only mails multipart bounces; the first part is flat
  return unless $ent->parts;
  return if $ent->parts(0)->parts;

  # The first non-blank line must contain the greeting
  $bh = $ent->parts(0)->bodyhandle->open('r');
  return unless $bh;

  while (1) {
    $line = $bh->getline;
    return unless defined $line;
    next if $line =~ /^\s*$/;
    last if $line =~ /^-+transcript of session follows/i;
    return;
  }

  # Next line is the user, next is the diag.
  chomp($user = $bh->getline);
  return unless $user =~ /.+\@.+/;

  while (1) {
    $line = $bh->getline;
    last unless defined $line;
    last if $line =~ /^\s*$/;
    chomp $line;
    $diag .= ' ' if $diag;
    $diag .= $line;
  }

  $data->{$user}{'diag'}   = $diag || 'unknown';
  $data->{$user}{'status'} = 'failure';

  'MSN';
}

=head2 parse_postfix

Attempts to parse the bounces issued by Postfix.

The message is multipart, with the first part being text/plain and having a
content-description of 'Notification'.  The identifying line is:

This is the Postfix program at host.*

Failure is indicated by the string "could not be delivered".

Bouncing addresses are located at the end, and look like

<xxxx@yyyy.org>: unknown user: "xxxx"

=cut
sub parse_postfix {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($bh, $diag, $failure, $line, $ok, $user);

  # Postfix returns only multipart bounces nested one level deep
  return unless $ent->parts;
  return if $ent->parts(0)->parts;

  $bh = $ent->parts(0)->bodyhandle->open('r');
  return 0 unless $bh;

  # The first non-blank line must contain the Postfix greeting
  while (defined($line = $bh->getline)) {
    next if $line =~ /^\s*$/;
    last if $line =~ /^\s*this is the postfix program/i;
    return;
  }

  # Now look for two things: a line containing "could not deliver" which
  # tells us that we're processing a set of failures, and an address in
  # angle brackets.
  while (defined($line = $bh->getline)) {
    if ($line =~ /could not be delivered/i) {
      $failure = 1;
      next;
    }
    if ($line =~ /^\s*<(.*)>:\s+(.*?)\s*$/) {
      $user = $1;
      $diag = $2;
      $data->{$user}{'diag'} = $diag;
      $data->{$user}{'status'} = $failure? 'failure' : 'warning';
      $ok = 'Postfix';
    }
  }
  $ok;
}

=head2 parse_postoffice

Attempts to parse the bounces issued by Post.Office (v3.5.3 tested).  These
bounces are multipart; the first part looks like this:


This Message was undeliverable due to the following reason:

Your message was not delivered because the DNS records for the
destination computer could not be found.  Carefully check that
the address was spelled correctly, and try sending it again if
there were any mistakes.

It is also possible that a network problem caused this situation,
so if you are sure the address is correct you might want to try to
send it again.  If the problem continues, contact your friendly
system administrator.

     Host yyyy.uk not found

The following recipients did not receive this message:

     <xxxx@yyyy.uk>

Please reply to Postmaster@site-2.jet.uk
if you feel this message to be in error.

Post.Office bounces are chatty and this makes it tough to get just a simple
diagnostic.  What we try to do is pull out the first sentence of the first
paragraph of the diagnostic and all of the users.  The diag is after the
"This message was undeliverable" line and the users are after the "The
following recipients" line.

=cut
sub parse_postoffice {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($bh, $diag, $line, $user);

  # Post.Office sends multipart bounces, each part is flat.
  return unless $ent->parts;
  return if $ent->parts(0)->parts;

  $bh = $ent->parts(0)->bodyhandle->open('r');
  return unless $bh;

  # Look for the line introducing the diagnostic
  while (defined($line = $bh->getline)) {
    next if $line =~ /^\s*$/;
#warn "A $line";
    last if $line =~ /^\s*this message was undeliverable due to the following reason:\s*$/i;
  }

  while (defined($line = $bh->getline)) {
    next if $line =~ /^\s*$/ && !$diag;
    last if $line =~ /^\s*$/;
#warn "B $line";
    chomp $line; $diag .= ($diag?' ':'').$line;
  }

  # We just want the first sentence of the diagnostic
  $diag =~ s/([^\.]+\.).*/$1/;

  # Look for the line introducing the users
  while (defined($line = $bh->getline)) {
    next if $line =~ /^\s*$/;
#warn "C $line";
    last if $line =~ /^\s*the following recipients did not receive this message:\s*$/i;
  }

  while (defined($line = $bh->getline)) {
    next if $line =~ /^\s*$/ && !$user;
    last if $line =~ /^\s*$/;
#warn "D $line";
    last unless $line =~ /^\s*<(.*)>\s*$/;
    $user = $1;

    if ($user) {
      $data->{$user}{'diag'} = $diag;
      $data->{$user}{'status'} = 'failure';
    }
  }

  return unless defined $user;
  'Post.Office';
}

=head2 parse_qmail

Attempts to parse the bounces issued by qmail, and also by yahoo (which is
possibly running a modified qmail).  These bounces look like this:

Hi. This is (site specific text)
I'm afraid I wasn't able to deliver your message to the following addresses.
This is a permanent error; I've given up. Sorry it didn't work out.

<xxxx@yyyy.com>:
Sorry, no mailbox here by that name. (#5.1.1)

--- Below this line is a copy of the message.

Yahoo messages instead look like:

Message from  yahoo.com.
Unable to deliver message to the following address(es).

<xxxx@yahoo.com>:
User is over the quota.  You can try again later.


--- Original message follows.

Any message that doesn't match the "failure text" is assumed to be a
warning.  Examples of warnings from qmail or Yahoo would be welcomed.

=cut
sub parse_qmail {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($bh, $diag, $failure, $line, $ok, $type, $user);

  # Qmail mails only single-part bounces
  return if $ent->parts;

  # The first non-blank line must contain the qmail or yahoo greeting.
  $bh = $ent->bodyhandle->open('r');
  return unless $bh;
  while (defined($line = $bh->getline)) {
    next if $line =~ /^\s*$/;
    $type = 'Qmail';
    last if $line =~ /^\s*hi.*this is/i;
    last if $line =~ /^\s*this is the mail transport/i;
    $type = 'Yahoo';
    last if $line =~ /^\s*message from\s*yahoo.com/i;
    return;
  }

  # Now look for two things: a line containing "permanent error" or "unable
  # to deliver" which tells us that we're processing a set of failures, and
  # an address in angle brackets.
  while (defined($line = $bh->getline)) {
    if ($line =~ /permanent error/i   ||
	$line =~ /unable to deliver/i ||
	$line =~ /could not be delivered/i)
      {
	$failure = 1;
	next;
      }
    if ($line =~ /^<(.*)>:$/) {
      $user = $1;
      $line = $bh->getline;
      return unless defined $line;
      chomp $line;
      $data->{$user}{'diag'} = $line;
      $data->{$user}{'status'} = $failure? 'failure' : 'warning';
      $ok = $type;
    }
    if ($line =~ /---.*copy of the message/i ||
	$line =~ /---.*original message follows/i)
      {
	last;
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

  return if $ent->parts;
  $bh = $ent->bodyhandle->open('r');
  return unless $bh;

  while (1) {
    $line = $bh->getline;
    return if !defined($line) || $line =~ /^\s*-+\s+original message/i;
    last if $line =~ /^\s*-+\s*the following addresses had permanent fatal errors/i;
  }

  while (defined($line = $bh->getline)) {
    last if $line =~ /^\s*$/;
    if ($line =~ /^\s*<(.*)>\s*$/) {
      $data->{$1}{'status'} = 'failure';
      $data->{$1}{'diag'}   = 'unknown';
      $ok = 'Sendmail Classic';
    }
  }
  if ($ok) {
    check_dsn_diags($ent, $data);
  }
  $ok;
}

=head2 parse_smtp32

Attempts to parse the bounces issued by an MTA I've never heard of called
SMTP32.

It identifies itself by an X-Mailer header:

X-Mailer: <SMTP32 v991129>

The only thing we care about is the first line of the bounce, which looks
something like:

User mailbox exceeds allowed size: xxxx@yyyy.net

=cut
sub parse_smtp32 {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($bh, $diag, $line, $user, $xmailer);

  $xmailer = $ent->head->get('X-Mailer');
  return unless $xmailer && $xmailer =~ /SMTP32/i;

  return if $ent->parts;
  $bh = $ent->bodyhandle->open('r');
  return unless $bh;

  while (1) {
    $line = $bh->getline;
    last unless $line =~ /^\s*$/;
  }
  return unless $line =~ /([^:]+):\s+(.*)/;
  $user = $2; $diag = $1;
  $data->{$user}{'status'} = 'failure';
  $data->{$user}{'diag'}   = $diag;

  'SMTP32';
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

  return if $ent->parts;

  $bh = $ent->bodyhandle->open('r');
  return unless $bh;

  while (1) {
    $line = $bh->getline;
    return unless defined $line;
    next if $line =~ /^\s*$/;
    last if $line =~ /^\s*this report relates to/i;
    return;
  }

  while (defined($line = $bh->getline)) {
    return 0 if $line =~ /^\s*\*/;
    if ($line =~ /^\s*your message was not delivered to\s+(.*)\s*$/i) {
      $user = $1; $diag = '';
      $line = $bh->getline;
      return unless $line =~ /\s*for the following/i;
      last;
    }
  }
  while (defined($line = $bh->getline)) {
    return if $line =~ /^\s*\*/;
    last if $line =~ /^\s*$/;
    chomp $line; $line =~ s/^\s+//; $line =~ s/\s+$//;
    $diag .= ' ' if $diag;
    $diag .= $line;
  }
  $data->{$user}{'status'} = 'failure';
  $data->{$user}{'diag'}   = $diag;

  'SoftSwitch';
}

=head2 check_dsn_diags

Does extra parsing for bounces where we could extract bouncing addresses
but didn't get useful diagnostics.  This includes DSNs not including the
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
    last if $line =~ /^\s*-+\s*transcript of session follows/i;
  }

  # We try to find a line that looks like an SMTP response, since that will
  # proably have the most accurate error message.  Look for the following,
  # in order:

  # <<< 552 <address>... Mailbox Full
  # 550 <address>... User Unknown
  # <<< 552 address... Mailbox Full
  # <<< 552 address Mailbox Full
  # 550 address... User unknown
  # <address>... User Unknown

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
	$line =~ /^\d{3}\s*([^\s]*)\.{3}\s*(.*)$/i    ||
	$line =~ /^<(.*)>[\s\.]+(.*)$/i
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

We keep the previous lines around (dumping them when we see a blank) and
when we hit the appropriate line we know to save away the diagnostics and
pull out addresses until the next blank.

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
  my ($fh, $diag, $format3, $format5, $line, $ok, $pdiag, $type, $user);

  # Check the type of the first part; it should be plain text
  $type = $ent->parts(0)->mime_type;
  if ($type !~ m!text/plain!i) {
    return;
  }

  $fh = $ent->parts(0)->bodyhandle->open('r');
  $format5=0;
 LINE:
  while (1) {
    $pdiag .= ($pdiag?" ":'').$line if defined($line);
    $line = $fh->getline; last unless defined $line;
    chomp $line;

    if ($line =~ /^\s*$/) {
      $pdiag = '';
      next;
    }

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
      $line =~ s/^\s*reason:\s*//i;
      $diag = $line;
    }

    elsif ($line =~ /following recipients did not receive/i) {
#      warn "format 3";
      $diag = $pdiag;
      $diag =~ s/^\s*//;
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
      $diag =~ s/^\s*//;
      $format5 = 1;
    }
    # Parsing the rest of the diagnostic
    elsif ($format5 == 1) {
      if ($line =~ /^\s*$/) {
	$format5=2;
      }
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
      $ok = 'DSN + Netscape';
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

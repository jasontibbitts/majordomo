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

=head2 parser

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
  $ok or ($ok = parse_dsn     ($ent, $data, $hints));
  $ok or ($ok = parse_exim    ($ent, $data, $hints));
  $ok or ($ok = parse_yahoo   ($ent, $data, $hints));

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
      return 0;
    }

  # So we must have a DSN.  The second part has the info we want.
  $type = $ent->parts(1)->mime_type;
  if ($type !~ m!message/delivery-status!i) {
    # Weird, the second part is always supposed to be of this type.  But
    # nothing else is going to be able to parse this message, so just
    # assume that we couldn't find a bouncing address.
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
    while (1) {
      $line = $fh->getline;
      last REC unless defined $line;
      chomp $line;
      next REC if $line =~ /^\s*$/;
      $line =~ /([^:]+):\s*(.*)/;
      $status[$i] = {} unless $status[$i];
      $status[$i]->{lc($1)} = $2;
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

=head2 parse_exim

Attempts to parse the bounces issued by the Exim MTA.  These bounces come
from Mailer-Daemon and look like the following:

This message was created automatically by mail delivery software.

A message that you sent could not be delivered to one or more of its
recipients. The following address(es) failed:

  asdfasd@lists.math.uh.edu:
    unknown local-part "asdfasd" in domain "lists.math.uh.edu"
  hurl@lists.math.uh.edu:
    unknown local-part "hurl" in domain "lists.math.uh.edu"

------ This is a copy of the message, including all the headers. ------

followed by the entire message.

=cut

sub parse_exim {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my $hints= shift;
  my ($bh, $line, $ok, $user);

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
  while (1) {
    $line = $bh->getline;
    last unless defined $line;
    chomp $line;

    # Stop before we get into the bounced message
    return $ok if $line =~ /^-/;

    # Ignore lines that don't look like indented addresses followed by
    # colons
    next unless $line =~ /  (.+\@.+):\s*$/;

    # We have an address;
    $ok = 1;
    $user = $1;
    $data->{$user}{'status'} = 'failure';

    # The next line holds the diagnostic, indented a bit
    $line = $bh->getline;
    chomp $line; $line =~ s/^\s*//;
    $data->{$user}{'diag'} = $line;
  }

  # Should never get here.
  $ok;
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

This function returns no useful value.

=cut
sub check_dsn_diags {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my ($diag, $fh, $line, $ok, $type, $user);

  # Check the type of the first part; it should be plain text
  $type = $ent->parts(0)->mime_type;
  if ($type !~ m!text/plain!i) {
    return 0;
  }

  $fh = $ent->parts(0)->bodyhandle->open('r');
  while (1) {
    $line = $fh->getline;
    return unless defined $line;
    last if $line =~ /transcript of session follows/i;
  }

  # We try to find a line that looks like an SMTP response, since that will
  # proably have the most accurate error message.
  while (defined($line = $fh->getline)) {
    if ($line =~ /^\s*<<<\s*\d{3}\s*<(.*)>[\s\.]*(.*)\s*$/i ||
	$line =~ /^\s*\d{3}\s*<(.*)>[\s\.]*(.*)\s*$/i)
      {
	$user = $1; $diag = $2;
	if ($data->{$user} &&
	    (
	     $data->{$user}{'diag'} eq 'unknown' ||
	     $data->{$user}{'diag'} =~ /250/     ||
	     !defined($data->{$user}{'diag'})
	    )
	   )
	{
	  $data->{$user}{'diag'} = $diag;
	}
      }
  }
}

=head2 check_dsn_netscape

Does extra parsing for bounces that come from some versions of Netscape
Messaging Server (4.15, at least).  These look just like DSNs but don't
contain any per-user delivery status blocks.  The DSN parser will set a
hint for us when it finds one.

To parse it, we have to plow through the human-readable portion to find
users and diagnostics.  This looks like:

This Message was undeliverable due to the following reason:

One or more of the recipients of your message did not receive it
because they would have exceeded their mailbox size limit.  It
may be possible for you to successfully send your message again
at a later time; however, if it is large, it is recommended that
you first contact the recipients to confirm that the space will be
available for your message when you send it.

User quota exceeded: SMTP <xxxx@yyyy.net>

Please reply to <postmaster@yyyy.net>
if you feel this message to be in error.

We look for lines matching

(.*): [sl]mtp <(.*)>

The reason is $1 and the user is $2.

Note that only one set of bounces from one user at one site was used to
construct this parser, so it may be incorrect or not applicable in general.

=cut
sub check_dsn_netscape {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $data = shift;
  my $hints= shift;
  my ($fh, $line, $ok, $type);

  # Check the type of the first part; it should be plain text
  $type = $ent->parts(0)->mime_type;
  if ($type !~ m!text/plain!i) {
    return 0;
  }

  $fh = $ent->parts(0)->bodyhandle->open('r');
  while (defined($line = $fh->getline)) {
    next unless $line =~ /(.*): [sl]mtp <(.*)>$/i;
    $data->{$2}{'status'} = 'failure';
    $data->{$2}{'diag'}   = $1;
    $ok = 1;
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

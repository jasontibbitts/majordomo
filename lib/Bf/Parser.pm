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

  type - type of message this was identified to be ('bounce', 'warning',
         'unknown').
  address - address which is identified to be bouncing.
  msgno   - the message number of the bouncing message, if known
  info    - a descriptive message for the list owner.

Please note that this is just a skeleton hack to get some functionality
going.

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

  my ($data, $info, $msgno, $ok, $to, $type, $user);

  # Look for useful bits in the To: header (assuming we even have one)
  $to = $ent->head->get('To');
  $to ||= '';

  # Look at the left hand side.  We expect to see the list name, followed
  # by '-owner', followed by the MTA-dependent separator followed by some
  # stuff.
  ($info) = $to =~ /\Q$list\E-owner\Q$sep\E([^@]+)\@/;

  if (!defined($info)) {
    $type = '';
 #   $status = 'none';
  }

  # We know the message is special.  Look for:
  # M\d{1,5}
  # M\d{1,5}=user=host
  # various other special types which we don't use right now.

  elsif ($info =~ /M(\d{1,5})=([^=]+)=([^=]+)/i) {
    $type   = 'M';
    $msgno  = $1;
    $user   = "$3\@$2";
#    $status = 'bounce';
#    $mess   = "VERPing detected a bounce of message #$msgno from $user.\n";
  }
  elsif ($info =~ /M(\d{1,5})/i) {
    $type   = 'M';
    $msgno  = $1;
    $user   = undef;
#    $status = 'bounce';
#    $mess   = "Detected a bounce of message #$msgno.\n";
  }
  else {
    $type = '';
#    $status = 'unknown';
#    $mess   = "Detected a special return message but could not discern its type.\n";
  }

  # Now try to identify the type of bounce
  $data = {};
  $ok or ($ok = parse_dsn($ent, $data));
# $ok or ($ok = parse_exim($ent, $data));

  # So now we have a hash of users and actions plus one possibly determined
  # from a VERP.  If the user in the VERP is already in the hash, trust
  # what's in the hash since it was determined by actually picking apart
  # the bounce.  Otherwise we just assume it's a bounce.
#  if ($user && !$data{$user}) {
#    $data{$user} = $status;
#  }

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
  my (@status, $action, $diag, $fh, $i, $line, $to, $type, $user);

  # Check the Content-Type
  $type = $ent->head->get('content-type');

  # We can quit now if we don't have a type of multipart/report and a
  # subtype of delivery-status
  unless ($type =~ m!multipart/report!i &&
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
    $status[$i] = {};
    while (1) {
      $line = $fh->getline;
      last REC unless defined $line;
      chomp $line;
      next REC if $line =~ /^\s*$/;
      $line =~ /([^:]+):\s*(.*)/;
      $status[$i]->{lc($1)} = $2;
    }
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
    }
    else {
	$data->{$user}{'diag'} = "unknown";
    }
  }
  return 1;
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

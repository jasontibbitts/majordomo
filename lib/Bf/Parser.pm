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

=cut

sub parse {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $list = shift;
  my $sep  = shift;

  my (%data, $info, $mess, $msgno, $to, $status, $type, $user);

  # Look for useful bits in the To: header
  $to = $ent->head->get('To');

  # Look at the left hand side.  We expect to see the list name, followed
  # by '-owner', followed by the MTA-dependent separator followed by some
  # stuff.
  ($info) = $to =~ /\Q${list}\E-owner\Q${sep}\E([^@]+)\@/;

  return ('none') unless $info;

  # We know the message is special.  Look for:
  # M\d{1,5}
  # M\d{1,5}=user=host
  # various other special types which we don't use right now.
  if ($info =~ /M(\d{1,5})=([^=]+)=([^=]+)/) {
    $type   = 'M';
    $msgno  = $1;
    $user   = "$3\@$2";
    $status = 'bounce';
    $mess   = "Detected a bounce of message #$msgno from $user.\n";
  }
  elsif ($info =~ /M(\d{1,5})/) {
    $type   = 'M';
    $msgno  = $1;
    $user   = undef;
    $status = 'bounce';
    $mess   = "Detected a bounce of message #$msgno but could not determine the user.\n";
  }
  else {
    $status = 'unknown';
    $mess   = "Detected a special return message but could not discern its type.\n";
  }

  # Now try to identify the type of bounce
  # ($ok, %data) = parse_dsn($ent);

  return ($status, $user, $mess);
}

=head2 parse_dsn

Attempt to identify an RFC1894 DSN, as sent by Sendmail.

sub parse_dsn {
  my $ent = shift;
  my (@status, $fh, $i, $to, $type);

  # Check the Content-Type
  $type = $ent->mime_type;

  # We can quit now if we don't have a type of multipart/report and a 
  unless ($type =~ !multipart/report!i &&
	  $type =~ !report-type=delivery-status!i)
    {
      return 0;
    }

  # So we must have a DSN.  The second part has the info we want.
  $type = $ent->parts(1)->mime_type;
  if ($type !~ !message/delivery-status!i) {
    # Weird, the second part is always supposed to be of this type.
    # Well, who cares; perhaps we can get something out of it anyway.
  }

  # Pull apart the delivery-status part
  $fh = $ent->bodyhandle->open('r');
 REC:
  for ($i = 0; 1; $i++) {
    $status[$i] = {};
    while (defined($line = $fh->getline)) {
      chomp $line;
      next REC if $line =~ /^\s*$/;
      $line =~ /([^:]):\s*(.*)/;
      $status[$i]->{$1} = $2;
    }
  }

  use Data::Dumper; print Dumper $status;


  # Start pulling apart the second part.  There's lots of info here, but we
  # only want couple of things: Original-Recipient: lines if we can get
  # them, Final-Recipient: lines otherwise, and Action: fields.
  
  return 0;

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

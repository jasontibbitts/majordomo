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

use Bf::Sender;
sub parse {
  my $log  = new Log::In 50;
  my $ent  = shift;
  my $list = shift;
  my $sep  = shift;

  my ($info, $msgno, $to, $user);

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
    $msgno = $1;
    $user  = "$3\@$2";
    return ('bounce', $user,
	    "Detected a bounce of message #$msgno from $user.\n");
  }
  elsif ($info =~ /M(\d{1,5})/) {
    $msgno = $1;
    $user = undef;
    return ('bounce', '',
	    "Detected a bounce of message #$msgno but could not determine the user.\n");
  }
  else {
    return ('unknown', '',
	    "Detected a special return message but could not discern its type.\n");
  }
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

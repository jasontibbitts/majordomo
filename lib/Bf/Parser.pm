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

  a parsed entity containing the potential bounce message.

Returns:

  type - type of message this was identified to be ('bounce', 'warning',
         'unknown').
  address - address which is identified to be bouncing.
  message - a descriptive message for the list owner.

Please note that this is just a skeleton hack to get some functionality
going.

=cut

sub parse {
  my $log = new Log::In 50;
  my $ent = shift;

  return ('unknown');
#  return ('bounce', '', "Detected a bounce.\n");

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

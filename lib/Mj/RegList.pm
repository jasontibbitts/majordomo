=head1 NAME

Mj::RegList.pm - A list of registered users

=head1 DESCRIPTION

This contains the object which encapsulates the list of registered users
and information about them.

The registered user list tracks all addresses that the Majordomo server
knows about.  These are generally all users who are subscribed to any list
served by the system.  The database exists to track per-user information
that is not per-list information.  It also serves to speed up such queries
as 'what lists is this user subscribed to'.

The database is keyed on the canonical address, and the following
information is kept about a registered user (dates in normal time format,
seconds since epoch):

  Stripped address (the address to which mail should be sent)
  Complete address (including comments)
  Registration time
  Time of last change
  Password (encrypted)
  Preferred language
  Lists (\002 separated)
  Flags
  Bounce data
  Warnings data
  Data1 - Data5 (site-specific data)

Bounce data is a scratchpad for the bounce processor, used to decide when
an address is bouncing too much.  Since an address bounces, not a list
subscription, this is made a global value.

Warnings data is intended to be used to store messages to be sent to an
address when it next communicates.  The idea is to be able to tell prople
what happened while they were unreachable.  This may turn out to be
useless, or may never be implemented.

=head1 SYNOPSIS

blah

=cut

package Mj::RegList;
use Mj::SimpleDB;
use strict;
use vars qw(@ISA);

@ISA=qw(Mj::SimpleDB);

my @fields = (qw(stripaddr fulladdr changetime regtime password language
		 lists flags bounce warnings data01 data02 data03 data04
		 data05 data06 data07 data08 data09 data10 data11 data12
		 data13 data14 data15));

=head2 new(path)

This allocates the SubscriberList for a particular list by creating a
SimpleDB object with the fields we use.

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;

  my $path = shift;
  my $back = shift;

  new Mj::SimpleDB(filename => $path,
		   backend  => $back,
		   fields   => \@fields,
		   compare  => \&compare,
		  );
}

sub compare {
  my ($k1, $k2) = @_;
  reverse($k1) cmp reverse($k2);
}

=head1 COPYRIGHT

Copyright (c) 1997, 1998 Jason Tibbitts for The Majordomo Development
Group.  All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the license detailed in the LICENSE file of the
Majordomo2 distribution.

his program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the Majordomo2 LICENSE file for more
detailed information.

=cut

1;
#
### Local Variables: ***
### mode:cperl ***
### cperl-indent-level:2 ***
### End: ***

=head1 NAME

Mj::SubscriberList.pm - A list of subscribers

=head1 DESCRIPTION

This contains the object which encapsulates the list of subscribers and
information about them.

A 'subscriber' is defined as an address, stripped of all comments and
validated for legality, which has undergone alias transformation to
canonical form.

The following information is kept about a subscriber (dates in normal time
format, seconds since epoch):

  The primary key is a canonical e-mail address.
  stripaddr  - Stripped address (the address to which mail should be sent)
  fulladdr   - Complete address (including comments)
  subtime    - Subscription time
  changetime - Time of last change
  class      - Delivery class (all, each, digest, nomail, unique)
  classarg   - Digest name or vacation return time
  classarg2  - Digest type or old class for timed vacations
  flags      - Settings (eliminatecc, replyto, etc.)
  groups     - Subtopic or subgroup memberships (unused except by the
               who-owners command)
  expire     - Subscription expiration time (unused)
  remind     - Expiration reminder flag (unused)
  id         - Unused
  bounce     - Information about delivery failures
  diagnostic - A description of the reason for the last delivery failure

See "help set" and "help who" for more information about delivery
classes, flags, and flag abbreviations.

You can add one or more subscribers to the SubscriberList, remove one or
more subscribers, iterate over the list of just the subscribers (like
scalar each) or iterate over the subscribers and their data (like each; you
get a string and a hashref; the hash has the data broken out for you),
determine membership quickly, change subscriber information, etc.

The actual data is stored in a Mj::SimpleDB object.  We inherit from that
object and just override the constructor to pass in the fields we use.

=head1 SYNOPSIS

blah

=cut

package Mj::SubscriberList;
use Mj::SimpleDB;
use strict;
use vars qw(@ISA);

@ISA=qw(Mj::SimpleDB);

my @fields = (qw(stripaddr fulladdr subtime changetime class classarg classarg2 flags groups expire remind id bounce diagnostic));

=head2 new(path)

This allocates the SubscriberList for a particular list by creating a
SimpleDB object with the fields we use.

=cut
sub new {
  my ($type, %args)  = @_;
  my $class = ref($type) || $type;

  new Mj::SimpleDB(
		   %args, 
		   fields   => \@fields,
		   compare  => \&compare,
		  );
}

sub compare {
  reverse($_[0]) cmp reverse($_[1]);
}

=head1 COPYRIGHT

Copyright (c) 1997, 1998, 2003 Jason Tibbitts for The Majordomo Development
Group.  All rights reserved.

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

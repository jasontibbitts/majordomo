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

  Stripped address (the address to which mail should be sent)
  Complete address (including comments)
  Subscription time
  Time of last change
  Class of article reception (single, digest(interval), on hold)
  Flags
  Bounce data (???)
  XXX More to come

Reception classes are (not chiseled in stone):
  each             - each message as it is posted
  digest-name-type - the named digest, received as the given type (test,
                     MIME, etc.)
  all              - user receives everything, digests, single messages,
                     etc. This is intended for list owners who might want
                     to see everything that does out.
  none        - the user doesn''t receive any mail at all.

Postpone status could be implemented here, too.  How?

Flags is a string of flags.  These could be made into normal fields, but
large numbers of fields incur a time penalty.  So stuffed here are bits of
info that the core might want to know about a subscriber but which will
never be the targets of a full search.  This includes:

  ack (A)            - the user receives notice that the message has
    been successfully delivered?
  selfcopy (S)       - the user receives a copy of their own message.
  CC elimination (C) - the user will _not_ receive a copy from the server
    if the user appears in the To: or CC headers.
  hideaddress (H)    - the user''s address will not appear in unapproved
    who requests.
  
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

my @fields = (qw(stripaddr fulladdr subtime changetime class classarg classarg2 flags));

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
		  );
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
### cperl-indent-level:2 ***
### End: ***

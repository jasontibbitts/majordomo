=head1 NAME

Mj::AddressList.pm - A list of addresses

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This encapsulates a simple list of addresses, stored with a comment.  This
is intended to be used for things like lists of allowed posters, or lists
of banned addresses.

One might think of ways to allow regular expressions in addition to
addresses, to match whole domains.  Not yet.

This simply inherits most of the work from SimpleDB.

=cut

package Mj::AddressList;
use Mj::SimpleDB;
use strict;
use vars qw(@ISA);

@ISA=qw(Mj::SimpleDB);

my @fields = qw(stripaddr comment changetime);

=head2 new(path)

This allocates an AddressList by making a SimpleDB object with the fields
we use.

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
  reverse($_[0]) cmp reverse($_[1]);
}

=head1 COPYRIGHT

Copyright (c) 1997, 1998 Jason Tibbitts for The Majordomo Development
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
### mode:cperl ***
### cperl-indent-level:2 ***
### End: ***

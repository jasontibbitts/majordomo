package Mj::FileSpaceDB;

=head1 NAME

Mj::FileSpaceDB.pm - A simple database for maintaining data about files

=head1 DESCRIPTION

This is a tiny module that implements a database holding metadata about
files under Majordomo''s control.

XXX Info about fields goes here/

=head1 SYNOPSIS

See Mj::SimpleDB.

=cut

use strict;
use Mj::SimpleDB;
use vars qw(@ISA);
@ISA=qw(Mj::SimpleDB);

my @fields = qw(description permissions c-type charset c-t-encoding changetime language);

=head2 new(path)

This allocates a FileSpaceDB by making a SimpleDB object with the fields we
use.

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;

  my $path = shift;
  my $back = shift;

  new Mj::SimpleDB $path, $back, \@fields;
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


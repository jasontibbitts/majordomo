=head1 NAME

Mj::SimpleDB::SQL - An attempt to make as much as possible generic using DBI

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This contains code to implement the abstract Majordomo database API that will 
allow for base usage of any database supported by DBI/DBD

=cut

package Mj::SimpleDB::SQL;
use DBI;
use Mj::Lock;
use Mj::Log;
use strict;
use vars qw(@ISA $VERSION $safe);

@ISA=qw(Mj::SimpleDB::Base);
$VERSION = 1;


1;

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

#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

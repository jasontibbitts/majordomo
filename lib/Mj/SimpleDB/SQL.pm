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
use vars qw(@ISA $VERSION);

@ISA=qw(Mj::SimpleDB::Base);
$VERSION = 1;

1;

=head1 DATABASE SCHEMA

All of these do also have these 3 fields :

domain	varchar(64) not null
list	varchar(64) not null
key	varchar(255) not null


table _parser :

    events	varchar(20)
    changetime	integer

table _register :

    stripaddr	varchar(130)
    fulladdr	varchar(255)
    changetime	integer
    regtime	integer
    password	varchar(64)
    language	varchar(5)
    lists	text
    flags	varchar(10)
    bounce	???
    warnings	???
    data01
    data02
    data03
    data04
    data05
    data06
    data07
    data08
    data09
    data10
    data11
    data12
    data13
    data14
    data15
    rewritefrom	???

table _bounce :

    bounce	integer
    diagnostic	varchar(255)

table _dup_id/dup/partial :

    lists	text
    changetime	integer

table _posts :

    dummy	???
    postdata	text
    changetime	integer

table _tokens/latchkeys :

    type	varchar(10)
    list	varchar(64)
    command		
    user		
    victim
    mode
    cmdline
    approvals
    chain1
    chain2
    chain3
    approver
    arg1
    arg2
    arg3
    time
    changetime
    sessionid
    reminded
    permanent
    expire
    remind
    reasons

table _subscribers/X"sublist" :

    stripaddr	varchar(130)
    fulladdr	varchar(255)
    subtime	integer
    changetime	integer
    class	varchar(64) -- Maybe more
    classarg	
    classarg2
    flags	varchar(20)
    groups
    expire
    remind
    id
    bounce
    diagnostic	varchar(255)

table archives, nope, always text

table _aliases

    target	varchar(255)
    stripsource	varchar(130)
    striptarget	varchar(130)
    changetime	integer


=head1 COPYRIGHT

Copyright (c) 1997, 1998, 2002 Jason Tibbitts for The Majordomo Development
Group.  All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the license detailed in the LICENSE file of the
Majordomo2 distribution.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the Majordomo2 LICENSE file for more
detailed information.

=cut

#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

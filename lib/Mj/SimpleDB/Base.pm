=head1 NAME

Mj::SimpleDB::Base - Useful database routines

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This module contains some routines common to many of the SimpleDB backends.
These include routines to import and export a database to and from a
filehandle.

=cut

package Mj::SimpleDB::Base;
use IO::File;
use Mj::File;
use Mj::FileRepl;
use Mj::Log;
use strict;
#use vars qw(@ISA);


=head2 export

=head2 import

=head2 lookup(key, fileh)

This checks to see if a stripped key is a member of the list, and
returns a reference to a hash containing the subscriber data if so.  If the
optional second parameter is given, it is taken as an already open
filehandle to use.

=cut
sub lookup {
  my $self = shift;
  my $key  = shift;
  my $fh   = shift;
  my $log = new Log::In 500, "$key";

  my $ex = $self->lookup_quick($key, $fh);
  return $self->_unstringify($ex) if defined $ex;
  return;
}

sub lookup_regexp {
  my $self = shift;
  my $key  = shift;
  my $fh   = shift;

  my ($match, $ex) = $self->lookup_quick_regexp($key, $fh);

  return ($match, $self->_unstringify($ex)) if defined $match;
  return;
}

=head2 _stringify(hashref), _unstringify(string) PRIVATE

These convert between a ref to a hash containing subscriber data and a
string.  This string is composed of the legal fields separated by tabs.
These routines are responsible for deciding the actual data representation;
change them with care.

The given hashref is modified.

These routines should be as fast as possible.

If an optional second paramater is passed to _stringify, the changetime
will not be updated.

=cut
sub _stringify {
  my $self     = shift;
  my $argref   = shift;
  my $nochange = shift;

  my ($i, $string);

  # Supply defaults
  $argref->{'changetime'} = time unless $nochange;

  $string = "";

  # Could this be done with map?
  for $i (@{$self->{'fields'}}) {
    $string .= defined($argref->{$i}) ? $argref->{$i} : '';
    $string .= "\t";
  }
  
  $string =~ s/\t$//;
  $string;
}

sub _unstringify {
  my $self = shift;
  my @args = split("\t", shift);
  my $hashref = {};

  for my $i (@{$self->{'fields'}}) {
    $hashref->{$i} = shift(@args);
  }
  $hashref;
}

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
### mode:cperl ***
### cperl-indent-level:2 ***
### End: ***

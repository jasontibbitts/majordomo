
=head1 NAME

Mj::SimpleDB::MySql - A wrapper around a Mysql database

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This contains code to implement the abstract Majordomo database API using a
MySql database.  The DBI module is used

=cut


package Mj::SimpleDB::MySql;
use Mj::SimpleDB::SQL;
use Mj::Lock;
use Mj::Log;
use DBI;
use strict;
use vars qw(@ISA $VERSION $safe $dbh $tables);

@ISA=qw(Mj::SimpleDB::SQL);
$VERSION = 1;

=head2 new(path, lockpath, field_list_ref)

This allocates the MySQL database with a particular name.  

=cut

sub new {
  my $type  = shift;
  my %args  = @_,
  my $class = ref($type) || $type;
  my $self  = {};
  my $log   = new Log::In 200, "$args{filename}";

  $self = $class->SUPER::new(@_);
  return unless $self;
  
  $self->{backend}  = 'MySQL';

  bless $self, $class;
  $self;
}

sub _make_db {
  my $self = shift;
  my $log   = new Log::In 200, "$self->{filename}";

  unless (defined $dbh) {
    $dbh = DBI->connect("DBI:mysql:majordomo", "majordomo", "majordomo", {PrintError => 0, RaiseError => 0, AutoCommit => 0} );
    warn "Problem allocating database" unless $dbh;
  }

  unless (defined($tables->{$self->{table}})) {
    my @tables = map { $_ =~ s/.*\.//; $_ } $dbh->tables(); 
    foreach my $table(@tables) {
      last if ($table =~ /^$self->{table}$/ && ($tables->{$self->{table}} = 1));
    }
    unless ($tables->{$self->{table}}) {
      my ($query, @prim_key);
      $query = "CREATE TABLE $self->{table} (";
      for my $f ($self->SUPER::_make_db()) {
	$query .= " $f->{NAME} $f->{TYPE}" .($f->{PRIM_KEY}?" NOT NULL":"") . ", ";
	push (@prim_key, $f->{NAME}) if $f->{PRIM_KEY};
      }
      $query .= "primary key (" . join(", ", @prim_key) . "))";
      $log->message(205, 'info', $query);
      my $ok = $dbh->do($query);
      my $error = $dbh->errstr;
      $dbh->commit();
      warn "Unable to create table $self->{table} $error" unless (defined $ok);
    }
  }
  $dbh;
}

1;

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

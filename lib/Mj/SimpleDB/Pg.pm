=head1 NAME

Mj::SimpleDB::Pg - A wrapper around a DBD::Pg database

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This contains code to implement the abstract Majordomo database API using a
PostgreSQL database.  The DBI module is used

=cut

package Mj::SimpleDB::Pg;
use Mj::SimpleDB::SQL;
use Mj::Log;
use DBI;
use strict;
use vars qw(@ISA $VERSION $safe $dbh $tables);

@ISA=qw(Mj::SimpleDB::SQL);
$VERSION = 1;

=head2 new(path, lockpath, field_list_ref)

This allocates the a PostgreSQL database with a particular name.

=cut

sub new {
  my $type  = shift;
  my %args  = @_,
  my $class = ref($type) || $type;
  my $self  = {};
  my $log   = new Log::In 200, "$args{filename}";

  $self = $class->SUPER::new(@_);
  return unless $self;
  
  $self->{backend}  = 'Pg';

  bless $self, $class;
  $self;
}

=head2 _make_db()

connect to the backend if it's not already done, and check that the
table we'll be trying to use exists.

=cut

sub _make_db {
  my $self = shift;
  my $log   = new Log::In 200, "$self->{filename}";

  unless (defined $dbh) {
    $dbh = DBI->connect("dbi:Pg:dbname=$self->{backend_opts}{name};host=$self->{backend_opts}{srvr};port=$self->{backend_opts}{port}",
			$self->{backend_opts}{user},
		       	$self->{backend_opts}{pass},
		       	{PrintError => 0, RaiseError => 0, AutoCommit => 0});
    unless ($dbh) {
      warn "Problem allocating database";
      $log->out('db creation failed');
      return;
    }
  }

  unless (defined($tables->{$self->{table}})) {
    $tables->{$self->{table}} = $dbh->func($self->{table}, 'table_attributes') ;

    unless (scalar @{$tables->{$self->{table}}}) {
      my ($query, @prim_key);
      $query = "CREATE TABLE \"$self->{table}\" (";
      for my $f ($self->SUPER::_make_db()) {
	$query .= " ".$self->_escape_field($f->{NAME})." $f->{TYPE}, ";
	push (@prim_key, $f->{NAME}) if $f->{PRIM_KEY};
      }
      $query .= "primary key (" . join(", ", $self->_escape_field(@prim_key)) . "))";
      $log->message(205, 'info', $query);
      my $ok = $dbh->do($query);
      my $error = $dbh->errstr;
      $dbh->commit();
      unless (defined $ok) {
	warn "Unable to create table $self->{table} $error";
	$log->out("table not created");
      }
    }
  }

  $dbh;
}

=head2 _escape_field(field names)

Some field name may be PgSQL reserved words, so quote them

=cut
sub _escape_field {
    my $self = shift;
    if (wantarray) {
	return map { "\"$_\""} @_;
    } else {
	return "\"$_[0]\""
    }
}

1 ;

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

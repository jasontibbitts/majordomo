
=head1 NAME

Mj::SimpleDB::MySql - A wrapper around a Mysql database

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This contains code to implement the abstract Majordomo database API using a
MySql database.  The DBI module is used

=cut


package Mj::SimpleDB::MySql;
use Mj::SimpleDB::Base;
use DBI;

use Mj::Lock;
use Mj::Log;

use strict;
use vars qw(@ISA $VERSION $safe);

@ISA=qw(Mj::SimpleDB::Base);
$VERSION = 1;

=head2 new(path, lockpath, field_list_ref)

This allocates the a BerkeleyDB with a particular name.  The database will
be created if it does not exist.  Note that if a sorter is specified, a
Btree database will be allocated, otherwise a somple Hash will be
allocated.
  
=cut

sub new {
  my $type  = shift;
  my %args  = @_;
  my $class = ref($type) || $type;
  my (%db, $db);
  my $self = {};
  bless $self, $class;

  $self->{backend}  = 'MySql';
  $self->{filename} = $args{filename};
  $self->{lockfile} = $args{lockfile} || $self->{filename};
  $self->{fields}   = $args{fields};

#?? $self->{key} = $self{fields}[0];
 #??  $self->{compare}  = $args{compare};

  my $log  = new Log::In 200, "$self->{filename}, $self->{lockfile}";
  # do I need a dbtype? can it be empty???
  # do I need a compare ?                                                                                                                                                                                             
  $self;


}



sub _stringify {
  my $self     = shift;
  my $argref   = shift;
  my $nochange = shift;
 
  my ($i, $string, $tmp);
 
  # Supply defaults
  $argref->{'changetime'} = time unless $nochange;
 
  $string = "";
 
  # Could this be done with map?
  for $i (@{$self->{'fields'}}) {
    $tmp = defined($argref->{$i}) ? $argref->{$i} : '';
    $tmp =~ s/[\001\r\n]/ /g;
    $string .= "$tmp\001";
  }
 
  $string =~ s/\001$//;
  $string;
}




sub _make_db {

  my $self = shift;
  my (%db, $db);

  #my $string = _stringify();
  
  #my $dbh = DBI->connect( $data_source, $username, $password); 
  my $dbh = DBI->connect("DBI:mysql:majordomo", "majordomo", "testing" );       
  my $tableExists = 0;
  my @tables = $dbh->func('_ListTables'); 
  foreach my $table(@tables) { 
    if  ($table =~ /majordomo/)
    {
        $tableExists = 1;}
    } 
 
 
  if ($tableExists == 0)  
  { 
#  	my $columnDef = get_fields(); 
 # 	my $sth = $dbh->prepare("Create table $self->{filename} (test varchar(20))");
  	#my $sth = $dbh->prepare("Create table majordomo (test varchar(20))");
  	my $sth = $dbh->prepare("Create table majordomo ($self->{fields} varchar(20))");  
        $sth->execute or die "Can't connect to  $self->{fields}  $dbh->errstr\n";
  	$sth->finish;
  }
  
  $db = $dbh;
  warn "Problem allocating database"  unless $db;
  $db;
}

=head2 DESTROY

This cleans up when the time comes to get rid of the database.  This undefs
all stored data and deletes the database file in the event that it has zero
size.

=cut

sub DESTROY {
  my $self = shift;
  my $log  = new Log::In 200, $self->{filename};
  
  #Problem: there is no self db
  ##$dbh = $self->{db };


  #my $database = "TestMajordomo";
  #my $data_source = "DBI:mysql:"; #$database;"
  #my $username = "rneuberger";
  #my $password = "meir";
  #my $dbh = DBI->connect( $data_source, $username, $password);


  
  #my $sth = $dbh->prepare("Drop table $self->{filename}");
  #$sth->execute or die "Unable execute query:$dbh->err, $dbh->errstr\n";
  #$sth->finish;
 # $dbh->disconnect; 
}

=head2 add(mode, key, datahashref)

This adds a row to the database.

This returns a list:

  flag - truth on success
  data - if failure, a ref to the data that already exists for the key (if any)

Note that if mode =~ force, existing data will be overwritten and _not
returned_.

=cut
sub add {
  my $self   = shift;
  my $mode   = shift || "";
  my $key    = shift;
  my $argref = shift;
  my $log    = new Log::In 120, "$self->{filename}, $mode, $key";
  my ($data, $db, $done, $flags, $status);

  # Grab a lock up front; this elminiates the race between creation and
  # opening.
  my $lock = new Mj::Lock($self->{lockfile}, 'Exclusive'); 
 
  $db = $self->_make_db;
  return 0 unless $db;

 #$flags = 0;  $flags = R_NOOVERWRITE unless $mode =~ /force/;                                                                                                          #$status = $db->put($key, $self->_stringify($argref), $flags);
 
  $data = $self->_lookup($db, $key);
  
  my $retflag;
  my $insertstring;
  $insertstring = $self->_stringify($argref);  
  if ($data == 0)
  { 
  	if ($retflag == insert($insertstring) ) {$done = 1;}
  }
  elsif ($data) 
  {
  	if ($mode !=~ /force/)
  		{$done = 0;} 
  	else
  	{
  		$retflag = deleteR($key);
  		if ($retflag = insert($data, $key)) {$done = 1;}
  		else {$data = 0; }# don't return for data
  	}  
  }
  # Else it just bombed
  else {
    $done = 0;
  }

  ($done, $data);
}

=head2 remove(mode, key)

This removes one or more rows from the database.  The mode parameter
controls how this operates.  By default the first matching entry is
removed; if mode=~/allmatching/, all matching entries are removed.  If
mode=~/regex/, the key is taken as a regular expression.

This returns a list of (keys, data) pairs that were removed.

=cut
sub remove {
  my $self = shift;
  my $mode = shift;
  my $key  = shift;
  my $log  = new Log::In 120, "$self->{filename}, $mode, $key";

  my (@nuke, @out, $data, $db, $fh, $match, $status, $try, $value, @deletions);
  
  $db = $self->_make_db;
  return unless $db;

  my $lock = new Mj::Lock($self->{lockfile}, 'Exclusive');

  # First, take care of the simple case.  Note that we don't allow
  # duplicates, but if we did there would be a problem with the del method
  # automatically removing all keys present.
  
  if ($mode !~ /regex/) 
  {
  	# Perhaps the key exists; look it up
    	$data = $self->_lookup($db, $key);
    	# If we got something, delete and return it.
    	if ($data) 
    	{      
      		#$status = $db->del($key);
    		deleteR($key);
    		return ($key, $data);
    	}
    	return;
  }

  # So we're doing regex processing, which means we have to search.
  # SimpleDB::Text can make use of lookup and lookup_regexp but we can't
  # rely on the stability of the cursor across a delete.
  
  my $limit;
  if ($mode !~ /allmatching/) {$limit = "limit 1"};
 
  delete_regexp($key, $limit);
  
  #had some error checking that I deleted
  return;
}



=head2 delete_regexp(db,key,limit)
Does a Mysql delete regexp

=cut
sub delete_regexp {
  my($self, $db, $key) = @_;
  my($status, $value, $data);
  
  my $dbh = $db;
  my $limit = 1;
  
  my $keyFieldName = 'remains to be done';
  my $sth = $dbh->prepare("DELETE FROM $self->{filename}  where $keyFieldName REGEXP $key $limit");
  $sth->execute or die "Unable execute query:$dbh->err, $dbh->errstr\n";
  $sth->finish;
   # should return if succesful
  return 0; 
}


=head2 deleteR (db,key)
Does a Mysql delete

=cut
sub deleteR{
  my($self, $db, $key) = @_;
  my($status, $value, $data);
  
  my $dbh = $db;
  my $limit = 1;
  
  my $keyFieldName = 'remains to be done';
  my $sth = $dbh->prepare("DELETE FROM $self->{filename}  where $keyFieldName = $key ");
  $sth->execute or die "Unable execute query:$dbh->err, $dbh->errstr\n";
  $sth->finish;
   # should return if succesful
  return 0; 
}



=head2 lookup_quick(key, fileh)
 
This checks to see if a key is a member of the list.  It
returns only truth on success and not any of the data.
 
=cut
 
sub lookup_quick {
  my $self = shift;
  my $key  = shift;
  unless ($key) {
    $::log->complain("SimpleDB::lookup_quick called with null key.");
  }
  my $lock = new Mj::Lock($self->{lockfile}, 'Shared');
  my $value = 0;
  my $db = $self->_make_db;
  return unless $db;
 
  my $status = $db->get($key, $value);
  if ($status != 0) {
    return;
  }
  $value;
}




=head2 put(db,insertstring)
Does a Mysql insert

=cut
sub put {
  my($self, $db, $key,$insertstring) = @_;
  my($status, $value, $data);
  
  my $dbh = $db;
  my $table = 1;
  
  my $sth = $dbh->prepare("INSERT INTO $self->{filename}  values $insertstring");
  $sth->execute or die "Unable execute query:$dbh->err, $dbh->errstr\n";
  $sth->finish;
  
  
   # should return if succesful
  return 0; 
}

=head2 lookup(db, key)

Does a Mysql select

=cut
sub _lookup {
  my($self, $db, $key) = @_;
  my($status, $value, $data);
  
  my $dbh = $db;
  my $sth = $dbh->prepare("SELECT * FROM $self->{filename} where KEY = $key");
  $sth->execute or die "Unable execute query:$dbh->err, $dbh->errstr\n";
  $data = $sth->fetchrow_array;
  $data = $self->_unstringify($value);
  
  return $data;
}
=head2 _lookup_regexp(db, key)

Does a Mysql select

=cut
sub lookup_regexp {
  my($self, $db, $key) = @_;
  my($status, $value, $data);
  
  my $dbh = $db;
  my $sth = $dbh->prepare("SELECT * FROM $self->{filename} where KEY REGEXP $key");
  $sth->execute or die "Unable execute query:$dbh->err, $dbh->errstr\n";
  
  my @data = $sth->fetchrow_array;
  foreach $data(@data)
  	{$data = $self->_unstringify($value);}
  $sth->finish;  
  @data;
}



=get_fields()

Does a Mysql select

=cut
 
sub get_fields
{

  my($self) = @_;
  my($i, $fields, @fields, $columnDef);

  @fields = $self->{fields}; 
  foreach my $field (@fields)
  {
 	if ($i == 0)
 	{
        	$columnDef = "(" . $field . " STRING(30) NULLPRIMARY KEY";
 	}
 	else
 	{
        	$columnDef .= ",";
    		$columnDef .= $field;
    		$columnDef .= " STRING(30) NULL";
 	}
 	$i++;
  }
  $columnDef .= ")";
  $columnDef;
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
### cperl-indent-level:2 ***
### End: ***

=head1 NAME

Mj::SimpleDB::SQL - An attempt to make as much as possible generic using DBI

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This contains code to implement the abstract Majordomo database API that will 
allow for base usage of any database supported by DBI/DBD

=cut

package Mj::SimpleDB::SQL;
use Mj::SimpleDB::Base;
use DBI;
use Mj::Lock;
use Mj::Log;
use strict;
use vars qw(@ISA $VERSION);

@ISA=qw(Mj::SimpleDB::Base);
$VERSION = 1;

=head2 new(path, lockpath, field_list_ref)

This allocates the a SQL DB with a particular name.

=cut

sub new {
  my $type  = shift;
  my %args  = @_;
  my $class = ref($type) || $type;
  my $self  = {};
  my $log   = new Log::In 200, "$args{filename}";

  $self->{backend}  = undef;
  $self->{fields}   = $args{fields};

  # We parse what we need from the filename XXX
  # work for the DBs in the list dir, but not for the ones in the files/ directory
  if ($args{filename} =~ m/\/([^\/]+)\/([^\/]+)\/([^\/]+)$/) {
    $self->{domain} = $1;
    $self->{list} = $2;
    $self->{file} = $3;
    $self->{filename} = "$self->{domain}, $self->{list}, $self->{file}";
  } else {
    warn "Problem parsing filename $self->{filename}";
  }


  bless $self, $class;
  $self;
}

=head2 _make_db

This will return the schema for the table so that the backend can
issue the proper "CREATE TABLE" statements.

=cut

sub _make_db {
  my $self = shift;
  my $log   = new Log::In 200, "$self->{filename}";

  return $self->{file};
}

=head2 put(db, key, argref, flag)

Try to insert a new key into the database. If the entry already exist
and flag = 0, then, an update is issued.

returns 0 on success, 1 when the value could not be inserted, and -1
if it could not be updated.

=cut

sub put {
  my $self = shift;
  my $db   = shift;
  my $key  = shift;
  my $argref = shift;
  my $flag = shift || 0;
  my $log    = new Log::In 200, "$self->{filename}, $key, $argref, $flag";

  my $exist = $db->do("SELECT cle FROM $self->{file} WHERE domain = ? AND list = ? AND cle = ? FOR UPDATE",
		      undef,
		      $self->{domain}, $self->{list}, $key);

  if ($exist == 0) {
    my $r = $db->do("INSERT INTO $self->{file} (domain, list, cle, ".
		     join(",", @{$self->{fields}}).
		     ") VALUES (?, ?, ?, ".
		     join(", ", map { "?" } @{$self->{fields}}).
		     ")", undef, $self->{domain}, $self->{list}, $key, 
		    @{%$argref}{@{$self->{fields}}});

    return (defined($r) ? 0 : 1);
  } elsif ($exist and $flag == 0) {
    my $r = $db->do("UPDATE $self->{file} SET ".
		     join(", ", map { "$_ = ? " } @{$self->{fields}}).
		     " WHERE domain = ? AND list = ? AND cle = ?", undef,
		    @{%$argref}{@{$self->{fields}}}, $self->{domain}, $self->{list}, $key);
		  
    return (defined($r) ? 0 : -1);
  }
  return 1;
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

  $db = $self->_make_db;
  return 0 unless $db;

  $db->begin_work();
  
  $flags = 0; $flags = 1 unless $mode =~ /force/;
  $status = $self->put($db, $key, $self->_stringify($argref), $flags);

  # If success...
  if ($status == 0) {
    $done = 1;
    $db->commit();
  }
  # If the key existed and flag = 1 was given...
  elsif ($status > 0) {
    $data = $self->_lookup($db, $key);
    $done = 0;
    $db->rollback();
  }
  # Else it just bombed
  else {
    $done = 0;
    $db->rollback();
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
use Mj::Util qw(re_match);
sub remove {
  my $self = shift;
  my $mode = shift;
  my $key  = shift;
  my $log  = new Log::In 120, "$self->{filename}, $mode, $key";

  my (@out, $data, $db, $fh, $match, $status, $try, @deletions, $sth);

  $db = $self->_make_db;
  return unless $db;

  # First, take care of the simple case.  Note that we don't allow
  # duplicates, but if we did there would be a problem with the del method
  # automatically removing all keys present.
  if ($mode !~ /regex/) {
    # Perhaps the key exists; look it up
    $db->begin_work();
    $data = $self->_lookup($db, $key);

    # If we got something, delete, commit the transaction and return the old value.
    if ($data) {
      $sth = $db->prepare_cached("DELETE FROM $self->{file} WHERE domain = ? AND list = ? AND cle = ?");
      $status = $sth->execute($self->{domain}, $self->{list}, $key);
      $sth->finish();
      $db->commit();
      return ($key, $data);
    }
    # if we did not, just rollback the transaction, as it was useless...
    $db->rollback();
    return;
  }

  # So we're doing regex processing, which means we have to search.
  # SimpleDB::Text can make use of lookup and lookup_regexp but we cannot*
  # just delete one entry with sql.
  
  $db->begin_work();

  $sth = $db->prepare_cached("SELECT cle, ".
			      join(",", @{$self->{fields}}).
			      " FROM $self->{file} WHERE domain = ? AND list = ? FOR UPDATE");

  $sth->execute($self->{domain}, $self->{list});
  
  for ($data = $sth->fetchrow_hashref;
       defined($data);
       $data = $sth->fetchrow_hashref) {
    $try = delete $data->{cle};
    if (re_match($key, $try)) {
      push @deletions, $try;
      push @out, ($try, $data);
      last if $mode !~ /allmatching/;
    }
  }

  $sth->finish();

  $sth = $db->prepare_cached("DELETE FROM $self->{file} WHERE domain = ? AND list = ? AND cle = ?");
  
  for $try (@deletions) {
    $sth->execute($self->{domain}, $self->{list}, $try)
  }
  
  $sth->finish();

  # if there were some row found, commit the transaction and return the old values
  if (@out) {
    $db->commit();
    return @out;
  }

  # if we did not, just rollback the transaction, as it was useless...
  $db->rollback();
  
  $log->out("failed");
  return;
}

=head2 replace(mode, key, field, value)

This replaces the value of a field in one or more rows with a different
value.  The mode parameter controls how this operates.  If mode=~/regex/,
key is taken as a regular expression, otherwise it is taken as the key to
modify.  If mode=~/allmatching/, all matching rows are modified, else only
$db, the first is.

If field is a hash reference, it is used as the hash of data and values.
If field is a code reference, it is executed (with the data hash available
as the only argument) and the resulting hash is written back as the data.
Unlike the mogrify function, this cannot change the key.

Returns a list of keys that were modified.

=cut
sub replace {
  my $self  = shift;
  my $mode  = shift;
  my $key   = shift;
  my $field = shift;
  my $value = shift;
  my (@out, $i, $k, $match, $data, $v, @changes, $sth);
  my $log = new Log::In 120, "$self->{filename}, $mode, $key, $field, ".defined($value)? $value :"<undef>";
  my $db  = $self->_make_db;
  return unless $db;

  # Take care of the easy case first.  Note that we don't allow duplicates, so there's no need to loop nere.
  if ($mode !~ /regex/) {
    $db->begin_work();
    $data = $self->_lookup($db, $key);
    return unless $data;
    # Update the value, and the record.
    if (ref($field) eq 'HASH') {
      $data = $field;
    }
    elsif (ref($field) eq 'CODE') {
      $data = &$field($data);
    }
    else {
      $data->{$field} = $value;
    }
    $self->put($db, $key, $self->_stringify($data));
    $db->commit();
    return ($key);
  }

  $db->begin_work();

  # So we're doing regex processing, which means we have to search.
  $sth = $db->prepare_cached("SELECT cle, ".
			      join(",", @{$self->{fields}}).
			      " FROM $self->{file} WHERE domain = ? AND list = ? FOR UPDATE");

  $sth->execute($self->{domain}, $self->{list});
  
  for ($data = $sth->fetchrow_hashref;
       defined($data);
       $data = $sth->fetchrow_hashref) {
    $k = delete $data->{cle};
    if (re_match($key, $k)) {
      if (ref($field) eq 'HASH') {
	$data = $field;
      }
      elsif (ref($field) eq 'CODE') {
	$data = &$field($data);
      }
      else {
	$data->{$field} = $value;
      }

      # For some DB implementations, changing the data affects the
      # cursor.  Work around this by saving keys and values.
      # An ordinary array is used because DB key/value pairs are
      # not necessarily unique.
      push @changes, $k, $self->_stringify($data);
      push @out, $k;
      last if $mode !~ /allmatching/;
    }
  }

  $sth->finish();
  
  while (($k, $v) = splice(@changes, 0, 2)) {
    $self->put($db, $k, $v);
  }

  if (@out) {
    $db->commit();
    return @out;
  }

  $db->rollback();

  $log->out("failed");
  return;
}

=head2 mogrify(coderef)

This is a more powerful, completely general database modification routine.
It iterates over the keys, extracts that data hash, and calls a coderef.
The coderef should take the following values:

 key  - the key
 data - a reference to the data hash

The coderef should return the following values:

 flag1 - true if the key is to be changed
 flag2 - true if the data is to be changed
       - negative if changeime should not be updated
 key   - the new key (undef to delete record)

The coderef can modify the elements of the data hash; if flag2 the modified
values will be used.

=cut
sub mogrify {
  my $self = shift;
  my $code = shift;
  my $log  = new Log::In 120, "$self->{filename}";
  my (@new, $changed, $changedata, $changekey, $data, $encoded, $k,
      $newkey, $v, @deletions, $sth);
  my $db = $self->_make_db;
  return unless $db;
  $changed = 0;

  $db->begin_work();

  $sth = $db->prepare_cached("SELECT cle, ".
			      join(",", @{$self->{fields}}).
			      " FROM $self->{file} WHERE domain = ? AND list = ?");

  $sth->execute($self->{domain}, $self->{list});
  
 RECORD:
  for ($data = $sth->fetchrow_hashref;
       defined($data);
       $data = $sth->fetchrow_hashref) {
    # Extract the data and call the coderef
    $k = delete $data->{cle};
    $v = $data;
    ($changekey, $changedata, $newkey) = &$code($k, $data);

    # If we have nothing to change, go on
    unless ($changekey || $changedata) {
      next RECORD;
    }

    # So we must change something
    $changed++;

    # Encode the data hash; if nothing changed, we don't have to
    # reflatten it
    if ($changedata) {
      $encoded = $self->_stringify($data, ($changedata < 0));
    }
    else {
      $encoded = $v;
    }

    # If the key must change, the old value must be deleted and the new
    # one saved for later addition in order to prevent a possible loop,
    # since if we add a key now we may come upon it later.  Otherwise we
    # can just the new data onto the same key.  If the new key is
    # undefined, we just delete the existing entry and save nothing for
    # later.
    if ($changekey) {
      if (defined $newkey) {
	push @new, $newkey, $encoded;
      }
      push @deletions, $k;
    }
    else {
      push @new, $k, $encoded; 
    }
  }

  $sth->finish();

  for $k (@deletions) {
    $db->do("DELETE FROM $self->{file} WHERE domain = ? AND list = ? AND cle = ?",
	    undef,
	    $self->{domain}, $self->{list}, $k);
  }
  while (($k, $v) = splice(@new, 0, 2)) {
    my $aa = $self->put($db, $k, $v);
  }
  $db->commit();
  $log->out("changed $changed");
}

=head2 get_start, get_done, _get

These are very simple.  Note that because the act of starting a sequence
also returns the first element, we have a tiny bit of complexity in _get.

=cut
{
  my $sth;
  my $db;

  sub get_start {
    my $self = shift;
    my $log   = new Log::In 201, "$self->{filename}";

    $sth->finish() if (defined($sth));

    $db = $self->_make_db;

    $sth = $db->prepare_cached("SELECT cle, ".
				join(",", @{$self->{fields}}).
				" FROM $self->{file} WHERE domain = ? AND list = ?");

    $sth->execute($self->{domain}, $self->{list});

    return unless $sth;
    1;
  }

  sub get_done {
    my $self = shift;
    my $log   = new Log::In 201, "$self->{filename}";

    $sth->finish();
    $db = undef;
    $sth = undef;
  }

  sub _get {
    my $self = shift;
    my($k, $v) = (0, 0);
    $v = $sth->fetchrow_hashref();
    $k = delete $v->{cle};
    return unless defined($k);
    ($k, $v);
  }
}

=head2 get_quick(count)

This gets a chunk of keys without their data from the list.  Will return no
more than count keys.  Will return an empty list at EOF.

=cut
sub get_quick {
  my $self  = shift;
  my $count = shift;
  my $log   = new Log::In 121, "$self->{filename}, $count";
  my (@keys, $key, $i);

 KEYS:
  for ($i=0; $i<$count; $i++) {
    ($key) = $self->_get;
    last KEYS unless $key;
    push @keys, $key;
  }
  return @keys;
}

=head2 get(count)

This gets a chunk of keys and data.  Will return no more than count
keys, or a list of no more than 2*count elements.  Will return an
empty list at EOF.

=cut
sub get {
  my $self  = shift;
  my $count = shift;
  my $log   = new Log::In 121, "$self->{filename}, $count";
  my (@keys, $i, $key, $val);

 KEYS:
  for ($i=0; $i<$count; $i++) {
    ($key, $val) = $self->_get;
    last KEYS unless $key;
    push @keys, ($key, $val);
  }
  return @keys;
}

=head2 get_matching_*(count, field, value) or (count, coderef)

These gets a chunk of keys satisfying some criteria.

This is tough.  How to specify the criteria?  List of field/value?  Just
one field/value?  Ugh.

We take either a field/value pair or coderef.  There are a couple of
interesting optimizations we can do with the field/value pair that get the
operation down close to one regexp match per line.  If a coderef is passed,
it will be called with the key and the extracted data hash for each
database entry.  It should return true or false, indicating whether or not
the field matched.  If it returns 'undef', the search will stop
immediately.  This is useful if you know the database is sorted or you only
want to find a small number of matches.

This returns a list of entries, or an empty list if no matching entries
before EOF.

XXX Coderef only implemented for get_matching;

=cut
sub get_matching_quick {
  my $self  = shift;
  my $log   = new Log::In 121, "$self->{filename}, @_";
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my (@keys, $i, $k, $v);

  for ($i=0; $i<$count; $i++) {
    ($k, $v) = $self->_get;
    last unless $k;

    if (defined($v->{$field}) && 
	$v->{$field} eq $value)
      {
	push @keys, $k;
	next;
      }
    redo;
  }
  return @keys;
}

sub get_matching_quick_regexp {
  my $self  = shift;
  my $log   = new Log::In 121, "$self->{filename}, @_";
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my (@keys, $i, $k, $v);

  for ($i=0; $i<$count; $i++) {
    ($k, $v) = $self->_get;
    last unless $k;

    if (defined($v->{$field}) && _re_match($value, $v->{$field})) {
      push @keys, $k;
      next;
    }
    redo;
  }
  return @keys;
}

sub get_matching {
  my $self  = shift;
  my $log   = new Log::In 121, "$self->{filename}, @_";
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my (@keys, $code, $i, $k, $tmp, $v);

  $code = 1 if ref($field) eq 'CODE';

  for ($i=0; ($count ? ($i<$count) : 1); $i++) {
    ($k, $v) = $self->_get;
    last unless $k;

    if ($code) {
      $tmp = &$field($k, $v);
      last unless defined $tmp;
      push @keys, ($k, $v) if $tmp;
    }
    elsif (defined($v->{$field}) &&
	$v->{$field} eq $value)
      {
	push @keys, ($k, $v);
	next;
      }
    redo;
  }
  return @keys;
}

sub get_matching_regexp {
  my $self  = shift;
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my $log   = new Log::In 121, "$self->{filename}, $count, $field, $value";
  my (@keys, $i, $k, $v);

  for ($i=0; $i<$count; $i++) {
    ($k, $v) = $self->_get;
    last unless $k;

    if (defined($v->{$field}) && _re_match($value, $v->{$field})) {
      push @keys, ($k, $v);
      next;
    }
    redo;
  }
  return @keys;
}

=head2 _lookup(key)

An internal lookup function that does no locking; essentially, it is
db->get with unstringification of the result.

=cut
sub _lookup {
  my($self, $db, $key) = @_;
  my $log   = new Log::In 201, "$self->{filename}, $key";
  my($status);

  my $sth = $db->prepare_cached("SELECT ".
				  join(",", @{$self->{fields}}).
				  " FROM $self->{file} WHERE domain = ? AND list = ? AND cle = ? FOR UPDATE");

  $status = $sth->execute($self->{domain}, $self->{list}, $key);

  if ($status) {
    $status = $sth->fetchrow_hashref();
    $sth->finish();
    return $status;
  } else {
    $sth->finish();
    return undef;
  }
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
  my $db = $self->_make_db;
  return unless $db;

  my $value = $self->_lookup($db, $key);
  return $value;
}

sub lookup_quick_regexp {
  my $self = shift;
  my $reg  = shift;
  my $db   = $self->_make_db;
  return unless $db;

  my ($key, $match, $status, $value);

  $key = $value = '';
  for ($status = $db->seq($key, $value, 1) ; # first
       $status == 0 ;
       $status = $db->seq($key, $value, 1) ) # next
    {
      if (_re_match($reg, $key)) {
	return ($key, $value);
      }
    }
  return;
}

sub _stringify {
  my $self     = shift;
  my $argref   = shift;
  my $nochange = shift;
  my $log   = new Log::In 201, "$self->{filename}, $argref, ".defined($nochange)?1:"";

  # Supply defaults
  $argref->{'changetime'} = time unless $nochange;

  $argref;
}

sub _unstringify {
  my $self = shift;
  my $string = shift;
  $string;
}


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

=cut 

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

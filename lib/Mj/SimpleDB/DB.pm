=head1 NAME

Mj::SimpleDB::DB - A wrapper around a BerkeleyDB database

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This contains code to implement the abstract Majordomo database API using a
Berkeley DB database.  The DB_File module is used, not the newer BerkeleyDB
module which is not yet stable.

Note that unlike SimpleDB::Text.pm, this module doesn''t delete empty
databases.  That opens up a very nasty set of race conditions.  Note also
that BTree databases never shrink.

=cut

package Mj::SimpleDB::DB;
use Mj::SimpleDB::Base;
use DB_File;
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

  $self->{backend}  = 'DB';
  $self->{filename} = $args{filename};
  $self->{lockfile} = $args{lockfile} || $self->{filename};
  $self->{fields}   = $args{fields};
  $self->{compare}  = $args{compare};

  my $log  = new Log::In 200, "$self->{filename}, $self->{lockfile}";

  # Now allocate the database bits.
  if ($self->{compare}) {
    $self->{dbtype} = new DB_File::BTREEINFO;
    $self->{dbtype}{compare} = $self->{compare};
  }
  else {
    $self->{dbtype} = new DB_File::HASHINFO;
  }

  $self;
}

sub _make_db {
  my $self = shift;
  my (%db, $db);

  # Now grab the DB object.  We don't care about the hash we're tying to,
  # because we're going to save the speed hit and use the API directly.
  $db = tie %db, 'DB_File', $self->{filename},
                         O_RDWR|O_CREAT, 0666, $self->{dbtype};
  warn "Problem allocating database: $self->{filename} - $!" unless $db;
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
  undef $self->{get_handle};
  undef $self->{get_lock};
  undef $self->{db};
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

  $flags = 0; $flags = R_NOOVERWRITE unless $mode =~ /force/;
  $status = $db->put($key, $self->_stringify($argref), $flags);

  # If success...
  if ($status == 0) {
    $done = 1;
  }
  # If the key existed and NOOVERWEITE was given...
  elsif ($status > 0) {
    $data = $self->_lookup($db, $key);
    $done = 0;
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
use Mj::Util qw(re_match);
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
  if ($mode !~ /regex|pattern/) {
    # Perhaps the key exists; look it up
    $data = $self->_lookup($db, $key);

    # If we got something, delete and return it.
    if ($data) {
      $status = $db->del($key);
      return ($key, $data);
    }
    return;
  }

  # So we're doing regex processing, which means we have to search.
  # SimpleDB::Text can make use of lookup and lookup_regexp but we can't
  # rely on the stability of the cursor across a delete.
  $try = $value = 0;
  for ($status = $db->seq($try, $value, R_FIRST);
       $status == 0;
       $status = $db->seq($try, $value, R_NEXT)
      )
    {
      if (re_match($key, $try)) {
        push @deletions, $try;
        push @out, ($try, $self->_unstringify($value));
        last if $mode !~ /allmatching/;
      }
    }
  
  for $try (@deletions) {
    $db->del($try);
  }

  if (@out) {
    return @out;
  }
  
  $log->out("failed");
  return;
}

=head2 replace(mode, key, field, value)

This replaces the value of a field in one or more rows with a different
value.  The mode parameter controls how this operates.  If mode=~/regex/,
key is taken as a regular expression, otherwise it is taken as the key to
modify.  If mode=~/allmatching/, all matching rows are modified, else only
the first is.

If field is a hash reference, it is used as the hash of data and values.
If field is a code reference, it is executed (with the data hash available
as the only argument) and the resulting hash is written back as the data.
Unlike the mogrify function, this cannot change the key.

Returns a list of keys that were modified.

=cut
use Mj::Util qw(re_match);
sub replace {
  my $self  = shift;
  my $mode  = shift;
  my $key   = shift;
  my $field = shift;
  my $value = shift;
  my (@out, $i, $k, $match, $data, $status, $v, @changes);
  $value = "" unless defined $value;
  my $log = new Log::In 120, "$self->{filename}, $mode, $key, $field, $value";
  my $db  = $self->_make_db;
  return unless $db;
  my $lock = new Mj::Lock($self->{lockfile}, 'Exclusive');

  # Take care of the easy case first.  Note that we don't allow duplicates, so there's no need to loop nere.
  if ($mode !~ /regex|pattern/) {
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
    $db->put($key, $self->_stringify($data));
    return ($key);
  }

  # So we're doing regex processing, which means we have to search.
  $k = $v = 0;
  for ($status = $db->seq($k, $v, R_FIRST);
       $status == 0;
       $status = $db->seq($k, $v, R_NEXT)
      )
    {
      if (re_match($key, $k)) {
	if (ref($field) eq 'HASH') {
	  $data = $field;
	}
	elsif (ref($field) eq 'CODE') {
	  $data = $self->_unstringify($v);
	  $data = &$field($data);
	}
	else {
	  $data = $self->_unstringify($v);
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
  for ($i = 0; defined($changes[$i]); $i+=2) {
    $db->del($changes[$i]);
  }
  while (($k, $v) = splice(@changes, 0, 2)) {
    $db->put($k, $v);
  }

  if (@out) {
    return @out;
  }

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
      $newkey, $status, $v, @deletions);
  my $db = $self->_make_db;
  return unless $db;
  my $lock = new Mj::Lock($self->{lockfile}, 'Exclusive');
  $changed = 0;
  
  $k = $v = 0;
 RECORD:
  for ($status = $db->seq($k, $v, R_FIRST);
       $status == 0;
       $status = $db->seq($k, $v, R_NEXT)
      ) 
    {
      # Extract the data and call the coderef
      $data = $self->_unstringify($v);
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
  for $k (@deletions) {
    $status = $db->del($k);
  }
  while (($k, $v) = splice(@new, 0, 2)) {
    $status = $db->put($k, $v);
  }
  $log->out("changed $changed");
}

=head2 get_start, get_done, _get

These are very simple.  Note that because the act of starting a sequence
also returns the first element, we have a tiny bit of complexity in _get.

=cut
sub get_start {
  my $self = shift;

  $self->{get_lock}  = new Mj::Lock($self->{lockfile}, 'Shared');
  $self->{get_going} = 0;
  $self->{db} = $self->_make_db;
  return unless $self->{db};
  1;
}

sub get_done {
  my $self = shift;
  $self->{db}        = undef;
  $self->{get_lock}  = undef;
  $self->{get_going} = 0;
}

sub _get {
  my $self = shift;
  my($k, $v, $stat) = (0, 0);
  if ($self->{get_going}) {
    $stat = $self->{db}->seq($k, $v, R_NEXT);
  }
  else {
    $stat = $self->{db}->seq($k, $v, R_FIRST);
    $self->{get_going} = 1;
  }
  return unless $stat == 0;
  ($k, $v);
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
    push @keys, ($key, $self->_unstringify($val));
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
use Mj::Util qw(re_match);
sub get_matching_quick {
  my $self  = shift;
  my $log   = new Log::In 121, "$self->{filename}, @_";
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my (@keys, $data, $i, $k, $v);

  for ($i=0; $i<$count; $i++) {
    ($k, $v) = $self->_get;
    last unless $k;

    # We may be able to skip the unstringification step
    redo unless re_match("/(\001|^)\Q$value\E/", $v);

    $data = $self->_unstringify($v);
    if (defined($data->{$field}) && 
	$data->{$field} eq $value)
      {
	push @keys, $k;
	next;
      }
    redo;
  }
  return @keys;
}

use Mj::Util qw(re_match);
sub get_matching_quick_regexp {
  my $self  = shift;
  my $log   = new Log::In 121, "$self->{filename}, @_";
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my (@keys, $data, $i, $k, $v);

  for ($i=0; $i<$count; $i++) {
    ($k, $v) = $self->_get;
    last unless $k;
#    redo unless re_match($value, $v);
    $data = $self->_unstringify($v);
    if (defined($data->{$field}) && re_match($value, $data->{$field})) {
      push @keys, $k;
      next;
    }
    redo;
  }
  return @keys;
}

use Mj::Util qw(re_match);
sub get_matching {
  my $self  = shift;
  my $log   = new Log::In 121, "$self->{filename}, @_";
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my (@keys, $code, $data, $i, $k, $tmp, $v);

  $code = 1 if ref($field) eq 'CODE';

  for ($i=0; ($count ? ($i<$count) : 1); $i++) {
    ($k, $v) = $self->_get;
    last unless $k;
    redo if (!$code && ! re_match("/(\001|^)\Q$value\E/", $v));
    $data = $self->_unstringify($v);
    if ($code) {
      $tmp = &$field($k, $data);
      last unless defined $tmp;
      push @keys, ($k, $data) if $tmp;
    }
    elsif (defined($data->{$field}) && 
	$data->{$field} eq $value)
      {
	push @keys, ($k, $data);
	next;
      }
    redo;
  }
  return @keys;
}

use Mj::Util qw(re_match);
sub get_matching_regexp {
  my $self  = shift;
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my $log   = new Log::In 121, "$self->{filename}, $count, $field, $value";
  my (@keys, $data, $i, $k, $v);

  for ($i=0; $i<$count; $i++) {
    ($k, $v) = $self->_get;
    last unless $k;
#    redo unless re_match($value, $v);
    $data = $self->_unstringify($v);
    if (defined($data->{$field}) && re_match($value, $data->{$field})) {
      push @keys, ($k, $data);
      next;
    }
    redo;
  }
  return @keys;
}

=head2 _lookup(db, key)

An internal lookup function that does no locking; essentially, it is
db->get with unstringification of the result.

=cut
sub _lookup {
  my($self, $db, $key) = @_;
  my($status, $value, $data);

  $status = $db->get($key, $value);
  if ($status == 0 && $value) {
    $data = $self->_unstringify($value);
  }
  $data;
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
    return;
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

use Mj::Util qw(re_match);
sub lookup_quick_regexp {
  my $self = shift;
  my $reg  = shift;
  my $lock = new Mj::Lock($self->{lockfile}, 'Shared');
  my $db   = $self->_make_db;
  return unless $db;

  my ($key, $match, $status, $value);

  $key = $value = '';
  for ($status = $db->seq($key, $value, R_FIRST) ;
       $status == 0 ;
       $status = $db->seq($key, $value, R_NEXT) )
    {
      if (re_match($reg, $key)) {
	return ($key, $value);
      }
    }
  return;
}

1;

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

#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

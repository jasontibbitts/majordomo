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

package Mj::SimpleDB::Text;
use Mj::SimpleDB::Base;
use DB_File;
use Mj::Lock;
use Mj::Log;
use Safe;
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

  unless (defined($safe)) {
    $safe = new Safe;
    $safe->permit_only(qw(const leaveeval null pushmark return rv2sv stub));
  }

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
  return if $self->{db};
  my (%db);

  # Now grab the DB object.  We don't care about the hash we're tying to,
  # because we're going to save the speed hit and use the API directly.
  $self->{db} = tie %db, 'DB_File', $self->{filename},
                         O_RDWR|O_CREAT, 0666, $self->{dbtype};
}

=head2 DESTROY

This cleans up when the time comes to get rid of the database.  This undefs
all stored data and deletes the database file in the event that it has zero
size.

=cut

sub DESTROY {
  my $self = shift;
  my $log  = new Log::In 200, $self->{'name'};
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
  my ($data, $done, $flags, $status);

  # Grab a lock up front; this elminiates the race between creation and
  # opening.
  my $lock = new Mj::Lock($self->{lockfile}, 'Exclusive');
  return 0 unless $self->_make_db;

  $flags = 0; $flags = R_NOOVERWRITE unless $mode =~ /force/;
  $status = $self->{db}->put($key, $self->_stringify($argref), $flags);

  # If success...
  if ($status == 0) {
    $done = 1;
  }
  # If the key existed and NOOVERWEITE was given...
  elsif ($status > 0) {
    $data = $self->lookup($key);
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
sub remove {
  my $self = shift;
  my $mode = shift;
  my $key  = shift;
  my $log  = new Log::In 120, "$self->{filename}, $mode, $key";

  my (@nuke, @out, $data, $fh, $match, $status, $try, $value);
  return unless $self->_make_db;

  my $lock = new Mj::Lock($self->{lockfile}, 'Exclusive');

  # First, take care of the simple case.  Note that we don't allow
  # duplicates, but if we did there would be a problem with the del method
  # automatically removing all keys present.
  if ($mode !~ /regex/) {
    # Perhaps the key exists; look it up
    $data = $self->_lookup($key);

    # If we got something, delete and return it.
    if ($data) {
      $status = $self->{db}->del($key);
      return ($key, $data);
    }
    return;
  }

  # So we're doing regex processing, which means we have to search.
  # SimpleDB::Text can make use of lookup and lookup_regexp but we can't
  # rely on the stability of the cursor across a delete.
  $try = $value = 0;
  for ($status = $self->{db}->seq($try, $value, R_FIRST);
       $status == 0;
       $status = $self->{db}->seq($try, $value, R_NEXT);
      ) 
    {
      if (_re_match($key, $try)) {
	$self->{db}->del($try, R_CURSOR);
	push @out, ($try, $self->_unstringify($value));
	last if $mode !~ /allmatching/;
      }
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
If field is a code reference, it is executed and the resulting hash is
written back as the data.  Unlike the mogrify function, this cannot change
the key.

Returns a list of keys that were modified.

=cut
sub replace {
  my $self  = shift;
  my $mode  = shift;
  my $key   = shift;
  my $field = shift;
  my $value = shift;
  $value = "" unless defined $value;
  my $log   =  new Log::In 120, "$self->{filename}, $mode, $key, $field, $value";
  return unless $self->_make_db;
  my (@out, $k, $matches, $match, $data, $v);
  my $lock = new Mj::Lock($self->{lockfile}, 'Exclusive');

  $matches = 0;

  # Take care of the easy case first.  Note that we don't allow duplicates, so there's no need to loop nere.
  if ($mode !~ /regex/) {
    $data = $self->_lookup($key);
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
    $self->{db}->put($key, $self->_stringify($data));
    return ($key);
  }
  
  # So we're doing regex processing, which means we have to search.
  # SimpleDB::Text can make use of lookup and lookup_regexp but we can't
  # rely on the stability of the cursor across a delete.
  $try = $value = 0;
  for ($status = $self->{db}->seq($k, $v, R_FIRST);
       $status == 0;
       $status = $self->{db}->seq($k, $v, R_NEXT);
      ) 
    {
      if (_re_match($key, $k)) {
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
	$self->{db}->put($key, $self->_stringify($data), R_CURSOR);
	return ($key);
	

	$self->{db}->del($try, R_CURSOR);
	push @out, ($try, $self->_unstringify($value));
	last if $mode !~ /allmatching/;
      }
    }

  if (@out) {
    return @out;
  }
  
  $log->out("failed");
  return;
}


  while (1) {
      # Note that lookup implicitly copies for us.
      ($match, $data) = $self->lookup_regexp($key, $fh);
      last unless defined $match;
      if (ref($field) eq 'HASH') {
	$data = $field;
      }
      elsif (ref($field) eq 'CODE') {
	$data = &$field($data);
      }
      else {
	$data->{$field} = $value;
      }
      $fh->print("$match\001" . $self->_stringify($data) . "\n");
      push @out, $match;
      if ($mode !~ /allmatching/) {
	$fh->copy;
	last;
      }
    }
  }
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
  my $log  = new Log::In 120, "$self->{name}";

  my ($fh, $record, $key, $encoded, $data, $changekey,
      $changedata, $newkey, $changed);

  # If we don't exist, there's no point
  unless (-r $self->{name}) {
    $log->out("failed");
    return;
  }

  $fh = new Mj::FileRepl($self->{name}, $self->{lockfile});
  $fh->untaint;
  $changed = 0;

 RECORD:
  while (defined ($record = $fh->getline)) {
    chomp $record;
    ($key, $encoded) = split("\001",$record, 2);
    $data = $self->_unstringify($encoded);
    ($changekey, $changedata, $newkey) = &$code($key, $data);

    # Do we need to change anything
    unless ($changekey || $changedata) {
      $fh->print("$record\n");
      next RECORD;
    }

    $changed++;
    if ($changekey) {
      $key = $newkey;
    }
    
    # Delete the line if necessary;
    unless (defined $key) {
      next RECORD;
    }

    # Re-encode data; update changetime if necessary
    if ($changedata) {
      $encoded = $self->_stringify($data, ($changedata < 0));
    }
    $fh->print("$key\001$encoded\n");
  }
  if ($changed) {
    $fh->commit;
  }
  else {
    $fh->abandon;
  }
  $log->out("changed $changed");
}

=head2 load

This loads the entire database into a hash and returns a reference to it.

Warning: this can consume large amounts of memory for large databases.  Use
this with great care.

XXX Not implemented.  Do I even need this?

=head2 get_start, get_done

These initialize and close the iterator used to retrieve lists of rows.

=cut
sub get_start {
  my $self = shift;

  $self->{get_lock} = new Mj::Lock($self->{lockfile}, 'Shared');

  # Auto-create ourselves.  Do this because we don't want to return an
  # error if the file doesn't exist, and because we want a lock during the
  # entire operation.
  unless (-r $self->{'name'}) {
    my $fh = new IO::File;
    $fh->open($self->{'name'}, ">>");
    $fh->close;
  }

  # Already locked
  $self->{get_handle} = new Mj::File $self->{name}, 'U<';
  $self->{get_handle}->untaint;
  1;
}

sub get_done {
  my $self = shift;
  $self->{get_handle}->close;
  $self->{get_handle} = undef;
  $self->{get_lock} = undef;
}

=head2 get_quick(count)

This gets a chunk of keys without their data from the list.  Will return no
more than count keys.  Will return an empty list at EOF.

=cut
sub get_quick {
  my $self  = shift;
  my $count = shift;
  my $log   = new Log::In 121, "$self->{'name'}, $count";
  my (@keys, $key, $i);

 KEYS:
  for ($i=0; $i<$count; $i++) {
    $key = $self->{'get_handle'}->getline;
    last KEYS unless $key;
    ($key) = split("\001",$key,2);
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
  my $log   = new Log::In 121, "$self->{'name'}, $count";
  my (@keys, $key, $i);

 KEYS:
  for ($i=0; $i<$count; $i++) {
    $key = $self->{'get_handle'}->getline;
    last KEYS unless $key;
    $key =~ /(.*?)\001(.*)/;
    push @keys, ($1, $self->_unstringify($2));
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
  my $log   = new Log::In 121, "$self->{'name'}, @_";
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my (@keys, $key, $data, $i);

  for ($i=0; $i<$count; $i++) {
    $key = $self->{'get_handle'}->search("/\001\Q$value\E/");
    last unless $key;
    ($key, $data) = split("\001", $key, 2);
    $data = $self->_unstringify($data);
    if (defined($data->{$field}) && 
	$data->{$field} eq $value)
      {
	push @keys, $key;
	next;
      }
    redo;
  }
  return @keys;
}

sub get_matching_quick_regexp {
  my $self  = shift;
  my $log   = new Log::In 121, "$self->{'name'}, @_";
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my (@keys, $key, $data, $i);

  for ($i=0; $i<$count; $i++) {
    $key = $self->{'get_handle'}->search("$value");
    last unless $key;
    ($key, $data) = split("\001", $key, 2);
    $data = $self->_unstringify($data);
    if (defined($data->{$field}) && _re_match($value, $data->{$field})) {
      push @keys, $key;
      next;
    }
    redo;
  }
  return @keys;
}

sub get_matching {
  my $self  = shift;
  my $log   = new Log::In 121, "$self->{'name'}, @_";
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my (@keys, $code, $key, $data, $i, $tmp);

  $code = 1 if ref($field) eq 'CODE';

  for ($i=0; ($count ? ($i<$count) : 1); $i++) {
    if ($code) {
      $key = $self->{'get_handle'}->getline;
    }
    else {
      $key = $self->{'get_handle'}->search("/\001\Q$value\E/");
    }
    last unless $key;
    chomp $key;
    ($key, $data) = split("\001", $key, 2);
    $data = $self->_unstringify($data);
    if ($code) {
      $tmp = &$field($key, $data);
      last unless defined $tmp;
      push @keys, ($key, $data) if $tmp;
    }
    elsif (defined($data->{$field}) && 
	$data->{$field} eq $value)
      {
	push @keys, ($key, $data);
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
  my $log   = new Log::In 121, "$self->{'name'}, $count, $field, $value";
  my (@keys, $key, $data, $i);

  for ($i=0; $i<$count; $i++) {
    $key = $self->{'get_handle'}->search("$value");
    last unless $key;
    ($key, $data) = split("\001", $key, 2);
    $data = $self->_unstringify($data);
    if (defined($data->{$field}) && _re_match($value, $data->{$field})) {
      push @keys, ($key, $data);
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
  my($self, $key) = @_;
  my($status, $value, $data);

  $status = $self->{db}->get($key, $value);
  if ($status == 0 && $value) {
    $data = $self->_unstringify($value);
  }
  $data;
}


=head2 lookup_quick(key, fileh)

This checks to see if a key is a member of the list.  It
returns only truth on success and not any of the data.  If the optional
second parameter is given, an already open filehandle is used.

=cut

sub lookup_quick {
  my $self = shift;
  my $key  = shift;
  return unless -f $self->{'name'};
  my $fh   = shift || new Mj::File $self->{'name'}, '<', $self->{lockfile};


    $status = $self->{db}->get($key, $value);
    if ($status != 0) {
      return;
    }
    $data = $self->


  # We should be able to trust the contents of this file.
  $fh->untaint;

  unless ($key) {
    $::log->abort("SimpleDB::lookup_quick called with null key.");
  }
  
  my $out = $fh->search("/^\Q$key\E\001/");
  return undef unless defined $out;
  chomp $out;
  return (split("\001",$out,2))[1];
}

sub lookup_quick_regexp {
  my $self = shift;
  my $reg  = shift;
  return unless -f $self->{'name'};
  my $fh   = shift || new Mj::File $self->{'name'}, '<', $self->{lockfile};
  my $wb  = shift;
  $fh->untaint;

  my ($key, $match, $line);

  while (defined ($line = $fh->search($reg))) {
    chomp $line;
    ($key, $match) = split("\001", $line, 2);
    if (_re_match($reg, $key)) {
      return ($key, $match);
    }
    elsif ($wb) {
      $fh->print("$line\n");
    }
  }
  return;
}

# sub _re_match {
#   my $re   = shift;
#   my $addr = shift;
#   my $match;
#   return 1 if $re eq 'ALL';

#   local($^W) = 0;
#   $match = $Majordomo::safe->reval("'$addr' =~ $re");
#   $::log->complain("_re_match error: $@") if $@;
#   return $match;
# }

sub _re_match {
  my    $re = shift;
  local $_  = shift;
  my $match;
  return 1 if $re eq 'ALL';

  local($^W) = 0;
  $match = $safe->reval("$re");
  $::log->complain("_re_match error: $@\nstring: $_\nregexp: $re") if $@;
  if (wantarray) {
    return ($match, $@);
  }
  return $match;
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

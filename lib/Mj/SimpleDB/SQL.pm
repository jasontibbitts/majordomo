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
    $self->{table} = $self->{file};
    if ($self->{table} =~ /^_/o) {
      $self->{table} =~ s/^_//o;
    } elsif ($self->{table} =~ /^X/o) {
      $self->{table} =~ s/^X//o;
      $self->{list} .= ":".$self->{table};
      $self->{table} = 'subscribers';
    } else {
      $log->complain("Unknown db : $self->{table}");
      return;
    }
    $self->{filename} = "$self->{domain}, $self->{list}, $self->{file}";
  } else {
    warn "Problem parsing filename $self->{filename}";
  }


  bless $self, $class;
  $self;
}

sub DESTROY {
  undef;
}

=head2 _make_db

This will return the schema for the table so that the backend can
issue the proper "CREATE TABLE" statements.

=cut

{
  my $schema = {
    'default' => [
		   { NAME => "t_domain", TYPE => "varchar(64)",  PRIM_KEY => 1 },
		   { NAME => "t_list",	 TYPE => "varchar(128)", PRIM_KEY => 1 },
		   { NAME => "t_key",	 TYPE => "varchar(255)", PRIM_KEY => 1 },
		 ],
    'parser' => [
		  { NAME => 'changetime', TYPE => 'integer' },
		  { NAME => 'events',	  TYPE => 'varchar(255)' },
		],
    'bounce' => [
		  { NAME => 'diagnostic', TYPE => 'varchar(255)' },
		  { NAME => 'bounce',	  TYPE => 'text' },
		],
    'dup_id' => [
		  { NAME => 'changetime', TYPE => 'integer' },
		  { NAME => 'lists',	  TYPE => 'varchar(255)' },
		],
    'posts' => [
		 { NAME => 'changetime', TYPE => 'integer' },
		 { NAME => 'postdata',	 TYPE => 'text' },
		 { NAME => 'dummy',	 TYPE => 'varchar(1)' },
	       ],
    'aliases' => [
		   { NAME => 'changetime',  TYPE => 'integer' },
		   { NAME => 'target',	    TYPE => 'varchar(255)' },
		   { NAME => 'stripsource', TYPE => 'varchar(255)' },
		   { NAME => 'striptarget', TYPE => 'varchar(255)' },
		 ],
    'subscribers' => [
		       { NAME => 'subtime',    TYPE => 'integer' },
		       { NAME => 'changetime', TYPE => 'integer' },
		       { NAME => 'stripaddr',  TYPE => 'varchar(130)' },
		       { NAME => 'fulladdr',   TYPE => 'varchar(255)' },
		       { NAME => 'class',      TYPE => 'varchar(10)' },
		       { NAME => 'classarg',   TYPE => 'varchar(64)' },
		       { NAME => 'classarg2',  TYPE => 'varchar(64)' },
		       { NAME => 'flags',      TYPE => 'varchar(20)' },
		       { NAME => 'expire',     TYPE => 'varchar(1)' },
		       { NAME => 'remind',     TYPE => 'varchar(1)' },
		       { NAME => 'id',	       TYPE => 'varchar(1)' },
		       { NAME => 'diagnostic', TYPE => 'varchar(255)' },
		       { NAME => 'groups',     TYPE => 'text' },
		       { NAME => 'bounce',     TYPE => 'text' },
		     ],
    'register' => [
		    { NAME => 'stripaddr',   TYPE => 'varchar(130)' },
		    { NAME => 'fulladdr',    TYPE => 'varchar(255)' },
		    { NAME => 'changetime',  TYPE => 'integer' },
		    { NAME => 'regtime',     TYPE => 'integer' },
		    { NAME => 'password',    TYPE => 'varchar(64)' },
		    { NAME => 'language',    TYPE => 'varchar(5)' },
		    { NAME => 'lists',	     TYPE => 'text' },
		    { NAME => 'flags',	     TYPE => 'varchar(1)' },
		    { NAME => 'bounce',	     TYPE => 'varchar(1)' },
		    { NAME => 'warnings',    TYPE => 'varchar(1)' },
		    { NAME => 'data01',	     TYPE => 'varchar(1)' },
		    { NAME => 'data02',	     TYPE => 'varchar(1)' },
		    { NAME => 'data03',	     TYPE => 'varchar(1)' },
		    { NAME => 'data04',	     TYPE => 'varchar(1)' },
		    { NAME => 'data05',	     TYPE => 'varchar(1)' },
		    { NAME => 'data06',	     TYPE => 'varchar(1)' },
		    { NAME => 'data07',	     TYPE => 'varchar(1)' },
		    { NAME => 'data08',	     TYPE => 'varchar(1)' },
		    { NAME => 'data09',	     TYPE => 'varchar(1)' },
		    { NAME => 'data10',	     TYPE => 'varchar(1)' },
		    { NAME => 'data11',	     TYPE => 'varchar(1)' },
		    { NAME => 'data12',	     TYPE => 'varchar(1)' },
		    { NAME => 'data13',	     TYPE => 'varchar(1)' },
		    { NAME => 'data14',	     TYPE => 'varchar(1)' },
		    { NAME => 'data15',	     TYPE => 'varchar(1)' },
		    { NAME => 'rewritefrom', TYPE => 'varchar(1)' },
		  ],
    'tokens' => [
		  { NAME => 'type',       TYPE => 'varchar(10)' },
		  { NAME => 'list',       TYPE => 'varchar(64)' },
		  { NAME => 'command',    TYPE => 'varchar(15)' },
		  { NAME => 'user',       TYPE => 'varchar(255)' },
		  { NAME => 'victim',     TYPE => 'varchar(255)' },
		  { NAME => 'mode',       TYPE => 'varchar(200)' }, # after a few calculations, 99 should be enought, but well
		  { NAME => 'cmdline',    TYPE => 'varchar(255)' },
		  { NAME => 'approvals',  TYPE => 'integer' },
		  { NAME => 'chain1',     TYPE => 'varchar(120)' },
		  { NAME => 'chain2',     TYPE => 'varchar(120)' },
		  { NAME => 'chain3',     TYPE => 'varchar(120)' },
		  { NAME => 'approver',   TYPE => 'varchar(64)' },
		  { NAME => 'arg1',       TYPE => 'text' },
		  { NAME => 'arg2',       TYPE => 'text' },
		  { NAME => 'arg3',       TYPE => 'text' },
		  { NAME => 'time',       TYPE => 'integer' },
		  { NAME => 'changetime', TYPE => 'integer' },
		  { NAME => 'sessionid',  TYPE => 'varchar(40)' },
		  { NAME => 'reminded',   TYPE => 'varchar(1)' },
		  { NAME => 'permanent',  TYPE => 'varchar(1)' },
		  { NAME => 'expire',     TYPE => 'integer' },
		  { NAME => 'remind',     TYPE => 'integer' },
		  { NAME => 'reasons',    TYPE => 'text' },
		],
    };
    # copying definitions is the worst thing so...
    $schema->{latchkeys}   = $schema->{tokens};
    $schema->{dup_sum}     = $schema->{dup_id};
    $schema->{dup_partial} = $schema->{dup_id};

=cut

There is not archive table in there yet, because it's hardcoded into text.

=cut
  
  sub _make_db {
    my $self = shift;
    my $log   = new Log::In 200, "$self->{filename}";

    if (defined($schema->{$self->{table}})) {
      my @schema = (@{$schema->{default}},@{$schema->{$self->{table}}});

      return @schema;
    } else {
      return;
    }
  }
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
  my $log    = new Log::In 200, "$self->{filename}, $key, $flag, $argref";
  my %args = %$argref;

  my $exist = $db->do("SELECT t_key FROM $self->{table} WHERE t_domain = ? AND t_list = ? AND t_key = ? FOR UPDATE",
		      undef,
		      $self->{domain}, $self->{list}, $key);

  if ($exist == 0) {
    my $r = $db->do("INSERT INTO $self->{table} (t_domain, t_list, t_key, ".
		     join(", ", $self->_escape_field(@{$self->{fields}})).
		     ") VALUES (?, ?, ?, ".
		     join(", ", map { "?" } @{$self->{fields}}).
		     ")", undef, $self->{domain}, $self->{list}, $key, 
		    $self->_escape_value(@args{@{$self->{fields}}}));

    return (defined($r) ? 0 : 1);
  } elsif ($exist and $flag == 0) {
    my $r = $db->do("UPDATE $self->{table} SET ".
		     join(", ", map { "$_ = ? " } $self->_escape_field(@{$self->{fields}})).
		     " WHERE t_domain = ? AND t_list = ? AND t_key = ?", undef,
		    $self->_escape_value(@args{@{$self->{fields}}}), $self->{domain}, $self->{list}, $key);
		  
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
      $sth = $db->prepare_cached("DELETE FROM $self->{table} WHERE t_domain = ? AND t_list = ? AND t_key = ?");
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

  $sth = $db->prepare_cached("SELECT t_key, ".
			      join(",", $self->_escape_field(@{$self->{fields}})).
			      " FROM $self->{table} WHERE t_domain = ? AND t_list = ? FOR UPDATE");

  $sth->execute($self->{domain}, $self->{list});
  
  for ($data = $sth->fetchrow_hashref;
       defined($data);
       $data = $sth->fetchrow_hashref) {
    $try = delete $data->{t_key};
    if (re_match($key, $try)) {
      push @deletions, $try;
      push @out, ($try, $data);
      last if $mode !~ /allmatching/;
    }
  }

  $sth->finish();

  $sth = $db->prepare_cached("DELETE FROM $self->{table} WHERE t_domain = ? AND t_list = ? AND t_key = ?");
  
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
  $sth = $db->prepare_cached("SELECT t_key, ".
			      join(",", $self->_escape_field(@{$self->{fields}})).
			      " FROM $self->{table} WHERE t_domain = ? AND t_list = ? FOR UPDATE");

  $sth->execute($self->{domain}, $self->{list});
  
  for ($data = $sth->fetchrow_hashref;
       defined($data);
       $data = $sth->fetchrow_hashref) {
    $k = delete $data->{t_key};
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

  $sth = $db->prepare_cached("SELECT t_key, ".
			      join(",", $self->_escape_field(@{$self->{fields}})).
			      " FROM $self->{table} WHERE t_domain = ? AND t_list = ?");

  $sth->execute($self->{domain}, $self->{list});
  
 RECORD:
  for ($data = $sth->fetchrow_hashref;
       defined($data);
       $data = $sth->fetchrow_hashref) {
    # Extract the data and call the coderef
    $k = delete $data->{t_key};
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
    $db->do("DELETE FROM $self->{table} WHERE t_domain = ? AND t_list = ? AND t_key = ?",
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

    $sth = $db->prepare_cached("SELECT t_key, ".
				join(",", $self->_escape_field(@{$self->{fields}})).
				" FROM $self->{table} WHERE t_domain = ? AND t_list = ?");

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
    $k = delete $v->{t_key};
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
				  join(",", $self->_escape_field(@{$self->{fields}})).
				  " FROM $self->{table} WHERE t_domain = ? AND t_list = ? AND t_key = ? FOR UPDATE");

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

  my ($key, $match, $data, $value, $sth);

  $sth = $db->prepare_cached("SELECT t_key FROM $self->{table} WHERE t_domain = ? AND t_list = ?");

  $sth->execute($self->{domain}, $self->{list});
  
 RECORD:
  for ($data = $sth->fetchrow_hashref;
       defined($data);
       $data = $sth->fetchrow_hashref) {
      $key = delete $data->{t_key};
      $value = $data;
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

sub _escape_field {
  my $self = shift;
  return @_;
}

sub _escape_value {
  my $self = shift;
  for (@_) {
    undef ($_) if /^$/o;
  }
  return @_
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

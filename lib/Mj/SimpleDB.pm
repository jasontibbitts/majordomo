=head1 NAME

Mj::SimpleDB - A Very simple database

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This contains rouines to implement a very simple database.  Data is tab
delimited and is not maintained in any particular order.  There are a few
access routines which are used to retrieve keys and data; these are
tailored to the kind of access which Majordomo needs.

If the database has a changetime field, it will be automatically maintained
during changes.

=cut

package Mj::SimpleDB;
use IO::File;
use Mj::File;
use Mj::FileRepl;
use Mj::Log;
use strict;

=head2 new(path, field_list_ref)

This allocates the SimpleDB with a particular name.  This will create the
data file if it does not exist.  The file is not locked in any way by this
operation.

XXX Add an argument 'method' and move the rest of this into
Mj::SimpleDB::Text.  Make a Mj::SimpleDB::DB and a Mj::SimpleDB::MySQL (or
DBI, I suppose) later.  Add export routines to produce a neutral file
format and an inport routine to read it.  This makes it possible to
convert, or even to adjust for changes in field order.

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;

  my $self = {};
  bless $self, $class;

  $self->{'name'} = shift;
  my $log  = new Log::In 200, $self->{'name'};
  $self->{'fields'} = shift;

  $self;
}

=head2 DESTROY

This cleans up when the time comes to get rid of the database.  This undefs
all stored data and deletes the database file in the event that it has zero
size.

=cut

sub DESTROY {
  my $self = shift;
  my $log  = new Log::In 200, $self->{'name'};
  undef $self->{'get_handle'};
  
  if (-z $self->{'name'}) {
    my $fh = new Mj::File;
    $fh->open($self->{'name'}, ">>");

    # Check again now that we have exclusive access.
    if (-z $self->{'name'}) {
      $log->message(170, "info", "Mj::SimpleDB deleting zero-size file $self->{'name'}");
      unlink $self->{'name'};
    }
    $fh->close;
  }
}

=head2 add(mode, key, datahashref)

This adds a row to the database.

This returns a list:

  flag - truth on success
  data - if failure, a ref to the data that already exists for the key

=cut
sub add {
  my $self   = shift;
  my $mode   = shift || "";
  my $key    = shift;
  my $argref = shift;
  my $log    = new Log::In 120, "$self->{'name'}, $mode, $key";
  my ($data, $done, $file);

  # Auto-create ourselves if we don't exist
  unless (-r $self->{'name'}) {
    my $fh = new Mj::File;
    $fh->open($self->{'name'}, ">>");
    $fh->close;
  }
  
  $file = new Mj::File $self->{'name'}, '+<';

  if ($mode =~ /force/i || !($data = $self->lookup($key, $file))) {
    $file->seek(0,2);
    $file->print("$key\t" . $self->_stringify($argref) . "\n");
    $done = 1;
  }
  $file->close;
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
  my $log  = new Log::In 120, "$self->{'name'}, $mode, $key";

  my (@out, $data, $fh, $match);
  
  # If we don't exist, there's no point
  unless (-r $self->{'name'}) {
    $log->out("failed");
    return;
  }

  $fh = new Mj::FileRepl $self->{'name'};
  
  if ($mode =~ /regex/) {
    while (1) {
      # Note that lookup on a FileRepl automatically copies for us.
      ($match, $data) = $self->lookup_regexp($key, $fh);
      last unless defined $match;
      push @out, ($match, $data);
      if ($mode !~ /allmatching/) {
	$fh->copy;
	last;
      }
    }
  }
  else {
    while (1) {
      # Note that lookup on a FileRepl automatically copies for us.
      ($data) = $self->lookup($key, $fh);
      last unless defined $data;
      push @out, ($key, $data);
      if ($mode !~ /allmatching/) {
	$fh->copy;
	last;
      }
    }
  }
  if (@out) {
    $fh->commit;
    return @out;
  }
  
  $fh->abandon;
  $log->out("failed");
  return;
}

=head2 replace(mode, key, field_or_hashref, value)

This replaces the value of a field in one or more rows with a different
value.  The mode parameter controls how this operates.  If mode=~/regex/,
key is taken as a regular expression, otherwise it is taken as the key to
modify.  If mode=~/allmatching/, all matching rows are modified, else only
the first is.

If field is a reference, it is used as the hash of data and values.

Returns a list of keys that were modified.

=cut
sub replace {
  my $self  = shift;
  my $mode  = shift;
  my $key   = shift;
  my $field = shift;
  my $value = shift;
  $value = "" unless defined $value;
  my $log   =  new Log::In 120, "$self->{'name'}, $mode, $key, $field, $value";
  my (@out, $fh, $matches, $match, $data);

  # If we don't exist, there's no point
  unless (-r $self->{'name'}) {
    $log->out("failed");
    return;
  }

  $fh = new Mj::FileRepl $self->{'name'};
  $matches = 0;
  
  if ($mode =~ /regex/) {
    while (1) {
      # Note that lookup implicitly copies for us.
      ($match, $data) = $self->lookup_regexp($key, $fh);
      last unless defined $match;
      if (ref $field) {
	$data = $field;
      }
      else {
	$data->{$field} = $value;
      }
      $fh->print("$match\t" . $self->_stringify($data) . "\n");
      push @out, $match;
      if ($mode !~ /allmatching/) {
	$fh->copy;
	last;
      }
    }
  }
  else {
    while (1) {
      $data = $self->lookup($key, $fh);
      last unless defined $data;
      
      # Update the value, and the record.
      if (ref $field) {
	$data = $field;
      }
      else {
	$data->{$field} = $value;
      }
      $fh->print("$key\t" . $self->_stringify($data) . "\n");
      push @out, $key;
      if ($mode !~ /allmatching/) {
	$fh->copy;
	last;
      }
    }
  }
  if (@out) {
    $fh->commit;
    return @out
  }

  $fh->abandon;
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
  my $log  = new Log::In 120, "$self->{'name'}";

  my ($fh, $record, $key, $encoded, $data, $changekey,
      $changedata, $newkey, $changed);

  # If we don't exist, there's no point
  unless (-r $self->{'name'}) {
    $log->out("failed");
    return;
  }

  $fh = new Mj::FileRepl $self->{'name'};
  $fh->untaint;
  $changed = 0;

 RECORD:
  while (defined ($record = $fh->getline)) {
    chomp $record;
    ($key, $encoded) = split("\t",$record, 2);
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
    $fh->print("$key\t$encoded\n");
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

  # Auto-create ourselves.  Do this because we don't want to return an
  # error if the file doesn't exist, and because we want a lock during the
  # entire operation.
  unless (-r $self->{'name'}) {
    my $fh = new Mj::File;
    $fh->open($self->{'name'}, ">>");
    $fh->close;
  }

  $self->{'get_handle'} = new Mj::File $self->{'name'};
  $self->{'get_handle'}->untaint;
  1;
}

sub get_done {
  my $self = shift;
  $self->{'get_handle'}->close;
  $self->{'get_handle'} = undef;
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
    ($key) = split("\t",$key,2);
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
    $key =~ /(.*?)\t(.*)/;
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
operation down close to one regexp match per line.

XXX coderef not implemented.

This returns a list of entries, or an empty list if no matching entries
before EOF.

=cut
sub get_matching_quick {
  my $self  = shift;
  my $log   = new Log::In 121, "$self->{'name'}, @_";
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my (@keys, $key, $data, $i);

  for ($i=0; $i<$count; $i++) {
    $key = $self->{'get_handle'}->search("\t\Q$value\E");
    last unless $key;
    ($key, $data) = split("\t", $key, 2);
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
    ($key, $data) = split("\t", $key, 2);
    $data = $self->_unstringify($data);
    if (defined($data->{$field}) && 
	$data->{$field} =~ /$value/)
      {
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
  my (@keys, $key, $data, $i);

  for ($i=0; ($count ? ($i<$count) : 1); $i++) {
    $key = $self->{'get_handle'}->search("\t\Q$value\E");
    last unless $key;
    chomp $key;
    ($key, $data) = split("\t", $key, 2);
    $data = $self->_unstringify($data);
    if (defined($data->{$field}) && 
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
  my $log   = new Log::In 121, "$self->{'name'}, @_";
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my (@keys, $key, $data, $i);

  for ($i=0; $i<$count; $i++) {
    $key = $self->{'get_handle'}->search("$value");
    last unless $key;
    ($key, $data) = split("\t", $key, 2);
    $data = $self->_unstringify($data);
    if (defined($data->{$field}) && 
	$data->{$field} =~ /$value/i)
      {
	push @keys, ($key, $data);
	next;
      }
    redo;
  }
  return @keys;
}

=head2 lookup_quick(key, fileh)

This checks to see if a key is a member of the list.  It
returns only truth on success and not any of the data.  If the optional
second parameter is used, an already open filehandle is used.

=cut

sub lookup_quick {
  my $self = shift;
  my $key  = shift;
  return unless -f $self->{'name'};
  my $fh   = shift || new Mj::File $self->{'name'}, '<';

  # We should be able to trust the contents of this file.
  $fh->untaint;

  unless ($key) {
    $::log->abort("SimpleDB::lookup_quick called with null key.");
  }
  
  my $out = $fh->search("^\Q$key\E\t");
  return undef unless defined $out;
  chomp $out;
  return (split("\t",$out,2))[1];
}

sub lookup_quick_regexp {
  my $self = shift;
  my $reg  = shift;
  return unless -f $self->{'name'};
  my $fh   = shift || new Mj::File $self->{'name'}, '<';
  $fh->untaint;

  my ($key, $match);

  while (defined ($match = $fh->search($reg))) {
    chomp $match;
    ($key, $match) = split("\t", $match, 2);
    if ($key =~ /$reg/) {
      return ($key, $match);
    }
  }
  return;
}

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

=head1 NAME

Mj::SimpleDB::Text - A very simple flat-file database

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

package Mj::SimpleDB::Text;
use Mj::SimpleDB::Base;
use Mj::File;
use Mj::Lock;
use Mj::FileRepl;
use Mj::Log;
use strict;
use vars qw(@ISA $VERSION $safe);

@ISA=qw(Mj::SimpleDB::Base);
$VERSION = 1;

=head2 new(path, lockpath, field_list_ref)

This allocates the SimpleDB with a particular name.  This will create the
data file if it does not exist.  The file is not locked in any way by this
operation.

If lockpath is set, it will be used as the path to lock.  This is done to
ease automatic use of multiple databases, so that one base name can be used
as the lockfile for all backends.  Note that due to the way Mj::Lock works,
this is not the actual path to the lockfile.  In effect, we can pretend
we''re locking a database without the extension.

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;
  my %args = @_;

  my $self = {};
  bless $self, $class;

  $self->{back} = 'Text';
  $self->{name} = $args{filename};
  $self->{lock} = $args{lockfile} || $self->{name};
  my $log  = new Log::In 200, "$self->{name}, $self->{lock}";
  $self->{fields} = $args{fields};

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
  undef $self->{get_handle};
  undef $self->{get_lock};
  
  if (-z $self->{name}) {
    my $lock = new Mj::Lock($self->{lock}, 'Exclusive');

    # Check again now that we have a lock
    if (-z $self->{name}) {
      $log->message(170, "info", "Mj::SimpleDB deleting zero-size file $self->{'name'}");
      unlink $self->{name};
    }
  }
}

=head2 add(mode, key, datahashref)

This adds a row to the database.

This returns a list:

  flag - truth on success
  data - a ref to the data that already exists for the key

=cut
sub add {
  my $self   = shift;
  my $mode   = shift || "";
  my $key    = shift;
  my $argref = shift;
  my $log    = new Log::In 120, "$self->{'name'}, $mode, $key";
  my ($data, $done, $fh);

  # Grab a lock up front; this elminiates the race between creation and
  # opening.
  my $lock = new Mj::Lock($self->{lock}, 'Exclusive');

  # Auto-create ourselves if we don't exist
  unless (-r $self->{'name'}) {
    open (FH, ">>$self->{'name'}")
      or $::log->abort("Unable to open file $self->{'name'}: $!");
    close (FH)
      or $::log->abort("Unable to close file $self->{'name'}: $!");
  }
  
  $fh = new Mj::FileRepl($self->{name});
  $data = $self->lookup($key, $fh);
  if ($data) {
    if ($mode =~ /force/i) {
      $fh->print("$key\001" . $self->_stringify($argref) . "\n");
      $fh->copy;
      $fh->commit;
      return (1, $data);
    }
    else {
      $fh->abandon;
      return (undef, $data);
    }
  }

  # The existing file has been copied by the lookup.  
  # Add the new entry to the end of the file.
  $fh->print("$key\001" . $self->_stringify($argref) . "\n");
  $fh->commit;

  (1, $data);
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
  unless (-r $self->{name}) {
    $log->out("failed");
    return;
  }

  $fh = new Mj::FileRepl($self->{name}, $self->{lock});
  
  if ($mode =~ /regex|pattern/) {
    while (1) {
      # Note that lookup on a FileRepl automatically copies for us, unless
      # the match is false (matches in the line but doesn't match the key).
      # For that, we pass the special flag that causes lookup_regexp to
      # write back false matches.
      ($match, $data) = $self->lookup_regexp($key, $fh, 1);
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
      # Note that lookup on a FileRepl automatically copies for us
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
  my $log   =  new Log::In 120, "$self->{'name'}, $mode, $key, $field, $value";
  my (@out, $fh, $matches, $match, $data);

  # If we don't exist, there's no point
  unless (-r $self->{name}) {
    $log->out("failed");
    return;
  }

  $fh = new Mj::FileRepl($self->{name}, $self->{lock});
  $matches = 0;
  
  if ($mode =~ /regex|pattern/) {
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
  else {
    while (1) {
      $data = $self->lookup($key, $fh);
      last unless defined $data;
      
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
      $fh->print("$key\001" . $self->_stringify($data) . "\n");
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
  my $log  = new Log::In 120, "$self->{name}";

  my ($fh, $record, $key, $encoded, $data, $changekey,
      $changedata, $newkey, $changed);

  # If we don't exist, there's no point
  unless (-r $self->{name}) {
    $log->out("failed");
    return;
  }

  $fh = new Mj::FileRepl($self->{name}, $self->{lock});
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

  $self->{get_lock} = new Mj::Lock($self->{lock}, 'Shared');

  # Auto-create ourselves.  Do this because we don't want to return an
  # error if the file doesn't exist, and because we want a lock during the
  # entire operation.
  unless (-r $self->{'name'}) {
    open (FH, ">>$self->{'name'}")
      or $::log->abort("Unable to open file $self->{'name'}: $!");
    close (FH)
      or $::log->abort("Unable to close file $self->{'name'}: $!");
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

use Mj::Util qw(re_match);
sub get_matching_quick_regexp {
  my $self  = shift;
  my $log   = new Log::In 121, "$self->{'name'}, @_";
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my (@keys, $key, $data, $i, $pattern);

  # Remove anchors from the pattern before searching
  $pattern = $value;
  $pattern =~ s/([^\\]|^)([\^\$])/$1(?:$2|\\001)/g;
  $pattern =~ s/([^\\]|^)\\([AZ])/$1(?:\\$2|\\001)/g;

  for ($i=0; $i<$count; $i++) {
    $key = $self->{'get_handle'}->search("$pattern");
    last unless $key;
    ($key, $data) = split("\001", $key, 2);
    $data = $self->_unstringify($data);
    if (defined($data->{$field}) && re_match($value, $data->{$field})) {
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

use Mj::Util qw(re_match);
sub get_matching_regexp {
  my $self  = shift;
  my $count = shift;
  my $field = shift;
  my $value = shift;
  my $log   = new Log::In 121, "$self->{'name'}, $count, $field, $value";
  my (@keys, $key, $data, $i, $pattern);

  # Remove anchors from the pattern before searching
  $pattern = $value;
  $pattern =~ s/([^\\]|^)[\^\$]/$1/g;

  for ($i=0; $i<$count; $i++) {
    $key = $self->{'get_handle'}->search("$pattern");
    last unless $key;
    ($key, $data) = split("\001", $key, 2);
    $data = $self->_unstringify($data);
    if (defined($data->{$field}) && re_match($value, $data->{$field})) {
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
second parameter is given, an already open filehandle is used.

=cut

sub lookup_quick {
  my $self = shift;
  my $key  = shift;
  return unless -f $self->{'name'};
  my $fh   = shift || new Mj::File $self->{'name'}, '<', $self->{lock};

  # We should be able to trust the contents of this file.
  $fh->untaint;

  unless ($key) {
    $::log->complain("SimpleDB::lookup_quick called with null key.");
    return;
  }
  
  my $out = $fh->search("/^\Q$key\E\001/");
  return undef unless defined $out;
  chomp $out;
  return (split("\001",$out,2))[1];
}

use Mj::Util qw(re_match);
sub lookup_quick_regexp {
  my $self = shift;
  my $reg  = shift;
  return unless -f $self->{'name'};
  my $fh   = shift || new Mj::File $self->{'name'}, '<', $self->{lock};
  my $wb  = shift;
  $fh->untaint;

  my ($key, $match, $line);

  while (defined ($line = $fh->search($reg))) {
    chomp $line;
    ($key, $match) = split("\001", $line, 2);
    if (re_match($reg, $key)) {
      return ($key, $match);
    }
    elsif ($wb) {
      $fh->print("$line\n");
    }
  }
  return;
}

1;

=head1 COPYRIGHT

Copyright (c) 1997, 1998, 2005 Jason Tibbitts for The Majordomo
Development Group.  All rights reserved.

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

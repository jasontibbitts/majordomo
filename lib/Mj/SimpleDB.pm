=head1 NAME

Mj::SimpleDB - An Abstract Database Interface

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This module implements a single access point for the creation of one of
Majordomo''s SimpleDB backend databases.  The point of abstracting database
access is so that multiple database backends can be written, each
supporting a common interface.  While the DBI modules support this, they do
so only for very heavyweight solutions like SQL servers and not for the
more lightweight solutions (like flat-text and Berkeley DB databases) which
better serve Majordomo.

A database backend needs to implement the following calls:
  new - creation
  DESTROY 
  export - print fields to a filehandle (supplied by base)
  import - add fields from filehandle (supplied by base)
  lookup - retrieve data for a given key (or undef)
  add - add a key and data, fail if exists
  remove - delete a key, returning data or undef if nonexistent
  replace - delete and add
  mogrify - complex iteration/modification function
  get_start - cursor creation
  get - cursor retrieval
  get_matching - "" by specific field
  get_matching_regexp - "" with regexp matching
  sort - sort the database

  _quick versions of all retrieval functions which can be the same as their
  normal counterparts, for when only a truth value or a list of keys is
  required.

Note that some have specific modes which need to be provided:

  add - force
  remove - regex, allmatching
  replace - regex, allmatching

Many of these (especially anything which retrieves keys by regexp) are
obviously very slow for some backends when compared to the normal access
methods as they require iteration over all of the keyspace.  Many of these
(like replace) are obviously simple combinations, but they can be done very
efficiently in a flat file database where the component calls would require
multiple passes over the file.

*** Need to code support for conversion: tag database files by the backend
*** and convert (via import/export through a temp file)
  Text    - T
  DB_File - D
  MySQL   - M
  old     - (none) convert by renaming to *.T

=cut

package Mj::SimpleDB;
use IO::File;
use Mj::File;
use Mj::FileRepl;
use Mj::Log;
use strict;
use vars qw(%beex %exbe);

%beex = 
  (
   'none' => '',
   'text' => 'T',
   'db'   => 'D',
  );

%exbe = reverse(%beex);

=head2 new(path, backend, field_list_ref, index_list_ref, sort_code_ref)

This creates and returns a SimpleDB object, or undef if the given backend
is not supported.  The object returned will actually be blessed into the
package of one of the submodules which implement the various backends.

field_list_ref is a listref of fields (columns) in the database.

index_list_ref is a listref of field names which should have indexes built.
  This is advisory; the backend can expect that get_matching will be called
  on these fields and can make preparations by building special indices for
  these fields.

sort_code_ref is a coderef which implements a key comparison function used
for sorting.

Note that these aren''t actually stored with the database (except, perhaps,
for the field list and indexed columns in an SQL backend), so they all
(except for 'backend', because of autoconversion) should be provided
identically for every opening of the same database.

XXX Accept additional backend parameters; SQL databases may need additional
arguments (for remote databases, etc.)

=cut
sub new {
  my ($type, $name, $backend, $fields, $indexes, $sorter) = @_;
  my $log  = new Log::In 200, "$name, $backend";
  my ($exist, $lock, $ver);

  # Lock the path
  $lock = new Mj::Lock($name, 'Shared');

  # Look for existing databases
  ($exist, $ver) = _find_existing($name);

  # Convert if necessary
  if ($exist && $exist ne $backend) {
    _convert($name, $exist, $backend);
  }

  # Create and return the database
  {
    no strict 'refs';
    &{"_c_$backend"}("$name.$beex{$backend}", $name, $fields, $indexes,
		   $sorter);
  }
}

=head2 _c_(backend)

These are broken out to allow autoloading to postpone compilation of the
database backends (some of which may fail on systems which don''t support
them.  Perhaps some use of eval and require would be better to trap errors.

=cut
use Mj::SimpleDB::Text;
sub _c_text {
  new Mj::SimpleDB::Text(@_);
}

=head2 _find_existing(path)

Finds existing databases named by the given path.  This just looks for
files with a certain set of extensions and takes the first one it finds.

Returns the backend and version.  Returns the special "none" if an old
untagged file is found.  Returns undef if the file simply doesn''t exist
under any backend.

The version isn''t used anywhere but is included in case it becomes useful.
When it is used, this will need to be rewritten to be less simplistic.

=cut
sub _find_existing {
  my $path = shift;

  # Handle no-extension case specially
  -f $path && return ('none', 0);

  for my $i (keys(%exbe)) {
    -f "$path.$i"  && return ($beex{$i}, 0);
  }
  return (undef, undef);
}

=head2 _convert(from, to)

Converts a database from one format to another.  For the case of 'none' to
'text', this is a simple renaming.  Otherwise the old database is exported
to a temporary file, the new database is created and the temporary file is
imported into it.  Finally the old database is renamed out of the way and
the new database is renamed to its final name.  The old database is
retained by appending .old and the extension to the given path.

XXX What about concurrency?  Multiple readers may come in while we''re
exporting or importing; in fact, anything can come in at any time.  One
solution is to not unlock the old database until after it is deleted.  (The
locking scheme will allow this).  Then make certain that the target
doesn''t exist after we''ve acquired a write lock.  Unfortunately the
databases lock themselves, so this won''t work.  Perhaps autoconversion is
a bad idea?

=cut

sub _convert {
  my $path = shift;
  my $from = shift;
  my $to   = shift;
  my $log = new Log::In 200, "$path, $from, $to";

  if ($from eq 'none' && $to eq 'text') {
    rename($path, "$path.$beex{'text'}");
  }

  # Create 'from' database

  # Open a temp file

  # Export to temp file

  # Close 'from' database

  # Create 

  1;
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

package Mj::FileSpace;

=head1 NAME

Mj::FileSpace.pm - Functions for manipulating a list''s file area

=head1 DESCRIPTION

This implements a FileSpace object, which encapsulates a piece of a
filesystem holding files accessibie through Majordomo.

Files can be retrieved, put, deleted, copied, renamed, or linked.  File
data can be set/changed.

Retrieval (get) involves returning a normal, fully qualified UNIX filename.
Optionally, an open handle can returned.  In addition, stored information
about the file is returned (content-type, content-transfer-encoding,
description).

Putting a file (put) involves opening the file for 'put' and passing in
important file information (description, content-type,
content-transfer-encoding), then successively putting chunks, then closing
the file.

Deleting a file simply removes the file and stored data about it.

Copying a file involves making a copy of the file and its data from another
list''s filespace.

Renaming a file changes its name without changing its data.

Linking a file involves making a symbolic of the file from another list''s
filespace and copying its data.

File permissions:
  R - world readable (gettable)
  w - writable by list owner
  ! - Majordomo doesn''t know about the file, or it does but the file isn''t
      alterable.

=head1 SYNOPSIS

blah

=cut

use strict;
use DirHandle;
use Symbol;
use Mj::Log;

=head2 new(dir)

This creates the FileSpace object in a directory, and makes the database in
which to store the files.

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;
  my $dir   = shift;
  my $back  = shift;
  my $self  = {};

  my $log = new Log::In(200, $dir);

  bless $self, $class;
  $dir =~ s|/$||;
  $self->{'dir'} = $dir;

  $self;
}

=head2 get(file, force)

This returns the complete path to a file, it''s description, content-type
and content-transfer-encoding, if it exists in the database, or undef
otherwise.

If the file does not have permission "R", force must be true.

If the file is really a directory, dir must be true.

=cut
sub get {
  my $self  = shift;
  my $file  = shift;
  my $force = shift;
  my $dir   = shift;
  my $log = new Log::In 150, $file;
  my $data;

  # Bail unless the file exists
  if ($dir) {
    return unless (-d "$self->{'dir'}/$file" && -r _);
  }
  else {
    return unless (-f "$self->{'dir'}/$file" && -r _);
  }

  $data = $self->getdata($file);

  if (($data->{'permissions'} !~ /R/ && !$force) ||
      $data->{'permissions'} eq '!' ||
      ($data->{'permissions'} eq 'd' && !$dir)) 
    {
      return;
    }

  if (wantarray) {
    return ("$self->{'dir'}/$file", %$data);
  }
  return "$self->{'dir'}/$file";
}

=head2 getdata(file)

This looks for a dotfile in the appropriate directory and loads it.  If no
dotfile is found, some default data is performed (so that files can be
copied in without difficulty).

=cut
sub getdata {
  my $self = shift;
  my $file = shift;
  my(@tmp, $data, $fh, $i, $line, $name, $path, $perm);

  $name = $self->_dotfile($file);
  $path = "$self->{'dir'}/$file";

  $perm = '!';
  $perm = 'd'  if (-d $path && -r $path);
  $perm = 'Rw' if (-f $path && -r $path);

  # Record the time at which the file was last modified.

  $data = {
	   'description' => '(none)',
	   'permissions' => $perm,
	   'c-type'      => $perm eq 'd' ? '(dir)' : 'text/plain',
	   'c-t-encoding'=> $perm eq 'd' ? '' : '8bit',
	   'charset'     => $perm eq 'd' ? '' : 'ISO-8859-1',
	   'language'    => $perm eq 'd' ? '' : 'en',
           'lastmod'     => (stat($path))[9],
	  };

  if ((-f $name || -d _) && -r _) {
    $fh = gensym();
    return unless (open($fh, "<$name"));
    for $i (qw(description permissions c-type charset c-t-encoding language)) {
      $line = <$fh>;
      last unless defined $line;
      chomp($line);
      $data->{$i} = $line if length($line);
    }
    close $fh;
  }

  # Force permissions on directories
  $data->{permissions} = 'd' if -d $path && -r $path;

  $data;
}

=head2 _dotfile(file)

This returns the full path to the dotfile corresponding to the provided
file (which should be the path relative to the filespace, not the full
path).

=cut
sub _dotfile {
  my $self = shift;
  my $file = shift;

  $file =~ m!^(.*/)?(.*?)/?$!;
  if (defined $1) {
    return "$self->{'dir'}/$1.$2";
  }
  return "$self->{'dir'}/.$2";
}

=head2 put(file, source, overwrite, description, content-type,
content-transfer-encoding, permissions)

This puts a file (copied from the source path) into the filespace and adds
the appropriate database entries.  The filename is checked for illegal
characters.  This returns truth on success.

If overwrite is true and the file exists, they will be put even if it does
not have permission "w".  (Unless, of course, it has permission "!", which
indicates a problem.)

If the source path is null, this creates the file id if did not already
exist.

The path of the new file is returned if this succeeds.  The file can be
locked and manipulated directly by the caller.

XXX Communicate errors better
XXX There is no locking here!

=cut
sub put {
  my $self = shift;
  my $file = shift;
  my $src  = shift;
  my $over = shift;
  my $desc = shift || "";
  my $type = shift || "text/plain";
  my $cset = shift || "ISO-8859-1";
  my $cte  = shift || "8bit";
  my $lang = shift || 'en';
  my $perm = shift || "Rw";
  my $log  = new Log::In 120, "$src, $file";
  my ($path, $oldperm, $data, $fh);

  # Check for legal name
  return (0, "Illegal file name.")
    unless $self->legal_file_name($file);

  $path = "$self->{'dir'}/$file";

  # If we were passed a file, check to see if file exists.
  if ($src) {
    if (-e $path ) {
      $oldperm = $self->get_permissions($file);
      return if $oldperm eq "!";
      if ($oldperm !~ /w/) {
	return unless $over;
      }
      return unless $self->delete($file);
    }
    # Copy in the file
    require File::Copy;
    File::Copy::cp($src, $path) ||
      $::log->abort("Mj::FileSpace::put failed copying file $src to $path, $!");
  }
  # Else were weren't passed a file, so we just make sure the destination
  # exists.
  else {
    $fh = gensym();
    open ($fh, ">>$path")
      or $::log->abort("Unable to open file $path: $!");
    close ($fh)
      or $::log->abort("Unable to close file $path: $!");
  }
  # Add database info
  $data =
    {
     'description' => $desc,
     'c-type'      => $type,
     'charset'     => $cset,
     'c-t-encoding'=> $cte,
     'permissions' => $perm,
     'language'    => $lang,
    };
  $self->putdata($file, $data);
  (1, $path);
}

=head2 putdata(file)

This creates a dotfile in the appropriate place and fills it with the provided data.

=cut
sub putdata {
  my $self = shift;
  my $file = shift;
  my $data = shift;
  my ($fh, $i, $name);

  $name = $self->_dotfile($file);
  $fh = gensym();
  return unless (open($fh, ">$name"));
  for $i (qw(description permissions c-type charset c-t-encoding language)) {
    $data->{$i} = '' unless defined $data->{$i};
    print $fh "$data->{$i}\n";
  }
  close ($fh)
    or $::log->abort("Unable to close file $name: $!");
}

=head2 put_start, put_chunk, put_done

An iterative interface to the put functions.  Note that put_start has the
same semantics as put, and will overwrite if necessary at the beginning;
the file will be created and entered into the database then and will exist
incomplete if the entire file is not deposited with put_chunk.  put_done
simply closes the file.

XXX There is no locking on puts!  There should be an option to lock or not;
   if file is single-use and unique then don''t lock.  Either that, or lock
   the entire FileSpace.

=cut
sub put_start {
  my $self = shift;
  my $file = shift;
  my $over = shift;
  my $desc = shift || "";
  my $type = shift || "text/plain";
  my $cset = shift || "ISO-8859-1";
  my $cte  = shift || "8bit";
  my $lang = shift || 'en';
  my $perm = shift || "Rw";
  my $force = shift || 0;
  my $log  = new Log::In 150, "$file, $desc";
  my ($data, $dir, $dpath, $ok, $oldperm, $mess, $path);

  # Check for legal name
  $file = $self->legal_file_name($file);
  return (0, "Illegal file name.\n")
    unless $file;
  $file =~ s#/+$##;

  # Trim off the trailing file part to get the directory
  ($dir = $file) =~ s![^/]*$!!;
  $dpath = "$self->{'dir'}/$dir";
  $path  = "$self->{'dir'}/$file";

  # Create directories as needed.
  unless (-e $dpath) {
    if ($force and length($dir) and ($dir ne $file)) {
      ($ok, $mess) = $self->mkdir($dir, '', 1);
      return ($ok, $mess) unless $ok;
    }
    else {
      return (0, "The directory \"$dir\" does not exist!\n")
    }
  }

  return (0, "Cannot put files in the \"$dir\" directory!\n")
    unless -w $dpath;

  # Check to see if file exists.  If it does?
  if (-e $path ) {
    $oldperm = $self->get_permissions($file);
    if ($oldperm !~ /w/) {
      return (0, "Cannot overwrite file.\n")
	unless $over;
    }
    return (0, "Cannot delete existing file!\n")
      unless $self->delete($file);
  }
  $self->{'fh'} = gensym();
  return (0, "Unable to open file.\n")
    unless (open ($self->{'fh'}, ">$path"));

  $data =
    {
     'description' => $desc,
     'c-type'      => $type,
     'charset'     => $cset,
     'c-t-encoding'=> $cte,
     'permissions' => $perm,
     'language'    => $lang,
    };
  $self->putdata($file, $data);
  1;
}

sub put_chunk {
  my $self  = shift;
  my $chunk = shift;
  return unless $self->{'fh'};
  print {$self->{'fh'}} $chunk;
}

sub put_done {
  my $self = shift;
  return unless $self->{'fh'};
  close ($self->{'fh'})
    or $::log->abort("Unable to close file: $!");
  $self->{'fh'} = undef;
  1;
}

=head2 mkdir (name, description, force)

The mkdir method creates a directory.  

If the force variable is set to a true value, parent directories will
also be created as needed.

=cut
sub mkdir {
  my $self  = shift;
  my $dir   = shift;
  my $desc  = shift || "(dir)";
  my $force = shift || 0;
  my $log   = new Log::In 150, "$dir, $desc";
  my ($base, $data, $dpath, $ok, $oldperm, $mess, $path);

  # Check for legal name
  $dir = $self->legal_file_name($dir);
  return (0, "Illegal file name.\n")
    unless $dir;

  # Trim off the trailing file part to get the directory
  ($base = $dir) =~ s![^/]*$!!;
  $base  =~ s!/+$!!;
  $dpath = "$self->{'dir'}/$base";
  $path  = "$self->{'dir'}/$dir";

  # Check to see if directory exists.  If it does?
  unless (-e $dpath) {
    if ($force and length($base) and ($base ne $dir)) {
      ($ok, $mess) = $self->mkdir($base, '', $force);
      return ($ok, $mess) unless $ok;
    }
    else {
      return (0, "The directory \"$base\" does not exist!\n")
    }
  }

  return (0, "Cannot put files in the \"$base\" directory!\n")
    unless -w $dpath;

  if (-e $path ) {
    $oldperm = $self->get_permissions($dir);
    if ($oldperm =~ /d/ || ($oldperm =~ /!/ && -d $path)) {
      unlink $self->_dotfile($dir);
    }
    else {
      return (0, "Cannot overwrite a file with a directory!\n");
    }
  }

  # Make the directory if it doesn't exist
  else {
    mkdir($path, 0770) || return (0, "Can't make directory: $!");
  }

  $data =
    {
     'description' => $desc,
     'permissions' => 'd',
    };
  $self->putdata($dir, $data);

  1;
}

=head2 delete(file, force)

This deletes a file or directory.  If the permissions do not include "w", 
the force option must be given.  If the permissions are "!", nothing will 
be done.  If the file does not exist, nothing will be done.

Directories that are not empty will not be removed unless the
force variable is set.

=cut
sub delete {
  my $self  = shift;
  my $file  = shift;
  my $force = shift;
  my $log   = new Log::In 150, $file;
  my ($mess, $ok, $perms, $path);
  
  # Check for legal name
  return (0, qq(Illegal file name: "$file"\n))
    unless $self->legal_file_name($file);

  $path = "$self->{'dir'}/$file";

  return (0, qq("/$file" does not exist.\n))
    unless (-e $path);

  return (0, qq("/$file" is not a plain file or directory.\n))
    unless (-f $path or -d $path);

  $perms = $self->get_permissions($file);
  return (0, qq(The file "$file" cannot be deleted.\n))
    if $perms eq "!";

  if (-f $path or -l $path) {
    return (0, qq(The file "$file" must be deleted by force.\n))
      if ($perms !~ "w" and !$force);
    return (0, qq(Unable to remove file "$file": $!\n))
      unless (unlink $path);
  }
  elsif (-d $path) {
    return (0, qq(The directory "$file" must be deleted by force.\n))
      if ($perms !~ "d" and !$force);
    if ($force) {
      ($ok, $mess) = &_empty_dir($path);
      return ($ok, $mess)
        unless $ok;
      return (0, qq(Unable to remove directory "$file" completely: $!\n))
        unless (rmdir $path);
    }
    else {
      return (0, qq(Unable to remove directory "$file": $!\n))
        unless (rmdir $path);
    }
  }
  unlink $self->_dotfile($file); # Don't complain if it wasn't there
  return 1;
}

=head2 _empty_dir(dir)

This function recursively removes the contents of a directory.

=cut
sub _empty_dir {
  my $dir = shift;
  my $depth = shift;
  my $log  = new Log::In 210, $dir;
  my ($dirh) = gensym();
  my ($file, $mess, $ok);

  $depth++;

  # arbitrary attempt to avoid loops.
  return (0, "Directory depth 100 exceeded.\n")
    if ($depth > 100);

  opendir ($dirh, $dir) 
    or return (0, qq(Cannot open directory "$dir": $!\n));
  while (defined($file = readdir($dirh))) {
    next if ($file eq '.' or $file eq '..');
    $file =~ /(.*)/; $file = $1;

    if (! -d "$dir/$file") {
      return (0, qq(Cannot unlink "$file": $!\n))
        unless (unlink "$dir/$file");
    }
    else {
      ($ok, $mess) = &_empty_dir("$dir/$file", $depth);
      return ($ok, $mess)
        unless $ok;
      return (0, qq(Cannot remove directory "$file": $!\n))
        unless (rmdir "$dir/$file");
    }
  }
  closedir $dirh;
  return (1, '');
}


=head2 get_permissions(file)

This retrieves the permissions string for a file.  If the file is not in
the database, the '!' permission is returned.

=cut
sub get_permissions {
  my $self = shift;
  my $file = shift;
  my $log  = new Log::In 210, "$file";
  my $data = $self->getdata($file);
  return $data->{'permissions'};
}  

=head2 index

Retrieves from the database a list of (file perm desc type enc size) sets.
Directories will be included unless $nodirs is true; their type will be
"(dir)".  Directories will be expanded recursively if $recurse is true.

Nothing will be sorted.

=cut
sub index {
  my $self    = shift;
  my $dir     = shift;
  my $nodirs  = shift;
  my $recurse = shift;
  my $log = new Log::In 200, "$dir";
  my (@files, @out, $data, $file, $i, $name);

  return (0, qq(The directory "$dir" does not exist.\n))
    unless (-d "$self->{'dir'}/$dir");

  @files = $self->_find_legal_files("$self->{'dir'}/$dir", !$recurse);
  return (0, qq(The directory "$dir" is empty.\n))
    unless (scalar @files);

  for $file (@files) {
    # Add the file data unless it's a directory and we don't want them or
    # it's a file in a directory (contains something after a slash) and we
    # don't want to recurse.
    $name = "$dir/$file";
    $data = $self->getdata($name);
    next unless $data; 

    # Tack on a visible identifier of a directory
    $file .= '/' if $data->{'permissions'} eq 'd';
    unless (($nodirs && $data->{'permissions'} eq 'd') ||
	    (!$recurse && $file =~ m!/.+!))
      {
        $data->{'file'} = $file;
        $data->{'size'} = (stat("$self->{'dir'}/$name"))[7];
	push @out, $data;
      }
  }
  (1, @out);
}

=head2 legal_file_name(string)

This returns the untainted file name if it is legal to store in a
filespace.  Currently illegal things are a leading '/', '//' anywhere and
'..'  anywhere.

=cut
sub legal_file_name {
  my $self = shift;
  my $file = shift;
  
  return if $file =~ m|^/|;   # No leading slashes
  return if $file =~ m|^\.|;  # No leading dots (reserved for dotfiles
  return if $file =~ m|//|;   # No double-slashes (just in case)
  return if $file =~ m|\.\.|; # No double-dots (attempt to escape up)
  return if $file =~ m|\\|;   # No backslashes (DOS?)
  return if $file =~ m|/\.|;   # No leading dot after a directory.

  $file =~ /(.*)/; # Untaint; we've decided it's OK.
  return $1;
}

=head2 find_legal_files

Since File::Find isn''t taint-clean, we have to roll our own.  We can be
pretty simplistic, though.

If $flat is true, we won''t recurse.

=cut

sub _find_legal_files {
  my $self = shift;
  my $dir  = shift;
  my $flat = shift;
  my $pre  = shift || "";
  my $log  = new Log::In 200, "$dir, $pre";
  my (@out, $ent);
 
  return unless (-d $dir);
 
  my $dh = new DirHandle $dir;
  return unless $dh;
  while (defined($ent = $dh->read)) {
    # Skip what we want to ignore.
    next if $ent =~ /^[._]/;
    push @out, "$pre$ent";
    if (-d "$dir/$ent") {
      next if $flat;
      push @out, $self->_find_legal_files("$dir/$ent", 0, "$pre$ent/");
    }
  }
  @out;
}


=head1 COPYRIGHT

Copyright (c) 1997, 1999, 2002 Jason Tibbitts for The Majordomo Development
Group.  All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the license detailed in the LICENSE file of the
Majordomo2 distribution.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the Majordomo2 LICENSE file for more
detailed information.

=cut

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

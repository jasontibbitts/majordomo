package Mj::FileRepl;

use strict;
use IO::File;
use Mj::Lock;
use Mj::Log;
use Safe;
use vars qw($AUTOLOAD $VERSION $safe);

=head1 NAME

Mj::FileRepl - Safe file replacement operations


=head1 DESCRIPTION

These functions implement the FileRepl class.  For reasons of speed, this
ignores that fact that Mj::File exists.  This saves an extra jump through
the AUTOLOAD function to implement proxied methods, and it lets us avoid
locking the replacement file since it isn''t necessary.

The downside is that we most duplicate some code, including a significant
chunk in open.

The trick to this object is that output goes to the new file, while reads
and other file operations go to the old file.  This, like the locking, is
handled transparently.

=head1 SYNOPSIS

blah

=head2 new

Allocates an Mj::FileRepl object.  If given parameters, calls open.

=cut
sub new {
  my $type = shift;
  my $class = ref($type) || $type;

  $::log->in(150);
  
  my $self = {};
  $self->{'oldhandle'} = new IO::File;
  $self->{'newhandle'} = new IO::File;
  bless $self, $class;

  if (@_) {
    $self->open(@_);
  }
  $::log->out;
  $self;
}

=head2 DESTROY

A simple destructor which abandons any replacement in progress.  It''s safer
to abandon in case the program takes an exception before a commit.

=cut
sub DESTROY {
  my $self = shift;

  $::log->in(150, $self->{'name'});
  if ($self->{'open'}) {
    $self->abandon;
  }
  $::log->out;
  1;
}

=head2 AUTOLOAD

This implements all other IO methods by proxy.  We take the stance that
everything we don''t explicitly define should happen to the original file,
though it may prove smarter to have a table of actions and which handle
they should act on.  It may also be useful to allow specification of which
handle os operated on.  For now, though we assume that the new file will
only be written, while any seeks will occur in the old file.

=cut
sub AUTOLOAD {
  my $self = shift;
  my $name = $AUTOLOAD;
  $name =~ s/.*://; 
#  my $log = new Log::In 200, "$name";
  
  unless ($self->{'oldhandle'}->can($name)) {
    $::log->abort("Attempting to call unimplemented function by proxy");
  }
  
  if (wantarray) {
    my @out = $self->{'oldhandle'}->$name(@_);
    @out;
  }
  else {
    my $out = $self->{'oldhandle'}->$name(@_);
    $out;
  }
}

=head2 open(name, mode)

This locks (exclusively) and opens the old file, and opens a unique
temporary file (unlocked, since it''s unique) which will be moved into
place if the operation is committed.  The source file will be created if it
does not exist.

=cut
sub open {
  my $self   = shift;
  my $name   = shift;
  my $lock   = shift || $name;
  
  $::log->in(110, "$name");

  my $tempname = _tempname($name);
  $self->{'lock'} = new Mj::Lock($lock, "exclusive");

  # We have a lock now; the file is ours to do with as we please.
  # First, create the old file if it doesn't exist.
  unless (-f $name) {
    $self->{'oldhandle'}->open(">> $name");
    $self->{'oldhandle'}->close;
  }
  # Now get down to business
  $self->{'oldhandle'}->open("+< $name") ||
    $::log->abort("Couldn't open $name, $!");
  $self->{'newhandle'}->open("+> $tempname") ||
    $::log->abort("Couldn't open $tempname, $!");

  $self->{'name'}     = $name;
  $self->{'tempname'} = $tempname;
  $self->{'open'}     = 1;

  $::log->out;
  1;
}

=head2 close

This is an illegal operation; because of the sensitive nature of the
replace operation, the programmer must explicitly call commit.  If the
FileRepl object goes out of scope, abandon will be called automatically.

=cut
sub close {
  $::log->abort("Cannot close a FileRepl object.");
}

=head2 commit(count)

This commits a previously started replace operation by moving the old file
to a temporary save, then moving the new in its place, then deleting the
old file and closing and unlocking everything.

This can optionally check to make sure that the file sizes come out to be
correct; if given a count, this will make sure that the files differ by
exactly count bytes before deleting anything.  If the counts differ, an
abandon will be carried out and the original file will remain unchanged.

The counting stuff is not yet implemented.

=cut
sub commit {
  my $self  = shift;
  my $count = shift;

  $::log->in(110, "$self->{'name'}");

  unless ($self->{'open'}) {
    $::log->abort("Mj::FileRepl::commit called on unopened object");
  }

  my $name     = $self->{'name'};
  my $savename = _savename($self->{'name'});
  my $tempname = $self->{'tempname'};

  # We link the old file to save it, then move the new one on top of the
  # old one.  This should guarantee that the file always exists, and that
  # there is always a consistent file in case something dies in the middle.
  # The locking must continue to work when we rename files.
  link($name, $savename)
    || $::log->abort("Couldn't link $name to $savename: $!");
  rename($tempname, $name)
    || $::log->abort("Couldn't rename $tempname to $name: $!");
  unlink($savename)
    || $::log->abort("Couldn't unlink $savename: $!");

  $self->{'oldhandle'}->close;
  $self->{'newhandle'}->close;
  $self->{'lock'}->unlock;

  delete $self->{'open'};
  $::log->out;
  1;
}

=head2 abandon

This abandons a previously started replace operation by deleting the new
file (which is being abandoned) and closing and unlocking everything.

=cut
sub abandon {
  my $self = shift;

  $::log->in(110, "$self->{'name'}");

  unless ($self->{'open'}) {
    $::log->abort("Mj::FileRepl::abandon called on unopened object");
  }

  my $tempname = $self->{'tempname'};
  unlink($tempname)
    || $::log->abort("file_replace_abandon couldn't unlink $tempname, $!");
  
  $self->{'oldhandle'}->close;
  $self->{'newhandle'}->close;
  $self->{'lock'}->unlock;
  
  delete $self->{'open'};
  $::log->out;
  return 1;
}

=head2 print(list)

We want print to be the exception in that it operates on the new file, not
the old one.  So we include a special function for it here.

=cut
sub print {
  my $self = shift;

  $self->{'newhandle'}->print(@_);
}

=head2 copy

This just copies the old file to the new file quickly.  Since this doesn''t
reset the file positions before it starts, it can be used to quickly copy
the rest of a file after a manipulation has been done.

This manipulates the internal filehandles directly.

=cut
sub copy {
  my $self = shift;
  my $line;

  while (defined($line = $self->{'oldhandle'}->getline)) {
    $self->{'newhandle'}->print($line);
  }
  1;
}

=head2 search_copy (...)

This is a useful companion to File::search; it runs through the FileRepl
object making a copy of it until it encounters a matching line, at which it
returns it without printing it.  If there is no match, this routine will
have (perhaps uselessly) copied the entire file.  This routine should not
be used to add lines to a file; just use a normal File object open in
append mode, or read+write mode instead.

This, like File::search, manipulates its internal filehandles itself.

=cut
sub search_copy {
  my $self = shift;
  my ($line, $re, $sub, $temp);

  $::log->in(110, "@_");
  if (ref $_[0] eq 'CODE') {
    $sub = shift;
    while ($_ = $self->{'oldhandle'}->getline) {
      chomp;
      $temp = &$sub($_);
      return $temp if defined $temp;
      $self->{'newhandle'}->print("$_\n");
    }
    $::log->out;
    return undef;
  }
  # Else we weren't passed a subroutine.
  while ($line = $self->{'oldhandle'}->getline) {
    for $re (@_) {
      if (Majordomo::_re_match($re, $line)) {
        $::log->out;
        return $line;
      }
    }
    $self->{'newhandle'}->print("$line");
  }
  $::log->out;
  return undef;
}

=head2 search

This just calls search_copy.

=cut
sub search {
  shift->search_copy(@_);
}

=head2 _tempname, _savename  (PRIVATE)

Returns the name of a temporary file (or temporary save file) based on the
given filename.  Must make certain that the new file is on the same
filesystem as the old file, so that one can be renamed to the other (so no
use of $TMPDIR).

 In:  filename
 Out: temporary/save filename

=cut

sub _tempname {
  my $name = shift;
  $name =~ m|^(.*/)?(.*)$|;
  return ($1 || "") . ".T" . $2 . $$;
}

sub _savename {
  my $name = shift;
  $name =~ m|^(.*/)?(.*)$|;
  return ($1 || "") . ".S" . $2 . $$;
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

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

package Mj::Lock;

=head1 NAME

Mj::Lock - Simple locking primitives for Majordomo


=head1 SYNOPSIS

To obtain exclusive access to /tmp/file:

 use Mj::Lock;
 $lock = new Mj::Lock("/tmp/file", "exclusive");

   Critical section

 $lock->unlock;


=head1 DESCRIPTION

This file contains a simple flock-based locking system.  Yes, it doesn''t
work over NFS.  You deserve what you get if you try to run Majordomo over
an NFS-mounted filesystem.  I do not know how this survives on odd
verisions of UNIX and on things like NT.  It should be relatively trivial
to replace these routines with some that work on other systems.

Note that to be absolutely bulletproof this will leave a dropping file for
each file locked.  For Majordomo''s use this is not a problem.  If someone
knows a way around this, please let me know.

This has been tested under serious load (100s of simultaneous pending
locks).

 lock      - locking functions
 unlock

=cut
use strict;
use Fcntl qw(:flock);
use Symbol;

# This gets Time::HiRes if available, or uses crappy resolution timers if
# not
BEGIN {eval {require Time::HiRes; import Time::HiRes qw(time);}}

=head2 new

Simple constructor.  Calls lock if passed parameters.

=cut
sub new {
  my $proto = shift;

  $::log->in(150);

  my $class = ref($proto) || $proto;
  my $self = {};
  bless $self, $class;
  if (@_) {
    $self->lock(@_);
  }
  $::log->out;
  return $self;
}

=head2 DESTROY

Simple destructor.  Just calls unlock.

=cut
sub DESTROY {
  my $self = shift;
  $::log->in(150);

  if ($self->{'handle'}) {
    $self->unlock;
  }
  $::log->out;
}

=head2 lock(name, mode, noblock)

Opens a lockfile and calls flock to lock it.  This doesn''t actually
operate on the file itself, because we have other operations that may move
or delete the actual file and the flock semantics of requiring an open
filehandle make that work badly.  So we lock an associated file instead.

 name - the name of the file to lock (not the name of the lockfile)
 node - a string describing the mode, one of "Read", "Write", "Shared",
        "Exclusive" (case-insensitive, only the first letter is
        significant.  R and S are equivalent, as are W and E.
 noblock - a flag; should the lock be non-blocking?

XXX noblock is not fully supported

=cut
sub lock {
  my $self    = shift;
  my $name    = shift;
  my $mode    = shift;
  my $noblock = shift;
  my $handle  = gensym();
  my $mhandle = gensym();
  my ($lm, $lname, $mname, $out);

  $::log->in(140, "$name, $mode");
  if ($mode =~ /^[rs]/i) {
    $lm = LOCK_SH;
  }
  elsif ($mode =~ /^[we]/i) {
    $lm = LOCK_EX;
  }
  else {
    $::log->abort("Mj::Lock::lock called with illegal mode $mode");
  }

  if ($noblock) {
    $lm |= LOCK_NB;
  }
  
  ($lname, $mname) = _name($name);

  if ($mname) {
    open($mhandle, "+> $mname") || $::log->abort("Couldn't open lockfile $mname, $!");
    $out = flock($mhandle, LOCK_SH);
  }
  open($handle, "+> $lname") || $::log->abort("Couldn't open lockfile $lname, $!");
  $out = flock($handle, $lm);

  # Here check for EWOULDBLOCK and return undef, else abort on error.

  if ($mname) {
    $self->{'master_handle'} = $mhandle;
    $self->{'master_name'}   = $mname;
  }
  $self->{'handle'} = $handle;
  $self->{'lname'}  = $lname;
  $self->{'ltime'}  = time();

  $::log->out("locked");
  return 1;
}

=head2 unlock()

Calls flock to unlock a file.

=cut
sub unlock {
  my $self = shift;
  my ($elapsed);

  $::log->in(140, "$self->{'lname'}");
  
  unless ($self->{'handle'}) {
    $::log->abort("Mj::Lock::unlock called on unlocked object.");
  }

  close $self->{'handle'};
  close $self->{'master_handle'} if $self->{'master_handle'};
  
  # Removing the lock file at any time seems to completely hose things on
  # some platforms.
  #unlink $self->{lname} ||
  #  $::log->abort("Failed unlinking $self->{lname}, $!");

  $elapsed = sprintf("%.3f", (time() - $self->{'ltime'}));

  delete $self->{'handle'};
  delete $self->{'master_handle'};
  delete $self->{'ltime'};

  $::log->out("done (held for $elapsed sec)");
  return 1;
}

=head2 expire_locks

This is a function (not a method) which expires locks.  Because just
allocating a Majordomo object and connecting will cause the global lock to
be held, this has to be called directly.  It''s part of this module to keep
the details hidden.

=cut
sub expire_locks {
  my $handle = gensym();
  my ($file, $mname, $ok);
  $::log->in(200);
  $mname = _name();
  unless ($mname) {
    $::log->out('failed');
    return undef;
  }
  open($handle, "+> $mname") || $::log->abort("Couldn't open lockfile $mname, $!");
  $ok = flock($handle, LOCK_EX);
  # Just get the filename; we want to ignore it when deleting
  $mname =~ s/^.*\///;

  opendir DIRH, $::LOCKDIR || return undef;
  while (defined($file = readdir(DIRH))) {
    $file =~ /(.*)/;  $file = $1;
    unlink "$::LOCKDIR/$file"
      unless ($file eq $mname || $file =~ /^\./ || $file eq 'mj_queueserv.lock');
  }
  closedir(DIRH);
  close $handle; # Release global lock
  $::log->out;
  1;
}

=head2 _name (private)

This returns the name of the lockfile associated with a file.  If given a
path, the path components are preserved intact.

If the global $::LOCKDIR is defined and nonempty, locks will be created
there by concatenating all of the path components and the filename with
underscores.  This could possibly lead to problems with line length;
filenames generated in this manner will be trimmed to 128 characters.  The
name of the master lockfile will also be returned.)

Otherwise the lockfile will be named by prepending .L to the filename, in
the same directory.  There is no master lockfile in this case (making the
non-LOCKDIR situation rather non-optimal).  A test-and-sleep locking
situation may be better for that case.

If the provided name is undefined, it is assumed that the name of the
master lock is required and it is retured if possible.  If not, undef is
returned.

=cut
sub _name {
  my $name = shift;
  my $n;

  # If asked for the master lock, return it if we can
  unless ($name) {
    if ($::LOCKDIR) {
      return "$::LOCKDIR/master.lock";
    }
    return undef;
  }

  # Special processing if we have LOCKDIR
  if ($::LOCKDIR && -d $::LOCKDIR) {
    ($n = $name) =~ s/\//_/g;
    $n = substr($n, -128);
    return ("$::LOCKDIR/$n", "$::LOCKDIR/master.lock");
  }

  $name =~ m|^(.*/)?(.*)$|;
  return (($1 || "") . ".L" . $2);
}

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

1;
#
### Local Variables: ***
### mode:cperl ***
### cperl-indent-level:2 ***
### End: ***

=head1 NAME

Mj::List.pm - Majordomo list object

=head1 SYNOPSIS

  $list = new Mj::List;
  $list->add('force', "nobody@nowhere.com");

=head1 DESCRIPTION

This contains code for the List object, which encapsulates all per-list
functionality for Majordomo.

A list owns a Config object to maintain configuration data, a
SubscriberList object to store the list of subscribers and their data, an
AliasList object to keep track of address aliases, various AddressList
objects, an Archive object, and a Digest object handling all archiving and
digesting aspects of the list.

=cut

package Mj::List;
use AutoLoader 'AUTOLOAD';

use strict;
use Safe;  # For evaluating the address transforms
use Mj::File;
use Mj::FileRepl;
use Mj::SubscriberList;
use Mj::AddressList;
use Mj::AliasList;
use Mj::Config qw(global_get parse_table);
use Mj::Addr;
use Mj::Log;
use vars (qw($addr %flags %noflags %classes));

# Flags -> [realflag, inverted (2=intermediate), invertible, flag]
%flags = 
  (
   'ackall'       => ['ackall',       0,0,'A'],
   'ackimportant' => ['ackimportant', 2,0,'a'],
   'selfcopy'     => ['selfcopy',     0,1,'S'],
   'hideall'      => ['hideall',      0,0,'H'],
   'hideaddress'  => ['hideall',      2,0,'h'],
   'showall'      => ['hideall',      1,0,'' ],
   'eliminatecc'  => ['eliminatecc',  0,1,'C'],
  );

# Special inverse descriptions
%noflags =
  (
   'showall' => 'H',
   'noack'   => 'A',
  );


# Classes -> [realclass, takesargs, description]
%classes =
  (
   'each'     => ['each',   0, "each message"],
   'single'   => ['each',   0],
   'high'     => ['each',   0, "messages at high priority"],
   'all'      => ['all',    0, "all list traffic"],
   'digest'   => ['digest', 2, "messages in a digest"],
   'nomail'   => ['nomail', 1, "no messages"],
   'vacation' => ['nomail', 1],
  );

=head2 new(name, separate_list_dirs)

Creates a list object.  This doesn't check validity or load any config
files (though the later is because the config files load themselves
lazily).  Note that this doesn't create a list; it just creates the object
that is used to hold information about an existing list.

=cut
sub new {
  my $type  = shift;
  my $name  = shift;
  my $ldir  = shift;
  my $sdirs = shift;
  my $av    = shift;
  my $class = ref($type) || $type;
  my $log   = new Log::In 150, "$ldir, $name";

  my ($alifile, $subfile);

  my $self = {};
  bless $self, $class;

  $self->{'name'}  = $name;
  $self->{'sdirs'} = $sdirs;
  $self->{'ldir'}  = $ldir;
  $self->{'av'}    = $av;
  $self->{'auxlists'} = {};

  if ($sdirs) {
    $subfile = $self->_file_path("_subscribers");
    $alifile = $self->_file_path("_aliases");
    $self->{'subs'} = new Mj::SubscriberList $subfile
      unless $name eq "GLOBAL";
    $self->{'aliases'}= new Mj::AliasList $alifile;
  }

  # Backwards compatibility?  Use some simple list of addresses.
  else {
    $subfile = $self->_file_path($self->{'name'});
  }

  $self->{'config'} = new Mj::Config $name, $ldir, $sdirs, $av;
  $self;
}

=head2 DESTROY (unfinished)

This should close any open thingies and generally make sure we flush
everything, update everything, etc.

=cut
sub DESTROY {
  return 1;
}

=head2 _file_path (private)

This returns the path to the lists'' directory.  If given a name, returns
the full path to that name.  Note that the path returned depends on the
global variable separate_list_dirs.

This is used by the constructor, so it should be before the __END__ token.

=cut
sub _file_path {
  my $self = shift;
  my $file = shift || "";

  if ($self->{'sdirs'}) {
    return "$self->{'ldir'}/$self->{'name'}/$file";
  }
  else {
    return "$self->{'ldir'}/$file";
  }
}

1;
__END__

#################################

=head1 Subscriber list operations

These functions operate on the subscriber list itself.

=head2 add(mode, address, class, flags)

Adds an address to the subscriber list.  The canonical form of the address
is generated for the database key, and the other subscriber data is
computed and stored in a hash which is passed to SubscriberList::add.

This passes out the return of SubscriberList::add, which is of the form
(flag, data) where data holds a ref to the subscriber data if there was a
failure due to an existing entry.

=cut
sub add {
  my $self  = shift;
  my $mode  = shift || '';
  my $addr  = shift;
  my $class = shift || $self->default_class;
  my $carg  = shift || '';
  my $flags = shift || $self->default_flags; 
  my (@out, $i, $caddr, $saddr, $ok, $data);

  $::log->in(120, "$mode, $addr");

  ($ok, $saddr, undef) = $self->{'av'}->validate($addr);
  $::log->abort("Attempt to add invalid address: $addr, $saddr")
    unless $ok;
  
  # Transform address and look up aliases.
  $caddr = $self->canon($saddr);

  $data = {
	   'fulladdr'  => $addr,
	   'stripaddr' => $saddr,
	   'subtime'   => time,
	   # Changetime handled automatically
	   'class'     => $class,
	   'classarg'  => $carg,
	   'flags'     => $flags,
	  };
  
  @out = $self->{'subs'}->add($mode, $caddr, $data);
  $::log->out;
  @out;
}

=head2 remove(mode, address)

Removes addresses from the main list.  Everything at "add" applies.  This
also removes any aliases which target the address being removed.

=cut
sub remove {
  my $self = shift;
  my $mode = shift;
  my $addr = shift;
  my (@removed, @out, $ok, $i);

  unless ($mode =~ /regex/) {
    ($ok, $addr, undef) = $self->{'av'}->validate($addr);
    # Whorf unless $ok?

    $addr = $self->canon($addr);
  }

  @out = $self->{'subs'}->remove($mode, $addr);
  
  # Now we have to go over the removed addresses (since we could have nuked
  # several with a regexp) and nuke all of the aliases for each one.
  # Unfortunately I can't walk an array by pairs without modifying it or
  # using this weird for loop.
  for ($i=0; $i<@out; $i+=2) {
    # If the target exists as an alias, it must be the bookkeeping alias
    # (else we screwed up, and we should nuke it anyway)
    if ($self->alias_lookup($out[$i])) {
      $self->alias_reverse_remove($out[$i]);
    }
  }
  @out;
}

=head2 is_subscriber(addr)

Returns the subscriber data if the address subscribes to the list.

=cut
sub is_subscriber {
  my $self = shift;
  my $addr = shift;
  my ($out, $ok);

  $::log->in(170, "$self->{'name'}, $addr");

  ($ok, $addr, undef) = $self->{'av'}->validate($addr);
  if ($ok) {
    $addr = $self->canon($addr);
    $out = $self->{'subs'}->lookup($addr);
    if ($out) {
      $::log->out("yes");
      return $out;
    }
  }
  $::log->out("no");
  return;
}

=head2 set(addr, setting, arg)

This sets various subscriber data.

=cut
sub set {
  my $self = shift;
  my $addr = shift;
  my $set  = shift;
  my $arg  = shift;
  my $log  = new Log::In 150, "$addr, $set";
  my ($data, $dig, $inv, $isflag, $key, $mime, $rset, $subflags, $time);

  ($inv = $set) =~ s/^no//;

  if ($rset = $flags{$set}->[0] || $flags{$inv}->[0]) {
    $isflag = 1;
  }
  elsif ($rset = $classes{$set}->[0]) {
    $isflag = 0;
  }
  else {
    $log->out("failed, invalidaction");
    return (0, "Invalid setting: $set.\n"); # XLANG
  }
  
  # Grab subscriber data (this handles aliasing internally)
  ($key, $data) = $self->get_member($addr);

  unless ($data) {
    $log->out("failed, nonmember");
    return (0, "$addr is not a subscriber.\n"); # XLANG
  }

  if ($isflag) {
    # Process flag setting; remove the flag from the list
    $data->{'flags'} =~ s/$flags{$rset}->[3]//ig;

    # Add the new flag (which may be null)
    $data->{'flags'} .= $flags{$set}->[3] || '';
    
  }
  else {
    # Process class setting
    $data->{'classarg'} = '';
    if ($classes{$rset}->[1] == 0) {
      $data->{'class'} = $rset;
    }
    elsif ($classes{$rset}->[1] == 1) {
      # Convert arg to time;
      if ($arg) {
	$time = _str_to_time($arg);
	return (0, "Invalid time $arg") unless $time; # XLANG
	$data->{'classarg'} = $time;
      }
      $data->{'class'} = $rset;
    }
    elsif ($rset eq 'digest') {
      # Process the digest data and pick apart the class
      $dig = $self->config_get('digests');
      if ($arg) {
	if ($arg =~ /(.*)-(.*)/) {
	  $arg = $1;
	  $mime = (lc($2) eq 'mime') ? 1 : 0;
	}
	return (0, "Illegal digest name: $arg.\n") # XLANG
	  unless $dig->{$arg};
      }
      else {
	$arg  = $dig->{'default_digest'};
      }
      $mime = $self->{'digest_data'}{$arg}{'mime'} unless defined $mime;
      $data->{'class'} = "$rset-$arg-" . ($mime ? "mime" : "nomime");
    }
  }
  $self->{'subs'}->replace("", $key, $data);
  1;
}

=head2 make_setting

This takes a string and a flag list and returns a class, a class argument,
and a new flag list which reflect the information present in the string.

=cut
sub make_setting {
  my $self  = shift;
  my $str   = shift;
  my $flags = shift;
  my $log   = new Log::In 150, "$str, $flags";
  my($arg, $class, $classarg, $dig, $i, $inv, $isflag, $mime, $rset, $set,
     $time);

  # Split the string on commas; discard empties.  XXX This should probably
  # ignore commas within parentheses.
  for $i (split("\s*,\s*", $str)) {
    next unless $i;
    
    # Deal with digest-(arg with spaces)
    if ($i =~ /(\S+?)\-\((.*)\)/) {
      $set = $1;
      $arg = $2;
    }
    elsif ($i =~ /(\S+?)-(\S+)/) {
      $set = $1;
      $arg = $2;
    }
    else {
      $set = $i;
      $arg = "";
    }
    
    ($inv = $set) =~ s/^no//;
    
    if ($rset = $flags{$set}->[0] || $flags{$inv}->[0]) {
      $isflag = 1;
    }
    elsif ($rset = $classes{$set}->[0]) {
      $isflag = 0;
    }
    else {
      $log->out("failed, invalidaction");
      return (0, "Invalid setting: $set"); # XLANG
    }
    
    if ($isflag) {
      # Process flag setting; remove the flag from the list
      $flags =~ s/$flags{$rset}->[3]//ig;
      
      # Add the new flag (which may be null)
      $flags .= $flags{$set}->[3] || '';
    }
    else {
      # Process class setting
      $classarg = '';
      if ($classes{$rset}->[1] == 0) {
	$class = $rset;
      }
      elsif ($classes{$rset}->[1] == 1) {
	# Convert arg to time;
	if ($arg) {
	  $classarg = _str_to_time($arg);
	  return (0, "Invalid time $arg") unless $classarg; # XLANG
	}
	$class = $rset;
      }
      elsif ($rset eq 'digest') {
	# Process the digest data and pick apart the class
	$dig = $self->config_get('digests');
	if ($arg) {
	  if ($arg eq 'mime') {
	    $arg = $dig->{'default_digest'};
	    $mime = 1;
	  }
	  elsif ($arg eq 'nomime') {
	    $arg = $dig->{'default_digest'};
	    $mime = 0;
	  }
	  elsif ($arg =~ /(.*)-(.*)/) {
	    $arg = $1;
	    $mime = (lc($2) eq 'mime') ? 1 : 0;
	  }
	  return (0, "Illegal digest name: $arg") # XLANG
	    unless $dig->{$arg};
	}
	else {
	  $arg  = $dig->{'default_digest'};
	}
	$mime = $dig->{$arg}{'mime'} unless defined $mime;
	$class = "digest-$arg-" . ($mime ? "mime" : "nomime");
      }
    }
  }
  return (1, $class, $classarg, $flags);
}

=head2 _str_to_time(string)

This converts a string to a time.

=cut
sub _str_to_time {
  my $arg = shift;
  my $log = new Log::In 150, "$arg";
  my($time);

  if ($arg =~ /(\d+)d(ays?)?/) {
    $time = time + (86400 * $1);
  }
  elsif ($arg =~ /(\d+)w(eeks?)?/) {
    $time = time + (86400 * 7 * $1);
  }
  elsif ($arg =~ /(\d+)m(onths?)?/) {
    $time = time + (86400 * 30 * $1);
  }
  else {
    # We try calling Date::Manip::ParseDate
    $time = _str_to_time_dm($arg);
  }
  $time;
}

=head2 _str_to_time_dm(string)

Calls Date::Manip to convert a string to a time; this is in a separate
function because it takes forever to load up Date::Manip.  Autoloading is
good.

=cut
use Date::Manip;
sub _str_to_time_dm {
  my $arg = shift;
  $Date::Manip::PersonalCnf="";
  return UnixDate(ParseDate($arg),"%s");
}

=head2 default_class

This returns the default subscription class for new subscribers.

This should be a per-list variable.

=cut
sub default_class {
  return "each";
}

=head2 default_flags

This returns the default flags (as a string) for new subscribers.

This should be a per-list variable, or a whole set of list variables.

=cut
sub default_flags {
  my $self = shift;
  return $self->config_get('default_flags');
}

=head2 flag_set(flag, address)

Returns true if the address is a subscriber and has the given flag set.

=cut
sub flag_set {
  my $self = shift;
  my $flag = shift;
  my $addr = shift;
  my $log  = new Log::In 150, "$flag, $addr";
  my ($flags, $data);
  return unless $flags{$flag};
  $data = $self->is_subscriber($addr);
  if ($data) {
    $flags = $data->{flags};
  }
  else {
    $flags = $self->config_get('nonmember_flags');
  }
  return unless $flags =~ /$flags{$flag}[3]/;
  1;
}

=head2 describe_flags(flag_string)

This returns a list of strings which give the names of the flags set in
flag_string.

=cut
sub describe_flags {
  my $self   = shift;
  my $flags  = shift || "";
  my %nodesc = reverse %noflags;
  my (%desc, @out, $i, $seen);

  for $i (keys %flags) {
    $desc{$flags{$i}->[3]} = $i if $flags{$i}->[3];
  }

  $seen = "";
  for $i (sort keys %desc) {
    if ($flags =~ /$i/) {
      push @out, $desc{$i};
      $seen .= $i;
    }
    else {
      unless ($seen =~ /$i/i || $flags =~ /$i/i) {
	push @out, $nodesc{$i} || "no$desc{$i}"; # XLANG
	$seen .= $i;
      }
    }
  }
  @out;
}

=head2 describe_class(class)

This returns a textual description for a subscriber class.

=cut
sub describe_class {
  my $self  = shift;
  my $class = shift;
  my $arg   = shift;
  my($dig, $time, $mime);

  if ($class =~ /^digest-(.*)-(.*)/) {
    $arg  = $1;
    $mime = lc($2) eq 'mime' ? 1 : 0;
    $dig = $self->config_get('digests');
    if ($dig->{$arg}) {
      return "$dig->{$arg}{'desc'} " .
	($mime ? "(MIME)" : "(non-MIME)"); # XLANG
    }
    else {
      return "Undefined digest." # XLANG
    }
  }
  
  if ($classes{$class}->[1] == 0) {
    return $classes{$class}->[2];
  }
  if ($classes{$class}->[1] == 1) {
    if ($arg) {
      $time = gmtime($arg);
      return "$classes{$class}->[2] until $time"; # XLANG
    }
    return $classes{$class}->[2];
  }
  return "$classes{$class}->[2]";
}

=head2 get_start()

Begin iterating over the list of subscribers.

=cut
sub get_start {
  shift->{'subs'}->get_start;
}

=head2 get_chunk(max_size)

Returns an array of subscriber data hashrefs of a certain maximum size.

=cut
sub get_chunk {
  my $self = shift;
  my (@addrs, @out, $i);

  @addrs = $self->{'subs'}->get(@_);
  while ((undef, $i) = splice(@addrs, 0, 2)) {
    push @out, $i;
  }
  return @out;
}

=head2 get_matching_chunk(max_size, field, value)

Returns an array of (key, hashref) pairs of max_size size of subscribers
(and data) with data field $field eq $value.

=cut
sub get_matching_chunk {
  my $self = shift;
  $self->{'subs'}->get_matching(@_);
}

=head2 get_done()

Closes the iterator.

=cut
sub get_done {
  shift->{'subs'}->get_done;
}

=head2 search(string, mode)

This searches the full addresses for a match to a string or regexp.  The
iterator must be opened before doing this.

Regexp matching is done sensitive to case.  This is Perl5; if you don''t want
that, use (?i).

This returns a list of (key, data) pairs.

=cut
sub search {
  my $self   = shift;
  my $string = shift;
  my $mode   = shift;

  if ($mode =~ /regexp/) {
    return ($self->{'subs'}->get_matching_regexp(1, 'fulladdr', $string))[0];
  }
  return ($self->{'subs'}->get_matching_regexp(1, 'fulladdr', "\Q$string\E"))[0];
}

=head2 get_member(address, noalias)

This takes an address and returns the member data for that address, or
undef if the address is not a member.  If the optional parameter aliased is
true, no stripping/transformation/aliasing will be done.

This will reset the list iterator.

=cut
sub get_member {
  my $self    = shift;
  my $addr    = shift;
  my $noalias = shift;
  my ($ok);
  
  unless ($noalias) {
    ($ok, $addr, undef) = $self->{'av'}->validate($addr);
    
    # Illegal addresses aren't members
    return undef unless $ok;
    $addr = $self->canon($addr);
  }

  return ($addr, $self->{'subs'}->lookup($addr));
}

=head2 rekey()

This regenerates the keys for the databases from the stripped addresses in
the event that the transformation rules change.

=cut
sub rekey {
  my $self = shift;
  $self->subscriber_rekey;
  $self->alias_rekey;
  $self->aux_rekey_all;
}

sub subscriber_rekey {
  my $self = shift;
  my $sub =
    sub {
      my $key  = shift;
      my $data = shift;
      my (@out, $newkey, $changekey);
      
      $newkey = $self->transform($data->{'stripaddr'});
      $changekey = ($newkey ne $key);
      
      return ($changekey, 0, $newkey);
    };
  $self->{'subs'}->mogrify($sub);
}

######################

=head1 Auxiliary AddressList functions

Thses operate on additional lists of addresses (implemented via the
AddressList object) which are associated with the main list.  These list
are intended to duplicate the function of the old restrict_post files, and
be remotely modifiable, to boot.  They can be used to contain any list of
addresses for any purpose, such as lists of banned addresses or what have
you.  The extended access mechanism is expected to make extensive use of
these.

=head2 aux_add(file, mode, address)

=cut
sub aux_add {
  my $self = shift;
  my $name = shift;
  my $mode = shift;
  my $addr = shift;
  my ($ok, $caddr, $data);
  
  unless ($self->{'sdirs'}) {
    $::log->abort("Mj::File::aux_add called in old directory structure.");
  }
  ($ok, $addr, undef) = $self->{'av'}->validate($addr);
  unless ($ok) {
    return (0, $addr);
  }
  $caddr = $self->canon($addr);
  $data  =
    {
     'stripaddr' => $addr,
    };

  $self->_make_aux($name);
  ($ok, $data) = $self->{'auxlists'}{$name}->add($mode, $caddr, $data);
  unless ($ok) {
    return (0, "Address is already a member of $name as $data->{'stripaddr'}.\n"); # XLANG
  }
  return 1;
}

=head2 aux_remove(file, mode, address_list)

Remove addresses from an auxiliary list.

=cut
sub aux_remove {
  my $self = shift;
  my $name = shift;
  my $mode = shift;
  my $addr = shift;
  my ($ok);

  unless ($self->{'sdirs'}) {
    $::log->abort("Mj::File::aux_remove called in old directory structure.");
  }

  unless ($mode =~ /regexp/) {
    ($ok, $addr, undef) = $self->{'av'}->validate($addr);
    # Whorf unless ok?
    
    $addr = $self->canon($addr)
  }

  $self->_make_aux($name);
  $self->{'auxlists'}{$name}->remove($mode, $addr);
}

=head2 aux_get_start(file)

Begin iterating over the members of an auxiliary list.

=cut
sub aux_get_start {
  my $self = shift;
  my $name = shift;
  
  unless ($self->{'sdirs'}) {
    $::log->abort("Mj::File::aux_get_start called in old directory structure.");
  }

  $self->_make_aux($name);
  $self->{'auxlists'}{$name}->get_start;
}

=head2 aux_get_chunk(file, max_size)

Returns an array of members of an auxiliary list of a certain maximum size.

=cut
sub aux_get_chunk {
  my $self = shift;
  my $name = shift;
  my $size = shift;
  my (@addrs, @out, $i);
  
  $self->_make_aux($name);
  @addrs = $self->{'auxlists'}{$name}->get($size);
  while ((undef, $i) = splice(@addrs, 0, 2)) {
    push @out, $i->{'stripaddr'};
  }
  return @out;
}

=head2 aux_get_done(file)

Stop iterating over the members of an auxiliary list.

=cut
sub aux_get_done {
  my $self = shift;
  my $name = shift;
  my $log  = new Log::In 150, "$name";
  unless ($self->{'sdirs'}) {
    $::log->abort("Mj::File::aux_get_done called in old directory structure.");
  }

  $self->_make_aux($name);
  $self->{'auxlists'}{$name}->get_done;
}

=head2 aux_is_member(file, addr)

This returns true if an address is a member of an auxiliary list.

=cut
sub aux_is_member {
  my $self = shift;
  my $name = shift;
  my $addr = shift;
  my ($saddr, $ok);

  ($ok, $saddr, undef) = $self->{'av'}->validate($addr);
  if ($ok) {
    $self->_make_aux($name);
    return $self->{'auxlists'}{$name}->lookup_quick($saddr);
  }
  return undef;
}

=head2 aux_rekey_all()

This rekeys all auxiliary lists associated with a list.

=cut
sub aux_rekey_all {
  my $self = shift;
  my $i;

  $self->_fill_aux;
  for $i (keys %{$self->{'auxlists'}}) {
    $self->aux_rekey($i);
  }
}

=head2 aux_rekey(name)

This rekeys a single auxiliary file.

=cut
sub aux_rekey {
  my $self = shift;
  my $name = shift;

  my $sub =
    sub {
      my $key  = shift;
      my $data = shift;
      my (@out, $newkey, $changekey);
      
      $newkey = $self->transform($data->{'stripaddr'});
      $changekey = ($newkey ne $key);
      
      return ($changekey, 0, $newkey);
    };

  $self->_make_aux($name);
  $self->{'auxlists'}{$name}->mogrify($sub);
}


=head2 _fill_aux

This fills in the hash of auxiliary lists associated with a List object.
Only preexisting lists are accounted for; others can be created at any
time.  This does not actually create the objects, only the hash slots, so
that they can be tested for with exists().

=cut
sub _fill_aux {
  my $self = shift;

  # Bail early if we don't have to do anything
  return 1 if $self->{'aux_loaded'};
  
  $::log->in(120);

  my $dirh = new IO::Handle;
  my ($file);
  
  my $listdir = $self->_file_path;
  opendir($dirh, $listdir) || $::log->abort("Error opening $listdir: $!");

  while (defined($file = readdir $dirh)) {
    if ($file =~ /^X(.*)/) {
      $self->{'auxlists'}{$1} = undef;
    }
  }
  closedir($dirh);
  
  $self->{'aux_loaded'} = 1;
  $::log->out;
  1;
}

=head1 Aliasing functions

These functions handle address aliasing.  This is simply a function where
several addresses can be treated as equivalent for the purposes of
determining such things as list membership.  Provisions are made for
general address transformations and specific, possibly user-controlled
equivalencies.  The latter are kept in an AliasList database object.

The canonical form of an address is one that is the same for any set of
addresses which are to be considered equivalent.  For example:

tibbs+junk@uh.edu tibbs+crud@uh.edu -> tibbs@uh.edu.
tibbs@a1.uh.edu   tibbs@b2.uh.edu   -> tibbs@uh.edu.

All four addresses are to be considered as equivalent because they all have
the same canonical form.  Note that this is _not_ the address that mail
gets sent to; it's only used for comparing addresses for things like list
membership.

=head2 transform(stripped_address)

This applies the transformations in the addr_xform config variables for the
global list (if apply_global_xform is set) and the list.  They are applied
in order;care should be taken that they are idempotent and that the
collection is idempotent.  This means that the result of applying them
repeatedly is the same as the result of applying them once.

Transformations look somewhat like the usual regular expression transforms:

/(.*)\+.*(\@.*)/$1$2/

Removes the sendmail +mailbox specifier from the address, which turns
tibbs+blah@hurl.edu into tibbs@hurl.edu.  Note that applying this
repeatedly leaves the address alone.  (What happens when there is more than
one '+'?)

/(.*\@).*?\.(hurl\.edu)/$1$2/

Removes the machine name from the hurl.edu domain, which turns
tibbs@a2.hurl.edu into tibbs@hurl.edu.  Note that applying this repeatedly
leaves the address alone.

The list of transformations is stored in a configuration variable.  It is
not expected that one list will have a large number of them, as generally
the internal network structures and mail setups of remote sites are beyond
the list owner's knowlege and control.

=cut
sub transform {
  my $self = shift;

  # Must be local to share with the Safe compartment; previously declared
  # with use vars.
  local $addr = shift;

  my (@xforms, $cpt, $i, $eval);

  $::log->in(120, $addr);

  $cpt = new Safe;
  $cpt->permit_only(qw(const rv2sv concat leaveeval));
  $cpt->share('$addr');

  if ($self->config_get("apply_global_xforms")) {
    @xforms = $::mj->_global_config_get("addr_xforms");
  }

  for $i (@xforms, $self->config_get("addr_xforms")) {
    # Do the substitution in a _very_ restrictive Safe compartment.
    $eval = "\$addr =~ s$i";
    $cpt->reval($eval);

    # Log any messages
    if ($@) {
      $::log->message(10,
		      "info",
		      "Mj::List::transform: error in Safe compartment: $@"
		     );
    }
  }
  $::log->out;
  $addr;
}

=head2 canon(stripped_address)

This returns the canonical form of an address by applying all existing
transforms and then doing an alias database lookup.

=cut
sub canon {
  my $self = shift;
  my $addr = shift;
  my $alias;

  $::log->in(119, $addr);

  $addr = $self->transform($addr);
  $alias = $self->alias_lookup($addr);

  $::log->out;
  return $alias if defined $alias;
  $addr;
}

=head2 addr_match(a b, astripped, acanon, bstripped, bcanon)

This returns true if two addreses are equivalent.  The addresses are
stripped (unless astripped or bstripped is true, in which case the
appropriate address is not stripped and _MUST_ be valid) and canonicalized
(unless acanon or bcanon is true).

False is returned if either of the addresses are illegal or if they are not
equivalent.

XXX Should the comparison be done insensitive to case?  Should canonicalization smash case?

=cut
sub addr_match {
  my ($self, $a1, $a2, $s1, $c1, $s2, $c2) = @_;
  my $log = new Log::In 120, "$a1, $a2";
  my ($ok);

  unless ($s1) {
    ($ok, $a1) = $self->{'av'}->validate($a1);
    return unless $ok;
  }

  unless ($s2) {
    ($ok, $a2) = $self->{'av'}->validate($a2);
    return unless $ok;
  }

  $a1 = $self->canon($a1) unless $c1;
  $a2 = $self->canon($a2) unless $c2;

  return $a1 eq $a2;
}

=head2 alias_add(source, target)

Adds an alias to the AliasList.  This also adds a bookkeeping alias to
speed up removal.  (This works because if we see that an address is aliased
to itself then we know we have aliases to remove.  The lookup doesn''t slow
anything down.)

The target must already be a subscriber to the list (in order to prevent
the problem where a user aliases himself away from a subscribed address, so
that he is no longer a member).  The source _cannot_ be a member of the
list, else that subscriber would alias himself to another subscriber.

=cut
sub alias_add {
  my $self   = shift;
  my $mode   = shift;
  my $source = shift;
  my $target = shift;
  my ($ok, $data, $err, $ssource, $starget, $tsource, $ttarget);

  ($ok, $ssource, undef) = $self->{'av'}->validate($source);
  unless ($ok) {
    return (0, $ssource);
  }
  ($ok, $starget, undef) = $self->{'av'}->validate($target);
  unless ($ok) {
    return (0, $starget);
  }

  # Perform transforms
  $tsource = $self->transform($ssource);
  $ttarget = $self->transform($starget);
  
  # Check list membership for target; suppress aliasing
  (undef, $ok) = $self->get_member($ttarget, 1);
  unless ($ok) {
    return (0, "$target is not a member of $self->{'name'}\n"); # XLANG
  }

  # Check list membership for source; suppress aliasing
  (undef, $ok) = $self->get_member($tsource, 1);

  # We get back undef if not a member...
  if ($ok) {
    return (0, "The alias source, $source,\ncannot be a member of the list ($self->{'name'}).\n"); # XLANG
  }

  # Add bookkeeping alias; don't worry if it fails
  $data = {
	   'fulltarget' => $starget,
	   'fullsource' => $starget,
	   'target'     => $ttarget,
	  };
  $self->{'aliases'}->add("", $ttarget, $data);

  # Add alias
  $data = {
	   'target'     => $ttarget,
	   'fullsource' => $ssource,
	   'fulltarget' => $starget,
	  };
  ($ok, $err) = $self->{'aliases'}->add("", $tsource, $data);
  unless ($ok) {
    # Really, this cannot happen.
    return (0, $err);
  }
  return 1;
}

=head2 alias_remove(mode, source)

This removes an alias pointing from one address.  Note that the target
address is irrelevant here; an alias can only ever point to one address.

This calls the transform routines, but doesn't call the aliasing routines
since that would replace the source with the target.  Since aliases don't
chain, this is fine.

mode is passed to the removal routine; if it =~ /regexp/, address
transformation is bypassed.

XXX Return value?

=cut
sub alias_remove {
  my $self = shift;
  my $mode = shift;
  my $addr = shift;
  
  $addr = $self->transform($addr) unless $mode =~ /regexp/;
  $self->{'aliases'}->remove($mode, $addr);
}

=head2 alias_lookup(canonical_address)

This looks up an address in the AliasList.  The address should be
transformed before calling this.

=cut
sub alias_lookup {
  my $self = shift;
  my $addr = shift;
  my $data;

  $::log->in(120, $addr);
  $data = $self->{'aliases'}->lookup($addr);

  $::log->out;
  return undef unless $data;
  $data->{'target'};
}

=head2 alias_reverse_remove(canonical_address)

This removes all aliases pointing _to_ an address.

This returns a list of ($key, $data) pairs that were removed.

=cut
sub alias_reverse_remove {
  my $self = shift;
  my $addr = shift;
  my (@kill, @out, $i);

  @kill = $self->alias_reverse_lookup($addr);
  
  # Nuke the bookkeeping alias, too
  push @kill, $addr;
  
  for $i (@kill) {
    push @out, $self->{'aliases'}->remove("", $i);
  }
  @out;
}

=head2 alias_reverse_lookup(canonical_address)

This does an inverse lookup; it finds all keys that point to a single
address, except for the bookkeeping alias.

=cut
sub alias_reverse_lookup {
  my $self = shift;
  my $addr = shift;
  my (@data, @out, $key, $args);

  $self->{'aliases'}->get_start;

  # Grab _every_ matching entry
  @data = $self->{'aliases'}->get_matching(0, 'target', $addr);
  $self->{'aliases'}->get_done;

  while (($key, $args) = splice(@data, 0, 2)) {
    unless ($key eq $args->{'target'}) {
      push @out, $args->{'fullsource'};
    }
  }
  @out;
}

=head2 alias_rekey()

This rekeys the alias database; that is, it regenerates the transformed
addresses from the full addresses when the set of transformations changes.

We builda closure which does the changes we want, then we call the mogrify
routine.

=cut
sub alias_rekey {
  my $self = shift;
  my $sub =
    sub {
      my $key =  shift;
      my $data = shift;
      my (@out, $newkey, $changekey, $newtarget, $changedata);
      
      $newkey = $self->transform($data->{'fullsource'});
      $changekey = ($newkey ne $key);
      
      $newtarget = $self->transform($data->{'fulltarget'});
      $changedata = 0;
      if ($newtarget ne $data->{'target'}) {
       $changedata = 1;
       $data->{'target'} = $newtarget;
     }
      return ($changekey, $changedata, $newkey);
    };
  $self->{'aliases'}->mogrify($sub);
}

=head1 FileSpace interface functions

These provide an interface into the list''s FileSpace object.

=cut
use Mj::FileSpace;
sub fs_get {
  my $self  = shift;
  $self->_make_fs || return;
  $self->{'fs'}->get(@_);
}

use Mj::FileSpace;
sub fs_put {
  my $self = shift;
  $self->_make_fs || return;
  $self->{'fs'}->put(@_);
}

use Mj::FileSpace;
sub fs_put_start {
  my $self = shift;
  $self->_make_fs || return;
  $self->{'fs'}->put_start(@_);
}

use Mj::FileSpace;
sub fs_put_chunk {
  my $self = shift;
  $self->_make_fs || return;
  $self->{'fs'}->put_chunk(@_);
}

use Mj::FileSpace;
sub fs_put_done {
  my $self = shift;
  $self->_make_fs || return;
  $self->{'fs'}->put_done(@_);
}

use Mj::FileSpace;
sub fs_delete {
  my $self = shift;
  my $log = new Log::In 150, "$_[0]";
  $self->_make_fs || return;
  $self->{'fs'}->delete(@_);
}

use Mj::FileSpace;
sub fs_sync {
  my $self = shift;
  $self->_make_fs || return;
  $self->{'fs'}->sync;
}

use Mj::FileSpace;
sub fs_index {
  my $self = shift;
  $self->_make_fs || return;
  $self->{'fs'}->index(@_);
}

use Mj::FileSpace;
sub fs_mogrify {
  my $self = shift;
  $self->_make_fs || return;
  $self->{'fs'}->mogrify(@_);
}

use Mj::FileSpace;
sub fs_mkdir {
  my $self = shift;
  $self->_make_fs || return;
  $self->{'fs'}->mkdir(@_);
}

=head1 Message ID/Checksum database management functions

These routines handle querying and adding records to the lists of message
ids checksums that a list maintains in order to keep track of duplicates.

=head2 check_dup(rec, type)

Checks to see if rec exists in the duplicate database _dup_type.

Returns truth if so.  Adds the record to the database in any case.

=cut
sub check_dup {
  my $self = shift;
  my $rec  = shift; # ID or checksum to check
  my $type = shift; # "id", "sum" or "partial"
  my $log  = new Log::In 150, "$rec";
  my ($data, $ok);

  $self->_make_dup($type);
  ($ok, $data) = $self->{'dup'}{$type}->add("", $rec, {});

  # Inverted logic here; we return nothing only if we didn't get a match
  return $data;
}

=head2 expire_dup

This removes old entries from the three duplicate databases.

=cut
sub expire_dup {
  my $self = shift;
  my $time = time;
  my $days = $self->config_get('dup_lifetime');
  my $i;

  my $mogrify = sub {
    my $key  = shift;
    my $data = shift;
    
    if ($data->{'changetime'} + $days*86400 < $time) {
      push @nuked, $key;
      return (1, 1, undef);
    }
    return (0, 0);
  };

  # Kill old entries from the various dup databases.
  for $i ('id', 'sum', 'partial') {
    $self->_make_dup($i);
    $self->{'dup'}{$i}->mogrify($mogrify);
  }

  return @nuked
}

=head1 Lazy Instantiation functions

These routines are used to allocate the various objects that a List has.
These functions are moved out of the List constructor in order to cut down
on startup time; if the objects are not used in a run, the support modules
don't even have to be loaded.

=head2 _make_aux (private)

This makes an AddressList object and stuff it into the List's collection.
This must be called before any function which accesses the AddressList.

=cut
sub _make_aux {
  my $self = shift;
  my $name = shift;
  
  unless (defined $self->{'auxlists'}{$name}) {
    $self->{'auxlists'}{$name} =
      new Mj::AddressList $self->_file_path("X$name");
  }
  1;
}

=head2 _make_fs

Makes a filespace object.

=cut
use Mj::FileSpace;
sub _make_fs {
  my $self = shift;
  return 1 if $self->{'fs'};
  my $dir = $self->{'config'}->get("filedir");
  $dir = $self->_file_path("files") unless $dir;
  $self->{'fs'} = new Mj::FileSpace($dir);
  return unless $self->{'fs'};
  1;
}

=head2 _make_dup(type)

This makes a very simple database for storing just keys and a time (for
expiry).  This is used to keep track of duplicate checksums and
message-ids.

=cut
use Mj::SimpleDB;
sub _make_dup {
  my $self = shift;
  my $type = shift;
  return 1 if $self->{'dup'}{$type};
  $self->{'dup'}{$type} = new Mj::SimpleDB $self->_file_path("_dup_$type"),
    ['changetime'];
  1;
}

=head2 _make_digest

This instantiates the Digest object.

=cut
use Mj::Digest;
sub _make_digest {
  my $self = shift;
  return 1 if $self->{'digest'};
  $self->_make_archive;

  $self->{'digest'} = new Mj::Digest($self->{'ldir'},
				     $self->{'archive'},
				     $self->config_get('digests'),
				    );
}

=head2 _make_archive

This instantiates the Archive object.

=cut

use Mj::Archive;
use Data::Dumper;
sub _make_archive {
  my $self = shift;
  return 1 if $self->{'archive'};
  my $dir = $self->config_get('archive_dir');

  # Default to /public/archive
  unless ($dir) {
    ($dir) = $self->fs_get('public/archive', 1, 1);
  }

  # Go away if we still don't have anything
  return unless $dir && -d $dir;

  # Create the archive
  $self->{'archive'} = new Mj::Archive ($dir,
					$self->{'name'},
					$self->config_get('archive_split'),
					$self->config_get('archive_size'),
				       );
  1;
}

=head1 Miscellaneous functions

Config modification, access checking, special bootstrapping functions for
the Majordomo object.

=head2 config_get

Retrieves a variable from the list''s Config object.

=cut
sub config_get {
  my $self = shift;
  $self->{'config'}->get(@_);
}

=head2 config_set

Sets a variable in the Config object.

=cut
sub config_set {
  my $self = shift;
  $self->{'config'}->set(@_);
}

=head2 config_set_to_default

Sets a variable to track the default value.

=cut
sub config_set_to_default {
  shift->{'config'}->set_to_default(@_);
}

=head2 config_save

Saves the config files, if necessary.

=cut
sub config_save {
  shift->{'config'}->save;
}

sub config_lock {
  shift->{'config'}->lock;
}

sub config_unlock {
  shift->{'config'}->unlock;
}

sub config_get_allowed {
  my $self = shift;
  my $var  = shift;
  $self->{'config'}->allowed($var);
}

sub config_get_comment {
  my $self = shift;
  my $var  = shift;
  $self->{'config'}->comment($var);
}

sub config_get_default {
  my $self = shift;
  my $var  = shift;
  $self->{'config'}->default($var);
}

sub config_get_intro {
  my $self = shift;
  my $var  = shift;
  $self->{'config'}->intro($var);
}

sub config_get_isarray {
  my $self = shift;
  my $var  = shift;
  $self->{'config'}->isarray($var);
}

sub config_get_isauto {
  my $self = shift;
  my $var  = shift;
  $self->{'config'}->isauto($var);
}

sub config_get_visible {
  my $self = shift;
  my $var  = shift;
  $self->{'config'}->visible($var);
}

sub config_get_mutable {
  my $self = shift;
  my $var  = shift;
  $self->{'config'}->mutable($var);
}

sub config_get_groups {
  my $self = shift;
  my $var  = shift;
  $self->{'config'}->groups($var);
}

sub config_get_type {
  my $self = shift;
  my $var  = shift;
  $self->{'config'}->type($var);
}

sub config_get_vars {
  my $self = shift;
  $self->{'config'}->vars(@_);
}

=head1 Archive functions

These interface with the list''s Archive object.

=head2 archive_add

This adds a message contained in a file to the archive.

=cut
sub archive_add {
  my $self = shift;
  return unless $self->_make_archive;
  $self->{'archive'}->add(@_);
}

=head1 Digest functions

These functions prepare data for and interface with the list's Digest object.

=head2 _build_digest_data

XXXXXXXXXXXX Remove this.

This builds the digest information hash for a list.

Note that this is a List method, not a Digest method.  The Digest object
doesn't have access to the list's config, and so expects an already parsed
set of rules.  This routine is used to parse the rules.

=cut
# use Mj::Digest;
# sub _build_digest_data {
#   my $self = shift;
#   my(@dig, $elem, $error, $i, $j, $table);
  
#   return if $self->{'digests_loaded'};
  
#   @dig = $self->config_get("digests");
#   ($table, $error) =
#     parse_table($self->config_get_isarray("digests"), \@dig);
  
#   # We expect that the table would have been syntax-checked when it was
#   # accepted, so we can abort if we get an error.  XXX Oops; this routine
#   # will be the syntax checker, too, so we need to return something.
#   if ($error) {
#     $::log->abort("Received an error while parsing digest table: $error");
#   }

#   $self->{'default_digest'} = $table->[0][0] if $table->[0];

#   for ($i=0; $i<@{$table}; $i++) {
#     $self->{'digest_data'}{$table->[$i][0]} = {};
#     $elem = $self->{'digest_data'}{$table->[$i][0]};

#     # minsizes
#     for $j (@{$table->[$i][1]}) {
#       if ($j =~ /(\d+)m/i) {
# 	$elem->{'minmsg'} = $1;
#       }
#       elsif ($j =~ /(\d+)k/i) {
# 	$elem->{'minsize'} = $1;
#       }
#       else {
# 	# Error condition XXX
#       }
#     }

#     # maxage
#     $elem->{'maxage'} = _str_to_offset($table->[$i][2]);
    
#     # maxsizes
#     for $j (@{$table->[$i][3]}) {
#       if ($j =~ /(\d+)m/i) {
# 	$elem->{'maxmsg'} = $1;
#       }
#       elsif ($j =~ /(\d+)k/i) {
# 	$elem->{'maxsize'} = $1*1024;
#       }
#       else {
# 	# Error condition XXX
#       }
#     }

#     # minage
#     $elem->{'minage'} = _str_to_offset($table->[$i][4]);
    
#     # runall
#     $elem->{'runall'} = $table->[$i][5] =~ /y/ ? 1 : 0;

#     # mime
#     $elem->{'mime'} = $table->[$i][6] =~ /y/ ? 1 : 0;

#     # times
#     $elem->{'times'} = [];
#     for $j (@{$table->[$i][7]}) {
#       push @{$elem->{'times'}}, _str_to_clock($j);
#     }
#     # Give a default of 'anytime'
#     $elem->{'times'} = [['a', 0, 23]] unless @{$elem->{'times'}};

#     # description
#     $elem->{'desc'} = $table->[$i][8];

#   }
#   $self->{'digests_loaded'} = 1;
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

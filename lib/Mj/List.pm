=head1 NAME

Mj::List.pm - Majordomo list object

=head1 SYNOPSIS

  $list = new Mj::List;
  $list->add('force', "nobody@nowhere.com");

=head1 DESCRIPTION

This contains code for the List object, which encapsulates all per-list
functionality for Majordomo.

A list owns a Config object to maintain configuration data, a
SubscriberList object to store the list of subscribers and their data,
various AddressList objects, an Archive object, and a Digest object
handling all archiving and digesting aspects of the list.

=cut

package Mj::List;

use strict;
use Safe;  # For evaluating the address transforms
use Mj::File;
use Mj::FileRepl;
use Mj::SubscriberList;
use Mj::AddressList;
use Mj::Config qw(parse_table);
use Mj::Addr;
use Mj::Log;
use vars (qw($addr %flags %noflags %classes %digest_types));

# Flags -> [realflag, inverted (2=intermediate), invertible, flag]
%flags = 
  (
   'ackall'       => ['ackall',       0,0,'A'],
   'ackimportant' => ['ackimportant', 2,0,'a'],
   'noack'        => ['ackall',       1,0,'' ],
   'selfcopy'     => ['selfcopy',     0,1,'S'],
   'hideall'      => ['hideall',      0,0,'H'],
   'hideaddress'  => ['hideall',      2,0,'h'],
   'nohide'       => ['hideall',      1,0,'' ],
   'showall'      => ['hideall',      1,0,'' ],
   'eliminatecc'  => ['eliminatecc',  0,1,'C'],
   'prefix'       => ['prefix',       0,1,'P'],
   'replyto'      => ['replyto',      0,1,'R'],
   'rewritefrom'  => ['rewritefrom',  0,1,'W'],
  );

# Special inverse descriptions
%noflags =
  (
   'nohide'  => 'H',
   'noack'   => 'A',
  );


# Classes -> [realclass, takesargs, description]
%classes =
  (
   'each'     => ['each',   0, "each message"],
   'single'   => ['each',   0],
   'all'      => ['all',    0, "all list traffic"],
   'digest'   => ['digest', 2, "messages in a digest"],
   'nomail'   => ['nomail', 1, "no messages"],
   'vacation' => ['nomail', 1],
  );

%digest_types =
  (
   'mime'  => 1,
   'index' => 1,
   'text'  => 1,
  );

=head2 new(name, separate_list_dirs)

Creates a list object.  This doesn't check validity or load any config
files (though the later is because the config files load themselves
lazily).  Note that this doesn't create a list; it just creates the object
that is used to hold information about an existing list.

=cut
sub new {
  my $type  = shift;
  my %args  = @_;
  
  my $class = ref($type) || $type;
  my $log   = new Log::In 150, "$args{'dir'}, $args{'name'}, $args{'backend'}";

  my ($subfile);

  my $self = {};
  bless $self, $class;

  $self->{auxlists} = {};
  $self->{backend}  = $args{backend};
  $self->{callbacks}= $args{callbacks};
  $self->{ldir}     = $args{dir};
  $self->{name}     = $args{name};
  $self->{sdirs}    = 1; # Obsolete goody
    
  $subfile = $self->_file_path("_subscribers");

  # XXX This should probably be delayed
  unless ($args{name} eq 'GLOBAL' or $args{name} eq 'DEFAULT') {
    $self->{subs} = new Mj::SubscriberList $subfile, $args{'backend'};
  }

  $self->{'config'} = new Mj::Config
    (
     list      => $args{'name'},
     dir       => $args{'dir'},
     callbacks => $args{'callbacks'},
    );
  
  # We have to figure out our database backend for ourselves if we're
  # creating the GLOBAL list, since it couldn't be passed to us.
  if ($args{name} eq 'GLOBAL' or $args{name} eq 'DEFAULT') {
    $self->{backend} = $self->config_get('database_backend');
  }
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

use AutoLoader 'AUTOLOAD';
1;
__END__

#################################

=head1 Subscriber list operations

These functions operate on the subscriber list itself.

=head2 add(mode, address, class, flags)

Adds an address (which must be an Mj::Addr object) to the subscriber list.
The canonical form of the address is used for the database key, and the
other subscriber data is computed and stored in a hash which is passed to
SubscriberList::add.

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
  my (@out, $i, $ok, $data);

  $::log->in(120, "$mode, $addr");

  $data = {
	   'fulladdr'  => $addr->full,
	   'stripaddr' => $addr->strip,
	   'subtime'   => time,
	   # Changetime handled automatically
	   'class'     => $class,
	   'classarg'  => $carg,
	   'flags'     => $flags,
	  };
  
  @out = $self->{'subs'}->add($mode, $addr->canon, $data);
  $::log->out;
  @out;
}

=head2 remove(mode, address)

Removes addresses from the main list.  Everything at "add" applies.

=cut
sub remove {
  my $self = shift;
  my $mode = shift;
  my $addr = shift;
  my ($a);

  if ($mode =~ /regex/) {
    $a = $addr;
  }
  else {
    $a = $addr->canon;
  }
  $self->{'subs'}->remove($mode, $a);
}

=head2 is_subscriber(addr)

Returns the subscriber data if the address subscribes to the list.

=cut
sub is_subscriber {
  my $self = shift;
  my $addr = shift;
  my $log = new Log::In 170, "$self->{'name'}, $addr";
  my ($data, $ok, $out, $subs);

  return unless $addr->isvalid;
  return if $addr->isanon;

  # If we have cached data within the addr, use it
  $data = $addr->retrieve("$self->{name}-subs");
  return $data if $data;

  # Otherwise see if we have enough cached data to tell us whether they're
  # subscribed or not, so we can save a database lookup
  $subs = $addr->retrieve('subs');
  if ($subs) {
    if ($subs->{$self->{name}}) {
      # We know they're a subscriber, so we can actually look up the data
      $out = $self->{'subs'}->lookup($addr->canon);
      $addr->cache("$self->{name}-subs", $out);
      $log->out('yes-fast');
      return $out;
    }
    else {
      $log->out('no-fast');
      return;
    }
  }

  # We know nothing about the address so we do the lookup
  $out = $self->{'subs'}->lookup($addr->canon);
  if ($out) {
    $addr->cache("$self->{name}-subs", $out);
    $log->out("yes");
    return $out;
  }
  $log->out("no");
  return;
}

=head2 set(addr, setting, arg, check)

This sets various subscriber data.

If $check is true, we check the validity of the settings but don''t
actually change any values (not implemented).

=cut
sub set {
  my $self = shift;
  my $addr = shift;
  my $set  = shift;
  my $check= shift;
  my $log  = new Log::In 150, "$addr, $set";
  my (@allowed, @class, $carg1, $carg2, $class, $data, $flags, $inv, $isflag,
      $key, $mask, $ok, $rset);

  ($inv = $set) =~ s/^no//;

  @class = split(/-/, $set);

  if ($rset = $flags{$set}->[0] || $flags{$inv}->[0]) {
    $isflag = 1;
  }
  elsif ($rset = $classes{$class[0]}->[0]) {
    $isflag = 0;
  }
  else {
    $log->out("failed, invalidaction");
    return (0, "Invalid setting: $set.\n"); # XLANG
  }

  if ($check) {
    # Check the setting against the allowed flag mask.
    if ($isflag) {
      $mask = $self->config_get('allowed_flags');
      # Make sure base flag is in the set.
    }

    # Else it's a class
    else {
      @allowed = $self->config_get('allowed_classes');
      # Make sure that one of the allowed classes is at the beginning of
      # the given class.

    }
    return 1;
  }

  # Grab subscriber data
  ($key, $data) = $self->get_member($addr);

  unless ($data) {
    $log->out("failed, nonmember");
    return (0, "$addr is not a subscriber.\n"); # XLANG
  }

  # Call make_setting to get a new flag list and class setting
  ($ok, $flags, $class, $carg1, $carg2) =
    $self->make_setting($set, $data->{'flags'}, $data->{'class'},
			$data->{'classarg'}, $data->{'classarg2'});
  return ($ok, $flags) unless $ok;

  ($data->{'flags'}, $data->{'class'},
   $data->{'classarg'}, $data->{'classarg2'}) =
     ($flags, $class, $carg1, $carg2);

  $self->{'subs'}->replace("", $key, $data);
  return (1, $flags, $class, $carg1, $carg2);
}

=head2 make_setting

This takes a string and a flag list and class info and returns a class,
class arguments, and a new flag list which reflect the information present
in the string.

=cut
sub make_setting {
  my($self, $str, $flags, $class, $carg1, $carg2) = @_;
  my $log   = new Log::In 150, "$str, $flags";
  my($arg, $dig, $i, $inv, $isflag, $rset, $set, $time, $type);

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
      return (0, "Invalid setting: $set.\n"); # XLANG
    }
    
    if ($isflag) {
      # Process flag setting; remove the flag from the list
      $flags =~ s/$flags{$rset}->[3]//ig;
      
      # Add the new flag (which may be null)
      $flags .= $flags{$set}->[3] || '';
    }
    else {
      # Process class setting

      # Just a plain class
      if ($classes{$rset}->[1] == 0) {
	$class = $rset;
	$carg1 = $carg2 = '';
      }

      # A class taking a time (nomail/vacation)
      elsif ($classes{$rset}->[1] == 1) {
	# If passed 'return', immediately set things back to the saved
	# settings if there were any
	if ($arg eq 'return') {
	  return (0, "Not currently in nomail mode.\n")
	    unless $classes{$class}->[0] eq 'nomail';
	  return (0, "No saved settings to return to.\n")
	    unless $carg2;

	  ($class, $carg1, $carg2) = split("\002", $carg2);
	  $class = 'each' unless defined($class) && $classes{$class};
	  $carg1 = ''     unless defined($carg1);
	  $carg2 = ''     unless defined($carg2);
	}

	# Convert arg to time;
	elsif ($arg) {
	  # Eliminate recursive stacking if a user already on timed
	  # vacation sets timed vacation again; just update the time and
	  # don't save away the class info.
	  if ($classes{$class}->[0] ne 'nomail') {
	    $carg2 = join("\002", $class, $carg1, $carg2); # Save the old class info
	  }
	  $carg1 = _str_to_time($arg);
	  return (0, "Invalid time $arg.\n") unless $carg1; # XLANG
	  $class = $rset;
	}
	else {
	  $class = $rset;
	  $carg1 = $carg2 = '';
	}
      }

      # Digest mode
      elsif ($rset eq 'digest') {
	# Process the digest data and pick apart the class
	$dig = $self->config_get('digests');
    return (0, "No digests have been configured for the $self->{'name'} list.\n")
      unless exists $dig->{'default_digest'};
	if ($arg) {
	  # The argument may be a digest type
	  if ($digest_types{$arg}) {
	    $type = $arg;
	    $arg = $dig->{'default_digest'};
	  }
	  # Or it mught be a digest name
	  elsif ($dig->{$arg}) {
	    $type = $dig->{$arg}{'type'};
	  }
	  # Or it might be a name-type string
	  elsif ($arg =~ /(.*)-(.*)/) {
	    $arg = $1;
	    $type = $2;
	  }
	  return (0, "Illegal digest name: $arg.\n") # XLANG
	    unless $dig->{$arg};
	  return (0, "Illegal digest type: $type.\n") #XLANG
	    unless $digest_types{$type};
	}
	else {
	  $arg  = $dig->{'default_digest'};
	  $type = $dig->{$arg}{'type'} || 'mime';
	}
	$class = "digest";
	$carg1 = $arg;
	$carg2 = $type;
      }
    }
  }
  return (1, $flags, $class, $carg1, $carg2);
}

=head2 _str_to_time(string)

This converts a string to a time.

=cut
sub _str_to_time {
  my $arg = shift;
  my $log = new Log::In 150, $arg;
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
Don''t ask for flags in the off state (noprefix, etc.) because this will
not provide a useful result.

This stashes the flags within the address so that repeated lookups will be
cheap.

=cut
sub flag_set {
  my $self = shift;
  my $flag = shift;
  my $addr = shift;
  my $force= shift;
  my $log  = new Log::In 150, "$flag, $addr";
  $log->out('no');
  my ($flags, $data);
  return unless $flags{$flag};
  return unless $addr->isvalid;
  
  $flags = $addr->retrieve("$self->{name}-flags");

  if ($force || !defined($flags)) {
    $data = $self->is_subscriber($addr);
    if ($data) {
      $flags = $data->{flags};
    }
    else {
      $flags = $self->config_get('nonmember_flags');
    }
    $addr->cache("$self->{name}-flags", $flags);
  }

  return unless $flags =~ /$flags{$flag}[3]/;
  $log->out('yes');
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
  my $arg1  = shift;
  my $arg2  = shift;
  my($dig, $time, $type);

  if ($class eq 'digest') {
    $dig = $self->config_get('digests');
    if ($dig->{$arg1}) {
      return "$dig->{$arg1}{'desc'} ($arg2)";
    }
    else {
      return "Undefined digest." # XLANG
    }
  }
  
  if ($classes{$class}->[1] == 0) {
    return $classes{$class}->[2];
  }
  if ($classes{$class}->[1] == 1) {
    if ($arg1) {
      $time = gmtime($arg1);
      return "$classes{$class}->[2] until $time"; # XLANG
    }
    return $classes{$class}->[2];
  }
  return $classes{$class}->[2];
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

=head2 get_member(address)

This takes an address and returns the member data for that address, or
undef if the address is not a member.

This will reset the list iterator.

=cut
sub get_member {
  my $self = shift;
  my $addr = shift;
  
  return ($addr->canon, $self->{'subs'}->lookup($addr->canon));
}

=head2 rekey()

This regenerates the keys for the databases from the stripped addresses in
the event that the transformation rules change.

=cut
sub rekey {
  my $self = shift;
  $self->subscriber_rekey 
    unless ($self->{name} eq 'GLOBAL' or $self->{name} eq 'DEFAULT');
  $self->aux_rekey_all;
}

sub subscriber_rekey {
  my $self = shift;
  my $sub =
    sub {
      my $key  = shift;
      my $data = shift;
      my (@out, $addr, $newkey, $changekey);

      # Allocate an Mj::Addr object from stripaddr and transform it.  XXX
      # Why not canon instead?
      $addr = new Mj::Addr($data->{'stripaddr'});
      $newkey = $addr->xform;
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

  $data  =
    {
     'stripaddr' => $addr->strip,
    };

  $self->_make_aux($name);
  ($ok, $data) = $self->{'auxlists'}{$name}->add($mode, $addr->canon, $data);
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
  my $log = new Log::In 150, "$name, $mode, $addr";
  my ($ok);

  unless ($mode =~ /regexp/) {
    $addr = $addr->canon;
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
  my $log  = new Log::In 150, $name;

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

  return 0 unless $addr->isvalid;
  return 0 if $addr->isanon;

  $self->_make_aux($name);
  return $self->{'auxlists'}{$name}->lookup_quick($addr->canon);
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
      my (@out, $addr, $newkey, $changekey);

      # Allocate an Mj::Addr object from stripaddr and transform it.  XXX
      # Why not canon instead?
      $addr = new Mj::Addr($data->{'stripaddr'});
      $newkey = $addr->xform;
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
    if ($file =~ /^X(.*)\..*/) {
      $self->{'auxlists'}{$1} = undef;
    }
  }
  closedir($dirh);
  
  $self->{'aux_loaded'} = 1;
  $::log->out;
  1;
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
  my $log = new Log::In 150, $_[0];
  $self->_make_fs || return;
  $self->{'fs'}->delete(@_);
}

use Mj::FileSpace;
sub fs_index {
  my $self = shift;
  $self->_make_fs || return;
  $self->{'fs'}->index(@_);
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
  my $log  = new Log::In 150, $rec;
  my ($data, $ok);

  $self->_make_dup($type);
  ($rec) = $rec =~ /(.*)/; # Untaint
  ($ok, $data) = $self->{'dup'}{$type}->add("", $rec, {});

  # Inverted logic here; we return nothing only if we didn't get a match
  return $data;
}

=head2 remove_dup(rec, type)

Removes the record of a duplicate from a duplicate database.

=cut
sub remove_dup {
  my $self = shift;
  my $rec  = shift; # ID or checksum to check
  my $type = shift; # "id", "sum" or "partial"
  my $log  = new Log::In 150, $rec;
  my ($data, $ok);

  $self->_make_dup($type);
  ($rec) = $rec =~ /(.*)/; # Untaint
  ($ok, $data) = $self->{'dup'}{$type}->remove("", $rec);

  return $ok;
}

=head2 expire_dup

This removes old entries from the three duplicate databases.

=cut
sub expire_dup {
  my $self = shift;
  my $time = time;
  my $days = $self->config_get('dup_lifetime');
  my (@nuked, $i);

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

=head2 expire_vacation

This converts members with timed nomail classes back to their old class
when the vacation time is passed.

=cut
sub expire_vacation {
  my $self = shift;
  my $time = time;

  my $mogrify = sub {
    my $key  = shift;
    my $data = shift;
    my ($c, $a1, $a2);

    # Fast exit unless we have a timed nomail class and the time has expired
    return (0, 0) 
      unless ($data->{class} eq 'nomail' &&
	      $data->{classarg} &&
	      $time > $data->{classarg});

    # Now we know we must expire; extract the args
    ($c, $a1, $a2) = split("\002", $data->{classarg2});
    $data->{'class'}     = defined $c  ? $c  : 'each';
    $data->{'classarg'}  = defined $a1 ? $a1 : '';
    $data->{'classarg2'} = defined $a2 ? $a2 : '';

    # And update the entry
    return (0, 1, $data);
  };

  $self->{subs}->mogrify($mogrify);
}


=head2 _make_aux (private)

This makes an AddressList object and stuff it into the List''s collection.
This must be called before any function which accesses the AddressList.

=cut
sub _make_aux {
  my $self = shift;
  my $name = shift;
  
  unless (defined $self->{'auxlists'}{$name}) {
    $self->{'auxlists'}{$name} =
      new Mj::AddressList $self->_file_path("X$name"), $self->{backend};
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
  $self->{'fs'} = new Mj::FileSpace($dir, $self->{backend});
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

  $self->{'dup'}{$type} =
    new Mj::SimpleDB(filename => $self->_file_path("_dup_$type"),
		     backend  => $self->{backend},
		     fields   => ['changetime'],
		    );
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

  $self->{'digest'} = new Mj::Digest($self->{archive},
				     "$self->{ldir}/$self->{name}",
				     $self->config_get('digests'),
				    );
}

=head2 _make_archive

This instantiates the Archive object.

=cut
use Mj::Archive;
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

=head2 archive_add_start(sender, data), archive_add_done(file)

This adds a message contained in a file to the archive.  _start gives you a
message number, _done actually commits the add.  The archive is
write-locked between calls to these functions, so it is important to
minimise the elapsed time between the two calls.

=cut
sub archive_add_start {
  my $self = shift;
  return unless $self->_make_archive;
  $self->{'archive'}->add_start(@_);
}

sub archive_add_done {
  my $self = shift;
  $self->{'archive'}->add_done(@_);
}

=head2 archive_get_start,chunk,done

Pass through to the archive interface

=cut
sub archive_get_start {
  my $self = shift;
  return unless $self->_make_archive;
  $self->{'archive'}->get_message(@_);
}

sub archive_get_chunk {
  my $self = shift;
  $self->{'archive'}->get_chunk(@_);
}

sub archive_get_done {
  my $self = shift;
  $self->{'archive'}->get_done(@_);
}

sub archive_expand_range {
  my $self = shift;
  $self->_make_archive;
  $self->{'archive'}->expand_range(@_);
}


=head1 Digest functions

These functions interface with the list''s Digest object.

=head2 digest_build

Builds a digest.

=cut
use Mj::Digest::Build;
sub digest_build {
  my $self = shift;
  $self->_make_archive;
  Mj::Digest::Build::build(@_, 'archive' => $self->{'archive'});
}

=head2 digest_add

Adds an [article, data] pair to the lists'' digest object.  This will
return what Mj::Digest::add returns, which is a hash keyed on digest name
containing the list of [article, data] pairs of the messages in that digest
which need to be sent out.

=cut
sub digest_add {
  my $self = shift;
  $self->_make_digest;
  $self->{digest}->add(@_);
}

=head2 digest_trigger

Trigger a digest.  This does what digest_add does, but instead of adding a
message it just checks to see if a digest should be sent.  The return is
the same as digest_add.

=cut
sub digest_trigger {
  my $self = shift;
  $self->_make_digest;
  $self->{digest}->trigger(@_);
}

=head2 digest_incvol(inc, digests)

Increment the volume numbers and reset the issue numbers for the given
digests.

$inc is a list of digests to increment the volume numbers of.  All digests
wil have their volume numbers incremented if this is not defined.

$digests is the parsed 'digests' variable; it will be extracted if not
defined.

=cut
sub digest_incvol {
  my $self    = shift;
  my $inc     = shift;
  my $digests = shift;
  my $log = new Log::In 150;
  my (%inc, @tmp, $i, $issues);

  $digests ||= $self->config_get('digests');
  $inc     ||= [keys(%$digests)];

  use Data::Dumper; print Dumper $inc;

  # Build a quick lookup hash
  for $i (@$inc) {
    $inc{$i} = 1;
  }

  $self->config_lock;
  # In critical section

  $issues = $self->config_get('digest_issues');

  # Note that we iterate over all defined digests (and skip the default
  # entry) because we need to rebuild the complete structure, even for the
  # items which aren't changing.
  for $i (keys(%$digests)) {
    next if $i eq 'default_digest';
    $issues->{$i}{volume} ||= 1; $issues->{$i}{issue} ||= 1;
    if ($inc{$i}) {
      # If we're in the set to be changed, up the volume and reset the
      # issue to 1
      push @tmp, "$i : " . ($issues->{$i}{volume}+1) ." : 1";
    }
    else {
      # Else leave it alone completely
      push @tmp, "$i : $issues->{$i}{volume} : $issues->{$i}{issue}";
    }
  }
  $self->config_set('digest_issues', @tmp);

  # Exit critical section
  $self->config_unlock;

  return $issues;
}

=head2 digest_incissue(inc, digests)

Increment the issue numbers for the given digests.

$inc is a listref of digest names which will have their issue numbers
incremented.  $digests is the parsed 'digests' variable; it is looked up if
not provided.

Returns the final 'digest_issues' structure.

=cut
sub digest_incissue {
  my $self    = shift;
  my $inc     = shift;
  my $digests = shift;
  my $log = new Log::In 150;
  my (%inc, @tmp, $i, $issues);

  $digests ||= $self->config_get('digests');

  # Build a quick lookup hash
  for $i (@$inc) {
    $inc{$i} = 1;
  }

  $self->config_lock;
  # In critical section

  $issues = $self->config_get('digest_issues');

  # Note that we iterate over all defined digests (and skip the default
  # entry) because we need to rebuild the complete structure, even for the
  # items which aren't changing.
  for $i (keys(%$digests)) {
    next if $i eq 'default_digest';
    $issues->{$i}{volume} ||= 1; $issues->{$i}{issue} ||= 1;
    push @tmp, "$i : $issues->{$i}{volume} " .
      " : " . ($issues->{$i}{issue}+($inc{$i} ? 1 : 0));
  }
  $self->config_set('digest_issues', @tmp);

  # Exit critical section
  $self->config_unlock;

  return $issues;
}


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

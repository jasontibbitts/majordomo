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
auxiliary SubscriberLists, an Archive object, and a Digest object
handling all archiving and digesting aspects of the list.

=cut

package Mj::List;

use strict;
use Mj::SubscriberList;
use Mj::Config qw(parse_table);
use Mj::Addr;
use Mj::Log;
use vars (qw($addr %alias %flags %noflags %classes %digest_types));

%alias =
  (
   'A'  => 'auxiliary',
   'M'  => 'moderate',
   'O'  => 'owner',
   'Q'  => 'request',
   'R'  => 'resend',
   'S'  => 'subscribe',
   'U'  => 'unsubscribe',
  );

# Flags -> [realflag, inverted (2=umbrella), invertible, flag]
%flags = 
  (
   'ackall'       => ['ackall',       2,0,'A'],
   'ackimportant' => ['ackall',       2,0,'a'],
   'ackdeny'      => ['ackall',       0,1,'d'],
   'ackpost'      => ['ackall',       0,1,'f'],
   'ackreject'    => ['ackall',       0,1,'j'],
   'ackstall'     => ['ackall',       0,1,'b'],
   'noack'        => ['ackall',       1,0,'' ],
   'selfcopy'     => ['selfcopy',     0,1,'S'],
   'hideall'      => ['hideall',      0,1,'H'],
   'hideaddress'  => ['hideall',      0,1,'h'],
   'nohide'       => ['hideall',      1,0,'' ],
   'showall'      => ['hideall',      1,0,'' ],
   'eliminatecc'  => ['eliminatecc',  0,1,'C'],
   'prefix'       => ['prefix',       0,1,'P'],
   'replyto'      => ['replyto',      0,1,'R'],
   'rewritefrom'  => ['rewritefrom',  0,1,'W'],
   'postblock'    => ['postblock',    0,1,'O'],
  );

# Special inverse descriptions
%noflags =
  (
   'nohide'  => 'H',
  );


# Classes -> [realclass, takesargs, description]
%classes =
  (
   'each'     => ['each',   0, "each message as it is posted"],
   'single'   => ['each',   0],
   'all'      => ['all',    0, "all list traffic"],
   'digest'   => ['digest', 2, "messages in a digest"],
   'mail'     => ['mail',   1, "resume receiving messages"],
   'nomail'   => ['nomail', 1, "no messages"],
   'vacation' => ['nomail', 1],
   'unique'   => ['unique', 0, "each unduplicated message"],
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

  $self->{sublists} = {};
  $self->{backend}  = $args{backend};
  $self->{callbacks}= $args{callbacks};
  $self->{domain}   = $args{domain};
  $self->{ldir}     = $args{dir};
  $self->{name}     = $args{name};
  $self->{sdirs}    = 1; # Obsolete goody

  return unless -d "$self->{ldir}/$self->{name}";

  $subfile = $self->_file_path("_subscribers");

  # XXX This should probably be delayed
  unless ($args{name} eq 'GLOBAL' or $args{name} eq 'DEFAULT') {
    $self->{sublists}{'MAIN'} = 
      new Mj::SubscriberList (
                              'backend' => $self->{'backend'},
                              'domain'  => $self->{'domain'},
                              'file'    => '_subscribers', 
                              'list'    => $self->{'name'},
                              'listdir' => $self->{'ldir'},
                             );
  }

  $self->{'templates'}{'MAIN'} = new Mj::Config
    (
     list        => $args{'name'},
     dir         => $args{'dir'},
     callbacks   => $args{'callbacks'},
     defaultdata => $args{'defaultdata'},
     installdata => $args{'installdata'},
    );

  $self->{'config'} = $self->{'templates'}{'MAIN'};

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

=head2 add(mode, address, sublist, data)

Adds an address (which must be an Mj::Addr object) to a subscriber list.
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
  my $sublist = shift || 'MAIN';
  my %data  = @_;
  my (@out, $i, $ok, $class, $carg, $carg2);

  my $log = new Log::In 120, "$mode, $addr";

  $data{'flags'} ||= $self->get_flags('default_flags');

  unless ($data{'class'}) {
    ($class, $carg, $carg2) = $self->default_class;
    $data{'class'}     = $class;
    $data{'classarg'}  = $carg;
    $data{'classarg2'} = $carg2;
  }

  $data{'fulladdr'}  = $addr->full;
  $data{'stripaddr'} = $addr->strip;
  $data{'subtime'}   = time;
  # Changetime handled automatically

  return (0, "Unable to access subscriber list $sublist")
    unless $self->_make_aux($sublist);

  $self->{'sublists'}{$sublist}->add($mode, $addr->canon, \%data);
}

=head2 update(mode, address, sublist, data)

Change the data for an address (which must be an Mj::Addr object) 
in a subscriber list.

The canonical form of the address is used for the database key, and the
other subscriber data is computed and stored in a hash which is passed to
SubscriberList::replace.

This passes out the return of SubscriberList::replace, which is of the form
(flag, data) where data holds a ref to the subscriber data if there was a
failure due to an existing entry.

=cut
sub update {
  my $self  = shift;
  my $mode  = shift || '';
  my $addr  = shift;
  my $sublist = shift || 'MAIN';
  my $data = shift;
  my (@out, $i, $ok, $class, $carg, $carg2);

  my $log = new Log::In 120, "$mode, $addr";

  return (0, "No data supplied") unless ref $data;
  return (0, "No address supplied") unless ref $addr;

  return (0, "Unable to access subscriber list $sublist")
    unless $self->_make_aux($sublist);

  $self->{'sublists'}{$sublist}->replace($mode, $addr->canon, $data);
}

=head2 remove(mode, address)

Removes addresses from the main list.  Everything at "add" applies.

=cut
sub remove {
  my $self = shift;
  my $mode = shift;
  my $addr = shift;
  my $sublist = shift || 'MAIN';
  my ($a, $dbmode);

  if ($mode =~ /regex/ || $mode =~ /pattern/) {
    $dbmode = "regex";
    $a = $addr;
    if ($mode =~ /allmatching/) {
      $dbmode .= '-allmatching';
    }
  }
  else {
    $dbmode = '';
    $a = $addr->canon;
  }

  return (0, "Nonexistent subscriber list \"$sublist\".")
    unless $self->valid_aux($sublist);
  return (0, "Unable to access subscriber list \"$sublist\".")
    unless $self->_make_aux($sublist);

  $self->{'sublists'}{$sublist}->remove($dbmode, $a);
}

=head2 is_subscriber(addr)

Returns the subscriber data if the address subscribes to the list.

=cut
sub is_subscriber {
  my $self = shift;
  my $addr = shift;
  my $sublist = shift || 'MAIN';
  my $log = new Log::In 170, "$self->{'name'}, $addr";
  my ($data, $ok, $out, $subs);

  return unless $addr->isvalid;
  return if $addr->isanon;

  # If we have cached data within the addr, use it.
  # Only the main subscriber list data is cached.
  if ($sublist eq 'MAIN') {
    $data = $addr->retrieve("$self->{name}-subs");
    return $data if $data;

    # Otherwise see if we have enough cached data to tell us whether they're
    # subscribed or not, so we can save a database lookup
    $subs = $addr->retrieve('subs');
    if ($subs) {
      if ($subs->{$self->{name}}) {
        # We know they're a subscriber, so we can actually look up the data
        $out = $self->{'sublists'}{$sublist}->lookup($addr->canon);
        $addr->cache("$self->{name}-subs", $out);
        $log->out('yes-fast');
        return $out;
      }
      else {
        $log->out('no-fast');
        return;
      }
    }
  }

  return unless $self->_make_aux($sublist);

  # We know nothing about the address so we do the lookup
  $out = $self->{'sublists'}{$sublist}->lookup($addr->canon);
  if ($out) {
    $addr->cache("$self->{name}-subs", $out) if ($sublist eq 'MAIN');
    $log->out("yes");
    return $out;
  }
  $log->out("no");
  return;
}

=head2 set(addr, setting, check)

This sets various subscriber data.

If $check is true, we check the validity of the settings but don''t
actually change any values.

If $force is true, we don't check to see if the class or flag setting is in
the allowed set.  This is used if the owner is changing normally off-limits
settings.  

=cut
sub set {
  my $self = shift;
  my $addr = shift;
  my $oset = shift || '';
  my $subl = shift || 'MAIN';
  my $check= shift;
  my $force= shift;
  my $log  = new Log::In 150, "$addr, $oset";
  my (@allowed, @class, @flags, @settings, $baseflag, $carg1, 
      $carg2, $class, $data, $db, $digest, $flags, $i, $inv, $isflag, 
      $j, $key, $list, $mask, $ok, $rset, $set);

  $oset = lc $oset;
  @settings = split(',', $oset);

  unless ($force) {
    # Derive list of allowed settings.
    $mask = $self->get_flags('allowed_flags');
    for $j (sort keys %flags) {
      $baseflag = $flags{$j}->[3];
      if (! $flags{$j}->[1]) {
        # Ordinary flag:  see if it appears in the mask.
        if ($mask =~ /$baseflag/) {
          push @flags, $j;
          push @flags, "no$j" if ($flags{$j}->[2]);
        }
      }
      else {
        # umbrella/inverted flag:  all flags in the group must be set
        $ok = 1;
        for $i (keys %flags) {
          next unless ($flags{$i}->[0] eq $flags{$j}->[0]);
          next if ($flags{$i}->[1]);
          $set = $flags{$i}->[3];
          unless ($mask =~ /$set/) {
            $ok = 0;
            last;
          }
        }
        push @flags, $j if ($ok);
      }
    }
  }
        
   
  # Loop over settings, checking for legality
  for $set (@settings) {
    ($inv = $set) =~ s/^no//;

    @class = split(/-/, $set);

    if (exists $flags{$set}) {
      $rset = $flags{$set}->[0];
      $isflag = $set;
    }
    elsif (exists $flags{$inv}) {
      $rset = $flags{$inv}->[0];
      $isflag = $inv;
    }
    elsif ($rset = $classes{$class[0]}->[0]) {
      $isflag = 0;
    }
    else {
      $log->out("failed, invalid action");
      # XLANG
      return (0, "Invalid setting: $set.\n"); 
    }

    unless ($force) {
      # Check the setting against the allowed group of flags.
      if ($isflag) {
        unless (grep {$_ eq $set} @flags) {
          $baseflag = join "\n               ", @flags;
          # XLANG
          return (0, "Unauthorized flag: $set\nAllowed flags: $baseflag\n");
        }
      }

      # Else it's a class
      else {
	@allowed = keys %{$self->config_get('allowed_classes')};
	# Make sure that one of the allowed classes is at the beginning of
	# the given class.
        unless (grep {$_ eq $rset} @allowed) {
          $data = join " ", @allowed;
          # XLANG
          return (0, "Unauthorized class: $set\nAllowed classes: $data\n");
        }
      }
    }
  }

  return (0, "Unknown auxiliary list name \"$subl\".") 
    unless $self->valid_aux($subl);
  ($key, $data) = $self->get_member($addr, $subl);
    
  unless ($data) {
    $log->out("failed, nonmember");
    $list = $self->{'name'};
    if (length $subl and $subl ne 'MAIN') {
      $list .= ":$subl";
    }
    # XLANG
    return (0, "$addr is not subscribed to the $list list.\n"); 
  }

  # If we were checking and didn't bail, we're done
  if ($check > 0) {
    return (1, {
                flags => $data->{'flags'},
	        class => [$data->{'class'}, 
                          $data->{'classarg'}, 
                          $data->{'classarg2'}],
	       },
	   );
  }

  $digest = '';
  for $set (@settings) {
    # Call make_setting to get a new flag list and class setting
    ($ok, $flags, $class, $carg1, $carg2) =
      $self->make_setting($set, $data->{'flags'}, $data->{'class'},
			  $data->{'classarg'}, $data->{'classarg2'});
    return ($ok, $flags) unless $ok;
    # XLANG
    return (0, "Digest mode is not supported by auxiliary lists.") 
      if ($subl ne 'MAIN' and $class eq 'digest');

    # Issue partial digest if changing from 'digest' to 'each'
    if ($data->{'class'} eq 'digest' 
        and ($class eq 'each' or $class eq 'unique')) {
      $ok = $self->digest_examine($data->{'classarg'});
      if ($ok) {
          $digest = $ok->{$data->{'classarg'}};
          $digest->{'type'} = $data->{'classarg2'};
      }
    }
      
    ($data->{'flags'}, $data->{'class'},
     $data->{'classarg'}, $data->{'classarg2'}) =
       ($flags, $class, $carg1, $carg2);
  }

  $self->{'sublists'}{$subl}->replace("", $key, $data);
  return (1, {flags  => $flags,
	      class  => [$class, $carg1, $carg2],
              digest => $digest,
	     },
	 );
}

=head2 make_setting

This takes a string and a flag list and class info and returns a class,
class arguments, and a new flag list which reflect the information present
in the string.

=cut
use Mj::Util 'str_to_time';
sub make_setting {
  my($self, $str, $flags, $class, $carg1, $carg2) = @_;
  $flags ||= '';
  my $log   = new Log::In 150, "$str, $flags";
  my($arg, $dig, $i, $inv, $isflag, $rset, $set, $time, $type);

  # Split the string on commas; discard empties.  XXX This should probably
  # ignore commas within parentheses.
  for $i (split (/\s*,\s*/, $str)) {
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

    if (exists $flags{$set}) {
      $rset = $flags{$set}->[0];
      $isflag = 1;
    }
    elsif (exists $flags{$inv}) {
      $rset = $flags{$inv}->[0];
      $isflag = 1;
    }
    elsif ($rset = $classes{$set}->[0]) {
      $isflag = 0;
    }
    else {
      $log->out("failed, invalid action");
      return (0, "Invalid setting: $set.\n"); # XLANG
    }

    if ($isflag) {
      # Process flag setting; remove the flag from the list
      if (exists $flags{$inv} and $flags{$inv}->[1] == 0) {
        # Convert umbrella flag (ackall or ackimportant) to
        # its constituent flags.
        if ($flags{$rset}->[1] == 2 and $flags =~ /$flags{$rset}->[3]/i) {
          $flags =~ s/$flags{$rset}->[3]//ig;
          for (keys %flags) {
            if (($flags{$_}->[0] eq $flags{$rset}->[0])
                and ($flags{$_}->[1] == 0)) {
              $flags .= $flags{$_}->[3]
                unless ($flags =~ /$flags{$_}->[3]/);
            }
          }
        }
        # Ordinary flags are cleared individually.
        $flags =~ s/$flags{$inv}->[3]//ig;
      }
      else {
        # Remove all in group ('noack' and 'ackall' clear all ack flags)
        for (keys %flags) {
          if ($flags{$_}->[0] eq $flags{$rset}->[0] and $flags{$_}->[3]) {
            $flags =~ s/$flags{$_}->[3]//ig; 
          }
        } 
      }
      # Add the new flag (which may be null)
      if (exists $flags{$set}) {
        if ($flags{$set}->[1] == 2) {
          # umbrella (ackall: set all ack flags in the ack group)
          for (keys %flags) {
            if ($flags{$_}->[0] eq $flags{$rset}->[0] 
                and $flags{$_}->[1] == 0) {
              $flags .= $flags{$_}->[3]; 
            }
          } 
        }
        else {
          $flags .= $flags{$set}->[3];
        }
      }
    }
    else {
      # Process class setting

      # Just a plain class
      if ($classes{$rset}->[1] == 0) {
	$class = $rset;
	$carg1 = $carg2 = '';
      }

      # A class taking a time (nomail/vacation/mail)
      elsif ($classes{$rset}->[1] == 1) {
	# If the class is 'nomail-return' or 'mail', return
        # to the saved settings, if there were any; otherwise,
        # use the 'each' class.
	if ($arg eq 'return') {
	  return (0, "No saved settings to return to.\n")
	    unless $carg2;
        }

	if ($arg eq 'return' or $rset eq 'mail') {
	  return (0, "Not currently in nomail mode.\n")
	    unless $classes{$class}->[0] eq 'nomail';

	  ($class, $carg1, $carg2) = split("\002", $carg2);
	  $class = 'each' unless defined($class) && $classes{$class};
	  $carg1 = ''     unless defined($carg1);
	  $carg2 = ''     unless defined($carg2);
	}

	# Convert arg to time;
	else {
	  # Eliminate recursive stacking if a user already on 
	  # vacation sets vacation again; just update the time and
	  # don't save away the class info.
	  if ($class and $classes{$class}->[0] ne 'nomail') {
            # Save the old class info
	    $carg2 = join("\002", $class, $carg1, $carg2); 
	  }
          if ($arg) {
            $carg1 = str_to_time($arg);
            return (0, "Invalid time $arg.\n") unless $carg1; # XLANG
          }
          else {
            $carg1 = '';
          }
	  $class = $rset;
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
	    unless $dig->{lc $arg};
	  return (0, "Illegal digest type: $type.\n") #XLANG
	    unless $digest_types{lc $type};
	}
	else {
	  $arg  = $dig->{'default_digest'};
	  $type = $dig->{$arg}{'type'} || 'mime';
	}
	$class = "digest";
	$carg1 = lc $arg;
	$carg2 = lc $type;
      }
    }
  }
  return (1, $flags, $class, $carg1, $carg2);
}

=head2 _digest_classes

This returns a list of all full digest classes

=cut
sub _digest_classes {
  my $self = shift;
  my ($digests, $i, $j, @out);

  $digests = $self->config_get('digests');
  return unless (ref $digests eq 'HASH');

  for $i (keys %$digests) {
    for $j (keys %digest_types) {
      push @out, "digest-$i-$j";
    }
  }
  @out;
}

=head2 should_ack (sublist, victim, flag)

Determine whether or not a particular action (deny, stall, succeed, reject)
should cause an acknowledgement to be sent to the victim.

=cut
sub should_ack {
  my $self    = shift;
  my $sublist = shift || 'MAIN';
  my $victim  = shift; 
  my $flag    = shift;
  my ($data);

  $data = $self->get_member($victim, $sublist);

  unless (defined $data) {
    $data = {};
    $data->{'flags'} = $self->get_flags('nonmember_flags');
  }
  # Ack if the victim has the (deprecated) 'ackall' or 'ackimportant' setting.
  return 1 if ($data->{'flags'} =~ /A/i);
  # Ack if victim has requested the flag explicitly.
  return 1 if ($data->{'flags'} =~ /$flag/);
  0;
}

=head2 default_class

This returns the default subscription class for new subscribers.

This should be a per-list variable.

=cut
sub default_class {
  my $self = shift;
  my $class = $self->config_get('default_class');
  my ($carg1, $carg2, $ok);

  ($ok, undef, $class, $carg1, $carg2) = $self->make_setting($class);
  return ($class, $carg1, $carg2) if $ok;
  return ('each', '', '');
}

=head2 get_flags 

This returns the default, allowed, or nonmember flags 
as a string of abbreviations.

This should be a per-list variable, or a whole set of list variables.

=cut
sub get_flags {
  my $self = shift;
  my $setting = shift;
  my (@newvalues, $f, $out, $values);

  $values = $self->config_get($setting);
  if (ref $values eq 'HASH') {
    $out = '';
    for $f (keys %$values) {
      $out .= $flags{$f}->[3];
    }

    return $out;
  }
  else {
    # Get the unparsed value.
    $values = $self->config_get($setting, 1);
    $values =~ s/[Aa]/bdfj/;
    @newvalues = $self->describe_flags($values, 1);
    $self->config_set($setting, @newvalues);
    $self->config_unlock;
    return $values;
  }
}

=head2 flag_set(flag, address, sublist)

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
  my $sublist = shift || 'MAIN';
  my $force= shift;
  my $log  = new Log::In 150, "$flag, $addr";
  $log->out('no');
  my ($flags, $data);
  return unless $flags{$flag};
  return 0 unless $addr->isvalid;

  $flags = $addr->retrieve("$self->{name}-flags")
    unless ($sublist eq 'MAIN');

  if ($force || ! defined($flags)) {
    $data = $self->is_subscriber($addr, $sublist);
    if ($data) {
      $flags = $data->{flags};
    }
    else {
      $flags = $self->get_flags('nonmember_flags');
    }
    $addr->cache("$self->{name}-flags", $flags)
      unless defined $sublist;
  }

  return 0 unless $flags =~ /$flags{$flag}[3]/;
  $log->out('yes');
  1;
}

=head2 describe_flags(flag_string)

This returns a list of strings which give the names of the flags set in
flag_string.

=cut
sub describe_flags {
  my $self    = shift;
  my $flags   = shift || "";
  my $noneg   = shift || "";
  my %nodesc  = reverse %noflags;
  my (%desc, @out, $i, $seen);

  # XXX This routine is written as an object method.  It
  # could be rewritten as a simple routine unless some
  # list-specific data (such as language) can vary the output.

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
      next if $noneg;
      unless ($flags{$desc{$i}}->[1] == 2 || $seen =~ /$i/i || $flags =~ /$i/i) {
	push @out, $nodesc{$i} || "no$desc{$i}"; # XLANG
	$seen .= $i;
      }
    }
  }
  @out;
}

=head2 describe_class(class)

This returns a textual description for a subscriber class.

If as_setting is true, the description returned is in the form taken by the
set command.

=cut
use Mj::Util 'time_to_str';
sub describe_class {
  my $self  = shift;
  my $class = shift;
  my $arg1  = shift;
  my $arg2  = shift;
  my $as_setting = shift;
  my($dig, $time, $type);

  if ($class eq 'digest') {
    $dig = $self->config_get('digests');
    if ($dig->{$arg1}) {
      return $as_setting? "$class-$arg1-$arg2" :
	$dig->{$arg1}{'desc'};
    }
    else {
      return "Undefined digest." # XLANG
    }
  }

  if ($classes{$class}->[1] == 0) {
    return $as_setting? $class : $classes{$class}->[2];
  }
  if ($classes{$class}->[1] == 1) {
    # nomail setting
    if ($arg1) {
      if ($as_setting) {
        return sprintf "$class-%s", time_to_str($arg1 - time);
      }
      else { 
        $time = localtime($arg1);
        return "$classes{$class}->[2] until $time"; # XLANG
      }
    }
    return $as_setting? $class : $classes{$class}->[2];
  }
  return $classes{$class}->[2];
}

=head2 get_setting_data()

Return a hashref containing complete data about settings:
  name, description, availability, abbreviations, defaults

=cut
sub get_setting_data {
  my $self = shift;
  my $log = new Log::In 150;
  my (@classes, $allowed, $class, $dd, $dfl, $dig, $flag, 
      $flagmask, $i, $out);

  $out = { 'classes' => [], 'flags' => [] };

  $flagmask = $self->get_flags('allowed_flags');
  $dfl = $self->get_flags('default_flags');

  $i = 0;
  for $flag (sort keys %flags) {
    next unless ($flags{$flag}->[1] == 0);

    $class = $flags{$flag}->[3];
    $allowed = ($flagmask =~ /$class/)? $flag : '';
    $out->{'flags'}[$i]->{'allow'}  = $allowed;
    $allowed = ($dfl =~ /$class/)? 1 : 0;
    $out->{'flags'}[$i]->{'default'}  = $allowed;
    $out->{'flags'}[$i]->{'name'}   = $flag;
    $out->{'flags'}[$i]->{'abbrev'} = $flags{$flag}->[3];

    $i++;
  }  

  @classes = keys %{$self->config_get('allowed_classes')};
  $dfl = $self->config_get('default_class');
  $dd = '';

  $i = 0;
  for $flag (sort keys %classes) {
    # skip aliases
    next unless ($classes{$flag}->[0] eq $flag);

    $allowed = grep { $_ eq $flag } @classes;

    if ($flag eq 'digest') {
      $dig = $self->config_get('digests');
      if ($dfl eq 'digest') {
        $dd = $dig->{'default_digest'};
      }
      
      for $class (sort keys %$dig) {
        next if ($class eq 'default_digest');
        $out->{'classes'}[$i]->{'name'}  = "digest-$class";
        $out->{'classes'}[$i]->{'allow'} = $allowed;
        $out->{'classes'}[$i]->{'default'} = 
          ($class eq $dd) ? 1 : 0;
        $out->{'classes'}[$i]->{'desc'}  = $dig->{$class}{'desc'};
        $i++;
      }
    }
    else {
      $out->{'classes'}[$i]->{'name'}  = $flag;
      $out->{'classes'}[$i]->{'allow'} = $allowed;
      $out->{'classes'}[$i]->{'default'} = 
        ($flag eq $dfl) ? 1 : 0;
      $out->{'classes'}[$i]->{'desc'}  = $classes{$flag}->[2];
      $i++;
    }
  }

  $out;
}

=head2 get_start()

Begin iterating over a list of subscribers.

=cut
sub get_start {
  my $self    = shift;
  my $sublist = shift || 'MAIN';
  return (0, "Unable to access subscriber list $sublist")
    unless $self->valid_aux($sublist);
  return (0, "Unable to initialize subscriber list $sublist")
    unless $self->_make_aux($sublist);
  $self->{'sublists'}{$sublist}->get_start;
}

=head2 get_chunk(max_size)

Returns an array of subscriber data hashrefs of a certain maximum size.

=cut
sub get_chunk {
  my $self    = shift;
  my $sublist = shift || 'MAIN';
  my (@addrs, @out, $k, $v);

  return unless (exists $self->{'sublists'}{$sublist});
  @addrs = $self->{'sublists'}{$sublist}->get(@_);
  while (($k, $v) = splice(@addrs, 0, 2)) {
    $v->{'canon'} = $k;
    push @out, $v;
  }
  return @out;
}

=head2 get_matching_chunk(max_size, field, value)

Returns an array of (key, hashref) pairs of max_size size of subscribers
(and data) with data field $field eq $value.

=cut
sub get_matching_chunk {
  my $self    = shift;
  my $sublist = shift || 'MAIN';
  return unless (exists $self->{'sublists'}{$sublist});
  $self->{'sublists'}{$sublist}->get_matching(@_);
}

=head2 get_done()

Closes the iterator.

=cut
sub get_done {
  my $self    = shift;
  my $sublist = shift || 'MAIN';
  return unless (exists $self->{'sublists'}{$sublist});
  $self->{'sublists'}{$sublist}->get_done;
}

=head2 search(string, mode)

This searches the full addresses for a match to a string or regexp.  The
iterator must be opened before doing this.

Regexp matching is done sensitive to case.  This is Perl5; if you don''t want
that, use (?i).

This returns a list of (key, data) pairs.

=cut
sub search {
  my $self    = shift;
  my $sublist = shift || 'MAIN';
  my $string  = shift;
  my $mode    = shift;
  my $count   = shift || 1;

  return unless (exists $self->{'sublists'}{$sublist});
  if ($mode =~ /regex/) {
    return ($self->{'sublists'}{$sublist}->get_matching_regexp($count, 
                                             'fulladdr', $string));
  }
  return ($self->{'sublists'}{$sublist}->get_matching_regexp($count, 
                                           'fulladdr', "\Q$string\E"));
}

=head2 get_member(address)

This takes an address and returns the member data for that address, or
undef if the address is not a member.

This will reset the list iterator.

=cut
sub get_member {
  my $self    = shift;
  my $addr    = shift;
  my $sublist = shift || 'MAIN';
  
  return (0, "Unable to access subscriber list $sublist")
    unless $self->_make_aux($sublist);
  return ($addr->canon, $self->{'sublists'}{$sublist}->lookup($addr->canon));
}

=head2 count_subs {

  Counts the number of entries in a subscriber database.

=cut
sub count_subs {
  my $self    = shift;
  my $sublist = shift || 'MAIN';
  my (@count);
  my ($total) = 0;
 
  return unless $self->get_start($sublist);
  while (@count = $self->{'sublists'}{$sublist}->get_quick(1000)) {
    $total += scalar @count;
  }
  $self->get_done($sublist);
  $total;
}


=head2 rekey(registry)

This regenerates the keys for the databases from the stripped addresses in
the event that the transformation rules change.

=cut
sub rekey {
  my $self = shift;
  $self->aux_rekey_all(@_);
}

=head2 aux_rekey_all(registry)

This rekeys all auxiliary lists associated with a list.

=cut
sub aux_rekey_all {
  my $self = shift;
  my (@values, $count, $i, $unsub, $unreg);

  $self->_fill_aux;
  for $i (keys %{$self->{'sublists'}}) {
    @values = $self->aux_rekey($i, @_);
    if ($i eq 'MAIN') {
      ($count, $unsub, $unreg) = @values;
    }
  }
  ($count, $unsub, $unreg);
}

=head2 aux_rekey(name, registry)

This rekeys a single auxiliary file.

=cut
sub aux_rekey {
  my $self = shift;
  my $name = shift;
  my $reg = shift;
  my $chunksize = shift;
  my (%regent, %unreg, @subs, $count);

  $count = 0;
  %regent = ();
  %unreg = ();

  if (ref $reg and $name eq 'MAIN') {
    if ($reg->get_start) {
      while (1) {
        @subs = $reg->get_matching_quick_regexp($chunksize, 
                                               'lists',
                                               "/\\b$self->{'name'}(\\002|\\Z)/");
        last unless @subs;
        @regent{@subs} = ();
      }
      $reg->get_done;
    }
  }
  
  my $sub =
    sub {
      my $key  = shift;
      my $data = shift;
      my (@out, $addr, $newkey, $changekey);

      # Allocate an Mj::Addr object from the canonical address.
      $addr = new Mj::Addr($key);
      return (1, 0, undef) unless $addr;
      # return (1, 0, undef) unless $addr->valid;
      $newkey = $addr->xform;
      $changekey = ($newkey ne $key or (! $data->{'class'}));

      # Enable transition from old AddressList to new SubscriberList
      $data->{'subtime'}  ||= $data->{'changetime'};
      $data->{'fulladdr'} ||= $data->{'stripaddr'};
      $data->{'class'}    ||= 'each';
      $data->{'flags'}    ||= $self->get_flags('default_flags');

      if (ref $reg and $name eq 'MAIN') {
        if (exists $regent{$newkey}) {
          delete $regent{$newkey};
          $count++;
        }
        else {
          $unreg{$newkey}++;
        }
      }
      else {
        $count++; 
      }

      return ($changekey, $data, $newkey);
    };

  $self->_make_aux($name);
  $self->{'sublists'}{$name}->mogrify($sub);
  return ($count, \%regent, \%unreg);
}


=head2 _fill_config

This fills in the hash of auxiliary configuration settings associated 
with a List object.  Only preexisting files are accounted for; 
others can be created at any time.  This does not actually create 
the objects, only the hash slots, so that they can be tested for with exists().

=cut
use Symbol;
sub _fill_config {
  my $self = shift;

  # Bail early if we don't have to do anything
  return 1 if $self->{'config_loaded'};
  
  $::log->in(120);

  my $dirh = gensym();
  my ($file);
  
  my $listdir = $self->_file_path;
  opendir($dirh, $listdir) || $::log->abort("Error opening $listdir: $!");

  while (defined($file = readdir $dirh)) {
    if ($file =~ /^C([a-z0-9\._\-]+)$/) {
      $self->{'templates'}{$1} = undef;
    }
  }
  closedir($dirh);
  
  $self->{'config_loaded'} = 1;
  $::log->out;
  1;
}

=head2 _fill_aux

This fills in the hash of auxiliary lists associated with a List object.
Only preexisting lists are accounted for; others can be created at any
time.  This does not actually create the objects, only the hash slots, so
that they can be tested for with exists().

=cut
use Symbol;
sub _fill_aux {
  my $self = shift;

  # Bail early if we don't have to do anything
  return 1 if $self->{'aux_loaded'};
  
  $::log->in(120);

  my $dirh = gensym();
  my ($file);
  
  my $listdir = $self->_file_path;
  opendir($dirh, $listdir) || $::log->abort("Error opening $listdir: $!");

  while (defined($file = readdir $dirh)) {
    if ($file =~ /^X(.*)\..*/) {
      $self->{'sublists'}{$1} = undef;
    }
  }
  closedir($dirh);
  
  $self->{'aux_loaded'} = 1;
  $::log->out;
  1;
}

=head2 moderators($group)

Returns an array of addresses corresponding to the list moderators.
In decreasing order, the sources are:
  The "moderators" or another, named auxiliary list.
  The "moderators" configuration setting.
  The "moderator" configuration setting.
  The "sender" configuration setting.

=cut

sub moderators {
  my $self = shift;
  my $group = shift;
  my (@addr, @out, $i);

  $self->_fill_aux;
  unless (defined $group and exists $self->{'sublists'}{$group}) {
    $group = 'moderators';
  }
  if (exists $self->{'sublists'}{$group}) {
    return unless $self->get_start($group);
    while (@addr = $self->get_chunk($group, 4)) {
      for $i (@addr) {
        push @out, $i->{'stripaddr'} if ($i->{'class'} ne 'nomail');
      }
    }
    return @out if (scalar @out);
  }
  @out = @{$self->config_get('moderators')};
  return @out if (scalar @out);
  $self->config_get('moderator') || $self->config_get('sender');
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
  my $list = shift || '';
  my $log  = new Log::In 150, $rec;
  my ($data, $ndata, $ok);

  return (0, "Unable to access duplicate database $type.\n")
    unless  $self->_make_dup($type);

  $data = {};
  ($rec) = $rec =~ /(.*)/; # Untaint

  if ($self->{'name'} eq 'GLOBAL') {
    $data = $self->{'dup'}{$type}->lookup($rec);
    if ($data) {
      $ndata = $data;
      $ndata->{'lists'} .= "\002$list";
      ($ok, $ndata) = $self->{'dup'}{$type}->replace('', $rec, $ndata);
    }
    else {
      $ndata = { 'lists' => $list };
      ($ok, $ndata) = $self->{'dup'}{$type}->add('', $rec, $ndata);
    }
  }
  else {  
    ($ok, $data) = $self->{'dup'}{$type}->add("", $rec, {});
  }

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

  return @nuked;
}

=head2 post_add

Add a post event to the post database, and return the parsed
data.

=cut
sub post_add {
  my($self, $addr, $time, $type, $number) = @_;
  my $log = new Log::In 150, "$time #$number";
  my($data, $event, $ok);

  $self->_make_post_data;
  return unless $self->{'posts'};

  $event = "$time$type$number";
  $data = $self->{'posts'}->lookup($addr->canon);
  if ($data) {
    $data->{'postdata'} .= " $event";
    $self->{'posts'}->replace('', $addr->canon, $data);
  }
  else {
    $data = {};
    $data->{'postdata'} = $event;
    $self->{'posts'}->add('', $addr->canon, $data);
  }
}

=head2 get_post_data



=cut
sub get_post_data {
  my $self = shift;
  my $addr = shift;
  my (@msgs);

  $self->_make_post_data;
  return unless $self->{'posts'};

  my $data = $self->{'posts'}->lookup($addr->canon);
  if ($data) {
    @msgs = split ' ', $data->{'postdata'};
    $data = {};
    for (@msgs) {
      if ($_ =~ /(\d+)\w(\d+)/) {
        $data->{$2} = $1;
      }
    }
  }
  $data;
}

=head2 expire_post_data

This expires old data about posted messages.

=cut
sub expire_post_data {
  my $self = shift;
  # XXX Use twice the lifetime of duplicates.
  my $expiretime = time - $self->config_get('dup_lifetime') * 2*60*60*24;

  $self->_make_post_data;
  return unless $self->{'posts'};

  my $mogrify = sub {
    my $key  = shift;
    my $data = shift;
    my (@b1, @b2, $b, $t);

    # Fast exit if we have no post data
    return (0, 0) if !$data->{postdata};

    # Expire old posted message data.
    @b1 = split(/\s+/, $data->{postdata});
    while (1) {
      $b = pop @b1; last unless defined $b;
      ($t) = $b =~ /^(\d+)\w/;
      next if $t < $expiretime;
      push @b2, $b; 
    }
    $data->{postdata} = join(' ', @b2);

    # Update if necessary
    if (@b2) {
      return (0, 1, $data);
    }
    return (0, 0);
  };

  $self->{'posts'}->mogrify($mogrify);
}

=head2 expire_subscriber_data

This converts members with timed nomail classes back to their old class
when the vacation time is passed and removes old bounce data.

=cut
sub expire_subscriber_data {
  my $self = shift;
  my $time = time;
  my $maxbouncecount = $self->config_get('bounce_max_count');
  my $maxbounceage   = $self->config_get('bounce_max_age') * 60*60*24;
  my $bounceexpiretime = $time - $maxbounceage;
  my $ali;

  my $mogrify = sub {
    my $key  = shift;
    my $data = shift;
    my (@b1, @b2, $a1, $a2, $b, $c, $e, $u1, $u2, $t);

    # True if we have an expired timer
    $e = ($data->{class} eq 'nomail' &&
	  $data->{classarg}          &&
	  $time > $data->{classarg}
	 );

    # Fast exit if we have no expired timers and no bounce data
    return (0, 0) if !$e && !$data->{bounce};
    if ($e) {
      # Now we know we must expire; extract the args
      ($c, $a1, $a2) = split("\002", $data->{classarg2});
      $data->{'class'}     = defined $c  ? $c  : 'each';
      $data->{'classarg'}  = defined $a1 ? $a1 : '';
      $data->{'classarg2'} = defined $a2 ? $a2 : '';
      $u1 = 1;
    }

    # Expire old bounce data.
    if ($data->{bounce}) {
      @b1 = split(/\s+/, $data->{bounce});
      @b2 = ();
      $c = 0;
      while (1) {

	# Stop now if we have too many bounces
	if ($c >= $maxbouncecount) {
	  $u2 = 1;
	  last;
	}

	$b = pop @b1; last unless defined $b;
	($t) = $b =~ /^(\d+)\w/;
	if ($t < $bounceexpiretime) {
	  $u2 = 1;
	  next;
	}
	unshift @b2, $b; $c++;
      }
      $data->{bounce} = join(' ', @b2) if $u2;
    }

    # Update if necessary
    if ($u1 || $u2) {
      return (0, 1, $data);
    }
    return (0, 0);
  };

  # If the list is configured to allow posting to 
  # auxiliary lists, the subscriber data for
  # them must be expired as well.
  $self->_fill_aux;
  for (keys %{$self->{'sublists'}}) {
    next unless $self->_make_aux($_);
    $self->{'sublists'}{$_}->mogrify($mogrify);
  }
  1;
}

=head2 _make_config (private)

This makes executes a config file and stuffs it into the List''s collection.
This must be called before any function which accesses the settings.

=cut
sub _make_config {
  my $self = shift;
  my $name = shift;

  $name =~ /([\w\-\.]+)/; $name = $1;
  return unless $name;

  unless (defined $self->{'templates'}{$name}) {
    $self->{'templates'}{$name} = 
      new Mj::Config
      (
       list        => $self->{'name'},
       name        => $name,
       dir         => $self->{'ldir'},
       callbacks   => $self->{'config'}->{'callbacks'},
       defaultdata => { 'raw' => {} },
       installdata => $self->{'config'}->{'source'}{'installation'},
      );
  }
  1;
}

=head2 _make_aux (private)

This makes a SubscriberList object and stuffs it into the List''s collection.
This must be called before any function which accesses the SubscriberList.

=cut
sub _make_aux {
  my $self = shift;
  my $name = shift;

  unless (defined $self->{'sublists'}{$name}) {
    $self->{'sublists'}{$name} =
      new Mj::SubscriberList (
                              'backend' => $self->{'backend'},
                              'domain'  => $self->{'domain'},
                              'file'    => "X$name", 
                              'list'    => $self->{'name'},
                              'listdir' => $self->{'ldir'},
                             );
  }
  1;
}

=head2 valid_aux

Verify the existence of an auxiliary list.  

=cut
sub valid_aux {
  my $self = shift;
  my $name = shift;

  $self->_fill_aux;
  if (exists $self->{'sublists'}{$name}) {
    # Untaint
    $name =~ /(.*)/; $name = $1;
    return $name;
  }
  return;
}


=head2 valid_config

Verify the existence of a configuration template.  

=cut
sub valid_config {
  my $self = shift;
  my $name = shift || 'MAIN';

  $self->_fill_config;
  if (exists $self->{'templates'}{$name}) {
    # Untaint
    $name =~ /(.*)/; $name = $1;
    return $name;
  }
  return;
}

=head2 _make_fs

Makes a filespace object.

=cut
use Mj::FileSpace;
sub _make_fs {
  my $self = shift;
  return 1 if $self->{'fs'};

  my $dir = $self->_file_path("files");
  return unless $dir;

  $self->{'fs'} = new Mj::FileSpace($dir, $self->{backend});
  return unless $self->{'fs'};
  1;
}

=head2 _make_bounce

This makes a small database for storing bounce data collected from
addresses which aren't list members.

=cut
use Mj::SimpleDB;
sub _make_bounce {
  my $self = shift;

  return 1 if $self->{bounce};

  my @fields = qw(bounce diagnostic);

  $self->{bounce} =
    new Mj::SimpleDB(filename => $self->_file_path("_bounce"),
		     backend  => $self->{backend},
		     fields   => \@fields,
		    );
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

  my @fields;
  if ($self->{'name'} eq 'GLOBAL') {
    @fields = qw(lists changetime);
  }
  else {
    @fields = qw(changetime);
  }
   

  $self->{'dup'}{$type} =
    new Mj::SimpleDB(filename => $self->_file_path("_dup_$type"),
		     backend  => $self->{backend},
		     fields   => \@fields,
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

=head2 _make_post_data

This opens the post database.

Note that we really should not be specifying a comparison function, but
since originally this was built on a Mj::AddressList and the post data
stored in the comment field, the format of the database needed to be
preserved.

=cut
sub _make_post_data {
  my $self = shift;
  return 1 if $self->{'posts'};

  $self->{'posts'} =
    new Mj::SimpleDB(filename => $self->_file_path("_posts"),
		     backend  => $self->{'backend'},
		     compare  => sub {reverse($_[0]) cmp reverse($_[1])},
		     fields   => [qw(dummy postdata changetime)],
		    );
}

=head1 Miscellaneous functions

Config modification, access checking, special bootstrapping functions for
the Majordomo object.

=head2 set_config

Choose the configuration file to be used by default

=cut
sub set_config {
  my $self = shift;
  my $name = shift || 'MAIN';

  if ($name eq 'MAIN') {
    $self->{'config'} = $self->{'templates'}{'MAIN'};
    return 1;
  }
  
  return unless $self->_make_config($name);
  $self->{'config'} = $self->{'templates'}{$name};
  1;
}

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
  my $self = shift;

  $self->{'config'}->set_to_default(@_);
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

sub config_regen {
  shift->{'config'}->regen;
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

sub config_get_whence {
  my $self = shift;
  my $var  = shift;
  $self->{'config'}->whence($var);
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

sub archive_get_to_file {
  my $self = shift;
  return unless $self->_make_archive;
  $self->{'archive'}->get_to_file(@_);
}

sub archive_expand_range {
  my $self = shift;
  return unless $self->_make_archive;
  $self->{'archive'}->expand_range(@_);
}

sub archive_delete_msg {
  my $self = shift;
  return unless $self->_make_archive;
  $self->{'archive'}->remove(@_);
}

sub archive_find {
  my $self = shift;
  my $patt = shift;
  my ($ok, $mess, $regex) = Mj::Config::compile_pattern($patt, 0, "exact");
  return ($ok, $mess) unless $ok;
  return unless $self->_make_archive;
  $self->{'archive'}->find($regex);
}

sub archive_summary {
  my $self = shift;
  return unless $self->_make_archive;
  $self->{'archive'}->summary(@_);
}

sub archive_sync {
  my $self = shift;
  my $qp = $self->config_get('quote_pattern');
  return unless $self->_make_archive;
  $self->{'archive'}->sync(@_, $qp);
}

sub count_posts {
  my $self = shift;
  my $days = shift;
  my $sublist = shift || '';
  my (@msgs) = ();
  my ($tmp) = (length $sublist)? "$sublist." : '';
  return 0 unless (defined $days and $days > 0);
  return 0 unless $self->_make_archive;
  @msgs = $self->{'archive'}->expand_range(0, $sublist . $days . "d");
  return scalar @msgs;
}


=head1 Digest functions

These functions interface with the list''s Digest object.

=head2 digest_build

Builds a digest.

=cut
use Mj::Digest::Build;
sub digest_build {
  my $self = shift;
  return unless $self->_make_archive;
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
  return unless $self->_make_digest;
  $self->{digest}->add(@_);
}

=head2 digest_trigger

Trigger a digest.  This does what digest_add does, but instead of adding a
message it just checks to see if a digest should be sent.  The return is
the same as digest_add.

=cut
sub digest_trigger {
  my $self = shift;
  return unless $self->_make_digest;
  $self->{digest}->trigger(@_);
}

=head2 digest_examine

Examine the current state of the digests without making any changes.

=cut
sub digest_examine {
  my $self = shift;
  return unless $self->_make_digest;
  $self->{digest}->examine(@_);
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

=head1 Bounce data functions

These involve manipulating per-user bounce data.

=head2 bounce_get

Retrieves the stored bounce data and returns it in parsed format.  Will use
cached data unless $force is true.

=cut
sub bounce_get {
  my $self = shift;
  my $addr = shift;
  my $force= shift;
  my ($data);

  # First look for cached data
  $data = $addr->retrieve("$self->{name}-subs");
  if ($force || !$data) {
    $data = $self->is_subscriber($addr);
  }

  # OK, user isn't a subscriber, but we still might have some data saved
  if (!$data) {
    $self->_make_bounce;
    $data = $self->{bounce}->lookup($addr->canon);
  }

  return unless $data && $data->{bounce};
  return $self->_bounce_parse_data($data->{bounce});
}

=head2 bounce_add

Add a bounce event to a user's saved bounce data, and return the parsed
data.

Takes a hash:

addr   - bouncing address
time   - time of bounce event
type   - type of bounce event
evdata - event data (message number, token, etc.)
subbed - true if user is subscribed

=cut
sub bounce_add {
  my($self, %args) = @_;
  my $log = new Log::In 150, "$args{time} T$args{type} #$args{evdata}";

  my($bouncedata, $event, $ok);

  $event = "$args{time}$args{type}$args{evdata}";
  my $repl = sub {
    my $data = shift;

    if ($data->{bounce}) {
      # Some types go first, to make expiry simpler
      if ($args{type} eq 'C' or $args{type} eq 'P') {
	$data->{bounce} = "$event $data->{bounce}";
      }
      else {
	$data->{bounce} .= " $event";
      }
    }
    else {
      $data->{bounce} = $event;
    }

    if ($args{diag}) {
      $data->{diagnostic} = substr ($args{diag}, 0, 160);
      $data->{diagnostic} =~ s/\001/X/g;
    }

    $bouncedata = $data->{bounce};
    $data;
  };

  # For subscribed users, modify their bounce data
  if ($args{subbed}) {
    $ok = $self->{'sublists'}{'MAIN'}->replace('', $args{addr}->canon, $repl);
  }
  # For unsubscribed users, we keep a bit of data in a separate database.
  else {
    $self->_make_bounce;
    # Add a blank entry, just to make sure one is there
    $self->{bounce}->add('', $args{addr}->canon, {});
    $ok = $self->{bounce}->replace('', $args{addr}->canon, $repl);
  }
  return $self->_bounce_parse_data($bouncedata) if $ok;
  return;
}

=head2 _bounce_parse_data

This takes apart a string of bounce data.  The string is simply a set of
space-separated bounce incidents; each incident contains minimal
information about a bounce: the time and the message numbers.  There may
also be other data there depending on what bounces were detected.

An incident is formatted like:

timeMnumber
timeMnumber,sessionid
timeCtoken
timePtoken

where 'time' is the numeric cound of seconds since the epoch, 'M' indicates
a message bounce, 'number' indicates the message number and sessionid, if
present, indicates the SessionID of the bounce (so that the text of the
bounce can be retrieved using the sessioninfo command).  'C' indicates that
a consult token was issued for the deletion of the bouncing address, while
'P' indicates that a probe was issued against the bounding address.
'token' indicates the token number used for the consultation or probe.

Some bounces have a type but no message number.  There are stored under
separate hash keys ("U$type") in flat lists.

=cut
sub _bounce_parse_data {
  my $self = shift;
  my $data = shift;
  my (@incidents, $i, $number, $out, $time, $type);

  $out = {};
  @incidents = split(/\s/, $data);

  for $i (@incidents) {
    ($time, $type, $number) = $i =~ /^(\d+)(\w)(.*)$/;
    if ($number) {
      $out->{$type}{$number} = $time;
    }
    else {
      $out->{"U$type"} ||= ();
      push @{$out->{"U$type"}}, $time;
    }
  }

  $out;
}

=head2 bounce_gen_stats

Generate a bunch of statistics from a set of bounce data.

Things generated:

number of bounces in last day
                          week
                          month
number of consecutive bounces
percentage of bounced messages

The first three are generated using only the collected bounce times.  The
last two are generated using bounces for which message numbers were
collected and require a pool of that type bounce (two and five, resp.)
before any statistics are generated.

=cut
sub bounce_gen_stats {
  my $self = shift;
  my $bdata = shift;
  my $now = time;
  my (@numbered, @times, $do_month, $i, $lastnum, $maxbounceage,
      $maxbouncecount, $seqendtime, $seqstarttime, $stats);

  # Initialize $stats
  $stats = {
	    bouncedpct       => 0,
	    consecutive      => 0,
	    consecutive_days => 0,
	    day              => 0,
	    day_overload     => '',
	    week             => 0,
	    week_overload    => '',
	    maxcount         => 0,
	    month            => 0,
	    month_overload   => '',
	    numbered         => 0,
	    span             => 0,
	   };

  # No bounce data?  Return empty statistics.
  return $stats unless $bdata;

  # We don't do a monthly view unless we're collecting a month's worth
  $maxbounceage   = $self->config_get('bounce_max_age');
  $maxbouncecount = $self->config_get('bounce_max_count');
  if ($maxbounceage >= 30) {
    $do_month = 1;
  }

  @numbered = sort {$a <=> $b} keys(%{$bdata->{M}});
  if (@numbered) {
    $stats->{span} = $numbered[$#numbered] - $numbered[0] + 1;
  }

  $seqstarttime = $seqendtime = 0;
  for $i (@numbered) {
    push @times, $bdata->{M}{$i};
    $stats->{numbered}++;
    if (!defined($lastnum) || $i == $lastnum+1) {
      $lastnum = $i;
      $stats->{consecutive}++;
      $seqendtime = $bdata->{M}{$i};
      $seqstarttime ||= $bdata->{M}{$i}
    }
    else {
      undef $lastnum;
      $seqstarttime = $seqendtime = $bata->{M}{$i};
      $stats->{consecutive} = 1;
    }
  }
  $stats->{consecutive_days} = ($seqendtime - $seqstarttime) / (24*60*60);

  if ($stats->{numbered} && $stats->{span}) {
    $stats->{bouncedpct} = int(.5 + 100*($stats->{numbered} / $stats->{span}));
  }

  $stats->{maxcount} = $maxbouncecount;

  # Extract breakdown by time
  for $i (@{$bdata->{UM}}, @times) {
    if (($now - $i) < 24*60*60) { # one day
      $stats->{day}++;
    }
    if (($now - $i) < 7*24*60*60) {
      $stats->{week}++;
    }
    if ($do_month && ($now - $i) < 30*24*60*60) {
      $stats->{month}++;
    }
  }
  $stats->{day_overload}   = ($stats->{day}   >= $maxbouncecount)?'>':'';
  $stats->{week_overload}  = ($stats->{week}  >= $maxbouncecount)?'>':'';
  $stats->{month_overload} = ($stats->{month} >= $maxbouncecount)?'>':'';

  $stats;
}

=head2 expire_bounce_data

This converts members with timed nomail classes back to their old class
when the vacation time is passed and removes old bounce data.

=cut
sub expire_bounce_data {
  my $self = shift;
  my $time = time;
  my $maxbouncecount = $self->config_get('bounce_max_count');
  my $maxbounceage   = $self->config_get('bounce_max_age') * 60*60*24;
  my $bounceexpiretime = $time - $maxbounceage;
  my $ali;

  my $mogrify = sub {
    my $key  = shift;
    my $data = shift;
    my (@b1, @b2, $b, $c, $k, $u, $t);

    if ($data->{bounce}) {
      @b1 = split(/\s+/, $data->{bounce});
      @b2 = ();
      $c = 0;
      while (1) {

	# Stop now if we have too many bounces
	if ($c >= $maxbouncecount) {
	  $u = 1;
	  last;
	}
	$b = pop @b1; last unless defined $b;
	($t, $k) = $b =~ /^(\d+)(\w)/;
	if ($t < $bounceexpiretime) {
	  $u = 1;
	  next;
	}
	# Don't count 'C' or 'P' events
	$c++ if $k ne 'C' && $k ne 'P';
	unshift @b2, $b;
      }
      $data->{bounce} = join(' ', @b2) if $u;
    }

    # If we deleted all bounce data, we want the key to go away
    if (!$data->{bounce}) {
      return (1, 0, undef);
    }

    # If the data changed, update it
    if ($u) {
      return (0, 1, $data);
    }

    # Otherwise, no change
    return (0, 0);
  };

  $self->_make_bounce;
  $self->{bounce}->mogrify($mogrify);

  1;
}

=head1 COPYRIGHT

Copyright (c) 1997-2000 Jason Tibbitts for The Majordomo Development
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

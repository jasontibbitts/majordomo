=head1 NAME

Mj::Config.pm - configuration functions

=head1 DESCRIPTION

This implements the Mj::Config object, which encapsulates configuration
file parsing, manipulation and access.  Transparent access to both old and
new style config files is provided.

Old-style files contain a pseudo-Perl description of all variables.
New-style files are data-dumped directly from the Config object.  When
using new-style files, a variable that has never had a set value will
always have the default value, even if the default changes after the list
is created.

Note that the Majordomo object owns its own private list and that list has
a Config object.  The set of variables that are useful to (and accessible
by) the GLOBAL config object are different from those accessible by normal
lists.

=head1 SYNOPSIS

Uh, like, configure something.

=cut

use strict;
no strict 'refs';

package Mj::Config;
use Data::Dumper;
use Mj::Log;
use Mj::File;
use Mj::FileRepl;
use Mj::CommandProps ':rules';

use vars qw(@EXPORT_OK @ISA $VERSION %is_array %is_parsed $list);

require Exporter;
require "mj_cf_data.pl";

$VERSION = "1.0";
@ISA = qw(Exporter);
@EXPORT_OK = qw(parse_table parse_keyed);

# This designates that the _raw_ form is an array of lines, not that the
# parsed data comtains a simple array.  Note that these are types, not
# variables.
%is_array =
  (
   'access_rules'     => 1,
   'address_array'    => 1,
   'attachment_rules' => 1,
   'bounce_rules'     => 1,
   'delivery_rules'   => 1,
   'digests'          => 1,
   'digest_issues'    => 1,
   'enum_array'       => 1,
   'inform'           => 1,
   'limits'           => 1,
   'list_array'       => 1,
   'passwords'        => 1,
   'regexp_array'     => 1,
   'restrict_post'    => 1,
   'string_array'     => 1,
   'string_2darray'   => 1,
   'sublist_array'    => 1,
   'taboo_body'       => 1,
   'taboo_headers'    => 1,
   'triggers'         => 1,
   'welcome_files'    => 1,
   'xform_array'      => 1,
  );

# Note that the passwords table is not parsed; its structure is
# special in that it retains old entries for the life of a run even
# when the structure is completely replaced.
%is_parsed =
  (
   'access_rules'     => 1,
   'address'          => 1,
   'address_array'    => 1,
   'attachment_rules' => 1,
   'bool'             => 1,
   'bounce_rules'     => 1,
   'delivery_rules'   => 1,
   'digests'          => 1,
   'digest_issues'    => 1,
   'enum_array'       => 1,
   'inform'           => 1,
   'limits'           => 1,
   'regexp'           => 1,
   'regexp_array'     => 1,
   'restrict_post'    => 1,
   'string_2darray'   => 1,
   'taboo_body'       => 1,
   'taboo_headers'    => 1,
   'triggers'         => 1,
   'welcome_files'    => 1,
   'xform_array'      => 1,
  );

=head2 new(list, listdir, separate_list_dirs)

Creates a Config object.  Does not actually load in any data; that is done
lazily.  Each object gets the name of the list it''s associated with (so it
knows where to find its files).

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;
  my %args  = @_;

  my $list  = $args{'list'} or
    $::log->abort("Mj::Config::New called without list name");

  $::log->in(150, "$list");

  my $self = {};
  bless $self, $class;

  $self->{'list'}           = $list;
  $self->{'ldir'}           = $args{'dir'};
  $self->{'callbacks'}      = $args{'callbacks'};
  $self->{'sdirs'}          = 1;
  $self->{'vars'}           = \%Mj::Config::vars;
  # $self->{'file_header'}    = \$Mj::Config::file_header;
  $self->{'default_string'} = \$Mj::Config::default_string;
  $self->{'dfldata'}        = $args{'defaultdata'};
  $self->{'locked'}         = 0;
  $self->{'mtime'}          = 0;
  $::log->out;
  $self;
}

=head2 DESTROY

Config changes are automatically saved during destruction.

=cut
sub DESTROY {
  my $self = shift;
  $self->unlock;
}

=head2 get(variable, raw)

This retrieves the value of a variable.  This will return undef for any
unknown variable.  If the object is in the process of loading its defaults,
this will just return undef.  This avoids loops when bootstrapping the
global configuration.

If raw is true, the raw, unparsed form of an array variable will be
returned instead of the preparsed version.  The raw version is simply the
array of strings that can be accepted from and shown to the user.

We check to see if the variable is of a parsed type, and extract the parsed
data.  If this is not possible for some reason (never been parsed or using
a default value), we try to extract the raw data or the default data, parse
it, and return that.

Note that if the variable is parsed _and_ has a complex type, the
caller will get back a ref to the parsed data structure.  (Unless of
course $raw is true, in which case the caller will just get an array
of strings.)  This leads to a problem where the caller has to know if
the data type is parsed or not to know what will come back.  This
should probably be fixed; it might not be a good thing to return a ref
to a big structure because it (and therefore the real config data that
gets saved) might get clobbered.  On the other hand, copying a
potentially huge structure like the parsed access_rules table probably
isn''t a good thing either.

=cut
sub get {
  my $self = shift;
  my $var  = shift;
  my $raw  = shift;
  my $log  = new Log::In 180, "$self->{'list'}, $var";
  my($ok, $parsed);

  # We include a facility for setting some variables that we can access
  # during the bootstrap process.
  if (exists $self->{'special'}{$var}) {
    return $self->{'special'}{$var};
  }

  # Just in case, we make sure we don't get into any stupid loops looking
  # up variables while we're still loading the variables.
  if ($self->{'defaulting'}) {
    $log->out("defaulting");
    return '';
  }

  # Pull in the config file if necessary
  unless ($self->{'loaded'}) {
    $self->load;
  }

  # If we need to return unparsed data...
  if ($raw || !$self->isparsed($var)) {

    # Return the raw data
    if (exists $self->{'data'}{'raw'}{$var}) {
      if ($self->isarray($var)) {
        return @{$self->{'data'}{'raw'}{$var}};
      }
      return $self->{'data'}{'raw'}{$var};
    }

    if (exists $self->{'dfldata'}{'raw'}{$var}) {
      if ($self->isarray($var)) {
        return @{$self->{'dfldata'}{'raw'}{$var}};
      }
      return $self->{'dfldata'}{'raw'}{$var};
    }

    # or return the default data
    if (exists $self->{'defaults'}{$var}) {
      $log->out('default');
      if ($self->isarray($var)) {
        return @{$self->{'defaults'}{$var}};
      }
      return $self->{'defaults'}{$var};
    }

    # or just return nothing
    return;
  }

  # We need to give back parsed data.  If we have it already...
  if (exists $self->{'data'}{'parsed'}{$var}) {
    $log->out('parsed');
    return $self->{'data'}{'parsed'}{$var};
  }

  # If we have raw data but not parsed data, we try to parse it.  This
  # really shouldn't happen unless someone hacks the config file.
  if (exists $self->{'data'}{'raw'}{$var}) {
    $log->out('raw');
    ($ok, undef, $parsed) =
      $self->parse($var, $self->{'data'}{'raw'}{$var});
    if ($ok) {
      return $parsed;
    }
    else {
      return;
    }
  }

  # Next, try the DEFAULT list values.
  if (exists $self->{'dfldata'}{'parsed'}{$var}) {
    $log->out('DEFAULT parsed');
    return $self->{'dfldata'}{'parsed'}{$var};
  }

  if (exists $self->{'dfldata'}{'raw'}{$var}) {
    $log->out('DEFAULT raw');
    ($ok, undef, $parsed) =
      $self->parse($var, $self->{'dfldata'}{'raw'}{$var});
    if ($ok) {
      return $parsed;
    }
  }

  # We have neither parsed data, nor raw data, so we pull out the default
  # and parse it.  If there's an error, we pretend we didn't see it.  The
  # site owner should know what they're doing.
  if (exists $self->{'defaults'}{$var}) {
    $log->out('default');
    ($ok, undef, $parsed) =
      $self->parse($var, $self->{'defaults'}{$var});
    if ($ok) {
      return $parsed;
    }
    else {
      $log->out('default illegal!');
      return;
    }
  }

  $log->out("not found");
  return;
}

=head2 whence
Determines the origin of a variable.

1   variable was set by the DEFAULT list
0   variable was set by mj_cf_defs.pl
-1  variable was set by the list's configuration data

=cut
sub whence {
  my $self = shift;
  my $var  = shift;
  my $log  = new Log::In 180, "$self->{'list'}, $var";
  my($ok);

  return unless $var;

  # We include a facility for setting some variables that we can access
  # during the bootstrap process.
  if (exists $self->{'special'}{$var}) {
    return 0;
  }

  # Just in case, we make sure we don't get into any stupid loops looking
  # up variables while we're still loading the variables.
  if ($self->{'defaulting'}) {
    $log->out("defaulting");
    return;
  }

  # Pull in the config file if necessary
  unless ($self->{'loaded'}) {
    $self->load;
  }

  if (exists $self->{'data'}{'raw'}{$var}) {
    return -1;
  }

  if (exists $self->{'dfldata'}{'raw'}{$var}) {
    return 1;
  }

  if (exists $self->{'defaults'}{$var}) {
    return 0;
  }
  # or just return nothing
  return;
}

=head2 load

This contains the logic for loading up stored config files.  It''s
responsible for determining which of possible many config files is the most
current and calling the appropriate function to bring it in.

=cut
sub load {  # XXX unfinished
  my $self = shift;
  my $log  = new Log::In 150, "$self->{'list'}";
  my ($file, $key, $oldfile, $old_more_recent);

  # Look up the filenames
  $file = $self->_filename;
  $oldfile = $self->_filename_old;

  # We want to make sure that the on-disk file is not more recent than when
  # we last looked at it.  So we store the time when we last looked.  Later
  # we will compare the on-disk timestamp with this one and reload if the
  # on-disk one is newer or the same age.  We don't store the actual
  # on-disk time here because if the file doesn't change, we will waste
  # time reloading it later.
  $self->{mtime} = time;

  # Clobber existing values (just in case) then pull in the defaults.  We
  # have to do the defaults now because we will allow the new style config
  # file to include only values that differ form the default, so a change
  # in the default can effect all lists that don't override it (i.e. cool
  # new functionality).
  delete $self->{'data'};
  $self->_defaults unless $self->{'defaults'};

  # The legacy config file is more recent if it exists and either the new
  # one doesn't or it's been modified more recently than the old one was.
  $old_more_recent =
    -r $oldfile &&
      (! -r $file ||
       (stat($oldfile))[9] >= (stat($file))[9]);

  if ($old_more_recent) {
    $self->_load_old;
    $self->_save_new;
  }
  elsif (-r $file) {
    $self->_load_new;
  }
  else {
    # Create the file, just because.
    $self->_save_new;
  }

  $self->_load_dfl unless $self->{'dfldata'};

  $self->{loaded} = 1;
  1;
}

=head2 _load_new (private)

This pulls in a new-style config file.

=cut
sub _load_new {
  my $self = shift;
  my $log  = new Log::In 160;
  my ($file, $name);

  $name = $self->_filename;

  # We have to lock the file
  $file = new Mj::File $name, "<";
  $self->{'data'} = do $name;
  $file->close;

  1;
}

=head2 _load_dfl

Get the configuration values for the DEFAULT list.
This data has higher precedence than the
settings in mj_cf_defs.pl, but lower than the
individual lists' settings.

=cut

sub _load_dfl {
  my $self = shift;
  my $log  = new Log::In 160;
  my ($file, $name);

  # The GLOBAL list never uses the DEFAULT data.
  if ($self->{'list'} eq 'GLOBAL') {
    $self->{'dfldata'} = {};
    return;
  }

  $name = "$self->{'ldir'}/DEFAULT/_config";
  if (-r $name) {
    $file = new Mj::File $name, "<";
    $self->{'dfldata'} = do $name;
    $file->close;
  }

  1;
}

use AutoLoader 'AUTOLOAD';
1;
__END__


=head2 default(variable)

Returns the default value of the given variable.

=cut
sub default {
  my ($self, $var) = @_;

  $::log->in(180, "$var");

  if ($self->{'defaults'}{$var}) {
    return $self->{'defaults'}{$var};
  }
  return undef;
}

=head2 allowed(variable)

Returns the allowed values of the given config variable, or undef if it
does not exist or if it not of type enum.

=cut
sub allowed {
  my $self = shift;
  my $var  = shift;

  if ($self->{'vars'}{$var} && $self->{'vars'}{$var}{'values'}) {
    return $self->{'vars'}{$var}{'type'};
  }
  return undef;
}

=head2 groups(variable)

This retrieves a list of groups which the variable belongs to.

=cut
sub groups {
  my $self = shift;
  my $var  = shift;

  if ($self->{'vars'}{$var}{'groups'}) {
    return @{$self->{'vars'}{$var}{'groups'}};
  }
  return;
}

=head2 comment(variable)

This retrieves a string containing a config variable''s comments from the
(private) master description.  This string will contain embedded newlines.

=cut
sub comment {
  my $self = shift;
  my $var  = shift;

  if ($self->{'vars'}{$var}) {
    return $self->{'vars'}{$var}{'comment'};
  }
  return undef;
}

=head2 instructions(variable)

Returns the instructions for use of a config variable as a string with
embedded newlines.  This is used in the old-style config file, and in the
configshow output if instructions are requested.

=cut
sub instructions {
  my $self = shift;
  my $var  = shift;

  return $self->intro($var) . $self->comment($var);
}

=head2 intro(variable)

This retrieves a string containing the introductory matter for a config
variable.  This includes the name of the variable, its default value, type,
group membership and allowed values.

=cut
sub intro {
  my $self = shift;
  my $var  = shift;
  my ($default, $enums, $groups, $type);

  $::log->in(180, "$self->{'list'}, $var");

  $self->_defaults unless $self->{'defaults'};

  $type = $self->{'vars'}{$var}{'type'};

  if ($self->isarray($var)) {
    if (defined $self->{'defaults'}{$var} && @{$self->{'defaults'}{$var}}) {
      $default = "$self->{'defaults'}{$var}[0] ...";
    }
    else {
      $default = "empty";
    }
  }
  else {
    $default = (defined $self->{'defaults'}{$var}) ?
      $self->{'defaults'}{$var} :
	"undef";
    if ($type eq 'bool') {
      $default = ('no', 'yes')[$default];
    }
  }

  $groups  = join(',',@{$self->{'vars'}{$var}{'groups'}});
  $enums = "";
  if ($type eq 'enum') {
    $enums  .= "/" .
      join(',',@{$self->{'vars'}{$var}{'values'}}) .
	"/";
  }

  $::log->out;
  return sprintf("%-20s %s\n%-20s %s\n",
		 $var, $enums, "($default)",
		 "[$type] <$groups>");
}

=head2 isarray(variable)

Returns true if the variable is of an array type; undef otherwise.

=cut
sub isarray {
  my $self = shift;
  my $var  = shift;

  if ($self->{'vars'}{$var}) {
    return $is_array{$self->{'vars'}{$var}{'type'}};
  }
  return;
}

=head2 isarray(variable)

Returns true if the variable is an "auto" variable.  That is, if it is
automatically maintained by Majordomo.

=cut
sub isauto {
  my $self = shift;
  my $var  = shift;

  if ($self->{'vars'}{$var}) {
    return $self->{'vars'}{$var}{'auto'};
  }
  return;
}

=head2 isparsed(variable)

Returns trus if the variable is of a parsed type; undef otherwise.

=cut
sub isparsed {
  my $self = shift;
  my $var  = shift;

  if ($self->{'vars'}{$var}) {
    return $is_parsed{$self->{'vars'}{$var}{'type'}};
  }
  return;
}

=head2 visible(variable)

Returns true of the variable is visible to external interfaces.

=cut
sub visible {
  my $self = shift;
  my $var  = shift;

  if ($self->{'vars'}{$var}) {
    return $self->{'vars'}{$var}{'visible'};
  }
  return;
}

=head2 mutable(variable)

Returns true if the variable can be changed with a list password.
Otherwise, a global password is required.

=cut
sub mutable {
  my $self = shift;
  my $var  = shift;

  if ($self->{'vars'}{$var}) {
    return $self->{'vars'}{$var}{'mutable'};
  }
  return;
}

=head2 type(variable)

Returns the type of the given config variable.

=cut
sub type {
  my $self = shift;
  my $var  = shift;

  if ($self->{'vars'}{$var}) {
    return $self->{'vars'}{$var}{'type'};
  }
  return undef;
}

=head2 vars(group/var, hidden, global)

This verifies that a variable exists and is visible.  It will also expand a
group (in all caps) to the list of visible variables it contains.  It
returns a list of variables, or an empty list if there were no matching
(and visible) variables.

If hidden is true, all variables in the group will be shown.  If not, only
variables that have the visible property will be shown.

If global is true, only variables that have the global property will be
shown.  If not, only variables that have the local property will be shown.

XXX There''s too much repeated code here.

=cut
sub vars {
  my ($self, $var, $hidden, $global) = @_;
  my (@vars, $i, $seen);

  $::log->in(140, "$self->{'list'}, $var");

  # Expand ALL tag
  if ($var eq 'ALL') {
    for $i (keys %{$self->{'vars'}}) {
      if (($hidden ? 1 : $self->{'vars'}{$i}{'visible'}) &&
	  ($global ? $self->{'vars'}{$i}{'global'} : $self->{'vars'}{$i}{'local'}))
	{
	  push @vars, $i;
	}
    }
  }
  # Expand groups
  elsif ($var eq uc($var)) {
    $seen = 0;
    $var = lc($var);
    for $i (keys %{$self->{'vars'}}) {
      if (grep {$var eq $_} @{$self->{'vars'}{$i}{'groups'}}) {
	if (($hidden ? 1 : $self->{'vars'}{$i}{'visible'}) &&
	    ($global ? $self->{'vars'}{$i}{'global'} : $self->{'vars'}{$i}{'local'}))
	  {
	    $seen = 1;
	    push @vars, $i;
	  }
      }
    }
  }

  # Try a single variable
  elsif ($self->{'vars'}{$var}) {
    if (($hidden ? 1 : $self->{'vars'}{$var}{'visible'}) &&
	($global ? $self->{'vars'}{$var}{'global'} : $self->{'vars'}{$var}{'local'}))
      {
	push @vars, $var;
      }
  }

  $::log->out;
  if (@vars) {
    return @vars;
  }
  return;
}

=head2 lock, unlock

These form a config file locking system.  Because we have vaiables which
change due to things other than user input and because changing one
variable involves saving back the entire config file, we must be very
careful to make sure that a process doesn''t save back stale data that it
has kept in memory.

lock does the obvious and must be done before any values are changed.  (The
set command locks automatically if necessary.)  The file is reloaded if
necessary after locking to ensure that the in-memory data is completely
op-to-date.  This locking model is opportunistic, in that you don''t need
to lock if you aren''t planning to change the file.

Note that the implicit locking of the set method should not be relied upon
to modify a variable based on its current value, because the in-memory data
is only refreshed after set is called.  Instead, make the lock implicitly,
then calculate the new value.

unlock just saves the file and commits if dirty, else it abandons any
changes.  (This avoids hosing the mtime of the on-disk file if we don''t
change anything.)  It is not harmful to unlock when not locked and indeed
the DESTROY function does an implicit unlock.

_These only work on new-style config files_.  Old-style files must be
explicitly loaded (and thus autoconverted) first.

=cut
sub lock {
  my $self = shift;
  my $log  = new Log::In 150;
  my $name = $self->_filename;

  # Bail early if locked
  return if $self->{'locked'};

  # Open the filerepl and stash it
  $self->{fh} = new Mj::FileRepl $name;

  # Load the file if necessary
  if ($self->{mtime} <= (stat($name))[9]) {
    $log->message(150, 'info', 'reloading');
    delete $self->{data};
    $self->{mtime} = time;
    $self->{data}  = do $name;
    $self->_defaults unless $self->{'defaults'};
    $self->_load_dfl unless $self->{'dfldata'};
    $self->{loaded} = 1;
  }

  # Note that we are locked
  $self->{locked} = 1;
}

sub unlock {
  my $self = shift;
  my $log  = new Log::In 150;
  my $ok;

  # Bail if not locked.
  return unless $self->{locked};

  $self->{mtime} = time;
  if ($self->{dirty}) {
    # Save (print out) the file and commit
    $ok = $self->{fh}->print(Dumper $self->{'data'});
    $ok ? $self->{fh}->commit : $self->{fh}->abandon;
  }
  else {
    # Nothing was changed; don't bother writing
    $self->{fh}->abandon;
  }

  # Say we're not locked any longer
  $self->{locked} = 0;
  delete $self->{fh};
}

=head2 set

Sets the value of a config variable, and sets the dirty flag.  Returns true
if the variable exists and was set, or false and a message if there was a
parsing error.

=cut
sub set {
  my $self = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$self->{'list'}, $var, @_";
  my($data, $error, $ok, $parsed, $rebuild_passwd);

  # Make sure we're setting a legal variable
  unless (exists $self->{'vars'}{$var} &&
	  ($self->{'list'} eq 'GLOBAL' ?
	   $self->{'vars'}{$var}{'global'} :
	   $self->{'vars'}{$var}{'local'}))
    {
      $log->out("illegal variable");
      return;
    }

  # Lock the file; this will load it for us
  $self->lock;

  # Stash the data away
  if ($self->isarray($var)) {
    $data = [ @_ ];
  }
  else {
    $data = shift;
    $data = '' unless (defined $data);
  }

  # Parse and syntax check
  ($ok, $error, $parsed) = $self->parse($var, $data);
  unless ($ok) {
    $log->out('parsing error');
    return (0, $error);
  }

  # We parsed OK; stash the data.
  $self->{'data'}{'raw'}{$var} = $data;
  $self->{'data'}{'parsed'}{$var} = $parsed
    if $self->isparsed($var);

  $self->{'dirty'} = 1;
  (1, $error);
}

=head2 atomic_set(var, updatesub)

This atomically sets a config variable.  The config file is locked
(implicitly by the FileRepl operation) loaded (from the FileRepl), modified
in memory (by retrieving the value of the variable and passing it to
updatesub, then setting the value of the variable, then writing the file
out and clearing the dirty bit.

XXX Probably should just ignore this, given lock/unlock.

=cut
sub atomic_set {
  my $self = shift;

  my $log = new Log::In 150;

  # Determine the filename

  # Save if it's dirty (yes, this is nexessary

  # Open file for writing

  # Load it in

  # Call the mod sub

  # Write the variable back

  # Deal with parsing routines

  # Save the file and unlock/commit

}

=head2 set_to_default

Removes the definition of a config variable, and sets the dirty flag.

=cut
sub set_to_default {
  my $self = shift;
  my $var  = shift;

  $::log->in(150, "$self->{'list'}, $var");
  $self->lock;

  if (exists $self->{'vars'}{$var}) {
    delete $self->{'data'}{'raw'}{$var};
    delete $self->{'data'}{'parsed'}{$var};
    $self->{'dirty'} = 1;
    $::log->out;
    return 1;
  }
  $::log->out("illegal variable");
  0;
}

=head2 set_directory, set_domain, set_sdirs

Set config global variables required for bootstrapping.

=cut
# sub set_directory {
#   my $self = shift;
#   $self->{'special'}{'listdir'} = shift;
# }

# sub set_domain {
#   my $self = shift;
#   $self->{'special'}{'domain'} = shift;
# }

# sub set_sdirs {
#   my $self = shift;
#   $self->{'special'}{'separate_list_dirs'} = shift;
# }


=head2 save

This saves out all of the config files.  A new-style file is always saved;
an old-style file is only saved when one already exists unless the force
option is given.

=cut
sub save {
  my $self  = shift;
  my $force = shift;

  $::log->in(150, $self->{'list'});
  if ($self->{'dirty'} || $force) {
#    $self->_save_old if $force || $self->{'old_loaded'};
    $self->_save_new;
  }
  delete $self->{'dirty'};
  $::log->out;
  1;
}

=head2 _load_old (private)

This parses an old-style config file and places its values in the
Config object''s data hash.

=cut
sub _load_old {
  my $self = shift;
  my ($file, $key, $name, $op, $val);

  $::log->in(160, "$self->{'list'}");
  $name = $self->_filename_old;

  # If there is no config file, we just keep the defaults.  There's no
  # sense in writing a new file here.
  unless (-r $name) {
    $::log->out("$name unreadable");
    return 1;
  }

  $file = new Mj::File($name);
  while (defined ($_ = $file->getline)) {
    next if /^\s*($|\#)/;
    chomp;
    s/#.*//;
    s/\s+$//;
    ($key, $op, $val) = split(" ", $_, 3);
    $key = lc($key);

    # XXX Check validity of key.  Figure out what to do about errors.
    if ($op eq "\<\<") {
      $self->{'data'}{'raw'}{$key} = [];
      while (defined($_ = $file->getline)) {
	chomp;
	next unless $_;
	s/^-//;
	last if $_ eq $val;
	push @{$self->{'data'}{'raw'}{$key}}, $_;
      }
    }
    else {
      $self->{'data'}{'raw'}{$key} = $val;
    }
  }
  $file->close;
  $self->{'loaded_old'} = 1;
  $::log->out;
  return 1;
}

=head2 _save_new

Dumps out the non-default variables in the Config object.

=head2

=cut
sub _save_new {
  my $self = shift;
  my ($file, $name, $ok);

  $::log->in(155, "$self->{'list'}");
  $name = $self->_filename;

  if (-r $name) {
    $file = new Mj::FileRepl "$name";
  }
  else {
    $file = new Mj::File "$name", ">";
  }

  $ok = $file->print(Dumper $self->{'data'});

  $file->commit if $ok;
  $::log->out;
}

=head2 _save_old

Recreates an old-style config file from the defaults and current values.
Accesses the variable array directly; calling config_get might trigger a
config_load which might trigger a writeconfig...

Note that the default will print wrongly if it's an array value having any
value other than undef.

This code is kind of gross, but it's just there to support the obsolete
files.

=cut
# sub _save_old {
#   my $self = shift;
#   my ($comment, $default, $enums, $file, $groups, $instructions,
#       $key, $lval, $name, $op, $tag, $type, $value);

#   $::log->in(155, "$self->{'list'}");

#   $name = $self->_filename_old;
#   $tag = "AA";

#   # If the file exists, we can just replace it; otherwise we have to create
#   # it.
#   if (-s $name) {
#     $file = new Mj::FileRepl($name);
#   }
#   else {
#     $file = new Mj::File($name);
#   }

#   # Just in case
#   $self->_defaults unless $self->{'defaults'};

#   $file->print($ {$self->{'file_header'}});

#   foreach $key (sort keys %{$self->{'vars'}}) {
#     # First set up the values to put into the format
#     $type    = $self->{'vars'}{$key}{'type'};
#     if (defined $self->{'data'}{'raw'}{$key}) {
#       $value = $self->{'data'}{'raw'}{$key};
#     }
#     elsif (defined $self->{'defaults'}{$key}) {
#       $value = $self->{'defaults'}{$key};
#     }
#     else {
#       $value = "";
#     }

#     $instructions = $self->instructions($key);
#     $instructions =~ s/^(.*)\n/   #$1\n/;
#     $file->print($instructions);

#     if ($type =~ /array/) {
#       $op = '<<';
#       $file->printf("%-20s << %s\n", $key, "END$tag");

#       for $lval (@{$value}) {
#         $lval =~ s/^-/--/;
#         $lval =~ s/^$/-/;
#         $lval =~ s/^(\s)/-$1/;
#         $file->print("$lval\n");
#       }
#       $file->print("END$tag\n");
#       $tag++;
#     }
#     else {
#       $op = '=';
#       $file->printf("%-20s = %s\n", $key, $value);
#     }
#     $file->print("\n");
#   }
#   $file->commit;
#   $::log->out;
# }

=head2 _defaults (private)

=head2

Load the default values for a list.  This evals the string containing the
code to determine the default values in the current context.

=cut
sub _defaults {
  my $self = shift;
  local($list) = $self->{'list'};
  my $log = new Log::In 250, "$list";

  $self->{'defaulting'} = 1;

  $self->{'defaults'} = eval ${$self->{'default_string'}};
  if ($@) {
    $::log->abort("Eval of config defaults failed: $@");
  }

  delete $self->{'defaulting'};
  1;
}

sub _filename {
  my $self = shift;
  my $list = $self->{'list'};
  my $listdir = $self->{'ldir'};

  if ($self->{'sdirs'}) {
    return "$listdir/$list/_config";
  }
  else {
    return "$listdir/$list.cf2";
  }
}

# Return the filename for the legacy config file for a list.
sub _filename_old {
  my $self = shift;
  my $list = $self->{'list'};
  my $listdir = $self->{'ldir'};

  if ($self->{'sdirs'}) {
    return "$listdir/$list/_oldconfig";
  }
  else {
    return "$listdir/$list.config";
  }
}


=head1 Variable Parsing functions

These methods are responsible for taking a raw config variable, verifying
its syntax, and parsing it into the appropriate parsed form.  Each of these
takes either a string or a ref to an array of strings and the name of the
variable being checked and returns a flag (indicating success), a string
(holding an error message) and a ref to the parsed data structure (if the
structure is complex).

=head2 parse(variable, value)

This calls the appropriate parsing routine for a variable, and returns the
results.

=cut
sub parse {
  my $self = shift;
  my $var  = shift;
  my $val  = shift;

  my $parser = "parse_$self->{'vars'}{$var}{'type'}";

  {
    no strict 'refs';
    return $self->$parser($val, $var);
  }
}

=head2 parse_access_rules

This takes an array containing access rules, runs a table parse on it, then
picks apart the table array and sends the appropriate bits to the compiler
to get evalable strings.  Returns a hash containing a hash per request
type, each containing:

 check_main  - membership in the main list must be checked
 check_aux   - hash of aux lists that must be checked.
 code        - a string ready to be evaled.

=cut
sub parse_access_rules {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150;

  my (%rules, @at, @tmp, $action, $check_aux, $check_main, $code, $count,
      $data, $error, $evars, $i, $j, $k, $l, $m, $n, $ok, $part, $rule,
      $table, $taboo, $tmp, $tmp2, $warn);

  # %$data will contain our output hash
  $data = {};

  # We start with no warnings.
  $warn = '';
  $count = 0;

  # Do the table parse: two multi-item, single field lines, one multiline
  # field
  ($table, $error) = parse_table('fmfmx', $arr);

  return (0, "\nError parsing table: $error\n")
    if $error;

  # Iterate over the rules
  for ($i=0; $i<@$table; $i++) {

    # Iterate over the requests.
    for ($j=0; $j<@{$table->[$i][0]}; $j++) {
      $rules{$table->[$i][0][$j]} ||= [];

      # Add an action-rule pair to the list of rules corresponding to the
      # appropriate request in the rule hash.  The lines of the rule are
      # joined with spaces.
      push(@{$rules{$table->[$i][0][$j]}},
	   ($table->[$i][1], join(' ',@{$table->[$i][2]})));
    }
  }

  # Now iterate over the keys in the rules hash; this will give us
  # request/[action, rule, action, rule] pairs
  for $i (keys %rules) {
    $part = "";

    # Check validity of the request
    unless (rules_request($i)) {
      @tmp = rules_requests();
      return (0, "\nIllegal request name: $i.\nLegal requests are:\n".
	      join(' ', sort(@tmp)))
    }

    # Iterate over the action/rule pairs
    while (($action, $rule) = splice @{$rules{$i}}, 0, 2) {
      $count++;

      # Check validity of the action.
      for ($j=0; $j<@{$action}; $j++) {

	# Unpack action=arg,arg set
	($tmp, $tmp2) = ($action->[$j] =~ /([^=]*)(?:=(.*))?/);
	unless (rules_action($i, $tmp)) {
	  @tmp = rules_actions($i);
	  return (0, "\nIllegal action: $action->[$j].\nLegal actions for '$i' are:\n".
		  join("\n",sort(@tmp)));
	}
	if ($tmp2) {
          $tmp2 =~ s/^\((.*)\)/$1/;
	  for $k (action_files($tmp, $tmp2)) {
	    ($file) =
	      &{$self->{callbacks}{'mj.list_file_get'}}($self->{list}, $k);
	    unless ($file) {
	      $warn .= "  Req. $i, action $tmp: file '$k' could not be found.\n";
	    }
	  }
	}
      }

      # Grab extra variables from admin_ and taboo_ (and their global
      # counterparts) for the post request.
      $evars = {};
      if ($i eq 'post') {
	for $k ('admin_', 'taboo_') {
	  for $l ('body', 'headers') {
	    $taboo = $self->get("$k$l");
	    for $m (keys %{$taboo->{'classes'}}) {
	      $evars->{"$k$m"} = 1;
	    }

	    $taboo = &{$self->{'callbacks'}{'mj._global_config_get'}}("$k$l");
	    for $m (keys %{$taboo->{'classes'}}) {
	      $evars->{"global_$k$m"} = 1;
	    }

	  }
	}
      }

      # Compile the rule
      ($ok, $error, $part, $check_main, $check_aux) =
	_compile_rule($i, $action, $evars, $rule, $count);

      # If the compilation failed, we return the error
      return (0, "\nError compiling rule for $i: $error")
	unless $ok;

      $data->{$i}{'code'}        .= $part;
      $data->{$i}{'check_main'} ||= $check_main;
      for $j (@{$check_aux}) {
	$data->{$i}{'check_aux'}{$j} = 1;
      }
    }

    $data->{$i}{'code'} .= "\nreturn [0, 'default'];\n";
  }
  # If we get this far, we know we shouldn't have any errors, but maybe
  # some warnings
  return (1, $warn, $data)
}

=head2 parse_address, parse_address_array

Calls Mj::Addr::validate to make sure the address is syntactically legal,
and returns any error message that routine generates.

=cut
use Mj::Addr;
sub parse_address {
  my $self = shift;
  my $str  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var, $str";

  # We try to tack on a hostname if one isn't given
  unless ($str =~ /\@/) {
    if (exists ($self->{'defaults'}{'whereami'})) {
      $str .= "\@" . $self->{'defaults'}{'whereami'};
    }
  }

  my $addr = new Mj::Addr($str);
  my ($ok, $mess) = $addr->valid;

  return (1, '', $str) if $ok;
  return (0, $mess);
}

use Mj::Addr;
sub parse_address_array {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my $addr;
  my $out = [];

  for my $i (@$arr) {
    next unless $i;
    my ($ok, $mess, $addr) = $self->parse_address($i, $var);
    return (0, $mess) unless $ok;
    push @$out, $addr;
  }

  (1, '', $out);
}

=head2 parse_attachment_rules

This parses the attachment_rules variable.  This variable holds lines
looking like:

mime/type : action=argument

This builds a piece of code that when matched against a MIME type
returns either 'allow', 'deny' or 'consult'.  This code is applied to
each of the MIME types present in the message and is used to determine
if the message should bounce.

Another piece of code is built which returns a list.  The first
element is either 'discard', 'allow'; the second is a
content-transfer-encoding or undef.  This code is applied before
posting to remove illegal types and to alter the encoding of various
parts.

=cut
use Safe;
sub parse_attachment_rules {
  my $self = shift;
  my $arr  = shift;
  my $log  = new Log::In 150;
  my(%allowed_actions, $check, $change, $data, $err, $i, $ok, $pat, $safe,
     $table);

  %allowed_actions =
    (
     'allow'   => 1,
     'consult' => 1,
     'deny'    => 0,
     'discard' => 0,
    );

  $safe = new Safe;
  $safe->permit_only(qw(const leaveeval not null pushmark return rv2sv stub));

  $check = "\n"; $change = "\n";

  # Parse the table.
  ($table, $err) = parse_table('fss', $arr);
  return (0, "Error parsing table: $err")
    if $err;

  # Run through entries.  Figure out action, add the appropriate code
  # to the appropriate strings.  (allow adds code to both strings.)
  # Bomb on unrecognized actions.
  for ($i=0; $i<@$table; $i++) {

    # First item is either an unquoted string or a pattern.  Convert the former to the latter.
    ($ok, $err, $pat) = compile_pattern($table->[$i][0], 0, 'iexact');

    if ($err) {
      return (0, "Error in regexp '$table->[$i][0]', $err.");
    }
    if ($table->[$i][1] eq 'deny') {
      $check .= qq^return 'deny' if $pat;\n^;

    }
    elsif ($table->[$i][1] =~ /^(allow|consult)(?:=(\S+))?$/) {
      $check  .= qq^return '$1' if $pat;\n^;
      if (defined($2)) {
	$change .= qq^return ('allow', '$2') if $pat;\n^;
      }
      else {
	$change .= qq^return ('allow', undef) if $pat;\n^;
      }
    }
    elsif ($table->[$i][1] eq 'discard') {
      $change .= qq^return ('discard', undef) if $pat;\n^;
    }
    else {
      return (0, "Unrecognized action: $table->[$i][1].");
    }
  }

  $check  .= "return 'allow';\n";
  $change .= "return ('allow', undef);\n";

  $data = {
	   'check_code'  => $check,
	   'change_code' => $change,
	  };
  return (1, '', $data);
}

=head2 parse_bool

Takes a string, converts it to 1 or 0, and returns it.

=cut
sub parse_bool {
  my $self = shift;
  my $str  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var, $str";

  # Attempt to be multi-lingual
  my %yes =
    (
     1                => 1,
     'y'	      => 1,
     'yes'	      => 1,
     'yeah'           => 1,
     'hell yeah'      => 1,
     'si'	      => 1,		# Spanish
     'hai'	      => 1,		# Japanese
     'ii'	      => 1,		# "
     'ha'	      => 1,		# Japanese (formal)
     'oui'	      => 1,		# French
     'damn straight'  => 1,             # Texan
     'darn tootin'    => 1,
     'shore nuf'      => 1,
     'ayuh'           => 1,             # Maine
    );

  my %no =
    (
     ''               => 1,
     0		      => 1,
     'n'	      => 1,
     'no'	      => 1,
     'iie'	      => 1,	# Japanese
     'iya'            => 1,
     'hell no'	      => 1,	# New Yorker
     'go die'	      => 1,
     'nyet'	      => 1,
     'nai'	      => 1,
     'no way'	      => 1,
     'as if'	      => 1,
     'in your dreams' => 1,
    );

  return (1, '', 0) unless defined $str;
  return (1, '', 1) if $yes{$str};
  return (1, '', 0) if $no{$str};
  (0, 'Could not determine if string means yes or no.');
}

=head2 parse_bounce_rules

Parses out a set of bounce rules, which look like access_rules without the
line specifying the requests.  Bounce rules also have a (mostly) different
set of variables and actions.

Returns a hash with the following elements:

 check_aux   - hash of aux lists that must be checked.
 code        - a string ready to be evaled.

=cut
sub parse_bounce_rules {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150;

  my (@tmp, $acts, $check_aux, $check_main, $count, $data, $error,
      $i, $j, $k, $o, $part, $rule, $table, $tmp, $tmp2, $warn);

  # %$data will contain our output hash
  $data = {};

  # We start with no warnings.
  $warn = '';

  # Do the table parse: one multi-item, single field line, one multiline
  # field
  ($table, $error) = parse_table('fmx', $arr);

  return (0, "\nError parsing table: $error\n")
    if $error;

  # Iterate over the rules
  for ($i=0; $i<@$table; $i++) {

    # Grab the action and code
    $acts = $table->[$i][0];
    $rule = join(' ',@{$table->[$i][1]});

    $part = "";

    # Check validity of the action.
    for ($j=0; $j<@{$acts}; $j++) {

      # Unpack action=arg,arg set
      ($tmp, $tmp2) = ($acts->[$j] =~ /([^=]*)(?:=(.*))?/);
      unless (rules_action('_bounce', $tmp)) {
	@tmp = rules_actions('_bounce');
	return (0, "\nIllegal action: $acts->[$j].\nLegal actions for bounce_rules are:\n".
		join("\n",sort(@tmp)));
      }
      if ($tmp2) {
	$tmp2 =~ s/^\((.*)\)/$1/;
	for $k (action_files($tmp, $tmp2)) {
	  ($file) =
	    &{$self->{callbacks}{'mj.list_file_get'}}($self->{list}, $k);
	  unless ($file) {
	    $warn .= "  Action $tmp: file '$k' could not be found.\n";
	  }
	}
      }

      # Compile the rule
      ($ok, $error, $part, $check_main, $check_aux) =
	_compile_rule('_bounce', $acts, {}, $rule, $i);

      # If the compilation failed, we return the error
      return (0, "\nError compiling rule for $i: $error")
	unless $ok;

      $data->{'code'}        .= $part;
      $data->{'check_main'} ||= $check_main;
      for $k (@{$check_aux}) {
	$data->{'check_aux'}{$k} = 1;
      }
    }
  }

  # By default the bounces are ignored
  $data->{'code'} .= "\nreturn [$i, 'ignore'];\n";

  # If we get this far, we know we shouldn't have any errors, but maybe
  # some warnings
  return (1, $warn, $data)
}

=head2 parse_delivery_rules

Parses a set of delivery rules and, if necessary, adds the default.

The parsed data ends up as an array of hashes, each containing:

 re   - the address matching expression, or 'ALL'
 data - the parsed rule

=cut
sub parse_delivery_rules {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150;
  my(@dr, $data, $err, $i, $ok, $re, $rule, $seen_all, $table);

  $data = [];

  # Parse the table.  A single line field followed by a multiline field.
  ($table, $err) = parse_table('lx', $arr);

  return (0, "Error parsing table: $err")
    if $err;

#  print Dumper $table;

  # The multiline field has keyed data; parse it out
  for ($i=0; $i<@$table; $i++) {

    # If we've seen an ALL tag, there's no need to parse any more
    if ($seen_all) {
      $err = "Ignoring rules after ALL tag.";
      last;
    }

    ($rule, $err) = parse_keyed(',', '=', '"', '(', ')', @{$table->[$i][1]});


    return (0, "Error parsing rule " . ($i+1) . ": $err")
      if $err;
    $data->[$i]{'data'} = $rule;

    if ($table->[$i][0] eq 'ALL') {
      $seen_all = 1;
      $data->[$i]{'re'} = $table->[$i][0];
    }
    else {
      ($ok, $err, $re) = compile_pattern($table->[$i][0], 1);
      return (0, "Error parsing rule " . ($i+1) . ":\n$err")
	if $err;
      $data->[$i]{'re'} = $re;
    }
  }

  unless ($seen_all) {
    $data->[$i] = {'re'   => 'ALL',
		   'data' => {},
		  };
  }

  return (1, $err, $data);
}

=head2 parse_digests

Parses the digests variable.  Returns a hash containing:

 default_digest - the first element from the table.  Because the digests go
                  into a hash, we lose the order so we stash the first one
 one element per digest name

=cut
sub parse_digests {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my(@tmp, $data, $elem, $error, $i, $j, $table);

  # %$data will hold the return hash
  $data = {};

  # Parse the table: one line with lots of fields, and single-line field
  ($table, $error) = parse_table('fspppooool', $arr);

  return (0, "Error parsing table: $error")
    if $error;

  $data->{'default_digest'} = $table->[0][0] if $table->[0];

  for ($i=0; $i<@{$table}; $i++) {
    $data->{lc $table->[$i][0]} = {};
    $elem = $data->{lc $table->[$i][0]};

    # times
    $elem->{'times'} = [];
    if (@{$table->[$i][1]}) {
      for $j (@{$table->[$i][1]}) {
        @tmp = _str_to_clock($j);
        if (defined $tmp[0] and not ref $tmp[0] and $tmp[0] == 0) {
          return @tmp;
        }
	push @{$elem->{'times'}}, @tmp;
      }
    }
    else {
      # The default should be 'any'
      push @{$elem->{'times'}}, ['a', 0, 23];
    }

    # minsizes
    for $j (@{$table->[$i][2]}) {
      if ($j =~ /(\d+)m/i) {
	$elem->{'minmsg'} = $1;
      }
      elsif ($j =~ /(\d+)k/i) {
	$elem->{'minsize'} = $1*1024;
      }
      else {
	return (0, "Can't parse minimum size $j");
      }
    }

    # maxsizes
    for $j (@{$table->[$i][3]}) {
      if ($j =~ /(\d+)m/i) {
	$elem->{'maxmsg'} = $1;
      }
      elsif ($j =~ /(\d+)k/i) {
	$elem->{'maxsize'} = $1*1024;
      }
      else {
	return (0, "Can't parse maximum size $j");
      }
    }

    # maxage
    $elem->{'maxage'} = _str_to_offset($table->[$i][4]);
    # default to zero (no limit) to avoid warnings in decide().
    $elem->{'maxage'} ||= 0;

    # separate
    $elem->{'separate'} = _str_to_offset($table->[$i][5]);

    # minage
    $elem->{'minage'} = _str_to_offset($table->[$i][6]);

    # type XXX Need some syntax checking here.
    $elem->{'type'} = $table->[$i][7] || 'mime';

    # description
    $elem->{'desc'} = $table->[$i][8];
  }
  return (1, '', $data);
}

=head2 parse_digest_issues

Parse the digest_issues variable.  Returns a hash keyed on digest name:

{name => {volume => xx,
	  issue  => yy,
	 }
}

=cut
sub parse_digest_issues {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my($data, $elem, $error, $i, $j, $table);

  $data = {};

  ($table, $error) = parse_table('fsss', $arr);
  return (0, "Error parsing table: $error") if $error;

  for ($i=0; $i<@{$table}; $i++) {
    $data->{$table->[$i][0]} =
      {volume => $table->[$i][1],
       issue  => $table->[$i][2],
      };
  }

  return (1, '', $data);
}

=head2 parse_directory

This takes a single string, makes sure that it represents an absolute path,
and verifies that the path both exists and is readable and writable.

=cut
sub parse_directory {
  my $self = shift;
  my $str  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var, $str";

  return (0, "Not a plain string.")
    if ref($str);

  return 1 if !defined $str || $str =~ /^\s*$/;

  return (0, "Must be an absolute path (i.e. start with '/'.")
    unless $str =~ m!^/!;

  return (0, "The directory must exist.")
    unless -d $str;

  return (0, "The directory must be writable.")
    unless -w $str;

  1;
}

=head2 parse_enum

Makes sure the value is allowed (i.e. in the variable''s 'allowed' list.

=cut
sub parse_enum {
  my $self = shift;
  my $str  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var, $str";

  for my $i (@{$self->{'vars'}{$var}{'values'}}) {
    return 1 if $str eq $i;
  }

  $log->out('illegal value');
  return (0, "Illegal value '$str'.\nLegal values are:\n".
	  join(' ', @{$self->{'vars'}{$var}{'values'}}));
}

=head2 parse_enum_array

This parses an array of strings, each of which must be in the variable''s
'allowed' list.

The parsed value of this is a hashref; this makes it easy to check if a
given value is supplied without traversing a list.

=cut
sub parse_enum_array {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my (%out, $i, $mess, $ok);

  for $i (@$arr) {
    ($ok, $mess) = $self->parse_enum($i, $var);
    return (0, $mess) unless $ok;
    $out{$i}++;
  }
  return (1, '', \%out);
}

=head2 parse_flags

Parses a string of flags.

=cut
sub parse_flags {
  my $self = shift;
  my $str  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var, $str";
  my ($i, $j, $reason, $seen, $values);
 
  $reason = ''; $seen = {};
  $values = join '', @{$self->{'vars'}{$var}{'values'}};

  for ($i = 0 ; $i < length $str ; $i++) {
    $j = substr($str, $i, 1);
    if ($j =~ /^[$values]*$/) {
      if (exists $seen->{lc $j}) {
        $reason .= "The $j flag is a duplicate.\n";
      }
      $seen->{lc $j} = 1;
    }
    else {
      $reason .= "The $j flag is not supported.\n";
    }
  }
  return (0, $reason) if $reason;
  1;
}

=head2 parse_inform

Parses the contents of the inform variable.

XXX We have a special default here.  This should really be elsewhere.

=cut
sub parse_inform {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my ($stat);

  my %stats =
    (
     'all'     => 2,
     'succeed' => 1,
     'success' => 1,
     'ok'      => 1,
     'fail'    => 0,
     'failure' => 0,
     'stall'   => -1,
    );

  my ($table, $err) = parse_table('fsmm', $arr);

  return (0, "Error parsing table: $err.")
    if $err;

  my %out =
    (
     'subscribe'   => {'1' => 3},
     'unsubscribe' => {'1' => 3},
     'reject'      => {'1' => 3},
    );

  # Iterate over the table
  for (my $i = 0; $i < @$table; $i++) {
    for (my $j = 0; $j < @{$table->[$i][1]}; $j++) {

      # Syntax check
      return (0, "Unknown condition $table->[$i][1][$j].")
	unless exists $stats{$table->[$i][1][$j]};

      $stat = $table->[$i][1][$j] eq 'all' ? 'all' :
              $stats{$table->[$i][1][$j]};

      for (my $k = 0; $k < @{$table->[$i][2]}; $k++) {
	if ($table->[$i][2][$k] eq 'report') {
	  $out{$table->[$i][0]}{$stat} |= 1;
	}
	elsif ($table->[$i][2][$k] eq 'inform') {
	  $out{$table->[$i][0]}{$stat} |= 2;
	}
	elsif ($table->[$i][2][$k] eq 'ignore') {
	  $out{$table->[$i][0]}{$stat} = 0;
	}
	else {
	  return (0, "Unknown action $table->[$i][2][$k].");
	}
      }
    }
  }

  return (1, '', \%out);
}


=head2 parse_integer

Checks to see if the value _looks_ like a valid integer.  Thanks, perlfaq.

=cut
sub parse_integer {
  my $self = shift;
  my $str  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var, $str";

  return 1 if !defined $str;
  return 1 if $str =~ /^\s*$/;
  return 1 if $str =~ /^[+-]?\d+$/;
  return (0, "Not an integer.");
}

=head2 parse_limits

A limits table consists of three fields per line:
PATTERN | CONDITIONS | CONDITIONS
The pattern is matched against the e-mail addresses of people
who post messages.  The first set of conditions defines a "soft"
limit (by default, the message will be held for approval), while
the second set of conditions defines a "hard" limit (by default,
the message will be denied).

=cut
sub parse_limits {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my ($ok, $part, $regex, $stat, $whole);

  my ($table, $err) = parse_table('fspp', $arr);

  return (0, "Error parsing table: $err.")
    if $err;

  my @out = ();

  # Iterate over the table
  for (my $i = 0; $i < @$table; $i++) {
    $out[$i] = {};

    ($ok, $err, $regex) = compile_pattern($table->[$i][0], 0, "isubstring");
    return ($ok, $err)
      unless $ok;

    $out[$i]->{'pattern'} = $regex;
    $out[$i]->{'soft'} = [];
    $out[$i]->{'hard'} = [];

    # Parse soft limit conditions
    for (my $j = 0; $j < @{$table->[$i][1]}; $j++) {
      $stat = $table->[$i][1]->[$j];
      if ($stat =~ m#(\d+)/([\dymwdh]*)([ymwdh])$#) {
        $part = $1;
        $whole = Mj::List::_str_to_time(($2 || 1) . $3) - time;
        return (0, "Unable to parse time span $stat.") unless ($whole > 0);
        push @{$out[$i]->{'soft'}}, ['t', $part, $whole];
      }
      elsif ($stat =~ m#(\d+)/(\d+)#) {
        $part = $1;
        $whole = $2;
        return (0, "Proportion $stat is greater than one.") 
          if ($whole < $part);
        push @{$out[$i]->{'soft'}}, ['p', $part, $whole];
      }
      else {
        return (0, "Unrecognized condition $stat.");
      }
    }
    # Parse hard limit conditions
    for (my $j = 0; $j < @{$table->[$i][2]}; $j++) {
      $stat = $table->[$i][2]->[$j];
      if ($stat =~ m#(\d+)/(\d*)([a-z]+)#) {
        $part = $1;
        $whole = _str_to_offset(($2 || 1) . $3);
        return (0, "Unable to parse time span $stat.") unless ($whole > 0);
        push @{$out[$i]->{'hard'}}, ['t', $part, $whole];
      }
      elsif ($stat =~ m#(\d+)/(\d+)#) {
        $part = $1;
        $whole = $2;
        return (0, "Proportion $stat is greater than one.") 
          if ($whole < $part);
        push @{$out[$i]->{'hard'}}, ['p', $part, $whole];
      }
      else {
        return (0, "Unrecognized condition $stat.");
      }
      $stat = $table->[$i][1]->[$j];
    }
  }

  return (1, '', \@out);
}

=head2 parse_list_array

Checks to see that all array items are the names of existing lists.
Permits a trailing extra bit separated from the list by a colon.  This is
useful as a path or comment or whatever.  The list portion (before the
colon) is allowed to be empty.  (Some of this functionality may need to be
moved to another function.)

=cut

use Majordomo qw(legal_list_name);
sub parse_list_array {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my($i, $l, $e);
  for $i (@$arr) {
    ($l, $e) = split /[ :]+/, $i, 2;
    next unless length($l);
    return (0, "Illegal or unknown list $l.")
      unless ((-d "$self->{'ldir'}/$l") && 
              (Majordomo::legal_list_name(undef, $l)));
  }
  (1, undef, $arr);
}

=head2 parse_sublist_array

Checks to see that all array items are the names of existing sublists.
Permits a trailing extra bit separated from the list by a colon.  This is
useful as a path or comment or whatever.  The list portion (before the
colon) is allowed to be empty.  (Some of this functionality may need to be
moved to another function.)

=cut

use Majordomo qw(legal_list_name);
sub parse_sublist_array {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my($i, $l, $e);
  for $i (@$arr) {
    ($l, $e) = split /[: ]+/, $i, 2;
    next unless length($l);
    # XXX Assumes .D or .T suffix for sublist database.
    return (0, "Illegal or unknown list $l.")
      unless ((-f "$self->{'ldir'}/$self->{'list'}/X$l.D" ||
               -f "$self->{'ldir'}/$self->{'list'}/X$l.T")
               && (Majordomo::legal_list_name(undef, $l)));
  }
  (1, undef, $arr);
}

=head2 parse_pw

This behaves as if we''re parsing a word, but in addition we force a
rebuild of the parsed password table so that the new value is stored
alongside the old.  This solves the problem where the user sets a
default password then sets master_password; the following commands
shouldn''t fail in this case, so the old password must continue to be
valid, but the new password must be valid also.

=cut
sub parse_pw {
  my $self = shift;
  my $str  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var, $str";

  return (0, "Cannot contain whitespace.")
    if $str =~ /\s/;

  (1, undef, undef);
}


=head2 parse_passwords

Currently a placeholder; because of the special nature of passwords
(their definition must stick around until flushed) we don''t actually
parse them here.  We can do some syntax checking, though.

=cut
sub parse_passwords {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";

  my ($table, $error) = parse_table('fsmp', $arr);

  return (0, "Error parsing table: $error.")
    if $error;

  (1, undef, undef);
}

=head2 parse_regexp

This parses a generalized regular expression.  The result is a legal Perl
regular expression.

=cut
sub parse_regexp {
  my $self = shift;
  my $str  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var, $str";

  compile_pattern($str, 1);
}

=head2 parse_regexp_array

This parses an array of regular expressions.  These look like

/.*/i?

=cut
use Safe;
sub parse_regexp_array {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my ($err, $ok, $out, $re);

  $out = [];
  for my $i (@$arr) {
    ($ok, $err, $re) = $self->parse_regexp($i, $var);
    return (0, $err) if $err;
    push @$out, $re;
  }
  (1, '', $out);
}


=head2 parse_restrict_post

This parses a restrict_post array, which is like a string_array except that
the first idem is split on whitespace and the result inserted at the top of
the list.

Note that the old colon separation conflicts with the new list:auxlist
notation.  Sigh.  I don''t see this as a huge problem, as convertlist will
take care of it and whitespace is the commonly used separator.

=cut
sub parse_restrict_post {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my $out = [];

  push(@$out, split(/\s+/, $arr->[0])) if @$arr;
  for (my $i = 1; $i < @$arr; $i++) {
    push @$out, $arr->[$i];
  }

  return (1, '', $out);
}

=head2 parse_string, parse_string_array

Does nothing to the string or array of strings; they''re uninterpreted data.

=cut
sub parse_string {
  1;
}

sub parse_string_array {
  1;
}

=head2 parse_string_2darray

This parses an array of arrays of lines.  In other words, an array of
text blocks, separated by blank lines.

A nice aspect here is that because blank lines have historically been
munged, we can make use of blank lines here and still be backwards
compatible.

A blank line may be included in individual parts of the array
by placing a hyphen on a line by itself.

=cut
sub parse_string_2darray {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my($table, $err, $i, $j, $out);

  $table = [];
  if (@$arr) {
    ($table, $err) = parse_table('x', $arr);
  }

  $out = [];
  for ($i=0;$i<@$table;$i++) {
    for ($j = 0; $j < @{$table->[$i][0]}; $j++) {
      $table->[$i][0]->[$j] =~ s/^-([\s-]|$)/$1/;
    }
    push @$out, $table->[$i][0];
  }

  (1, '', $out);
}

=head2 parse_taboo_body

This takes an array of extended regular expressions and builds perl code
which when evaled matches against all of them.

The extended regexes look like

!?/.*/i?\s*(\d*)((,(\d+))(,(\w+))?)?

i.e.

!/this must match/i 10,20,class

The leading ! indicates an inversion, the trailing numbers indicate the
maximum line to match and a severity, and the final string indicates the
name of the class.

This returns a hashref containing:

 code  - a string to be evaled containing the matching code
 max   - the maximum line to be matched
 inv   - a listref of strings describing the inverted regexes

The routine in 'code' will be evaled in a Safe compartment with only the
current line number and the current line of text shared.  It return an
array containing the four items per match: the regexp and the text that
matched, the severity of the match, and a flag indicating whether or not
the rule is inverted (and so has satisfied its condition).

The default severity is 10.
The default class is "header"; this conveniently gives back "taboo_header",
a backwards compatible class.

=cut
sub parse_taboo_body {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my($class, $data, $err, $inv, $j, $max, $ok, $pat, $re, $sev, $stop);

  $data = {};
  $data->{'inv'} = [];
  $max = -1;

  # Start
  $data->{'code'} = "my \@out = ();\n";
  $data->{'classes'} = {};

  for $j (@$arr) {
    # Format: !/match/i 10,20,blah
    ($inv, $pat, $stop, undef, undef, $sev, undef, $class) =
      $j =~ /^(\!?)(.*?)\s*(\d*)((,([+-]?\d+)?)(,(\w+))?)?\s*$/;
    $sev = 10 unless defined $sev && length $sev;
    $class ||= 'body';
    $data->{'classes'}{$class} = 1;

    # Compile the pattern
    ($ok, $err, $re) = compile_pattern($pat, 1);
    return (0, "Error parsing taboo_body line:\n$err")
      unless $ok;

    # For backwards compatibility, we have a different default for
    # admin_body
    unless (defined $stop && length $stop) {
      $stop = ($var eq 'admin_body')? 10: 0;
    }

    # Build a line of code for an inverted match
    if ($inv) {
      if ($stop > 0) {
	$data->{'code'} .=
	  "\$line <= $stop && \$text =~ $re && (push \@out, (\'$pat\', \$&, $sev, \'$class\', 1));\n";
      }
      else {
	$data->{'code'} .=
	  "\$text =~ $re && (push \@out, (\'$pat\', \$&, $sev, \'$class\', 1));\n";
      }
	push @{$data->{'inv'}}, "$self->{list}\t$var\t$pat\t$sev\t$class";
    }

    # Build a line of code for a normal match
    else {
      if ($stop > 0) {
	$data->{'code'} .=
	  "\$line <= $stop && \$text =~ $re && (push \@out, (\'$pat\', \$&, $sev, \'$class\', 0));\n";
      }
      else {
	$data->{'code'} .=
	  "\$text =~ $re && (push \@out, (\'$pat\', \$&, $sev, \'$class\', 0));\n";
      }
    }
    $max = $stop ? $stop > $max ? $stop : $max : 0; #Whee!
  }

  # Tack on the 'no match' condition, which provides us with a convenient
  # default
  $data->{'code'} .= "return \@out;\n";
  $data->{'max'}   = $max;

  return (1, '', $data);
}

=head2 parse_taboo_headers

This is a slightly simpler version of parse_taboo_body, because it doesn''t
need to deal with stop lines.  Lines look like this:

!?/.*/\s*(\d*)(,(\w+))?

Inverted matches are supported, as are optional severities and classes.
The default severity is 10; the default class is 'header'.

=cut
sub parse_taboo_headers {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my($class, $data, $err, $inv, $j, $ok, $pat, $re, $sev);

  $data = {};
  $data->{'inv'} = [];
  $data->{'classes'} = {};
  $data->{'code'} = "my \@out = ();\n";
  for $j (@$arr) {
    ($inv, $pat, $sev, undef, $class) = $j =~ /^(\!?)(.*?)\s*([+-]?\d+)?(,(\w+))?$/;
    $sev = 10 unless defined $sev;
    $class ||= 'header';
    $data->{'classes'}{$class} = 1;

    # Compile the pattern
    ($ok, $err, $re) = compile_pattern($pat, 1);
    return (0, "Error parsing taboo_headers line:\n$err")
      unless $ok;

    if ($inv) {
      $data->{'code'} .= "\$text =~ $re && (push \@out, (\'$pat\', \$&, $sev, \'$class\', 1));\n";
      push @{$data->{'inv'}}, "$self->{list}\t$var\t$pat\t$sev\t$class";
    }
    else {
      $data->{'code'} .= "\$text =~ $re && (push \@out, (\'$pat\', \$&, $sev, \'$class\', 0));\n";
    }
  }
  $data->{'code'} .= "return \@out;\n";

  return (1, '', $data);
}

=head2 parse_welcome_files

Special parser for the welcome_files variable.  Returns a ref to a list
containing one element per file to be mailed.

=cut
sub parse_welcome_files {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my($error, $i, $table);

  # Parse the table, one siingle-field line and a line with two fields
  ($table, $error) = parse_table('lfso', $arr);

  return (0, "Error parsing: $error")
    if $error;

#   # Check for an empty table and supply a default; the 'welcome' and 'info'
#   # files should always exist in the GLOBAL filespace
#   unless (@$table) {
#     $table =
#       [
#        [
# 	'Welcome to the $LIST mailing list!',
# 	'welcome',
# 	'NS',
#        ],
#        [
# 	"List introductory information",
# 	'info',
# 	'PS',
#        ],
#       ];
#   }

  for ($i=0; $i < @$table; $i++) {
    return (0, "Illegal flags $table->[$i][2]")
      if $table->[$i][2] =~ /[^NPS]/;
  }

  return (1, '', $table);
}


=head2 parse_word

Checks to make sure the string has no whitespace.

=cut
sub parse_word {
  my $self = shift;
  my $str  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var, $str";

  return (0, "Cannot contain whitespace.")
    if $str =~ /\s/;
  return 1;
}

=head2 parse_xform_array

Check an array of address xforms.  These have the form

/.*/.*/i?

The routine that uses these just takes them one by one, so we don''t have to
do any parsing.  XXX We could build a routine to apply all of the xforms at
once, though.

=cut
sub parse_xform_array {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, "$var";
  my(%repl, $data, $i);

  $data = ();
  %repl = ('trim mbox'     => '/(.*?)\+.*(\@.*)/$1$2/',
	   'ignore case'   => '/(.*)/\L$1/',
	   'mungedomain'   => '/(.*\@).*\.([^.]+\.[^.]+)/$1$2/',
	   'two level'     => '/(.*\@).*\.([^.]+\.[^.]+)/$1$2/',
	   'three level'   => '/(.*\@).*\.([^.]+\.[^.]+\.[^.]+)/$1$2/',
	  );

  for $i (@$arr) {
    if ($repl{$i}) {
      push @$data, $repl{$i};
    }
    elsif ($i =~ /flatten domain\s+(.*)/) {
      push @$data, "/(.*\\\@).*(\Q$1\E)/\$1\$2/";
    }
    elsif ($i =~ /map\s+(.*)\s+to\s+(.*)/) {
      push @$data, "/(.*\\\@.*)\Q$1\E\$/\$1$2/";
    }
    elsif ($i =~ m!^/.*/.*/i?$!) {
      push @$data, $i;
    }
    else {
      return (0, "Invalid transform: $i")
    }
  }
  return (1, '', $data);
}

=head1 Utility Routines

These aren''t Config object methods but instead are utility routines that
are useful for operating on config information.

=head2 parse_table(specifier_string, arrayref)

This splits up a config table.

  Input: specifier string, ref to array of lines.
    The specifier string can contain the following characters:

     \s - space is ignored
      l - line of free text (a line containing a single field)
      f - line split into fields (a line containing multiple fields)
      x - text until blank line (a set of lines containing a multivalue field)
    After an f, one or more of the following describing the fields:
      s - single value
      o - optional single value
      m - multivalue, split on commas
      p - optional multivalue

  Output: a listref containing one listref per table record, containing one
    string or listref per table element, the elements of which depend on
    the specifier:
      l - a string
      f - a string per s element, or a list of strings per m element
      x - a list of strings
    a string containing an error message, used for syntax checking.

 Examples:

  1. fsss
     field : field : field

  2. fsms
     field : field, field : field

  3. lfsss
     Line of text           \ One record
     field : field : field  /
     Line of text
     field : field : field

  Function takes n lines of text, then splits on the next, then resets.

  4. l l fsss x
     Line
     Line
     field : field : field
     Line
     .x.
     Line
     (blank line)
     Line
     Line
     field : field : field
     .y.
     Line

     variable number of lines, ending in a blank line.

=cut
sub parse_table {
  my $spec = shift;
  my $data = shift;
  my (@out, @row, @group, $line, $elem, $s, $f, $error, $temp);
  my $log = new Log::In 150, $spec;

  # Line loops over the elements of the $data arrayref
  $line = 0;

  # We walk over the lines of data
 LINE:
  while (1) {

    while (defined $data->[$line] && $data->[$line] !~ /\S/) {
      $line++;
    }

    # Stop when we run out of data
    last LINE unless defined $data->[$line];

    # Start with a clean row
    @row = ();

    # Reset the //g iterator on $spec
    pos $spec = 0;

    # We walk the spec string to build a row.  Regexp magic follows.
    while ($spec =~ /\s*([^f]|f[msop]+)\s*/g) {
      $s = $1;

      # We must have data at all times while parsing a record
      unless (defined $data->[$line]) {
	$error .= "Ran out of data while parsing table.\n";
	last LINE;
      }

      # Process single lines
      if ($s eq 'l') {
	push @row, $data->[$line];
	$line++;
      }

      # Process all lines until EOD or a blank line
      elsif ($s eq 'x') {
	@group=();
	while ($line < @{$data} && $data->[$line] =~ /\S/) {
	  push @group, $data->[$line];
	  $line++;
	}
	push @row, [@group];
      }

      # Process multifield lines
      elsif ($s =~ /^f/g) {
	@group = split(/\s*[:|]\s*/,$data->[$line]);
	$elem = 0;
	while ($s =~ /\s*(.)\s*/g) {
	  $f = $1;

	  # Hendle optional fields; set a value, then parse normally
	  # XXX need to complain about missing/empty fields unless optional
	  if ($f eq 'o') {
	    $group[$elem] = "" unless defined $group[$elem];
	    $f = 's';
	  }
	  elsif ($f eq 'p') {
	    $group[$elem] = "" unless defined $group[$elem];
	    $f = 'm';
	  }

	  # Now every field should be set; complain if not
	  unless (defined $group[$elem]) {
	    $error .= "Required field left empty at line ".($line+1).".\n";
	    last LINE;
	  }

	  # Handle single-valued fields
	  if ($f eq 's') {
	    $elem++;
	  }

	  # Handle multivalued fields
	  elsif ($f eq 'm') {
	    $temp = $group[$elem];
	    $group[$elem] = [];
	    push @{$group[$elem]}, $+ while $temp =~
	      # We split the list on commas, but not within quotes or
	      # parentheses.  Note that the quotes/parentheses will be left
	      # in as part of the string.  XXX This bogosity might not be
	      # correct...
	      m{
                ((?=.)         # Must not be empty
                 (?:[^\"\(,\\]|\\[\"\(,])*
                 (?:
                 \"(?:[^\"\\]|\\.)*(?:\"|$)
                 |
                 \((?:[^\)\\]|\\.)*(?:\)|$)
                 |
                 )
                )
                [\s,]*      # Any number of spaces and commas

	       }gx;

	    # The old non-parenthesis version in case I screwed up
	    # m{
	    # ([^\",]*?"[^\"\\]*(?:\\.[^\"\\]*)*")\s*,?\s*
	    # | ([^,]+)\s*,?\s*
	    # | \s*,\s*
	    # }gx;
	    $elem++;
	  }

	  # Oops
	  else {
	    $error .= "Illegal field specifier '$1'.\n";
	    last LINE;
	  }
	}
	push @row, @group;
	$line++;
      }
      else {
	$error .= "Illegal line specifier '$s'.\n";
	last LINE;
      }
    }
    push @out, [@row];
  }
  ([@out], $error);
}

=head2 parse_triggers

Parses the triggers variable.  
Returns a hash containing an array of times as
created by _str_to_clock().

=cut
sub parse_triggers {
  my $self = shift;
  my $arr  = shift;
  my $var  = shift;
  my $log  = new Log::In 150, $var;
  my (@tmp, $data, $elem, $error, $i, $j, $table);

  # %$data will hold the return hash
  $data = {};

  # Parse the table: one line with lots of fields, and single-line field
  ($table, $error) = parse_table('fsm', $arr);

  return (0, "Error parsing table: $error")
    if $error;

  for ($i=0; $i<@{$table}; $i++) {
    # Ensure that each trigger name is valid.
    unless (grep {$table->[$i][0] eq $_} @{$self->{'vars'}{$var}{'values'}}) {
      $log->out('illegal value');
      return (0, "Illegal trigger '$table->[$i][0]'.\nLegal triggers are:\n".
	  join(' ', @{$self->{'vars'}{$var}{'values'}}));
    }
    $data->{lc $table->[$i][0]} = [];
    $elem = $data->{lc $table->[$i][0]};

    if (@{$table->[$i][1]}) {
      for $j (@{$table->[$i][1]}) {
        @tmp = _str_to_clock($j);
        if (defined $tmp[0] and not ref $tmp[0] and $tmp[0] == 0) {
          return @tmp;
        }
	push @$elem, @tmp;
      }
    }
  }
  (1, '', $data);
}

=head2 parse_keyed(field, key, quote, open, close, lines)

This routine parses out lines containing nested key, value pairs separated
by delimiters.  A key may have values that are themselves nested key, value
pairs.  All delimiters and parsing details are configurable.

As an exapmple, take the string

key1="a b c", key2 = (d=e, f)

'field' is the field delimiter ','; this separates the key-value pairs.
'key' is the key separator, '=', which separates keys from their values.
  Keys don''t have to have values.
'quote' is the quoting character, '"', for putting spaces and special
  things into values.
'open' and 'close' are the characters that begin and end groups of items
  '(', ')'.

calling

parse_keyed(',', '=', '"', '(', ')', 'key1="a b c", key2 = (d=e, f)')

results in a hashref:

{
 key1 => 'a b c',
 key2 => {
	  d => 'e',
          f => ''
         }
};

=cut
sub parse_keyed {
  my $d = shift; # field Delimiter
  my $k = shift; #       Key separator
  my $q = shift; #       Quote character
  my $o = shift; #  list Open
  my $c = shift; #  list Close
  my $log = new Log::In 150;
  my(@done, @stack, $err, $group, $key, $n, $ok, $pop, $state, $val);
  $n = 0;
  $val = '';
  my $out  = {};
  local($_);

  # Tokenize
  my @list = grep {$_ ne ''} split(/([\s$d$k$q$o$c\\])/, join($d, @_));

#  print join('',@list), "\n";

  $state = 'key';

  # Run the state machine
  while (1) {
    push @done, $_ if defined $_;
    $_ = shift @list;
#     if (defined $_) {
#       print "$n: ", substr($state, 0, 2), ": ", join('',@done), " _${_}_ ", join('', @list), ": $val\n";
#     }
#     else {
#       print "$n: ", substr($state, 0, 2), ": ", join('',@done), " _U_ ", join('', @list), ": $val\n";
#     }

    if (0) {}

    # Val state, trying to build a value
    elsif ($state eq 'val') {
      !defined        and $err = 'Ran out of data.', last;
      /\s+/           and next;
      /\\/            and push(@stack, $state), $state = 'backslash', next;
      /[^$d$k$q$o$c]/ and $out->{$key} = $_, $state = 'delim', next;
      /\Q$d/          and $err = 'Must give a value.', last;
      /\Q$k/          and $err = "Two ${k}'s in a row.", last;
      /\Q$o/          and $state = 'group', $n=1, $val = '', next;
      /\Q$c/          and $err = "$c before $o.", next;
      /\Q$q/          and push(@stack, 'delim'), $state = 'quote', next;
    }

    # Quote state, trying to find an end quote to finish building a value
    elsif ($state eq 'quote') {
      !defined        and $err = "Ran out of data looking for $q.", last;
      /\\/            and push(@stack, $state), $state = 'backslash', next;
      /\Q$q/          and $out->{$key} = $val, $state = pop @stack, next;
      'default'       and $val .= $_, next;
    }

    # GQuote state, trying to find an end quote while processing a group
    elsif ($state eq 'gquote') {
      !defined        and $err = "Ran out of data looking for $q.", last;
      /\\/            and $val .= $_, push(@stack, $state), $state = 'backslash', next;
      /\Q$q/          and $val .= $_, $state = pop @stack, next;
      'default'       and $val .= $_, next;
    }

    # Group state, building a group to recurse on
    elsif ($state eq 'group') {
      !defined        and $err = 'Ran out of data looking for $c.', last;
      /\\/            and $val .= $_, push(@stack, $state), $state = 'backslash', next;
      /\Q$q/          and $val .= $_, push(@stack, $state), $state = 'gquote', next;
      /\Q$o/          and $n++, $val .= $_, next;
      /\Q$c/          and do {
	$n--;
	if ($n>0) {
	  $val .= $_;
	  next;
	}
	else {
	  #$val .= $_;
#	  print "Recursing\n";
	  ($ok, $err) = parse_keyed($d, $k, $q, $o, $c, $val);
#	  print "Recursed.\n";
	  if (defined $ok) {
	    $out->{$key} = $ok;
	    $state = 'delim';
	    next;
	  }
	  else {
	    last;
	  }
	}
      };
      'default'       and $val .= $_;
    }

    # Delim state, waiting for a delimiter
    elsif ($state eq 'delim') {
      !defined        and return $out;
      /\Q$d/          and $state = 'key', next;
      /\s/            and next;
      'default'       and $err = "Expected $c.", last;
    }

    # Separator state, got key, waiting for a separator or a delimiter
    elsif ($state eq 'separator') {
      !defined        and $out->{$key} = '', return $out;
      /\Q$k/          and $state = 'val', next;
      /\Q$d/          and $state = 'key', $out->{$key} = '', next;
      /\s/            and next;
      'default'       and $err = "Illegal text; expected $k.", last;
    }

    # Kay state; trying to get a key
    elsif ($state eq 'key') {
      !defined        and return $out;
      /\s/            and next;
      /\\/            and $err = 'Backslashes not allowed in keys.', last;
      /[^$d$k$q$o$c]/ and $key = $_, $state = 'separator',           next;
      /\Q$d/          and $err = 'Blank entries not allowed.',       last;
      /\Q$k/          and $err = 'Must give a key.',                 last;
      /\Q$o/          and $err = 'Illegal $o.',                      last;
      /\Q$c/          and $err = 'Illegal $c.',                      last;
      /\Q$q/          and $err = '$q not allowed in keys.',          last;
      die "Hosed!";
    }

    # Backslash mode, ignoring a special while building a value.  We pass
    # non-specials, too, so this is really simple.
    elsif ($state eq 'backslash') {
      $val .= $_;
      $state = pop @stack;
      next;
    }
  }

  # Only got here if we errored out!
  my $done = join('', splice(@done, -6, 6));
  my $list = join('', splice(@list, 0, 6));

  if ($err =~ /\n/) {
    return (undef, $err);
  }

  $_ = 'U' unless defined $_;
  return (undef, "$err\n  $done __${_}__ $list");
}

=head2 compile_pattern(pattern, multiple, force)

This takes a generalized pattern and turns it into a regular expression.
If multiple is true, the returned expression is allowed to be a listref
containing regexps that are to be 'and'ed.  ('or'ing is easy in one regexp,
but 'and'ing is difficult so the matcher can save state between regexps.
This is not yet implemented.)

If force is 'substring', convert an undelimited pattern into a substring
pattern.  If force is 'exact', convert an undelimited pattern into an
equality match.  Prefixing either with 'i' maeks the match
case-inseneitive.

Returns a flag, an error, and the compiled pattern.

Right now we only parse three kinds of generalized expressions:

 substring, delimited by double quotes, in which all metacharacters are
   escaped.

 csh/DOS like, delimited by percent signs, in which the characters ? and *
 have their usual meaning in the shell and character classes using '[' and
 ']' are supported.

 perl-like, delimited by forward slashes, in which nothing is escaped
   _unless_ the original expression fails because of an array deref error.
   In that case, all unescaped @ symbols are escaped and the regexp is
   tried again.

=cut
sub compile_pattern {
  my $str  = shift;
  my $mult = shift;
  my $force= shift || '';
  my ($err, $id1, $id2, $inv, $mod, $pat, $re);

  # Mapping of shell specials to regexp specials
  my %sh = ('?'=>'.', '*'=>'.*', '['=>'[', ']'=>']');

  return (1, '', '') unless $str;

  # Extract leading and trailing characters and the pattern; remove
  # whitespace
  ($inv, $id1, $pat, $id2, $mod) = 
                             $str =~ /^\s*      # Leading whitespace
                                      (?:
                                       (\!?)     # Inversion
                                       ([\/\"\%]?) # Opening delimiter
                                       (.*)      # The pattern
                                       (\2)      # Closing delimiter
                                       ([ix]+)?  # Allowed modifiers
                                       |         # or nothing
                                      )
                                       \s*$     # Trailing whitespace
				     /x;

  # Prefix "not " to the resulting pattern if inverted.
  $inv = length $inv ? "not " : "";
  # Handle case where there are no delimiters
  unless ($id1) {
    if ($force =~ /^i(.*)/) {
      $mod = 'i';
      $force = $1;
    }
    if ($force eq 'substring') {
      $id1 = $id2 = '"';
    }
    elsif ($force eq 'exact') {
      $id1 = $id2 = '/';
      $pat = '^' . quotemeta($str) . "\$";
    }
    else {
      return (0, "Unrecognized pattern '$str':\nNot enclosed in pattern delimiters.\n")
    }
  }

  $mod ||= '';

  # Decide which type of RE we're dealing with.  Extract the first character of the string
  if ($id1 eq '"') {
    # Substring pattern; fail if the quote isn't closed
    return (0, "Error in pattern '$str': no closing '\"'.\n")
      unless $id2 eq '"';
    $re = "/\Q$pat\E/$mod";
    return (1, '', $inv . $re);
  }
  if ($id1 eq '/') {
    # Perl pattern; fail if the closing '/' is missing
    return (0, "Error in pattern '$str': no closing '/'.\n")
      unless $id2 eq '/';
    $re = "/$pat/$mod";

    # Check validity of the regexp
    $err = (Majordomo::_re_match($re, "justateststring"))[1];

    # If we got an array deref error, try escaping '@' signs and trying
    # again
    if ($err =~ /array deref/) {
      $re =~ s/((?:^|[^\\\@])(?:\\\\)*)\@/$1\\\@/g; # Ugh
      $err = (Majordomo::_re_match($re, "justateststring"))[1];
    }
    return (0, "Error in regexp '$str'\n$err") if $err;
    return (1, '', $inv . $re);
  }
  if ($id1 eq '%') {
    # Shell-like pattern; fail if the closing '%' is absent
    return (0, "Error in pattern '$str': no closing '\%'.\n")
      unless $id2 eq '%';

    # Simple conversion of shell-like patterns to Perl; thanks to the Perl
    # Cookbook
    $pat =~ s/(.)/ $sh{$1} || "\Q$1"/ge;
    $re = "/$pat/$mod";

    # Check validity of the regexp
    $err = (Majordomo::_re_match($re, "justateststring"))[1];
    return (0, "Error in regexp '$str'\n$err") if $err;
    return (1, '', $inv . $re);
  }
  return (0, "Unrecognized pattern '$str'.\n");
}

=head2 compile_rule(request, action, rule, id)

This takes the access control language and "compiles" it into a Perl
subroutine (contained in a string) which can be processed with eval (or
reval).

This routine basically scans left to right turning the pseudo-language
into real Perl.  The pseudo-language is simple enough that nothing
other than strict translation is required.  The only real complexity
comes from trying to produce pretty code by properly indenting things.
(This helps in debugging, and is thus valuable.)

Things supported:
  AND, &&, OR, ||, NOT, !
  Parentheses for grouping
  regexp matches within /.../, matching the user address
  list membership checks with @
  ALL rule matching everything

Returns:

 flag  (ok or not)
 error (if any)
 code in a string
 check_main - flag: should membership in the main list be checked
 check_aux  - listref: list of aux lists to check for membership

About the ID:

 A matching rule returns its ID.  With the assumption that IDs are
 monotonically increasing, it is easy to rerun the rule code and skip
 directly to the next rule just by skipping all rules with IDs less than or
 equal to the returned ID.

=cut
sub _compile_rule {
  my $request = shift;
  my $action  = shift;
  my $evars   = shift; # Any extra legal variables
  $_          = shift;
  my $id      = shift;
  my ($check_main,# Should is_list_member be called?
      $check_aux, # Listref of aux lists to check for membership
      $indent,    # Counter for current indentation level.
      $invert,    # Should sense of next expression be inverted?
      $need_or,   # Is an 'or' required to join the next exp?
      $var,       # Variable name for parsing $variable=arg
      $arg,       # Argument for pasring @variable=arg or @list
      $o,         # Accumulates output string.
      $e,         # Accumulates errors encountered.
      $i,         # General iterator thingy.
      $op,        # Variable comparison operator
      $iop,       # holder for inverted op
      $re,        # Current regexp operator
      $pr,        # Element prologue
      $ep,        # Element epilogie
      $err,       # Generic error holder
      $ok,
      @tmp,
   );

  $e = "";
  $o = "";
  $indent = 0;
  $invert = 0;
  $need_or = 0;
  $check_main = 0;
  $check_aux = [];
  $pr = "\nif ((\$skip < $id) &&\n   (";
  $ep = "\n   ))\n  {\n";

  $o .= $pr;

  while (length $_) {

    # Eat leading space.
    if (s:^\s+::) {
      next;
    }

    # Process /reg\/exp/
    if (s:^(([\/\"\%\_]).*?(?!\\).\2[ix]?)::) {
      ($ok, $err, $re) = compile_pattern($1, 0);
      unless ($ok) {
	$e .= $err;
	last;
      }

      if ($need_or) {
	$o .= "  ||";
      }
      $o .= "\n    "."  "x$indent;
      if ($invert) {
	$o .= "(\$args{'addr'} !~ $re)";
	$invert = 0;
      }
      else {
	$o .= "(\$args{'addr'} =~ $re)";
      }
      $need_or = 1;
      next;
    }

    # Process $variable =~ /reg\/exp/
    if (s:
 	^               # Beginning
 	\$              # $ designates a variable
 	(\w+)           # the variable name, match 1
 	\s*
	(\=\~|\!\~)     # The binding operator =~ or !~ , match 2
 	\s*
	(               # Enclose the full pattern, match 3
	 ([\/\"\%\_])   # A pattern delimiter match 4
	 .*?            # The pattern
	 (?!\\).\4      # The same pattern delimiter, not backwhacked
	 [ix]?          # Possible pattern modifier
	)
	::x             # Replace with nothing
       )
      {
	$var = $1;
	$op = $2; $iop = '!~'; $iop = '=~' if $op eq '!~';
	($ok, $err, $re) = compile_pattern($3, 0);
	unless ($ok) {
	  $e .= $err;
	  last;
	}

	unless (rules_var($request, $var, 3)) {
	  @tmp = rules_vars($request, 3);
	  $e .= "Illegal match variable for $request: $var.\nLegal variables which you can match against are:\n".
	    join("\n", sort(@tmp));
	  last;
	}

	if ($need_or) {
	  $o .= "  ||";
	}
	$o .= "\n    "."  "x$indent;
	if ($invert) {
	  $o .= "(\$args{'$var'} $iop $re)";
	  $invert = 0;
	}
	else {
	  $o .= "(\$args{'$var'} $op $re)";
	}
	$need_or = 1;
	next;
      }

    # Process open group '('
    if (s:^\(::) {
#warn "open group";
      $o .= "\n    "."  "x$indent;
      if ($invert) {
	$o .= "!";
	$invert = 0;
      }
      $o .= "(";
      $indent++;
      next;
    }

    # Process close group ')'
    if (s:^\)::) {
#warn "close group";
      if ($invert) {
	$e .= "Can't invert close_group!\n";
	last;
      }
      $indent--;
      $o .= "\n    "."  "x$indent;
      $o .= ")";
      $need_or = 1;
      next;
    }

    # Process AND 'n &&
    if (s:^AND:: || s:^\&\&::) {
      if ($invert) {
	$e .= "Can't invert AND at\n";
	$e .= "$_\n";
	last;
      }
      $o .= " &&";
      $need_or = 0;
      next;
    }

    # Process OR and ||
    if (s:^(OR):: || s:^(\|\|)::) {
      unless ($need_or) {
	$e .= "OR not legal at\n$1$_\n";
	last;
      }
      if ($invert) {
	$e .= "Can't invert OR at\n";
	$e .= "$1$_\n";
	last;
      }
      $o .= " ||";
      $need_or = 0;
      next;
    }

    # Process NOT or '!'
    if (s:^NOT:: || s:^\!::) {
      if ($invert) {
	$e .= "Can't invert NOT at\n";
	$e .= "$_\n";
	last;
      }
      $invert = 1;
      next;
    }

    # Process the special ALL tag
    if (s:^(ALL)::) {
      if ($invert) {
	$e .= "Can't invert ALL at\n$1$_\n";
	last;
      }
      if ($need_or) {
	$o .= " ||";
      }
      $o .= "\n    "."  "x$indent;
      $o .= "(1)";
      $need_or = 1;
      next;
    }

    # Process $variable and $variable=value
    # Lost of room for improvement here; numeric vs string values, ".*",
    # quoting of spaces, etc.
    if (s/
 	^                       # Beginning
 	\$                      # $ designates a variable
 	(\w*)                   # the variable name
 	\s*
 	(?:
 	 (>=|<=|==|<>|=|!=|<|>) # any legal op
 	 \s*                    # possible whitespace
 	 ([^\s]+)               # the value, ends at space
 	)?                      # but maybe not "op value"
 	\s*                     # Trim any trailing whitespace
 	#	   ($|[\s\)])              # End with the end or some space
 	//x)                    # or a close
      {
	($var, $op, $arg) = ($1, $2, $3);
#warn "var comparison V$var O$op A$arg";
	$op ||= '';

	# Weed out bad variables, but allow some special cases
	unless (rules_var($request, $var) ||
	       ($request eq 'post' && $evars->{$var}))
#$var =~ /(global_)?(admin_|taboo_)\w+/))
	  {
	    @tmp = rules_vars($request);
	    $e .= "Illegal variable for $request: $var.\nLegal variables are:\n  ".
	      join("\n  ", sort(@tmp));
	    if ($request eq 'post' && scalar(keys(%$evars))) {
	      $e .= "\nPlus these variables currently defined in admin and taboo rules:\n  ".
		join("\n  ", sort (keys(%$evars)));
	    }
	    last;
	  }
	if ($need_or) {
	  $o .= " ||";
	}
	$o .= "\n    "."  "x$indent;

	# Do plain $var form
	if (!$op) {
	  if ($invert) {
	    $o .= "(!\$args{'$var'})";
	    $invert = 0;
	  }
	  else {
	    $o .= "(\$args{'$var'})";
	  }
	}

	# String equality comparisons
	elsif ($op eq '!=' || $op eq '=') {
	  $op eq '!=' and $op = 'ne' and $iop = 'eq';
	  $op eq '='  and $op = 'eq' and $iop = 'ne';

	  if ($invert) {
	    $o .= "(\$args{'$var'} $iop \"$arg\")";
	    $invert = 0;
	  }
	  else {
	    $o .= "(\$args{'$var'} $op \"$arg\")";
	  }
	}

	# Numeric comparisons; first make sure we allow them
	else {
	  if ($var !~ /(global_)?(admin_|taboo_)\w+/ &&
	      rules_var($request, $var) != 2) {
	    $e .= "Variable '$var' does not allow numeric comparisons.\n";
	    last;
	  }

	  $op eq '<=' and $iop = '>';
	  $op eq '>'  and $iop = '<=';
	  $op eq '>=' and $iop = '<';
	  $op eq '>'  and $iop = '<=';
	  $op eq '==' and $iop = '!=';
	  $op eq '<>' and $op  = '!=' and $iop = '==';

	  # Do $var > arg form
	  if ($invert) {
	    $o .= "(\$args{'$var'} $iop $arg)";
	    $invert = 0;
	  }
	  else {
	    $o .= "(\$args{'$var'} $op $arg)";
	  }
	}

	$need_or = 1;
	next;
      }

    # Process @list, @MAIN, and @ forms
    if (s:^\@(.*?)($|[\s\)])::) {
      $arg = $1 || "MAIN";
      $o .= "\n    "."  "x$indent;
      if ($arg eq "MAIN") {
	$check_main = 1;
      }
      else {
	push @{$check_aux}, $arg;
      }
      if ($invert) {
	$o .= "(!\$memberof{'$arg'})";
	$invert = 0;
      }
      else {
	$o .= "(\$memberof{'$arg'})";
      }
      $need_or = 1;
      next;
    }

    $e .= "unknown rule element at:\n";
    $e .= "$_";
    last;
  }

  $o .= "$ep";
  $o .= "    return [$id, '" . join("', '",(map { s/([\\\'])/\\$1/g; $_ } @{$action})) . "'];\n  }\n";

  if ($e) {
    return (0, $e, $o);
  }
  return (1, undef, $o, $check_main, $check_aux);
}

=head2 _str_to_offset(string)

This converts a string to a number of seconds.  If it doesn''t recognize the
string, it will return undef.

=cut
sub _str_to_offset {
  my $arg = shift || '';
  my $log = new Log::In 150, "$arg";
  my($time);

  if ($arg =~ /(\d+)d/) {
    $time = 86400 * $1;
  }
  elsif ($arg =~ /(\d+)w/) {
    $time = 86400 * 7 * $1;
  }
  elsif ($arg =~ /(\d+)mo/) {
    $time = 86400 * 30 * $1;
  }
  elsif ($arg =~ /(\d+)h/) {
    $time = 3600 * $1;
  }
  elsif ($arg =~ /(\d+)m/) {
    $time = 60 * $1;
  }
  $time;
}

=head2 _str_to_clock(string)

This converts a string to a list of clock values, which are three-element
lists:

[
 flag: day of week (w), day of month (m), free date (a)
 start
 end (or undef for non-range clocks)
]

start and end (if present) are integers made by (day number) * 24 + hour
number (i.e. offsets in hours from midnight Sunday or midnight on the 1st.
Note that the first is day number 0, which is different from what gmtime
gives for $mday.

A single string can translate into several clocks.  This returns a list of them.

=cut
sub _str_to_clock {
  my $arg = shift;
  my(@out, $day, $flag, $i, $in, $out, $start, $end);
  my %days = ('su'=>0, 'm'=>1, 'tu'=>2, 'w'=>3, 'th'=>4, 'f'=>5, 'sa'=>6);

  @out = ();

  # Extract arguments outside and inside parentheses.
  ($out, $in) = $arg =~ /^([a-zA-Z0-9-]+)\s*(.*)$/;
  return () unless $out;

  # Deal with 'always', 'any',
  if ($out =~ /^a[ln]/i) {
    return (['a', 0, 23]);
  }

  # Deal with 'never', 'none'
  if ($out =~ /^n[eo]/i) {
    return ();
  }
  # Deal with 'yearly'
  if ($out =~ /^yearly/i) {
    return (['y', 4, 4]);
  }
  # Deal with 'quarterly'
  if ($out =~ /^quarterly/i) {
    return (['m1', 3, 3], ['m4', 3, 3], ['m7', 3, 3], ['m10', 3, 3]);
  }
  # Deal with 'monthly'
  if ($out =~ /^monthly/i) {
    return (['m', 2, 2]);
  }
  # Deal with 'weekly'
  if ($out =~ /^weekly/i) {
    return (['w', 1, 1]);
  }
  # Deal with 'daily'
  if ($out =~ /^daily/i) {
    return (['a', 0, 0]);
  }
  # Hour or hour range
  elsif ($out =~ /^(\d{1,2})-?(\d{1,2})?$/) {
    $flag = 'a';
    $start = $1;
    $end   = defined $2 ? $2 : $1;
    return ([$flag, $start, $end]);
    $flag  = 'a';
    $start = $1;
    $end   = defined $2 ? $2 : $1;
    return ([$flag, $start, $end]);
  }

  # Day of the month, possibly followed by hours in parens.
  elsif ($out =~ /^(\d+)(st|nd|rd|th)$/i) {
    $flag  = 'm';
    $day   = $1-1;
    $start = $day*24;
    $end   = $day*24 + 23;
  }
  # Day of the week, possibly followed by hours in parens.
  elsif ($out =~ /^(su|m|tu|w|th|f|sa)[dayonesurit]*$/i) {
    # mon(0-6, 12, 20-23)
    $flag  = 'w';
    $day   = $days{lc $1};
    $start = $day*24;
    $end   = $day*24 + 23;
  }
  # Month and Day of month, possibly followed by hours
  elsif ($out =~ /^(\d{1,2})m(\d{1,2})d$/i) {
    $flag = "m$1";
    $day = $2 - 1;
    $start = $day*24;
    $end   = $day*24 + 23;
  }
  # Day of the year, month, or week, possibly followed by hours
  elsif ($out =~ /^(\d{1,3})([ywm])$/i) {
    $flag = $2;
    $day = $1 - 1;
    $start = $day*24;
    $end   = $day*24 + 23;
  }
  else {
    # XXX error condition
    return (0, "Unable to parse $out\n");
  }
  return ([$flag, $start, $end]) unless $in =~ /^\((.+)\)\s*$/;
  # Parse the expression in parentheses; split on commas.
  for $i (split(/\s*,\s*/,$1)) {
    if ($i =~ /^(\d{1,2})-?(\d{1,2})?/) {
      $start = $day*24 + $1;
      $end   = $day*24 + (defined $2 ? $2 : $1);
    }
    else {
      # XXX Error condition
      return (0, "Unable to parse $in\n");
    }
    push @out, [$flag, $start, $end];
  }
  @out;
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

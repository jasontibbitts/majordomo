=head1 NAME

Majordomo.pm - The top-level Majordomo object.


=head1 DESCRIPTION

This contains all of the code for the Majordomo object, which is the main
object that is manipulated by a Majordomo interface.  This object
encapsulates all of the externally-visible functionality of Majordomo.
This means that every function which is to be callable by any external
routine must be visible here.  This means that this module has piles of
functions.  XXX Think up an AUTOLOAD method to automatically dispatch these
calls to the appropriate module, so maintenance issues are reduced.

=head1 SYNOPSIS

 use Majordomo;
 $mj = new Majordomo $listdir;
 
 # Grab lists visible to us, their description and their flags 
 @lists = $mj->lists($user, $passwd, $auth, $interface,
                     "lists".$mode?"=mode":"", $mode);

=head2 A note about the division of labor between core and interface:

First and foremost, the interface is responsible for doing all of the
output formatting.  The core tries hard to give back simple return values
containing strings that come from values that the list owner can change.
The interface should turn these into something which makes sense for the
the method with which is is communicating with the user.  This may seem
like extra work because several interfaces may end up returning the same
data, but then these interfaces can all call a single set of glue functions
to do their formatting.

The return values for the core are intended to be as simple as possible.
This has some trade-offs; in the case of which, the interface is required
to iterate over the lists itself to keep the return value a simple list of
matched addresses.  This was done in order to facilitate a client-server
model; returning a simple list makes it very easy to send the data over a
network stream.  While it is possible to send complex data structures using
Data::Dumper, this is something to avoid out of general principles
(i.e. efficency).

Because we may have very, very large lists, some communication is done in
chunks.  Passing huge arrays takes memory, and eats network bandwidth.
Plus, it allows the interface to bail without receiving all of the data.
This means that the interface must call an iterator repeatedly to get all
data in some cases.  It may be predent to consider doing this for lists,
too, except that internally the whole structure gets filled in anyway.

=head2 A note about security

The core is responsible for security as much as possible.  While the
interface is responsible for taking passwords and determining who is
talking to it, the core actually validates the passwords and determines if
the user is allowed to perform a certain action.  The core tries to avoid
leaking any information to the interface beyond what the present user is
allowed to see.  The problem with this is now that any operation where the
interface might want to know what lists a user can see will take a long
time as every single list config is loaded and the access function is
checked.  Without some form of caching, there isn't a way around this.
Then again, for every operation except lists it is virtually certain that
something will be done with each of those lists, which would require a
config file parse anyway.

Security is not a concern at any level directly below this object's public
methods.  At the moment there is no client-server interface and so it's
assuming that anything that can do damage has to be running setuid to do
it, so we don't have to worry about rogue interfaces calling private
methods.  A client-server situation would simply present the same public
functions and communicate directly over the wire; the private methods would
simply not exist.

=cut

package Majordomo;

@ISA = qw(Mj::Access Mj::Token Mj::MailOut Mj::Resend Mj::Inform);
$VERSION = "0.1199805030";

use strict;
no strict 'refs';
use vars (qw($str));
use IO::File;
use Mj::Log;
use Mj::List;
use Mj::Addr;
use Mj::Access;
use Mj::MailOut;
use Mj::Token;
use Mj::Resend;
use Mj::Inform;

# sub is_tainted {
#   return ! eval {
#     join('',@_), kill 0;
#     1;
#   };
# }

=head2 new(topdir, domain)

This constructs a Majordomo object.  Such an object consists of a List
which encapsulates the global configuration and any associated messages and
auxiliary files, and hash which maps list names to List objects, one for
each list belonging to the Majordomo object.  This hash is initially empty,
and is filled in lazily.

=cut
sub new {
  my $type   = shift;
  my $class  = ref($type) || $type;
  my $topdir = shift;
  my $domain = shift;

  $::log->in(50, "$topdir, $domain");

  my $self   = {};
  bless $self, $class;
  $self->{'sdirs'}  = 1;
  $self->{'ldir'}   = ($domain =~ m!^/!) ? $domain : "$topdir/$domain";
  $self->{'domain'} = $domain;
  $self->{'lists'}  = {};
  $self->{'unique'} = 'AAA';

  # We'll have to do this anyway, so do it here and leave it out of the
  # rest of the code.
  $self->{'av'} = new Mj::Addr
    (
     'allow_at_in_phrase'          => 0,
     'allow_bang_paths'            => 0,
     'allow_comments_after_route'  => 0,
     'allow_ending_dot'            => 0,
     'limit_length'                => 1,
     'require_fqdn'                => 1,
     'strict_domain_check'         => 1,
    );
  
  $self->_make_list('GLOBAL');

  # Pull in the constants for our address validator
  $self->{'av'}->params
    (
     'allow_at_in_phrase'
     => $self->_global_config_get('addr_allow_at_in_phrase'),
     'allow_bang_paths'
     => $self->_global_config_get('addr_allow_bang_paths'),
     'allow_comments_after_route'
     => $self->_global_config_get('addr_allow_comments_after_route'),
     'allow_ending_dot'
     => $self->_global_config_get('addr_allow_ending_dot'),
     'limit_length'
     => $self->_global_config_get('addr_limit_length'),
     'require_fqdn'
     => $self->_global_config_get('addr_require_fqdn'),
     'strict_domain_check'
     => $self->_global_config_get('addr_strict_domain_check'),
    );
  
  $::log->out;
  $self;
}

=head2 connect(interface, sessinfo)

Connect a session to the Majordomo object.

A connect call must be made before the dispatcher is called; the purpose is
to store the session info (which is just a string) into a spool somewhere
and stuff a session ID into the Majordomo class.  This ID gets into the
logs and tokens and is made available to all command responses.

The idea is that the client will provide all available information on the
request (email headers, CGI environment, etc.) to be used in the eventual
tracking of forgeries and such.

(The CGI interfaces should try to have the client track sessions so that we
don''t generate huge numbers of spool files and fill up disks and such.)

$int is the name of the interface.
$sess is a string containing all of the session info.

XXX Add some way for an interface to pass us an ID to see if we still think
it''s valid.  The CGI interface may need to do this if it doesn''t take
care of that itself.

XXX This needs to get much more complex; reconnecting with a previous
session should now be fine, but we want to enforce timeouts and other
interesting things.

=cut
use MD5;
sub connect {
  my $self = shift;
  my $int  = shift;
  my $sess = shift;
  my $log = new Log::In 50, "$int";
  my ($path, $id, $ok);

  # Generate a session ID; hash the session, the time and the PID
  $id = MD5->hexhash($sess.scalar(localtime).$$);

  # Open the session file; overwrite in case of a conflict;
  $self->{sessionid} = $id;
  $self->{sessionfh} =
    new Mj::File("$self->{ldir}/GLOBAL/sessions/$id", '>');
  
  $log->abort("Can't write session file to $self->{ldir}/GLOBAL/sessions/$id, $!")
    unless $self->{sessionfh};

  $self->{sessionfh}->print("Source: $int\n\n");
  $self->{sessionfh}->print("$sess\n");

  return $id;
}


# A hash of functions that the dispatcher will allow.  The hash value will
# eventually convey more useful information.
my %functions =
  (
   'accept'      => {'top_half' => 1},
   'alias'       => {'top_half' => 1},
   'auxadd'      => {'top_half' => 1},
   'auxremove'   => {'top_half' => 1},
   'auxwho'      => {'top_half' => 1, 'iterator' => 1},
   'createlist'  => {'top_half' => 1},
   'faq'         => {'top_half' => 1, 'iterator' => 1},
   'get'         => {'top_half' => 1, 'iterator' => 1},
   'help'        => {'top_half' => 1, 'iterator' => 1},
   'index'       => {'top_half' => 1},
   'info'        => {'top_half' => 1, 'iterator' => 1},
   'intro'       => {'top_half' => 1, 'iterator' => 1},
   'lists'       => {'top_half' => 1},
   'put'         => {'top_half' => 1, 'iterator' => 1},
   'reject'      => {'top_half' => 1},
   'rekey'       => {'top_half' => 1},
   'sessioninfo' => {'top_half' => 1},
   'set'         => {'top_half' => 1},
   'show'        => {'top_half' => 1},
   'showtokens'  => {'top_half' => 1},
   'subscribe'   => {'top_half' => 1},
   'tokeninfo'   => {'top_half' => 1},
   'trigger'     => {'top_half' => 1},
   'unalias'     => {'top_half' => 1},
   'unsubscribe' => {'top_half' => 1},
   'which'       => {'top_half' => 1},
   'who'         => {'top_half' => 1, 'iterator' => 1},
  );

=head2 dispatch(function, user, passwd, auth, interface, mode, cmdline, list, victim, ...)

This is the main interface to all non-utility functionality of the
Majordomo core.  It handles calling the appropriate function and logging
its return value.

It could possibly provide for the removal of much repeated code by also
calling the security routines and possibly even making the appropriate
calls to deeper objects.  This would eliminate both the bottom and top
halves of some functions.  This will have to wait, however.

This uses the %functions hash to determine what a particular function
needs.  The keys of this hash are the function names; the values are
hashrefs with the following keys:

  top_half ------- if this exists, control will be passed to the top half
    function with the same name as the function.  No other processing will
    be done.

  iterator ------- true if this function is really a trio of iterator
    functions; the dispatcher will accept the three functions $fun_start,
    $fun_chunk and $fun_done.  Only the first will be security checked.

=cut
sub dispatch {
  my ($self, $fun, $user, $pass, $auth, $int, $cmd, $mode, $list, $vict,
      @extra) = @_;
  my $log  = new Log::In 29, "$fun" unless $fun =~ /_chunk$/;
  my(@out, $base_fun, $ok, $over);

  ($base_fun = $fun) =~ s/_(start|chunk|done)$//;
  $list ||= 'GLOBAL';
  $vict ||= '';
  $mode ||= '';

  $log->abort('Not yet connected!') unless $self->{'sessionid'};

  unless (exists $functions{$base_fun}) {
    return (0, "Illegal core function: $fun");
  }

  if (($base_fun ne $fun) && !$functions{$base_fun}{'iterator'}) {
    return (0, "Illegal core function: $fun");
  }

  if ($mode =~ /nolog/) {
    # This is serious; user must use the master global password.
    $ok = $self->validate_passwd($user, $pass, $auth, $int,
				 'GLOBAL', 'ALL', 1);
    return (0, "The given password is not sufficient to disable logging.")
      unless $ok;
    $over = -1;
  }
  elsif ($mode =~ /noinform/) {
    $ok = $self->validate_passwd($user, $pass, $auth, $int, $list,
				 'config_inform');
    return (0, "The given password is not sufficient to disable owner information.")
      unless $ok;
    $over = 1;
  }
  else {
    $over = 0;
  }

  if ($functions{$base_fun}{'top_half'}) {
    @out = $self->$fun($user, $pass, $auth, $int, $cmd, $mode, $list, $vict, @extra);
  }
  else {
    # Last resort; we found _nothing_ to call
   return (0, "No action implemented for $fun");
  }
  # Inform unless overridden or continuing an iterator
  unless ($over == -1 || $fun =~ /_(chunk|done)$/) {
    $self->inform($list, $base_fun, $user, $vict, $cmd, $int, $out[0],
		  !!$pass+0, $over)
  }
  @out;
}

use AutoLoader 'AUTOLOAD';
1;
__END__

=head2 get_all_lists(user, passwd, auth, interface)

Utility function.

This just grabs all of the lists that are accessible by the user and
returns them in an array.  Because of the access checking, it will have the
side effect of loading the configurations for all of the lists.

=cut
sub get_all_lists {
  my ($self, $user, $passwd, $auth, $interface) = @_;
  my (@lists, $list);

  $::log->in(100);

  $self->_fill_lists;

  for $list (keys %{$self->{'lists'}}) {
    next if $list eq 'GLOBAL';
    $self->_make_list($list);
    if ($self->list_access_check($passwd, $auth, $interface, '', 'lists',
				 $list, 'advertise', $user))
      {
	push @lists, $list;
      }
  }

  $::log->out;
  @lists;
}

=head2 addr_validate(address)

Utility function.

This validates and strips an address using the Majordomo object''s internal
address validator.

=cut
sub addr_validate {
  my $self = shift;
  $self->{'av'}->validate(@_);
}

=head2 s_expire

Miscellaneous internal function.

This removes all spooled sessions older than 'session_lifetime' days old.
We stat all of the files in the sessions directory and delete the old ones.

=cut
use DirHandle;
sub s_expire {
  my $self = shift;
  my $log = new Log::In 60;
  my $days = $self->_global_config_get('session_lifetime');
  my $now = time;
  my (@nuke, $dh, $dir, $i, $time);

  $dir = "$self->{ldir}/GLOBAL/sessions";
  $dh  = new DirHandle $dir;

  while(defined($i = $dh->read)) {
    # Untaint the filename, so we can delete it later
    $i =~ /(.*)/; $i = $1;
    $time = (stat("$dir/$i"))[9];
    if ($time + $days*86400 < $now) {
      push @nuke, $i;
      unlink "$dir/$i";
    }
  }
  @nuke;
}


#########################

=head1 Configuration methods

These access the list or global configuration variables.  Interfaces are
expected to use only the non-private implementations; the private ones
will likely not exist at all in a client-side implementation.

=head2 global_config_get(user, passwd, auth, interface, variable)

Retrieve the value of a global config variable.  This just passes the
request in to the global list, but also contains a hack so that
majordomo.cf still works.

=cut
sub global_config_get {
  my ($self, $user, $passwd, $auth, $interface, $var) = @_;

  # Check access levels and such here.  Only interface code has to go
  # through checks on config variables.
 
  $self->{'lists'}{'GLOBAL'}->config_get($var);
}

=head2 list_config_get(user, passwd, auth, interface, list, var)

Retrieves the value of a list''s config variable.

Note that anyone can get a visible variable; these are available to the
interfaces for the asking.  They should not be security-sensitive in any
way.

For other variables, the standard security rules apply.

=cut
sub list_config_get {
  my ($self, $user, $passwd, $auth, $interface, $list, $var, $raw) = @_;
  my $log = new Log::In 170, "$list, $var";
  my (@out, $i, $ok);

  $self->_make_list($list);

  # Anyone can see it if it is visible.
  if ($self->config_get_visible($var)) {
    return $self->_list_config_get($list, $var, $raw);
  }

  for $i ($self->config_get_groups($var)) {
    $ok = $self->validate_passwd($user, $passwd, $auth, $interface,
				   $list, "config_$i");
    last if $ok;
  }
  unless ($ok) {
    return;
  }
  $self->_list_config_get($list, $var, $raw);
}

=head2 list_config_set

Alters the value of a list''s config variable.  Returns a list:

 flag    - true if command succeeded
 message - to be shown to user if present

=cut
sub list_config_set {
  my ($self, $user, $passwd, $auth, $interface, $list, $var) =
    splice(@_, 0, 7);
  my $log = new Log::In 150, "$list, $var";
  my (@groups, $i, $mess, $ok, $global_only);

  $self->_make_list($list);

  unless (defined $passwd) {
    return (0, "No passwd supplied.\n");
  }

  @groups = $self->config_get_groups($var);
  unless (@groups) {
    return (0, "Unknown variable \"$var\".\n");
  }

  $global_only = 1;
  if ($self->config_get_mutable($var)) {
    $global_only = 0;
  }

  # Validate passwd
  for $i (@groups) {
    $ok = $self->validate_passwd($user, $passwd, $auth, $interface,
				   $list, "config_$i", $global_only);
    last if $ok;
  }
  unless ($ok) {
    return (0, "Password does not authorize $user to alter $var.\n");
  }
  
  # Get possible error value and print it here, for error checking.
  ($ok, $mess) = $self->{'lists'}{$list}->config_set($var, @_);
  unless ($ok) {
    return (0, "Error parsing $var: $mess\n");
  }
  return 1;
}

=head2 list_config_set_to_default

Removes any definition of a config variable, causing it to track the
default.

=cut
sub list_config_set_to_default {
  my ($self, $user, $passwd, $auth, $interface, $list, $var) = @_;
  my (@levels, $ok, $mess, $level);
  $self->_make_list($list);
  
  unless (defined $passwd) {
    return (0, "No passwd supplied.\n");
  }

  @groups = $self->config_get_groups($var);
  unless (@groups) {
    return (0, "Unknown variable \"$var\".\n");
  }

  # Validate passwd, check for proper auth level.
  ($ok, $mess, $level) =
    $self->validate_passwd($user, $passwd, $auth,
			   $interface, $list, 'config_$var');
  unless ($ok) {
    return (0, "Password does not authorize $user to alter $var.\n");
  }

  $self->{'lists'}{$list}->config_set_to_default($var);
}

sub save_configs {
  my $self = shift;
  $::log->in(100);;
  for my $i ($self->{'lists'}) {
    if ($self->{'lists'}{$i}) {
      $self->{'lists'}{$i}->config_save;
    }
  }
  $::log->out;
}  

=head2 _global_config_get (private)

This is an unchecked interface to the global config, for internal use only.

=cut
sub _global_config_get {
  my $self = shift;
  my $var  = shift;
  my $log = new Log::In 150, "$var";

  $self->_make_list('GLOBAL');
  $self->{'lists'}{'GLOBAL'}->config_get($var);
}

=head2 _list_config_get, _list_config_set (private)

Thesw are unchecked interfaces to the config variables, provided for
internal use.

=cut
sub _list_config_get {
  my $self = shift;
  my $list = shift;
  
  $list = 'GLOBAL' if $list eq 'ALL';
  $self->_make_list($list);
  $self->{'lists'}{$list}->config_get(@_);
}

sub _list_config_set {
  my $self = shift;
  my $list = shift;
  
  $list = 'GLOBAL' if $list eq 'ALL';
  $self->_make_list($list);
  $self->{'lists'}{$list}->config_set(@_);
}

sub _list_config_lock {
  my $self = shift;
  my $list = shift;
  
  $list = 'GLOBAL' if $list eq 'ALL';
  $self->_make_list($list);
  $self->{'lists'}{$list}->config_lock(@_);
}

sub _list_config_unlock {
  my $self = shift;
  my $list = shift;
  
  $list = 'GLOBAL' if $list eq 'ALL';
  $self->_make_list($list);
  $self->{'lists'}{$list}->config_unlock(@_);
}

=head2 config_get_allowed, config_get_comment, config_get_intro,
config_get_isarray, config_get_isauto, config_get_groups,
config_get_type, config_get_visible

These return various information about a config variable:

  Allowed values (for enum variables)
  Comment
  Formatted introductory mater
  If the variable has array type
  A list of (visible level, modifiable level)
  The variables type

They just jump through the global list''s method since all lists have the
same variables.  This avoids needlessly vivifying a list''s config.

=cut
sub config_get_allowed {
  my $self = shift;
  my $var  = shift;
  $self->{'lists'}{'GLOBAL'}->config_get_allowed($var);
}

sub config_get_comment {
  my $self = shift;
  my $var  = shift;
  $self->{'lists'}{'GLOBAL'}->config_get_comment($var);
}

sub config_get_groups {
  my $self = shift;
  my $var  = shift;
  $self->{'lists'}{'GLOBAL'}->config_get_groups($var);    
}

sub config_get_intro {
  my $self = shift;
  my $list = shift;
  my $var  = shift;
  $self->_make_list($list);
  $self->{'lists'}{$list}->config_get_intro($var);
}

sub config_get_isarray {
  my $self = shift;
  my $var  = shift;
  $self->{'lists'}{'GLOBAL'}->config_get_isarray($var);    
}

sub config_get_isauto {
  my $self = shift;
  my $var  = shift;
  $self->{'lists'}{'GLOBAL'}->config_get_isauto($var);    
}

sub config_get_type {
  my $self = shift;
  my $var  = shift;
  $self->{'lists'}{'GLOBAL'}->config_get_type($var);
}

sub config_get_visible {
  my $self = shift;
  my $var  = shift;
  $self->{'lists'}{'GLOBAL'}->config_get_visible($var);
}

sub config_get_mutable {
  my $self = shift;
  my $var  = shift;
  $self->{'lists'}{'GLOBAL'}->config_get_mutable($var);
}

=head2 config_get_default(user, passwd, auth, interface, list, variable)

This returns the default value of a lists variable.

=cut
sub config_get_default {
  my ($self, $user, $passwd, $auth, $interface, $list, $var) = @_;

  $self->_fill_lists;
  $self->_make_list($list);
 
  # XXX Should check access here.  Sigh.

  $self->{'lists'}{$list}->config_get_default($var);
}

=head2 config_get_vars(list, var/group)

This takes a variable name or group and the normal security data, makes
certain that the data is visible to the password, expands a group to the
list of variables it contains, and returns a list of variables.  If this
returns no variables, there are none visible to the supplied password.

&_make_list
&validate_passwd
&list->config_get_vars

=cut
sub config_get_vars {
  my ($self, $user, $passwd, $auth, $interface, $list, $var) = @_;
  my (@groups, @out, $i, $error, $lvar, $ok);

  $::log->in(100, "$list, $var");

  $lvar = lc($var);

  $self->_make_list($list);

  if ($var eq 'ALL') {
    $ok = $self->validate_passwd($user, $passwd, $auth, $interface,
				   $list, "config_ALL");
  }

  # Do we have a group?
  elsif ($var eq uc($var)) {
    $ok = $self->validate_passwd($user, $passwd, $auth, $interface,
				   $list, "config_$lvar");
  }
  
  # We have a single variable
  else {
    @groups = $self->config_get_groups($var);
    unless (@groups) {
      $::log->out("not found");
      return;
    }
    for $i (@groups) {
      $ok = $self->validate_passwd($user, $passwd, $auth, $interface,
				     $list, "config_$i");
      last if $ok;
    }
  }

  @out = $self->{'lists'}{$list}->config_get_vars($var, $ok, ($list eq 'GLOBAL'));
  $::log->out($ok?"validated":"not validated");
  @out;
}

=head2 domain

This returns the domain that this Majordomo object is running in.

XXX The interface should already know, since _it_ told _us_.  This is only
used by deep objects making calls to us.

=cut
sub domain {
  my $self = shift;
  return $self->{'domain'};
}

=head2 _re_match

This expects a safe compartment to already be set up, and matches a
string against a regular expression within that safe compartment.  The
special 'ALL' regexp is also accepted, and always matches.

If called in an array context, also returns any errors encountered
while compiling the match code, so that this can be used as a general
regexp syntax checker.

=cut
sub _re_match {
  my $safe = shift;
  my $re   = shift;
  local $str  = shift;
#  my $log  = new Log::In 200, "$re, $str";
  my $match;
  return 1 if $re eq 'ALL';

  # Hack; untaint things.  That's why we're running inside a safe
  # compartment.
  $str =~ /(.*)/;
  $str = $1;
  $re =~ /(.*)/;
  $re = $1;

  $safe->share('$str');
  $match = $safe->reval("\$str =~ $re");
  if (wantarray) {
    return ($match, $@);
  }
  $::log->complain("_re_match error: $@") if $@;
  return $match;
}


##############

=head2 substitute_vars(file, subhash)

This routine iterates over a file and expands embedded "variables".  It
takes a file and a hash, the keys of which are the tags to be expanded.

=cut
sub substitute_vars {
  my $self = shift;
  my $file = shift;
  my %subs = @_;
  my ($tmp, $in, $out, $i);

  $tmp = $self->_global_config_get("tmpdir");
  $tmp = "$tmp/mj-tmp." . $self->unique;
  $in  = new Mj::File "$file"
    || $::log->abort("Cannot read file $file, $!");
  $out  = new IO::File ">$tmp"
    || $::log->abort("Cannot write to file $tmp, $!");
  
  while (defined ($i = $in->getline)) {
    $i = $self->substitute_vars_string($i, %subs);
    $out->print($i);
  }
  $in->close;
  $out->close;
  $tmp;
}
  
sub substitute_vars_string {
  my $self = shift;
  my $str  = shift;
  my %subs = @_;
  my $i;

  for $i (keys %subs) {
    $str =~ s/\$\Q$i\E\b/$subs{$i}/g;
  }
  $str;
}

=head2 unique, unique2, tempname

Request a unique value/filename.  The value returned by unique is
guaranteted to be different for successive calls and for calls in
different processes.  The value returned by unique2 is only guaranteed
to be different for successive calls.  Use unique to generate
filenames; use unique2 to generate parser tags and such.  Use tempname
to generate temporary filenames in the configured temporary directory.

=cut
sub unique {
  my $self = shift;

  my $unique = "$$.$self->{'unique'}";
  $self->{'unique'}++;
  $unique;
}

sub unique2 {
  my $self = shift;

  my $unique = $self->{'unique'};
  $self->{'unique'}++;
  $unique;
}

sub tempname {
  my $self = shift;

  my $tmp = $self->_global_config_get("tmpdir");
  return "$tmp/mj-tmp." . $self->unique;
}


##################

=head1 Filespace functions

These operate on a list''s filespace.

=head2 get_start, _get, get_chunk, get_done

These provide an iterative interface for the retrieval of list files.
Generally the public will retrieve files from the public directory, but
there are no security issues with allowing client gets from the toplevel as
long as read permission is properly set.  (It should _not_ be present on
spool files, for instance.)

We set an access variable for root-based accesses because we don''t want
most users to be able to poke around in anything but the public filespace.

XXX There is no locking and hence no protection against a file being
altered, replaced, or deleted while the get operation is in progress.  To
fix this, consider adding lock and unlock routines to FileSpace.pm, or
pushing the iterative process down into filespace.pm and manage the locks
there.  The downside is that then a client can hold a lock indefinitely,
which could screw things up worse.

=cut
sub get_start {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list, $vict,
      $name) = @_;
  my $log = new Log::In 50, "$list, $user, $name";
  my ($mess, $ok, $root);

  $root = 1 if $name =~ m!^/!;

  ($ok, $mess) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
                             $list, 'get', $user, $vict, $name, '', '',
			     'root' => $root);


  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_get($list, $user, $vict, $mode, $cmdline, $name);
}

sub _get {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $name) = @_;
  my $log = new Log::In 35, "$list, $name";
  my ($cset, $desc, $enc, $file, $mess, $nname, $ok, $type);

  $self->_make_list($list);

  # If given an "absolute path", trim it, else stick "public/" onto it
  unless (($nname = $name) =~ s!^/!!) {
    $nname = "public/$name";
  }
  
  ($file, $desc, $type, $cset, $enc) = 
    $self->_list_file_get($list, $nname);
  
  unless ($file) {
    return (0, "No such file \"$name\".\n");
  }
  
  # Start up the iterator if we're running in immediate mode
  if ($mode =~ /immediate/) {
    $self->{'get_fh'} = new IO::File $file;
    unless ($self->{'get_fh'}) {
      return 0;
    }
    return 1;
  }

  # Else build the entity and mail out the file
  $self->_get_mailfile($list, $victim, $file, $desc, $type, $cset, $enc);

  # and be sneaky and return another file to be read; this keeps the code
  # simpler and lets the owner customize the transmission message
  ($file, $desc, $type, $cset, $enc) = 
    $self->_list_file_get($list, 'file_sent');
  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return 0;
  }
  return 1;
}

use MIME::Entity;
use Mj::MailOut;
sub _get_mailfile {
  my ($self, $list, $vict, $file, $desc, $type, $cset, $enc) = @_;
  my ($ent, $sender);

  $sender = $self->_list_config_get($list, 'sender');

  $ent = build MIME::Entity
    (
     Path     => $file,
     Type     => $type,
     Charset  => $cset,
     Encoding => $enc,
     Subject  => $desc || "Requested file $file from $list",
     Top      => 1,
     Filename => undef,
    );

  $self->mail_entity($sender, $ent, $vict);
}

sub get_chunk {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list, $vict,
      $chunksize) = @_;
  my ($i, $line, $out);
  
  return unless $self->{'get_fh'};
  for ($i = 0; $i < $chunksize; $i++) {
    $line = $self->{'get_fh'}->getline;
    last unless defined $line;
    $out = '' unless $out;
    $out .= $line;
  }
  if (defined($out) && $self->{'get_subst'}) {
    $out = $self->substitute_vars_string($out, %{$self->{'get_subst'}});
  }
  return (1, $out);
}

sub get_done {
  my $self = shift;
  my $log = new Log::In 50;
  return unless $self->{'get_fh'};
  undef $self->{'get_fh'};
  undef $self->{'get_subst'};
  1;
}

=head2 faq_start, _faq, help_start, info_start, _info, intro_start, _intro

These are special-purpose functions for retrieving special sets of files
from the file storage.  They exist because we want to allow different
access restrictions and list/GLOBAL visibilities for certain sets of files,

=cut
sub faq_start {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list,
      $vict) = @_;
  my $log = new Log::In 50, "$list, $user";
  my ($mess, $ok);
  
  ($ok, $mess) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
                             $list, 'faq', $user, $vict);
  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_faq($list, $user, $vict, $mode, $cmdline, 'faq');
}

sub _faq {
  my ($self, $list, $requ, $victim, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$list";
  my ($cset, $desc, $enc, $file, $mess, $ok, $type);

  $self->_make_list($list);

  ($file, $desc, $type, $cset, $enc) = 
    $self->_list_file_get($list, 'faq');
  
  unless ($file) {
    return (0, "No FAQ available.\n");
  }
  
  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return 0;
  }
  return 1;
}

sub help_start {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list, $vict,
      $topic) = @_;
  my $log = new Log::In 50, "$user, $topic";
  my (@info, $file, $mess, $ok);
  
  ($ok, $mess) =
    $self->global_access_check($passwd, $auth, $interface, $mode, $cmdline,
                             'help', $user, $topic);

  # No stalls should be allowed...
  unless ($ok > 0) {
    return ($ok, $mess);
  }

  ($file) =  $self->_list_file_get('GLOBAL', "help/$topic");

  unless ($file) {
    return (0, "No help for that topic.\n");
  }

  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return 0;
  }
  $self->{'get_subst'} =
    {VERSION  => $Majordomo::VERSION,
     WHEREAMI => $self->_global_config_get('whereami'),
     WHOAMI   => $self->_global_config_get('whoami'),
     OWNER    => $self->_global_config_get('whoami_owner'),
     SITE     => $self->_global_config_get('site_name'),
     USER     => $user,
    };
  return 1;
}

sub info_start {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list,
      $vict) = @_;
  my $log = new Log::In 50, "$list, $user";
  my ($mess, $ok);
  
  ($ok, $mess) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
                             $list, 'info', $user, $vict);
  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_info($list, $user, $vict, $mode, $cmdline, 'info');
}

sub _info {
  my ($self, $list, $requ, $victim, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$list";
  my ($cset, $desc, $enc, $file, $mess, $ok, $type);

  $self->_make_list($list);

  ($file, $desc, $type, $cset, $enc) = 
    $self->_list_file_get($list, 'info');
  
  unless ($file) {
    return (0, "No info available.\n");
  }
  
  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return 0;
  }
  return 1;
}

sub intro_start {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list,
      $vict) = @_;
  my $log = new Log::In 50, "$list, $user";
  my ($mess, $ok);
  
  ($ok, $mess) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
                             $list, 'intro', $user, $vict);
  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_intro($list, $user, $vict, $mode, $cmdline);
}

sub _intro {
  my ($self, $list, $requ, $victim, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$list";
  my ($cset, $desc, $enc, $file, $mess, $ok, $type);

  $self->_make_list($list);

  ($file, $desc, $type, $cset, $enc) = 
    $self->_list_file_get($list, 'intro');
  
  unless ($file) {
    return (0, "No intro available.\n");
  }
  
  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return 0;
  }
  return 1;
}

# sub help_chunk {
#   my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list, $vict,
#       $chunksize) = @_;
#   my ($i, $line, $out);

#   return unless $self->{'help_fh'};
#   for ($i = 0; $i < $chunksize; $i++) {
#     $line = $self->{'help_fh'}->getline;
#     last unless defined $line;
#     $out = '' unless $out;
#     $out .= $line;
#   }
#   return (1, $out);
# }

# sub help_done {
#   my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode) = @_;
#   my $log = new Log::In 50;
#   return unless $self->{'help_fh'};
#   undef $self->{'help_fh'};
#   1;
# }

=head2 put_start(..., file, subject, content_type, content_transfer_encoding)

This starts the file put operation.

=cut
sub put_start {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list, $vict,
      $file, $subj, $type, $cset, $cte) = @_;
  my ($ok, $mess);
  
  $subj ||= $file;
  my $log = new Log::In 30, "$list, $file, $subj, $type, $cset, $cte";
  
  $self->_make_list($list);

  # Check the password
  ($ok, $mess) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'put', $user, $vict, $file, $subj,
			     "$type%~%$cset%~%$cte");
  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_put($list, $user, $vict, $mode, $cmdline, $file, $subj,
	      "$type%~%$cset%~%$cte");
}

sub _put {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $file, $subj, $stuff)
    = @_;
  my ($cset, $enc, $mess, $ok, $type);

  # Extract the encoded type and encoding
  ($type, $cset, $enc) = split('%~%', $stuff);

  my $log = new Log::In 35, "$list, $file, $subj, $type, $cset, $enc";
  $self->_make_list($list);

  # If given an "absolute path", trim it, else stick "public/" onto it
  unless ($file =~ s!^/!!) {
    $file = "public/$file";
  }

  # Make a directory instead?
  if ($mode =~ /dir/) {
    return $self->{'lists'}{$list}->fs_mkdir($file, $subj);
  }

  # The zero is the overwrite control; haven't quite figured out what to
  # do with it yet.
  $self->{'lists'}{$list}->fs_put_start($file, 0, $subj, $type, $cset, $enc);
}

=head2 put_chunk(..., data, data, data, ...)

Adds a bunch of data to the file.

=cut
sub put_chunk {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list, $vict,
      @chunk) = @_;
  
  $self->{'lists'}{$list}->fs_put_chunk(@chunk);
}

=head2 put_done(...)

Stops the put operation.

=cut
sub put_done {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list) = @_;
  
  $self->{'lists'}{$list}->fs_put_done;
}

sub index {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list, $vict,
      $dir) = @_;
  my ($ok, $mess, $root);
  my $log = new Log::In  30, "$list, $dir";
  
  $self->_make_list($list);

  # Are we rooted?  Special case '/help', so index GLOBAL /help works.
  $root = 1 if $dir =~ m!^/! && $dir ne '/help';

  # Check for access
  ($ok, $mess) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'index', $user, $vict, $dir, '', '',
			     'root' => $root);

  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_index($list, $user, $vict, $mode, $cmdline, $dir);
}

sub _index {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $dir) = @_;
  my $log = new Log::In 35, "$list, $dir";
  my ($nodirs, $recurse);

  $self->_make_list($list);

  # If given an "absolute path", trim it, else stick "public/" onto it
  unless ($dir =~ s!^/!!) {
    $dir = "public/$dir";
  }

  # Now trim a trailing slash
  $dir =~ s!/$!!;

  $nodirs  = 1 if $mode =~ /nodirs/;
  $recurse = 1 if $mode =~ /recurs/;

  (1, '', $self->{'lists'}{$list}->fs_index($dir, $nodirs, $recurse));
}
  

=head2 _list_file_get(list, file)

This forms the basic internal interface to a list''s (virtual) filespace.
All core routines which need to retrieve files should use this function as
it provides all of the i18n functionality for file access.

This handles figuring out the list''s default language, properly expanding
the search list and handling the share_list.

If $lang is defined, it is used in place of any default_language setting.

=cut
sub _list_file_get {
  my $self  = shift;
  my $list  = shift;
  my $file  = shift;
  my $lang  = shift;
  my $force = shift;
  my $log  = new Log::In 130, "$list, $file";
  my (%paths, @langs, @out, @paths, @search, @share, $ok, $d, $f, $i, $j,
      $l, $p, $tmp);

  $self->_make_list($list);
  @search = $self->_list_config_get($list, 'file_search');
  
  $lang ||= $self->_list_config_get($list, 'default_language'); 
  @langs = split(/\s*,\s*/, $lang);

  # Build @paths list; maintain %paths hash to determine uniqueness.
  for $i (@search, 'GLOBAL:$LANG', 'GLOBAL:',
	  'GLOBAL:stock/$LANG', 'GLOBAL:stock/en')
    {
      # Split and supply defaults
      ($l, $d) = split(':', $i);
      $l ||= $list; $d ||= '';
    
      # Build filename; no leading slashes allowed
      $f = "$d/$file"; $f =~ s!^/!!;
    
      # Expand if necessary; push into @paths array
      if ($f =~ /\$LANG/) {
	for $j (@langs) {
	  ($tmp = $f) =~ s/\$LANG/$j/g;
	  unless ($paths{"$l:$tmp"}) {
	    push @paths, [$l, $tmp];
	    $paths{"$l:$tmp"} = 1;
	  }
	}
      }
      else {
	unless ($paths{"$l:$f"}) {
	  push @paths, [$l, $f];
	  $paths{"$l:$f"} = 1;
	}
      }
    }
  undef %paths;

  # Now iterate over @paths and search
 PATH:
  for $i (@paths) {
    ($l, $f) = @{$i};

    # Consult the share list if necessary
    if ($l ne $list && $l ne 'GLOBAL') {
     SHARE:
      for $j ($self->_list_config_get($l, "file_share")) {
	if ($j =~ /^\s*$list\s*$/) {
	  $ok = 1;
	  last SHARE;
	}
      }
      next PATH unless $ok;
    }
    # The list shares with us, so we can get the file
    @out = $self->{'lists'}{$l}->fs_get($f, $force);
    
    # We are done if we got something
    return @out if @out;
  }
  return;
}

=head2 _list_file_put(list, name, source, overwrite, description,
content-type, charset, content-transfer-encoding, permissions)

Calls the lists fs_put function.

=cut
sub _list_file_put {
  my $self = shift;
  my $list = shift;
  $self->_make_list($list);
  $self->{'lists'}{$list}->fs_put(@_);
}

=head2 _list_file_delete(list, file, force)

Calls the lists fs_delete function.

=cut
sub _list_file_delete {
  my $self  = shift;
  my $list  = shift;
  my $log = new Log::In 150, "$list, $_[0]";
  $self->_make_list($list);
  $self->{'lists'}{$list}->fs_delete(@_);
}

=head2 list_file_sync(..., list)

This calls the lists sync function to bring the file database up to date.

=cut
sub list_file_sync {
  my ($self, $user, $passwd, $auth, $interface, $cmd, $mode, $list) = @_;

  $self->_make_list($list);
  $self->{'lists'}{$list}->fs_sync;
}
		 
###########################################

=head2 _fill_lists (private)

Fill in the lists hash with the names of the lists.  This doesn''t
actually allocate any List objects.

=cut 
sub _fill_lists {
  my $self = shift;

  # Bail early if we don't have to do anything
  return 1 if $self->{'lists_loaded'};
  
  $::log->in(120);

  my $dirh = new IO::Handle;
  my ($list, @lists);
  
  my $listdir = $self->{'ldir'};
  opendir($dirh, $listdir) || $::log->abort("Error opening $listdir: $!");

  if ($self->{'sdirs'}) {
    while (defined($list = readdir $dirh)) {
      $self->{'lists'}{$list} ||= undef
	if $self->legal_list_name($list) && -d "$listdir/$list";
    }
  }
  else {
    while (defined($list = readdir $dirh)) {
      # Make a hash entry for the list if it doesn't already exist
      $self->{'lists'}{$list} ||= undef
	if $self->legal_list_name($list);
    }
  }
  closedir($dirh);

  $self->{'lists_loaded'} = 1;
  $::log->out;
  1;
}

=head2 _make_list (private)

This makes a List object and stuffs it into the lists hash.  You can''t
actually call any list methods without doing this to the list first.

=cut
sub _make_list {
  my $self = shift;
  my $list = shift;

  return if $list eq 'ALL';
  unless ($self->{'lists'}{$list}) {
    $self->{'lists'}{$list} =
      new Mj::List $list, $self->{'ldir'}, $self->{'sdirs'}, $self->{'av'};
  }
  1;
}

=head2 legal_list_name(string)

This just checks to see if a string could be a legal list name.  It does
_not_ verify that the list exists.  This is a method call because in the
future it may be useful to determine what is a legal name by some internal
parameters.

This is expanded over what''s in 1.9x; we allow lists to have upper-case
names and to include periods.  Whether the MTA can deal with the necessary
aliases is another matter.

=cut
sub legal_list_name {
  my $self = shift;
  my $name = shift || "";

  $::log->message(200, "info", "legal_list_name", "$name");
  return undef unless $name;
  return undef if $name =~ /[^a-zA-Z0-9-_.]/;
  return undef if $name eq '.';
  return undef if $name eq '..';
  return undef if $name =~/^(RCS|core)$/;
  return 1;
}

=head2 valid_list(list, allok, globalok)

Checks to see that the list is valid, i.e. that it exists on the server.
This has the nice side effect of returning the untainted list name.

If allok, then ALL will be accepted as a list name.
If globalok, then GLOBAL will be accepted as a list name.

=cut
sub valid_list {
  my $self   = shift;
  my $name   = shift || "";
  my $all    = shift;
  my $global = shift;

  $::log->in(120, "$name");

  unless ($self->legal_list_name($name)) {
    $::log->out("failed");
    return undef;
  }

  $self->_fill_lists;
  
  if ((exists $self->{'lists'}{$name} ||
       ($name eq 'ALL' && $all)) &&
      ($name eq 'GLOBAL' ? $global : 1))
    {
      # untaint
      $name =~ /(.*)/;
      $name = $1;
      $::log->out;
      return $name;
    }
  
  $::log->out("failed");
  return undef;
}

##########################

=head1 Main core functions

These functions implement the core of functionality historically associated
with the Majordomo email interface.  The functions take the names of the
old commands whose functionality they most closely duplicate.

All of these commands take the following parameters, in order:

  user       - the user operating the interface, if known
  passwd     - any passwd, if given
  auth       - to be decided; some kind of extra auth key.  PGP key?
               Secret data to authenticate the interface itself?
  interface  - the name of the interface
  mode       - a command-specific behavior modfier
  cmdline    - a string used for user information and to forward to a
               remote Majordomo server.  Must be legal email command
               syntax.

All but mode are just passed into the access_check routine.

The command can (and usually does) take additional arguments, but these six
always come first and in order.

Command returns vary.

Most of these routines are split into two parts; the first performs any
access checking while the second (prefixed with an underscore and not to be
used by the interface) performs the action.  This makes it possible for the
authentication routine to suspend the action and perform it later, in
another run.  (Perhaps after a confirmation token has been returned.)

The bottom half of each function takes the following arguments:

  list         - the list
  requester    - the user who made the request (for owner info)
  victim       - the user who will be effected
  mode         - the command mode
  command line - the command line used to make the request
  arg1
  arg2         - the command-dependent arguments from the token
  arg3

=head2 accept(..., token)

Accepts a single token.  Any string can be passed in; if there is a token
within it, it will be extracted.  This is done so that the details of token
format are not exposed to the interface.

There is no bottom half, because while an accept can generate other tokens
(i.e. confirm+consult) an accept itself cannot be stalled.  That is, there
can never be a token for the 'accept' command.

=cut
sub accept {
  my ($self, $user, $pass, $auth, $int, $cmd, $mode, $list, $vict,
      $ttoken) = @_;
  my $log = new Log::In 30, "$ttoken";
  my ($token);

  $token = $self->t_recognize($ttoken);
  return (0, "Illegal token $ttoken.\n") unless $token;

  my ($ok, $mess, $data, @out) = $self->t_accept($token);

  # We don't want to blow up on a bad token; log something useful.
  unless (defined $data) {
    $data = {list      => 'GLOBAL',
	     request   => 'badtoken',
	     requester => $user,
	     victim    => 'none',
	     cmdline   => $cmd,
	    };
    @out = (0);
  }

  # Now call inform so the results are logged
  $self->inform($data->{'list'},
		$data->{'request'},
		$data->{'requester'},
		$data->{'victim'},
		$data->{'cmdline'},
		"token-$int",
		$out[0],
		0, 0);

  $mess ||= "Further approval is required.\n" if $ok<0;

  # We cannot pass the data ref out to the interface, so we choose to pass
  # some useful pieces.
  return ($ok, $mess,
	  $data->{'request'},
	  $data->{'requester'},
	  $data->{'cmdline'},
	  $data->{'mode'},
	  $data->{'list'},
	  $data->{'victim'},
	  $data->{'arg1'},
	  $data->{'arg2'},
	  $data->{'arg3'},
	  $data->{'time'},
	  $data->{'sessionid'},
	  @out);
}

=head2 alias(..., list, source, target)

Adds an alias from one address to another.

=cut
sub alias {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $to, $from) = @_;
  my $log = new Log::In 30, "$list, $to, $from";
  my ($ok, $mess, $mismatch);

  $self->_make_list($list);
  $mismatch = !$self->{'lists'}{$list}->addr_match($user, $from);
  ($ok, $mess) = 
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'alias', $user, $to, $from, '','',
			     'mismatch' => $mismatch);
  
  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }
  $self->_alias($list, $user, $to, $mode, $cmdline, $from);
}

sub _alias {
  my ($self, $list, $requ, $to, $mode, $cmdline, $from) = @_;
  my $log = new Log::In 35, "$list, $to, $from";

  $self->_make_list($list);

  # I got the internal call's arguments backwards.
  my($ok, $err) = $self->{'lists'}{$list}->alias_add($mode, $from, $to);
#  $self->inform($list, 'alias', $requ, $to, $cmdline, $ok);
  ($ok, $err);
}

=head2 auxadd(..., list, name, address)

This adds an address to a lists named auxiliary address list.

=cut
sub auxadd {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $addr, $name) = @_;
  my $log = new Log::In 30, "$list, $name, $addr";
  my(@out, $ok, $mess, $mismatch);

  $self->_make_list($list);
  $mismatch = !$self->{'lists'}{$list}->addr_match($user, $addr);
  ($ok, $mess) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'auxadd', $user, $addr, $name, '','',
			     'mismatch' => $mismatch);
  
  unless ($ok > 0) {
    $log->out("noaccess");
#    $self->inform($list, 'auxadd', $user, $addr, $cmdline, $ok);
    return ($ok, $mess);
  }
  
  $self->_auxadd($list, $user, $addr, $mode, $cmdline, $name);
}

sub _auxadd {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $name) = @_;
  my $log = new Log::In 35, "$name, $victim";

  $self->_make_list($list);

  # I got the internal call's arguments backwards.
  my($ok, $data) =
    $self->{'lists'}{$list}->aux_add($name, $mode, $victim);

  unless ($ok) {
    $log->out("failed, existing");
    return (0, "Already a member of $name as $data->{'fulladdr'}.\n");
  }

  1;
}

=head2 auxremove(..., list, name, address)

This removes an address from a lists named auxiliary address list.

=cut
sub auxremove {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $addr, $name) = @_;
  my(@removed, @out, $key, $data);
  
  $::log->in(30, "$list, $name, $addr");
  $self->_make_list($list);
  @removed = $self->{'lists'}{$list}->aux_remove($name, $mode, $addr);

  unless (@removed) {
    $::log->out("failed, nomatching");
    return (0, "No matching addresses.\n");
  }

  while (($key, $data) = splice(@removed, 0, 2)) {
    push @out, $data->{'stripaddr'};
  }
  $::log->out;
  (1, @out);
}

=head2 auxwho_start, auxwho_chunk, auxwho_done

These implement iterative access to an auxiliary list.

=cut
sub auxwho_start {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $vict, $file) = @_;
  my $log = new Log::In 30, "$list, $file";
  my ($check, $error);

  ($check, $error) = 
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'auxwho', $user);

  return (0, $error) unless $check;

  return (0, "Illegal sublist name $file.")
    unless $self->legal_list_name($file);

  $self->{'lists'}{$list}->aux_get_start($file);

  return 1;
}

sub auxwho_chunk {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $vict, $file, $chunksize) = @_;
  my (@chunk, @out, $i);

  $::log->in(100, "$list, $file");

  @chunk = $self->{'lists'}{$list}->aux_get_chunk($file, $chunksize);
  
  unless (@chunk) {
    $::log->out("finished");
    return 0;
  }
 
  # Here eliminate addresses that are unlisted
  for $i (@chunk) {
    # Call List::unlisted or whatever.
    push @out, $i;
  }
  
  $::log->out;
  return (1, @out);
}

sub auxwho_done {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $vict, $file) = @_;
  my $log = new Log::In 30, "$list, $file";

  $self->{'lists'}{$list}->aux_get_done($file);
  1;
}

=head2 createlist

Makes all of the directories in the Majordomo system required for a list to
operate.  (The required files are created as needed.)  This will also call
the proper routine in MTAConfig.pm to suggest aliases.

XXX Rely on umask to get the mode right.

Note that $list is the list to be created, and not a validated list.  Thus
it goes in an extra argument slot and not the normal list slot.  The victim
is the owner, since this is who will be sent introductory information.

=cut
use Mj::MTAConfig;
sub createlist {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $d1, 
      $owner, $list) = @_;
  my($mess, $ok);

  return (0, "Must supply a list name.")
    unless $list;

  return (0, "Must supply an address for the owner.")
    unless $owner;

  my $log = new Log::In 50, "$list, $owner";

  return (0, "Illegal list name: $list")
    unless $self->legal_list_name($list);
  
  $self->_fill_lists;

  # Check the password XXX Think more about where the results are
  # sent.  Noemally we expect that the majordomo-owner will be the
  # only one running this command, but if site policy allows other
  # users to run it, the information about the MTA configuration will
  # need to be sent to a different place than the results of the
  # command.
  ($ok, $mess) = 
    $self->global_access_check($passwd, $auth, $interface, $mode, $cmdline,
			       "createlist", $user, $owner, $owner, $list);
    
  unless ($ok > 0) {
    return ($ok, '', $mess);
  }

  $self->_createlist('', $user, $owner, $mode, $cmdline, $owner, $list);
}
    
sub _createlist {
  my($self, $dummy, $requ, $vict, $mode, $cmd, $owner, $list) = @_;
  my $log = new Log::In 35, "$list";
  my($bdir, $dir, $dom, $head, $mess, $mta);

  $mta  = $self->_global_config_get('mta');
  $dom  = $self->{'domain'};
  $bdir = $self->_global_config_get('install_dir');
  $bdir .= "/bin";
    
  unless ($mode =~ /nocreate/) {

    # Untaint $list - we know it's a legal name, so no slashes, so it's safe
    $list =~ /(.*)/; $list = $1;
    $dir  = "$self->{'ldir'}/$list";

    return (0, "List already exists.\n")
      if exists $self->{'lists'}{$list};

    unless (-d $dir) {
      mkdir $dir, 0777 
	or $log->abort("Couldn't make $dir, $!");
      mkdir "$dir/files", 0777
	or $log->abort("Couldn't make $dir/files, $!");
      mkdir "$dir/files/public", 0777
	or $log->abort("Couldn't make $dir/files/public, $!");
    }
  }
  
  unless ($mta && $Mj::MTAConfig::supported{$mta}) {
    return (1, '', "Unsupported MTA $mta, can't suggest configuration.");
  }
  
  {
    no strict 'refs';
    ($head, $mess) = &{"Mj::MTAConfig::$mta"}(
					      'list'   => $list,
					      'owner'  => $owner,
					      'bindir' => $bdir,
					      'domain' => $dom,
					     );
  }
  
  # XXX Now do some basic configuration and mail owner information.
  
  return (1, $head, $mess);
}

=head2 lists

Perform the lists command.  This gets the visible lists and their
descriptions and some data.

This returns a list of triples:

  the list name
  the list description
  a string containing single-letter flags

The descriptions will not contain newlines.  The interface should be
prepared to handle undefined descriptions.

If mode =~ /enhanced/, the flag string will contain the following:

  S - the user is subscribed

XXX More flags to come: D=digest available, 

Enhanced mode is terribly inefficient as it checks every list for
membership.

=cut
sub lists {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode) = @_;
  my $log = new Log::In 30, "$mode";
  my (@out, $list, $desc, $flags, $count, $limit, $ok, $err);
  
  # Check global access
  ($ok, $err) =
    $self->global_access_check($passwd, $auth, $interface, $mode, $cmdline,
			       "lists", $user);
  unless ($ok > 0) {
    return (0, $err);
  }

  $mode ||= $self->_global_config_get("default_lists_format");
  $limit = $self->_global_config_get("description_max_lines");

  if ($mode =~ /compact/) {
    $limit = 1;
  }

  for $list ($self->get_all_lists($user, $passwd, $auth, $interface)) {
    $desc = "";
    $flags = "";

    $count = 1;
    for ($self->_list_config_get($list, "description_long")) {
      $desc .= "$_\n";
      $count++;
      last if $limit && $count > $limit;
    }
    $desc ||= $self->_list_config_get($list, "description");

    if ($mode =~ /enhanced/) {
      $flags .= 'S' if $self->{'lists'}{$list}->is_subscriber($user);
    }
    push @out, $list, $desc, $flags;
  }

  return (1, @out);
}

=head2 reject(..., token)

Rejects a single token.  Any string can be passed in; if there is a
token in it, it will be extracted.  This is done so that the interface
does not need to know the internals of the token format.

There''s no bottom half, because there''s no security on tokens.  If
you have the token itself, you''ve proved your identity as well as it
can be proven.

XXX Need to add special information code here, because the usual
information code doesn''t give the owner enough info to figure out
what happened, and the token number is meaningless later.

=cut
use MIME::Entity;
sub reject {
  my ($self, $user, $pass, $auth, $int, $cmd, $mode, $list, $vict,
      $token) = @_;
  my $log = new Log::In 30, "$token";
  my (%repl, $cset, $cte, $ctype, $data, $desc, $ent, $file, $in, $inf,
      $inform, $line, $list_owner, $mj_addr, $mj_owner, $ok, $sess, $site);

  return (0, "Illegal token $token.\n")
    unless !$token || ($token = $self->t_recognize($token));

  ($ok, $data) = $self->t_reject($token);

  return (0, "No such token $token.\n") unless $ok;

  # For confirmation tokens, a rejection is a serious thing.  We send a
  # message to the victim with important information.
  if ($data->{'type'} eq 'confirm') {
    $list_owner = $self->_list_config_get($data->{'list'}, "sender");
    $site       = $self->_global_config_get("site_name");
    $mj_addr    = $self->_global_config_get("whoami");
    $mj_owner   = $self->_global_config_get("whoami_owner");

    # Extract the session data
    ($file) =
      $self->_list_file_get('GLOBAL', "sessions/$data->{'sessionid'}");
    # If the file no longer exists, what should we do?  We assume it's just
    # a really old token and say so.
    if ($file) {
      $in = new Mj::File "$file"
	|| $::log->abort("Cannot read file $file, $!");
      while (defined($line = $in->getline)) {
	$sess .= $line;
      }
      $in->close;
    }
    else {
      $sess = "Session info has expired.\n";
    }

    %repl = ('OWNER'      => $list_owner,
	     'MJ'         => $mj_addr,
	     'MJOWNER'    => $mj_owner,
	     'TOKEN'      => $token,
	     'REJECTER'   => $user,
	     'REQUESTER'  => $data->{'requester'},
	     'VICTIM'     => $data->{'victim'},
	     'CMDLINE'    => $data->{'cmdline'},
	     'REQUEST'    => $data->{'request'},
	     'LIST'       => $data->{'list'},
	     'SESSIONID'  => $data->{'sessionid'},
	     'SITE'       => $site,
	     'SESSION'    => $sess,
	    );
    
    ($file, $desc, $ctype, $cset, $cte) =
      $self->_list_file_get($data->{'list'}, "token_reject");
    $file = $self->substitute_vars($file, %repl);
    $desc = $self->substitute_vars_string($desc, %repl);
    
    # Send it off
    $ent = build MIME::Entity
      (
       Path        => $file,
       Type        => $ctype,
       Charset     => $cset,
       Encoding    => $cte,
       Filename    => undef,
       -From       => $mj_owner,
       -To         => $data->{'victim'},
       '-Reply-To' => $mj_owner,
       -Subject    => $desc,
      );
    
    $self->mail_entity($mj_owner, $ent, $data->{'victim'});
    $ent->purge;
    
    # Then we send a message to the list owner and majordomo owner if
    # appropriate
    ($file, $desc, $ctype, $cset, $cte) =
      $self->_list_file_get($data->{'list'}, "token_reject_owner");
    $file = $self->substitute_vars($file, %repl);
    $desc = $self->substitute_vars_string($desc, %repl);
    
    $ent = build MIME::Entity
      (
       Path        => $file,
       Type        => $ctype,
       Charset     => $cset,
       Encoding    => $cte,
       Filename    => undef,
       -From       => $mj_owner,
       '-Reply-To' => $mj_owner,
       -Subject    => $desc,
       -To         => $list_owner,
      );
    
    # Should we inform the list owner?
    $inform = $self->_list_config_get($data->{'list'}, 'inform');
    $inf = $inform->{'reject'}{'all'} || $inform->{'reject'}{1} || 0;
    if ($inf & 2) {
      $self->mail_entity($mj_owner, $ent, $list_owner);
    }

    # Should we inform majordomo-owner?
    $inform = $self->_global_config_get('inform');
    $inf = $inform->{'reject'}{'all'} || $inform->{'reject'}{1} || 0;
    if ($inf & 2) {
      $ent->head->replace('To', $mj_owner);
      $self->mail_entity($mj_owner, $ent, $mj_owner);
    }
    $ent->purge;
  }

  # We cannot pass the data ref out to the interface, so we choose to
  # pass some useful pieces.
  return ($ok, '', $token,
	  $data->{'request'},
	  $data->{'requester'},
	  $data->{'cmdline'},
	  $data->{'mode'},
	  $data->{'list'},
	  $data->{'vict'},
	  $data->{'arg1'},
	  $data->{'arg2'},
	  $data->{'arg3'},
	  $data->{'time'},
	  $data->{'sessionid'},
	 );
}


=head2 rekey(..., list)

This causes the list to rekey itself.  In other words, this recomputes the
keys for all of the rows of all of the databases based on the current
address transformations.  This must be done when the transformations
change, else address matching will fail to work properly.

=cut
sub rekey {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list) = @_;
  my $log = new Log::In 30, "$list";
  $self->_make_list($list);

  my ($ok, $error) = 
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, "rekey", $user);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $error);
  }

  $self->_rekey($list, $user, $user, $mode, $cmdline);
}

sub _rekey {
  my($self, $list, $requ, $vict, $mode, $cmd) = @_;
  my $log = new Log::In 35, "$list";

  $self->_make_list($list);
  $self->{'lists'}{$list}->rekey;
  return 1;
}

=head2 sessioninfo(..., $sessionid)

Returns the stored text for a given session id.

=cut
sub sessioninfo {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $dummy, $vict, $sessionid) = @_;
  my $log = new Log::In 30, "$sessionid";
  my($file, $in, $line, $sess);

  $in = new Mj::File "$self->{ldir}/GLOBAL/sessions/$sessionid"
    || return (0, "No such session.\n");
  while (defined($line = $in->getline)) {
    $sess .= $line;
  }
  $in->close;
  
  (1, '', $sess);
}

=head2 set

Perform the set command.  This changes various pieces of subscriber data.

There are two classes of settings: flags and subscriber classes.  The flags
are:

  ack/noack (A)
  selfcopy/noselfcopy (S)
  hideall/hideaddress/showall (H/h)
  eliminatecc/noeliminatecc (C)

The classes are:

  each,single (single messages)
  high (single messages, high piority)
  digest (default digest)
  digest-x (the named digest x)
  nomail,vacation (no mail at all)
  nomail-span (no mail for a span of days, months, years)
  nomail-(datespec) (no mail until datespec)
  all (all messages, including digests)

  x is defined by the list of digests the list owner creates.
  span looks like 1day, 4days, 1week, 4weeks, 1month, 1year.  No spaces
    allowed.
  datespec is anything Date::Manip can parse.

=cut
sub set {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $addr, $action, $arg) = @_;
  my $log = new Log::In 30, "$list, $addr, $action";
  my ($isflag, $ok, $raction);
 
  ($ok, $addr, undef) = $self->{'av'}->validate($addr);
  unless ($ok) {
    $log->out("failed, invalidaddr");
    return (0, "Invalid address:\n$addr");
  }

  $self->_make_list($list);

  # Check access

  return $self->{'lists'}{$list}->set($addr, $action, $arg);
}

=head2 show(..., mode, list, address)

Perform the show command.  This retrieves a pile of information about an
address and stuffs it in a list.

Returns:

 flag       - true if address is valid
 saddr      - the stripped address (or error message if invalid)
(
 comment    - the comment portion of the address
 xform      - the address after transformations are applied
 alias      - the result of an aliasing lookup
 aliases    - comma separated of equivalently aliased addresses
 flag       - true of address is a subscriber
 (
 fulladdr   - the full subscription address
 class      - the subscription class
 subtime    - the subscription time
 changetime - last change time
 flags      - comma separated list of flag names
 )
)

=cut
sub show {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $addr) = @_;
  my (@out, $ok, $comm, $data, $aliases);

  $::log->in(30, "$list, $addr");

  ($ok, $addr, $comm) = $self->{'av'}->validate($addr);
  unless ($ok) {
    $::log->out;
    return (0, $addr);
  }
  push @out, ($ok, $addr, $comm);

  $self->_make_list($list);

  # Transform
  $addr = $self->{'lists'}{$list}->transform($addr);
  push @out, $addr;
  
  # Alias
  $addr = $self->{'lists'}{$list}->alias_lookup($addr) || $addr;
  push @out, $addr;
  
  $aliases = join(',',$self->{'lists'}{$list}->alias_reverse_lookup($addr));
  push @out, $aliases;

  # Get membership info with no aliasing (since we already did it all)
  (undef, $data) = $self->{'lists'}{$list}->get_member($addr, 1);

  unless ($data) {
    $::log->out;
    return (@out, 0);
  }
  
  # Extract some useful data
  push @out, (1,
	      $data->{'fulladdr'},
	      $self->{'lists'}{$list}->describe_class($data->{'class'},
						      $data->{'classarg'}),
	      $data->{'subtime'}, $data->{'changetime'},
	     );
  
  # Deal with flags
  push @out, (join(',',
		   $self->{'lists'}{$list}->describe_flags($data->{'flags'})
		  )
	     );
  $::log->out;
  @out;
}

=head2 showtokens(..., list)

This returns a list of all tokens (and some data) associated with a given
list.  This is not an iterative function; it is assumed that the total
number of tokens will remain reasonably bounded (since they expire).

If $list is 'GLOBAL' and $mode contains 'all', data on all lists will be
fetched.  Otherwise only data on the specified list''s tokens (or GLOBAL
tokens) will be returned.

=cut
sub showtokens {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list) = @_;
  my $log = new Log::In 30, "$list";
  my ($error, $ok);
  
  $self->_make_list($list);
  ($ok, $error) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'showtokens', $user, '', '', '', '');
  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $error);
  }
  $self->_showtokens($list, $user, '', $mode, $cmdline);
}

sub _showtokens {
  my ($self, $list, $user, $vict, $mode, $cmd) = @_;
  my $log = new Log::In 35, "$list";
  my (@out, $data, $token);

  # We have access; open the token database and start pulling data.
  $self->_make_tokendb;
  $self->{'tokendb'}->get_start();
  while (1) {
    ($token, $data) = $self->{'tokendb'}->get(1);
    last unless $token;
    next unless $data->{'list'} eq $list || $list eq 'ALL';

    # Stuff the data
    push @out, ($token,
		$data->{'request'},
		$data->{'requester'},
		$data->{'cmdline'},
		$data->{'mode'},
		$data->{'list'},
		$data->{'victim'},
		$data->{'arg1'},
		$data->{'arg2'},
		$data->{'arg3'},
		$data->{'type'},
		$data->{'approvals'},
		$data->{'time'},
		$data->{'sessionid'},
		$data->{'reminded'},
	       );
  }

  return (1, @out);
}

=head2 subscribe(..., mode, list, address, class, flags)

Perform the subscribe command.  class should be a legal subscriber class.
flags should be a string containing subscriber flags.  mode be interpreted
to find a class and additional subscriber flags; it will also be passed
onto to the List::add routine.

Returns a list:

  flag - truth on success
  an error message

Note that the error message can be multiline; interfaces will need to be
able to deal with this.  The error message is not always defined; in that
case the failure was due to an access failure that did not return a
message.

=cut
sub subscribe {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $addr, $class, $flags) = @_;
  my ($ok, $error, $i, $matches_list, $mismatch, $whereami);
  
  my $log = new Log::In  30, "$list, $addr, $mode";
  
  $self->_make_list($list);

  # Validate the address
  ($ok, $error, undef) = $self->{'av'}->validate($addr);
  unless ($ok) {
    $log->out("failed, invalidaddr");
    return (0, "Invalid address:\n$error");
  }

  # Do a list_access_check here for the address; subscribe if it succeeds.
  # The access mechanism will automatically generate failure notices and
  # confirmation tokens if necessary.
  $whereami     = $self->_global_config_get('whereami');
  $matches_list = $self->{'lists'}{$list}->addr_match($addr, "$list\@$whereami");
  ($ok, $error) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'subscribe', $user, $addr, $class,
			     $flags, "", 'matches_list' => $matches_list,);
  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $error);
  }
  $self->_subscribe($list, $user, $addr, $mode, $cmdline, $class, $flags);
}

sub _subscribe {
  my $self  = shift;
  my $list  = shift;
  my $requ  = shift;
  my $vict  = shift;
  my $mode  = shift;
  my $cmd   = shift;
  my $class = shift;
  my $flags = shift;
  my $log   = new Log::In 35, "$list, $vict";
  my ($ok, $classarg, $cstr, $data, $welcome);

  $self->_make_list($list);

  # Gross.  We've overloaded the mode string to specify subscriber
  # flags as well, and that mechanism is reasonably nasty as is.  But
  # we have to somehow remove modes that we know might get to us but
  # that aren't legal subscriber flags, so that make_setting() doesn't
  # yell at us.  XXX Make this a variable somewhere.
  ($cstr = $mode) =~ s/(quiet|(no)?(welcome|inform|log)),?//g;
  
  ($ok, $class, $classarg, $flags) =
    $self->{'lists'}{$list}->make_setting($cstr, "");
  
  unless ($ok) {
    return (0, $class);
  }

  ($ok, $data) =
    $self->{'lists'}{$list}->add($mode, $vict, $class, $classarg, $flags);
  
  unless ($ok) {
    $log->out("failed, existing");
    return (0, "Already subscribed as $data->{'fulladdr'}.\n");
  }

  $welcome = $self->_list_config_get($list, "welcome");
  $welcome = 1 if $mode =~ /welcome/;
  $welcome = 0 if $mode =~ /(nowelcome|quiet)/;

  if ($welcome) {
    $ok = $self->welcome($list, $vict);
    unless ($ok) {
      # Perhaps complain to the list owner?
    }
  }
  return (1);
}

=head2 tokeninfo(..., token)

Returns all available information about a token, including the session data
(unless the mode includes "nosession").

=cut
sub tokeninfo {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $dummy, $vict, $token) = @_;
  my $log = new Log::In 30, "$token";
  my (@out, @removed, $mismatch, $ok, $regexp, $error, $key, $data, $sess);

  # Don't check access for now; users should always be able to get
  # information on tokens.  When we have some way to prevent lots of
  # consecutive requests, we could call the access check routine.

  # Call t_info to extract the token data hash
  ($ok, $error, $data) = $self->t_info($token);
  return ($ok, $error) unless $ok>0;

  # Pull out the session data
  if ($mode !~ /nosession/ && $data->{'sessionid'}) {
    ($ok, $error, $sess) =
      $self->sessioninfo($user, $passwd, $auth, $interface, $cmdline, $mode,
			 $dummy, $vict, $data->{'sessionid'});
  }    

  # Return the lot.
  return (1, '',
	  $data->{'request'},
	  $data->{'requester'},
	  $data->{'cmdline'},
	  $data->{'mode'},
	  $data->{'list'},
	  $data->{'victim'},
	  $data->{'arg1'},
	  $data->{'arg2'},
	  $data->{'arg3'},
	  $data->{'type'},
	  $data->{'approvals'},
	  $data->{'time'},
	  $data->{'sessionid'},
	  $sess,
	 );
}

=head2 trigger(...)

This is the generic trigger event.  It is designed to be called somehow by
cron or an alarm in an event loop or something to perform periodic tasks
like expiring old data in the various databases, reminding token owners, or
doing periodic digest triggers.

There are two modes: hourly, daily.

=cut
sub trigger {
  my ($self, $user, $passwd, $auth, $int, $cmd, $mode) = @_;
  my $log = new Log::In 27, "$mode";
  my($list);

  # Right now the interfaces can't call this function (it's not in the
  # parser tables) so we don't check access on it.

  # Mode: daily - clean out tokens and sessions and other databases
  if ($mode =~ /^d/) {
    $self->t_expire;
    $self->t_remind;
    $self->s_expire;
    
    # Loop over lists
    $self->_fill_lists;
    for $list (keys %{$self->{'lists'}}) {

      # GLOBAL never has duplicate databases
      next if $list eq 'GLOBAL';
      $self->_make_list($list);

      # Expire checksum and message-id databases
      $self->{'lists'}{$list}->expire_dup;
    }
  }

  # Mode: hourly
  # Loop over lists
  #   Trigger digests
  1;
}


=head2 unalias(..., list, source)

Removes an alias pointing from one address.

XXX Security???

=cut
sub unalias {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $source) = @_;
  my (@out);

  $::log->in(27, $source);
  
  $self->_make_list($list);
  @out = $self->{'lists'}{$list}->alias_remove($mode, $source);

  $::log->out;
  @out;
}


=head2 unsubscribe(..., mode, list, address)

Perform the unsubscribe command.  This just makes some checks, then calls
the List::remove function, then builds a useful result string.

Returns a list:

 flag - truth on success
 if failure, a message, else a list of removed addresses.

=cut
sub unsubscribe {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $addr) = @_;
  my $log = new Log::In 30, "$list, $addr";
  my (@out, @removed, $mismatch, $ok, $regexp, $error, $key, $data);

  $self->_make_list($list);

  unless ($mode =~ /regex/) {
    # Validate the address
    ($ok, $error, undef) = $self->{'av'}->validate($addr);
    unless ($ok) {
      $log->out("failed, invalidaddr");
      return (0, "Invalid address:\n$error");
    }
  }

  if ($mode =~ /regex/) {
    $mismatch = 0;
    $regexp   = 1;
  }
  else {
    # Check for mismatch; second address already validated.
    $mismatch = !$self->{'lists'}{$list}->addr_match($user, $error, 0, 0, 1, 0);
    $regexp   = 0;
  }
  ($ok, $error) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'unsubscribe', $user, $addr, '','','',
			     'mismatch' => $mismatch,
			     'regexp'   => $regexp,
			    );
  unless ($ok>0) {
    $log->out("noaccess");
    return ($ok, $error);
  }
  
  $self->_unsubscribe($list, $user, $addr, $mode, $cmdline);
}

sub _unsubscribe {
  my($self, $list, $requ, $vict, $mode, $cmd) = @_;
  my $log = new Log::In 35, "$list, $vict";
  my(@out, @removed, $key, $data);

  $self->_make_list($list);

  (@removed) = $self->{'lists'}{$list}->remove($mode, $vict);
  
  unless (@removed) {
    $log->out("failed, nomatching");
    return (0, "No matching addresses.\n");
  }

  while (($key, $data) = splice(@removed, 0, 2)) {
    push (@out, $data->{'fulladdr'});
  }

  return (1, @out);
}

=head2 which(..., string)

Perform the which command.  It loops over all lists advertized to the user
and calls each lists search method to find matching members.

This deals with both global and per-list restrictions on which and the
number of hits.

This returns a list:

flag
message
list of (list, address) match pairs

If the list is undef, the address is instead a message to be displayed.

mode can be "regexp" or "substring".  It's just passed to the search
routine.

This is optimized for small max hits values; we only get one value from the
search routine at a time because we assume we'll be allowed to hit only a
couple of times.

XXX Check for unlisted addresses?

XXX Require that for any match to succeed, the match must match a small
    number of addresses only.  In other words, return absolutely nothing
    instead of stopping the search if max_list_hits is exceeeded.  Use
    max_hits as the global maximum, not the total.  (It a user subscribes
    to a large number of lists, they should see all of them.  A global
    match limit can prevent this.)

=cut
sub which {
  my ($self, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $string) = @_;
  my $log = new Log::In 30, "$string";
  my (@matches, $data, $err, $hits, $match, $max_hits, $max_list_hits,
      $mess, $total_hits);

  # Check search string length; make sure we're not being trolled
  return (0, "Search string too short.\n")
    if length($string) < 3 || ($mode =~ /regex/ && length($string) < 5);

  # Check global access, to get max hit limit
  ($max_hits, $err) =
    $self->global_access_check($pass, $auth, $int, $mode, $cmd,
			       "which", $user);

  # Bomb if we're not allowed any hits
  return (0, $err)
    unless $max_hits;

  $total_hits = 0;

  # Loop over the lists that the user can see
 LIST:
  for $list ($self->get_all_lists($user, $pass, $auth, $int)) {
    
    # Check access for this list, 
    ($max_list_hits, $err) =
      $self->list_access_check($pass, $auth, $int, $mode, $cmd,
			       $list, "which", $user);
    
    next unless $max_list_hits;
    
    # We are authenticated and ready to search.
    $self->{'lists'}{$list}->get_start;
    $hits = 0;

   ADDR:
    while (1) {
      ($match, $data) = $self->{'lists'}{$list}->search($string, $mode);
      last unless defined $match;
      push @matches, ($list, $match);
      $total_hits++;
      $hits++;
      if ($total_hits >= $max_hits) {
	push @matches, (undef, "Total match limit exceeded.\n");
	last LIST;
      }
      if ($hits >= $max_list_hits) {
	push @matches, (undef, "Match limit exceeded.\n");
	last ADDR;
      }
    }
    $self->{'lists'}{$list}->get_done;
  }

  (1, $mess, @matches);
}

=head2 who_start, who_chunk, who_done

Perform the who command.  

These implement an iterator-based method of accessing a lists subscriber
list.  Call who_start with the usual parameters and the name of a list,
then call who_chunk repeatedly until failure is returned.  Call who_done at
any time to close things and reset the iterator.

There is only one iterator per list.  Bad things may happen if who_start is
called more than once without an intervening who_done.  (If Perl's garbage
collector works properly, all references to the old iterator will disappear
and it will be destroyed automatically.)

mode doesn"t do anything; I"m not sure if there"s anything to do with it.
It's here anyway, just in case.

who_chunk returns a flag and a list of members.  If the value is zero, the
iterator is finished.  If the value is one, the iterator is not yet
finished even though there may be no listed subscribers in this chunk.
Keep calling until the value is zero.

_who is the bottom half; it just calls the internal get_start routine to do
the setup and returns.

=cut
sub who_start {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $vict, $regexp) = @_;
  my $log = new Log::In 30, "$list";
  my ($ok, $error);

  ($ok, $error) = 
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, "who", $user, $regexp);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $error);
  }

  if ($ok > 1) {
    $self->{'unhide_who'} = 1;
  }

  $self->_who($list, $user, '', $mode, $cmdline);
}

sub _who {
  my ($self, $list, $requ, $victim, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$list";

  $self->_make_list($list);
  $self->{'lists'}{$list}->get_start;
}

use Mj::Addr;
use Safe;
sub who_chunk {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $d1, $regexp, $chunksize) = @_;
  my $log = new Log::In 100, "$list, $regexp, $chunksize";
  my (@chunk, @out, $i, $ok, $addr, $com, $safe);

  $regexp = "/$regexp/i" if $regexp;

  @chunk = $self->{'lists'}{$list}->get_chunk($chunksize);
  
  unless (@chunk) {
    $log->out("finished");
    return 0;
  }
 
  if ($regexp) {
    $safe = new Safe;
    $safe->permit_only(qw(const leaveeval null pushmark return rv2sv stub));
  }

  for $i (@chunk) {
    next if $regexp && !_re_match($safe, $regexp, $i->{fulladdr}); 
    # If we're to show it all...
    if ($self->{'unhide_who'}) {
      push @out, $i->{'fulladdr'};
      next;
    }

    # Else we hide if necessary
    if ($i->{'flags'} =~ /h/) {
      ($ok, $addr, $com) = $self->{'av'}->validate($i->{'fulladdr'});
      if ($com) {
	push @out, $com;
      }
      else {
	$addr =~ s/\@.*//;
	push @out, $addr;
      }
    }
    elsif ($i->{'flags'} =~ /H/) {
      next;
    }
    else {
      push @out, $i->{'fulladdr'};
    }
  }
  
  return (1, @out);
}

sub who_done {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list) = @_;
  my $log = new Log::In 30, "$list";

  $self->{'lists'}{$list}->get_done;
  $self->{'unhide_who'} = 0;

  1;
}

# =head2 writeconfig

# This just calls the config internal Config::Old::save command.  $mode is ignored.

# =cut
# sub writeconfig {
#   my ($user, $passwd, $outfh, $mode, $list) = @_;
#   my ($vlist);
  
#   $::log->in(30, "info", "Internal writeconfig", "$list");

#   unless (defined($vlist = ::list_valid($list))) {
#     print $outfh "Invalid list \"$list\".\n";
#     return undef;
#   }

#   Mj::Config::Old::save($vlist);
  
#   $::log->out;
#   return 1;
# }

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
### cperl-indent-level:2 ***
### cperl-label-offset:-1 ***
### End: ***


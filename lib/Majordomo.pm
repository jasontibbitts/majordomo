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
$VERSION = "0.1200005190";
$unique = 'AAA';

use strict;
no strict 'refs';
use vars (qw($indexflags $safe $tmpdir $unique));
use IO::File;
use Mj::Log;
use Mj::List;
use Mj::AliasList;
use Mj::RegList;
use Mj::Addr;
use Mj::Access;
use Mj::MailOut;
use Mj::Token;
use Mj::Resend;
use Mj::Inform;
use Mj::CommandProps ':function';
use Safe;

#BEGIN{$AutoLoader::Verbose = 1; $Exporter::Verbose = 1;};
#BEGIN{sub UNIVERSAL::import {warn "Importing $_[0]"};};
#BEGIN{sub CORE::require {warn "Requiring $_[0]"; CORE::require(@_);};};

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

  my $log = new Log::In 50, "$topdir, $domain";

  unless (-d $topdir) {
    return "Top level directory $topdir does not exist!";
  }

  my $self   = {};
  bless $self, $class;
  $self->{'sdirs'}  = 1;
  $self->{'topdir'} = $topdir;
  $self->{'ldir'}   = ($domain =~ m!^/!) ? $domain : "$topdir/$domain";
  $self->{'sitedir'}= "$topdir/SITE";
  $self->{'domain'} = $domain;
  $self->{'lists'}  = {};

  unless (-d $self->{'ldir'}) {
    return "The domain '$domain' does not exist!";
  }

  # Pull in the site configuration file
  $self->{'sitedata'}{'config'} = do "$topdir/SITE/config.pl";
  $log->abort("Can't find site config file $topdir/SITE/config.pl: $!")
    unless $self->{'sitedata'}{'config'};

  # Pull in config variable default string for this domnain
  if (-f "$topdir/LIB/cf_defs_$domain.pl") {
    require "$topdir/LIB/cf_defs_$domain.pl";
  }
  else {
    # This will search the library path
    require "mj_cf_defs.pl";
  }

  $self->{backend} = ''; # Suppress warnings
  $self->_make_list('GLOBAL');
  $self->_make_list('DEFAULT');
  $self->{backend} = $self->_site_config_get('database_backend');
  $self->{alias} = new Mj::AliasList("$self->{ldir}/GLOBAL/_aliases",
				     $self->{backend});
  $self->{reg}   = new Mj::RegList("$self->{ldir}/GLOBAL/_register",
				     $self->{backend});

  # Pull in the constants for our address validator
  Mj::Addr::set_params
    (
     'aliaslist'        => $self->{alias},
     'allow_bang_paths' => $self->_global_config_get('addr_allow_bang_paths'),
     'allow_ending_dot' => $self->_global_config_get('addr_allow_ending_dot'),
     'limit_length'     => $self->_global_config_get('addr_limit_length'),
     'require_fqdn'     => $self->_global_config_get('addr_require_fqdn'),
     'xforms'           => $self->_global_config_get('addr_xforms'),
     'allow_at_in_phrase'
       => $self->_global_config_get('addr_allow_at_in_phrase'),
     'allow_comments_after_route'
       => $self->_global_config_get('addr_allow_comments_after_route'),
     'strict_domain_check'
       => $self->_global_config_get('addr_strict_domain_check'),
    );

  unless (defined($safe)) {
    $safe = new Safe;
#    $safe->reval('$^W=0');
    $safe->permit_only(qw(const leaveeval null pushmark return rv2sv stub));
  }
  unless (defined($tmpdir)) {
    $tmpdir = $self->_global_config_get('tmpdir');
  }

  $self;
}

sub DESTROY {
  my $self = shift;
  undef $self->{alias};
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
  my $user = shift || 'unknown@anonymous';
  my $log = new Log::In 50, "$int, $user";
  my ($err, $id, $ok, $path);

  $user = new Mj::Addr($user);
  ($ok, $err) = $user->valid;

  return (undef, "Invalid address: $user\n$err") unless $ok;

  $self->{sessionuser} = $user;

  # Generate a session ID; hash the session, the time and the PID
  $id = MD5->hexhash($sess.scalar(localtime).$$);
  $id =~ /(.*)/; $id = $1; # Safe to untaint because it's nearly impossible
                           # to leak information through the digest
                           # algorithm.

  # Open the session file; overwrite in case of a conflict;
  $self->{sessionid} = $id;
  $self->{sessionfh} =
    new IO::File(">$self->{ldir}/GLOBAL/sessions/$id");
  
  $log->abort("Can't write session file to $self->{ldir}/GLOBAL/sessions/$id, $!")
    unless $self->{sessionfh};

  $self->{sessionfh}->print("Source: $int\n");
  $self->{sessionfh}->print("PID:    $$\n\n");
  $self->{sessionfh}->print("$sess\n");

  # Now check if the client has access.  (Didn't do it earlier because we
  # want to save the session data first.)
  ($ok, $err) =
    $self->global_access_check(undef, undef, undef, undef, $int,
			       'access', $user);

  # If the access check failed we tell the client to sod off.  Clearing the
  # sessionid prevents further actions.
  unless ($ok > 0) {
    undef $self->{sessionfh};
    undef $self->{sessionid};
    return (undef, $err);
  }

  return wantarray ? ($id, $user->strip) : $id;
}

=head2 dispatch(function, user, passwd, auth, interface, mode, cmdline, list, victim, ...)

This is the main interface to all non-utility functionality of the
Majordomo core.  It handles calling the appropriate function and logging
its return value.

It could possibly provide for the removal of much repeated code by also
calling the security routines and possibly even making the appropriate
calls to deeper objects.  This would eliminate both the bottom and top
halves of some functions.  This will have to wait, however.

This uses the %commands hash to determine what a particular function
needs.  The keys of this hash are the function names; the values are
hashrefs with the following keys:

  top ------- if this exists, control will be passed to the top half
    function with the same name as the function.  No other processing will
    be done.

  iter ------- true if this function is really a trio of iterator
    functions; the dispatcher will accept the three functions $fun_start,
    $fun_chunk and $fun_done.  Only the first will be security checked.

  noaddr - true if no address pasring should be done.  Normally the
  dispatcher whii create and initialize appropriate address objects, but
  some calls either never use the addresses or are not expected to be
  called with legal addresses.  These functions should expect to be passed
  strings instead of Mj::Addr objects, and should create those objects
  themselves if they ever do need to operate on addresses.

Note that the _chunk and _done iterator functions have 'noaddr' implied.
(They''re called repeatedly and have everything that needs address
processing done at the beginning.

=cut
sub dispatch {
  my ($self, $fun, $user, $pass, $auth, $int, $cmd, $mode, $list, $vict,
      @extra) = @_;
  my(@out, $base_fun, $continued, $mess, $ok, $over);

  ($base_fun = $fun) =~ s/_(start|chunk|done)$//;
  $continued = 1 if $fun =~ /_(chunk|done)/;
  $list ||= 'GLOBAL';
  $user ||= 'unknown@anonymous';
  $vict ||= $user;
  $mode ||= '';

  my $log  = new Log::In 29, "$fun, $user, $vict" unless $fun =~ /_chunk$/;

  $log->abort('Not yet connected!') unless $self->{'sessionid'};

  unless (function_legal($fun)) {
    return (0, "Illegal core function: $fun.\n");
  }

  # Turn some strings into addresses and check their validity; never with a
  # continued function (they never need it) and only if the function needs
  # validated addresses.
  unless ($continued || function_prop($fun, 'noaddr')) {
    $user = new Mj::Addr($user);
    ($ok, $mess) = $user->valid;
    return (0, "$user is an invalid address:\n$mess")
      unless $ok;

    $vict = new Mj::Addr($vict);
    ($ok, $mess) = $vict->valid;
    return (0, "$vict is an invalid address:\n$mess")
      unless $ok;
  }

  # Check for suppression of logging and owner information
  if ($mode =~ /nolog/) {
    # This is serious; user must use the master global password.
    $ok = $self->validate_passwd($user, $pass, $auth, $int,
				 'GLOBAL', 'ALL', 1);
    return (0, "The given password is not sufficient to disable logging.")
      unless $ok > 0;
    $over = 2;
  }
  elsif ($mode =~ /noinform/) {
    $ok = $self->validate_passwd($user, $pass, $auth, $int, $list,
				 'config_inform');
    return (0, "The given password is not sufficient to disable owner information.")
      unless $ok > 0;
    $over = 1;
  }
  else {
    $over = 0;
  }

  if (function_prop($fun, 'top')) {
    @out = $self->$fun($user, $pass, $auth, $int, $cmd, $mode, $list, $vict, @extra);
  }
  else {
    # Last resort; we found _nothing_ to call
   return (0, "No action implemented for $fun");
  }
  if ($base_fun eq 'post' and defined $out[1]) {
    $user = $out[1];
  }
  # Inform unless overridden or continuing an iterator
  unless ($over == 2 || $fun =~ /_(chunk|done)$/) {
    $self->inform($list, $base_fun, $user, $vict, $cmd, $int, $out[0],
		  !!$pass+0, $over, '')
  }
  @out;
}

use AutoLoader 'AUTOLOAD';
1;
__END__

=head1 Utility functions

These functions are called from various places in the code to do verious
small tasks.

=head2 get_all_lists(user, passwd, auth, interface)

This just grabs all of the lists that are accessible by the user and
returns them in an array.

=cut
sub get_all_lists {
  my ($self, $user, $passwd, $auth, $interface) = @_;
  my $log = new Log::In 100;
  my (@lists, $always, $list);

  $user = new Mj::Addr($user);
  $self->_fill_lists;
  $always = $self->_global_config_get('advertise_subscribed');

  for $list (keys %{$self->{'lists'}}) {
    next if ($list eq 'GLOBAL' or $list eq 'DEFAULT');

    # If membership always overrides advertising:
    if ($always && $self->is_subscriber($user, $list)) {
      push @lists, $list;
      next;
    }

    # Else do the full check
    $self->_make_list($list);
    if ($self->list_access_check($passwd, $auth, $interface, '', 'lists',
				 $list, 'advertise', $user))
      {
	push @lists, $list;
      }
  }
  sort @lists;
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
  my    $re = shift;
  local $_  = shift;
#  my $log  = new Log::In 200, "$re, $_";
  my ($match, $warn);
  return 1 if $re eq 'ALL';

  # Hack; untaint things.  That's why we're running inside a safe
  # compartment. XXX Try it without the untainting; it has a speed penalty.
  # Routines that need it can untaint as appropriate before calling.
  $_ =~ /(.*)/;
  $_ = $1;
  $re =~ /(.*)/;
  $re = $1;

  local($^W) = 0;
  $match = $safe->reval("$re");
  $warn = $@;
  $::log->message(10,'info',"_re_match error: $warn string: $_\nregexp: $re") if $warn;
  if (wantarray) {
    return ($match, $warn);
  }
#  $log->out('matched') if $match;
  return $match;
}

=head2 substitute_vars(file, subhashref, filehandle, list, depth)

This routine iterates over a file and expands embedded "variables".  It
takes a file and a hash, the keys of which are the tags to be expanded.
The hash of substitutions ($subs) is allowed to be undefined, in which
case only $INCLUDE processing is done, but _list_file_get currently
does not call this routine if $subs is undefined.

=cut
sub substitute_vars {
  my $self = shift;
  my $file = shift;
  my $subs = shift;
  my $list = shift || 'GLOBAL';
  my $out  = shift;
  my $depth= shift || 0;
  my ($tmp, $in, $i, $inc);
  my $log = new Log::In 200, "$file, $list, $depth";

  # always open a new input file
  $in  = new Mj::File "$file"
    or $::log->abort("Cannot read file $file, $!");

  # open a new output file if one is not already open (should be at $depth of 0)
  $tmp = $tmpdir;
  $tmp = "$tmp/mj-tmp." . unique();
  $out ||= new IO::File ">$tmp"
    or $::log->abort("Cannot write to file $tmp, $!");
  
  while (defined ($i = $in->getline)) {
    # Don't process INCLUDE after a backslashed $
    if ($i =~ /([^\\]|^)\$INCLUDE-(.*)$/) {
      # Do a _list_file_get.  If we get a file, open it and call
      # substitute_vars on it, printing to the already opened handle.  If
      # we don't get a file, print some amusing text.
      ($inc) =  $self->_list_file_get($list, $2);

      if ($inc) {
	if ($depth > 3) {
	  $out->print("Recursive inclusion depth exceeded\n ($depth levels: may be a loop, now reading $2)\n");
	}
	else {
	  # Got the file; substitute in it, perhaps recursively
	  $self->substitute_vars($inc, $subs, $list, $out, $depth+1);
	}
      }
      else {
	warn "Include file $2 not found.";
	$out->print("Include file $2 not found.\n");
      }
      next;
    }
    # don't waste time in substitute_vars_string unless there is a hash
    $i = $self->substitute_vars_string($i, $subs) if($subs);
    $out->print($i);
  }
  $in->close;
  $out->close if(!$depth);
  $tmp;
}

=head2 substitute_vars_string(string, subhashref)

This substitutes embedded variables in a string.

If passed an arrayref instead of a string, the elements of the array are
operated on instead.  Note that in this case, the array elements are
modified.  The operation is recursive.

=cut
sub substitute_vars_string {
  my $self = shift;
  my $str  = shift;
  my $subs = shift;
  my $i;

  if (ref $str eq 'ARRAY') {
    for (@$str) {
      # Perform a recursive substitution
      $_ = $self->substitute_vars_string($_, $subs);
    }
    return $str;
  }

  for $i (keys %$subs) {
    # Don't substitute after backslashed $'s
    $str =~ s/([^\\]|^)\$\Q$i\E(\b|$)/$1$subs->{$i}/g;
  }
  $str =~ s/\\\$/\$/g;
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
  my $tmp = "$$.$unique";
  $unique++;
  $tmp;
}

sub unique2 {
  $unique++;
  $unique;
}

sub tempname {
 "$tmpdir/mj-tmp." . unique();
}

=head2 _reg_add($addr, %args)

Adds a user to the registration database.

addr should be a Mj::Addr object so that the necessary data can be obtained
from it.

Args is a hash; all keys in the reglist database are recignized, with the
followig exceptions:

list - a list to add to the set of lists that the user is in.

update - should an existing entry be updated with any database values in
args.  Note that if list has a value and update is false, only the new list
will be added and all other entries will remain the same (besides
changetime).

Returns:
  flag - was the user already in the database

Problem: when we are called from subscribe, we need to add the address is
it isn''t already there, so we have to provide some default data so that
this can happen all in one pass.  But this results in the old data being
overrwitten.

=cut
sub _reg_add {
  my $self = shift;
  my $addr = shift;
  my %args = @_;
  my $log = new Log::In 200;
  my (@lists, $data, $existing);
  
  # Look up the user
  $data = $self->{reg}->lookup($addr->canon);

  # If the entry doesn't exist, we need to generate a new one.
  if ($data) {
    $existing = 1;
  }
  else {
    # Make a new registration
    $data = {
             stripaddr => $addr->strip,
             fulladdr  => $addr->full,
             regtime   => time,
             language  => '',
             'lists'   => '',
             flags     => '',
             bounce    => '',
             warnings  => '',
             data1     => '',
             data2     => '',
             data3     => '',
             data4     => '',
             data5     => '',
	    };
  }

  # Copy arguments 
  if (!$existing || $args{'update'}) {
    for my $i (qw(regtime password language lists flags bounce warnings
	       data1 data2 data3 data4 data5)) {
      $data->{$i} = $args{$i} if $args{$i};
    }
  }

  if ($args{list}) {
    @lists = split("\002", $data->{'lists'});
    push @lists, $args{list};
    $data->{'lists'} = join("\002", sort @lists);
  }

  # Replace or add the entry
  if ($existing && ($args{'update'} || $args{'list'})) {
    $self->{reg}->replace('', $addr->canon, $data);
  }
  else {
    $self->{reg}->add('', $addr->canon, $data);
  }
  return ($existing, $data);
}

=head2 _reg_lookup($addr, $regdata, $cache)

This looks up an address in the registration database and caches the
results within the Addr object.  The registration data is returned.

It the optional $regdata parameter is provided, it will be used as the
registration data instead of a database lookup.  This will result in the
appropriate data being cached without any lookups being done.

If the optional $cache parameter is proviced, the request will be served
from cached data within the address, if any exists.  This should only be
used where possibly stale data is acceptable.

This caches registration data under the 'reg' tag and a hash of subscribed
lists under the 'subs' tag.

Returns the registration data that was looked up.

=cut
sub _reg_lookup {
  my $self = shift;
  my $addr = shift;
  my $reg  = shift;
  my $cache = shift;
  my ($subs, $tmp);

  return undef unless $addr->isvalid;
  return undef if $addr->isanon;

  $tmp = $addr->retrieve('reg');
  if ($cache && $tmp) {
    return $tmp;
  }

  $reg = $self->{reg}->lookup($addr->canon) unless $reg;
  return undef unless $reg;

  $subs = {};
  for my $i (split("\002", $reg->{'lists'})) {
    $subs->{$i} = 1;
  }
  # Use this cached data for non-critical things only.  Don't try to modify
  # it and write it back.
  $addr->cache('reg',  $reg);
  $addr->cache('subs', $subs);
  $reg;
}

=head2 _reg_remove($addr, $list)

Removes a list from the set of subscribed lists in a user''s register
entry.

Note that this does not remove the entry altogether if the user has left
their last list.  They may be intending to join another list immediately or
in the near future, so removing their password would be a bad thing.

XXX A periodic process could cull stale registrations, or a command could
be provided to remove a user''s reguistration (unsubscribing them from all
of their lists in the process).

XXX There is a race here between removing the user from the list and
removing the list from the user''s registration.  This should be rare, but
not impossible.  To solve this we need to lock some special file (the
global lock, perhaps?) or add a lock primitive to the database backends so
that we can modify both atomically.

=cut
sub _reg_remove {
  my $self = shift;
  my $addr = shift;
  my $list = shift;
  my $log  = new Log::In 200, "$addr, $list";

  my $sub =
    sub {
      my $data = shift;
      my (@lists, @out, $i);

      @lists = split("\002", $data->{'lists'});
      for $i (@lists) {
        push @out, $i unless $i eq $list;
      }
      $data->{'lists'} = join("\002", sort @out);
      $data;
    };
      
  $addr->flush;
  $self->{'reg'}->replace('', $addr->canon, $sub);
}


=head2 _alias_reverse_lookup($addr)

This finds all aliases that point to a single address, except for the
circular bookkeeping alias.

Note that this returns strings, not address objects.  Since the results of
this routine will normally be used as keys for alias removal (upon
deregistration) or for display to the user, this isn''t a concern.

=cut
sub _alias_reverse_lookup {
  my $self = shift;
  my $addr = shift;
  my (@data, @out, $data, $key);
  
  $self->{'alias'}->get_start;
  
  # Grab _every_ matching entry
  @data = $self->{'alias'}->get_matching(0, 'target', $addr->canon);
  $self->{'alias'}->get_done;
  
  while (($key, $data) = splice(@data, 0, 2)) {
    unless ($key eq $data->{'target'}) {
      push @out, $data->{'stripsource'};
    }
  }
  @out;
}

=head2 is_subscriber($addr, $list, $regdata)

This checks to see if an address is subscribed to a list.  Since the
registration database holds all of the necessary information, we don''t
have to consult any lists, nor do we have to even create the lists.

Returns true if the user is a member of the given list.

=cut
sub is_subscriber {
  my $self = shift;
  my $addr = shift;
  my $list = shift;
  my $reg  = shift;
  my ($subs);

  # By default, invalid addresses and anonymous addresses are never
  # subscribers to anything
  return 0 unless $addr->isvalid;
  return 0 if $addr->isanon;

  # If passed some data, prime the cache
  if ($reg) {
    $self->_reg_lookup($addr, $reg);
  }
  # Pull out the membership hash
  $subs = $addr->retrieve('subs');

  # Finally, do a lookup to get the data;
  unless ($subs) {
    $self->_reg_lookup($addr);
    $subs = $addr->retrieve('subs');
  }

  return 0 unless $subs;
  return 1 if $subs->{$list};
  0;
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

Retrieve the value of a global config variable by passing the appropriate
parameters to list_config_get.

=cut
sub global_config_get {
  my ($self, $user, $passwd, $auth, $interface, $var, $raw) = @_;
  $self->list_config_get($user, $passwd, $auth, $interface,
			 'GLOBAL', $var, $raw);
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

  # Make sure we have a real user before checking passwords
  $user = new Mj::Addr($user);
  return unless $user && $user->isvalid;

  for $i ($self->config_get_groups($var)) {
    $ok = $self->validate_passwd($user, $passwd, $auth, $interface,
				   $list, "config_$i");
    last if $ok > 0;
  }
  unless ($ok > 0) {
    return;
  }
  $self->_list_config_get($list, $var, $raw);
}

=head2 list_config_set

Alters the value of a list''s config variable.  Returns a list:

 flag    - true if command succeeded
 message - to be shown to user if present

Ugh, we need to call inform but it clutters up the code badly.

=cut
sub list_config_set {
  my ($self, $user, $passwd, $auth, $int, $list, $var) =
    splice(@_, 0, 7);
  my $log = new Log::In 150, "$list, $var";
  my (@groups, @out, $i, $mess, $ok, $global_only);

  $self->_make_list($list);

  if (!defined $passwd) {
    $self->inform($list, 'config_set', $user, $user, "configset $list $var",
		  $int, 0, 0, 0, '');
    return (0, "No passwd supplied.\n");
  }

  $user = new Mj::Addr($user);
  ($ok, $mess) = $user->valid;
  if (!$ok) {
    $self->inform($list, 'config_set', $user, $user, "configset $list $var",
		  $int, 0, 0, 0, '');
    return (0, "$user is invalid\n$mess");
  }


  @groups = $self->config_get_groups($var);
  if (!@groups) {
    $self->inform($list, 'config_set', $user, $user, "configset $list $var",
		  $int, 0, 0, 0, '');
    return (0, "Unknown variable \"$var\".\n");
  }
  $global_only = 1;
  if ($self->config_get_mutable($var)) {
    $global_only = 0;
  }
  
  # Validate passwd
  for $i (@groups) {
    $ok = $self->validate_passwd($user, $passwd, $auth, $int,
				 $list, "config_\U$i", $global_only);
    last if $ok > 0;
  }
  unless ($ok > 0) {
    $ok = $self->validate_passwd($user, $passwd, $auth, $int,
				 $list, "config_$var", $global_only);
  }
  unless ($ok > 0) {
    $self->inform($list, 'config_set', $user, $user, "configset $list $var",
		  $int, 0, 1, 0, '');
    return (0, "Password does not authorize $user to alter $var.\n");
  }

  # Untaint the stuff going in here.  The security implications: this
  # may (after suitable interpretation) turn into code or an eval'ed
  # regexp.  We are sure (for other reasons) do do everything in
  # suitable Safe compartments.  Besides, the generated code/regexps
  # will be saved out and read in later, at which point they will be
  # untainted for free.  This this untainting only lets us make use
  # of a variable setting in the same session that sets it without
  # failing.
  for ($i = 0; $i < @_; $i++) {
    $_[$i] =~ /(.*)/;
    $_[$i] = $1;
  }
  
  # Get possible error value and print it here, for error checking.
  ($ok, $mess) = $self->_list_config_set($list, $var, @_);
  $self->_list_config_unlock($list);
  if (!$ok) {
    @out = (0, "Error parsing $var:\n$mess");
  }
  elsif ($mess) {
    @out = (1, "Warnings parsing $var:\n$mess");
  }
  else {
    @out = (1);
  }
  $self->inform($list, 'config_set', $user, $user, "configset $list $var",
		$int, $out[0], !!$passwd+0, 0, '');
  @out;
}

=head2 list_config_set_to_default

Removes any definition of a config variable, causing it to track the
default.

=cut
sub list_config_set_to_default {
  my ($self, $user, $passwd, $auth, $int, $list, $var) = @_;
  my (@groups, @out, $ok, $mess, $level);
  $self->_make_list($list);
  
  if (!defined $passwd) {
    $self->inform($list, 'configdefault', $user, $user, "configdefault
		  $list $var", $int, 0, 0, 0, '');
    return (0, "No password supplied.\n");
  }
  @groups = $self->config_get_groups($var);
  if (!@groups) {
    $self->inform($list, 'configdefault', $user, $user, "configdefault
		  $list $var", $int, 0, 0, 0, '');
    return (0, "Unknown variable \"$var\".\n");
  }

  $user = new Mj::Addr($user);
  ($ok, $mess) = $user->valid;
  unless ($ok) {
    $self->inform($list, 'configdefault', $user, $user, "configdefault
		  $list $var", $int, 0, 0, 0, '');
    return (0, "$user is invalid:\n$mess");
  }

  # Validate passwd, check for proper auth level.
  ($ok, $mess, $level) =
    $self->validate_passwd($user, $passwd, $auth,
			   $int, $list, "config_$var");
  if (!($ok>0)) {
    @out = (0, "Password does not authorize $user to alter $var.\n");
  }
  else {
    @out = $self->{'lists'}{$list}->config_set_to_default($var);
    $self->_list_config_unlock($list);
  }
  $self->inform($list, 'configdefault', $user, $user,
		"configdefault $list $var",
		$int, $out[0], !!$passwd+0, 0, '');
  @out;
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

=head2 _site_config_get (private)

Returns a value from the site config.

=cut
sub _site_config_get {
  my $self = shift;
  my $var  = shift;

  $self->{'sitedata'}{'config'}{$var};
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

_list_config_set will look at the type of the set variable and determine if
any internal data structures need to be rebuilt in order to maintain
consistency with the saved state.

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
  my $var  = shift;
  my (@out, $type);

  $list = 'GLOBAL' if $list eq 'ALL';
  $self->_make_list($list);
  @out = $self->{'lists'}{$list}->config_set($var, @_);

  $type = $self->config_get_type($var);
  if ($out[0] == 1) {
    # Now do some special stuff depending on the variable
    if ($type eq 'pw' || $type eq 'passwords') {
      $self->_build_passwd_data($list, 'force');
    }
  }
  @out;
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

They (except for config_get_comment)just jump through the global list''s
method since all lists have the same variables.  This avoids needlessly
vivifying a list''s config.

config_get_comment grabs the file out of the filespace.  This allows for
local overrides and translations (since the search list and LANG are
honored.

=cut
sub config_get_allowed {
  my $self = shift;
  my $var  = shift;
  $self->{'lists'}{'GLOBAL'}->config_get_allowed($var);
}

sub config_get_comment {
  my $self = shift;
  my $var  = shift;
#  $self->{'lists'}{'GLOBAL'}->config_get_comment($var);
  # No substitutions, so no tempfile here
  $self->_list_file_get_string('GLOBAL', "config/$var");
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

sub config_get_whence {
  my $self = shift;
  my $list = shift;
  my $var  = shift;
  $self->_make_list($list);
  $self->{'lists'}{$list}->config_get_whence($var);
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
  my ($i, $ok);

  $self->_make_list($list);

  # Make sure we have a real user before checking passwords
  $user = new Mj::Addr($user);
  return unless $user->isvalid;

  for $i ($self->config_get_groups($var)) {
    $ok = $self->validate_passwd($user, $passwd, $auth, $interface,
				 $list, "config_$i");
    last if $ok > 0;
  }
  unless ($ok>0) {
    return;
  }
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

  $var =~ tr/ \t//d;
  $user = new Mj::Addr($user);
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
      last if $ok > 0;
    }
  }

  @out = $self->{'lists'}{$list}->config_get_vars($var, $ok>0, ($list eq 'GLOBAL'));
  $::log->out(($ok>0)?"validated":"not validated");
  @out;
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
  my (%data, $cset, $desc, $enc, $file, $mess, $nname, $ok, $type);

  $self->_make_list($list);

  # Untaint the file name
  $name =~ /(.*)/; $name = $1;

  # If given an "absolute path", trim it, else stick "public/" onto it
  unless (($nname = $name) =~ s!^/!!) {
    $nname = "public/$name";
  }
  
  ($file, %data) = $self->_list_file_get($list, $nname);
  
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
  $self->_get_mailfile($list, $victim, $name, $file, %data); #$desc, $type, $cset, $enc);

  # and be sneaky and return another file to be read; this keeps the code
  # simpler and lets the owner customize the transmission message
#  ($file, $desc, $type, $cset, $enc) = 
  ($file, %data) = $self->_list_file_get($list, 'file_sent');
  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return 0;
  }
  return 1;
}

use MIME::Entity;
use Mj::MailOut;
sub _get_mailfile {
  my ($self, $list, $vict, $name, $file, %data) = @_;
  my ($ent, $sender);

  $sender = $self->_list_config_get($list, 'sender');

  $ent = build MIME::Entity
    (
     Path     => $file,
     Type     => $data{'c-type'},
     Charset  => $data{'charset'},
     Encoding => $data{'c-t-encoding'},
     Subject  => $data{'description'} || "Requested file $name from $list",
     Top      => 1,
     Filename => undef,
     'Content-Language:' => $data{'language'},
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
    $out = $self->substitute_vars_string($out, $self->{'get_subst'});
  }
  return (1, $out);
}

sub get_done {
  my $self = shift;
  my $log = new Log::In 50;
  return unless $self->{'get_fh'};
  unlink @{$self->{'get_temps'}} if $self->{'get_temps'};
  undef $self->{'get_fh'};
  undef $self->{'get_temps'};
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
  my ($file, $subs);

  $self->_make_list($list);

  $subs =
    {VERSION  => $Majordomo::VERSION,
     WHEREAMI => $self->_global_config_get('whereami'),
     WHOAMI   => $self->_list_config_get($list, 'whoami'),
     MJ       => $self->_global_config_get('whoami'),
     MJOWNER  => $self->_global_config_get('sender'),
     OWNER    => $self->_list_config_get($list, 'sender'),
     SITE     => $self->_global_config_get('site_name'),
     USER     => $requ,
     LIST     => $list,
    };

  ($file) = $self->_list_file_get($list, 'faq', $subs);
  
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
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $list, $mode, $vict,
      $topic) = @_;
  my $log = new Log::In 50, "$user, $topic";
  my (@info, $file, $mess, $ok, $subs, $whoami, $wowner);
  
  ($ok, $mess) =
    $self->global_access_check($passwd, $auth, $interface, $mode, $cmdline,
                             'help', $user, $vict, $topic);

  # No stalls should be allowed...
  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $whoami = $self->_global_config_get('whoami'),
  $wowner = $self->_global_config_get('sender'),

  $subs =
    {VERSION  => $Majordomo::VERSION,
     WHEREAMI => $self->_global_config_get('whereami'),
     WHOAMI   => $whoami,
     MJ       => $whoami,
     MJOWNER  => $wowner,
     OWNER    => $wowner,
     SITE     => $self->_global_config_get('site_name'),
     USER     => $user,
    };

  ($topic) = $topic =~ /(.*)/; # Untaint
  ($file) =  $self->_list_file_get('GLOBAL', "help/$topic", $subs);

  unless ($file) {
    ($file) =  $self->_list_file_get('GLOBAL', "help/unknowntopic", $subs);
  }
  unless ($file) {
    return (0, "No help for that topic.\n");
  }

  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return 0;
  }
  push @{$self->{'get_temps'}}, $file;
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
  my ($file, $subs);

  $self->_make_list($list);

  $subs =
    {VERSION  => $Majordomo::VERSION,
     WHEREAMI => $self->_global_config_get('whereami'),
     WHOAMI   => $self->_list_config_get($list, 'whoami'),
     MJ       => $self->_global_config_get('whoami'),
     MJOWNER  => $self->_global_config_get('sender'),
     OWNER    => $self->_list_config_get($list, 'sender'),
     SITE     => $self->_global_config_get('site_name'),
     USER     => $requ,
     LIST     => $list,
    };

  ($file) = $self->_list_file_get($list, 'info', $subs);
  
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
  my ($file, $subs);

  $self->_make_list($list);

  $subs =
    {VERSION  => $Majordomo::VERSION,
     WHEREAMI => $self->_global_config_get('whereami'),
     WHOAMI   => $self->_list_config_get($list, 'whoami'),
     MJ       => $self->_global_config_get('whoami'),
     MJOWNER  => $self->_global_config_get('sender'),
     OWNER    => $self->_list_config_get($list, 'sender'),
     SITE     => $self->_global_config_get('site_name'),
     USER     => $requ,
     LIST     => $list,
    };

  ($file) = $self->_list_file_get($list, 'intro', $subs);
  
  unless ($file) {
    return (0, "No intro available.\n");
  }
  
  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return 0;
  }
  return 1;
}

=head2 password(..., password)

This changes a user''s password.  If mode is 'gen' or 'rand' (generate or
random) a password is randomly generated.

=cut
sub password {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list,
      $vict, $pass) = @_;
  my ($ok, $mess, $minlength);
  my $log = new Log::In 30, "$vict, $mode";

  # Generate a password if necessary
  if ($mode =~ /gen|rand/) {
    $pass = Mj::Access::_gen_pw();
  }

  ($ok, $mess) =
    $self->global_access_check($passwd, $auth, $interface, $mode, $cmdline,
			       'password', $user, $vict, $pass, '', '',
			       'password_length' => length($pass));
  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_password($list, $user, $vict, $mode, $cmdline, $pass);  
}

use MIME::Entity;
sub _password {
  my ($self, $list, $user, $vict, $mode, $cmdline, $pass) = @_;
  my $log = new Log::In 35, "$vict";
  my (%file, $desc, $ent, $file, $majord, $majord_own, $reg, $sender,
      $site, $subst, $whereami);

  # Make sure user is registered.  XXX This ends up doing two reg_lookops,
  # which should probably be cached
  $reg = $self->_reg_lookup($vict);
  return (0, "$vict is not a registered user.")
    unless $reg;

  # Write out new data.
  $self->_reg_add($vict,
		  'password' => $pass,
		  'update'   => 1,
		 );

  # Mail the password_set message to the victim if requested
  if ($mode !~ /quiet/) {
    $sender = $self->_global_config_get('sender');
    $whereami = $self->_global_config_get('whereami');
    $majord   = $self->_global_config_get('whoami');
    $majord_own = $self->_global_config_get('whoami_owner');
    $site       = $self->_global_config_get('site_name');

    $subst = {
	      MAJORDOMO => $majord,
	      OWNER     => $majord_own,
	      SITE      => $site,
	      LIST      => $list,
	      PASSWORD  => $pass,
	      VICTIM    => $vict->canon,
	     };

    ($file, %file) = $self->_list_file_get('GLOBAL', 'new_password');
    return 1 unless $file;

    # Expand variables
    $desc = $self->substitute_vars_string($file{'description'}, $subst);
    $file = $self->substitute_vars($file, $subst);

    $ent = build MIME::Entity
      (
       Path     => $file,
       Type     => $file{'c-type'},
       Charset  => $file{'charset'},
       Encoding => $file{'c-t-encoding'},
       Subject  => $desc,
       -To      => $vict->canon,
       Top      => 1,
       Filename => undef,
       'Content-Language:' => $file{'language'},
      );

    if ($ent) {
      $self->mail_entity($sender, $ent, $vict);
      $ent->purge;
    }
  }
  1;
}

=head2 put_start(..., file, subject, content_type, content_transfer_encoding)

This starts the file put operation.

=cut
sub put_start {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list, $vict,
      $file, $subj, $type, $cset, $cte, $lang) = @_;
  my ($ok, $mess);
  
  $subj ||= $file;
  my $log = new Log::In 30, "$list, $file, $subj, $type, $cset, $cte, $lang";
  
  $self->_make_list($list);

  # Check the password
  ($ok, $mess) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'put', $user, $vict, $file, $subj,
			     "$type\002$cset\002$cte\002$lang");
  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_put($list, $user, $vict, $mode, $cmdline, $file, $subj,
	      "$type\002$cset\002$cte\002$lang");
}

sub _put {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $file, $subj, $stuff)
    = @_;
  my ($cset, $enc, $lang, $mess, $ok, $type);

  # Extract the encoded type and encoding
  ($type, $cset, $enc, $lang) = split("\002", $stuff);

  my $log = new Log::In 35, "$list, $file, $subj, $type, $cset, $enc, $lang";
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
  $self->{'lists'}{$list}->fs_put_start($file, 0, $subj, $type, $cset, $enc, $lang);
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

=head2 request_response(...)

This is a simple function which mails a list''s request_response file to
the victim.  It does not handle returning the file inline (because the
intent is for it to be called from an email interface without returning any
status.)

=cut
sub request_response {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $list,
      $vict) = @_;
  my $log = new Log::In 50, "$list, $vict";
  my ($mess, $ok, $whereami);
  
  ($ok, $mess) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
                             $list, 'request_response', $user, $vict, '',
                             '', '');
  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_request_response($list, $user, $vict, $mode, $cmdline);
}

use MIME::Entity;
use Mj::MailOut;
sub _request_response {
  my ($self, $list, $requ, $victim, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$list";
  my (%file, $cset, $desc, $enc, $ent, $file, $list_own, $majord,
      $majord_own, $mess, $sender, $site, $subst, $type, $whereami);

  $self->_make_list($list);

  ($file, %file) = $self->_list_file_get($list, 'request_response');
  return unless $file;

  # Build the entity and mail out the file
  $sender = $self->_list_config_get($list, 'sender');
  $whereami = $self->_global_config_get('whereami');
  $majord   = $self->_global_config_get('whoami');
  $majord_own = $self->_global_config_get('sender');
  $site       = $self->_global_config_get('site_name');
  $list_own   = $self->_list_config_get($list, 'sender');

  $subst = {
	    REQUEST   => "$list-request\@$whereami",
	    MAJORDOMO => $majord,
	    OWNER     => $list_own,
	    SITE      => $site,
	    LIST      => $list,
	   };

  # Expand variables
  $desc = $self->substitute_vars_string($file{'description'}, $subst);
  $file = $self->substitute_vars($file, $subst);

  $ent = build MIME::Entity
    (
     Path     => $file,
     Type     => $file{'c-type'},
     Charset  => $file{'charset'},
     Encoding => $file{'c-t-encoding'},
     Subject  => $desc || "Your message to $list-request",
     Top      => 1,
     Filename => undef,
     'Content-Language:' => $file{'language'},
    );

  $self->mail_entity($sender, $ent, $victim);
  1;
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
  

=head2 _list_file_get(list, file, subs, nofail, lang, force)

This forms the basic internal interface to a list''s (virtual) filespace.
All core routines which need to retrieve files should use this function as
it provides all of the i18n functionality for file access.

This handles figuring out the list''s default language, properly expanding
the search list and handling the share_list.

If $subs is defined, it should be a hashref of substitutions to be made;
substitute_vars will be called automatically.

If $nofail is defined, this function will never fail to return a file, even
if the file is not found.  Instead, it will emit a warning and return a
generic "file not found" file.

If $lang is defined, it is used in place of any default_language setting.

Note that if $subs is provided, the returned filename will be a temporary
generated by substitute_vars.  The caller is responsible for cleaning up
this temporary.

=cut
sub _list_file_get {
  my $self  = shift;
  my $list  = shift;
  my $file  = shift;
  my $subs  = shift;
  my $nofail= shift;
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
	  'STOCK:$LANG', 'STOCK:en')
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
    if ($l ne $list && $l ne 'GLOBAL' && $l ne 'STOCK') {
     SHARE:
      for $j ($self->_list_config_get($l, "file_share")) {
	if ($j =~ /^\s*$list\s*$/) {
	  $ok = 1;
	  last SHARE;
	}
      }
      next PATH unless $ok;
    }
    # The list shares with us, so we can get the file.  Handle the special
    # stock list first:
    if ($l eq 'STOCK') {
      @out = $self->_get_stock($f);
    }
    else {
      @out = $self->{'lists'}{$l}->fs_get($f, $force);
    }

    # Now, if we got something
    if (@out) {
      # Substitute if necessary; $out[0] is thefilename
      if ($subs) {
	$out[0] = $self->substitute_vars($out[0], $subs, $list);
      }
      return @out;
    }
  }

  # If we get here, we didn't find anything that matched at all so if so
  # instructed we pull out the file of last resort.
  if ($nofail) {
    @out = $self->_get_stock('en/file_not_found');
    $log->complain("Requested file $file not found");
    return @out;
  }
  return;
}

=head2 _list_file_get_string

This takes the same arguments as _list_file_get, but returns the entire
file in a string instead of the filename.  The other information is
returned just as _list_file_get returns it in a list context, or is ignored
in a scalar context.

=cut
sub _list_file_get_string {
  my $self = shift;
  my (%data, $fh, $file, $line, $out);

  ($file, %data) = $self->_list_file_get(@_);

  $fh = new Mj::File($file);
  
  while (defined($line = $fh->getline)) {
    $out .= $line;
  }

  if (wantarray) {
    return ($out, %data);
  }
  return $out;
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

=head2 _get_stock(file)

This looks through the set of stock files in a final attempt to find a
file.  This only gets called if no overridden copy of the file exists.

The basic idea is to look for an index file in a known place, load it, make
sure the requested file exists, and return its path.

Returns the file name and a hash like that of FileSpace::get containing the
pertinent data, or undef if the file does not exist.

=cut
sub _get_stock {
  my $self = shift;
  my $file = shift;
  my $log = new Log::In 150, "$file, $self->{'sitedir'}";
  my (%out, $data, $lang);

  # Ugly hack, but 'my' variables aren't available in require'd files
  $indexflags = 0;
  $indexflags |= 1 if $self->{'sitedata'}{'config'}{'cgi_bin'};

  # Pull in the index file if necessary
  unless ($self->{'sitedata'}{'files'}) {
    ($self->{'sitedata'}{'files'}, $self->{'sitedata'}{'dirs'})
      = @{do "$self->{'sitedir'}/files/INDEX.pl"};
    $log->abort("Can't load index file $self->{'sitedir'}/files/INDEX.pl!")
      unless $self->{'sitedata'}{'files'};
  }

#  use Data::Dumper; print Dumper $self->{'sitedata'};

  $data = $self->{'sitedata'}{'files'}{$file};
  return unless $data;

  ($lang) = $file =~ m!^([^/]*)!;
  if (ref($data)) {
    %out = (
	    'description' => $data->[0],
	    'c-type'      => 'text/plain',
	    'charset'     => $data->[1],
	    'c-t-encoding'=> $data->[2],
	    'language'    => $lang,
	    'changetime'  => 0,
	   );
    
    if ($data->[3]) {
      # Use alternate filename for noweb stuff
      $file = $data->[3]
    }
  }
  else {
    %out = (
	    'description' => $data,
	    'c-type'      => 'text/plain',
	    'charset'     => 'ISO-8859-1',
	    'c-t-encoding'=> '8bit',
	    'language'    => $lang,
	    'changetime'  => 0,
	   );
  }    
  return ("$self->{'sitedir'}/files/$file", %out);
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

Returns true if it actually made the list, false otherwise.

=cut
sub _make_list {
  my $self = shift;
  my $list = shift;
  my $tmp;

  return 1 if $list eq 'ALL';
  return 1 if $self->{'lists'}{$list};

  $tmp =
    new Mj::List(name      => $list,
		 dir       => $self->{ldir},
		 backend   => $self->{backend},
		 callbacks =>
		 {
		  'mj.list_file_get' => 
		  sub { $self->_list_file_get(@_) },
		  'mj._global_config_get' =>
		  sub {$self->_global_config_get(@_) },
		 },
		);
  return unless $tmp;
  $self->{'lists'}{$list} = $tmp;
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

  $::log->message(200, "info", "Majordomo::legal_list_name", "$name");
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
  my $log    = new Log::In 120, "$name";

  unless ($self->legal_list_name($name)) {
    return undef;
  }

  $self->_fill_lists;
  
  if (($name eq 'ALL' && $all) ||
      (($name eq 'GLOBAL' or $name eq 'DEFAULT') && $global))
    {
      # untaint
      $name =~ /(.*)/;
      $name = $1;
      return $name;
    }

  $name = lc($name);
  if (exists $self->{'lists'}{$name}) {
    # untaint
    $name =~ /(.*)/;
    $name = $1;
    return $name;
  }

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

  my ($ok, $mess, $data, @out) = $self->t_accept($token, $mode);

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
		0, 0, '');

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

=head2 alias(..., list, to, from)

Adds an alias from one address to another.

Note that, as a user, you do aliasing by adding addresses which are
equivaent to the one you joined with.  That means you add pointers _from_
various addresses _to_ your registered address.

'to' is the victim here, because you can harass someone by adding your
address pointing to theres and thus manipulate their data (assuming that
the list does some security based on whether or not the addresses match).

Considerations:

'to' must be registered.

'to' can undergo alias processing; this just lets you add additional
  aliases to your real address from an aliased address.  The real address
  gets in the database.

'from' cannot be registered (else you would never be able to do anything
  with 'from', because any references to it would be converted by aliasing
  to 'to'.
'from' can''t be aliased to anything.

Possibilities:

(before aliasing)

y -> z : Normal case

(x -> y) -> z : Cannot happen, x cannot be registered so cannot be aliased.

x -> (y -> z) : alias y to z.  Lookup aliases on the target address.

(w -> x) -> (y -> z) : cannot happen because w cannot be registered.

(after aliasing)
a -> b : if b -> a, fail (cycle)
         if a -> c, fail (cannot happen after aliasing)
         if b -> c, fail (chains illegal)

The alias database does the latter checks to ensure the consistency of the
alias database.  Some of them make no sense after the lookups and
processing done here, but it''s possible that something external or code
elsewhere will want to add aliases, so the checks still make sense.

=cut
sub alias {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $to, $from) = @_;
  my $log = new Log::In 30, "$to, $from";
  my ($a2, $ok, $mess);

  $from = new Mj::Addr($from);
  ($ok, $mess) = 
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'alias', $user, $to, $from, '','');
  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }
  $self->_alias($list, $user, $to, $mode, $cmdline, $from);
}

sub _alias {
  my ($self, $list, $requ, $to, $mode, $cmdline, $from) = @_;
  my $log = new Log::In 35, "$to, $from";
  my ($data, $err, $fdata, $ok, $tdata);
  
  # the dispatcher doesn't do this one for us.
  $from = new Mj::Addr($from);

  # Check that the target (after aliasing) is registered
  $tdata = $self->{reg}->lookup($to->alias);
  return (0, "$to is not registered here.\n")
    unless $tdata;

  # Check that the transformed but unaliased source is _not_ registered, to
  # prevent cycles.
  $fdata = $self->{reg}->lookup($from->xform);

  return (0, "$from is already registered here.\n")
    if $fdata;

  # Add bookkeeping alias; don't worry if it fails
  $data = {
 	   'striptarget' => $to->strip,
 	   'stripsource' => $from->strip,
 	   'target'     => $to->alias,
 	  };
  $self->{'alias'}->add("", $to->xform, $data);

  # Add alias
  $data = {
	   'target'     => $to->alias,
	   'stripsource' => $from->strip,
	   'striptarget' => $to->strip,
	  };
  
  ($ok, $err) = $self->{'alias'}->add("", $from->xform, $data);
  unless ($ok) {
    # Really, this cannot happen.
    return (0, $err);
  }
  return 1;
}

=head2 archive(..., list, args)

This is a general archive interface.  It checks access, then looks at the
mode to determine what action to take.

Useful modes include:

  search - grep message subjects or bodies; build TOC or digest if few
           enough hits

  Search the bodies:
    archive-search list regexp

  Search subjects:
    archive-search-subject list regexp

  get - retrieve a named message (or messages)

  By named messages:
    archive-get list 199805/12 199805/15

  By a range of names:
    archive-get list 199805/12 - 199805/20

  By date:
    archive-get list 19980501

  By date range:
    archive-get list 19980501 - 19980504

  The slash in a named message is required.  (Note that names don''t always
  have six digits; it depends on archive_split.)  Dates hever have slashes.
  Separators (1998.05.01, 1998-05-01) are allowed in dates and names, by
  applying s/[\.\-]//g to each date.  Spaces around the dashes in a range
  are required.  Multiple ranges aren''t supported in a first cut.  If the
  end of a range is left off, the most recent message or current date is
  used.

  Results are returned in digests unless -immediate is given; in that case,
  the messages will be returned immediately in mbox format.  The type of
  digest is selected by a mode; normal, MIME and HTML are possibilities.
  The digest will be mailed in a separate message.

  Other modes ('index', perhaps) could be used to return just the subjects
  of messages or other data (probably an array of everything stored within
  the archive index).

=cut
sub archive_start {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $vict, @args) = @_;
  my $log = new Log::In 30, "$list, @args";
  my ($out, $ok);

  $self->_make_list($list);
  ($ok, $out) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
                             $list, 'archive', $user, $vict, @args);

  unless ($ok > 0) {
    return ($ok, $out);
  }
  $self->_archive($list, $user, $vict, $mode, $cmdline, @args);
}

# Returns data for all messages matching the arguments.
sub _archive {
  my ($self, $list, $user, $vict, $mode, $cmdline, @args) = @_;
  my $log = new Log::In 30, "$list, @args";
  my (@msgs) = $self->{'lists'}{$list}->archive_expand_range(0, @args);
  return (1, '', @msgs);
}

sub archive_chunk {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $vict, @args) = @_;
  my $log = new Log::In 30, "$list, @args";
  my ($ent, $file, $i, $out, $owner, $fh, $buf, $dtype);
  $dtype = ($mode =~ /get/)? "text" : "index";

  # Build a digest; gives back an entity
  if (scalar(@args) > 0) {
    ($file) = $self->{'lists'}{$list}->digest_build
    (messages      => [@args],
     type          => "$dtype",
     subject       => "$dtype digest from $cmdline",
     tmpdir        => $tmpdir,
     index_line    => $self->_list_config_get($list, 'digest_index_format'),
     index_header  => "Custom-Generated Digest Containing " . scalar(@args) . 
                      " Messages

Contents:
",
     index_footer  => "\n",
    );
    if ($mode =~ /immediate/) {
      $out = '';
      $fh = new IO::File "< $file";
      if (!defined $fh) {
        return (0, "Unable to build $dtype digest of messages.\n");
      }
      # skip over message header
      while ($buf = $fh->getline) {
        last if ($buf =~ /^$/);
      }
      while ($buf = $fh->getline) {
        # skip digest trailer
        last if ($buf =~ /^End of $dtype digest/);
        $out .= $buf;
      }
      $fh->close;
      unlink $file;
      return (1, $out);
    }
    # Mail the entity out to the victim
    $owner = $self->_list_config_get($list, 'sender');
    $self->mail_message($owner, $file, $vict);
    unlink $file;
    return (1, "A digest containing ".scalar(@args)." messages has been mailed.\n");
  }
  return (1, "No messages were found which matched your request.\n");
}



sub archive_done {
}


=head2 auxadd(..., list, name, address)

This adds an address to a lists named auxiliary address list.

=cut
sub auxadd {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $addr, $name) = @_;
  my $log = new Log::In 30, "$list, $name, $addr";
  my(@out, $ok, $mess);

  $self->_make_list($list);
  ($ok, $mess) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'auxadd', $user, $addr, $name, '','');

  unless ($ok > 0) {
    $log->out("noaccess");
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
      $list, $addr, $subl) = @_;
  my(@removed, @out, $error, $ok);
  my $log = new Log::In 30, "$list, $subl, $addr";

  $self->_make_list($list);
  $user = new Mj::Addr($user);
  ($ok, $error) = $user->valid;
  unless ($ok) {
    $log->out("failed, invalidaddr");
    return (0, "Invalid address:\n$error");
  }

  if ($mode =~ /regex/) {
    ($ok, $error, $addr) = Mj::Config::compile_pattern($addr, 0);
    return (0, $error) unless $ok;
  }
  else {
    # Validate the address
    $addr = new Mj::Addr($addr);
    ($ok, $error) = $addr->valid;
    unless ($ok) {
      $log->out("failed, invalidaddr");
      return (0, "Invalid address:\n$error");
    }
  }

  ($ok, $error) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'auxremove', $user, $addr, $subl
			     ,'','');
  unless ($ok>0) {
    $log->out("noaccess");
    return ($ok, $error);
  }

  $self->_auxremove($list, $user, $addr, $mode, $cmdline, $subl);
}

sub _auxremove {
  my($self, $list, $requ, $vict, $mode, $cmd, $subl) = @_;
  my $log = new Log::In 35, "$list, $vict";
  my(@out, @removed, $key, $data);

  $self->_make_list($list);

  @removed = $self->{'lists'}{$list}->aux_remove($subl, $mode, $vict);

  unless (@removed) {
    $log->out("failed, nomatching");
    return (0, "No matching addresses.\n");
  }

  while (($key, $data) = splice(@removed, 0, 2)) {
    push (@out, $data->{'stripaddr'});
  }
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

=head2 changeaddr

This replaces an entry in the master address database.  

=cut
sub changeaddr {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $addr) = @_;
  my $log = new Log::In 30, "$addr, $user";
  my (@out, @removed, $mismatch, $ok, $regexp, $error, $key, $data);

  $regexp   = 0;
  ($ok, $error) =
    $self->global_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     'changeaddr', $user, $addr, '','','',
			    );
  unless ($ok>0) {
    $log->out("noaccess");
    return ($ok, $error);
  }
  
  $self->_changeaddr($list, $user, $addr, $mode, $cmdline);
}

sub _changeaddr {
  my($self, $list, $requ, $vict, $mode, $cmd) = @_;
  my $log = new Log::In 35, "$vict, $requ";
  my(@out, @aliases, @lists, %uniq, $data, $key, $l, $lkey, $ldata);

  ($key, $data) = $self->{'reg'}->remove($mode, $vict->canon);

  unless ($key) {
    $log->out("failed, nomatching");
    return (0, "No address matched $vict->{'canon'}.\n");
  }


  push @out, $data->{'fulladdr'};
  $data->{'fulladdr'} = $requ->full;
  $data->{'stripaddr'} = $requ->strip;

  # Does the address already exist in the registry?  
  # If so, combine the list data.
  if ($ldata = $self->{'reg'}->lookup($requ->canon)) {
    @lists = split ("\002", $ldata->{'lists'});
    push @lists, split ("\002", $data->{'lists'});
    @uniq{@lists} = ();
    $data->{'lists'} = join "\002", sort keys %uniq;
  }
  $self->{'reg'}->add('force', $requ->canon, $data);

  $key = new Mj::Addr($key);

  # Remove from all subscribed lists
  for $l (split("\002", $data->{'lists'})) {
    $self->_make_list($l);
    ($lkey, $ldata) = $self->{'lists'}{$l}->remove('', $key);
    if ($ldata) {
      $ldata->{'fulladdr'} = $requ->full;
      $ldata->{'stripaddr'} = $requ->strip;
      $self->{'lists'}{$l}->{'subs'}->add('', $requ->canon, $ldata);
    }
  }

  @aliases = $self->_alias_reverse_lookup($key);
  for (@aliases) {
    $self->{'alias'}->replace('', $_, 'target', $requ->canon);
    $self->{'alias'}->replace('', $_, 'striptarget', $requ->strip);
  }

  return (1, @out);
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

  unless ($mode =~ /regen/) {
    return (0, '', "Must supply a list name.\n")
      unless $list;

    return (0, '', "Must supply an address for the owner.\n")
      unless $owner;

    $owner = new Mj::Addr($owner);
    ($ok, $mess) = $owner->valid;
    return (0, '', "Owner address is invalid:\n$mess") unless $ok;

    $owner ||= '';
    my $log = new Log::In 50, "$list, $owner";

    return (0, "Illegal list name: $list")
      unless $self->legal_list_name($list);
  }
  
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
  $list ||= '';
  my $log = new Log::In 35, "$mode,$list";
  my(%args, @lists, $bdir, $dir, $dom, $mess, $mta, $mtaopts, $rmess,
     $who);

  $owner = new Mj::Addr($owner);
  $mta   = $self->_site_config_get('mta');
  $dom   = $self->{'domain'};
  $bdir  = $self->_site_config_get('install_dir');
  $bdir .= "/bin";
  $who   = $self->_global_config_get('whoami');
  $who   =~ s/@.*$//; # Just want local part
  $mtaopts = $self->_site_config_get('mta_options');

  %args = ('bindir' => $bdir,
	   'topdir' => $self->{topdir},
	   'domain' => $dom,
	   'whoami' => $who,
	   'options'=> $mtaopts,
	   'queue_mode' => $self->_site_config_get('queue_mode'),
	  );

  unless ($mtaopts->{'maintain_config'}) {
    # We know that we'll give back instructions, so pull out the header.
    $mess = $Mj::MTAConfig::header{$mta} 
      unless $mode =~ /noheader/;
  }

  # Should the MTA configuration be regenerated?
  if ($mode =~ /regen/) {
    unless ($mta && $Mj::MTAConfig::supported{$mta}) {
      return (1, "Unsupported MTA $mta, can't regenerate configuration.\n");
    }

    # Extract lists and owners
    $args{regenerate} = 1;
    $args{'lists'} = [];
    $self->_fill_lists;
    for my $i (keys %{$self->{'lists'}}) {
      push @{$args{'lists'}}, [$i, $self->_list_config_get($i, 'debug')];
    }
    {
      no strict 'refs';
      $mess .= &{"Mj::MTAConfig::$mta"}(%args);
    }
    $mess ||= "MTA configuration for $dom regenerated.\n";
    return (1, $mess);
  }

  # Should a list be created?
  if ($mode !~ /nocreate/) {
    if ($list ne 'GLOBAL') {
      # Untaint $list - we know it's a legal name, so no slashes, so it's safe
      $list =~ /(.*)/; $list = $1;
      $dir  = "$self->{'ldir'}/$list";

      return (0, "List already exists.\n")
	if exists $self->{'lists'}{$list} && $mode !~ /force/;

      $self->{'lists'}{$list} = undef;

      unless (-d $dir) {
	mkdir $dir, 0777 
	  or $log->abort("Couldn't make $dir, $!");
	mkdir "$dir/files", 0777
	  or $log->abort("Couldn't make $dir/files, $!");
	mkdir "$dir/files/public", 0777
	  or $log->abort("Couldn't make $dir/files/public, $!");
      }
    }

    # Now do some basic configuration
    $self->_make_list($list);
    $self->_list_config_set($list, 'owners', "$owner");
    $self->_list_config_unlock($list);
    
    # XXX mail the owner some useful information
  }

  {
    no strict 'refs';
    $mess = &{"Mj::MTAConfig::$mta"}(%args, 'list' => $list);
    $mess ||= "$list was created with owner $owner.\n";
  }

  return (1, $mess);
}

=head2 digest

This implements an interface to various digest functionality:

  incrementing the volume number (and resetting the issue number)
  forcing a digest to be run
  checking to see whether a digest should be run (according to the various
    digest parameters)

=cut
sub digest {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $vict, $digest) = @_;
  $digest ||= 'ALL';
  my $log = new Log::In 30, "$mode, $list, $digest";

  my ($ok, $mess) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'digest', $user, '', $digest, '','');

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }
  $self->_digest($list, $user, $vict, $mode, $cmdline, $digest);
}

sub _digest {
  my ($self, $list, $requ, $vict, $mode, $cmd, $digest) = @_;
  my $log  = new Log::In 35, "$mode, $list, $digest";
  my ($d, $deliveries, $digests, $force, $i, $sender, $subs, $tmpdir,
      $whereami);

  $d = [$digest];
  $d = undef if $digest eq 'ALL';

  $self->_make_list($list);

  # check, force: call do_digests
  if ($mode =~ /(check|force)/) {
    # A simple substitution hash; do_digests will add to it
    $sender   = $self->_list_config_get($list, 'sender');
    $whereami = $self->_global_config_get('whereami');
    $tmpdir   = $self->_global_config_get('tmpdir');
    $subs = {
	     LIST     => $list,
	     VERSION  => $Majordomo::VERSION,
	     WHEREAMI => $whereami,
	     MJ       => $self->_global_config_get('whoami'),
	     MJOWNER  => $self->_global_config_get('sender'),
	     SITE     => $self->_global_config_get('site_name'),
	    };
    $deliveries = {};
    $force = 1 if $mode =~ /force/;
    $self->do_digests('list'       => $list,     'run'        => $d,
		      'force'      => $force,    'deliveries' => $deliveries,
		      'substitute' => $subs,     'sender'     => $sender,
		      'whereami'   => $whereami, 'tmpdir'     => $tmpdir
		      # 'msgnum' => undef, 'arcdata' => undef,
		     );

    # Deliver then clean up
    if (keys %$deliveries) {
      $self->deliver($list, $sender, undef, $deliveries);
      for $i (keys %$deliveries) {
	unlink $deliveries->{$i}{file}
	  if $deliveries->{$i}{file};
      }
    }
    return (1, "Digests forced.\n") if $force;
    return (1, "Digests triggered.\n");
  }

  # incvol: call list->digest_incvol
  if ($mode =~ /incvol/) {
    $self->{'lists'}{$list}->digest_incvol($d);
    return (1, "Volume numbers for $digest incremented.\n");
  }
  return (0, "No digest operation performed.\n");
}


=head2 lists

Perform the lists command.  This gets the visible lists and their
descriptions and some data.

This returns two elements, then a list of triples:

  success flag
  default mode

  the list name
  the list description
  a string containing single-letter flags

The descriptions will not contain newlines.  The interface should be
prepared to handle undefined descriptions.

If mode =~ /enhanced/, the flag string will contain the following:

  S - the user is subscribed

XXX More flags to come: D=digest available, 

Short mode:
  uses short descriptions

Enhanded mode:
  returns extra data  

=cut
sub lists {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode) = @_;
  my $log = new Log::In 30, "$mode";
  my (@lines, @out, $cat, $compact, $count, $desc, $err, $flags, $limit,
      $list, $sublist, $ok);

  # Stuff the registration information to save lots of database lookups
  $self->_reg_lookup($user);

  # Check global access
  ($ok, $err) =
    $self->global_access_check($passwd, $auth, $interface, $mode, $cmdline,
			       "lists", $user);
  unless ($ok > 0) {
    return (0, $err);
  }

  $mode ||= $self->_global_config_get('default_lists_format');
  $limit =  $self->_global_config_get('description_max_lines');

  if ($mode =~ /short/) {
    $compact = 1;
  }

  for $list ($self->get_all_lists($user, $passwd, $auth, $interface)) {
    @lines = $self->_list_config_get($list, "description_long");
    $cat   = $self->_list_config_get($list, 'category');;
    $desc  = '';
    $flags = '';
 
    if ($compact) {
      $desc = $self->_list_config_get($list, "description");
      $desc ||= $lines[0];
    }
    else {
      $count = 1;
      for (@lines) {
	$desc .= "$_\n";
	$count++;
	last if $limit && $count > $limit;
      }
      $desc ||= $self->_list_config_get($list, "description");
    }

    if ($mode =~ /enhanced/) {
      $flags .= 'S' if $self->is_subscriber($user, $list);
    }
    push @out, $list, $cat, $desc, $flags;

    # return information about auxiliary lists
    if ($mode =~ /aux/) {
      $self->{'lists'}{$list}->_fill_aux;
      for $sublist (keys %{$self->{'lists'}{$list}->{'auxlists'}}) {
        $flags = '';
        if ($mode =~ /enhanced/) {
          $flags = 'S'  
            if ($self->{'lists'}{$list}->aux_is_member($sublist, $user));        
        }
        push @out, "$list:$sublist", "", "auxiliary list", $flags;
      }
    }  
    
  }

  return (1, $mode, @out);
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
      $t) = @_;
  my $log = new Log::In 30, "$t";
  my (%file, $data, $desc, $ent, $file, $in, $inf, $inform, $line,
      $list_owner, $mj_addr, $mj_owner, $ok, $repl, $sess, $site, $token);

  if (defined $t) {
    $token = $self->t_recognize($t);
  }
  return (0, "Illegal token $t.\n") unless $token;

  ($ok, $data) = $self->t_reject($token);

  return (0, "No such token $token.\n") unless $ok;

  # For confirmation tokens, a rejection is a serious thing.  We send a
  # message to the victim with important information.
  if ($data->{'type'} eq 'confirm') {
    $list_owner = $self->_list_config_get($data->{'list'}, 'sender');
    $site       = $self->_global_config_get('site_name');
    $mj_addr    = $self->_global_config_get('whoami');
    $mj_owner   = $self->_global_config_get('sender');

    # Extract the session data
    $in = new IO::File("$self->{ldir}/GLOBAL/sessions/$data->{'sessionid'}");

    # If the file no longer exists, what should we do?  We assume it's just
    # a really old token and say so.
    if ($in) {
      while (defined($line = $in->getline)) {
	$sess .= $line;
      }
      $in->close;
    }
    else {
      $sess = "Session info has expired.\n";
    }

    $repl = {'OWNER'      => $list_owner,
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
	    };
    
    ($file, %file) = $self->_list_file_get($data->{'list'}, "token_reject");
    $file = $self->substitute_vars($file, $repl);
    $desc = $self->substitute_vars_string($file{'description'}, $repl);
    
    # Send it off
    $ent = build MIME::Entity
      (
       Path        => $file,
       Type        => $file{'c-type'},
       Charset     => $file{'charset'},
       Encoding    => $file{'c-t-encoding'},
       Filename    => undef,
       -From       => $mj_owner,
       -To         => $data->{'victim'},
       '-Reply-To' => $mj_owner,
       -Subject    => $desc,
       'Content-Language:' => $file{'language'},
      );
    
    if ($ent) { 
      $self->mail_entity($mj_owner, $ent, $data->{'victim'});
      $ent->purge;
    }
    
    # Then we send a message to the list owner and majordomo owner if
    # appropriate
    ($file, %file) = $self->_list_file_get($data->{'list'}, "token_reject_owner");
    $file = $self->substitute_vars($file, $repl);
    $desc = $self->substitute_vars_string($desc, $repl);
    
    $ent = build MIME::Entity
      (
       Path        => $file,
       Type        => $file{'c-type'},
       Charset     => $file{'charset'},
       Encoding    => $file{'c-t-encoding'},
       Filename    => undef,
       -From       => $mj_owner,
       '-Reply-To' => $mj_owner,
       -Subject    => $desc, 
       -To         => $list_owner,
       'Content-Language:' => $file{'language'},
      );
    
    # Should we inform the list owner?
    $inform = $self->_list_config_get($data->{'list'}, 'inform');
    $inf = $inform->{'reject'}{'all'} || $inform->{'reject'}{1} || 0;
    if ($ent) {
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

=head2 register

This adds a user to the registration database without actually adding them
to any lists.

Modes: nopassword   - don''t assign a password
       randpassword - assign a random password

else a password is a required argument.

XXX Add a way to take additional data, like the language.

=cut
sub register {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode, $d, $addr,
      $pw) = @_;
  my ($ok, $error);
  my $log = new Log::In  30, "$addr, $mode";
  
  # Do a list_access_check here for the address; subscribe if it succeeds.
  # The access mechanism will automatically generate failure notices and
  # confirmation tokens if necessary.
  ($ok, $error) =
    $self->global_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     'register', $user, $addr, $pw, '', '');
  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $error);
  }
  $self->_register('', $user, $addr, $mode, $cmdline, $pw);
}

sub _register {
  my $self  = shift;
  my $d     = shift;
  my $requ  = shift;
  my $vict  = shift;
  my $mode  = shift;
  my $cmd   = shift;
  my $pw    = shift;
  my $log   = new Log::In 35, "$vict";
  my ($ok, $data, $exist, $welcome);
  
  if (!defined $pw || !length($pw)) {
    $pw = Mj::Access::_gen_pw();
  }

  # Add to/update registration database
  ($exist, $data) = $self->_reg_add($vict, 'password' => $pw);
  
  # We shouldn't fail, because we trust the reg. database to be correct
  if ($exist) {
    $log->out("failed, existing");
    return (0, "Already registered as $data->{'fulladdr'}.\n");
  }
  
  $welcome = $self->_global_config_get('welcome');
  $welcome = 1 if $mode =~ /welcome/;
  $welcome = 0 if $mode =~ /(nowelcome|quiet)/;
  
  if ($welcome) {
    $ok = $self->welcome('GLOBAL', $vict, 'PASSWORD' => $pw);
    unless ($ok) {
      # Perhaps complain to the list owner?
    }
  }
  return (1);
}


=head2 rekey(...)

This causes the list to rekey itself.  In other words, this recomputes the
keys for all of the rows of all of the databases based on the current
address transformations.  This must be done when the transformations
change, else address matching will fail to work properly.

=cut
sub rekey {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode) = @_;
  my $log = new Log::In 30;

  my ($ok, $error) = 
    $self->global_access_check($passwd, $auth, $interface, $mode, $cmdline,
			       "rekey", $user);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $error);
  }

  $self->_rekey('', $user, $user, $mode, $cmdline);
}

sub _rekey {
  my($self, $d, $requ, $vict, $mode, $cmd) = @_;
  my $log = new Log::In 35;
  my ($list);

  # Do a rekey operation on the registration database
  my $sub =
    sub {
      my $key  = shift;
      my $data = shift;
      my (@out, $addr, $newkey, $changekey);

      # Allocate an Mj::Addr object from stripaddr and transform it.
      $addr = new Mj::Addr($data->{'stripaddr'});

      # Skip this record if it is not a valid address.
      return (0, 0, 0) unless $addr;

      $newkey = $addr->xform;
      $changekey = ($newkey ne $key);
      return ($changekey, 0, $newkey);
    };
  $self->{reg}->mogrify($sub);

  # loop over all lists
  $self->_fill_lists;
  for $list (keys(%{$self->{lists}})) {
    $self->_make_list($list);
    $self->{'lists'}{$list}->rekey;
  }
  return 1;
}

=head2 sessioninfo(..., $sessionid)

Returns the stored text for a given session id.

=cut
use Mj::FileSpace;
sub sessioninfo {
  my ($self, $user, $passwd, $auth, $interface, $request, $mode,
      $spoolfile, $vict, $sessionid) = @_;
  my $log = new Log::In 30, "$sessionid";
  my($file, $in, $line, $sess);

  return (0, "You must supply a session identifier.\n")
    unless $sessionid;

  if ($sessionid !~ /^[0-9a-f]{32}$/) {
    return (0, "Illegal session identifier $sessionid.\n");
  }
  
  if ($request eq 'post' and $mode =~ /full/ and (-f $spoolfile)) {
    $file = $spoolfile;
  }
  else {
    $file = "$self->{ldir}/GLOBAL/sessions/$sessionid";
  }
  $in = new IO::File "$file";
  return (0, "No such session.\n") if (! defined $in);
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
      $list, $addr, $setting) = @_;
  my $log = new Log::In 30, "$list, $addr, $setting";
  my ($ok, $mess);

  return (0, "The set command is not supported for the $list list.\n")
    if ($list eq 'GLOBAL' or $list eq 'DEFAULT'); 

  ($ok, $mess) =
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
                 $list, 'set', $user, $addr, $setting, '', '');
  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }

  $self->_set($list, $user, $addr, $mode, $cmdline, $setting);
}

sub _set {
  my ($self, $list, $user, $addr, $mode, $cmd, $setting) = @_;
  my (@lists, @out, $data, $l, $ok, $res);

  @out = (1);
  if ($list eq 'ALL') {
    $data = $self->{'reg'}->lookup($addr->canon);
    return (0, "Unable to find data for $addr->canon.\n") unless $data;
    @lists = split("\002", $data->{'lists'});
  }
  else {
    @lists = ($list);
  }

  for $l (@lists) {
    $self->_make_list($l);
    ($ok, $res) = $self->{'lists'}{$l}->set($addr, $setting);
    if ($ok) {
      $res->{'list'} = $l;
      $res->{'flagdesc'} = [$self->{'lists'}{$l}->describe_flags($res->{'flags'})];
      $res->{'classdesc'} = $self->{'lists'}{$l}->describe_class(@{$res->{'class'}});
    }
    push @out, ($ok, $res);
  }
  @out;
}

=head2 show(..., mode,, address)

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
 all of the database fields

 One per list joined:
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
      $d, $addr) = @_;
  my ($error, $ok);
  my $log = new Log::In 30, "$addr";

  # We know the address is valid; the dispatcher took care of that for us.

  ($ok, $error) =
    $self->global_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     'show', $user, $addr, '', '', '');
  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $addr->strip, $addr->comment, $error);
  }
  $self->_show('', $user, $addr, $mode, $cmdline);
}

sub _show {
  my ($self, $dummy, $user, $addr, $mode, $cmd) = @_;
  my $log = new Log::In 35;
  my (@out, $aliases, $comm, $data, $i, $mess, $ok);

  # Extract mailbox and comment
  push @out, (1, $addr->strip, $addr->comment);

  # Transform
  push @out, $addr->xform;

  # Alias, inverse aliases
  push @out, $addr->alias;
  $aliases = join("\002",$self->_alias_reverse_lookup($addr));
  push @out, $aliases;

  # Registration data
  $data = $self->{reg}->lookup($addr->canon);
  return @out unless $data;
  push @out, (1, $data->{'fulladdr'}, $data->{'stripaddr'},
	      $data->{'language'}, $data->{'data1'}, $data->{'data2'},
	      $data->{'data3'}, $data->{'data4'}, $data->{'data5'},
	      $data->{'regtime'}, $data->{'changetime'}, $data->{'lists'});

  # Lists
  for $i (split("\002", $data->{'lists'})) {
    $self->_make_list($i);

    # Get membership info with no aliasing (since we already did it all)
    (undef, $data) = $self->{'lists'}{$i}->get_member($addr);

    # It is possible that the registration database is hosed, and the user
    # really isn't on the list.  Just skip it in this case.
    if ($data) {
      # Extract some useful data
      push @out, ($data->{'fulladdr'},
		  $self->{'lists'}{$i}->describe_class($data->{'class'},
						       $data->{'classarg'},
						       $data->{'classarg2'},
						      ),
		  $data->{'subtime'}, $data->{'changetime'},
		 );

      # Deal with flags
      push @out, (join(',',
		       $self->{'lists'}{$i}->describe_flags($data->{'flags'})
		      )
		 );
    }
    else {
      push @out, ('Database error') x 2, 0, 0, 'Database error';
    }
  }
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
  my (@tmp, @out, $data, $token);

  # We have access; open the token database and start pulling data.
  $self->_make_tokendb;
  $self->{'tokendb'}->get_start();
  while (1) {
    ($token, $data) = $self->{'tokendb'}->get(1);
    last unless $token;
    next unless $data->{'list'} eq $list || $list eq 'ALL';

    # Stuff the data
    push @tmp, [$token,
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
	       ];
  }
  @tmp = sort { $a->[12] <=> $b->[12] } @tmp;
  for (@tmp) {
    push @out, @$_;
  }
  $self->{'tokendb'}->get_done;
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
  my ($ok, $error, $i, $matches_list, $mismatch, $tmp, $whereami);
  
  my $log = new Log::In  30, "$list, $addr, $mode";
  
  $self->_make_list($list);

  # Do a list_access_check here for the address; subscribe if it succeeds.
  # The access mechanism will automatically generate failure notices and
  # confirmation tokens if necessary.
  $whereami     = $self->_global_config_get('whereami');
  $tmp = new Mj::Addr("$list\@$whereami");
  $matches_list = $addr eq $tmp;
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
  my ($ok, $classarg, $cstr, $data, $exist, $rdata, $welcome);

  $self->_make_list($list);

  # Gross.  We've overloaded the mode string to specify subscriber
  # flags as well, and that mechanism is reasonably nasty as is.  But
  # we have to somehow remove modes that we know might get to us but
  # that aren't legal subscriber flags, so that make_setting() doesn't
  # yell at us.  XXX Make this a variable somewhere.
  ($cstr = $mode) =~ s/(quiet|(no)?(welcome|inform|log))[-,]?//g;
  
  ($ok, $flags, $class, $classarg) =
    $self->{'lists'}{$list}->make_setting($cstr, '');
  
  unless ($ok) {
    return (0, $class);
  }

  # Add to list
  ($ok, $data) =
    $self->{'lists'}{$list}->add($mode, $vict, $class, $classarg, $flags);
  
  unless ($ok) {
    $log->out("failed, existing");
    return (0, "Already subscribed as $data->{'fulladdr'}.\n");
  }

  # dd to/update registration database
  ($exist, $rdata) =
    $self->_reg_add($vict, 'password' => Mj::Access::_gen_pw(), 'list' =>
		    $list);

  $welcome = $self->_list_config_get($list, "welcome");
  $welcome = 1 if $mode =~ /welcome/;
  $welcome = 0 if $mode =~ /(nowelcome|quiet)/;

  if ($welcome) {
    $ok = $self->welcome($list, $vict, 'PASSWORD' => $rdata->{'password'});
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

  if ($data->{'request'} eq 'post') {
    # spool file
    $dummy = $data->{'arg1'};
  }
  # Pull out the session data
  if ($mode !~ /nosession/ && $data->{'sessionid'}) {
    ($ok, $error, $sess) =
      $self->sessioninfo($user, $passwd, $auth, $interface, $data->{'request'}, 
                         $mode, $dummy, $vict, $data->{'sessionid'});
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
use Mj::Lock;
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

      # GLOBAL and DEFAULT never have duplicate databases or members
      next if ($list eq 'GLOBAL' or $list eq 'DEFAULT');
      $self->_make_list($list);

      # Expire checksum and message-id databases
      $self->{'lists'}{$list}->expire_dup;

      # Expire vacation settings
      $self->{'lists'}{$list}->expire_vacation;
    }
  }

  # Mode: hourly
  if ($mode =~ /^h/) {
    # Loop over lists
    $self->_fill_lists;
    for $list (keys %{$self->{'lists'}}) {
      # Nothing to do to GLOBAL
      next if ($list eq 'GLOBAL' or $list eq 'DEFAULT');
      $self->_make_list($list);

      # Call digest-check; this will do whatever is necessary to tickle the
      # digests.
      $self->_digest($list, $user, $user, 'check', '', 'ALL');
    }
  }      

  1;
}


=head2 unalias(..., source)

Removes an alias pointing from one address.

This just involves looking up the stripped, transformed address in the
database, making sure that it aliases to the the user (for access checking)
and deleting it from the alias database.

=cut
sub unalias {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $source) = @_;
  my $log = new Log::In 27, "$source";
  my ($ok, $mess, $mismatch);

  $mismatch = !($user->alias eq $source->alias);
  ($ok, $mess) = 
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, 'unalias', $user, $source, '', '','',
			     'mismatch' => $mismatch);
  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }

  $self->_unalias($list, $user, $source, $mode, $cmdline);
}

sub _unalias {
  my ($self, $list, $requ, $source, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$requ, $source";
  my ($key, $data);
  
  ($key, $data) = $self->{'alias'}->remove('', $source->xform);
  return !!$key;
}

=head2 unregister

This removes a user from the master address database.  It also deletes the
registration entry, in effect wiping the user from all databases.

=cut
sub unregister {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $addr) = @_;
  my $log = new Log::In 30, "$addr";
  my (@out, @removed, $mismatch, $ok, $regexp, $error, $key, $data);

  $user = new Mj::Addr($user);

  unless ($mode =~ /regex/) {
    # Validate the address
    $addr = new Mj::Addr($addr);
    ($ok, $error) = $addr->valid;
    unless ($ok) {
      $log->out("failed, invalidaddr");
      return (0, "Invalid address:\n$error");
    }
  }

  if ($mode =~ /regex/) {
    $mismatch = 0;
    $regexp   = 1;
    # Untaint the regexp
    $addr =~ /(.*)/; $addr = $1;
  }
  else {
    $mismatch = !($user eq $addr);
    $regexp   = 0;
  }
  ($ok, $error) =
    $self->global_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     'unregister', $user, $addr, '','','',
			     'mismatch' => $mismatch,
			     'regexp'   => $regexp,
			    );
  unless ($ok>0) {
    $log->out("noaccess");
    return ($ok, $error);
  }
  
  $self->_unregister($list, $user, $addr, $mode, $cmdline);
}

sub _unregister {
  my($self, $list, $requ, $vict, $mode, $cmd) = @_;
  my $log = new Log::In 35, "$vict";
  my(@out, @removed, @aliases, $data, $key, $l);

  if ($mode =~ /regex/) {
    (@removed) = $self->{'reg'}->remove($mode, $vict);
  }
  else {
    (@removed) = $self->{'reg'}->remove($mode, $vict->canon);
  }

  unless (@removed) {
    $log->out("failed, nomatching");
    return (0, "No matching addresses.\n");
  }

  while (($key, $data) = splice(@removed, 0, 2)) {
    $key = new Mj::Addr($key);

    # Remove from all subscribed lists
    for $l (split("\002", $data->{'lists'})) {
      $self->_make_list($l);
      $self->{'lists'}{$l}->remove('', $key);
    }
    @aliases = $self->_alias_reverse_lookup($key);
    for (@aliases) {
      $self->{'alias'}->remove('', $_);
    }
    push (@out, $data->{'fulladdr'});
  }


  return (1, @out);
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
  my (@out, @removed, $mismatch, $ok, $regexp, $error);

  $self->_make_list($list);
  $user = new Mj::Addr($user);
  ($ok, $error) = $user->valid;
  unless ($ok) {
    $log->out("failed, invalidaddr");
    return (0, "Invalid address:\n$error");
  }

  if ($mode =~ /regex/) {
    $mismatch = 0;
    $regexp   = 1;
    # Parse the regexp
    ($ok, $error, $addr) = Mj::Config::compile_pattern($addr, 0);
    return (0, $error) unless $ok;
  }
  else {
    # Validate the address
    $addr = new Mj::Addr($addr);
    ($ok, $error) = $addr->valid;
    unless ($ok) {
      $log->out("failed, invalidaddr");
      return (0, "Invalid address:\n$error");
    }
    $mismatch = !($user eq $addr);
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

    # Convert to an Addr and remove the list from that addr's registration
    # entry.
    $key = new Mj::Addr($key);
    $self->_reg_remove($key, $list);
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
use Mj::Config;
sub which {
  my ($self, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $string) = @_;
  my $log = new Log::In 30, "$string";
  my (@matches, $data, $err, $hits, $match, $max_hits, $max_list_hits,
      $mess, $ok, $total_hits);

  # compile the pattern
  if ($mode =~ /regex/) {
    ($ok, $err, $string) = Mj::Config::compile_pattern($string, 0);
    return (0, $err) unless $ok;
  }
  else {
    ($ok, $err, $string) = Mj::Config::compile_pattern("\"$string\"",0);
  }

  # $max_hits will equal 1 for unprivileged people if they are allowed
  # to use the which command.  Thus, the string length check is unneeded.

  # Check search string length; make sure we're not being trolled
  # return (0, "Search string too short.\n")
    # if length($string) < 3 || ($mode =~ /regex/ && length($string) < 5);

  # Check global access, to get max hit limit
  ($max_hits, $err) =
    $self->global_access_check($pass, $auth, $int, $mode, $cmd,
			       "which", $user);

  # Bomb if we're not allowed any hits
  return (0, $err)
    unless $max_hits > 0;

  $total_hits = 0;

  # Untaint
  $string =~ /(.*)/; $string = $1;

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
      ($match, $data) = $self->{'lists'}{$list}->search($string, 'regexp');
      last unless defined $match;
      # if ($total_hits > $max_hits) {
        # push @matches, (undef, "Total match limit exceeded.\n");
        # last LIST;
      # }
      if ($hits > $max_list_hits) {
        push @matches, (undef, "-- Match limit exceeded.\n");
        last ADDR;
      }
      else {
        push @matches, ($list, $match);
      }
      $hits++;
      $total_hits++;
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
use Mj::Config;
sub who_start {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $vict, $regexp) = @_;
  my $log = new Log::In 30, "$list";
  my ($ok, $error);

  $self->_make_list($list);
  if ($regexp) {
    ($ok, $error, $regexp) = Mj::Config::compile_pattern($regexp, 0);
    return (0, $error) unless $ok;
  }

  ($ok, $error) = 
    $self->list_access_check($passwd, $auth, $interface, $mode, $cmdline,
			     $list, "who", $user, $user, $regexp);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $error);
  }

  $self->{'unhide_who'} = ($ok > 1 ? 1 : 0);
  $self->_who($list, $user, '', $mode, $cmdline, $regexp);
}

sub _who {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $regexp) = @_;
  my $log = new Log::In 35, "$list";
  my ($fh, $listing);
  my ($tmpl) = '';
  $listing = [];
 
  if ($list eq 'GLOBAL' or $list eq 'DEFAULT') {
    $self->{'reg'}->get_start;
    if ($mode =~ /enhanced/) {
      ($tmpl) = $self->_list_file_get('GLOBAL', 'who_registry');
    }
  }
  else {
    $self->_make_list($list);
    $self->{'lists'}{$list}->get_start;
    if ($mode =~ /enhanced/) {
      ($tmpl) = $self->_list_file_get('GLOBAL', 'who_subscriber');
    }
  }
  if ($tmpl) {
    $fh = new IO::File "< $tmpl";
    return (0, "Unable to open template file.") unless $fh;
    while ($_ = $fh->getline) {
      push @{$listing}, $_;
    }
    $fh->close;
  }

  (1, '', $regexp, $listing);
}

use Mj::Addr;
use Safe;
sub who_chunk {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $d1, $regexp, $chunksize) = @_;
  my $log = new Log::In 100, "$list, $regexp, $chunksize";
  my (@chunk, @out, $i, $j, $addr, $strip);

#  $regexp = "/$regexp/i" if $regexp;
  # who for DEFAULT returns nothing
  if ($list eq 'DEFAULT') {
    return 0;
  }
  # who for GLOBAL will search the registry
  if ($list eq 'GLOBAL') {
    my @tmp;
    @tmp = $self->{'reg'}->get($chunksize);
    while ((undef, $i) = splice(@tmp, 0, 2)) {
      push @chunk, $i;
    }
  }
  else {
    @chunk = $self->{'lists'}{$list}->get_chunk($chunksize);
  }

  unless (@chunk) {
    $log->out("finished");
    return 0;
  }

  for $i (@chunk) {
    next if $regexp && !_re_match($regexp, $i->{'fulladdr'});
    # If we're to show it all...
    if ($self->{'unhide_who'}) {
      $i->{'fullflags'} =
	join(',',$self->{'lists'}{$list}->describe_flags($i->{'flags'}));
      $i->{'fullclass'} =
	$self->{'lists'}{$list}->describe_class($i->{'class'},
						$i->{'classarg'},
						$i->{'classarg2'},
						1,
					       );
      push @out, $i;
      next;
    }

    # Else we hide if necessary
    if ($i->{'flags'} =~ /h/) {
      $addr = new Mj::Addr($i->{'fulladdr'});
      if ($addr->comment) {
        $i->{'fulladdr'} = $addr->comment;
      }
      else {
        $strip = $addr->strip;
        $strip =~ s/\@.*//;
        $i->{'fulladdr'} = $strip;
      }
    }
    elsif ($i->{'flags'} =~ /H/) {
      next;
    }
    # blot out everything except for fulladdr for ordinary users.
    for $j (keys %$i) {
      $i->{$j} = '' unless ($j eq 'fulladdr');
    }
    push @out, $i;
  }

  return (1, @out);
}

sub who_done {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list) = @_;
  my $log = new Log::In 30, "$list";

  if ($list eq 'GLOBAL' or $list eq 'DEFAULT') {
    $self->{'reg'}->get_done;
  }
  else {
    $self->{'lists'}{$list}->get_done;
  }
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

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the Majordomo2 LICENSE file for more
detailed information.

=cut

#
### Local Variables: ***
### cperl-indent-level:2 ***
### cperl-label-offset:-1 ***
### End: ***


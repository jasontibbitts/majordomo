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
 @lists = $mj->lists($user, $passwd, "lists".$mode?"=mode":"", $mode);

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
$VERSION = "0.1200009110";
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
use Mj::CommandProps qw(:function :command);
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
  $self->{'defaultdata'} = '';

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
  $log->abort("Can't create GLOBAL list: $!")
    unless $self->_make_list('GLOBAL');
  $log->abort("Can't create DEFAULT list: $!")
    unless $self->_make_list('DEFAULT');
  $self->{backend} = $self->_site_config_get('database_backend');
  $self->{alias} = new Mj::AliasList(backend => $self->{backend},
                                      domain => $domain,
                                     listdir => $self->{ldir},
                                        list => "GLOBAL",
                                        file => "_aliases");
  $self->{reg}   = new Mj::RegList(backend => $self->{backend},
                                    domain => $domain,
                                   listdir => $self->{ldir},
                                      list => "GLOBAL",
                                      file => "_register");
  # XXX Allow addresses to be drawn from the registry for delivery purposes.
  $self->{'lists'}{'GLOBAL'}->{'subs'} = $self->{'reg'};

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
    $safe->permit_only(qw(const leaveeval not null pushmark return rv2sv stub));
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
  my ($err, $id, $ok, $path, $req);

  $user = new Mj::Addr($user);
  ($ok, $err) = $user->valid;

  return (undef, "Invalid address: $user\n$err") unless $ok;

  $self->{sessionuser} = $user;
  $self->{interface} = $int;

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
  $req = {  
          'command' => 'access',
          'delay'   => 0,
          'list'    => 'GLOBAL',
          'user'    => $user,
         };
          
  ($ok, $err) = $self->global_access_check($req);

  # Access check succeeded; now try the block_headers variable if applicable.
  if ($ok > 0 and ($int eq 'email' or $int eq 'request')) {
    ($ok, $err) = $self->check_headers($sess);
  }
  # If the access check failed we tell the client to sod off.  Clearing the
  # sessionid prevents further actions.
  unless ($ok > 0) {
    $self->inform('GLOBAL', 'connect', $user, $user, 'connect',
                  $int, $ok, '', 0, $err);
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
  my ($self, $request, $extra) = @_;
  my (@res, $base_fun, $comment, $continued, $data, $func, 
      $mess, $ok, $out, $over);
  my ($level) = 29;
  $level = 500 if ($request->{'command'} =~ /_chunk$/);

  ($base_fun = $request->{'command'}) =~ s/_(start|chunk|done)$//;
  $continued = 1 if $request->{'command'} =~ /_(chunk|done)/;

  $request->{'delay'}    ||= 0;
  $request->{'list'}     ||= 'GLOBAL';
  $request->{'mode'}     ||= '';
  $request->{'mode'}       = lc $request->{'mode'};
  $request->{'mode'}       =~ /([a-z-]+)/; 
  $request->{'mode'}       =~ $1;
  $request->{'password'} ||= '';
  $request->{'user'}     ||= 'unknown@anonymous';
  $request->{'victim'}   ||= '';

  my $log  = new Log::In $level, "$request->{'command'}, $request->{'user'}";

  $log->abort('Not yet connected!') unless $self->{'sessionid'};

  unless (function_legal($request->{'command'})) {
    return [0, "Illegal command \"$request->{'command'}\".\n"];
  }

  unless ($ok = $self->valid_list($request->{'list'}, 1, 1)) {
    return [0, "Illegal list: \"$request->{'list'}\".\n"];
  }
  # Untaint
  $request->{'list'} = $ok;

  # XXX Move this to Mj::Access.
  if ($request->{'password'} =~ /^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$/) {
    # The password given appears to be a latchkey, a temporary password.
    # If the latchkey exists and has not expired, convert the latchkey
    # to a permanent password for the call to dispatch().
    $self->_make_latchkeydb;
    if (defined $self->{'latchkeydb'}) {
      $data = $self->{'latchkeydb'}->lookup($request->{'password'});
      if (defined $data) {
        $request->{'password'} = $data->{'arg1'}
          if (time <= $data->{'expire'});
      }
    }
  }

  # Turn some strings into addresses and check their validity; never with a
  # continued function (they never need it) and only if the function needs
  # validated addresses.
  if (function_prop($request->{'command'}, 'noaddr')) {
    $request->{'victims'} ||= ['unknown@anonymous'];
  }
  elsif (!$continued) {
    $request->{'user'} = new Mj::Addr($request->{'user'});
    ($ok, $mess) = $request->{'user'}->valid;
    return [0, "$request->{'user'} is an invalid address:\n$mess"]
      unless $ok;

    # Each of the victims must be verified. 
    if (exists ($request->{'victims'}) and ($request->{'mode'} !~ /regex/)) {
      my ($addr, @tmp);
      while (@{$request->{'victims'}}) {
        $addr = shift @{$request->{'victims'}};
        next unless $addr;
        $addr =~ s/^\s+//;
        $addr =~ s/\s+$//;
        $addr = new Mj::Addr($addr);
        ($ok, $mess) = $addr->valid;
        return [0, "$addr is an invalid address:\n$mess"]
          unless $ok;
        push (@tmp, $addr); 
      }
      $request->{'victims'} = \@tmp;
    }
    unless (exists $request->{'victims'} and @{$request->{'victims'}}) {
      $request->{'victims'} = [$request->{'user'}];
    }
  }

  # Check for suppression of logging and owner information
  if ($request->{'mode'} =~ /nolog/) {
    # This is serious; user must use the master global password.
    $ok = $self->validate_passwd($request->{'user'}, $request->{'password'}, 
				                 'GLOBAL', 'ALL', 1);
    return [0, "The given password is not sufficient to disable logging."]
      unless $ok > 0;
    $over = 2;
  }
  elsif ($request->{'mode'} =~ /noinform/) {
    $ok = $self->validate_passwd($request->{'user'}, $request->{'password'}, 
                                 $request->{'list'}, 'config_inform');
    return [0, "The given password is not sufficient to disable owner information."]
      unless $ok > 0;
    $over = 1;
  }
  else {
    $over = 0;
  }

  for (@{$request->{'victims'}}) { 
    $request->{'victim'} = $_;
    gen_cmdline($request) unless ($request->{'command'} =~ /_chunk|_done/);
    if (function_prop($request->{'command'}, 'top')) {
      $func = $request->{'command'};
      @res = $self->$func($request, $extra);
      push @$out, @res;
    }
    else {
      # Last resort; we found _nothing_ to call
     return [0, "No action implemented for $request->{'command'}"];
    }
 
    $comment = '';
    # owner_done returns the address of the originator,
    # and bouncing addresses if any were identified.
    if ($base_fun eq 'owner' and $res[1]) {
      if ($request->{'command'} eq 'owner_done' and @{$res[1]}) {
        $base_fun = "bounce";
        $request->{'cmdline'} = "(bounce from " .
                                join(" ", @{$res[1]}) . ")";
      } 
    }
    else {
      # Obtain the comment for failed and stalled actions.
      $comment = $res[1] if (defined $res[1] and $res[0] < 1);
    }
      
    # Inform on post_done and post and owner_done, 
    # but not on post_start or owner_start.
    $over = 2 if ($request->{'command'} eq 'post_start');
    $over = 2 if ($request->{'command'} eq 'owner_start');

    # Inform unless overridden or continuing an iterator
    unless ($over == 2 || 
            $request->{'command'} =~ /(_chunk|(?<!post|wner)_done)$/) {
      # XXX How to handle an array of results?
      $self->inform($request->{'list'}, $base_fun, $request->{'user'}, 
                    $request->{'victim'}, $request->{'cmdline'}, 
                    $self->{'interface'}, $res[0], 
                    !!$request->{'password'}+0, $over, $comment);
    }
  }
  $out;
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
  my ($self, $user, $passwd, $regexp) = @_;
  my $log = new Log::In 100;
  my (@lists, $always, $list, $req);

  $user = new Mj::Addr($user);
  $self->_fill_lists;
  $always = $self->_global_config_get('advertise_subscribed');

  # Avoid having to reload the DEFAULT configuration
  # files for every list.
  $list = '';
  $self->{'defaultdata'} = $self->{'lists'}{'DEFAULT'}->{'config'}->{'dfldata'};

  for $list (keys %{$self->{'lists'}}) {
    next if ($list eq 'GLOBAL' or $list eq 'DEFAULT');
    if ($regexp) {
      next unless _re_match($regexp, $list);
    }

    # If membership always overrides advertising:
    if ($always && $self->is_subscriber($user, $list)) {
      push @lists, $list;
      next;
    }

    # Else do the full check
    next unless $self->_make_list($list);
    $req = {
            'cmdline'  => 'lists',
            'command'  => 'advertise',
            'delay'    => 0,
            'list'     => $list,
            'mode'     => '',
            'password' => $passwd,
            'user'     => $user
           };

    if ($self->list_access_check($req)) {
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

=head2 gen_cmdline

This routine derives the command line from a request hash.
The command line is indicated in the logs and in
acknowledgement messages such as confirmation requests.

=cut
sub gen_cmdline {
  my ($request) = shift;
  my (@tmp, $arguments, $base, $cmdline, $hereargs, $variable);

  return unless (ref $request eq 'HASH');
  if ($request->{'command'} =~ /owner/) {
    $request->{'cmdline'} = "(message to $request->{'list'}-owner)";
    return 1;
  }
  if ($request->{'command'} =~ /post/) {
    if (length $request->{'auxlist'}) {
      $request->{'cmdline'} = "(post to $request->{'list'}:$request->{'auxlist'})";
    }
    else {
      $request->{'cmdline'} = "(post to $request->{'list'})";
    }
    return 1;
  }
  # The command line is  COMMAND[-MODE] [LIST] [ARGS]
  $base = "$request->{'command'}";
  $base =~ s/_(start|chunk|done)//;
  $cmdline = $base;
  if ($request->{'mode'}) {
    $cmdline .= "-$request->{'mode'}";
  }
  # Add LIST if the command requires one
  if (command_prop($base, "list")) {
    $cmdline .= " $request->{'list'}";
  }

  $hereargs  = function_prop($base, 'hereargs');
  $arguments = function_prop($base, 'arguments');

  if (defined $arguments) {
    for $variable (sort keys %$arguments) {
      next if ($variable eq 'split');
      next if ($variable eq 'newpasswd');
      next if (exists $arguments->{$variable}->{'include'}
               and $request->{'mode'} !~ /$arguments->{$variable}->{'include'}/);
      next if (exists $arguments->{$variable}->{'exclude'}
               and $request->{'mode'} =~ /$arguments->{$variable}->{'exclude'}/);
      if ($variable eq 'victims' and defined $request->{'victim'}) {
        $cmdline .= " $request->{'victim'}";
        next;
      }
      last if (defined $hereargs and ($variable eq $hereargs));
      if ($arguments->{$variable} ne 'ARRAY') {
        $cmdline .= " $request->{$variable}" 
          if length $request->{$variable};
      }
    }
  }
  $request->{'cmdline'} = $cmdline;
  1;
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

=head2 standard_subs(list)

This routine returns a hash of a standard set of variable
substitutions, used in various places in the Mj modules.

=cut
sub standard_subs {
  my $self = shift;
  my $olist = shift;
  my ($list, $sublist, $whereami, $whoami);
  ($list, $sublist) = $olist =~ /([a-zA-Z0-9\.\-\_]+):?([a-zA-Z0-9\.\-\_]*)/;

  return unless $self->valid_list($list, 1, 1);
  $whereami  = $self->_global_config_get('whereami');

  if (length $sublist) {
    $whoami = "$list-$sublist\@$whereami";
  }
  else {
    $whoami = $self->_list_config_get($list, 'whoami');
  }
  my %subs = (
    'LIST'        => $olist,
    'MJ'          => $self->_global_config_get('whoami'),
    'MAJORDOMO'   => $self->_global_config_get('whoami'),
    'MJOWNER'     => $self->_global_config_get('whoami_owner'),
    'OWNER'       => $self->_list_config_get($list, 'whoami_owner'),
    'REQUEST'     => ($list eq 'GLOBAL' or $list eq 'DEFAULT') ?
                     $whoami :
                     "$list-request\@$whereami",
    'SUBLIST'     => $sublist,
    'SITE'        => $self->_global_config_get('site_name'),
    'VERSION'     => $Majordomo::VERSION,
    'WHEREAMI'    => $whereami,
    'WHOAMI'      => $whoami,
  );
  %subs;
}

=head2 substitute_vars(file, subhashref, filehandle, list, depth)

This routine iterates over a file and expands embedded "variables".  It
takes a file and a hash, the keys of which are the tags to be expanded.

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
    if ($i =~ /\$INCLUDE-(.*)$/) {
      # Do a _list_file_get.  If we get a file, open it and call
      # substitute_vars on it, printing to the already opened handle.  If
      # we don't get a file, print some amusing text.
      ($inc) =  $self->_list_file_get($list, $1);

      if ($inc) {
	if ($depth > 3) {
	  $out->print("Recursive inclusion depth exceeded\n ($depth levels: may be a loop, now reading $1)\n");
	}
	else {
	  # Got the file; substitute in it, perhaps recursively
	  $self->substitute_vars($inc, $subs, $list, $out, $depth+1);
	}
      }
      else {
	warn "Include file $1 not found.";
	$out->print("Include file $1 not found.\n");
      }
      next;
    }
    $i = $self->substitute_vars_string($i, $subs);
    $out->print($i);
  }

  # always close the INPUT file
  $in->close;
  # ONLY close the OUTPUT file at zero depth - else recursion gives 'print to closed file handle'
  $out->close if(!$depth); # it will automatically close itself when it goes out of scope
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
  my $self    = shift;
  my $addr    = shift;
  my $incself = shift;
  my (@data, @out, $data, $key);
  
  $self->{'alias'}->get_start;
  
  # Grab _every_ matching entry
  @data = $self->{'alias'}->get_matching(0, 'target', $addr->canon);
  $self->{'alias'}->get_done;
  
  while (($key, $data) = splice(@data, 0, 2)) {
    unless ($key eq $data->{'target'} and ! $incself) {
      push @out, $key;
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
  my ($self, $user, $passwd, $var, $raw) = @_;
  $self->list_config_get($user, $passwd, 'GLOBAL', $var, $raw);
}

=head2 list_config_get(user, passwd, auth, interface, list, var)

Retrieves the value of a list''s config variable.

Note that anyone can get a visible variable; these are available to the
interfaces for the asking.  They should not be security-sensitive in any
way.

For other variables, the standard security rules apply.

=cut
sub list_config_get {
  my ($self, $user, $passwd, $list, $var, $raw) = @_;
  my $log = new Log::In 170, "$list, $var";
  my (@out, $i, $ok);

  return unless $self->_make_list($list);

  # Anyone can see it if it is visible.
  if ($self->config_get_visible($var)) {
    return $self->_list_config_get($list, $var, $raw);
  }

  # Make sure we have a real user before checking passwords
  $user = new Mj::Addr($user);
  return unless $user && $user->isvalid;

  for $i ($self->config_get_groups($var)) {
    $ok = $self->validate_passwd($user, $passwd, $list, "config_$i");
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
  my ($self, $user, $passwd, $list, $var) =
    splice(@_, 0, 5);
  my $log = new Log::In 150, "$list, $var";
  my (@groups, $i, $mess, $ok, $global_only);

  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

  if (!defined $passwd) {
    return (0, "No passwd was supplied.\n");
  }

  $user = new Mj::Addr($user);
  ($ok, $mess) = $user->valid;
  if (!$ok) {
    return (0, "$user is invalid\n$mess");
  }


  @groups = $self->config_get_groups($var);
  if (!@groups) {
    return (0, "Unknown variable \"$var\".\n");
  }
  $global_only = 1;
  if ($self->config_get_mutable($var)) {
    $global_only = 0;
  }
  
  # Validate passwd
  for $i (@groups) {
    $ok = $self->validate_passwd($user, $passwd, 
				 $list, "config_\U$i", $global_only);
    last if $ok > 0;
  }
  unless ($ok > 0) {
    $ok = $self->validate_passwd($user, $passwd, 
				 $list, "config_$var", $global_only);
  }
  unless ($ok > 0) {
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
    return (0, "Error parsing $var:\n$mess");
  }
  elsif ($mess) {
    return (1, "Warnings parsing $var:\n$mess");
  }
  else {
    return 1;
  }
}

=head2 list_config_set_to_default

Removes any definition of a config variable, causing it to track the
default.

=cut
sub list_config_set_to_default {
  my ($self, $user, $passwd, $list, $var) = @_;
  my (@groups, @out, $ok, $mess, $level);
  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);
  
  if (!defined $passwd) {
    return (0, "No password was supplied.\n");
  }
  @groups = $self->config_get_groups($var);
  if (!@groups) {
    return (0, "Unknown variable \"$var\".\n");
  }

  $user = new Mj::Addr($user);
  ($ok, $mess) = $user->valid;
  unless ($ok) {
    return (0, "$user is invalid:\n$mess");
  }

  # Validate passwd, check for proper auth level.
  ($ok, $mess, $level) =
    $self->validate_passwd($user, $passwd, $list, "config_$var");
  if (!($ok>0)) {
    @out = (0, "Password does not authorize $user to alter $var.\n");
  }
  else {
    @out = $self->{'lists'}{$list}->config_set_to_default($var);
    $self->_list_config_unlock($list);
  }
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

  return unless $self->_make_list('GLOBAL');
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
  return unless $self->_make_list($list);
  $self->{'lists'}{$list}->config_get(@_);
}

sub _list_config_set {
  my $self = shift;
  my $list = shift;
  my $var  = shift;
  my (@out, $type);

  $list = 'GLOBAL' if $list eq 'ALL';
  return unless $self->_make_list($list);
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
  return unless $self->_make_list($list);
  $self->{'lists'}{$list}->config_lock(@_);
}

sub _list_config_unlock {
  my $self = shift;
  my $list = shift;
  
  $list = 'GLOBAL' if $list eq 'ALL';
  return unless $self->_make_list($list);
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
  return unless $self->_make_list($list);
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
  return unless $self->_make_list($list);
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
  my ($self, $user, $passwd, $list, $var) = @_;
  my ($i, $ok);

  return unless $self->_make_list($list);

  # Make sure we have a real user before checking passwords
  $user = new Mj::Addr($user);
  return unless $user->isvalid;

  for $i ($self->config_get_groups($var)) {
    $ok = $self->validate_passwd($user, $passwd, $list, "config_$i");
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
  my ($self, $user, $passwd, $list, $var) = @_;
  my (@groups, @out, $i, $error, $lvar, $ok);

  $::log->in(100, "$list, $var");

  $var =~ tr/ \t//d;
  $user = new Mj::Addr($user);
  $lvar = lc($var);

  return unless $self->_make_list($list);

  if ($var eq 'ALL') {
    $ok = $self->validate_passwd($user, $passwd, $list, "config_ALL");
  }

  # Do we have a group?
  elsif ($var eq uc($var)) {
    $ok = $self->validate_passwd($user, $passwd, $list, "config_$lvar");
  }
  
  # We have a single variable
  else {
    @groups = $self->config_get_groups($var);
    unless (@groups) {
      $::log->out("not found");
      return;
    }
    for $i (@groups) {
      $ok = $self->validate_passwd($user, $passwd, $list, "config_$i");
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
  my ($self, $request) = @_;
  my $log = new Log::In 50, "$request->{'list'}, $request->{'user'}, $request->{'path'}";
  my ($mess, $ok, $root);

  $root = 1 if $request->{'path'} =~ m!^/!;

  ($ok, $mess) =
    $self->list_access_check($request, 'root' => $root);

  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_get($request->{'list'}, $request->{'user'}, $request->{'user'}, 
              $request->{'mode'}, $request->{'cmdline'}, $request->{'path'});
}

sub _get {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $name) = @_;
  my $log = new Log::In 35, "$list, $name";
  my (%data, $cset, $desc, $enc, $file, $mess, $nname, $ok, $type);

  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

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
      return (0, "Cannot open file \"$name\".\n");
    }
    return (1, '');
  }

  # Else build the entity and mail out the file
  $self->_get_mailfile($list, $victim, $name, $file, %data); #$desc, $type, $cset, $enc);

  # and be sneaky and return another file to be read; this keeps the code
  # simpler and lets the owner customize the transmission message
#  ($file, $desc, $type, $cset, $enc) = 
  ($file, %data) = $self->_list_file_get($list, 'file_sent');
  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return (0, "Cannot open file \"$name\".\n");
  }
  return (1, '');
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
  my ($self, $request, $chunksize) = @_;
  my $log = new Log::In 50;
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
  (1, '');
}

=head2 faq_start, _faq, help_start, info_start, _info, intro_start, _intro

These are special-purpose functions for retrieving special sets of files
from the file storage.  They exist because we want to allow different
access restrictions and list/GLOBAL visibilities for certain sets of files,

=cut
sub faq_start {
  my ($self, $request) = @_;
  my $log = new Log::In 50, "$request->{'list'}, $request->{'user'}";
  my ($mess, $ok);
  
  ($ok, $mess) =
    $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_faq($request->{'list'}, $request->{'user'}, $request->{'user'}, 
              $request->{'mode'}, $request->{'cmdline'}, 'faq');
}

sub _faq {
  my ($self, $list, $requ, $victim, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$list";
  my ($file, $subs);

  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

  $subs =
    {
     $self->standard_subs($list),
     USER     => $requ,
    };

  ($file) = $self->_list_file_get($list, 'faq', $subs);
  
  unless ($file) {
    return (0, "No FAQ available.\n");
  }
  
  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return (0, "No FAQ available.\n");
  }
  push @{$self->{'get_temps'}}, $file;
  return (1, '');
}

sub help_start {
  my ($self, $request) = @_;
  my (@info, $file, $mess, $ok, $subs, $whoami, $wowner);

  $request->{'list'} = 'GLOBAL';

  # convert, for example,
  #    "help configset access_rules" 
  # to "help configset_access_rules"
  if ($request->{'topic'}) {
    $request->{'topic'} = lc(join('_', split(/\s+/, $request->{'topic'})));
  }
  else {
    $request->{'topic'} = "help";
  }
  my $log = new Log::In 50, "$request->{'user'}, $request->{'topic'}";

  ($ok, $mess) =
    $self->global_access_check($request);

  # No stalls should be allowed...
  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $whoami = $self->_global_config_get('whoami'),
  $wowner = $self->_global_config_get('sender'),

  $subs =
    {
     $self->standard_subs('GLOBAL'),
     USER     => $request->{'user'},
    };

  ($request->{'topic'}) = $request->{'topic'} =~ /(.*)/; # Untaint
  ($file) =  $self->_list_file_get('GLOBAL', "help/$request->{'topic'}", $subs);

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
  return (1, '');
}

sub info_start {
  my ($self, $request) = @_;
  my $log = new Log::In 50, "$request->{'list'}, $request->{'user'}";
  my ($mess, $ok);
  
  ($ok, $mess) =
    $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_info($request->{'list'}, $request->{'user'}, $request->{'user'}, 
               $request->{'mode'}, $request->{'cmdline'}, 'info');
}

sub _info {
  my ($self, $list, $requ, $victim, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$list";
  my ($file, $subs);

  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

  $subs =
    {
     $self->standard_subs($list),
     USER     => $requ,
    };

  ($file) = $self->_list_file_get($list, 'info', $subs);
  
  unless ($file) {
    return (0, "No info available.\n");
  }
  
  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return (0, "Info file available.\n");
  }
  push @{$self->{'get_temps'}}, $file;
  return (1, '');
}

sub intro_start {
  my ($self, $request) = @_;
  my $log = new Log::In 50, "$request->{'list'}, $request->{'user'}";
  my ($mess, $ok);
  
  ($ok, $mess) =
    $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_intro($request->{'list'}, $request->{'user'}, $request->{'user'}, 
                $request->{'mode'}, $request->{'cmdline'});
}

sub _intro {
  my ($self, $list, $requ, $victim, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$list";
  my ($file, $subs);

  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

  $subs =
    {
     $self->standard_subs($list),
     USER     => $requ,
    };

  ($file) = $self->_list_file_get($list, 'intro', $subs);
  
  unless ($file) {
    return (0, "No intro available.\n");
  }
  
  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return (0, "Intro file is unavailable.\n");
  }
  push @{$self->{'get_temps'}}, $file;
  return (1, '');
}

=head2 password(..., password)

This changes a user''s password.  If mode is 'gen' or 'rand' (generate or
random) a password is randomly generated.

=cut
sub password {
  my ($self, $request) = @_;
  my ($ok, $mess, $minlength);
  my $log = new Log::In 30, "$request->{'victim'}, $request->{'mode'}";

  $request->{'list'} = 'GLOBAL';

  $minlength = $self->_global_config_get('password_min_length');
  # Generate a password if necessary
  if ($request->{'mode'} =~ /gen|rand/) {
    $request->{'newpasswd'} = Mj::Access::_gen_pw($minlength);
  }
  return (0, "The password must be at least $minlength characters long.\n")
    unless (length($request->{'newpasswd'}) >= $minlength);

  ($ok, $mess) =
    $self->global_access_check($request, 'password_length' => 
                               length($request->{'newpasswd'}));

  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_password($request->{'list'}, $request->{'user'}, $request->{'victim'}, 
                   $request->{'mode'}, $request->{'cmdline'}, $request->{'newpasswd'});  
}

use MIME::Entity;
sub _password {
  my ($self, $list, $user, $vict, $mode, $cmdline, $pass) = @_;
  my $log = new Log::In 35, "$vict";
  my (%file, $desc, $ent, $file, $reg, $sender, $subst);

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

    $subst = {
              $self->standard_subs('GLOBAL'),
	      PASSWORD  => $pass,
	      VICTIM    => $vict->strip,
	     };

    ($file, %file) = $self->_list_file_get('GLOBAL', 'new_password');
    return (1, '') unless $file;

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
  (1, '');
}

=head2 put_start(..., file, subject, content_type, content_transfer_encoding)

This starts the file put operation.

=cut
sub put_start {
  my ($self, $request) = @_;
  my ($filedesc, $ok, $mess);

  # Initialize optional parameters.
  $request->{'xdesc'}     ||= '';
  $request->{'ocontype'}  ||= '';
  $request->{'ocset'}     ||= '';
  $request->{'oencoding'} ||= '';
  $request->{'olanguage'} ||= '';
  $filedesc =   "$request->{'ocontype'}\002$request->{'ocset'}\002$request->{'oencoding'}\002$request->{'olanguage'}";
  $request->{'arg3'} = $filedesc;

  my $log = new Log::In 30, "$request->{'list'}, $request->{'file'}, 
              $request->{'xdesc'}, $request->{'ocontype'}, $request->{'ocset'}, 
              $request->{'oencoding'}, $request->{'olanguage'}";
  
  # Check the password
  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_put($request->{'list'}, $request->{'user'}, $request->{'user'}, 
              $request->{'mode'}, $request->{'cmdline'}, $request->{'file'}, 
              $request->{'xdesc'}, $filedesc);
}

sub _put {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $file, $subj, $stuff)
    = @_;
  my ($cset, $enc, $lang, $mess, $ok, $type);

  # Extract the encoded type and encoding
  ($type, $cset, $enc, $lang) = split("\002", $stuff);

  my $log = new Log::In 35, "$list, $file, $subj, $type, $cset, $enc, $lang";
  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

  # If given an "absolute path", trim it, else stick "public/" onto it
  unless ($file =~ s!^/!!) {
    $file = "public/$file";
  }

  # Make a directory instead?
  if ($mode =~ /dir/) {
    return ($self->{'lists'}{$list}->fs_mkdir($file, $subj));
  }

  # The zero is the overwrite control; haven't quite figured out what to
  # do with it yet.
  $self->{'lists'}{$list}->fs_put_start($file, 0, $subj, $type, $cset, $enc, $lang);
}

=head2 put_chunk(..., data, data, data, ...)

Adds a bunch of data to the file.

=cut
sub put_chunk {
  my ($self, $request, @chunk) = @_;
  $self->{'lists'}{$request->{'list'}}->fs_put_chunk(@chunk);
}

=head2 put_done(...)

Stops the put operation.

=cut
sub put_done {
  my ($self, $request) = @_;
  
  $self->{'lists'}{$request->{'list'}}->fs_put_done;
}

=head2 request_response(...)

This is a simple function which mails a list''s request_response file to
the victim.  It does not handle returning the file inline (because the
intent is for it to be called from an email interface without returning any
status.)

=cut
sub request_response {
  my ($self, $request) = @_;
  my $log = new Log::In 50, "$request->{'list'}, $request->{'victim'}";
  my ($mess, $ok);
  
  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_request_response($request->{'list'}, $request->{'user'}, 
                           $request->{'user'}, $request->{'mode'}, 
                           $request->{'cmdline'});
}

use MIME::Entity;
use Mj::MailOut;
sub _request_response {
  my ($self, $list, $requ, $victim, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$list";
  my (%file, $cset, $desc, $enc, $ent, $file, $list_own, 
      $mess, $sender, $subst, $type);

  return unless $self->_make_list($list);

  ($file, %file) = $self->_list_file_get($list, 'request_response');
  return unless $file;

  # Build the entity and mail out the file
  $sender = $self->_list_config_get($list, 'sender');
  $list_own   = $self->_list_config_get($list, 'sender');

  $subst = {
            $self->standard_subs($list),
            'REQUESTER' => "$requ",
            'USER'      => "$requ",
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

  $self->mail_entity($sender, $ent, $victim) if $ent;
  (1, '');
}


sub index {
  my ($self, $request) = @_;
  my ($ok, $mess, $root);
  my $log = new Log::In  30, "$request->{'list'}, $request->{'path'}";
  
  # Are we rooted?  Special case '/help', so index GLOBAL /help works.
  $root = 1 if $request->{'path'} =~ m!^/! && $request->{'path'} ne '/help';

  # Check for access
  ($ok, $mess) = $self->list_access_check($request, 'root' => $root);

  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_index($request->{'list'}, $request->{'user'}, $request->{'user'}, 
                $request->{'mode'}, $request->{'cmdline'}, $request->{'path'});
}

sub _index {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $dir) = @_;
  my $log = new Log::In 35, "$list, $dir";
  my ($nodirs, $recurse);

  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

  # If given an "absolute path", trim it, else stick "public/" onto it
  unless ($dir =~ s!^/!!) {
    $dir = "public/$dir";
  }

  # Now trim a trailing slash
  $dir =~ s!/$!!;

  $nodirs  = 1 if $mode =~ /nodirs/;
  $recurse = 1 if $mode =~ /recurs/;

  (1, $self->{'lists'}{$list}->fs_index($dir, $nodirs, $recurse));
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

  return unless $self->_make_list($list);
  @search = $self->_list_config_get($list, 'file_search');

  $lang ||= $self->_list_config_get($list, 'default_language'); 
  @langs = split(/\s*,\s*/, $lang);

  # Build @paths list; maintain %paths hash to determine uniqueness.
  for $i (@search, 'DEFAULT:', 'GLOBAL:$LANG', 'GLOBAL:',
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
    if ($l ne $list && $l ne 'DEFAULT' && $l ne 'GLOBAL' && $l ne 'STOCK') {
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
    if (@out and $subs) {
      $out[0] = $self->substitute_vars($out[0], $subs, $list);
    }
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

  return "No such file: \"$_[1]\".\n" unless $file;

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
  return unless $self->_make_list($list);
  $self->{'lists'}{$list}->fs_put(@_);
}

=head2 _list_file_delete(list, file, force)

Calls the lists fs_delete function.

=cut
sub _list_file_delete {
  my $self  = shift;
  my $list  = shift;
  my $log = new Log::In 150, "$list, $_[0]";
  return unless $self->_make_list($list);
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
                 defaultdata  => $self->{defaultdata},
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

#  $self->_fill_lists;
  
  if (($name eq 'ALL' && $all) ||
      (($name eq 'GLOBAL' or $name eq 'DEFAULT') && $global))
    {
      # untaint
      $name =~ /(.*)/;
      $name = $1;
      return $name;
    }

  $name = lc($name);
  if (-d "$self->{'ldir'}/$name") {
    # untaint
    $name =~ /(.*)/;
    $name = $1;
    $self->_make_list($name);
    return $name if ($self->{'lists'}{$name});
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
  my ($self, $request) = @_;
  my $log = new Log::In 30, scalar(@{$request->{'tokens'}}) . " tokens";
  my ($comment, $token, $ttoken, @out);

  $request->{'list'} = 'GLOBAL';

  return (0, "No token was supplied.\n")
    unless (scalar(@{$request->{'tokens'}}));

  # XXX Log an entry for each token / only recognized tokens? 
  for $ttoken (@{$request->{'tokens'}}) {
    $token = $self->t_recognize($ttoken);
    if (! $token) {
      push @out, 0, "Illegal token \"$ttoken\".\n";
      next;
    }

    my ($ok, $mess, $data, $tmp) = 
        $self->t_accept($token, $request->{'mode'}, $request->{'xplanation'},
                        $request->{'delay'});

    # We don't want to blow up on a bad token; log something useful.
    unless (defined $data) {
      $data = { list      => 'GLOBAL',
           command   => 'badtoken',
           type      => 'badtoken',
           user      => $request->{'user'},
           victim    => 'none',
           cmdline   => $request->{'cmdline'},
          };
      $tmp = [0];
    }

    $comment = '';
    $comment = $tmp->[1] unless (!defined $tmp->[1] or ref $tmp->[1]);

    # Now call inform so the results are logged
    $self->inform($data->{'list'},
          ($data->{'type'} eq 'consult')? 'consult' : $data->{'command'},
          $data->{'user'},
          $data->{'victim'},
          $data->{'cmdline'},
          "token-$self->{'interface'}",
          $tmp->[0], 0, 0, $comment);

    $mess ||= "Further approval is required.\n" if ($ok < 0);
    if ($ok) {
      push @out, $ok, [$mess, $data, $tmp];
    }
    else {
      push @out, $ok, $mess;
    }
  }
  @out; 
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
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'newaddress'}, $request->{'user'}";
  my ($a2, $ok, $mess);

  return (0, "No address was supplied.\n") 
    unless (exists $request->{'newaddress'});
 
  $a2 = new Mj::Addr($request->{'newaddress'});
  ($ok, $mess) = $a2->valid;
  return (0, "$request->{'newaddress'} is an invalid address.\n$mess")
    unless ($ok > 0);

  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }
  $self->_alias($request->{'list'}, $request->{'user'}, $request->{'user'}, 
                $request->{'mode'}, $request->{'cmdline'}, $request->{'newaddress'});
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

  ($ok, $err) = $self->{'alias'}->add("", $from->xform, $data);
  unless ($ok) {
    # Really, this cannot happen.
    return (0, $err);
  }
  return (1, '');
}

=head2 announce

This command allows a message to be sent to all or a portion
of the subscribers of a mailing list, optionally including
the subscribers in "nomail" mode.

The message is sent as a probe, meaning that each subscriber
will receive a customized copy.  The "To:" header in
the message will be set to the subscriber's address.

=cut

sub announce {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'list'}, $request->{'file'}";

  return (0, "A file name was not supplied.\n")
    unless $request->{'file'};

  return (0, "Announcements to the DEFAULT list are not supported.\n")
    if ($request->{'list'} eq 'DEFAULT');

  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_announce($request->{'list'}, $request->{'user'}, $request->{'user'}, 
                   $request->{'mode'}, $request->{'cmdline'}, $request->{'file'});

}

use MIME::Entity;
sub _announce {
  my ($self, $list, $user, $vict, $mode, $cmdline, $file) = @_;
  my $log = new Log::In 30, "$list, $file";
  my (@classlist, %data); 
  my ($baseclass, $classes, $desc, $ent, $mailfile, $sender, $tmpfile);

  $sender = $self->_list_config_get($list, 'sender');
  return (0, "Unable to obtain sender address.\n")
    unless $sender;

  $subs =
    {
     $self->standard_subs($list),
     'REQUESTER' => $user,
     'USER'      => $user,
    };
  
  ($mailfile, %data) = $self->_list_file_get($list, $file, $subs);
 
  return (0, "The file $file is unavailable.\n")
    unless $mailfile;

  $desc = $self->substitute_vars_string($data{'description'}, $subs);
  
  $ent = build MIME::Entity
    (
     'Path'     => $mailfile,
     'Type'     => $data{'c-type'},
     'Charset'  => $data{'charset'},
     'Encoding' => $data{'c-t-encoding'},
     'Subject'  => $desc || "Announcement from the $list list",
     'Top'      => 1,
     '-To'      => '$MSGRCPT',
     '-From'    => $sender,
     'Filename' => undef,
     'Content-Language:' => $data{'language'},
    );
 
  return (0, "Unable to create mail entity.\n")
    unless $ent;

  $tmpfile = "$tmpdir/mja" . unique();
  open FINAL, ">$tmpfile" ||
    return(0, "Could not open temporary file, $!");
  $ent->print(\*FINAL);
  close FINAL;

  # Construct classes from the mode.  If none was given,
  # use all classes.
  $classes = {};
  if ($list eq 'GLOBAL') {
    @classlist = qw(each nomail);
  }
  else {
    @classlist = qw(nomail each-noprefix-noreplyto each-prefix-noreplyto 
                    each-noprefix-replyto each-prefix-replyto);
    push @classlist, $self->{'lists'}{$list}->_digest_classes;
  }
  for (@classlist) {
    ($baseclass = $_) =~ s/\-.+//;
    if (!$mode or $mode =~ /$baseclass/) {
      $classes->{$_} =
        {
         'exclude' => {},
         'file'    => $tmpfile,
        };
    }
  }
  return (0, "No valid subscriber classes were found.\n")
    unless (scalar keys %$classes);

  # Send the message.
  $self->probe($list, $sender, $classes);
  unlink $tmpfile;
  unlink $mailfile;
  1;
}

=head2 archive(..., list, args)

This is a general archive interface.  It checks access, then looks at the
mode to determine what action to take.

Useful modes include:

  get - retrieve a named message (or messages).
 
  index - retrieve a list of messages.

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
  Separators (1998-05-01) are allowed in dates and names, by
  applying s/[\-]//g to each date.  Spaces around the dashes in a range
  are required.  

  Results for archive-get are returned in one or more digests unless 
  -immediate is given; in that case, the messages will be returned 
  immediately in mbox format.  The type of digest is selected by a mode; 
  mime if "mime" mode is specified; text otherwise.  The digest will be mailed 
  in a separate message.

  Other modes could be used to return other data 
  (probably an array of everything stored within the archive index).

=cut
sub archive_start {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'list'}, $request->{'args'}";
  my ($ok, $out);

  return (0, "No dates or message numbers were supplied.\n")
    unless ($request->{'args'});

  ($ok, $out) =
    $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $out);
  }
  if ($request->{'mode'} =~ /delete|sync/) {
    return (0, "Insufficient privileges to alter the archive.\n")
      unless ($ok > 1);
    $self->{'arcadmin'} = 1;
  }

  $self->_archive($request->{'list'}, $request->{'user'}, $request->{'user'}, 
                  $request->{'mode'}, $request->{'cmdline'}, $request->{'args'});
}

# Returns data for all messages matching the arguments.
sub _archive {
  my ($self, $list, $user, $vict, $mode, $cmdline, $args) = @_;
  my $log = new Log::In 30, "$list, $args";
  my (@msgs, $mess, $ok);
  return 1 unless $args;
  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);
  if ($mode =~ /sync/) {
    @msgs = $self->{'lists'}{$list}->archive_find($args);
  }
  else {
    @msgs = $self->{'lists'}{$list}->archive_expand_range(0, $args);
  }
  $self->{'archct'} = 1;
  return (1, @msgs);
}

sub archive_chunk {
  my ($self, $request, $result) = @_;
  my $log = new Log::In 30, "$request->{'list'}";
  my (@msgs, @out, $data, $ent, $file, $i, $list, $out, $owner, $fh, $buf);

  return (0, "The archive was not initialized.\n")
    unless (exists $self->{'archct'});
  return (1, "No messages were found which matched your request.\n")
    if (scalar(@$result) <= 0);
  return (0, "Unable to initialize list $request->{'list'}.\n")
    unless $self->_make_list($request->{'list'});
  $list = $self->{'lists'}{$request->{'list'}};


  if ($request->{'mode'} =~ /sync/) {
    @msgs = @$result;
    for $i (@msgs) {
      push @out, $list->archive_sync($i, $tmpdir);
    }
    return @out;
  }
  elsif ($request->{'mode'} =~ /immediate/) {
    $buf = '';
    @msgs = @$result;
    for $i (@msgs) {
      $out = $list->archive_get_start(@$i);
      next unless $out;
      while ($out = $list->archive_get_chunk(4096)) {
        $buf .= $out;
      }
      $list->archive_get_done;
      $buf .= "\n";
    }
    return (1, $buf);
  }
  elsif ($request->{'mode'} =~ /delete/) {
    return (0, "Permission denied.\n") 
      unless (exists $self->{'arcadmin'});
    $buf = '';
    @msgs = @$result;
    for $i (@msgs) {
      $out = $list->archive_delete_msg(@$i);
      if ($out) {
        $buf .= "Message $i->[0] deleted.\n";
      }
      else {
        $buf .= "Message $i->[0] not deleted.\n";
      }
    }
    return (1, $buf);
  }
    
  else {
    $out = ($request->{'mode'} =~ /mime/) ? "mime" : "text";
    ($file) = $list->digest_build
    (messages      => $result,
     type          => $out,
     subject       => "$request->{'list'} list archives ($self->{'archct'})",
     to            => "$request->{'user'}",
     tmpdir        => $tmpdir,
     index_line    => $self->_list_config_get($request->{'list'}, 'digest_index_format'),
     index_header  => "Custom-Generated Digest Containing " . scalar(@$result) . 
                      " Messages

Contents:
",
     index_footer  => "\n",
    );
    # Mail the entity out to the victim
    $owner = $self->_list_config_get($request->{'list'}, 'sender');
    $self->mail_message($owner, $file, $request->{'user'});
    unlink $file;
    $self->{'archct'}++;
    return (1, "A digest containing ".scalar(@$result)." messages has been mailed.\n");
  }
}



sub archive_done {
  my ($self, $request, $result) = @_;
  delete $self->{'archct'};
  delete $self->{'arcadmin'};
  1;
}


=head2 auxadd(..., list, name, address)

This adds an address to a lists named auxiliary address list.

=cut
sub auxadd {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'list'}, $request->{'auxlist'}";
  my (@out, $addr, $ok, $mess);

  return (0, "Illegal auxiliary list name \"$request->{'auxlist'}\".")
    unless $self->legal_list_name($request->{'auxlist'});

  $request->{'auxlist'} =~ /(.*)/;  
  $request->{'auxlist'} = $1;  

  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    $log->message(30, "info", "$request->{'victim'}: noaccess");
    return ($ok, $mess);
  }
  
  $self->_auxadd($request->{'list'}, $request->{'user'}, $request->{'victim'}, 
    $request->{'mode'}, $request->{'cmdline'}, $request->{'auxlist'});
}

sub _auxadd {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $name) = @_;
  my $log = new Log::In 35, "$name, $victim";

  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

  # I got the internal call's arguments backwards.
  my($ok, $data) =
    $self->{'lists'}{$list}->aux_add($name, $mode, $victim);

  unless ($ok) {
    $log->out("failed, existing");
    return ($ok, $data);
  }

  return ($ok, [$victim]);
}

=head2 auxremove(..., list, name, address)

This removes an address from a lists named auxiliary address list.

=cut
sub auxremove {
  my ($self, $request) = @_;
  my (@removed, @out, $error, $ok);
  my $log = new Log::In 30, "$request->{'list'}, $request->{'auxlist'}";

  return (0, "Illegal auxiliary list name \"$request->{'auxlist'}\".")
    unless $self->legal_list_name($request->{'auxlist'});

  $request->{'auxlist'} =~ /(.*)/;  
  $request->{'auxlist'} = $1;  

  if ($request->{'mode'} =~ /regex/) {
    ($ok, $error, $request->{'victim'}) 
      = Mj::Config::compile_pattern($request->{'victim'}, 0);
    return ($ok, $error) unless $ok;
  }

  ($ok, $error) = $self->list_access_check($request);

  unless ($ok > 0) {
    $log->message(30, "info", "$addr: noaccess");
    return ($ok, $error);
  }
  
  $self->_auxremove($request->{'list'}, $request->{'user'}, 
                    $request->{'victim'}, $request->{'mode'}, 
                    $request->{'cmdline'}, $request->{'auxlist'});
}

sub _auxremove {
  my($self, $list, $requ, $vict, $mode, $cmd, $subl) = @_;
  my $log = new Log::In 35, "$list, $vict";
  my(@out, @removed, $key, $data);

  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

  @removed = $self->{'lists'}{$list}->aux_remove($subl, $mode, $vict);

  unless (@removed) {
    $log->out("failed, nomatching");
    return (0, "Cannot remove $vict:  no matching addresses.");
  }

  while (($key, $data) = splice(@removed, 0, 2)) {
    push (@out, $data->{'stripaddr'});
  }
  (1, [@out]);
}



=head2 auxwho_start, auxwho_chunk, auxwho_done

These implement iterative access to an auxiliary list.

=cut
sub auxwho_start {
  &who_start(@_);
}

sub _auxwho {
  &_who(@_);
}

sub auxwho_chunk {
  &who_chunk(@_);
}

sub auxwho_done {
  &who_done(@_);
}

sub configdef {
  my ($self, $request) = @_;
  my ($var, @out, $ok, $mess);
  my $log = new Log::In 30, "$request->{'list'}, @{$request->{'vars'}}";

  for $var (@{$request->{'vars'}}) {
    ($ok, $mess) =
      $self->list_config_set_to_default($request->{'user'}, $request->{'password'},
                                      $request->{'list'}, $var);
    push @out, $ok, [$mess, $var];
  }
  @out;
}

sub configset {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'list'}, $request->{'setting'}";
  my ($ok, $mess) =
      $self->list_config_set($request->{'user'}, $request->{'password'}, 
                             $request->{'list'}, $request->{'setting'},
                             @{$request->{'value'}});
  return ($ok, $mess);
}

sub configshow {
  my ($self, $request) = @_;
  my (%all_vars, @vars, $auto, $comment, $flag, $group, $groups,
      $message, $tag, $val, $var, $vars, @whence, @out, @hereargs);

  if (! defined $request->{'groups'}->[0]) {
    $request->{'groups'} = ['ALL'];
  }
  for $group (@{$request->{'groups'}}) {
    # This expands groups and checks visibility and existence of variables
    @vars = $self->config_get_vars($request->{'user'}, $request->{'password'}, 
                                   $request->{'list'}, $group);
    unless (@vars) {
      push @out, [0, "**** No visible variables matching $group", $group, ''];
    }
    else {
      for $var (@vars) {
        $all_vars{$var}++;
      }
    }
  }
  for $var (sort keys %all_vars) {
    $auto = 2;
    if ($self->config_get_isauto($var)) {
      $auto = -1;
    }
    elsif ($self->config_get_mutable($var)) {
      $auto = 1;
    }
    # Process the options
    $comment = '';
    if ($request->{'mode'} !~ /nocomments/) {
      $comment = $self->config_get_intro($request->{'list'}, $var) .
        $self->config_get_comment($var);
      $whence = $self->config_get_whence($request->{'list'}, $var);
      if (!defined($whence)) {
        $comment .= "Hmm, couldn't tell where this was set.\n";
      }
      elsif ($whence > 0) {
        $comment .= "This value was set by the DEFAULT list.\n";
      }
      elsif ($whence < 0 and $auto == 2) {
        $comment .= "This value was set by the list owners.\n";
      }
      elsif ($whence == 0) {
        $comment .= "This value was set by the installation defaults.\n";
      }
      if ($auto == 2) {
        $comment .= "A global password is required to change this value.\n";
      }
    }
    if ($self->config_get_isarray($var)) {
      @hereargs = ();
      # Process as an array
      $tag = Majordomo::unique2();
      for ($self->list_config_get($request->{'user'}, $request->{'password'}, 
                                  $request->{'list'}, $var, 1))
      {
        push (@hereargs, "$_\n") if defined $_;
      }
      push @out, [$auto, $comment, $var, [@hereargs]];
    }
    else {
      # Process as a simple variable
      $val = $self->list_config_get($request->{'user'}, $request->{'password'}, 
                                    $request->{'list'}, $var, 1);
      push @out, [$auto, $comment, $var, $val];
    }
  }
  return (1, @out);
}

=head2 changeaddr

This replaces an entry in the master address database.  

=cut
sub changeaddr {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'victim'}, $request->{'user'}";
  my ($ok, $error);
  
  $request->{'list'} = 'GLOBAL';

  ($ok, $error) = $self->global_access_check($request);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $error);
  }
  
  $self->_changeaddr($request->{'list'}, $request->{'user'}, $request->{'victim'},                     $request->{'mode'}, $request->{'cmdline'});
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
    next unless $self->_make_list($l);
    ($lkey, $ldata) = $self->{'lists'}{$l}->remove('', $key);
    if ($ldata) {
      $ldata->{'fulladdr'} = $requ->full;
      $ldata->{'stripaddr'} = $requ->strip;
      $self->{'lists'}{$l}->{'subs'}->add('', $requ->canon, $ldata);
    }
  }

  @aliases = $self->_alias_reverse_lookup($key, 1);
  for (@aliases) {
    if ($_ eq $vict->canon) {
      ($lkey, $ldata) = $self->{'alias'}->remove('', $_);
      $ldata->{'target'} = $requ->canon;
      $ldata->{'striptarget'} = $requ->strip;
      $self->{'alias'}->add('', $requ->canon, $ldata);
    }
    else {
      $self->{'alias'}->replace('', $_, 'target', $requ->canon);
      $self->{'alias'}->replace('', $_, 'striptarget', $requ->strip);
    }
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
  my ($self, $request) = @_;
  my ($mess, $ok);

  $request->{'list'} = 'GLOBAL';

  unless ($request->{'mode'} =~ /regen/) {
    return (0, "Must supply a list name.\n")
      unless $request->{'newlist'};

    return (0, "Must supply an address for the owner.\n")
      unless $request->{'victim'};

    my $log = new Log::In 50, "$request->{'newlist'}, $request->{'victim'}";

    return (0, "Illegal list name: $request->{'newlist'}")
      unless $self->legal_list_name($request->{'newlist'});
  }
 
  $request->{'newlist'} = lc $request->{'newlist'}; 
  $self->_fill_lists;

  # Check the password XXX Think more about where the results are
  # sent.  Noemally we expect that the majordomo-owner will be the
  # only one running this command, but if site policy allows other
  # users to run it, the information about the MTA configuration will
  # need to be sent to a different place than the results of the
  # command.
  ($ok, $mess) = $self->global_access_check($request);
    
  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_createlist('', $request->{'user'}, $request->{'victim'}, 
                     $request->{'mode'}, $request->{'cmdline'}, 
                     $request->{'victim'}, $request->{'newlist'});
}

sub _createlist {
  my ($self, $dummy, $requ, $vict, $mode, $cmd, $owner, $list) = @_;
  $list ||= '';
  my $log = new Log::In 35, "$mode, $list";
  my (%args, %data, @lists, @sublists, @tmp, $aliases, $bdir, $desc, 
      $dir, $dom, $debug, $ent, $file, $mess, $mta, $mtaopts, $pw, 
      $rmess, $sender, $subs, $sublists, $who);

  $owner = new Mj::Addr($owner);
  $pw    = Mj::Access::_gen_pw;
  $mta   = $self->_site_config_get('mta');
  $dom   = $self->{'domain'};
  $bdir  = $self->_site_config_get('install_dir');
  $bdir .= "/bin";
  $who   = $self->_global_config_get('whoami');
  $who   =~ s/@.*$// if $who; # Just want local part
  $mtaopts = $self->_site_config_get('mta_options');

  %args = ('bindir' => $bdir,
	   'topdir' => $self->{topdir},
	   'domain' => $dom,
	   'whoami' => $who,
	   'options'=> $mtaopts,
	   'aliases'=> $self->_list_config_get('DEFAULT', 'aliases'),
	   'queue_mode' => $self->_site_config_get('queue_mode'),
	  );

  unless ($mtaopts->{'maintain_config'}) {
    # We know that we'll give back instructions, so pull out the header.
    $mess = $Mj::MTAConfig::header{$mta} 
      unless $mode =~ /noheader/;
  }

  # Destroy mode: remove the list, but only if it has no subscribers.
  if ($mode =~ /destroy/) {
    return (0, "The GLOBAL and DEFAULT lists cannot be destroyed.\n")
      if ($list eq 'GLOBAL' or $list eq 'DEFAULT');
    $desc = $list;
    return (0, "The $desc list does not exist.\n")
      # valid_list calls _make_list and untaints the name
      unless ($list = $self->valid_list($desc));
    return (0, "Unable to open subscriber list for $list.\n")
      unless $self->{'lists'}{$list}->get_start;
    if ($self->{'lists'}{$list}->get_chunk(1)) {
      $self->{'lists'}{$list}->get_done;
      return (0, "All addresses must be unsubscribed before destruction.\n");
    }
    $self->{'lists'}{$list}->get_done;
    # Prefix a comma to the list directory name.  Suffix a version number.
    for ($desc = 0; ; $desc++) {
      last unless (-d "$self->{'ldir'}/,$list.$desc");
    }
    rename("$self->{'ldir'}/$list", "$self->{'ldir'}/,$list.$desc");
    return (0, "Unable to remove all of the files for $list.\n")
      if (-d "$self->{'ldir'}/$list");
    delete $self->{'lists'}{$list};
    $mess .= "The $list list was destroyed.\n";
  }

  # Should the MTA configuration be regenerated?
  if ($mode =~ /regen/ or $mode =~ /destroy/) {
    unless ($mta && $Mj::MTAConfig::supported{$mta}) {
      return (1, "Unsupported MTA $mta, can't regenerate configuration.\n");
    }

    # Extract lists and owners
    $args{'regenerate'} = 1;
    $args{'lists'} = [];
    $self->_fill_lists;
    for my $i (keys %{$self->{'lists'}}) {
      $debug = $self->_list_config_get($i, 'debug');
      $aliases = $self->_list_config_get($i, 'aliases');
      @sublists = '';
      if ($aliases =~ /A/) {
        if ($self->_make_list($i)) {
          @tmp = $self->_list_config_get($i, 'sublists');
          for my $j (@tmp) {
            ($j, undef) = split /[\s:]+/, $j, 2;
            push @sublists, $j;
          }
          $sublists = join "\002", @sublists;
        }
      }
      push @{$args{'lists'}}, [$i, $debug, $aliases, $sublists];
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
    $self->_list_config_set($list, 'master_password', $pw); 
    $self->_list_config_unlock($list);

    unless ($list eq 'GLOBAL' or $list eq 'DEFAULT' or $mode =~ /noarchive/) {
      $self->{'lists'}{$list}->fs_mkdir('public/archive', 'List archives');
    }

    # Send an introduction to the list owner.
    unless ($mode =~ /nowelcome/) {
      $sender = $self->_global_config_get('sender');

      $subs = {
       $self->standard_subs($list),
       'USER'     => $owner->strip,
       'PASSWORD' => $pw,
      };
   
      ($file, %data) = $self->_list_file_get('GLOBAL', 'new_list', $subs);
      $desc = $self->substitute_vars_string($data{'description'}, $subs); 

      if ($file) { 
        $ent = build MIME::Entity
          (
           Path     => $file,
           Type     => $data{'c-type'},
           Charset  => $data{'charset'},
           Encoding => $data{'c-t-encoding'},
           Subject  => $desc,
           Top      => 1,
           Filename => undef,
           '-To'    => $owner->full,
           'Content-Language:' => $data{'language'},
          );

        $self->mail_entity($sender, $ent, $owner) if $ent;
        unlink $file;
      }
    }
  }

  {
    no strict 'refs';
    $mess = &{"Mj::MTAConfig::$mta"}(%args, 'list' => $list);
    $mess ||= "The $list list was created with owner $owner and password $pw.\n";
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
  my ($self, $request) = @_;
  $request->{'args'} ||= 'ALL';
  my $log = new Log::In 30, "$request->{'mode'}, $request->{'list'}, 
                             $request->{'args'}";

  my ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }
  $self->_digest($request->{'list'}, $request->{'user'}, $request->{'user'}, 
                 $request->{'mode'}, $request->{'cmdline'}, $request->{'args'});
}

sub _digest {
  my ($self, $list, $requ, $vict, $mode, $cmd, $digest) = @_;
  my $log  = new Log::In 35, "$mode, $list, $digest";
  my ($d, $deliveries, $digests, $force, $i, $sender, $subs, $tmpdir,
      $whereami);

  $d = [$digest];
  $d = undef if $digest eq 'ALL';

  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

  # status:  return data but make no changes.
  if ($mode =~ /status/) {
    $i = $self->{'lists'}{$list}->digest_examine($digest);
    return (1, $i) if $i;
    return (0, "Unable to obtain digest data.\n");
  }

  # check, force: call do_digests
  if ($mode =~ /(check|force)/) {
    # A simple substitution hash; do_digests will add to it
    $sender   = $self->_list_config_get($list, 'sender');
    $whereami = $self->_global_config_get('whereami');
    $tmpdir   = $self->_global_config_get('tmpdir');
    $subs = {
              $self->standard_subs($list),
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
      $self->deliver($list, '', $sender, undef, $deliveries);
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
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'mode'}";
  my (@lines, @out, @sublists, $cat, $compact, $count, $data, $desc, 
      $digests, $flags, $i, $limit, $list, $mess, $ok, $sublist);

  $request->{'list'} = 'GLOBAL';

  # Stuff the registration information to save lots of database lookups
  $self->_reg_lookup($request->{'user'});

  if ($request->{'regexp'}) {
    ($ok, $mess, $request->{'regexp'}) 
      = Mj::Config::compile_pattern($request->{'regexp'}, 0, "isubstring");
    return ($ok, $mess) unless $ok;
  }

  # Check global access
  ($ok, $mess) = $self->global_access_check($request);

  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $request->{'mode'} ||= $self->_global_config_get('default_lists_format');
  $limit =  $self->_global_config_get('description_max_lines');

  if ($request->{'mode'} =~ /short/) {
    $compact = 1;
  }

  for $list ($self->get_all_lists($request->{'user'}, 
                                  $request->{'password'}, $request->{'regexp'})) {
    @lines = $self->_list_config_get($list, 'description_long');
    $cat   = $self->_list_config_get($list, 'category');;
    $desc  = '';
    $flags = '';
 
    if ($compact) {
      $desc = $self->_list_config_get($list, 'description');
      $desc ||= $lines[0];
    }
    else {
      $count = 1;
      for (@lines) {
	$desc .= "$_\n";
	$count++;
	last if $limit && $count > $limit;
      }
      $desc ||= $self->_list_config_get($list, 'description');
    }

    $data = { 
             'category'    => $cat, 
             'description' => $desc, 
             'flags'       => '',
             'list'        => $list, 
            };

    if ($request->{'mode'} =~ /enhanced/) {
      $data->{'flags'} .= 'S' 
                         if $self->is_subscriber($request->{'user'}, $list);
    }
    # "aux" mode: return information about auxiliary lists
    # and other administrative details
    # XXX Use config_get_vars with user and password to allow
    # restrictions on the data.
    if ($request->{'mode'} =~ /aux/) {
      $data->{'owner'}    = $self->_list_config_get($list, 'whoami_owner');
      $data->{'address'}  = $self->_list_config_get($list, 'whoami');
      $data->{'subs'}     = $self->{'lists'}{$list}->count_subs;
      $data->{'posts'}    = $self->{'lists'}{$list}->count_posts(30);
      $data->{'archive'}  = $self->_list_config_get($list, 'archive_url');
      $data->{'digests'}  = {};
      $digests = $self->_list_config_get($list, 'digests');
      for $i (keys %$digests) {
        next if ($i eq 'default_digest');
        $data->{'digests'}->{$i} = 
          $self->{'lists'}{$list}->describe_class('digest', $i, '');
      }
    }
    push @out, $data;
 
    if ($request->{'mode'} =~ /aux/) {
      $self->{'lists'}{$list}->_fill_aux;
      # If a master password was given, show all auxiliary lists.
      if ($ok > 1) {
        @sublists = keys %{$self->{'lists'}{$list}->{'auxlists'}};
      }
      else {
        @sublists = $self->_list_config_get($list, "sublists");
      }
      for $sublist (@sublists) {
        ($sublist, $desc) = split /[\s:]+/, $sublist, 2;
        $flags = '';
        if ($request->{'mode'} =~ /enhanced/) {
          $flags = 'S'  
            if ($self->{'lists'}{$list}->aux_is_member($sublist, $request->{'user'}));        
        }
        push @out, { 'list'        => "$list:$sublist", 
                     'category'    => $cat, 
                     'description' => $desc, 
                     'flags'       => $flags,
                     'subs'        => $self->{'lists'}{$list}->count_subs($sublist),
                   };
      }
    }  
    
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
  my ($self, $request) = @_;
  my $log = new Log::In 30, "@{$request->{'tokens'}}";
  my (%file, $data, $desc, $ent, $file, $in, $inf, $inform, $line, $t, @out);
  my ($list_owner, $mj_addr, $mj_owner, $ok, $mess, $reason, $repl, $rfile);
  my ($sess, $site, $token, $victim);

  $request->{'list'} = 'GLOBAL';

  return (0, "No token was supplied.\n")
    unless (scalar(@{$request->{'tokens'}}));

  $site       = $self->_global_config_get('site_name');
  $mj_addr    = $self->_global_config_get('whoami');
  $mj_owner   = $self->_global_config_get('sender');

  for $t (@{$request->{'tokens'}}) { 

    if (defined $t) {
      $token = $self->t_recognize($t);
    }
    if (! $token) {
      push @out, 0, ["Illegal token $t."];
      next;
    }

    ($ok, $data) = $self->t_reject($token);
    
    if (! $ok) {
      push @out, $ok, [$data];
      next;
    }

    # For confirmation tokens, a rejection is a serious thing.  We send a
    # message to the victim with important information.
    $reason = $rfile = '';
    if ($data->{'type'} eq 'confirm') {
      $rfile = 'token_reject';
    }
    # XXX Allowing a file name to be used gives read access to any file
    # in the list's file space to any moderator of the list.
    # 
    # The explanation for a consult rejection could be a file or a string.  
    # If it contains no white space, treat it as a file.  
    else {
      $rfile = 'ack_rejection';
      if (length $request->{'xplanation'}) {
        if ($request->{'xplanation'} =~ /^\S+$/) {
          $rfile = $request->{'xplanation'};
        }
        else {
          $reason = $request->{'xplanation'};
        }
      }
    }
    $list_owner = $self->_list_config_get($data->{'list'}, 'sender');
    if (! $list_owner) {
      # This will cope with the inability to create a list.
      push @out, 0, ["Unable to determine owner of $data->{'list'}."];
      next;
    }

    # Extract the session data
    # XXX Send this as an attachment instead of storing it in a string.
    $in = new IO::File("$self->{ldir}/GLOBAL/sessions/$data->{'sessionid'}");

    # If the file no longer exists, what should we do?  We assume it's just
    # a really old token and say so.
    $sess = '';
    if ($in) {
      while (defined($line = $in->getline)) {
        $sess .= $line;
      }
      $in->close;
    }
    else {
      $sess = "Session info has expired.\n";
    }

    $data->{'ack'} = 0;
    $repl = {
         $self->standard_subs($data->{'list'}),
         'CMDLINE'    => $data->{'cmdline'},
         'DATE'       => scalar localtime($data->{'time'}),
         'MESSAGE'    => $reason,
         'REJECTER'   => $request->{'user'},
         'COMMAND'    => $data->{'command'},
         'REQUESTER'  => $data->{'user'},
         'SESSIONID'  => $data->{'sessionid'},
         'SESSION'    => $sess,
         'TOKEN'      => $token,
         'VICTIM'     => $data->{'victim'},
        };
   
  
    $data->{'auxlist'} = '';
    if ($data->{'command'} eq 'post') {
      my %avars = split("\002", $data->{'arg3'});
      $data->{'auxlist'} = $avars{'sublist'} || '';
    }
    $victim = new Mj::Addr($data->{'victim'});  
    if ($data->{'type'} eq 'confirm' 
          or
        $self->{'lists'}{$data->{'list'}}->should_ack($data->{'auxlist'}, $victim, 'j')) 
    {
      $data->{'ack'} = 1;
      ($file, %file) = $self->_list_file_get($data->{'list'}, $rfile, $repl);
      unless (defined $file) {
        ($file, %file) = 
          $self->_list_file_get($data->{'list'}, "token_reject", $repl);
      }
      $desc = $self->substitute_vars_string($file{'description'}, $repl);
        
      # Send it off if type confirm or required by settings
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
    }
      
    # Then we send a message to the list owner and majordomo owner if
    # appropriate
    if ($data->{'type'} eq 'confirm') {
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
    push @out, $ok, [$token, $data];
  }
  @out;
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
  my ($self, $request) = @_;
  my ($ok, $error);
  my $log = new Log::In  30, "$request->{'victim'}, $request->{'mode'}";

  $request->{'newpasswd'} ||= '';
  $request->{'list'} = 'GLOBAL';
 
  # Do a list_access_check here for the address; subscribe if it succeeds.
  # The access mechanism will automatically generate failure notices and
  # confirmation tokens if necessary.
  ($ok, $error) = $self->global_access_check($request);

  unless ($ok > 0) {
    $log->message(30, "info", "noaccess");
    return ($ok, $error);
  }
  $self->_register('', $request->{'user'}, $request->{'victim'}, $request->{'mode'}, 
                       $request->{'cmdline'}, $request->{'newpasswd'});
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
    return (0, "$vict is already registered as $data->{'fulladdr'}.\n");
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
  return (1, [$vict]);
}


=head2 rekey(...)

This causes the list to rekey itself.  In other words, this recomputes the
keys for all of the rows of all of the databases based on the current
address transformations.  This must be done when the transformations
change, else address matching will fail to work properly.

=cut
sub rekey {
  my ($self, $request) = @_;
  my $log = new Log::In 30;
  
  $request->{'list'} = 'GLOBAL';

  my ($ok, $error) = $self->global_access_check($request);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $error);
  }

  $self->_rekey('', $request->{'user'}, $request->{'user'}, 
                $request->{'mode'}, $request->{'cmdline'});
}

sub _rekey {
  my($self, $d, $requ, $vict, $mode, $cmd) = @_;
  my $log = new Log::In 35, $mode;
  my ($addr, $count, $data, $list, $mess, $pw, @chunk, @lists);

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
  $mess = '';
  for $list (keys(%{$self->{lists}})) {
    next if ($list eq 'GLOBAL' or $list eq 'DEFAULT');
    if ($self->_make_list($list)) {
      $self->{'lists'}{$list}->rekey;
      if ($mode =~ /verify|repair/) {
        $log->message(35, 'info', "Verifying $list");
        $count = 0;
        next unless $self->{'lists'}{$list}->get_start;
        while (@chunk = $self->{'lists'}{$list}->get_chunk(1)) {
          $data = $chunk[0];
          unless ($addr = new Mj::Addr($data->{'fulladdr'})) {
            $mess .= "Skipping address $data->{'fulladdr'}.\n";
            next;
          }
          $data = $self->{'reg'}->lookup($addr->canon);
          # Create a new registry entry if one was missing.
          unless ($data) {
            $mess .= "$addr is subscribed to $list but not registered.\n";
            if ($mode =~ /repair/) {
              $pw = Mj::Access::_gen_pw();
              $data = {
                 stripaddr => $addr->strip,
                 fulladdr  => $addr->full,
                 regtime   => time,
                 language  => '',
                 'lists'   => $list,
                 flags     => '',
                 bounce    => '',
                 warnings  => '',
                 data1     => '',
                 data2     => '',
                 data3     => '',
                 data4     => '',
                 data5     => '',
                 password  => $pw,
              };
              $self->{'reg'}->add('', $addr->canon, $data);
              # inform the subscriber that a new password was generated.
              # "quiet" mode will cause a notice not to be sent.
              $self->_password($list, $addr, $addr, $mode, $cmd, $pw);
              $mess .= "Created new registry entry for $addr.\n";
            }
            next;
          }
          unless ($data->{'lists'} =~ /\b$list\b/) {
            $mess .= "$addr is subscribed to $list; registry says otherwise.\n";
            @lists = split("\002", $data->{'lists'});
            push @lists, $list;
            $data->{'lists'} = join("\002", @lists);
            $self->{'reg'}->replace('', $addr->canon, $data);
            next;
          }
          $count++;
        }
        $mess .= "$count addresses verified for the $list list.\n";
        $self->{'lists'}{$list}->get_done;
      }
    }
  }

  return (1, $mess);
}

=head2 report(..., $sessionid)

Display statistics about logged actions for one or more lists.

=cut
sub report_start {
  my ($self, $request) = @_;
  my $log = new Log::In 50, 
     "$request->{'list'}, $request->{'user'}, $request->{'action'}";
  my ($mess, $ok);

  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_report($request->{'list'}, $request->{'user'}, $request->{'user'}, 
              $request->{'mode'}, $request->{'cmdline'}, $request->{'action'},
              '', $request->{'date'});
}

use Mj::Archive qw(_secs_start _secs_end);
sub _report {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $action, $d, $date) = @_;
  my $log = new Log::In 35, "$list, $action";
  my (@actions, @legal, $begin, $end, $file, $span);

  if (defined $action) {
    @actions = split /\s*,\s*/, $action;
    @legal = command_list();
    push @legal, ('badtoken', 'bounce', 'consult', 'connect', 'ALL');
    for $action (@actions) {
      unless (grep {$_ eq $action} @legal) {
        return (0, "Action $action is unknown.\n");
      }
    }
  }

  $begin = 0; $end = time;

  if (length $date) {
    $date =~ s/[\-]//g;
    # date in yyyymmdd or yyyymmw format
    if ($date =~ /^\d+$/) {
      $begin = Mj::Archive::_secs_start($date, 1);
      $end = Mj::Archive::_secs_end($date, 1);
      return (0, "Unable to parse date $date.\n")
        unless ($begin <= $end);
    }
    # 5m for last five months, 1d2h for last 26 hours
    elsif ($span = Mj::List::_str_to_time($date)) {
      # _str_to_time returns current time + the difference.
      # Convert to current time - the difference.
      $begin = 2 * $end - $span;
    }
    else {
      return (0, "Unable to parse date $date.\n");
    }
  }
  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

  $file = "$self->{'ldir'}/GLOBAL/_log";
  
  $self->{'report_fh'} = new IO::File $file;
  unless ($self->{'report_fh'}) {
    return (0, "Cannot access the log.\n");
  }
  return (1, [$begin, $end]);
}

sub report_chunk {
  my ($self, $request) = @_;
  my $log = new Log::In 500, 
     "$request->{'list'}, $request->{'user'}, $request->{'action'}";
  my (@data, @out, $count, $line, $bounce, $trigger);
  my @actions = split /\s*,\s*/, $request->{'action'};
  unless (@actions) {
    $actions[0] = 'ALL';
  }
  $bounce  = grep { $_ eq 'bounce' } @actions;
  $trigger = grep { $_ eq 'trigger' } @actions;

  $request->{'begin'} ||= 0;
  $request->{'end'} ||= time;
  $request->{'chunksize'} ||= 1;
  return (0, "Invalid chunk size given.\n")
    unless ($request->{'chunksize'} > 0);
  return (0, "Unable to read data.\n") 
    unless ($self->{'report_fh'});

  $count = 0;

  while (1) { 
    $line = $self->{'report_fh'}->getline;
    last unless $line;
    @data = split "\001", $line;
    # check time, list, and action constraints
    next unless (defined $data[9] and $data[9] >= $request->{'begin'} 
                 and $data[9] <= $request->{'end'});
    next unless ($data[0] eq $request->{'list'} 
                 or $request->{'list'} eq 'ALL');
    next if ($data[1] eq 'bounce'  and ! $bounce);
    next if ($data[1] eq 'trigger' and ! $trigger);
    next unless ($actions[0] eq 'ALL' or grep {$_ eq $data[1]} @actions);
    push @out, [@data];
    $count++;  last if ($count >= $request->{'chunksize'});
  }

  (1, [@out]);
}

sub report_done {
  my ($self, $request) = @_;
  my $log = new Log::In 50, 
     "$request->{'list'}, $request->{'user'}, $request->{'action'}";
  return unless $self->{'report_fh'};
  undef $self->{'report_fh'};
  # Return complete list of auxiliary lists if in "summary" mode.
  if ($request->{'mode'} =~ /summary/) {
    return (1, '') unless $self->_make_list($request->{'list'});
    return (1, '') unless $self->{'lists'}{$request->{'list'}}->_fill_aux;
    return (1, sort keys %{$self->{'lists'}{$request->{'list'}}->{'auxlists'}});
  }
  (1, '');
}

=head2 sessioninfo(..., $sessionid)

Returns the stored text for a given session id.

=cut
sub sessioninfo_start {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'sessionid'}";
  my ($file);

  return (0, "You must supply a session identifier.\n")
    unless ($request->{'sessionid'});

  if ($request->{'sessionid'} !~ /^[0-9a-f]{32}$/) {
    return (0, "Illegal session identifier $request->{'sessionid'}.\n");
  }

  # spoolfile should only be defined if invoked by tokeninfo. 
  if (exists $request->{'spoolfile'}) { 
    # use the base name to untaint the file.
    $request->{'spoolfile'} =~ s#.+/([^/]+)$#$1#;
    $request->{'spoolfile'} = "$self->{ldir}/GLOBAL/spool/$request->{'spoolfile'}";
    if ($request->{'command'} eq 'post' and (-f $request->{'spoolfile'})) {
      $file = $request->{'spoolfile'};
    }
  }
  $file = "$self->{ldir}/GLOBAL/sessions/$request->{'sessionid'}" 
    unless defined $file;

  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return (0, "No such session.\n");
  }

  (1, '');
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
  my ($self, $request) = @_;
  my ($force, $ok, $mess);
  $request->{'auxlist'} = '' unless $request->{'mode'} =~ /aux/;
  $request->{'setting'} = '' if $request->{'mode'} =~ /check/;
  my $log = new Log::In 30, "$request->{'list'}, $request->{'setting'}";
 
  return (0, "The set command is not supported for the $request->{'list'} list.\n")
    if ($request->{'list'} eq 'GLOBAL' or $request->{'list'} eq 'DEFAULT'); 

  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }
  # If the request succeeds immediately, using the master password,
  # override the allowed_classes and allowed_flags settings if necessary.
  $force = ($ok > 1)? 1 : 0;

  $self->_set($request->{'list'}, $request->{'user'}, $request->{'victim'}, 
              $request->{'mode'}, $request->{'cmdline'}, $request->{'setting'},
              '', $request->{'auxlist'}, $force);
}

sub _set {
  my ($self, $list, $user, $addr, $mode, $cmd, $setting, $d, $sublist, $force) = @_;
  my (@lists, @out, $check, $data, $file, $l, $ok, $owner, $res);

  $check = 0;
  if ($mode =~ /check/ or ! $setting) {
    $check = 1;
  }

  if ($list eq 'ALL') {
    $data = $self->{'reg'}->lookup($addr->canon);
    return (0, "$addr is not registered.\n") 
      unless $data;
    @lists = split("\002", $data->{'lists'});
    return (0, "$addr is not subscribed to any lists.\n")
      unless @lists;
  }
  else {
    @lists = ($list);
  }
    
  for $l (sort @lists) {
    unless ($self->_make_list($l)) {
      push @out, (0, "The $l list apparently does not exist.\n");
      next;
    }
    if ($sublist) {
      unless ($ok = $self->{'lists'}{$l}->valid_aux($sublist)) {
        push @out, (0, "There is no sublist $sublist of the $l list.\n");
        next;
      }
      $sublist = $ok;
    }
    ($ok, $res) = 
      $self->{'lists'}{$l}->set($addr, $setting, $sublist, $check, $force);
    if ($ok) {
      $res->{'victim'}   = $addr;
      $res->{'list'}     = $l;
      $res->{'auxlist'}  = $sublist;
      $res->{'flagdesc'} = 
        [$self->{'lists'}{$l}->describe_flags($res->{'flags'})];
      $res->{'classdesc'} = 
        $self->{'lists'}{$l}->describe_class(@{$res->{'class'}});

      # Issue a partial digest if changing from digest mode
      # to nomail or single mode.
      if (exists $res->{'digest'} and ref $res->{'digest'}) {
        ($file) = $self->{'lists'}{$l}->digest_build
          (messages      => $res->{'digest'}->{'messages'},
           type          => $res->{'digest'}->{'type'},
           subject       => "Partial digest for the $l list",
           to            => "$addr",
           tmpdir        => $tmpdir,
           index_line    => $self->_list_config_get($l, 'digest_index_format'),
           index_header  => "Custom-Generated Digest",
           index_footer  => "\n",
          );
        # Mail the partial digest 
        if ($file) {
          $owner = $self->_list_config_get($l, 'sender');
          $self->mail_message($owner, $file, $addr);
          unlink $file;
        }
      } 
    }
    push @out, $ok, $res;
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
  my ($self, $request) = @_;
  my ($error, $ok, @out);
  my $log = new Log::In 30;

  $request->{'list'} = 'GLOBAL';
 
  # We know each address is valid; the dispatcher took care of that for us.
  $addr = $request->{'victim'};
  ($ok, $error) = $self->global_access_check($request);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, {strip   => $addr->strip,
                  comment => $addr->comment,
                  error   => $error,
                 },
           );
  }
  $self->_show('', $request->{'user'}, $request->{'victim'}, $request->{'mode'}, 
               $request->{'cmdline'});
}

sub _show {
  my ($self, $dummy, $user, $addr, $mode, $cmd) = @_;
  my $log = new Log::In 35, "$addr";
  my (%out, $aliases, $bouncedata, $comm, $data, $i, $mess, $ok);

  # Extract mailbox and comment, transform and aliases
  $out{strip}   = $addr->strip;
  $out{comment} = $addr->comment;
  $out{xform}   = $addr->xform;
  $out{alias}   = $addr->alias;
  $out{aliases} = [$self->_alias_reverse_lookup($addr, 0)];

  # Registration data
  $data = $self->{'reg'}->lookup($addr->canon);
  return (1, \%out) unless $data;
  $out{regdata} = {
		   fulladdr   => $data->{'fulladdr'},
		   stripaddr  => $data->{'stripaddr'},
		   language   => $data->{'language'},
		   data1      => $data->{'data1'},
		   data2      => $data->{'data2'},
		   data3      => $data->{'data3'},
		   data4      => $data->{'data4'},
		   data5      => $data->{'data5'},
		   regtime    => $data->{'regtime'},
		   changetime => $data->{'changetime'},
		   lists      => [split("\002", $data->{'lists'})],
		  };

  # Lists
  for $i (split("\002", $data->{'lists'})) {
    next unless $self->_make_list($i);

    # Get membership info with no aliasing (since we already did it all)
    (undef, $data) = $self->{'lists'}{$i}->get_member($addr);

    # It is possible that the registration database is hosed, and the user
    # really isn't on the list.  Just skip it in this case.
    if ($data) {
      # Extract some useful data
      $out{lists}{$i} =
	{
	 fulladdr   => $data->{fulladdr},
         class      => $data->{'class'},
         flags      => $data->{'flags'},
	 classdesc  => $self->{'lists'}{$i}->describe_class($data->{'class'},
							    $data->{'classarg'},
							    $data->{'classarg2'},
							   ),
	 subtime    => $data->{subtime},
	 changetime => $data->{changetime},
	 flagdesc   => [$self->{'lists'}{$i}->describe_flags($data->{'flags'})],
	};
      $bouncedata = $self->{lists}{$i}->bounce_get($addr);
      if ($bouncedata) {
	$out{lists}{$i}{bouncedata}  = $bouncedata;
	$out{lists}{$i}{bouncestats} = $self->{lists}{$i}->bounce_gen_stats($bouncedata);
      }
    }
  }
  (1, \%out);
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
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'list'}";
  my ($mess, $ok);
 
  if ($request->{'action'}) {
    if (! command_legal($request->{'action'})) {
      return (0, "$request->{'action'} is not a legal command."); 
    }
  }

  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }
  $self->_showtokens($request->{'list'}, $request->{'user'}, '', 
                     $request->{'mode'}, $request->{'cmdline'}, 
                     $request->{'action'});
}

sub _showtokens {
  my ($self, $list, $user, $vict, $mode, $cmd, $action) = @_;
  my $log = new Log::In 35, "$list";
  my (@tmp, @out, $data, $token);

  # We have access; open the token database and start pulling data.
  $self->_make_tokendb;
  $self->{'tokendb'}->get_start();
  while (1) {
    ($token, $data) = $self->{'tokendb'}->get(1);
    last unless $token;
    next unless $data->{'list'} eq $list || $list eq 'ALL';
    next if ($action and ($data->{'command'} ne $action)); 
    next if ($data->{'type'} eq 'delay' and $mode !~ /delay/);

    # Obtain file size
    if ($data->{'command'} eq 'post') {
      $data->{'size'} = (stat $data->{'arg1'})[7];
    }

    # Stuff the data
    push @tmp, [$token, $data];
  }
  @tmp = sort { $a->[1]->{'time'} <=> $b->[1]->{'time'} } @tmp;
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
  my ($self, $request) = @_;
  my ($ok, $error, $i, $matches_list, $mismatch, $tmp, $whereami);
  
  my $log = new Log::In  30, "$request->{'list'}, $request->{'victim'}, $request->{'mode'}";
  
  # Do a list_access_check here for the address; subscribe if it succeeds.
  # The access mechanism will automatically generate failure notices and
  # confirmation tokens if necessary.
  $whereami     = $self->_global_config_get('whereami');
  $tmp = new Mj::Addr("$request->{'list'}\@$whereami");
  $matches_list = $request->{'victim'} eq $tmp;
  # Do not add the -unsubscribe alias
  unless ($matches_list) {
    $tmp = new Mj::Addr("$request->{'list'}-unsubscribe\@$whereami");
    $matches_list = $request->{'victim'} eq $tmp;
  }

  ($ok, $error) =
    $self->list_access_check($request, 'matches_list' => $matches_list);

  unless ($ok > 0) {
    $log->message(30, "info", "noaccess");
    return ($ok, $error);
  }
  $self->_subscribe($request->{'list'}, $request->{'user'}, $request->{'victim'}, 
                    $request->{'mode'}, $request->{'cmdline'}, '', '');
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
  my ($ok, $classarg, $classarg2, $cstr, $data, $exist, $ml, $rdata, $welcome);

  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

  # Gross.  We've overloaded the mode string to specify subscriber
  # flags as well, and that mechanism is reasonably nasty as is.  But
  # we have to somehow remove modes that we know might get to us but
  # that aren't legal subscriber flags, so that make_setting() doesn't
  # yell at us.  XXX Make this a variable somewhere.
  ($cstr = $mode) =~ s/(quiet|(no)?(welcome|inform|log))[-,]?//g;

  ($ok, $flags, $class, $classarg, $classarg2) =
    $self->{'lists'}{$list}->make_setting($cstr, '');

  unless ($ok) {
    return (0, $class);
  }

  # Add to list
  ($ok, $data) =
    $self->{'lists'}{$list}->add($mode, $vict, $flags, $class, $classarg, $classarg2);

  unless ($ok) {
    $log->out("failed, existing");
    return (0, "Already subscribed as $data->{'fulladdr'}.\n");
  }

  $ml = $self->_global_config_get('password_min_length');

  # dd to/update registration database
  ($exist, $rdata) =
    $self->_reg_add($vict, 'password' => Mj::Access::_gen_pw($ml), 'list' =>
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
  return (1, [$vict]);
}

=head2 tokeninfo(..., token)

Returns all available information about a token, including the session data
(unless the mode includes "nosession").

=cut
sub tokeninfo {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'token'}";
  my ($ok, $error, $data, $sess, $spool);

  # Don't check access for now; users should always be able to get
  # information on tokens.  When we have some way to prevent lots of
  # consecutive requests, we could call the access check routine.

  # Call t_info to extract the token data hash
  ($ok, $data) = $self->t_info($request->{'token'});
  return ($ok, $data) unless ($ok > 0);

  $spool = $sess = '';
  if ($data->{'command'} eq 'post' and $request->{'mode'} eq 'full') {
    # spool file; use basename
    $spool = $data->{'arg1'};
    $spool =~ s#.+/([^/]+)$#$1#;
    $data->{'spoolfile'} = $spool;
  }
  # Pull out the session data
  if ($request->{'mode'} !~ /nosession/ && $data->{'sessionid'}) {
    ($sess) =
      $self->sessioninfo_start($data);
  }    

  # Return the lot.
  return (1, $data, $sess);
}

=head2 trigger(...)

This is the generic trigger event.  It is designed to be called somehow by
cron or an alarm in an event loop or something to perform periodic tasks
like expiring old data in the various databases, reminding token owners, or
doing periodic digest triggers.

There are two modes: hourly, daily.

=cut
use Mj::Lock;
use Mj::Digest qw(in_clock);
sub trigger {
  my ($self, $request) = @_;
  my $log = new Log::In 27, "$request->{'mode'}";
  my (@ready, $data, $key, $list, $ok, $mess, $mode, $times, $tmp);
  $mode = $request->{'mode'};
  @ready = ();

  # Right now the interfaces can't call this function (it's not in the
  # parser tables) so we don't check access on it.

  # If this is an hourly check, examine the "triggers" configuration
  # setting, and see if any of the triggers must be run.
  if ($mode =~ /^h/) {
    $times = $self->_global_config_get('triggers');
    for (keys %$times) {
       if (Mj::Digest::in_clock($times->{$_})) {
         push @ready, $_;
       }
    }
  }

  # Mode: daily or token - expire tokens and passwords, and send reminders
  if ($mode =~ /^(da|t)/ or grep {$_ eq 'token'} @ready) {
    $self->t_expire;
    $self->t_remind;
  }
  # Mode: daily or delay - complete delayed requests
  if ($mode =~ /^(da|de|h)/) {
    @req = $self->t_fulfill;
    while (@req) {
      ($key, $data) = splice @req, 0, 2;
      $times = $self->_list_config_get($data->{'list'}, 'triggers');
      next unless (exists $times->{'delay'} and
                   Mj::Digest::in_clock($times->{'delay'}));
      
      ($ok, $mess, $data, $tmp) =
        $self->t_accept($key, '', 'The request was completed after a delay', 0);
      $self->inform($data->{'list'},
                    $data->{'command'},
                    $data->{'user'},
                    $data->{'victim'},
                    $data->{'cmdline'},
                    "token-fulfill",
                    $tmp->[0], 0, 0, $mess);
    }
  }
  # Mode: daily or session - expire session data
  if ($mode =~ /^(da|s)/ or grep {$_ eq 'session'} @ready) {
    $self->s_expire;
  }
  # Mode: daily or log - expire log entries
  if ($mode =~ /^(da|l)/ or grep {$_ eq 'log'} @ready) {
    $self->l_expire;
  }
  # Loop over lists
  $self->_fill_lists;
  for $list (keys %{$self->{'lists'}}) {
    # GLOBAL and DEFAULT never have duplicate databases or members
    next if ($list eq 'GLOBAL' or $list eq 'DEFAULT');
    next unless $self->_make_list($list);

    # Mode: daily or checksum - expire checksum and message-id databases
    if ($mode =~ /^(da|c)/ or grep {$_ eq 'checksum'} @ready) {
      $self->{'lists'}{$list}->expire_dup;
    }

    # Mode: daily or bounce or vacation - expire vacation settings and bounces
    if ($mode =~ /^(da|b|v)/ or grep {$_ eq 'bounce'} @ready) {
      $self->{'lists'}{$list}->expire_subscriber_data;
    }

    # Mode: daily or post - expire post data
    if ($mode =~ /^(da|p)/ or grep {$_ eq 'post'} @ready) {
      $self->{'lists'}{$list}->expire_post_data;
    }

    # Mode: hourly or digest - issue digests 
    if ($mode =~ /^(h|di)/) {
      # Call digest-check; this will do whatever is necessary to tickle the
      # digests.
      $self->_digest($list, $request->{'user'}, 
                     $request->{'user'}, 'check', '', 'ALL');
    }
  }
  (1, '');
}


=head2 unalias(..., source)

Removes an alias pointing from one address.

This just involves looking up the stripped, transformed address in the
database, making sure that it aliases to the the user (for access checking)
and deleting it from the alias database.

=cut
sub unalias {
  my ($self, $request) = @_;
  my $log = new Log::In 27, "$request->{'victim'}";
  my ($ok, $mess, $mismatch);

  $mismatch = !($request->{'user'}->alias eq $request->{'victim'}->alias);

  ($ok, $mess) = 
    $self->list_access_check($request, 'mismatch' => $mismatch);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }

  $self->_unalias($request->{'list'}, $request->{'user'}, $request->{'victim'}, 
                  $request->{'mode'}, $request->{'cmdline'});
}

sub _unalias {
  my ($self, $list, $requ, $source, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$requ, $source";
  my ($key, $data);
  
  ($key, $data) = $self->{'alias'}->remove('', $source->xform);
  if (defined $key) {
    return (1, $key);
  }
  return (0, "$source is not aliased to $requ.\n");
}

=head2 unregister

This removes a user from the master address database.  It also deletes the
registration entry, in effect wiping the user from all databases.

=cut
sub unregister {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'victim'}";
  my ($mismatch, $ok, $regexp, $error);

  $request->{'list'} = 'GLOBAL';

  if ($request->{'mode'} =~ /regex/) {
    $mismatch = 0;
    $regexp   = 1;
    # Untaint the regexp
    $request->{'victim'} =~ /(.*)/; $request->{'victim'} = $1;
  }
  else {
    $mismatch = !($request->{'user'} eq $request->{'victim'});
    $regexp   = 0;
  }

  ($ok, $error) =
    $self->global_access_check($request, 'mismatch' => $mismatch,
                               'regexp'   => $regexp);

  unless ($ok > 0) {
    $log->message(30, "info", "$request->{'user'}:  noaccess");
    return  ($ok, $error);
  }
  $self->_unregister($request->{'list'}, $request->{'user'}, 
                     $request->{'victim'}, $request->{'mode'}, 
                     $request->{'cmdline'});

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
    return (0, "Cannot unregister $vict:  no matching addresses.");
  }

  while (($key, $data) = splice(@removed, 0, 2)) {
    $key = new Mj::Addr($key);

    # Remove from all subscribed lists
    for $l (split("\002", $data->{'lists'})) {
      next unless $self->_make_list($l);
      $self->{'lists'}{$l}->remove('', $key);
    }
    @aliases = $self->_alias_reverse_lookup($key, 1);
    for (@aliases) {
      $self->{'alias'}->remove('', $_);
    }
    push (@out, $data->{'fulladdr'});
  }

  return (1, [@out]);
}

=head2 unsubscribe(..., mode, list, address)

Perform the unsubscribe command.  This just makes some checks, then calls
the List::remove function, then builds a useful result string.

Returns a list:

 flag - truth on success
 if failure, a message, else a list of removed addresses.

=cut
sub unsubscribe {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'list'}";
  my (@out, @removed, $mismatch, $ok, $regexp, $error);

  $addr = $request->{'victim'};
  
  if ($request->{'mode'} =~ /regex/) {
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
      $log->message(30, "info", "$addr failed, invalidaddr");
      return (0, "Invalid address:\n$error");
    }
    $mismatch = !($request->{'user'} eq $addr);
    $regexp   = 0;
  }

  ($ok, $error) =
    $self->list_access_check($request, 'mismatch' => $mismatch,
                             'regexp'   => $regexp);

  unless ($ok>0) {
    $log->message(30, "info", "$addr:  noaccess");
    return ($ok, $error);
  }
   
  $self->_unsubscribe($request->{'list'}, $request->{'user'}, 
                      $request->{'victim'}, $request->{'mode'}, 
                      $request->{'cmdline'});
}

sub _unsubscribe {
  my($self, $list, $requ, $vict, $mode, $cmd) = @_;
  my $log = new Log::In 35, "$list, $vict";
  my(@out, @removed, $key, $data);

  return (0, "Unable to initialize list $list.\n")
    unless $self->_make_list($list);

  (@removed) = $self->{'lists'}{$list}->remove($mode, $vict);

  unless (@removed) {
    $log->out("failed, nomatching");
    return (0, "Cannot unsubscribe $vict: no matching addresses.");
  }

  while (($key, $data) = splice(@removed, 0, 2)) {

    # Convert to an Addr and remove the list from that addr's registration
    # entry.
    $key = new Mj::Addr($key);
    $self->_reg_remove($key, $list);
    push (@out, $data->{'fulladdr'});
  }

  return (1, [@out]);
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
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'regexp'}";
  my (@matches, $data, $err, $hits, $match, $max_hits, $max_list_hits,
      $mess, $ok, $total_hits, $list);

  $request->{'list'} = 'GLOBAL';

  # compile the pattern
  if ($request->{'mode'} =~ /regex/) {
    ($ok, $err, $request->{'regexp'}) = 
       Mj::Config::compile_pattern($request->{'regexp'}, 0);
    return (0, $err) unless $ok;
  }
  else {
    ($ok, $err, $request->{'regexp'}) = 
       Mj::Config::compile_pattern("\"$request->{'regexp'}\"", 0);
  }

  # $max_hits will equal 1 for unprivileged people if they are allowed
  # to use the which command.  Thus, the string length check is unneeded.

  # Check search string length; make sure we're not being trolled
  # return (0, "Search string too short.\n")
    # if length($string) < 3 || ($mode =~ /regex/ && length($string) < 5);

  # Check global access, to get max hit limit
  ($max_hits, $err) = $self->global_access_check($request);

  # Bomb if we're not allowed any hits
  return (0, $err)
    unless $max_hits > 0;

  $total_hits = 0;

  # Untaint
  my ($string) = $request->{'regexp'};
  $string =~ /(.*)/; $string = $1;

  # Loop over the lists that the user can see
 LIST:
  for $list 
    ($self->get_all_lists($request->{'user'}, $request->{'password'})) {
    
    # Check access for this list, 
    $request->{'list'} = $list;
    ($max_list_hits, $err) =
      $self->list_access_check($request);

    next unless $max_list_hits;

    # We are authenticated and ready to search.
    next unless $self->_make_list($list);
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
        push @matches, [undef, "-- Match limit exceeded.\n"];
        last ADDR;
      }
      else {
        push @matches, [$list, $match];
      }
      $hits++;
      $total_hits++;
    }
    $self->{'lists'}{$list}->get_done;
  }

  (1, @matches);
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
  my ($self, $request) = @_;
  $request->{'auxlist'} ||= '';
  my $log = new Log::In 30, "$request->{'list'}, $request->{'auxlist'}";
  my ($base, $ok, $error);

  $base = $request->{'command'}; $base =~ s/_start//i;

  if ($request->{'regexp'}) {
    ($ok, $error, $request->{'regexp'}) 
      = Mj::Config::compile_pattern($request->{'regexp'}, 0, "isubstring");
    return ($ok, $error) unless $ok;
  }

  ($ok, $error) = $self->list_access_check($request);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $error);
  }

  $self->{'unhide_who'} = ($ok > 1 ? 1 : 0);
  $self->_who($request->{'list'}, $request->{'user'}, '', 
              $request->{'mode'}, $request->{'cmdline'}, 
              $request->{'regexp'}, $request->{'auxlist'});
}

sub _who {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $regexp, $sublist) = @_;
  my $log = new Log::In 35, $list;
  my ($fh, $listing, $ok);
  my ($tmpl) = '';
  $listing = [];
  $sublist ||= '';

  if (($list eq 'GLOBAL' or $list eq 'DEFAULT') and (! length $sublist)) {
    $self->{'reg'}->get_start;
    if ($mode =~ /enhanced/) {
      ($tmpl) = $self->_list_file_get('GLOBAL', 'who_registry');
    }
  }
  else {
    return (0, "Unable to initialize list $list.\n")
      unless $self->_make_list($list);
    if (length $sublist) {
      return (0, "Unknown auxiliary list name \"$sublist\".")
        unless ($ok = $self->{'lists'}{$list}->valid_aux($sublist));
      $sublist = $ok;
      $self->{'lists'}{$list}->aux_get_start($sublist);
    }
    else {
      $self->{'lists'}{$list}->get_start;
    }
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

  (1, $regexp, $listing);
}

use Mj::Addr;
use Safe;
sub who_chunk {
  my ($self, $request, $chunksize) = @_;
  my $log = new Log::In 100, "$request->{'list'}, $request->{'regexp'}, $chunksize";
  my (@chunk, @out, @tmp, $addr, $i, $j, $strip);

  if (length $request->{'auxlist'}) {
    @chunk = $self->{'lists'}{$request->{'list'}}->aux_get_chunk(
               $request->{'auxlist'}, $chunksize);
  }
  # who for DEFAULT returns nothing
  elsif ($request->{'list'} eq 'DEFAULT') {
    return (0, "The DEFAULT list never has subscribers");
  }
  # who for GLOBAL will search the registry
  elsif ($request->{'list'} eq 'GLOBAL') {
    @tmp = $self->{'reg'}->get($chunksize);
    while ((undef, $i) = splice(@tmp, 0, 2)) {
      push @chunk, $i;
    }
  }
  else {
    @chunk = $self->{'lists'}{$request->{'list'}}->get_chunk($chunksize);
  }

  unless (@chunk) {
    $log->out("finished");
    return (0, '');
  }

  for $i (@chunk) {
    next if ($request->{'regexp'} 
             and !_re_match($request->{'regexp'}, $i->{'fulladdr'})); 
    # If we're to show it all...
    if ($self->{'unhide_who'}) {
      # GLOBAL has no flags or classes or bounces
      if ($request->{'list'} ne 'GLOBAL') {
        if ($request->{'mode'} =~ /bounces/) {
          next unless $i->{'bounce'};
          $i->{'bouncedata'} = $self->{'lists'}{$request->{'list'}}->_bounce_parse_data($i->{'bounce'});
          next unless $i->{'bouncedata'};
          $i->{'bouncestats'} = 
            $self->{'lists'}{$request->{'list'}}->bounce_gen_stats($i->{'bouncedata'});
          next unless ($i->{'bouncestats'}->{'month'} > 0);
        }
	$i->{'flagdesc'} =
	  join(',',$self->{'lists'}{$request->{'list'}}->describe_flags($i->{'flags'}));
	$i->{'classdesc'} =
	  $self->{'lists'}{$request->{'list'}}->describe_class($i->{'class'},
						  $i->{'classarg'},
						  $i->{'classarg2'},
						  1,
						 );
	if (($i->{'class'} eq 'nomail') && $i->{'classarg2'}) {
	  # classarg2 holds information on the original class
	  $i->{'origclassdesc'} =
	    $self->{'lists'}{$request->{'list'}}->describe_class(split("\002",
							  $i->{'classarg2'},
							  3
							 ),
						    1,
						   );
	}
      }
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
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'list'}";

  if (length $request->{'auxlist'}) {
    $self->{'lists'}{$request->{'list'}}->aux_get_done($request->{'auxlist'});
  }
  elsif ($request->{'list'} eq 'GLOBAL' or $request->{'list'} eq 'DEFAULT') {
    $self->{'reg'}->get_done;
  }
  else {
    $self->{'lists'}{$request->{'list'}}->get_done;
  }
  $self->{'unhide_who'} = 0;

  (1, '');
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


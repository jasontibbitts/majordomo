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

 ($id, $mess) = $mj->connect($interface, $sessiondata, $user);

 die "$mess" unless ($id);

 # Grab lists visible to us, their descriptions and other info
 $request = {
             'command'  => 'lists',
             'mode'     => 'full',
             'password' => $passwd,
             'user'     => $user,
             'victim'   => $user,
            };

 $result = $mj->dispatch($request);

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

@ISA = qw(Mj::Access Mj::Token Mj::MailOut Mj::Resend Mj::Inform Mj::BounceHandler);
$VERSION = "0.1200410180";
$unique = 'AAA';

use strict;
no strict 'refs';
use vars (qw($indexflags $safe $tmpdir $unique));
use Symbol;
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
use Mj::BounceHandler;
use Mj::CommandProps qw(:function :command);

#BEGIN{$AutoLoader::Verbose = 1; $Exporter::Verbose = 1;};
#BEGIN{sub UNIVERSAL::import {warn "Importing $_[0]"};};
#BEGIN{sub CORE::require {warn "Requiring $_[0]"; CORE::require(@_);};};

sub is_tainted {
  return ! eval {
    eval("#" . substr(join("", @_), 0, 0));
    1;
  };
}

=head2 domains(topdir)

Returns a list of domains served by Majordomo at a site.

=cut

sub domains {
  my $topdir = shift;
  my (@domains, $fh);

  return unless (-r "$topdir/ALIASES/mj-domains");

  $fh = gensym();
  open ($fh, "< $topdir/ALIASES/mj-domains") or return;

  while (<$fh>) {
    chomp $_;
    push @domains, $_ if (defined ($_) and -d "$topdir/$_/GLOBAL");
  }

  close $fh;
  @domains;
}

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
  my $config = shift;
  my (@domains, @tmp, $basename);

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

  $basename = $domain;  
  $basename =~ s#.+/([^/\s]+)#$1#;
  if ($basename =~ /[^A-Za-z0-9\.\-]/) {
    return qq(The domain name "$basename" is invalid.);
  }

  unless (-d $self->{'ldir'}) {
    @domains = domains($topdir);
    @tmp = grep { lc $_ eq lc $basename } @domains;
    if (defined $tmp[0] and $tmp[0] =~ /(.+)/) {
      $basename = $1;
      $self->{'ldir'} = "$topdir/$basename";
      $self->{'domain'} = $basename;
    }
    else {
      return qq(The domain "$domain" is not supported!);
    }
  }

  # Pull in the site configuration file
  $self->{'sitedata'}{'setup'} = $config; # New cf format
  $self->{'sitedata'}{'config'} = do "$topdir/SITE/config.pl";
  $log->abort("Can't find site config file $topdir/SITE/config.pl: $!")
    unless $self->{'sitedata'}{'config'};

  $self->{backend} = $self->_site_config_get('database_backend');
  $log->abort("Can't create GLOBAL list: $!")
    unless $self->_make_list('GLOBAL');
  $log->abort($self->format_error('make_list', 'GLOBAL', 'LIST' => 'DEFAULT'))
    unless $self->_make_list('DEFAULT');

  $self->{alias} = new Mj::AliasList(backend => $self->{backend},
                                      domain => $self->{domain},
                                     listdir => $self->{ldir},
                                        list => "GLOBAL",
                                        file => "_aliases");
  $log->abort("Unable to initialize GLOBAL aliases database: $!")
    unless ($self->{'alias'});

  $self->{reg}   = new Mj::RegList(backend => $self->{backend},
                                    domain => $self->{domain},
                                   listdir => $self->{ldir},
                                      list => "GLOBAL",
                                      file => "_register");
  $log->abort("Unable to initialize GLOBAL registry database: $!")
    unless ($self->{'reg'});

  # XXX Allow addresses to be drawn from the registry for delivery purposes.
  $self->{'lists'}{'GLOBAL'}->{'sublists'}{'MAIN'} = $self->{'reg'};

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

$int is the name of the interface.
$sess is a string containing all of the session info.

XXX This needs to get much more complex; reconnecting with a previous
session should now be fine, but we want to enforce timeouts and other
interesting things.

=cut

use Digest::SHA1 qw(sha1_hex);
sub connect {
  my $self = shift;
  my $int  = shift;
  my $sess = shift;
  my $addr = shift || 'unknown@anonymous';
  my $pw   = shift || '';
  my $log = new Log::In 50, "$int, $addr";
  my (@anon_interfaces, $avars, $dir1, $dir2, $err, $expire, $id, $loc, 
      $ok, $path, $pdata, $req, $sfile, $tmp, $user);

  $user = new Mj::Addr($addr);
  # Untaint
  $int =~ /([\w-]+)/;
  $self->{'interface'} = $1;
  $self->{'sessionid'} = '';
  @anon_interfaces = ('owner', 'resend', 'shell', 'wwwconfirm',
                      'wwwadm', 'wwwusr');

  unless (grep { $_ eq $int } @anon_interfaces) {
    if (! defined $user) {
      ($ok, $err) = (0, $self->format_error('undefined_address', 'GLOBAL'));
    }
    else {
      ($ok, $err, $loc) = $user->valid;
      unless ($ok) {
        $tmp = $self->format_error($err, 'GLOBAL');
        $err = $self->format_error('invalid_address', 'GLOBAL', 
                                   'ADDRESS' => $addr, 'ERROR' => $tmp,
                                   'LOCATION' => $loc);
      }
    }

    unless ($ok) {
      $self->inform('GLOBAL', 'connect', $addr, $addr, 'connect',
                    $int, $ok, '', 0, $err, $::log->elapsed);
      return (undef, $err);
    }
  }

  $self->{sessionuser} = $user;

  # If a temporary password was supplied, check to see if it represents
  # a session that is still valid, and append the session information
  # to the appropriate file instead of creating a new file.
  if ($self->t_recognize($pw)) {
    $self->_make_latchkeydb;
    if (defined $self->{'latchkeydb'}) {
      $pdata = $self->{'latchkeydb'}->lookup($pw);
      if (defined $pdata) {
        if (time <= $pdata->{'expire'}) {
          $id = $pdata->{'sessionid'};
        }
      }
    }
  }
  # If the session number of an existing session was provided,
  # save results in that session file.
  elsif ($self->s_recognize($pw)) {
    $id = $pw;
  }

  unless (defined $id) {
    # Generate a session ID; hash the session, the time and the PID
    $id = sha1_hex($sess.scalar(localtime).$$);
  }

  $id =~ /(.*)/; $id = $1; # Safe to untaint because it's nearly impossible
                           # to leak information through the digest
                           # algorithm.

  ($self->{sessionid}, $sfile, $dir1, $dir2) =
    $self->s_recognize($id, 'nocheck');

  close $self->{'sessionfh'} if (exists $self->{'sessionfh'});
  $self->{sessionfh} = gensym();

  # Create directories if necessary, and open the session file;
  mkdir($dir1, 0777);
  mkdir($dir2, 0777);
  unless (open ($self->{sessionfh}, ">>$sfile")) {
    # Directory might just have been deleted due to expiry; try again.
    # This assumes that there is only one process doing expiry, so our
    # directories can't be deleted twice.
    unless (mkdir($dir1, 0777)) {
      warn "Can't mkdir $dir1: $!";
    }
    unless (mkdir($dir2, 0777)) {
      warn "Can't mkdir $dir2: $!";
    }
    $log->abort("Can't write session file to $sfile, $!")
      unless (open ($self->{sessionfh}, ">>$sfile"));
  }

  # Autoflush
  select((select($self->{sessionfh}), $| = 1)[0]);

  # Do not log "Approved:" passwords
  $sess =~ s/^(approved:[ \t]*)(\S+)/$1PASSWORD/gim;

  print {$self->{sessionfh}} "Source: $int\n";
  print {$self->{sessionfh}} "PID:    $$\n\n";
  print {$self->{sessionfh}} "$sess\n";

  if ($int =~ /^email/ or $int eq 'request') {
    ($ok, $err) = $self->check_headers($sess);
    $avars = $err if ($ok);
  }
  else {
    $ok = 1;
    $avars = { 'reasons' => [] };
  }

  # Now check if the client has access.  (Didn't do it earlier because we
  # want to save the session data first.)
  $req = {
          'command' => 'access',
          'delay'   => 0,
          'list'    => 'GLOBAL',
          'user'    => $user,
         };

  if ($ok) {
    ($ok, $err) = $self->list_access_check($req, %$avars);
  }

  # If the access check failed we tell the client to sod off.  Clearing the
  # sessionid prevents further actions.
  unless ($ok > 0) {
    $self->inform('GLOBAL', 'connect', $user, $user, 'connect',
                  $int, $ok, '', 0, $err, $::log->elapsed);
    if (exists $self->{'sessionfh'}) {
      close $self->{sessionfh};
      undef $self->{sessionfh};
    }
    undef $self->{sessionid};
    return (undef, $err);
  }

  # Determine the session expiration time.
  $expire = $self->_global_config_get('session_lifetime') || 0;
  if ($expire >= 0) {
    $expire *= 86400;
    $expire += time;
  }

  return wantarray ? ($id, $user->strip, $expire) : $id;
}

=head2 dispatch(request, extra)

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

  noaddr - true if no address parsing should be done.  Normally the
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
  my (@addr, @canon, @modes, @res, @tmp, $addr, $base_fun, $comment,
      $continued, $data, $elapsed, $func, $l, $loc, $modelist, $mess, 
      $ok, $out, $over, $sl, $tmp, $validate);
  my $level = 29;
  $level = 500 if ($request->{'command'} =~ /_chunk$/);

  ($base_fun = $request->{'command'}) =~ s/_(start|chunk|done)$//;
  $continued = 1 if $request->{'command'} =~ /_(chunk|done)/;

  $request->{'cgidata'}  ||= '';
  $request->{'cgiurl'}   ||= '';
  $request->{'delay'}    ||= 0;
  $request->{'list'}     ||= 'GLOBAL';

  # Sanitize the mode
  $request->{'mode'}     ||= '';
  $request->{'mode'}       = lc $request->{'mode'};
  $request->{'password'} ||= '';
  $request->{'sublist'}  ||= '';
  $request->{'user'}     ||= 'unknown@anonymous';
  $request->{'victim'}   ||= '';

  my $log  = new Log::In $level, "$request->{'command'}, $request->{'user'}";

  $log->abort('Not yet connected!') unless $self->{'sessionid'};

  unless (function_legal($request->{'command'})) {
    return [0, $self->format_error('invalid_command', 'GLOBAL',
                                   'COMMAND' => $request->{'command'})];
  }

  # Catenate list and sublist for validity checks.
  $l = $request->{'list'};
  if (length $request->{'sublist'}) {
    $l =~ s/:.*$//;
    $l .= ":$request->{'sublist'}";
  }

  if (command_prop($base_fun, 'list') and
      $request->{'command'} !~ /_chunk$/) {
    ($l, $sl, $mess) =
      $self->valid_list($l, command_prop($base_fun, 'all'),
                        command_prop($base_fun, 'global'));

  }
  else {
    ($l, $sl, $mess) = $self->valid_list($l, 1, 1);
  }

  return [0, $mess]
    unless $l;

  # Untaint
  $request->{'list'} = $l;

  $request->{'sublist'} = $sl if (length $sl);
  $request->{'time'} ||= $::log->elapsed;

  # The command mode can only have letters, hyphens, and equals signs.
  if ($request->{'mode'} =~ /[^a-z=-]/) {
    @modes = sort keys %{function_prop($request->{'command'}, 'modes')};
    return [0, $self->format_error('invalid_mode', $request->{'list'},
               'MODE' => $request->{'mode'},
               'MODES' => \@modes)];
  }
  elsif ($request->{'mode'} =~ /([a-z=-]+)/) {
    # Untaint
    $request->{'mode'} = $1;
  }
  else {
    $request->{'mode'} = '';
  }

  # Test the command mode against the list of acceptable modes
  # from Mj::CommandProps.
  $request->{'modes'} ||= {};
  if ($request->{'mode'} and !$continued) {
    @tmp = split /[=-]/, $request->{'mode'};
    $modelist = function_prop($request->{'command'}, 'modes');
    @modes = sort keys %$modelist;
    for $l (@tmp) {
      @canon = grep { $l =~ /^$_/ } @modes;
      unless (scalar @canon) {
        return [0, $self->format_error('invalid_mode', $request->{'list'},
                   'MODE' => $l,
                   'MODES' => \@modes)];
      }
      unless (length($l) < 12) {
        return [0, $self->format_error('invalid_mode', $request->{'list'},
                   'MODE' => $l,
                   'MODES' => \@modes)];
      }
      if (ref $modelist->{$canon[0]}) {
        if (exists $modelist->{$canon[0]}->{'include'}) {
          unless ($request->{'mode'} =~ /(^|\b)$modelist->{$canon[0]}->{'include'}/) {
            return [0, $self->format_error('missing_mode', $request->{'list'},
                         'MODE' => $l,
                         'MODES' => [split "\\|", $modelist->{$canon[0]}->{'include'}],)
                   ];
          }
        }
        if (exists $modelist->{$canon[0]}->{'exclude'}) {
          if ($request->{'mode'} =~ /(^|\b)$modelist->{$canon[0]}->{'exclude'}/) {
            return [0, $self->format_error('incompatible_mode', $request->{'list'},
                     'MODE' => $l,
                     'MODES' => [split "\\|", $modelist->{$canon[0]}->{'exclude'}],)
                   ];
          }
        }
      }
      $request->{'modes'}{$canon[0]} = 1;
    }
  }

  # Turn some strings into addresses and check their validity; never with a
  # continued function (they never need it) and only if the function needs
  # validated addresses.
  $validate = 1;
  if (function_prop($request->{'command'}, 'noaddr') or $continued) {
    $validate = 0;
  }

  # Validate the address responsible for the request.
  $addr = $request->{'user'};
  $request->{'user'} = new Mj::Addr($addr);
  if ($validate) {
    if (! defined $request->{'user'}) {
      ($ok, $mess) = (0, $self->format_error('undefined_address', 'GLOBAL'));
    }
    else {
      ($ok, $mess, $loc) = $request->{'user'}->valid;
      unless ($ok) {
        $tmp = $self->format_error($mess, 'GLOBAL');
        $mess = $self->format_error('invalid_address', 'GLOBAL', 
                                    'ADDRESS' => $addr, 'ERROR' => $tmp,
                                    'LOCATION' => $loc);
      }
    }
    return [0, $mess] unless $ok;
  }

  # Each of the victims must be verified.
  if (exists ($request->{'victims'}) and
      @{$request->{'victims'}} and
      $request->{'mode'} !~ /regex|pattern/)
  {
    while (@{$request->{'victims'}}) {
      $addr = shift @{$request->{'victims'}};
      next unless $addr;
      $addr =~ s/^\s+//;
      $addr =~ s/\s+$//;
      $addr = new Mj::Addr($addr);
      push (@addr, $addr);
    }
    $request->{'victims'} = [@addr];
  }

  if (exists ($request->{'victims'}) and @{$request->{'victims'}}) {
    @addr = @{$request->{'victims'}};
  }
  else {
    @addr = ($request->{'user'});
  }

  # Check for suppression of logging and owner information
  if ($request->{'mode'} =~ /nolog/) {
    # This is serious; user must use a domain-level password.
    $ok = $self->validate_passwd($request->{'user'}, $request->{'password'},
				                 'GLOBAL', 'ALL', 1);
    return [0, $self->format_error('password_level', $request->{'list'},
                                   'MODE'    => 'nolog',
                                   'SETTING' => '',
                                   'LEVEL'   => $ok,
                                   'NEEDED'  => 3,
                                   'USER'    => "$request->{'user'}")]
      unless $ok > 0;
    $over = 2;
  }
  elsif ($request->{'mode'} =~ /noinform/) {
    $ok = $self->validate_passwd($request->{'user'}, $request->{'password'},
                                 $request->{'list'}, 'config_inform');
    return [0, $self->format_error('password_level', $request->{'list'},
                                   'MODE'    => 'noinform',
                                   'SETTING' => '',
                                   'LEVEL'   => $ok,
                                   'NEEDED'  => 1,
                                   'USER'    => "$request->{'user'}")]
      unless $ok > 0;
    $over = 1;
  }
  else {
    $over = 0;
  }

  # Make a separate request for each affected address.
  for $addr (@addr) {
    $request->{'victim'} = $addr;
    if ($validate and $request->{'mode'} !~ /regex|pattern/) {
      if (! defined $addr) {
        ($ok, $mess) = (0, $self->format_error('undefined_address', 'GLOBAL'));
      }
      else {
        ($ok, $mess, $loc) = $addr->valid;
        unless ($ok) {
          $tmp = $self->format_error($mess, 'GLOBAL');
          $mess = $self->format_error('invalid_address', 'GLOBAL', 
                                      'ADDRESS' => "$addr", 'ERROR' => $tmp,
                                      'LOCATION' => $loc);
        }
      }
      unless ($ok) {
        push @$out, (0, $mess);
        next;
      }
    }
    gen_cmdline($request) unless ($request->{'command'} =~ /_chunk|_done/);
    if (function_prop($request->{'command'}, 'top')) {
      $func = $request->{'command'};
      @res = $self->$func($request, $extra);
      push @$out, @res;
    }
    else {
      # Last resort; we found _nothing_ to call
     return [0, $self->format_error('invalid_command', 'GLOBAL',
                                    'COMMAND' => $request->{'command'})];
    }

    $comment = '';
    # owner_done returns the address of the originator,
    # and bouncing addresses if any were identified.
    if ($base_fun eq 'owner' and $res[1]) {
      if ($request->{'command'} eq 'owner_done' and length $res[1]) {
        if (ref $res[3] eq 'ARRAY' and scalar @{$res[3]}) {
          $mess = " from " . join(" ", @{$res[3]});
        }
        else {
          $mess = '';
        }

        if ($res[1] eq 'P') {
          $base_fun = 'probebounce';
        }
        elsif ($res[1] eq 'D' or $res[1] eq 'T') {
          $base_fun = 'tokenbounce';
        }
        else {
          $base_fun = 'bounce';
        }
        $request->{'cmdline'} = "($base_fun message$mess)";
      }
    }
    else {
      # Obtain the comment for failed and stalled actions.
      $comment = $res[1] if (defined $res[1] and $res[0] < 1);
    }

    # Inform on post_done and post and owner_done,
    # but not on post_start or owner_start.
    $over = 2 if ($request->{'command'} eq 'post_start' or
                  $request->{'command'} eq 'owner_start' or
                  ($request->{'command'} =~ /_start$/ and $res[0] == 1));

    # Inform unless overridden or continuing an iterator
    unless ($over == 2 ||
            $request->{'command'} =~ /_chunk$/) {
      $elapsed = $::log->elapsed - $request->{'time'};
      # XXX How to handle an array of results?
      $self->inform($request->{'list'}, $base_fun, $request->{'user'},
                    $request->{'victim'}, $request->{'cmdline'},
                    $self->{'interface'}, $res[0],
                    !!$request->{'password'}+0, $over, $comment, $elapsed);

      # reset timer in case multiple commands are being issued.
      $request->{'time'} = $::log->elapsed;
    }
  }
  $out;
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
                 domain    => $self->{domain},
		 backend   => $self->{backend},
		 callbacks =>
		 {
		  'mj._list_file_get' =>
		  sub { $self->_list_file_get(@_) },
		  'mj._global_config_get' =>
		  sub { $self->_global_config_get(@_) },
		  'mj._list_config_search' =>
		  sub { $self->_list_config_search(@_) },
		  'mj._list_file_get_string' =>
		  sub { $self->_list_file_get_string(@_) },
		  'mj.valid_list' =>
		  sub { $self->valid_list(@_) },
		 },
		);
  return unless $tmp;
  $self->{'lists'}{$list} = $tmp;

  1;
}

use AutoLoader 'AUTOLOAD';
1;
__END__

=head1 Utility functions

These functions are called from various places in the code to do verious
small tasks.

=head2 get_all_lists(user, passwd, regexp)

This grabs all of the lists that are accessible by the user
and that match the regular expression, and returns them in an array.

=cut

sub get_all_lists {
  my ($self, $user, $passwd, $regexp) = @_;
  my $log = new Log::In 100;
  my (@lists, $always, $list, $ok, $req);

  $user = new Mj::Addr($user);
  $self->_fill_lists;
  $always = $self->_global_config_get('advertise_subscribed');

  $list = '';

  if ($regexp) {
    require Mj::Util;
    import Mj::Util qw(re_match);
  }

  for $list (keys %{$self->{'lists'}}) {
    next if ($list eq 'GLOBAL' or $list eq 'DEFAULT');
    if ($regexp) {
      next unless re_match($regexp, $list);
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

    ($ok) = $self->list_access_check($req, 'nostall' => 1);
    push (@lists, $list) if $ok;
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

=head2 gen_cmdline(request)

This routine derives the command line from a request hash.
The command line is displayed in the logs and in
acknowledgement messages such as confirmation requests.

The request hash is altered to contain the command line
in $request->{'cmdline'}.

This routine relies on information from Mj::CommandProps
to determine how a command is parsed.

=cut

sub gen_cmdline {
  my $request = shift;
  my (@tmp, $arguments, $base, $cmdline, $hereargs, $variable);

  return unless (ref $request eq 'HASH');
  if ($request->{'command'} =~ /owner/) {
    if ($request->{'list'} =~ /GLOBAL|DEFAULT|ALL/) {
      $request->{'cmdline'} = "(message to majordomo-owner)";
    }
    else {
      $request->{'cmdline'} = "(message to $request->{'list'}-owner)";
    }
    return 1;
  }
  if ($request->{'command'} =~ /post/) {
    if (length($request->{'sublist'}) and $request->{'sublist'} ne 'MAIN') {
      $request->{'cmdline'} = "(post to $request->{'list'}:$request->{'sublist'})";
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
  if (length $request->{'mode'}) {
    $cmdline .= "-$request->{'mode'}";
  }
  # Add LIST if the command requires one
  if (command_prop($base, "list")) {
    $cmdline .= " $request->{'list'}";
    if (exists ($request->{'sublist'}) and
        length ($request->{'sublist'}) and
        ($request->{'sublist'} ne 'MAIN'))
    {
      $cmdline .= ":$request->{'sublist'}";
    }
  }

  $hereargs  = function_prop($base, 'hereargs');
  $arguments = function_prop($base, 'arguments');

  if (defined $arguments) {
    for $variable (sort keys %$arguments) {
      # "split" is a pattern used to separate arguments in some commands.
      next if ($variable eq 'split');

      # exclude and include arrays are used in Mj::CommandProps.pm
      # to distinguish arguments that may be present or absent
      # depending upon the command mode.
      next if (exists $arguments->{$variable}->{'include'}
               and $request->{'mode'} !~ /$arguments->{$variable}->{'include'}/);
      next if (exists $arguments->{$variable}->{'exclude'}
               and $request->{'mode'} =~ /$arguments->{$variable}->{'exclude'}/);

      # a new password should never be displayed
      if ($variable eq 'newpasswd') {
        # The misnomer is due to a 3-argument limit in the token db.
        if ($base eq 'createlist' and $request->{'mode'} =~ /rename/) {
          # show new list name
          $cmdline .= " $request->{'newpasswd'}";
        }
        else {
          $cmdline .= " PASSWORD";
        }
        next;
      }

      if ($variable eq 'victims' and defined $request->{'victim'}) {
        $cmdline .= " $request->{'victim'}";
        next;
      }

      if ($variable eq 'tokens' and scalar @{$request->{'tokens'}}) {
        $cmdline .= " $request->{'tokens'}->[0]";
        last;
      }

      last if (defined $hereargs and ($variable eq $hereargs));
      if (exists $request->{$variable} and $arguments->{$variable} ne 'ARRAY') {
        $cmdline .= " $request->{$variable}"
          if (defined $request->{$variable} and length $request->{$variable});
      }
    }
  }
  $request->{'cmdline'} = $cmdline;
  1;
}

=head2 standard_subs(list)

This routine returns a hash of a standard set of variable
substitutions, used in various places in the Mj modules.

=cut

sub standard_subs {
  my $self = shift;
  my $olist = shift;

  my ($all_footers, $all_fronters, $curl, $footer, $footers, $fronter,
      $fronters, $i, $list, $random_footer, $random_fronter, $sublist,
      $whereami, $whoami);

  ($olist, $sublist) = $self->valid_list($olist, 1, 1);
  if (! (defined $olist and length $olist)) {
    $list = 'GLOBAL';
    $olist = '';
    $sublist = '';
  }
  else {
    $list = $olist;
  }

  $whereami  = $self->_global_config_get('whereami');

  if ($list =~ /^DEFAULT/ or $list eq 'GLOBAL') {
    $whoami = $self->_global_config_get('whoami');
  }
  elsif (length $sublist) {
    $whoami = "$list-$sublist\@$whereami";
  }
  else {
    $whoami = $self->_list_config_get($list, 'whoami');
  }

  $curl = $self->_global_config_get('confirm_url');

  my %subs = (
    'ARCURL'      => $self->_list_config_get($list, 'archive_url'),
    'CONFIRM_URL' => $self->substitute_vars_string(
                       $curl, {'TOKEN' => ''}),
    'DATE'        => scalar localtime,
    'DOMAIN'      => $self->{'domain'},
    'LIST'        => length $sublist ? "$olist:$sublist" : $olist,
    'MAJORDOMO'   => $self->_global_config_get('whoami'),
    'MJ'          => $self->_global_config_get('whoami'),
    'MJOWNER'     => $self->_global_config_get('whoami_owner'),
    'OWNER'       => $self->_list_config_get($list, 'whoami_owner')
                     || $self->_global_config_get('whoami_owner'),
    'PLIST'       => $olist,
    'PWLENGTH'    => $self->_global_config_get('password_min_length') || 6,
    'REQUEST'     => ($list eq 'GLOBAL' or $list eq 'DEFAULT') ?
                     $whoami :
                     "$list-request\@$whereami",
    'SITE'        => $self->_global_config_get('site_name'),
    'SUBLIST'     => $sublist,
    'UCLIST'      => length $sublist ? uc("$olist:$sublist") : uc($olist),
    'VERSION'     => $Majordomo::VERSION,
    'WHEREAMI'    => $whereami,
    'WHOAMI'      => $whoami,
    'WWWADM_URL'  => $self->_global_config_get('wwwadm_url'),
    'WWWUSR_URL'  => $self->_global_config_get('wwwusr_url'),
  );

  $fronters = $self->_list_config_get($list, 'message_fronter') || [];
  $footers  = $self->_list_config_get($list, 'message_footer')  || [];
  $all_fronters = $all_footers = '';
  for $i (@$fronters) { $all_fronters .= join("\n", @$i, '', ''); }
  for $i (@$footers)  { $all_footers  .= join("\n", @$i, '', ''); }
  chomp $all_fronters; chomp $all_fronters;
  chomp $all_footers;  chomp $all_footers;

  $fronter = $self->substitute_vars_string
    (@$fronters ? join("\n", @{$fronters->[0]}) : '',
     \%subs,
    );
  $footer = $self->substitute_vars_string
    (@$footers ? join("\n", @{$footers->[0]}) : '',
     \%subs,
    );

  $random_fronter = $self->substitute_vars_string
    (@$fronters ? join("\n", @{@$fronters[rand(@$fronters)]}) : '',
     \%subs,
    );
  $random_footer = $self->substitute_vars_string
    (@$footers  ? join("\n", @{@$footers[rand(@$footers)]})   : '',
     \%subs,
    );
  $all_fronters = $self->substitute_vars_string($all_fronters, \%subs);
  $all_footers  = $self->substitute_vars_string($all_footers,  \%subs);

  $subs{FRONTER} = $fronter;
  $subs{FOOTER}  = $footer;
  $subs{RANDOM_FRONTER} = $random_fronter;
  $subs{RANDOM_FOOTER}  = $random_footer;
  $subs{ALL_FRONTERS}   = $all_fronters;
  $subs{ALL_FOOTERS}    = $all_footers;

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
  $in  = gensym();
  open ($in, "< $file")
    or $::log->abort("Cannot read file $file: $!");

  # open a new output file if one is not already open (should be at $depth of 0)
  $tmp = $tmpdir;
  $tmp = "$tmp/mj-tmp." . unique();
  unless (defined $out) {
    $out = gensym();
    open ($out, "> $tmp") or
      $::log->abort("Cannot write to file $tmp: $!");
  }

  while (defined ($i = <$in>)) {
    if ($i =~ /([^\\]|^)\$INCLUDE-(.*)$/) {
      # Do a _list_file_get.  If we get a file, open it and call
      # substitute_vars on it, printing to the already opened handle.  If
      # we don't get a file, print some amusing text.
      $inc = $2; $inc =~ s/\s*$//;
      ($inc) =  $self->_list_file_get(list => $list, file => $inc);

      if ($inc) {
	if ($depth > 3) {
	  print $out "Recursive inclusion depth exceeded\n ($depth levels: may be a loop, now reading $2)\n"; #XLANG
	}
	else {
	  # Got the file; substitute in it, perhaps recursively
	  $self->substitute_vars($inc, $subs, $list, $out, $depth+1);
	}
      }
      else {
	warn "Include file $2 not found.";
	print $out $self->format_error('no_file', 'GLOBAL', 'FILE' => $2);
      }
      next;
    }
    $i = $self->substitute_vars_string($i, $subs);
    print $out $i;
  }

  # always close the INPUT file
  close ($in);
  # Only close the OUTPUT file at zero depth - else recursion 
  # gives a 'print to closed file handle' error.
  # The file handle will be closed automatically when the variable goes 
  # out of scope.
  close ($out) if (!$depth); 
  $tmp;
}

=head2 substitute_vars_format(string, subhashref)

This substitutes embedded variables in a string, one line at a time.

It allows for the repetition of substitutions when a
substitution value is an array reference instead of
a scalar value.

=cut

sub substitute_vars_format {
  my $self = shift;
  my $str  = shift;
  my $subs = shift;
  my $log = new Log::In 250;
  my (%subcount, @ghost, @lines, @out, @table,
      $ghost, $helpurl, $i, $j, $line, $maxiter, $value);

  return unless $str;
  return unless (ref $subs eq 'HASH');

  # Count the elements in the largest of the listrefs in the substitution hash
  $maxiter = 1;

  # HELP substitution hack
  if ($self->{'interface'} =~ /^www/) {
    $i = $self->_global_config_get('www_help_window');
    $j = $i ? ' target="mj2help"' : '';
    $helpurl =
      q(<a href="$CGIURL?$CGIDATA&amp;list=$LIST&amp;func=help&amp;extra=%s"%s>%s</a>);
  }
  else {
    $helpurl = '%s';
    $j = '';
  }

  # Make initial substitution for HELP:TOPIC
  while ($str =~ /([^\\]|^)\$HELP:([A-Z_]+)/m) {
    $line = $1 . sprintf($helpurl, lc $2, $j, lc $2);
    $str =~ s/([^\\]|^)\$HELP:([A-Z_]+)/$line/m;
  }

  # The ghost is a copy of the initial string without any of
  # the scalar substitution variables.  It is used to ease
  # iteration for array values.
  #
  # Newlines are replaced to maintain alignment between the 
  # original and the ghost after substitution.

  $str =~ s/\n/\002\001/g;
  $ghost = $str;

  # Track the number of data elements in each substitution value
  for $i (keys %$subs) {
    if (! ref $subs->{$i}) {
      # handle simple substitutions immediately
      if (defined $subs->{$i} and length $subs->{$i}) {
        while ($str =~ /([^\\]|^)(\$|\?)\Q$i\E(:-?\d+)?(?![A-Z_])/m) {
          $value = defined $3 ? "%$3s" : "%s";
          $value =~ s/://s;
          $line = sprintf $value, $subs->{$i};
          $str =~ s/([^\\]|^)(\$|\?)\Q$i\E(:-?\d+)?(?![A-Z_])/$1$line/m;
        }
      }
      # empty value: mark for line-by-line processing
      else {
        while ($str =~ /([^\\]|^)\$\Q$i\E(:-?\d+)?(?![A-Z_])/m) {
          $value = defined $2 ? "%$2s" : "%s";
          $value =~ s/://;
          $line = sprintf $value, $subs->{$i};
          $str =~ s/([^\\]|^)\$\Q$i\E(:-?\d+)?(?![A-Z_])/$1$line/m;
        }
        next unless ($str =~ /([^\\]|^)(\?)\Q$i\E(:-?\d+)?(?![A-Z_])/m);
        $subcount{$i} = 1;
      }
    }
    elsif (ref ($subs->{$i}) eq 'ARRAY')  {
      next unless ($str =~ /([^\\]|^)(\$|\?)\Q$i\E(:-?\d+)?(\b|$)/m);
      $value = scalar @{$subs->{$i}};
      $maxiter = $value if ($value > $maxiter);
      $subcount{$i} = $value;
    }
    else {
      warn ("The $i substitution is a " . ref($subs->{$i}) . 
            " reference.\n");
      next;
    }
  }

  # if no arrays are present, restore newlines and return.
  unless (keys %subcount) {
    $str =~ s/\\\$/\$/g;
    $str =~ s/\002\001/\n/g;
    return $str;
  }

  # substitute in the ghost with empty values if arrays are present.
  for $i (keys %$subs) {
    last unless $maxiter > 1;
    if (! ref $subs->{$i}) {
      if (defined $subs->{$i} and length $subs->{$i}) {
        while ($ghost =~ /([^\\]|^)(\$|\?)\Q$i\E(:-?\d+)?(?![A-Z_])/m) {
          $value = defined $3 ? "%$3s" : "%s";
          $value =~ s/://;
          $line = sprintf $value, " ";
          $ghost =~ s/([^\\]|^)(\$|\?)\Q$i\E(:-?\d+)?(?![A-Z_])/$1$line/m;
        }
      }
      else {
        while ($ghost =~ /([^\\]|^)\$\Q$i\E(:-?\d+)?(?![A-Z_])/m) {
          $value = defined $2 ? "%$2s" : "%s";
          $value =~ s/://;
          $line = sprintf $value, " ";
          $ghost =~ s/([^\\]|^)\$\Q$i\E(:-?\d+)?(?![A-Z_])/$1$line/m;
        }
      }
    }
  }

  # Build the substitution table.  Each value is depleted as it is
  # used.  As a result, if a line is repeated more than once, a
  # substitution value that has only one element will appear only
  # in the first iteration.
  #
  # Consider the lists command, and a line that looks like
  #   $LIST $DESCRIPTION
  # If the description is eight lines long, in the output, the
  # name of the mailing list will only appear on the first of
  # the eight lines.
  #
  for ($i = 0 ; $i < $maxiter ; $i++) {
    $table[$i] = {};
    for $value (keys %subcount) {
      if ($i + 1 > $subcount{$value}) {
        $table[$i]->{$value} = '';
      }
      elsif (ref $subs->{$value}) {
        $table[$i]->{$value} = $subs->{$value}->[$i];
      }
      else {
        $table[$i]->{$value} = $subs->{$value};
      }
    }
  }


  @lines = split "\002\001", $str;
  @ghost = split "\002\001", $ghost;
  # Split the input string into lines, and make substitutions
  # on each line.
  LINE:
  for ($j = 0; $j < @lines ; $j++) {
    $line = $lines[$j];
    $ghost = $ghost[$j];
    if ($line !~ /[\?\$][A-Z]/) {
      $line =~ s/\\\$/\$/g;
      push @out, $line;
      next;
    }
    $maxiter = 1;
    for $i (keys %subcount) {
      # Variables starting with question marks will cause
      # the line to be ignored if the variable is unset.
      if ($line =~ /([^\\]|^)\?\Q$i\E(?![A-Z_])/m) {
        if ($table[0]->{$i} eq '') {
          next LINE;
        }
        # Convert the ? to $.
        $line =~ s/([^\\]|^)\?\Q$i\E(?![A-Z_])/$1\$$i/gm;
        $ghost =~ s/([^\\]|^)\?\Q$i\E(?![A-Z_])/$1\$$i/gm;
      }
      if ($line =~ /([^\\]|^)\$\Q$i\E(:-?\d+)?(?![A-Z_])/m) {
        $maxiter = $subcount{$i} if ($subcount{$i} > $maxiter);
      }
    }
    for ($i = 0 ; $i < $maxiter ; $i++) {
      $line = $ghost if ($i == 1);
      push @out, $self->substitute_vars_string($line, $table[$i]);
    }
  }

  join "\n", @out;
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
  # my $log = new Log::In 250;
  my ($format, $i, $value);

  if (ref $str eq 'ARRAY') {
    for (@$str) {
      # Perform a recursive substitution
      $_ = $self->substitute_vars_string($_, $subs);
    }
    return $str;
  }

  for $i (keys %$subs) {
    # Don't substitute after backslashed $'s
    while ($str =~ /([^\\]|^)\$\Q$i\E(:-?\d+)?(\b|$)/gm) {
      $format = defined $2 ? "%$2s" : "%s";
      $format =~ s/://s;
      $value = sprintf $format, $subs->{$i};
      $str =~ s/([^\\]|^)\$\Q$i\E(:-?\d+)?(\b|$)/$1$value/m;
    }
  }
  $str =~ s/\\\$/\$/g;
  $str;
}

=head2 format_error (name, list, %subs)

Format an error message in the appropriate language, with
variable substitutions as given in the third argument.

The list name is used to obtain the standard substitutions,
which are also available.

=cut

sub format_error {
  my $self = shift;
  my $name = shift;
  my $list = shift;
  my %subs = @_;
  my ($subs, $tmp, $truelist);

  unless (defined $list and length $list) {
    $list = 'GLOBAL';
  }
  # Accounts for any relocated lists
  ($truelist) = $self->valid_list($list, 1, 1);
  unless (defined $truelist and length $truelist) {
    $truelist = 'GLOBAL';
  }

  $subs = { $self->standard_subs($list),
            %subs
          };

  $tmp = $self->_list_file_get_string('list' => $truelist, 
                                      'file' => "error/$name");
  $self->substitute_vars_format($tmp, $subs);
}

=head2 record_parser_data

Add a parser event to the parser database, and return the parsed
data.

=cut

sub record_parser_data {
  my($self, $user, $time, $type, $number) = @_;
  my $log = new Log::In 150, "$user $time $number ";
  my($addr, $data, $event, $ok);

  $self->_make_parser_data;
  return unless $self->{'parserdata'};

  $addr = new Mj::Addr($user);
  return unless $addr;

  $event = "$time$type$number";
  $data = $self->{'parserdata'}->lookup($addr->canon);
  if ($data) {
    $data->{'events'} .= " $event";
    $self->{'parserdata'}->replace('', $addr->canon, $data);
  }
  else {
    $data = {};
    $data->{'events'} = $event;
    $self->{'parserdata'}->add('', $addr->canon, $data);
  }
  return $data->{'events'};
}

use Mj::SimpleDB;
sub _make_parser_data {
  my $self = shift;
  return 1 if $self->{'parserdata'};

  $self->{'parserdata'} =
    new Mj::SimpleDB(filename =>
                       $self->{'lists'}{'GLOBAL'}->_file_path("_parser"),
                     backend  => $self->{'backend'},
                     compare  => sub {reverse($_[0]) cmp reverse($_[1])},
                     fields   => [qw(events changetime)],
                    );
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
  my ($data, $i, $ok, $sub);

  # Look up the user
  $data = $self->{reg}->lookup($addr->canon);

  # If the entry doesn't exist, we need to generate a new one.
  unless ($data) {
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

    for $i (qw(regtime password language lists flags bounce warnings
               data1 data2 data3 data4 data5)) {
      $data->{$i} = $args{$i} if (defined $args{$i});
    }
    if ($args{'list'}) {
      $data->{'lists'} = $args{'list'};
    }

    ($ok) = $self->{reg}->add('', $addr->canon, $data);
    return (0, $data) if $ok;
  }

  # Replace the data atomically to avoid a race condition.
  $sub = sub {
    my (@lists, $i, $rdata);
    $rdata = shift;

    if ($args{'update'}) {
      for $i (qw(regtime password language lists flags bounce warnings
                 data1 data2 data3 data4 data5)) {
        $rdata->{$i} = $args{$i} if (defined $args{$i});
      }
    }

    if (defined $args{'list'} and length $args{'list'}) {
      @lists = split("\002", $rdata->{'lists'});
      push (@lists, $args{'list'}) 
        unless (grep { $_ eq $args{'list'} } @lists);
      $rdata->{'lists'} = join("\002", sort @lists);
    }

    $rdata;
  };

  $self->{'reg'}->replace('', $addr->canon, $sub);

  return (1, $data);
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
  my ($i, $subs, $tmp);

  return undef unless $addr->isvalid;
  return undef if $addr->isanon;

  $tmp = $addr->retrieve('reg');
  if ($cache && $tmp) {
    return $tmp;
  }

  $reg = $self->{reg}->lookup($addr->canon) unless $reg;
  return undef unless $reg;

  $subs = {};
  for $i (split("\002", $reg->{'lists'})) {
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

  # Do not trawl the database unless the bookkeeping alias is present.
  # $data = $self->{'alias'}->lookup($addr->canon);
  # return unless $data;

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

=head2 common_subs (list, list...)

Find the subscribers that are common to more than one mailing
list, and present the data from the first list.

=cut

sub common_subs {
  my $self = shift;
  my (@tmp) = @_;
  my (%subs, @lists, $chunksize, $i, $k, $list, $mess,
      $out, $tlist, $v);
  my $log = new Log::In 150, "$tmp[0], $tmp[1]";

  $out = {};

  for $tlist (@tmp) {
    return (0, $mess)
      unless (($list, undef, $mess) = $self->valid_list($tlist, 0, 1));
    push (@lists, $list) unless ($list eq 'GLOBAL');
  }

  $self->{'reg'}->get_start;
  $chunksize = $self->_global_config_get('chunksize') || 1000;

  # Obtain registry entries.  If an entry is subscribed
  # to all of the lists, store its value in the output hashref.
  while (@tmp = $self->{'reg'}->get($chunksize)) {
    while (($k, $v) = splice @tmp, 0, 2) {
      @subs{@lists} = ();
      for $i (split("\002", $v->{'lists'})) {
        delete $subs{$i};
      }
      $out->{$k}++ unless (scalar keys %subs);
    }
  }
  $self->{'reg'}->get_done;

  (1, $out);
}

=head2 p_expire

This removes all parser database entries older that the GLOBAL
'session_lifetime' setting in days.  The parser database is
used to keep track of requests without valid commands, to prevent
mail loops.

=cut

sub p_expire {
  my $self = shift;
  my $log = new Log::In 60;
  my $days = $self->_global_config_get('session_lifetime') || 1;
  return unless (defined $days and $days >= 0);
  my $now = time;
  my ($expiretime) = $now - (86400 * $days);

  $self->_make_parser_data;
  return unless $self->{'parserdata'};

  my $mogrify = sub {
    my $key  = shift;
    my $data = shift;
    my (@b1, @b2, $b, $t);

    # Fast exit if we have no post data
    return (0, 0) if !$data->{events};

    # Expire old posted message data.
    @b1 = split(/\s+/, $data->{events});
    while (1) {
      $b = pop @b1; last unless defined $b;
      ($t) = $b =~ /^(\d+)\w/;
      next if $t < $expiretime;
      push @b2, $b;
    }
    $data->{events} = join(' ', @b2);

    # Update if necessary
    if (@b2) {
      return (0, 1, $data);
    }
    return (0, 0);
  };

  $self->{'parserdata'}->mogrify($mogrify);
}

=head2 s_expire

Miscellaneous internal function.

This removes all spooled sessions older than 'session_lifetime' days old.
Empty session directories will be deleted (except the top-level directory,
not that it could ever be empty).

=cut

use DirHandle;
sub s_expire {
  my $self = shift;
  my $dir  = shift;
#  my $log = new Log::In 60, "$dir";
  my $log = new Log::In 60 if !$dir;

  my $days = $self->_global_config_get('session_lifetime');
  return unless (defined $days and $days >= 0);

  my $now = time;
  my ($dh, $i, $nodel, $time);

  unless ($dir) {
    $dir = "$self->{ldir}/GLOBAL/sessions";
    $nodel = 1;
  }

  $dh = new DirHandle $dir;
  return unless (defined $dh);

  while (defined($i = $dh->read)) {
    next if $i eq '.' or $i eq '..';

    # Untaint the filename, so we can delete it later
    $i =~ /(.*)/; $i = $1;

    if (-d "$dir/$i") {
      $self->s_expire("$dir/$i");
      rmdir "$dir/$i" unless $nodel;
      next;
    }

    $time = (stat("$dir/$i"))[9];
    if ($time + $days*86400 < $now) {
      unlink "$dir/$i";
    }
  }
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
  $self->list_config_get($user, $passwd, 'GLOBAL', 'MAIN', $var, $raw);
}

=head2 list_config_get(user, passwd, list, var)

Retrieves the value of a list''s config variable.

Note that anyone can get a visible variable; these are available to the
interfaces for the asking.  They should not be security-sensitive in any
way.

For other variables, the standard security rules apply.

=cut

sub list_config_get {
  my ($self, $user, $passwd, $list, $sublist, $var, $raw) = @_;
  my $log = new Log::In 170, "$list, $var";
  my (@out, $i, $level, $ok);

  $sublist ||= 'MAIN';
  $list = 'GLOBAL' if ($list eq 'ALL');

  # Verify the list and sublist, and adjust the list to
  # use the appropriate configuration file.
  return unless $self->_make_list($list);
  return unless $self->{'lists'}{$list}->valid_config($sublist);
  return unless $self->_list_set_config($list, $sublist);

  # Find the level of access required to see a variable.
  $level = $self->config_get_visible($list, $var);

  # Anyone can see it if it is visible or part of a DEFAULT template.
  if ($level == 0) {
    @out = $self->_list_config_get($list, $var, $raw);
    $self->_list_set_config($list, 'MAIN');
    return wantarray ? @out : $out[0];
  }

  # Make sure we have a real user before checking passwords
  $user = new Mj::Addr($user);
  return unless $user && $user->isvalid;

  for $i ($self->config_get_groups($var)) {
    if ($i ne 'password' and $list =~ /^DEFAULT/) {
      $ok = 1; $level = 0; last;
    }
    $ok = $self->validate_passwd($user, $passwd, $list, "config_$i");
    last if $ok > 0;
  }
  unless ($ok > 0 and $level <= $ok) {
    return;
  }

  @out = $self->_list_config_get($list, $var, $raw);
  $self->_list_set_config($list, 'MAIN');
  return wantarray ? @out : $out[0];
}

=head2 list_config_set

Alters the value of a list''s config variable.  Returns a list:

 flag    - true if command succeeded
 message - to be shown to user if present

=cut

sub list_config_set {
  my ($self, $request) = @_;
  my $log = new Log::In 150, "$request->{'list'}, $request->{'setting'}";
  my (@groups, @tmp, @tmp2, $global_only, $i, $j, $join, $level, $mess, $ok);

  unless ($self->_make_list($request->{'list'})) {
    return (0, $self->format_error('make_list', 'GLOBAL',
                                   'LIST' => $request->{'list'}));
  }

  if (!defined $request->{'password'}) {
    return (0, $self->format_error('no_password', 'GLOBAL',
                                   'COMMAND' => 'configset'));
  }

  @groups = $self->config_get_groups($request->{'setting'});
  if (!@groups) {
    return (0, $self->format_error('unknown_setting', $request->{'list'},
                                   'SETTING' => $request->{'setting'}));
  }
  $level = $self->config_get_mutable($request->{'list'}, $request->{'setting'});

  # Validate passwd
  for $i (@groups) {
    $ok = $self->validate_passwd($request->{'user'},
                                 $request->{'password'},
				 $request->{'list'},
                                 "config_\U$i", $global_only);
    last if $ok >= $level;
  }
  unless ($ok >= $level) {
    $ok = $self->validate_passwd($request->{'user'},
                                 $request->{'password'},
				 $request->{'list'},
                                 "config_$request->{'setting'}", $global_only);
  }
  unless ($ok >= $level) {
    return (0, $self->format_error('password_level', $request->{'list'},
                                   'MODE'    => '',
                                   'SETTING' => $request->{'setting'},
                                   'LEVEL'   => $ok,
                                   'NEEDED'  => $level,
                                   'USER'    => "$request->{'user'}"));
  }

  # Untaint the stuff going in here.  The security implications: this
  # may (after suitable interpretation) turn into code or an eval'ed
  # regexp.  We are sure (for other reasons) do do everything in
  # suitable Safe compartments.  Besides, the generated code/regexps
  # will be saved out and read in later, at which point they will be
  # untainted for free.  This this untainting only lets us make use
  # of a variable setting in the same session that sets it without
  # failing.
  for ($i = 0; $i < @{$request->{'value'}}; $i++) {
    $request->{'value'}->[$i] =~ /(.*)/;
    $request->{'value'}->[$i] = $1;
  }

  $self->_list_set_config($request->{'list'}, $request->{'sublist'});
  @tmp = @{$request->{'value'}};
  #  Append mode:  catenate arrays and replace scalar values.
  if ($request->{'mode'} =~ /append/) {
    $join = $self->config_get_isarray($request->{'setting'});
    unless ($join) {
      # XLANG
      return (0, "Appending values to the $request->{'setting'} setting is not possible.\n");
    }
    @tmp = $self->_list_config_get($request->{'list'}, $request->{'setting'}, 1);
    if ($join == 2) {
      # Add a blank line separator (do it always, to make extraction easier.)
      push @tmp, "";
    }
    push @tmp, @{$request->{'value'}};
    # Get possible error value and print it here, for error checking.
    ($ok, $mess) =
      $self->_list_config_set($request->{'list'}, $request->{'setting'}, @tmp);
  }
  #  Extract mode:  splice values out of arrays and set scalar values to defaults.
  elsif ($request->{'mode'} =~ /extract/) {
    $join = $self->config_get_isarray($request->{'setting'});
    @tmp = $self->_list_config_get($request->{'list'},
                                   $request->{'setting'}, 1);

    if (! $join) {
      # Extraction of a scalar setting causes it to be set to its default value.
      # if the existing and desired settings are identical.
      if ($tmp[0] eq $request->{'value'}->[0]) {
        ($ok, $mess) =
          $self->{'lists'}{$request->{'list'}}->
            config_set_to_default($request->{'setting'});
      }
      else {
        $ok = 0;
        $mess = $self->format_error('not_extracted', $request->{'list'},
                                    'SETTING'  => $request->{'setting'},
                                    'EXPECTED' => $request->{'value'}->[0],
                                    'VALUE'    => $tmp[0]);
      }
    }
    # Impossible to splice an array out of a smaller array.
    elsif ($#{$request->{'value'}} > $#tmp) {
      $ok = 0;
      $mess = "The $request->{'setting'} setting\n"
             ."does not contain the value you specified"; #XLANG
    }
    else {
      for ($i = 0; $#{$request->{'value'}} + $i <= $#tmp ; $i++) {
        $j = $i + $#{$request->{'value'}};
        @tmp2 = @tmp[$i .. $j];
        if (compare_arrays($request->{'value'}, \@tmp2)) {
          splice @tmp, $i, scalar @{$request->{'value'}};
          last;
        }
      }
      if (@tmp) {
        ($ok, $mess) =
          $self->_list_config_set($request->{'list'},
                                  $request->{'setting'}, @tmp);
      }
      else {
        # Set the value to its default if no lines remain.
        ($ok, $mess) =
          $self->{'lists'}{$request->{'list'}}->config_set_to_default(
                                                 $request->{'setting'});
      }
    }
  } # "extract" mode

  elsif ($request->{'mode'} =~ /noforce/) {
    $join = $self->config_get_isarray($request->{'setting'});
    @tmp = $self->_list_config_get($request->{'list'},
                                   $request->{'setting'}, 1);

    # If the new value and current value are identical, return
    # an error.
    if (($join and compare_arrays($request->{'value'}, \@tmp))
      or (! $join and $tmp[0] eq $request->{'value'}->[0]))
    {
      $ok = 0;
      $mess = $self->format_error('setting_unchanged', $request->{'list'},
                                  'SETTING'  => $request->{'setting'},
                                  'VALUE'    => $tmp[0]);
    }
    else {
      ($ok, $mess) = $self->_list_config_set($request->{'list'},
                                             $request->{'setting'}, @tmp);
    }
  }

  #  Simply replace the value.
  else {
    # Get possible error value and print it here, for error checking.
    ($ok, $mess) = $self->_list_config_set($request->{'list'},
                                           $request->{'setting'}, @tmp);
  }
  $self->_list_config_unlock($request->{'list'});
  $self->_list_set_config($request->{'list'}, 'MAIN');

  if (!$ok) {
    return ($ok, $mess);
  }
  elsif ($mess) {
    return (1, "Warnings for the $request->{'setting'} setting:\n$mess"); #XLANG
  }
  else {
    return 1;
  }
}

=head2 compare_arrays (listref, listref)

Compare the contents of two arrays.
Taken from perlfaq4.  Thanks to the authors of the perl documentation.

=cut

sub compare_arrays {
  my ($first, $second) = @_;
  return 0 unless @$first == @$second;
    for (my $i = 0; $i < @$first; $i++) {
      return 0 if $first->[$i] ne $second->[$i];
    }
    return 1;
}

=head2 list_config_set_to_default

Removes any definition of a config variable, causing it to track the
default.

=cut

sub list_config_set_to_default {
  my ($self, $user, $passwd, $list, $sublist, $var) = @_;
  my (@groups, @out, $ok, $mess, $level);

  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);

  return (0, "Unable to access configuration file $list:$sublist")
    unless $self->{'lists'}{$list}->valid_config($sublist); #XLANG

  if (!defined $passwd) {
    return (0, $self->format_error('no_password', $list,
                                   'COMMAND' => 'configdef')); 
  }

  @groups = $self->config_get_groups($var);
  if (!@groups) {
    return (0, $self->format_error('unknown_setting', $list,
                                   'SETTING' => $var));
  }
  $level = $self->config_get_mutable($list, $var);

  # Validate by category.
  # Validate passwd, check for proper auth level.
  $ok =
    $self->validate_passwd($user, $passwd, $list, "config_$var");
  unless ($ok >= $level) {
    return (0, $self->format_error('password_level', $list,
                                   'MODE'    => '',
                                   'SETTING' => $var,
                                   'LEVEL'   => $ok,
                                   'NEEDED'  => $level,
                                   'USER'    => "$user"));
  }
  else {
    $self->_list_set_config($list, $sublist);
    @out = $self->{'lists'}{$list}->config_set_to_default($var);
    $self->_list_config_unlock($list);
    $self->_list_set_config($list, 'MAIN');
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
  my (@out, $owners, $type);

  $list = 'GLOBAL' if $list eq 'ALL';
  return unless $self->_make_list($list);

  if ($var eq 'owners') {
    $owners = $self->{'lists'}{$list}->config_get($var);
  }

  @out = $self->{'lists'}{$list}->config_set($var, @_);

  $type = $self->config_get_type($var);
  if (defined ($out[0]) and $out[0] == 1) {
    # Now do some special stuff depending on the variable:

    # Regenerate password
    if ($type eq 'pw' || $type eq 'passwords') {
      $self->_list_config_unlock($list);
      $self->_build_passwd_data($list, 'force');
    }

    # Store new addr_xforms in the address parser
    elsif ($var eq 'addr_xforms') {
      Mj::Addr::set_params('xforms' => $out[2]);
    }

    # Synchronize the GLOBAL:owners sublist if the owners
    # setting was changed.
    elsif ($var eq 'owners') {
      $self->_list_config_unlock($list);
      $self->_list_sync_owners($list, $owners, \@_);
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

sub _list_config_search {
  my $self = shift;
  my $list = shift;

  return unless $self->_make_list($list);
  $self->{'lists'}{$list}->config_search(@_);
}

sub _list_set_config {
  my $self = shift;
  my $list = shift;

  return unless $self->_make_list($list);
  $self->{'lists'}{$list}->set_config(@_);
}

=head2 _list_config_regen(list, sublist)

This private function takes the raw data in a configuration
file and recreates the corresponding parsed data.  It
is used during installation to bootstrap the GLOBAL:_install
and DEFAULT:_install configuration files, which are used
to provide default values for all configuration settings.

=cut

sub _list_config_regen {
  my $self = shift;
  my $list = shift;
  my $sublist = shift;
  my ($error, $ok);

  return unless $self->_list_set_config($list, $sublist);
  ($ok, $error) = $self->{'lists'}{$list}->config_regen;
  $self->_list_set_config($list, 'MAIN');
  ($ok, $error);
}

=head2 _list_sync_owners (list, old, new)

This private function adjusts the GLOBAL:owners auxiliary
list when the owner addresses for one list are changed.

=cut

sub _list_sync_owners {
  my $self = shift;
  my $list = shift;
  my $old = shift;
  my $new = shift;
  my $log = new Log::In 150, $list;

  my (%owners, %seen, @lists, $addr, $data, $i, $j, $requ,
      $strip, $time);

  $requ = $self->{'sessionuser'};
  ($i) = $self->valid_list($list);
  return unless $i;

  for $i (@$old) {
    $addr = new Mj::Addr($i);
    next unless (defined $addr);
    next unless $addr->isvalid;
    $strip = $addr->strip;
    $seen{$strip}--;
    $owners{$strip} = $addr;
  }
  for $i (@$new) {
    $addr = new Mj::Addr($i);
    next unless (defined $addr);
    next unless $addr->isvalid;
    $strip = $addr->strip;
    $seen{$strip}++;
    $owners{$strip} = $addr;
  }
  for $i (keys %owners) {
    next unless $seen{$i};
    $time = $::log->elapsed;
    $data = $self->{'lists'}{'GLOBAL'}->is_subscriber($owners{$i}, 'owners');
    unless ($data) {
      next if ($seen{$i} < 0);
      $self->{'lists'}{'GLOBAL'}->add('', $owners{$i}, 'owners',
                                      'groups' => $list);
      $self->inform('GLOBAL', 'subscribe', $requ, $i,
                    "subscribe GLOBAL:owners $i",
                    $self->{'interface'}, 1, 1, 0,
                    '',
                    $::log->elapsed - $time);

      next;
    }
    @lists = split "\002", $data->{'groups'};

    if ($seen{$i} > 0) {
      unless (grep { $_ eq $list } @lists) {
        push @lists, $list;
        $data->{'groups'} = join "\002", sort @lists;
        $self->{'lists'}{'GLOBAL'}->update('', $owners{$i}, 'owners', $data);
      }
    }
    else {
      @lists = grep { $_ ne $list } @lists;
      if (@lists) {
        $data->{'groups'} = join "\002", sort @lists;
        $self->{'lists'}{'GLOBAL'}->update('', $owners{$i}, 'owners', $data);
      }
      else {
        # remove and inform
        $self->{'lists'}{'GLOBAL'}->remove('', $owners{$i}, 'owners');
        $self->inform('GLOBAL', 'unsubscribe', $requ, $i,
                      "unsubscribe GLOBAL:owners $i",
                      $self->{'interface'}, 1, 1, 0,
                      '', $::log->elapsed - $time);

      }
    }
  }
}

=head2 format_get_charset, format_get_string

Format files are used by the Mj::Format module to display the results of
Majordomo commands.  In the WWW interfaces, it is necessary to include
the character set along with the content-type of a format file.

These two methods cause the character set or the contents of a format
file to be returned.

=cut

sub format_get_charset {
  my $self = shift;
  my $type = shift;
  my $file = shift;
  my $list = shift;

  my ($name, %data) =
    $self->_list_file_get(list => $list, file => "format/$type/$file");

  if (exists $data{'charset'}) {
    return $data{'charset'};
  }
  return;
}

sub format_get_string {
  my $self = shift;
  my $type = shift;
  my $file = shift;
  my $list = shift;
  my ($out, $truelist);
  unless (defined $list and length $list) {
    $list = 'GLOBAL';
  }
  # Accounts for any relocated lists
  ($truelist) = $self->valid_list($list, 1, 1);
  unless (defined $truelist and length $truelist) {
    $truelist = 'GLOBAL';
  }

  $out = $self->_list_file_get_string(list => $truelist,
				      file => "format/$type/$file",
				     );

  if (defined $out) {
    chomp $out;
  }
  else {
    $out = '';
  }
  $out;
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
  $self->_list_file_get_string(list => 'GLOBAL', file => "config/$var");
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
  my $list = shift;
  my $var  = shift;
  return unless $self->_make_list($list);
  $self->{'lists'}{$list}->config_get_visible($var);
}

sub config_get_whence {
  my $self = shift;
  my $list = shift;
  my $sublist = shift;
  my $var  = shift;
  my $source;

  return unless $self->_make_list($list);
  return unless $self->_list_set_config($list, $sublist);
  $source = $self->{'lists'}{$list}->config_get_whence($var);
  return unless $self->_list_set_config($list, 'MAIN');
  $source;
}

sub config_get_mutable {
  my $self = shift;
  my $list = shift;
  my $var  = shift;

  return unless $self->_make_list($list);
  $self->{'lists'}{$list}->config_get_mutable($var);
}

=head2 config_get_default(user, passwd, list, variable)

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
  my ($self, $user, $passwd, $list, $sublist, $var) = @_;
  my (@groups, @out, $hidden, $i, $error, $lvar, $ok);
  $sublist ||= 'MAIN';

  $::log->in(100, "$list, $var");

  $var =~ tr/ \t//d;
  $user = new Mj::Addr($user);
  $lvar = lc($var);

  return unless $self->_make_list($list);

  # DEFAULT settings are always visible.
  if ($list =~ /^DEFAULT/ and $sublist ne 'MAIN') {
    $ok = 1;
  }
  elsif ($var eq 'ALL') {
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

  $hidden = ($ok > 0) ? $ok : 0;
  @out = $self->{'lists'}{$list}->config_get_vars($var, $hidden,
                                                  ($list eq 'GLOBAL'));
  $::log->out(($ok > 0)? "validated" : "not validated");
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
  $self->_get($request->{'list'}, $request->{'user'}, $request->{'victim'},
              $request->{'mode'}, $request->{'cmdline'}, $request->{'path'});
}

use IO::File;
sub _get {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $name) = @_;
  my $log = new Log::In 35, "$list, $name";
  my (%data, $cset, $desc, $enc, $file, $mess, $nname, $ok, $type);

  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);

  # Untaint the file name
  $name =~ /(.*)/; $name = $1;

  # If given an "absolute path", trim it, else stick "public/" onto it
  unless (($nname = $name) =~ s!^/!!) {
    $nname = "public/$name";
  }

  unless ($self->{'lists'}{$list}->fs_legal_file_name($nname)) {
    return (0, $self->format_error('invalid_file', $list, 'FILE' => $name));
  }

  ($file, %data) = $self->_list_file_get(list => $list, file => $nname);

  unless ($file) {
    if ($mode =~ /immediate|edit/) {
      ($file, %data) = $self->_list_file_get(list => $list,
					     file => 'unknown_file',
					    );
    }
    unless ($file) {
      return (0, $self->format_error('no_file', $list, 
                                     'FILE' => $name));
    }
  }

  # Start up the iterator if we're running in immediate mode
  if ($mode =~ /immediate|edit/) {
    $self->{'get_fh'} = new IO::File $file;
    unless ($self->{'get_fh'}) {
      return (0, $self->format_error('open_file', $list, 
                                     'FILE' => $name, 'ERROR' => $!));
    }
    # Return the data to make editing/replacing the file easier.
    return (1, \%data);
  }

  $self->_get_send_and_reply($list, $victim, $name, $file, %data);
}

use IO::File;
sub _get_send_and_reply {
  my $self = shift;
  my ($list, $victim, $name) = @_;
  my (%data, $file);

  # Mail out the file to the victim.
  # Be sneaky and return another file to be read; this keeps the code
  # simpler and lets the owner customize the file_sent message
  ($file, %data) = $self->_list_file_get(list => $list, file => 'file_sent');
  $self->_get_mailfile(@_);

  $self->{'get_subst'} = {
                          $self->standard_subs($list),
                          'FILE'     => $name,
                          'VICTIM'   => "$victim",
                         };
  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return (0, $self->format_error('open_file', $list, 
                                   'FILE' => $name, 'ERROR' => $!));
  }
  return (1, \%data);
}

use MIME::Entity;
use Mj::MailOut;
sub _get_mailfile {
  my ($self, $list, $vict, $name, $file, %data) = @_;
  my ($ent, $sender);

  $sender = $self->_list_config_get($list, 'sender');

  # XXX Should File basename be specified explicitly?
  $ent = build MIME::Entity
    (
     Path     => $file,
     Type     => $data{'c-type'},
     Charset  => $data{'charset'},
     Encoding => $data{'c-t-encoding'},
     Subject  => $data{'description'} || "Requested file $name from $list",
     -To      => "$vict",
     Top      => 1,
     Filename => undef,
     'Content-Language:' => $data{'language'},
    ); #XLANG

  $self->mail_entity($sender, $ent, $vict) if $ent;
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
  $self->_faq($request->{'list'}, $request->{'user'}, $request->{'victim'},
              $request->{'mode'}, $request->{'cmdline'}, 'faq');
}

use IO::File;
sub _faq {
  my ($self, $list, $requ, $victim, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$list";
  my (%fdata, $file, $subs);

  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);

  ($file, %fdata) = $self->_list_file_get(list => $list, file => 'faq');

  unless ($file) {
    return (0, $self->format_error('no_file', $list, 'FILE' => '/faq'));
  }

  if ($mode !~ /edit/) {
    $subs =
      {
       $self->standard_subs($list),
       'LASTCHANGE' => scalar localtime($fdata{'lastmod'}),
       'USER'       => $requ,
      };

    $file = $self->substitute_vars($file, $subs);
    push @{$self->{'get_temps'}}, $file;
    if ("$requ" ne "$victim") {
      return $self->_get_send_and_reply($list, $victim, '/faq', $file, %fdata);
    }
  }

  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return (0, $self->format_error('open_file', $list, 'FILE' => '/faq',
                                   'ERROR' => $!));
  }
  return (1, \%fdata);
}

# Included for purposes of logging.
sub faq_done {
  (shift)->get_done(@_);
}

use IO::File;
sub help_start {
  my ($self, $request) = @_;
  my (%fdata, @info, $file, $mess, $ok, $subs, $whoami, $wowner);

  # convert, for example,
  #    "help configset access_rules"
  # to "help configset_access_rules"
  if ($request->{'topic'}) {
    $request->{'topic'} = lc(join('_', split(/\s+/, $request->{'topic'})));
  }
  else {
    $request->{'topic'} = "overview";
  }
  my $log = new Log::In 50, "$request->{'user'}, $request->{'topic'}";

  ($ok, $mess) =
    $self->list_access_check($request, 'nostall' => 1);

  # No stalls should be allowed...
  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $whoami = $self->_global_config_get('whoami'),
  $wowner = $self->_global_config_get('sender'),

  ($request->{'topic'}) = $request->{'topic'} =~ /(.*)/; # Untaint

  $subs =
    {
     $self->standard_subs('GLOBAL'),
     'TOPIC' => $request->{'topic'},
     'USER'  => "$request->{'user'}",
    };

  ($file, %fdata) =  
    $self->_list_file_get(list => 'GLOBAL',
                          file => "help/$request->{'topic'}",
                          subs => $subs,
                         );

  # Allow abbreviations for configuration settings.  For example,
  # "help configset_access_rules" can be abbreviated to "help access_rules"
  unless ($file) {
    $subs->{'TOPIC'} = "configset_$request->{'topic'}";
    ($file, %fdata) =  
      $self->_list_file_get(list => 'GLOBAL',
                            file => "help/configset_$request->{'topic'}",
                            subs => $subs,
                           );
  }
  unless ($file) {
    $subs->{'TOPIC'} = "unknowntopic";
    ($file, %fdata) =  
      $self->_list_file_get(list => 'GLOBAL',
                            file => 'help/unknowntopic',
                            subs => $subs,
                           );
  }
  unless ($file) {
    return (0, $self->format_error('no_file', 'GLOBAL', 'FILE' =>
                                   "help/$request->{'topic'}"));
  }

  if ("$request->{'user'}" ne "$request->{'victim'}") {
    return $self->_get_send_and_reply('GLOBAL', $request->{'victim'},
                                      "help/$request->{'topic'}", 
                                      $file, %fdata);
  }

  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return 0;
  }
  push @{$self->{'get_temps'}}, $file;
  return (1, \%fdata);
}

# Included for purposes of logging.
sub help_done {
  (shift)->get_done(@_);
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
  $self->_info($request->{'list'}, $request->{'user'}, $request->{'victim'},
               $request->{'mode'}, $request->{'cmdline'}, 'info');
}

use IO::File;
sub _info {
  my ($self, $list, $requ, $victim, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$list";
  my (%fdata, $file, $subs);

  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list); 

  ($file, %fdata) = $self->_list_file_get(list => $list, file => 'info');

  unless ($file) {
    return (0, $self->format_error('no_file', $list, 'FILE' => '/info'));
  }

  if ($mode !~ /edit/) {
    $subs =
      {
       $self->standard_subs($list),
       'LASTCHANGE' => scalar localtime($fdata{'lastmod'}),
       'USER'       => $requ,
      };

    $file = $self->substitute_vars($file, $subs);
    push @{$self->{'get_temps'}}, $file;
    if ("$requ" ne "$victim") {
      return $self->_get_send_and_reply($list, $victim, '/info', $file, %fdata);
    }
  }

  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return (0, $self->format_error('open_file', $list, 'FILE' => '/info',
                                   'ERROR' => $!));
  }
  return (1, \%fdata);
}

# Included for purposes of logging.
sub info_done {
  (shift)->get_done(@_);
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
  $self->_intro($request->{'list'}, $request->{'user'}, $request->{'victim'},
                $request->{'mode'}, $request->{'cmdline'});
}

use IO::File;
sub _intro {
  my ($self, $list, $requ, $victim, $mode, $cmdline) = @_;
  my $log = new Log::In 35, "$list";
  my (%fdata, $file, $subs);

  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);

  ($file, %fdata) = $self->_list_file_get(list => $list, file => 'intro');

  unless ($file) {
    return (0, $self->format_error('no_file', $list, 'FILE' => '/intro'));
  }

  if ($mode !~ /edit/) {
    $subs =
      {
       $self->standard_subs($list),
       'LASTCHANGE' => scalar localtime($fdata{'lastmod'}),
       'USER'       => $requ,
      };

    $file = $self->substitute_vars($file, $subs);
    push @{$self->{'get_temps'}}, $file;

    if ("$requ" ne "$victim") {
      return $self->_get_send_and_reply($list, $victim, '/intro', $file, %fdata);
    }
  }
    
  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    return (0, $self->format_error('open_file', $list, 'FILE' => '/intro',
                                   'ERROR' => $!));
  }
  return (1, \%fdata);
}

# Included for purposes of logging.
sub intro_done {
  (shift)->get_done(@_);
}

=head2 password(..., password)

This changes a user''s password.  If mode is 'gen' or 'rand' (generate or
random) a password is randomly generated.

=cut

use Mj::Util qw(gen_pw);
sub password {
  my ($self, $request) = @_;
  my ($ok, $length, $mess, $minlength);
  my $log = new Log::In 30, "$request->{'victim'}, $request->{'mode'}";

  # Generate a password if necessary
  if ($request->{'mode'} =~ /gen|rand/) {
    $request->{'newpasswd'} = &gen_pw($minlength);
  }
  elsif ($request->{'mode'} =~ /show/) {
    $request->{'newpasswd'} = '';
  }

  $length = length $request->{'newpasswd'};
  $minlength = $self->_global_config_get('password_min_length') || 0;

  return (0, $self->format_error('password_length', 'GLOBAL'))
    unless ($request->{'mode'} =~ /show/ or $length >= $minlength);

  ($ok, $mess) =
    $self->list_access_check($request, 'password_length' => $length);

  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_password($request->{'list'}, $request->{'user'}, 
                   $request->{'victim'}, $request->{'mode'}, 
                   $request->{'cmdline'}, $request->{'newpasswd'});
}

use MIME::Entity;
use Mj::Format;
sub _password {
  my ($self, $list, $user, $vict, $mode, $cmdline, $pass) = @_;
  my $log = new Log::In 35, "$vict";
  my (%file, $desc, $ent, $file, $i, $reg, $sender, $subst);

  # Make sure user is registered. 
  $reg = $self->_reg_lookup($vict);
  return (0, $self->format_error('unregistered', 'GLOBAL', 'VICTIM' => "$vict"))
    unless $reg;

  if ($mode =~ /show/) {
    $pass = $reg->{'password'};
  }
  else {
    # Write out new data.
    $self->_reg_add($vict,
                    'password' => $pass,
                    'update'   => 1,
                   );
  }

  # Mail the password_set message to the victim if requested
  if ($mode !~ /quiet/) {
    $sender = $self->_global_config_get('sender');

    $subst = {
              $self->standard_subs('GLOBAL'),
	      'PASSWORD'  => $pass,
              'STRIPADDR' => $vict->strip,
              'QSADDR'    => Mj::Format::qescape($vict->strip),
	      'USER'      => "$vict",
	      'VICTIM'    => "$vict",
	     };

    ($file, %file) = $self->_list_file_get(list => 'GLOBAL',
					   file => 'new_password',
					  );
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
       -From    => $subst->{'MJOWNER'},
       -To      => $vict->canon,
       Top      => 1,
       Filename => undef,
       'Content-Language:' => $file{'language'},
      );

    if ($ent) {
      for $i ($self->_global_config_get('message_headers')) {
        $i = $self->substitute_vars_string($i, $subst);
        $ent->head->add(undef, $i);
      }
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

  $filedesc = "$request->{'ocontype'}\002$request->{'ocset'}\002$request->{'oencoding'}\002$request->{'olanguage'}";
  $request->{'arg3'} = $filedesc;

  my $log = new Log::In 30, "$request->{'list'}, $request->{'file'}, " .
            "$request->{'xdesc'}, $request->{'ocontype'}, $request->{'ocset'}, "
              . "$request->{'oencoding'}, $request->{'olanguage'}";

  # Check the password
  ($ok, $mess) = $self->list_access_check($request, 'nostall' => 1);

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
  my (%ofdata, $cset, $enc, $force, $lang, $mess, $oldfile, $type);

  # Extract the encoded type and encoding
  ($type, $cset, $enc, $lang) = split("\002", $stuff);

  my $log = new Log::In 35, "$list, $file, $subj, $type, $cset, $enc, $lang";
  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list); 

  # Untaint the file name
  $file =~ /(.*)/; $file = $1;

  # If given an "absolute path", trim it, else stick "public/" onto it
  unless ($file =~ s!^/!!) {
    $file = "public/$file";
  }

  unless ($self->{'lists'}{$list}->fs_legal_file_name($file)) {
    return (0, $self->format_error('invalid_file', $list, 
                                   'FILE' => $file));
  }

  $force = ($mode =~ /force/) ? 1 : 0;

  # Make a directory instead?
  if ($mode =~ /dir/) {
    return ($self->{'lists'}{$list}->fs_mkdir($file, $subj, $force));
  }

  # Delete a file/directory instead?
  if ($mode =~ /delete/) {
    return $self->_list_file_delete($list, $file, $force);
  }

  if ($subj eq 'default') {
    ($oldfile, %ofdata) = $self->_list_file_get('list' => $list, 
                                                'file' => $file);
    if (exists $ofdata{'description'}) {
      $subj = $ofdata{'description'};
    }
  }

  # The zero is the overwrite control; haven't quite figured out what to
  # do with it yet.
  $self->{'lists'}{$list}->fs_put_start($file, 0, $subj, $type, $cset, 
                             $enc, $lang, '', $force);
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
  my (%file, $cset, $desc, $dom, $enc, $ent, $file, $hdr, $list_own,
      $mess, $sender, $subs, $type);

  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);

  $dom = $self->_global_config_get('whereami');
  if ($victim->strip eq "$list-request\@$dom") {
    return (0, "Loop detected.\n");  # XLANG
  }

  ($file, %file) = $self->_list_file_get(list => $list,
					 file => 'request_response',
					);
  return unless $file;

  # Build the entity and mail out the file
  $sender = $self->_list_config_get($list, 'sender');
  $list_own   = $self->_list_config_get($list, 'whoami_owner');

  $subs = {
           $self->standard_subs($list),
           'REQUESTER' => "$requ",
           'USER'      => "$requ",
	  };

  # Expand variables
  $desc = $self->substitute_vars_string($file{'description'}, $subs);
  $file = $self->substitute_vars($file, $subs);

  $ent = build MIME::Entity
    (
     Path     => $file,
     Type     => $file{'c-type'},
     Charset  => $file{'charset'},
     Encoding => $file{'c-t-encoding'},
     Subject  => $desc || "Your message to $list-request",
     -From    => $list_own,
     -To      => "$victim",
     Top      => 1,
     Filename => undef,
     'Content-Language:' => $file{'language'},
    );

  if ($ent) {
    for $hdr ($self->_global_config_get('message_headers')) {
      $hdr = $self->substitute_vars_string($hdr, $subs);
      $ent->head->add(undef, $hdr);
    }

    $self->mail_entity($sender, $ent, $victim);
    $ent->purge;
    return (1, '');
  }
  else {
    return (0, $self->format_error('no_entity', $list));
  }
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

  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);

  # If given an "absolute path", trim it, else stick "public/" onto it
  unless ($dir =~ s!^/!!) {
    $dir = "public/$dir";
  }

  # Now trim a trailing slash
  $dir =~ s!/$!!;

  unless (!$dir or $self->{'lists'}{$list}->fs_legal_file_name($dir)) {
    return (0, $self->format_error('invalid_file', $list, 'FILE' => $dir));
  }

  $nodirs  = 1 if $mode =~ /nodirs/;
  $recurse = 1 if $mode =~ /recurs/;

  $self->{'lists'}{$list}->fs_index($dir, $nodirs, $recurse);
}


=head2 _list_file_get(args)

Takes named arguments list, file, subs, nofail, lang, force.

This forms the basic internal interface to a list''s (virtual) filespace.
All core routines which need to retrieve files should use this function as
it provides all of the i18n functionality for file access.

This handles figuring out the list''s default language, properly expanding
the search list and handling the share_list.

If $args{subs} is defined, it should be a hashref of substitutions to
be made; substitute_vars will be called automatically.

If $args{nofail} is true, this function will never fail to return a
file, even if the file is not found.  Instead, it will emit a warning
and return a generic "file not found" file.

If $args{lang} is defined, it is used in place of any default_language
setting.

If $args{nodefsearch} is true, the DEFAULT and STOCK files will not be
used as sources for files.

Note that if $args{subs} is provided, the returned filename will be a temporary
generated by substitute_vars.  The caller is responsible for cleaning up
this temporary.

=cut

sub _list_file_get {
  my $self = shift;
  my %args = @_;

  my $log  = new Log::In 130, "$args{list}, $args{file}";
  my (%paths, @dsearch, @langs, @out, @paths, @search, @share, $ok,
      $d, $f, $i, $j, $l, $p, $tmp);

  my $list = $args{list};
  my $file = $args{file};
  my $lang = $args{lang};

  # Account for list:sublist
  if ($list =~ /^([^:\s]+):/) {
    $list = $1;
  }

  $list = 'GLOBAL' if ($list eq 'ALL');
  return unless $self->_make_list($list);
  @search  = $self->_list_config_get($list, 'file_search');
  @dsearch = ();
  unless ($args{nodefsearch}) {
    @dsearch = ('DEFAULT:$LANG', 'DEFAULT:', 'STOCK:$LANG',
                'STOCK:en', 'STOCK:');
  }

  $lang ||= $self->_list_config_get($list, 'default_language');
  @langs = split(/\s*,\s*/, $lang) if $lang;

  # Build @paths list; maintain %paths hash to determine uniqueness.
  for $i (@search, @dsearch)
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
    if ($l ne $list && $l ne 'DEFAULT' && $l ne 'STOCK') {
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
      @out = $self->{'lists'}{$l}->fs_get($f, $args{force});
    }

    # Now, if we got something
    if (@out) {
      # Substitute if necessary; $out[0] is the filename
      if ($args{subs}) {
	$out[0] = $self->substitute_vars($out[0], $args{subs}, $list);
      }
      return @out;
    }
  }

  # If we get here, we didn't find anything that matched at all so if so
  # instructed we pull out the file of last resort.
  if ($args{nofail}) {
    @out = $self->_get_stock('en/file_not_found');
    $args{subs} ||= {};
    $args{subs}->{'UNKNOWNFILE'} = $file;
    $out[0] = $self->substitute_vars($out[0], $args{subs}, $list);
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
  my (%args, %data, $fh, $file, $line, $out);

  %args = @_;
  ($file, %data) = $self->_list_file_get(@_);

  return unless $file;

  $fh = gensym();

  return $self->format_error('open_file', $args{'list'}, 
                             'FILE' => $args{'file'}, 'ERROR' => $!)
    unless (open $fh, "<$file");

  while (defined($line = <$fh>)) {
    $out .= $line;
  }

  if ($args{'subs'}) {
    unlink $file;
  }

  if (wantarray) {
    return ($out, %data);
  }
  return $out;
}

=head2 _list_file_put(list, name, source, overwrite, description,
content-type, charset, content-transfer-encoding, permissions)

Calls the list's fs_put function.

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

use Mj::FileSpace;
sub _get_stock {
  my $self = shift;
  my $file = shift;
  my $log = new Log::In 150, "$file, $self->{'sitedir'}";
  my (%out, $data, $lang, $noweb);

  $noweb = 1;
  $noweb = 0 if $self->{'sitedata'}{'config'}{'cgi_bin'};

  # Pull in the index file if necessary
  if ($noweb) {
    unless ($self->{'sitedata'}{'noweb'}) {
      ($self->{'sitedata'}{'noweb'})
        = do "$self->{'sitedir'}/files/INDEX.pl";
      $log->abort("Can't load index file $self->{'sitedir'}/files/INDEX.pl!")
        unless $self->{'sitedata'}{'noweb'};
    }

    # Disable spurious warnings from perl 5.8.2.
    local($^W) = 0;

    # XXX This change should be made at a higher level.
    if (exists $self->{'sitedata'}{'noweb'}{$file}) {
      $file .= "_noweb";
    }
  }

  unless ($self->{'sitedata'}{'filespace'}) {
    return unless ($self->{'sitedata'}{'filespace'} =
      new Mj::FileSpace("$self->{'sitedir'}/files", $self->{'backend'}));
  }

  $self->{'sitedata'}{'filespace'}->get($file);
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

  my $dirh = gensym();
  my ($list, @lists);

  my $listdir = $self->{'ldir'};
  opendir($dirh, $listdir) || $::log->abort("Error opening $listdir: $!");

  if ($self->{'sdirs'}) {
    while (defined($list = readdir $dirh)) {
      $self->{'lists'}{$list} ||= undef
	if (legal_list_name($list) && -d "$listdir/$list");
    }
  }
  else {
    while (defined($list = readdir $dirh)) {
      # Make a hash entry for the list if it doesn't already exist
      $self->{'lists'}{$list} ||= undef
	if (legal_list_name($list));
    }
  }
  closedir($dirh);

  $self->{'lists_loaded'} = 1;
  $::log->out;
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
  my $name = shift || "";

  $::log->message(200, 'info', 'Majordomo::legal_list_name', $name);
  return undef unless $name;
  return undef if $name =~ /[^a-zA-Z0-9_.-]/;
  return undef if $name eq '.';
  return undef if $name eq '..';
  return undef if $name =~/^(RCS|core)$/;
  $name =~ /(.*)/; $name = lc $1;
  return $name;
}

=head2 valid_list(list, allok, globalok)

Checks to see that the list is valid, i.e. that it exists on the server.
This has the nice side effect of returning the untainted list name.
If the list is invalid or has been relocated, a message is returned.

If allok is true, then ALL will be accepted as a list name.
If globalok is true, then GLOBAL and DEFAULT will be accepted as
list names.

=cut

sub valid_list {
  my $self   = shift;
  my $name   = shift || "";
  my $all    = shift;
  my $global = shift;
  my $log    = new Log::In 120, $name;
  my ($file, $mess, $oname, $reloc, $sublist, $subs, $tmp);
  $sublist = $mess = '';

  if ($name =~ /^([^\s:]+):(\S*)$/) {
    $name = $1; 
    $sublist = $2 if (defined $2 and length $2);
  }

  unless (legal_list_name($name)) {
    return (undef, undef,
            $self->format_error('invalid_list', 'GLOBAL', 'LIST' => $name));
  }
  if ($sublist) {
    unless (legal_list_name($sublist)) {
      return (undef, undef,
              $self->format_error('invalid_list', 'GLOBAL', 'LIST' => $sublist));
    }
  }

  if (($name eq 'ALL' && $all) ||
      (($name eq 'GLOBAL' or $name eq 'DEFAULT') && $global))
    {
      # untaint
      $name =~ /(.*)/;
      $name = $1;
      $sublist =~ /(.*)/;
      $sublist = $1;
      return ($name, $sublist, '');
    }

  $name    = lc($name);
  $oname   = $name;
  $sublist = lc($sublist) unless ($sublist eq 'MAIN');

  # Check the GLOBAL relocated_lists setting for list aliases.
  $reloc = $self->_global_config_get('relocated_lists');
  if ((ref $reloc eq 'HASH') and (exists $reloc->{$oname})) {
    $name = $reloc->{$oname}->{'name'};
    if ($name) {
      $reloc->{$oname}->{'file'} ||= '/error/relocated_list';
    }
    if (length($reloc->{$oname}->{'file'})) {
      $subs = {
                $self->standard_subs('GLOBAL'),
                'LIST' => $oname,
                'NEWLIST' => $name,
              };

      $tmp = $self->_list_file_get_string(list => 'GLOBAL',
                                          file => $reloc->{$oname}->{'file'},
					 );
      $mess .= $self->substitute_vars_format($tmp, $subs);
    }
  }

  if ($name and -d "$self->{'ldir'}/$name") {
    # untaint
    $name =~ /(.*)/;
    $name = $1;
    $sublist =~ /(.*)/;
    $sublist = $1;
    $self->_make_list($name);
    return ($name, $sublist, $mess) if ($self->{'lists'}{$name});
  }

  # The list is not supported at this site.
  $mess ||= $self->format_error('unknown_list', 'GLOBAL',
                                'LIST' => $oname);
  return ('', '', $mess);
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
  my ($comment, $elapsed, $token, $ttoken, @out);

  $elapsed = 0;
  $elapsed = $request->{'time'}
    if (exists $request->{'time'});

  return (0, $self->format_error('no_token', 'GLOBAL'))
    unless (scalar(@{$request->{'tokens'}}));

  for $ttoken (@{$request->{'tokens'}}) {
    $token = $self->t_recognize($ttoken);
    if (! $token) {
      push @out, 0, 
        $self->format_error('invalid_token', 'GLOBAL', 'TOKEN' => $ttoken);
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

    $elapsed = $::log->elapsed - $elapsed;
    # Now call inform so the results are logged
    $self->inform($data->{'list'},
          ($data->{'type'} eq 'consult'
           and $request->{'mode'} !~ /archive/
           and $data->{'command'} eq 'post')?
           'consult' : $data->{'command'},
          $data->{'user'},
          $data->{'victim'},
          $data->{'cmdline'},
          "token-$self->{'interface'}",
          $tmp->[0], 0, 0, $comment, $elapsed);

    $elapsed = $::log->elapsed;

    $mess ||= "Further approval is required.\n" if ($ok < 0); #XLANG
    $data->{'token'} = $token;

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
  my ($a2, $loc, $mess, $ok, $tmp);

  return (0, $self->format_error('undefined_address', 'GLOBAL'))
    unless (length $request->{'newaddress'});

  $a2 = new Mj::Addr($request->{'newaddress'});

  return (0, $self->format_error('undefined_address', 'GLOBAL'))
    unless (defined $a2);

  ($ok, $mess, $loc) = $a2->valid;
  $tmp = $self->format_error($mess, 'GLOBAL');
  return (0, $self->format_error('invalid_address', 'GLOBAL', 
                                 'ADDRESS' => $request->{'newaddress'},
                                 'ERROR'   => $tmp, 'LOCATION' => $loc,))
    unless ($ok > 0);

  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }
  $self->_alias($request->{'list'}, $request->{'user'}, $request->{'user'},
                $request->{'mode'}, $request->{'cmdline'},
                $request->{'newaddress'});
}

sub _alias {
  my ($self, $list, $requ, $to, $mode, $cmdline, $from) = @_;
  my $log = new Log::In 35, "$to, $from";
  my ($data, $err, $fdata, $ok, $tdata);

  # the dispatcher doesn't do this one for us.
  $from = new Mj::Addr($from);

  # Check that the target (after aliasing) is registered
  $tdata = $self->{reg}->lookup($to->canon);
  return (0, $self->format_error('unregistered', 'GLOBAL', 
                                 'VICTIM' => "$to"))
    unless $tdata;

  # Check that the transformed but unaliased source is _not_ registered, to
  # prevent cycles.
  $fdata = $self->{reg}->lookup($from->xform);

  return (0, $self->format_error('already_registered', 'GLOBAL', 
                                 'VICTIM' => "$from"))
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
of the subscribers of a mailing list, including the subscribers 
who receive digests or no mail.

The message is sent as a probe, meaning that each subscriber
will receive a customized copy.  The "To:" header in
the message will be set to the subscriber's address.
The "From:" header will contain the LIST-owner address.

=cut

sub announce {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'list'}, $request->{'file'}";
  my ($mess, $ok);

  $request->{'sublist'} ||= 'MAIN';

  return (0, "A file name was not supplied.\n")
    unless $request->{'file'}; #XLANG

  return (0, "Announcements to the DEFAULT list are not supported.\n")
    if ($request->{'list'} eq 'DEFAULT'); #XLANG

  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $mess);
  }
  $self->_announce($request->{'list'}, $request->{'user'}, $request->{'user'},
                   $request->{'mode'}, $request->{'cmdline'}, $request->{'file'},
                   $request->{'sublist'});

}

use MIME::Entity;
sub _announce {
  my ($self, $list, $user, $vict, $mode, $cmdline, $file, $sublist) = @_;
  my $log = new Log::In 30, "$list, $file";
  my (@classlist, %data, $author, $baseclass, $classes, $desc, $ent, $fh,
      $mailfile, $sender, $subs, $tmpfile);

  $author = $self->_list_config_get($list, 'whoami_owner');
  $sender = $self->_list_config_get($list, 'sender');
  return (0, "Unable to obtain sender address.\n")
    unless $sender; #XLANG

  $subs =
    {
     $self->standard_subs($list),
     'REQUESTER' => "$user",
     'USER'      => "$user",
    };

  ($mailfile, %data) = $self->_list_file_get(list => $list,
					     file => $file,
					     subs => $subs,
					    );

  return (0, $self->format_error('no_file', $list, 'FILE' => $file))
    unless $mailfile;

  $desc = $self->substitute_vars_string($data{'description'}, $subs);

  # XLANG
  $ent = build MIME::Entity
    (
     'Path'     => $mailfile,
     'Type'     => $data{'c-type'},
     'Charset'  => $data{'charset'},
     'Encoding' => $data{'c-t-encoding'},
     'Subject'  => $desc || "Announcement from the $list list",
     'Top'      => 1,
     '-To'      => '$MSGRCPT',
     '-From'    => $author,
     'Filename' => undef,
     'Content-Language:' => $data{'language'},
    );

  return (0, $self->format_error('no_entity', $list))
    unless $ent;

  $tmpfile = "$tmpdir/mja" . unique();
  $fh = gensym();
  open ($fh, ">$tmpfile") ||
    return(0, $self->format_error('open_file', $list, 'FILE' =>
                                  $tmpfile, 'ERROR' => $!));
  $ent->print($fh);
  close ($fh)
    or $::log->abort("Unable to close file $tmpfile: $!");

  # Construct classes from the mode.  If none was given,
  # use all classes.
  $classes = {};
  if ($list eq 'GLOBAL' and $sublist eq 'MAIN') {
    @classlist = qw(each nomail);
  }
  else {
    @classlist = qw(nomail each-noprefix-noreplyto each-prefix-noreplyto
                    each-noprefix-replyto each-prefix-replyto
                    unique-noprefix-noreplyto unique-prefix-noreplyto
                    unique-noprefix-replyto unique-prefix-replyto);
    push @classlist, $self->{'lists'}{$list}->_digest_classes
      if ($sublist eq 'MAIN');
  }
  for (@classlist) {
    ($baseclass = $_) =~ s/\-.+//;
    if (!$mode or $mode =~ /$baseclass/) {
      $classes->{$_} =
        {
         'exclude' => {},
         'file'    => $tmpfile,
         'seqnum'  => 'M0',
        };
    }
  }
  return (0, "No valid subscriber classes were found.\n")
    unless (scalar keys %$classes); #XLANG

  # Send the message.
  $self->probe($list, $sender, $classes, $sublist);
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
  my (@tmp, $i, $mess, $ok, $out, $pattern, $type);
  $request->{'args'} = '' unless (defined $request->{'args'});
  my $log = new Log::In 30, "$request->{'list'}, $request->{'args'}";

  return (0, $self->format_error('no_messages', $request->{'list'}))
    unless ($request->{'mode'} =~ /summary/ or $request->{'args'});

  $request->{'part'} ||= 0;

  # Verify any patterns that were supplied, and pack them.
  if (exists $request->{'contents'} and
      ref ($request->{'contents'}) eq 'ARRAY') {

    if ($request->{'mode'} =~ /replace/) {
      $request->{'contents'} = join "\002", @{$request->{'contents'}};
    }
    elsif ($request->{'mode'} =~ /summary/) {
      # Hack to allow sublist transfer for stalled commands.
      $request->{'contents'} = $request->{'sublist'};
    }
    else {
      for $i (@{$request->{'contents'}}) {
        if ($i =~ /~([as])(.+)/) {
          $type = ($1 eq 'a') ? 'author' : 'subject';
          $pattern = $2;
        }
        else {
          $type = 'subject';
          $pattern = $i;
        }

        ($ok, $mess, $pattern) =
          Mj::Config::compile_pattern($pattern, 0, 'isubstring');

        unless ($ok) {
          return (0, qw(The pattern "$i" is invalid.\n)); # XLANG
        }
        $pattern =~ s/\002//g;
        push @tmp, $type, $pattern;
      }
      $request->{'contents'} = join "\002", @tmp;
    }
  }

  ($ok, $out) =
    $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $out);
  }

  if ($request->{'mode'} =~ /delete|edit|replace|sync|hidden/) {
    return (0, $self->format_error('no_password', $request->{'list'},
                 'COMMAND' => 'archive-' . $request->{'mode'}))
      unless ($ok > 1);
  }
  $self->{'arcadmin'} = 1 if ($ok > 1);

  $self->_archive($request->{'list'}, $request->{'user'}, $request->{'victim'},
                  $request->{'mode'}, $request->{'cmdline'},
                  $request->{'args'}, $request->{'part'},
                  $request->{'contents'});
}

# Returns data for all messages matching the arguments.
use Mj::Util qw(re_match);
sub _archive {
  my ($self, $list, $user, $vict, $mode, $cmdline, $args,
      $part, $contents) = @_;
  my $log = new Log::In 30, "$list, $args";
  my (@msgs, @patterns, @tmp, $arc, $data, $i, $j, $mess, $msg, $ok,
      $private, $re_pattern, $regex, $type);
  return 1 unless ($args or $mode =~ /summary/);
  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);

  # sync mode makes the message database correspond to the archive files.
  if ($mode =~ /sync/) {
    @msgs = $self->{'lists'}{$list}->archive_find($args);
  }

  # summary mode lists all archives, along with the number of messages in each.
  elsif ($mode =~ /summary/) {
    @msgs = $self->{'lists'}{$list}->archive_summary($contents);
  }

  # return information from the message database for each message matching
  # the command arguments.
  else {
    # Determine if "hidden" messages should be included in the
    # result.
    $private = 1;
    if (exists $self->{'arcadmin'}) {
      $private = 0;
    }
    @msgs = $self->{'lists'}{$list}->archive_expand_range(0, $args,
                                       $private);

    # "hidden" mode causes only messages which are not intended to
    # be public to be included.
    if ($mode =~ /hidden/) {
      @tmp = ();
      for $j (@msgs) {
        ($i, $data) = @$j;
        if (exists($data->{'hidden'}) and $data->{'hidden'}) {
          push @tmp, $j;
        }
      }
      @msgs = @tmp;
    }

    # If any patterns were supplied, omit messages that do not match.
    if (length $contents) {
      @patterns = split "\002", $contents;
      if ($mode !~ /part|replace/) {
        while (($type, $regex) = splice @patterns, 0, 2) {
          @tmp = ();
          for $j (@msgs) {
            ($i, $data) = @$j;
            if ($type eq 'author') {
              push (@tmp, $j) if (re_match($regex, $data->{'from'}));
            }
            else {
              push (@tmp, $j) if (re_match($regex, $data->{'subject'}));
            }
          }
          @msgs = @tmp;
        }
      }
    }
  }
  $self->{'archct'} = 1;

  $re_pattern = $self->_list_config_get($list, 'subject_re_pattern');

  if ($mode =~ /author|date|reverse|subject|thread/) {
    eval ("use Mj::Util qw(sort_msgs)");
    @msgs = sort_msgs(\@msgs, $mode, $re_pattern);
  }

  if ($mode =~ /get/ and $mode =~ /immediate|part/ and ! $part) {
    # collect data about each message

    for ($i = 0; $i <= $#msgs; $i++) {
      ($msg, $data) = @{$msgs[$i]};
      next unless $msg;
      $msgs[$i]->[1] =
        $self->{'lists'}{$list}->archive_get_neighbors(
          $msg, $data, $re_pattern, $private);
    }
  }

  if (scalar @msgs and $mode =~ /part|edit|replace/) {
    # The edit, replace, and part modes imply that only
    # one message is being altered.  Return an error
    # if more than one matching message was found.
    return (0, $self->format_error('message_number', $list,
                                   'MSGNO' => $args))
      if ($#msgs > 0);

    ($msg, $data) = @{$msgs[0]};
    # In part mode, save the message to a temporary file and
    # obtain information about its structure.  Return the
    # resulting data.
    ($ok, $mess) = $self->{'lists'}{$list}->archive_get_to_file(
       $msg, '', $data, 1);
    return ($ok, $mess) unless ($ok);
    $self->{'spoolfile'} = $mess;

    ($ok, $mess) = $self->_get_msg_data($data, $part, $mode, [ @patterns ]);
    return ($ok, $mess) unless ($ok);

    $self->{'msg_data'} = $mess;
    $msgs[0]->[2] = $mess;
  }

  return (1, @msgs);
}

sub archive_chunk {
  my ($self, $request, $result) = @_;
  my $log = new Log::In 30, "$request->{'list'}";
  my (%file, %pending, @headers, @msgs, @nuke, @out, $buf, $data, 
      $dig, $dtype, $ent, $fh, $file, $finfo, $foot, $head, $i, $j, $k, 
      $line, $list, $ok, $out, $owner, $part, $subj, $subs);

  return (0, $self->format_error('archive_init', $request->{'list'}))
    unless (exists $self->{'archct'});

  return (0, $self->format_error('no_messages', $request->{'list'}))
    if (scalar(@$result) <= 0);

  return (0, $self->format_error('make_list', 'GLOBAL', 
                                 'LIST' => $request->{'list'}))
    unless $self->_make_list($request->{'list'});

  $list = $self->{'lists'}{$request->{'list'}};

  if ($request->{'mode'} =~ /sync/) {
    return (0, $self->format_error('no_password', $request->{'list'},
                                   'COMMAND' => 'archive-sync'))
      unless (exists $self->{'arcadmin'});
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
    return (0, $self->format_error('no_password', $request->{'list'},
                                   'COMMAND' => 'archive-delete'))
      unless (exists $self->{'arcadmin'});
    $buf = '';
    @msgs = @$result;

    # Exclude messages that are awaiting digest delivery if "delete" mode
    # is used without "force" mode.
    if ($request->{'mode'} !~ /force/) {
      $dig = $self->_list_config_get($request->{'list'}, 'digests');
      $j = $list->digest_examine([ keys %$dig ], 0);
      for $i (sort keys %$j) {
        next if ($i eq 'default_digest');
        $dig = $j->{$i};
        for $k (@{$dig->{'messages'}}) {
          $pending{$k->[0]}++;
        }
      }
    }
    for $i (@msgs) {
      if ($request->{'mode'} !~ /force/ and
          exists($pending{$i->[0]}))
      {
        $buf .= $self->format_error('pending_delivery',
                  $request->{'list'}, 'MSGNO' => $i->[0]);
        next;
      }

      if ($request->{'mode'} =~ /part/) {
        ($j, $k) = @$i;
        ($ok, $out) =
          $list->archive_replace_msg($j, $self->{'spoolfile'}, $tmpdir);

        if ($ok) {
          $buf .= $self->format_error('part_deleted', $request->{'list'},
                    'PART' => $request->{'part'}, 'MSGNO' => $j);
        }
        else {
          return (0, $self->format_error('part_not_deleted', 
                       $request->{'list'}, 'PART' => $request->{'part'}, 
                       'MSGNO' => $j, 'ERROR' => $out));
        }
      }
      else {
        ($ok, $out) = $list->archive_delete_msg(@$i);
        if ($ok) {
          $buf .= $self->format_error('message_deleted', $request->{'list'},
                    'PART' => $request->{'part'}, 'MSGNO' => $i->[0]);
        }
        else {
          $buf .= $self->format_error('message_not_deleted', 
                    $request->{'list'}, 'PART' => $request->{'part'}, 
                    'MSGNO' => $i->[0], 'ERROR' => $out);
        }
      }
    }
    return (1, $buf);
  }
  elsif ($request->{'mode'} =~ /digest/) {
    $dtype = ($request->{'mode'} =~ /mime/) ? 'mime' : 'text';
    $owner = $self->_list_config_get($request->{'list'}, 'sender');
    $subs = { 
              $self->standard_subs($request->{'list'}),
              'ARCHCT' => $self->{'archct'},
              'DATE'   => scalar(localtime()),
              'DIGESTDESC' => '',
              'DIGESTNAME' => 'archive',
              'DIGESTTYPE' => $dtype,
              'HOST'   => $self->_list_config_get($request->{'list'}, 
                             'resend_host'),
              'ISSUE'  => $self->{'archct'},
              'MESSAGECOUNT' => scalar(@$result),
              'MSGNO'  => '',
              'SENDER' => $owner,
              'SEQNO'  => '',
              'SUBJECT' => '',
              'SUBSCRIBED' => '',
              'USER' => $request->{'user'},
              'VOLUME' => 1,
            };

    for $i (qw(preindex postindex footer)) {
      for $j ("digest_archive_${dtype}_${i}", "digest_archive_${i}", 
              "digest_${dtype}_${i} ", "digest_${i}") 
      {
        ($file, %file) = 
          $self->_list_file_get(list => $request->{'list'},
                                file => $j,
                                subs => $subs,
                               );
        if ($file) {
          $finfo->{$dtype}{$i}{'name'} = $file;
          $finfo->{$dtype}{$i}{'data'} = \%file;
          push @nuke, $file;
          last;
        }
      }
    }
             
    for $j ("digest_archive_${dtype}_subject", "digest_archive_subject") {
      $subj = 
        $self->_list_file_get_string(list => $request->{'list'},
                                     file => $j,
                                     subs => $subs,
                                    );
      last if (defined $subj and length $subj);
    }

    @headers = $self->_digest_get_headers($request->{'list'}, $subs);
 
    ($file) = $list->digest_build
    (messages      => $result,
     files         => $finfo,
     from          => $self->_list_config_get($request->{'list'}, 'whoami_owner'),
     headers       => \@headers,
     index_line    => $self->_list_config_get($request->{'list'}, 'digest_index_format'),
     subject       => $subj,
     tmpdir        => $tmpdir,
     to            => "$request->{'victim'}",
     type          => $dtype,
    );

    # Mail the digest out to the victim
    $self->mail_message($owner, $file, $request->{'victim'});
    unlink $file;
    unlink @nuke;
    $self->{'archct'}++;
    return (1, scalar(@$result));
  }
  elsif ($request->{'mode'} =~ /replace/) {
    ($j, $k) = @{$result->[0]};
    ($ok, $out) = $list->archive_replace_msg($j, $self->{'spoolfile'}, $tmpdir);
    if ($ok) {
      return (1, $self->format_error('part_replaced', $request->{'list'}, 
                   'PART' => $request->{'part'}, 'MSGNO' => $j));
    }
    else {
      return (0, $self->format_error('part_not_replaced', 
                   $request->{'list'}, 'PART' => $request->{'part'}, 
                   'MSGNO' => $j, 'ERROR' => $out));
    }
  }
  elsif ($request->{'mode'} =~ /part/) {
    return (0, undef) unless (exists $self->{'msg_data'});

    return (0, undef)
      unless (defined $request->{'part'} and
              exists $self->{'msg_data'}->{$request->{'part'}});

    $part = $self->{'msg_data'}->{$request->{'part'}};
    unless (exists $part->{'fh'}) {
      if ($request->{'part'} eq '0') {
        $i = gensym();
        open ($i, "< $part->{'file'}");
        $part->{'fh'} = $i;
      }
      elsif ($request->{'mode'} =~ /clean/ and
             $part->{'entity'}->effective_type =~ /text\/html/i) {
        $file = $self->clean_text($part->{'entity'});
        return (0, undef) unless (defined $file and length $file);
        push @{$self->{'archive_temps'}}, $file;
        $i = gensym();
        open ($i, "< $file");
        return (0, undef) unless (defined $i);
        $part->{'fh'} = $i;
      }
      else {
        $part->{'fh'} = $part->{'entity'}->open("r");
      }
      return (0, undef) unless ($part->{'fh'});
    }

    while ($line = $part->{'fh'}->getline) {
      $out = '' unless $out;
      $out .= $line;
    }

    delete ($part->{'fh'});
    return (1, $out);
  }
  # Mail each message separately.
  else {
    @msgs = @$result;
    $owner = $self->_list_config_get($request->{'list'}, 'sender');
    for $i (@msgs) {
      ($buf, $data) = @$i;
      (undef, $file) = $list->archive_get_to_file($buf, '', $data, 1);
      next unless $file;
      $self->mail_message($owner, $file, $request->{'victim'});
      unlink $file;
    }
    return (1, scalar(@$result));
  }
}

sub archive_done {
  my ($self, $request, $result) = @_;

  delete $self->{'archct'};
  delete $self->{'arcadmin'};

  if (exists $self->{'archive_temps'}) {
    unlink @{$self->{'archive_temps'}};
    delete $self->{'archive_temps'};
  }
  if (exists $self->{'msg_parser'}) {
    if (defined $MIME::Tools::VERSION and $MIME::Tools::VERSION >= 5) {
      $self->{'msg_parser'}->filer->purge;
    }
    delete $self->{'msg_parser'};
    delete $self->{'msg_data'};
  }
  if (exists $self->{'spoolfile'}) {
    unlink $self->{'spoolfile'};
    delete $self->{'spoolfile'};
  }

  1;
}

=head2 configdef

Unset one or more values in a configuration file, which
causes the settings to use their default values.

=cut

sub configdef {
  my ($self, $request) = @_;
  my ($var, @out, $ok, $mess);
  my $log = new Log::In 30, "$request->{'list'}, @{$request->{'setting'}}";

  return (0, ["No configuration settings were specified.\n", ''])
    unless (@{$request->{'setting'}}); # XLANG

  return (0, ["The GLOBAL:_install template values cannot be reset.\n", ''])
    if ($request->{'list'} eq 'GLOBAL' and
        $request->{'sublist'} eq '_install'); # XLANG

  return (0, ["The DEFAULT:_install template values cannot be reset.\n", ''])
    if ($request->{'list'} eq 'DEFAULT' and
        $request->{'sublist'} eq '_install'); # XLANG

  for $var (@{$request->{'setting'}}) {
    ($ok, $mess) =
      $self->list_config_set_to_default($request->{'user'},
                                        $request->{'password'},
                                        $request->{'list'},
                                        $request->{'sublist'},
                                        $var);
    push @out, $ok, [$mess, $var];
  }
  @out;
}

=head2 configset

Change a configuration setting to a particular value

=cut

sub configset {
  my ($self, $request) = @_;
  return (0, "The name of the setting to be changed is missing.\n")
    unless (defined $request->{'setting'} and
            length $request->{'setting'});
  my $log = new Log::In 30, "$request->{'list'}, $request->{'setting'}";

  $self->list_config_set($request);
}

=head2 configshow

Display the values of one or more configuration settings.
Settings are classified into groups.  Requesting a particular
group (in capital letters) will cause all of the variables
in that group to be displayed.

"declared" mode will cause only those values defined in a
particular configuration file to be shown; settings which have
the default values are ignored.

"extract," "merge," and "append" modes will alter the appearance
of the configset commands that are displayed.

=cut

sub configshow {
  my ($self, $request) = @_;
  my (%all_vars, %category, @hereargs, @out, @tmp, @vars,
      $auto, $comment, $config, $data, $flag, $group, $groups,
      $i, $intro, $level, $message, $val, $var, $vars, $whence);

  if (! defined $request->{'groups'}->[0]) {
    $request->{'groups'} = ['ALL'];
  }
  if (exists $request->{'config'}) {
    ($config) = $self->valid_list($request->{'config'}, 0, 1);
    unless ($config) {
      return (1, [0, "Invalid configuration name: $request->{'config'}",
                  '', '']); # XLANG
    }
    # Expose DEFAULT list settings in "merge" mode.
    $config = $request->{'list'} unless ($request->{'list'} =~ /^DEFAULT/);
  }
  else {
    $config = $request->{'list'};
  }

  for $group (@{$request->{'groups'}}) {
    $data = {};
    # This expands groups and checks visibility and existence of variables
    @vars = $self->config_get_vars($request->{'user'}, $request->{'password'},
                                   $config, $request->{'sublist'},
                                   $group);
    unless (@vars) {
      push @out, [0, $self->format_error('no_visible', $request->{'list'},
                                         'SETTING' => $group),
                  $data, $group, ''];
    }
    else {
      for $var (@vars) {
        $all_vars{$var}++;
        @tmp = $self->config_get_groups($var);
        for $i (@tmp) {
          if (! exists $category{$i}) {
            $category{$i} = [ $var ];
          }
          else {
            push @{$category{$i}}, $var;
          }
        }
      }
    }
  }

  if ($request->{'mode'} =~ /categories/) {
    for $var (sort keys %category) {
      $comment = $self->_list_file_get_string(list => 'GLOBAL',
                                              file => "config/categories/$var",
					     );
      push @out, [1, $comment, $data, $var, $category{$var}];
    }
    return (1, @out);
  }

  for $var (sort keys %all_vars) {
    $level = $self->config_get_mutable($request->{'list'}, $var);
    $auto = $self->config_get_isauto($var);
    # Process the options
    $comment = '';
    $whence = $self->config_get_whence($request->{'list'},
                                       $request->{'sublist'}, $var);
    next if (defined $whence and $whence ne 'MAIN' and
             $request->{'mode'} =~ /declared|merge|append/);

    if ($request->{'mode'} !~ /nocomments/) {
      if (defined $whence and $whence ne 'MAIN') {
        $comment = "This value was determined by the $whence settings.\n"; #XLANG
      }
      $intro = $self->config_get_intro($request->{'list'}, $var);
      $comment = $self->config_get_comment($var) . $comment;
    }

    $data = {
             'auto' => $auto,
             'default' => $intro->[1],
             'enum' => $intro->[0],
             'groups' => $intro->[2],
             'type' => $intro->[3],
            };

    if ($self->config_get_isarray($var)) {
      @hereargs = ();
      # Process as an array
      for ($self->list_config_get($request->{'user'}, $request->{'password'},
                                  $request->{'list'}, $request->{'sublist'},
                                  $var, 1))
      {
        push (@hereargs, "$_\n") if defined $_;
      }
      push @out, [$level, $comment, $data, $var, [@hereargs]];
    }
    else {
      # Process as a simple variable
      ($val) = $self->list_config_get($request->{'user'}, $request->{'password'},
                                    $request->{'list'}, $request->{'sublist'},
                                    $var, 1);
      push @out, [$level, $comment, $data, $var, $val];
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

  ($ok, $error) = $self->list_access_check($request);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $error);
  }

  $self->_changeaddr($request->{'list'}, $request->{'user'}, $request->{'victim'},
                     $request->{'mode'}, $request->{'cmdline'});
}

sub _changeaddr {
  my ($self, $list, $requ, $vict, $mode, $cmd) = @_;
  my $log = new Log::In 35, "$vict, $requ";
  my (@out, @aliases, @lists, @olists, %uniq, $addr, $alias, $data, 
      $key, $l, $lkey, $ldata, $over, $time, $tmp);

  $over = 0;
  $over = 1 if ($mode =~ /noinform/);

  if ((($vict->canon eq $requ->canon) and ($vict->xform ne $requ->xform))
      or $requ->full eq $vict->full)
  {
    return (0, $self->format_error('same_address', 'GLOBAL', 
                 'USER' => "$requ", 'VICTIM' => "$vict"));
  }

  # The xformed and canonical addresses are identical.
  $alias = ($requ->canon eq $vict->canon);
  ($key, $data) = $self->{'reg'}->remove($mode, $vict->canon);

  unless ($key) {
    $log->out("failed, nomatching");
    return (0, $self->format_error('unregistered', 'GLOBAL',
                                   'VICTIM' => "$vict"));
  }

  $key = new Mj::Addr($key);
  return (0, $self->format_error('no_address', 'GLOBAL'))
    unless (defined $key);

  push @out, $data->{'fulladdr'};
  @olists = split ("\002", $data->{'lists'});

  # Does the new address already exist in the registry?
  # If so, combine the list data.
  if ($ldata = $self->{'reg'}->lookup($requ->canon)) {
    @lists = split ("\002", $ldata->{'lists'});
    push @lists, @olists;
    @uniq{@lists} = ();
    $ldata->{'lists'} = join "\002", sort keys %uniq;
    $data = $ldata;
  }
  else {
    unless ($alias and $vict->xform ne $key->xform) {
      $data->{'fulladdr'} = $requ->full;
      $data->{'stripaddr'} = $requ->strip;
    }
  }

  $self->{'reg'}->add('force', $requ->canon, $data);

  # Remove from all subscribed lists
  for $l (@olists) {
    $time = $::log->elapsed;
    next unless $self->_make_list($l);

    $tmp = $self->{'lists'}{$l}->is_subscriber($requ);

    ($lkey, $ldata) = $self->{'lists'}{$l}->remove('', $key);
    if ($ldata) {
      $addr = new Mj::Addr($ldata->{'fulladdr'});
      unless (defined $addr and $vict->xform ne $addr->xform
              and ($alias or $addr->xform ne $addr->canon)) {
        # If A is an alias for B, and A is subscribed to a list,
        # changeaddr B->C preserves A's subscription, whereas
        # changeaddr A->C changes A's subscription to C. 
        $ldata->{'fulladdr'} = $requ->full;
        $ldata->{'stripaddr'} = $requ->strip;
      }
      $self->{'lists'}{$l}->{'sublists'}{'MAIN'}->add('', $requ->canon, $ldata);
      if ($mode !~ /nolog/) {
        $self->inform($l, 'unsubscribe', $requ, $vict, "changeaddr $vict", 
                      $self->{'interface'}, 1, 0, $over, '', 
                      $::log->elapsed - $time);
      }
    }
    if (($alias or !defined $tmp) and $mode !~ /nolog/) {
      $self->inform($l, 'subscribe', $requ, $requ, "changeaddr $vict", 
                    $self->{'interface'}, 1, 0, $over, '', 
                    $::log->elapsed - $time);
    }
  }

  @aliases = $self->_alias_reverse_lookup($key, 1);
  for $tmp (@aliases) {
    if ($alias) {
      ($lkey, $ldata) = $self->{'alias'}->remove('', $tmp);
      next unless defined $ldata;

      $addr = new Mj::Addr($ldata->{'stripsource'});
      if (defined $addr and $addr->xform eq $vict->xform) {
        $ldata->{'stripsource'} = $requ->strip;
      }

      $addr = new Mj::Addr($ldata->{'striptarget'});
      if (defined $addr and $addr->xform eq $vict->xform) {
        $ldata->{'striptarget'} = $requ->strip;
      }

      $self->{'alias'}->add('', $tmp, $ldata);
    }
    elsif ($tmp eq $vict->canon) {
      ($lkey, $ldata) = $self->{'alias'}->remove('', $tmp);
      $ldata->{'target'} = $requ->canon;
      $ldata->{'striptarget'} = $requ->strip;
      $self->{'alias'}->add('', $requ->canon, $ldata);
    }
    else {
      $self->{'alias'}->replace('', $tmp, 'target', $requ->canon);
      $self->{'alias'}->replace('', $tmp, 'striptarget', $requ->strip);
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
  my ($mess, $ok, $tmp);

  unless ($request->{'mode'} =~ /regen/) {

    unless (defined $request->{'newlist'} and 
            length $request->{'newlist'}) {
      $tmp = 'createlist';
      if (length $request->{'mode'}) {
        $tmp .= '-' . $request->{'mode'};
      }
      return (0, $self->format_error('no_list', 'GLOBAL', 
                                     'COMMAND' => $tmp));
    }

    # Use the address of the requester as the list owner
    # unless an address was requested explicitly.
    $request->{'owners'} = [ "$request->{'user'}" ]
      unless (ref $request->{'owners'} eq 'ARRAY' and @{$request->{'owners'}});

    my $log = new Log::In 50, "$request->{'newlist'}, $request->{'owners'}->[0]";

    return (0, $self->format_error('invalid_list', 'GLOBAL',
                                   'LIST' => $request->{'newlist'}))
      unless ($ok = legal_list_name($request->{'newlist'}));

    $request->{'newlist'} = $ok;
  }

  $request->{'newpasswd'} ||= '';
  $request->{'newlist'} = lc $request->{'newlist'};

  # Check the password XXX Think more about where the results are
  # sent.  Normally we expect that the majordomo-owner will be the
  # only one running this command, but if site policy allows other
  # users to run it, the information about the MTA configuration will
  # need to be sent to a different place than the results of the
  # command.
  $request->{'owners'} = join "\002\002", @{$request->{'owners'}};
  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_createlist('', $request->{'user'}, $request->{'victim'},
                     $request->{'mode'}, $request->{'cmdline'},
                     $request->{'owners'}, $request->{'newlist'},
                     $request->{'newpasswd'});
}

use MIME::Entity;
use Mj::Util qw(gen_pw shell_hook);
sub _createlist {
  my ($self, $dummy, $requ, $vict, $mode, $cmd, $owner, $list, $pw) = @_;
  $list ||= '';
  my $log = new Log::In 35, "$mode, $list";

  my (%args, %data, @defaults, @lists, @owners, @tmp, $aliases, $bdir,
      $desc, $digests, $dir, $dom, $debug, $ent, $file, $i, $j, $k,
      $loc, $mess, $mta, $mtaopts, $newlist, $ok, $priority, $pwl, $regsub,
      $result, $sender, $setting, $shpass, $sources, $sublists, $subs,
      $tmp, $who);

  $mta   = $self->_site_config_get('mta');
  $dom   = $self->_global_config_get('whereami') || $self->{'domain'};
  $pwl   = $self->_global_config_get('password_min_length') || 6;
  $bdir  = $self->_site_config_get('install_dir');
  $bdir .= "/bin";
  $who   = $self->_global_config_get('whoami');
  $who   =~ s/@.*$// if $who; # Just want local part
  $mtaopts = { %{$self->_site_config_get('mta_options')} };
  $result = {
             'aliases' => '',
             'newlist' => $list,
             'oldaliases' => '',
             'oldlist' => '',
             'owners'  => [],
             'password'=> '',
            };

  %args = ('bindir'     => $bdir,
	   'topdir'     => $self->{'topdir'},
           'mj_domain'  => $self->{'domain'},
	   'domain'     => $dom,
	   'whoami'     => $who,
	   'options'    => $mtaopts,
	   'queue_mode' => $self->_site_config_get('queue_mode'),
	   'domain_priority' => $self->_global_config_get('priority') || 0,
	  );

  $self->_fill_lists;

  # Destroy mode: remove the list, but only if it has no subscribers.
  if ($mode =~ /destroy/) {
    # XLANG
    return (0, "The GLOBAL and DEFAULT lists cannot be destroyed.\n")
      if ($list eq 'GLOBAL' or $list eq 'DEFAULT');

    $desc = $list;
    # valid_list calls _make_list and untaints the name
    ($list, undef, $mess) = $self->valid_list($desc);
    return (0, $mess) unless ($list);

    ($ok, $mess) = $self->{'lists'}{$list}->get_start('MAIN');
    return (0, $mess) unless $ok;

    if ($self->{'lists'}{$list}->get_chunk('MAIN', 1)) {
      $self->{'lists'}{$list}->get_done('MAIN');
      # XLANG
      return (0, "All addresses must be unsubscribed before destruction.\n");
    }

    $self->{'lists'}{$list}->get_done('MAIN');

    unless ($args{'options'}{'maintain_config'}) {
      $aliases = $self->_list_config_get($list, 'aliases');
      $digests = $self->_list_config_get($list, 'digests');
      $sublists = $self->_list_config_get($list, 'sublists');
      $priority = $self->_list_config_get($list, 'priority');
      $debug = $self->_list_config_get($list, 'debug');

      $args{'aliases'}  = {%$aliases};
      $args{'debug'}    = $debug;
      $args{'digests'}  = [keys(%{$digests})];
      $args{'priority'} = $priority || 0;
      $args{'sublists'} = [keys(%{$sublists})];
      $args{'list'} = $list;

      {
        no strict 'refs';
        $result->{'oldaliases'} = &{"Mj::MTAConfig::$mta"}(%args);
      }
    }

    # Prefix a comma to the list directory name.  Suffix a version number.
    for ($desc = 0; ; $desc++) {
      last unless (-d "$self->{'ldir'}/,$list.$desc");
    }

    rename("$self->{'ldir'}/$list", "$self->{'ldir'}/,$list.$desc");
    # XLANG
    return (0, "Unable to remove all of the files for $list.\n")
      if (-d "$self->{'ldir'}/$list");

    delete $self->{'lists'}{$list};
  }
  elsif ($mode =~ /rename/) {

    return (0, "The GLOBAL and DEFAULT lists cannot be renamed.\n")
      if ($list eq 'GLOBAL' or $list eq 'DEFAULT');

    # old list must exist
    $i = $list;
    ($list, undef, $mess) = $self->valid_list($i);
    return (0, $mess) unless ($list);

    # new list name must be valid
    return (0, $self->format_error('invalid_list', 'GLOBAL', 
                                   'LIST' => $pw))
      unless ($newlist = legal_list_name($pw));

    # new list must not exist
    # XLANG
    return (0, "The \"$newlist\" list already exists.\n")
      if (exists $self->{'lists'}{$newlist});

    $result->{'newlist'} = $newlist;
    $result->{'oldlist'} = $list;

    unless ($args{'options'}{'maintain_config'}) {
      $aliases = $self->_list_config_get($list, 'aliases');
      $debug = $self->_list_config_get($list, 'debug');
      $digests = $self->_list_config_get($list, 'digests');
      $priority = $self->_list_config_get($list, 'priority');
      $sublists = $self->_list_config_get($list, 'sublists');

      $args{'aliases'}  = {%$aliases};
      $args{'debug'}    = $debug;
      $args{'digests'}  = [keys(%{$digests})];
      $args{'priority'} = $priority || 0;
      $args{'sublists'} = [keys(%{$sublists})];
      $args{'list'} = $list;

      {
        no strict 'refs';
        $result->{'oldaliases'} = &{"Mj::MTAConfig::$mta"}(%args);
      }
    }

    # replace the entries in the registry
    $regsub =
      sub {
        my $key = shift;
        my $data = shift;
        my (@lists, @tmp, $change);
        $change = 0;

        @tmp = split ("\002", $data->{'lists'});
        @lists = map { if ($_ eq $list) {
                         $_ = $newlist;
                         $change++;
                       }
                       $_;
                     } @tmp;


        if ($change) {
          $data->{'lists'} = join ("\002", @lists);
          return (0, $data, '');
        }
        return (0, 0, 0);
      };

    $self->{'reg'}->mogrify($regsub);

    # rename directory
    rename("$self->{'ldir'}/$list", "$self->{'ldir'}/$newlist");

    # instantiate new list
    return (0, $self->format_error('make_list', 'GLOBAL',
                                   'LIST' => $newlist))
      unless ($self->_make_list($newlist));

    # re-parse the configuration files
    for $j ($self->{'lists'}{$newlist}->_fill_config) {
      $self->_list_config_regen($newlist, $j);
    }

    # rename archive files
    $self->{'lists'}{$newlist}->rename_archive($list);

    # delete old list
    delete $self->{'lists'}{$list};
  }

  # Should the MTA configuration be regenerated?
  if ($mode =~ /regen|destroy|rename/) {
    unless ($mta && $Mj::MTAConfig::supported{$mta}) {
      # XLANG
      return (1, "Unsupported MTA $mta, can't regenerate configuration.\n");
    }

    # Convert the raw data in the installation default configuration
    # settings into parsed data.
    if ($mode =~ /regen/) {
      $self->_fill_lists;
      for $i (keys %{$self->{'lists'}}) {
	next unless ($self->_make_list($i));
	for $j ($self->{'lists'}{$i}->_fill_config) {
	  $self->_list_config_regen($i, $j);
	}
      }
    }

    # Synchronize the GLOBAL:owners auxiliary list with the current group
    # of list owners.
    $self->sync_owners($requ);

    # Extract lists and owners
    $args{'regenerate'} = 1;
    $args{'lists'} = [];
    $self->_fill_lists;
    for $i (keys %{$self->{'lists'}}) {
      $aliases  = $self->_list_config_get($i, 'aliases');
      $debug    = $self->_list_config_get($i, 'debug');
      $digests  = $self->_list_config_get($i, 'digests');
      $priority = $self->_list_config_get($i, 'priority') || 0;
      $sublists = $self->_list_config_get($i, 'sublists');

      push @{$args{'lists'}}, {
                               'list'     => $i,
			       'aliases'  => $aliases,
			       'debug'    => $debug,
			       'digests'  => [keys(%{$digests})],
			       'priority' => $priority,
			       'sublists' => [keys(%{$sublists})],
			      };
    }
    {
      no strict 'refs';
      $result->{'aliases'} = &{"Mj::MTAConfig::$mta"}(%args);

      # Obtain the new aliases if the list has been renamed.
      if ($mode =~ /rename/ and ! $args{'options'}{'maintain_config'}) {
        $args{'regenerate'} = 0;
        $args{'list'} = $newlist;
        $result->{'aliases'} = &{"Mj::MTAConfig::$mta"}(%args);
      }
    }

    shell_hook('name'    => 'createlist-regen', 
               'cmdargs' => [ $self->domain ]);

    return (1, $result);
  }

  @tmp = split "\002\002", $owner;
  return (0, "No owner address was specified.\n") unless @tmp; # XLANG
  for $owner (@tmp) {
    $i = new Mj::Addr($owner);
    return (0, $self->format_error('undefined_address', 'GLOBAL'))
      unless (defined $i);
    ($ok, $mess, $loc) = $i->valid;
    $tmp = $self->format_error($mess, 'GLOBAL');
    return (0, $self->format_error('invalid_address', 'GLOBAL', 
                                   'ADDRESS' => $owner,
                                   'ERROR'   => $tmp, 'LOCATION' => $loc))
      unless $ok;
    push @owners, $i;
  }

  if (defined($pw) and length($pw)) {
    return (0, $self->format_error('password_length', 'GLOBAL'))
      if (length($pw) < $pwl);
  }
  else {
    $pw = &gen_pw($pwl);
  }

  # Should a list be created?
  if ($mode !~ /nocreate/) {
    # XLANG
    return (0, "The \"$list\" list already exists.\n")
      if ($list eq 'default' or $list eq 'global');

    if ($list ne 'GLOBAL') {
      # Untaint $list - we know it's a legal name, so no slashes, so it's safe
      $list =~ /(.*)/; $list = $1;
      $dir  = "$self->{'ldir'}/$list";

      # XLANG
      return (0, "The \"$list\" list already exists.\n")
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
    return (0, $self->format_error('make_list', 'GLOBAL',
                                   'LIST' => $list))
      unless ($self->_make_list($list));
    @tmp = ();
    for $j (@owners) {
      push @tmp, $j->strip;
    }
    $self->_list_config_set($list, 'owners', @tmp);
    $self->_list_config_set($list, 'master_password', $pw);
    if ($mode =~ /inactive/) {
      $self->_list_config_set($list, 'active', 0);
    }

    $self->_list_config_unlock($list);

    if ($self->_list_config_get($list, 'active')) {
      $result->{'inactive'} = '';
    }
    else {
      $result->{'inactive'} = " ";
    }

    $result->{'noarchive'} = " ";
    unless ($list eq 'GLOBAL' or $list eq 'DEFAULT' or $mode =~ /noarchive/) {
      $self->{'lists'}{$list}->fs_mkdir('public/archive', 'List archives');
      $result->{'noarchive'} = '';
    }

    $result->{'welcome'} = '';
    # Send an introduction to the list owner.
    unless ($mode =~ /nowelcome/) {
      $result->{'welcome'} = " ";
      $sender = $self->_global_config_get('sender');

      $subs = {
       $self->standard_subs($list),
       'PASSWORD' => $pw,
      };

      for $owner (@owners) {
        $subs->{'USER'} = $owner->strip;
        ($file, %data) = $self->_list_file_get(list => 'GLOBAL',
					       file => 'new_list',
					       subs => $subs,
					      );
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
  }
  else {
    # In "nocreate" mode, display the aliases instead of adding them
    # to the file.
    $args{'options'}{'maintain_config'} = 0;
  }

  ($i) = $self->valid_list($list);
  # If the list already exists, use its settings to determine
  # the aliases.
  if ($i) {
    $aliases  = $self->_list_config_get($list, 'aliases');
    $debug    = $self->_list_config_get($list, 'debug');
    $digests  = $self->_list_config_get($list, 'digests');
    $priority = $self->_list_config_get($list, 'priority');
    $sublists = $self->_list_config_get($list, 'sublists');
  }
  # otherwise, use the DEFAULT list and templates to determine
  # the correct values.
  else {
    $sources = {
                'aliases'  => 'MAIN',
                'debug'    => 'MAIN',
                'digests'  => 'MAIN',
                'priority' => 'MAIN',
                'sublists' => 'MAIN',
               };

    @defaults = $self->_list_config_get('DEFAULT', 'config_defaults');
    for $i (keys %$sources) {
      for $j (@defaults) {
        if ($self->config_get_whence('DEFAULT', $j, $i) eq 'MAIN') {
          $sources->{$i} = $j;
          last;
        }
      }
    }

    $self->_list_set_config('DEFAULT', $sources->{'aliases'});
    $aliases = $self->_list_config_get('DEFAULT', 'aliases');

    $self->_list_set_config('DEFAULT', $sources->{'digests'});
    $digests = $self->_list_config_get('DEFAULT', 'digests');

    if (exists $aliases->{'auxiliary'}) {
      $self->_list_set_config('DEFAULT', $sources->{'sublists'});
      $sublists = $self->_list_config_get('DEFAULT', 'sublists');
    }

    $self->_list_set_config('DEFAULT', $sources->{'priority'});
    $priority = $self->_list_config_get('DEFAULT', 'priority');
    $self->_list_set_config('DEFAULT', $sources->{'debug'});
    $debug = $self->_list_config_get('DEFAULT', 'debug');
    $self->_list_set_config('DEFAULT', 'MAIN');
  }

  $args{'aliases'}  = {%$aliases};
  $args{'debug'}    = $debug;
  $args{'digests'}  = [keys(%{$digests})];
  $args{'priority'} = $priority || 0;
  $args{'sublists'} = [keys(%{$sublists})];

  {
    no strict 'refs';
    $result->{'aliases'}  = &{"Mj::MTAConfig::$mta"}(%args, 'list' => $list);
    $result->{'owners'}   = [ @owners ];
    $result->{'password'} = $pw;
  }

  shell_hook('name'    => 'createlist-regen', 
             'cmdargs' => [ $self->domain ]);
  return (1, $result);
}

=head2 sync_owners

A complete list of mailing list owners is kept in the GLOBAL::owners
auxiliary list.  This routine synchronizes the auxiliary list with
the contents of each "owners" configuration setting.

=cut

sub sync_owners {
  my ($self, $requ) = @_;
  my (%owners, %seen, @deletions, @tmp, $addr, $data, $i, $j, $lists, $out,
      $owners, $strip, $time);
  my $log = new Log::In 150;
  $self->_fill_lists;
  $out = {};

  for $i (keys %{$self->{'lists'}}) {
    $owners = $self->_list_config_get($i, 'owners');
    for $j (@$owners) {
      $addr = new Mj::Addr($j);
      next unless $addr->isvalid;
      $strip = $addr->strip;
      # If this address has already been processed, update its
      # data and continue.
      if (exists $out->{$strip}) {
        push @{$out->{$strip}}, $i;
        next;
      }
      else {
        $out->{$strip} = [$i];
        $owners{$strip} = $addr;
      }
    }
  }
  for $addr (keys %owners) {
    $time = $::log->elapsed;
    $data = $self->{'lists'}{'GLOBAL'}->is_subscriber($owners{$addr}, 'owners');
    $lists = join "\002", sort @{$out->{$addr}};

    if ($data) {
      $data->{'groups'} = $lists;
      $self->{'lists'}{'GLOBAL'}->update('', $owners{$addr}, 'owners', $data);
    }
    else {
      $self->{'lists'}{'GLOBAL'}->add('', $owners{$addr}, 'owners',
                                      'groups' => $lists);

      $self->inform('GLOBAL', 'subscribe', $requ, $addr,
                    "subscribe GLOBAL:owners $addr",
                    $self->{'interface'}, 1, 1, 1,
                    '', $::log->elapsed - $time);
    }
  }
  # Synchronize the GLOBAL::owners sublist with the current
  # set of owners by iterating over all of the addresses and
  # removing those that are not currently list owners.
  $self->{'lists'}{'GLOBAL'}->get_start('owners');
  while (1) {
    @tmp = $self->{'lists'}{'GLOBAL'}->get_chunk('owners', 1000);
    last unless @tmp;
    for $i (@tmp) {
      unless (exists $out->{$i->{'stripaddr'}}) {
        push @deletions, $i->{'stripaddr'};
      }
    }
  }
  $self->{'lists'}{'GLOBAL'}->get_done('owners');
  for $i (@deletions) {
    $time = $::log->elapsed;
    $addr = new Mj::Addr($i);
    next unless $addr;
    $self->_unsubscribe('GLOBAL', $requ, $addr, '',
                        "unsubscribe GLOBAL:owners $addr", 'owners');
    $self->inform('GLOBAL', 'unsubscribe', $requ, $addr,
                  "unsubscribe GLOBAL:owners $addr",
                  $self->{'interface'}, 1, 1, 0, '',
                  $::log->elapsed - $time);
  }
  return (1, $out);
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
  my (@desc, @req, @sup, $d, $deliveries, $digests, $force, $i, $issues,
      $mess, $owner, $sender, $subs, $tmpdir, $whereami);

  $digests = $self->_list_config_get($list, 'digests');
  # XLANG
  return (0, "No digests have been configured for the $list list.\n")
    unless (ref ($digests) eq 'HASH' and scalar (keys %$digests));

  for $i (keys(%$digests)) {
    next if ($i eq 'default_digest');
    push (@sup, $i);
    push (@desc, $digests->{$i}->{'desc'});
  }

  # Obtain the list of requested digests by splitting on commas.
  @req = split (/\s*,\s*/, $digest);
  if (grep ({$_ eq 'ALL'} @req) or ! scalar (@req)) {
    # Use all digests if "ALL" was requested.
    @req = @sup;
  }
  else {
    map { $_ = lc $_ } @req;
    for $i (@req) {
      unless (grep { $_ eq $i } @sup) {
        # XLANG
        return (0, "The $i digest is not supported for the $list list.\n");
      }
    }
  }

  $d = [ @req ];

  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);

  # status:  return data but make no changes.
  if ($mode =~ /status/) {
    $i = $self->{'lists'}{$list}->digest_examine($d, 0);
    return (1, $i) if $i;
    # XLANG
    return (0, qq(Nothing is known about the "$digest" digest.\n"));
  }

  # check, force: call do_digests
  if ($mode =~ /(check|force)/) {
    # A simple substitution hash; do_digests will add to it
    $sender   = $self->_list_config_get($list, 'sender');
    $owner    = $self->_list_config_get($list, 'whoami_owner');
    $whereami = $self->_global_config_get('whereami');
    $tmpdir   = $self->_global_config_get('tmpdir');
    $subs = {
              $self->standard_subs($list),
              'DATE'   => scalar(localtime()),
              'HOST'   => $self->_list_config_get($list, 'resend_host'),
              'MSGNO'  => '',
              'SENDER' => $sender,
              'SEQNO'  => '',
              'SUBJECT' => '',
              'SUBSCRIBED' => '',
              'USER'   => $sender,
	    };
    if ($mode =~ /force/) {
      $force = 1;
    }
    else {
      $force = 0;
    }

    $issues = {};

    while (1) {
      $deliveries = {};
      $self->do_digests(
                        'deliveries' => $deliveries,
                        'force'      => $force,
                        'list'       => $list,
                        'run'        => $d,
                        'sender'     => $owner,
                        'substitute' => $subs,
                        'tmpdir'     => $tmpdir,
                        'whereami'   => $whereami,
                        # 'msgnum' => undef, 'arcdata' => undef,
                       );

      # Deliver then clean up
      if (keys %$deliveries) {
        $self->deliver($list, '', $sender, $deliveries);
        for $i (keys %$deliveries) {
          unlink $deliveries->{$i}{file}
            if $deliveries->{$i}{file};
          $i =~ s/^digest-(.+)-(\w+)$/$1/;
          $issues->{$i}++ if ($2 eq 'index');
        }
      }
      else {
        last;
      }
      last unless ($mode =~ /repeat/);
    }

    return (1, $issues);
  }

  # incvol: call list->digest_incvol
  if ($mode =~ /incvol/) {
    $self->{'lists'}{$list}->digest_incvol($d);
    return (1, '');
  }

  $mess = $self->format_error('digest_mode', $list,
                              'DIGESTS' => \@sup,
                              'DIGEST_DESCRIPTIONS' => \@desc,
                              'MODES' => [qw(check force incvol status)]);

  return (0, $mess);
}

=head2 _digest_get_headers

Obtain a list of digest headers from the message_headers, precedence,
sender, and reply_to settings.

=cut
sub _digest_get_headers {
  my $self = shift;
  my $list = shift;
  my $subs = shift;
  my $log = new Log::In 350, $list;
  my (@headers, $i, $name, $value);

  return unless $self->_make_list($list);

  for $i ($self->_list_config_get($list, 'message_headers')) {
    $i = $self->substitute_vars_string($i, $subs);
    if ($i =~ /^([^\x00-\x1f\x7f-\xff :]+):(.*)$/) {
      push @headers, [$1, $2];
    }
  }
  if ($i = $self->_list_config_get($list, 'precedence')) {
    push @headers, ['Precedence', $i];
  }
  if ($i = $self->_list_config_get($list, 'sender')) {
    push @headers, ['Sender', $i];
    push @headers, ['Errors-To', $i];
  }
  if ($i = $self->_list_config_get($list, 'reply_to')) {
    $i = $self->substitute_vars_string($i, $subs);
    push @headers, ['Reply-To', $i];
  }

  return @headers;
}

=head2 lists

Obtain data about mailing lists at this domain and
return a hashref of data for each list that is visible.

=cut

sub lists {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'mode'}";
  my ($mess, $ok);

  # Check access
  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_lists('GLOBAL', $request->{'user'}, $request->{'user'},
                $request->{'mode'}, $request->{'cmdline'},
                $request->{'regexp'}, $request->{'password'}, $ok);
}

sub _lists {
  my $self = shift;
  my ($d, $user, $vict, $mode, $cmd, $regexp, $password, $ok) = @_;
  my $log = new Log::In 35, $mode;
  my (@lines, @lists, @out, @tmp, $cat, $compact, $count, $data,
      $desc, $digests, $expose, $flags, $i, $j, $limit, $list,
      $mess, $ok2, $sublist, $sublists, $testreq);

  $ok ||= 0;

  if ($mode =~ /aux/) {
    return $self->_lists_aux(@_);
  }

  if ($regexp) {
    ($ok2, $mess, $regexp)
      = Mj::Config::compile_pattern($regexp, 0, 'iexact');
    return ($ok2, $mess) unless $ok2;
  }

  $expose = 0;
  $mode ||= $self->_global_config_get('default_lists_format');
  $limit =  $self->_global_config_get('description_max_lines');

  # Stuff the registration information to save lots of database lookups
  $self->_reg_lookup($user);

  if ($mode =~ /short/) {
    $compact = 1;
  }

  @lists = $self->get_all_lists($user, $password, $regexp);

  if ($mode =~ /config/) {
    eval ("use Mj::Util qw(re_match)");
    if (re_match($regexp, 'DEFAULT')) {
      push @lists, 'DEFAULT';
    }
    if (re_match($regexp, 'GLOBAL')) {
      push @lists, 'GLOBAL';
    }
  }

  for $list (@lists) {
    # Only list owners and site administrators should be able
    # to see private configuration template names
    # and private auxiliary list names.  To accommodate this,
    # the password is checked against each list, and the "ok"
    # result is upgraded.
    if ($mode =~ /config/) {
      $expose = $self->validate_passwd($user, $password, $list, 'ALL', 0);
      $expose = ($expose > $ok) ? $expose : $ok;
    }
    else {
      $expose = $ok;
    }

    $cat   = $self->_list_config_get($list, 'category');
    $flags = '';

    if ($compact) {
      $desc = $self->_list_config_get($list, 'description');
      unless ($desc) {
        @lines = $self->_list_config_get($list, 'description_long');
        $desc ||= $lines[0];
      }
    }
    else {
      $desc  = '';
      @lines = $self->_list_config_get($list, 'description_long');
      $count = 1;
      for (@lines) {
	$desc .= "$_\n";
	$count++;
	last if ($limit && $count > $limit);
      }
      $desc ||= $self->_list_config_get($list, 'description');
    }

    $data = {
             'category'    => $cat,
             'description' => $desc,
             'flags'       => '',
             'list'        => $list,
            };

    if ($mode =~ /enhanced/) {
      $data->{'flags'} .= 'S'
                         if $self->is_subscriber($user, $list);
    }
    # "full" mode:  return digests, post and subscriber counts, archive URL.
    if ($mode =~ /full/ and $list !~ /^(DEFAULT|GLOBAL)/) {
      $data->{'owner'}    = $self->_list_config_get($list, 'whoami_owner');
      $data->{'address'}  = $self->_list_config_get($list, 'whoami');
      $data->{'subs'}     = $self->{'lists'}{$list}->count_subs;
      $data->{'posts'}    = $self->{'lists'}{$list}->count_posts(30);
      $data->{'archive'}  = $self->_list_config_get($list, 'archive_url');
      $data->{'digests'}  = {};
      $j = {};

      # See if this user can read archives.
      $testreq = {
                   'command'  => 'archive',
                   'list'     => $list,
                   'mode'     => '',
                   'password' => $password,
                   'user'     => $user,
                   'victim'   => $vict,
                 };

      ($data->{'can_read'}) =
        $self->list_access_check($testreq, 'nostall' => 1);

      $digests = $self->_list_config_get($list, 'digests');
      for $i (keys %$digests) {
        next if ($i eq 'default_digest');
        $data->{'digests'}->{$i} =
          $self->{'lists'}{$list}->describe_class('digest', $i, '');
      }
    }
    push (@out, $data) unless ($list =~ /^(DEFAULT|GLOBAL)/);

    # Config mode:  display information about configuration templates.
    if ($mode =~ /config/ and ($expose > 1 or $list =~ /^DEFAULT/)) {
      for $sublist ($self->{'lists'}{$list}->_fill_config) {
        next if ($sublist eq 'MAIN' and $list !~ /^DEFAULT/);
        $desc = '';
        @lines = $self->list_config_get($user, $password, $list,
                                        $sublist, 'comments', 1);
        $count = 1;
        for (@lines) {
          $desc .= "$_\n";
          $count++;
          last if $limit && $count > $limit;
        }

        push @out, { 'list'        => "$list:$sublist",
                     'category'    => 'settings',
                     'description' => $desc,
                     'flags'       => '',
                   };
      }
    }
  }

  return (1, @out);
}

use Mj::Util qw(re_match);
sub _lists_aux {
  my $self = shift;
  my ($d, $user, $vict, $mode, $cmd, $regexp, $password, $ok) = @_;
  my $log = new Log::In 35, $mode;
  my (@lists, @out, $desc, $expose, $flags, $i, 
      $list, $mess, $ok2, $sublists);

  $ok ||= 0;

  if ($regexp) {
    ($ok2, $mess, $regexp)
      = Mj::Config::compile_pattern($regexp, 0, 'iexact');
    return ($ok2, $mess) unless $ok2;
    if (re_match($regexp, 'DEFAULT')) {
      push @lists, 'DEFAULT';
    }
    if (re_match($regexp, 'GLOBAL')) {
      push @lists, 'GLOBAL';
    }
  }

  $expose = 0;

  # Stuff the registration information to save lots of database lookups
  $self->_reg_lookup($user);

  push @lists, $self->get_all_lists($user, $password, $regexp);

  for $list (@lists) {
    # Only list owners and site administrators should be able
    # to see private auxiliary list names.  To accommodate this,
    # the password is checked against each list, and the "ok"
    # result is upgraded.
    $expose = $self->validate_passwd($user, $password, $list, 'ALL', 0);
    $expose = ($expose > $ok) ? $expose : $ok;

    $self->{'lists'}{$list}->_fill_aux;
    $sublists = {};

    # If a master password was given, show all auxiliary lists by merging
    # together those in the sublist setting with those that aren't.
    if ($expose > 1) {
      $sublists = { %{$self->_list_config_get($list, "sublists")}};
      for $i (keys %{$self->{'lists'}{$list}->{'sublists'}}) {
        next if ($i eq 'MAIN');
        next if exists $sublists->{$i};
        $sublists->{$i} = '';
      }
    }
    elsif ($list ne 'DEFAULT' and $list ne 'GLOBAL') {
      $sublists = { %{$self->_list_config_get($list, "sublists")}};
    }
    else {
      # DEFAULT and GLOBAL have no public sublists
      return (1, '');
    }
    
    for $i (keys %{$sublists}) {
      next if ($i eq 'MAIN');
      $desc = $sublists->{$i};
      $flags = '';
      if ($mode =~ /enhanced/) {
        $flags = 'S'
          if ($self->{'lists'}{$list}->is_subscriber($user, $i));
      }
      push @out, {
                  'category'    => 'sublist',
                  'description' => $desc,
                  'flags'       => $flags,
                  'list'        => "$list:$i",
                  'posts' => $self->{'lists'}{$list}->count_posts(30, $i),
                  'subs'  =>
                    $self->{'lists'}{$list}->count_subs($i) || 0,
                 };
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
use IO::File;
sub reject {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "@{$request->{'tokens'}}";
  my (%file, @out, $ack_attach, $data, $desc, $ent, $file, $in, $inf,
      $inform, $line, $list_owner, $mess, $mj_addr, $mj_owner, $ok,
      $owner, $reason, $rejecter, $repl, $rfile, $sess, $sfile, $site, 
      $t, $tmp, $token, $victim);

  return (0, $self->format_error('no_token', 'GLOBAL'))
    unless (scalar(@{$request->{'tokens'}}));

  $site       = $self->_global_config_get('site_name');
  $mj_addr    = $self->_global_config_get('whoami');
  $mj_owner   = $self->_global_config_get('sender');

  for $t (@{$request->{'tokens'}}) {

    if (defined $t) {
      $token = $self->t_recognize($t);
    }
    if (! $token) {
      push @out, 0,
        $self->format_error('invalid_token', 'GLOBAL', 'TOKEN' => $t);
      next;
    }

    ($ok, $data) = $self->t_reject($token);

    if (! $ok) {
      push @out, $ok, $data;
      next;
    }

    # Send no notification messages if quiet mode is used.
    if ($request->{'mode'} =~ /quiet/) {
      push @out, $ok, [$token, $data];
      next;
    }

    $reason = $rfile = '';
    if ($data->{'type'} ne 'consult') {
      $rfile = 'token_reject';
      if (length $request->{'xplanation'}) {
        $reason = $request->{'xplanation'};
      }
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
    $list_owner = $self->_list_config_get($data->{'list'}, 'whoami_owner');
    if (! $list_owner) {
      # This will cope with the inability to create a list.
      push @out, $ok, [$token, $data];
      push @out, 0, 
        qq(Unable to determine the owner of the \"$data->{'list'}\" list.);
      next;
    }

    $rejecter = "$request->{'user'}";
    if ($rejecter =~ /^.([\d\.]+)\@example.com$/) {
      $rejecter = "IP address $1";
    }
    
    $data->{'ack'} = 0;
    $repl = {
         $self->standard_subs($data->{'list'}),
         'CMDLINE'    => $data->{'cmdline'},
         'COMMAND'    => $data->{'command'},
         'DATE'       => scalar localtime($data->{'time'}),
         'MESSAGE'    => $reason,
         'REJECTER'   => $rejecter,
         'REQUESTER'  => $data->{'user'},
         'SESSIONID'  => $data->{'sessionid'},
         'TOKEN'      => $token,
         'VICTIM'     => $data->{'victim'},
        };

    $data->{'sublist'} = '';
    if ($data->{'command'} eq 'post') {
      my %avars = split("\002", $data->{'arg3'});
      $data->{'sublist'} = $avars{'sublist'} || '';
    }
    $victim = new Mj::Addr($data->{'victim'});

    # For confirmation tokens, or if the 'ackreject' flag is set,
    # a notice is sent to the victim
    if ($data->{'type'} eq 'confirm'
          or
        $self->{'lists'}{$data->{'list'}}->should_ack($data->{'sublist'},
                                                      $victim, 'j')
       )
    {
      $data->{'ack'} = 1;
      ($file, %file) = $self->_list_file_get(list => $data->{'list'},
					     file => $rfile,
					     subs => $repl,
					    );
      unless (defined $file) {
        ($file, %file) =
          $self->_list_file_get(list => $data->{'list'},
				file => "token_reject",
				subs => $repl,
			       );
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
         -From       => $repl->{'OWNER'},
         -To         => $data->{'victim'},
         -Subject    => $desc,
         'Content-Language:' => $file{'language'},
        );

      if ($ent) {
        $ack_attach = $self->_list_config_get($data->{'list'},
                                              'ack_attach_original');

        ($tmp, $sfile) = $self->s_recognize($data->{'sessionid'}, 0);

        if ($data->{'command'} eq 'post' and (-f $data->{'arg1'})
           and ($ack_attach->{'reject'} or $ack_attach->{'all'})) {
          $ent->make_multipart;
          # XLANG
          $ent->attach(
                       'Description' => 'Original message',
                       'Filename'    => undef,
                       'Path'        => $data->{'arg1'},
                       'Type'        => 'message/rfc822',
                       'Encoding'    => '8bit',
                      );
        }
        elsif ($tmp and -f $sfile) {
          $ent->make_multipart;
          # XLANG
          $ent->attach(
            'Description' => "Information about session $data->{'sessionid'}",
            'Filename'    => undef,
            'Path'        => $sfile,
            'Type'        => 'text/plain',
            'Encoding'    => '8bit',
          );
        }

        $self->mail_entity($mj_owner, $ent, $data->{'victim'});
        unlink $file;
      }
    }

    # Send a message to the list owner and majordomo owner if appropriate
    if ($data->{'type'} eq 'confirm'
        and $request->{'mode'} !~ /nolog|noinform/)
    {
      ($file, %file) = $self->_list_file_get(list => $data->{'list'},
                                             file => "token_reject_owner",
					    );
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
        ($tmp, $sfile) = $self->s_recognize($data->{'sessionid'}, 0);
        if ($tmp and -f $sfile) {
          $ent->make_multipart;
          # XLANG
          $ent->attach(
                       'Description' => "Information for session $data->{'sessionid'}",
                       'Filename'    => undef,
                       'Path'        => $sfile,
                       'Type'        => 'text/plain',
                       'Encoding'    => '8bit',
                      );
        }

        if ($inf & 2) {
          $self->mail_entity($mj_owner, $ent, $list_owner)
            if ($list_owner);
        }

        # Should we inform majordomo-owner?
        if ($data->{'list'} !~ /^(GLOBAL|ALL)$/) {
          $inform = $self->_global_config_get('inform');
          $inf = $inform->{'reject'}{'all'} || $inform->{'reject'}{1} || 0;
          if ($inf & 2) {
            $ent->head->replace('To', $mj_owner);
            $self->mail_entity($mj_owner, $ent, $mj_owner)
              if ($mj_owner);
          }
        }
        unlink $file;
      }
    }
    push @out, $ok, [$token, $data];
  }
  @out;
}

=head2 register

This adds a user to the registration database without actually adding them
to any lists.

Modes: password   - assign the password that is specified

else a password is assigned randomly.

XXX Add a way to take additional data, like the language.

=cut

sub register {
  my ($self, $request) = @_;
  my ($ok, $error);
  my $log = new Log::In  30, "$request->{'victim'}, $request->{'mode'}";

  $request->{'newpasswd'} ||= '';

  # Do a list_access_check here for the address; subscribe if it succeeds.
  # The access mechanism will automatically generate failure notices and
  # confirmation tokens if necessary.
  ($ok, $error) = $self->list_access_check($request);

  unless ($ok > 0) {
    $log->message(30, "info", "noaccess");
    return ($ok, $error);
  }
  $self->_register('', $request->{'user'}, $request->{'victim'}, $request->{'mode'},
                       $request->{'cmdline'}, $request->{'newpasswd'});
}

use Mj::Util qw(gen_pw);
sub _register {
  my $self  = shift;
  my $d     = shift;
  my $requ  = shift;
  my $vict  = shift;
  my $mode  = shift;
  my $cmd   = shift;
  my $pw    = shift;
  my $log   = new Log::In 35, "$vict";
  my ($data, $exist, $ok, $welcome, $welcome_table);

  if (!defined $pw || !length($pw)) {
    $d = $self->_global_config_get('password_min_length');
    $pw = &gen_pw($d);
  }

  # Add to/update registration database
  ($exist, $data) = $self->_reg_add($vict, 'password' => $pw);

  # We shouldn't fail, because we trust the reg. database to be correct
  if ($exist) {
    # XLANG
    $log->out("failed, existing");
    return (0, "$vict is already registered as $data->{'fulladdr'}.\n");
  }

  $welcome = $self->_global_config_get('welcome');
  $welcome = 1 if $mode =~ /welcome/;
  $welcome = 0 if $mode =~ /(nowelcome|quiet)/;

  if ($welcome) {
    $welcome_table = $self->_global_config_get('welcome_files');
    $ok = $self->welcome('GLOBAL', $vict, $welcome_table,
			 'PASSWORD'   => $pw,
                         'REGISTERED' => 0);
    unless ($ok) {
      # Perhaps complain to the list owner?
    }
  }
  return (1, [$vict]);
}

=head2 r_expire

Expire registration entries that have been inactive for too long.
Inactive registrations have no subscriptions.  The expiration age
is determined by the GLOBAL inactive_lifetime setting.

=cut
sub r_expire {
  my $self = shift;
  my (@nuked, $age, $expiretime, $time);
  my $log = new Log::In 250;

  $time = time;
  $age = $self->_global_config_get('inactive_lifetime');
  if (defined $age and $age =~ /^\+?\d+$/) {
    $expiretime = $time - $age * 86400;
  }
  else {
    return 1;
  }

  my $mogrify = sub {
    my $key  = shift;
    my $data = shift;

    # True if we have an inactive account
    my $i = ($data->{lists} =~ /^[\s\002]*$/ &&
             $expiretime > $data->{changetime}
            );
    if ($i) {
      push @nuked, ($key, $data);
      return (1, 1, undef);
    }
    return (0, 0);
  };

  $self->{'reg'}->mogrify($mogrify);
  return (1, @nuked);
}

=head2 rekey(...)

This causes the list to rekey itself.  In other words, this recomputes the
keys for all of the rows of all of the databases based on the current
address transformations.  This must be done when the transformations
change, else address matching will fail to work properly.

=cut

sub rekey_start {
  my ($self, $request) = @_;
  my $log = new Log::In 30;
  my ($mess, $ok);
  $request->{'regexp'} ||= '';

  if ($request->{'regexp'}) {
    ($ok, $mess, $request->{'regexp'})
      = Mj::Config::compile_pattern($request->{'regexp'}, 0, 'iexact');
    return ($ok, $mess) unless $ok;
  }

  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }

  $self->_rekey('', $request->{'user'}, $request->{'user'},
                $request->{'mode'}, $request->{'cmdline'},
                $request->{'regexp'});
}

sub _rekey {
  my($self, $d, $requ, $vict, $mode, $cmd, $regexp) = @_;
  my $log = new Log::In 35, $mode;
  my (%seen, @lists, $aa, $aca, $changed, $dry, $list, 
      $ra, $rca, $sub);

  if ($mode =~ /noxform/) {
    $dry = 1;
  }
  else {
    $dry = 0;
  }

  # Rekey the alias database
  $aca = $aa = 0;

  $sub =
    sub {
      my $key  = shift;
      my $data = shift;
      my (@out, $addr, $addr2, $changekey, $source, $target);

      # Allocate an Mj::Addr object and transform it.
      # In the aliases database, each set of data appears 
      # twice, under two different keys.
      $addr = new Mj::Addr($data->{'stripsource'});
      $addr2 = new Mj::Addr($data->{'striptarget'});

      # Skip this record if it is not a valid address.
      return (0, 0, 0) unless $addr;
      return (0, 0, 0) unless $addr2;

      $aa++;
      $source = $addr->xform;
      $target = $addr2->xform;

      if ($target eq $key) {
        # Skip this bookkeeping alias.
        return (0, 0, $target);
      }
      elsif ($source eq $key) {
        # Skip this ordinary alias.
        $seen{$data->{'stripsource'}} = 1;
        return (0, 0, $source);
      }
      else {
        $aca++;
        $changekey = $dry ? 0 : 1;

        if (exists $seen{$data->{'stripsource'}}) {
          return ($changekey, 0, $target);
        }
        else {
          $seen{$data->{'stripsource'}} = 1;
          return ($changekey, 0, $source);
        }
      }
    };

  $self->{'alias'}->mogrify($sub) unless ($mode =~ /verify|repair/);

  # Rekey the registry
  $rca = $ra = 0;

  $sub =
    sub {
      my $key  = shift;
      my $data = shift;
      my (@out, $addr, $newkey, $changekey);

      # Allocate an Mj::Addr object and transform it.
      $addr = new Mj::Addr($data->{'stripaddr'});

      # Skip this record if it is not a valid address.
      return (0, 0, 0) unless $addr;

      $ra++;
      $newkey = $addr->xform;
      if ($newkey ne $key) {
        $rca++;
        $changekey = $dry ? 0 : 1;
      }
      else {
        $changekey = 0;
      }
      return ($changekey, 0, $newkey);
    };

  $self->{'reg'}->mogrify($sub) unless ($mode =~ /verify|repair/);


  # loop over all lists
  $self->_fill_lists;
  @lists = sort keys(%{$self->{'lists'}});
  $self->{'rekey_lists'} = [];
  if ($regexp) {
    require Mj::Util;
    import Mj::Util qw(re_match);
  }

  for $list (@lists) {
    if ($regexp and $mode =~ /verify|repair/) {
      next unless re_match($regexp, $list);
    }
    push (@{$self->{'rekey_lists'}}, $list)
      unless ($mode =~ /verify|repair/ and
              ($list eq 'DEFAULT' or $list eq 'GLOBAL'));
  }
  unless (scalar @{$self->{'rekey_lists'}}) {
    # XLANG
    return (0, "No mailing lists were found for rekeying.\n");
  }
  return (1, $ra, $rca, $aa, $aca);
}

use Mj::Util qw(gen_pw);
sub rekey_chunk {
  my ($self, $request) = @_;
  my $list = shift @{$self->{'rekey_lists'}};
  return unless (defined $list);
  my $log = new Log::In 35, "$list, $request->{'mode'}";
  my ($addr, $changed, $chunksize, $count, $data, $dry,
      $minlength, $pw, $reg, $unreg, $unsub);

  $chunksize = $self->_global_config_get('chunksize') || 1000;
  $minlength = $self->_global_config_get('password_min_length');
  $reg = '';
  $reg = $self->{'reg'} if ($request->{'mode'} =~ /repair|verify/);
  if ($request->{'mode'} =~ /noxform/) {
    $dry = 1;
  }
  else {
    $dry = 0;
  }

  if ($self->_make_list($list)) {
    ($count, $unsub, $unreg, $changed) =
      $self->{'lists'}{$list}->rekey($reg, $chunksize, $dry);

    if ($request->{'mode'} =~ /repair/) {
      for $addr (keys %$unreg) {
        unless ($data = new Mj::Addr($addr)) {
          delete $unreg->{$addr};
          next;
        }
        $pw = &gen_pw($minlength);
        $self->_reg_add($data, 'list' => $list, 'password' => $pw);
      }
      for $addr (keys %$unsub) {
        unless ($data = new Mj::Addr($addr)) {
          delete $unsub->{$addr};
          next;
        }
        $self->{'lists'}{$list}->add('', $data, '', '', '', '', 'MAIN');
      }
    }
  }
  else {
    return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list));
  }

  return (1, $list, $count, $unsub, $unreg, $changed);
}

sub rekey_done {
  my $self = shift;
  my $request = shift;

  undef $self->{'rekey_lists'};
  1;
}

=head2 report(..., $sessionid)

Display statistics about logged actions for one or more lists.

=cut

sub report_start {
  my ($self, $request) = @_;
  my $log = new Log::In 50,
     "$request->{'list'}, $request->{'user'}";
  my ($action, $mess, $ok);

  unless (ref ($request->{'requests'}) eq 'ARRAY' and
          scalar(@{$request->{'requests'}}) > 0)
  {
    $request->{'requests'} = ['ALL : all'];
  }
  $request->{'action'} = join "\002", @{$request->{'requests'}};

  ($ok, $mess) = $self->list_access_check($request);

  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_report($request->{'list'}, $request->{'user'}, $request->{'user'},
              $request->{'mode'}, $request->{'cmdline'}, $request->{'date'},
              $request->{'action'});
}

use Mj::Archive qw(_secs_start _secs_end);
use Mj::Util qw(str_to_offset);
use IO::File;
use Mj::Config;
sub _report {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $date, $action) = @_;
  my $log = new Log::In 35, "$list, $action";
  my (@table, @tmp, @tmp2, $begin, $end, $file, $i, $j,
      $req, $res, $scope, $span, $tmp);

  $scope = {};

  # Determine which actions are specified to be reported by the
  # "inform" configuration setting.  A request for "ALL" lists will
  # use the GLOBAL inform setting.
  if ($mode =~ /inform/) {
    $tmp = $self->_list_config_get($list, 'inform');
    if ($tmp) {
      for $i (keys %$tmp) {
        for $j (keys %{$tmp->{$i}}) {
          if ($tmp->{$i}{$j} & 1) {
            $scope->{$i}{$j} = 1;
          }
        }
      }
    }
  }
  else {
    @tmp = split "\002", $action;
    $j = 'report';
    # Hack the requested actions into a table that resembles
    # the "inform" configuration setting.
    for ($i = 0; $i < scalar(@tmp); $i++) {
      ($req, $res) = split /\s*[:|]\s*/, $tmp[$i], 2;
      $res ||= 'all';
      @tmp2 = split /[\s,]+/, $req;
      for $tmp (@tmp2) {
        push @table, join (' | ', ($tmp, $res, $j));
      }
    }
    @tmp = Mj::Config::parse_inform('', \@table, 'report_command');
    if (! $tmp[0]) {
      return (0, $tmp[1]);
    }
    $scope = $tmp[$#tmp];
  }
  $self->{'report_scope'} = $scope;

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
    elsif ($span = str_to_offset($date, 0, 0)) {
      $begin = $end - $span;
    }
    else {
      # XLANG
      return (0, "Unable to parse date $date.\n");
    }
  }
  
  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);

  $file = "$self->{'ldir'}/GLOBAL/_log";

  $self->{'report_fh'} = new IO::File "< $file";
  unless ($self->{'report_fh'}) {
    # XLANG
    return (0, "Cannot access the log.\n");
  }
  return (1, [$begin, $end]);
}

sub report_chunk {
  my ($self, $request) = @_;
  my $log = new Log::In 500,
     "$request->{'list'}, $request->{'user'}";
  my (@data, @out, $count, $line, $scope);

  # XLANG
  return (0, "The log file is unopened.\n")
    unless (defined $self->{'report_fh'});

  # XLANG
  return (0, "Invalid chunk size given.\n")
    unless (defined ($request->{'chunksize'}) and $request->{'chunksize'} > 0);

  # XLANG
  return (0, "Unable to determine what to report")
    unless (defined $self->{'report_scope'});

  $request->{'begin'} ||= 0;
  $request->{'end'} ||= time;
  $request->{'chunksize'} ||= 1;
  $scope = $self->{'report_scope'};
  $count = 0;

  while (1) {
    $line = $self->{'report_fh'}->getline;
    last unless $line;
    chomp $line;
    @data = split "\001", $line;
    # check time, list, and action constraints
    next unless (defined $data[9] and $data[9] >= $request->{'begin'}
                 and $data[9] <= $request->{'end'});
    next unless ($data[0] eq $request->{'list'}
                 or $request->{'list'} eq 'ALL');
    next unless (exists ($scope->{'ALL'}{$data[6]}) or
                 exists ($scope->{$data[1]}{$data[6]}));
    push @out, [@data];
    $count++;  last if ($count >= $request->{'chunksize'});
  }

  (1, [@out]);
}

sub report_done {
  my ($self, $request) = @_;
  my $log = new Log::In 50,
     "$request->{'list'}, $request->{'user'}";
  undef $self->{'report_scope'};
  return unless $self->{'report_fh'};
  undef $self->{'report_fh'};
  (1, '');
}

=head2 sessioninfo(..., $sessionid)

Returns the stored text for a given session id.

=cut

use IO::File;
sub sessioninfo_start {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'sessionid'}";
  my ($d1, $d2, $file, $sess);

  # XLANG
  return (0, "You must supply a session identifier.\n")
    unless ($request->{'sessionid'});

  $request->{'sessionid'} =~ s/\s+//g;

  # The session identifier can be a 32-character MD5 digest, or
  # a 40-character SHA-1 digest.
  ($sess, $file) = $self->s_recognize($request->{'sessionid'});
  unless (defined $sess) {
    # XLANG
    return (0, qq(The session ID "$request->{'sessionid'}" is invalid.\n));
  }

  # defined but false means it's a legal ID but doesn't exist
  unless ($sess) {
    # XLANG
    return (0, qq(The session ID "$request->{'sessionid'}" has expired.\n));
  }

  $self->{'get_fh'} = new IO::File $file;
  unless ($self->{'get_fh'}) {
    # XLANG
    return (0, "No such session.\n");
  }

  (1, '');
}

# Included for purposes of logging.
sub sessioninfo_done {
  (shift)->get_done(@_);
}

=head2 s_recognize(id)

The id is examined to see if it is a valid session number.
A session number consists only of digits and lower-case letters,
and is 32 or 40 characters long.

if $nocheck is true, this will validate the form of the ID and return the
full path to the session file but won't check to see if the file exists.

=cut
sub s_recognize {
  my $self    = shift;
  my $id      = shift || "";
  my $nocheck = shift;
  my $log  = new Log::In 60;
  my($d1, $d2, $file);

  if ($id =~ /^([0-9a-f]{32}([0-9a-f]{8})?)$/) {
    $id = $1; # Untaint
    $file = "$self->{ldir}/GLOBAL/sessions/$id";

    if (-f $file && !$nocheck) {
      return ($id, $file) if wantarray;
      return $id;
    }

    $d1 = substr($id, 0, 2);
    $d2 = substr($id, 2, 2);
    $file = "$self->{ldir}/GLOBAL/sessions/$d1/$d2/$id";

    if (-f $file || $nocheck) {
      return ($id, $file, "$self->{ldir}/GLOBAL/sessions/$d1",
	      "$self->{ldir}/GLOBAL/sessions/$d1/$d2")
	if wantarray;
      return $id;
    }
    return (0, $file) if wantarray;
    return 0;
  }
  return;
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
  my ($force, $ok, $mess, $mismatch, $regexp);

  $request->{'setting'} = '' if $request->{'mode'} =~ /check/;
  $request->{'sublist'} ||= 'MAIN';

  my $log = new Log::In 30, "$request->{'list'}, $request->{'setting'}";

  # XLANG
  return (0, "The set command is not supported for the $request->{'list'} list.\n")
    if ($request->{'list'} eq 'GLOBAL' or $request->{'list'} eq 'DEFAULT');


  if ($request->{'mode'} =~ /regex|pattern/) {
    $mismatch = 0;
    $regexp   = 1;
    # Parse the regexp
    ($ok, $mess, $request->{'victim'}) =
       Mj::Config::compile_pattern($request->{'victim'}, 0);
    return (0, $mess) unless $ok;
    # Untaint the regexp
    $request->{'victim'} =~ /(.*)/; $request->{'victim'} = $1;
  }
  else {
    $mismatch = !($request->{'user'} eq $request->{'victim'});
    $regexp   = 0;
  }

  ($ok, $mess) = $self->list_access_check($request,
                                          'mismatch' => $mismatch,
                                          'regexp'   => $regexp);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $mess);
  }
  # If the request succeeds immediately, using the master password,
  # override the allowed_classes and allowed_flags settings if necessary.
  $force = ($ok > 1)? 1 : 0;

  $self->_set($request->{'list'}, $request->{'user'}, $request->{'victim'},
              $request->{'mode'}, $request->{'cmdline'}, $request->{'setting'},
              '', $request->{'sublist'}, $force);
}

sub _set {
  my ($self, $list, $user, $vict, $mode, $cmd, $setting, $d, $sublist, $force) = @_;
  my (%file, @addrs, @headers, @lists, @nuke, @out, @tmp, $addr, 
      $check, $chunksize, $count, $data, $db, $dtype, $file, $finfo, 
      $format, $i, $j, $k, $l, $mess, $ok, $owner, $res, $sd, $subj,
      $subs, $v);

  $check = 0;
  if ($mode =~ /check/ or ! $setting) {
    $check = 1;
  }
  $sd = {};

  if ($mode =~ /regex|pattern/) {
    # Initialize the database
    if ($list eq 'ALL') {
      # XLANG
      return (0, "Unable to initialize registry.\n")
        unless $self->{'reg'}->get_start;
      $db = $self->{'reg'};
    }
    else {
      return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
        unless $self->_make_list($list);
      # XLANG
      return (0, "Unknown auxiliary list name \"$sublist\".")
        unless ($ok = $self->{'lists'}{$list}->valid_aux($sublist));
      $sublist = $ok;

      ($ok, $mess) = $self->{'lists'}{$list}->get_start($sublist);
      return (0, "$mess\n") unless ($ok);

      $db = $self->{'lists'}{$list}->{'sublists'}{$sublist};
    }

    if ($mode =~ /allmatching/) {
      $chunksize = 1000;
    }
    else {
      $chunksize = 1;
    }
    $count = 0;
    while (@tmp = $db->get_matching_regexp($chunksize, 'stripaddr', $vict)) {
      while (($k, $v) = splice @tmp, 0, 2) {
        $count++;
        if ($list eq 'ALL') {
          $data = $v->{'lists'};
        }
        else {
          $data = $list;
        }
        next unless ($addr = new Mj::Addr($k));
        push @addrs, $addr, $data;
      }
      last unless ($mode =~ /allmatching/);
    }
    $db->get_done;
    unless ($count) {
      return (0, $self->format_error('not_subscribed', $list, 
                                     'VICTIM' => $vict));
    }
  }
  else {
    if ($list eq 'ALL') {
      $data = $self->{'reg'}->lookup($vict->canon);
      return (0, $self->format_error('unregistered', 'GLOBAL',
                                     'VICTIM' => $vict->full))
        unless $data;
      $v = $data->{'lists'};
    }
    else {
      $v = $list;
    }
    push @addrs, $vict, $v;
  }

  while (($addr, $data) = splice @addrs, 0, 2) {
    @lists = split("\002", $data);
    push @out, (0, $self->format_error('not_subscribed', $list,
                                       'VICTIM' => $vict->full))
      unless @lists;
    for $l (sort @lists) {
      unless ($self->_make_list($l)) {
        push @out, (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $l));
        next;
      }

      if ($sublist) {
        unless ($ok = $self->{'lists'}{$l}->valid_aux($sublist)) {
          # XLANG
          push @out, (0, "There is no sublist $sublist of the $l list.\n");
          next;
        }
        $sublist = $ok;
      }

      unless (exists $sd->{$l}) {
        $sd->{$l} = $self->{'lists'}{$l}->get_setting_data($sublist);
      }

      ($ok, $res) =
        $self->{'lists'}{$l}->set($addr, $setting, $sublist, $check, $force);

      if ($ok) {
        $res->{'victim'}   = $addr->full;
        $res->{'fulladdr'} = $addr->full;
        $res->{'stripaddr'} = $addr->strip;
        $res->{'list'}     = $l;
        $res->{'sublist'}  = $sublist;
        $res->{'flagdesc'} =
          [$self->{'lists'}{$l}->describe_flags($res->{'flags'})];
        $res->{'classdesc'} =
          $self->{'lists'}{$l}->describe_class(@{$res->{'class'}});
        $res->{'settings'} = $sd->{$l};
        $res->{'partial'} = 0;

        # Issue a partial digest if changing from digest mode
        # to nomail or single mode.
        if (exists $res->{'digest'} and ref $res->{'digest'}
            and exists $res->{'digest'}->{'messages'}
            and scalar(@{$res->{'digest'}->{'messages'}})) {

          $format = $res->{'digest'}->{'index'} ||
                    $self->_list_config_get($l, 'digest_index_format');
          $dtype = $res->{'digest'}->{'type'};
          $owner = $self->_list_config_get($l, 'whoami_owner');

          $subs = { 
                    $self->standard_subs($l),
                    'DATE'   => scalar(localtime()),
                    'DIGESTDESC' => '',
                    'DIGESTNAME' => 'partial',
                    'DIGESTTYPE' => $dtype,
                    'HOST'   => $self->_list_config_get($l, 'resend_host'),
                    'ISSUE'  => 1,
                    'MESSAGECOUNT' => scalar(@{$res->{'digest'}->{'messages'}}),
                    'MSGNO'  => '',
                    'SENDER' => $owner,
                    'SEQNO'  => '',
                    'SUBJECT' => '',
                    'SUBSCRIBED' => '',
                    'USER' => "$addr",
                    'VOLUME' => 1,
                  };

          for $i (qw(preindex postindex footer)) {
            for $j ("digest_partial_${dtype}_${i}", "digest_partial_${i}", 
                    "digest_${dtype}_${i} ", "digest_${i}") 
            {
              ($file, %file) = $self->_list_file_get(list => $l,
                                                     file => $j,
                                                     subs => $subs,
                                                    );
              if ($file) {
                $finfo->{$dtype}{$i}{'name'} = $file;
                $finfo->{$dtype}{$i}{'data'} = \%file;
                push @nuke, $file;
                last;
              }
            }
          }

          for $j ("digest_partial_${dtype}_subject", "digest_partial_subject") {
            $subj = 
              $self->_list_file_get_string(list => $l,
                                           file => $j,
                                           subs => $subs,
                                          );
            last if (defined $subj and length $subj);
          }
                   
          @headers = $self->_digest_get_headers($l, $subs);

          ($file) = $self->{'lists'}{$l}->digest_build
            (messages   => $res->{'digest'}->{'messages'},
             files      => $finfo,
             from       => $owner,
             headers    => \@headers,
             index_line => $format,
             subject    => $subj,
             tmpdir     => $tmpdir,
             to         => "$addr",
             type       => $dtype,
            ); # XLANG

          # Mail the partial digest
          if ($file) {
            $owner = $self->_list_config_get($l, 'sender');
            $self->mail_message($owner, $file, $addr);
            unlink $file;
            $res->{'partial'} = 1;
          }

          unlink @nuke;
        }
      }
      push @out, $ok, $res;
    }
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
  my ($addr);

  # We know each address is valid; the dispatcher took care of that for us.
  $addr = $request->{'victim'};
  ($ok, $error) = $self->list_access_check($request);

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
                   password   => $data->{'password'},
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
      $out{'lists'}{$i} =
	{
	 changetime => $data->{'changetime'},
         class      => $data->{'class'},
         classarg   => $data->{'classarg'},
         classarg2  => $data->{'classarg2'},
	 classdesc  => $self->{'lists'}{$i}->describe_class($data->{'class'},
							    $data->{'classarg'},
							    $data->{'classarg2'},
							   ),
         flags      => $data->{'flags'},
	 flagdesc   => [$self->{'lists'}{$i}->describe_flags($data->{'flags'})],
	 fulladdr   => $data->{'fulladdr'},
         settings   => $self->{'lists'}{$i}->get_setting_data('MAIN'),
	 subtime    => $data->{'subtime'},
	};

      $bouncedata = $self->{'lists'}{$i}->bounce_get($addr);
      if ($bouncedata) {
	$out{'lists'}{$i}{'bouncedata'}  = $bouncedata;
	$out{'lists'}{$i}{'bouncestats'} =
          $self->{'lists'}{$i}->bounce_gen_stats($bouncedata);
      }
    }
  }

  # List ownerships
  $out{'ownerships'} = [];
  (undef, $data) = $self->{'lists'}{'GLOBAL'}->get_member($addr, 'owners');
  if ($data) {
    $out{'ownerships'} = [ split("\002", $data->{'groups'}) ];
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
      # XLANG
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
  my (@out, $data, $token);

  # If we weren't passed any token types, assume "-confirm-consult"
  $mode .= "-confirm-consult" unless
    $mode =~ /(alias|async|confirm|consult|delay|probe)/;

  # We have access; open the token database and start pulling data.
  # XLANG
  return (0, "Unable to initialize token database.\n")
    unless $self->_make_tokendb;

  $self->{'tokendb'}->get_start();
  while (1) {
    ($token, $data) = $self->{'tokendb'}->get(1);
    last unless $token;
    next unless ($data->{'list'} eq $list or $list eq 'ALL'
                 or ($data->{'list'} eq 'ALL' and $list eq 'GLOBAL'));
    next if ($action and ($data->{'command'} ne $action));
    next if ($data->{'type'} eq 'async'   and $mode !~ /async/);
    next if ($data->{'type'} eq 'alias'   and $mode !~ /alias/);
    next if ($data->{'type'} eq 'confirm' and $mode !~ /confirm/);
    next if ($data->{'type'} eq 'consult' and $mode !~ /consult/);
    next if ($data->{'type'} eq 'delay'   and $mode !~ /delay/);
    next if ($data->{'type'} eq 'probe'   and $mode !~ /probe/);

    # Obtain file size for posted messages
    if ($data->{'command'} eq 'post') {
      $data->{'size'} = (stat $data->{'arg1'})[7];
    }
    else {
      $data->{'size'} = '';
    }
    $data->{'token'} = $token;

    # Stuff the data
    push @out, $data;
  }

  $self->{'tokendb'}->get_done;
  return (1, @out);
}

=head2 sublist (request)

The sublist command creates, destroys, or displays information about
one auxiliary list (sublist).

=cut
sub sublist {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'list'}, $request->{'sublist'}";
  my ($mess, $ok);

  ($ok, $mess) = $self->list_access_check($request);
  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $self->_sublist($request->{'list'}, $request->{'user'}, $request->{'victim'},
                  $request->{'mode'}, $request->{'cmdline'}, 
                  $request->{'sublist'});
}

sub _sublist {
  my ($self, $list, $requ, $vict, $mode, $cmd, $sublist) = @_;
  my $log = new Log::In 35, "$list, $sublist";
  my ($desc, $mess, $ok, $sublists);

  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);
 
  return (0, $self->format_error('no_sublist', $list, 'COMMAND' => 'sublist'))
    unless (defined $sublist and length $sublist);

  $sublist = lc $sublist unless ($sublist eq 'MAIN');

  if ($mode =~ /create/) {
    ($ok, $mess) = $self->{'lists'}{$list}->aux_create($sublist);
    unless ($ok) {
      if ($mess eq 'none') {
        $mess = $self->format_error('no_sublist', $list, 'COMMAND' => 'sublist');
      }
      elsif ($mess eq 'existing') {
        $mess = $self->format_error('existing_sublist', $list, 
                                    'SUBLIST' => $sublist);
      }
    }
  }
  elsif ($mode =~ /destroy/) {
    ($ok, $mess) = $self->{'lists'}{$list}->aux_destroy($sublist);
    unless ($ok) {
      if ($mess eq 'none') {
        $mess = $self->format_error('no_sublist', $list, 'COMMAND' => 'sublist');
      }
      elsif ($mess eq 'absent') {
        $mess = $self->format_error('invalid_sublist', $list, 
                                    'SUBLIST' => $sublist);
      }
      elsif ($mess eq 'public') {
        $mess = $self->format_error('public_sublist', $list, 
                                    'SUBLIST' => $sublist);
      }
    }
  }
  else {
    if ($list ne 'DEFAULT' and $list ne 'GLOBAL') {
      $sublists = { %{$self->_list_config_get($list, "sublists")}};
    }
    else {
      $sublists = {};
    }

    $desc = '';
    if (exists $sublists->{$sublist}) {
      $desc = $sublists->{$sublist};
    }

    if ($self->{'lists'}{$list}->valid_aux($sublist)) {
      $mess = {
                'description' => $desc,
                'posts' => $self->{'lists'}{$list}->count_posts(30, $sublist),
                'subs'  => $self->{'lists'}{$list}->count_subs($sublist) || 0,
              };
      $ok = 1;
    }
    else {
      $mess = $self->format_error('invalid_sublist', $list, 
                                  'SUBLIST' => $sublist);
      $ok = 0;
    }
  }

  return ($ok, $mess);
}

=head2 subscribe()

Perform the subscribe command.  If the "set" mode is used, an
the "setting" element of the request hash is treated as a
subscription class and/or flags.

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
  my (@addrs, $error, $i, $matches_list, $mismatch, $mj, $ok, $tmp, $whereami);

  my $log = new Log::In  30, "$request->{'list'}, $request->{'victim'}, $request->{'mode'}";

  # Do a list_access_check here for the address; subscribe if it succeeds.
  # The access mechanism will automatically generate failure notices and
  # confirmation tokens if necessary.
  $whereami = $self->_global_config_get('whereami');

  # Do not allow command aliases to be subscribed
  @addrs = qw(-unsubscribe -subscribe -subscribe-digest -subscribe-each 
              -subscribe-nomail -subscribe-unique -request);
  push @addrs, "";

  $tmp = $self->_list_config_get($request->{'list'}, 'digests');
  if (ref $tmp eq 'HASH') {
    for $i (keys %$tmp) {
      next if ($i eq 'default_digest');
      push @addrs, "-subscribe-digest-$i";
    }
  }

  for $i (@addrs) { 
    $tmp = new Mj::Addr("$request->{'list'}$i\@$whereami");
    $matches_list = $request->{'victim'} eq $tmp;
    last if $matches_list;
  }
  # Also guard against subscribing the main server address.
  unless ($matches_list) {
    $tmp = new Mj::Addr($self->_global_config_get('whoami'));
    $matches_list = $request->{'victim'} eq $tmp;
  }

  $request->{'setting'} ||= '';
  $request->{'sublist'} ||= 'MAIN';
  # XLANG
  return (0, "The GLOBAL and DEFAULT lists have no subscribers.\n")
    if ($request->{'sublist'} eq 'MAIN' and
        $request->{'list'} =~ /GLOBAL|DEFAULT/);

  ($ok, $error) =
    $self->list_access_check($request, 'matches_list' => $matches_list);

  unless ($ok > 0) {
    $log->message(30, "info", "noaccess");
    return ($ok, $error);
  }
  $self->_subscribe($request->{'list'}, $request->{'user'}, $request->{'victim'},
                    $request->{'mode'}, $request->{'cmdline'},
                    $request->{'setting'}, $request->{'sublist'});
}

use Mj::Util qw(gen_pw);
sub _subscribe {
  my $self  = shift;
  my $list  = shift;
  my $requ  = shift;
  my $vict  = shift;
  my $mode  = shift;
  my $cmd   = shift;
  my $setting = shift;
  my $sublist = shift || 'MAIN';
  my $log   = new Log::In 35, "$list, $vict";
  my ($class, $classarg, $classarg2, $data, $exist, $flags, $ml,
      $ok, $rdata, $sl, $welcome, $welcome_table);

  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);

  if ($sublist ne 'MAIN') {
    $sl = "$list:$sublist";
  }
  else {
    $sl = $list;
  }

  if ($setting) {
    ($ok, $flags, $class, $classarg, $classarg2) =
      $self->{'lists'}{$list}->make_setting($setting, '',
        $self->{'lists'}{$list}->default_class);
    unless ($ok) {
      return (0, $flags);
    }
    # sublists do not support digests
    if ($sublist ne 'MAIN' and $class eq 'digest') {
      ($class, $classarg, $classarg2) = 
        $self->{'lists'}{$list}->default_class;
      if ($class =~ /digest/) {
        $class = 'nomail';
        $classarg = '';
        $classarg2 = '';
      }
    }
  }
  else {
    $flags = $class = $classarg = $classarg2 = '';
  }

  # Add to list
  ($ok, $data) =
    $self->{'lists'}{$list}->add($mode, $vict, $sublist,
                                 'flags' => $flags,
                                 'class' => $class,
                                 'classarg' => $classarg,
                                 'classarg2' => $classarg2,
                                );

  unless ($ok) {
    $log->out("failed, existing");
    return (0, $self->format_error('already_subscribed', $sl,
            'VICTIM' => "$vict", 'FULLADDR' => $data->{'fulladdr'}));
  }

  $ml = $self->_global_config_get('password_min_length');

  # dd to/update registration database
  if ($sublist eq 'MAIN') {
    ($exist, $rdata) =
      $self->_reg_add($vict, 'password' => &gen_pw($ml),
                      'list' => $list);
  }

  $welcome = $self->_list_config_get($list, "welcome");
  $welcome = 1 if $mode =~ /welcome/;
  $welcome = 0 if $mode =~ /(nowelcome|quiet)/;
  $welcome = 0 if ($sublist ne 'MAIN');

  if ($welcome) {
    $welcome_table = $self->_list_config_get($list, 'welcome_files');
    $ok = $self->welcome($list, $vict, $welcome_table,
			 'PASSWORD'   => $rdata->{'password'},
                         'REGISTERED' => $exist);
    unless ($ok) {
      # Perhaps complain to the list owner?
    }
  }
  return (1, [$vict]);
}

=head2 tokeninfo_start (request)

Returns all available information about a token, including the session data
(unless the mode includes "nosession").

=cut

sub tokeninfo_start {
  my ($self, $request) = @_;
  my $log = new Log::In 30, $request->{'id'};
  my ($ok, $ent, $error, $data, $gurl, $mess, $mj_owner, $origmsg, $parser,
      $part, $sender, $sess, $spool, $token, $victim);

  # Don't check access for now; users should always be able to get
  # information on tokens.  When we have some way to prevent lots of
  # consecutive requests, we could call the access check routine.

  return (0, $self->format_error('no_token', 'GLOBAL'))
    unless (length $request->{'id'});

  $token = $self->t_recognize($request->{'id'});
  if (! $token) {
    return (0, $self->format_error('invalid_token', 'GLOBAL', 
                                   'TOKEN' => $request->{'id'}));
  }
  $request->{'id'} = $token;

  # Call t_info to extract the token data hash
  ($ok, $data) = $self->t_info($token);
  return ($ok, $data) unless ($ok > 0);

  return (0, $self->format_error('make_list', 'GLOBAL', 
                                 'LIST' => $data->{'list'}))
    unless $self->_make_list($data->{'list'});

  
  # Check access
  $request->{'oldlist'} = $request->{'list'};
  $request->{'list'} = $data->{'list'};
  ($ok, $mess) = $self->list_access_check($request, 'nostall' => 1,
                                          'token_type' => $data->{'type'});

  unless ($ok > 0) {
    return ($ok, $mess);
  }

  $data->{'willack'} = '';
  $victim = new Mj::Addr($data->{'victim'});

  if ($data->{'command'} ne 'post' or
      $self->{'lists'}{$data->{'list'}}->
        should_ack($data->{'sublist'}, $victim, 'j')
     )
  {
    $data->{'willack'} = " ";
  }

  if ($request->{'mode'} =~ /part/ and
      $data->{'command'} ne 'post') {
    # XLANG
    return (0, "The part command mode only applies to moderated messages.\n");
  }

  $spool = $sess = '';
  if ($data->{'command'} eq 'post') {

    # spool file; use basename
    $spool = $data->{'arg1'};
    $spool =~ s#.+/([^/]+)$#$1#;
    $self->{'spoolfile'} = "$self->{'ldir'}/GLOBAL/spool/$spool";
    $request->{'part'} ||= 0;

    ($ok, $sess) =
      $self->_get_msg_data($data, $request->{'part'},
                           $request->{'mode'}, $request->{'contents'});
    return ($ok, $sess) unless ($ok);

    $self->{'msg_data'} = $sess;
  }
  elsif ($request->{'mode'} !~ /nosession/ && $data->{'sessionid'}) {
    # Pull out the session data
    ($sess) =
      $self->sessioninfo_start($data);
  }

  if ($request->{'mode'} =~ /remind/) {
    $gurl = $self->_global_config_get('confirm_url');
    $sender = $self->_list_config_get($data->{'list'}, 'sender');
    $mj_owner = $self->_global_config_get('sender');

    $ent = $self->r_gen($token, $data, $gurl, $sender);
    if ($ent and exists $self->{'spoolfile'}) {
      $ent->make_multipart;
      $ent->attach(Type        => 'message/rfc822',
                   Encoding    => '8bit',
                   Description => 'Original message',
                   Path        => $self->{'spoolfile'},
                   Filename    => undef,
                  );
    }
    if ($ent) {
      $self->mail_entity({ addr => $mj_owner,
                           type => 'D',
                           data => $token,
                         },
                         $ent,
                         $request->{'user'}
                        );
    }
    if (exists $data->{'tmpfile'} and -f $data->{'tmpfile'}) {
      unlink $data->{'tmpfile'};
    }
  }

  # Return the token data and session or message information.
  return (1, $data, $sess);
}

use Mj::MIMEParser qw(get_entity_structure);
sub _get_msg_data {
  my ($self, $data, $part, $mode, $contents) = @_;
  my $log = new Log::In 30;
  my ($ent, $ok, $parser, $spool, $table);

  # XLANG
  return (0, "The message spool file is unavailable.\n")
    unless (exists $self->{'spoolfile'} and -f $self->{'spoolfile'});

  $spool = $self->{'spoolfile'};
  $part ||= '0';

  $parser = new Mj::MIMEParser;
  # XLANG
  return (0, "Unable to initialize message parser.\n")
    unless ($parser);

  $parser->output_to_core(0);
  $parser->output_dir($tmpdir);
  $parser->output_prefix("mjt");

  if ($mode =~ /delete/) {
    ($ok, $table) = $parser->remove_part($spool, $part);
  }
  elsif ($mode =~ /replace/) {
    ($ok, $table) = $parser->replace_part($spool, $part, $contents);
  }
  else {
    # no mode, "part" mode, or "part-edit" mode
    $ent = $parser->parse_open($spool);
    # XLANG
    return (0, "Unable to parse message.\n") unless ($ent);

    $table = {};
    $ok = get_entity_structure($ent, 1, $table);
    if (exists $table->{'1'}) {
        $table->{'0'} = 
          {
            'charset' => $table->{'1'}->{'charset'},
            'file'    => $spool,
            'type'    => $table->{'1'}->{'type'},
            'size'    => sprintf("%.1f", ((-s ($spool)) + 51) / 1024),
          };
    }

    $part =~ s/[hH]$//;
    # XLANG
    return (0, "The message has no part numbered $part.\n")
      if ($mode =~ /part/ and 
        (! exists $table->{$part} or $part eq '0h'));
  }

  if ($ok) {
    $self->{'msg_parser'} = $parser;
  }
  return ($ok, $table);
}

sub tokeninfo_chunk {
  my ($self, $request, $chunksize) = @_;
  my $log = new Log::In 550, $request->{'id'};
  my ($i, $file, $line, $out, $part);

  return (0, undef) unless (exists $self->{'msg_data'});

  return (0, undef)
    unless (defined $request->{'part'} and
            exists $self->{'msg_data'}->{$request->{'part'}});

  $request->{'part'} ||= 0;

  $part = $self->{'msg_data'}->{$request->{'part'}};
  unless (exists $part->{'fh'} and defined $part->{'fh'}) {
    if ($request->{'part'} eq '0') {
      $i = gensym();
      open ($i, "< $part->{'file'}");
      return (0, undef) unless (defined $i);
      $part->{'fh'} = $i;
    }
    elsif ($request->{'mode'} =~ /clean/ and
           $part->{'entity'}->effective_type =~ /text\/html/i) {
      $file = $self->clean_text($part->{'entity'});
      return (0, undef) unless (defined $file and length $file);
      push @{$self->{'tokeninfo_temps'}}, $file;
      $i = gensym();
      open ($i, "< $file");
      return (0, undef) unless (defined $i);
      $part->{'fh'} = $i;
    }
    else {
      $part->{'fh'} = $part->{'entity'}->open("r");
    }
    return (0, undef)
      unless ($part->{'fh'});
  }

  for ($i = 0; $i < $chunksize; $i++) {
    $line = $part->{'fh'}->getline;
    last unless defined $line;
    $out = '' unless $out;
    $out .= $line;
  }

  delete ($part->{'fh'}) unless (defined $out);
  return (1, $out);
}

sub tokeninfo_done {
  my ($self, $request) = @_;
  my $log = new Log::In 550, $request->{'id'};

  if (exists $self->{'tokeninfo_temps'}) {
    unlink @{$self->{'tokeninfo_temps'}};
    delete $self->{'tokeninfo_temps'};
  }
  if (exists $self->{'msg_parser'}) {
    if (defined $MIME::Tools::VERSION and $MIME::Tools::VERSION >= 5) {
      $self->{'msg_parser'}->filer->purge;
    }
    delete $self->{'msg_parser'};
    delete $self->{'msg_data'};
  }
  if (exists $self->{'spoolfile'}) {
    delete $self->{'spoolfile'};
  }

  $request->{'list'} = $request->{'oldlist'};
  1;
}

=head2 trigger(...)

This is the generic trigger event.  It is designed to be called somehow by
cron or an alarm in an event loop or something to perform periodic tasks
like expiring old data in the various databases, reminding token owners, or
doing periodic digest triggers.

There are two modes: hourly, daily.

=cut

use Mj::Util qw(in_clock);
sub trigger {
  my ($self, $request) = @_;
  my $log = new Log::In 27, "$request->{'mode'}";
  my (%subs, @data, @files, @ready, @req, $addr, $cmdfile, $data,
      $elapsed, $farewell, $farewell_table, $key, $list, $mess, 
      $mode, $ok, $times, $tmp);
  $mode = $request->{'mode'};

  # Right now the interfaces can't call this function (it's not in the
  # parser tables) so we don't check access on it.

  # If this is an hourly check, examine the "triggers" configuration
  # setting, and see if any of the triggers must be run.
  if ($mode =~ /^h/) {
    $times = $self->_global_config_get('triggers');
    for (keys %$times) {
       if (Mj::Util::in_clock($times->{$_})) {
         push @ready, $_;
       }
    }
    $tmp = join " ", @ready;
    $log->message(27, 'info', "Ready: $tmp");
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
      $elapsed = $::log->elapsed;
      ($key, $data) = splice @req, 0, 2;
      $times = $self->_list_config_get($data->{'list'}, 'triggers');
      next unless (exists $times->{'delay'} and
                   Mj::Util::in_clock($times->{'delay'}));

      # XLANG
      ($ok, $mess, $data, $tmp) =
        $self->t_accept($key, '', 'The request was completed after a delay', 0);
      $self->inform($data->{'list'},
                    $data->{'command'},
                    $data->{'user'},
                    $data->{'victim'},
                    $data->{'cmdline'},
                    "token-fulfill",
                    $tmp->[0], 0, 0, $mess, $::log->elapsed - $elapsed);
    }
  }
  # Mode: daily or session - expire session and parser data
  if ($mode =~ /^(da|s)/ or grep {$_ eq 'session'} @ready) {
    $self->s_expire;
    $self->p_expire;
  }
  # Mode: daily or log - expire log entries
  if ($mode =~ /^(da|l)/ or grep {$_ eq 'log'} @ready) {
    $self->l_expire;
  }
  # Mode: daily or checksum - expire GLOBAL checksum and message-id databases
  if ($mode =~ /^(da|c)/ or grep {$_ eq 'checksum'} @ready) {
    $self->{'lists'}{'GLOBAL'}->expire_dup;
  }
  # Mode: daily or inactive - expire inactive registry entries
  if ($mode =~ /^(da|i)/ or grep {$_ eq 'inactive'} @ready) {
    $elapsed = $::log->elapsed;
    ($ok, @data) = $self->r_expire;
    while (($addr, undef) = splice @data, 0, 2) {
      # Log the removal of the registration.
      $self->inform('GLOBAL', 'unregister', $request->{'user'},
                    $addr, "unregister $addr",
                    $self->{'interface'}, 1, '', 0, 
                    'inactive_lifetime exceeded', $::log->elapsed - $elapsed);
    }
  }
  if ($mode =~ /^h/) {
    @files = grep { $_ =~ m#^/# } @ready;
    %subs = $self->standard_subs('GLOBAL');
    for $cmdfile (@files) {
      $self->_list_file_execute('GLOBAL', $cmdfile, \%subs);
    }
  }

  # Loop over lists
  $self->_fill_lists;
  for $list (keys %{$self->{'lists'}}) {
    # GLOBAL and DEFAULT never have bounces, etc.
    next if ($list eq 'GLOBAL' or $list eq 'DEFAULT');
    next unless $self->_make_list($list);
    @ready = ();
    $times = $self->_list_config_get($list, 'triggers');
    for (keys %$times) {
       if (Mj::Util::in_clock($times->{$_})) {
         push @ready, $_;
       }
    }

    # Mode: daily or checksum - expire checksum and message-id databases
    if ($mode =~ /^(da|c)/ or grep {$_ eq 'checksum'} @ready) {
      $self->{'lists'}{$list}->expire_dup;
    }

    # Mode: daily or bounce - expire bounces
    if ($mode =~ /^(da|b)/ or grep {$_ eq 'bounce'} @ready) {
      $self->{'lists'}{$list}->expire_bounce_data;
    }
    # Mode: daily or vacation - expire vacation data
    if ($mode =~ /^(da|v)/ or grep {$_ eq 'vacation'} @ready) {
      $elapsed = $::log->elapsed;
      ($ok, @data) = $self->{'lists'}{$list}->expire_subscriber_data;
      while (($addr, undef) = splice @data, 0, 2) {
        # Log the delivery mode change.
        $self->inform($list,
                      'set',
                      $request->{'user'},
                      $addr,
                      "set $list nomail-return $addr",
                      $self->{'interface'},
                      1, '', 0, '', $::log->elapsed - $elapsed);
      }
    }

    # Mode: daily or post - expire post data
    if ($mode =~ /^(da|p)/ or grep {$_ eq 'post'} @ready) {
      $self->{'lists'}{$list}->expire_post_data;
    }

    # Mode: daily or inactive - expire inactive subscriptions.
    if ($mode =~ /^(da|i)/ or grep {$_ eq 'inactive'} @ready) {
      $elapsed = $::log->elapsed;
      ($ok, @data) = $self->{'lists'}{$list}->expire_inactive_subs;
      $farewell = $self->_list_config_get($list, "farewell");

      while (($addr, undef) = splice @data, 0, 2) {
        $key = new Mj::Addr($addr);
        if (defined $key) {
          $self->_reg_remove($key, $list);

          if ($farewell) {
            $farewell_table = $self->_list_config_get($list, 'farewell_files');
            $data = $self->_reg_lookup($key);
            next unless $data;
            $self->welcome($list, $key, $farewell_table,
                           'PASSWORD' => $data->{'password'},
                          );
          }
        }

        # Log the unsubscription.
        $self->inform($list, 'unsubscribe', $request->{'user'},
                      $addr, "unsubscribe $list $addr",
                      $self->{'interface'}, 1, '', 0, 
                      'inactive_lifetime exceeded', 
                      $::log->elapsed - $elapsed);
      }
    }

    # Mode: hourly or digest - issue digests
    if ($mode =~ /^(h|di)/) {
      # Call digest-check-repeat; this will do whatever is necessary
      # to tickle the digests.
      $self->_digest($list, $request->{'user'},
                     $request->{'user'}, 'check-repeat', '', 'ALL');
    }

    # Mode: hourly.  Check for files in the filespace containing commands
    # to execute.
    if ($mode =~ /^h/) {
      @files = grep { $_ =~ m#^/# } @ready;
      %subs = $self->standard_subs($list);
      for $cmdfile (@files) {
        $self->_list_file_execute($list, $cmdfile, \%subs);
      }
    }
  }
  (1, '');
}

=head2 _list_file_execute(list, file, subs)

Execute the commands contained in a file in the file space
of a particular mailing list.

=cut
use Mj::Parser;
use IO::File;
sub _list_file_execute {
  my ($self, $list, $file, $subs) = @_;
  my ($infh, $int);
  ($file) = $self->_list_file_get(list => $list,
				  file => $file,
				  subs => $subs,
				 );
  return unless $file;

  $infh = new IO::File "<$file";
  return unless $infh;

  # XXX Alter interface to allow command parsing.
  $int = $self->{'interface'};
  $self->{'interface'} = 'shell';

  # XXX What if failure occurs?
  Mj::Parser::parse_part(
        $self,
        'attachments' => '',
        'infh' => $infh,
        'outfh' => \*STDOUT,
        'password' => '',
        'reply_to' => '',
        'title' => $file,
  );

  $self->{'interface'} = $int;

  unlink $file if $subs;
  1;
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
  my (@aliases, @lists, $addr, $data, $key, $l, $rdata, $reg, $sdata);

  return (0, $self->format_error('no_alias', $list, 
                                 'SOURCE' => "$source",
                                 'TARGET' => "$requ"))
    if ($source->xform eq $source->alias);

  ($key, $data) = $self->{'alias'}->remove('', $source->xform);
  unless (defined $key and defined $data) {
    return (0, $self->format_error('no_alias', $list, 
                                   'SOURCE' => "$source",
                                   'TARGET' => "$requ"));
  }

  $reg = new Mj::Addr($source->canon);
  return (1, [$key]) unless defined $reg;

  $rdata = $self->_reg_lookup($reg);
  return (1, [$key]) unless defined $rdata;
 
  @lists = split ("\002", $rdata->{'lists'});
  for $l (@lists) {
    next unless $self->_make_list($l);

    $sdata = $self->{'lists'}{$l}->is_subscriber($reg);
    next unless defined $sdata;

    $addr = new Mj::Addr($sdata->{'stripaddr'});
    next unless defined $addr;

    if ($addr->xform eq $source->xform) {
      $sdata->{'stripaddr'} = $data->{'striptarget'};
      $sdata->{'fulladdr'} = $data->{'striptarget'};
      $self->{'lists'}{$l}->update('', $reg, '', $sdata);
    }
  }
    
  @aliases = $self->_alias_reverse_lookup($reg, 1);
  for $l (@aliases) {
    $sdata = $self->{'alias'}->lookup($l);
    next unless defined $sdata;

    $addr = new Mj::Addr($sdata->{'striptarget'});
    next unless defined $addr;

    if ($addr->xform eq $source->xform) {
      $self->{'alias'}->replace('', $l, 'striptarget', 
                                $data->{'striptarget'});
    }
  }

  return (1, [$key]);
}

=head2 unregister

This removes a user from the master address database.  It also deletes the
registration entry, in effect wiping the user from all databases.

=cut

sub unregister {
  my ($self, $request) = @_;
  my $log = new Log::In 30, "$request->{'victim'}";
  my ($mismatch, $ok, $regexp, $error);

  if ($request->{'mode'} =~ /regex|pattern/) {
    $mismatch = 0;
    $regexp   = 1;
    # Parse the regexp
    ($ok, $error, $request->{'victim'}) =
       Mj::Config::compile_pattern($request->{'victim'}, 0);
    return (0, $error) unless $ok;
    # Untaint the regexp
    $request->{'victim'} =~ /(.*)/; $request->{'victim'} = $1;
  }
  else {
    $mismatch = !($request->{'user'} eq $request->{'victim'});
    $regexp   = 0;
  }

  ($ok, $error) =
    $self->list_access_check($request, 'mismatch' => $mismatch,
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
  my ($self, $list, $requ, $vict, $mode, $cmd) = @_;
  my $log = new Log::In 35, "$vict";
  my (@out, @removed, @aliases, $data, $key, $l, $over, $tmp);

  # Since we call inform() ourselves, we must decide whether to
  # override owner information.  We can assume that the
  # dispatch function has already checked the appropriate passwords
  # here.
  $over = 0;
  $over = 1 if ($mode =~ /noinform/);

  if ($mode =~ /regex|pattern/) {
    $tmp = 'regex';
    $tmp .= '-allmatching' if ($mode =~ /allmatching/);
    (@removed) = $self->{'reg'}->remove($tmp, $vict);
  }
  else {
    (@removed) = $self->{'reg'}->remove('', $vict->canon);
  }

  unless (@removed) {
    $log->out("failed, nomatching");
    # XLANG
    return (0, "Cannot unregister $vict:  no matching addresses.");
  }

  while (($key, $data) = splice(@removed, 0, 2)) {
    $key = new Mj::Addr($key);

    # Remove from all subscribed lists
    for $l (split("\002", $data->{'lists'})) {
      next unless $self->_make_list($l);
      $tmp = $::log->elapsed;
      $self->{'lists'}{$l}->remove('', $key);

      # Log the removal of the subscription.
      $self->inform($l, 'unsubscribe', $requ, $key, $cmd,
                    $self->{'interface'}, 1, '', $over, '',
                    $::log->elapsed - $tmp)
        unless ($mode =~ /nolog/);
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
  my (@out, @removed, $error, $mismatch, $ok, $regexp);

  if ($request->{'mode'} =~ /regex|pattern/) {
    $mismatch = 0;
    $regexp   = 1;
    # Parse the regexp
    ($ok, $error, $request->{'victim'}) =
       Mj::Config::compile_pattern($request->{'victim'}, 0);
    return (0, $error) unless $ok;
    # Untaint the regexp
    $request->{'victim'} =~ /(.*)/; $request->{'victim'} = $1;
  }
  else {
    $mismatch = !($request->{'user'} eq $request->{'victim'});
    $regexp   = 0;
  }

  $request->{'sublist'} ||= 'MAIN';
  # XLANG
  return (0, "The GLOBAL and DEFAULT lists have no subscribers.\n")
    if ($request->{'sublist'} eq 'MAIN' and
        $request->{'list'} =~ /GLOBAL|DEFAULT/);

  ($ok, $error) =
    $self->list_access_check($request, 'mismatch' => $mismatch,
                             'regexp'   => $regexp);

  unless ($ok>0) {
    $log->message(30, "info", "$request->{'victim'}:  noaccess");
    return ($ok, $error);
  }

  $self->_unsubscribe($request->{'list'}, $request->{'user'},
                      $request->{'victim'}, $request->{'mode'},
                      $request->{'cmdline'}, $request->{'sublist'});
}

use IO::File;
sub _unsubscribe {
  my($self, $list, $requ, $vict, $mode, $cmd, $sublist) = @_;
  my $log = new Log::In 35, "$list, $vict";
  my(%fdata, @out, @removed, $data, $desc, $farewell, $farewell_table, $fh,
     $file, $flist, $key, $ok, $subs);

  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);

  if (defined $sublist) {
    # XLANG
    return (0, "Unable to access subscriber list \"$sublist\".\n")
      unless $self->{'lists'}{$list}->valid_aux($sublist);
  }

  # Use both the list and sublist in file substitutions.
  $flist = $list;
  if ($sublist ne 'MAIN') {
    $flist .= ":$sublist";
  }

  @removed = $self->{'lists'}{$list}->remove($mode, $vict, $sublist);

  unless (@removed) {
    $log->out("failed, nomatching");
    return (0, $self->format_error('not_subscribed', $list, 
                                   'VICTIM' => "$vict"));
  }

  while (($key, $data) = splice(@removed, 0, 2)) {
    # Convert to an Addr object and remove the list from
    # the registration entry for that address.
    $key = new Mj::Addr($key);

    if (defined $key and $sublist eq 'MAIN') {
      $self->_reg_remove($key, $list);
    }

    push (@out, $data->{'fulladdr'});

    # Send a farewell message
    $farewell = $self->_list_config_get($list, "farewell");
    $farewell = 1 if $mode =~ /farewell/;
    $farewell = 0 if $mode =~ /(nofarewell|quiet)/;
    $farewell = 0 if ($sublist ne 'MAIN');

    if ($farewell) {
      $farewell_table = $self->_list_config_get($list, 'farewell_files');
      $data = $self->_reg_lookup($key);
      next unless $data;
      $ok = $self->welcome($list, $key, $farewell_table,
			   'PASSWORD' => $data->{'password'},
			  );
    }
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
  my ($err, $match, $max_hits, $ok);

  $request->{'chunksize'} ||= 0;

  unless (length $request->{'regexp'}) {
    $request->{'regexp'} = $request->{'user'}->canon;
    $match = 'iexact';
  }
  else {
    $match = 'isubstring';
  }

  # compile the pattern
  ($ok, $err, $request->{'regexp'}) =
     Mj::Config::compile_pattern($request->{'regexp'}, 0, $match);
  return (0, $err) unless $ok;

  # $max_hits will equal 1 for unprivileged people if they are allowed
  # to use the which command.  Thus, a string length check is unneeded.

  # Check global access, to get max hit limit, which is unused.
  ($max_hits, $err) = $self->list_access_check($request);

  return ($max_hits, $err) unless $max_hits > 0;

  $self->_which($request->{'list'}, $request->{'user'},
                $request->{'user'}, $request->{'mode'},
                $request->{'cmdline'}, $request->{'regexp'},
                $request->{'chunksize'}, $request->{'password'});
}

sub _which {
  my ($self, $d, $requ, $victim, $mode, $cmdline, $regexp, $chunksize,
      $password) = @_;
  my $log = new Log::In 35, $regexp;
  my (@matches, $data, $err, $hits, $list, $match, $max_list_hits, 
      $ok, $request, $total_hits);

  # The chunk size and password aren't stored in the token
  # database, so they may not be defined.
  $chunksize ||= 0;
  $password ||= '';

  $total_hits = 0;

  # Untaint
  $regexp =~ /(.*)/; $regexp = $1;

  $request = {
              'cmdline' => $cmdline,
              'command' => 'which',
              'mode'    => $mode,
              'password'=> $password,
              'regexp'  => $regexp,
              'user'    => $requ,
              'victim'  => $victim,
             };

  # Loop over the lists that the user can see
  for $list ($self->get_all_lists($requ, $password)) {

    # Check access for this list
    $request->{'list'} = $list;
    ($max_list_hits, $err) = $self->list_access_check($request);

    next unless $max_list_hits;
    if ($chunksize > 0 and $chunksize < $max_list_hits) {
      $max_list_hits = $chunksize;
    }

    # We are authenticated and ready to search.
    next unless $self->_make_list($list);
    ($ok, $err) = $self->{'lists'}{$list}->get_start;
    next unless $ok;

    $hits = 0;

    while (1) {
      ($match, $data) = 
        $self->{'lists'}{$list}->search('MAIN', $regexp, 'regexp');

      last unless defined $match;

      if ($hits >= $max_list_hits) {
        # XLANG
        push @matches, [undef, 
               "-- Match limit of $max_list_hits for $list exceeded."]; 
        last;
      }
      else {
        push @matches, [$list, $data->{'stripaddr'}];
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

_who is the bottom half; it just calls the internal get_start routine to
initialize the registry, alias database, or subscriber list.

=cut

use Mj::Config;
sub who_start {
  my ($self, $request) = @_;
  my ($base, $error, $list, $mess, $ok, $ok2, $tmp);

  $request->{'sublist'} ||= 'MAIN';
  $request->{'list2'} ||= '';

  my $log = new Log::In 30, "$request->{'list'}, $request->{'sublist'}";

  $base = $request->{'command'}; $base =~ s/_start//i;

  if ($request->{'regexp'} and $request->{'regexp'} ne 'ALL') {
    ($ok, $error, $request->{'regexp'})
      = Mj::Config::compile_pattern($request->{'regexp'}, 0, "isubstring");
    return ($ok, $error) unless $ok;
  }
  else {
    $request->{'regexp'} = 'ALL';
  }

  if ($request->{'mode'} =~ /alias/ and
      ($request->{'list'} ne 'GLOBAL' or
       $request->{'sublist'} ne 'MAIN')) {
    # XLANG
    return (0, "Alias mode is only supported for the GLOBAL list.\n");
  }

  if ($request->{'mode'} =~ /owners/ and
      ($request->{'list'} ne 'GLOBAL' or
       $request->{'sublist'} ne 'MAIN')) {
    # XLANG
    return (0, "Owners mode is only supported for the GLOBAL list.\n");
  }

  ($ok, $error) = $self->list_access_check($request);

  unless ($ok > 0) {
    $log->out("noaccess");
    return ($ok, $error);
  }

  # Common mode allows two subscriber lists to be compared.
  if ($request->{'mode'} =~ /common/) {
    ($list, undef, $mess) = $self->valid_list($request->{'list2'}, 0, 1);
    unless ($list) {
      # XLANG
      $log->out("invalid second list \"$request->{'list2'}\"");
      return (0, $mess);
    }
    $tmp = $request->{'list'};
    $request->{'list'} = $request->{'list2'} = $list;
    # Check access for the second list as well
    ($ok2, $error) = $self->list_access_check($request);

    unless ($ok2 > 0) {
      $log->out("noaccess");
      return ($ok2, $error);
    }
    # Restore the original list.
    $request->{'list'} = $tmp;
    # Use the lowest of the return values to determine unhiding.
    # $ok = $ok2 if ($ok2 < $ok);

  }

  $self->{'unhide_who'} = ($ok > 1 ? 1 : 0);
  $self->_who($request->{'list'}, $request->{'user'}, '',
              $request->{'mode'}, $request->{'cmdline'},
              $request->{'regexp'}, $request->{'sublist'}, $request->{'list2'});
}

sub _who {
  my ($self, $list, $requ, $victim, $mode, $cmdline, $regexp, $sublist, $list2) = @_;
  my $log = new Log::In 35, $list;
  my (@deletions, @tmp, $addr, $error, $i, $j, $listing, $mess,
      $ok, $ok2, $out, $owners, $settings, $strip);
  $listing = [];
  $sublist ||= 'MAIN';

  if ($mode =~ /common/) {
    # Obtain a hashref of addresses
    ($ok2, $error) =
      $self->common_subs($list, $list2);

    unless ($ok2 > 0) {
      $log->out($error);
      return ($ok2, $error);
    }
    unless (scalar keys %$error) {
      # XLANG
      $log->out("no common addresses");
      return (0, "No common addresses were found.\n");
    }
    $self->{'commoners'} = $error;
  }

  if ($list eq 'GLOBAL' and $mode =~ /alias/) {
    # XLANG
    return (0, "Unable to initialize alias list.\n")
      unless $self->{'alias'}->get_start;
  }
  elsif ($list eq 'GLOBAL' and $mode =~ /owners/) {
    return $self->sync_owners($requ);
  }
  elsif ($list eq 'DEFAULT' and $sublist eq 'MAIN') {
    # XLANG
    return (0, "The DEFAULT list never has subscribers");
  }
  elsif ($list eq 'GLOBAL' and $sublist eq 'MAIN') {
    # XLANG
    return (0, "Unable to initialize registry.\n")
      unless $self->{'reg'}->get_start;
  }
  else {
    return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
      unless $self->_make_list($list);

    unless ($ok = $self->{'lists'}{$list}->valid_aux($sublist)) {
      return (0, $self->format_error('invalid_sublist', $list, 
                                      'SUBLIST' => $sublist));
    }
    $sublist = $ok;

    ($ok, $mess) = $self->{'lists'}{$list}->get_start($sublist);
    return (0, $mess) unless ($ok);
  }

  $settings = $self->{'lists'}{$list}->get_setting_data($sublist);

  (1, $regexp, $settings);
}

use Mj::Addr;
use Safe;
sub who_chunk {
  my ($self, $request, $chunksize) = @_;
  my $log = new Log::In 100,
                  "$request->{'list'}, $request->{'regexp'}, $chunksize";
  my (@chunk, @out, @tmp, $addr, $cs, $i, $j, $k, $list, $strip);

  # Common mode: stop now if no addresses remain to be matched.
  return (0, '')
    if ($request->{'mode'} =~ /common/ and not
        (exists $self->{'commoners'} and
         scalar keys %{$self->{'commoners'}}));

  return (0, "No subscriber list was specified")
    unless (length $request->{'sublist'}); # XLANG

  return (0, "Invalid chunk size \"$chunksize\"")
    unless (defined $chunksize and $chunksize > 0); # XLANG

  $list = $self->{'lists'}{$request->{'list'}};
  # XLANG
  return (0, "Unable to access the \"$request->{'list'}\" list.")
    unless $list;

  # who for DEFAULT returns nothing
  # XLANG
  if ($request->{'list'} eq 'DEFAULT' and $request->{'sublist'} eq 'MAIN') {
    return (0, "The DEFAULT list never has subscribers");
  }
  # who-alias for GLOBAL will search the alias list
  elsif ($request->{'list'} eq 'GLOBAL' and $request->{'mode'} =~ /alias/) {
    $cs = $chunksize;
ACHUNK:
    @tmp = $self->{'alias'}->get_matching_regexp($cs, 'stripsource',
                                                 $request->{'regexp'});
    $k = scalar @tmp;
    while (($j, $i) = splice(@tmp, 0, 2)) {
      # Do not show bookkeeping aliases.
      next if ($j eq $i->{'striptarget'});
      $i->{'fulladdr'} = $j;
      $i->{'canon'} = $i->{'striptarget'};
      push @chunk, $i;
    }
    if ($k and scalar @chunk < $chunksize) {
      $cs = $chunksize - scalar @chunk;
      goto ACHUNK;
    }
  }
  # who for GLOBAL will search the registry
  elsif ($request->{'list'} eq 'GLOBAL' and $request->{'sublist'} eq 'MAIN') {
    @tmp = $self->{'reg'}->get_matching_regexp($chunksize, 'fulladdr',
                                               $request->{'regexp'});
    while (($j, $i) = splice(@tmp, 0, 2)) {
      $i->{'canon'} = $j;
      push @chunk, $i;
    }
  }
  else {
    $cs = $chunksize;
CHUNK:
    @tmp = $list->search($request->{'sublist'}, $request->{'regexp'},
                         'regex', $cs);

    $k = scalar @tmp;
    while (($j, $i) = splice(@tmp, 0, 2)) {

      # In bounce mode, addresses without bounce data must be removed here, to
      # allow the full chunk of addresses to be collected.
      if ($request->{'mode'} =~ /bounce/) {
        # use Data::Dumper; warn Dumper $i;
        next unless $i->{'bounce'};
        $i->{'bouncedata'} = $list->_bounce_parse_data($i->{'bounce'});
        next unless $i->{'bouncedata'};
        $i->{'bouncestats'} = $list->bounce_gen_stats($i->{'bouncedata'});
        next unless ($i->{'bouncestats'}->{'month'} > 0);
      }

      $i->{'canon'} = $j;
      push @chunk, $i;
    }

    if ($request->{'mode'} =~ /bounce/ and $k and
        scalar @chunk < $chunksize)
    {
      $cs = $chunksize - scalar @chunk;
      goto CHUNK;
    }

  }

  unless (@chunk) {
    $log->out("finished");
    return (0, '');
  }

  for $i (@chunk) {
    if ($request->{'mode'} =~ /common/) {
      last unless scalar keys %{$self->{'commoners'}};
      next unless exists ($self->{'commoners'}->{$i->{'canon'}});
      delete $self->{'commoners'}->{$i->{'canon'}}
        unless ($request->{'mode'} =~ /alias/);
    }

    # If we're to show it all, obtain descriptions of the settings.
    if ($self->{'unhide_who'}) {

      # The GLOBAL registry has no flags or classes
      if ($request->{'list'} ne 'GLOBAL' or $request->{'sublist'} ne 'MAIN') {
	$i->{'flagdesc'} =
	  join(',', $list->describe_flags($i->{'flags'}));

	$i->{'classdesc'} =
	  $list->describe_class($i->{'class'}, $i->{'classarg'},
				$i->{'classarg2'}, 1);

	if (($i->{'class'} eq 'nomail') && $i->{'classarg2'}) {
	  # classarg2 holds information on the original class
	  $i->{'origclassdesc'} =
	    $list->describe_class(split("\002", $i->{'classarg2'}, 3), 1);
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

  if ($request->{'list'} eq 'GLOBAL' and $request->{'mode'} =~ /alias/) {
    $self->{'alias'}->get_done;
  }
  elsif ($request->{'list'} eq 'GLOBAL' and $request->{'sublist'} eq 'MAIN') {
    $self->{'reg'}->get_done;
  }
  else {
    $self->{'lists'}{$request->{'list'}}->get_done($request->{'sublist'});
  }
  $self->{'unhide_who'} = 0;
  delete $self->{'commoners'};

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

Copyright (c) 1997, 1998, 2002, 2003 Jason Tibbitts for The Majordomo 
Development Group.  All rights reserved.

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


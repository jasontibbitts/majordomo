=head1 NAME

Mj::Access.pm - access restriction functions for Majordomo

=head1 DESCRIPTION

These functions deal with passwords and the access restriction facility.
These are all method calls on the Majordomo object, split off because of
size reasons.

=head1 SYNOPSIS

 # See that the user is allowed to use the password to subscribe addresses
 $mj->validate_password($user, $passwd, undef, "shell", "mylist", "subscribe");

 # Eradicate the cached, parsed password tables
 $mj->flush_passwd_data;

 # Check that a user is allowed to get a file, automatically handling
 # confirmation tokens if the list owner has so configured it
 $mj->list_access_check($passwd, undef, "web", $mode, $cmdline,
                        $list, "get", $user);

=cut
package Mj::Access;
use Mj::Config qw(parse_table);
use strict;
use vars qw($victim $passwd @permitted_ops %args %memberof %requests);

use AutoLoader 'AUTOLOAD';
1;
__END__

=head2 validate_passwd(user, passwd, auth, interface, list, action)

This checks the validity of a password and whether or not it permits a
certain action.

This returns only truth or falsehood; true if the password allows the
action to be carried out, false if it doesn't.

Visibility should be handled elsewhere; this routine just shouldn't be
called for visible variables unless it's to check ahead of time if they
can't be modified.

The password data is cached so that it does not have to be repeatedly
parsed.  When password restrictions change, the data should be re-parsed.
This will take note of permissions which are granted by the change, but
ignore those that are taken away.

XXX There should be some provision for the user to specify that a password
is _not_ allowed to do something.

=cut
sub validate_passwd {
  my ($self, $user, $passwd, $auth, $interface,
      $list, $action, $global_only) = @_;
  my (@try, $i, $j);
  
  return unless defined $passwd;

  $::log->in(100, "$user, $list, $action");
  
  if ($global_only) {
    @try = ('GLOBAL');
  }
  else {
    @try = ('GLOBAL', $list);
  }

  for $i (@try) {
    $self->_build_passwd_data($i);
    
    # Check for access specific to this user, and to any user
    for $j ('ALL', $user) {
      unless ($j eq 'ALL') {
	$j = $self->{'lists'}{$i}->canon($j);
      }

      # We have two special permission groups and the specific check.  Add
      # new permission groups here.

      # Note the extreme pain gone through to avoid autovivification.  It
      # may not be necessary, but it does make debugging easier by not
      # cluttering up the data structure.
      if (($self->{'pw'}{$i} &&
	   $self->{'pw'}{$i}{$passwd} &&
	   $self->{'pw'}{$i}{$passwd}{$j} &&
	   $self->{'pw'}{$i}{$passwd}{$j}{'ALL'}) ||
	  ($action =~ /^config/ && ($self->{'pw'} &&
				    $self->{'pw'}{$i} &&
				    $self->{'pw'}{$i}{$passwd} &&
				    $self->{'pw'}{$i}{$passwd}{$j} &&
				    $self->{'pw'}{$i}{$passwd}{$j}{'config_ALL'})) ||
	  ($self->{'pw'} &&
	   $self->{'pw'}{$i} &&
	   $self->{'pw'}{$i}{$passwd} &&
	   $self->{'pw'}{$i}{$passwd}{$j} &&
	   $self->{'pw'}{$i}{$passwd}{$j}{$action}))
	{
	  $::log->out("approved");
	  return 1;
	}
    }
  }
  $::log->out("failed");
  return;
}

=head2 flush_passwd_data(list)

This removes the cached permission data from memory.

=cut
sub flush_passwd_data {
  my $self = shift;
  my $list = shift;

  delete $self->{'pw'}{$list};
  delete $self->{'pw_loaded'}{$list};
}

=head2 _build_passwd_data(list, force) (private)

This builds the permissions hash for a list.  This is a multidimentional
hash that matches passwds and actions.

The table has the following structure

$mj->{'pw'}->list->passwd->address->action

address and action can be ALL.

Arguably, this should be a List method.

This is not parsed/built like all of the other complex config things (yet?)
because passwords are special in that the parsed data structure maintains
its old state in addition to its new state when it''s reconfigured.  This is
so that a password stays valid, even if changed, for the life of the
Majordomo object (or until flushed).

Normally this routine will exit early if the password data has already
been built, but if $force is true it the data will always be rebuilt.
This enables new config settings to be incorporated without flushing
the old ones.

=cut
sub _build_passwd_data {
  my $self  = shift;
  my $list  = shift;
  my $force = shift;
  my $log   = new Log::In 130, "$list";

  my (@pw, $pw, $i, $j, $k, $table, $error);

  # Bail quickly if we don't need to do anything
  return if $self->{'pw_loaded'}{$list} && !$force;

  # First deal with the list's master_password.
  $pw = $self->_list_config_get($list, "master_password");

  if (defined $pw) {
    # XXX If ALL is ever restricted, the master must get extra privs.
    $self->{'pw'}{$list}{$pw}{'ALL'}{'ALL'} = 1;
  }

  @pw = $self->_list_config_get($list, "passwords");
  ($table, $error) =
    parse_table('fsmp', \@pw);
  
  # We expect that the table would have been syntax-checked when it was
  # accepted, so we can abort if we get an error.
  if ($error) {
    $log->abort("Received an error while parsing password table: $error");
  }
    
  # The password table could be empty...
  if ($table) {
    # Iterate over the records
    for ($i=0; $i<@{$table}; $i++) {

      # First canonicalize each address
      for ($j=0; $j<@{$table->[$i][2]}; $j++) {
	# Skip what's obviously not an address
	next unless $table->[$i][2][$j] =~ /@/;
	$table->[$i][2][$j] = $self->{'lists'}{$list}->canon($table->[$i][2][$j]);
      }

      # Iterate over each action ($table->[$i][1] is a listref of actions)
      for ($j=0; $j<@{$table->[$i][1]}; $j++) {
	if (@{$table->[$i][2]}) {
	  for $k (@{$table->[$i][2]}) {
	    $self->{'pw'}{$list}{$table->[$i][0]}{$k}{$table->[$i][1][$j]} = 1;
	  }
	}
	else {
	  $self->{'pw'}{$list}{$table->[$i][0]}{'ALL'}{$table->[$i][1][$j]} = 1;
	}
      }
    }
  }
  
  $self->{'pw_loaded'}{$list} = 1;
  return;
}

=head2 *_access_check(..., request, arghash)

These check to see of a user is permitted to make a request.

These takes the standard arguments, the name of the request, and a hash of
arguments appropriate to the request.  (For instance, 'post' should take
'failed_admin_check' and 'failed_taboo_check', each containing a list
describing the failed check(s).)

Returns:
  a flag
  a message, to be returned to the user

If the flag is false, the operation failed.  If the flag is positibe, the
operation succeeds and the core code should carry it out.  It is necessary
to communicate some type of conditional failure, because the command may be
fine while the action cannot be immediately completed.

Outline:
  Check to see if a password always overrides
  Check validity of password and bypass rest or set variable
  Build access table (separate routine)
  Check for the presense of an access routine for that task.
  Provide the proper variables; look up list memberships.
  Allocate a Safe compartment, enable the necessary ops, share
    the necessary variables, and reval it.
  The result must be the action string, or "default" if no rule
    matched.

  Take the action string and do what it says:
    default - do normal processing using old variables to decide what
      to do.
    confirm   - send a tag to the appropriate user
    consult   - consult the list owner
    ignore    - forget the request ever happened
    deny      - reject the request with a message
    allow     - let the request happen as normal
    forward   - pass the request on to a different majordomo server
    reply     - use this message as the command acknowlegement
    replyfile - use this file as the command acknowlegement
    mailfile  - mail this file to the user separately

reply and replyfile are cumulative; the contents of all of the reply
strings and all of the files are strung together.  Variable substitution is
done.  mailfile sends the contents of a file in a separate mail message.
Note that if you do confirm and mailfile, the user will get two messages.

=cut
sub global_access_check {
  my $self = shift;
  splice(@_, 5, 0, 'GLOBAL');
  $self->list_access_check(@_);
}

=head2 list_access_check(..., list, request, arghash)

=cut
# These are the ops we allow our generated code to perform.  Even though we
# generated it, we go further and severely restrict what it can do.
@permitted_ops =
  qw(
     anonlist
     const
     enter
     eq
     ge
     gt
     helem
     le
     leaveeval
     lt
     ne
     not
     null
     pushmark
     refgen
     return
     rv2sv
     seq
     sne
    );

sub list_access_check {
  # We must share some of these variables with the compartment, so they
  # can't be lexicals
  my    $self      = shift;
  local $passwd    = shift;
  my    $auth      = shift;
  my    $interface = shift;
  my    $mode      = shift || '';
  my    $cmdline   = shift;
  my    $list      = shift;
  my    $request   = shift;
  my    $requester = shift;
  local $victim    = shift || $requester;
  my    $arg1      = shift;
  my    $arg2      = shift;
  my    $arg3      = shift;
  local %args      = @_;

  my $log = new Log::In 60, "$list, $request";

  my ($password_override,   # Does a supplied password always override
                            # other restrictions?
      $access,              # To save typing
      $actions,             # The action to be performed
      $cpt,                 # A safe compartment for running the code in
      $act,                 # Base action
      $arg,                 # Action argument
      $allow,               # Return code: is operation allowed?
      $stat,                # Description of return code
      $mess,                # Message to be returned (from 'reply' action)
      $ent,                 # MIME Entity for actions needing to send mail
      $deffile,             # The default replyfile if none is given
      $sender,              # Sender for this list's mail
      $mj_owner,
      $reasons,             # The \n separated list of bounce reasons
      $i,                   # duh
      $func,
      $text,
      $temp,
      $ok,
      @temps,
     );
  
  local (
	 %memberof,         # Hash of auxlists the user is in
	);

  $list = 'GLOBAL' if $list eq 'ALL';
  $self->_make_list($list);
  $password_override =
    $self->_list_config_get($list, "access_password_override");

  # If we were given a password, it must be valid.
  $args{'password_valid'} = 0;
  if ($passwd) {
    $args{'password_valid'} =
      $self->validate_passwd($requester, $passwd, $auth,
			     $interface, $list, $request);
    return (0, "Invalid password.\n") unless $args{'password_valid'};
  }
  
  # If we got a good password _and_ it overrides access restrictions,
  # we're done.
  if ($password_override && $args{'password_valid'}) {
    # Return some huge value, because this value is also used as a count
    # for some routines.
    return 2**30;
  }

  # Figure out if $requester and $victim are the same
  $args{'mismatch'} =
    !$self->{'lists'}{$list}->addr_match($requester, $victim);

  $access = $self->_list_config_get($list, 'access_rules');

  if ($access->{$request}) {
    # Populate the memberships hash
    if ($access->{$request}{'check_main'}) {
      $memberof{'MAIN'} = $self->{'lists'}{$list}->is_subscriber($victim);
    }
    if ($access->{$request}{'check_aux'}) {
      for $i (keys %{$access->{$request}{'check_aux'}}) {
	$memberof{$i} = $self->{'lists'}{$list}->aux_is_member($i, $victim);
      }
    }

    # Now execute the code
    $cpt = new Safe;
    $cpt->permit_only(@permitted_ops);
    $cpt->share(qw($victim %args %memberof));
    $actions = $cpt->reval($access->{$request}{'code'});
    warn $@ if $@;
  }

  $actions ||= ['default'];

  # Pull in some useful variables; we don't do these earlier because it
  # wastes time if we were given a password (and it can foul up the test
  # code)
  $sender = $self->_list_config_get($list, "sender");
  $mj_owner = $self->_global_config_get("whoami_owner");

  # Now figure out what to do
  for $i (@{$actions}) {
    no strict 'refs';
    ($_, $arg) = split('=',$i,2);
    $arg ||= '';
    $func = "_a_$_";
    $func =~ s/\+/\_/g;
    # Handle stupid 8 character autoload uniqueness limit
    $func = '_a_conf_cons' if $func eq '_a_confirm_consult';
    ($ok, $deffile, $text, $temp) =
      $self->$func($arg, $mj_owner, $sender, $list, $request, $requester,
		   $victim, $mode, $cmdline, $arg1, $arg2, $arg3, %args);
    $allow = $ok if defined $ok;
    $mess .= $text if defined $text;
    push @temps, $temp if defined $temp;
  }

  # If we ran out of actions and didn't generate any reply text, we
  # should replyfile the default (for the last action we ran).
  if (!$mess && $deffile) {
    (undef, undef, $mess) =
      $self->_a_replyfile($deffile, $mj_owner, $sender, $list,
			  $request, $requester, $victim, $mode,
			  $cmdline, $arg1, $arg2, $arg3, %args);
  }

  # Build the reasons list by splitting $arg2, if we're handling a
  # post request.
  $reasons = '';
  if ($request eq 'post') {
    $reasons = join("\n", split('%~%', $arg2));
  }

  # Expand variables in the returned message.  XXX Obviously add some
  # more useful substitutions here.  taboo information (taboo_rule,
  # taboo_match), etc.
  $mess =
    $self->substitute_vars_string
      ($mess,
       'LIST'    => $list,
       'REQUEST' => $request,
       'VICTIM'  => $victim,
       'REASONS' => $reasons,
      ) if $mess;
  
  for $i (@temps) {
    unlink $i || $::log->abort("Failed to unlink $i, $!");
  }
  
  return wantarray? ($allow, $mess) : $allow;
}

=head2 The action subroutines

These routines are called to actually carry out the various actions.
They each take the following:

  arg       - the argument passed to the action, i.e. 
                allow=2
  mj_owner  - the majordomo-owner
  sender    - the sender (owner-list, usually)
  list      - the list name
  request   - the various request parameters
  requester
  victim
  mode
  cmdline
  arg1
  arg2
  arg3

They return a list.  The first element is the result code; this will
(if defined) be returned as the result of the access check.  The
second is a message; this will be appended to the returned message.
The last is a tempfile; if defined, all returned tempfiles will be
unlinked at the end of action processing.

=cut

sub _a_deny {
  my ($self, $arg, $mj_owner, $sender, $list, $request, $requester,
      $victim, $mode, $cmdline, $arg1, $arg2, $arg3) = @_;
  my $log = new Log::In 150, "$request";
  return (0, $request eq 'post' ? 'ack_denial' : 'repl_deny');
}
 
sub _a_allow {
  my $self = shift;
  my $arg  = shift;
  return $arg || 1;
}

# The confirm+consult action, appreviated to appease the autoloader.
sub _a_conf_cons {
  my ($self, $arg, $mj_owner, $sender, $list, $request, $requester,
      $victim, $mode, $cmdline, $arg1, $arg2, $arg3) = @_;
  my ($file1, $file2, $group, $approvals);

  # Confirm file, consult file, consult group, consult approvals
  ($file1, $file2, $group, $approvals) = split(/\s*,\s*/,$arg);

  $self->confirm($file1 || "confirm", $list, $request, $requester,
		 $victim, $mode, $cmdline, 1, $file2 || 'consult',
		 $group || 'default', $approvals || 1, $file2 ||
		 'repl_chain', $arg1, $arg2, $arg3);

  return (-1, 'repl_confcons');
}

sub _a_confirm {
  my ($self, $arg, $mj_owner, $sender, $list, $request, $requester,
      $victim, $mode, $cmdline, $arg1, $arg2, $arg3) = @_;

  $self->confirm($arg || "confirm", $list, $request, $requester, $victim,
		 $mode, $cmdline, 1, '', '', '', '', $arg1, $arg2, $arg3,
		);
  return (-1, 'repl_confirm');
}

sub _a_consult {
  my ($self, $arg, $mj_owner, $sender, $list, $request, $requester,
      $victim, $mode, $cmdline, $arg1, $arg2, $arg3) = @_;
  my $log = new Log::In 150, "$request";
  my ($file, $group, $size);

  ($file, $arg, $group, $size) = split(/\s*,\s*/,$arg || "");
  $self->consult($file || "consult", $group || 'default',
		 $list, $request, $requester, $victim, $mode, $cmdline,
		 $arg || 1, '', '', '', '', $arg1, $arg2, $arg3,
		);
  return (-1, $request eq 'post' ? 'ack_stall' : 'repl_consult');
}

use MIME::Entity;
sub _a_forward {
  my ($self, $arg, $mj_owner, $sender, $list, $request, $requester,
      $victim, $mode, $cmdline, $arg1, $arg2, $arg3) = @_;

  my $ent = new MIME::Entity 
    [
     "Subject: Forwarded request from $requester\n",
     "Reply-To: $requester\n",
     "\n",
     "$cmdline\n",
    ];
  $self->mail_entity($mj_owner, $ent, $arg);
  return (-1, 'repl_forward');
}

sub _a_reply {
  my $self = shift;
  my $arg  = shift;

  $arg =~ s/^\"(.*)\"$/$1/;
  return (undef, undef, "$arg\n");
}    

sub _a_replyfile {
  my ($self, $arg, $mj_owner, $sender, $list, $request, $requester,
      $victim, $mode, $cmdline, $arg1, $arg2, $arg3) = @_;
  my $log = new Log::In 150, "$arg";
  my ($cset, $c_type, $c_t_encoding, $desc, $ent, $file, $fh, $line, $out);

  ($file, $desc, $c_type, $cset, $c_t_encoding) =
    $self->_list_file_get($list, $arg);

  $fh = new Mj::File "$file"
    || $log->abort("Cannot read file $file, $!");
  while (defined ($line = $fh->getline)) {
    $out .= $line;
  }
  return (undef, undef, $out, $file);
}

use MIME::Entity;
sub _a_mailfile {
  my ($self, $arg, $mj_owner, $sender, $list, $request, $requester,
      $victim, $mode, $cmdline, $arg1, $arg2, $arg3) = @_;

  my ($cset, $ent, $file, $desc, $c_type, $c_t_encoding);

  ($file, $desc, $c_type, $cset, $c_t_encoding) =
    $self->_list_file_get($list, $arg);
  $file = $self->substitute_vars($file,
				 'LIST'      => $list,
				 'REQUESTER' => $requester,
				 'REQUEST'   => $request,
				 # XXX and so on...
				);
  $ent = build MIME::Entity
    (
     Path        => $file,
     Type        => $c_type,
     Charset     => $cset,
     Encoding    => $c_t_encoding,
     Filename    => undef,
     -Subject    => $desc,
    );
  $self->mail_entity($sender, $ent, $requester);
  return (undef, undef, undef, $file);
}

=head2 The default actions

When action processing is completed without a rule being matched, the
default rule is invoked.  This runs a request-specific routine which
may read config variables or do anything else in order to provide an
appropriate action.  This is where the backwards compatibility comes
in; legacy variables are checked here.

Then the default routine figures out an action, it should call it
directly and return the results.

XXX Some of these actions require further scrutiny.

=cut
sub _a_default {
  my ($self, $arg, $mj_owner, $sender, $list, $request, $requester,
      $victim, $mode, $cmdline, $arg1, $arg2, $arg3, %args) = @_;
  my $log = new Log::In 150, "$request";
  my ($access, $fun);
  my %allowed_requests   = ('access'=>1, 'help'=>1, 'lists'  =>1);
  my %confirmed_requests = ('alias' =>1, 'set' =>1, 'unalias'=>1);
  my %access_requests    = ('which' =>1, 'info'=>1, 'intro'  =>1,
			    'index' =>1, 'who' =>1, 'get'    =>1,
			    'faq'   =>1);
  my %mismatch_requests  = ('show'  =>1, 'unsubscribe'=>1);
  my %special_requests   = ('post'  =>1, 'advertise'  =>1, 'subscribe'=>1);

  # First check the hash of allowed requests.
  if ($allowed_requests{$request}) {
    return $allowed_requests{$request};
  }

  # We'll use the arglist almost verbatim in a couple of places.
  shift @_;

  return $self->_a_confirm(@_) if ($confirmed_requests{$request});

  if ($access_requests{$request}) {
    $access = $self->_list_config_get($list, "${request}_access");

    # 'list' access doesn't make sense for GLOBAL; assume nobody's
    # subscribed, which implies 'closed'.
    $access = 'closed' if $access eq 'list' && $list eq 'GLOBAL';

    # Always deny rooted requests (only happens for get and index)
    if ($args{'root'}) {
      return $self->_a_deny(@_);
    }
    if ($access eq 'open') {
      return $self->_a_allow(@_);
    }
    elsif ($access eq 'closed') {
      return $self->_a_consult(@_);
    }
    elsif ($access eq 'list' &&
	   $self->{'lists'}{$list}->is_subscriber($victim))
      {
	return 1;
      }
    else {
      return $self->_a_deny(@_);
    }
  }

  if ($mismatch_requests{$request}) {
    if ($args{'mismatch'}) {
      return $self->_a_confirm(@_);
    }
    return $self->_a_allow(@_);
  }

  # Now call the specific default function if it exists; can't just
  # check definedness of the function because autoloading screws this
  # up.
  if ($special_requests{$request}) {
    $fun = "_d_$request";
    return $self->$fun(@_);
  }

  # Finally just deny the request
  return $self->_a_deny(@_);
}

# Normally the default would be to allow, but we must first check the
# advertise and noadvertise variables.  These are regexp arrays
# (unparsed but already syntax checked).  If advertise matches then we
# succeed, else if noadvertise then we fail (unless the address is
# subscribed to the list), else we succeed.
use Safe;
sub _d_advertise {
  my ($self, $arg, $mj_owner, $sender, $list, $request, $requester,
      $victim, $mode, $cmdline, $arg1, $arg2, $arg3) = @_;
  my $log = new Log::In 150, "";
  my (@adv, @noadv, $i, $safe);

  $safe = new Safe;
  $safe->permit_only(qw(const leaveeval null pushmark return rv2sv stub));
  
  @adv = $self->_list_config_get($list, 'advertise');

  for $i (@adv) {
    return 1 if Majordomo::_re_match($safe, $i, $requester);
  }

  # Somewhat complicated; we try not to check membership unless we
  # need to; we do so only if we would otherwise deny.
  @noadv = $self->_list_config_get($list, 'noadvertise');
  for $i (@noadv) {
    if (Majordomo::_re_match($safe, $i, $requester)) {
      if ($self->{'lists'}{$list}->is_subscriber($requester)) {
	return 1;
      }
      return 0;
    }
  }
  # By default we allow
  return 1;
}  

# Provide the expected behavior for the post command.  This means we
# have to check moderate and restrict_post, and all of the appropriate
# variables passed into the access_check routine.
sub _d_post {
  my ($self, $arg, $mj_owner, $sender, $list, $request, $requester,
      $victim, $mode, $cmdline, $arg1, $arg2, $arg3, %args) = @_;
  my $log = new Log::In 150;
  my(@consult_vars, @deny_vars, $i, $member, $moderate, $restrict,
     $tmp);
  shift @_;
  @consult_vars = qw(bad_approval taboo_header taboo_body
		     global_taboo_header global_taboo_body dup_meg_id
		     dup_checksum dup_partial_checksum mime_consult);
  @deny_vars = qw(mime_deny);

  # Deny is stronger than consult, so process denials first
  for $i (@deny_vars) {
    return $self->_a_deny(@_) if $args{$i};
  }

  # Immediately consult for moderated lists
  $moderate = $self->_list_config_get($list, 'moderate');
  return $self->_a_consult(@_) if $moderate;

  # Check restrict_post
  $restrict = $self->_list_config_get($list, 'restrict_post');
  $member = 0;
  for $i (@$restrict) {
    # For backwards compatibility, look for "list", "list.digest",
    # "list-digest", etc.
    if ($i =~ /\Q$list\E([.-_]digest)?/) {
      if ($self->{'lists'}{$list}->is_subscriber($requester)) {
	$member = 1;
	last;
      }
    }
    # Otherwise we have to check both the exact restrict_post file and
    # try to remove the list name and a separator from it and try that
    else {
      if ($self->{'lists'}{$list}->aux_is_member($i, $requester)) {
	$member = 1;
	last;
      }
      else {
	$tmp = $i;
	$tmp =~ s/\Q$list\E[.-_]?//;
	if ($self->{'lists'}{$list}->aux_is_member($i, $requester)) {
	  $member = 1;
	  last;
	}
      }
    }
  }
  return $self->_a_consult(@_) unless $member || !@$restrict;

  # Now check all of the variables passed in from resend and consult
  # if necessary
  return $self->_a_consult(@_)
    if $args{'admin'} && $self->_list_config_get($list, 'administrivia');

  for $i (@consult_vars) {
    return $self->_a_consult(@_) if $args{$i};
  }

  return $self->_a_allow(@_);
}

# Check the subscribe_policy variable
sub _d_subscribe {
  my ($self, $arg, $mj_owner, $sender, $list, $request, $requester,
      $victim, $mode, $cmdline, $arg1, $arg2, $arg3, %args) = @_;
  my $log = new Log::In 150, "";
  my $policy = $self->_list_config_get($list, 'subscribe_policy');
  
  # We'll need this to pass on
  shift @_;

  # First make sure that someone isn't trying to subscribe the list to
  # itself
  return (0, 'subscribe_to_self') if $args{'matches_list'};

  # The easy ones
  return $self->_a_allow(@_)     if $policy eq 'auto';
  return $self->_a_confirm(@_)   if $policy eq 'auto+confirm';
  return $self->_a_consult(@_)   if $policy eq 'closed';
  return $self->_a_conf_cons(@_) if $policy eq 'closed+confirm';
  
  # Now, open.  This depends on whether there's a mismatch.
  if ($args{'mismatch'}) {
    return $self->_a_consult(@_)   if $policy eq 'open';
    return $self->_a_conf_cons(@_) if $policy eq 'open+confirm';
  }
  return $self->_a_allow(@_)   if $policy eq 'open';
  return $self->_a_confirm(@_) if $policy eq 'open+confirm';

  # The variable was syntax-checked when it was set, so we can just
  # blow up if we get here.
  $log->abort("Can't handle policy: $policy");
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
### cperl-label-offset:-1 ***
### End: ***


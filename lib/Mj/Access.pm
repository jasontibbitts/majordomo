=head1 NAME

Mj::Access.pm - access restriction functions for Majordomo

=head1 DESCRIPTION

These functions deal with passwords and the access restriction facility.
These are all method calls on the Majordomo object, split off because of
size reasons.

=head1 SYNOPSIS

 # See that the user is allowed to use the password to subscribe addresses
 $mj->validate_password($user, $passwd, "mylist", "subscribe");

 # Eradicate the cached, parsed password tables
 $mj->flush_passwd_data;

 # Test session data for invalid headers
 $mj->check_headers($sess);

 # Check that a user is allowed to get a file, automatically handling
 # confirmation tokens if the list owner has so configured it
 $mj->list_access_check($request);

=cut
package Mj::Access;
use Mj::Config qw(parse_table);
use Mj::CommandProps qw(:rules);
use Mj::MIMEParser;
use strict;
use vars qw($current $skip $text $victim $passwd @permitted_ops %args
            %memberof %requests);

use AutoLoader 'AUTOLOAD';
1;
__END__

=head2 validate_passwd(user, passwd, list, action)

This checks the validity of a password and whether or not it permits a
certain action.

This returns 0 if the password is invalid, a positive number if it is an
access password (that enables a user to carry out secured actions) or a
negative number if it is a user password, used to bypass identity
confirmation.  If the password happens to be both kinds of passwords, the
strongest (most positive) possible value will be returned.

In addition, positive values can be discriminated: the site password
returns a value of 5; the global master password returns 4; global
subsidiary passwords return 3; list master passwords return 2 and list
subsidiary passwords return 1.  These values may change in the future;
generally a check for a positive value is sufficient.

Visibility should be handled elsewhere; this routine just shouldn''t be
called for visible variables unless it''s to check ahead of time if they
can''t be modified.

The password data is cached so that it does not have to be repeatedly
parsed.  When password restrictions change, the data should be re-parsed.
This will take note of permissions which are granted by the change, but
ignore those that are taken away.

XXX There should be some provision for the user to specify that a password
is _not_ allowed to do something.

=cut
sub validate_passwd {
  my ($self, $user, $passwd, $list, $action, $global_only) = @_;
  my (@try, $c, $i, $j, $pdata, $reg);
  return 0 unless defined $passwd;
  my $log = new Log::In 100, "$user, $list, $action";

  if ($self->t_recognize($passwd)) {
    # The password given appears to be a latchkey, a temporary password.
    # If the latchkey exists and has not expired, convert the latchkey
    # to a permanent password.
    $self->_make_latchkeydb;
    if (defined $self->{'latchkeydb'}) {
      $pdata = $self->{'latchkeydb'}->lookup($passwd);
      if (defined $pdata) {
        $passwd = $pdata->{'arg1'}
          if (time <= $pdata->{'expire'});
      }
    }
  }

  $global_only = 1  
    if ($list =~ /^DEFAULT/);
 
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
      if ($j eq 'ALL') {
	$c = 'ALL';
      }
      else {
	$c = $j->canon;
      }

      # We have two special permission groups and the specific check.  Add
      # new permission groups here.

      # Note the extreme pain gone through to avoid autovivification.  It
      # may not be necessary, but it does make debugging easier by not
      # cluttering up the data structure.
      if (($self->{'pw'}{$i} &&
	   $self->{'pw'}{$i}{$passwd} &&
	   $self->{'pw'}{$i}{$passwd}{$c} &&
	   $self->{'pw'}{$i}{$passwd}{$c}{'ALL'}))
	{
	  $log->out("approved");
	  return $self->{'pw'}{$i}{$passwd}{$c}{'ALL'};
	}
      if ($action =~ /^config/ && ($self->{'pw'} &&
				   $self->{'pw'}{$i} &&
				   $self->{'pw'}{$i}{$passwd} &&
				   $self->{'pw'}{$i}{$passwd}{$c} &&
				   $self->{'pw'}{$i}{$passwd}{$c}{'config_ALL'}))
	{
	  $log->out("approved");
	  return $self->{'pw'}{$i}{$passwd}{$c}{'config_ALL'};
	}
      if  ($self->{'pw'} &&
	   $self->{'pw'}{$i} &&
	   $self->{'pw'}{$i}{$passwd} &&
	   $self->{'pw'}{$i}{$passwd}{$c} &&
	   $self->{'pw'}{$i}{$passwd}{$c}{$action})
	{
	  $log->out("approved");
	  return $self->{'pw'}{$i}{$passwd}{$c}{$action};
	}
    }
  }

  # Now check to see if the user's password matches.  Loookup registration
  # data; cached data acceptable
  $reg = $self->_reg_lookup($user, undef, 1);

  # Compare password field; return '-1' if eq.
  if ($reg && $passwd eq $reg->{'password'}) {
    $log->out('user approved');
    return -1;
  }

  # Finally, fail.
  $log->out("failed");
  return 0;
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

  my (@pw, $addr, $pw, $i, $j, $k, $table, $error);

  # Bail quickly if we don't need to do anything
  return if $self->{'pw_loaded'}{$list} && !$force;

  # First deal with the site password
  $pw = $self->_site_config_get('site_password');
  if (defined $pw) {
    # XXX If ALL is ever restricted, the site password must get extra privs.
    $self->{'pw'}{$list}{$pw}{'ALL'}{'ALL'} = 5;
  }

  # Then deal with the list's master_password.
  $pw = $self->_list_config_get($list, "master_password");
  if (defined $pw) {
    # XXX If ALL is ever restricted, the master must get extra privs.
    $self->{'pw'}{$list}{$pw}{'ALL'}{'ALL'} = ($list eq 'GLOBAL' ? 4 : 2);
  }

  # Finally, the subsidiary passwords
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

      # First canonize each address
      for ($j=0; $j<@{$table->[$i][2]}; $j++) {
	$addr = new Mj::Addr($table->[$i][2][$j]);
	next unless $addr->valid;
	$table->[$i][2][$j] = $addr->canon;
      }

      # Iterate over each action ($table->[$i][1] is a listref of actions)
      for ($j=0; $j<@{$table->[$i][1]}; $j++) {
	if (@{$table->[$i][2]}) {
	  for $k (@{$table->[$i][2]}) {
	    $self->{'pw'}{$list}{$table->[$i][0]}{$k}{$table->[$i][1][$j]} =
	      ($list eq 'GLOBAL' ? 3 : 1);
	  }
	}
	else {
	  $self->{'pw'}{$list}{$table->[$i][0]}{'ALL'}{$table->[$i][1][$j]} =
	    ($list eq 'GLOBAL' ? 3 : 1);
	}
      }
    }
  }
  
  $self->{'pw_loaded'}{$list} = 1;
  return;
}

=head2 _gen_pw (length)

Generate a password randomly.

One of the implementations is cribbed from an email to majordomo-workers
sent by OXymoron.  The other is trivial anyway.  I don''t know which I like
more.

The new password will be at least six characters long.

=cut
sub _gen_pw {
  my $length = shift || 6;
  $length = 6 if ($length < 6);

  my $log = new Log::In 200;
#   my @forms = qw(
# 		 xxxxxxx
# 		 xxxxxx0
# 		 000xxxx
# 		 xxx0000
# 		 xxxx000
# 		 0xxxxx0
# 		 xxxxx00
# 		 00xxxxx
# 		 xxx00xxx
# 		 00xxxx00
# 		 Cvcvcvc
# 		 cvcvc000
# 		 000cvcvc
# 		 Cvcvcvc0
# 		 xxx00000
# 		);
  
#   my %groups= (
# 	       'x' => "abcdefghijkmnpqrstuvwxyz",
# 	       'X' => "ABCDEFGHJKLMNPQRSTUVWXYZ",
# 	       'c' => "bcdfghjklmnpqrstvwxyz",
# 	       'C' => "BCDFGHJKLMNPQRSTVWXYZ",
# 	       'v' => "aeiou",
# 	       'V' => "AEIOU",
# 	       '0' => "0123456789"
# 	      );

#   $pw=$forms[int(rand(@forms))];
#   $pw=~s/(.)/substr($groups{$1},int(rand(length($groups{$1}))),1)/ge;

  my $chr = 'ABCDEFGHIJKLMNPQRSTUVWXYZabcdefghijkmnpqrstyvwxyz23456789';
  my $pw;
  
  for my $i (1..$length) {
    $pw .= substr($chr, rand(length($chr)), 1);
  }
  $pw;
}

=head2 check_headers(sessiondata)

Check the session data (for the email and request interfaces only)
for headers caught by the block_headers global configuration setting.

=cut
use Mail::Header;
use Safe;
sub check_headers {
  my ($self, $sd) = @_;
  my (%inv, @headers, @inv, @matches, $class, $code, $data, $head, $i,
      $inv, $j, $k, $l, $match, $reasons, $rule, $safe, $sev);
  my $log = new Log::In 200;
  local ($text);

  return unless $sd;
  @headers = split /\n/, $sd;
  $head = new Mail::Header \@headers;
  return unless $head;

  $code = {};
  $reasons = '';
  $data = $self->_global_config_get('block_headers');
  push @inv, @{$data->{'inv'}};
  $code = $data->{'code'};

  # Make a hash of these for fast lookup
  for $i (@inv) {
    $inv{$i} = $i;
  }

  # Set up the Safe compartment
  $safe = new Safe;
  $safe->permit_only(qw(aassign const leaveeval not null padany push pushmark
                        return rv2sv stub));
  $safe->share('$text');

  # Iterate over each tag present in the header.
  for $i ($head->tags) {

    # Skip the mailbox separator, if we get one
    next if $i eq 'From ';

    # Grab all of the occurrences of that tag and iterate over them
    for $j ($head->get($i)) {
      chomp $j;
      $text = "$i: $j";

      # Eval the code
      @matches = $safe->reval($code);
      warn $@ if $@;

      # Run over the matches that resulted
      while (($rule, $match, $sev, $class, $inv) = splice(@matches, 0, 5)) {

        # An inverted match; remove it from the list
        if ($inv) {
          delete $inv{"$k\t$l\t$rule\t$sev\t$class"};
        }
        else {
          $reasons .= "block_headers matched \"" . 
                      substr($match, 0, 100) .  "\"\n";
        }
      }
    }
  }
  # Now complain about missed inverted matches
  for $i (keys %inv) {
    ($k, $l, $rule, $sev, $class) = split('\t', $i);
    $reasons .= "block_headers failed to match $rule\n";
  }
  return (0, $reasons) if $reasons;
  (1, '');
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
    delay     - delay the request and offer the victim a chance to stop it.
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
  $self->list_access_check(@_);
}

=head2 list_access_check(request, arghash)

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

use Data::Dumper;
use Mj::CommandProps qw(:function action_terminal);
use Mj::Digest qw(in_clock);
sub list_access_check {
  # We must share some of these variables with the compartment, so they
  # can't be lexicals.
  my    $self      = shift;
  my    $data      = shift;
  local %args      = @_;

  local $passwd    = $data->{'password'};
  my    $mode      = $data->{'mode'};
  my    $cmdline   = $data->{'cmdline'};
  my    $list      = $data->{'list'};
        $list      = 'GLOBAL'
          if ($list =~ /^DEFAULT/);
  my    $request   = $data->{'command'}; 
        $request   =~ s/_(start|chunk|done)$//;
  my    $requester = $data->{'user'};
  my    $sublist   = (exists $data->{'sublist'}) ? 
                       $data->{'sublist'} : 'MAIN';
  local $victim    = $data->{'victim'} || $requester;
  my    $arg1      = exists $data->{'arg1'} ? $data->{'arg1'} : '';
  my    $arg2      = exists $data->{'arg2'} ? $data->{'arg2'} : '';
  my    $arg3      = exists $data->{'arg3'} ? $data->{'arg3'} : '';

  my $log = new Log::In 60, "$list, $request, $requester, $victim";

  $log->message(450, "info", "Access variables: ". Dumper \%args);

  # Convert the hash arguments into token data
  my ($td) = function_prop ($data->{'command'}, 'tokendata');
  for (keys %$td) {
    next if ($_ eq 'victim');
    $$_ = $data->{$td->{$_}};
    $data->{$_} = $data->{$td->{$_}};
  }

  my (@final_actions,       # The final list of actions dictated by the rules
      $password_override,   # Does a supplied password always override
                            # other restrictions?
      $access,              # To save typing
      $actions,             # The action to be performed
      $cpt,                 # A safe compartment for running the code in
      $arg,                 # Action argument
      $allow,               # Return code: is operation allowed?
      $stat,                # Description of return code
      $mess,                # Message to be returned (from 'reply' action)
      $ent,                 # MIME Entity for actions needing to send mail
      $deffile,             # The default replyfile if none is given
      $saw_terminal,        # Flag: did a rule emit a terminal action
      $reasons,             # The \n separated list of bounce reasons
      $i,                   # duh
      $func,
      $fileinfo,
      $pdata,               # latchkey data
      $text,
      $temp,
      $ok, $ok2,
      $tmpl, $tmpa,         # Temporary list and sublist holders
      @temps,
      $value,               # Value to which the 'set' action changes a variable.
     );
  
  local (
	 %memberof,         # Hash of sublists the user is in
	);

  if ($self->t_recognize($passwd)) {
    # The password given appears to be a latchkey, a temporary password.
    # If the latchkey exists and has not expired, convert the latchkey
    # to a permanent password.
    $self->_make_latchkeydb;
    if (defined $self->{'latchkeydb'}) {
      $pdata = $self->{'latchkeydb'}->lookup($passwd);
      if (defined $pdata) {
        $passwd = $pdata->{'arg1'}
          if (time <= $pdata->{'expire'});
      }
    }
  }

  # Figure out if $requester and $victim are the same
  $args{'mismatch'} = !($requester eq $victim)
    unless defined($args{'mismatch'});

  # Figure out if the user's identity has changed during this session.
  $args{'posing'} = !($requester eq $self->{'sessionuser'})
    unless defined($args{'posing'});

  $list = 'GLOBAL' if $list eq 'ALL';
  $self->_make_list($list);

  # If we were given a password, it must be valid.  Note that, in the case
  # of a mismatch, we make sure that the user password supplied matches
  # that of the _victim_; you can't use your user password to
  # forge-subscribe other people.  This also means that we have to check
  # the password against both addresses before we bomb with an invalid
  # password error.
  $args{'master_password'} = 0;
  $args{'user_password'}   = 0;
  $args{'delay'}           = 0;
  $args{'interface'}       = $self->{'interface'};
  $args{'sublist'}         = $sublist;

  if ($passwd) {
    # Check the password against the requester
    $ok = $self->validate_passwd($requester, $passwd, $list, $request);
    if ($ok > 0) {
      $args{'master_password'} = 1;
    }
    if ($args{'mismatch'}) {
      # Check the password against the victim
      $ok2 = $self->validate_passwd($victim, $passwd, $list, $request);
      if ($ok2 < 0) {
	$args{'user_password'} = 1;
      }
    }
    else {
      # The requester and victim are the same, so no need to recheck
      if ($ok < 0) {
	$args{'user_password'} = 1;
      }
    }
    # It's invalid unless one of the flags was set, excepting
    # the help command.
    return (0, "Invalid password.\n")
      unless $args{'master_password'} || $args{'user_password'}
             || $request eq 'help' || $request eq 'lists';
  }
  return (0, "The master password is required to use regular expressions.\n")
    if ($args{'regexp'} and not $args{'master_password'});
  
  # If we got a good master password _and_ it overrides access
  # restrictions, we're done.
  if ($args{'master_password'}) {
    $password_override = 
      $self->_list_config_get($list, "access_password_override");
  
    $args{'delay'} = $data->{'delay'};
    # Return some huge value, because this value is also used as a count
    # for some routines.  If a delay was used, delay the command.
    # If "rule" mode was used, do not override the access rules.
    if ($password_override and $mode !~ /rule/) {
      if ($data->{'delay'} > 0) {
        @final_actions = ('delay');
        goto FINISH;
      }
      return $self->_a_allow(2**30);
    }
  }

  $access = $self->_list_config_get($list, 'access_rules');
  $args{'reasons'} ||= '';

  if ($access->{$request}) {
    # Populate the memberships hash
    # check_main is supported for backward compatibility only.
    if ($access->{$request}{'check_main'}) {
      $memberof{'MAIN'} = $self->{'lists'}{$list}->is_subscriber($victim, 'MAIN');
    }
    if ($access->{$request}{'check_aux'}) {
      for $i (keys %{$access->{$request}{'check_aux'}}) {
	# Handle list: and list:sublist syntaxes; if the list doesn't
	# exist, just skip the entry entirely. 
	if ($i =~ /(.+):(.*)/) {
	  ($tmpl, $tmpa) = ($1, $2);
	  next unless $self->_make_list($tmpl);
        }
        else {
          ($tmpl, $tmpa) = ($list, $i);
        }
	$memberof{$i} = $self->{'lists'}{$tmpl}->is_subscriber($victim, $tmpa);
      }
    }
    $current = 0;
    if ($access->{$request}{'check_time'}) {
      $current = Mj::Digest::in_clock($access->{$request}{'check_time'});
    }

    # Add some chunks of the address to the set of matchable variables
    $victim->strip =~ /.*\@(.*)$/;
    $args{'host'}     = $1;
    $args{'addr'}     = $victim->strip;
    $args{'fulladdr'} = $victim->full;
    $args{'mode'}     = $mode;
   
    # Prepare to execute the rules
    $skip = 0;
    $cpt = new Safe;
    $cpt->permit_only(@permitted_ops);
    $cpt->share(qw(%args %memberof $current $skip));

    # Loop until we get a terminal action
   RULE:
    while (1) {
      $actions = $cpt->reval($access->{$request}{'code'});
      warn "Error found when running access_rules code:\n$@" if $@;

      # The first element of the action array is the ID of the matching
      # rule.  If we have to rerun the rules, we will want to skip to the
      # next one.
      $actions ||= [0, 'default'];
      $skip = shift @{$actions};

      # Now go over the actions we received.  We must process 'set' and
      # 'unset' here so that they'll take effect if we have to rerun the
      # rules.  Other actions are pushed into @final_actions.  If we hit a
      # terminal action we stop rerunning rules.
     ACTION:
      for $i (@{$actions}) {
	($func, $arg) = split(/[=-]/, $i, 2);
        # Remove enclosing parentheses
        if ($arg) {
            $arg =~ s/^\((.*)\)$/$1/;
            $i = "$func=$arg";
        }

	if ($func eq 'set') {
	  # Set a variable.
	  ($arg, $value) = split(/[=-]/, $arg, 2);
	  if ($arg and ($ok2 = rules_var($request, $arg))) {
            if ($value and $arg eq 'delay') {
              my ($time) = time;
              $args{'delay'} = Mj::List::_str_to_time($value) || $time + 1;
              $args{'delay'} -= $time;
            }
            elsif ($value and $ok2 > 1) {
              $args{$arg} = $value;
            }
            else {
              $args{$arg} ||= 1;
            }
	  }
	  next ACTION;
	}
	elsif ($func eq 'unset') {
	  # Unset a variable.
	  if ($arg and rules_var($request, $arg)) {
	    $args{$arg} = 0;
	  }
	  next ACTION;
	}
        elsif ($func eq 'reason') {
          if ($arg) {
            $arg =~ s/^\"(.*)\"$/$1/;
            $args{'reasons'} = "$arg\002" . $args{'reasons'};
          }
          next ACTION;
        }

	# We'll process the function later.
	push @final_actions, $i;

	$saw_terminal ||= action_terminal($func);
      }

      # We need to stop if we saw a terminal action in the results of the
      # last rule
      last RULE if $saw_terminal;
    }
  }

  # What if we don't have a rule for this action?
  else {
    @final_actions = ('default');
  }

FINISH:
  # Now figure out what to do
  for $i (@final_actions) {
    no strict 'refs';
    ($func, $arg) = split(/[-=]/,$i,2);
    $arg ||= '';
    $func = "_a_$func";
    $func =~ s/\+/\_/g;
    # Handle stupid 8 character autoload uniqueness limit
    $func = '_a_conf_cons' if $func eq '_a_confirm_consult';
    ($ok, $deffile, $text, $fileinfo, $temp) =
      $self->$func($arg, $data, \%args);
    $allow = $ok if defined $ok;
    $mess .= $text if defined $text;
    push @temps, $temp if defined $temp;
  }

  # If we ran out of actions and didn't generate any reply text, we
  # should replyfile the default (for the last action we ran).
  if (!$mess && $deffile) {
    (undef, undef, $mess, $fileinfo) =
      $self->_a_replyfile($deffile, $data, \%args);
  }

  # Build the reasons list. 
  $reasons .= join("\n", split("\002", $args{'reasons'}));

  # Append the sublist for variable substitutions.
  if ($request =~ /post/) {
    my %avars = split("\002", $arg3);
    if ($avars{'sublist'}) {
      $list .= ':' . $avars{'sublist'};
    }
  }

  # Expand variables in the returned message.  XXX Obviously add some
  # more useful substitutions here.  taboo information (taboo_rule,
  # taboo_match), etc.
  $mess =
    $self->substitute_vars_string
      ($mess,
       {
        $self->standard_subs($list),
        'CMDLINE' => $cmdline,
        'FULFILL' => scalar localtime (time + $args{'delay'}),
        'NOTIFY'  => $victim,
	'REASONS' => $reasons,
	'VICTIM'  => $victim,
       },
      ) if $mess;
  
  for $i (@temps) {
    unlink $i || $::log->abort("Failed to unlink $i, $!");
  }
  
  return wantarray? ($allow, $mess, $fileinfo) : $allow;
}

=head2 The action subroutines

These routines are called to actually carry out the various actions.
They each take the following:

  arg       - the argument passed to the action, i.e. 
                allow=2
  list      - the list name
  request   - the various request parameters
  requester
  victim
  mode
  cmdline
  arg1
  arg2
  arg3

They return a list:

the result code; this will (if defined) be returned as the result of the
  access check.
the name of the default file for this action.
a message; this will be appended to the returned message.
fileinfo; this is the raw data hashref returned from list_file_get.
  _a_replyfile uses this to return this data back to the caller.
a tempfile; if defined, all returned tempfiles will be unlinked at the end
  of action processing.

=cut

sub _a_deny {
  my ($self, $arg, $td, $args) = @_;
  my $log = new Log::In 150, $td->{'command'};

  if ($td->{'command'} =~ /post/
       and not $self->_list_config_get($td->{'list'}, 'save_denial_checksums')) {
    unless (exists $args->{'dup_checksum'}) {
      $self->{'lists'}{$td->{'list'}}->remove_dup($args->{'checksum'}, 'sum')
        if $args->{'checksum'};
    }
    unless (exists $args->{'dup_partial_checksum'}) {
      $self->{'lists'}{$td->{'list'}}->remove_dup($args->{'partial_checksum'}, 'partial')
        if $args->{'partial_checksum'};
    }
  }
  if ($arg) {
    return (0, $arg);
  }
  return (0, $td->{'command'} =~ /post/ ? 'ack_denial' : 'repl_deny');
}

sub _a_allow {
  my ($self, $arg, $td, $args) = @_;

  return $arg || 1;
}

# The confirm+consult action, appreviated to appease the autoloader.
# Accepts four parameters: file for confirmation, file for consultation,
# moderator group to consult, number of approvals to require.
sub _a_conf_cons {
  my ($self, $arg, $td, $args) = @_;
  my ($file1, $file2, $group, $approvals);
  my $log = new Log::In 150, $td->{'command'};

  # Confirm file, consult file, consult group, consult approvals
  ($file1, $file2, $group, $approvals) = split /\s*,\s*/, $arg;

  $self->confirm(%$td,
                 'file'      => $file1 || "confirm",
		 'notify'    =>	$td->{'victim'},
                 'reasons'   => $args->{'reasons'},
		 'approvals' => 1,
		 'chain'     => [$file2 || 'consult',
				 $group || 'default',
				 $approvals || 1,
				 'repl_chain',
				],
		 'args'      => [$td->{'arg1'}, $td->{'arg2'}, $td->{'arg3'}],
		);

  return (-1, 'repl_confcons');
}

# Accepts just a filename
sub _a_confirm {
  my ($self, $arg, $td, $args) = @_;
  my $log = new Log::In 150, $td->{'command'};

  $self->confirm(%$td,
                 'file'      => $arg || 'confirm',
		 'notify'    =>	$td->{'victim'},
                 'reasons'   => $args->{'reasons'},
		 'approvals' => 1,
		 'args'      => [$td->{'arg1'}, $td->{'arg2'}, $td->{'arg3'}],
		);

  return (-1, 'repl_confirm');
}

# Confirm with both the requester and the victim, victim first.
sub _a_confirm2 {
  my ($self, $arg, $td, $args) = @_;
  my ($chain, $tmp, $reply, $notify);
  my $log = new Log::In 150, $td->{'command'};

  $reply = "repl_confirm";
  $notify = $td->{'victim'};

  # Confirm file, consult file, consult group, consult approvals
  my ($file1, $file2, $group, $approvals) = split /\s*,\s*/, $arg;
  if ($args->{'mismatch'}) {
    if (!$args->{'user_password'}) {
      $chain  = [$file2 || 'confirm', $group || 'requester',
               $approvals || 1, 'repl_confirm' ];
      $reply = "repl_confirm2";
    }
    # confirm with the requester if the victim's password was supplied.
    else {
      $notify = $td->{'user'};
    }
  }
  elsif ($args->{'user_password'}) {
    # The requester and victim are identical
    # and the password was supplied, so allow the command.
    return 1;
  }
 
  $self->confirm(%$td,
                 'file'      => $file1 || 'confirm',
		 'notify'    =>	$notify,
		 'approvals' => 1,
                 'reasons'   => $args->{'reasons'},
		 'chain'     => $chain,
		 'args'      => [$td->{'arg1'}, $td->{'arg2'}, $td->{'arg3'}],
		);

  return (-1, $reply);
}

# Accepts four parameters: filename, approvals, the moderator group, the
# number of moderators.  XXX Possibly allow the push of a bounce reason, or
# can the whole moderator group thing.

sub _a_consult {
  my ($self, $arg, $td, $args) = @_;
  my $log = new Log::In 150, $td->{'command'};
  my ($file, $group, $size);

  ($file, $arg, $group, $size) = split (/\s*,\s*/, $arg || "");
  $self->consult(%$td,
                 'file'      => $file || 'consult',
		 'group'     => $group || 'default',
		 'size'      => $size || 0,
                 'reasons'   => $args->{'reasons'},
		 'approvals' => $arg || 1,
		 'args'      => [$td->{'arg1'}, $td->{'arg2'}, $td->{'arg3'}],
		);

  return (-1, $td->{'command'} =~ /post/ ? 'ack_stall' : 'repl_consult');
}

# Accepts a filename and a delay
sub _a_delay {
  my ($self, $arg, $td, $args) = @_;
  my $log = new Log::In 150, "$td->{'command'}, $arg";
  my ($delay, $file);

  ($file, $arg) = split (/\s*,\s*/, $arg || "");
  if ($arg) {
    $delay = Mj::List::_str_to_time($arg) - time;
    if ($delay > 0) {
      $td->{'delay'} = $delay;
      # For the result message
      $args->{'delay'} = $delay;
    }
  }
  elsif ($args->{'delay'}) {
    $td->{'delay'} = $args->{'delay'};
  }
    
  $self->delay(%$td,
               'file'      => $file || 'delay',
               'notify'    => $td->{'victim'},
               'approvals' => 1,
               'reasons'   => $args->{'reasons'} || '',
               'args'      => [$td->{'arg1'}, $td->{'arg2'}, $td->{'arg3'}],
              );

  return (-1, $td->{'command'} =~ /post/ ? 'ack_delay' : 'repl_delay');
}

use MIME::Entity;
sub _a_forward {
  my ($self, $arg, $td, $args) = @_;

  my (%avars, $cmdline, $ent, $fh, $mj_owner, $parser,
      $subject, $tmpdir, $whoami);
  my $log = new Log::In 150, $arg;
  $cmdline = $td->{'cmdline'};

  if ($td->{'command'} !~ /post/) {
    $whoami = $self->_global_config_get('whoami');
    if (lc $whoami eq lc $arg) {
      # Mail Loop!  Send to owners instead.
      $arg = $self->_list_config_get($td->{'list'}, 'whoami_owner');
      $cmdline .= "\nUnable to forward to $arg due to apparent mail loop.";
    }

    $ent = new MIME::Entity
      [
       "Subject: Forwarded request from $td->{'user'}\n",
       "From: $td->{'user'}\n",
       "Reply-To: $td->{'user'}\n",
       "\n",
       "$cmdline\n",
      ];
  } 
  else {
    # Reconstruct the list address
    %avars = split("\002", $td->{'vars'});
    $whoami = $td->{'list'};
    if ($avars{'sublist'} ne '') {
      $whoami .=  "-$avars{'sublist'}";
    }
    $whoami .=  '@' . $self->_list_config_get($td->{'list'}, 'whereami');

    # Create an entity from the spool file.
    $tmpdir = $self->_global_config_get("tmpdir");

    $parser = new Mj::MIMEParser;
    $parser->output_to_core($self->_global_config_get("max_in_core"));
    $parser->output_dir($tmpdir);
    $parser->output_prefix("mjf");

    $fh = new IO::File "<$td->{'arg1'}";
    $ent = $parser->read($fh);
    # This should be safe, because the file has already
    # been moved from the queue to the spool.
    $fh->close;

    if (lc $whoami eq lc $arg) {
      # Mail Loop!  Send to owners instead.
      if ($ent) {
        $subject = $ent->head->get('subject');
        $subject = "Forwarding loop detected for $arg (was $subject)";
        $ent->head->replace('subject', $subject);
      }
      $arg = $self->_list_config_get($td->{'list'}, 'whoami_owner');
    }
  }
  $mj_owner = $self->_global_config_get('sender');
  $self->mail_entity($mj_owner, $ent, $arg) if ($ent and $arg);
  $ent->purge if $ent;
  # Cannot unlink spool file now, because it may be attached
  # to the reply message.
  return (-1, 'repl_forward');
}

sub _a_reply {
  my $self = shift;
  my $arg  = shift;

  # Return an empty message if passed 'NONE'; this means something to the
  # 'post' request.
  return (undef, undef, '') if $arg eq 'NONE';

  $arg =~ s/^\"(.*)\"$/$1/;
  return (undef, undef, "$arg\n");
}    

sub _a_replyfile {
  my ($self, $arg, $td, $args) = @_;
  my $log = new Log::In 150, $arg;
  my (%file, $file, $fh, $line, $out);

  # Given 'NONE', return an empty message.  This means something to the
  # 'post' request.
  return (undef, undef, '') if $arg eq 'NONE';

  # Retrieve the file, but don't fail
  ($file, %file) = $self->_list_file_get($td->{'list'}, $arg, undef, 1);

  $fh = new Mj::File "$file"
    or $log->abort("Cannot read file $file, $!");
  while (defined ($line = $fh->getline)) {
    $out .= $line;
  }
  return (undef, undef, $out, \%file);
}

use MIME::Entity;
sub _a_mailfile {
  my ($self, $arg, $td, $args) = @_;
  my (%file, $ent, $file, $sender, $subs);

  $subs = {
    $self->standard_subs($td->{'list'}),
  };

  ($file, %file) = $self->_list_file_get($td->{'list'}, $arg, $subs, 1);

  $ent = build MIME::Entity
    (
     Path        => $file,
     Type        => $file{'c_type'},
     Charset     => $file{'charset'},
     Encoding    => $file{'c_t_encoding'},
     Filename    => undef,
     -Subject    => $file{'description'},
     'Content-Language:' => $file{'language'},
    );

  $sender = $self->_list_config_get($td->{'list'}, 'sender');
  if ($sender and $ent) {
    $self->mail_entity($sender, $ent, $td->{'user'});
  }
  return (undef, undef, undef, undef, $file);
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
use Mj::CommandProps ':access';
sub _a_default {
  my ($self, $arg, $td, $args) = @_;
  my $log = new Log::In 150, $td->{'command'};
  my ($access, $policy, $action, $reason, $request);
  ($request = $td->{'command'}) =~ s/_(start|chunk|done)$//;

  # We'll use the arglist almost verbatim in several places.
  shift @_;

  # First check the hash of allowed requests.
  if (access_def($request, 'allow')) {
    return $self->_a_allow(@_);
  }

  # Allow these if the user supplied their password, else confirm them.
  if (access_def($request, 'confirm')) {
    return $self->_a_allow(@_) if $args->{'user_password'};
    $action = "_a_confirm";
    $reason = "By default, $request must be confirmed by the person affected."
  }

  elsif (access_def($request, 'confirm2')) {
    $action = "_a_confirm2";
    $reason = "By default, $request must be confirmed by all persons involved."
  }

  elsif (access_def($request, 'access')) {
    $access = $self->_list_config_get($td->{'list'}, "${request}_access");

    # 'list' access doesn't make sense for GLOBAL; assume nobody's
    # subscribed, which implies 'closed'.
    $access = 'closed' if $access eq 'list' && $td->{'list'} eq 'GLOBAL';
    $action = '_a_deny';

    # Always deny rooted requests (only happens for get and index)
    if ($args->{'root'}) {
      $action = "_a_deny";
      $reason = "Requests which specify absolute paths are denied."
    }
    elsif (exists $td->{'sublist'} and $td->{'sublist'} 
           and $td->{'sublist'} !~ /MAIN/) {
      $action = "_a_deny";
      $reason = "Only list owners can make requests that involve sublists";
    }
    elsif ($access eq 'open') {
      $action = "_a_allow";
    }
    elsif ($access eq 'closed') {
      $action = "_a_deny";
      $reason = "${request}_access is set to 'closed'";
    }
    elsif ($access eq 'list' &&
	   $self->{'lists'}{$td->{'list'}}->is_subscriber($td->{'victim'}))
      {
		$action = "_a_allow";
      }
  }

  elsif (access_def($request, 'policy')) {
    $policy = $self->_list_config_get($td->{'list'}, "${request}_policy");

    # First make sure that someone isn't trying to subscribe the list to
    # itself
    return (0, 'subscribe_to_self') 
      if $request eq 'subscribe' and $args->{'matches_list'};

    if (exists $td->{'sublist'} and $td->{'sublist'} 
           and $td->{'sublist'} !~ /MAIN/) {
      $action = "_a_deny";
      $reason = "Only list owners can make requests that involve sublists";
    }
    # If the user has supplied their password, we never confirm.  We also
    # don't have to worry about mismatches, since we know we saw the victim's
    # password.  So we allow it unless the list is closed, and we ignore
    # confirm settings.
    elsif ($args->{'user_password'}) {
      $action = "_a_allow"   if $policy =~ /^(auto|open)/;
    }

    # Now, open.  This depends on whether there's a mismatch.
    elsif ($args->{'mismatch'} or $args->{'posing'}) {
      $action = "_a_consult"   if $policy eq 'open';
      $action = "_a_conf_cons" if $policy eq 'open+confirm';
      $reason = "$td->{'user'} made a request that affects\n" .
                "another address ($td->{'victim'})."
        if $args->{'mismatch'};
      $reason = "$self->{'sessionuser'} is masquerading as $td->{'user'}."
        if $args->{'posing'};
    }
    unless ($action) {
      $action = "_a_allow"   if $policy eq 'open';
      $action = "_a_confirm" if $policy eq 'open+confirm';
      $action = "_a_allow"     if $policy eq 'auto';
      $action = "_a_confirm"   if $policy eq 'auto+confirm';
      $action = "_a_consult"   if $policy eq 'closed';
      $action = "_a_conf_cons" if $policy eq 'closed+confirm';
      $reason = "The ${request}_policy setting requires confirmation."
        if $action eq "_a_consult";
      $reason = "The ${request}_policy setting requires confirmation."
        if $action eq "_a_confirm";
      $reason = "The ${request}_policy setting requires confirmation from the subscriber and the list owner."
        if $action eq "_a_conf_cons";
    }

    # The variable was syntax-checked when it was set, so we can just
    # blow up if we get here.
    $log->abort("Can't handle policy: $policy") unless $action;
  }
  # If the suplied password was correct for the victim, we don't need to
  # confirm.
  elsif (access_def($request, 'mismatch')) {
    if ($args->{'posing'}) {
      $action = "_a_confirm2";
      $reason = "$self->{'sessionuser'} is masquerading as $td->{'user'}.";
    }
    elsif ($args->{'mismatch'} && !$args->{'user_password'}) {
      $action = "_a_confirm";
      $reason = "$td->{'user'} made a request that affects\n" .
                "a different address ($td->{'victim'}).\n";
    }
    else {
      $action = "_a_allow";
    }
  }

  # Now call the specific default function if it exists; can't just
  # check definedness of the function because autoloading screws this
  # up.
  elsif (access_def($request, 'special')) {
    $action = "_d_$request";
  }

  # Finally just deny the request
  else {
    $action = "_a_deny";
  }

  if ($args->{'delay'} and $action eq '_a_allow') {
    $action = '_a_delay';
  }

  if (defined $reason) {
    $args->{'reasons'} = "$reason\002" . $args->{'reasons'}; 
  }
  return $self->$action(@_);
}

# Normally the default would be to allow, but we must first check the
# advertise and noadvertise variables.  These are regexp arrays
# (unparsed but already syntax checked).  If advertise matches then we
# succeed, else if noadvertise then we fail (unless the address is
# subscribed to the list), else we succeed.
use Safe;
sub _d_advertise {
  my ($self, $arg, $td, $args) = @_;
  my $log = new Log::In 150;
  my ($adv, $i, $noadv);
  shift @_;

  $adv = $self->_list_config_get($td->{'list'}, 'advertise');

  for $i (@$adv) {
    return $self->_a_allow(@_) if Majordomo::_re_match($i, $td->{'user'}->strip);
  }

  # Somewhat complicated; we try not to check membership unless we
  # need to; we do so only if we would otherwise deny.
  $noadv = $self->_list_config_get($td->{'list'}, 'noadvertise');
  for $i (@$noadv) {
    if (Majordomo::_re_match($i, $td->{'user'}->strip)) {
      if ($self->{'lists'}{$td->{'list'}}->is_subscriber($td->{'user'})) {
	return $self->_a_allow(@_);
      }
      return $self->_a_deny(@_);
    }
  }
  # By default we allow
  return $self->_a_allow(@_);
}  

# Provide the expected behavior for the post command.  This means we
# have to check moderate and restrict_post, and all of the appropriate
# variables passed into the access_check routine.
sub _d_post {
  my ($self, $arg, $td, $args) = @_;
  my $log = new Log::In 150;
  my(@consult_vars, @deny_vars, $i, $member, $moderate, $restrict,
     $tmp, $tmpl, $tmps);
  shift @_;

  @consult_vars = qw(bad_approval body_length_exceeded dup_msg_id dup_checksum
             dup_partial_checksum global_taboo_body global_taboo_header 
             limit_soft max_header_length_exceeded mime_consult 
             mime_header_length_exceeded taboo_body taboo_header
             total_header_length_exceeded);

  @deny_vars = qw(limit_hard mime_deny);

  # Deny is stronger than consult, so process denials first
  for $i (@deny_vars) {
    return $self->_a_deny(@_) if $args->{$i};
  }

  # Immediately consult for moderated lists
  $moderate = $self->_list_config_get($td->{'list'}, 'moderate');
  $args->{'reasons'} = "The $td->{'list'} list is moderated.\002" . 
                  $args->{'reasons'} if $moderate;
  return $self->_a_consult(@_) if $moderate;

  # Check restrict_post
  $restrict = $self->_list_config_get($td->{'list'}, 'restrict_post');
  $member = 0;
  for $i (@$restrict) {
    # First, check to see that we don't have a "list:" or "list:sublist" string
    if ($i =~ /(.+):(.*)/) {
      ($tmpl, $tmps) = ($1, $2);
      next unless $self->_make_list($tmpl);
      if ($self->{'lists'}{$tmpl}->is_subscriber($td->{'user'}, $tmps)) {
	$member = 1;
	last;
      }
    }

    # For backwards compatibility, look for "list", "list.digest",
    # "list-digest", etc.
    if ($i =~ /\Q$td->{'list'}\E([.-_]digest)?/) {
      if ($self->{'lists'}{$td->{'list'}}->is_subscriber($td->{'user'})) {
	$member = 1;
	last;
      }
    }
    # Otherwise we have to check both the exact restrict_post file and
    # try to remove the list name and a separator from it and try that
    else {
      if ($self->{'lists'}{$td->{'list'}}->is_subscriber($td->{'user'}, $i)) {
	$member = 1;
	last;
      }
      else {
	$tmp = $i;
	$tmp =~ s/\Q$td->{'list'}\E[.-_]?//;
	if ($self->{'lists'}{$td->{'list'}}->is_subscriber($td->{'user'}, $i)) {
	  $member = 1;
	  last;
	}
      }
    }
  }
  if (@$restrict && !$member) {
    $args->{'reasons'} = "Non-Member Submission from $td->{'victim'}\002" 
                        . $args->{'reasons'};
    return $self->_a_consult(@_);
  }

  # Now check all of the variables passed in from resend and consult
  # if necessary
  return $self->_a_consult(@_)
    if $args->{'admin'} && $self->_list_config_get($td->{'list'}, 'administrivia');

  for $i (@consult_vars) {
    # Consult only if the value is defined and is either a string or a
    # positive integer.
    return $self->_a_consult(@_)
      if defined($args->{$i}) && ($args->{$i} =~ /\D/ || $args->{$i} > 0);
  }

  if ($args->{'delay'}) {
    return $self->_a_delay(@_);
  }
  return $self->_a_allow(@_);
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

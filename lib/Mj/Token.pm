=head1 NAME

Token.pm - conformation token functions for Majordomo

=head1 SYNOPSIS

  # Pick a token out of a string
  $token = $mj->t_recognize($string);

  # Accept a token
  ($ok, $mess) = $mj->t_accept($token);

=head1 DESCRIPTION

This module handles the confirmation token system for Majordomo.  This
involves managing a database of tokens, performing various manipulations on
those tokens, and performing internal core Majordomo functions when the
acceptance criteria for a token are met.

This contains two packages; one exports functions into Majordomo's
namespace, the other is a simple database object to hold the tokens.  The
reason that Majordomo's namespace is used is because the internal routines
here have to call internal core Majordomo functions in order to continue
after token confirmation.

=cut

package Mj::Token;
use Mj::Log;
use Mj::TokenDB;
use strict;

=head2 t_recognize(string)

This checks a string to see if it contains what looks to be a valid token.
If it does, that token will be returned.  Otherwise, undef will be
returned.  This does not verify that the token actually exists in the
database.

The extracted token is returned.  It is free of any tainting.

=cut
sub t_recognize {
  my $self = shift;
  my $str  = shift || "";
  my $log  = new Log::In 60;

  $str =~ /([A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4})/;
  $1;
}

use AutoLoader 'AUTOLOAD';
1;
__END__

=head2 t_gen()

This generates a unique token and returns it as a string.  This token is
random; the length is currently fixed at 12 hex digits plus two dashes.
The total key space is 2^48, which should allow enough keys for the
conceivable future.  It is easy to tune the key length; in fact, it would
be possible to make it configurable.

This routine does not ensure that the token is unique.

This could do any number of things, such as generate a triple of words or a
random pronouncable string.  The only constraint is that the keyspace
should be large enough to accommodate the load of the site and that
t_recognize be taught how to find the new format.

=cut
sub t_gen {
  my $self = shift;
  my $log  = new Log::In 60;
  my ($i, $token);
  
  $token = "";
  for (my $i=0; $i<6; $i++) {
    # Perl 5.004 automatically does srand
    $token .= uc(unpack('h2', pack('c',rand 256)));
    $token .= "-" if ($i==1||$i==3);
  }
  return $token;
}

=head2 t_add(user, time, approvals, cmdline, request, list, arglist)

This adds a token to the database.  The token itself is generated, then a
database entry is added with all of the information filled in.  This will
loop intil a token is generated that does not already exist in the
database.

=cut
sub t_add {
  my $self = shift;
  my ($token, $data, $ok);
  
  $self->_make_tokendb;
  $data =
    {
     'type'       => shift,
     'list'	  => shift,
     'request'	  => shift,
     'requester'  => shift,
     'victim'	  => shift,
     'mode'       => shift,
     'cmdline'	  => shift,
     'approvals'  => shift,
     'chain1'     => shift,
     'chain2'     => shift,
     'chain3'     => shift,
     'chain4'     => shift,
     'arg1'	  => shift,
     'arg2'	  => shift,
     'arg3'	  => shift,
     'expire'     => shift,
     'remind'     => shift,
     'time'       => time,
     'sessionid'  => $self->{'sessionid'},
    };
  
  while (1) {
    $token = $self->t_gen;
    ($ok, undef) = $self->{'tokendb'}->add("",$token,$data);
    last if $ok;
  }
  return $token;
}

=head2 t_remove(token, unspool)

Removes a token from the database.  If optional argument unspool is true,
also deletes the file "spool/$token" from the GLOBAL FileSpace, if it
exists.

=cut
sub t_remove {
  my $self = shift;
  my $tok  = shift;
  my $unsp = shift;
  my $log  = new Log::In 150, "$tok";
  $self->_make_tokendb;
  if ($unsp) {
    $self->_list_file_delete('GLOBAL', "spool/$tok", 1);
  }
  $self->{'tokendb'}->remove("", $tok);
}

=head2 confirm(file, user, list, request, cmdline, approvals, chain1,
chain2, chain3, chain4, arglist)

This adds a token to the database and mails out the confirmation notice.

The chain fields make a chained confirm->consult, like
subscribe_policy=closed+confirm.  The idea is that when the
confirmation token is accepted, a consultation token is generated with
the data in the chain fields (if any is present).

Data we have to chain so we can generate a complete consultation
token:

filename, approval count, moderator group, group size (?)

=cut
use MIME::Entity;
sub confirm {
  my ($self, $fname, $list, $request, $requester, $victim, $mode,
      $cmdline, $approvals, $chain1, $chain2, $chain3, $chain4, $arg1,
      $arg2, $arg3) = @_;
  my $log  = new Log::In 50;
  my (%repl, $token, $cset, $data, $ent, $sender, $url, $file, $mj_addr,
      $mj_owner, $expire, $expire_days, $desc, $c_type, $c_t_encoding,
      $remind, $remind_days);

  $self->_make_tokendb;

  # Figure out when a token will expire
  $expire_days = $self->_list_config_get($list, "token_lifetime");
  $expire = time+86400*$expire_days;
  $remind_days = $self->_list_config_get($list, "token_remind");
  $remind = time+86400*$remind_days;

  # Make a token and add it to the database
  $token = $self->t_add('confirm', $list, $request, $requester,
			$victim, $mode, $cmdline, $approvals, $chain1,
			$chain2, $chain3, $chain4, $arg1, $arg2,
			$arg3, $expire, $remind);

  # Spool away the message if doing a post request
  if ($request eq 'post') {
    $self->_list_file_put('GLOBAL', "spool/$token", $arg1, 'overwrite',
			  "Spooled awaiting acceptance of $token",
			  'message/rfc822', 'ISO-8859-1', '8bit', 'w');
  }

  # Extract the file from storage
  ($file, $desc, $c_type, $cset, $c_t_encoding) =
    $self->_list_file_get($list, $fname);
  
  $log->abort("Couldn't get $fname from $list")
    unless $file;

  $sender   = $self->_list_config_get($list, 'sender');
  $mj_addr  = $self->_global_config_get('whoami');
  $mj_owner = $self->_global_config_get('whoami_owner');
  $url = $self->_global_config_get('confirm_url');
  $url = $self->substitute_vars_string($url,
				       'TOKEN' => $token,
				      );

  %repl = ('OWNER'      => $sender,
	   'MJ'         => $mj_addr,
	   'MJOWNER'    => $mj_owner,
	   'TOKEN'      => $token,
	   'URL'        => $url,
	   'EXPIRE'     => $expire_days,
	   'REMIND'     => $remind_days,
	   'REQUESTER'  => $requester,
	   'VICTIM'     => $victim,
	   'APPROVALS'  => $approvals,
	   'CMDLINE'    => $cmdline,
	   'REQUEST'    => $request,
	   'LIST'       => $list,
	   'SESSIONID'  => $self->{'sessionid'},
	   'ARG1'       => $arg1,
	   'ARG2'       => $arg2,
	   'ARG3'       => $arg3,
	  );

  $file = $self->substitute_vars($file, %repl);
  $desc = $self->substitute_vars_string($desc, %repl);

  # Send it off
  $ent = build MIME::Entity
    (
     Path        => $file,
     Type        => $c_type,
     Charset     => $cset,
     Encoding    => $c_t_encoding,
     Filename    => undef,
     To          => $victim,
     -From       => $mj_addr,
     '-Reply-To' => $mj_addr,
     -Subject    => "$token : $desc",
    );

  $self->mail_entity($mj_owner, $ent, $victim);

  $ent->purge;
}

=head2 consult

This adds a token to the database and mails out a message to the moderator.

If this is a post request, the message is used as the body with no
substitutions instead of using a file of instructions.  Also, post requests
go to the moderator while administrative requests go to the approval
address.

XXX Somehow communicate the reason the request was bounced?  This must go
in the subject and must include the possibility of multiple bounce reasons.
arg1 will be the name of the message file and arg2 will be the list of
reasons, concatenated with %~%.

XXX Multiple moderators?  Choose from list of moderators?  The 'moderator'
variable lists the moderator as normal.  The 'moderators' array allows the
listing of several moderators.  When a message needs approval, it is sent
to 'moderator_group' of them chosen at random, (or all of them, if
'moderator_group' is zero or unset.

XXX This really needs to be looked at very closely.

This function takes:

  fname - name of template file to mail to owner
  group - name of moderator group to use
  list
  request
  requester
  victim
  mode
  cmdline
  approvals - number of approvals required
  chain1 - 
  chain2 - useless, really, since we don''t chain
  chain3 - consultation tokens.
  chain4 - 
  arg1-3 - arguments for the real command

Rearrange these.  Add moderator pool size.  Add some way to tell that the
token came from a consultation, so that we can send the results to the
proper place.

=cut
use MIME::Entity;
sub consult {
  my ($self, $fname, $group, $list, $request, $requester, $victim,
      $mode, $cmdline, $approvals, $chain1, $chain2, $chain3, $chain4,
      $arg1, $arg2, $arg3, $sessionid) = @_;
  my $log  = new Log::In 50;
  my (%repl, @mod1, @mod2, $c_t_encoding, $c_type, $cset, $data, $desc,
      $ent, $expire, $expire_days, $file, $mj_addr, $mj_owner, $remind,
      $remind_days, $sender, $subject, $token, $url);

  $self->_make_tokendb;

#  $cmdline = "(post to $list)" if $request eq "post";
  $sessionid ||= $self->{'sessionid'};

  $expire_days = $self->_list_config_get($list, "token_lifetime");
  $expire = time+86400*$expire_days;
  $remind_days = $self->_list_config_get($list, "token_remind");
  $remind = time+86400*$remind_days;

  # Make a token and add it to the database
  $token = $self->t_add('consult', $list, $request, $requester,
			$victim, $mode, $cmdline, $approvals, $chain1,
			$chain2, $chain3, $chain4, $arg1, $arg2,
			$arg3, $expire, $remind);

  $sender = $self->_list_config_get($list, "sender");
  $mj_addr  = $self->_global_config_get("whoami");
  $mj_owner = $self->_global_config_get("whoami_owner");
  $url = $self->_global_config_get("confirm_url");
  $url = $self->substitute_vars_string($url,
				       'TOKEN' => $token,
				      );

  # This extracts the moderator. XXX We want to rewrite this so that it
  # extracts the appropriate moderator group and picks a sample of the
  # appropriate size.  I think this can come much later, though.
  @mod1 = @{$self->_list_config_get($list, 'moderators')};
  if (@mod1) {
    $group = $self->_list_config_get($list, 'moderator_group');
    if ($group) {
      for (my $i=0; $i<$group && @mod1; $i++) {
	push(@mod2, splice(@mod1, rand @mod1, 1));
      }
    }
    else {
      @mod2 = @mod1;
    }
  }
  else {
    $mod2[0] = $self->_list_config_get($list, 'moderator') || $sender;
  }

  # For post requests, the consult message we send to the
  # owner/moderator has to include the entire original message (since
  # they'll want to read it).  Since we also want to enable the old
  # edit-the-message-to-approve-it thing, we can't include anything
  # else.  We do give a useful content-type, though.  This is going to
  # be a sticking point.
  if ($request eq 'post') {
    # Drop the message into storage
    $self->_list_file_put('GLOBAL', "spool/$token", $arg1, 'overwrite',
			  "Spooled awaiting acceptance of $token",
			  'message/rfc822', 'ISO-8859-1', '8bit', 'w');

    
    # Build a mesage
    $subject = '';
    if ($arg2) {
      ($subject = $arg2) =~ s/\%\~\%/\n /g;
    }
    $subject = "$token : CONSULT $list\n $subject";
    $ent = build MIME::Entity
      (
       Path            => $arg1,
       Type            => 'message/rfc822',
       Encoding        => '8bit',
       Filename        => undef,
       -From           => $sender,
       '-X-Mj-Confirm' => $url,
       '-Reply-To'     => $mj_addr,
      );
    # This prevents Mail::Header from refolding gratuitously
    $ent->head->modify(0);
    $ent->head->add('Subject', $subject);

    $self->mail_entity($mj_addr, $ent, @mod2);
    return;
  }

  # Not doing a post, so we send a form letter.
  # Extract the file from storage:
  ($file, $desc, $c_type, $cset, $c_t_encoding) =
    $self->_list_file_get($list, $fname);
  
  $::log->abort("Couldn't get $fname from $list")
    unless $file;

  %repl = ('OWNER'      => $sender,
	   'MJ'         => $mj_addr,
	   'MJOWNER'    => $mj_owner,
	   'TOKEN'      => $token,
	   'URL'        => $url,
	   'EXPIRE'     => $expire_days,
	   'REMIND'     => $remind_days,
	   'REQUESTER'  => $requester,
	   'VICTIM'     => $victim,
	   'APPROVALS'  => $approvals,
	   'CMDLINE'    => $cmdline,
	   'REQUEST'    => $request,
	   'LIST'       => $list,
	   'SESSIONID'  => $self->{'sessionid'},
	   'ARG1'       => $arg1,
	   'REASONS'    => $arg2,
	   'ARG3'       => $arg3,
	  );

  $file = $self->substitute_vars($file, %repl);
  $desc = $self->substitute_vars_string($desc, %repl);

  # Send it off
  $ent = build MIME::Entity
    (
     Path        => $file,
     Type        => $c_type,
     Charset     => $cset,
     Encoding    => $c_t_encoding,
     Filename    => undef,
     -From       => $mj_addr,
     '-Reply-To' => $mj_addr,
     -Subject    => "$token : $desc",
    );

  $self->mail_entity($sender, $ent, @mod2);
  $ent->purge;
#  unlink $file || $::log->abort("Couldn't unlink $file, $!");
}

=head2 t_accept(token)

This accepts a token.  It verifies that the token exists and if so
decrements the approval count.  If the count is zero, the action that
prompted the token is carried out by prefixing '_' to the request and
executing it as a function with arguments $list, $arg1, $arg2, and $arg3.

This returns a list:

False if the token is not valid, a positive number of the token is fully
approved and the action is completed, or a negative number of the token
requires further approval.

The token data (to save a t_info call).

The full results from the bottom half of the command, if a command was run.

XXX When accepting a consult token, the user who made the request
should get some notice that the token was accepted.  Right now the
list owner sees the output, which is dumb.

XXX Perhaps break out acceptance of a consult token so we don''t have
to load the MIME stuff.

=cut
use MIME::Entity;
use Mj::Format;
use Mj::MailOut;
sub t_accept {
  my $self  = shift;
  my $token = shift;
  my $log   = new Log::In 50, "$token";
  my (@out, $data, $ent, $ffunc, $func, $line, $mess, $ok, $outfh,
      $sender, $tmp);

  $self->_make_tokendb;
  $data = $self->{'tokendb'}->lookup($token);
  return (0, "Nonexistant token \"$token\"!\n") unless $data;
  
  # Tick off one approval
  # XXX Note that more approvals are stull required.
  $data->{'approvals'}--;
  if ($data->{'approvals'} > 0) {
    $self->{'tokendb'}->replace("", $token, $data);
    return (-1, '', $data, -1);
  }

  # All of the necessary approvals have been gathered.  Make sure we don't
  # now have to ask the list owner.
  if ($data->{'chain1'}) {

    # We have a confirm+consult token.  Generate the consult token
    # from it
    $self->consult($data->{'chain1'},
		   $data->{'chain2'},
		   $data->{'list'},
		   $data->{'request'},
		   $data->{'requester'},
		   $data->{'victim'},
		   $data->{'mode'},
		   $data->{'cmdline'},
		   $data->{'chain3'},
		   '', '', '',
		   $data->{'arg1'},
		   $data->{'arg2'},
		   $data->{'arg3'},
		   $data->{'sessionid',}
		  );
    $self->t_remove($token);

    # and build the return message string from the replyfile
    my ($file, $desc, $c_type, $cset, $c_t_encoding) =
      $self->_list_file_get($data->{'list'}, $data->{'chain4'});
    my $fh = new Mj::File "$file"
      || $log->abort("Cannot read file $file, $!");
    while (defined ($line = $fh->getline)) {
      $mess .= $line;
    }
    return (-1, $mess, $data, -1);
  }

  # We know we want to carry out the action, so call the core routine
  # and stash the results
  $func = "_$data->{'request'}";
  @out = $self->$func($data->{'list'},
		      $data->{'requester'},
		      $data->{'victim'},
		      $data->{'mode'},
		      $data->{'cmdline'},
		      # really, really, really gross hack
		      ($data->{'request'} eq 'post' ? $token : $data->{'arg1'}),
		      $data->{'arg2'},
		      $data->{'arg3'},
		     );

  # Nuke the token, and delete any spooled files associated with it.
  $self->t_remove($token, 1);

  # If we're accepting a confirm token, we can just return the results
  # so that they'll be formatted by the core accept routine.
  return (1, '', $data, @out) if ($data->{'type'} eq 'confirm');

  # So we're accepting a consult token. We need to give back some
  # useful info the the accept routine so the owner will know that the
  # accept worked, but we also need to generate a separate reply
  # message and send it to the user so that they get the results from
  # that command they submitted so long ago...  To do this, we create
  # a MIME entity and format the output of the command return into its
  # bodyhandle.  Then we send it.  Then we return some token info and
  # pretend we did a 'consult' (in $rreq) command so that the accept
  # routine will format it as we want for the reply to the owner.
  
  # First make a tempfile
  $tmp = $self->_global_config_get("tmpdir");
  $tmp = "$tmp/mj-tmp." . $self->unique;
  $outfh = new IO::File ">$tmp";

  # Print some introductory info into the file, so the user is not
  # surprised.  XXX This all should probably be in a file somewhere.
  # Even better, this should somehow be settable by the owner, either
  # when the request is approved or when the original comsult action
  # was generated.
  if ($data->{'request'} eq 'post') {
    print $outfh "The list owner has approved your message.\n";
    print $outfh "It is being distributed now.\n";
  }
  else {
    print $outfh "The list owner has approved your request.\n";
    print $outfh "Here are the results:\n\n";
  }    

  # Now pass those results to the formatter and have it spit its
  # output to our tempfile.
  $ffunc = "Mj::Format::$data->{'request'}";
  my $ret;
  {
    no strict 'refs';
    $ret = &$ffunc($self, $outfh, $outfh, 'text',
		   $data->{'requester'},
		   '', '', 'core',
		   $data->{'cmdline'},
		   $data->{'mode'},
		   $data->{'list'},
		   $data->{'victim'},
		   $data->{'arg1'},
		   $data->{'arg2'},
		   $data->{'arg3'},
		   @out,
		  );
  }
  close $outfh;

  $sender = $self->_list_config_get($data->{'list'}, "sender");
  
  # Construct a message.  (MIME-tools is cool.)
  $ent = build MIME::Entity
    (
     Path     => $tmp,
     Filename => undef,
     -To      => $data->{'victim'},
     -From    => $sender, 
     -Subject => "Results from delayed command",
    );

  # Mail out what we just generated
  $self->mail_entity($sender, $ent, $data->{'victim'});

  $ent->purge;

  # Now convince the formatter to give the accepter some info about
  # the token, but not the command return.
  $data->{'request'} = 'consult';
  return (1, '', $data, @out);
}

=head2 t_reject(token)

This takes a token and eradicates it.

=cut
sub t_reject {
  my $self = shift;
  my $token = shift;
  my $log   = new Log::In 60, "$token";
  my ($data);

  $self->_make_tokendb;

  (undef, $data) = $self->t_remove($token, 1);
  return unless $data;

  # XXX Notify/requester the owner unless $quiet
  
  return (1, $data);
}

=head2 t_info

This returns a hashref containing all information about a token.

=cut
sub t_info {
  my $self = shift;
  my $token = shift;
  my $log = new Log::In 60, "$token";

  $self->_make_tokendb;
  my $data = $self->{'tokendb'}->lookup($token);

  return (0, "Illegal token!\n") unless $data;

  return 1, '', $data;
}

=head2 t_remind

This goes through all of the stored tokens and sends out reminders as
necessary.

=cut
use MIME::Entity;
sub t_remind {
  my $self = shift;
  my $log  = new Log::In 60;
  my $time = time;
  my (%repl, @reminded, @tmp, $cset, $cte, $ctype, $data, $desc, $ent,
      $expire, $file, $gurl, $i, $mj_addr, $mj_owner, $sender, $token,
      $url);

  my $mogrify = sub {
    my $key  = shift;
    my $data = shift;

    if (!$data->{'reminded'} && !$data->{'permanent'} &&
	$time > $data->{'remind'})
      {
	push @reminded, ($key, $data);
	$data->{'reminded'} = 1;
	return (0, 1);
      }
    return (0, 0);
  };

  $self->_make_tokendb;
  $self->{'tokendb'}->mogrify($mogrify);

  # Send out reminder notices
  @tmp = @reminded;
  if (@tmp) {

    # Grab some global variables
    $mj_addr  = $self->_global_config_get('whoami');
    $mj_owner = $self->_global_config_get('whoami_owner');
    $gurl = $self->_global_config_get('confirm_url');

    while (($token, $data) = splice(@reminded, 0, 2)) {
      # Extract the file from storage
      ($file, $desc, $ctype, $cset, $cte) =
	$self->_list_file_get($data->{'list'}, "token_remind");

      # Extract some list-specific variables
      $sender = $self->_list_config_get($data->{'list'}, 'sender');
      $url    = $self->substitute_vars_string($gurl,
					      'TOKEN' => $token,
					     );

      # Find number of days left until it dies
      $expire = int(($data->{'expire'}+43200-time)/86400);

      # Generate replacement hash
      %repl = (OWNER      => $sender,
	       MJ         => $mj_addr,
	       MJOWNER    => $mj_owner,
	       TOKEN      => $token,
	       URL        => $url,
	       EXPIRE     => $expire,
	       REQUESTER  => $data->{'requester'},
	       VICTIM     => $data->{'victim'},
	       APPROVALS  => $data->{'approvals'},
	       CMDLINE    => $data->{'cmdline'},
	       REQUEST    => $data->{'request'},
	       LIST       => $data->{'list'},
	       SESSIONID  => $data->{'sessionid'},
	       ARG1       => $data->{'arg1'},
	       ARG2       => $data->{'arg2'},
	       ARG3       => $data->{'arg3'},
	      );

      # Substitute values in the file and the description
      $file = $self->substitute_vars($file, %repl);
      $desc = $self->substitute_vars_string($desc, %repl);
      
      # Build an entity
      $ent = build MIME::Entity
	(
	 Path        => $file,
	 Type        => $ctype,
	 Charset     => $cset,
	 Encoding    => $cte,
	 Filename    => undef,
	 -From       => $mj_addr,
	 '-Reply-To' => $mj_addr,
	 -Subject    => "$token : $desc",
	);
      
      # Mail it out; the victim gets confirm notices, otherwise the owner
      # gets them
      if ($data->{type} eq 'confirm') {
	$self->mail_entity($mj_owner, $ent, $data->{'victim'});
      }
      else {
	$self->mail_entity($mj_owner, $ent, $sender);
      }
	
      # Purge the entity
      $ent->purge;
    }
  }
  return @reminded;
}

=head2 t_expire

This goes through all of the tokens and removes the ones which are older
than their 'expire' time.

Returns a list of (key, data) pairs that were deleted.

XXX Need to notify owner of implicit rejection if a consult token expires.

=cut
sub t_expire {
  my $self = shift;
  my $log  = new Log::In 60;
  my $time = time;
  my (@kill, @nuked, $i, $key, $data);

  my $mogrify = sub {
    my $key  = shift;
    my $data = shift;

    if (!$data->{'permanent'} && $time > $data->{'expire'}) {
      push @nuked, ($key, $data);
      return (1, 1, undef);
    }
    return (0, 0);
  };

  $self->_make_tokendb;
  $self->{'tokendb'}->mogrify($mogrify);

  # Unspool any spooled documents relating to the nuked tokens
  @kill = @nuked;
  while (($key, $data) = splice(@nuked, 0, 2)) {
    $self->_list_file_delete('GLOBAL', "spool/$key");
  }
  return @nuked;
}

=head2 _make_tokendb private

This generates and initializes the token database.

=cut
sub _make_tokendb {
  my $self = shift;
  
  unless ($self->{'tokendb'}) {
    $self->{'tokendb'} =
      new Mj::TokenDB "$self->{'ldir'}/GLOBAL/_tokens";
  }
  1;
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

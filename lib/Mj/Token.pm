=head1 NAME

Token.pm - conformation token functions for Majordomo

=head1 SYNOPSIS

  # Pick a token out of a string
  $token = $mj->t_recognize($string);

  # Accept a token
  ($ok, $mess) = $mj->t_accept($token, $mode);

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
use Mj::CommandProps qw(:function);
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

  if ($str =~ /([A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4})/) {
    return $1;
  }
  return;
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
     'list'       => shift,
     'command'    => shift,
     'user'       => shift,
     'victim'     => shift,
     'mode'       => shift,
     'cmdline'    => shift,
     'approvals'  => shift,
     'chain1'     => shift,
     'chain2'     => shift,
     'chain3'     => shift,
     'chain4'     => shift,
     'arg1'          => shift,
     'arg2'          => shift,
     'arg3'          => shift,
     'expire'     => shift,
     'remind'     => shift,
     'reminded'   => shift,
     'permanent'  => shift,
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

=head2 t_remove(token)

Removes a token from the database.

=cut
sub t_remove {
  my $self = shift;
  my $tok  = shift;
  my $log  = new Log::In 150, "$tok";
  $self->_make_tokendb;
  $self->{'tokendb'}->remove("", $tok);
}

=head2 confirm(file, arghash)

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
  my ($self, %args) = @_;

  my $log  = new Log::In 50;
  my (%file, $repl, $token, $data, $ent, $sender, $url, $file, $mj_addr,
      $mj_owner, $expire, $expire_days, $desc, $remind, $remind_days,
      $reminded, $permanent, $reasons);
  my $list = $args{'list'};

  $self->_make_tokendb;

  # Figure out when a token will expire
  $permanent = 0;
  $expire_days = $self->_list_config_get($list, "token_lifetime");
  $expire = time+86400*$expire_days;
  $remind_days = $self->_list_config_get($list, "token_remind");
  if (!$remind_days or $remind_days < 0 or $remind_days > $expire_days) {
    $remind_days = $expire_days;
    $remind = 0;
    $reminded = 1;
  }
  else {
    $remind = time+86400*$remind_days;
    $reminded = 0;
  }

  # Make a token and add it to the database
  $token = $self->t_add('confirm', $list, $args{'command'},
        		$args{'user'}, $args{'victim'}, $args{'mode'},
        		$args{'cmdline'}, $args{'approvals'},
        		@{$args{'chain'}}[0..3], @{$args{'args'}}[0..2],
			    $expire, $remind, $reminded, $permanent);

  $sender   = $self->_list_config_get($list, 'sender');
  $mj_addr  = $self->_global_config_get('whoami');
  $mj_owner = $self->_global_config_get('sender');
  $url = $self->_global_config_get('confirm_url');
  $url = $self->substitute_vars_string($url,
        			       {'TOKEN' => $token,},
        			      );

  ($reasons = $args{'args'}[1]) =~ s/\002/\n  /g;
  $repl = {'OWNER'      => $sender,
           'MJ'         => $mj_addr,
           'MJOWNER'    => $mj_owner,
           'TOKEN'      => $token,
           'URL'        => $url,
           'EXPIRE'     => $expire_days,
           'REMIND'     => $remind_days,
           'REQUESTER'  => $args{'user'},
           'REQUESTOR'  => $args{'user'},
           'VICTIM'     => $args{'victim'},
           'NOTIFY'     => $args{'notify'},
           'APPROVALS'  => $args{'approvals'},
           'CMDLINE'    => $args{'cmdline'},
           'REQUEST'    => $args{'command'},
           'LIST'       => $list,
           'SESSIONID'  => $self->{'sessionid'},
           'ARG1'       => $args{'arg1'},
           'ARG2'       => $args{'arg2'},
	       'REASONS'    => $reasons,
           'ARG3'       => $args{'arg3'},
          };

  # Extract the file from storage
  ($file, %file) = $self->_list_file_get($list, $args{'file'}, $repl, 1);
  $desc = $self->substitute_vars_string($file{'description'}, $repl);

  # Send it off
  $ent = build MIME::Entity
    (
     Path        => $file,
     Type        => $file{'c_type'},
     Charset     => $file{'charset'},
     Encoding    => $file{'c_t_encoding'},
     Filename    => undef,
                    # Note explicit stringification
     -To         => "$args{'notify'}", 
     -From       => $mj_addr,
     '-Reply-To' => $mj_addr,
     -Subject    => "$token : $desc",
     'Content-Language:' => $file{'language'},
    );

  $self->mail_entity({addr => $mj_owner,
		      type => 'T',
		      data => $token,
		     },
		     $ent,
		     $args{'notify'}
		    );

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
reasons, concatenated with \002.

XXX Multiple moderators?  Choose from list of moderators?  The 'moderator'
variable lists the moderator as normal.  The 'moderators' array allows the
listing of several moderators.  When a message needs approval, it is sent
to 'moderator_group' of them chosen at random, (or all of them, if
'moderator_group' is zero or unset.

XXX This really needs to be looked at very closely.

This function takes:

  file  - name of template file to mail to owner
  group - name of moderator group to use
  list
  request (command)
  requester (user)
  victim
  mode
  cmdline
  approvals - number of approvals required
  args - listref of (currently 3) arguments for the real command

Rearrange these.  Add moderator pool size.  Add some way to tell that the
token came from a consultation, so that we can send the results to the
proper place.

=cut
use MIME::Entity;
sub consult {
  my ($self, %args) = @_;
  my $log  = new Log::In 50;
  my (%file, @mod1, @mod2, $data, $desc, $ent, $expire, $expire_days,
      $file, $group, $mj_addr, $mj_owner, $remind, $remind_days, $repl,
      $sender, $subject, $tmp, $token, $url, $reminded, $permanent, $reasons);
  my $list = $args{'list'};

  $self->_make_tokendb;

  $args{'sessionid'} ||= $self->{'sessionid'};

  $permanent = 0;
  $expire_days = $self->_list_config_get($list, "token_lifetime");
  $expire = time+86400*$expire_days;
  $remind_days = $self->_list_config_get($list, "token_remind");
  if (!$remind_days or $remind_days < 0 or $remind_days > $expire_days) {
    $remind_days = $expire_days;
    $remind = 0;
    $reminded = 1;
  }
  else {
    $remind = time+86400*$remind_days;
    $reminded = 0;
  }

  # Make a token and add it to the database
  $token = $self->t_add('consult', $list, $args{'command'},
        		$args{'user'}, $args{'victim'}, $args{'mode'},
        		$args{'cmdline'}, $args{'approvals'},
        		@{$args{'chain'}}[0..3], @{$args{'args'}}[0..2],
                $expire, $remind, $reminded, $permanent);

  $sender = $self->_list_config_get($list, 'sender');
  $mj_addr  = $self->_global_config_get('whoami');
  $mj_owner = $self->_global_config_get('sender');
  $url = $self->_global_config_get('confirm_url');
  $url = $self->substitute_vars_string($url,
        			       {'TOKEN' => $token,},
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
  ($reasons = $args{'args'}[1]) =~ s/\002/\n  /g;

  # Not doing a post, so we send a form letter.
  # First, build our big hash of substitutions.
  $repl = {'OWNER'      => $sender,
           'MJ'         => $mj_addr,
           'MJOWNER'    => $mj_owner,
           'TOKEN'      => $token,
           'URL'        => $url,
           'EXPIRE'     => $expire_days,
           'REMIND'     => $remind_days,
           'REQUESTER'  => $args{'user'},
           'REQUESTOR'  => $args{'user'},
           'VICTIM'     => $args{'victim'},
           'APPROVALS'  => $args{'approvals'},
           'CMDLINE'    => $args{'cmdline'},
           'REQUEST'    => $args{'command'},
           'LIST'       => $list,
           'SESSIONID'  => $self->{'sessionid'},
           'ARG1'       => $args{'args'}[0],
           'ARG2'       => $args{'args'}[1],
           'REASONS'    => $reasons,
           'ARG3'       => $args{'args'}[2],
          };

  # Extract the file from storage:
  ($file, %file) = $self->_list_file_get($list, $args{'file'}, $repl, 1);
  $desc = $self->substitute_vars_string($file{'description'}, $repl);

  # Send it off
  $ent = build MIME::Entity
    (
     Path        => $file,
     Type        => $file{'c_type'},
     Charset     => $file{'charset'},
     Encoding    => $file{'c_t_encoding'},
     Filename    => undef,
     -To         => $sender,
     -From       => $sender,
     '-Reply-To' => $mj_addr,
     -Subject    => "$token : $desc",
     'Content-Language:' => $file{'language'},
    );

  if ($args{'command'} eq 'post') {
    $ent->make_multipart;
    $ent->attach(Type        => 'message/rfc822',
                 Description => 'Original message',
                 Path        => $args{'args'}[0],
                 Filename    => undef,
                );
  }
  $self->mail_entity($sender, $ent, @mod2);
  # We do not want to unlink the spool file.
  # $ent->purge;
  unlink $file || $::log->abort("Couldn't unlink $file, $!");
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

XXX Perhaps break out acceptance of a consult token so we don''t have
to load the MIME stuff.

=cut
use MIME::Entity;
use Mj::Format;
use Mj::MailOut;
sub t_accept {
  my $self  = shift;
  my $token = shift;
  my $mode = shift;
  my $log   = new Log::In 50, "$token";
  my (@out, $data, $ent, $ffunc, $func, $line, $mess, $ok, $outfh,
      $req, $sender, $tmp, $vict, $repl);

  $self->_make_tokendb;
  $data = $self->{'tokendb'}->lookup($token);
  return (0, "Nonexistent token \"$token\"!\n") unless $data;
  
  # Tick off one approval
  # XXX Note that more approvals are still required.
  $data->{'approvals'}--;
  if ($data->{'approvals'} > 0) {
    $self->{'tokendb'}->replace("", $token, $data);
    return (-1, '', $data, -1);
  }
  
  # Allow "accept-archive" to store a message in the archive but
  # not distribute it on to a mailing list.  Note that this could
  # have interesting side effects, good and bad, if used in
  # other ways.
  if (defined $mode) {
    $data->{'mode'} ||= $mode;
  }

  # All of the necessary approvals have been gathered.  Now, this may be a
  # chained token where we need to generate yet another token and send it
  # to another source.
  if ($data->{'chain1'}) {
    if ($data->{'chain2'} eq 'requester') {
      $self->confirm('chained'   => 1,
        'file'      => $data->{'chain1'},
        'group'     => $data->{'chain2'},
        'list'      => $data->{'list'},
        'command'   => $data->{'command'},
        'user'      => $data->{'user'},
        'victim'    => $data->{'victim'},
        'notify'    => $data->{'user'},
        'mode'      => $data->{'mode'},
        'cmdline'   => $data->{'cmdline'},
        'sessionid' => $data->{'sessionid'},
        'approvals' => $data->{'chain3'},
        'args'      => [$data->{'arg1'}, $data->{'arg2'}, $data->{'arg3'}],
      );
    }

    # We have a confirm+consult token, the first half was just accepted.
    # Generate the new consult token
    else {
      $self->consult('chained'   => 1,
        	   'file'      => $data->{'chain1'},
        	   'group'     => $data->{'chain2'},
        	   'list'      => $data->{'list'},
        	   'command'   => $data->{'command'},
        	   'user'      => $data->{'user'},
        	   'victim'    => $data->{'victim'},
        	   'mode'      => $data->{'mode'},
        	   'cmdline'   => $data->{'cmdline'},
        	   'sessionid' => $data->{'sessionid'},
        	   'approvals' => $data->{'chain3'},
        	   'args'      => [$data->{'arg1'}, $data->{'arg2'}, $data->{'arg3'}],
        	  );
    }
    $self->t_remove($token);

    # and build the return message string from the replyfile
    $repl = {
             'REQUESTER'  => $data->{'user'},
             'VICTIM'     => $data->{'victim'},
             'NOTIFY'     => $data->{'user'},
             'CMDLINE'    => $data->{'cmdline'},
             'REQUEST'    => $data->{'command'},
             'LIST'       => $data->{'list'},
             'SESSIONID'  => $data->{'sessionid'},
            };

    my ($file) = $self->_list_file_get($data->{'list'}, $data->{'chain4'});
    $file = $self->substitute_vars($file, $repl);
    my $fh = new Mj::File "$file"
      or $log->abort("Cannot read file $file, $!");
    while (defined ($line = $fh->getline)) {
      $mess .= $line;
    }
    return (-1, $mess, $data, -1);
  }

  $func = $data->{'command'};
  $req  = new Mj::Addr($data->{'user'});
  $vict = new Mj::Addr($data->{'victim'});
  
  $func = "_$func";
  @out = $self->$func($data->{'list'},
        	       $req,
        	       $vict,
        	       $data->{'mode'},
        	       $data->{'cmdline'},
        	       $data->{'arg1'},
        	       $data->{'arg2'},
        	       $data->{'arg3'},
        	      );

  # Nuke the token
  $self->t_remove($token);

  # If we're accepting a confirm token, we can just return the results
  # so that they'll be formatted by the core accept routine.
  return (1, '', $data, \@out) if ($data->{'type'} eq 'confirm');

  # So we're accepting a consult token. We need to give back some
  # useful info the the accept routine so the owner will know that the
  # accept worked, but we also need to generate a separate reply
  # message and send it to the user so that they get the results from
  # that command they submitted so long ago...  To do this, we create
  # a MIME entity and format the output of the command return into its
  # bodyhandle.  Then we send it.  Then we return some token info and
  # pretend we did a 'consult' (in $rreq) command so that the accept
  # routine will format it as we want for the reply to the owner.
  if ($data->{'command'} ne 'post' 
      ||
      $self->{'lists'}{$data->{'list'}}->flag_set('ackimportant', $vict)
      ||
      $self->{'lists'}{$data->{'list'}}->flag_set('ackall', $vict))
      {
 
    # First make a tempfile
    $tmp = $self->_global_config_get("tmpdir");
    $tmp = "$tmp/mj-tmp." . Majordomo::unique();
    $outfh = new IO::File ">$tmp";

    # Print some introductory info into the file, so the user is not
    # surprised.  XXX This all should probably be in a file somewhere.
    # Even better, this should somehow be settable by the owner, either
    # when the request is approved or when the original comsult action
    # was generated.
    print $outfh "The list owner has approved your request.\n";
    print $outfh "Here are the results:\n\n";

    # Convert the token data into the appropriate hash entries
    # that would have appeared in the original $request hash
    my ($td) = function_prop ($data->{'command'}, 'tokendata');
    for (keys %$td) {
      $data->{$td->{$_}} = $data->{$_};
    }

    # Now pass those results to the formatter and have it spit its
    # output to our tempfile.
    $ffunc = "Mj::Format::$data->{'command'}";
    my $ret;
    {
      no strict 'refs';
      $ret = &$ffunc($self, $outfh, $outfh, 'text', $data, \@out);
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
  }

  # Now convince the formatter to give the accepter some info about
  # the token, but not the command return.
  return (1, '', $data, \@out);
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
  return (0, "Token $token is unavailable")
    unless $data;

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
  $token =~ /(.*)/; $token = $1; # Untaint
  my $data = $self->{'tokendb'}->lookup($token);

  return (0, "Illegal token!\n") unless $data;

  return (1, $data);
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
  my (%file, @reminded, @tmp, $data, $desc, $ent, $expire, $file, $gurl, 
      $i, $mj_addr, $mj_owner, $reasons, $repl, $sender, $token, $url);

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
    $mj_owner = $self->_global_config_get('sender');
    $gurl = $self->_global_config_get('confirm_url');

    while (($token, $data) = splice(@reminded, 0, 2)) {
      # Extract the file from storage
      ($file, %file) = $self->_list_file_get($data->{'list'}, "token_remind");

      # Extract some list-specific variables
      $sender = $self->_list_config_get($data->{'list'}, 'sender');
      $url    = $self->substitute_vars_string($gurl,
        				      {'TOKEN' => $token,},
        				     );

      # Find number of days left until it dies
      $expire = int(($data->{'expire'}+43200-time)/86400);

      ($reasons = $data->{'arg2'}) =~ s/\002/\n  /g;
      # Generate replacement hash
      $repl = {OWNER      => $sender,
               MJ         => $mj_addr,
               MJOWNER    => $mj_owner,
               TOKEN      => $token,
               URL        => $url,
               EXPIRE     => $expire,
               REQUESTER  => $data->{'user'},
               REQUESTOR  => $data->{'user'},
               VICTIM     => $data->{'victim'},
               APPROVALS  => $data->{'approvals'},
               CMDLINE    => $data->{'cmdline'},
               REQUEST    => $data->{'command'},
               LIST       => $data->{'list'},
               SESSIONID  => $data->{'sessionid'},
               ARG1       => $data->{'arg1'},
               ARG2       => $data->{'arg2'},
               REASONS    => $reasons,
               ARG3       => $data->{'arg3'},
              };

      # Substitute values in the file and the description
      $file = $self->substitute_vars($file, $repl);
      $desc = $self->substitute_vars_string($file{'description'}, $repl);
      
      # Build an entity
      $ent = build MIME::Entity
        (
         Path        => $file,
         Type        => $file{'c-type'},
         Charset     => $file{'charset'},
         Encoding    => $file{'c-t-encoding'},
         Filename    => undef,
         -From       => $mj_addr,
         '-Reply-To' => $mj_addr,
         -Subject    => "$token : $desc",
         'Content-Language:' => $file{'language'},
        );
      
      # Mail it out; the victim gets confirm notices, otherwise the owner
      # gets them
      if ($data->{type} eq 'confirm') {
        $ent->head->replace('To', $data->{'victim'});
        $self->mail_entity($mj_owner, $ent, $data->{'victim'});
      }
      else {
        $ent->head->replace('To', $sender);
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
    if ($data->{'command'} eq 'post') {
      unlink "$self->{ldir}/GLOBAL/spool/$data->{arg1}";
    }
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
      new Mj::TokenDB "$self->{'ldir'}/GLOBAL/_tokens", $self->{backend};
  }
  1;
}

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

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### cperl-label-offset:-1 ***
### End: ***

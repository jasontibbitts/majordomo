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
     'arg1'       => shift,
     'arg2'       => shift,
     'arg3'       => shift,
     'expire'     => shift,
     'remind'     => shift,
     'reminded'   => shift,
     'permanent'  => shift,
     'reasons'    => shift,
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
      $reminded, $permanent, $reasons, $i);
  my $list = $args{'list'};

  return unless $self->_make_tokendb;
  $args{'command'} =~ s/_(start|chunk|done)$//;

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
			$expire, $remind, $reminded, $permanent,
                        $args{'reasons'});

  $sender   = $self->_list_config_get($list, 'sender');
  $mj_addr  = $self->_global_config_get('whoami');
  $mj_owner = $self->_global_config_get('sender');
  $url = $self->_global_config_get('confirm_url');
  $url = $self->substitute_vars_string($url,
        			       {'TOKEN' => $token,},
        			      );

  ($reasons = $args{'reasons'}) =~ s/\002/\n  /g;
  $repl = {
           $self->standard_subs($list),
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
           'COMMAND'    => $args{'command'},
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
     -From       => $sender,
     -Subject    => $desc,
     'Content-Language:' => $file{'language'},
    );

  return unless $ent;

  for $i ($self->_global_config_get('message_headers')) {
    $i = $self->substitute_vars_string($i, $repl);
    $ent->head->add(undef, $i);
  }

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
      $file, $group, $i, $mj_addr, $mj_owner, $remind, $remind_days, $repl,
      $sender, $subject, $tmp, $token, $url, $reminded, $permanent, $reasons);
  my $list = $args{'list'};

  return unless $self->_make_tokendb;
  $args{'command'} =~ s/_(start|chunk|done)$//;
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
                        $expire, $remind, $reminded, $permanent,
                        $args{'reasons'});

  $sender = $self->_list_config_get($list, 'sender');
  $mj_addr  = $self->_global_config_get('whoami');
  $mj_owner = $self->_global_config_get('sender');
  $url = $self->_global_config_get('confirm_url');
  $url = $self->substitute_vars_string($url,
        			       {'TOKEN' => $token,},
        			      );

  # This extracts a list of moderators.  If a moderator group
  # was specified, the addresses are taken from the auxiliary
  # list of the same name.  If no such list exists, the
  # "moderators" auxiliary list and the "moderators," "moderator,"
  # and "sender" configuration setting are each consulted
  # in turn until an address is found.
  $self->_make_list($list);
  $group = $args{'group'} || 'moderators';
  @mod1  = $self->{'lists'}{$list}->moderators($group);

  # The number of moderators consulted can be limited to a
  # certain (positive) number, in which case moderators
  # are chosen randomly.
  $size  = $args{'size'} or $self->_list_config_get($list, 'moderator_group');
  if (($size > 0) and (scalar @mod1 > $size)) {
    for ($i = 0; $i < $size && @mod1; $i++) {
      push(@mod2, splice(@mod1, rand @mod1, 1));
    }
  }
  else {
    @mod2 = @mod1;
  }

  ($reasons = $args{'reasons'}) =~ s/\002/\n  /g;

  # Not doing a post, so we send a form letter.
  # First, build our big hash of substitutions.
  $repl = {
           $self->standard_subs($list),
           'TOKEN'      => $token,
           'URL'        => $url,
           'EXPIRE'     => $expire_days,
           'REMIND'     => $remind_days,
           'REQUESTER'  => $args{'user'},
           'REQUESTOR'  => $args{'user'},
           'VICTIM'     => $args{'victim'},
           'APPROVALS'  => $args{'approvals'},
           'CMDLINE'    => $args{'cmdline'},
           'COMMAND'    => $args{'command'},
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
     -Subject    => $desc,
     'Content-Language:' => $file{'language'},
    );

  return unless $ent;

  for $i ($self->_global_config_get('message_headers')) {
    $i = $self->substitute_vars_string($i, $repl);
    $ent->head->add(undef, $i);
  }

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

=head2 delay(file, arghash)

This adds a delay token to the database and mails out the delay notice.
Requests in delay tokens are carried out when the token expires.

=cut
use MIME::Entity;
sub delay {
  my ($self, %args) = @_;

  my $log  = new Log::In 50;
  my (%file, $repl, $token, $data, $ent, $sender, $url, $file, $mj_addr,
      $mj_owner, $expire, $expire_days, $desc, $permanent, $reasons, $i);
  my $list = $args{'list'};

  return unless $self->_make_tokendb;
  $args{'command'} =~ s/_(start|chunk|done)$//;

  # Figure out when a token will expire
  $permanent = 0;
  $expire = time + $args{'delay'};

  # Make a token and add it to the database
  $token = $self->t_add('delay', $list, $args{'command'},
        		$args{'user'}, $args{'victim'}, $args{'mode'},
        		$args{'cmdline'}, $args{'approvals'},
        		@{$args{'chain'}}[0..3], @{$args{'args'}}[0..2],
			$expire, 0, 1, $permanent, $args{'reasons'});

  # Do not inform the victim if "quiet" mode was specified
  # or if the request was a posted message.
  return 1 if ($args{'mode'} =~ /quiet/ or $args{'command'} eq 'post');

  $sender   = $self->_list_config_get($list, 'sender');
  $mj_addr  = $self->_global_config_get('whoami');
  $mj_owner = $self->_global_config_get('sender');
  $url = $self->_global_config_get('confirm_url');
  $url = $self->substitute_vars_string($url,
        			       {'TOKEN' => $token,},
        			      );

  ($reasons = $args{'reasons'}) =~ s/\002/\n  /g;
  $repl = {
           $self->standard_subs($list),
           'TOKEN'      => $token,
           'URL'        => $url,
           'FULFILL'    => scalar localtime ($expire),
           'REQUESTER'  => $args{'user'},
           'REQUESTOR'  => $args{'user'},
           'VICTIM'     => $args{'victim'},
           'NOTIFY'     => $args{'notify'},
           'APPROVALS'  => $args{'approvals'},
           'CMDLINE'    => $args{'cmdline'},
           'COMMAND'    => $args{'command'},
	   'REASONS'    => $reasons,
           'SESSIONID'  => $self->{'sessionid'},
           'ARG1'       => $args{'args'}->[0],
           'ARG2'       => $args{'args'}->[1],
           'ARG3'       => $args{'args'}->[2],
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
     -From       => $sender,
     -Subject    => $desc,
     'Content-Language:' => $file{'language'},
    );

  return unless $ent;

  for $i ($self->_global_config_get('message_headers')) {
    $i = $self->substitute_vars_string($i, $repl);
    $ent->head->add(undef, $i);
  }

  $self->mail_entity({addr => $mj_owner,
		      type => 'D',
		      data => $token,
		     },
		     $ent,
		     $args{'notify'}
		    );

  $ent->purge;
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
  my $comment = shift;
  my $delay = shift;
  my $log   = new Log::In 50, $token;
  my (%file, @out, $data, $ent, $ffunc, $func, $line, $mess, $ok, $outfh,
      $req, $sender, $tmp, $tmpdir, $vict, $repl, $whoami);

  $self->_make_tokendb;
  $data = $self->{'tokendb'}->lookup($token);
  return (0, "Nonexistent token \"$token\"!\n") unless $data;

  # Tick off one approval
  $data->{'approvals'}--;

  # If a delay was requested, change the token type and return.
  if ($data->{'type'} eq 'consult' and defined $delay and $delay > 0) {
    $data->{'expire'} = time + $delay;
    $data->{'type'} = 'delay';
    $data->{'reminded'} = 1;
    $self->{'tokendb'}->replace('', $token, $data);
    return (-1, sprintf "Request delayed until %s.\n", 
            scalar localtime ($data->{'expire'}), $data, -1);
  }
  
  if ($data->{'approvals'} > 0) {
    $self->{'tokendb'}->replace("", $token, $data);
    return (-1, "$data->{'approvals'} approvals are still required", 
            $data, -1);
  }
  
  # Allow "accept-archive" to store a message in the archive but
  # not distribute it on to a mailing list.  Note that this could
  # have interesting side effects, good and bad, if used in
  # other ways.
  if (defined $mode and $data->{'command'} eq 'post') {
    $data->{'mode'} .= $data->{'mode'} ? "-$mode" : $mode;
  }

  $data->{'ack'} = 0;

  $repl = {
           $self->standard_subs($data->{'list'}),
           'CMDLINE'    => $data->{'cmdline'},
           'DATE'       => scalar localtime ($data->{'time'}),
           'NOTIFY'     => $data->{'user'},
           'COMMAND'    => $data->{'command'},
           'REQUESTER'  => $data->{'user'},
           'SESSIONID'  => $data->{'sessionid'},
           'VICTIM'     => $data->{'victim'},
          };

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


    my ($file) = $self->_list_file_get($data->{'list'}, $data->{'chain4'});
    $file = $self->substitute_vars($file, $repl);
    my $fh = new Mj::File "$file"
      or $log->abort("Cannot read file $file, $!");
    while (defined ($line = $fh->getline)) {
      $mess .= $line;
    }
    $fh->close;
    unlink $file;
    return (-1, $mess, $data, -1);
  } # chain1 

  ($func = $data->{'command'}) =~ s/_(start|chunk|done)$//;
  $vict = new Mj::Addr($data->{'victim'});
  $req  = new Mj::Addr($data->{'user'});

  if ($func ne 'post') {
  
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
  }
  else {
    if (! -r $data->{'arg1'}) {
      # missing spool file; inform and quit.
      $self->inform("GLOBAL", "post", $data->{'user'}, $data->{'user'},
        $data->{'cmdline'}, "resend",
        0, 0, -1, "Spool file $data->{'arg1'} is missing; cannot requeue.");
      @out = (0, "Unable to locate the posted message.\n");
    }
    else {
      # To respond to the request faster, add an Approved header
      # and requeue the message.  

      # Obtain sender and list (with possible sublist) addresses.
      $sender = $self->_list_config_get($data->{'list'}, 'sender');
      $tmpdir = $self->_global_config_get('tmpdir');

      # Reconstruct the list address.
      my %avars = split("\002", $data->{'arg3'});
      $whoami = $data->{'list'};
      $data->{'auxlist'} = $avars{'sublist'} || '';
      if ($avars{'sublist'} ne '') {
        $whoami .=  "-$avars{'sublist'}";
      }
      $whoami .=  '@' . $self->_list_config_get($data->{'list'}, 'whereami');

      # Set up a parser to add headers to the message.
      my $parser = new Mj::MIMEParser;
      $parser->output_to_core($self->_global_config_get("max_in_core"));
      $parser->output_dir($tmpdir);
      $parser->output_prefix("mjq");

      my $pw = $self->_list_config_get($data->{'list'}, "master_password"); 
      # Add or replace the Approved header, and mail the message. 
      # Remove the Delivered-To header if it exists.
      $ok = $parser->replace_headers($data->{'arg1'}, 
                                     'Approved' => $pw,
                                     '-Delivered-To' => '');
      if ($ok and $sender and $whoami) {
        $self->mail_message($sender, $data->{'arg1'}, $whoami);
        @out = (1, "The message was requeued and will be delivered soon.\n");
        # Delete the spool file.
        unlink $data->{'arg1'};
      }
      else {
        @out = (0, "The message could not be requeued.\n");
      }
    }
  }
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
  # Acknowledgements of posts take place in Mj::Resend::_post.
  if ($data->{'command'} ne 'post') {
    # Note that the victim was notified.
    $data->{'ack'} = 1;

    # First make a tempfile
    ($tmp, %file) = $self->_list_file_get($data->{'list'}, "repl_fulfill", $repl);
    $outfh = new IO::File ">>$tmp";
    return (1, '', $data, [@out]) unless $outfh;

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

    # If a comment was supplied, include it in the output.
    if (defined $comment) {
      print $outfh "\n$comment\n";
    }

    close $outfh;

    $self->_get_mailfile($data->{'list'}, $data->{'victim'}, 
                         'fulfill', $tmp, %file)
      if ($data->{'victim'});

    unlink $tmp;
  }
  else {
    # determine whether or not the victim was notified.
    if ($self->{'lists'}{$data->{'list'}}->should_ack(
         $data->{'auxlist'}, $vict, 'f')) {
      $data->{'ack'} = 1;
    }
  }

  return (1, '', $data, [@out]);
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
  return (0, "Token $token is unavailable.\n")
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

      ($reasons = $args{'reasons'}) =~ s/\002/\n  /g;

      # Generate replacement hash
      $repl = {
               $self->standard_subs($data->{'list'}),
               TOKEN      => $token,
               URL        => $url,
               EXPIRE     => $expire,
               REQUESTER  => $data->{'user'},
               REQUESTOR  => $data->{'user'},
               VICTIM     => $data->{'victim'},
               APPROVALS  => $data->{'approvals'},
               CMDLINE    => $data->{'cmdline'},
               COMMAND    => $data->{'command'},
               REASONS    => $reasons,
               SESSIONID  => $data->{'sessionid'},
               ARG1       => $data->{'arg1'},
               ARG2       => $data->{'arg2'},
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
         -From       => $sender,
         -Subject    => $desc,
         'Content-Language:' => $file{'language'},
        );

      next unless $ent;

      for $i ($self->_global_config_get('message_headers')) {
        $i = $self->substitute_vars_string($i, $repl);
        $ent->head->add(undef, $i);
      }
      
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

    if (!$data->{'permanent'} && $time > $data->{'expire'} 
        && $data->{'type'} ne 'delay') {
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
  $self->_make_latchkeydb;
  $self->{'latchkeydb'}->mogrify($mogrify);

  return @kill;
}

=head2 t_fulfill

Expire "delay" tokens, completing their requests

=cut
sub t_fulfill {
  my $self = shift;
  my $log  = new Log::In 60;
  my $time = time;
  my (@waiting, $key, $data);

  my $extract = sub {
    my $key  = shift;
    my $data = shift;

    if (!$data->{'permanent'} && $time > $data->{'expire'} 
        && $data->{'type'} eq 'delay') {
      push @waiting, ($key, $data);
    }
    return (0, 0);
  };
  
  return unless $self->_make_tokendb;
  $self->{'tokendb'}->mogrify($extract);

  return @waiting;
}

=head2 _make_tokendb, _make_latchkeydb private

These subroutines generate and initialize the token and latchkey databases.

=cut
sub _make_tokendb {
  my $self = shift;
  
  unless ($self->{'tokendb'}) {
    $self->{'tokendb'} =
      new Mj::TokenDB "$self->{'ldir'}/GLOBAL/_tokens", $self->{backend};
  }
  1;
}

sub _make_latchkeydb {
  my $self = shift;
  
  unless ($self->{'latchkeydb'}) {
    $self->{'latchkeydb'} =
      new Mj::TokenDB "$self->{'ldir'}/GLOBAL/_latchkeys", $self->{backend};
  }
  1;
}

=head2 gen_latchkey(passwd)

Create a temporary password for improved security.

=cut

sub gen_latchkey {
  my ($self, $password) = @_;
  my ($duration, $token);

  $self->_make_latchkeydb;
  return unless defined $self->{'latchkeydb'};
  return unless length $password;
  $duration = $self->_global_config_get('latchkey_lifetime');
  $duration ||= 60;
  return unless ($duration > 0);

  $data = {
     'type'       => 'latchkey',
     'list'       => '',
     'command'    => '',
     'user'       => $self->{'sessionuser'},
     'victim'     => '',
     'mode'       => '',
     'cmdline'    => '',
     'approvals'  => '',
     'chain1'     => '',
     'chain2'     => '',
     'chain3'     => '',
     'chain4'     => '',
     'arg1'       => $password,
     'arg2'       => '',
     'arg3'       => '',
     'expire'     => time + $duration * 60,
     'remind'     => '',
     'reminded'   => 1,
     'permanent'  => '',
     'time'       => time,
     'sessionid'  => $self->{'sessionid'},
  };
  while (1) {
    $token = $self->t_gen;
    ($ok, undef) = $self->{'latchkeydb'}->add("",$token,$data);
    last if $ok;
  }
  return $token;
}

=head2 validate_latchkey(user, passwd, list, command)

Check the validity of a password to which a latchkey refers.

=cut
sub validate_latchkey {
  my ($self, $user, $passwd, $list, $command) = @_;
  my ($data, $realpass);
  $self->_make_latchkeydb;
  if (defined $self->{'latchkeydb'}) {
    $data = $self->{'latchkeydb'}->lookup($passwd);
    if (defined $data) {
        return if (time > $data->{'expire'});
        $realpass = $data->{'arg1'};
        return $self->validate_passwd($user, $realpass, $list, $command);
    }
  }
  0;
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

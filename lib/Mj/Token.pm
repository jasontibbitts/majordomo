=head1 NAME

Token.pm - confirmation token functions for Majordomo

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


=head2 confirm(args)

This adds a token to the database and mails out a message to the 
moderators, requester, or victim.

Moderator addresses can be taken from auxiliary lists, from the
moderators configuration setting, or from the moderator configuration
setting.

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

=cut
use MIME::Entity;
use Mj::Util qw(condense);
sub confirm {
  my ($self, %args) = @_;
  my $log  = new Log::In 50, "$args{'chain'}, $args{'expire'}";
  my (%file, @headers, @notify, @remind, @recip, @tmp, $approvals, $curl,
      $data, $desc, $dest, $ent, $envext, $expire, $expire_days, $file,
      $hdr, $i, $j, $list, $mj_addr, $mj_owner, $owner, $permanent,
      $realtoken, $reasons, $recip, $remind, $remind_days, $reminded,
      $repl, $rd, $sender, $tmp, $tmpf, $token, $ttype, $url);

  $log->abort("confirm called with no notify structures.\n")
    unless (exists $args{'notify'} and 
            ref($args{'notify'}) eq 'ARRAY' and
            scalar(@{$args{'notify'}}) >= 1);

  $list = $args{'list'};
  $list = 'GLOBAL' if ($list eq 'ALL');

  return unless $self->_make_tokendb;
  $args{'command'} =~ s/_(start|chunk|done)$//;

  $permanent = 0;
  if (exists $args{'expire'} and $args{'expire'} >= 0) {
    $expire = $args{'expire'};
    $expire_days = int(($expire + 43200) / 86400);
    $expire += time;
  }
  else {
    $expire_days = $self->_list_config_get($list, "token_lifetime");
    $expire_days = 0 unless (defined($expire_days) and $expire_days > 0);
    $expire = time + 86400 * $expire_days;
  }

  if (exists($args{'chain'}) and $args{'chain'} == 1) {
    @notify = ($args{'notify'}->[0]);
    @tmp = sort keys %Mj::Util::notify_var;
    for ($i = 1; $i < scalar(@{$args{'notify'}}) && $i < 5 ; $i++) {
      $args{"chain$i"} = condense($args{'notify'}->[$i], \@tmp);
    }
    for ( ; $i < 5 ; $i++) {
      $args{"chain$i"} ||= '';
    }
  }
  else {
    @notify = @{$args{'notify'}};
    for ($i = 1; $i < 5 ; $i++) {
      $args{"chain$i"} ||= '';
    }
  }

  $approvals = 0;
  $ttype = 'confirm';
  @remind = ();
  $rd = $self->_list_config_get($list, "token_remind") || 0;

  for $i (@notify) {
    # use Data::Dumper; $log->message(3, 'debug', Dumper $i);
    $approvals += $i->{'approvals'} 
      if (exists($i->{'approvals'}) and $i->{'approvals'} > 0);
    if ($i->{'fulfill'} == 1) {
      $ttype = 'delay';
    }
    elsif (($i->{'group'} !~ /^(victim|requester)$/) and $ttype eq 'confirm') {
      $ttype = 'consult';
    }
    elsif (exists $i->{'bounce'} && $i->{'bounce'} == -1) {
      $ttype = 'probe';
    }

    if (exists $i->{'remind'} and $i->{'remind'} >= 0) {
      $remind = $i->{'remind'};
      $reminded = 1 if ($remind == 0);
      $remind_days = int(($remind + 43200) / 86400);
      $remind += time;
    }
    else {
      if (defined($rd) and $rd > 0) {
        $remind_days = $rd;
        $remind = time + 86400 * $remind_days;
        $reminded = 0;
      }
      else {
        $remind_days = $expire_days;
        $remind = 0;
        $reminded = 1;
      }
    }

    if ($remind > $expire) {
      $remind_days = $expire_days;
      $remind = 0;
      $reminded = 1;
    }
    push @remind, [$remind, $reminded, $remind_days];
  }
 
  # Initialize variables and make substitutions.
  ($reasons = $args{'reasons'}) =~ s/\002/\n  /g;
  $sender   = $self->_list_config_get($list, 'sender');
  $owner    = $self->_list_config_get($list, 'whoami_owner');
  $mj_addr  = $self->_global_config_get('whoami');
  $mj_owner = $self->_global_config_get('sender');
  $curl = $self->_global_config_get('confirm_url');
  @headers = $self->_global_config_get('message_headers');

  # Make a token and add it to the database
  $realtoken = 
    $self->t_add($ttype, $args{'list'}, $args{'command'}, $args{'user'}, 
                 $args{'victim'}, $args{'mode'}, $args{'cmdline'}, 
                 $approvals, $args{'chain1'}, $args{'chain2'}, $args{'chain3'},
                 $args{'chain4'}, $args{'arg1'}, $args{'arg2'}, $args{'arg3'}, 
                 $expire, $remind[0]->[0], $remind[0]->[1], 
                 $permanent, $args{'reasons'});

  $url = $self->substitute_vars_string($curl,
        			       {'TOKEN' => $realtoken,},
        			      );

  $repl = {
           $self->standard_subs($list),
           'TOKEN'      => $realtoken,
           'URL'        => $url,
           'EXPIRE'     => $expire_days,
           'FULFILL'    => scalar localtime($expire),
           'REMIND'     => $remind[0]->[2],
           'REQUESTER'  => $args{'user'},
           'REQUESTOR'  => $args{'user'},
           'VICTIM'     => $args{'victim'},
           'APPROVALS'  => $approvals,
           'CMDLINE'    => $args{'cmdline'},
           'COMMAND'    => $args{'command'},
           'SESSIONID'  => $self->{'sessionid'},
           'ARG1'       => $args{'arg1'},
           'ARG2'       => $args{'arg2'},
	   'REASONS'    => $reasons,
           'ARG3'       => $args{'arg3'},
          };
   
  # Determine which of the notify structures actually receives a message
  for ($i = 0; $i < scalar @notify; $i++) {
    $dest = $notify[$i];
    if ($dest->{'group'} eq 'victim') {
      $repl->{'NOTIFY'} = "$args{'victim'}";
    }
    elsif ($dest->{'group'} eq 'requester') {
      $repl->{'NOTIFY'} = "$args{'user'}";
    }
    else {
      $repl->{'NOTIFY'} = 'the moderators';
    }
    @recip = ();
    $recip = '';
    # Determine the destination address(es).  If the group is "none,"
    # no notice is sent.
    if ($dest->{'group'} eq 'none') {
      @recip = ([]);
    }
    elsif ($dest->{'group'} eq 'requester') {
      @recip = (["$args{'user'}"]);
      $recip = "$args{'user'}";
    }
    elsif ($dest->{'group'} eq 'victim') {
      @recip = (["$args{'victim'}"]);
      $recip = "$args{'user'}";
    }
    else {
      @tmp = $self->get_moderators($args{'list'}, $dest->{'group'},
                                   $dest->{'pool'});

      if ($dest->{'approvals'} > 1) {
        for $j (@tmp) {
          push @recip, [$j];
        }
      }
      else {
        @recip = ([@tmp]);
      }
      $recip = $owner;
    }

    $repl->{'APPROVALS'} = $dest->{'approvals'};
    $repl->{'REMIND'} = $remind[$i]->[2];
    ($file, %file) = $self->_list_file_get($list, $dest->{'file'});

    for $j (@recip) {
      if ($dest->{'approvals'} > 1 or scalar(@notify) > 1) {
        $token = 
          $self->t_add('alias', $args{'list'}, $args{'command'}, $args{'user'}, 
                 $args{'victim'}, $args{'mode'}, $args{'cmdline'}, 
                 1, $realtoken, $dest->{'group'}, '',
                 '', $args{'arg1'}, $args{'arg2'}, $args{'arg3'}, 
                 $expire, $remind[$i]->[0], $remind[$i]->[1], 
                 $permanent, $args{'reasons'});
      }
      else {
        $token = $realtoken;
      }

      $repl->{'URL'} = 
        $self->substitute_vars_string($curl, {'TOKEN' => $token,});
      $repl->{'TOKEN'} = $token;

      # Determine if a notification should be sent.
      # It should not be sent for "delay" tokens if quiet mode is used.
      # Nor if the "none" group was specified.
      next if (($ttype eq 'delay' and $args{'mode'} =~ /quiet/) or
               (scalar(@$j) == 0));

      # Extract the file from storage
      $tmpf = $self->substitute_vars($file, $repl);
      $desc = $self->substitute_vars_string($file{'description'}, $repl);

      # Send it off
      $ent = build MIME::Entity
        (
         Path        => $tmpf,
         Type        => $file{'c_type'},
         Charset     => $file{'charset'},
         Encoding    => $file{'c_t_encoding'},
         Filename    => undef,
                        # Note explicit stringification
                        # victim's address, requester's address, sender.
         -To         => $recip, 
         -From       => $sender,
         -Subject    => $desc,
         'Content-Language:' => $file{'language'},
        );

      next unless $ent;

      for $hdr (@headers) {
        $hdr = $self->substitute_vars_string($hdr, $repl);
        $ent->head->add(undef, $hdr);
      }

      # Attach the message file if necessary.
      if ($dest->{'attach'}) {
	$dest->{attach} = {} if ref($dest->{attach}) ne 'HASH';
	$ent->make_multipart;
        $ent->attach(Type        => $dest->{attach}{type} || 'message/rfc822',
                     Description => $dest->{attach}{desc} || 'Original message',
                     Path        => $dest->{attach}{file} || $args{'arg1'},
                     Filename    => undef,
                    );
      }

      # Determine whether or not a bounce of the token would result
      # in the token being deleted.
      if (exists($dest->{'bounce'}) and $dest->{'bounce'} == -1) {
      	$envext = 'P';
      }
      elsif (exists($dest->{'bounce'}) and $dest->{'bounce'} == 0) {
        $envext = 'D';
      }
      else {
        $envext = 'T';
      }

      $self->mail_entity({addr => $mj_owner,
                          type => $envext,
                          data => $token,
                         },
                         $ent,
                         @$j
                        );

      unlink $tmpf;
      # Do not purge the entity.  It might delete the spool file
      # if a posted message is attached to the notice.
      # $ent->purge;
    }
  }
  $realtoken;
}

=head2 get_moderators(list, moderator_group, pool_size)

Obtain the e-mail addresses of one or more list moderators.
If the moderator group is specified, the addresses will be taken
from the auxiliary list of the same name.  If the pool size
is greater than zero, a subset of the moderator group will be
chosen randomly.

=cut
sub get_moderators {
  my $self  = shift;
  my $list  = shift;
  my $group = shift || 'moderators';
  my $size  = shift;

  my (@mod1, @mod2, $i);

  # This extracts a list of moderators.  If a moderator group
  # was specified, the addresses are taken from the auxiliary
  # list of the same name.  If no such list exists, the
  # "moderators" auxiliary list and the "moderators," "moderator,"
  # and "sender" configuration setting are each consulted
  # in turn until an address is found.
  return unless ($self->_make_list($list));
  @mod1  = $self->{'lists'}{$list}->moderators($group);

  # The number of moderators consulted can be limited to a
  # certain (positive) number, in which case moderators
  # are chosen randomly.
  unless (defined($size) and $size >= 0) {
    $size = $self->_list_config_get($list, 'moderator_group') || 0 ;
  }
  if (($size > 0) and (scalar @mod1 > $size)) {
    for ($i = 0; $i < $size && @mod1; $i++) {
      push(@mod2, splice(@mod1, rand @mod1, 1));
    }
    return @mod2;
  }
  else {
    return @mod1;
  }
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
use Mj::MIMEParser;
use Mj::Addr;
use Mj::File;
use Mj::Format;
use Mj::MailOut;
use Mj::Util qw(n_defaults reconstitute);
sub t_accept {
  my $self  = shift;
  my $token = shift;
  my $mode = shift;
  my $comment = shift;
  my $delay = shift;
  my $log   = new Log::In 50, $token;
  my (%file, @out, @tmp, $data, $ent, $ffunc, $func, $line, $mess, 
      $notify, $ok, $outfh, $repl, $req, $rf, $sender, $server, 
      $tmp, $tmpdir, $vict, $whoami);

  $self->_make_tokendb;
  $data = $self->{'tokendb'}->lookup($token);
  return (0, "Nonexistent token \"$token\"!\n") unless $data;

  # Tick off one approval
  $data->{'approvals'}--;

  # If a delay was requested, change the token type and return.
  if ($data->{'type'} eq 'consult' and defined($delay) and $delay > 0) {
    $data->{'expire'} = time + $delay;
    $data->{'type'} = 'delay';
    $data->{'reminded'} = 1;
    $self->{'tokendb'}->replace('', $token, $data);
    return (-1, sprintf "Request delayed until %s.\n", 
            scalar localtime ($data->{'expire'}), $data, [-1]);
  }
  
  if ($data->{'approvals'} > 0) {
    $self->{'tokendb'}->replace("", $token, $data);
    return (-1, "$data->{'approvals'} approvals are still required", 
            $data, [-1]);
  }
 
  # Deal with alias tokens:  remove the token and accept
  # the new token recursively.
  if ($data->{'type'} eq 'alias') {
    $self->t_remove($token);
    $token = $data->{'chain1'};
    return $self->t_accept($token, $mode, $comment, $delay);
  }
 
  # Allow "accept-archive" to store a message in the archive but
  # not distribute it on to a mailing list.  Note that this could
  # have interesting side effects, good and bad, if used in
  # other ways.
  if (defined $mode and $data->{'command'} =~ /^post/) {
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

    # New style
    if ($data->{'chain1'} =~ /\002/) {
      @tmp = sort keys %Mj::Util::notify_var;
      $tmp = reconstitute($data->{'chain1'}, \@tmp);
      $data->{'chain1'} = $data->{'chain2'};
      $data->{'chain2'} = $data->{'chain3'};
      $data->{'chain3'} = $data->{'chain4'};
      $data->{'chain4'} = '';
    }
    # Old style
    else {
      if ($data->{'chain2'} eq 'requester') {
        $tmp = n_defaults('confirm');
        $tmp->{'group'} = 'requester';
      }
      else {
        $tmp = n_defaults('consult');
      }

      if (defined($data->{'chain1'}) and length($data->{'chain1'})) {
        $tmp->{'file'} = $data->{'chain1'};
      }
      if (defined($data->{'chain2'}) and length($data->{'chain2'})) {
        $tmp->{'group'} = $data->{'chain2'};
      }
      if (defined($data->{'chain3'}) and length($data->{'chain3'})) {
        $tmp->{'approvals'} = $data->{'chain3'};
      }
      delete $data->{'chain1'};
      delete $data->{'chain2'};
      delete $data->{'chain3'};
      delete $data->{'chain4'};
      delete $data->{'remind'};
    }

    delete $data->{'expire'};
    delete $data->{'reminded'};

    # Which reply file should be sent?
    if ($tmp->{'group'} eq 'requester') {
      $rf = 'repl_confirm';
    }
    else {
      $rf = 'repl_chain';
    }

    $self->confirm(%$data, 
                   'chain'   => 1,
                   'notify'  => [$tmp],
                  );

    # XXX What if the confirm method fails?
    $self->t_remove($token);

    # Determine which file to send.  chain4 or repl_something
    # based upon notify->{'group'}.

    my ($file) = $self->_list_file_get($data->{'list'}, $rf);
    $file = $self->substitute_vars($file, $repl);
    my $fh = new Mj::File "$file"
      or $log->abort("Cannot read file $file, $!");
    while (defined ($line = $fh->getline)) {
      $mess .= $line;
    }
    $fh->close;
    unlink $file;
    return (-1, $mess, $data, [-1]);
  } # chain1 

  ($func = $data->{'command'}) =~ s/_(start|chunk|done)$//;

  $data->{'ack'} = 1;
  if ($func eq 'post') {
    # determine whether or not the victim was notified.
    $vict = new Mj::Addr($data->{'victim'});
    unless ($self->{'lists'}{$data->{'list'}}->should_ack(
         $data->{'sublist'}, $vict, 'f')) {
      $data->{'ack'} = 0;
    }
  }

  # Hack to cause deliveries to happen asynchronously:
  # an "accept" message is mailed to the server, with
  # the server address in the From header.  No reply will be
  # sent.
  if ($func eq 'post' and $data->{'type'} ne 'async'
      and $data->{'mode'} !~ /archive/) {

    my ($origtype) = $data->{'type'};
    $data->{'type'} = 'async';
    $data->{'reminded'} = 1;
    while (1) {
      $tmp = $self->t_gen;
      ($ok, undef) = $self->{'tokendb'}->add('', $tmp, $data);
      last if $ok;
    }
    $self->t_remove($token);

    $sender = $self->_global_config_get('sender');
    $server = $self->_global_config_get('whoami');
    $ent = build MIME::Entity
      (
       'Subject'  => "Forwarded approval from $server\n",
       'From'     => "$server\n",
       'Reply-To' => "$server\n",
       'Data'     => ["accept $tmp\n"],
      );

    $self->mail_entity($sender, $ent, $server) if ($server and $ent);

    $data->{'type'} = $origtype;
    return (1, '', $data, [1]);
  }
  else {
    $vict = new Mj::Addr($data->{'victim'}) unless (defined $vict);
    $req  = new Mj::Addr($data->{'user'});
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

  # Nuke the token
  $self->t_remove($token);

  # If we're accepting a confirm token, we can just return the results
  # so that they'll be formatted by the core accept routine.
  return (1, '', $data, \@out) 
    if ($data->{'type'} eq 'confirm' or $data->{'type'} eq 'async');

  # So we're accepting a consult or delay token. We need to give back some
  # useful info to the accept routine so the owner will know that the
  # accept worked, but we also need to generate a separate reply
  # message and send it to the user so that they get the results from
  # that command they submitted so long ago...  To do this, we create
  # a MIME entity and format the output of the command return into its
  # bodyhandle.  Then we send it.  Then we return some token info and
  # pretend we did a 'consult' (in $rreq) command so that the accept
  # routine will format it as we want for the reply to the owner.
  # Acknowledgements of posts take place in Mj::Resend::_post.
  if ($func ne '_post') {

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

  # If we are removing an alias token, find the real
  # token and eliminate it, too.
  if ($data->{'type'} eq 'alias') {
    $token = $data->{'chain1'};
    return $self->t_reject($token);
  }
  
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
  my (%file, @mod, @reminded, @tmp, $data, $desc, $ent, $expire, $file, $gurl, 
      $i, $mj_addr, $mj_owner, $reasons, $repl, $sender, $tmp, $token, $url);

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

    while (($token, $data) = splice(@tmp, 0, 2)) {
      # For alias tokens, remove the token unless the original exists.
      if ($data->{'type'} eq 'alias') {
        $tmp = $self->{'tokendb'}->lookup($data->{'chain1'});
        unless (defined $tmp) {
          $self->t_remove($token);
          next;
        }
      }
      # Extract the file from storage
      ($file, %file) = $self->_list_file_get($data->{'list'}, "token_remind");

      # Extract some list-specific variables
      $sender = $self->_list_config_get($data->{'list'}, 'sender');
      $url    = $self->substitute_vars_string($gurl,
        				      {'TOKEN' => $token,},
        				     );

      # Find number of days left until it dies
      $expire = int(($data->{'expire'}+43200-time)/86400);

      ($reasons = $data->{'reasons'}) =~ s/\002/\n  /g;

      # Generate replacement hash
      $repl = {
               $self->standard_subs($data->{'list'}),
               TOKEN      => $token,
               URL        => $url,
               EXPIRE     => $expire,
               FULFILL    => scalar localtime($data->{'expire'}),
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
      elsif ($data->{'type'} eq 'alias') {
        $ent->head->replace('To', $sender);
        if ($data->{'chain2'} eq 'none') {
          next;
        }
        elsif ($data->{'chain2'} eq 'victim') {
          @mod = ($data->{'victim'});
        }
        elsif ($data->{'chain2'} eq 'requester') {
          @mod = ($data->{'user'});
        }
        else {
          @mod = $self->get_moderators($data->{'list'}, $data->{'chain2'}, -1);
        }
        $self->mail_entity($mj_owner, $ent, @mod) if (scalar @mod);
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
use Mj::TokenDB;
sub _make_tokendb {
  my $self = shift;
  
  unless ($self->{'tokendb'}) {
    $self->{'tokendb'} =
      new Mj::TokenDB "$self->{'ldir'}/GLOBAL/_tokens", $self->{backend};
  }
  1;
}

use Mj::TokenDB;
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
use Mj::Util qw(ep_convert);
sub gen_latchkey {
  my ($self, $password) = @_;
  my ($data, $duration, $ok, $token);

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
     'arg1'       => ep_convert($password),
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

=head2 del_latchkey(latchkey)

Removes a latchkey from the database.

=cut
sub del_latchkey {
  my $self = shift;
  my $lkey  = shift;
  my $log  = new Log::In 150, $lkey;

  return unless $lkey;

  $self->_make_latchkeydb;
  return unless defined $self->{'latchkeydb'};

  $self->{'latchkeydb'}->remove("", $lkey);
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

=head1 NAME

Mj::BounceHandler.pm - Functions for dealing with bounces

=head1 DESCRIPTION

A set of routines for dealing with bounces.  This includes calling the
bounce parser, dealing with the data returned, locating bouncing users and
removing them if necessary.

=head1 SYNOPSIS

blah

=cut

package Mj::BounceHandler;
use Mj::Log;
use Symbol;
use AutoLoader 'AUTOLOAD';

$VERSION = "0.0";
use strict;
#use vars qw(%args %memberof $skip);

1;
__END__

=head2 handle_bounce

Look for and deal with bounces in an entity.  All of the bounce processing
machinery is rooted here.

The given file is parsed into a MIME entity

=cut
use Mj::MIMEParser;
use Mj::BounceParser;
sub handle_bounce {
  my ($self, $list, $file) = @_;
  my $log  = new Log::In 30, "$list";
  my ($addrs, $data, $ent, $fh, $handled, $handler, $msgno, $parser,
      $source, $type, $user, $whoami);

  $parser = new Mj::MIMEParser;
  $parser->output_dir($self->_global_config_get('tmpdir'));
  $parser->output_prefix("mjo");

  $fh = gensym();
  open ($fh, "< $file");
  $ent = $parser->read($fh);
  close $fh;

  # Extract information from the envelope, if any, and parse the bounce.
  $whoami = $self->_global_config_get('whoami');
  $whoami =~ s/\@.*$//;
  $source = 'unknown@anonymous';
  $addrs  = [];

  if (defined $ent) {
    chomp($source = $ent->head->get('from') ||
          $ent->head->get('apparently-from') || 'unknown@anonymous');

    ($type, $msgno, $user, $handler, $data) =
      Mj::BounceParser::parse($ent,
			      $list eq 'GLOBAL'?$whoami:$list,
			      $self->_site_config_get('mta_separator')
			     );

    # If we know we have a message
    if ($type eq 'M') {
      $handled = 1;
      $addrs =
	$self->handle_bounce_message(data    => $data,
				     entity  => $ent,
				     file    => $file,
				     handler => $handler,
				     list    => $list,
				     msgno   => $msgno,
				     type    => $type,
				     user    => $user,
				    );
    }

    # If a token bounced
    elsif ($type eq 'T' or $type eq 'D') {
      $handled = 1;
      $self->handle_bounce_token(entity  => $ent,
                                 data    => $data,
                                 file    => $file,
                                 handler => $handler,
                                 token   => $msgno,
                                 type    => $type,
                                );
      $addrs = [$msgno];
    }

    # If a probe bounced
    elsif ($type eq 'P') {
      $handled = 1;
      $self->handle_bounce_probe(entity  => $ent,
				 data    => $data,
				 file    => $file,
				 handler => $handler,
				 token   => $msgno,
                                 type    => $type,
				);
      $addrs = [$msgno];
    }

    # We couldn't parse anything useful
    else {
      $handled = 0;
    }
  }

  $ent->purge if $ent;

  # Tell the caller whether or not we handled the bounce
  ($handled, $type, $source, $addrs);
}

=head2 handle_bounce_message

Deal with a bouncing message.  This involves figuring out what address is
bouncing and if it's on the list, then running the bounce_rules code to
figure out what to do about it.

=cut
sub handle_bounce_message {
  my($self, %args) = @_;
  my $log  = new Log::In 35;
  my (@bouncers, @owners, $diag, $from, $i, $lsender, $mess, $nent, $sender,
      $status, $subj, $tmp);

  my $data = $args{data};
  my $list = $args{list};
  my $user = $args{user};
  my $addrs= [];

  # Dump the body to the session file
  $args{entity}->print_body($self->{sessionfh});

  $mess  = "Detected a bounce of message #$args{msgno}, list $list.\n";
  $mess .= "  (bounce type $args{handler})\n\n";

  @owners   = @{$self->_list_config_get($list, 'owners')};
  @bouncers = @{$self->_list_config_get($list, 'bounce_recipients')};
  @bouncers = @owners unless @bouncers;
  if ($list eq 'GLOBAL') {
    $sender = $owners[0];
    $from = $self->_list_config_get('GLOBAL', 'sender');
  }
  else {
    $from = $sender = $self->_list_config_get('GLOBAL', 'sender');
  }
  $lsender  = $self->_list_config_get($list, 'sender');

  # If we have an address or subscriber ID from the envelope, we can only
  # have one and we know it's correct.  First we have to get from that to
  # the actual user email address.  Parsing may have been able to extract a
  # status and diagnostic, so grab them then overwrite the data hash with a
  # new one containing just that user.  The idea is to ignore any addresses
  # that parsing extracted but aren't relevant.
  if ($user) {

    # Get back to the real email address; loop up subscriber ID if we have
    # one.

    if ($data->{$user}) {
      $status = $data->{$user}{status};
      $diag   = $data->{$user}{diag} || 'unknown';
    }
    else {
      my ($other) = keys %$data;
      if (defined($other)) {
        $status = $data->{$other}{status};
        $diag   = $data->{$other}{diag} || 'unknown';
        $diag   = $other . ' : ' . $diag;
      } else {
       $status = 'failure';
       $diag   = 'unknown';
      }
    }
    $data = {$user => {status => $status, diag => $diag}};
  }

  # Now plow through the data from the parsers
  for $i (keys %$data) {
    push @$addrs, $i;
    $tmp = $self->handle_bounce_user(%args,
				     user   => $i,
				     sender => $sender,
				     %{$data->{$i}},
				    );

    # If we got something back, we need to inform the owners
    if (defined($tmp)) {
      # XXX tmp is a hashref in some situations.
      $mess .= "$tmp\n";

      if ($subj) {
	$subj .= ", $i";
      }
      else {
	$subj  = "Bounce detected (list $list) from $i";
      }
    }
  }

  # We can bail if we have nothing to inform the owner of
  return $addrs unless (defined $subj);

  # Build a new message which includes the explanation from the bounce
  # parser and attach the original message.
  $subj ||= 'Bounce detected';
  $nent = build MIME::Entity
    (
     Encoding => '8bit',
     Data     => [ $mess,
		   "The bounce message is attached below.\n\n",
		 ],
     -Subject => $subj,
     -To      => $lsender,
     -From    => $from,
    );
  $nent->attach(Type        => 'message/rfc822',
		Encoding    => '8bit',
		Description => 'Original message',
		Path        => $args{file},
		Filename    => undef,
	       );
  $self->mail_entity($sender, $nent, @bouncers);

  $nent->purge if $nent;
  $addrs;
}

=head2 handle_bounce_probe

Deal with a bouncing probe.  If the owner is to be consulted, generate a
consult token.  Otherwise, just remove the user directly.

=cut
sub handle_bounce_probe {
  my($self, %args) = @_;
  my $log = new Log::In 35;
  my (@bouncers, @owners, $data, $ok, $user);

  # Grab the data for the token
  ($ok, $data) = $self->t_info($args{token});

  # Simply return if it doesn't exist.  XXX This should be an error
  # condition, and someone should be notified.
  return 1 if !$ok || !$data;

  $self->t_remove($args{token});

  $user = new Mj::Addr $data->{victim};

  # Should the owners be consulted?
  if ($data->{mode} && $data->{mode} !~ /noconsult/ &&
      $data->{mode} =~ /consult/)
    {
      $self->_hbr_consult(%args,
			  user   => $user,
			  list   => $data->{list},
			 );
      return;
    }

  # Otherwise, just remove the user
  $self->_hbr_noprobe(%args,
		      user   => $user,
		      list   => $data->{list},
		      sender => $self->_list_config_get('GLOBAL', 'sender'),
		      reason => qq(The bounce_rules setting says "remove" and a probe message was bounced.),
		     );
}

=head2 handle_bounce_token

Deal with a bouncing token.  This involves simply deleting the token, since
it didn't get where it was going.

=cut
sub handle_bounce_token {
  my($self, %args) = @_;
  my $log  = new Log::In 35;
  my(%file, @owners, @bouncers, $data, $del, $desc, $dest, $ent, $file, $from, 
     $i, $inform, $ok, $reasons, $sender, $subs, $time);

  # Dump the body to the session file
  $args{entity}->print_body($self->{sessionfh});

  # If we parsed out a failure, delete the token
  # unless it is for a delayed action.
  $del = '';
  $reasons = '';
  for $i (keys %{$args{'data'}}) {
    last if $args{'type'} eq 'D';
    if ($args{'data'}{$i}{'diag'}) {
      $reasons .= $args{'data'}{$i}{'diag'} . "\n";
    }
    if ($args{'data'}{$i}{'status'} eq 'failure') {
      $time = $::log->elapsed;
      ($ok, $data) = $self->t_reject($args{token});
      $del = 'The token has been deleted.' if ($ok);
      $self->inform('GLOBAL', 'reject',
		qq("Automatic Bounce Processor" <$args{'sender'}>),
		$data->{'victim'}, "reject $args{'token'}",
		$self->{'interface'}, $ok, 0, 0, 
		qq(A confirmation message could not be delivered.),
		$::log->elapsed - $time) 
        if (defined $data and exists $data->{'victim'});
      last;
    }
  }

  unless ($del) {
    ($ok, $data) = $self->t_info($args{'token'});
  }

  return 1 unless ($ok and ref ($data) eq 'HASH');
  $data->{'list'} ||= 'GLOBAL';

  unless (($i) = $self->_make_list($data->{'list'})) {
    return 1;
  }

  @owners = @{$self->_list_config_get($data->{'list'}, 'owners')};
  $inform = $self->_list_config_get($data->{'list'}, 'inform');
  $i = $inform->{'tokenbounce'}{'all'} || $inform->{'tokenbounce'}{1} || 0;
  $i &= 2;
  if ($i) {
    @bouncers = @{$self->_list_config_get($data->{'list'}, 'bounce_recipients')};
    @bouncers = @owners unless @bouncers;
  }
  $sender = $owners[0];
  $from = $self->_list_config_get($data->{'list'}, 'whoami_owner');
  $dest = $from;
  
  # send a notice to the requester if the requester and victim
  # addresses are different.
  if (defined($data) and length($del) and $data->{'user'}
      ne $data->{'victim'} and $data->{'type'} eq 'confirm') 
  {
     $dest = $data->{'user'};
     push @bouncers, $data->{'user'};
  }

  return 1 unless (scalar @bouncers);

  # XXX If the token was sent to some destination other than
  # the victim, the bounce notice may indicate the wrong destination.
  $subs = {
           $self->standard_subs($data->{'list'}),
           'CMDLINE'    => $data->{'cmdline'},
           'COMMAND'    => $data->{'command'},
           'DATE'       => scalar localtime ($data->{'time'}),
           'DELETED'    => $del,
           'HANDLER'    => $args{'handler'},
           'REASONS'    => $reasons || '(reasons unknown)',
           'REQUESTER'  => $data->{'user'},
           'SESSIONID'  => $data->{'sessionid'},
           'TOKEN'      => $args{'token'},
           'VICTIM'     => $data->{'victim'},
          };

  ($file, %file) = $self->_list_file_get(list => $data->{'list'},
					 file => 'token_bounce',
					);
  return 1 unless $file;

  # Expand variables
  $desc = $self->substitute_vars_string($file{'description'}, $subs);
  $file = $self->substitute_vars($file, $subs);

  # Build a new message which includes the explanation from the bounce
  # parser and attach the original message.
  $ent = build MIME::Entity
    (
     Path     => $file,
     Type     => $file{'c-type'},
     Charset  => $file{'charset'},
     Encoding => $file{'c-t-encoding'},
     Subject  => $desc,
     -To      => $dest,
     -From    => $from,
     Top      => 1,
     Filename => undef,
     'Content-Language:' => $file{'language'},
    );

  $ent->attach(Type        => 'message/rfc822',
               Encoding    => '8bit',
               Description => 'Original message',
               Path        => $args{file},
               Filename    => undef,
              );

  if ($ent and $sender) {
    $self->mail_entity($sender, $ent, @bouncers);
  }

  $ent->purge if $ent;
  1;
}

=head2 handle_bounce_user

Does the bounce processing for a single user.  This involves:

*) adding new bounce data

*) generating statistics

*) deciding what action (if any) to take

*) logging the bounce

*) return an explanation message block to the caller

=cut
use Mj::CommandProps 'action_terminal';
use Mj::Util 'process_rule';
sub handle_bounce_user {
  my $self   = shift;
  my %params = @_; # Can't use %args, because the access code uses it.
  my $log  = new Log::In 35;

  my (%args, %memberof, @final_actions, $arg, $bdata, $func, $i, 
      $mess, $rules, $sdata, $status, $tmp, $tmpa, $tmpl);

  my $user   = $params{user};
  my $list   = $params{list};
  my $parser = shift || 'unknown';

  $status = $params{status};

  $params{msgno} = '' if $params{msgno} eq 'unknown';

  # Make sure we understand what to do with this bounce
  if ($status ne 'warning' && $status ne 'failure') {
    return "  Unknown bounce type; can't handle.\n";
  }

  $user = new Mj::Addr($user);

  # No guarantees that an address pulled out of a bounce is valid
  return "  User:       (unknown)\n\n"       unless $user;
  return "  User:       $user (invalid)\n\n" unless $user->isvalid;

  # Process a bounce that came in on the GLOBAL list.  We don't do much;
  # bounce_rules doesn't apply and we don't record bounce data in the
  # registry.  Plus we'll never have nice numbered bounces anyway.  Thus
  # we output a little message and return.
  if ($list eq 'GLOBAL') {
    $mess .= "  User:        $user\n";
    $mess .= "  Status:      $params{status}\n";
    $mess .= "  Diagnostic:  $params{diag}\n";
    return $mess;
  }

  $sdata = $self->{lists}{$list}->is_subscriber($user);

  # For warnings, we don't actually want to add any data but we will want
  # to generate statistics
  if ($params{status} eq 'warning') {
    $bdata = $self->{lists}{$list}->bounce_get($user);
  }
  else {
    $bdata = $self->{lists}{$list}->bounce_add
      (addr   => $user,
       subbed => !!$sdata,
       time   => time,
       type   => $params{type},
       evdata => $params{msgno},
       diag   => $params{diag},
      );
  }

  %args = %{$self->{lists}{$list}->bounce_gen_stats($bdata)};

  # Get ready to run the bounce rules
  $rules = $self->_list_config_get($list, 'bounce_rules');

  # Fill in the memberof hash as necessary
  for $i (keys %{$rules->{check_aux}}) {
    # Handle list: and list:auxlist syntaxes; if the list doesn't
    # exist, just skip the entry entirely.
    if ($i =~ /(.+):(.*)/) {
      ($tmpl, $tmpa) = ($1, $2);
      next unless $self->_make_list($tmpl);
    }
    else {
      ($tmpl, $tmpa) = ($list, $i);
    }
    $memberof{$i} = $self->{'lists'}{$tmpl}->is_subscriber($user, $tmpa);
  }

  # Add in extra arguments
  $args{warning}              = ($params{status} eq 'warning');
  $args{failure}              = ($params{status} eq 'failure');
  $args{diagnostic}           = $params{diag};
  $args{subscribed}           = !!$sdata;
  $args{days_since_subscribe} = $sdata? ((time - $sdata->{subtime})/86400): 0;
  $args{notify}               = [];

  $args{'addr'}     = $user->strip || '';
  $args{'fulladdr'} = $user->full || '';
  if ($args{'addr'} =~ /.*\@(.*)$/) {
    $args{'host'}   = $1;
  }
  else {
    $args{'host'}   = '';
  }

  # Now run the rule
  @final_actions =
    process_rule(name     => 'bounce_rules',
		 request  => '_bounce',
		 code     => $rules->{code},
		 args     => \%args,
		 memberof => \%memberof,
		);

  # Now figure out what to do
  for $i (@final_actions) {
    ($func, $arg) = split(/[-=]/,$i,2);
    $arg ||= '';

    # ignore -> do nothing
    next if $func eq 'ignore';

    # Do we need to inform the owner?  inform does, and everything else
    # does unless given an argument of 'quiet'.
    if ($func eq 'inform' || $arg !~ /quiet/) {
      $mess = _gen_bounce_message($user, \%args, \%params, \@final_actions);
    }

    # If we're only informing, we're done
    next if $func eq 'inform';

    # The only thing left is remove
    if ($func ne 'remove') {
      warn "Running bounce_rules: don't know how to $func";
      next;
    }

    # Remove user if necessary
    $tmp = $self->handle_bounce_removal(%params,
					mode   => $arg,
					notify => $args{notify},
					subbed => !!$sdata,
					user   => $user,
				       );
    $mess .= $tmp if $tmp;
  }

  $mess;
}

=head2 handle_bounce_removal

Deal with the particulars of removing a bouncing user.

There are several possibilities:

1) Remove the user immediately.

2) Send the owner(s) a consultation token; when accepted, the user is
   removed.

3) Generate a bounce probe; if it bounces, remove the user.

4) #3, but consult the owner before removing.

=cut
sub handle_bounce_removal {
  my $self = shift;
  my %args = @_;
  my $log = new Log::In 50;
  my ($time) = $::log->elapsed;
  my ($mess, $ok);

  if (!$args{subbed}) {
    return "  Cannot remove addresses which are not subscribed.\n";
  }

  my $consult = 0;
  my $probe   = 1;

  $probe = 0   if $args{mode} =~ /noprobe/;
  $consult = 1 if $args{mode} =~ /consult/;

  # warn "$probe, $consult";

  # Direct removal, no token involved
  if (!$probe && !$consult) {
    return $self->_hbr_noprobe(%args);
  }

  # Generate a simple consult token
  if (!$probe && $consult) {
    return $self->_hbr_consult(%args);
  }

  # We are probing
  return $self->_hbr_probe(%args);
}

=head2 _hbr_noprobe

Directly remove a bouncing user, no consultation, no probing.

=cut
use Mj::Util qw(shell_hook);
sub _hbr_noprobe {
  my $self = shift;
  my %args = @_;
  my $log = new Log::In 100;
  my ($mess, $ok, $time);
  $time = $::log->elapsed;

  ($ok, $mess) =
    $self->_unsubscribe($args{list},
			"$args{sender} (Automatic Bounce Processor)",
			$args{user},
			'',
			'automatic removal',
			'MAIN',
		       );
  $self->inform($args{list}, 'unsubscribe',
		qq("Automatic Bounce Processor" <$args{'sender'}>),
		$args{'user'}, "unsubscribe $args{'list'} $args{'user'}",
		$self->{'interface'}, $ok, 0, 0, 
		$args{reason} || qq(The bounce_rules setting says "remove-noprobe"),
		$::log->elapsed - $time);

  shell_hook('bouncehandler-unsubscribe');

  if ($ok) {
    return "  User was removed.\n";
  }
  return "  User could not be removed: $mess\n";
}

=head2 _hbr_consult

Send a consultation token to the owners; if accepted, the address is
removed.

We also note that we have consulted the owner about this address, and if we
see that we have already done so, we return without doing anything.  We
don't care if we have sent a probe, because the probe may have been lost
somewhere or may have made it through.  This enables probing at a normnal
threshold and consultation at a higher threshold, so that the owner only
gets bothered if automatic handling doesn't take care of the bounce.

=cut
use Mj::Token;
use Mj::Util qw(n_build n_defaults);
sub _hbr_consult {
  my $self = shift;
  my %args = @_;
  my $log = new Log::In 100;
  my ($bdata, $defaults, $notify, $token);

  # Check that a type 'C' bounce event does not exist for this address
  $self->_make_list($args{list});
  $bdata = $self->{lists}{$args{list}}->bounce_get($args{user});
  return if $bdata->{'C'};

  $defaults = n_defaults('consult', 'unsubscribe');
  $notify = n_build($args{notify}, $defaults);
  $notify->[0]{attach} = {file => $args{file}} if $notify->[0]{attach};
  # XXX Should replace $notify->[0]{file} as well.

  $token =
    $self->confirm(
		   command  => 'unsubscribe',
		   list     => $args{list},
		   victim   => $args{user},
		   user     => ($self->_list_config_get($args{list}, 'sender') .
				" (automatic bounce processor)"),
		   mode     => '',
		   cmdline  => "unsubscribe $args{list} $args{user}",
		   notify   => $notify,
		   chain    => 0,
		   expire   => -1,
		   arg1     => 'MAIN',
		   #XXX Include some info from statistics
		   reasons  => 'Address has bounced too many messages.',
		  );

  # Now add a type C bounce event
  $self->{lists}{$args{list}}->bounce_add
    (addr   => $args{user},
     subbed => 1,
     time   => time,
     type   => 'C',
     evdata => $token,
    );
}

=head2 _hbr_probe

Send a bounce probe token to the bouncing address.  If it bounces, the
address is removed (possibly after consultation).

We also note that we have probed the address so that we do not continuously
probe.  Also, we do not probe if a consultation token has been sent
already.

=cut
use Mj::Token;
use Mj::Util qw(n_build n_defaults);
sub _hbr_probe {
  my $self = shift;
  my %args = @_;
  my $log = new Log::In 100;
  my (%tokenargs, $bdata, $defaults, $notify, $token);

  # Check that no type 'P' or type 'C' bounce event exists for this address
  $bdata = $self->{lists}{$args{list}}->bounce_get($args{user});
  return if $bdata->{'C'} || $bdata->{'P'};

  $defaults = n_defaults('probe', 'unsubscribe');
  $notify = n_build($args{notify}, $defaults);
  $notify->[0]{attach} = {file => $args{file}} if $notify->[0]{attach};

  # Now create the token
  $token =
    $self->confirm(
		   command  => 'unsubscribe',
		   list     => $args{list},
		   victim   => $args{user},
		   user     => $self->_list_config_get($args{list}, 'sender'),
		   mode     => $args{mode},
		   cmdline  => "bounceprobe for $args{user} on $args{list}",
		   chain    => 0,
		   expire   => -1,
		   notify   => $notify,
		   #XXX Include some info from statistics
		   reasons  => 'Address has bounced too many messages.',
		  );

  # And add a type P bounce event
  $self->{lists}{$args{list}}->bounce_add
    (addr   => $args{user},
     subbed => 1,
     time   => time,
     type   => 'P',
     evdata => $token,
    );
}

sub _gen_bounce_message {
  my ($user, $args, $params, $actions) = @_;
  my $acts = join ',', @$actions;
  my $mess = '';

  $mess .= "  User:        $user\n";
  $mess .= "  Subscribed:  " .($args->{subscribed}?'yes':'no')."\n";
  $mess .= "  Status:      $params->{status}\n";
  $mess .= "  Diagnostic:  $params->{diag}\n";

  $mess .= "  Bounce statistics for this user:\n";
  $mess .= "    Bounces last 24 hours:          $args->{day_overload}$args->{day}\n";
  $mess .= "    Bounces last 7 days:            $args->{week_overload}$args->{week}\n";
  $mess .= "    Bounces last 30 days:           $args->{month_overload}$args->{month}\n"
    if $args->{month};
  $mess .= "    Consecutive messages bounced:   $args->{consecutive}\n"
    if $args->{consecutive} && $args->{consecutive} > 3;
  $mess .= "    Percentage of messages bounced: $args->{bouncedpct}\n"
    if $args->{bouncedpct} && $args->{numbered} >= 5;

  $mess .= "  Bounce rules said: $acts.\n";

  $mess;
}


=head1 COPYRIGHT

Copyright (c) 2000, 2002 Jason Tibbitts for The Majordomo Development Group.  All
rights reserved.

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

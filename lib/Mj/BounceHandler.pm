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

$VERSION = "0.1";
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
  my $log = new Log::In 30, $list;
  my ($addrs, $data, $ent, $fh, $handled, $handler, $mess, $msgno, $ok, 
      $parser, $source, $type, $user, $whoami);

  # Extract information from the envelope, if any, and parse the bounce.
  $whoami = $self->_global_config_get('whoami');
  $whoami =~ s/\@.*$//;
  $handled = 0;
  $type = '';
  $source = 'unknown@anonymous';
  $addrs  = [];

  $parser = new Mj::MIMEParser;
  return ($handled, $type, $source, $addrs) unless (defined $parser); 
  $parser->output_dir($self->_global_config_get('tmpdir'));
  $parser->output_prefix("mjo");

  $fh = gensym();
  open ($fh, "< $file");
  unless (defined $fh) {
    $addrs = $self->format_error('no_file', $list, 'FILE' => $file);
    return ($handled, $type, $source, $addrs); 
  }

  $ent = $parser->read($fh);
  close $fh;
  unless (defined $ent) {
    $addrs = $self->format_error('unparsed_entity', $list);
    return ($handled, $type, $source, $addrs); 
  }

  chomp($source = $ent->head->get('from') ||
        $ent->head->get('apparently-from') || 'unknown@anonymous');

  ($type, $msgno, $user, $handler, $data) =
    Mj::BounceParser::parse($ent,
                            $list eq 'GLOBAL'?$whoami:$list,
                            $self->_site_config_get('mta_separator')
                           );

  # If we know we have a message
  if ($type eq 'M') {
    ($handled, $addrs) =
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
    ($handled, $mess) = 
      $self->handle_bounce_token(entity  => $ent,
                                 data    => $data,
                                 file    => $file,
                                 handler => $handler,
                                 token   => $msgno,
                                 type    => $type,
                                );
    $addrs = $handled ? $mess : [$msgno];
  }

  # If a probe bounced
  elsif ($type eq 'P') {
    ($handled, $mess) =
      $self->handle_bounce_probe(entity  => $ent,
                                 data    => $data,
                                 file    => $file,
                                 handler => $handler,
                                 token   => $msgno,
                                 type    => $type,
                                );
    $addrs = $handled ? $mess : [$msgno];
  }

  # We couldn't parse anything useful
  else {
  }

  $ent->purge;

  # Tell the caller whether or not we handled the bounce
  ($handled, $type, $source, $addrs);
}

=head2 handle_bounce_message

Deal with a bouncing message.  This involves figuring out what address is
bouncing and if it's on the list, then running the bounce_rules code to
figure out what to do about it.

=cut
sub handle_bounce_message {
  my ($self, %args) = @_;
  my $log  = new Log::In 35;
  my (%file, @userdata, @bouncers, @owners, $desc, $diag, $file, $from, 
      $i, $lsender, $mess, $nent, $ok, $other, $sender, $status, 
      $subs, $tmp);

  my $data = $args{data};
  my $list = $args{list};
  my $user = $args{user};
  my $addrs= [];

  # Dump the body to the session file
  $args{entity}->print_body($self->{sessionfh});

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
  $lsender = $self->_list_config_get($list, 'sender');

  # If we have an address or subscriber ID from the envelope, we can only
  # have one and we know it's correct.  First we have to get from that to
  # the actual user email address.  Parsing may have been able to extract a
  # status and diagnostic, so grab them then overwrite the data hash with a
  # new one containing just that user.  The idea is to ignore any addresses
  # that parsing extracted but aren't relevant.
  if (defined $user and length $user) {
    if (defined $data->{$user}) {
      $status = $data->{$user}{status};
      $diag   = $data->{$user}{diag} || 'unknown';
    }
    else {
      # Account for abbreviated local parts
      ($other) = grep /^$user/i, keys %$data;

      # Use the first address.
      ($other) = keys %$data unless (defined $other);

      if (defined($other)) {
        $user   = $other;
        $status = $data->{$other}{status};
        $diag   = $data->{$other}{diag} || 'unknown';
        $diag   = $other . ' : ' . $diag;
      } 
      else {
        $status = 'failure';
        $diag   = 'unknown';
      }
    }
    $data = {$user => {status => $status, diag => $diag}};
  }

  # Now plow through the data from the parsers
  for $i (keys %$data) {
    push @$addrs, $i;
    ($ok, $tmp) = $self->handle_bounce_user(%args,
                                            user   => $i,
                                            sender => $sender,
                                            %{$data->{$i}},
                                           );

    # If we got something back, we need to inform the owners
    if ($ok and ref $tmp eq 'HASH') {
      $subs = {  
               'VICTIM' => $i,
               'NONMEMBER' => $tmp->{'subscribed'} ? '' : " ",
               'STATUS' => $data->{$i}->{'status'},
               'DIAGNOSTIC' => $data->{$i}->{'diag'},
               'BOUNCES_DAY' => "$tmp->{'day_overload'}$tmp->{'day'}",
               'BOUNCES_WEEK' => "$tmp->{'week_overload'}$tmp->{'week'}",
               'BOUNCES_MONTH' => "$tmp->{'month_overload'}$tmp->{'month'}",
              };

      if (defined $tmp->{'consecutive'} and $tmp->{'consecutive'} > 3) {
        $subs->{'CONSECUTIVE'} = $tmp->{'consecutive'};
      }
      else {
        $subs->{'CONSECUTIVE'} = '';
      }

      if (defined $tmp->{'bouncedpct'} && $tmp->{'numbered'}
          && $tmp->{'numbered'} >= 5) {
        $subs->{'BOUNCE_PERCENT'} = $tmp->{'bouncedpct'};
      }
      else {
        $subs->{'BOUNCE_PERCENT'} = '';
      }

      if ($tmp->{'reasons'}) {
        $subs->{'REASONS'} = [ split ("\003", $tmp->{'reasons'}) ];
      }
      else {
        $subs->{'REASONS'} = '';
      }
        
      push @userdata, 
        $self->format_error('bounce_user', $list, %$subs);
    }
    elsif (!$ok) {
      push @userdata,
        $self->format_error('bounce_error', $list, 
                            'VICTIM' => $i,
                            'ERROR' => $tmp);
    }
  }

  # We can bail if we have nothing to inform the owner of
  return (1, $addrs) unless (scalar @userdata);

  $subs = {
           $self->standard_subs($list),
           'BOUNCE_DATA' => join ("\n", @userdata),
           'HANDLER'     => $args{'handler'},
           'SEQNO'       => $args{'msgno'},
           'VICTIM'      => join (", ", @$addrs),
          };

  ($file, %file) = $self->_list_file_get(list => $list,
					 file => 'bounce_detected',
					);

  unless ($file) {
    $mess = $self->format_error('no_file', $list,
                                'FILE' => 'bounce_detected');
    return (0, $mess);
  }

  # Expand variables
  $desc = $self->substitute_vars_string($file{'description'}, $subs);
  $file = $self->substitute_vars($file, $subs);

  # Build a new message which includes the explanation from the bounce
  # parser and attach the original message.
  $nent = build MIME::Entity
    (
     Encoding => '8bit',
     Path     => $file,
     Type     => $file{'c-type'},
     Charset  => $file{'charset'},
     Encoding => $file{'c-t-encoding'},
     'Content-Language:' => $file{'language'},
     -Subject => $desc,
     -To      => $lsender,
     -From    => $from,
     Top      => 1,
     Filename => undef,
    );

  if ($nent) {
    $nent->attach(Type        => 'message/rfc822',
                  Encoding    => '8bit',
                  Description => 'Original message',
                  Path        => $args{file},
                  Filename    => undef,
                 );

    $self->mail_entity($sender, $nent, @bouncers);

    $nent->purge;
  }
  else {
    return (0, $self->format_error('no_entity', $list));
  }

  (1, $addrs);
}

=head2 handle_bounce_probe

Deal with a bouncing probe.  If the owner is to be consulted, generate a
consult token.  Otherwise, just remove the user directly.

=cut
sub handle_bounce_probe {
  my ($self, %args) = @_;
  my $log = new Log::In 35;
  my (@bouncers, @owners, $data, $desc, $ok, $mess, $reasons, $tmp, $user);

  # Grab the data for the token
  ($ok, $data) = $self->t_info($args{token});

  # Simply return if it doesn't exist.
  return ($ok, $data) unless ($ok and defined($data));

  $self->t_remove($args{token});

  $user = new Mj::Addr $data->{victim};

  return (0, $self->format_error('undefined_address', $data->{'list'}))
    unless (defined $user);

  ($ok, $mess, $desc) = $user->valid;
  unless ($ok) {
    $tmp = $self->format_error($mess, 'GLOBAL');
    chomp $tmp if (defined $tmp);
    return (0, $self->format_error('invalid_address', $data->{'list'}, 
                                   'ADDRESS' => "$user", 'ERROR' => $tmp,
                                   'LOCATION' => $desc));
  }

  # Should the owners be consulted?
  if ($data->{mode} && $data->{mode} !~ /noconsult/ &&
      $data->{mode} =~ /consult/)
    {
      return $self->_hbr_consult(%args,
			         user   => $user,
			         list   => $data->{list},
			        );
    }

  # Otherwise, just remove the user
  $reasons = $self->format_error('probe_bounce', $data->{'list'}, 
                                 'VICTIM' => $user);
  return $self->_hbr_noprobe(
           %args,
	   'user'   => $user,
	   'list'   => $data->{list},
	   'sender' => $self->_list_config_get('GLOBAL', 'sender'),
	   'reasons'=> $reasons,
	 );
}

=head2 handle_bounce_token

Deal with a bouncing token.  This involves simply deleting the token, since
it didn't get where it was going.

=cut
sub handle_bounce_token {
  my ($self, %args) = @_;
  my $log  = new Log::In 35;
  my (%file, @owners, @bouncers, $data, $del, $desc, $dest, $ent, 
      $file, $from, $i, $inform, $mess, $ok, $reasons, $sender, 
      $subs, $time);

  # Dump the body to the session file
  # XXX Check validity
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
      $del = " " if ($ok);
      if (ref ($data) eq 'HASH' and exists $data->{'victim'}) {
        $mess = $self->format_error('probe_bounce', $data->{'list'});
        $self->inform('GLOBAL', 'reject',
                  qq("Automatic Bounce Processor" <$args{'sender'}>),
                  $data->{'victim'}, "reject $args{'token'}",
                  $self->{'interface'}, $ok, 0, 0, 
                  $mess, $::log->elapsed - $time);
      }
      last;
    }
  }

  unless ($del) {
    ($ok, $data) = $self->t_info($args{'token'});
  }
  return ($ok, $data) unless ($ok and ref ($data) eq 'HASH');

  $data->{'list'} ||= 'GLOBAL';

  unless (($i) = $self->_make_list($data->{'list'})) {
    return (0, $self->format_error('make_list', 'GLOBAL', 
                                   'LIST' => $data->{'list'}));
  }

  # Only inform the administrators if the inform setting requires it.
  @owners = @{$self->_list_config_get($data->{'list'}, 'owners')};
  $inform = $self->_list_config_get($data->{'list'}, 'inform');
  $i = $inform->{'tokenbounce'}{'all'} || $inform->{'tokenbounce'}{1} || 0;
  if ($i & 2) {
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

  return (1, '') unless (scalar @bouncers);

  $reasons ||= '';

  # XXX If the token was sent to some destination other than
  # the victim, the bounce notice may indicate the wrong destination.
  $subs = {
           $self->standard_subs($data->{'list'}),
           'CMDLINE'    => $data->{'cmdline'},
           'COMMAND'    => $data->{'command'},
           'DATE'       => scalar localtime ($data->{'time'}),
           'HANDLER'    => $args{'handler'},
           'REASONS'    => $reasons,
           'REQUESTER'  => $data->{'user'},
           'SESSIONID'  => $data->{'sessionid'},
           'TOKEN'      => $args{'token'},
           'VICTIM'     => $data->{'victim'},
          };

  if ($del) {
    $subs->{'DELETED'} = 
      $self->format_error('token_deleted', $data->{'list'},
                          'TOKEN' => $args{'token'});
  }
  else {
    $subs->{'DELETED'} = '';
  }

  ($file, %file) = $self->_list_file_get(list => $data->{'list'},
					 file => 'token_bounce',
					);

  unless (defined $file) {
    $mess = $self->format_error('no_file', $data->{'list'},
                                'FILE' => 'token_bounce');
    return (0, $mess);
  }

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
     'Content-Language:' => $file{'language'},
     Subject  => $desc,
     -To      => $dest,
     -From    => $from,
     Top      => 1,
     Filename => undef,
    );

  if ($ent) {
    $ent->attach(Type        => 'message/rfc822',
                 Encoding    => '8bit',
                 Description => 'Original message',
                 Path        => $args{file},
                 Filename    => undef,
                );

    if ($sender) {
      $self->mail_entity($sender, $ent, @bouncers);
    }

    $ent->purge;
  }
  else {
    return (0, $self->format_error('no_entity', $data->{'list'}));
  }

  (1, '');
}

=head2 handle_bounce_user

Does the bounce processing for a single user.  This involves:

=item Add new bounce data

=item Generate statistics

=item Decide what action (if any) to take

=item Log the bounce

=item Return an explanation to the caller if a failure occurs

=cut
use Mj::CommandProps 'action_terminal';
use Mj::Util 'process_rule';
sub handle_bounce_user {
  my $self   = shift;
  my %params = @_; # Can't use %args, because the access code uses it.
  my $log  = new Log::In 35, "$params{'list'}, $params{'user'}";
  my (%args, %memberof, @final_actions, $arg, $bdata, $desc, $func, 
      $i, $inform, $list, $mess, $ok, $rules, $sdata, $status, $tmp, $tmpa, 
      $tmpl, $user);

  $list   = $params{list};
  $status = $params{status};
  $inform = 0;
  $params{msgno} = '' if $params{msgno} eq 'unknown';

  # Make sure we understand what to do with this bounce
  if ($status ne 'warning' && $status ne 'failure') {
    return (0, $self->format_error('unknown_bounce', $list));
  }

  $user = new Mj::Addr($params{user});

  # No guarantees that an address pulled out of a bounce is valid
  return (0, $self->format_error('undefined_address', $list))
    unless (defined $user);

  ($ok, $mess, $desc) = $user->valid;
  unless ($ok) {
    $tmp = $self->format_error($mess, 'GLOBAL');
    chomp $tmp if (defined $tmp);
    return (0, $self->format_error('invalid_address', $list, 
                                   'ADDRESS' => "$user", 'ERROR' => $tmp,
                                   'LOCATION' => $desc));
  }

  # Process a bounce that came in on the GLOBAL list.  We don't do much;
  # bounce_rules doesn't apply and we don't record bounce data in the
  # registry.  Plus we'll never have nice numbered bounces anyway.
  if ($list eq 'GLOBAL') {
    return (1, '');
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
  $args{reasons}              = '';

  if (defined $sdata and $sdata->{class} eq 'digest') {
    $args{'digest'} = $sdata->{'classarg'};
  }
  else {
    $args{'digest'} = '';
  }
  $args{'addr'}     = $user->strip || '';
  $args{'fulladdr'} = $user->full || '';
  $args{'host'}     = $user->domain || '';

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
    ($func, $arg) = split(/[-=]/, $i, 2);
    $arg ||= '';

    if ($func eq 'ignore') {
      $inform = 0;
      last;
    }
    elsif ($func eq 'inform') {
      unless (defined $args{'reasons'} and length $args{'reasons'}) {
        $args{'reasons'} = $self->format_error('bounce_rule', $list, 
                                               'COMMAND' => $i);
      }
      $inform = 1 unless ($arg =~ /quiet/);
    }
    elsif ($func eq 'remove') {
      unless (defined $args{'reasons'} and length $args{'reasons'}) {
        $args{'reasons'} = $self->format_error('bounce_rule', $list, 
                                               'COMMAND' => $i);
      }
      ($ok, $tmp) = 
        $self->handle_bounce_removal(%params,
                                     mode   => $arg,
                                     notify => $args{'notify'},
                                     reasons=> $args{'reasons'},
                                     subbed => !!$sdata,
                                     user   => $user,
                                    );
      return ($ok, $tmp) unless $ok; 
      $args{'reasons'} .= "\003" . 
        $self->format_error('bounce_unsub', $list, 'VICTIM' => $user);
      $inform = 1 unless ($arg =~ /quiet/);
    }
    else {
      warn "Running bounce_rules: don't know how to $func";
    }
  }

  if ($inform > 0) {
    return (1, \%args);
  }
  else {
    return (1, '');
  }
}

=head2 handle_bounce_removal

Deal with the particulars of removing a bouncing user.

There are several possibilities:

=item Remove the user immediately.

=item Send the owner(s) a consultation token; when accepted, the user is
   removed.

=item Generate a bounce probe; if it bounces, remove the user.

=item Probe, but consult the owner before removing if the probe
  bounces.

=cut
sub handle_bounce_removal {
  my $self = shift;
  my %args = @_;
  my $log = new Log::In 50;
  my ($time) = $::log->elapsed;
  my ($consult, $mess, $ok, $probe);

  if (!$args{subbed}) {
    return (0, $self->format_error('not_subscribed', $args{'list'},
                                   'VICTIM' => $args{'user'}));
  }

  $consult = 0;
  $probe   = 1;

  $probe   = 0 if $args{mode} =~ /noprobe/;
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
		$args{'reasons'}, $::log->elapsed - $time);

  shell_hook('name' => 'bouncehandler-unsubscribe',
             'cmdargs' => [ $self->domain, $args{'list'}, $args{'user'} ]);

  return ($ok, $mess);
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
		   reasons  => $args{reasons},
		  );

  # Now add a type C bounce event
  $self->{lists}{$args{list}}->bounce_add
    (addr   => $args{user},
     subbed => 1,
     time   => time,
     type   => 'C',
     evdata => $token,
    );

  return (1, '');
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
		   reasons  => $args{reasons},
		  );

  # And add a type P bounce event
  $self->{lists}{$args{list}}->bounce_add
    (addr   => $args{user},
     subbed => 1,
     time   => time,
     type   => 'P',
     evdata => $token,
    );

  return (1, '');
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

Copyright (c) 2000, 2002, 2003 Jason Tibbitts for The Majordomo
Development Group.  All rights reserved.

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

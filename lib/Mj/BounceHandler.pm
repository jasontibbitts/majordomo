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

  $fh = new IO::File "$file";
  $ent = $parser->read($fh);
  $fh->close;

  # Extract information from the envelope, if any, and parse the bounce.
  $whoami = $self->_global_config_get('whoami');
  $whoami =~ s/\@.*$//;
  $source = 'unknown@anonymous';

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
    }

    # We couldn't parse anything useful
    else {
      $handled = 0;
    }
  }

  $ent->purge if $ent;

  # Tell the caller whether or not we handled the bounce
  ($handled, $source, $addrs);
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
      $status = 'failure';
      $diag   = 'unknown';
    }
    $data = {$user => {status => $status, diag => $diag}};
  }

  # Now plow through the data from the parsers
  for $i (keys %$data) {

    # We completely ignore warnings
    next if $data->{$i}{status} eq 'warning';
    $tmp = $self->handle_bounce_user(%args,
				     user => $i,
				     %{$data->{$i}},
				    );
    $mess .= $tmp if $tmp;

    if ($subj) {
      $subj .= ", $i";
    }
    else {
      $subj  = "Bounce detected (list $list) from $i";
    }
    push @$addrs, $i;
  }

  # We can bail if we didn't get any non-warning addresses
  return [] unless @$addrs;

  # Build a new message which includes the explanation from the bounce
  # parser and attach the original message.
  $subj ||= 'Bounce detected';
  $nent = build MIME::Entity
    (
     Data     => [ $mess,
		   "The bounce message is attached below.\n\n",
		 ],
     -Subject => $subj,
     -To      => $lsender,
     -From    => $from,
    );
  $nent->attach(Type        => 'message/rfc822',
		Description => 'Original message',
		Path        => $args{file},
		Filename    => undef,
	       );
  $self->mail_entity($sender, $nent, @bouncers);

  $nent->purge if $nent;
  $addrs;
}

=head2 handle_bounce_token

Deal with a bouncing token.  This involves simply deleting the token, since
it didn't get where it was going.

=cut
sub handle_bounce_token {
  my($self, %args) = @_;
  my $log  = new Log::In 35;
  my(@owners, @bouncers, $from, $i, $mess, $nent, $sender);


  # Dump the body to the session file
  $args{entity}->print_body($self->{sessionfh});

  # If we parsed out a failure, delete the token
  # unless it is for a delayed action.
  for $i (keys %{$args{data}}) {
    last if $args{'type'} eq 'D';
    if ($args{data}{$i}{status} eq 'failure') {
      $self->t_remove($args{token});
      last;
    }
  }

  @owners   = @{$self->_global_config_get('owners')};
  @bouncers = @{$self->_global_config_get('bounce_recipients')};
  @bouncers = @owners unless @bouncers;
  $sender = $owners[0];
  $from = $self->_global_config_get('sender');

  # Build a new message which includes the explanation from the bounce
  # parser and attach the original message.
  $nent = build MIME::Entity
    (
     Data     => [ "Detected a bounce of token $args{token}.\n",
		   "  (bounce type $args{handler})\n\n",
		   "This token has been deleted.\n\n",
		   "The bounce message is attached below.\n\n",
		 ],
     -Subject => "Bounce of token $args{token} detected",
     -To      => $from,
     -From    => $from,
    );
  $nent->attach(Type        => 'message/rfc822',
		Description => 'Original message',
		Path        => $args{file},
		Filename    => undef,
	       );
  $self->mail_entity($sender, $nent, @bouncers);

  $nent->purge if $nent;

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

  my (%args, %memberof, @final_actions, $actions, $arg, $bdata, $cpt,
      $func, $i, $mess, $ok, $rules, $saw_terminal, $sdata, $status, $tmpa,
      $tmpl, $value);

  my $user   = $params{user};
  my $list   = $params{list};
  my $parser = shift || 'unknown';

  $status = $params{status};

  $params{msgno} = '' if $params{msgno} eq 'unknown';

  if ($status eq 'unknown' || $status eq 'warning' || $status eq 'failure') {
    $user = new Mj::Addr($user);

    # No guarantees that an address pulled out of a bounce is valid
    unless ($user) {
      return "  User:       (unknown)\n\n";
    }

    unless ($user->isvalid) {
      return "  User:       $user (invalid)\n\n";
    }

    # Add the new bounce event to the collected bounce data
    if ($list ne 'GLOBAL') {
      $sdata = $self->{lists}{$list}->is_subscriber($user);
      $bdata = $self->{lists}{$list}->bounce_add($user, time, $params{type}, $params{msgno}, $params{diag});
    }

    $mess .= "  User:        $user\n";
    $mess .= "  Subscribed:  " .($sdata?'yes':'no')."\n" if $list ne 'GLOBAL';
    $mess .= "  Status:      $params{status}\n";
    $mess .= "  Diagnostic:  $params{diag}\n";

    if ($bdata) {
      %args = %{$self->{lists}{$list}->bounce_gen_stats($bdata)};

      $mess .= "  Bounce statistics for this user:\n";
      $mess .= "    Bounces last 24 hours:          $args{day_overload}$args{day}\n";
      $mess .= "    Bounces last 7 days:            $args{week_overload}$args{week}\n";
      $mess .= "    Bounces last 30 days:           $args{month_overload}$args{month}\n"
	if $args{month};
      $mess .= "    Consecutive messages bounced:   $args{consecutive}\n"
	if $args{consecutive} && $args{consecutive} > 3;
      $mess .= "    Percentage of messages bounced: $args{bouncedpct}\n"
	if $args{bouncedpct} && $args{numbered} >= 5;

      # Make triage decision.  Run the parsed code from bounce_rules.  XXX
      # Note that most of this code is duplicated from access_rules.  This
      # is bad; the code needs to be shared.
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
      $args{days_since_subscribe} = (time - $sdata->{subtime})/86400;

      @final_actions =
	process_rule(name     => 'bounce_rules',
		     request  => '_bounce',
		     code     => $rules->{code},
		     args     => \%args,
		     memberof => \%memberof,
		    );

      # XXX Don't actually do anything yet
      $mess .= "  Bounce rules said: @final_actions.\n";

      # Remove user if necessary
    }
  }
  "$mess\n";
}


=head1 COPYRIGHT

Copyright (c) 2000 Jason Tibbitts for The Majordomo Development Group.  All
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

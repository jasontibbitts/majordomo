=head1 NAME

Mj::MailOut.pm - simple mailing functions for Majordomo

=head1 SYNOPSIS

 $mj->mail_message($sender, $file, "address1", "address2");
 $mj->mail_entity($sender, $entity, "address1", "address2");

 # Send a file to all members of $lists's digest class except for
 # "addressa"
 $mj->deliver($list, $sublist, $sender, $file, $seqno, "digest", "addressa");

=head1 DESCRIPTION

These functions deal with sending out mail from various sources.  The
actual mail delivery engine is not included here; that is in
Mj::Deliver.pm.

=cut
package Mj::MailOut;
use strict;

use AutoLoader 'AUTOLOAD';
1;
__END__

=head2 mail_message(sender, file, addresses)

This sends a piece of mail contained in a file to several addresses.  Use
this if you have built a complete MIME message complete with headers and
printed it out to a file.

If $sender is a hashref, an extended envelope sender is built if possible
using the hash keys 'addr', 'type' and 'data'.

=cut
use Mj::Deliver::Envelope;
sub mail_message {
  my $self   = shift;
  my $sender = shift;
  my $file   = shift;
  my @addrs  = @_;
  my $log = new Log::In 30, "$file, $sender, $addrs[0]";
  my (@a, $i);

  # Make sure all addresses are stripped before mailing.  If we were given
  # no legal addresses, do nothing.
  for $i (@addrs) {
    $i = new Mj::Addr($i);
    next unless $i->isvalid;
    next if     $i->isanon;
    push @a, $i->strip;
  }
  return unless @a;

  if (ref($sender)) {
    $sender = $self->extend_sender($sender->{addr},
				   $sender->{type},
				   $sender->{data}
				  );
  }

  my $env = new Mj::Deliver::Envelope
    'sender' => $sender,
    'file'   => $file,
    'host'   => 'localhost',
    'personal' => 0,
    'addrs'  => \@a;

  unless ($env) {
    # log the failure, but do not notify anyone by mail, since
    # inform() calls mail_entity().
    $self->inform("GLOBAL", "mail_message", $sender, $addrs[0],
                  "(envelope $file)", "mailout", 0, 0, 1);
    return 0;
  }
  unless ($env->send) {
    $self->inform("GLOBAL", "mail_message", $sender, $addrs[0],
                  "(message $file)", "mailout", 0, 0, 1);
    return 0;
  }
  1;
}

=head2 mail_entity(sender, entity, addresses)

This mails a pre-built MIME entity to a list of addresses.  It prints it
out to a file, then calls mail_message.

=cut
use MIME::Entity;
sub mail_entity {
  my $self   = shift;
  my $sender = shift;
  my $entity = shift;
  my @addrs  = @_;
  my $log = new Log::In 35, "$addrs[0]";
  my ($fh, $tmpdir, $tmpfile);

  $tmpdir = $self->_global_config_get("tmpdir");
  $tmpfile = "$tmpdir/mj-tmp." . Majordomo::unique();

  $fh = new IO::File "> $tmpfile" || $::log->abort("Can't open $tmpfile, $!");
  $entity->print($fh);
  $fh->close;

  if ($self->mail_message($sender, $tmpfile, @addrs)) {
    unlink $tmpfile || $::log->abort("Can't unlink $tmpfile, $!");
  }
}

=head2 deliver(list, sublist, sender, sequence_number, class_hashref)

This calls the delivery routine to deliver a message to all subscribers to
a list who are in a certain class, except for some users.

list should be a list name.

We take the sequence number here because _post will have already changed it
in the config by the time we are called.

=cut
use Mj::Deliver;
use Mj::MTAConfig;
sub deliver {
  my $self    = shift;
  my $list    = shift;
  my $sublist = shift || '';
  my $sender  = shift;
  my $seqno   = shift;
  my $classes = shift;

  my $log = new Log::In 30;
  my(%args, $bucket, $buckets, $mta, $regexp, $subdb);

  # Figure out some data related to bounce probing
  $mta     = $self->_site_config_get('mta');
  $buckets = $self->_list_config_get($list, 'bounce_probe_frequency');
  #
  if (defined $seqno) {
    $bucket  = $seqno % $buckets if $buckets;
  }
  else {
    $bucket = int(rand $buckets) if $buckets;
  }
  $regexp  = $self->_list_config_get($list, 'bounce_probe_pattern');

  %args =
    (list    => $self->{'lists'}{$list},
     sublist => $sublist,
     sender  => $sender,
     classes => $classes,
     rules   => $self->_list_config_get($list,'delivery_rules'),
     chunk   => $self->_global_config_get('chunksize'),
     sendsep => $self->_site_config_get('mta_separator'),
     manip   => 1,
     seqnum  => $seqno,
    );

  if ($buckets) {
    $args{probe}   = 1;
    $args{buckets} = $buckets;
    $args{bucket}  = $bucket;
  }
  if ($regexp) {
    $args{probe}   = 1;
    $args{regexp}  = $regexp;
  }

  Mj::Deliver::deliver(%args);
}

=head2 probe

Send a customized message to a group of people.

=cut
use Mj::Deliver;
sub probe {
  my $self    = shift;
  my $list    = shift;
  my $sender  = shift;
  my $classes = shift;

  return unless $self->_make_list($list);

  my %args =
    (list    => $self->{'lists'}{$list},
     sublist => '',
     sender  => $sender,
     classes => $classes,
     rules   => $self->_list_config_get($list,'delivery_rules'),
     chunk   => $self->_global_config_get('chunksize'),
     sendsep => $self->_site_config_get('mta_separator'),
     manip   => 1,
     seqnum  => 0,
     probe   => 1,
     probeall => 1,
    );

  Mj::Deliver::deliver(%args);
}

=head2 owner_*

These functions comprise an iterative interface to a function which
forwards a message to the owner(s) of a mailing list.

=cut
sub owner_start {
  my ($self, $request) = @_;
  my $log  = new Log::In 30, "$request->{'list'}";

  my $tmp  = $self->_global_config_get('tmpdir');
  my $file = "$tmp/owner." . Majordomo::unique();
  $self->{'owner_file'} = $file;
  $self->{'owner_fh'} = new IO::File ">$file" or
    $log->abort("Can't open $file, $!");
  (1, '');
}

sub owner_chunk {
  my ($self, $request, $data) = @_;
  $self->{'owner_fh'}->print($data);
  (1, '');
}

sub owner_done {
  my ($self, $request) = @_;
  $request->{'list'} ||= 'GLOBAL';
  my $log  = new Log::In 30, "$request->{'list'}";
  my (@owners, $badaddr, $handled, $sender, $user);
  $badaddr = '';

  $self->{'owner_fh'}->close;
  $self->_make_list($request->{'list'});

  # Call bounce handling routine
  ($handled, $user, $badaddr) =
   $self->handle_bounce($request->{'list'}, $self->{'owner_file'});

  if (! $handled) {
    # Nothing from the bounce parser
    # Just mail out the file as if we never saw it
    $sender  = $self->_list_config_get('GLOBAL', 'sender');
    if ($request->{'mode'} eq 'm') {
      # Forward to moderators instead of owners.
      @owners = $self->{'lists'}{$request->{'list'}}->moderators;
    }
    else {
      @owners  = @{$self->_list_config_get($request->{'list'}, 'owners')};
    }
    $self->mail_message($sender, $self->{'owner_file'}, @owners);
  }

  unlink $self->{'owner_file'};
  undef $self->{'owner_fh'};
  undef $self->{'owner_file'};
  (1, $badaddr);
}

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
  my (@bouncers, @owners, $diag, $i, $lsender, $mess, $nent, $sender,
      $status, $subj, $tmp);

  my $data = $args{data};
  my $list = $args{list};
  my $user = $args{user};
  my $addrs= [];

  # Dump the body to the session file
  $args{entity}->print_body($self->{sessionfh});

  $mess  = "Detected a bounce of message #$args{msgno}.\n";
  $mess .= "  (bounce type $args{handler})\n\n";

  $sender   = $self->_list_config_get('GLOBAL', 'sender');
  $lsender  = $self->_list_config_get($list, 'sender');
  @owners   = @{$self->_list_config_get($list, 'owners')};
  @bouncers = @{$self->_list_config_get($list, 'bounce_recipients')};
  @bouncers = @owners unless @bouncers;

  # If we have an address from the envelope, we can only have one and we
  # know it's correct.  Parsing may have been able to extract a status
  # and diagnostic, so grab them then overwrite the data hash with a new
  # one containing just that user.  The idea is to ignore any addresses
  # that parsing extracted but aren't relevant.
  if ($user) {
    if ($data->{$user}) {
      $status = $data->{$user}{status};
      $diag   = $data->{$user}{diag} || 'unknown';
    }
    else {
      $status = 'bounce';
      $diag   = 'unknown';
    }
    $data = {$user => {status => $status, diag => $diag}};
  }

  # Now plow through the data from the parsers
  for $i (keys %$data) {
    $tmp = $self->handle_bounce_user(%args,
				     user => $i,
				     %{$data->{$i}},
				    );
    $mess .= $tmp if $tmp;

    if ($subj) {
      $subj .= ", $i";
    }
    else {
      $subj  = "Bounce detected from $i";
    }
    push @$addrs, $i;
  }

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
     -From    => $sender,
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
  my(@owners, @bouncers, $i, $mess, $nent, $sender);


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

  $sender   = $self->_global_config_get('sender');
  @owners   = @{$self->_global_config_get('owners')};
  @bouncers = @{$self->_global_config_get('bounce_recipients')};
  @bouncers = @owners unless @bouncers;

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
     -To      => $sender,
     -From    => $sender,
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

*) retrieving any stored bounce data

*) trimming it down if necessary (expiring old entries)

*) adding new bounce data

*) writing the data back

*) generating statistics

*) deciding what action (if any) to take

*) logging the bounce

*) return an explanation message block to the caller

=cut
sub handle_bounce_user {
  my $self   = shift;
  my %args = @_;
  my $log  = new Log::In 35;
  my ($mess, $bdata, $stats, $status, $userdata);

  my $user   = $args{user};
  my $list   = $args{list};
  my $parser = shift || 'unknown';

  $status = $args{status};
  $args{msgno} = '' if $args{msgno} eq 'unknown';
  if ($status eq 'unknown' || $status eq 'warning' || $status eq 'failure') {
    $user = new Mj::Addr($user);

    # No guarantees that an address pulled out of a bounce is valid
    unless ($user->isvalid) {
      return "  User:       $user (invalid)\n\n";
    }

    # Add the new bounce event to the collected bounce data
    if ($list ne 'GLOBAL') {
      $bdata = $self->{lists}{$list}->bounce_add($user, time, $args{type}, $args{msgno}, $args{diag});
    }
    $mess .= "  User:        $user\n";
    $mess .= "  Subscribed:  " .($bdata?'yes':'no')."\n" if $list ne 'GLOBAL';
    $mess .= "  Status:      $args{status}\n";
    $mess .= "  Diagnostic:  $args{diag}\n";

    if ($bdata) {
      $stats = $self->{lists}{$list}->bounce_gen_stats($bdata);
#      use Data::Dumper; $mess .= Dumper $bdata;

      $mess .= "  Bounce statistics for this user:\n";
      $mess .= "    Bounces last 24 hours:          $stats->{day_overload}$stats->{day}\n";
      $mess .= "    Bounces last 7 days:            $stats->{week_overload}$stats->{week}\n";
      $mess .= "    Bounces last 30 days:           $stats->{month_overload}$stats->{month}\n"
	if $stats->{month};
      $mess .= "    Consecutive messages bounced:   $stats->{consecutive}\n"
	if $stats->{consecutive};
      $mess .= "    Percentage of messages bounced: $stats->{bouncedpct}\n"
	if $stats->{bouncedpct};

      # Make triage decision.  Run the parsed code from bounce_rules
      if (($stats->{consecutive} && $stats->{consecutive} > 10) ||
	  ($stats->{bouncedpct}      && $stats->{numbered} &&
	   $stats->{bouncedpct} > 70 && $stats->{numbered} > 20))
	{
	  $mess .= "  It is recommended that this user be removed.\n";
	}

      # Remove user if necessary

    }
  }
  "$mess\n";
}

=head2 welcome(list, address)

This welcomes a subscriber to the list by sending them the messages
specified in the 'welcome_files' variable. If one of the files in the
welcome message does not exist, it is ignored.

=cut
use MIME::Entity;
sub welcome {
  my $self = shift;
  my $list = shift;
  my $addr = shift;
  my %args = @_;
  my $log = new Log::In 150, "$list, $addr";
  my (%file, @mess, @temps, $count, $head, $file, $final, $subj, $subs,
      $top, $i, $j);

  # Extract some necessary variables from the config files
  my $tmpdir    = $self->_global_config_get('tmpdir');
  my $sender    = $self->_list_config_get($list, 'sender');
  my $table     = $self->_list_config_get($list, 'welcome_files');

  $subs = {
           $self->standard_subs($list),
	   'USER'     => $addr,
	   %args,
	  };

  # Loop over the table, processing parts and substituting values
  $count = 0;
  for($i=0; $i<@{$table}; $i++) {
    # Are we starting a new message?
    if ($i!=0 && $table->[$i][2] =~ /N/) {
      $count++;
    }
    ($file, %file) = $self->_list_file_get($list, $table->[$i][1]);
    # XXX Need to complain here
    next unless $file;

    $subj = $self->substitute_vars_string($table->[$i][0] ||
					  $file{'description'}, $subs);

    # We may have to substitute variables in the file
    if ($table->[$i][2] =~ /S/) {
      $file = $self->substitute_vars($file, $subs);
      push @temps, $file;
    };

    # Set the subject only for the first part
    $mess[$count]{'subject'} = $subj
      unless ($mess[$count]{'subject'});

    # Build a part and add it to the list
    push @{$mess[$count]{'ents'}}, build MIME::Entity
      (
       Path        => $file,
       Type        => $file{'c_type'},
       Charset     => $file{'charset'},
       Encoding    => $file{'c_t_encoding'},
       Filename    => undef,
       Description => $subj,
       Top         => 0,
       'Content-Language:' => $file{'language'},
      );
  }

  # Now we can go over the @mess array, build messages and deliver them
  for ($i=0; $i<@mess; $i++) {
    # If we have a single-part message...
    if (@{$mess[$i]{'ents'}} == 1) {
      $top = shift @{$mess[$i]{'ents'}};
    }
    else {
      $top = build MIME::Entity(Type => "multipart/mixed");
      for $j (@{$mess[$i]{'ents'}}) {
	$top->add_part($j);
      }
    }
    $head = $top->head;
    $head->replace('To',      $addr);
    $head->replace('Subject', $mess[$i]{'subject'});
    $head->replace('From',    $sender);
    $final = "$tmpdir/mj-tmp." . Majordomo::unique();
    open FINAL, ">$final" ||
      $::log->abort("Cannot open file $final, $!");
    $top->print(\*FINAL);
    close FINAL;
    push @temps, $final;
    $self->mail_message($sender, $final, $addr);
  }
  for $i (@temps) {
    unlink $i || $::log->abort("Failed to unlink $i, $!");
  }
  1;
}

=head2 extend_sender

This generates an extended sender given an address, a type and some data.

=cut
sub extend_sender {
  my($self, $addr, $type, $data) = @_;
  my $sep = $self->_site_config_get('mta_separator');

  $addr =~ /^(.+)\@(.+)$/;
  return "$1$sep$type$data\@$2";
}


=head1 COPYRIGHT

Copyright (c) 1997-2000 Jason Tibbitts for The Majordomo Development
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

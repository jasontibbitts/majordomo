=head1 NAME

Mj::MailOut.pm - simple mailing functions for Majorodmo

=head1 SYNOPSIS

 $mj->mail_message($sender, $file, "address1", "address2");
 $mj->mail_entity($sender, $entity, "address1", "address2");

 # Send a file to all members of $lists's digest class except for
 # "addressa"
 $mj->deliver($list, $sender, $file, $seqno, "digest", "addressa");

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

  my $env = new Mj::Deliver::Envelope
    'sender' => $sender,
    'file'   => $file,
    'host'   => 'localhost',
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

=head2 deliver(list, sender, sequence_number, class_hashref)

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
  my $sender  = shift;
  my $seqno   = shift;
  my $classes = shift;

  my $log = new Log::In 30;
  my(%args, $bucket, $buckets, $mta);

  # Figure out some data related to bounce probing
  $mta     = $self->_site_config_get('mta');
  $buckets = $self->_list_config_get($list, 'bounce_probe_frequency');
  $bucket  = $seqno % $buckets if $buckets;

  %args =
    (list    => $self->{'lists'}{$list},
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

  Mj::Deliver::deliver(%args);
}

=head2 owner_*

These functions comprise an iterative interface to a function which
forwards a message to the owner(s) of a mailing list.

=cut
sub owner_start {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list) = @_;
  my $log  = new Log::In 30, "$list";

  my $tmp  = $self->_global_config_get('tmpdir');
  my $file = "$tmp/owner." . Majordomo::unique();
  $self->{'owner_file'} = $file;
  $self->{'owner_fh'} = new IO::File ">$file" or
    $log->abort("Can't open $file, $!");
  1;
}

sub owner_chunk {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $vict, $data) = @_;
  $self->{'owner_fh'}->print($data);
}

use Mj::MIMEParser;
use Bf::Parser;
sub owner_done {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list) = @_;
  $list ||= 'GLOBAL';
  my $log  = new Log::In 30, "$list";
  my (@owners, @bouncers, $data, $ent, $fh, $i, $mess, $msgno, $nent, $parser,
      $sender, $lsender, $tmpdir);

  $self->{'owner_fh'}->close;
  $self->_make_list($list);

  # Extract the some config data
  $sender  = $self->_list_config_get('GLOBAL', 'sender');
  $tmpdir  = $self->_global_config_get("tmpdir");
  @owners  = @{$self->_list_config_get($list, 'owners')};

  $parser = new Mj::MIMEParser;
  $parser->output_to_core($self->_global_config_get("max_in_core"));
  $parser->output_dir($tmpdir);
  $parser->output_prefix("mjo");

  $fh = new IO::File "<$self->{owner_file}";
  $ent = $parser->read($fh);
  $fh->close;

  # Extract information from the envelope, if any, and parse the bounce.
  ($type, $msgno, $user, $data) =
    Bf::Parser::parse($ent,
		      $list,
		      $self->_site_config_get('mta_separator')
		     );

  # If we know we have a message
  if ($type eq 'M') {
    $mess = "Detected a bounce of message #$msgno.\n";

    $lsender  = $self->_list_config_get($list, 'sender');
    @bouncers = @{$self->_list_config_get($list, 'bounce_recipients')};
    @bouncers = @owners unless @bouncers;

    # If we have an address from the envelope, we can only have one.
    # Always trust it but try to look for a more specific bounce status in
    # the $data hash
    if ($user) {
      if ($data->{$user}) {
	$status = $data->{$user}{status};
      }
      else {
	$status = "bounce";
      }
      $mess .= "  User:   $user.\n";
      $mess .= "  Status: $status\n\n";
    }

    # If we don't have a specific user from the envelope, we might have
    # several that we got from parsing the bounce
    else {
      for $i (keys %$data) {
	$status = $data->{$i}{status};
	if ($status eq 'unknown' || $status eq 'warning' || $status eq 'failure') {
	  $mess .= "  User:   $i\n";
	  $mess .= "  Status: $data->{$i}{status}\n\n";
	}
      }
    }

    # Build a new message which includes the explanation from the bounce
    # parser and attach the original message.
    $nent = build MIME::Entity
	(
	 Data     => [ $mess,
		     "The bounce message is attached below.\n\n",
		   ],
       -Subject => "Bounce detected",
       -To      => $lsender,
       -From    => $sender,
      );
    $nent->attach(Type        => 'message/rfc822',
		  Description => 'Original message',
		  Path        => $self->{owner_file},
                  Filename    => undef,
		 );
    $self->mail_entity($sender, $nent, @bouncers);
  }

  else {
    # Just mail out the file as if we never saw it
      $self->mail_message($sender, $self->{'owner_file'}, @owners);
  }

  unlink $self->{'owner_file'};
  undef $self->{'owner_fh'};
  undef $self->{'owner_file'};
  $ent->purge;
  $nent->purge if $nent;
  1;
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
  my $mj        = $self->_global_config_get('whoami');
  my $mj_owner  = $self->_global_config_get('sender');
  my $whereami  = $self->_global_config_get('whereami');
  my $tmpdir    = $self->_global_config_get('tmpdir');
  my $site      = $self->_global_config_get('site_name');
  my $sender    = $self->_list_config_get($list, 'sender');
  my $table     = $self->_list_config_get($list, 'welcome_files');

  $subs = {'LIST' => $list,
	   'REQUEST'  => "$list-request\@$whereami",
	   'MAJORDOMO'=> $mj,
	   'MJ'       => $mj,
	   'USER'     => $addr,
	   'SITE'     => $site,
	   'MJOWNER'  => $mj_owner,
	   'OWNER'    => $sender,
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

=head1 COPYRIGHT

Copyright (c) 1997-2000 Jason Tibbitts for The Majordomo Development
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

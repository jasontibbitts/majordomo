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
  my $log = new Log::In 30, "$file, $addrs[0]";
  
  my $env = new Mj::Deliver::Envelope
    'sender' => $sender,
    'file'   => $file,
    'host'   => 'localhost',
    'addrs'  => \@addrs;

  unless ($env) {
    $::log->abort("Failed to build envelope for mailing.")
  }
  $env->send || $::log->abort("Failed to send message!");
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
  $tmpfile = "$tmpdir/mj-tmp." . $self->unique;
  
  $fh = new IO::File "> $tmpfile" || $::log->abort("Can't open $tmpfile, $!");
  $entity->print($fh);
  $fh->close;

  $self->mail_message($sender, $tmpfile, @addrs);
  unlink $tmpfile || $::log->abort("Can't unlink $tmpfile, $!");
}

=head2 deliver(list, sender, file, class, exclude_list)

This calls the delivery routine to deliver a message to all subscribers to
a list who are in a certain class, except for some users.

list should be a list name.  Addresses in exclude_list should be in
canonical form.

We take the sequence number here because _post will have already changed it
in the config by the time we are called.

=cut
use Mj::Deliver;
use Mj::MTAConfig;
sub deliver {
  my $self    = shift;
  my $list    = shift;
  my $sender  = shift;
  my $file    = shift;
  my $seqno   = shift;
  my $class   = shift;
  my @exclude = @_;
  my $log = new Log::In 30, $file;
  my(%args, $bucket, $buckets, $mta);

  # Figure out some data related to bounce probing
  $mta     = $self->_global_config_get('mta');
  $buckets = $self->_list_config_get($list, 'bounce_probe_frequency');
  $bucket  = $seqno % $buckets if $buckets;

  %args =
    (list    => $self->{'lists'}{$list},
     sender  => $sender,
     file    => $file,
     class   => $class,
     rules   => $self->_list_config_get($list,'delivery_rules'),
     chunk   => $self->_global_config_get('chunksize'),
     exclude => [@exclude],
     sendsep => $Mj::MTAConfig::sendsep{$mta},
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
  my $file = "$tmp/post." . $self->unique;
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

sub owner_done {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list) = @_;
  $list ||= 'GLOBAL';
  my $log  = new Log::In 30, "$list";
  my (@owners, $owner);

  $self->{'owner_fh'}->close;
  $self->_make_list($list);

  # Extract the owners
  $owner  = $self->_list_config_get($list, 'whoami_owner');
  @owners = @{$self->_list_config_get($list, 'owners')};

  # Mail the file
  $self->mail_message($owner, $self->{'owner_file'}, @owners);

  unlink $self->{'owner_file'};
  undef $self->{'owner_fh'};
  undef $self->{'owner_file'};
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
  my (%subs, @mess, @temps, $count, $cset, $head, $final, $subj, $file,
      $desc, $c_type, $c_t_encoding, $top, $i, $j);

  # Extract some necessary variables from the config files
  my $whoami        = $self->_global_config_get('whoami');
  my $whoami_owner  = $self->_global_config_get('whoami_owner');
  my $whereami      = $self->_global_config_get('whereami');
  my $tmpdir        = $self->_global_config_get('tmpdir');
  my $site          = $self->_global_config_get('site_name');
  my $sender        = $self->_list_config_get($list, 'sender');
  my $table         = $self->_list_config_get($list, 'welcome_files');

  %subs = ('LIST' => $list,
	   'REQUEST'  => "$list-request\@$whereami",
	   'MAJORDOMO'=> $whoami,
	   'USER'     => $addr,
	   'SITE'     => $site,
	   'MJOWNER'  => $whoami_owner,
	   'OWNER'    => $sender,
	   %args,
	  );
  
  # Loop over the table, processing parts and substituting values
  $count = 0;
  for($i=0; $i<@{$table}; $i++) {
    # Are we starting a new message?
    if ($i!=0 && $table->[$i][2] =~ /N/) {
      $count++;
    }
    ($file, $desc, $c_type, $cset,  $c_t_encoding) =
      $self->_list_file_get($list, $table->[$i][1]);
    # XXX Need to complain here
    next unless $file;

    $subj = $self->substitute_vars_string($table->[$i][0] || $desc, %subs);
    
    # We may have to substitute variables in the file
    if ($table->[$i][2] =~ /S/) {
      $file = $self->substitute_vars($file, %subs);
      push @temps, $file;
    };
    
    # Set the subject only for the first part
    $mess[$count]{'subject'} = $subj
      unless ($mess[$count]{'subject'});
      
    # Build a part and add it to the list
    push @{$mess[$count]{'ents'}}, build MIME::Entity
      (
       Path        => $file,
       Type        => $c_type,
       Charset     => $cset,
       Encoding    => $c_t_encoding,
       Filename    => undef,
       Description => $subj,
       Top         => 0,
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
    $head->replace('to',      $addr);
    $head->replace('subject', $mess[$i]{'subject'});
    $head->replace('from',    $whoami);
    $final = "$tmpdir/mj-tmp." . $self->unique;
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
### mode:cperl ***
### cperl-indent-level:2 ***
### cperl-label-offset:-1 ***
### End: ***

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
use Symbol;

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
use Mj::Deliver;
sub mail_message {
  my $self   = shift;
  my $sender = shift;
  my $file   = shift;
  my @addrs  = @_;
  my $log = new Log::In 30, "$file, $sender, $addrs[0]";
  my (%args, @a, $i);

  $args{'rules'} = $self->_global_config_get('delivery_rules');
  $args{'dbtype'} = 'none';
  $args{'regexp'} = '';
  $args{'buckets'} = 0;
  $args{'lhost'} = $self->_global_config_get('whereami');
  $args{'classes'} = { 'all' => { 
                                 'file' => $file,
                                 'exclude' => [],
                                }
                     };

  $args{'addresses'} = [];
  # Make sure all addresses are stripped before mailing.  If we were given
  # no legal addresses, do nothing.
  for $i (@addrs) {
    next unless ($i);
    $i = new Mj::Addr($i);
    next unless $i->isvalid;
    next if     $i->isanon;
    push @{$args{'addresses'}}, { 'canon' => $i->canon,
                                  'strip' => $i->strip };
  }

  if (ref($sender)) {
    $args{'manip'}   = 1;
    $args{'sender'}  = $sender->{'addr'};
    $args{'sendsep'} = $self->_site_config_get('mta_separator'),
    $args{'classes'}{'all'}{'seqnum'} = $sender->{'type'} . $sender->{'data'};
  }
  else {
    $args{'manip'}   = 0;
    $args{'sender'}  = $sender;
  }

  Mj::Deliver::deliver(%args);
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

  $fh = gensym();
  open ($fh, "> $tmpfile") || $::log->abort("Can't open $tmpfile, $!");
  $entity->print($fh);
  close ($fh)
    or $::log->abort("Unable to close file $tmpfile: $!");

  if ($self->mail_message($sender, $tmpfile, @addrs)) {
    unlink ($tmpfile) || $::log->abort("Can't unlink $tmpfile, $!");
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
sub deliver {
  my $self    = shift;
  my $list    = shift;
  my $sublist = shift || '';
  my $sender  = shift;
  my $classes = shift;

  my $log = new Log::In 30;
  my(%args, $bucket, $buckets, $regexp, $subdb);

  # Figure out some data related to bounce probing
  $buckets = $self->_list_config_get($list, 'bounce_probe_frequency');
  $bucket  = int(rand $buckets) if $buckets;
  $regexp  = $self->_list_config_get($list, 'bounce_probe_pattern');

  %args =
    (
     backend => $self->{'backend'},
     chunk   => $self->_global_config_get('chunksize'),
     classes => $classes,
     domain  => $self->{'domain'},
     lhost   => $self->_global_config_get('whereami'),
     listdir => $self->{'ldir'},
     list    => $list,
     manip   => 1,
     rules   => $self->_list_config_get($list, 'delivery_rules'),
     sender  => $sender,
     sendsep => $self->_site_config_get('mta_separator'),
    );

  if ($list ne 'GLOBAL' or ($sublist and $sublist ne 'MAIN')) {
    $args{'dbtype'} = 'sublist';
    if ($sublist and $sublist ne 'MAIN') {
      $args{'dbfile'} = "X$sublist";
    }
    else {
      $args{'dbfile'} = '_subscribers';
    }
  }
  else {
    $args{'dbtype'} = 'registry';
    $args{'dbfile'} = '_register';
  }

  if ($buckets) {
    $args{'buckets'} = $buckets;
    $args{'bucket'}  = $bucket;
  }
  else {
    $args{'buckets'} = 0;
    $args{'bucket'}  = 0;
  }

  if ($regexp) {
    $args{'regexp'}  = $regexp;
  }
  else {
    $args{'regexp'}  = '';
  }

  Mj::Deliver::deliver(%args);
}

=head2 probe

Send a customized message to a group of people, one copy
per recipient.

=cut
use Mj::Deliver;
sub probe {
  my $self    = shift;
  my $list    = shift;
  my $sender  = shift;
  my $classes = shift;
  my $sublist = shift || 'MAIN';

  my %args =
    (
     backend => $self->{'backend'},
     bucket  => 0,
     buckets => 0,
     chunk   => $self->_global_config_get('chunksize'),
     classes => $classes,
     domain  => $self->{'domain'},
     lhost   => $self->_global_config_get('whereami'),
     list    => $list,
     listdir => $self->{'ldir'},
     manip   => 1,
     regexp  => 'ALL',
     rules   => $self->_list_config_get($list,'delivery_rules'),
     sender  => $sender,
     sendsep => $self->_site_config_get('mta_separator'),
    );

  if ($list ne 'GLOBAL' or ($sublist and $sublist ne 'MAIN')) {
    $args{'dbtype'} = 'sublist';
    if ($sublist and $sublist ne 'MAIN') {
      $args{'dbfile'} = "X$sublist";
    }
    else {
      $args{'dbfile'} = '_subscribers';
    }
  }
  else {
    $args{'dbtype'} = 'registry';
    $args{'dbfile'} = '_register';
  }

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
  $self->{'owner_fh'} = gensym();
  open ($self->{'owner_fh'}, ">$file") or
    $log->abort("Can't open $file, $!");
  (1, '');
}

sub owner_chunk {
  my ($self, $request, $data) = @_;
  print {$self->{'owner_fh'}} $data;
  (1, '');
}

use Mj::BounceHandler;
sub owner_done {
  my ($self, $request) = @_;
  $request->{'list'} ||= 'GLOBAL';
  my $log  = new Log::In 30, "$request->{'list'}";
  my (@owners, $badaddr, $handled, $sender, $type, $user);
  $badaddr = $type = $user = '';

  close ($self->{'owner_fh'})
    or $::log->abort("Unable to close file $self->{'owner_file'}: $!");
  $self->_make_list($request->{'list'});

  # Call bounce handling routine
  if (!$request->{'modes'}{'nobounce'}) {
    ($handled, $type, $user, $badaddr) =
      $self->handle_bounce($request->{'list'}, $self->{'owner_file'});
  }

  if (!$handled) {
    # Nothing from the bounce parser (or parser wasn't called)
    # Just mail out the file as if we never saw it
    if ($request->{'modes'}{'m'}) {
      # Forward to moderators instead of owners.
      @owners = $self->{'lists'}{$request->{'list'}}->moderators;
    }
    else {
      @owners  = @{$self->_list_config_get($request->{'list'}, 'owners')};
    }
    if ($request->{'list'} eq 'GLOBAL') {
      $sender = $owners[0];
    }
    else {
      $sender  = $self->_list_config_get('GLOBAL', 'sender');
    }
    $self->mail_message($sender, $self->{'owner_file'}, @owners);
  }

  unlink $self->{'owner_file'};
  undef $self->{'owner_fh'};
  undef $self->{'owner_file'};
  (1, $type, $user, $badaddr);
}


=head2 welcome(list, address, args)

This welcomes a subscriber to the list by sending them the messages
specified in the 'welcome_files' variable. If one of the files in the
welcome message does not exist, it is ignored.

It also is used to mail files to someone whose address has been added to
the global registry using the "register" command, and to someone whose
address has been removed from a list.

=cut
use Date::Format;
use MIME::Entity;
use Mj::Format;
sub welcome {
  my $self = shift;
  my $list = shift;
  my $addr = shift;
  my $table= shift;
  my %args = @_;
  my $log = new Log::In 150, "$list, $addr";
  my (%file, @mess, @temps, $count, $desc, $fh, $file, $final, $head, 
      $i, $j, $nodefsearch, $reg, $subj, $subs, $top);

  return unless (ref($addr) and $addr->isvalid);

  # Extract some necessary variables from the config files
  my $tmpdir    = $self->_global_config_get('tmpdir');
  my $sender    = $self->_list_config_get($list, 'sender');

  $subs = {
           $self->standard_subs($list),
           'STRIPADDR' => $addr->strip,
           'QSADDR'    => Mj::Format::qescape($addr->strip),
	   'USER'      => $addr,
	   'VICTIM'    => $addr,
	   %args,
	  };

  if (exists $args{'REGISTERED'} and $args{'REGISTERED'}) {
    $reg = 1;
  }
  else {
    $reg = 0;
  }

  # Loop over the table, processing parts and substituting values
  $count = 0;
  for($i = 0; $i < @{$table}; $i++) {
    # skip this file if the registration flags do not match.
    next if ($table->[$i][2] =~ /U/ and $reg);
    next if ($table->[$i][2] =~ /R/ and ! $reg);

    # Are we starting a new message?
    if ($i!=0 && $table->[$i][2] =~ /N/) {
      $count++;
    }
    $nodefsearch = 0;
    $nodefsearch = 1 if $table->[$i][2] =~ /E/;

    ($file, %file) = $self->_list_file_get(list        => $list,
					   file        => $table->[$i][1],
					   nodefsearch => $nodefsearch,
					  );
    # XXX Need to complain here
    next unless $file;

    if (defined $table->[$i][0] and length $table->[$i][0] 
        and lc $table->[$i][0] ne 'default') {
      $desc = $table->[$i][0];
    }
    else {
      $desc = $file{'description'};
    }

    $subj = $self->substitute_vars_string($desc, $subs);

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
    next unless (@{$mess[$i]{'ents'}} > 0);

    # If we have a single-part message...
    if (@{$mess[$i]{'ents'}} == 1) {
      $top = shift @{$mess[$i]{'ents'}};
    }
    else {
      $top = build MIME::Entity(
	Type     => 'multipart/mixed',
	Encoding => '8bit',
      );
      for $j (@{$mess[$i]{'ents'}}) {
	$top->add_part($j);
      }
    }
    $head = $top->head;
    $head->replace('To',      $addr);
    $head->replace('Subject', $mess[$i]{'subject'});
    $head->replace('From',    $sender);
    $head->replace('Date',    time2str("%a, %d %b %Y %T %z", time));

    for $j ($self->_global_config_get('message_headers')) {
      $j = $self->substitute_vars_string($j, $subs);
      $head->add(undef, $j);
    }

    $final = "$tmpdir/mj-tmp." . Majordomo::unique();
    $fh = gensym();
    open ($fh, ">$final") ||
      $::log->abort("Cannot open file $final, $!");
    $top->print($fh);
    close ($fh) or
      $::log->abort("Unable to close file $final: $!");
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

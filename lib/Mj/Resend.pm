=head1 NAME

Mj::Resend - filtering and transformation functions for Majordomo

=head1 SYNOPSIS

  $mj->post($request);

=head1 DESCRIPTION

This performs two important functions: filtering (including MIME
transformation), and delivery.  Incoming messages are filtered by checking
headers and body against various regular expressions.  Then the message is
decomposed into MIME parts and the various parts are transformed, decoded,
saved, and deleted according to a configuration table.  Messages which fail
the various filters are sent of for approval.  The transformed versions of
messages which pass are delivered to the various recipients who receive
each message.  The message is also passed on for archiving and
digestifying.

Order of operation:

 Pull in message, parse into MIME entities and header [1]
 Check for approval.
 Apply admin_headers, taboo_headers, and noarchive_headers.
 Apply admin_body to first n lines of first text part.
 Apply taboo_body to all text parts.  (What is a text part?)
 Find "illegal" MIME parts.
 *** Bounce now if necessary ***
 Strip out approvals to get the real article; parse it if necessary
 Make two copies of the entity
 Convert or drop MIME parts for list and archive/digest
 Deposit in archive.
 Strip unwanted headers from list, archive/digest.
 Add headers, fronter and footer [3] to outgoing copy.
 Compose final message.
 Pass to digest.
 Deliver.

1. MIME parsing automatically handles QP and base64 decoding (and
   some other weird ones, like x-gzip64).

2. There are six supported approval methods.  Briefly:
     Approved: in the header
     Single-part messages:
       Approved: as first non-blank line of the body, followed by a
         blank line and the body.
       Approved: as first non-blank line of the body, followed by a
         complete message including headers and body.
     Multipart messages:
       Approved: as first non-blank line of the preamble.
       Approved: as first non-blank of first body part.
       Approved: as first non-blank line of the first body part of a
         multipart message with exactly two parts, the second of which
         is of ty0e message/rfc822 and contains the complete message
         to be sent to the list.
   There is also the post command, which allows out-of-band approval,
   and the normal token-based approval method.

3. Fronter and footer get separate MIME parts when configured to do so, and
   always for Multipart messages.  This is to prevent non-MIME messages
   from being gratuitously turned into MIME messages.  Non-MIME messages
   will not generally be hurt by adding fronters and footers right into the
   body, but this should be configurable.  The mangling of true MIME
   messages should not be allowed to occur.

Note that the bodyhandles get opened and closed and things are copied
more than once in some cases.  This is inefficient, but is also
conceptually easy to deal with and relatively easy to maintain and
extend.  Eventually this should all be restructured to recurse down
the MIME tree once, doing what ever is required, and to open the body
exactly once, doing all the copying and checksumming that is required.

=cut

package Mj::Resend;
use Mj::Log;
use strict;

use vars qw($line $text $type);

use AutoLoader 'AUTOLOAD';
1;
__END__

use Date::Format;
use Mj::MIMEParser;
use IO::File;
use File::Copy 'mv';
sub post {
  my ($self, $request) = @_;
  my ($ack_attach, $approved, $avars, $c_t_encoding, $c_type, $desc,
      $ent, $fh, $fileinfo, $head, $i, $list, $mess, $nent, $ok, $owner,
      $parser, $passwd, $reasons, $sender, $spool, $subject, $subs,
      $thead, $tmp, $tmpdir, $token, $user);
  my $log = new Log::In 30, 
       "$request->{'list'}, $request->{'user'}, $request->{'file'}";
  $tmpdir = $self->_global_config_get("tmpdir");

  $parser = new Mj::MIMEParser;
  $parser->output_to_core($self->_global_config_get("max_in_core"));
  $parser->output_dir($tmpdir);
  $parser->output_prefix("mjr");

  $fh = new IO::File "<$request->{'file'}";
  $ent = $parser->read($fh);
  # If perl is configured without Config{'d_flock'}, this close call
  # will cause the lock on the queue file to be dropped, creating
  # a race condition.  Do not call close() explicitly.
  # $fh->close;

  # Fail gracefully if the message cannot be parsed
  if (! $ent) {
    $spool = "$tmpdir/unparsed." . Majordomo::unique();
    mv ($request->{'file'}, $spool);
    $mess = $self->format_error('invalid_entity', $request->{'list'});
    $self->inform('GLOBAL', 'post', $request->{'user'}, $request->{'user'},
        $request->{'cmdline'}, $self->{'interface'}, 0, 0, -1, $mess, 
        $::log->elapsed);
    return (0, $mess);
  }

  # Get the header.
  $::log->in(80, undef, "info", "Parsing the header");
  $head = $ent->head;
  $head->modify(0);

  # Make a copy that we can mess with.
  $thead = $head->dup;
  $thead->decode;
  $thead->unfold;
  $::log->out;
  $reasons = []; 
  $avars = { 
             'taboo'    => 0,
             'admin'    => 0,
           };
  $user =  $head->get('from') ||
        $head->get('apparently-from') || 'unknown@anonymous';
  chomp $user;
  $user = new Mj::Addr($user);

  if (!(defined $user and ref $user)) {
    $avars->{'invalid_from'} = 1;
    push @$reasons, 
      $self->format_error('undefined_address', $request->{'list'});
  }
  else {
    ($ok, $mess, $desc) = $user->valid;
    unless ($ok) {
      $avars->{'invalid_from'} = 1;
      $tmp = $self->format_error($mess, 'GLOBAL');
      chomp $tmp if (defined $tmp);
      push @$reasons, 
        $self->format_error('invalid_address', $request->{'list'}, 
                            'ADDRESS' => "$user", 'ERROR' => $tmp,
                            'LOCATION' => $desc);
    }
  }

  # XXX Pass in the password we were called with, so that passwords
  # can be passed out-of-band.
  ($ok, $passwd, $token) =
    $self->_check_approval($request->{'list'}, $thead, $ent, $user);
  $approved = $ok && ($ok > 0) && $passwd;
  if ($ok) {
    $request->{'password'} = $passwd;
  }
  else {
    $request->{'password'} = '';
  }

  $avars->{bad_approval} = 0;
  unless ($ok) {
    $avars->{bad_approval} = 1;
    push (@$reasons, $passwd) if (defined $passwd and length $passwd);
  }

  # Check poster
  $self->_check_poster($request->{'list'}, $user, $reasons, $avars);

  # Check header
  $self->_check_header($request->{'list'}, $ent, $reasons, $avars);

  # Recursively check bodies
  $self->_check_body($request->{'list'}, $ent, $reasons, $avars);

  # Construct some aggregate variables;
  $avars->{dup} = $avars->{dup_msg_id} || $avars->{dup_checksum} ||
    $avars->{dup_partial_checksum} || '';
  $avars->{mime} = $avars->{mime_consult} || $avars->{mime_deny} || '';

  $avars->{any} = $avars->{dup} || $avars->{mime} || $avars->{taboo} ||
    $avars->{admin} || $avars->{bad_approval} || $avars->{post_block} ||
    $avars->{body_length_exceeded} || $avars->{invalid_from} ||
    $avars->{mime_header_length_exceeded} || $avars->{limit} ||
    $avars->{total_header_length_exceeded} || 
    $avars->{max_header_length_exceeded} || '';

  $avars->{'sublist'} = $request->{'sublist'} || '';
  $avars->{'time'} = time;

  # Bounce if necessary: concatenate all possible reasons with \003, call
  # access_check with filename as arg1 and reasons as arg2.  Victim
  # here is the user in the headers; requester is  the user
  # making the request.  We should only regenerate user if it is not set.
  # This adds a modicum of security to the post command.
  if ($approved) {
    $ok = 1;
  }
  else {
    # Move the message into a spool file to prevent it being
    # reprocessed.  Make sure the file doesn't already exist.
    while (1) {
      $spool = $self->t_gen;
      last unless -f "$self->{ldir}/GLOBAL/spool/$spool";
    }
    mv($request->{'file'}, "$self->{'ldir'}/GLOBAL/spool/$spool")
      || $::log->abort("Unable to create spool file: $!");
    $request->{'file'} = "$self->{'ldir'}/GLOBAL/spool/$spool";
    chomp @$reasons;

    # Untaint
    for ($i = 0; $i < @$reasons; $i++) {
      # The reasons may contain newline characters
      $reasons->[$i] =~ /(.*)/s; $reasons->[$i] = $1;
    }

    $avars->{'reasons'} = join("\003", @$reasons);
    $request->{'vars'} = join("\002", %$avars);
    $request->{'victim'} = $user;

    ($ok, $mess, $fileinfo) =
      $self->list_access_check($request, %$avars);
  }

  if ($ok > 0) {
    return $self->_post($request->{'list'}, $user, $user, $request->{'mode'},
            $request->{'cmdline'}, $request->{'file'}, '',
            join("\002", %$avars), $ent);
  }

  # We handled the OK case, so we have either a stall or a denial.
  # If we got an empty return message, this is a signal not to ack anything
  # and so we just return;
  unless (defined $mess and length $mess and $mess ne 'NONE') {
    # Unlink the spool file if the post was denied.
    unlink $request->{'file'} unless $ok; 
    unlink @{$self->{'post_temps'}} if $self->{'post_temps'};
    undef $self->{'post_temps'};
    return ($ok, '');
  }

  chomp($subject = ($thead->get('subject') || '(none)')); 
  $list = $request->{'list'};
  if ($request->{'sublist'}) {
    $list .= ":" . $request->{'sublist'};
  }

  # Some substitutions will be done by the access routine, but we have
  # extensive information about the message here so we can do some more.
  $subs = {
           $self->standard_subs($list),
           CMDLINE  => "(post to $list)",
	   HEADERS  => $ent->head->stringify,
	   SUBJECT  => $subject || '(no subject)',
           USER     => "$user",
	  };

  if (exists $fileinfo->{description}) {
    $desc = $self->substitute_vars_string($fileinfo->{description}, $subs);
  }
  elsif ($ok == 0) {
    $desc = $self->format_error('denied_post', $list);
  }
  else {
    $desc = $self->format_error('stalled_post', $list);
  }

  $ack_attach = 
    $self->_list_config_get($request->{'list'}, 'ack_attach_original');
  $sender = $self->_list_config_get($request->{'list'}, 'sender');
  $owner = $self->_list_config_get($request->{'list'}, 'whoami_owner');

  # Otherwise, decide what to ack, based on the user's flags
  # and the ack_important setting.
  if ($self->{'lists'}{$request->{'list'}}->should_ack($request->{'sublist'},
                         $user, $ok ? 'b' : 'd')) {
      $nent = build MIME::Entity
	(
	 Data        => [ $mess ],
	 Type        => $fileinfo->{'c-type'},
	 Encoding    => $fileinfo->{'c-t-encoding'},
	 Charset     => $fileinfo->{'charset'},
	 Filename    => undef,
         -Date       => time2str("%a, %d %b %Y %T %z", time),
	 -From       => $owner,
	 -To         => "$user", # Note stringification
	 -Subject    => $desc,
	 'Content-Language:' => $fileinfo->{'language'},
	);

      if (($ok <  0 && $ack_attach->{stall}) ||
	  ($ok == 0 && $ack_attach->{fail})  ||
	  ($ok <= 0 && $ack_attach->{all}))
      {
        $nent->make_multipart;
        $nent->attach(Type        => 'message/rfc822',
                      Encoding    => '8bit',
                      Description => 'Original message',
                      Path        => $request->{'file'},
                      Filename    => undef,
                     );
      }
      $self->mail_entity($sender, $nent, $user);
  }

  # If the request failed, we need to unlink the file.
  if (!$ok) {
    unlink $request->{'file'};
  }
  unlink @{$self->{'post_temps'}} if $self->{'post_temps'};
  undef $self->{'post_temps'};

  # Purging will unlink the spool file.
  # $nent->purge if $nent;

  # Clean up after ourselves;
  $ent->purge;
  ($ok, $mess);
}

=head2 post_start, post_chunk, post_done

These provide an iterative interface to the post function, so that it can
be used from the command interfaces and from a network source.

There is no access checking here, because that happens once the
to-be-posted message is parsed.  It may be useful to place some
restrictions here, because it makes forging messages even more trivial,
since the message doesn''t actually have to pass through the mail system.
Hmmm.

=cut
use IO::File;
sub post_start  {
  my ($self, $request) = @_;
  my $log  = new Log::In 30, $request->{'list'};

  my $tmp  = $self->_global_config_get('tmpdir');
  my (@sl, $aliases, $head);
  my $file = "$tmp/post." . Majordomo::unique();
  $self->{'post_file'} = $file;
  $self->{'post_fh'} = new IO::File ">$file" or
    $log->abort("Can't open $file, $!");

  if ($request->{'mode'} =~ /addhdr/) {
    $head = $self->_add_headers($request);
    return (0, $self->format_error('add_headers', $request->{'list'}))
      unless $head;
    $self->{'post_fh'}->print($head->as_string);
    $self->{'post_fh'}->print("\n");
  }  

  if ($request->{'sublist'} and $request->{'sublist'} ne 'MAIN') {
    $aliases = $self->_list_config_get($request->{'list'}, 'aliases');
    unless (ref $aliases and exists $aliases->{'auxiliary'}) {
      return (0, $self->format_error('sublist_post',
              "$request->{'list'}:$request->{'sublist'}"));
    }
    @sl = $self->_list_config_get($request->{'list'}, 'sublists');
    unless (grep { $_ eq $request->{'sublist'} } @sl) {
      return (0, $self->format_error('sublist_post',
              "$request->{'list'}:$request->{'sublist'}"));
    }
  }

  (1, '');
}
use Date::Format;
use MIME::Head;
use Digest::SHA1 qw(sha1_hex);
sub _add_headers {
  my ($self, $request) = @_;
  my $log  = new Log::In 30, $request->{'list'};
  my $head = new MIME::Head;
  my ($tmp);

  return unless $head;

  # Create headers based upon the request data.
  # XXX Charset should be chosen more judiciously. 
  # text/html and other types should be accommodated.
  # Language choice should be configurable.

  $head->add('From', "$request->{'user'}");

  if (! $request->{'sublist'} or $request->{'sublist'} eq 'MAIN') {
    $tmp = $self->_list_config_get($request->{'list'}, 'whoami');
    $head->add('To', $tmp);
  }
  else {
    $tmp = "$request->{'list'}-$request->{'sublist'}\@" .
            $self->_list_config_get($request->{'list'}, 'whereami');
    $head->add('To', $tmp);
  }
    
  $head->add('Subject', $request->{'subject'} || '(no subject)');

  # Add the Date header
  $tmp = time2str("%a, %d %b %Y %T %z", time);
  $head->add('Date', $tmp);

  $tmp = sha1_hex($head->as_string . rand(9));
  $tmp = '<' . $tmp . '@' . 
         $self->_global_config_get('whereami') . '>';
  $head->add('Message-ID', $tmp);
  $head->add('MIME-Version', '1.0');
  $head->add('Content-Type', 'text/plain; charset=iso-8859-1');
  $head->add('Content-Disposition', 'inline');
  $head->add('Content-Transfer-Encoding', '8bit');

  return $head;
}

sub post_chunk {
  my ($self, $request, $data) = @_;
  $self->{'post_fh'}->print($data);
  (1, '');
}

sub post_done {
  my ($self, $request) = @_;
  my $log  = new Log::In 30;
  my ($ok, $mess);

  $self->{'post_fh'}->close()
    or $::log->abort("Unable to close post file: $!");

  $request->{'file'} = $self->{'post_file'};

  ($ok, $mess) =
    $self->post($request);

  unlink $self->{'post_file'};
  undef $self->{'post_fh'};
  undef $self->{'post_file'};

  ($ok, $mess);
}

use Date::Format;
use Mj::MIMEParser;
use Mj::Util qw(gen_pw);
use Symbol;
sub _post {
  my($self, $list, $user, $victim, $mode, $cmdline, $file, $arg2,
     $avars, $ent) = @_;
  my $log  = new Log::In 35, "$list, $user, $file";

  my(%ackinfo, %avars, %deliveries, %digest, @changes, @dfiles, @dtypes,
     @dup, @ent, @files, @refs, @tmp, @skip, $ack_attach, $ackfile,
     $arcdata, $arcdate, $arcent, $archead, $date, $desc, $digests,
     $dissues, $dup, $exclude, $from, $head, $hidden, $i, $j, $k, 
     $members, $mess, $msgid, $msgnum, $nent, $nonmembers, $parser,
     $precedence, $prefix, $rand, $replyto, $sender, $seqno, $subject, 
     $sl, $subs, $tmp, $tmpdir, $tprefix, $whereami);

  return (0, $self->format_error('make_list', 'GLOBAL', 'LIST' => $list))
    unless $self->_make_list($list);
  $tmpdir   = $self->_global_config_get('tmpdir');
  $whereami = $self->_global_config_get('whereami');
  $sender   = $self->_list_config_get($list, "sender");

  %avars = split("\002", $avars);
  # Is the message being sent to a sublist?
  if ($avars{'sublist'} ne '') {
    unless ($sl = $self->{'lists'}{$list}->valid_aux($avars{'sublist'})) {
      $mess = $self->format_error('invalid_sublist', $list, 'SUBLIST' =>
                                  $avars{'sublist'});
      $self->inform($list, "post", $user, $victim, $cmdline, 
                    $self->{'interface'}, 0, 0, -1, $mess, 
                    $::log->elapsed);
      return (0, $mess);
    }
  }
  else { $sl = ''; }

  $self->{'body_changed'} = 0;

  # Issue a warning if any of the avars data are tainted.
  for $i (keys %avars) {
    if (Majordomo::is_tainted($avars{$i})) {
      warn "Mj::Resend::_post: The $i variable is tainted.";
    }
  }

  # $sl now holds the untainted sublist name.
  if (!$sl and $mode !~ /archive/) {
    # Atomically update the sequence number
    $self->_list_config_lock($list);
    $seqno  = $self->_list_config_get($list, 'sequence_number');
    $self->_list_config_set($list, 'sequence_number', $seqno+1);
    $self->_list_config_unlock($list);
    $log->message(35,'info',"Sending message $seqno");
    print {$self->{sessionfh}} "Post: sequence #$seqno.\n";
  }
  else {
    $log->message(35,'info',"Sending message to $sl");
    print {$self->{sessionfh}} "Post: auxiliary list $sl.\n";
    $seqno = 0;
  }

  # trick: we take a pre-parsed entity as an extra argument; if it's
  # defined, we can skip the parse step.  Note that after this, $file will
  # refer to the source message file regardless of whether it was spooled
  # or not.
  if ($ent) {
    $ent[0] = $ent;
  }
  else {
    $k = gensym();
    unless (open $k,  "<$file") {
      # The spool file, containing the message to be posted, is missing.
      # Inform the site owner, and return.
      $mess = $self->format_error('spool_file', $list);
      $self->inform("GLOBAL", "post", $user, $victim, $cmdline, 
                    $self->{'interface'}, 0, 0, -1, $mess, $::log->elapsed);
      return (0, $mess);
    }
    $parser = new Mj::MIMEParser;
    $parser->output_to_core($self->_global_config_get("max_in_core"));
    $parser->output_dir($tmpdir);
    $parser->output_prefix("mjr");
    $ent[0] = $parser->read($k);
  }

  # Trim off approvals, get back a new entity
  $ent[0] = $self->_trim_approved($ent[0]);
  $head = $ent[0]->head;
  $head->modify(0);

  # Convert/drop MIME parts.  
  $i = $self->_list_config_get($list, 'attachment_filters');
  if (exists $i->{'change_code'} and $mode !~ /intact/) {
    @changes = $self->_r_strip_body($list, $ent[0], $i->{'change_code'}, 1);
    $ent[0]->sync_headers;
    $head = $ent[0]->head;
    $head->modify(0);
    for $i (@changes) {
      if ($i->[1] eq 'format') {
        $head->add('X-Content-Reformatted', "$i->[0]");
      }
      elsif ($i->[1] eq 'discard') {
        $head->add('X-Content-Discarded', "$i->[0]");
      }
      elsif ($i->[1] eq 'clean') {
        $head->add('X-Content-Cleaned', "$i->[0]");
      }
    }
  }
 
  # Generate the exclude and membership lists
  # before the headers have been altered.
  if ($mode !~ /archive/) { 
    ($exclude, $members, $nonmembers) = 
      $self->_exclude($ent[0], $list, $sl, $user);
  }

  # Remove skippable headers, including Approved:.
  @skip = ('Approved');
  push @skip, $self->_list_config_get($list, 'delete_headers');
  push @skip, 'Received' if $self->_list_config_get($list, 'purge_received');
  for $i (@skip) {
    $head->delete($i);
  }

  # Rewrite the From: header
  $self->_munge_from($ent[0], $list);

  # Make duplicate archive/digest entity
  $arcent = $ent[0]->dup;
  $archead = $arcent->head;
  $archead->modify(0);

  while (1) {
    $rand = gen_pw(6);
    last unless (-f "$tmpdir/mjr.$$.$rand.arc");
  }

  # Pass to archiver; first extract all references
  $tmp = $archead->get('references') || '';
  while ($tmp =~ s/<([^>]*)>//) {
    push @refs, $1;
  }
  $tmp = $archead->get('in-reply-to') || '';
  while ($tmp =~ s/<([^>]*)>//) {
    push @refs, $1;
  }

  # Strip the subject prefix from the archive copy.  Note that this
  # function can have odd side effects because it plays with the entities,
  # so we re-extract $archead at this point.
  (undef, $arcent) = $self->_munge_subject($arcent, $list, $seqno);
  $archead = $arcent->head;

  # Collect information from the message, then store
  # it in the archive.
  $from = $archead->get('from') || $archead->get('apparently-from')
            || 'unknown@anonymous';  chomp $from;
  $from =~ /(.*)/s; $from = $1;
  $subject = $archead->get('subject') || ''; chomp $subject;
  $subject =~ /(.*)/s; $subject = $1;
  $msgid = $archead->get('message-id') || ''; chomp $msgid;
  $msgid =~ s/<([^>]*)>//; $msgid = $1;
  $date = $archead->get('date') || scalar localtime; chomp $date;
  $date =~ /(.*)/s; $date = $1;
  $arcdate = $self->_list_config_get($list, 'archive_date');
  if ($arcdate eq 'arrival') {
    $arcdate = $avars{'time'};
    # Untaint
    if ($arcdate =~ /^(\d+)$/) {
      $arcdate = $1;
    }
    else {
      $arcdate = time;
    }
  }
  else {
    $arcdate = time;
  }

  $hidden = 0;
  if ($mode =~ /hide/
      or (defined($avars{noarchive}) and 
          ($avars{noarchive} > 0 or $avars{noarchive} =~ /\D/))
      or $self->{'lists'}{$list}->flag_set('hidepost', $user, $sl)
      ) 
  {
    $hidden = 1;
  }

  ($msgnum) = $self->{'lists'}{$list}->archive_add_start
    ($sender,
     {
      'body_lines' => $avars{lines},
      'bytes'      => (stat($file))[7],
      'date'       => $arcdate,
      'from'       => $from,
      'hidden'     => $hidden,
      'msgid'      => $msgid,
      'quoted'     => $avars{quoted_lines},
      'refs'       => join("\002", @refs),
      'subject'    => $subject,
      'sublist'    => $sl,
     },
    );

  # Only call this if we got back a message number because there isn't an
  # archive around if we didn't.
  if ($msgnum) {
    $archead->replace('X-Archive-Number', $msgnum);
    $archead->replace('X-Sequence-Number', $seqno) 
      unless ($sl or $mode =~ /archive/);
    $archead->replace('X-No-Archive', 'yes')
      if $hidden;

    # Print out the archive copy
    $tmp = "$tmpdir/mjr.$$.$rand.arc";
    $k = gensym();
    open ($k, ">$tmp") or
      $::log->abort("Cannot open archive output file:  $!");

    if ($self->{'body_changed'}) {
      $arcent->print($k);
    }
    else {
      $j = gensym();
      unless (open $j,  "<$file") {
        $mess = $self->format_error('spool_file', $list);
        $self->inform("GLOBAL", "post", $user, $victim, $cmdline, 
                      $self->{'interface'}, 0, 0, -1, $mess, $::log->elapsed);
        return (0, $mess);
      }
      $i = new Mail::Internet $j;
      $::log->abort("Cannot parse spool file.") unless $i;
      $arcent->head->print($k);
      print $k "\n";
      $i->print_body($k);
    }
    close ($k) 
      or $::log->abort("Unable to close file $tmp: $!");

    ($msgnum, $arcdata) = $self->{'lists'}{$list}->archive_add_done($tmp);

    unlink $tmp;
  }

  # Cook up a substitution hash
  $subs = {
         $self->standard_subs($list),
         'DATE'       => $date,
         'HOST'       => $self->_list_config_get($list, 'resend_host'),
         'MSGNO'      => $msgnum,
         'SENDER'     => "$user",
         'SEQNO'      => $seqno,
         'SUBJECT'    => $subject || '(no subject)',
         'SUBSCRIBED' => ($avars{'days_since_subscribe'} < 0) ? "not" : "",
         'USER'       => "$user",
  };

  if ($mode !~ /archive/) {
    # Update post data
    $self->{'lists'}{$list}->post_add($user, time, 'F', $seqno);
    # Add headers
    for $i ($self->_list_config_get($list, 'message_headers')) {
      $i = $self->substitute_vars_string($i, $subs);
      $head->add(undef, $i) if ($i =~ /^[^\x00-\x1f\x7f-\xff :]+:/);
    }

    $head->replace('X-No-Archive', 'yes')
      if $hidden;

    # Add list-headers standard headers
    if ($precedence = $self->_list_config_get($list, 'precedence')) {
      $head->add('Precedence', $precedence);
    }

    if ($sender) {
      $head->add('Sender', $sender);
    }

    $subs->{'USER'} = $head->get('From');

    # Add fronter and footer.
    $self->_add_fters($ent[0], $list, $subs);

    # Add in subject prefix
    ($ent[0], $ent[1]) = $self->_munge_subject($ent[0], $list, $seqno);

    # Add in Reply-To:
    $ent[2] = $self->_reply_to($ent[0]->dup, $list, $seqno, $user, $nonmembers);
    $ent[3] = $self->_reply_to($ent[1]->dup, $list, $seqno, $user, $nonmembers);

    if ($i = $self->_list_config_get($list, 'reply_to')) {
      $i = $self->substitute_vars_string($i, $subs);
    }

    # Obtain list of lists to check for duplicates.
    $dup = {};
    if ($self->_global_config_get('dup_lifetime') and !$sl) {
      my (%seen, @tmp, $msgid);
      chomp($msgid = $head->get('Message-ID') || '(none)');

      # update the global duplicate databases, obtaining previous data
      # for this message-id and checksum.  
      $i = $self->{'lists'}{'GLOBAL'}->check_dup($msgid, 'id', $list);
      if ($i and exists $i->{'lists'} and $msgid ne '(none)') {
        @tmp = split ("\002", $i->{'lists'});
      }

      $i = $self->{'lists'}{'GLOBAL'}->check_dup($avars{'checksum'}, 'sum', $list);
      # Do not check for duplicates of a message with an empty body.
      if ($i and exists ($i->{'lists'}) and $avars{'body_length'} > 0) {
        push @tmp, split ("\002", $i->{'lists'});
      }

      # remove duplicate lists
      @seen{@tmp} = ();
      @tmp = grep { $_ ne $list } keys %seen;  
      @dup = ();
 
      # initialize the other lists.
      for (@tmp) {
        next unless $self->_make_list($_);
        push @dup, $self->{'lists'}{$_}->{'sublists'}{'MAIN'};
      }
      $dup = $self->_find_dup($self->{'lists'}{$list}->{'sublists'}{'MAIN'}, @dup)
        if scalar @dup;
    }

    # Incorporate the exclude list into the duplicate list.
    $dup = { %$exclude, %$dup };

    # Print delivery messages to files
    for ($i = 0; $i < @ent; $i++) {
      $files[$i] = "$tmpdir/mjr.$$.$rand.final$i";
      $k = gensym();
      open ($k, ">$files[$i]") or
        $::log->abort("Couldn't open final output file, $!");
      if ($self->{'body_changed'}) {
        $ent[$i]->print($k);
      }
      else {
        $j = gensym();
        unless (open $j,  "<$file") {
          $mess = $self->format_error('spool_file', $list);
          $self->inform("GLOBAL", "post", $user, $victim, $cmdline, 
                        $self->{'interface'}, 0, 0, -1, $mess, $::log->elapsed);
          return (0, $mess);
        }
        $tmp = new Mail::Internet $j;
        $::log->abort("Cannot parse spool file.") unless $tmp;
        $ent[$i]->head->print($k);
        print $k "\n";
        $tmp->print_body($k);
      }
      close ($k)
        or $::log->abort("Unable to close file $files[$i]: $!");
    }

    $seqno = 'M' . $seqno;
    # These are the deliveries we always make.  If pushing digests, we'll add
    # those later.
    %deliveries =
      (
       'each-prefix-noreplyto' =>
       {
        exclude => $exclude,
        file    => $files[0],
        seqnum  => $seqno,
       },
       'each-noprefix-noreplyto' =>
       {
        exclude => $exclude,
        file    => $files[1],
        seqnum  => $seqno,
       },
       'each-prefix-replyto' =>
       {
        exclude => $exclude,
        file    => $files[2],
        seqnum  => $seqno,
       },
       'each-noprefix-replyto' =>
       {
        exclude => $exclude,
        file    => $files[3],
        seqnum  => $seqno,
       },
       'unique-prefix-noreplyto' =>
       {
        exclude => $dup,
        file    => $files[0],
        seqnum  => $seqno,
       },
       'unique-noprefix-noreplyto' =>
       {
        exclude => $dup,
        file    => $files[1],
        seqnum  => $seqno,
       },
       'unique-prefix-replyto' =>
       {
        exclude => $dup,
        file    => $files[2],
        seqnum  => $seqno,
       },
       'unique-noprefix-replyto' =>
       {
        exclude => $dup,
        file    => $files[3],
        seqnum  => $seqno,
       }
      );

    # Build digests if we have a message number from the archives
    # (%deliveries is modified)
    if ($msgnum and !$sl) {
      $self->do_digests(
                        'arcdata'    => $arcdata,  
                        'deliveries' => \%deliveries,
                        'list'       => $list,     
                        'msgnum'     => $msgnum,
                        'sender'     => $subs->{'OWNER'},
                        'substitute' => $subs,     
                        'tmpdir'     => $tmpdir,
                        'whereami'   => $whereami, 
                        # 'run' => 0, 'force' => 0,
                       );
    }

    # Invoke delivery routine
    $self->deliver($list, $sl, $sender, \%deliveries);

    # Clean up and say goodbye
    for $i (keys %deliveries) {
      unlink $deliveries{$i}{file}
        if $deliveries{$i}{file};
    }
  } # not archive mode

  if ($self->{'lists'}{$list}->should_ack($sl, $user, 'f')) {
    ($ackfile, %ackinfo) = 
      $self->_list_file_get(list => $list,
                            file => ($mode =~ /archive/)? 'ack_archive' : 'ack_success',
                            subs => $subs,
			   );
    if ($ackfile) {
      $desc = $self->substitute_vars_string($ackinfo{'description'}, $subs);
      $ack_attach = $self->_list_config_get($list, 'ack_attach_original');

      $nent = build MIME::Entity
	(
	 Path        => $ackfile,
	 Type        => $ackinfo{'c-type'},
	 Encoding    => $ackinfo{'c-t-encoding'},
	 Charset     => $ackinfo{'charset'},
	 Filename    => undef,
         -Date       => time2str("%a, %d %b %Y %T %z", time),
	 -From       => $sender,
	 -To         => "$user", # Note stringification
	 -Subject    => $desc,
	 'Content-Language:' => $ackinfo{'language'},
	);

      if ($nent) {
        if ($ack_attach->{succeed} || $ack_attach->{all})
        {
          $nent->make_multipart;
          $nent->attach(Type        => 'message/rfc822',
                        Encoding    => '8bit',
                        Description => 'Original message',
                        Path        => $file,
                        Filename    => undef,
                       );
        }
        $self->mail_entity($sender, $nent, $user);
      }
      unlink $ackfile;
    } 
  } # should_ack
  for ($i = 0; $i < @ent; $i++) {
    $ent[$i]->purge;
  }
  $arcent->purge if $arcent;

  # We're done with the file by this point, so we should remove it.
  # This step must be done last: if _post is called by Mj::Token::t_accept,
  # and the program aborts between the deletion of the file
  # and the removal of the token, we will have a request in the
  # queue for a token with no associated spool file.
  unlink $file;
  delete $self->{'body_changed'};

  (1, '');
}

=head2 _check_approval(list, head, entity, user)

This takes a ref to a MIME::Entity and checks to see if it is approved by
one of several methods:

  In header
  First line of preamble
  First line of first part
  First line of body
  First line of first part followed by a message/rfc822 attachment.

Head should be a copy of the message header, already decoded and unfolded.

Return flag, password, token.

The password is validated and the token unspooled if they are given.

Note that this routine doesn''t do any processing on the message;
specifically, it does not remove any Approved: lines or extract any
embedded messages.  This is done in the bottom half of the post
function.

=cut
use Mj::Token;
sub _check_approval {
  my $self = shift;
  my $list = shift;
  my $head = shift;
  my $ent  = shift;
  my $user = shift;
  my $log  = new Log::In 40;
  my ($body, $data, $fh, $i, $lang, $line, $mess, $ok, $part, $passwd, 
      $pre, $sender, $time, $token);

  $pre = $ent->preamble;

  # Approved: header; the header will be deleted later, but we leave
  # it in because if it's wrong we want to bounce with it in.
  if ($head->count('approved')) {
    $line = $head->get('approved');
    chomp $line;
    ($passwd, $token) = split('\s*,\s*', $line);
  }

  # Check that we have a preamble and that it contains something that
  # looks like Approved: password, token in the first few lines
  elsif ($pre) {
    for $i (0..3) {
      if ($$pre[$i] && $$pre[$i] =~ /Approved:\s*([^\s,]+)\s*,?\s*(.*)\s*/i) {
	($passwd, $token) = ($1, $2);
	last;
      }
    }
  }

  # Check in the body
  unless ($passwd) {
    # If multipart, grab first part.  Cope with nested multipart messages.
    $part = $ent;
    while (defined $part->parts(0)) {
      last if $part->bodyhandle;
      $part = $part->parts(0);
    }

    return (0, $self->format_error('no_body', $list))
      unless $part->bodyhandle;
    # Check in first few of lines of that entity; skip blank lines but
    # stop as soon as we see any text
    $fh = $part->bodyhandle->open('r');
    return (0, $self->format_error('no_body', $list))
      unless $fh;
    while (defined ($line = $fh->getline)) {
      last if $line =~ /\S/;
    }
    if (defined($line) && $line =~ /Approved:\s*([^\s,]+)\s*,?\s*(\S*)\s*/i) {
      ($passwd, $token) = ($1, $2);
      # Make sure the next line is blank or a header.
      $line = $fh->getline;
      if (defined $line and $line =~ /\S/) {
        return (0, $self->format_error('replacement_header', $list))
          unless ($line =~ /^[^\x00-\x1f\x7f-\xff :]+:/ 
                  or $line =~ /^>?From /);
      }
    }
  }

  # Now check validity of the password and existance of the token if
  # provided; unspool the token if it exists.  (If it doesn't, just
  # ignore it.  The password must be good, though.)
  if ($passwd) {
    return (0, $self->format_error('invalid_approval', $list))
      unless $self->validate_passwd($user, $passwd, $list, 'post') > 0;
  }

  if ($token = $self->t_recognize($token)) {
    $time = $::log->elapsed;
    ($ok, $data) = $self->t_reject($token);
    if ($ok) {
      $lang = $self->_list_config_get($list, 'default_language');
      $mess = $self->_list_file_get_string('list' => $list, 
                                           'file' => 'approved_reject',
                                           'lang' => $lang);
      $self->inform('GLOBAL', 'reject', $user, $data->{'user'}, 
                    "reject $token", $self->{'interface'}, $ok, 
                    0, 0, $mess, $::log->elapsed - $time);
      # No notice is sent to the list owners.
    }
    else {
      $token = undef;
    }
  }

  return (1, $passwd, $token);
}

=head2 _check_poster(list, user, reasons, avars)

This computes various pieces of data about the poster:

  days since the user subscribed
  whether a hard or soft posted message limit has been reached
  whether the user has the moderate or nopost flags set

=cut
use Mj::Util qw(re_match);
sub _check_poster {
  my $self    = shift;
  my $list    = shift;
  my $user    = shift; # Already in an Mj::Addr object
  my $reasons = shift;
  my $avars   = shift;
  my $log     = new Log::In 40, "$user";
  my ($data, $i, $mess, $ok, $pstats, $rules);

  # Grab the list data
  $data = $self->{'lists'}{$list}->is_subscriber($user);

  # Extract subscribe date
  if ($data) {
    $avars->{days_since_subscribe}
      = (time - $data->{subtime})/86400;
  }
  else {
    $avars->{days_since_subscribe} = -1;
  }

  # Extract flags
  $avars->{post_block} = $avars->{hide_post} = '';
  $avars->{post_block} = $self->{lists}{$list}->flag_set('postblock', $user);

  if ($avars->{post_block}) {
    push @$reasons, 
      $self->format_error('post_block', $list, 'USER' => "$user");
  }

  $avars->{hide_post} = $self->{lists}{$list}->flag_set('hidepost', $user);
  $avars->{limit} = 0;
  $avars->{limit_soft} = 0;
  $avars->{limit_hard} = 0;

  # Obtain posting statistics for this address and add them to the access
  # variables
  $data = $self->{'lists'}{$list}->get_post_data($user);

  $pstats = $self->{'lists'}{$list}->post_gen_stats($data);
  for $i (keys %{$pstats}) {
    $avars->{$i} = $pstats->{$i};
  }

  return unless $data;

  $rules = $self->_list_config_get($list, 'post_limits');

  # Check post_limits rules in turn and determine if a hard
  # or soft limit has been reached.  Stop after the first
  # rule whose pattern matches the address.
  for ($i = 0 ; $i <= $#$rules ; $i++) {
    if (re_match($rules->[$i]->{'pattern'}, $user->canon)) {
      ($ok, $mess) = 
        $self->_within_limits($list, $data, 
                              $rules->[$i]->{'soft'},
                              $rules->[$i]->{'hard'}, 
                              $rules->[$i]->{'lower'});
      if ($ok) {
        $avars->{limit} = 1;
        $avars->{limit_hard}  = 1 if ($ok & 1);
        $avars->{limit_soft}  = 1 if ($ok & 2);
        $avars->{limit_lower} = 1 if ($ok & 4);
        push (@$reasons, @$mess) if (ref $mess eq 'ARRAY');
      }
      last;
    }
  }
}

=head2 _within_limits(list, data, soft, hard, lower)

Using the posted message data for an address, determine if
it falls within the hard, soft, and lower limits from the post_limits
configuration setting.  Returns 1 for a hard limit, 2 for a soft limit,
4 for a lower limit, and and 0 for no limit.

=cut
use Mj::Util qw(str_to_offset);
sub _within_limits {
  my ($self, $list, $data, $soft, $hard, $lower) = @_;
  my ($cond, $count, $i, $msg, $out, $seqno, $reasons, $time, $var);
  return unless (ref $soft eq 'ARRAY' and ref $hard eq 'ARRAY'
                 and ref $lower eq 'ARRAY');
  my $log = new Log::In 350;

  $reasons = [];
  $out = 0;
  $seqno = $self->_list_config_get($list, 'sequence_number');

  # Each limit has a number assigned: 1 - hard, 2 - soft, 4 - lower.
  $i = 1;
  for $var (($hard, $soft, $lower)) {
    for $cond (@$var) {
      if ($cond->[0] eq 't') {
        # time-dependent
        $time = time - &str_to_offset($cond->[2], 0, 0);
        $count = 0;
        for $msg (keys %$data) {
          if ($data->{$msg} > $time) {
            $count++;
          }
        }
        if ($i < 4) {
          if ($count >= $cond->[1]) {
            push (@$reasons, 
                  $self->format_error('over_time_limit', $list,
                                      'COUNT' => $cond->[1],
                                      'TIME'  => &str_to_offset($cond->[2], 0, 1)))
              unless ($i == 2 and $out & 1);
            $out |= $i;
          }
        }
        else {
          if ($count < $cond->[1]) {
            push (@$reasons, 
                  $self->format_error('under_time_limit', $list,
                                      'COUNT' => $cond->[1],
                                      'TIME'  => &str_to_offset($cond->[2], 0, 1))
                 );
            $out |= $i;
          }
        }
      }
      elsif ($cond->[0] eq 'p') {
        # count-dependent
        $time = $seqno - $cond->[2] + 1;
        $time = 1 if ($time < 1);
        $count = 0;
        for $msg (keys %$data) {
          if ($msg > $time and $msg <= $seqno) {
            $count++;
          }
        }
        if ($i < 4) {
          if ($count >= $cond->[1]) {
            push (@$reasons, 
                  $self->format_error('over_message_limit', $list,
                                      'COUNT' => $cond->[1],
                                      'TOTAL' => $cond->[2],
                                     )
                 )
              unless ($i == 2 and $out & 1);
            $out |= $i;
          }
        }
        else {
          if ($count < $cond->[1]) {
            push (@$reasons, 
                  $self->format_error('under_message_limit', $list,
                                      'COUNT' => $cond->[1],
                                      'TOTAL' => $cond->[2],
                                     )
                 );
            $out |= $i;
          }
        }
      }
      else {
        # XXX Error
        return;
      }
    }
    $i *= 2;
  }
    
  return ($out, $reasons);
}

=head2 _check_header (list, entity, reasons, variables)

This checks for taboo and admin headers, based upon the various
taboo_headers and admin_headers variables.

No returns; implicitly modifies the the list referenced by reasons and the
hash referenced by avars.

=cut
use Safe;
sub _check_header {
  my $self    = shift;
  my $list    = shift;
  my $ent     = shift;
  my $reasons = shift;
  my $avars   = shift;
  my $log     = new Log::In 40;
  my (@inv, $class, $code, $data, $i, $invars, $j, $k, $l, 
      $len, $max, $rule, $safe, $sev);

  return unless ($self->_make_list($list));
  $code = {};

  return unless $ent->head;

  for $i ('GLOBAL', $list) {
    for $j ('admin_headers', 'taboo_headers', 'noarchive_headers') {
      $data = $self->_list_config_get($i, $j);
      next unless (defined $data);
      push @inv, @{$data->{'inv'}};
      $code->{$j}{$i} = $data->{'code'};
    }
  }

  # Make a hash of these for fast lookup
  for $i (@inv) {
    $invars->{$i} = $i;
  }

  # Set up the Safe compartment
  $safe = new Safe;
  $safe->permit_only(qw(aassign and const leaveeval lineseq list match not 
                        null padany push pushmark return rv2sv stub subst));

  $avars->{total_header_length} = 0;
  $avars->{max_header_length}   = 0;
  $avars->{mime_header_length}  = 0;
  $avars->{blind_copy} = 1;

  # Recursively check message headers for taboo, admin, and
  # noarchive matches.
  $self->_r_ck_header($list, $ent, $reasons, $avars, $safe, 
                      $code, $invars, 'toplevel');

  # Untaint
  if ($avars->{total_header_length} =~ /(\d+)/) {
    $avars->{total_header_length} = $1;
  }
  if ($avars->{max_header_length} =~ /(\d+)/) {
    $avars->{max_header_length} = $1;
  }
  if ($avars->{mime_header_length} =~ /(\d+)/) {
    $avars->{mime_header_length} = $1;
  }

  # Check the size of the largest top-level header.
  $max = $self->_list_config_get($list, 'max_header_line_length');
  $len = $avars->{'max_header_length'};
  if ($max && ($len > $max)) {
    push @$reasons, 
      $self->format_error('single_header_length', $list,
                          'SIZE' => $len, 'LIMIT' => $max);
    $avars->{max_header_length_exceeded} = 1;
  }

  # Check the total size of the top-level headers combined.
  $max = $self->_list_config_get($list, 'max_total_header_length');
  $len = $avars->{'total_header_length'};
  if ($max && ($len > $max)) {
    push @$reasons, 
      $self->format_error('total_header_length', $list,
                          'SIZE' => $len, 'LIMIT' => $max);
    $avars->{total_header_length_exceeded} = 1;
  }

  # Check the size of the largest MIME header.
  $max = $self->_list_config_get($list, 'max_mime_header_length');
  $len = $avars->{'mime_header_length'};
  if ($max && ($len > $max)) {
    push @$reasons,
      $self->format_error('mime_header_length', $list,
                          'SIZE' => $len, 'LIMIT' => $max);
    $avars->{mime_header_length_exceeded} = 1;
  }

  # Record missed inverted matches from the taboo_headers,
  # admin_headers, and noarchive_headers settings.
  for $i (keys %$invars) {
    ($k, $l, $rule, $sev, $class) = split('\t', $i);
    $self->describe_taboo($reasons, $avars, $k, $l, $rule, 
                          undef, undef, $sev, $class, 1);
  }

  1;
}

=head2 _r_ck_header

=cut
sub _r_ck_header {
  my ($self, $list, $ent, $reasons, $avars, $safe, $code,
      $invars, $part) = @_;
  my $log  = new Log::In 150, "$part";
  my (@addrs, @headers, @matches, @parts, $class, $data, $head, $i, 
      $id, $inv, $j, $k, $l, $listaddr, $match, $msg, $rule, $sev, $spart);
  local($text);

  $listaddr = $self->_list_config_get($list, 'whoami');

  @parts = $ent->parts;
  if (@parts) {
    for ($i = 0; $i < @parts; $i++) {
      if ($part eq 'toplevel') {
	$spart = "part ". ($i+1);
      }
      else {
	$spart = "$part, subpart " . ($i+1);
      }
      $self->_r_ck_header($list, $parts[$i], $reasons, $avars, 
                          $safe, $code, $invars, $spart);
    }
  }

  $head = $ent->head->dup;
  return unless $head;
  $head->unfold;
  $head->decode;

  $safe->share('$text');

  if ($part eq 'toplevel') {
    # Check for duplicate message ID
    chomp($id = $head->get('Message-ID') || '(none)');
    if ($data = $self->{'lists'}{$list}->check_dup($id, 'id')) {
      $msg = $self->format_error('dup_msg_id', $list, 
                                 'MESSAGE_ID' => $id, 
                                 'DATE' => scalar localtime($data->{changetime}));
      push @$reasons, $msg;
      $avars->{dup_msg_id} = 1;
    }

    # Count the number of addresses in the To and Cc headers.
    push @headers, $head->get('To');
    push @headers, $head->get('Cc');
    for $i (@headers) {
      chomp $i;
      push @addrs, Mj::Addr::separate($i) if $i;
    }
    $avars->{'recipients'} = scalar @addrs;
  }

  # Process the header
  for $i ($head->tags) {
    # Skip the mailbox separator, if we get one
    next if $i eq 'From ';

    # Grab all of the occurrences of that tag and iterate over them
    for $j ($head->get($i)) {
      chomp $j;
      $text = "$i: $j";

      if ($part ne 'toplevel') {
        $avars->{mime_header_length} = length($text)
          if (length($text) > $avars->{mime_header_length});
      }
      else {
        # Check for the presence of the list's address in the To
        # and Cc headers.
        if ($i =~ /^(to|cc)$/i) {
          # A looser test would be $j =~ /$list\@/i
          if ($j =~ /$listaddr/i) {
            $avars->{blind_copy} = 0;
          }
        }

        # Check lengths
        $avars->{total_header_length} += length($text) + 1;
        $avars->{max_header_length}    = length($text) + 1
          if $avars->{max_header_length} <= length($text);
      }

      # Now run all of the taboo codes
      for $k ('GLOBAL', $list) {
	for $l ('admin_headers', 'taboo_headers', 'noarchive_headers') {
          next unless (defined $code->{$l}{$k});

	  # Eval the code
	  @matches = $safe->reval($code->{$l}{$k});
	  warn "Error processing $l:  $@" if $@;

	  # Run over the matches that resulted
	  while (($rule, $match, $sev, $class, $inv) = splice(@matches, 0, 5)) {

	    # An inverted match; remove it from the list
	    if ($inv) {
	      delete $invars->{"$k\t$l\t$rule\t$sev\t$class"};
	    }
	    else {
	      $self->describe_taboo($reasons, $avars, $k, $l, $rule, 
                                    $match, undef, $sev, $class, $inv);
	    }
	  }
	}
      }
    }
  }
  1;
}

=head2 _check_body

This investigates a body part for improprieties.  Builds all preliminary
code and data, then calls _r_ck_body to do the dirty work, then builds any
bounce reasons due to missed inverted matches.

=cut
use Safe;
sub _check_body {
  my $self    = shift;
  my $list    = shift;
  my $ent     = shift;
  my $reasons = shift;
  my $avars   = shift;
  my $log     = new Log::In 150;
  my (@inv, $class, $data, $i, $inv, $j, $l, $max, $maxbody, 
      $mcode, $qreg, $rule, $safe, $sev, $tcode, $var);
  $inv = {}; $mcode = {}; $tcode = {};

  # Extract the code from the config variables XXX Move to separate func
  for $i ('GLOBAL', $list) {
    for $j ('admin_body', 'taboo_body', 'noarchive_body') {
      $data = $self->_list_config_get($i, $j);
      next unless (defined $data);
      push @inv, @{$data->{'inv'}};
      $tcode->{$i}{$j} = $data->{'code'};

      # Sigh.  max = 0 means unlimited, so we must preserve it
      if ($data->{'max'} == 0 ||
	  !defined($max) ||
	  ($data->{'max'} > $max && $data->{'max'} > 0))
	{
	  $max = $data->{'max'};
	}
    }
  }
  # Build a hash for fast lookup
  for $i (@inv) {
    $inv->{$i} = $i;
  }

  $i      = $self->_list_config_get($list, 'attachment_rules');
  $mcode  = $i->{check_code};
  $qreg   = $self->_list_config_get($list, 'quote_pattern');

  # Create a Safe compartment
  $safe = new Safe;
  $safe->permit_only(qw(aassign and const le leaveeval lineseq list match 
                        not null padany push pushmark return rv2sv stub 
                        subst));

  # Recursively check the body
  $avars->{'mime_header_length'} = 0;
  $avars->{'body_length'} = 0;
  $avars->{'mime_require'} = 0;
  $self->_r_ck_body($list, $ent, $reasons, $avars, $safe, $qreg, $mcode,
            $tcode, $inv, $max, 'toplevel', 1);

  $maxbody = $self->_list_config_get($list, 'maxlength');
  if ($maxbody && $maxbody < $avars->{'body_length'}) {
    push @$reasons, $self->format_error('body_length', $list, 
                      'SIZE' => $avars->{'body_length'}, 
                      'MAXLENGTH' => $maxbody,
                    );
    $avars->{'body_length_exceeded'} = 1;
  }
  # Now look at what's left in %$inv and build reasons from it
  for $i (keys %$inv) {
    ($l, $var, $rule, $sev, $class) = split('\t', $i);
    $self->describe_taboo($reasons, $avars, $list, $var, $rule, 
                          undef, undef, $sev, $class, 1);
  }
}

use Digest::SHA1;
use Mj::Util qw(re_match);
sub _r_ck_body {
  my ($self, $list, $ent, $reasons, $avars, $safe, $qreg, $mcode, $tcode,
      $inv, $max, $part, $first) = @_;
  my $log  = new Log::In 150, "$part";
  my (@parts, $body, $data, $i, $line, $spart, $sum1, $sum2, $text);

  # Initialize access variables
  if ($first) {
    $avars->{quoted_lines} ||= 0;
    $avars->{lines} ||= 0;
    $avars->{body_length} ||= 0;
    $avars->{nonempty_lines} ||= 0;
    $avars->{percent_quoted} ||= 0;
    $avars->{checksum} ||= 0;
    $avars->{partial_checksum} ||= 0;
    $avars->{dup_checksum} ||= 0;
    $avars->{dup_msg_id} ||= 0;
    $avars->{dup_partial_checksum} ||= 0;
  }

  # If we have parts, we don't have any text so we process the parts and
  # exit.  Note that we try to preserve the $first setting down the chain
  # if appropriate.  We also construct an appropriate name for the part
  # we're processing.
  @parts = $ent->parts;
  if (@parts) {
    for ($i=0; $i<@parts; $i++) {
      if ($part eq 'toplevel') {
	$spart = "part ".($i+1);
      }
      else {
	$spart = "$part, subpart ".($i+1);
      }
      $self->_r_ck_body($list, $parts[$i], $reasons, $avars, $safe, $qreg,
			$mcode, $tcode, $inv, $max, $spart,
			($first && $i==0));
    }
    return;
  }

  # Initialize the body and partial body checksums.
  $sum1 = new Digest::SHA1;
  $sum2 = new Digest::SHA1;

  # Check MIME status and any other features of the entity as a whole
  $self->_check_mime($list, $reasons, $avars, $safe, $ent, $mcode, $part);

  # Now the meat.  Open the body.
  return unless ($ent->bodyhandle);
  $body = $ent->bodyhandle->open('r');
  $line = 1;

  # Iterate over the lines
  while (defined($text = $body->getline)) {
    # Call the taboo matcher on the line if we're not past the max line;
    # pay attention to $max == 0 case
    if (!$max || $line <= $max) {
      $self->_ck_tbody_line($list, $reasons, $avars, $safe, $tcode, 
                            $inv, $line, $text);
    }

    # Update checksum counters.  The partial checksum only applies
    # to the first ten lines of the body.
    if ($first and $sum1 and $sum2) {
      $sum1->add($text);
      $sum2->add($text) if $line <= 10;
    }

    # Calculate a few message metrics
    $avars->{lines}++;
    $avars->{body_length} += length($text);
    $avars->{nonempty_lines}++ if $text =~ /\S/;
    $avars->{quoted_lines}++ if re_match($qreg, $text);
    $line++;
  }

  if ($avars->{'lines'}) {
    $avars->{percent_quoted} =
      int(100*($avars->{quoted_lines} / $avars->{lines}));
  }

  # Untaint
  $avars->{body_length} =~ /(\d+)/;
  $avars->{body_length} = $1;

  # Calculate full and partial body checksums
  if ($first and $sum1 and $sum2) {
    $sum1 = $sum1->hexdigest;
    $avars->{checksum} = $sum1;
    if ($data = $self->{'lists'}{$list}->check_dup($sum1, 'sum')) {
      push @$reasons,
       $self->format_error('dup_checksum', $list, 
                           'DATE' => scalar localtime($data->{changetime})
                          );
      $avars->{dup_checksum} = 1;
    }
    $sum2 = $sum2->hexdigest;
    $avars->{partial_checksum} = $sum2;
    if ($data = $self->{'lists'}{$list}->check_dup($sum2, 'partial')) {
      push @$reasons,
       $self->format_error('dup_partial_checksum', $list, 
                           'DATE' => scalar localtime($data->{changetime})
                          );
      $avars->{dup_partial_checksum} = 1;
    }
  }
}

=head2 _r_strip_body (list, entity, change_code, level)

Recursively examine the body parts, and remove those slated
to be discarded by the attachment_rules setting.  Strip
HTML formatting if requested.

Encoding changes are not yet implemented.

The ability to store a particular body part and
make it available through FTP, HTTP, or other means
is not yet implemented.

=cut
use MIME::Entity;
use Safe;
use Symbol;
sub _r_strip_body {
  my $self     = shift;
  my $list     = shift;
  my $ent      = shift;
  my $code     = shift;
  local $level = shift;
  my $log = new Log::In 50, $level;
  my (@changes, @newparts, @parts, $char, $enc, $i, $mt, $nent, $tmpdir, 
      $txtfile, $verdict, $xform);

  # Create a Safe compartment
  my ($safe) = new Safe;
  $safe->permit_only(qw(aassign and const gt le leaveeval lineseq list 
                        match not null padany push pushmark return 
                        rv2sv stub subst undef));
  $safe->share(qw($level));
  local ($_);
  @newparts = ();

  @parts = $ent->parts;

  if (@parts) {
    $_ = $mt = $ent->effective_type;
    $enc = $ent->head->mime_encoding;
    $char = $ent->head->mime_attr('content-type.charset') || 'iso-8859-1';
    ($verdict, $xform) = $safe->reval($code);
    warn "Error filtering type $mt:  $@" if $@;
    return if ($verdict eq 'keep');

    $level++;
    for $i (@parts) {
      $_ = $mt = $i->effective_type;
      $enc = $i->head->mime_encoding;
      $char = $i->head->mime_attr('content-type.charset') 
                || 'iso-8859-1';
      ($verdict, $xform) = $safe->reval($code);
      warn "Error filtering type $mt:  $@" if $@;

      if ($verdict eq 'allow' or $verdict eq 'keep') {
        push @newparts, $i;
      }
      elsif ($verdict eq 'clean') {
        $txtfile = $self->clean_text($i);

        if ($txtfile) {
          # Create an entity from the cleaned file.
          $nent = build MIME::Entity('Path' => $txtfile);
         
          if ($nent) { 
            $nent->head($i->head->dup);
            push @newparts, $nent;
            push @changes, [$mt, 'clean'];
            $self->{'body_changed'} = 1;
          }
          else {
            $log->message(50, 'info', "Unable to replace part $mt");
            push @newparts, $i;
          }
        }
        else {
          $log->message(50, 'info', "No changes made to $mt");
          push @newparts, $i;
        }
      }
      elsif ($verdict eq 'discard') {
        if ($level == 2 and scalar(@parts) == 1) {
          $log->message(50, 'info', "Cannot discard a top-level single part.");
          push @newparts, $i;
        }
        elsif ($i->parts) {
          $log->message(50, 'info', "Cannot discard a multipart subpart.");
          push @newparts, $i;
        }
        else {
          push @changes, [$mt, 'discard'];
          $self->{'body_changed'} = 1;
          $log->message(50, 'info', "Discarding MIME type $mt");
        }
      }
      elsif ($verdict eq 'format') {
        $log->message(50, 'info', "Formatting MIME type $mt");

        $txtfile = $self->_format_text($i, $xform);

        if ($txtfile) {
          # Create a new plain text entity and include it
          # in the list of new parts.
          $nent = build MIME::Entity('Path' => $txtfile);
          
          if ($nent) { 
            $nent->head($i->head->dup);
            $nent->head->mime_attr('Content-Type' => 'text/plain');
            push @newparts, $nent;
            push @changes, [$mt, 'format'];
            $i->purge;
            $self->{'body_changed'} = 1;
          }
          else {
            $log->message(50, 'info', "Unable to replace part $mt");
            push @newparts, $i;
          }
        }
        else {
          $log->message(50, 'info', "No changes made to $mt");
          push @newparts, $i;
        }
      }
      else {
        # If the attachment rules code does not work properly, log
        # the error and keep the part in question.
        $log->message(50, 'info', "Attachment filters error: $@");
        push @newparts, $i;
      }
    } 
    $ent->parts(\@newparts);
    for ($i = 0; $i < @newparts; $i++) {
      push @changes, $self->_r_strip_body($list, $newparts[$i], $code, $level);
    }
    if (@newparts <= 1) {
      if ($ent->make_singlepart eq "DONE") {
        $self->{'body_changed'} = 1;
      }
    }
  }
  elsif ($level == 1) {
    # single-part messages cannot have parts discarded, but the 
    # message can be formatted or cleaned.
    $_ = $mt = $ent->effective_type;
    $char = $ent->head->mime_attr('content-type.charset') 
              || 'iso-8859-1';
    ($verdict, $xform) = $safe->reval($code);
    warn "Error filtering type $mt:  $@" if $@;

    if ($verdict eq 'format') {
      $log->message(50, 'info', "Formatting MIME type $mt");
      $txtfile = $self->_format_text($ent, $xform);

      if ($txtfile) {
        # Create a new body from the text file.
        $i = new MIME::Body::File "$txtfile";
        $ent->bodyhandle->purge;
        $ent->bodyhandle($i);
        $ent->head->mime_attr('Content-Type' => 'text/plain');
        push @changes, [$mt, 'format'];
        $self->{'body_changed'} = 1;
      }
    }
    elsif ($verdict eq 'clean') {
      $log->message(50, 'info', "Cleaning MIME type $mt");
      $txtfile = $self->clean_text($ent);

      if ($txtfile) {
        # Create a new body from the text file.
        $i = new MIME::Body::File "$txtfile";
        $ent->bodyhandle($i);
        push @changes, [$mt, 'clean'];
        $self->{'body_changed'} = 1;
      }
    }
  }
  else {
    # no changes for single-part entities below level 1.
  }
  return @changes;
}

=head2 _format_text (entity, width)

Given a mime entity and margin width, remove HTML tags from the
entity's body; format the text with the right margin at the
given width.

=cut
use Symbol;
sub _format_text {
  my $self = shift;
  my $entity = shift;
  my $width = shift || 72;
  my $log = new Log::In 50, $width;
  my ($body, $formatter, $outfh, $tmpdir, $tree, $txtfile, $type);
  unless (defined $entity) {
    $log->message(50, 'info', "Entity is undefined.");
    return;
  }

  $type = $entity->effective_type;
  unless ($entity->effective_type =~ /^text/i) {
    $log->message(50, 'info', "Formatting is not supported for type $type.");
    return;
  }

  # Make certain this is a single-part entity with a body.
  unless ($entity->bodyhandle) {
    $log->message(50, 'info', "Entity has no body.");
    return;
  }

  # Create a temporary file.
  $tmpdir = $self->_global_config_get('tmpdir');
  $txtfile = "$tmpdir/mjr." . Majordomo::unique() . ".in";
  $outfh = gensym();
  open($outfh, "> $txtfile");
  unless ($outfh) {
    $log->message(50, 'info', "Unable to open $txtfile: $!");
    return;
  }
      
  $entity->bodyhandle->print($outfh);
  close ($outfh)
    or $::log->abort("Unable to close file $txtfile: $!");

  # Convert plain text or enriched text to hypertext.
  if ($type =~ m#^text/plain#i) {
    eval ( "use Text::Reflow;" );
    if ($@) {
      # Use simple fallback if Text::Reflow is not available.
      eval ( "use Mj::Util qw(plain_to_hyper);" );
      &plain_to_hyper($txtfile);
    }
    else {
      # Reformat the text and return immediately.
      eval ( "use Mj::Util qw(reflow_plain);" );
      &reflow_plain($txtfile, $width, 1);
      return $txtfile;
    }
  }
  elsif ($type =~ m#^text/(richtext|enriched)#i) {
    eval ( "use Mj::Util qw(enriched_to_hyper);" );
    &enriched_to_hyper($txtfile);
  }
  else {
    # XXX Treat other text/* types as HTML
  }

  require HTML::TreeBuilder;
  $tree = HTML::TreeBuilder->new->parse_file($txtfile);
  unlink $txtfile;

  unless ($width =~ /^\d+$/ and $width > 0) {
    $width = 72;
  }

  require HTML::FormatText;
  $formatter = HTML::FormatText->new(leftmargin => 0, 
                                     rightmargin => $width);

  $txtfile = "$tmpdir/mjr." . Majordomo::unique() . ".in";
  $outfh = gensym();
  open($outfh, "> $txtfile");
  unless ($outfh) {
    $log->message(50, 'info', "Unable to open $txtfile: $!");
    return;
  }
  print $outfh $formatter->format($tree);
  close ($outfh)
    or $::log->abort("Unable to close file $txtfile: $!");
  $tree->delete;

  return $txtfile;
}

=head2 clean_text(entity)

Removes selected HTML elements and attributes from a text/html
body part.

=cut
use Symbol;
use Mj::Util qw(clean_html);
sub clean_text {
  my $self = shift;
  my $entity = shift;
  my $log = new Log::In 50;
  my (@attr, @elem, @tags, $body, $outfh, $tmpdir, $txtfile, $type);

  unless (defined $entity) {
    $log->message(50, 'info', "Entity is undefined.");
    return;
  }

  $type = $entity->effective_type;
  unless ($entity->effective_type =~ /^text\/html/i) {
    $log->message(50, 'info', "Formatting is not supported for type $type.");
    return;
  }

  # Make certain this is a single-part entity with a body.
  unless ($entity->bodyhandle) {
    $log->message(50, 'info', "Entity has no body.");
    return;
  }

  # Create a temporary file.
  $tmpdir = $self->_global_config_get('tmpdir');
  $txtfile = "$tmpdir/mjr." . Majordomo::unique() . ".in";
  $outfh = gensym();
  open($outfh, "> $txtfile");
  unless ($outfh) {
    $log->message(50, 'info', "Unable to open $txtfile: $!");
    return;
  }
  
  # Save the decoded text    
  $entity->bodyhandle->print($outfh);
  close ($outfh)
    or $::log->abort("Unable to close file $txtfile: $!");

  @attr = qw(background onblur onchange onclick ondblclick onfocus 
             onkeydown onkeypress onkeyup onload onmousedown 
             onmousemove onmouseout onmouseover onmouseup onreset 
             onselect onunload);

  @elem = qw(applet embed form frame iframe ilayer 
             layer object option script select textarea);

  @tags = qw(base img input link meta);

  return unless &clean_html($txtfile, \@attr, \@elem, \@tags);
  return $txtfile;
}

=head2 _ck_tbody_line

This method checks a line from the message against the prebuilt taboo
code from the taboo_body, admin_body, or noarchive_body configuration
settings.

=cut
sub _ck_tbody_line {
  my $self    = shift;
  my $list    = shift;
  my $reasons = shift;
  my $avars   = shift;
  my $safe    = shift;
  my $code    = shift;
  my $inv     = shift;
  local $line = shift;
  local $text = shift;
#  my $log = new Log::In 250, "$list, $line, $text";
  my (@matches, $class, $i, $invert, $j, $k, $l, $match, $rule, $sev);

  # Share some variables with the compartment
  $safe->share(qw($text $line));

  for $i ('GLOBAL', $list) {
    for $j ('admin_body', 'taboo_body', 'noarchive_body') {
      next unless (defined $code->{$i}{$j});
      # Eval the code
      @matches = $safe->reval($code->{$i}{$j});
      warn $@ if $@;

      # Run over the matches that resulted
      while (($rule, $match, $sev, $class, $invert) = splice(@matches, 0, 5)) {
	# An inverted match; remove it from the list
	if ($invert) {
	  delete $inv->{"$i\t$j\t$rule\t$sev\t$class"};
	}
	else {
	  $self->describe_taboo($reasons, $avars, $i, $j, $rule, 
                                $match, $line, $sev, $class, $invert);
	}
      }
    }
  }
}

=head2 _check_mime (list, reasons, avars, safe, entity, code, part, type)

This checks a given MIME type against the mime matching code built from
attachment_rules and modifies the bounce reasons and access variables as
appropriate.

=cut
sub _check_mime {
  my $self    = shift;
  my $list    = shift;
  my $reasons = shift;
  my $avars   = shift;
  my $safe    = shift;
  my $ent     = shift;
  my $code    = shift;
  my $part    = shift;
  my $type    = $ent->mime_type;
  my $log = new Log::In 250, $type;
  local($_);
  my ($action);

  # Evaluate the matching code
  $_      = $type;
  $action = $safe->reval($code);
  warn "Error processing type $type:  $@" if $@;
  if ($action eq 'consult') {
    push @$reasons, $self->format_error('body_part_consult', $list,
                                        'PART' => $part,
                                        'CONTENT_TYPE' => $type,
                                       );
     # "Questionable MIME part in $part: $type";
    $avars->{mime_consult} = 1;
    $avars->{mime} = 1;
    $log->out('consult');
  }
  elsif ($action eq 'deny') {
    push @$reasons, $self->format_error('body_part_deny', $list,
                                        'PART' => $part,
                                        'CONTENT_TYPE' => $type,
                                       );
    $avars->{mime_deny} = 1;
    $avars->{mime} = 1;
    $log->out('deny');
  }
  elsif ($action eq 'require') {
    $avars->{mime_require} = 1;
    $log->out('require');
  }
}

=head2 _trim_approved

This removes Approved: pseudo-headers from the body of the message.

If present in the preamble, it is removed.

If present in the first line of the body of the message and followed
immediately by a blank line, it and the blank line are removed by
creating a new body copying all but the new body into it.

If present in the first line of the body and not followed immediately
by a blank line, everything directly after the Approved: line is parsed
as a new MIME entity and the old entity is completely obliterated.

If the message is multipart, the first body part is checked for the
header, and it is removed if present.

If the message is multipart, consists of exactly two parts, the first
part contains nothing but the Approved: line and the second part has
type message/rfc822, then the second part is parsed as a MIME message
and the original entity is completely obliterated.

This returns an entity and a head; they may be the same, they may be
different.

Note that Approved: headers are removed along with the rest of the
skip headers after this step is complete.

XXX Perhaps call this function recursively?  Are there situations
where many approvals can be stacked up?

XXX Need to purge all of the bodies and entities that we get rid of in
the course of this function.

=cut
use Mj::MIMEParser;
sub _trim_approved {
  my $self  = shift;
  my $oent  = shift;
  my $log   = new Log::In 40;
  my ($i, $line, $nbody, $nent, $nfh, $obody, $ofh, $part,
      $parser, $passwd, $pos, $pre, $token);

  # Nuke Approved:-looking lines in the preamble
  $pre = $oent->preamble;
  if ($pre) {
    for $i (0..3) {
      last unless $$pre[$i];
      if ($$pre[$i] && $$pre[$i] =~ /Approved:\s*([^\s,]+)\s*,?\s*(.*)/i) {
	splice @$pre, $i, 1;
        $self->{'body_changed'} = 1;
	return $oent;
      }
      last if $$pre[$i] =~ /\S/;
    }
  }

  # Now check the body; if multipart:
  $part = $oent->parts(0);
  if ($part) {
    # Look for approved.
    $ofh = $part->open('r');
    if ($ofh) {
      while (defined ($line = $ofh->getline)) {
	last if $line =~ /\S/;
      }
      if (defined($line) && $line =~ /Approved:\s*([^\s,]+)\s*,?\s*(.*)/i) {
        $self->{'body_changed'} = 1;
	# Look a single additional part of type message/rfc822 and if so,
	# parse it and return it.
	if (scalar($oent->parts) == 2 &&
	    $oent->parts(1)->effective_type eq 'message/rfc822')
	  {
	    # We could turn on parse_nested_message, but that's more
	    # pain than its worth.
	    $nfh = $oent->parts(1)->open('r');
	    $parser = new Mj::MIMEParser;
	    $parser->output_to_core($self->_global_config_get('max_in_core'));
	    $parser->output_dir($self->_global_config_get('tmpdir'));
	    $parser->output_prefix('mjr');
	    $nent = $parser->read($nfh);
	    $oent->purge;
	    return $nent;
	  }
	# Otherwise make a new body and copy everything after the approved
	# line into it, set part 0's body to the new value, and return.
	$nbody = new MIME::Body::File $self->tempname;
	$nfh   = $nbody->open('w');

	# Skip the single blank line that follows the Approve: line.
	$ofh->getline;
	while (defined ($line = $ofh->getline)) {
	  $nfh->print($line);
	}
	$obody = $part->bodyhandle($nbody);
	$obody->purge;
	return $oent;
      }
    }
  }
  else {
    # We have a single part message.  Look for approved.
    $ofh = $oent->open('r');
    if ($ofh) {
      while (defined ($line = $ofh->getline)) {
	last if $line =~ /\S/;
      }
      if (defined($line) && $line =~ /Approved:\s*([^\s,]+)\s*,?\s*(.*)/i) {
	# Found it; save the file position and read one more line.
        $self->{'body_changed'} = 1;
	$pos = $ofh->tell;
	$line = $ofh->getline;

	# If it's blank, make a new body and copy everything after the
	# blank into it, replace the old body with the new one and return
	# the entity.
	if (!defined($line) || $line !~ /\S/) {
	  $nbody = new MIME::Body::File $self->tempname;
	  $obody = $oent->bodyhandle;
	  $nfh   = $nbody->open('w');
	  while (defined ($line = $ofh->getline)) {
	    $nfh->print($line);
	  }
	  $oent->bodyhandle($nbody);
	  $obody->purge;
	  return $oent;
	}
	# Else we have headers; seek back (unless we're at a possibly
	# quoted mailbox separator) and parse from the body to a new
	# entity; return it.
	$ofh->seek($pos, 0) unless $line =~ /^>?From /;
	$parser = new Mj::MIMEParser;
	$parser->output_to_core($self->_global_config_get('max_in_core'));
	$parser->output_dir($self->_global_config_get('tmpdir'));
	$parser->output_prefix('mjr');
	$nent =  $parser->read($ofh);
	$oent->purge;
	return $nent;
      }
    }
  }

  # No approvals found; just return what we got.
  return $oent;
}

=head2 _add_fters(entity, list, subs)

This adds fronters and footers to the entity.  If the message is
multipart or the only part is not text/plain, then we have to do
things via attachments.  For a first pass, we will only deal with
multipart messages or text/plain single-part messages; trying to
convert a single-part message into a multipart one just to attach some
goodies is not a really good idea (and might never happen).  We need
to decide if we really want to add a fronter or footer, figure out
which one to use, then attach it.

=cut
sub _add_fters {
  my $self = shift;
  my $ent  = shift;
  my $list = shift;
  my $subs = shift;
  my $log  = new Log::In 40;
  my ($foot, $footers, $foot_ent, $foot_freq, $front, $fronters,
     $front_ent, $front_freq, $line, $nbody, $nfh, $obody, $ofh);

  # Extract fter arrays and frequencies from storage.
  $fronters   = $self->_list_config_get($list, 'message_fronter');
  $front_freq = $self->_list_config_get($list, 'message_fronter_frequency');
  $footers    = $self->_list_config_get($list, 'message_footer');
  $foot_freq  = $self->_list_config_get($list, 'message_footer_frequency');

  # Choose the proper items if we need them at all; also, tack on line
  # endings and stuff into useful arrayrefs.  (This makes it easy to
  # build entities out of them if necessary.)
  if (@$fronters && $front_freq > rand(100)) {
      $front = [];
      for $line (@{@$fronters[rand(@$fronters)]}) {
	  push @$front, "$line\n";
      }
  }
  if (@$footers && $foot_freq > rand(100)) {
      $foot = [];
      for $line (@{@$footers[rand(@$footers)]}) {
	  push @$foot, "$line\n";
      }
  }

  # Bail unless we're adding something
  return unless $front || $foot;

  # Substitute values
  $front = $self->substitute_vars_string($front, $subs) if $front;
  $foot  = $self->substitute_vars_string($foot,  $subs) if $foot;

  # We take different actions if the message is multipart
  if ($ent->is_multipart) {
      return 0 unless ($ent->effective_type eq 'multipart/mixed');
      if ($front) {
	  $front_ent = build MIME::Entity(Type       => "text/plain",
					  Encoding   => '8bit',
					  Data       => $front,
					  'X-Mailer' => undef,
					 );
	  # Add the part at the beginning of the message
	  $ent->add_part($front_ent, 0);
          $self->{'body_changed'} = 1;
      }
      if ($foot) {
	  $foot_ent = build MIME::Entity(Type       => "text/plain",
					 Encoding   => '8bit',
					 Data       => $foot,
					 'X-Mailer' => undef,
					);
	  # Add the part at the end of the message
	  $ent->add_part($foot_ent, -1);
          $self->{'body_changed'} = 1;
      }
      return 1;
  }
  # Else we have a single part message; make sure it's a type we can mess with
  return 0 unless $ent->effective_type eq 'text/plain';

  # prepare to copy the body
  $nbody = new MIME::Body::File $self->tempname;
  $obody = $ent->bodyhandle;
  return 0 unless ($nbody and $obody); 
  $nfh   = $nbody->open('w');
  $ofh   = $obody->open('r');

  # Copy in the fronter
  if ($front) {
      for $line (@$front) {
	  $nfh->print($line);
      }
      $self->{'body_changed'} = 1;
  }
  # Copy the message
  while (defined ($line = $ofh->getline)) {
      $nfh->print($line);
  }
  # Copy in the footer
  if ($foot) {
      for $line (@$foot) {
	  $nfh->print($line);
      }
      $self->{'body_changed'} = 1;
  }

  # Put the new body in place.  We don't purge the old body because
  # the archive copy still references the backing file.
  $ent->bodyhandle($nbody);
  return 1;
}

=head2 _munge_from(ent, list)

This hacks up the From: header and perhaos CC: as well.  Currently the only
function is to check to see if the user in the From: header has the
rewritefrom flag set and if so replace it with the version from the list.

=cut
sub _munge_from {
  my ($self, $ent, $list) = @_;
  my ($data, $from);

  $from = new Mj::Addr($ent->head->get('From'));
  if ($from and $from->isvalid &&
      $self->{lists}{$list}->flag_set('rewritefrom', $from))
    {
      $data = $self->{lists}{$list}->is_subscriber($from);
      return unless $data;
      $ent->head->replace('From', $data->{fulladdr});
    }
}

=head2 _munge_subject(ent, sequence_number)

Prepend the subject prefix and strip extra Re:-like components.  $SENDER is
is expanded under 1.94 but it is done is such a broken manner that nobody
would ever use it.  We disable it; if someone needs it we can probably find
a way to make it work at the expense of some accuracy in prefix removal.

Returns two entities: one with the prefix, one with any existing prefix
removed.

=cut
use Mj::Util qw(re_match);
sub _munge_subject {
  my ($self, $ent1, $list, $seqno) = @_;
  my ($ent2, $gprefix, $head1, $head2, $prefix, $re_mods, $re_part,
      $re_regexp, $re_strip, $rest, $subject1, $subject2, $subs);

  $ent2  = $ent1->dup;
  $head1 = $ent1->head;
  $head2 = $ent2->head;
  $subject1 = $head1->get('Subject');

  $prefix   = $self->_list_config_get($list, 'subject_prefix');
  $re_regexp= $self->_list_config_get($list, 'subject_re_pattern');
  $re_strip = $self->_list_config_get($list, 'subject_re_strip');

  # re_regexp will have delimiters, but we don't want them.  We do want to
  # save any modifiers.
  $re_regexp =~ s!^/(.*)/([ix]*)$!$1!;
  $re_mods = $2 || '';
  $re_mods .= 's';

  $subs = {
	   $self->standard_subs($list),
	   'SEQNO'   => $seqno,
	  };

  # Strip any existing Re:-like stuff and replace with a single "Re: "
  if ($re_strip && $subject1) {
    ($re_part, $rest) =
      re_match("/^($re_regexp)\\s*(.*)\$/$re_mods", $subject1, 1);
    if (defined($re_part) && length($re_part)) {
      $subject1  = "Re:";
      $subject1 .= " $rest" if defined($rest);
      $re_regexp = 'Re: '; $re_mods = '';
    }
  }

  $subject2 = $subject1;

  if ($prefix) {
    # Substitute constant values into the prefix and turn it into a regexp
    # matching a 'general prefix'.  We have to do this because the sequence
    # number changes.
    $gprefix = quotemeta($prefix);
    $gprefix =~ s/\\\$LIST/$list/;
    $gprefix =~ s/\\\$SEQNO/\\d+/;

    # Generate the prefix to be prepended
    $prefix = $self->substitute_vars_string($prefix, $subs);

    if (defined $subject1) {
      chomp $subject1;

      # Does this subject have the prefix already on it?  If so, turn it
      # into the new prefix and (for the second copy) remove it and the
      # following space entirely.
      if ($subject1 =~ /$gprefix/) {
	$subject1 =~ s/$gprefix/$prefix/;
	$subject2 =~ s/$gprefix ?//;
      }

      # otherswise tack it onto one copy and leave the other alone
      else {
	($re_part, $rest) =
	  re_match("/^($re_regexp)\\s*(.*)\$/$re_mods", $subject1, 1);
	if (defined($re_part) && length($re_part)) {
	  $re_part =~ s/\s*$//;
	  $subject1  = "$re_part $prefix";
	  $subject1 .= " $rest" if defined($rest) && length($rest);
	}
	else {
	  $subject1 = "$prefix $subject1";
	}
      }
    }

    # Turn an empty subject into just the prefix, leave the second copy empty.
    else {
      $subject1 = "$prefix";
    }
  }

  $head1->replace('Subject', "$subject1") if defined($subject1);
  $head2->replace('Subject', "$subject2") if defined($subject2);

  ($ent1, $ent2);
}

=head2 _reply_to(ent)

This adds a Reply-To: header to an entity.

=cut
sub _reply_to {
  my($self, $ent, $list, $seqno, $user, $nonmembers) = @_;
  my(%needcopy, $head, $needcopy, $replyto, $resendhost);

  $head       = $ent->head;
  $replyto    = $self->_list_config_get($list, 'reply_to');
  $resendhost = $self->_list_config_get($list, 'resend_host');

  %needcopy   = ("$list\@$resendhost" => "$list\@$resendhost",
		 %$nonmembers,
		);
  $needcopy   = join(', ', values(%needcopy));

  if ($replyto && (!$head->get('Reply-To') ||
		   $self->_list_config_get($list, 'override_reply_to')))
    {
      $replyto =
	$self->substitute_vars_string
	  ($replyto,
	   {
            $self->standard_subs($list),
	    'HOST'    => $resendhost,
	    'NEEDCOPY'=> $needcopy,
	    'SENDER'  => $user,
	    'SEQNO'   => $seqno,
	    'USER'    => $user,
	   },
	  );
      $head->set('Reply-To', $replyto);
    }
  $ent;
}

=head2 _exclude

Figure out who to exclude.

This looks at the To: and CC: headers of the given entity, plus the provded
user.  It checks the status and settings of those addresses and adds them
to various lists if appropriate:

  $user is excluded if it has flags 'noselfcopy'.
  To: and CC: are excluded if they have flags 'eliminatecc'.

  List members are added to the $members hash

  Non-members are added to the $nonmembers hash.

=cut
sub _exclude {
  my($self, $ent, $list, $sublist, $user) = @_;
  my(@addrs, @headers, $addr, $exclude, $i, $members, $nonmembers);

  $exclude    = {};
  $members    = {};
  $nonmembers = {};

  # The user doesn't get a copy if they don't have 'selfcopy' set.
  if ($user->isvalid) {
    $exclude->{$user->canon} = $user->full
      unless ($self->{'lists'}{$list}->flag_set('selfcopy', $user, $sublist));
    if ($self->{'lists'}{$list}->is_subscriber($user)) {
      $members->{$user->canon} = $user->full;
    }
    else {
      $nonmembers->{$user->canon} = $user->full;
    }
  }

  # Extract recipient addresses from headers
  push @headers, $ent->head->get('To');
  push @headers, $ent->head->get('Cc');

  for $i (@headers) {
    chomp $i;
    push @addrs, Mj::Addr::separate($i) if $i;
  }

  for $i (@addrs) {
    $addr = new Mj::Addr($i);
    next unless $addr && $addr->isvalid;
    $exclude->{$addr->canon} = $addr->full
      if $self->{'lists'}{$list}->flag_set('eliminatecc', $addr, $sublist);
    if ($self->{'lists'}{$list}->is_subscriber($addr)) {
      $members->{$addr->canon} = $addr->full;
    }
    else {
      $nonmembers->{$addr->canon} = $addr->full;
    }
  }

  ($exclude, $members, $nonmembers);
}

=head2 _find_dup (list, list, ...)

Returns a list of addresses which have class "unique"
on the first list and class other than "nomail" on 
at least one of the succeeding lists.

=cut
sub _find_dup {
  my ($self, $first, @others) = @_;
  my (%check, %found, @tmp, $chunk, $isect, $j);
  my $log = new Log::In 250;
  return {} unless (scalar @others);

  $isect = sub {
    my ($key, $values) = @_;
    return 0 if ($values->{'class'} eq 'nomail');
    # return 0 if ($values->{'class'} eq 'digest');
    if (exists $check{$key}) {
      delete $check{$key};
      $found{$key}++;
    }
    return 0;
  };

  $chunk = $self->_global_config_get('chunksize') || 1000;
  return {} unless $first->get_start;
 
  # Obtain addresses from the primary list, one block
  # at a time.  For each block, examine the subscriber
  # list for each other list on which the message has
  # been posted. 
  while (1) {
    @tmp = $first->get_matching_quick($chunk, 'class', 'unique');
    last unless scalar @tmp;
    @check{@tmp} = ();

    for $j (@others) {
      last unless (scalar keys %check);
      next unless $j->get_start;
      @tmp = $j->get_matching(1, $isect);
      $j->get_done;
    }
  }

  $first->get_done;

  \%found;
}

=head2 do_digests($list, $deliveries, $msgnum, $arcdata, $sender, $whereami, $tmpdir)

This handles passing the message to all defined digests and building any
digests that were triggered.

$run is a listref of digests to run.  If $run and $megnum are both defined,
$run is ignored.  (I.e. messages are always added to all digests.)

If $force is true, a digest will be generated if any messages are waiting.
If not true, the normal decision algorithm will run.

$deliveries is modified.

If $msgnum is not defined, digest_trigger will be called instead of
digest_add, so this function can be used to trigger a digest.

=cut
sub do_digests {
  my ($self, %args) = @_;
  my $log = new Log::In 40;
  my (%digest, %file, @dfiles, @dtypes, @headers, @msgs, @nuke, @tmp, 
      $dfl_format, $digests, $dissues, $dtext, $elapsed, $file, $from, $i, 
      $index_format, $j, $k, $l, $list, $pattern, $seqnum, 
      $sort, $subs, $subject, $whoami);

  $list = $args{'list'}; 
  $subs = $args{'substitute'}; 
  $subs->{LIST} = $list;
  $from = $args{'sender'};
  $subs->{'SENDER'} = $from;
  $whoami = $self->_list_config_get($list, 'whoami');

  # Pass to digest if we got back good archive data and there is something
  # in the digests variable.
  $digests = $self->_list_config_get($list, 'digests');
  if (scalar keys %{$digests}) {

    @headers = $self->_digest_get_headers($list, $subs);
    for $i (@headers) {
      if ($i->[0] =~ /^from$/i) {
        $from = $i->[1];
      }
      elsif ($i->[0] =~ /^to$/i) {
        $whoami = $i->[1];
      }
    }

    $dfl_format = $self->_list_config_get($list, 'digest_index_format')
                  || 'subject';

    if ($args{'msgnum'}) {
      # Note that digest_add will eventually call the trigger itself.
      %digest = $self->{'lists'}{$list}->digest_add($args{'msgnum'},
						    $args{'arcdata'},
						   );
    }
    else {
      %digest = $self->{'lists'}{$list}->digest_trigger($args{'run'},
							$args{'force'},
						       );
    }

    if (%digest) {
      # Extract volumes and issues, then write back the incremented values.
      # Note that when we set the new value, we must do it in an unparsed
      # form.  Hence the weird string-building code.
      $dissues = $self->{lists}{$list}->digest_incissue([keys(%digest)], $digests);

      # Now have a hash of digest name, listref of [article, data] pairs.
      # For each digest, build the three types and for each type and then
      # stuff an appropriate entry into %deliveries.
      for $i (keys(%digest)) {
        $elapsed = $::log->elapsed;
	@dtypes = qw(text mime index);
	$subs->{DIGESTNAME}   = $i;
	$subs->{DIGESTDESC}   = $digests->{$i}{desc};
	$subs->{MESSAGECOUNT} = scalar(@{$digest{$i}});
	$subs->{ISSUE}        = $dissues->{$i}{issue};
	$subs->{VOLUME}       = $dissues->{$i}{volume};

	# Fetch the files from storage.  Per digest type, we have three
	# files that we need, and we look for them under any of four names
	# of decreasing specificity.  Hence the wildly nested loop here.
	for $j (@dtypes) {
          $subs->{DIGESTTYPE} = $j;
	  for $k (qw(preindex postindex footer)) {
	    for $l ("digest_${i}_${j}_${k}", "digest_${i}_${k}", "digest_${j}_${k}", "digest_${k}") {
	      ($file, %file) = $self->_list_file_get(list => $list,
						     file => $l,
						     subs => $subs,
						    );
	      if ($file) {
	        # We're guaranteed to have something if we got here; if the user
	        # didn't provide a file, the build routine will just leave
	        # the appropriate spot blank.
	        $dtext->{$j}{$k}{'name'} = $file;
	        $dtext->{$j}{$k}{'data'} = \%file;
	        push @nuke, $file;
	        last;
	      }
	    }
	  }
	}

	$subject = $self->substitute_vars_string($digests->{$i}{subject}, $subs);
        $index_format = $digests->{$i}{'index'} || $dfl_format;

        $sort = $digests->{$i}{'sort'} || 'numeric';
        if ($sort ne 'numeric') {
          eval ("use Mj::Util qw(sort_msgs)");
          $pattern = $self->_list_config_get($list, 'subject_re_pattern');
          @msgs = &sort_msgs($digest{$i}, $sort, $pattern);
        }
        else {
          @msgs = @{$digest{$i}};
        }

	@dfiles = $self->{'lists'}{$list}->digest_build
	  (messages     => [@msgs],
	   types        => [@dtypes],
	   files        => $dtext,
	   subject      => $subject,
	   from         => $from,
	   to           => $whoami,
	   tmpdir       => $args{'tmpdir'},
	   index_line   => $index_format,
	   headers      => \@headers,
	  );

	# Unlink the temporaries.
	unlink @nuke;

        $seqnum = 'DV';
        if ($dissues->{$i}{'volume'} =~ /(\d+)/) {
          $seqnum .= "0$1N";
        }
        else {
          $seqnum .= "01N";
        }
        if ($dissues->{$i}{'issue'} =~ /(\d+)/) {
          $seqnum .= sprintf "%.5d", $1;
        }
        else {
          $seqnum .= "01";
        }

	for $j (@dtypes) {
	  # shifting off an element of @dfiles gives the corresponding digest
	  $args{'deliveries'}->{"digest-$i-$j"} = {exclude => {},
						   file    => shift(@dfiles),
                                                   seqnum  => $seqnum,
						  };
	}
        # XXX The status and password values (1, 0) may be inaccurate.
	$self->inform($list, "digest", 'unknown@anonymous', 'unknown@anonymous',
           "digest $list $i", $self->{'interface'}, 1, 0, 0, 
           "Volume $dissues->{$i}{'volume'}, Issue $dissues->{$i}{'issue'}", 
            $::log->elapsed - $elapsed);
      }
    }
  }
}

=head1 COPYRIGHT

Copyright (c) 1997, 1998, 2002, 2004 Jason Tibbitts for The Majordomo
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

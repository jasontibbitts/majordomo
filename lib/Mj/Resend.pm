=head1 NAME

Mj::Resend - filtering and transformation functions for Majordomo

___NNNOOOTTT FINISHED!!!___

=head1 SYNOPSIS

  $mj->resend($list, $file);

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

Future cool things to investigate include: users who do not receive
their own messages.  (I implemented everything else on my list.)

Order of operation:

 Pull in message, parse into MIME entities and header [1]
 Check for approval.
 Apply admin_headers and taboo_headers.
 Apply admin_body to first n lines of first text part.
 Apply taboo_body to all text parts.  (What is a text part?)
 Find "illegal" MIME parts.
 *** Bounce now if necessary ***
 Strip out approvals to get the real article; parse it if necessary
 Make two copies of the entity
 Convert or drop MIME parts for list and archive/digest
 Strip unwanted headers from list, archive/digest.
 Add headers, fronter and footer [3] to outgoing copy.
 Compose final message.
 Deliver.
 Deposit in archive.

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
use AutoLoader 'AUTOLOAD';
use Mj::Log;
use IO::File;
use strict;

use vars qw($line $text $type);

1;
__END__

use MIME::Parser;
sub post {
  my($self, $user, $passwd, $auth, $int, $cmd, $mode, $list, $file) = @_;

  my (
      $owner,                # The list owner address
#      $user,                 # User name lifted from headers
#      $passwd,               # Password lifted from approval check
      $token,                # Token lifted from approval check, to be deleted
      $parser,               # MIME::Parser
      $tmpdir,               # duh
      $fh,                   # File handle to parse from
      $ent,                  # Parsed entity
      $head,                 # Message headers
      $thead,                # Temporary copy of message headers
      $id,                   # The Message-ID
      $ok,
      $mess, 
      @taboo,                # Returned taboo list
      $type,
      $rule,
      $match,
      $line,
      $sev,
      $desc,
      $c_type,
      $c_t_encoding,
      # Bounce reasons
      $reason,               # Used to compose a reason
      $var,                  # Used to build a bounce variable
      @reasons,              # Array of all possible message faults
      $bad_approval,         # Invalid password or munged Approve header
      $taboo,                # Generic taboo variable
      $taboo_header,         # Failed taboo match in header
      $taboo_body,           # Failed taboo match in body
      $global_taboo_header,  # Global counterparts for each
      $global_taboo_body,
      $admin,                # Generic admin variable
      $admin_header,
      $admin_body,
      $global_admin_header,
      $global_admin_body,
      $dup,                  # Generic duplicate variable
      $dup_msg_id,           # Message ID was recently seen
      $dup_checksum,         # Body checksums to something recently seen
      $dup_partial_checksum, # First N lines of body checksum seen
      $mime,                 # Anything wrong with MIME
      $mime_consult,         # A MIME part was on the no-no list
      $mime_deny,            # A MIME part was on the really-bad list
      $any,                  # Any impropriety at all
      @tmp,
     );
  my $log = new Log::In 30, "$list, $user, $file"; 
  $tmpdir = $self->_global_config_get("tmpdir");

  $parser = new MIME::Parser;
  $parser->output_to_core($self->_global_config_get("max_in_core"));
  $parser->output_dir($tmpdir);
  $parser->output_prefix("mjr");
  
  $fh = new IO::File "<$file";
  $ent = $parser->read($fh);
  $fh->close;

  # Get the header.
  $::log->in(80, undef, "info", "Parsing the header");
  $head = $ent->head;
  $head->modify(0);
  
  # Make a copy that we can mess with.
  $thead = $head->dup;
  $thead->decode;
  $thead->unfold;
  $::log->out;
  
  # Snarf user from headers XXX Is this really the victim?  The user
  # is the one who made the command happen; that may be unset if
  # called from mj_resend but will exist if calling from the post
  # command.
  $user = $thead->get('reply-to') ||
    $thead->get('from') ||
    $thead->get('apparently-from');
  chomp $user;

  @reasons = ();

  # XXX Pass in the password we were called with, so that passwords
  # can be passed out-of-band.
  ($ok, $passwd, $token) = $self->_check_approval($list, $thead, $ent, $user);

  # No need to do any more (expensive) checks if we're approved.  This
  # might turn out to be a bad idea.  If passwords don't always
  # override access restrictions then we need to do our checks.
  if ($ok > 0 &&
      $passwd &&
      $self->_list_config_get($list, 'access_password_override'))
    {
      return $self->_post($list, $user, $user, $mode, $cmd, $ent);
    }
  
  $bad_approval = "Invalid Approve Header" unless $ok;
  push @reasons, $bad_approval if $bad_approval;

  # Check taboo stuff
  @taboo = $self->_check_taboo($list, $thead, $ent);

  while (($type, $rule, $match, $line, $sev) = splice(@taboo, 0, 5)) {
    # Set bounce variables; construct and push @reasons
    if ($type =~ /inverted/i) {
      $reason = "$type: $rule failed to match";
    }
    elsif ($line) {
      $reason = "$type: $rule matched \"$match\" at $line";
    }
    else {
      $reason = "$type: $rule matched \"$match\"";
    }
    push @reasons, $reason;
    # This is better than the alternative...but it's still stupid
    $type =~ /global taboo header/i and $global_taboo_header += $sev and next;
    $type =~ /global taboo body/i   and $global_taboo_body   += $sev and next;
    $type =~ /global admin header/i and $global_admin_header += $sev and next;
    $type =~ /global admin body/i   and $global_admin_body   += $sev and next;
    $type =~ /taboo header/i        and $taboo_header        += $sev and next;
    $type =~ /taboo body/i          and $taboo_body          += $sev and next;
    $type =~ /admin header/i        and $admin_header        += $sev and next;
    $type =~ /admin body/i          and $admin_body          += $sev and next;
  }

  # Check the message-ID cache
  $dup_msg_id = $self->_check_id($list, $thead);
  if ($dup_msg_id) {
    $dup_msg_id = "Duplicate Message-ID - $dup_msg_id";
    push @reasons, $dup_msg_id;
  }

  # Checksum the body
  ($dup_checksum, $dup_partial_checksum) = $self->_check_sums($list, $ent);
  if ($dup_checksum) {
    $dup_checksum = "Duplicate Message Checksum";
    push @reasons, $dup_checksum;
  }
  if ($dup_partial_checksum) {
    $dup_partial_checksum = "Duplicate Partial Message Checksum";
    push @reasons, $dup_partial_checksum;
  }

  # Check for illegal MIME types.
  ($mime_consult, $mime_deny, @tmp) = $self->_check_mime($list, $ent);
  push @reasons, @tmp;

  # Make some extra access variables
  $taboo = $taboo_header || $taboo_body || $global_taboo_header ||
    $global_taboo_body;
  $admin = $admin_header || $admin_body || $global_admin_header ||
    $global_admin_body;
  $dup = $dup_msg_id || $dup_checksum || $dup_partial_checksum;
  $mime = $mime_consult || $mime_deny;
  $any = $taboo || $admin || $dup || $bad_approval || $mime;

  # Bounce if necessary: concatenate all possible reasons with %~%, call
  # access_check with filename as arg1 and reasons as arg2.  XXX Victim
  # here should be the user in the headers; requester should be the user
  # making the request.  We should only regenerate user if it is not set.
  # This adds a modicum of security to the post command.
  ($ok, $mess) =
    $self->list_access_check
      ($passwd, undef, $int, $mode, $cmd, $list, "post", $user, '',
       $file, join('%~%', @reasons), undef,
       'bad_approval'        => $bad_approval,
       'taboo'               => $taboo,
       'taboo_header'        => $taboo_header,
       'taboo_body'          => $taboo_body,
       'admin'               => $admin,
       'admin_header'        => $admin_header,
       'admin_body'          => $admin_body,
       'global_taboo_header' => $global_taboo_header,
       'global_taboo_body'   => $global_taboo_body,
       'global_admin_header' => $global_admin_header,
       'global_admin_body'   => $global_admin_body,
       'dup'                 => $dup,
       'dup_msg_id'          => $dup_msg_id,
       'dup_checksum'        => $dup_checksum,
       'dup_partial_checksum'=> $dup_partial_checksum,
       'mime'                => $mime,
       'mime_consult'        => $mime_consult,
       'mime_deny'           => $mime_deny,
       'any'                 => $any,
      );

  $owner = $self->_list_config_get($list, 'sender');
  if ($ok > 0) {
    return $self->_post($list, $user, $user, $mode, $cmd, $ent);
  }
  elsif ($ok < 0) {
    # ack the stall if necessary.  Note that we let the access call
    # generate the message even though we have better access to the
    # information because the list owner can control the message using
    # the access language while we can't do that here.  We could do
    # something gross like return a filename as the message an
    # dprocess it here, but it's cleaner this way, even with the bit
    # of added conditional code in Access.pm.  We could also
    # substitute some variables in the access routine and some here,
    # but since we already passes in the essential information there's
    # no reason not to take care of it all at once.
    if ($self->{'lists'}{$list}->flag_set('ackall', $user)) {
      $ent = build MIME::Entity
	(
	 Data        => [ $mess ],
	 Type        => 'text/plain',
	 Encoding    => '8bit',
	 Filename    => undef,
	 -From       => $owner,
	 -Subject    => "Stalled post to $list",
	);
      $self->mail_entity($owner, $ent, $user);
    }
  }
  else {
    if ($self->{'lists'}{$list}->flag_set('ackimportant', $user) ||
	$self->{'lists'}{$list}->flag_set('ackall', $user))
      {
	$ent = build MIME::Entity
	  (
	   Data        => [ $mess ],
	   Type        => 'text/plain',
	   Encoding    => '8bit',
	   Filename    => undef,
	   -From       => $owner,
	   -Subject    => "Denied post to $list",
	  );
	$self->mail_entity($owner, $ent, $user);
      }
  }      
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
sub post_start  {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list) = @_;
  my $log  = new Log::In 30, "$list";

  my $tmp  = $self->_global_config_get('tmpdir');
  my $file = "$tmp/post." . $self->unique;
  $self->{'post_file'} = $file;
  $self->{'post_fh'} = new IO::File ">$file" or
    $log->abort("Can't open $file, $!");

  1;
}

sub post_chunk {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list, $vict, $data) = @_;
  $self->{'post_fh'}->print($data);
}

sub post_done {
  my ($self, $user, $passwd, $auth, $interface, $cmdline, $mode,
      $list) = @_;
  my $log  = new Log::In 30;

  $self->{'post_fh'}->close;

  $self->post($user, $passwd, $auth, $interface, $cmdline, $mode,
	      $list, $self->{'post_file'});

  unlink $self->{'post_file'};
  undef $self->{'post_fh'};
  undef $self->{'post_file'};

  1;
}

# For archive copy, we don't want to do some things (like add
# subjext_prefix, extra headers, footers, fronters) and we may want to
# allow a different set of MIME parts through.  How can we do this?
# Maintain two separate copies of the entity and munge them both
# except where appropriate?  Ugh.
use MIME::Parser;
use Data::Dumper;
sub _post {  
  my($self, $list, $user, $victim, $mode, $cmdline, $file, $arg2,
     $arg3) = @_;
  my $log  = new Log::In 35, "$list, $user, $file";

  my(@refs, @skip, $arcent, $archead, $ent, $head, $i, $msgnum,
     $prefix, $sender, $seqno, $subject, $tmp, $tmpdir, $tprefix);

  $self->_make_list($list);
  $tmpdir = $self->_global_config_get('tmpdir');
  $seqno  = $self->_list_config_get($list, 'sequence_number');
  $self->_list_config_set($list, 'sequence_number', $seqno+1);

  # trick: if $file is a ref to a MIME::Entity, we can skip the parse
  if (ref($file) eq "MIME::Entity") {
    $ent = $file;
  }
  else {
    ($file) = $self->_list_file_get('GLOBAL', "spool/$file", undef, 1);
    my $fh = new IO::File "<$file";
    my $mime_parser = new MIME::Parser;
    $mime_parser->output_to_core($self->_global_config_get("max_in_core"));
    $mime_parser->output_dir($tmpdir);
    $mime_parser->output_prefix("mjr");
    $ent = $mime_parser->read($fh);
    $fh->close;
  }

  # Trim off approvals, get back a new entity
  $ent = $self->_trim_approved($ent);
  $head = $ent->head;
  $head->modify(0);

  # Make duplicate archive/digest entity
  $arcent = $ent->dup;
  $archead = $arcent->head;

  # Convert/drop MIME parts.  Bill?
  
  # Remove skippable headers, including Approved:.
  @skip = ('Approved');
  push @skip, $self->_list_config_get($list, 'delete_headers');
  push @skip, 'Received' if $self->_list_config_get($list, 'purge_received');
  for $i (@skip) {
    $head->delete($i);
    $archead->delete($i);
  }

  # Munge Subject:.  Is anyone daft enough to use SENDER?  It breaks pretty
  # badly if you do...  There's probably a better way to do this (perhaps
  # check for Re:, but this is how 1.9x does it so it's good enough for a start.
  $prefix = $self->_list_config_get($list, 'subject_prefix');
  $tprefix = "\Q$prefix";
  $tprefix =~ s/\\\$SEQNO/\\d+/;
  if ($prefix) {
    $prefix =
      $self->substitute_vars_string($prefix,
				    'LIST'    => $list,
				    'VERSION' => $Majordomo::VERSION,
				    #'SENDER'  => $user,
				    'SEQNO'   => $seqno,
				   );
    ($subject) = $head->get('Subject');
    if (defined $subject) {
      chomp $subject;
      if ($subject =~ /$tprefix/) {
	$subject =~ s/$tprefix/$prefix/;
	$head->replace('Subject', "$subject")
      }
      else {
	$head->replace('Subject', "$prefix $subject")
      }
    }
    else {
      # XXX Should we just leave off the subject if one wasn't
      # provided?
      $head->replace('Subject', "$prefix");
    }
  }

  # Determine sender
  $sender = $self->_list_config_get($list, "sender");
  
  # Add headers
  for $i ($self->_list_config_get($list, 'message_headers')) {
    $i = $self->substitute_vars_string($i,
				       'LIST'    => $list,
				       'VERSION' => $Majordomo::VERSION,
				       'SENDER'  => $user,
				       'SEQNO'   => $seqno,
				      );
    $head->add(undef, $i);
  }
  $head->add('Sender', $sender);

  # Add list-headers standard headers

  # Add fronter and footer.
  $self->_add_fters($list, $ent);

  # Print message to file
  $file = "$tmpdir/mjr.$$.final";
  open FINAL, ">$file" ||
    $::log->abort("Couldn't open final output file, $!");
  $ent->print(\*FINAL);
  close FINAL;
  
  # Invoke delivery routine on the file, first to high-priority folks, then
  # to the rest
  $self->deliver($list, $sender, $file, 'high');
  $self->deliver($list, $sender, $file, 'each');
  
  # Pass to archiver; first extract all references
#  print Dumper $head;
  $tmp = $head->get('references') || '';
  while ($tmp =~ s/<([^>]*)>//) {
    push @refs, $1;
  }
  $tmp = $head->get('in-reply-to') || '';
  while ($tmp =~ s/<([^>]*)>//) {
    push @refs, $1;
  }
  
  # Pass to archive.  XXX Is $user good enough, or should we re-extract?
  $msgnum =
    $self->{'lists'}{$list}->archive_add($file,
					 undef,
					 {
					  'from'    => $user,
					  'subject' => $subject,
					  'refs'    => join(',',@refs),
					 },
					);

  # Pass to digest
  #$self->{'lists'}{$list}->digest_add($msgnum) if $msgnum;

  # Inform sender of successful delivery
  
  # Clean up and say goodbye
  unlink "$file";
  $ent->purge;
  $arcent->purge;
  1;
}

=head2 _check_approval(list, head, entity, user)

This takes a ref to a MIME::Entity and checks to see if it is approved by
one of several methods:

 *In header 
 *First line of preamble
  First line of first part
  First line of body
  First line of first part followed by a message/rfc822 attachment.
  

Head should be a copy of the message header, already decoded and unfolded.

Return flag, password, token. 

The password is validated and the token unspooled if they are given.

Note that this routine doesn''t do any processing on the message;
specifically, it does not remove any Approved: lines or extract any
embedded messages.  This is done in teh bottom half of the post
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
  my ($body, $fh, $i, $line, $part, $passwd, $pre, $token);

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
      if ($$pre[$i] && $$pre[$i] =~ /Approved:\s*(\S+)\s*,?\s*(.*)\s*/i) {
	($passwd, $token) = ($1, $2);
	last;
      }
    }
  }

  # Check in the body
  else {
    # If multipart, grab first part
    $part = $ent->parts(0);
    unless ($part) {
      # Else use the entity itself
      $part = $ent;
    }
    
    # Check in first few of lines of that entity; skip blank lines but
    # stop as soon as we see any text
    $fh = $part->bodyhandle->open('r');
    while (defined ($line = $fh->getline)) {
      last if $line =~ /\S/;
    }
    if (defined($line) && $line =~ /Approved:\s*(\S+)\s*,?\s*(.*)\s*/i) {
      ($passwd, $token) = ($1, $2);
    }
  }
  
  # Now check validity of the password and existance of the token if
  # provided; unspool the token if it exists.  (If it doesn't, just
  # ignore it.  The password must be good, though.)
  if ($passwd) {
    return
      unless $self->validate_passwd($user, $passwd, undef,
				    'resend', $list, 'post');
  }
  
  if ($token) {
    $token = undef unless $self->t_remove($token);
  }

  return (1, $passwd, $token);
}

=head2 _check_sums(list, entity)

This takes a MIME::Entity and does two checksums on its first body part.
The first sum is done over the first (checksum_lines) lines, the second
over the entire body.

Should this be the first text/.* part?  Should it checksum every part (bad
for signatures)?

=cut
use MD5;
sub _check_sums {
  my $self = shift;
  my $list = shift;
  my $ent  = shift; # MIME::Entity
  my $log  = new Log::In 40;
  my $sum1 = new MD5;
  my $sum2 = new MD5;

  my ($body, $i, $io, $line);

  # Find the first body part
  while (1) {
    last unless $ent->parts;
    $ent = ($ent->parts)[0];
  }

  # Do the checksums.  Ouch, wastes a bunch of comparisons.
  $body = $ent->bodyhandle;
  $io = $body->open('r');
  $i = 0;
  while (defined ($line = $io->getline)) {
    $sum1->add($line);
    $sum2->add($line) if $i < 10;#$check_lines;
    $i++;
  }

  $sum1 = $sum1->hexdigest;
  $sum2 = $sum2->hexdigest;

  # Do the checksum database manipulations
  $self->_make_list($list);
  return($self->{'lists'}{$list}->check_dup($sum1, 'sum'),
	 $self->{'lists'}{$list}->check_dup($sum2, 'partial'));
}

=head2 _check_id(list, head)

Checks to see if the message-id has been seen before.

=cut
sub _check_id {
  my $self = shift;
  my $list = shift;
  my $head   = shift;
  $self->_make_list($list);
  my $id = $head->get('Message-ID') || '(none)';
  chomp $id;
  return $self->{'lists'}{$list}->check_dup($id, 'id');
}

=head2 _check_taboo(list, head, entity) UNFINISHED

Takes a MIME::Head and a MIME::Entity and checks them against the list''s
(admin|taboo)_(headers|body).

Returns a list of lists:
 (
  type of match (taboo, admin)
  taboo rule that matched
  text that matched
  matching line number (for body rules)
  the severity of the match
 )

=cut
use Safe;
sub _check_taboo {
  my $self = shift;
  my $list = shift;
  my $head = shift;
  my $ent  = shift;
  my $log  = new Log::In 40;
  my (@inv,     # List of inverted rules (list\ttype\trule)
      %inv,     # Existence hash used to track inversions
      $inv,     # Was this an inverted match?
      $max,     # Maximum line to check
      $safe,    # Safe compartment
      $type,    # The type of the taboo match
      $rule,    # The rule that matched
      $match,   # The actual matched string
      $sev,     # The severity of the matched string
      @matches, # The list of matches returned from the header matcher
      @taboo,   # Accumulated list of bad things
      $data,    # Used for extracting the config data
      $code,    # Holding the various bits of matcher code
      @t, $i, $j, $k, $l, $t);
  local ($text);
  
  # Extract the parsed taboo data from the configs.  Build up the $code
  # hash and the @inv list and figure out $max.
  $code = {};
  for $i ('GLOBAL', $list) {
    for $j ('admin_headers', 'taboo_headers') {
      $data = $self->_list_config_get($i, $j);
      push @inv, @{$data->{'inv'}};
      $code->{$j}{$i} = $data->{'code'};
    }
    for $j ('admin_body', 'taboo_body') {
      $data = $self->_list_config_get($i, $j);
      push @inv, @{$data->{'inv'}};
      $code->{$j}{$i} = $data->{'code'};

      # Sigh.  max = 0 means unlimited, so we must preserve it
      if ($data->{'max'} == 0 ||
	  !defined($max) ||
	  ($data->{'max'} > $max && $data->{'max'} > 0))
	{
	  $max = $data->{'max'};
	}
    }
  }
  
  # Make a hash of these for fast lookup
  for $i (@inv) {
    $inv{$i} = $i;
  }

  # Set up the Safe compartment
  $safe = new Safe;
  $safe->permit_only(qw(aassign const leaveeval null padany push pushmark
			return rv2sv stub));
  $safe->share('$text');

  # Process the header; mega-nesting!  Iterate over each tag present in the
  # header.
  for $i ($head->tags) {

    # Skip the mailbox separator, if we get one
    next if $i eq 'From ';

    # Grab all of the occurrences of that tag and iterate over them
    for $j ($head->get($i)) {
      chomp $j;
      for $k ('GLOBAL', $list) {
	for $l ('admin_headers', 'taboo_headers') {

	  # Construct a header from the tag and the text and check it
	  $text = "$i: $j";

	  # Eval the code
	  @matches = $safe->reval($code->{$l}{$k});
	  warn $@ if $@;

	  # Run over the matches that resulted
	  while (($rule, $match, $sev, $inv) = splice(@matches, 0, 4)) {

	    # An inverted match; remove it from the list
	    if ($inv) {
	      delete $inv{"$k\t$l\t$rule\t$sev"};
	    }

	    # A normal match; build a failure notice for it
	    else {
	      # Mega-gross match-type construction
	      if ($k eq 'GLOBAL') {
		$type = uc("global $l");
	      }
	      else {
		$type = uc($l);
	      }
	      $type =~ s/S$//;   # Nuke that pesky trailing S
	      $type =~ s/\_/ /g; # underscores to spaces
	      push @taboo, ($type, $rule, $match, undef, $sev)
	    }
	  }
	}
      }
    }
  }
  
  # Recursively process the body
  push @taboo, $self->_r_ck_taboo($list, $code, $max, $ent, \%inv);

  # Deal with remaining (i.e. failed) inverted matches
  for $i (keys %inv) {
    ($l, $type, $rule, $sev) = split('\t', $i);
    if ($l eq 'GLOBAL') {
      $type = uc("inverted global $type");
    }
    else {
      $type = uc("inverted $type");
    }
    $type =~ s/S$//;
    $type =~ s/\_/ /g;
    push @taboo, ($type, $rule, undef, undef, $sev);
  }
  
  return @taboo;
}

sub _r_ck_taboo {
  my $self = shift;
  my $list = shift; # Name of the list
  my $code = shift; # Hash containing match functions
  my $max  = shift; # Maximum line to check; max = 0 or undef means check all
  my $ent  = shift; # Entity to check
  my $inv  = shift; # Ref to hash of inverted matches (to be modified)
  my $part = shift || "toplevel";
  my $log  = new Log::In 150, "$part";
  my(@matches, @parts, @taboo, $body, $i, $invert, $j, $match, $rule, $safe, $sev,
     $type);
  local($text, $line);

  @parts = $ent->parts;

  if (@parts) {
    for ($i=0; $i<@parts; $i++) {
      push @taboo, $self->_r_ck_taboo($list, $code, $max, $parts[$i], $inv,
					 "$part, subpart " . ($i+1));
    }
  }
  else {
    # Deal with the body.  Open the bodyhandle.
    $body = $ent->bodyhandle->open('r');
    $line = 1;
    $safe = new Safe;
    $safe->permit_only(qw(aassign const le leaveeval null padany push
			  pushmark return rv2sv stub));
    $safe->share(qw($text $line));
    
    # Loop over the lines, apply matchers to each; we loop until either we
    # don't get a line or, if we have a maximum line limit, we exceed it
    while (defined($text = $body->getline) && (!$max || $line <= $max)) {
      for $i ('GLOBAL', $list) {
	for $j ('admin_body', 'taboo_body') {
	  @matches = $safe->reval($code->{$j}{$i});
	  warn $@ if $@;
	  while (($rule, $match, $sev, $invert) = splice(@matches, 0, 4)) {
	    if ($rule) {
	      if ($invert) {
		delete $inv->{"$i\t$j\t$rule\t$sev"};
	      }
	      else {
		# Mega-gross match-type construction
		if ($i eq 'GLOBAL') {
		  $type = uc("global $j");
		}
		else {
		  $type = uc($j);
		}
		$type =~ s/S$//;   # Nuke that pesky trailing S
		$type =~ s/\_/ /g; # underscores to spaces
		push @taboo, ($type, $rule, $match, "$part, line $line", $sev)
	      }
	    }
	  }
	}
      }
      $line++;
    }
    $body->close;
  }
  @taboo;
}

=head2 _check_mime(list, entity)

This recursively descends the part tree looking applying the part
matching code from the parsed attachment_rules variable.  We always
get back an action; when it is anything but 'allow' we construct a
reason and set an appropriate variable.

The _check_mime function is just a wrapper; the recursion is done by
_r_ck_mime;

=cut
sub _check_mime {
  my($self, $list, $ent) = @_;
  my $log = new Log::In 150;
  my(@reasons, $consult, $deny, $i, $rules, $safe);

  $safe = new Safe;
  $safe->permit_only(qw(const leaveeval null pushmark return rv2sv stub));
  $consult = [];
  $deny    = [];
  $rules = $self->_list_config_get($list, 'attachment_rules');
  _r_ck_mime($safe, $ent, $rules->{'check_code'}, $consult, $deny);
  
  # Make reasons; iterate over @$consult and @$deny and make a message
  # "Illegal MIME part: $type" and push it onto @reasons.
  for $i (@$consult) {
    push @reasons, "Questionable MIME part: $i";
  }

  for $i (@$deny) {
    push @reasons, "Illegal MIME part: $i";
  }

  return(!!@$consult, !!@$deny, @reasons);
}

sub _r_ck_mime {
  my($safe, $ent, $code, $consult, $deny) = @_;
  my(@parts, $action, $i);
  my $log = new Log::In 160;
  local($_);

  for $i ($ent->parts) {
    _r_ck_mime($safe, $i, $code, $consult, $deny);
  }
  
  $_ = $ent->mime_type;
  $action = $safe->reval($code);
  $log->complain($@) if $@;
  
  push @$consult, $_ if $action eq 'consult';
  push @$deny   , $_ if $action eq 'deny'   ;
  return;    
}

=head2 _trim_approved

This removes Approved: pseudo-headers from the body of the message.

If present in the preamble, it is removed.

If present in the first line of the body of the message and followed
immediately by a blank line, it and the blank line are removed by
creating a new body copying all but the new body into it.

If present in the first line of the body and not followed immediately
by a blank line, everything directly after the Aproved: line is parsed
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
use MIME::Parser;
use Data::Dumper;
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
      if ($$pre[$i] && $$pre[$i] =~ /Approved:\s*(\S+)\s*,?\s*(.*)/i) {
	splice @$pre, $i, 1;
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
      if (defined($line) && $line =~ /Approved:\s*(\S+)\s*,?\s*(.*)/i) {
	# Look a single additional part of type message/rfc822 and if so,
	# parse it and return it.
	if (scalar($oent->parts) == 2 &&
	    $oent->parts(1)->effective_type eq 'message/rfc822')
	  {
	    # We could turn on parse_nested_message, but that's more
	    # pain than its worth.
	    $nfh = $oent->parts(1)->open('r');
	    $parser = new MIME::Parser;
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
	  warn("$line");
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
      if (defined($line) && $line =~ /Approved:\s*(\S+)\s*,?\s*(.*)/i) {
	# Found it; save the file position and read one more line.
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
	$parser = new MIME::Parser;
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

=head2 _add_fters(entity)

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
  my $list = shift;
  my $ent  = shift;
  my $log  = new Log::In 40;
  my($foot, $footers, $foot_ent, $foot_freq, $front, $fronters,
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

  # We take different actions if the message is multipart
  if ($ent->is_multipart) {
      if ($front) {
	  $front_ent = build MIME::Entity(Type       => "text/plain",
					  Data       => $front,
					  'X-Mailer' => undef,
					 );
	  # Add the part at the beginning of the message
	  $ent->add_part($front_ent, 0);
      }
      if ($foot) {
	  $foot_ent = build MIME::Entity(Type       => "text/plain",
					 Data       => $foot,
					 'X-Mailer' => undef,
					);
	  # Add the part at the end of the message
	  $ent->add_part($foot_ent, -1);
      }
      return 1;
  }
  # Else we have a single part message; make sure it's a type we can mess with
  return 0 unless $ent->effective_type eq 'text/plain';

  # prepare to copy the body
  $nbody = new MIME::Body::File $self->tempname;
  $obody = $ent->bodyhandle;
  $nfh   = $nbody->open('w');
  $ofh   = $obody->open('r');

  # Copy in the fronter
  if ($front) {
      for $line (@$front) {
	  $nfh->print($line);
      }
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
  }

  # Put the new body in place.  We don't purge the old body because
  # the archive copy still references the backing file.
  $ent->bodyhandle($nbody);
  return 1;
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
### cperl-indent-level:2 ***
### cperl-label-offset:-1 ***
### End: ***

=head1 NAME

Mj::Archive.pm - Majordomo archive object

=head1 SYNOPSIS

  $archive = new Mj::Archive parameters;

=head1 DESCRIPTION

This contains code for the Archive object, which encapsulates all message
archiving functionality for Majordomo.

An archive is a collection of files in the standard mbox format along with
an index file for each mbox.  The index file has one line per message
containing information about each message, including size and offset from
the beginning of the archive file in bytes and lines.  This enables fast
retrieval with a single seek and a sysread.

Archives have specific names: listname-yyymmcc, where yyy is the 4 digit
year, mm is the two digit month, and cc is a one or two digit count 
(could be week number, or day number, or an arbitrary counter).

Note that the addition operation should if at all possible _not_ cause a
load of any data.  This precludes any Data::Dumped structure for the index.

If the archive is to be limited by the number of messages, either we need
another file with a message count, or we need to load in the index in order
to add a message.

=cut

package Mj::Archive;

use strict;
use DirHandle;
use IO::File;
use Mj::Log;
use vars qw(@index_fields);

@index_fields = qw(byte bytes line lines body_lines quoted split date from
		   subject refs hidden msgid);

use AutoLoader 'AUTOLOAD';
1;   
__END__

=head2 new(directory, listname, split, size)

This allocates an archive object and loads in the names of the individual
archive files.  directory is the actual pathname to the directory
containing the archive files; listname is the name of the list the files
are associated with (so that their names can be easily deduced) and split
is a string describing just when an archive should be split:

  yearly
  monthly
  weekly
  daily

The split value is determined by the archive_split configuration
setting.

Size is a string representing the maximum size of a subarchive:

  AAAAk  (A kilobytes)
  BBBBm  (B messages)

note that no less frequent interval is supported.

=cut
sub new {
  my $type  = shift;
  my $dir   = shift;
  my $list  = shift;
  my $split = shift;
  my $size  = shift;
  my $class = ref($type) || $type;
  my $log   = new Log::In 150, "$dir, $list, $split, $size";
  my (%data, @tmp, $dh, $fh, $sort_arcs, $tmp);
  my $self = {'dir'   => $dir,
	      'list'  => $list,
	      'split' => $split,
	      'size'  => $size,
	     };
  bless $self, $class;

  unless (-d "$dir/.index") {
    mkdir("$dir/.index", 0777) ||
      $log->abort("Couldn't create index dir $dir/.index, $!");
  }

  # Get list of files but don't pull in any data.
  $dh = new DirHandle $dir;
  return unless defined $dh;

  # The splits hash contains separate data for each file, whereas
  # the archives hash contains only one entry for an archive that
  # has been split into several files.
  while (defined($_ = $dh->read)) {
    if (s/^$list\.//) {
      $self->{'splits'}{$_} = {};
      @tmp = _split_name($_);
      $data{$_} = [ @tmp ];

      if ($_ =~ /(.*)-\d\d/) {
	$self->{'archives'}{$1} = {};
        @tmp = _split_name($_);
        $data{$1} = [ @tmp ];
      }
      else {
	$self->{'archives'}{$_} = {};
      }
    }
  }

  $sort_arcs = 
  sub {

    # different sublists
    if ($data{$a}->[0] ne $data{$b}->[0]) {
      return $a cmp $b;
    }
    # same date
    elsif ($data{$a}->[1] eq $data{$b}->[1]) {
      return $a cmp $b;
    }
    # different date
    else {
      return $data{$a}->[1] cmp $data{$b}->[1];
    }
  };

  @tmp = sort $sort_arcs (keys %{$self->{'archives'}});
  $self->{'sorted_archives'} = [ @tmp ];

  @tmp = sort $sort_arcs (keys %{$self->{'splits'}});
  $self->{'sorted_splits'} = [ @tmp ];
                
  return $self;
}

=head2 _split_name (filename)

This function returns the sublist name and full date
(with four-digit year) of an archive file name.

=cut
sub _split_name {
  my $arc = shift;
  my ($sl, $tmp);

  # Remove sublist names
  $sl = "";
  if ($arc =~ s/^(.*)\.//) {
    $sl = $1;
  }

  # Remove trailing split numbers
  $arc =~ s/-\d\d$//;

  # Account for two-digit years
  unless ($arc =~ /^(19|20)/) {
    $tmp = substr($arc, 0, 2);
    if ($tmp > 69) {
      $arc = '19' . $arc;
    }
    else {
      $arc = '20' . $arc;
    }
  }

  # Account for quarter years
  if ($arc =~ /^(\d{4})(\d)$/) {
    $arc = $1 . sprintf ("%0.2d", ($2 - 1) * 3 + 1);
  }

  return ($sl, $arc);
}

=head2 add_start(sender, bytes, datahashref), add_done(file)

These adds a message contained in a file to the archive.  A standard mbox
header is appended to the archive, followed by the file''s contents.

sender contains information for the mbox separator that is not contained in
the message.  If blank or undef, it is assumed that the message to be
appended already has an mbox separator prepended.

bytes contains an estimate of the number of bytes in the message, since it
may not yet exist in its final form.  This is used as a hint in computing
whether or not the message will exceed the maximum size of an archive as
specified in the given configuration.

$data->{'date'} should be in seconds since 1970 and is used in determining
the proper archive to add the message to.  If it is blank or undef, the
current date is assumed.

$data->{'from'} should contain the stripped and canonical address of the
message poster.

$data->{'subject'} should contain the subject of the message.

$data->{'refs'} should contain the data from the References: header (a
comma-separated list of message-IDs in brackets), or the single message-ID
from the In-Reply-To: header.  Or nothing...

$data->{'hidden'} should be set to 1 if a message contains headers
that indicate that a subscriber does not wish the message to be 
available in a public archive.

Throughout these routine, $arc is the name of the main archive while $sub
is the name of the subarchive (the archive with the split count appended).
$data holds info about the message being added.

This is split into two routines so that the message number can be known
before the actual message is generated.  This enables the archive number of
a message to be included in a message sent to the archives (so that a
separate copy of the message for the archives is not necessary).

=cut
use Mj::File;
sub add_start {
  my $self   = shift;
  my $sender = shift;
  my $data   = shift || {};
  my $log    = new Log::In 150;

  my($arc, $count, $dir, $fh, $month, $msgno, $msgs, $sub, $tmp, $year);

  $data->{'date'} ||= time;
  $data->{'split'} = '';

  $dir = $self->{'dir'};
  $arc = _arc_name($self->{'split'}, $data->{'date'});
  if (length $data->{'sublist'}) {
    $arc = "$data->{'sublist'}.$arc";
  }

  # A note on possible races here: we are trying to find the proper file to
  # add the message to.  A race results in too many messages being added to
  # an archive, which is a problem but not one considered serious enough to
  # add the locking required to prevent it.  (To do so, lock the index file
  # and don't unlock it until the end.)

  # Determine the proper count if necessary; don't bother if unlimited;
  # otherwise, take the last existing one and check to make sure it will
  # fit.
  unless ($self->{size} eq 'unlimited') {
    $count = "00";
    # Check to see whether we already have archives from this month
    if ($self->{'splits'}{"$arc-$count"}) {

      # Figure out which count to use; take the last file in the list and
      # extract the count from it
      $sub = (grep(/^$arc-\d\d/, @{$self->{'sorted_splits'}}))[-1] 
                || "$arc-$count";

      $sub =~ /.*-(\d+)/; $count = $1;
      # Grab the counts for the subarchive and open a new archive if
      # necessary. XXX Put the archive in the filespace with an appropriate
      # description if creating a new one.
      $self->_read_counts($sub, 1);
      if ($self->{size} =~ /(\d+)k/) {
	$count++ if $self->{splits}{$sub}{bytes} &&
	  $data->{bytes} + $self->{splits}{$sub}{bytes} > $1 * 1024;
      }
      if ($self->{size} =~ /(\d+)m/) {
	$count++ if $self->{splits}{$sub}{msgs} &&
	  $self->{splits}{$sub}{msgs}+1 > $1;
      }
    }
  }
  # Now choose the final values we will use
  $sub = $arc;
  if (defined $count) {
    $sub .= "-$count";
    $data->{'split'} = $count;
  }

  # Open and lock the subarchive; we're now in a critical section
  $fh = new Mj::File;
  $fh->open("$dir/$self->{'list'}.$sub", ">>");
  $data->{'byte'} = $fh->tell;

  # Grab the overall counts for the archive 
  $self->_read_counts($sub, 1);
  $self->_read_counts($arc, 1);

  # Figure out the proper message number, which is from the unsplit count
  # file.
  $self->{state}{msgno} = $self->{splits}{$arc}{msgs}+1;

  # Save some state
  $self->{state}{'sub'}  = $sub;
  $self->{state}{arc}    = $arc;
  $self->{state}{data}   = $data;
  $self->{state}{fh}     = $fh;
  $self->{state}{sender} = $sender;

  # Return the full message number
  "$arc/$self->{state}{msgno}";
}

sub add_done {
  my $self = shift;
  my $file = shift;
  my $log    = new Log::In 150, "$file";
  my ($time, $from_line, $th);

  # Restore some things from saved state
  my $arc    = $self->{'state'}{'arc'};
  my $sub    = $self->{'state'}{'sub'};
  my $data   = $self->{'state'}{'data'};
  my $sender = $self->{'state'}{'sender'};
  my $fh     = $self->{'state'}{'fh'};
  my $msgno  = $self->{'state'}{'msgno'};

  # Find the starting line of the new message
  $data->{'line'}  = $self->{splits}{$sub}{lines}+1;
  $data->{'bytes'} = (stat($file))[7];

  $self->_make_index($arc);

  # Generate and append the mbox separator if necessary
  if ($sender) {
    if ($data->{'time'}) {
      $time = localtime($data->{'time'});
    }
    else {
      $time = localtime;
    }
    $from_line = "From $sender  $time\n";
    $fh->print($from_line);
    $data->{'lines'}++;
    $data->{'bytes'} += length($from_line);
  }

  # Copy in the message
  $th = new IO::File "<$file";
  $log->abort("Couldn't read message file $file: $!") unless $th;
  while (defined ($_ = $th->getline)) {
    # XXX Error check the print
    $fh->print($_);
    $data->{lines}++;
  }
  
  # Close the message
  $th->close;

  # Print the blank line separator
  $fh->print("\n");
  $data->{'lines'}++;
  # Don't increment the byte count; seek counts from zero so we have to
  # subtract one somewhere.

  # Print out the new count files; additionally do the main archive if
  # splitting by size.
  $self->{splits}{$sub}{lines} += $data->{lines};
  $self->{splits}{$sub}{msgs}++;
  $self->_write_counts($sub);
  if ($arc ne $sub) {
    $self->{splits}{$arc}{lines} += $data->{lines};
    $self->{splits}{$arc}{msgs}++;
    $self->_write_counts($arc);
  }

  # Append the line containing the info to index
  $self->{'indices'}{$arc}->add("", $msgno, $data);
  
  # Close the archive
  $fh->close()
    or $::log->abort("Unable to close archive $arc: $!");

  # Return the message number - yyyymmdd/#####
  ("$arc/$msgno", $data);
}

=head2 find (regex)

Returns a list of archive files which match a regular expression

=cut 
use Mj::Util qw(re_match);
sub find {
  my $self = shift;
  my $regex = shift;
  my $log = new Log::In 150, $regex;
  my (@arcs, @out);
  @out = ();

  opendir (ARCDIR, $self->{'dir'}) 
    or return;

  @arcs = grep { s/^$self->{'list'}\.// } readdir ARCDIR;
  closedir ARCDIR;

  for (@arcs) {
    push @out, $_ if re_match($regex, $_);
  }

  @out;
}
   
=head2 remove(message_num, data)

This takes a message number (as "archive/number") and deletes it
from the archive.  If data is not provided, it is looked up from the
index.

=cut
use Mj::FileRepl;
sub remove {
  my $self = shift;
  my $msg  = shift;
  my $data = shift;
  my $log = new Log::In 150, $msg;
  my ($arc, $buf, $count, $dir, $fh, $file, $i, $res, $size, $sub);

  # Figure out appropriate index database and message number
  ($arc, $msg) = $msg =~ m!([^/]+)/(.*)!;
  $dir = $self->{dir};

  # Always look up the data for the message
  $self->_make_index($arc);
  $data = $self->{'indices'}{$arc}->lookup($msg);
  return (0, "Unable to lookup message data") 
    unless $data;
  
  $self->_read_counts($arc, 1);
  if ($self->{'splits'}{$arc}{'msgs'} == $msg) {
    for ($i = $msg - 1; $i > 0; $i--) {
      last if $self->{'indices'}{$arc}->lookup($i);
    }
    $self->{'splits'}{$arc}{'msgs'} = $i;
  }
  $self->{'splits'}{$arc}{'lines'} -= $data->{'lines'};

  # Open FH on appropriate split
  if (length $data->{'split'} and $data->{'split'} ne '0') {
    # Untaint
    if ($data->{'split'} =~ /(\d+)/) {  
      $sub = "$arc-$1";
      $self->_read_counts($sub, 1);
      $self->{'splits'}{$sub}{'msgs'}--;
      $self->{'splits'}{$sub}{'lines'} -= $data->{'lines'};
      $file= "$dir/$self->{'list'}.$sub";
    }
    else {
      $sub = $arc;
    }
  }
  else {
    $sub = $arc;
    $file= "$dir/$self->{'list'}.$arc";
  }
  $fh = new Mj::FileRepl $file;
  return (0, "Unable to open the new archive: $!") unless $fh;

  # Copy the original archive up to the beginning of the deleted message.
  for ($count = $data->{byte} ; $count > 0; ) {
    $size = $count > 4096 ? 4096 : $count;
    $res = $fh->{'oldhandle'}->read($buf, $size);
    if (!$res) {
      $fh->abandon;
      return (0, "Unable to read from the archive: $!");
    }
    $count -= $res;
    $fh->{'newhandle'}->print($buf);
  }

  # Seek to message end and copy the remainder of the file.
  $fh->{'oldhandle'}->seek($data->{byte} + $data->{bytes} + 1, 0);
  $fh->copy;
  $fh->commit;

  my $realign = sub {
    my $key = shift;
    my $values = shift;
    
    if ($key > $msg) {
      $values->{'byte'} -= ($data->{'bytes'} + 1);
      $values->{'line'} -= $data->{'lines'};
      return (0, 1);
    }
    elsif ($key == $msg) {
      return (1, 1, undef);
    }
    return (0, 0);
  };

  $self->{'indices'}{$arc}->mogrify($realign);

  $self->_write_counts($arc);
  if ($arc ne $sub) {
    $self->_write_counts($sub);
  }

  # Return
  (1, $data);
}

=head2 replace(message_num, message_file, tmpdir, quote_pattern)

This takes a message number (as "archive/number") and replaces it
with the contents of a new file. 

=cut
use Mj::FileRepl;
sub replace {
  my $self = shift;
  my $msg  = shift;
  my $msgfile = shift;
  my $tmpdir = shift;
  my $qp = shift;
  my $owner = shift;
  my $log = new Log::In 150, $msg;
  my ($arc, $buf, $count, $data, $dir, $fh, $file, $i, $newfh, 
      $res, $size, $sub);

  # Figure out appropriate index database and message number
  ($arc, $msg) = $msg =~ m!([^/]+)/(.*)!;
  $dir = $self->{dir};

  # Always look up the data for the message
  $self->_make_index($arc);
  $data = $self->{'indices'}{$arc}->lookup($msg);
  return (0, "Unable to lookup message data") 
    unless $data;
  return (0, "Unable to locate the replacement message") 
    unless (defined $msgfile and -f $msgfile);
  
  $self->_read_counts($arc, 1);
  if ($self->{'splits'}{$arc}{'msgs'} == $msg) {
    for ($i = $msg - 1; $i > 0; $i--) {
      last if $self->{'indices'}{$arc}->lookup($i);
    }
    $self->{'splits'}{$arc}{'msgs'} = $i;
  }
  $self->{'splits'}{$arc}{'lines'} -= $data->{'lines'};

  # Open FH on appropriate split
  if (length $data->{'split'} and $data->{'split'} ne '0') {
    # Untaint
    if ($data->{'split'} =~ /(\d+)/) {  
      $sub = "$arc-$1";
      $self->_read_counts($sub, 1);
      $self->{'splits'}{$sub}{'msgs'}--;
      $self->{'splits'}{$sub}{'lines'} -= $data->{'lines'};
      $file= "$dir/$self->{'list'}.$sub";
    }
    else {
      $sub = $arc;
    }
  }
  else {
    $sub = $arc;
    $file= "$dir/$self->{'list'}.$arc";
  }

  $newfh = new IO::File $msgfile;
  return (0, "Unable to open the archive: $!") unless $newfh;

  $fh = new Mj::FileRepl $file;
  return (0, "Unable to open the new archive: $!") unless $fh;

  # Copy the original archive up to the beginning of the deleted message.
  for ($count = $data->{byte} ; $count > 0; ) {
    $size = $count > 4096 ? 4096 : $count;
    $res = $fh->{'oldhandle'}->read($buf, $size);
    if (!$res) {
      $fh->abandon;
      return (0, "Unable to read from the archive: $!");
    }
    $count -= $res;
    $fh->{'newhandle'}->print($buf);
  }

  $buf = "From $owner  " . localtime($data->{'date'}) . "\n";
  $fh->{'newhandle'}->print($buf);
  
  while ($buf = $newfh->getline) {
    $fh->{'newhandle'}->print($buf);
  }

  # Seek to message end and copy the remainder of the file.
  $fh->{'oldhandle'}->seek($data->{byte} + $data->{bytes} + 1, 0);
  $fh->copy;
  $fh->commit;

  $self->sync($arc, $tmpdir, $qp);

  # Return the data for the replacement message
  return (1, $self->{'indices'}{$arc}->lookup($msg));
}

=head2 sync(archive_file, temporary_dir, quote_pattern)

Parse an archive of messages and extract the data for the index.
If the archive has not previously been indexed, create a new one.
If the archive has previously been indexed, assign new message
data to messages lacking an X-Archive-Number header, with 
sequence numbering starting where the old archive left off.

=cut
use File::Basename;
sub sync {
  my $self = shift;
  my $arc  = shift;
  my $tmpdir = shift;
  my $qp = shift;
  my $log  = new Log::In 250, "$arc, $qp";
  my (@msgs, $btotal, $count, $data, $ltotal, $num, $ok, $split, 
      $sub, $values);

  # Untaint the archive name.
  $arc = basename($arc);
  $arc =~ /^((?:[\w\-\.]+\.)?\d+)(-\d\d)?$/;
  $sub = defined $2 ? "$1$2" : $1;
  $split = defined $2 ? substr $2, 1, 2 : '';
  return (0, "Illegal archive name: \"$arc\"\n") unless $sub;
  $arc = $1;

  # Verify that the file in question exists.  
  return (0, "No such archive:  \"$sub\"\n") 
    unless (-f "$self->{'dir'}/$self->{'list'}.$sub");

  # If an index exists for the archive, load its counts.
  if (exists $self->{'archives'}{$arc}) {
    $self->_read_counts($arc, 1);
    if ($arc ne $sub and exists $self->{'splits'}{$sub}) { 
      $self->_read_counts($sub, 1);
    }
    # Keep track of highest message number.
    $count = $self->{'splits'}{$arc}{'msgs'};
  }
  else {
    $count = 0;
  }

  # Add X-Archive-Number headers to the archive and collect data.
  # The first return value is a count of messages.
  ($ok, @msgs) = $self->_sync_msgs($sub, $tmpdir, $split, $count, $qp);

  unless ($ok > 0) {
    return (0, $msgs[0]);
  }

  # instantiate the archive
  return (0, "Unable to create index.\n") unless $self->_make_index($arc);

  # remove all entries with the same "split" from the index. 
  my $erase = sub {
    my $key = shift;
    my $values = shift;
   
    if ($values->{'split'} eq $split) {
      return (1, 1, undef);
    }
    return (0, 0);
  };

  # modify the index, removing all data for this split
  $self->{'indices'}{$arc}->mogrify($erase);
  $ltotal = 0;
  $btotal = 0;

  for $data (@msgs) {
    ($num, $values) = @$data;
    $values->{'line'} = $ltotal + 1;
    $values->{'byte'} = $btotal;
    $ltotal += $values->{'lines'};
    $btotal += $values->{'bytes'};
    $values->{'bytes'}--;
    $self->{'indices'}{$arc}->add('', $num, $values);
    $count = $num if ($num > $count);
  }

  if (exists $self->{'splits'}{$arc}{'lines'}) {
    $self->{'splits'}{$arc}{'lines'} += 
      $ltotal - $self->{'splits'}{$sub}{'lines'};
    $self->{'splits'}{$arc}{'msgs'} = $count;
  }
  else {
    $self->{'splits'}{$arc}{'lines'} = $ltotal;
    $self->{'splits'}{$arc}{'msgs'} = $ok;
  }
  $self->_write_counts($arc);

  if ($arc ne $sub) {
    $self->{'splits'}{$sub}{'lines'} = $ltotal;
    $self->{'splits'}{$sub}{'msgs'} = $ok;
    $self->_write_counts($sub);
  }

  (1, "Archive \"$sub\", containing $self->{'splits'}{$sub}{'msgs'} messages,"
   . " has been synchronized.\n");
}

=head2 _sync_msgs(file, tmpdir, split, message_count, quote_pattern) 

Processes an archive to collect data and add headers.
Replaces the old archive with the new.
Returns a count of messages and a hash with data for each message.

=cut
use Mj::FileRepl;
use Mj::MIMEParser;
sub _sync_msgs {
  my ($self, $file, $tmpdir, $split, $count, $qp) = @_;
  my $log = new Log::In 250, $file;
  my (@out, $arcname, $arcnum, $blank, $data, $entity, $line, 
      $lines, $mbox, $num, $parser, $seen, $tmpfh, $tmpfile); 
 
  $file =~ /^((?:[\w\-\.]+\.)?\d+)(-\d\d)?$/;
  $arcname = $1;
  $mbox = new Mj::FileRepl("$self->{'dir'}/$self->{'list'}.$file");
  return (0, "Unable to replace archive $file.\n") unless $mbox;

  $tmpfile = Majordomo::tempname();
  $tmpfh =  new IO::File "> $tmpfile";
  return (0, "Unable to open temporary file.\n") unless $tmpfh;

  $parser = new Mj::MIMEParser;
  return (0, "Unable to create parser.\n") unless $parser;
  $parser->output_dir($tmpdir);

  $lines = $seen = 0;
  $count++;
  $data = {};
  $blank = 1;

  while (1) {
    $line = $mbox->{'oldhandle'}->getline; 
    if ($blank && (!$line or 
      $line =~ /^From\s+(?:"[^"]+"@\S+|\S+)\s+\S+\s+\S+\s+\d+\s+\d+:\d+:\d+\s+\d+/
    )) {
      # If a message has been seen, close the temporary file
      # and update the index.
      if ($seen) {
        $tmpfh->close() 
          or $::log->abort("Unable to close file $tmpfile: $!");
        $entity = $parser->parse_open($tmpfile);
        return (0, "Unable to parse mailbox.\n") unless $entity;
        $arcnum = $entity->head->get("X-Archive-Number");
        unless (defined $arcnum and $arcnum =~ m#$arcname/\d+#) {
          $arcnum = "$arcname/$count";
          $entity->head->replace("X-Archive-Number", $arcnum);
          $count++;
        }
        $arcnum =~ m#/(\d+)$#; $num = $1;
        $data = Mj::MIMEParser::collect_data($entity, $qp);
        $data->{'bytes'} = (stat($tmpfile))[7];
        $data->{'lines'} = $lines;
        $data->{'split'} = $split;
        push @out, [$num, $data];
        $lines = 0;

        $entity->print($mbox->{'newhandle'});
        $entity->purge;
        last unless $line;
        $mbox->{'newhandle'}->print($line);
        # reopen the temporary file
        $tmpfh =  new IO::File "> $tmpfile";
        return (0, "Unable to open temporary file.\n") unless $tmpfh;
      }
      else {
        $mbox->{'newhandle'}->print($line) if ($line);
      }
      $seen++;
      $blank = 0;
    }
    elsif ($seen and !$blank) {
      $blank = ($line =~ m#\A\Z#o) ? 1 : 0;
    }
    last unless $line;
    $lines++;
    $tmpfh->print($line);
  }
  $mbox->commit;
  $tmpfh->close();
    # or $::log->abort("Unable to close file $tmpfile: $!");
  unlink $tmpfile;

  ($seen, @out);
}

=head2 get_message(message_num, data)

This takes a message number (as archive/number) and sets up the archive''s
iterator to read it.  If data is not provided, it is looked up from the
index.

What to return?  Perhaps all useful message data, in a hashref?

=cut
use Mj::File;
sub get_message {
  my $self = shift;
  my $msg  = shift;
  my $data = shift;
  my $log = new Log::In 150, "$msg";
  my ($arc, $dir, $fh, $file);

  # Figure out appropriate index database and message number
  ($arc, $msg) = $msg =~ m!([^/]+)/(.*)!;
  $dir = $self->{dir};
  $file= "$dir/$self->{'list'}.$arc";

  unless ($data) {
    # Look up the data for the message
    $self->_make_index($arc);
    $data = $self->{'indices'}{$arc}->lookup($msg);
    return unless $data;
  }

  # Open FH on appropriate split
  if (length($data->{'split'})) {
    # Untaint
    $data->{'split'} =~ /(\d+)/;  $arc = $1;
    $fh = new Mj::File "$file-$arc";
  }
  else {
    $fh = new Mj::File "$file";
  }

  # Seek to byte offset
  $fh->seek($data->{byte}, 0);

  # Stuff handle
  $self->{get_handle} = $fh;
  $self->{get_count}  = 0;
  $self->{get_max}    = $data->{bytes};

  # Return
  $data;
}

=head2 get_neighbors(msg, data, re_pattern, private)

Obtain information about the preceding and succeeding messages
for a particular message within an archive for each sort order 
(numeric, author, date, subject, and thread).

=cut
use Mj::Util qw(sort_msgs);
sub get_neighbors {
  my $self = shift;
  my $msg  = shift;
  my $data = shift;
  my $pattern = shift;
  my $private = shift;
  my $log = new Log::In 150, $msg;
  my (@msgs, @tmp, $arc, $i, $j, $msgno, $sort);

  # Figure out appropriate index database and message number
  ($arc, $msgno) = $msg =~ m!([^/]+)/(.*)!;

  $data->{'archive'} = $arc;
  @tmp = $self->get_all_data($arc);
  while (($i, $j) = splice @tmp, 0, 2) {
    push @msgs, ["$arc/$i", $j];
  }

  for $sort (qw(numeric author date thread subject)) {
    $data->{"${sort}_prev"} = '';
    $data->{"${sort}_next"} = '';
    unless ($sort eq 'numeric') {
      @msgs = sort_msgs(\@msgs, $sort, $pattern);
    }
    for ($i = 0; $i <= $#msgs; $i++) {
      if ($msgs[$i]->[0] eq $msg) {
        for ($j = $i - 1 ; $j >= 0 ; $j--) {
          unless ($private and $msgs[$j]->[1]->{'hidden'}) {
            $data->{"${sort}_prev"} = $msgs[$j]->[0];
            last;
          }
        }
        for ($j = $i + 1 ; $j <= $#msgs ; $j++) {
          unless ($private and $msgs[$j]->[1]->{'hidden'}) {
            $data->{"${sort}_next"} = $msgs[$j]->[0];
            last;
          }
        }
        last;
      }
    }
  }
      
  # Return the altered data
  $data;
}

=head2 get_line(file, line)

Starts the iterator on the message containing the given line from the given file.

=cut
sub get_line {

  # Call find_line;

  # Call get_message;
}

=head2 get_byte(file, byte)

Starts the iterator on the message containing the given byte.

=head2 get_chunk(size)

This reads a chunk of size bytes from the selected message.  The caller
should be sure not to read past the end of the message into the next one.

XXX There is probably at least one off-by-one error in here.

=cut
sub get_chunk {
  my $self = shift;
  my $size = shift;
  my $log  = new Log::In 200, "$size";
  my ($chunk, $bytes);

  return undef if $self->{get_count} >= $self->{get_max};

  if ($self->{get_count} + $size > $self->{get_max}) {
    $size = $self->{get_max} - $self->{get_count};
  }
  $bytes = $self->{get_handle}->read($chunk, $size);
  return undef unless $bytes;
  $self->{get_count} += $bytes;
  $chunk;
}

=head2 get_done

Closes the iterator.

=cut
sub get_done {
  my $self = shift;
  undef $self->{get_handle};
}

=head2 get_to_file(message, filename, data, skip)

Retrieves a message from the archive and places it in the given file, which
must be writable.  If a filename is not provided, one is generated
randomly.  If data is not provided, it is looked up from the index.

If skip is set, the initial "From " line will be discarded.

=cut
sub get_to_file {
  my $self = shift;
  my $msg  = shift;
  my $file = shift || Majordomo::tempname();
  my $data = $self->get_message($msg, shift);
  my $skip = shift || '';
  return unless $data;
  my $fh =   new IO::File ">$file";
  my $chunk;

  $::log->abort("Unable to open file $file: $!") unless ($fh);
  return unless (defined $self->{'get_handle'});

  if ($skip) {
    $chunk = $self->{'get_handle'}->getline;
    $self->{'get_count'} += length($chunk);
  }
  while (defined($chunk = $self->get_chunk(4096))) {
    $fh->print($chunk);
  }
  $self->get_done;
  $fh->close()
    or $::log->abort("Unable to close file $file: $!");
  ($data, $file);
}

=head2 get_all_data(archive)

Load all of the data for a particular archive into a list.

=cut
sub get_all_data {
  my $self = shift;
  my $arc  = shift;
  my $log = new Log::In 150, $arc;
  my (@chunk, @out, $data);

  @out = ();
  # Restore sublist name if needed.
  if ($self->{'sublist'} and $arc !~ /^$self->{'sublist'}/) {
    $arc = "$self->{'sublist'}.$arc";
  }

  return unless $self->_make_index($arc);
  return unless $self->{'indices'}{$arc}->get_start;
  while (@chunk = $self->{'indices'}{$arc}->get(1000)) {
    push @out, @chunk;
  }
  $self->{'indices'}{$arc}->get_done;
  @out;
}

=head2 get_data(message)

This just retrieves the data for a message, or undef if the message does
not exist.

=cut
sub get_data {
  my $self = shift;
  my $msg  = shift;
  my $log = new Log::In 150, $msg;
  my ($arc, $data);

  # Figure out appropriate index database and message number
  ($arc, $msg) = $msg =~ m!([^/]+)/(.*)!;

  # Restore sublist name if needed.
  if ($self->{'sublist'} and $arc !~ /^$self->{'sublist'}/) {
    $arc = "$self->{'sublist'}.$arc";
  }

  return unless $self->_make_index($arc);

  # Look up the data for the message
  $self->{'indices'}{$arc}->lookup($msg);
}

=head2 last_message(archive)

Returns the name of the last message in an archive.

If $archive is undef, this looks up the last message in the archive,
period.

=cut
sub last_message {
  my $self = shift;
  my $arc  = shift;

  unless ($arc) {
    # Pick out the last archive in the list and strip the count and list
    # from it
    $arc = (grep {$_ =~ /^$self->{'sublist'}\.?\d/}
                 @{$self->{'sorted_archives'}})[-1];
  }
  
  # Restore sublist name if needed.
  if ($self->{'sublist'} and $arc !~ /^$self->{'sublist'}/) {
    $arc = "$self->{'sublist'}.$arc";
  }

  # Read the counts for this archive
  $self->_read_counts($arc, 0);

  # Take the maximum count and build a message name
  return "$arc/$self->{'splits'}{$arc}{'msgs'}";
}

=head2 first_n(count, m, archive)

Returns the first count message names from the archive, excluding
the first m names.

=cut
sub first_n {
  my $self = shift;
  my $n    = shift;
  my $ct   = shift || 0;
  my $arc  = shift;
  my (@arcs, @data, @msgs, $final, $key, $msg, $tmp, $value);
  @msgs = ();

  if ($arc and $self->{'sublist'}) {
    $arc = "$self->{'sublist'}.$arc";
  }
  # @arcs will hold all archives newer than $arc, if given
  if ($arc) {
    @arcs = grep { $_ =~ /^$self->{'sublist'}\.?\d/ } 
             @{$self->{'sorted_archives'}};
    while ($tmp = shift @arcs) {
      last if ($tmp eq $arc);
    }
  }
  else {
    @arcs = grep { $_ =~ /^$self->{'sublist'}\.?\d/ }               
               @{$self->{'sorted_archives'}};
  }

  $arc ||= shift @arcs;
  return unless $arc;

  ($final) = $self->last_message($arc) =~ m!^[^/]+/(.*)$!;

  while ($ct >= $final) {
    $ct -= $final;
    $arc = shift @arcs;
    last unless $arc;
    ($final) = $self->last_message($arc) =~ m!^[^/]+/(.*)$!;
  }

  while ($arc) {
    @data = $self->get_all_data($arc);
    while (@data and $ct > 0) {
      shift @data; shift @data;
      $ct--;
    }
    while (@data and $n > 0) {
      $key = shift @data;
      $value = shift @data;
      push @msgs, ["$arc/$key", $value];
      $n--;
    }
    last if ($n <= 0);
    $arc = shift @arcs;
  }
  @msgs;
}

=head2 last_n(count, last, archive)

Returns the last count message names from the archive.

=cut
sub last_n {
  my $self = shift;
  my $n    = shift;
  my $ct   = shift || 0;
  my $arc  = shift;
  my (@arcs, @data, @msgs, $final, $key, $msg, $tmp, $value);
  @msgs = ();

  if ($arc and $self->{'sublist'}) {
    $arc = "$self->{'sublist'}.$arc";
  }
  # @arcs will hold all archives older than $arc, if given
  if ($arc) {
    @arcs = grep { $_ =~ /^$self->{'sublist'}\.?\d/ } 
              @{$self->{'sorted_archives'}};
    while ($tmp = pop @arcs) {
      last if ($tmp eq $arc);
    }
  }
  else {
    @arcs  = grep { $_ =~ /^$self->{'sublist'}\.?\d/ }               
               @{$self->{'sorted_archives'}};
  }

  $arc ||= pop @arcs;
  return unless $arc;

  ($final) = $self->last_message($arc) =~ m!\d+/(\d+)!;
 
  while ($ct >= $final) {
    $ct -= $final;
    $arc = pop @arcs;
    last unless $arc;
    ($final) = $self->last_message($arc) =~ m!\d+/(\d+)!;
  }

  while ($arc) {
    @data = $self->get_all_data($arc);
    while (@data and $ct > 0) {
      pop @data; pop @data;
      $ct--;
    }
    while (@data and $n > 0) {
      $value = pop @data;
      $key = pop @data;
      unshift @msgs, ["$arc/$key", $value];
      $n--;
    }
    last if ($n <= 0);
    $arc = pop @arcs;
  }
  @msgs;
}

=head2 expand_date(date, date)
  
This returns all messages from a given time or between two times.  The
times are seconds since the epoch began (January 1, 1970).  The ct
argument sets a limit to the number of matches returned.

=cut
sub expand_date {
  my $self  = shift;
  my $s = shift;
  my $e = shift || $s;
  my $ct = shift || 65535;
  my (@arcs, $arc, $date, @matches, @tmp, $ea, $i, $j, $k, $l, $match, $sa);
  my (@out) = ();
 
  # Extract the names of all archives overlapping requested interval
  # Use only archives corresponding to the sublist.
  for $arc (@{$self->{'sorted_archives'}}) {
    next unless $arc =~ /^$self->{'sublist'}\.?\d/;
    # separate sublist from archive name
    $date = $arc;  $date =~ s/$self->{'sublist'}\.?(\d.+)/$1/;
    $sa = _secs_start($date, 1);
    if ($sa >= $s && $sa <= $e) {
      $ct > 0 ? push @arcs, $arc : unshift @arcs, $arc;
    }
    else {
      $ea = _secs_end($date, 1);
      if (($ea >= $s && $ea <= $e) or ($s >= $sa && $e <= $ea)) {
        $ct > 0 ? push @arcs, $arc : unshift @arcs, $arc;
      }
    }
  }

  $match = sub {
    shift;
    my $date = (shift)->{'date'};
    return 0 unless (defined $date and $date >= $s and $date <= $e);
    1;
  };

  for $i (@arcs) {
    $self->_make_index($i);
    $self->{'indices'}{$i}->get_start;
    while (1) {
      @tmp = $self->{'indices'}{$i}->get_matching(100, $match);
      last unless scalar(@tmp);
      push @matches, @tmp;
    }
    # If ct is negative, the archives are being processed
    #  in reverse chronological order, so we must reverse
    #  the results for each archive, then reverse the
    #  result from all archives before returning.
    if ($ct < 0) {
      while (($j, $k) = splice(@matches, 0, 2)) {
        unshift @tmp, $j, $k;
      }
      @matches = @tmp;  
    }
    $self->{'indices'}{$i}->get_done;
    while (($j, $k) = splice(@matches, 0, 2)) {
      push @out, ["$i/$j", $k];
      last if (scalar(@out) >= abs($ct));
    }
    last if (scalar(@out) >= abs($ct));
  }
  if ($ct < 0) {
    @out = reverse @out;
  }
  @out;
}

=head2 _secs_start(date, local)

Returns the seconds count at the beginning of the given 'date'.

If local is true, the date is assumed to be in local time, else it is
assumed to be in GMT.

=cut
use Time::Local;
sub _secs_start {
  my $d = shift;
  my $local = shift;
  my ($i, $tmp);

  # Convert the data into yyyymmmdd format
  if ($d =~ /^\d$/) {
    $d += 2000;
  }
  elsif ($d =~ /^\d{2,3}$/) {
    $d += 1900;
  }

  unless ($d =~ /^(20|19)/) {
    $i = substr($d, 0, 2);
    if ($i >= 70) {
      $d = '19' . $d;
    }
    else {
      $d = '20' . $d;
    }
  }

  if ($d =~ /^\d{4}$/) {
    $d .= '0101';
  }
  elsif ($d =~ /^(\d{4})(\d)$/) {
    $d = $1; $tmp = $2;
    $tmp = 1 if ($tmp < 1);
    $tmp = 4 if ($tmp > 4);
    $d .= sprintf "%.2d01", $tmp * 3 - 2;
  }
  elsif ($d =~ /^\d{6}$/) {
    $d .= '01';
  }
  elsif ($d =~ /^(\d{6})(\d)$/) {
    # Turn week 1, 2, 3, 4 into day 1, 8, 15, 22
    my ($wk) = $2;
    $wk = 4 if $wk > 4;
    $wk = 1 if $wk < 1;
    $d = $1 . ($wk<3?"0":"") . (($wk - 1) * 7) + 1;
  }
  elsif ($d =~ /^(\d{8})/) {
    $d = $1;
  }

  # Now convert that to seconds
  $d =~ /^(\d{4})(\d{2})(\d{2})$/ or return -1;

  # timelocal and timegm croak if parameters are out of range
  return -1 if ($2 < 1 || $2 > 12 || $3 < 1 || $3 > 31);

  if ($local) {
    return timelocal(0,0,0,$3,$2-1,$1);
  }
  else {
    return timegm(0,0,0,$3,$2-1,$1);
  }
}

=head2 _secs_end(date)

Returns the seconds count at the end of the given 'date'.

=cut
use Time::Local;
sub _secs_end {
  my $d = shift;
  my $local = shift;
  my ($i, $tmp);

  # Convert the data into yyyymmmdd format
  if ($d =~ /^\d$/) {
    $d += 2000;
  }
  elsif ($d =~ /^\d{2,3}$/) {
    $d += 1900;
  }

  unless ($d =~ /^(20|19)/) {
    $i = substr($d, 0, 2);
    if ($i >= 70) {
      $d = '19' . $d;
    }
    else {
      $d = '20' . $d;
    }
  }

  if ($d =~ /^\d{4}$/) {
    $d .= '1231';
  }
  elsif ($d =~ /^(\d{4})(\d)$/) {
    $d = $1; $tmp = $2;
    $tmp = 1 if ($tmp < 1);
    $tmp = 4 if ($tmp > 4);
    $d .= sprintf "%.2d%.2d", $tmp * 3, _dim($tmp * 3);
  }
  elsif ($d =~ /^(\d{4})(\d{2})$/) {
    $d .= _dim($2);
  }
  elsif ($d =~ /^(\d{4})(\d{2})(\d)$/) {
    # Turn week 1, 2, 3, 4 into day 7, 14, 21, (28, 30, 31)
    if ($3 >= 4) {
      $d = $1 . $2 . _dim($2);
    }
    else {
      $d = $1 . $2 . ($3<=1? "07": $3 * 7);
    }
  }
  elsif ($d =~ /^(\d{8})/) {
    $d = $1;
  }

  # Now convert that to seconds
  $d =~ /^(\d{4})(\d{2})(\d{2})$/ or return -1;

  # timelocal and timegm croak if parameters are out of range
  return -1 if ($2 < 1 || $2 > 12 || $3 < 1 || $3 > 31);

  if ($local) {
    return timelocal(59,59,23,$3,$2-1,$1);
  }
  else {
    return timegm(59,59,23,$3,$2-1,$1);
  }
}

# Days in month.
sub _dim {
  my $m = shift;
  return 28 if $m == 2;
  return 30 if $m == 2 || $m == 4 || $m == 6 || $m == 9 || $m == 11;
  31;
}

=head2 find_line

Returns the number of the message containing the given line.

=head2 find_byte

Returns the number of the message containing the given byte.

=cut


=head2 index_name(file)

Given the name of an archive file, return the path to the index file.

=cut
sub index_name {
  my $self = shift;
  my $file = shift;

  # Look up archive directory; tack it on, with I

}

sub count_name {
  my $self = shift;
  my $file = shift;

  # Look up archive dir, tack on with C

}

=head2 _msgnum 

Extracts the message number within an archive from the full message
identifier.

=cut
sub _msgnum {
  my $a = shift;
  $a =~ /(.*)\.(.*)/;
  $2;
}

=head2 _arc_name

Gives the base name of the archive file for a given split and a given time.

=cut
sub _arc_name {
  my $split = shift;
  my $time  = shift || time;
  my $log = new Log::In 200, "$split, $time";
  my ($mday, $month, $quarter, $week, $year);

  # Extract data from the given time
  ($mday, $month, $year) = (localtime($time))[3,4,5];

  # Week 1 is from day 0 to day 6, etc.
  $week = 1 + int(($mday-1)/7);
  $year += 1900;
  $quarter = 1 + int($month/3);
  $month++;
  $month = "0$month" if $month < 10;
  $mday  = "0$mday"  if $mday  < 10;

  return "$year"            if $split eq 'yearly';
  return "$year$quarter"    if $split eq 'quarterly';
  return "$year$month"      if $split eq 'monthly';
  return "$year$month$week" if $split eq 'weekly';
  return "$year$month$mday" if $split eq 'daily';
}

=head2 summary

Return a list of all archives, along with the message count for
each archive.

=cut
sub summary {
  my $self = shift;
  my (@out, $arc);

  for $arc (@{$self->{'sorted_splits'}}) {
    $self->_read_counts($arc, 0);
    push @out, [$arc, $self->{'splits'}{$arc}]
      if (exists($self->{'splits'}{$arc}) and 
          $self->{'splits'}{$arc}{'msgs'});
  }

  @out;
}

=head2 _read_counts

Loads in the sizing data for an archive or a subarchive.  This really
expects that the index file exists; else some default values are set.

=cut
sub _read_counts {
  my $self = shift;
  my $file = shift;
  my $force = shift || 0;
  my $dir = $self->{dir};
  my $log = new Log::In 200, "$file";
  my ($fh, $list, $tmp);

  return if (defined $self->{splits}{$file}{bytes} and ! $force);

  $list = $self->{'list'};

  if (-f "$dir/.index/C$list.$file") {
    $self->{splits}{$file}{bytes} = (stat("$dir/$list.$file"))[7];
    $fh = new IO::File "<$dir/.index/C$list.$file";
    # XLANG
    $log->abort("Can't read count file $dir/.index/C$list.$file: $!") unless $fh;
    $tmp = $fh->getline;
    chomp $tmp;
    $self->{splits}{$file}{lines} = $tmp;
    $tmp = $fh->getline;
    chomp $tmp;
    $self->{splits}{$file}{msgs} = $tmp;
    $fh->close()
      or $::log->abort("Unable to close file C$list.$file: $!");
  }
  else {
    $self->{'splits'}{$file}{bytes} = 0;    
    $self->{'splits'}{$file}{lines} = 0;
    $self->{'splits'}{$file}{msgs}  = 0;
  }
}

=head2 _write_counts

Writes out the count file for a given file.  This depends on the data
stored in the archive object being correct.

=cut
sub _write_counts {
  my $self  = shift;
  my $file  = shift;
  my $dir   = $self->{dir};
  my $log   = new Log::In 200, "$file";
  my ($fh, $list);

  $list = $self->{'list'};

  unless ($self->{splits}{$file}{msgs}) {
    unlink "$dir/.index/C$list.$file";
    unlink "$dir/.index/I$list.$file";
    return 1;
  }

  $fh = new IO::File ">$dir/.index/C$list.$file";
    # XLANG
  $log->abort("Can't write count file $dir/.index/C$list.$file: $!") unless $fh;
  $fh->print("$self->{splits}{$file}{lines}\n") ||
    $log->abort("Can't write count file $dir/.index/C$list.$file: $!");
  $fh->print("$self->{splits}{$file}{msgs}\n") ||
    $log->abort("Can't write count file $dir/.index/C$list.$file: $!");
  $fh->close()
    or $::log->abort("Unable to close file C$list.$file: $!");
}

=head2 _make_index

Instantiates the index for a particular archive.

=cut
sub _make_index {
  my ($self, $arc) = @_;

  unless ($self->{'indices'}{$arc}) {
    my $idx = "$self->{'dir'}/.index/I$self->{'list'}.$arc";
    $self->{'indices'}{$arc} = new Mj::SimpleDB(filename => $idx,
						backend  => 'text',
						fields   => \@index_fields,
					       );
  }

  return $self->{'indices'}{$arc};
}

=head2 expand_range

Takes a range of articles and expands it into a list of articles.

  By named messages:
    199805/12 199805/15

  By a message count (last 10 messages):
     10

  By a range of names:
    199805/12 - 199805/20

  By a message and a count:
     199805/12 - 10
  
  Ranges of names can span dates:
    199805/12 - 199806/2

  By date:
    19980501

  By date range:
    19980501 - 19980504

A limit on the size of the returned article list can be set.

If the data for an article is known when the range is expanded, it will be
returned as a [number, data] listref.  Otherwise it will just be returned
as a string.  This spares extraneous lookups when the data is known because
of the expansion process.

=cut
use Mj::Util 'str_to_offset';
sub expand_range {
  my $self = shift;
  my $lim  = shift;
  my $args = shift; 
  my $private = shift;
  my (@out, @args, @tmp, $data, $i, $j, $ct, $a1, $m1, $a2, $m2, $tmp);

  @args = split " ", $args;
  # Walk the arg list
  while (defined($i = shift(@args))) {
    $a1 = $a2 = $m1 = $m2 = 0;
    return @out if $lim && $#out > $lim;
    # Skip commas and bomb on dashes
    next if $i eq ',';
    return if $i eq '-';

    if ($i =~ /^([\w\.]+)\.([\d\/\-a-z]+)$/) {
      $self->{'sublist'} = $1;
      $i = $2;
    }
    else {
      $self->{'sublist'} = '';
    }
    # Remove date separator.
    $i =~ s/(\d)[\-](\d)/$1$2/g;

    # Deal with "mwdhmis" format
    if ($i =~ /^\d[\da-z]*[a-z]$/) {
      $j = time;
      $tmp = &str_to_offset($i, 0, 0);
      next unless (defined($tmp) and $tmp > 0);
      $i = $j - $tmp;
      next unless $i;
      push @out, $self->expand_date($i, $j, '');
      next;
    }

    # Do we have a count, a date or a message?
    ($a1, $m1) = $self->_parse_archive_arg($i);
    if (!$a1 && !$m1) {
      # Invalid value; discard other range argument if present.
      if (@args && $args[0] eq '-') {
        shift @args; shift @args;
      }
      next;
    }
    # Get right hand side of range if present.
    if (@args && $args[0] eq '-') {
      shift @args; $j = shift @args;
      ($a2, $m2) = $self->_parse_archive_arg($j);
      next if (!$a2 && !$m2);
    }
    else {
      #  Deal with single values
      if (!$m1) {
	    # Expand date to all messages on that date; push into @out
        $j = _secs_end($i, 1);
        $i = _secs_start($i, 1);
        push @out, $self->expand_date($i, $j);
      }
      elsif (!$a1) {
        # ordinary number
        push @out, $self->last_n($m1);
      }
      else {
        # message number
        # Restore sublist if necessary
        if ($self->{'sublist'}) {
          $i = "$self->{'sublist'}.$i";
        }
        push (@out, [$i, $j]) if ($j = $self->get_data($i));
      }
      next;
    }

    #  Deal with ranges.  There are nine possibilities at this point,
    #    permutations of pairs of (date, 0) , (0, number), (date, number).
    if (!$a1 && !$a2) {
      #  Number range.  100 - 20 would return 100 messages ending with
      #  The 20th previous message.
      push @out, $self->last_n($m1, $m2);
    }
    elsif ($m1 && $m2) {
      # Message range
      push @out, $self->_parse_message_range($a1, $m1, $a2, $m2);
    }  
    else {
	  # Date range
      if (!$a1) {
        # number - date
        $i = 0;
        $j = _secs_end($a2);
        $ct = -$m1;
      }
      elsif (!$a2) {
        # date - number
        $i = _secs_start($a1);
        $j = time;
        $ct = $m2;
      }
      elsif ($m1) {
        # message - date
        $i = $self->get_data("$a1/$m1");
        $i = $i->{'date'};
        $j = _secs_end($a2);
        $ct = undef;
      }
      elsif ($m2) {
        # date - message
        $i = _secs_start($a1);
        $j = $self->get_data("$a2/$m2");
        $j = $j->{'date'};
        $ct = undef;
      }
      else {
        # date - date
        $i = _secs_start($a1);
        $j = _secs_end($a2);
        $ct = undef;
      }
      push @out, $self->expand_date($i, $j, $ct);
    }
  }
  $self->{'sublist'} = '';
  if ($private) {
    @tmp = ();
    for $i (@out) {
      ($j, $data) = @$i;
      unless (exists($data->{'hidden'}) and $data->{'hidden'}) {
        push @tmp, $i;
      }
    }
    @out = @tmp;
  }
  @out;
}

=head2 _parse_archive_arg(arg)

There are three possible arguments: 

=item Date or Archive Name

=item Natural Number

=item Message Number

(A combination of the first two.)

=cut
sub _parse_archive_arg {
    my $self = shift;
    my $arg = shift;
    my ($archive, $msg) = (0, 0);
    
    if ($arg =~ m#(\d+)/(\d+)#) {
      $archive = $1;
      $msg = $2;
    }
    elsif ($arg =~ /^(\d+)$/) {
      if (_secs_start($1, 1) > 0) {
        $archive = $1;
      }
      else {
        $msg = $arg;
      }
    }
    ($archive, $msg);
}

=head2 _parse_message_range(archive1, msgno1, archive2, msgno2)

=cut

sub _parse_message_range {
    my $self = shift;
    my ($arch1, $msg1, $arch2, $msg2) = splice (@_, 0, 4);
    my (@arcs, @out, $arc, $final, $num, $tmp);
    my $log = new Log::In 250, "$arch1 $msg1 $arch2 $msg2";

    if (!$msg1 || !$msg2 || !($arch1 || $arch2) || 
        ($arch2 and ($arch1 gt $arch2))) {
      return @out;
    }
    if (!$arch1) {
      # number - message; use last_n to retrieve preceding message numbers. 
      ($final) = $self->last_message($arch2) =~ m!^[^/]+/(.*)$!;
      # number of messages to skip
      $num = $final - $msg2;
      @out = $self->last_n($msg1, $num, $arch2);
    }
    elsif (!$arch2) {
      # message - number; use first_n to retrieve succeeding message numbers.
      @out = $self->first_n($msg2, $msg1 - 1, $arch1);
    }
    else {
      # message - message; 
      # Restore sublist name if needed.
      if ($self->{'sublist'} and $arch1 !~ /^$self->{'sublist'}/) {
        $arch1 = "$self->{'sublist'}.$arch1";
      }
      if ($self->{'sublist'} and $arch2 !~ /^$self->{'sublist'}/) {
        $arch2 = "$self->{'sublist'}.$arch2";
      }
      # @arcs will hold all archives newer than $arch1.
      @arcs = grep { $_ =~ /^$self->{'sublist'}\.?\d/ } 
                @{$self->{'sorted_archives'}};

      while ($arc = shift @arcs) {
        last if ($arc eq $arch1);
      }

      return @out unless $arc;

      $num = $msg1;
      ($final) = $self->last_message($arc) =~ m!^[^/]+/(.*)$!;

      while (($arc lt $arch2) || (($arc eq $arch2) && ($num <= $msg2))) {
        $tmp = $self->get_data("$arc/$num");
        if (defined $tmp) {
          push @out, ["$arc/$num", $tmp];
        }

        $num++;

        unless ($num <= $final) {
          # Move to next archive.
          $arc = shift @arcs;
          last unless $arc;
          # Set $final to its last message number
          ($final) = $self->last_message($arc) =~ m!^[^/]+/(.*)$!;
          $num = 1;
        }
      }
    }
    @out;
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
### mode:cperl ***
### cperl-indent-level:2 ***
### End: ***

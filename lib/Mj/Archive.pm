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
year, mm is the two digit month, and cc is a two digit count (could be week
number, or day number, or an arbitrary counter).

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
use Mj::File;
use Mj::Log;
use vars qw(@index_fields);

@index_fields = qw(byte bytes line lines body_lines quoted split date from
		   subject refs);

#use AutoLoader 'AUTOLOAD';
1;   
#__END__

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
  my($dh, $fh, $tmp);
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
  return undef unless defined $dh;
  while (defined($_ = $dh->read)) {
    if (s/^$list\.//) {
      $self->{'splits'}{$_} = {};
      $_ =~ /(.*)-\d\d/;
      if ($1) {
	$self->{'archives'}{$1} = {};
      }
      elsif ($size eq 'unlimited') {
	$self->{'archives'}{$_} = {};
      }
    }
  }
  return $self;
}

=head2 add(file, sender, datahashref)

This adds a message contained in a file to the archive.  A standard mbox
header is appended to the archive, followed by the file''s contents.

sender contains information for the mbox separator that is not contained in
the message.  If blank or undef, it is assumed that the message to be
appended already has an mbox separator prepended.

$data->{'date'} should be in seconds since 1970 and is used in determining
the proper archive to add the message to.  If it is blank or undef, the
current date is assumed.

$data->{'from'} should contain the stripped and canonical address of the
message poster.

$data->{'subject'} should contain the subject of the message.

$data->{'refs'} should contain the data from the References: header (a
comma-separated list of message-IDs in brackets), or the single message-ID
from the In-Reply-To: header.  Or nothing...

Throughout this routine, $arc is the name of the main archive while $sub is
the name of the subarchive (the archive with the split count appended).
$data holds info about the message being added.

=cut
sub add {
  my $self   = shift;
  my $file   = shift;
  my $sender = shift;
  my $data   = shift || {};
  my $log    = new Log::In 150, "$file";

  my($arc, $count, $dir, $fh, $from_line, $month, $msgno, $msgs, $sub, $th,
     $time, $tmp, $year);

  $data->{'bytes'} = (stat($file))[7];
  $data->{'date'} ||= time;
  $data->{'split'} = '';

  $dir = $self->{'dir'};
  $arc = _arc_name($self->{'split'}, $data->{'time'});

  # Determine the proper count if necessary; don't bother if unlimited;
  # otherwise, take the last existing one and check to make sure it will
  # fit.
  unless ($self->{size} eq 'unlimited') {
    $count = "00";
    # Check to see whether we already have archives from this month
    if ($self->{'splits'}{"$arc-$count"}) {

      # Figure out which count to use; take the last file in the list and
      # extract the count from it
      $sub = (grep(/^$arc-\d\d/,
		   sort(keys(%{$self->{'splits'}})))
	     )[-1] || "$arc-$count";

      $sub =~ /.*-(\d\d)/; $count = $1;
      # Grab the counts for the subarchive and open a new archive if
      # necessary. XXX Put the archive in the filespace with an appropriate
      # description if creating a new one.
      $self->_read_counts($sub);
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

  # Grab the overall counts for the archive XXX Add force option to
  # eliminate race possibility here.
  $self->_read_counts($sub);
  $self->_read_counts($arc);

  # Figure out the proper message number, which is from the unsplit count
  # file.
  $msgno = $self->{splits}{$arc}{msgs}+1;

  # Find the starting line of the new message
  $data->{line} = $self->{splits}{$sub}{lines}+1;

  # Instantiate the index; implicitly use text (or 'none' if we supported
  # it) here
  unless ($self->{'indices'}{$arc}) {
    $self->{'indices'}{$arc} = new Mj::SimpleDB("$dir/.index/I$self->{'list'}.$arc",
						'text', \@index_fields);
  }

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
  $fh->close;

  # Return the message number - yyyymmcc.#####
  $msgno;
}

=head2 get_message(message_num)

This takes a message number (as archive/number) and sets up the archive''s
iterator to read it.

What to return?  Perhaps all useful message data, in a hashref?

=cut
sub get_message {
  my $self = shift;
  my $msg  = shift;
  my $log = new Log::In 150, "$msg";
  my ($arc, $data, $dir, $fh, $file, $idx);

  # Figure out appropriate index database and message number
  ($arc, $msg) = $msg =~ m!([^/]+)/(.*)!;
  $dir = $self->{dir};
  $idx = "$dir/.index/I$self->{'list'}.$arc";
  $file= "$dir/$self->{'list'}.$arc";

  # Open the database
  unless ($self->{'indices'}{$arc}) {
    $self->{'indices'}{$arc} = new Mj::SimpleDB($idx, 'text', \@index_fields);
  }
  
  # Look up the data for the message
  $data = $self->{'indices'}{$arc}->lookup($msg);
  return unless $data;

  # Open FH on appropriate split
  if (length($data->{'split'})) {
    $fh = new Mj::File "$file-$data->{'split'}";
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

=head2 get_to_file(message, filename)

Retrieves a message from the archive and places it in the given file, which
must be writable.  If a filename is not provided, one is generated
randomly.

=cut
sub get_to_file {
  my $self = shift;
  my $msg  = shift;
  my $file = shift || Majordomo::tempname();
  my $data = $self->get_message($msg);
  return unless $data;
  my $fh =   new IO::File ">$file";
  my $chunk;

  while (defined($chunk = $self->get_chunk(1000))) {
    $fh->print($chunk);
  }
  $self->get_done;
  $fh->close;
  ($data, $file);
}

=head2 get_data(message)

This just retrieves the data for a message, or undef if the message does
not exist.

=cut
sub get_data {
  my $self = shift;
  my $msg  = shift;
  my $log = new Log::In 150, "$msg";
  my ($arc, $data, $dir, $fh, $file, $idx);

  # Figure out appropriate index database and message number
  ($arc, $msg) = $msg =~ m!([^/]+)/(.*)!;
  $dir = $self->{dir};
  $idx = "$dir/.index/I$self->{'list'}.$arc";
  $file= "$dir/$self->{'list'}.$arc";

  # Open the database
  unless ($self->{'indices'}{$arc}) {
    $self->{'indices'}{$arc} = new Mj::SimpleDB($idx, 'text', \@index_fields);
  }
  
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
    $arc = (sort(keys(%{$self->{'archives'}})))[-1];
  }

  # Read the counts for this archive
  $self->_read_counts($arc);

  # Take the maximum count and build a message name
  return "$arc/$self->{'splits'}{$arc}{'msgs'}";
}

=head2 last_n(count, archive)

Returns the last count message names from the archive.

=cut
sub last_n {
  my $self = shift;
  my $n    = shift;
  my $arc  = shift;
  my (@arcs, @msgs, $msg, $num);

  # @arcs will hold all archives older than $arc, if given
  if ($arc) {
    @arcs  = sort(grep {$_ < $arc} keys(%{$self->{'archives'}}));
  }
  else {
    @arcs  = sort(keys(%{$self->{'archives'}}));
  }

  $arc ||= pop @arcs;

  $msg = $self->last_message($arc);
  ($num) = $msg =~ m!\d+/(\d+)!;
  while (1) {
    unshift @msgs, "$arc/$num";
    $n--;
    last unless $n>0;
    $num--;
    unless ($num > 0) {
      # Move to previous archive.
      $arc = pop @arcs;
      last unless $arc;
      # Set $num to its last message number
      ($num) = $self->last_message($arc) =~ m!^[^/]+/(.*)$!;
    }
  }
  @msgs;
}

=head2 expand_date(date, date)
  
This returns all messages from a given date or between two dates.  The
dates should be integers in yyyymmdd, yyyymmw, yyyymm, or yyyy format.

=cut
sub expand_date {
  my $self  = shift;
  my $start = shift;
  my $end   = shift || $start;
  my ($e, $s);

  $s = _secs_start($start);
  $e = _secs_end($end);

warn "$start -> $s; $end -> $e";

  
}

=head2 _secs_start(date)

Returns the seconds count at the beginning of the given 'date'.

=cut
use Time::Local;
sub _secs_start {
  my $d = shift;

  # Convert the data into yyyymmmdd format
  if ($d =~ /^\d$/) {
    $d += 2000;
  }
  elsif ($d =~ /^\d{2,3}$/) {
    $d += 1900;
  }
  elsif ($d =~ /^\d{4}$/) {
    $d .= '0101';
  }
  elsif ($d =~ /^(\d{4})(\d)$/) {
    $d = "${1}0${2}01";
  }
  elsif ($d =~ /^\d{6}$/) {
    $d .= '01';
  }
  elsif ($d =~ /^(\d{6})(\d)$/) {
    # Turn week 1, 2, 3, 4 into day 1, 8, 15, 22
    $2 = 4 if $2 > 4;
    $d = $1 . (($2 - 1) * 7) + 1;
  }
  elsif ($d =~ /^(\d{8})/) {
    $d = $1;
  }

  # Now convert that to seconds
  $d =~ /^(\d{4})(\d{2})(\d{2})$/;
  timegm(0,0,0,$3,$2-1,$1);
}

=head2 _secs_end(date)

Returns the seconds count at the end of the given 'date'.

=cut
use Time::Local;
sub _secs_end {
  my $d = shift;

  # Convert the data into yyyymmmdd format
  if ($d =~ /^\d$/) {
    $d += 2000;
  }
  elsif ($d =~ /^\d{2,3}$/) {
    $d += 1900;
  }
  elsif ($d =~ /^\d{4}$/) {
    $d .= '1231';
  }
  elsif ($d =~ /^(\d{4})(\d)$/) {
    $d = "${1}0${2}";
  }
  elsif ($d =~ /^(\d{4})(\d{2})$/) {
    $d .= _dim($2);
  }
  elsif ($d =~ /^(\d{4})(\d{2})(\d)$/) {
    # Turn week 1, 2, 3, 4 into day 7, 14, 21, (28, 30, 31)
    if ($3 >= 4) {
      $d = $1 . _dim($2);
    }
    else {
      $d = $1 . ($2 * 7);
    }
  }
  elsif ($d =~ /^(\d{8})/) {
    $d = $1;
  }

  # Now convert that to seconds
  $d =~ /^(\d{4})(\d{2})(\d{2})$/;
  timegm(59,59,23,$3,$2-1,$1);
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
  my ($mday, $month, $week, $year);

  # Extract data from teh given time
  ($mday, $month, $year) = (localtime($time))[3,4,5];

  # Week 1 is from day 0 to day 6, etc.
  $week = 1+(int($mday)/7);
  $mday++;
  $year += 1900;
  $month++;
  $month = "0$month" if $month < 10;
  $mday  = "0$mday"  if $mday  < 10;

  return "$year"            if $split eq 'yearly';
  return "$year$month"      if $split eq 'monthly';
  return "$year$month$mday" if $split eq 'daily';
  return "$year$month$week" if $split eq 'wekly';
}

=head2 _read_counts

Loads in the sizing data for an archive or a subarchive.  This really
expects that the index file exists; else some default values are set.

=cut
sub _read_counts {
  my $self = shift;
  my $file = shift;
  my $dir = $self->{dir};
  my $log = new Log::In 200, "$file";
  my ($fh, $list, $tmp);

  return if defined $self->{splits}{$file}{bytes};

  $list = $self->{'list'};

  if (-f "$dir/.index/C$list.$file") {
    $self->{splits}{$file}{bytes} = (stat("$dir/$list.$file"))[7];
    $fh = new IO::File "<$dir/.index/C$list.$file";
    $log->abort("Can't read count file $dir/.index/C$list.$file: $!") unless $fh;
    $tmp = $fh->getline;
    chomp $tmp;
    $self->{splits}{$file}{lines} = $tmp;
    $tmp = $fh->getline;
    chomp $tmp;
    $self->{splits}{$file}{msgs} = $tmp;
    $fh->close;
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
  $fh = new IO::File ">$dir/.index/C$list.$file";
  $log->abort("Can't write count file $dir/.index/C$list.$file: $!") unless $fh;
  $fh->print("$self->{splits}{$file}{lines}\n") ||
    $log->abort("Can't write count file $dir/.index/C$list.$file: $!");
  $fh->print("$self->{splits}{$file}{msgs}\n") ||
    $log->abort("Can't write count file $dir/.index/C$list.$file: $!");
  $fh->close;
}

=head2 load_index

Loads the index for a given archive.  This must be done as a precursor to
any by-message retrieval.  Indexes are small when compared to the archive
and give exact line and bute counts enabling messages to be read in with a
seek and a sysread.

=cut


=head2 expand_range

Takes a range of articles and expands it into a list of articles.

* By named messages:
    199805/12 199805/15

* By a message count (last 10 messages):
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

This must be an archive method because it needs to expand a date to a list
of article numbers using the index.

=cut
sub expand_range {
  my $self = shift;
  my $lim  = shift;
  my @args = @_;
  my (@out, $i, $j);

  # Walk the arg list
  while (defined($i = shift(@args))) {
    return @out if $lim && $#out > $lim;
    # Skip commas and bomb on dashes
    next if $i eq ',';
    return if $i eq '-';

    # Remove date separators.
    $i =~ s/[\.\-]//g;

    # Do we have a count, a date or a message?
    if ($i =~ /^(\d{1,3})$/) {
      push @out, $self->last_n($i)
    }
    elsif ($i =~ m!/!) {
      # Message: look beyond for a range, grab it, expand it
      if (@args && $args[0] eq '-') {
	# Parse message range
	shift @args; $j = shift @args;
	push @out, $self->_parse_message_range($i, $j);
      }
      else {
	push @out, $i;
      }
    }
    else {
      if (@args && $args[0] eq '-') {
	# Date range: expand to list of dates, unshift dates into args
	shift @args; $j = shift @args;
	unshift @args, $self->_expand_date_range($i, $j);
      }
      else {
	# Expand date to all messages on that date; push into @out
	push @out, $self->_expand_date($i);
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
### End: ***

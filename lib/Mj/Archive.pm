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
use AutoLoader 'AUTOLOAD';

use strict;
use DirHandle;
use IO::File;
use Mj::File;
use Mj::Log;
use vars qw(@index_fields);

@index_fields = qw(byte bytes line lines date from subject refs quoted);

1;   
__END__

=head2 new(directory, listname, split)

This allocates an archive object and loads in the names of the individual
archive files.  directory is the actual pathname to the directory
containing the archive files; listname is the name of the list the files
are associated with (so that their names can be easily deduced) and split
is a string describing just when an archive should be split:

  monthly
  weekly
  daily
  AAAAk  (after A kilobytes)
  BBBBl  (after B lines) (not implemented)
  CCCCm  (after C messages) (not implemented)

note that no less frequent interval is supported.

=cut
sub new {
  my $type  = shift;
  my $dir   = shift;
  my $list  = shift;
  my $split = shift;
  my $class = ref($type) || $type;
  my $log   = new Log::In 150, "$dir, $list";
  my($dh);
  my $self = {'dir'   => $dir,
	      'list'  => $list,
	      'split' => $split,
	     };
  bless $self, $class;

  # Get list of files
  $dh = new DirHandle $dir;
  return undef unless defined $dh;
  while (defined($_ = $dh->read)) {
#XXX    $self->{'archives'}{$_} = {};
    $self->{'archives'}{$_}{'bytes'} = (stat("$dir/$_"))[7]
      if /^$list-\d{8}/;
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

This routine will fill in the other data fields (byte, bytes, line, lines,
quoted) itself.

XXX This is too large; break it up.

=cut
sub add {
  my $self   = shift;
  my $file   = shift;
  my $sender = shift;
  my $data   = shift || {};
  my $log    = new Log::In 150, "$file";

  my($arc, $count, $dir, $fh, $from_line, $month, $msgno, $msgs, $th,
     $time, $tmp, $year);

  $data->{'bytes'} = (stat($file))[7];
  $data->{'lines'} = 0;

  # Figure out which archive to add to: use date -> year, month
  $data->{'date'} ||= time;
  ($month, $year) = (localtime($data->{'date'}))[4,5];
  $year += 1900;
  $month++;
  $month = "0$month" if $month < 10;
  $count = "00";
  $arc = "$self->{'list'}-$year$month$count";
  $dir = $self->{'dir'};

  # Check to see whether we already have archives from this month
  if ($self->{'archives'}{$arc}) {
    # Figure out which count to use; take the last file in the list
    $arc = (grep(/^$self->{'list'}-$year$month\d\d/,
		 sort(keys(%{$self->{'archives'}})))
	   )[-1];
    ($count) = $arc =~ /$self->{'list'}-$year$month(\d\d)/;

    # If we're splitting on size, check sizes and increment count if necessary
    if ($self->{'split'} =~ /(\d+)k/ &&
	$data->{'bytes'} + $self->{'archives'}{$arc}{'bytes'} > $1 * 1024)
      {
	$count++;
	$arc = "$self->{'list'}-$year$month$count";
      }
    # Do the same for message counts; open the count file and check
   
    # Do the same for line counts

  }
  
  # Instantiate the index
  $self->{'indices'}{$arc} = new Mj::SimpleDB "$dir/.I$arc", \@index_fields;

  # Open and lock the archive
  $fh = new Mj::File;
  $fh->open("$dir/$arc", ">>");
  $data->{'byte'} = $fh->tell;

  # Grab the line and message count
  if (-f "$dir/.C$arc") {
    $th = new IO::File "<$dir/.C$arc";
    $log->abort("Can't read count file $dir/.C$arc: $!") unless $th;
    $tmp = $th->getline;
    chomp $tmp;
    $data->{'line'} = $tmp;
    $tmp = $th->getline;
    chomp $tmp;
    $msgs = $tmp + 1;
    $msgno = "$year$month$count.$msgs";
    $th->close;
  }
  else {
    $data->{'line'} = 0;
    $msgs = 1;
    $msgno = "$year$month$count.1";
  }

  # Generate and append the mbox separator if necessary
  if ($sender) {
    if ($data->{'date'}) {
      $time = localtime($data->{'date'});
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
  $log->abort("Coundn't read message file $file: $!") unless $th;
  $data->{'quoted'} = 0;
  while (defined ($_ = $th->getline)) {
    # XXX Error check the print
    $fh->print($_);
    $data->{'quoted'}++ if /^( : | > | [a-z]+> )/xio;
    $data->{'lines'}++;
  }
  
  # Close the message
  $th->close;

  # Print the blank line separator
  $fh->print("\n");
  $data->{'lines'}++;
  # Don't increment the byte count, because seek counts from zero so we
  # have to subtract one somewhere.

  # Print out the new count file
  $th = new IO::File ">$dir/.C$arc";
  $log->abort("Can't write count file $dir/.C$arc: $!") unless $th;
  $count = $data->{'line'} + $data->{'lines'};
  $th->print("$count\n") ||
    $log->abort("Can't write count file $dir/.C$arc: $!");
  $th->print("$msgs\n") ||
    $log->abort("Can't write count file $dir/.C$arc: $!");
  $th->close;
  
  # Append the line containing the info to index
  $self->{'indices'}{$arc}->add("", $msgno, $data);
  
  # Close the archive
  $fh->close;

  # Return the message number - yyyymmcc.#####
  $msgno;
}

=head2 get_message(message_num)

This takes a message number and sets up the archive''s iterator to read it.

What to return?  Perhaps all useful message data, in a listref?

=cut
sub get_message {
  my $self = shift;
  my $msg  = shift;
  my $log = new Log::In 150, "$msg";
  my ($cache, $file);

  # Figure out appropriate index file
  ($file) = $msg =~ /(.*)\.(.*)/;
  $idx = "$self->{dir}/.I$file";

  # If cached data, look at end to see if what we want is contained within.
  $cache = $self->{icache}{$file};
  if (@$cache && _msgnum($msg) < $cache->[$#{$cache}]{msgnum}) {

    # If so, binary search for it.
    
  }
  # Otherwise, open index file, seek to where we left off (if we've looked
  # here before, iterate until we hit the right message number, pushing
  # data into cache.

  # Open FH on appropriate archive file

  # Seek to byte offset

  # Return

}

=head2 get_line(file, line)

Starts the iterator on the message containing the given line from the given file.

=cut
sub get_line {

  # Figure out appropriate index file

  # Iterate until we hit the right line (msg_line <= line, msg_line +
  # total_lines > line)

  # Open FH on appropaiate archive file

  # Seek to byte offset

  # Return

}

=head2 get_byte(file, byte)

Starts the iterator on the message containing the given byte.

=head2 get_chunk(size)

This reads a chunk of size lines (or until the end of the message) from the
selected message.

=cut
sub get_chunk {

}

=head2 get_done

Closes the iterator.

=cut
sub get_done {

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

  # Look up archive directory; tack it on, with .I

}

sub count_name {
  my $self = shift;
  my $file = shift;

  # Look up archive dir, tack on with .C

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


=head2 load_index

Loads the index for a given archive.  This must be done as a precursor to
any by-message retrieval.  Indexes are small when compared to the archive
and give exact line and bute counts enabling messages to be read in with a
seek and a sysread.

=cut



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

=head1 NAME

Mj::MIMEParser - Subclass of MIME::Parser used to override a few functions

=head1 DESCRIPTION

This is a simple subclass of MIME::Parser which exists to allow us to
override a few important functions such as filename generation.  We never
want to trust any provided filename, so we always generate a temporary one.

=head1 SYNOPSIS

See MIME::Parser.

=cut
package Mj::MIMEParser;
use strict;
use vars qw(@ISA $output_path_counter);
use MIME::Parser;
@ISA = qw(MIME::Parser);

# This is based on MIME::Parser::output_path
sub output_path {
    my ($self, $head) = @_;
    my ($dir, $name);

    $output_path_counter++;
    $name = ($self->output_prefix . "$$.$output_path_counter.mime");
    $dir = $self->output_dir;
    $dir = '.' if (!defined($dir) || ($dir eq ''));  # just to be safe
    "$dir/$name";  
}

use AutoLoader 'AUTOLOAD';
1;
__END__

=head2 collect_data(entity)

Return information about a MIME entity:

body_lines quoted date from subject refs hidden msgid;

=cut
use Date::Parse;
sub collect_data {
  my ($entity, $qp) = @_;
  my (@rcv, @refs, $tmp);
  return unless $entity;
  my ($data) = {
                 'body_lines'  => 0,
                 'date'        => time,
                 'from'        => '',
                 'hidden'      => 0,
                 'msgid'       => '',
                 'quoted'      => 0,
                 'refs'        => '',
                 'subject'     => '',
               };
  my ($head) = $entity->head->dup;
  return unless $head;
  $head->unfold;

  # Obtain references
  @refs = ();
  $tmp = $head->get('references') || '';
  while ($tmp =~ s/<([^>]*)>//) {
    push @refs, $1;
  }
  $tmp = $head->get('in-reply-to') || '';
  while ($tmp =~ s/<([^>]*)>//) {
    push (@refs, $1) unless (grep { $_ eq $1 } @refs);;
  }
  map { $_ =~ s/\002/X/g; } @refs;
  $data->{'refs'} = join "\002", @refs;

  $tmp = $head->get('message-id') || '';
  chomp $tmp;
  $tmp =~ s/\s*<([^>]*)>\s*/$1/;
  $tmp =~ s/\002/X/g;
  $data->{'msgid'} = $tmp;
 
  $data->{'subject'} = $head->get('subject') || ''; 
  chomp $data->{'subject'};

  # Look for "X-no-archive: yes" or "Restrict: no-external-archive"
  # header to indicate that a  message should be considered hidden.
  $tmp = $head->get('x-no-archive');
  if (defined($tmp) and $tmp =~ /\byes\b/i) {
    $data->{'hidden'} = 1;
  }
  else {
    $tmp = $head->get('restrict');
    if (defined($tmp) and $tmp =~ /\bno-external-archive\b/i) {
      $data->{'hidden'} = 1;
    }
  }

  # Convert the message date into a time value.
  # Use the earliest Received header, or the Date header.
  $tmp = '';
  @rcv = $head->get('received');
  if (@rcv) {
    @rcv = split /\s*;\s*/, $rcv[-1];
    $tmp = $rcv[-1];
  }
  $tmp ||= $head->get('date');
  if (defined $tmp) {
    chomp $tmp;
    $tmp = &str2time($tmp);
  }
  $tmp = time unless (defined ($tmp) and $tmp > 0 and $tmp < time);
  $data->{'date'} = $tmp;
  
  chomp($data->{'from'} = $head->get('from') ||
        $head->get('apparently-from') || '');

  _r_ct_lines($entity, $data, $qp);
  # Account for separator
  $data->{'body_lines'}--;

  $data;
} 
   
use Mj::Util qw(re_match);
sub _r_ct_lines {
  my ($entity, $data, $qp) = @_;
  my (@parts) = $entity->parts;
  my ($body, $i, $line);
  if (@parts) {
    for ($i = 0; $i < @parts ; $i++) {
      _r_ct_lines($parts[$i], $data, $qp);
    }
    return;
  }

  return unless $entity->bodyhandle;
  $body = $entity->bodyhandle->open('r');
  return unless $body;

  # Iterate over the lines
  while ($line = $body->getline) {
    $data->{body_lines}++;
    $data->{quoted_lines}++ if re_match($qp, $line);
  }
}

=head2 get_entity_structure (entity, id, result)

Given a file containing a message, modify the "result" hash 
to describing the structure of the message entity.  Each
key of the hash is a message part number.

=cut
sub get_entity_structure {
  my ($entity, $id, $result) = @_;
  defined ($id) or $id = 1;
  my (@parts, @tmp, $basename, $hdr, $i, $level, $part, $path, 
      $size, $type);
  @tmp = split ("\\.", $id);
  $level  = $#tmp;

  $result->{$id}->{'entity'} = $entity;
  $result->{$id}->{'type'} = $entity->mime_type || 'unknown';
  $result->{$id}->{'header'} = $entity->head->as_string;

  $path = ($entity->bodyhandle ? $entity->bodyhandle->path : '');
  if ($path) {
    $result->{$id}->{'path'} = $path;
    $result->{$id}->{'size'} = sprintf("%.1f", ((-s ($path)) + 51) / 1024);
  }
  else {
    $result->{$id}->{'path'} = '';
    $result->{$id}->{'size'} = '';
  }

  @parts = $entity->parts;
  $i = 1;
  for $part (@parts) {
    &get_entity_structure($part, $id . ".$i", $result);
    $i++;
  }
  1; 
}

=head2 remove_part(file, part_number)

Remove a numbered body part from an entity in a message file.

=cut
use Mj::FileRepl;
sub remove_part {
  my ($self, $file, $part) = @_;
  my (@kept, $child, $entity, $i, $j, $parent, $repl, $result);
  $result = {};

  return (0, "The headers of a body part cannot be removed.")
    if ($part =~ s/[hH]$//);

  return (0, "The top-level body part cannot be removed.")
    if ($part eq '1' or $part eq '0');

  return (0, "Unable to access file $file.")
    unless (-f $file);

  $entity = $self->parse_open($file);
  return (0, "Unable to parse file $file.")
    unless ($entity);

  &get_entity_structure($entity, 1, $result);
  return (0, "The message has no part numbered $part.")
    unless (exists $result->{$part});

  ($parent, $child) = ($part =~ m/(.+)\.(\d+)$/);
  return (0, "The message has no part numbered $parent.")
    unless (exists $result->{$parent});

  $j = 1;
  for $i ($result->{$parent}->{'entity'}->parts) {
    push (@kept, $i) unless ($j eq $child);
    $j++;
  }

  $result->{$parent}->{'entity'}->parts(\@kept);
  if (scalar @kept <= 1) {
    $result->{$parent}->{'entity'}->make_singlepart;
  }

  $result->{$parent}->{'entity'}->head->add('X-Content-Discarded',
                                            $result->{$part}->{'type'});  
  $result->{$parent}->{'entity'}->sync_headers;

  $repl = new Mj::FileRepl $file;
  return (0, "Unable to open replacement file.")
    unless $repl;

  $entity->print($repl->{'newhandle'});
  $repl->commit;

  $result = {};
  &get_entity_structure($entity, 1, $result);
  (1, $result);
}
  
=head2 replace_headers (file, headers)

Given a file containing a message, replace a group of headers within
the file.

=cut
use Mj::FileRepl;
sub replace_headers {
  my $self = shift;
  my $file = shift;
  my %hdrs = @_;
  my ($ent, $hdr, $repl, $tmp);

  return unless keys %hdrs;

  $repl = new Mj::FileRepl "$file";
  return unless $repl;

  $ent = $self->read($repl->{'oldhandle'});
  return unless $ent;
  for $hdr (keys %hdrs) {
    if ($hdr =~ /^-/) {
      # Remove headers beginning with "-"
      $tmp = substr $hdr, 1;
      $ent->head->delete($tmp);
    }
    else {
      $ent->head->replace($hdr, $hdrs{$hdr});
    }
  }

  $ent->print($repl->{'newhandle'});
  $ent->purge;
  $repl->commit;
  1;
}

=head2 replace_part(file, part_number, contents)

Replace the contents of a body part or its headers.

=cut
use Mj::FileRepl;
sub replace_part {
  my ($self, $file, $part, $contents) = @_;
  my (@tmp, $chhead, $entity, $fh, $head, $line, $repl, $result);
  $result = {};

  if ($part =~ s/[hH]$//) {
    $chhead = 1;
  }
  else {
    $chhead = 0;
  }
  
  return (0, "Part number 0h cannot be replaced.")
    if ($part eq '0' and $chhead);
  
  return (0, "Unable to access file $file.")
    unless (-f $file);

  $entity = $self->parse_open($file);
  return (0, "Unable to parse file $file.")
    unless ($entity);

  if ($part ne '0') {
    &get_entity_structure($entity, 1, $result);
    return (0, "The message has no part numbered $part.")
      unless (exists $result->{$part});
  }

  if ($chhead) {
    @tmp = grep { 
                 $_ =~ /^[^\x00-\x1f\x7f-\xff:]+:(.*)/ or
                 $_ =~ /^[ \t]+/;
                } @$contents;
    $head = new MIME::Head \@tmp;
    return (0, "Unable to obtain header from contents.") 
      unless $head;
    $result->{$part}->{'entity'}->head($head);
  }
  elsif ($part ne '0') {
    return (0, "The part $part has no body.")
      unless ($result->{$part}->{'size'} >= 0);
    $fh = $result->{$part}->{'entity'}->open("w");
    return (0, "Unable to open body part $part for writing: $!.")
      unless ($fh);

    for $line (@$contents) {
      $fh->print("$line\n");
    }

    $fh->close;
    $result->{$part}->{'entity'}->sync_headers;
  }

  $repl = new Mj::FileRepl $file;
  return (0, "Unable to open replacement file.")
    unless $repl;

  if ($part ne '0') {
    $entity->print($repl->{'newhandle'});
  }
  else {
    for $line (@$contents) {
      $repl->{'newhandle'}->print("$line\n");
    }
  }
    
  $repl->commit;

  $result = {};
  &get_entity_structure($entity, 1, $result);
  (1, $result);
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

#
### Local Variables: ***
### cperl-indent-level:2 ***
### cperl-label-offset:-1 ***
### End: ***

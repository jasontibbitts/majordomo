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

body_lines quoted date from subject refs;

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
                 'quoted'      => 0,
                 'refs'        => '',
                 'subject'     => '',
               };
  my ($head) = $entity->head;
  return unless $head;

  # Obtain references
  @refs = ();
  $tmp = $head->get('references') || '';
  while ($tmp =~ s/<([^>]*)>//) {
    push @refs, $1;
  }
  $tmp = $head->get('in-reply-to') || '';
  while ($tmp =~ s/<([^>]*)>//) {
    push @refs, $1;
  }
  $data->{'refs'} = join "\002", @refs;
 
  $data->{'subject'} = $head->get('subject') || ''; 
  chomp $data->{'subject'};

  # Convert the message date into a time value.
  # Use the earliest Received header, or the Date header.
  $tmp = '';
  @rcv = $head->get('received');
  if (@rcv) {
    @rcv = split /\s*;\s*/, $rcv[-1];
    $tmp = $rcv[-1];
  }
  $tmp ||= $head->get('date');
  chomp $tmp;
  $tmp = &str2time($tmp);
  $tmp = time unless ($tmp > 0 and $tmp < time);
  $data->{'date'} = $tmp;
  
  chomp($data->{'from'} = $head->get('from') ||
        $head->get('apparently-from'));

  _r_ct_lines($entity, $data, $qp);
  # Account for separator
  $data->{'body_lines'}--;

  $data;
} 
   

sub _r_ct_lines {
  my ($entity, $data, $qp) = @_;
  my (@parts) = $entity->parts;
  my ($body, $line);
  if (@parts) {
    for ($i=0; $i<@parts; $i++) {
      _r_ct_lines($parts[$i], $data, $qp);
    }
    return;
  }
  $body = $entity->bodyhandle->open('r');
  return unless $body;

  # Iterate over the lines
  while ($line = $body->getline) {
    $data->{body_lines}++;
    $data->{quoted_lines}++ if Majordomo::_re_match($qp, $line);
  }
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

#
### Local Variables: ***
### cperl-indent-level:2 ***
### cperl-label-offset:-1 ***
### End: ***

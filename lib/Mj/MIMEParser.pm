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

=head1 NAME

Mj::FakeLog - Fake Majordomo's logging system without doing anything.

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

blah

=cut

require 5.003_19;
package Mj::Log;

sub new {my $proto = shift; my $class = ref($proto) || $proto; my $self={}; bless $self, $class; $self;}
sub add {1;}
sub set_level {1;}
sub delete {1;}
sub message {1;}
sub elapsed {1;}
sub startup_time {1;}
sub in {1;}
sub out {1;}
sub abort {1;}
sub complain {1;}

package Log::In;
sub new {my $proto = shift; my $class = ref($proto) || $proto; my $self={}; bless $self, $class;
	 print STDERR (caller(1))[3], "\n" if $Mj::FakeLog::verbose;
	 $self;}
sub out {shift;$a = shift; print "$a\n" if $a && $Mj::FakeLog::verbose;1;}
sub abort {1;}
sub complain {1;}
sub message {1;}

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

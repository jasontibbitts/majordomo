# This file contains data used by the Majordomo email interface, and
# subroutines used to manipulate it.  These are grouped together in case
# the representation changes.

# The %commands hash contains the commands and a list of properties for
# each.  Properties supported:
# list       -> verify the given list, or add the default if necessary and
#               if one is specified
# obsolete   -> obsolete command; warn if obsolescence warnings enabled
# noargs     -> command doesn't take arguments
# nohereargs -> command doesn't take here arguments
# global     -> if 'list', also takes the 'global' meta-list
# all        -> if 'list', also takes the 'all' meta-list
# shell      -> callable from the shell interface
# shell_parsed -> callable when the shell interface is parsing a file
# email      -> callable from the email parser
# real       -> corresponds to a real core command
# interp     -> corresponds to a command that the interpreter handles

%commands = 
  (
   'accept'         => [qw(email shell real)],
   'alias'          => [qw(email shell list global real)],
   'approve'        => [qw(email shell interp)],
   'auxsubscribe'   => [qw(email shell list global real)],
   'auxunsubscribe' => [qw(email shell list global all real)],
   'auxwho'         => [qw(email shell list global real)],
   'config'         => [qw(email list obsolete=configshow real)],
   'configshow'     => [qw(email shell list global real)],
   'configset'      => [qw(email shell list global real)],
   'configdef'      => [qw(email shell list global real)],
   'configedit'     => [qw(shell list global real)],
   'createlist'     => [qw(email shell nohereargs real)],
   'default'        => [qw(email shell_parsed real)],
   'end'            => [qw(email shell interp)],
   'faq'            => [qw(email shell list global real)],
   'filesync'       => [qw(email shell list global all real)],
   'get'            => [qw(email shell list global real)],
   'help'           => [qw(email shell real)],
   'index'          => [qw(email shell list global real)],
   'info'           => [qw(email shell list real)],
   'intro'          => [qw(email shell list real)],
   'lists'          => [qw(email shell noargs real)],
#   'mkdigest'       => [qw(email shell list)],
   'newconfig'      => [qw(email shell list obsolete=configset real)],
   'newfaq'         => [qw(email shell list real)],
   'newinfo'        => [qw(email shell list real)],
   'newintro'       => [qw(email shell list real)],
   'passwd'         => [qw(email shell list obsolete=configset real)],
   'post'           => [qw(email shell list real)],
   'put'            => [qw(email shell list global real)],
   'reject'         => [qw(email shell real)],
   'rekey'          => [qw(email shell list global all real)],
   'sessioninfo'    => [qw(email shell real)],
   'set'            => [qw(email shell list real)],
   'show'           => [qw(email shell list real)],
   'showtokens'     => [qw(email shell list global all real)],
   'subscribe'      => [qw(email shell list real)],
   'tokeninfo'      => [qw(email shell real)],
   'unalias'        => [qw(email shell list global all real)],
   'unsubscribe'    => [qw(email shell list all real)],
# XXX Is this too draconian?  It's here to discourage abuse of which.
   'which'          => [qw(email shell nohereargs real)],
   'who'            => [qw(email shell list real)],
   'writeconfig'    => [qw(email shell list obsolete real)],
  );

# The %aliases hash maps aliases to the commands they really are.  This is
# intended for the support of foreign languages and other applications
# where having multiple names for one command is useful.
%aliases =
  (
   '.'              => 'end',
   'aliasadd'       => 'alias',
   'aliasremove'    => 'unalias',
   'auxdel'         => 'auxunsubscribe',
   'auxadd'         => 'auxsubscribe',
   'auxremove'      => 'auxunsubscribe',
   'auxshow'        => 'auxwho',
   'cancel'         => 'unsubscribe',
   'configdefault'  => 'configdef',
   'exit'           => 'end',
   'man'            => 'help',
   'quit'           => 'end',
   'remove'         => 'unsubscribe',
   'signoff'        => 'unsubscribe',
   'stop'           => 'end',
   'unsub'          => 'unsubscribe',
  );


# This determines if a command is legal.  Returns undef if not; otherwise
# returns the true name of the command looked up through the %aliases hash
# if necessary.
sub command_legal {
  my $command = shift;

  return $command if exists $commands{$command};
  return $aliases{$command} if defined $aliases{$command};
  return undef;
}

# This determines if a command (or alias to a command) has a certain
# property.  Returns undef if not or if the command doesn't exist (check
# first!), returns true if so.  If the property has a tag, returns the tag.
sub command_property {
  my $command = shift;
  my $prop = shift;
  
  my ($i, $plist);

  $command = $aliases{$command} unless defined $commands{$command};
  return undef unless defined $commands{$command};

  @plist = @{$commands{$command}};

  for $i (@plist) {
    if ($i =~ /^$prop($|=)(.*)/) {
      return $2 || 1;
    }
  }
  return undef;
}

# This takes a regex and finds all matching commands.  If $alias is true,
# aliases will be returned, too.  Proplist is a listref of properties, all
# of which must be on for a match.
sub commands_matching {
  my ($regex, $alias, $proplist) = @_;
  my (@out, @tmp, $i, $ok);

  for $i (keys(%commands), $alias?keys(%aliases):()) {
    if ($i =~ /$regex/) {
      push @tmp, $i;
    }
  }

  if (@$proplist) {
    for $i (@tmp) {
      $ok = 1;
      for $j (@$proplist) {
	unless (command_property($i, $j)) {
	  $ok = 0
	}
      }
      push @out, $i if $ok;
    }
  }
  else {
    @out = @tmp;
  }
  @out;
}

1;

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
### End: ***

# This file contains data used by the Majordomo shell interface, and
# subroutines used to manipulate it.  These are grouped together in case
# the representation changes.

# The %commands hash contains the commands and a list of properties for
# each.  Properties supported:
# deflist    -> add the default list to the command line of unspecified
# obsolete   -> obsolete command; warn if obsolescence warnings enabled
# noargs     -> command doesn't take arguments
# nohereargs -> command doesn't take here arguments

%commands = 
  (
   'alias'          => [qw(list global)],
   'auxsubscribe'   => [qw(list global)],
   'auxunsubscribe' => [qw(list global all)],
   'auxwho'         => [qw(list global)],
   'config'         => [qw(list obsolete=configshow)],
   'configshow'     => [qw(list global)],
   'configset'      => [qw(list global)],
   'configdef'      => [qw(list global)],
   'configedit'     => [qw(list global)],
   'filesync'       => [qw(list global all)],
   'get'            => [qw(list global)],
   'help'           => ['noargs'],
   'index'          => [qw(list global)],
   'info'           => [qw(list)],
   'intro'          => [qw(list)],
   'lists'          => ['noargs'],
   'mkdigest'       => [qw(list)],
   'newconfig'      => [qw(list obsolete=configset)],
   'newinfo'        => [qw(list obsolete=configset)],
   'passwd'         => [qw(list obsolete=configset)],
   'rekey'          => [qw(list global all)],
   'set'            => [qw(list)],
   'show'           => [qw(list)],
   'subscribe'      => [qw(list)],
   'unalias'        => [qw(list global all)],
   'unsubscribe'    => [qw(list all)],
# XXX Is this too draconian?  It's here to discourage abuse of which.
   'which'          => ['nohereargs'],
   'who'            => [qw(list)],
   'writeconfig'    => [qw(list obsolete)],
   );

# The %aliases hash maps aliases to the commands they really are.  This is
# intended for the support of foreign languages and other applications
# where having multiple names for one command is useful.
%aliases =
  (
   'aliasadd'       => 'alias',
   'aliasremove'    => 'unalias',
   'auxdel'         => 'auxunsubscribe',
   'auxadd'         => 'auxsubscribe',
   'auxremove'      => 'auxunsubscribe',
   'auxshow'        => 'auxwho',
   'cancel'         => 'unsubscribe',
   'configdefault'  => 'configdef',
   'remove'         => 'unsubscribe',
   'signoff'        => 'unsubscribe',
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

# This determines if a command has a certain property.  Returns undef if
# not or if the command doesn't exist (check first!), returns true if so.
# If the property has a tag, returns the tag.
sub command_property {
  my $command = shift;
  my $prop = shift;
  
  my ($i, $plist);

  return undef unless defined $commands{$command};

  @plist = @{$commands{$command}};

  for $i (@plist) {
    if ($i =~ /^$prop($|=)(.*)/) {
      return $2 || 1;
    }
  }
  return undef;
}

1;   
   

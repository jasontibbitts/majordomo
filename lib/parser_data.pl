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

%commands = 
  (
   'accept'         => [qw(email shell)],
   'alias'          => [qw(email shell list global)],
   'approve'        => [qw(email shell_parsed)],
   'auxsubscribe'   => [qw(email shell list global)],
   'auxunsubscribe' => [qw(email shell list global all)],
   'auxwho'         => [qw(email shell list global)],
   'config'         => [qw(email list obsolete=configshow)],
   'configshow'     => [qw(email shell list global)],
   'configset'      => [qw(email shell list global)],
   'configdef'      => [qw(email shell list global)],
   'configedit'     => [qw(shell list global)],
   'createlist'     => [qw(email shell nohereargs)],
   'default'        => [qw(email shell_parsed)],
   'end'            => [qw(email)],
   'faq'            => [qw(email shell list global)],
   'filesync'       => [qw(email shell list global all)],
   'get'            => [qw(email shell list global)],
   'help'           => [qw(email shell)],
   'index'          => [qw(email shell list global)],
   'info'           => [qw(email shell list)],
   'intro'          => [qw(email shell list)],
   'lists'          => [qw(email shell noargs)],
#   'mkdigest'       => [qw(email shell list)],
   'newconfig'      => [qw(email shell list obsolete=configset)],
   'newfaq'         => [qw(email shell list)],
   'newinfo'        => [qw(email shell list)],
   'newintro'       => [qw(email shell list)],
   'passwd'         => [qw(email shell list obsolete=configset)],
   'post'           => [qw(email shell list)],
   'put'            => [qw(email shell list global)],
   'reject'         => [qw(email shell)],
   'rekey'          => [qw(email shell list global all)],
   'sessioninfo'    => [qw(email shell)],
   'set'            => [qw(email shell list)],
   'show'           => [qw(email shell list)],
   'showtokens'     => [qw(email shell list global all)],
   'subscribe'      => [qw(email shell list)],
   'tokeninfo'      => [qw(email shell)],
   'unalias'        => [qw(email shell list global all)],
   'unsubscribe'    => [qw(email shell list all)],
# XXX Is this too draconian?  It's here to discourage abuse of which.
   'which'          => [qw(email shell nohereargs)],
   'who'            => [qw(email shell list)],
   'writeconfig'    => [qw(email shell list obsolete)],
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
   

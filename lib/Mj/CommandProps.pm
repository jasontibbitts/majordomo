# This file contains data about all available Majordomo commands along with
# functions for accessing this data, collected in a single place.

package Mj::CommandProps;
require Exporter;
@ISA = qw(Exporter);

@EXPORT_OK = qw(access_def command_legal command_prop
		commands_matching command_list function_prop function_legal
		rules_request rules_requests rules_var rules_vars
		rules_action rules_actions action_files action_terminal);
%EXPORT_TAGS = ('command'  => [qw(command_legal command_prop
				  commands_matching command_list)],
		'function' => [qw(function_legal function_prop)],
		'rules'    => [qw(rules_request rules_requests rules_var
				  rules_vars rules_action
				  rules_actions action_files)],
		'access'   => [qw(access_def)],
       );
use strict;

# All supported actions, plus some additional information used for syntax
# checking
my %actions =
  ('allow'           => {files => [],    terminal => 1,},
   'confirm'         => {files => [0],   terminal => 1,},
   'consult'         => {files => [0],   terminal => 1,},
   'confirm_consult' => {files => [0,1], terminal => 1,},
   'default'         => {files => [],    terminal => 1,},
   'deny'            => {files => [],    terminal => 1,},
   'forward'         => {files => [],    terminal => 1,},
#  'log'             => 1,
   'mailfile'        => {files => [0],},
   'reason'          => {files => [],},
   'reply'           => {files => [],},
   'replyfile'       => {files => [0],},
   'set'             => {files => [],},
   'unset'           => {files => [],},
  );

my %reg_legal =
  ('master_password'=>1,
   'user_password'  =>1,
   'mismatch'       =>1,
   'addr'           =>3,
   'fulladdr'       =>3,
   'host'           =>3,
  );

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

my %commands = 
  (
   # Commands implemented by the parser/marshaller only
   'approve'    => {'parser' => [qw(email shell interp)]},
   'default'    => {'parser' => [qw(email shell_parsed real)]},
   'end'        => {'parser' => [qw(email shell interp)]},
   'config'     => {'parser' => [qw(email list obsolete=configshow real)]},
   'configshow' => {'parser' => [qw(email shell list global real)]},
   'configset'  => {'parser' => [qw(email shell list global real)]},
   'configdef'  => {'parser' => [qw(email shell list global real)]},
   'configedit' => {'parser' => [qw(shell list global real)]},
   'newconfig'  => {'parser' => [qw(email shell list obsolete=configset real)]},
   'newfaq'     => {'parser' => [qw(email shell list real)]},
   'newinfo'    => {'parser' => [qw(email shell list real)]},
   'newintro'   => {'parser' => [qw(email shell list real)]},

   # Internal commands (not accessible to the end user except through
   # specialized interfaces)
   'owner'   => {'dispatch' => {'top' => 1, 'iter' => 1, 'noaddr' => 1}},
   'trigger' => {'dispatch' => {'top' => 1, 'noaddr' => 1}},
   'request_response' =>
   {
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'allow',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },

   # Pure access methods not related to core functions
   'access' =>
   {
    'access'   => {
		   'default' => 'allow',
		   'legal'   =>\%reg_legal,
		   'actions' =>{
				'allow'     =>1,
				'deny'      =>1,
				'mailfile'  =>1,
				'reply'     =>1,
				'replyfile' =>1,
			      },
		},
   },
   'advertise' =>
   {
    'access'   => {
		   'default' => 'special',
		   'legal'   => \%reg_legal,
		   'actions' => {
				 'allow'   =>1,
				 'deny'    =>1,
				 'mailfile'=>1,
				},
		  },
   },

   # Normal core commands
   'accept' => 
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1},
    # The token is the access restriction
   },
   'alias' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'confirm',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'archive' =>
   {
    'parser'   => [qw(email shell list real)],
    'dispatch' => {'top' => 1, 'iter' => 1},
    'access'   => {
		   'default' => 'allow',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'auxadd' =>
   {
    'parser' => [qw(email shell list global real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'deny',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'auxremove' =>
   {
    'parser' => [qw(email shell list global all real)],
    'dispatch' => {'top' => 1, 'noaddr' => 1},
    'access'   => {
		   'default' => 'deny',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'auxwho' =>
   {
    'parser' => [qw(email shell list global real)],
    'dispatch' => {'top' => 1, 'iter' => 1},
    'access'   => {
		   'default' => 'deny',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'createlist' =>
   {
    'parser' => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'deny',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'digest' =>
   {
    'parser' => [qw(email shell list nohereargs real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'deny',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'faq' =>
   {
    'parser'   => [qw(email shell list global real)],
    'dispatch' => {'top' => 1, 'iter' => 1},
    'access'   => {
		   'default' => 'access',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'get' =>
   {
    'parser'   => [qw(email shell list global real)],
    'dispatch' => {'top' => 1, 'iter' => 1},
    'access'   => {
		   'default' => 'access',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'help' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1, 'iter' => 1},
    'access'   => {
		   'default' => 'allow',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'index' =>
   {
    'parser'   => [qw(email shell list global real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'access',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'info' =>
   {
    'parser'   => [qw(email shell list real)],
    'dispatch' => {'top' => 1, 'iter' => 1},
    'access'   => {
		   'default' => 'access',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'intro' =>
   {
    'parser'   => [qw(email shell list real)],
    'dispatch' => {'top' => 1, 'iter' => 1},
    'access'   => {
		   'default' => 'access',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'lists' =>
   {
    'parser'   => [qw(email shell noargs real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'allow',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   # mkdigest is fake; it just calls digest-force, but aliases don't work
   # for modes
   'mkdigest'       => {'parser' => [qw(email shell list)],
   		       },
   'password' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'special',
		   'legal'   => {
				 'master_password'  => 1,
				 'user_password'    => 1, 
				 'mismatch'         => 1,
				 'password_length'  => 2,
				 'addr'             => 3,
				 'fulladdr'         => 3,
				 'host'             => 3,
				},
		   'actions' => \%actions,
		  },
   },
   'post' =>
   {
    'parser'   => [qw(email shell list real)],
    'dispatch' => {'top' => 1, 'iter' => 1, 'noaddr' => 1},
    'access'   => {
		   'default' => 'special',
		   'legal'   =>
		   {
		    'master_password'              => 1,
		    'user_password'                => 1,
		    'mismatch'                     => 1,
		    'any'                          => 1,
		    'bytes'                        => 2,
		    'bad_approval'                 => 1,
		    'taboo'                        => 2,
		    'admin'                        => 2,
		    'days_since_subscribe'         => 2,
		    'dup'                          => 1,
		    'dup_msg_id'                   => 1,
		    'dup_checksum'                 => 1,
		    'dup_partial_checksum'         => 1,
		    'lines'                        => 2,
		    'max_header_length'            => 2,
		    'max_header_length_exceeded'   => 1,
		    'mime_consult'                 => 1,
		    'mime_deny'                    => 1,
		    'mime'                         => 1,
		    'percent_quoted'               => 2,
		    'quoted_lines'                 => 2,
		    'total_header_length'          => 2,
		    'total_header_length_exceeded' => 1,
		    'addr'                         => 3,
		    'fulladdr'                     => 3,
		    'host'                         => 3,
		   },
		   'actions' => \%actions,
		  },
   },
   'put' =>
   {
    'parser'   => [qw(email shell list global real)],
    'dispatch' => {'top' => 1, 'iter' => 1},
    'access'   => {
		   'default' => 'deny',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'register' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'confirm',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'reject' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1},
    # The token is the access restriction
   },
   'rekey' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'deny',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'sessioninfo' =>
   {
    'parser' => [qw(email shell real)],
    'dispatch' => {'top' => 1},
    # The session key is the access restriction
   },
   'set' =>
   {
    'parser'   => [qw(email shell list real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'confirm',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'show' =>
   {
    'parser' => [qw(email shell real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'mismatch',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'showtokens' =>
   {
    'parser'   => [qw(email shell list global all real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'deny',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'subscribe' =>
   {
    'parser'   => [qw(email shell list real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'special',
		   'legal'   => {
				 'master_password'=> 1,
				 'user_password'  => 1,
				 'mismatch'       => 1,
				 'matches_list'   => 1,
				 'addr'           => 3,
				 'fulladdr'       => 3,
				 'host'           => 3,
				},
		   'actions' => \%actions,
		  },
   },
   'tokeninfo' =>
   {
    'parser' => [qw(email shell real)],
    'dispatch' => {'top' => 1},
    # The token is the access restriction
   },
   'unalias' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'confirm',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'unregister' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1, 'noaddr' => 1},
    'access'   => {
		   'default' => 'confirm',
		   'legal'   =>\%reg_legal,
		   'actions' =>\%actions,
		  },
   },
   'unsubscribe' =>
   {
    'parser'   => [qw(email shell list all real)],
    'dispatch' => {'top' => 1, 'noaddr' => 1},
    'access'   => {
		   'default' => 'special',
		   'legal'   =>\%reg_legal,
		   'actions' =>\%actions,
		  },
   },
   'which' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1},
    'access'   => {
		   'default' => 'access',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
   'who' =>
   {
    'parser'   => [qw(email shell global list real)],
    'dispatch' => {'top' => 1, 'iter' => 1},
    'access'   => {
		   'default' => 'access',
		   'legal'   => \%reg_legal,
		   'actions' => \%actions,
		  },
   },
#   'writeconfig'    => {'parser' => [qw(email shell list obsolete real)],
#			'dispatch' => {'top' => 1},
#		       },
  );

# The %aliases hash maps aliases to the commands they really are.  This is
# intended for the support of foreign languages and other applications
# where having multiple names for one command is useful.
my %aliases =
  (
   '.'              => 'end',
   'aliasadd'       => 'alias',
   'aliasremove'    => 'unalias',
   'auxdel'         => 'auxremove',
   'auxsubscribe'   => 'auxadd',
   'auxunsubscribe' => 'auxremove',
   'auxshow'        => 'auxwho',
   'cancel'         => 'unsubscribe',
   'configdefault'  => 'configdef',
   'exit'           => 'end',
   'man'            => 'help',
   'quit'           => 'end',
   'remove'         => 'unsubscribe',
   'signoff'        => 'unsubscribe',
   'stop'           => 'end',
   'sub'            => 'subscribe',
   'unsub'          => 'unsubscribe',
  );

# --- Functions for the text parser and interfaces

# This determines if a command is legal.  A command is legal if it has
# parser properties or it is an alias.  Returns undef if not; otherwise
# returns the true name of the command looked up through the %aliases hash
# if necessary.
sub command_legal {
  my $command = lc(shift);
  return $command
    if( exists($commands{$command}) && $commands{$command}{'parser'} );
  return $aliases{$command}
    if( defined $aliases{$command} );
  return undef;
}

# This determines if a command (or alias to a command) has a certain
# property.  Returns undef if not or if the command doesn't exist (check
# first!), returns true if so.  If the property has a tag, returns the tag.
sub command_prop {
  my $command = shift;
  my $prop = shift;
  my (@plist, $i);

  $command = command_legal($command);
  return undef unless $command;

  @plist = @{$commands{$command}{'parser'}};

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
  my (@out, @tmp, $i, $j, $ok);

  for $i (keys(%commands), $alias?keys(%aliases):()) {
    if ($i =~ /$regex/ && $commands{$i}{'parser'}) {
      push @tmp, $i;
    }
  }

  if (@$proplist) {
    for $i (@tmp) {
      $ok = 1;
      for $j (@$proplist) {
	unless (command_prop($i, $j)) {
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

# This returns a list of all commands and aliases.
# beware! the first returned string is ".", for which no help file exists
# and which may kill some mail tools if echoed to a message on a separate line
sub command_list {
  return(sort keys(%commands), keys(%aliases));
}

# --- Functions for the core
sub function_prop {
  my $func = shift;
  my $prop = shift;
  my ($base) = $func =~ /^(.*?)(_(start|chunk|done))?$/;
  $commands{$base}{'dispatch'}{$prop};
}

sub function_legal {
  my $func = shift;
  my ($base) = $func =~ /^(.*?)(_(start|chunk|done))?$/;

  return 0 unless $commands{$base}{'dispatch'};
  return 0 if ($base ne $func) && !function_prop($func, 'iter');
  1;
}

# --- functions for access_rules configuration

# True if a request can legally appear in access_rules
sub rules_request {
  my $req = shift;
  !!$commands{$req}{'access'};
}

# Return all requests that can be restricted by access_rules
sub rules_requests {
  my(@out, $i);
  for $i (keys %commands) {
    push @out, $i if $commands{$i}{'access'};
  }
  @out;
}

# If passed a type, return true if the given variable is legal for the
# given request and has the given type.  Else return the type of the given
# variable.  If the request is not valid or the variable is not valid for
# the request, return false in any case
sub rules_var {
  my $req  = shift;
  my $var  = shift;
  my $type = shift;

  if (defined $type) {
    return $commands{$req}{'access'}{'legal'}{$var} &&
      $commands{$req}{'access'}{'legal'}{$var} == $type;
  }
  $commands{$req}{'access'}{'legal'}{$var};
}

# Return all legal variables for the given request.  If type is given,
# restrict to variables of that type.
sub rules_vars {
  my $req  = shift;
  my $type = shift;

  if (defined $type) {
    return grep {$commands{$req}{'access'}{'legal'}{$_} == $type} 
      keys %{$commands{$req}{'access'}{'legal'}}
	if rules_request($req);
  }
  else {
    return keys %{$commands{$req}{'access'}{'legal'}}
      if rules_request($req);
  }
  ();
}

# True if the given action is legal for the given request.
sub rules_action {
  my $req = shift;
  my $act = shift;
  $commands{$req}{'access'}{'actions'}{$act};
}

# Return all legal actions for the given request.
sub rules_actions {
  my $req = shift;
  return keys %{$commands{$req}{'access'}{'actions'}}
    if rules_request($req);
  ();
}

# Given the argument string of an action, split it and return the arguments
# which are filenames.
sub action_files {
  my $act = shift;
  my $arg = shift;
  my (@args, @out, $i);
  
  return unless $actions{$act};
    
  @args = split(/\s*,\s*/, $arg);
  for $i (@{$actions{$act}{files}}) {
    push @out, $args[$i];
  }
  @out;
}

# Return true if the action is terminal.
sub action_terminal {
  my $act = shift;
  return unless $actions{$act};
  return $actions{$act}{terminal};
}

# --- 
sub access_def {
  my $req = shift;
  my $def = shift;
  return 0 unless rules_request($req);
  return 0 unless $commands{$req}{'access'}{'default'} eq $def;
  1;
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

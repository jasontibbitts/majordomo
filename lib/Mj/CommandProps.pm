# This file contains data about all available Majordomo commands along with
# functions for accessing this data, collected in a single place.

package Mj::CommandProps;
require Exporter;
@ISA = qw(Exporter);

@EXPORT_OK = qw(access_def command_legal command_default command_prop
                commands_matching command_list function_prop function_legal
                rules_request rules_requests rules_var rules_vars
                rules_action rules_actions action_files action_terminal
                access_vars_desc_en);
%EXPORT_TAGS = ('command'  => [qw(command_legal command_default command_prop
                                  commands_matching command_list)],
                'function' => [qw(function_legal function_prop)],
                'rules'    => [qw(rules_request rules_requests rules_var
                                  rules_vars rules_action
                                  rules_actions action_files)],
                'access'   => [qw(access_def)],
       );
use strict;

# All supported actions, plus some additional information used for syntax checking
my %actions =
  ('allow'           => {files => [],    terminal => 1,},
   'confirm'         => {files => [0],   terminal => 1,},
   'confirm2'        => {files => [0,1], terminal => 1,},
   'consult'         => {files => [0],   terminal => 1,},
   'confirm_consult' => {files => [0,1], terminal => 1,},
   'default'         => {files => [],    terminal => 1,},
   'delay'           => {files => [0],   terminal => 1,},
   'deny'            => {files => [],    terminal => 1,},
   'forward'         => {files => [],    terminal => 1,},
#  'log'             => 1,
   'mailfile'        => {files => [0],},
   'reason'          => {files => [],},
   'reply'           => {files => [],},
   'replyfile'       => {files => [0],},
   'set'             => {files => [],},
   'unset'           => {files => [],},

   # These are for bounce_rules
   'unsubscribe'     => {files => [],    terminal => 1,},
   'ignore'          => {files => [],    terminal => 1,},
  );

# a standard set of access_rules variables
# this set is re-used for most of $commands{???}{'access'}{'legal'} below
my %reg_legal =
  ('master_password'=>1,
   'user_password'  =>1,
   'mismatch'       =>1,
   'posing'         =>1,
   'addr'           =>3,
   'delay'          =>3,
   'fulladdr'       =>3,
   'host'           =>3,
   'mode'           =>3,
  );

# one-line descriptions of every access_rule variable used in $commands{???}{'access'}{'legal'}
#  (not used at run-time, this hash is for the help file generator)
# only "en" for now, but some day there may be versions in other than english!
%Mj::CommandProps::access_vars_desc_en = (
                        'addr' => "contains the user's address, stripped of comments (such as 'joe\@blow.org')",
                       'admin' => "is set if any admin_* variable is set (note that admin configsets can create new variables)",
                         'any' => "is set if any of dup, taboo, admin, mime, or bad_approval is set",
                'bad_approval' => "is set if someone tried to do use a classic approval method and gave a bad password",
        'body_length_exceeded' => "is set if 'body_length' exceeds the value in 'configset LISTNAME maxlength'",
                 'body_length' => "contains the number of characters actually in the message body, see 'body_length_exceeded' for test",
        'days_since_subscribe' => "contains the number of days since the user signed up (used for a cooling off period before allowing posting)",
                       'delay' => "a string specifying the amount of time to delay a command",
                         'dup' => "is set if any of dup_checksum, dup_partial_checksum, or dup_msg_id are set",
                'dup_checksum' => "is set if the checksum of the message has been seen before",
                  'dup_msg_id' => "is set if the message ID has been seen before",
        'dup_partial_checksum' => "is set if the checksum of the first ten lines of the message has been seen before",
                    'fulladdr' => "contains the user's address, complete with any comments provided (such as 'Joe Blow <joe\@blow.org>')",
                        'host' => "contains the stuff on the right of the '\@' in the user's address (sometimes called the domain)",
                       'limit' => "is set if a soft or hard posting limit is reached",
                  'limit_hard' => "is set if a hard posting limit is reached",
                  'limit_soft' => "is set if a soft posting limit is reached",
                       'lines' => "contains the total number of lines in the message",
             'master_password' => "is set if one of the list's correct passwords was used",
                'matches_list' => "is set if the victim address matches the listname on a subscribe request (e.g. someone is trying to make a mail loop)",
           'max_header_length' => "contains the number of characters actually in the longest header, see 'max_header_length_exceeded' for test",
  'max_header_length_exceeded' => "is set if 'max_header_length' exceeds the value in 'configset LISTNAME max_header_line_length'",
                        'mime' => "is set if either mime_consult or mime_deny is true",
                'mime_consult' => "is set if attachment_rules flagged a MIME part as 'consult'",
                   'mime_deny' => "is set if attachment_rules flagged a MIME part as 'deny'",
          'mime_header_length' => "contains the number of characters actually in the longest MIME header, see 'mime_header_length_exceeded' for test",
 'mime_header_length_exceeded' => "is set if 'mime_header_length' exceeds the value in 'configset LISTNAME max_mime_header_length'",
                    'mismatch' => "is set if the user and victim addresses are not the same (after aliasing, transformation, etc.)",
                        'mode' => "contains the command mode or switch: for example, it contains 'enhanced' when the 'who-enhanced' command is used",
             'password_length' => "contains the length in characters of the new password the user is trying to set (can be used to enforce a minimum length)",
              'percent_quoted' => "contains the percentage of lines which are quoted (100 * quoted_lines / lines)",
                      'posing' => "is set if 'default user' is in effect",
                'quoted_lines' => "contains the number of lines that matched the pattern in 'configset quote_pattern'",
                     'sublist' => "is set to the name of the sublist, if a message was posted to an auxiliary list",
                       'taboo' => "is set if any taboo_* variable is set (note that taboo configsets can create new variables)",
         'total_header_length' => "contains the sum of the lengths of all headers, see 'total_header_length_exceeded' for test",
'total_header_length_exceeded' => "is set if 'total_header_length' exceeds the value in 'configset LISTNAME max_total_header_length'",
               'user_password' => "is set if the user's correct password was used",
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
   'default'    => {'parser' => [qw(email shell shell_parsed real)]},
   'end'        => {'parser' => [qw(email shell interp)]},
   'config'     => {'parser' => [qw(email list obsolete=configshow real)]},
   'configshow' => {'parser' => [qw(email shell list global real)],
                    'dispatch' => {'top' => 1, 
                                   'arguments' => {'split' => '[\s,]+',
                                                   'groups' => {'type' => 'ARRAY'}},
                                   'hereargs' => 'groups' 
                                  }
                   },
   'configset'  => {'parser' => [qw(email shell list global real)],
                    'dispatch' => {'top' => 1, 
                                   'arguments' => {'split' => '\s*=\s*',
                                                   'setting' => {'type' => 'SCALAR',},
                                                   'value', {'type' => 'ARRAYELEM'}},
                                   'hereargs' =>  'value',
                                  }
                   },
   'configdef'  => {'parser' => [qw(email shell list global real)],
                    'dispatch' => {'top' => 1,
                                   'arguments' => {'split', '[\s,]+',
                                                   'vars', {'type' => 'ARRAY'}},
                                   'hereargs' =>  'vars',
                                  }
                   },
   'configedit' => {'parser' => [qw(shell list global real)]},
   'newconfig'  => {'parser' => [qw(email shell list obsolete=configset real)]},
   'newfaq'     => {'parser' => [qw(email shell list global real)]},
   'newinfo'    => {'parser' => [qw(email shell list global real)]},
   'newintro'   => {'parser' => [qw(email shell list global real)]},

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
    'dispatch' => {'top' => 1,
                   'arguments' => {'tokens' => {'type' => 'ARRAYELEM',},
                                   'xplanation' => {'type' => 'SCALAR'}},
                   'hereargs'  => 'tokens',
                   'tokendata' => {'arg1' => 'tokens'},
                  },
    # The token is the access restriction
   },
   'alias' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1, 
		   'arguments' => {'newaddress', {'type' => 'SCALAR'}},
                   'tokendata' => {'arg1' => 'newaddress'},
                  },
    'access'   => {
                   'default' => 'confirm',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'announce' =>
   {
    'parser'   => [qw(email shell list global nohereargs real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {'file', {'type' => 'SCALAR'}},
                   'tokendata' => {'arg1' => 'file'}
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'archive' =>
   {
    'parser'   => [qw(email shell list real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => {'args', {'type' => 'SCALAR'}},
                   'tokendata' => {'arg1' => 'args'}
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'auxadd' =>
   {
    'parser' => [qw(email shell list global real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'auxlist' => {'type' => 'SCALAR',},
                                   'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs' => 'victims',
                   'tokendata' => {'victim' => 'victims',
                                   'arg1'   => 'auxlist' }
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'auxremove' =>
   {
    'parser' => [qw(email shell list global all real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {'auxlist' => {'type' => 'SCALAR',},
                                   'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs' => 'victims',
                   'tokendata' => {'victim' => 'victims',
                                   'arg1'   => 'auxlist' }
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'auxwho' =>
   {
    'parser' => [qw(email shell list global nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => {'auxlist' => {'type' => 'SCALAR',},
                                   'regexp'  => {'type' => 'SCALAR'}},
                   'tokendata' => {'arg2'    => 'auxlist',
                                   'arg1'    => 'regexp'}
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'changeaddr' =>
   {
    'parser' => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'victims'  => {'type' => 'ARRAYELEM'}},
                   'tokendata' => {'victim'   => 'victims'}
                  },
    'access'   => {
                   'default' => 'confirm2',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'createlist' =>
   {
    'parser' => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {'newlist' => {'type' => 'SCALAR',
                                                 'exclude' => 'regen'},
                                   'victims' => {'type' => 'ARRAYELEM'}},
                   'tokendata' => {'victim' => 'victims',
                                   'arg1' => 'newlist'}
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'digest' =>
   {
    'parser' => [qw(email shell list nohereargs real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {'args' => {'type' => 'SCALAR'}},
                   'tokendata' => {'arg1' => 'args'}
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'faq' =>
   {
    'parser'   => [qw(email shell list global nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1},
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'get' =>
   {
    'parser'   => [qw(email shell list global nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1, 
		   'arguments' => {'path' => {'type' => 'SCALAR'}},
                   'tokendata' => {'arg1' => 'path'}
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'help' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => {'topic' => {'type' => 'SCALAR'}},
                   'tokendata' => {'arg1' => 'topic'}
                  },
    'access'   => {
                   'default' => 'allow',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'index' =>
   {
    'parser'   => [qw(email shell list global nohereargs real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'path' => {'type' => 'SCALAR'}},
                   'tokendata' => {'arg1' => 'path'}
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'info' =>
   {
    'parser'   => [qw(email shell list nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1},
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'intro' =>
   {
    'parser'   => [qw(email shell list nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1},
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'lists' =>
   {
    'parser'   => [qw(email shell noargs nohereargs real)],
    'dispatch' => {'top' => 1,
                   'arguments' => { 'regexp' => {'type' => 'SCALAR'}}
                  },
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
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {'newpasswd' => {'type' => 'SCALAR',
                                                   'exclude' => 'rand|gen'},
                                   'victims'   => {'type' => 'ARRAYELEM',}
                                  },
                   'tokendata' => { 'arg1'   => 'newpasswd',
                                   'victim'  => 'victims'}
                  },
    'access'   => {
                   'default' => 'confirm',
                   'legal'   => {
                                 %reg_legal,
                                 'password_length'  => 2,
                                },
                   'actions' => \%actions,
                  },
   },
   'post' =>
   {
    'parser'   => [qw(email shell list real)],
    'dispatch' => {'top' => 1, 'iter' => 1, 
                   'arguments' => { 'auxlist' => {'type' => 'SCALAR'} },
                   'hereargs'  =>   'message',
                   'tokendata' => { 'arg1'   => 'file',
                                    'arg3'   => 'vars',}
                  },
    'access'   => {
                   'default' => 'special',
                   'legal'   =>
                   {
                    %reg_legal,
                    'any'                          => 1,
                    'bad_approval'                 => 1,
                    'body_length'                  => 2,
                    'body_length_exceeded'         => 1,
                    'taboo'                        => 2,
                    'admin'                        => 2,
                    'days_since_subscribe'         => 2,
                    'dup'                          => 1,
                    'dup_msg_id'                   => 1,
                    'dup_checksum'                 => 1,
                    'dup_partial_checksum'         => 1,
                    'limit'                        => 1,
                    'limit_hard'                   => 1,
                    'limit_soft'                   => 1,
                    'lines'                        => 2,
                    'max_header_length'            => 2,
                    'max_header_length_exceeded'   => 1,
                    'mime_consult'                 => 1,
                    'mime_deny'                    => 1,
                    'mime_header_length'           => 2,
                    'mime_header_length_exceeded'  => 1,
                    'mime'                         => 1,
                    'mode'                         => 3,
                    'percent_quoted'               => 2,
                    'quoted_lines'                 => 2,
                    'sublist'                      => 3,
                    'total_header_length'          => 2,
                    'total_header_length_exceeded' => 1,
                   },
                   'actions' => \%actions,
                  },
   },
   'put' =>
   {
    'parser'   => [qw(email shell list global real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => {'file'     => {'type' => 'SCALAR',},
                                   'ocontype' => {'type' => 'SCALAR',
                                                  'include' => 'data'},
                                   'ocset'    => {'type' => 'SCALAR',
                                                  'include' => 'data'},
                                   'oencoding'=> {'type' => 'SCALAR',
                                                  'include' => 'data'},
                                   'olanguage'=> {'type' => 'SCALAR',
                                                  'include' => 'data'},
                                   'xdesc'    => {'type' => 'SCALAR'}},
                   'hereargs' => 'contents'
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'register' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'newpasswd' => {'type' => 'SCALAR',
                                                   'include' => 'pass'},
                                   'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs'  => 'victims',
                   'tokendata' => {'victim' => 'victims',
                                   'arg1'   => 'newpasswd'}
                  },
    'access'   => {
                   'default' => 'confirm',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'reject' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'tokens' => {'type' => 'ARRAYELEM',},
                                   'xplanation' => {'type' => 'SCALAR'}},
                   'hereargs'  => 'tokens'
                  },
    # The token is the access restriction
   },
   'rekey' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1},
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'report' =>
   {
    'parser'   => [qw(email shell list global all nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => {'action'  => {'type' => 'SCALAR',},
                                   'date'    => {'type' => 'SCALAR',},},
                   'tokendata' => {'arg1'   => 'action',
                                   'arg2'   => 'date'}
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'sessioninfo' =>
   {
    'parser' => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => {'sessionid' => {'type' => 'SCALAR'}}
                  },
    # The session key is the access restriction
   },
   'set' =>
   {
    'parser'   => [qw(email shell list global all real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'auxlist' => {'type' => 'SCALAR',
                                                 'include' => 'aux'},
                                   'setting' => {'type' => 'SCALAR',
                                                 'exclude' => 'check'},
                                   'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs'  => 'victims',
                   'tokendata' => {'victim' => 'victims',
                                   'arg1'   => 'setting',
                                   'arg2'   => 'auxlist'}
                  },
    'access'   => {
                   'default' => 'policy',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'show' =>
   {
    'parser' => [qw(email shell real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs'  =>  'victims',
                   'tokendata' => {'victim' => 'victims'}
                  },
    'access'   => {
                   'default' => 'mismatch',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'showtokens' =>
   {
    'parser'   => [qw(email shell list global all real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'action' => {'type' => 'SCALAR'}},
                   'tokendata' => {'arg1' => 'action'}
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'subscribe' =>
   {
    'parser'   => [qw(email shell list real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs'  =>  'victims',
                   'tokendata' => {'victim' => 'victims'}
                  },
    'access'   => {
                   'default' => 'policy',
                   'legal'   => {
                                 'master_password'=> 1,
                                 'user_password'  => 1,
                                 'mismatch'       => 1,
                                 'posing'         => 1,
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
    'parser' => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'token' => {'type' => 'SCALAR'}},
                   'tokendata' => {'arg1'  => 'token'}
                  },
    # The token is the access restriction
   },
   'unalias' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'victims' => {'type' => 'ARRAYELEM'}},
                   'tokendata' => {'victim'  => 'victims'}
                  },
    'access'   => {
                   'default' => 'confirm',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'unregister' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs'  =>  'victims',
                   'tokendata' => {'victim' => 'victims'}
                  },
    'access'   => {
                   'default' => 'confirm',
                   'legal'   =>\%reg_legal,
                   'actions' =>\%actions,
                  },
   },
   'unsubscribe' =>
   {
    'parser'   => [qw(email shell list all real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs'  =>  'victims',
                   'tokendata' => {'victim' => 'victims'}
                  },
    'access'   => {
                   'default' => 'policy',
                   'legal'   =>\%reg_legal,
                   'actions' =>\%actions,
                  },
   },
   'which' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'regexp' => {'type' => 'SCALAR'}},
                   'tokendata' => {'arg1'   => 'regexp'}
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },
   'who' =>
   {
    'parser'   => [qw(email shell global list nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => {'regexp' => {'type' => 'SCALAR'}},
                   'tokendata' => {'arg1'   => 'regexp'}
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%actions,
                  },
   },

   # This isn't a command at all; the bounce_rules variable reuses most of
   # the access_rules code, so we store information about actions and
   # variables here as well.
   '_bounce' =>
   {
    'access' => {
		 'legal'   => {
			       'days_since_subscribe' => 2,
			       'consecutive'          => 2,
			       'bouncedpct'           => 2,
			       'numbered'             => 2,
			       'day'                  => 2,
			       'week'                 => 2,
			       'month'                => 2,
			      },
		 'actions' => {
			       'unsubscribe' => {files => [],    terminal => 1,},
			       'ignore'      => {files => [],    terminal => 1,},
			      },
		},
   },

#   'writeconfig'    => {'parser' => [qw(email shell list obsolete real)],
#                        'dispatch' => {'top' => 1},
#                       },
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

# This returns the default access for a command.
# Returns undef if command is not listed above, does NOT expand aliases.
sub command_default {
  my $command = lc(shift);
  # $command = command_legal($command);
  return undef if(!defined($commands{$command}));
  return $commands{$command}{'access'}{'default'};
}

1;


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
### End: ***

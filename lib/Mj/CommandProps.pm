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
                                  rules_vars rules_action rules_actions 
                                  action_files)],
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
   'notify'          => {files => [],},
   'reason'          => {files => [],},
   'reply'           => {files => [],},
   'replyfile'       => {files => [0],},
   'set'             => {files => [],},
   'unset'           => {files => [],},

   'remove'          => {files => [],    terminal => 1,},
   'ignore'          => {files => [],    terminal => 1,},
   'inform'          => {files => [],    terminal => 1,},
  );

my %generic_actions =
  ('allow'           => 1,
   'confirm'         => 1,
   'confirm2'        => 1,
   'consult'         => 1,
   'confirm_consult' => 1,
   'default'         => 1,
   'delay'           => 1,
   'deny'            => 1,
   'forward'         => 1,
#  'log'             => 1,
   'mailfile'        => 1,
   'notify'          => 1,
   'reason'          => 1,
   'reply'           => 1,
   'replyfile'       => 1,
   'set'             => 1,
   'unset'           => 1,
  );

my %generic_modes =
  (
   'noinform' => 1,
   'nolog'    => 1,
   'quiet'    => 1,
   'rule'     => 1,
  );

# a standard set of access_rules variables
# this set is re-used for most of $commands{???}{'access'}{'legal'} below
# The values on the right-hand side indicate the type.

my %reg_legal =
  (
   'chain'          =>  'bool',
   'mismatch'       =>  'bool',
   'posing'         =>  'bool',
   'user_password'  =>  'bool',
   'master_password'=>  'integer',
   'addr'           =>  'string',
   'addrcomment'    =>  'string',
   'fulladdr'       =>  'string',
   'host'           =>  'string',
   'interface'      =>  'string',
   'mode'           =>  'string',
   'sublist'        =>  'string',
   'delay'          =>  'timespan',
   'expire'         =>  'timespan',
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
   'configshow' => 
   {
    'parser' => [qw(email shell list global real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {'split' => '[\s,]+',
                                   'config' => {'type' => 'SCALAR',
                                                'include' => 'merge'
                                               },
                                   'groups' => {'type' => 'ARRAY'}},
                   'hereargs' => 'groups',
                   'modes'    =>  
                     {
                      %generic_modes,
                      'append'      => {'exclude' => 'extract'},
                      'categories'  => {'exclude' => 'append|declared|extract|merge|nocomments' },
                      'declared'    => {'exclude' => 'merge'},
                      'extract'     => 1,
                      'merge'       => 1,
                      'nocomments'  => 1,
                     },
                  }
   },
   'configset'  => 
   {
    'parser' => [qw(email shell list global real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {'split'   => '[\s=]+',
                                   'setting' => {'type' => 'SCALAR',},
                                   'value'   => {'type' => 'ARRAYELEM'}},
                   'hereargs' =>  'value',
                   'modes'    =>  {
                                   %generic_modes,
                                   'append'      => {'exclude' => 'extract'},
                                   'extract'     => 1,
                                  },
                  }
   },
   'configdef'  => 
   {
    'parser' => [qw(email shell list global real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'split', '[\s,]+',
                                   'setting'     => {'type' => 'ARRAY'}},
                   'hereargs' =>  'setting',
                   'modes'    =>  {
                                   %generic_modes,
                                  },
                  }
   },
   'configedit' => {'parser' => [qw(shell list global real)]},
   'newconfig'  => {'parser' => [qw(email shell list obsolete=configset real)]},
   'newfaq'     => {'parser' => [qw(email shell list global real)]},
   'newinfo'    => {'parser' => [qw(email shell list global real)]},
   'newintro'   => {'parser' => [qw(email shell list global real)]},

   # Internal commands (not accessible to the end user except through
   # specialized interfaces)
   'owner' => 
   {
    'dispatch' => {'top' => 1, 
                   'iter' => 1, 
                   'noaddr' => 1,
                   'modes' => {
                                'm'           => 1,
                              },
                  },
   },
   'trigger' => 
   {
    'dispatch' => {'top' => 1, 
                   'noaddr' => 1,
                   'modes'    =>  {
                                   %generic_modes,
                                   'b'           => 1,
                                   'c'           => 1,
                                   'da'          => 1,
                                   'de'          => 1,
                                   'di'          => 1,
                                   'h'           => 1,
                                   'l'           => 1,
                                   'p'           => 1,
                                   's'           => 1,
                                   't'           => 1,
                                   'v'           => 1,
                                  },
                  }
   },
   'request_response' =>
   {
    'dispatch' => {'top' => 1},
    'access'   => {
                   'default' => 'allow',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
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
                   'modes'    =>  {
                                   %generic_modes,
                                   'archive'     => 1,
                                   'hide'        => 1,
                                   'intact'      => 1,
                                  },
                   'tokendata' => {'arg1' => 'tokens'},
                  },
    # The token is the access restriction
   },
   'alias' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1, 
		   'arguments' => {'newaddress', {'type' => 'SCALAR'}},
                   'modes'    =>  {
                                   %generic_modes,
                                  },
                   'tokendata' => {'arg1' => 'newaddress'},
                  },
    'access'   => {
                   'default' => 'confirm',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'announce' =>
   {
    'parser'   => [qw(email shell list global nohereargs real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {
                                   'file' => {'type' => 'SCALAR'}
                                  },
                   'modes'    =>  {
                                   %generic_modes,
                                   'digest'      => 1,
                                   'each'        => 1,
                                   'nomail'      => 1,
                                   'unique'      => 1,
                                  },
                   'tokendata' => {
                                   'arg1' => 'file',
                                   'arg2' => 'sublist'
                                  }
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'archive' =>
   {
    'parser'   => [qw(email shell list real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => {
                                   'args' => {'type' => 'SCALAR'}
                                  },
                   'hereargs' => 'patterns',
                   'modes'    =>  {
                                   %generic_modes,
                                   'author'      => {'include' => 'get|index'},
                                   'date'        => {'include' => 'get|index'},
                                   'delete'      => {'exclude' => 'get|index|stats|summary|sync'},
                                   'digest'      => {'include' => 'get'},
                                   'force'       => {'include' => 'delete'},
                                   'get'         => 1,
                                   'hidden'      => 1,
                                   'immediate'   => {'include' => 'get'},
                                   'index'       => 1,
                                   'mime'        => {'include' => 'digest'},
                                   'reverse'     => {'include' => 'get|index'},
                                   'stats'       => {'exclude' => 'get|index|summary|sync'},
                                   'subject'     => {'include' => 'get|index'},
                                   'summary'     => {'exclude' => 'get|index|sync'},
                                   'sync'        => {'exclude' => 'get|index'},
                                   'thread'      => {'include' => 'get|index'},
                                  },
                   'tokendata' => {'arg1' => 'args',
                                   'arg2' => 'patterns' }
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'changeaddr' =>
   {
    'parser' => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'victims'  => {'type' => 'ARRAYELEM'}},
                   'modes'    =>  {
                                   %generic_modes,
                                  },
                   'tokendata' => {'victim'   => 'victims'}
                  },
    'access'   => {
                   'default' => 'confirm2',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'createlist' =>
   {
    'parser' => [qw(email shell real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {'newlist'   => {'type' => 'SCALAR',
                                                   'exclude' => 'regen'},
                                   'newpasswd' => {'type' => 'SCALAR',
                                                   'include' => 'pass|rename'},
                                   'owners'   =>  {'type' => 'ARRAYELEM'}
                                  },
                   'hereargs'  => 'owners',
                   'modes'    =>  {
                                   %generic_modes,
                                   'destroy'     => {'exclude' => 'force|noarchive|nocreate|noheader|nowelcome|pass|regen|rename'},
                                   'force'       => 1,
                                   'noarchive'   => 1,
                                   'nocreate'    => {'exclude' => 'force|noarchive|noheader|nowelcome|pass|regen|rename'},
                                   'noheader'    => 1,
                                   'nowelcome'   => 1,
                                   'pass'        => 1,
                                   'regen'       => {'exclude' => 'force|noarchive|noheader|nowelcome|pass|rename'},
                                   'rename'      => {'exclude' => 'force|noarchive|noheader|nowelcome|pass'},
                                  },
                   'tokendata' => {'arg2' => 'owners',
                                   'arg1' => 'newlist',
                                   'arg3' => 'newpasswd',
                                  }
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'digest' =>
   {
    'parser' => [qw(email shell list nohereargs real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {'args' => {'type' => 'SCALAR'}},
                   'modes'    =>  {
                                   %generic_modes,
                                   'check'       => {'exclude' => 'force|incvol|status'},
                                   'force'       => {'exclude' => 'incvol|status'},
                                   'incvol'      => 1,
                                   'repeat'      => 1,
                                   'status'      => {'exclude' => 'repeat'},
                                  },
                   'tokendata' => {'arg1' => 'args'}
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'faq' =>
   {
    'parser'   => [qw(email shell list global nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'modes'    =>  {
                                   %generic_modes,
                                   'edit'        => 1,
                                  },
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'get' =>
   {
    'parser'   => [qw(email shell list global nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1, 
		   'arguments' => {'path' => {'type' => 'SCALAR'}},
                   'modes'    =>  {
                                   %generic_modes,
                                   'edit'        => {'exclude' => 'immediate'},
                                   'immediate'   => 1,
                                  },
                   'tokendata' => {'arg1' => 'path'}
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'help' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1, 'nopass' => 1,
                   'arguments' => {'topic' => {'type' => 'SCALAR'}},
                   'modes'    =>  {
                                   %generic_modes,
                                  },
                   'tokendata' => {'arg1' => 'topic'}
                  },
    'access'   => {
                   'default' => 'allow',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'index' =>
   {
    'parser'   => [qw(email shell list global nohereargs real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'path' => {'type' => 'SCALAR'}},
                   'modes'    =>  {
                                   %generic_modes,
                                   'long'        => {'exclude' => 'short'},
                                   'nodirs'      => 1,
                                   'nosort'      => 1,
                                   'recurs'      => 1,
                                   'short'       => 1,
                                   'ugly'        => {'exclude' => 'nodirs|nosort'},
                                  },
                   'tokendata' => {'arg1' => 'path'}
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'info' =>
   {
    'parser'   => [qw(email shell list nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'modes'    =>  {
                                   %generic_modes,
                                   'edit'        => 1,
                                  },
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'intro' =>
   {
    'parser'   => [qw(email shell list nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'modes'    =>  {
                                   %generic_modes,
                                   'edit'        => 1,
                                  },
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'lists' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1, 'nopass' => 1,
                   'arguments' => { 'regexp' => {'type' => 'SCALAR'}},
                   'modes'    =>  {
                                   %generic_modes,
                                   'aux'         => 1,
                                   'compact'     => 1,
                                   'config'      => 1,
                                   'enhanced'    => 1,
                                   'full'        => 1,
                                   'long'        => 1,
                                   'short'       => 1,
                                   'tiny'        => 1,
                                  },
                   'tokendata' => { 'arg1' => 'regexp',
                                    'arg2' => 'password', },
                  },
    'access'   => {
                   'default' => 'mismatch',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'password' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1, 
                   'arguments' => {'newpasswd' => {'type' => 'SCALAR',
                                                   'exclude' => 'rand|gen'},
                                   'victims'   => {'type' => 'ARRAYELEM',}
                                  },
                   'modes'    =>  {
                                   %generic_modes,
                                   'gen'         => 1,
                                   'rand'        => 1,
                                  },
                   'tokendata' => { 'arg1'   => 'newpasswd',
                                   'victim'  => 'victims'}
                  },
    'access'   => {
                   'default' => 'confirm',
                   'legal'   => {
                                 %reg_legal,
                                 'password_length'  => 'integer',
                                },
                   'actions' => \%generic_actions,
                  },
   },
   'post' =>
   {
    'parser'   => [qw(email shell list real)],
    'dispatch' => {'top' => 1, 'iter' => 1,  'noaddr' => 1,
                   'arguments' => {'subject' => {'type' => 'SCALAR',
                                                 'include' => 'addhdr'},
                                  },
                   'hereargs'  =>   'message',
                   'modes'    =>  {
                                   %generic_modes,
                                   'addhdr'      => 1,
                                   'archive'     => 1,
                                   'hide'        => 1,
                                   'intact'      => 1,
                                  },
                   'tokendata' => { 'arg1'   => 'file',
                                    'arg3'   => 'vars',}
                  },
    'access'   => {
                   'default' => 'special',
                   'legal'   =>
                   {
                    %reg_legal,
                    'any'                          => 'bool',
                    'bad_approval'                 => 'bool',
                    'blind_copy'                   => 'bool',
                    'body_length'                  => 'integer',
                    'body_length_exceeded'         => 'bool',
                    'taboo'                        => 'integer',
                    'admin'                        => 'integer',
                    'noarchive'                    => 'integer',
                    'days_since_subscribe'         => 'integer',
                    'dup'                          => 'bool',
                    'dup_msg_id'                   => 'bool',
                    'dup_checksum'                 => 'bool',
                    'dup_partial_checksum'         => 'bool',
                    'hide_post'                    => 'bool',
                    'invalid_from'                 => 'bool',
                    'limit'                        => 'bool',
                    'limit_hard'                   => 'bool',
                    'limit_soft'                   => 'bool',
                    'lines'                        => 'integer',
                    'max_header_length'            => 'integer',
                    'max_header_length_exceeded'   => 'bool',
                    'mime_consult'                 => 'bool',
                    'mime_deny'                    => 'bool',
                    'mime_header_length'           => 'integer',
                    'mime_header_length_exceeded'  => 'bool',
                    'mime_require'                 => 'bool',
                    'mime'                         => 'bool',
                    'mode'                         => 'string',
		    'nonempty_lines'               => 'integer',
                    'percent_quoted'               => 'integer',
                    'post_block'                   => 'bool',
                    'quoted_lines'                 => 'integer',
                    'total_header_length'          => 'integer',
                    'total_header_length_exceeded' => 'bool',
                   },
                   'actions' => \%generic_actions,
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
                                   'xdesc'    => {'type' => 'SCALAR'}
                                  },
                   'hereargs' => 'contents',
                   'modes'    =>  {
                                   %generic_modes,
                                   'data'        => {'exclude' => 'delete|dir'},
                                   'delete'      => {'exclude' => 'dir'},
                                   'dir'         => 1,
                                   'force'       => {'include' => 'delete'},
                                  },
                   'tokendata' => { 'arg1'   => 'spool' }
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
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
                   'modes'    =>  {
                                   %generic_modes,
                                   'nowelcome'   => 1,
                                   'pass'        => 1,
                                   'welcome'     => 1,
                                  },
                   'tokendata' => {'victim' => 'victims',
                                   'arg1'   => 'newpasswd'}
                  },
    'access'   => {
                   'default' => 'confirm',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'reject' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'tokens' => {'type' => 'ARRAYELEM',},
                                   'xplanation' => {'type' => 'SCALAR'}},
                   'hereargs'  => 'tokens',
                   'modes'    =>  {
                                   %generic_modes,
                                  },
                  },
    # The token is the access restriction
   },
   'rekey' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => { 'regexp' => {'type'    => 'SCALAR',
                                                 'include' => 'repair|verify',
                                                }
                                  },
                   'modes'    =>  {
                                   %generic_modes,
                                   'noxform'     => {'exclude' => 'repair|verify'},
                                   'repair'      => 1,
                                   'verify'      => 1,
                                  },   
                   'tokendata' => { 'arg1' => 'regexp',},
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'report' =>
   {
    'parser'   => [qw(email shell list global all real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => {'date'    => {'type' => 'SCALAR',},
                                   'requests'=> {'type' => 'ARRAYELEM',},
                                  },
                   'hereargs' => 'requests',
                   'modes'    =>  {
                                   %generic_modes,
                                   'full'        => {'exclude' => 'summary'},
                                   'inform'      => 1,
                                   'summary'     => 1,
                                  },
                   'tokendata' => {'arg2'   => 'action',
                                   'arg1'   => 'date'}
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'sessioninfo' =>
   {
    'parser' => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => {'sessionid' => {'type' => 'SCALAR'}},
                   'modes'    =>  {
                                   %generic_modes,
                                  },
                  },
    # The session key is the access restriction
   },
   'set' =>
   {
    'parser'   => [qw(email shell list global all real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'setting' => {'type' => 'SCALAR',
                                                 'exclude' => 'check'},
                                   'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs'  => 'victims',
                   'modes'    =>  {
                                   %generic_modes,
                                   'allmatching' => {'include' => 'pattern|regex'},
                                   'check'       => 1,
                                   'pattern'     => 1,
                                   'regex'       => 1,
                                  },
                   'tokendata' => {'victim' => 'victims',
                                   'arg1'   => 'setting',
                                   'arg2'   => 'sublist'}
                  },
    'access'   => {
                   'default' => 'policy',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'show' =>
   {
    'parser' => [qw(email shell real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs'  =>  'victims',
                   'modes'    =>  {
                                   %generic_modes,
                                  },
                   'tokendata' => {'victim' => 'victims'}
                  },
    'access'   => {
                   'default' => 'mismatch',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'showtokens' =>
   {
    'parser'   => [qw(email shell nohereargs list global all real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'action' => {'type' => 'SCALAR'}},
                   'modes'    =>  {
                                   %generic_modes,
                                   'alias'       => 1,
                                   'async'       => 1,
                                   'delay'       => 1,
                                   'probe'       => 1,
                                  },
                   'tokendata' => {'arg1' => 'action'}
                  },
    'access'   => {
                   'default' => 'deny',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'subscribe' =>
   {
    'parser'   => [qw(email shell list global real)],
    'dispatch' => {'top' => 1,
                                   
                   'arguments' => {'setting' => {'type'    => 'SCALAR',
                                                 'include' => 'set' },
                                   'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs'  =>  'victims',
                   'modes'    =>  {
                                   %generic_modes,
                                   'nowelcome'   => {'exclude' => 'welcome'},
                                   'set'         => 1,
                                   'welcome'     => 1,
                                  },
                   'tokendata' => {'victim' => 'victims',
                                   'arg1' => 'setting',
                                   'arg2' => 'sublist'}
                  },
    'access'   => {
                   'default' => 'policy',
                   'legal'   => {
                                 %reg_legal,
                                 'matches_list'   => 'bool',
                                },
                   'actions' => \%generic_actions,
                  },
   },
   'tokeninfo' =>
   {
    'parser' => [qw(email shell real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => {'id'   => {'type' => 'SCALAR'},
                                   'part' => {'type' => 'SCALAR',
                                              'include' => 'part',
                                             },
                                  },
                   'hereargs' =>  'contents',
                   'modes'    =>  {
                                   %generic_modes,
                                   'delete'      => {'include' => 'part',
                                                     'exclude' => 'edit|replace'},
                                   'edit'        => {'include' => 'part',
                                                     'exclude' => 'replace'},
                                   'nosession'   => 1,
                                   'part'        => 1,
                                   'remind'      => {'exclude' => 'nosession|part'},
                                   'replace'     => {'include' => 'part'},
                                  },
                   'tokendata' => {'arg1'  => 'id',
                                   'arg2'  => 'part'
                                  },
                  },
    # The token is the access restriction
   },
   'unalias' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'victims' => {'type' => 'ARRAYELEM'}},
                   'modes'    =>  {
                                   %generic_modes,
                                  },
                   'tokendata' => {'victim'  => 'victims'}
                  },
    'access'   => {
                   'default' => 'confirm',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'unregister' =>
   {
    'parser'   => [qw(email shell real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs'  =>  'victims',
                   'modes'    =>  {
                                   %generic_modes,
                                   'allmatching' => {'include' => 'pattern|regex'},
                                   'pattern'     => 1,
                                   'regex'       => 1,
                                  },
                   'tokendata' => {'victim' => 'victims'}
                  },
    'access'   => {
                   'default' => 'confirm',
                   'legal'   =>\%reg_legal,
                   'actions' =>\%generic_actions,
                  },
   },
   'unsubscribe' =>
   {
    'parser'   => [qw(email shell list global all real)],
    'dispatch' => {'top' => 1,
                   'arguments' => {'victims' => {'type' => 'ARRAYELEM'}},
                   'hereargs'  =>  'victims',
                   'modes'    =>  {
                                   %generic_modes,
                                   'allmatching' => {'include' => 'pattern|regex'},
                                   'farewell'    => 1,
                                   'pattern'     => 1,
                                   'regex'       => 1,
                                  },
                   'tokendata' => {'victim' => 'victims',
                                   'arg1'   => 'sublist' }
                  },
    'access'   => {
                   'default' => 'policy',
                   'legal'   =>\%reg_legal,
                   'actions' =>\%generic_actions,
                  },
   },
   'which' =>
   {
    'parser'   => [qw(email shell nohereargs real)],
    'dispatch' => {'top' => 1,
                   'arguments' => { 'regexp' => {'type' => 'SCALAR'}},
                   'modes'    =>  {
                                   %generic_modes,
                                   'pattern'     => 1,
                                   'regex'       => 1,
                                  },
                   'tokendata' => {'arg1'   => 'regexp'}
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },
   'who' =>
   {
    'parser'   => [qw(email shell global list nohereargs real)],
    'dispatch' => {'top' => 1, 'iter' => 1,
                   'arguments' => {'list2'  => {'type'    => 'SCALAR',
                                                'include' => 'common'},
                                   'regexp' => {'type'    => 'SCALAR'}
                                  },
                   'modes'    =>  {
                                   %generic_modes,
                                   'alias'       => {'exclude' => 'bounce|common|enhaced|export|owners'},
                                   'bounce'      => 1,
                                   'common'      => 1,
                                   'enhanced'    => 1,
                                   'export'      => {'exclude' => 'bounce|common|enhanced|owners'},
                                   'owners'      => {'exclude' => 'bounce|common|enhanced'},
                                   'short'       => 1,
                                  },
                   'tokendata' => {'arg1'   => 'regexp',
                                   'arg2'   => 'sublist',
                                   'arg3'   => 'list2'}
                  },
    'access'   => {
                   'default' => 'access',
                   'legal'   => \%reg_legal,
                   'actions' => \%generic_actions,
                  },
   },

   # This isn't a command at all; the bounce_rules variable reuses most of
   # the access_rules code, so we store information about actions and
   # variables here as well.
   '_bounce' =>
   {
    'access' => {
		 'legal'   => {
			       'addr'                 => 'string',
			       'fulladdr'             => 'string',
			       'host'                 => 'string',
			       'diagnostic'           => 'string',
			       'subscribed'           => 'bool',
			       'days_since_subscribe' => 'integer',
			       'consecutive'          => 'integer',
			       'consecutive_days'     => 'integer',
			       'bouncedpct'           => 'integer',
			       'numbered'             => 'integer',
			       'day'                  => 'integer',
			       'week'                 => 'integer',
			       'month'                => 'integer',
			      },
		 'actions' => {
			       'remove' => 1,
			       'ignore' => 1,
			       'inform' => 1,
			       'notify' => 1,
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
   'cancel'         => 'unsubscribe',
   'configdefault'  => 'configdef',
   'exit'           => 'end',
   'man'            => 'help',
   'mkdigest'       => 'digest',
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
      $commands{$req}{'access'}{'legal'}{$var} eq $type;
  }
  $commands{$req}{'access'}{'legal'}{$var};
}

# Return all legal variables for the given request.  If type is given,
# restrict to variables of that type.
sub rules_vars {
  my $req  = shift;
  my $type = shift;

  if (defined $type) {
    return grep {$commands{$req}{'access'}{'legal'}{$_} eq $type}
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

=head1 NAME

mj_cf_data.pl - data for configuration file manipulation

=head1 DESCRIPTION

This file contains the data on the configuration keys that are accepted by
the configuration parser.  It is not intended to be edited by the end user;
use mj_cf_local.pl instead.

A single hash of hashes is used to store the data.  The following hash
keys are used:

 type    - the data type stored in the variable
 values  - the set of allowed values for type enum variables
 groups  - the group memberships of the variable
 local   - true if the variable is list-specific.
 global  - true if the variable is part of the global Majordomo config
           (note that a variable may be both local and global).
 visible - True if the variable is visible without password validation.
 mutable - True if the list owner can change the variable; otherwise,
           only someone with a global password can change it.

=cut
 
package Mj::Config;

$std_access_desc = <<EOC;
One of three values: open, list, closed.  Open allows anyone access to this
command.  List allows only list members access, while closed completely
disables the command for everyone.
EOC

%vars =
  (
   'faq_access' => 
   {
    'type'   => 'enum',
    'values' => [qw(open closed list)],
    'groups' => [qw(access majordomo)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'get_access' => 
   {
    'type'   => 'enum',
    'values' => [qw(open closed list)],
    'groups' => [qw(access majordomo)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'index_access' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed list)],
    'groups' => [qw(access majordomo)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'who_access' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed list)],
    'groups' => [qw(access majordomo)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'which_access' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed list)],
    'groups' => [qw(access majordomo)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'info_access' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed list)],
    'groups' => [qw(access majordomo)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'intro_access' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed list)],
    'groups' => [qw(access majordomo)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'advertise' =>
   {
    'type'   => 'regexp_array',
    'groups' => [qw(majordomo access advertise lists)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'noadvertise' =>
   {
    'type'   => 'regexp_array',
    'groups' => [qw(majordomo access advertise lists)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'advertise_subscribed' =>
   {
    'type'   => 'bool',
    'groups' => [qw(majordomo access advertise lists)],
    'visible'=> 0,
    'global' => 1,
   },
   'ack_denials_always' =>
   {
    'type'   => 'bool',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 0,
    'mutable'=> 1,
   },
   'ack_attach_original' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(fail stall succeed any)],
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 0,
    'mutable'=> 1,
   },
   'inform' =>
   {
    'type'   => 'inform',
    'groups' => [qw(inform)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'access_password_override' =>
   {
    'type'   => 'bool',
    'groups' => [qw(access)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'access_rules' =>
   {
    'type'   => 'access_rules',
    'groups' => [qw(access)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'attachment_rules' =>
   {
    'type'   => 'attachment_rules',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 0,
    'mutable'=> 1,
   },
   'database_backend' =>
   {
    'type'   => 'enum',
    'values' => [qw(text)],
    'groups' => [qw(general)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
   },
   'default_flags' =>
   {
    'type'   => 'string',
    'groups' => [qw(flags)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'nonmember_flags' =>
   {
    'type'   => 'string',
    'groups' => [qw(flags)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'allowed_flags' =>
   {
    'type'   => 'string',
    'groups' => [qw(flags)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'default_class' =>
   {
    'type'   => 'string',
    'groups' => [qw(class)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'allowed_classes' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(class)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'delivery_rules' =>
   {
    'type'   => 'delivery_rules',
    'groups' => [qw(delivery)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 0,
   },
   'comments' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(comments)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'category' =>
   {
    'type'   => 'string',
    'groups' => [qw(majordomo lists)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'description' =>
   {
    'type'   => 'string',
    'groups' => [qw(majordomo lists)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'description_long' =>
   {
    'type'   => 'string_array',
    'groups' => ['lists'],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'subscribe_policy' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed auto open+confirm closed+confirm auto+confirm)],
    'groups' => [qw(majordomo access subscribe)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'unsubscribe_policy' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed auto)],
    'groups' => [qw(majordomo access subscribe)],
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'date_info' =>
   {
    'type'   => 'bool',
    'groups' => [qw(majordomo messages)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'date_intro' =>
   {
    'type'   => 'bool',
    'groups' => [qw(majordomo messages)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'max_header_line_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'max_mime_header_length' =>
   {
    'type'   => 'integer',
    'groups' => ['resend'],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'max_total_header_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'maxlength' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'moderate' =>
   {
    'type'   => 'bool',
    'groups' => [qw(resend access)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'moderator' =>
   {
    'type'   => 'word',
    'groups' => [qw(resend access)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'moderators' =>
   {
    'type'   => 'address_array',
    'groups' => [qw(resend access)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'moderator_group' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend access)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'sender' =>
   {
    'type'   => 'address',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'global' => 1,
    'local'  => 1,
    'mutable'=> 1,
   },
   'precedence' =>
   {
    'type'   => 'word',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'reply_to' =>
   {
    'type'   => 'word',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'override_reply_to' =>
   {
    'type'   => 'bool',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'purge_received' =>
   {
    'type'   => 'bool',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'quote_pattern' =>
   {
    'type'   => 'regexp',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'resend_host' =>
   {
    'type'   => 'word',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'restrict_post' =>
   {
    'type'   => 'restrict_post',
    'groups' => [qw(resend access)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'sequence_number' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 0,
    'mutable'=> 1,
    'auto'   => 1,
   },
   'administrivia' =>
   {
    'type'   => 'bool',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'debug' =>
   {
    'type'   => 'integer',
    'groups' => [qw(mtaconfig)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 0,
    'global' => 1,
   },
   'addr_allow_at_in_phrase' =>
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
   },
   'addr_allow_bang_paths' =>
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
   },
   'addr_allow_comments_after_route' =>
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
   },
   'addr_allow_ending_dot' => 
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
   },
   'addr_limit_length' =>
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
   },
   'addr_require_fqdn' =>
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
   },
   'addr_strict_domain_check' =>
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
   },
   'archive_dir' =>
   {
    'type'   => 'directory',
    'groups' => [qw(archive)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 0,
   },
   'archive_size' =>
   {
    'type'   => 'string',
    'groups' => [qw(archive)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'archive_split' =>
   {
    'type'   => 'enum',
    'values' => [qw(yearly monthly weekly daily)],
    'groups' => [qw(archive)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'message_fronter' =>
   {
    'type'   => 'string_2darray',
    'groups' => [qw(resend digest)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'message_fronter_frequency' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'message_footer' =>
   {
    'type'   => 'string_2darray',
    'groups' => [qw(resend digest)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'message_footer_frequency' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'message_headers' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(resend digest)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'delete_headers' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'subject_prefix' =>
   {
    'type'   => 'string',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'admin_headers' =>
   {
    'type'   => 'taboo_headers',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'admin_body' =>
   {
    'type'   => 'taboo_body',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'taboo_headers' =>
   {
    'type'   => 'taboo_headers',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'taboo_body' =>
   {
    'type'   => 'taboo_body',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'digests' =>
   {
    'type'   => 'digests',
    'groups' => [qw(digest)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'digest_index_format' =>
   {
    'type'   => 'enum',
    'values' => [qw(subject subject_author)],
    'groups' => ['digest'],
    'visible'=> 0,
    'global' => 0,
    'local'  => 1,
    'mutable'=> 1,
   },
   'digest_issues' =>
   {
    'type'   => 'digest_issues',
    'groups' => ['digest'],
    'visible'=> 0,
    'global' => 0,
    'local'  => 1,
    'mutable'=> 1,
    'auto'   => 1,
   },
   'addr_xforms' =>
   {
    'type'   => 'xform_array',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'global' => 1,
    'local'  => 0,
    'mutable'=> 1,
   },
   'master_password' =>
   {
    'type'   => 'pw',
    'groups' => [qw(password)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'passwords' =>
   {
    'type'   => 'passwords',
    'groups' => [qw(password)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'password_min_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(password)],
    'visible'=> 0,
    'global' => 1,
   },
   'welcome' =>
   {
    'type'   => 'bool',
    'groups' => [qw(majordomo welcome)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'welcome_files' =>
   {
    'type'   => 'welcome_files',
    'groups' => [qw(majordomo welcome)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
   },
   'filedir' =>
   {
    'type'   => 'directory',
    'groups' => [qw(filespace)],
    'global' => 1,
    'local'  => 1,
    'mutable'=> 0,
    'visible'=> 0,
   },
   'file_search' =>
   {
    'type'   => 'list_array',
    'groups' => [qw(filespace)],
    'local'  => 1,
   },
   'file_share' =>
   {
    'type'   => 'list_array',
    'groups' => [qw(filespace)],
    'local'  => 1,
   },
# Purely global configuration variables below
   
   'site_name' =>
   {
    'type'   => 'string',
    'groups' => [qw(majordomo)],
    'global' => 1,
    'visible'=> 1,
   },
   'whereami' =>
   {
    'type'   => 'word',
    'groups' => [qw(majordomo)],
    'global' => 1,
    'visible'=> 0,
   },
   'whoami' =>
   {
    'type'   => 'address',
    'groups' => [qw(majordomo)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
   },
   'whoami_owner' =>
   {
    'type'   => 'address',
    'groups' => [qw(majordomo)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'owners' =>
   {
    'type'   => 'address_array',
    'groups' => [qw(majordomo)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'tmpdir' =>
   {
    'type'   => 'word',
    'groups' => ['majordomo'],
    'global' => 1,
    'visible'=> 0,
   },
   'max_in_core' =>
   {
    'type'   => 'integer',
    'groups' => ['email'],
    'global' => 1,
    'visible'=> 1,
   },
   'return_subject' =>
   {
    'type'   => 'bool',
    'groups' => ['email'],
    'global' => 1,
    'visible'=> 1,
   },
   'chunksize' =>
   {
    'type'   => 'integer',
    'groups' => ['majordomo'],
    'global' => 1,
    'visible'=> 1,
   },
   'default_language' =>
   {
    'type'   => 'string',
    'groups' => [qw(language)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
   },
   'default_lists_format' =>
   {
    'type'   => 'enum',
    'values' => [qw(tiny compact short long enhanced)],
    'groups' => ['lists'],
    'global' => 1,
    'visible'=> 0,
   },
   'description_max_lines' =>
   {
    'type'   => 'integer',
    'groups' => ['lists'],
    'global' => 1,
    'visible'=> 0,
   },
   'confirm_url' =>
   {
    'type'   => 'string',
    'groups' => [qw(access token)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 0,
   },
   'token_remind' =>
   {
    'type'   => 'integer',
    'groups' => [qw(access token)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 0,
   },
   'dup_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend majordomo)],
    'global' => 0,
    'local'  => 1,
    'visible'=> 0,
  },
   'session_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(majordomo)],
    'global' => 1,
    'visible'=> 0,
  },
   'token_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(access token)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 0,
   },
   'bounce_probe_frequency' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend deliver bounce)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 0,
    'mutable'=> 0,
   },
   'request_answer' =>
   {
    'type'   => 'enum',
    'values' => [qw(majordomo owner response)],
    'groups' => [qw(general)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'signature_separator' =>
   {
    'type'   => 'regexp',
    'groups' => [qw(parser)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
   },
   );

$file_header = q(# Most of this is completely bogus!

# The configuration file for a majordomo mailing list.
# Comments start with the first # on a line, and continue to the end
# of the line. There is no way to escape the # character. The file
# uses either a key = value for simple (i.e. a single) values, or uses
# a here document
#     key << END 
#     value 1
#     value 2
#     [ more values 1 per line]
#     END 
# for installing multiple values in array types. Note that the here
# document delimiter (END in the example above) must be the same at the end
# of the list of entries as it is after the << characters.
# Within a here document, the # sign is NOT a comment character.
# A blank line is allowed only as the last line in the here document.
#
# The values can have multiple forms:
#
#	absolute_dir -- A root anchored (i.e begins with a /) directory 
#	absolute_file -- A root anchored (i.e begins with a /) file 
#	bool -- choose from: yes, no, y, n
#	enum -- One of a list of possible values
#	integer -- an integer (string made up of the digits 0-9,
#		   no decimal point)
#	float -- a floating point number with decimal point.
#	regexp -- A perl style regular expression with
# 		  leading and trailing /'s.
#	restrict_post -- a series of space or : separated file names in which
#                        to look up the senders address
#	            (restrict-post should go away to be replaced by an
#		     array of files)
#	string -- any text up until a \\n stripped of
#		  leading and trailing whitespace
#	word -- any text with no embedded whitespace
#
# A blank value is also accepted, and will undefine the corresponding keyword.
# The character Control-A may not be used in the file.
#
# A trailing _array on any of the above types means that that keyword
# will allow more than one value.
#
# Within a here document for a string_array, the '-' sign takes on a special
# significance.
#
#     To embed a blank line in the here document, put a '-' as the first
#       and ONLY character on the line.
#
#     To preserve whitespace at the beginning of a line, put a - on the
#       line before the whitespace to be preserved
#
#     To put a literal '-' at the beginning of a line, double it.
#
#
# The default if the keyword is not supplied is given in ()'s while the 
# type of value is given in [], the subsystem the keyword is used in is
# listed in <>'s. (undef) as default value means that the keyword is not
# defined or used.

);

#^L
### Local Variables: ***
### cperl-indent-level:2 ***
### fill-column:70 ***
### End: ***

1;

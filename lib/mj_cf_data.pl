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
 visible - Level of password validation required to see a variable (0-5).
 mutable - Level of password validation required to change a variable (1-5).

           The password levels are:
           5 - site password
           4 - domain master password (from the master_password setting)
           3 - domain auxiliary password (from the passwords setting)
           2 - list master password
           1 - list auxiliary password
           Each level includes all of the higher levels as well.

=cut
 
package Mj::Config;

%vars =
  (
   'config_access' => 
   {
    'type'   => 'access_array',
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 4,
   },
   'faq_access' => 
   {
    'type'   => 'enum',
    'values' => [qw(open open+password closed list list+password)],
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'get_access' => 
   {
    'type'   => 'enum',
    'values' => [qw(open open+password closed list list+password)],
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'archive_access' => 
   {
    'type'   => 'enum',
    'values' => [qw(open open+password closed list list+password)],
    'groups' => [qw(access archive)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'index_access' =>
   {
    'type'   => 'enum',
    'values' => [qw(open open+password closed list list+password)],
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'who_access' =>
   {
    'type'   => 'enum',
    'values' => [qw(open open+password closed list list+password)],
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'which_access' =>
   {
    'type'   => 'enum',
    'values' => [qw(open open+password closed list list+password)],
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'info_access' =>
   {
    'type'   => 'enum',
    'values' => [qw(open open+password closed list list+password)],
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'intro_access' =>
   {
    'type'   => 'enum',
    'values' => [qw(open open+password closed list list+password)],
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'advertise' =>
   {
    'type'   => 'regexp_array',
    'groups' => [qw(lists)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'noadvertise' =>
   {
    'type'   => 'regexp_array',
    'groups' => [qw(lists)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'advertise_subscribed' =>
   {
    'type'   => 'bool',
    'groups' => [qw(lists)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 3,
   },
   'ack_attach_original' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(fail stall succeed all)],
    'groups' => [qw(reply)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'inform' =>
   {
    'type'   => 'inform',
    'groups' => [qw(reply)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'post_limits' =>
   {
    'type'   => 'limits',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'access_password_override' =>
   {
    'type'   => 'bool',
    'groups' => [qw(password)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'access_rules' =>
   {
    'type'   => 'access_rules',
    'groups' => [qw(access moderate)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'attachment_rules' =>
   {
    'type'   => 'attachment_rules',
    'groups' => [qw(moderate deliver)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'aliases' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(auxiliary moderator owner request 
                    resend subscribe unsubscribe)],
    'groups' => [qw(miscellany)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 3,
   },
   'priority' =>
   {
    'type'   => 'integer',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 3,
    'mutable'=> 5,
   },
   'default_flags' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(ackstall ackdeny ackpost ackreject eliminatecc 
                    hideaddress hideall postblock prefix replyto 
                    rewritefrom selfcopy)],
    'groups' => [qw(reply deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'nonmember_flags' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(ackstall ackdeny ackpost ackreject postblock)],
    'groups' => [qw(reply deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'allowed_flags' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(ackdeny ackpost ackreject ackstall eliminatecc 
                    hideaddress hideall postblock prefix 
                    replyto selfcopy rewritefrom)],
    'groups' => [qw(reply deliver)],
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'default_class' =>
   {
    'type'   => 'string',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'allowed_classes' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(all digest each nomail unique)],
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'delivery_rules' =>
   {
    'type'   => 'delivery_rules',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 3,
   },
   'comments' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(miscellany)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'category' =>
   {
    'type'   => 'string',
    'groups' => [qw(lists)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'description' =>
   {
    'type'   => 'string',
    'groups' => [qw(lists)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'description_long' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(lists)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'set_policy' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed auto open+confirm closed+confirm auto+confirm
                    auto+password open+password)],
    'groups' => [qw(access)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'subscribe_policy' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed auto open+confirm closed+confirm auto+confirm
                    auto+password open+password)],
    'groups' => [qw(access)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'unsubscribe_policy' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed auto open+confirm closed+confirm auto+confirm
                    auto+password open+password)],
    'groups' => [qw(access)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'max_header_line_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'max_mime_header_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'max_total_header_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'maxlength' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'moderate' =>
   {
    'type'   => 'bool',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'moderator' =>
   {
    'type'   => 'address',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'moderators' =>
   {
    'type'   => 'address_array',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'moderator_group' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'sender' =>
   {
    'type'   => 'address',
    'groups' => [qw(deliver)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'precedence' =>
   {
    'type'   => 'word',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'reply_to' =>
   {
    'type'   => 'word',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'override_reply_to' =>
   {
    'type'   => 'bool',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'purge_received' =>
   {
    'type'   => 'bool',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'quote_pattern' =>
   {
    'type'   => 'regexp',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'resend_host' =>
   {
    'type'   => 'word',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'restrict_post' =>
   {
    'type'   => 'restrict_post',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'sequence_number' =>
   {
    'type'   => 'integer',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
    'auto'   => 1,
   },
   'administrivia' =>
   {
    'type'   => 'bool',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'debug' =>
   {
    'type'   => 'integer',
    'groups' => [qw(miscellany)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 3,
   },
   'addr_allow_at_in_phrase' =>
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'addr_allow_bang_paths' =>
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'addr_allow_comments_after_route' =>
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'addr_allow_ending_dot' => 
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'addr_limit_length' =>
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'addr_require_fqdn' =>
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'addr_strict_domain_check' =>
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'archive_date' =>
   {
    'type'   => 'enum',
    'values' => [qw(arrival delivery)],
    'groups' => [qw(archive)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'archive_dir' =>
   {
    'type'   => 'directory',
    'groups' => [qw(archive)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 3,
   },
   'archive_size' =>
   {
    'type'   => 'string',
    'groups' => [qw(archive)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'archive_split' =>
   {
    'type'   => 'enum',
    'values' => [qw(yearly monthly weekly daily)],
    'groups' => [qw(archive)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'message_fronter' =>
   {
    'type'   => 'string_2darray',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'message_fronter_frequency' =>
   {
    'type'   => 'integer',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'message_footer' =>
   {
    'type'   => 'string_2darray',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'message_footer_frequency' =>
   {
    'type'   => 'integer',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'message_headers' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'delete_headers' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'subject_re_pattern' =>
   {
    'type'   => 'regexp',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 10,
   },
   'subject_re_strip' =>
   {
    'type'   => 'bool',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 2,
   },
   'subject_prefix' =>
   {
    'type'   => 'string',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 1,
   },
   'admin_headers' =>
   {
    'type'   => 'taboo_headers',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'admin_body' =>
   {
    'type'   => 'taboo_body',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'taboo_headers' =>
   {
    'type'   => 'taboo_headers',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'taboo_body' =>
   {
    'type'   => 'taboo_body',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'block_headers' =>
   {
    'type'   => 'taboo_headers',
    'groups' => [qw(access)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'triggers' =>
   {
    'type'   => 'triggers',
    'values' => [qw(bounce checksum delay log post session token)],
    'groups' => [qw(miscellany)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 2,
   },
   'digests' =>
   {
    'type'   => 'digests',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'digest_index_format' =>
   {
    'type'   => 'enum',
    'values' => [qw(numbered subject subject_author)],
    'groups' => [qw(deliver)],
    'global' => 0,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'digest_issues' =>
   {
    'type'   => 'digest_issues',
    'groups' => [qw(deliver)],
    'global' => 0,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'auto'   => 1,
   },
   'addr_xforms' =>
   {
    'type'   => 'xform_array',
    'groups' => [qw(address)],
    'global' => 1,
    'local'  => 0,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'master_password' =>
   {
    'type'   => 'pw',
    'groups' => [qw(password)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 2,
    'mutable'=> 2,
   },
   'passwords' =>
   {
    'type'   => 'passwords',
    'groups' => [qw(password)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 2,
    'mutable'=> 2,
   },
   'password_min_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(password)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 3,
   },
   'welcome' =>
   {
    'type'   => 'bool',
    'groups' => [qw(reply)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'welcome_files' =>
   {
    'type'   => 'welcome_files',
    'groups' => [qw(reply)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'file_search' =>
   {
    'type'   => 'list_array',
    'groups' => [qw(reply)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'file_share' =>
   {
    'type'   => 'list_array',
    'groups' => [qw(reply)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
# Purely global configuration variables below
   
   'site_name' =>
   {
    'type'   => 'string',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'whereami' =>
   {
    'type'   => 'word',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'whoami' =>
   {
    'type'   => 'address',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'whoami_owner' =>
   {
    'type'   => 'address',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'bounce_recipients' =>
   {
    'type'   => 'address_array',
    'groups' => [qw(bounce)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'owners' =>
   {
    'type'   => 'address_array',
    'groups' => [qw(moderate)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'tmpdir' =>
   {
    'type'   => 'directory',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'max_in_core' =>
   {
    'type'   => 'integer',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'return_subject' =>
   {
    'type'   => 'bool',
    'groups' => [qw(reply)],
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'chunksize' =>
   {
    'type'   => 'integer',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'default_language' =>
   {
    'type'   => 'string',
    'groups' => [qw(reply)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'default_lists_format' =>
   {
    'type'   => 'enum',
    'values' => [qw(tiny compact short long enhanced)],
    'groups' => [qw(lists)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'description_max_lines' =>
   {
    'type'   => 'integer',
    'groups' => [qw(lists)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'sublists' =>
   {
    'type'   => 'sublist_array',
    'groups' => [qw(lists)],
    'global' => 0,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'archive_url' =>
   {
    'type'   => 'string',
    'groups' => [qw(archive)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'confirm_url' =>
   {
    'type'   => 'string',
    'groups' => [qw(access)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'wwwadm_url' =>
   {
    'type'   => 'string',
    'groups' => [qw(miscellany)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'wwwusr_url' =>
   {
    'type'   => 'string',
    'groups' => [qw(miscellany)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'token_remind' =>
   {
    'type'   => 'integer',
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'dup_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'save_denial_checksums' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'global' => 0,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'latchkey_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(access)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'log_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'session_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
  },
   'token_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'bounce_probe_frequency' =>
   {
    'type'   => 'integer',
    'groups' => [qw(bounce)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'bounce_probe_pattern' =>
   {
    'type'   => 'regexp',
    'groups' => [qw(bounce)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'bounce_max_age' =>
   {
    'type'   => 'integer',
    'groups' => [qw(bounce)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'bounce_max_count' =>
   {
    'type'   => 'integer',
    'groups' => [qw(bounce)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'bounce_rules' =>
   {
    'type'   => 'bounce_rules',
    'groups' => [qw(bounce)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
   },
   'request_answer' =>
   {
    'type'   => 'enum',
    'values' => [qw(majordomo owner response)],
    'groups' => [qw(reply)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   'signature_separator' =>
   {
    'type'   => 'regexp',
    'groups' => [qw(miscellany)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
   },
   );

#^L
### Local Variables: ***
### cperl-indent-level:2 ***
### fill-column:70 ***
### End: ***

1;

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
 wizard  - Importance of and/or level of skill required to understand
           a setting.  Level 1 settings are "essential" and must be
           understood by novice list owners.
 visible - Level of password validation required to see a variable (0-5).
 mutable - Level of password validation required to change a variable (1-5).

           The password levels are:
           5 - site password
           4 - domain master password (from the master_password setting)
           3 - domain auxiliary password (from the passwords setting)
           2 - list master password
           1 - list auxiliary password
           Each level includes all of the lower-numbered levels as well.

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
    'wizard' => 9,
   },
   'config_defaults' => 
   {
    'type'   => 'config_array',
    'groups' => [qw(miscellany)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
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
    'wizard' => 9,
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
    'wizard' => 9,
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
    'wizard' => 1,
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
    'wizard' => 9,
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
    'wizard' => 1,
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
    'wizard' => 1,
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
    'wizard' => 9,
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
    'wizard' => 9,
   },
   'advertise' =>
   {
    'type'   => 'regexp_array',
    'groups' => [qw(lists)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'noadvertise' =>
   {
    'type'   => 'regexp_array',
    'groups' => [qw(lists)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 1,
   },
   'advertise_subscribed' =>
   {
    'type'   => 'bool',
    'groups' => [qw(lists)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 3,
    'wizard' => 9,
   },
   'ack_attach_original' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(fail reject stall succeed all)],
    'groups' => [qw(reply)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'inform' =>
   {
    'type'   => 'inform',
    'groups' => [qw(reply)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'post_limits' =>
   {
    'type'   => 'limits',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'access_password_override' =>
   {
    'type'   => 'bool',
    'groups' => [qw(password)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'access_rules' =>
   {
    'type'   => 'access_rules',
    'groups' => [qw(access moderate)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'active' =>
   {
    'type'   => 'bool',
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 2,
    'wizard' => 1,
   },
   'attachment_rules' =>
   {
    'type'   => 'attachment_rules',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'attachment_filters' =>
   {
    'type'   => 'attachment_filters',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'aliases' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(auxiliary moderator owner request resend subscribe
                    subscribe-digest subscribe-digest-all subscribe-each
                    subscribe-nomail subscribe-unique unsubscribe)],
    'groups' => [qw(miscellany)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 3,
    'wizard' => 9,
   },
   'priority' =>
   {
    'type'   => 'integer',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 3,
    'mutable'=> 5,
    'wizard' => 9,
   },
   'default_flags' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(ackstall ackdeny ackpost ackreject eliminatecc 
                    hideaddress hideall hidepost postblock prefix replyto 
                    rewritefrom selfcopy)],
    'groups' => [qw(reply deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 1,
   },
   'nonmember_flags' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(ackstall ackdeny ackpost ackreject hidepost postblock)],
    'groups' => [qw(reply deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 1,
   },
   'allowed_flags' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(ackdeny ackpost ackreject ackstall eliminatecc 
                    hideaddress hideall hidepost postblock prefix 
                    replyto selfcopy rewritefrom)],
    'groups' => [qw(reply deliver)],
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'default_class' =>
   {
    'type'   => 'string',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'allowed_classes' =>
   {
    'type'   => 'enum_array',
    'values' => [qw(all digest each mail nomail unique)],
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'delivery_rules' =>
   {
    'type'   => 'delivery_rules',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 3,
    'wizard' => 9,
   },
   'comments' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(miscellany)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'category' =>
   {
    'type'   => 'string',
    'groups' => [qw(lists)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 1,
   },
   'description' =>
   {
    'type'   => 'string',
    'groups' => [qw(lists)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 1,
   },
   'description_long' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(lists)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 1,
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
    'wizard' => 9,
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
    'wizard' => 1,
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
    'wizard' => 1,
   },
   'max_header_line_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'max_mime_header_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'max_total_header_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'maxlength' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'moderate' =>
   {
    'type'   => 'bool',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 1,
   },
   'moderators' =>
   {
    'type'   => 'address_array',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 1,
   },
   'moderator_group' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'sender' =>
   {
    'type'   => 'address',
    'groups' => [qw(deliver)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'precedence' =>
   {
    'type'   => 'word',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'reply_to' =>
   {
    'type'   => 'string',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'override_reply_to' =>
   {
    'type'   => 'bool',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'purge_received' =>
   {
    'type'   => 'bool',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'quote_pattern' =>
   {
    'type'   => 'regexp',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'resend_host' =>
   {
    'type'   => 'word',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'restrict_post' =>
   {
    'type'   => 'restrict_post',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'sequence_number' =>
   {
    'type'   => 'integer',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
    'auto'   => 1,
   },
   'administrivia' =>
   {
    'type'   => 'bool',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'debug' =>
   {
    'type'   => 'integer',
    'groups' => [qw(miscellany)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 3,
    'wizard' => 9,
   },
   'addr_allow_at_in_phrase' =>
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'addr_allow_bang_paths' =>
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'addr_allow_comments_after_route' =>
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'addr_allow_ending_dot' => 
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'addr_limit_length' =>
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'addr_require_fqdn' =>
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'addr_strict_domain_check' =>
   {
    'type'   => 'bool',
    'groups' => [qw(address)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'archive_date' =>
   {
    'type'   => 'enum',
    'values' => [qw(arrival delivery)],
    'groups' => [qw(archive)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'archive_dir' =>
   {
    'type'   => 'directory',
    'groups' => [qw(archive)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 3,
    'wizard' => 9,
   },
   'archive_size' =>
   {
    'type'   => 'string',
    'groups' => [qw(archive)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'archive_split' =>
   {
    'type'   => 'enum',
    'values' => [qw(yearly quarterly monthly weekly daily)],
    'groups' => [qw(archive)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'message_fronter' =>
   {
    'type'   => 'string_2darray',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'message_fronter_frequency' =>
   {
    'type'   => 'integer',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'message_footer' =>
   {
    'type'   => 'string_2darray',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 1,
   },
   'message_footer_frequency' =>
   {
    'type'   => 'integer',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'message_headers' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'delete_headers' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'subject_re_pattern' =>
   {
    'type'   => 'regexp',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'subject_re_strip' =>
   {
    'type'   => 'bool',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
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
    'wizard' => 9,
   },
   'admin_body' =>
   {
    'type'   => 'taboo_body',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'taboo_headers' =>
   {
    'type'   => 'taboo_headers',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'taboo_body' =>
   {
    'type'   => 'taboo_body',
    'groups' => [qw(moderate)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'block_headers' =>
   {
    'type'   => 'taboo_headers',
    'groups' => [qw(access)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'noarchive_headers' =>
   {
    'type'   => 'taboo_headers',
    'groups' => [qw(archive moderate)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'noarchive_body' =>
   {
    'type'   => 'taboo_body',
    'groups' => [qw(archive moderate)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'triggers' =>
   {
    'type'   => 'triggers',
    'values' => [qw(bounce checksum delay inactive log post session
                    token vacation)],
    'groups' => [qw(miscellany)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 2,
    'wizard' => 9,
   },
   'digests' =>
   {
    'type'   => 'digests',
    'groups' => [qw(deliver)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 1,
   },
   'digest_index_format' =>
   {
    'type'   => 'enum',
    'values' => [qw(numbered numbered_name subject subject_author subject_name)],
    'groups' => [qw(deliver)],
    'global' => 0,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'digest_issues' =>
   {
    'type'   => 'digest_issues',
    'groups' => [qw(deliver)],
    'global' => 0,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
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
    'wizard' => 9,
   },
   'master_password' =>
   {
    'type'   => 'pw',
    'groups' => [qw(password)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 2,
    'mutable'=> 2,
    'wizard' => 9,
   },
   'passwords' =>
   {
    'type'   => 'passwords',
    'groups' => [qw(password)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 2,
    'mutable'=> 2,
    'wizard' => 9,
   },
   'password_min_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(password)],
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 3,
    'wizard' => 9,
   },
   'farewell' =>
   {
    'type'   => 'bool',
    'groups' => [qw(reply)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'farewell_files' =>
   {
    'type'   => 'welcome_files',
    'groups' => [qw(reply)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'welcome' =>
   {
    'type'   => 'bool',
    'groups' => [qw(reply)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'welcome_files' =>
   {
    'type'   => 'welcome_files',
    'groups' => [qw(reply)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'file_search' =>
   {
    'type'   => 'list_array',
    'groups' => [qw(reply)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'file_share' =>
   {
    'type'   => 'list_array',
    'groups' => [qw(reply)],
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'bounce_recipients' =>
   {
    'type'   => 'address_array',
    'groups' => [qw(bounce)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'owners' =>
   {
    'type'   => 'address_array',
    'groups' => [qw(moderate)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'whoami' =>
   {
    'type'   => 'address',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'whoami_owner' =>
   {
    'type'   => 'address',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'default_language' =>
   {
    'type'   => 'string',
    'groups' => [qw(reply)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'sublists' =>
   {
    'type'   => 'sublist_array',
    'groups' => [qw(lists)],
    'global' => 0,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'archive_url' =>
   {
    'type'   => 'string',
    'groups' => [qw(archive)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
# Purely global configuration variables below
   
   'site_name' =>
   {
    'type'   => 'string',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 1,
   },
   'whereami' =>
   {
    'type'   => 'word',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 1,
   },
   'tmpdir' =>
   {
    'type'   => 'directory',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'max_in_core' =>
   {
    'type'   => 'integer',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'return_subject' =>
   {
    'type'   => 'bool',
    'groups' => [qw(reply)],
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'chunksize' =>
   {
    'type'   => 'integer',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'default_lists_format' =>
   {
    'type'   => 'enum',
    'values' => [qw(tiny compact short long enhanced)],
    'groups' => [qw(lists)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'description_max_lines' =>
   {
    'type'   => 'integer',
    'groups' => [qw(lists)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'confirm_url' =>
   {
    'type'   => 'string',
    'groups' => [qw(access)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'www_help_window' =>
   {
    'type'   => 'bool',
    'groups' => [qw(miscellany)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'wwwadm_url' =>
   {
    'type'   => 'string',
    'groups' => [qw(miscellany)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'wwwusr_url' =>
   {
    'type'   => 'string',
    'groups' => [qw(miscellany)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'token_remind' =>
   {
    'type'   => 'integer',
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'dup_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'post_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'global' => 0,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'inactive_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'save_denial_checksums' =>
   {
    'type'   => 'integer',
    'groups' => [qw(moderate)],
    'global' => 0,
    'local'  => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'latchkey_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(access)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'log_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'session_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(miscellany)],
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
  },
   'token_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(access)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'bounce_probe_frequency' =>
   {
    'type'   => 'integer',
    'groups' => [qw(bounce)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'bounce_probe_pattern' =>
   {
    'type'   => 'regexp',
    'groups' => [qw(bounce)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'bounce_max_age' =>
   {
    'type'   => 'integer',
    'groups' => [qw(bounce)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'bounce_max_count' =>
   {
    'type'   => 'integer',
    'groups' => [qw(bounce)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'bounce_rules' =>
   {
    'type'   => 'bounce_rules',
    'groups' => [qw(bounce)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
   },
   'relocated_lists' =>
   {
    'type'   => 'relocated_lists',
    'groups' => [qw(miscellany)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 1,
    'mutable'=> 1,
    'wizard' => 9,
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
    'wizard' => 9,
   },
   'signature_separator' =>
   {
    'type'   => 'regexp',
    'groups' => [qw(miscellany)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'wizard' => 9,
   },
   );

#^L
### Local Variables: ***
### cperl-indent-level:2 ***
### fill-column:70 ***
### End: ***

1;

=head1 NAME

mj_cf_defs.pl - default values for config variables

=head1 DESCRIPTION

This file holds the configuration defaults that are supplied to new lists.
It is require''d into the config package when the defaults need to be
written.  This means that you can put real code to be evaluated here in
place of the clunky #! mechanism that was there before.  You must use 0 or
1 for bool values, not "no" and "yes".  Use undef if the keyword has no
default.  This is executed in the Mj::Config package, so be sure to qualify
variables and functions from other packages.

=cut

$Mj::Config::default_string = q(
{
 'access_password_override' => 1,
 'access_rules'         => [],
 'ack_attach_original'  => [qw(fail stall)],
 'addr_allow_at_in_phrase' => 0,
 'addr_allow_bang_paths'=> 0,
 'addr_allow_comments_after_route' => 0,
 'addr_allow_ending_dot'=> 0,
 'addr_limit_length'    => 1,
 'addr_require_fqdn'    => 1,
 'addr_strict_domain_check' => 1,
 'addr_xforms'          => [$subs->{'addr_xforms'}],
 'admin_body'           => (($list eq 'GLOBAL') ?
			    [
                             '/^accept$/i',
                             '/^reject$/i',
			     '/\bcancel\b/i',
			     '/\badd me\b/i',
			     '/\bdelete me\b/i',
			     '/\bremove\s+me\b/i',
			     '/\bchange\b.*\baddress\b/',
			     '/\bsubscribe\b/i',
			     '/^sub\b/i',
			     '/\bunsubscribe\b/i',
			     '/^unsub\b/i',
			     '/\buns\w*b/i',
			     '/^\s*help\s*$/i',
			     '/^\s*info\s*$/i',
			     '/^\s*info\s+\S+\s*$/i',
			     '/^\s*lists\s*$/i',
			     '/^\s*which\s*$/i',
			     '/^\s*which\s+\S+\s*$/i',
			     '/^\s*index\s*$/i',
			     '/^\s*index\s+\S+\s*$/i',
			     '/^\s*who\s*$/i',
			     '/^\s*who\s+\S+\s*$/i',
			     '/^\s*get\s+\S+\s*$/i',
			     '/^\s*get\s+\S+\s+\S+\s*$/i',
			     '/^\s*approve\b/i',
			     '/^\s*passwd\b/i',
			     '/^\s*newinfo\b/i',
			     '/^\s*config\b/i',
			     '/^\s*newconfig\b/i',
			     '/^\s*writeconfig\b/i',
			     '/^\s*mkdigest\b/i',
			    ] : []),
 'admin_headers'        => (#'
			    ($list eq 'GLOBAL') ? 
			    ['/^subject:\s*subscribe\b/i',
			     '/^subject:\s*unsubscribe\b/i',
			     '/^subject:\s*uns\w*b/i',
			     '/^subject:\s*.*un-sub/i',
			     '/^subject:\s*help\b/i',
			     '/^subject:\s.*\bchange\b.*\baddress\b/i',
			     '/^subject:\s*request\b(.*\b)?addition\b/i',
			     '/^subject:\s*cancel\b/i',
                             '/MSGRCPT/',
			    ] : []),
 'administrivia'        => 1,
 'advertise'            => [],
 'advertise_subscribed' => 1,
 'aliases'              => [qw(owner request resend)],
 'allowed_classes'      => [qw(each digest nomail unique)],
 'allowed_flags'        => [qw(ackdeny ackpost ackreject ackstall eliminatecc 
                               hideaddress hideall prefix replyto 
                               rewritefrom selfcopy)],
 'archive_access'       => "list+password",
 'archive_dir'          => '',
 'archive_size'         => 'unlimited',
 'archive_split'        => 'monthly',
 'archive_url'          => '',
 'attachment_rules'     => [],
 'block_headers'        => ['/X-Loop:.*majordomo/i'],
 'bounce_max_age'       => 31,
 'bounce_max_count'     => 100,
 'bounce_probe_frequency' => 0,
 'bounce_probe_pattern' => '',
 'bounce_recipients'    => [],
 'bounce_rules'         => [],
 'category'             => '',
 'chunksize'            => 1000,
 'comments'             => [],
 'confirm_url'          => $subs->{'confirm_url'},
 'debug'                => 0,
 'default_class'        => 'each',
 'default_flags'        => [qw(selfcopy)],
 'default_language'     => 'en',
 'default_lists_format' => 'short',
 'delete_headers'       => [qw(X-Confirm-Reading-To
			       X-Ack
			       Sender
			       Return-Receipt-To
			       Flags
			       Priority
			       X-Pmrqc
			       Return-Path
			       Delivered-To
			      )],
 'delivery_rules'       => [],
 'description'          => '',
 'description_long'     => [],
 'description_max_lines'=> 0,
 'digest_index_format'  => 'subject',
 'digest_issues'        => [],
 'digests'              => [],
 'dup_lifetime'         => 28,
 'faq_access'           => "open",
 'file_search'          => [':$LANG', ':'],
 'file_share'           => [],
 'get_access'           => "list",
 'index_access'         => "open",
 'info_access'          => "open",
 'inform'               => [],
 'intro_access'         => "open",
 'latchkey_lifetime'    => 60,
 'log_lifetime'         => 31,
 'master_password'      => ($list eq 'GLOBAL') ? 
                             $subs->{'master_password'} : 
                             '$LIST.pass',
 'max_header_line_length'=> 448,
 'max_in_core'          => '20000',
 'max_mime_header_length'=> 128,
 'max_total_header_length'=> 2048,
 'maxlength'            => 40000,
 'message_footer'       => [],
 'message_footer_frequency' => 100,
 'message_fronter'      => [],
 'message_fronter_frequency' => 100,
 'message_headers'      => ($list eq 'GLOBAL') ?
                           [
                            'Reply-To: $MJ',
                            'X-Loop: majordomo',
                           ] : [],
 'moderate'             => 0,
 'moderator'            => '',
 'moderator_group'      => 0,
 'moderators'           => [],
 'noadvertise'          => [],
 'nonmember_flags'      => [qw(ackdeny ackreject ackstall)],
 'override_reply_to'    => 0,
 'owners'               => ($list eq 'GLOBAL') ? [$subs->{'owners'}] : [],
 'password_min_length'  => 4,
 'passwords'            => [],
 'post_limits'          => [],
 'precedence'           => "bulk",
 'purge_received'       => 0,
 'quote_pattern'        => '/^( - | : | > | [a-z]+> )/xi',
 'reply_to'             => '$LIST@$HOST',
 'request_answer'       => 'majordomo',
 'resend_host'          => ($list eq 'GLOBAL') ? '' : $subs->{'resend_host'},
 'restrict_post'        => [],
 'return_subject'       => 1,
 'save_denial_checksums'=> 0,
 'sender'               => ($list eq 'GLOBAL') ? $subs->{'sender'} : '$LIST-owner',
 'sequence_number'      => 1,
 'session_lifetime'     => 14,
 'set_policy'           => "open+confirm",
 'signature_separator'  => '/^[-_]/',
 'site_name'            => $subs->{'site_name'},
 'subject_prefix'       => '[$LIST]',
 'sublists'             => [],
 'subscribe_policy'     => "open+confirm",
 'taboo_body'           => ($list eq 'GLOBAL') ? [] : [],
 'taboo_headers'        => ($list eq 'GLOBAL') ? [] : [],
 'tmpdir'               => $subs->{'tmpdir'},
 'token_lifetime'       => 7,
 'token_remind'         => 4,
 'triggers'             => ($list eq 'GLOBAL') ? 
                           [ 
                             'checksum | daily', 
                             'delay    | hourly', 
                             'log      | daily',
                             'session  | daily', 
                             'token    | daily' 
                           ] : 
                           [ 
                             'bounce   | daily',
                             'checksum | daily',
                             'delay    | hourly',
                             'post     | daily',
                           ],
 'unsubscribe_policy'   => "open",
 'welcome'              => 1,
 'welcome_files'        => (($list eq 'GLOBAL') ?
			    [
			     'You have been registered at $SITE.',
			     'registered | NS',
			    ]
			    :
			    [
			     'Welcome to the $LIST mailing list!',
			     'welcome | NS',
			     'List introductory information',
			     'info | PS',
			    ]),
 'whereami'             => $subs->{'whereami'},
 'which_access'         => "open",
 'who_access'           => ($list eq 'GLOBAL') ? "closed" : "open",
 'whoami'               => ($list eq 'GLOBAL') ? $subs->{'whoami'} : '$LIST',
 'whoami_owner'         => ($list eq 'GLOBAL') ? $subs->{'whoami_owner'} : '$LIST-owner',
 'wwwadm_url'           => $subs->{'wwwadm_url'},
 'wwwusr_url'           => $subs->{'wwwusr_url'},
};
);

# List of default reply files and subjects to be installed in the GLOBAL
# filespace
%files =
  (
   # English
   'en/ack_denial'              => ['Denial',                                          'us-ascii', '7bit'],
   'en/ack_rejection'           => ['Rejection',                                       'us-ascii', '7bit'],
   'en/ack_stall'               => ['Stall',                                           'us-ascii', '7bit'],
   'en/ack_success'             => ['Success',                                         'us-ascii', '7bit'],
   'en/ack_timeout'             => ['Timeout',                                         'us-ascii', '7bit'],
   'en/faq'                     => ['Default faq reply',                               'us-ascii', '7bit'],
   'en/file_sent'               => ['File has been sent',                              'us-ascii', '7bit'],
   'en/info'                    => ['Info',                                            'us-ascii', '7bit'],
   'en/intro'                   => ['Intro',                                           'us-ascii', '7bit'],
   'en/welcome'                 => ['Welcome',                                         'us-ascii', '7bit'],
   'en/registered'              => ['Welcome to $SITE',                                'us-ascii', '7bit'],
   'en/new_password'            => ['New password at $SITE',                           'us-ascii', '7bit'],
   'en/inform'                  => ['$UREQUEST $LIST',                                 'us-ascii', '7bit'],
   'en/repl_consult'            => ['Default consult mailreply file',                  'us-ascii', '7bit'],
   'en/repl_confirm'            => ['Default confirm mailreply file',                  'us-ascii', '7bit'],
   'en/repl_confcons'           => ['Default confirm+consult mailreply file',          'us-ascii', '7bit'],
   'en/repl_chain'              => ['Default chained mailreply file',                  'us-ascii', '7bit'],
   'en/repl_deny'               => ['Default denial replyfile',                        'us-ascii', '7bit'],
   'en/repl_forward'            => ['Default forward replyfile',                       'us-ascii', '7bit'],
   'en/request_response'        => ['Automated response from $REQUEST',                'us-ascii', '7bit'],
   'en/subscribe_to_self'       => ['Attempt to subscribe $LIST to itself',            'us-ascii', '7bit'],
   'en/token_reject'            => ['Rejected token $TOKEN',                           'us-ascii', '7bit'],
   'en/token_reject_owner'      => ['Token rejected by $REJECTER',                     'us-ascii', '7bit'],
   'en/token_remind'            => ['REMINDER from $LIST',                             'us-ascii', '7bit'],
   'en/help/default'            => ['Default help file',                               'us-ascii', '7bit'],
   'en/help/commands'           => ['Overview of available commands',                  'us-ascii', '7bit'],
   'en/help/parser'             => ['Information about the text parser',               'us-ascii', '7bit'],
   'en/help/subscribe'          => ['Help on subscribing',                             'us-ascii', '7bit'],
   'en/help/topics'             => ['Available help topics',                           'us-ascii', '7bit'],
   'en/help/admin_commands'     => ['Overview of available administrative commands',   'us-ascii', '7bit'],
   'en/help/admin_configuration'=> ['Overview of configuration variables and methods', 'us-ascii', '7bit'],
   'en/help/admin_passwords'    => ['Information on Majordomo security and passwords', 'us-ascii', '7bit'],

   # German
   'de/ack_denial'              => 'Denial',
   'de/ack_rejection'           => 'Rejection',
   'de/ack_stall'               => 'Stall',
   'de/ack_success'             => 'Success',
   'de/ack_timeout'             => 'Timeout',
   'de/faq'                     => 'Default faq reply',
   'de/file_sent'               => 'File has been sent',
   'de/info'                    => 'Info',
   'de/intro'                   => 'Intro',
   'de/welcome'                 => 'Welcome',
#   'de/registered'              => 'Welcome to $SITE',
   'de/inform'                  => '$UREQUEST $LIST',
   'de/repl_consult'            => 'Default consult mailreply file',
   'de/repl_confirm'            => 'Default confirm mailreply file',
   'de/repl_confcons'           => 'Default confirm+consult mailreply file',
   'de/repl_chain'              => 'Default chained mailreply file',
   'de/repl_deny'               => 'Default denial replyfile',
   'de/repl_forward'            => 'Default forward replyfile',
#   'de/request_response'        => 'Automated response from $REQUEST',
   'de/subscribe_to_self'       => 'Attempt to subscribe $LIST to itself',
   'de/token_reject'            => 'Rejected token $TOKEN',
   'de/token_reject_owner'      => 'Token rejected by $REJECTER',
   'de/token_remind'            => 'REMINDER from $LIST',
#    'de/help/default'            => 'Default help file',
#    'de/help/commands'           => 'Overview of available commands',
#    'de/help/parser'             => 'Information about the text parser',
#    'de/help/subscribe'          => 'Help on subscribing',
#    'de/help/topics'             => 'Available help topics',
#    'de/help/admin_commands'     => 'Overview of available administrative commands',
#    'de/help/admin_configuration'=> 'Overview of configuration variables and methods',
#    'de/help/admin_passwords'    => 'Information on Majordomo security and passwords',

   # Informal German
   'de/informal/ack_denial'              => 'Denial',
   'de/informal/ack_rejection'           => 'Rejection',
   'de/informal/ack_stall'               => 'Stall',
   'de/informal/ack_success'             => 'Success',
   'de/informal/ack_timeout'             => 'Timeout',
   'de/informal/faq'                     => 'Default faq reply',
   'de/informal/file_sent'               => 'File has been sent',
   'de/informal/info'                    => 'Info',
   'de/informal/intro'                   => 'Intro',
   'de/informal/welcome'                 => 'Welcome',
#   'de/informal/registered'              => 'Welcome to $SITE',
   'de/informal/inform'                  => '$UREQUEST $LIST',
   'de/informal/repl_consult'            => 'Default consult mailreply file',
   'de/informal/repl_confirm'            => 'Default confirm mailreply file',
   'de/informal/repl_confcons'           => 'Default confirm+consult mailreply file',
   'de/informal/repl_chain'              => 'Default chained mailreply file',
   'de/informal/repl_deny'               => 'Default denial replyfile',
   'de/informal/repl_forward'            => 'Default forward replyfile',
#   'de/informal/request_response'        => 'Automated response from $REQUEST',
   'de/informal/subscribe_to_self'       => 'Attempt to subscribe $LIST to itself',
   'de/informal/token_reject'            => 'Rejected token $TOKEN',
   'de/informal/token_reject_owner'      => 'Token rejected by $REJECTER',
   'de/informal/token_remind'            => 'REMINDER from $LIST',
#    'de/informal/help/default'            => 'Default help file',
#    'de/informal/help/commands'           => 'Overview of available commands',
#    'de/informal/help/parser'             => 'Information about the text parser',
#    'de/informal/help/subscribe'          => 'Help on subscribing',
#    'de/informal/help/topics'             => 'Available help topics',
#    'de/informal/help/admin_commands'     => 'Overview of available administrative commands',
#    'de/informal/help/admin_configuration'=> 'Overview of configuration variables and methods',
#    'de/informal/help/admin_passwords'    => 'Information on Majordomo security and passwords',

  );

if ($config->{cgi_bin}) {
  $files{'en/confirm'} = ['CONFIRM from $LIST', 'us-ascii', '7bit'];
  $files{'en/consult'} = ['CONSULT from $LIST', 'us-ascii', '7bit'];

  $files{'de/confirm'} = 'CONFIRM from $LIST';
  $files{'de/consult'} = 'CONSULT from $LIST';

  $files{'de/informal/confirm'} = 'CONFIRM from $LIST';
  $files{'de/informal/consult'} = 'CONSULT from $LIST';
}
else {
  $files{'en/confirm'} = ['CONFIRM from $LIST', 'us-ascii', '7bit', 'en/confirm_noweb'];
  $files{'en/consult'} = ['CONSULT from $LIST', 'us-ascii', '7bit', 'en/consult_noweb'];

  $files{'de/confirm'} = ['CONFIRM from $LIST', 'ISO-8859-1', '8bit', 'de/confirm_noweb'];
  $files{'de/consult'} = ['CONSULT from $LIST', 'ISO-8859-1', '8bit', 'de/consult_noweb'];

  $files{'de/informal/confirm'} = ['CONFIRM from $LIST', 'ISO-8859-1', '8bit', 'de/informal/confirm_noweb'];
  $files{'de/informal/consult'} = ['CONSULT from $LIST', 'ISO-8859-1', '8bit', 'de/informal/consult_noweb'];
}

# These have to be ordered...
@dirs =
  ('stock'                  => 'Majordomo-supplied files',
   'stock/en'               => 'English',
   'stock/en/help'          => 'English Help files',
   'stock/de'               => 'German',
   'stock/de/help'          => 'German Help Files',
   'stock/de/informal'      => 'Informal German',
   'stock/de/informal/help' => 'Informal German Help Files',
   'spool'                  => 'Spooled files',
   'public'                 => 'Public files',
  );

1;

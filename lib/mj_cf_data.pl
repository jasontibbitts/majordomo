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
 comment - an instructional comment
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
    'comment'=> $std_access_desc,
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
    'comment'=> $std_access_desc,
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
    'comment'=> $std_access_desc,
   },
   'who_access' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed list)],
    'groups' => [qw(access majordomo)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> $std_access_desc,
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
    'comment'=> $std_access_desc,
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
    'comment'=> $std_access_desc,
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
    'comment'=> $std_access_desc,
   },
   'advertise' =>
   {
    'type'   => 'regexp_array',
    'groups' => [qw(majordomo access advertise lists)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If the requestor name matches one of these regexps, then the list will
not be listed in the output of a lists command.  Noadvertise overrides
advertise.
EOC
   },
   'noadvertise' =>
   {
    'type'   => 'regexp_array',
    'groups' => [qw(majordomo access advertise lists)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If the requestor name matches one of these regexps, then the list will
not be listed in the output of a lists command.  Noadvertise overrides
advertise.
EOC
   },
   'inform' =>
   {
    'type'   => 'inform',
    'groups' => [qw(inform)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,

This controls just what actions the list owner will be informed of and
what will be logged.  The format of each line is:

request | status | actions

where request is subscribe, lists, post, etc., status is a comma
separated list of:

  succeed: perform the actions if the request succees.
  fail:    perform the actions if the request fails.
  stall:   perform the actions if the request is stalled.
  any:     always perform the actions

and actions is a comma separated list of:

  ignore: completelu ignore the request
  report: log the request for later reposting
  inform: inform the owner immediately

ignore overrides the others.

If a request is not specified, the default behavior for subscribe and
unsubscribe is to inform on success, report otherwise.  The default
behavior for all other requests is to report always.  This
approximates the 1.9x behavior.

Note that all actions are logged; this only affects which actions are
deemed important enough to send mail about and which will be reported.
EOC
   },
   'access_password_override' =>
   {
    'type'   => 'bool',
    'groups' => [qw(access)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
This controls whether or not the restrictions given in access_rules
can always be overridden with a password.  If this is set to no, then
a supplied password is just another variable that can be used in the
access table.

WARNING: use this variable with care.  It is possible to lock yourself
out of your lists if you do not grant some password access.
EOC
   },
   'access_rules' =>
   {
    'type'   => 'access_rules',
    'groups' => [qw(access)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,

A table containing access rules.  This is a very powerful and
unfortunately somewhat complicated mechanism for precisely restricting
access to Majordomo functions which I will document later.

EOC
   },
   'attachment_rules' =>
   {
    'type'   => 'attachment_rules',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 0,
    'mutable'=> 1,
    'comment'=> <<EOC,

A table containing attachment rules, which describe how various MIME
types are to be treated when they appear in messages sent to the list.

A rule consists of a MIME type (or regular expression matching a MIME
type) and a list of actions to perform when a message with this type
or containing a part of this type passes through the list.  It looks
something like this:

mime/type | action=argument

Some MIME types are:

text/plain, text/html, image/jpeg, video/mpeg

Possible actions are:

  allow     - let the part pass
  deny      - reject the entire message
  discard   - remove the part from the message and pass the rest
  consult   - send the entire message to the list owner for approval
  (more are planned)

allow and consult take an argument; if present, it should be a
content-transfer-encoding.  Majordomo will change the encoding of the
part to match before it is sent.  Some valid encodings are "8bit",
"base64", "quoted-printable", "x-uuencode" and "x-gzip64".  If an
argument is not provided, the encoding will be left as is.  Due to the
nature of MIME, be aware that the encoding can be changed at any
machine that the message passes through, so the encoding you choose
will not necessarily be the encoding that list members will see (and
some may see different encodings than the others).

Note that the first matching rule is the one that is used and types
are by default allowed if no rule matches.  Deny and consult rules are
applied first, and discard rules always apply, even for approved
messages.

Note also that deny and consult just set variables that can be checked
in access_rules.  The default rule for posting normally takes care of
these, but if you add any additional rules is is possible to override
the checks made here.

EOC
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
    'comment'=> <<EOC,
This controls the database format used to store various sets of data
like subscriber lists.  Currently only a flat text database is supported.
EOC
   },
   'default_flags' =>
   {
    'type'   => 'string',
    'groups' => [qw(general)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
A string containing the flags to be given to new subscribers unless they
choose otherwise.  Possible flags are:

  A - ackall
  a - ackimportant
  S - selfcopy
  H - hideall
  h - hideaddress
  C - elimatecc
EOC
   },
   'delivery_rules' =>
   {
    'type'   => 'delivery_rules',
    'groups' => [qw(delivery)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 0,
    'comment'=> <<EOC,

A table containing delivery rules, which describe how Majordomo will
deliver mail.  In the simplest form, you can specify a host to use for
delivery and a batch size.  (This duplicates much of the functionality
of bulk_mailer, for those familiar with it.)

More complicated forms allow you specify a list of hosts to be used
for parallel delivery, and to specify more powerful batching
parameters.

The most general form allows various addresses to be directed to
different sets of hosts for delivery.

Each delivery destination should begin with a line containing either a
regular expression, or the word ALL.  Addreses are compared against
these in order; the first matching destination is chosen.  This
enables you to choose which addresses go to which sets of hosts.

The remaining lines (up until the next blank) should consist of
various parameters which affect delivery.  The possible parameters
are:

numbatches=N
  Split the address list up into exactly N batches.

maxaddrs=N
  Split the list into batches of N addresses apiece.

maxdomains=N
  Split the address list into batches of N domains apiece.  This
  differs from maxaddrs in that a batch can contain more than N
  addresses if several of them are in the same domain.  This requires
  a sorted address list to function completely.

minseparate=N
  If a domain appears more than N times in various addresses, they
  will all be given a separate batch.  This can improve the average
  delivery time quite a bit if you have many addresses at large
  providers, since they will be delivered immediately without waiting
  for other addresses.

  Domains that do not appear more than N times are batched according
  to maxdomains, which should also be specified in order to set the
  batch size for the infrequently occurring hosts.  If maxdomains is
  not also specified, maxdomains=20 is used.

If neither of the above are specified, the default is numbatches=1,
which duplicates the Majordomo 1.x behavior.

hosts=(hosta, hostb, hostc)
  A list of hostnames that Majordomo will connect to to deliver
  batches.  If no hosts are given, Majordomo connects to localhost.

  Batches are delivered to each host in turn in a round-robin fashion.
  (Future enhancements will deliver batches to each host
  simulataneously to compensate for possible delays from individual
  hosts due to load or network traffic.)

  The hosts in this list are randomly reordered, so even if you use a
  single batch the load will be spread out over several messages.

backup=(hostd, hoste, hostf)
  A list of backup hosts to use in case one or more of the regular
  delivery hosts are down.  These will normally be ignored, but if
  there is a problem contacting one of the normal delivery hosts,
  these hosts will be used in addition to the other working hosts.  In
  the event that no host is contactable, Majordomo will attempt to
  contact localhost.  If that fails, Majorodmo will sleep for ten
  minutes and try the whole process again.

sort
  Sort the address list.  Many of the batching options depend on
  getting the addresses in sorted order and will not work as expected
  if the address are unsorted.  Including the sort option causes the
  list to be sorted, but beware that this takes time and memory.  This
  is not necessary (and will have no effect) when using a sorted
  database backend.  A reasonable balance can be struck by sorting the
  list periodically (using the sortlist command) and not sorting here.

Hosts in either the hosts or backup lists can also be specified with
additional information, as follows:

hosts=(hosta=(parameter1, param2=5), hostb=(param3), hostc)

The host parameters are as follows:

esmtp      - speak ESMTP with the hosts if it is able.
onex       - send ESMTP ONEX to the host if it supports it.
pipelining - send the ESMTP PIPELINING command to the host.
timeout    - the number of seconds to wait when opening a connection
             to the host
port       - the port number to connect to, if different from the
             usual SMTP port.

If, instead of a host name, the string "\@qmail" is used, Majordomo
will open a direct connection to the qmail-queue program and directly
inject the message into the qmail delivery system.  This assumes, of
course, that you are running qmail.

Examples (these are all separate):

Duplicate bulk_mailer:
ALL
sort, maxdomains=20

Use a remote exploder for Scandinavia:
/(\.fi|\.no|\.se)$/
hosts=(nordland.no=(esmtp, onex), reallycold.se)
backup=(my.host.com)
numbatches=2

ALL
numbatches=1
hosts=(my.host.com)

EOC
   },
   'comments' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(comments)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Comment string that will be retained across config file rewrites.
EOC
   },
   'description' =>
   {
    'type'   => 'string',
    'groups' => [qw(majordomo lists)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
This is a short description of the list, used in the short listing.
It should be no more than 50 characters in order to fit on the average
terminal.  If this is empty, the first line of 'description_long' is
used.  If both are empty, the string "(no description)" is used.
EOC
   },
   'description_long' =>
   {
    'type'   => 'string_array',
    'groups' => ['lists'],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 0,
    'comment'=> <<EOC,
This is the list description that appears in the long listing.  Each line
should be no longer than 50 characters in order to fit on the average
terminal.  If this variable is empty, the value of 'description' is used.
If both are empty, the string "(no description)" is used.
EOC
   },
   'subscribe_policy' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed auto open+confirm closed+confirm auto+confirm)],
    'groups' => [qw(majordomo access subscribe)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
One of three values: open, closed, auto; plus an optional modifier:
'+confirm'.  Open allows people to subscribe themselves to the list,
but attempts to subscribe addresses diferent than where the request is
coming from will require approval.  Auto allows anybody to subscribe
anybody to the list without maintainer approval.  Closed requires
maintainer approval for all subscribe requests to the list.  Adding
'+confirm', (i.e. 'open+confirm') will cause majordomo to send a reply
back to the subscriber which includes a authentication number which
must be sent back in with another subscribe command.
EOC
   },
   'unsubscribe_policy' =>
   {
    'type'   => 'enum',
    'values' => [qw(open closed auto)],
    'groups' => [qw(majordomo access subscribe)],
    'local'  => 1,
    'visible'=> 0,
    'mutable'=> 1,
    'comment'=> <<EOC,
One of three values: open, closed, auto.  Open allows people to
unsubscribe themselves from the list.  Auto allows anybody to
unsubscribe anybody to the list without maintainer approval.  Closed
requires maintainer approval for all unsubscribe requests to the list.
EOC
   },
   'date_info' =>
   {
    'type'   => 'bool',
    'groups' => [qw(majordomo messages)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Put the last updated date for the info file at the top of the info
file rather than having it appended with an info command.  This is
useful if the file is being looked at by some means other than
majordomo (e.g. finger).
EOC
   },
   'date_intro' =>
   {
    'type'   => 'bool',
    'groups' => [qw(majordomo messages)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Put the last updated date for the intro file at the top of the intro
file rather than having it appended with an intro command.  This is
useful if the file is being looked at by some means other than
majordomo (e.g. finger).
EOC
   },
   'max_header_line_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Sets the maximum length of a single header in an unapproved message.
This can be used to prevent excessive CC\'ing or to cur down on some
types of spam.  Set to zero to disable length checks on single
headers.
EOC
   },
   'max_total_header_length' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Sets the maximum length of the headers in an unapproved message.  Set to
zero to disable the total length check.
EOC
   },
   'maxlength' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
The maximum size of an unapproved message in characters.  Set to zero to
disable the message length check.
EOC
   },
   'moderate' =>
   {
    'type'   => 'bool',
    'groups' => [qw(resend access)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If yes, all postings to the list must be approved by the moderator.
EOC
   },
   'moderator' =>
   {
    'type'   => 'word',
    'groups' => [qw(resend access)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
List messages requiring consultation will be sent to this address.
This is overridden by the addresses in \'moderators\'.
EOC
   },
   'moderators' =>
   {
    'type'   => 'address_array',
    'groups' => [qw(resend access)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
List messages requiring consultation will be sent to
\'moderator_group\' (or all) of these addresses.  Any of them may
approve or reject the message.
EOC
   },
   'moderator_group' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend access)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
List messages requiring consulataion will be sent to this many of the
addresses in \'moderators\', chosen at random.  If this is zero, the
message will be sent to all of the addresses in \'moderators\'.
EOC
   },
   'nonmember_flags' =>
   {
    'type'   => 'string',
    'groups' => [qw(general)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
A string containing the flags which apply to users who are not list members
when they send messages to the list.  Only a very few flags make sense in
this case.  They are:

  A - ackall
  a - ackimportant
EOC
   },
   'sender' =>
   {
    'type'   => 'address',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'global' => 1,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
The envelope and sender address for the resent mail.  This string has
"@" and the value of resend_host appended to it to make a complete
address.  For majordomo, it provides the sender address for the
welcome mail message generated as part of the subscribe command.
EOC
   },
   'precedence' =>
   {
    'type'   => 'word',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Put a precedence header with value <value> into the outgoing message.
EOC
   },
   'reply_to' =>
   {
    'type'   => 'word',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Put a reply-to header with value <value> into the outgoing message.  If the
following strings appear here, they will be converted to the appropriate
text when the header is inserted into the message:

  \$HOST   - the hostname of the server (from the resend_host variable)
  \$LIST   - the name of the list
  \$SENDER - the address of person who sent the message
  \$SEQNO  - the message sequence number

Note that a preexisting Reply-To: header will not be replaced unless
override_reply_to is true.
EOC
   },
   'override_reply_to' =>
   {
    'type'   => 'bool',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If a reply-to header exists in the message and the list is configured
to add one of its own, should the existing one be deleted and replaced
with the list\'s?  If set to no, the list will not add its reply-to
header if one is already present.
EOC
   },
   'purge_received' =>
   {
    'type'   => 'bool',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Remove all received lines before resending the message.
EOC
   },
   'quote_regexp' =>
   {
    'type'   => 'regexp',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
A regular expression used to match quoted text in message bodies.
This is used to generate the counts and percentages of quoted text.
EOC
   },
   'resend_host' =>
   {
    'type'   => 'word',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
The host name that is appended to all address strings specified for
resend.
EOC
   },
   'restrict_post' =>
   {
    'type'   => 'restrict_post',
    'groups' => [qw(resend access)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,

If defined only addresses belonging to one of the listed sublists will
be allowed to post to the list.  This variable's function is
completely encapsulated within the access_rules mechanism, but it
remains for backwards compatibility and because it's simpler to use.

This is an array variable, but for backwards compatibility the first
item is split on spaces, tabs, and colons.
EOC
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
    'comment'=> <<EOC,
This is the sequence number used to number messages which pass through the
list.  It is automatically incremented by one for each message.  It may be
manually set here.
EOC
   },
   'administrivia' =>
   {
    'type'   => 'bool',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Look for administrative requests (e.g. subscribe/unsubscribe) and
forward them to the list maintainer instead of the list.
EOC
   },
   'debug' =>
   {
    'type'   => 'bool',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 0,
    'global' => 1,
    'comment'=> <<EOC,
Don\'t actually forward message, just go though the motions.
EOC
   },
   'addr_allow_at_in_phrase' =>
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If this is true, Majordomo will allow an \@ symbol in the phrase, or
unbracketed portion of an address.
EOC
   },
   'addr_allow_bang_paths' =>
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If this is true, Majordomo will allow old-style UUCP or "bang" addresses.
EOC
   },
   'addr_allow_comments_after_route' =>
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If this is true, Majordomo will allow addresses with comments after the <>
bracked route portion of an address.
EOC
   },
   'addr_allow_ending_dot' => 
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If this is true, Majordomo will allow trailing dots on hostnames.  This is
legal syntax for a hostname, but not within an email address.
Unfortunately some sites addd them spuriously.
EOC
   },
   'addr_limit_length' =>
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If this is true, Majordomo will verify that all address contain a user name
no longer than 64 characters and a host name no longer than 64 characters.
To enable the use of extremely long user or host names, set this to false.
EOC
   },
   'addr_require_fqdn' =>
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If this is true, addresses are required to have fully qualified domain
names.  Since Majordomo does not verify this using name service lookups,
this essentially means that the right hand side of an address must contain
at least one period.

To enable Majordomo to run at a site where the mail transfer agents do not
fully qualify the domain names, set this to false.
EOC
   },
   'addr_strict_domain_check' =>
   {
    'type'   => 'bool',
    'groups' => [qw(addr)],
    'visible'=> 0,
    'local'  => 0,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If this is true, addresses are verified to be in one of the legal top-level
domains.  New domains are occasionally added; if Majordomo\'s internal list
becomes outdated, set this to false to turn off strict domain checking.
EOC
   },
   'archive_dir' =>
   {
    'type'   => 'directory',
    'groups' => [qw(archive)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 0,
    'comment'=> <<EOC,
The directory where the mailing list archive is kept.

If this is not set, Majordomo will look for a directory named "archive" in
the public directory of the filespace.  If it exists, archives will be
placed there.  If not, archives will not be generated and digests will not
function.
EOC
   },
   'archive_size' =>
   {
    'type'   => 'string',
    'groups' => [qw(archive)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
A string decribing the maximum size of a single archive file.  When a
message arrives that would cause an archive file to exceed the size set
here, a new archive file is created with the final number incremented by
one.

Possible values are an integer followed by one of k, or m for
kilobytes or messages.  The value 'unlimited' is also permitted, in
which case the archives will not have the following period and two
digits appended.

Note that changing this variable will only change the settings for new
messages; old archives will not be renamed or altered in any way.
EOC
   },
   'archive_split' =>
   {
    'type'   => 'enum',
    'values' => [qw(yearly monthly weekly daily)],
    'groups' => [qw(archive)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
A word describing how the archive files should be split.  Here are the
possibilities, along with sample names of the archive files:

  yearly  - 1999.00
  monthly - 199903.00
  weekly  - 20021031.00
  daily   - 21121002.00

Note that archives will be further split by size; see the archive_size
variable.  This gives rise to the two trailing digits, which may not be
present depending on the archive_size setting.

Also note that changing this variable will only change the settings for new
messages; old archives will not be renamed or altered in any way.
EOC
   },
   'install_dir' =>
   {
    'type'   => 'directory',
    'groups' => [qw(install)],
    'visible'=> 0,
    'global' => 1,
    'comment'=> <<EOC,
The directory holding the Majordomo binaries and libraries.  This is
normally set automatically during installation, and is used in
generating aliases.
EOC
   },
   'lists_dir' =>
   {
    'type'   => 'directory',
    'groups' => [qw(install)],
    'global' => 1,
    'comment'=> <<EOC,
The directory holding the Majordomo lists.  This is normally set
automatically during installation, and is used when creating lists.
EOC
   },
   'mta'    =>
   {
    'type'   => 'string',
    'groups' => [qw(install)],
    'global' => 1,
    'comment'=> <<EOC,
The Mail Transfer Agent running on the Majordomo host.  This is
normally set automatically during installation, and is used when
creating lists.
EOC
   },
   'message_fronter' =>
   {
    'type'   => 'string_2darray',
    'groups' => [qw(resend digest)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
This contains blocks of text, called fronters, that can be added to
the beginning of outgoing messages.  You can include multiple fronters
here by separating them by blank lines.  When a fronter is to be
added, it is chosen at random from the fronters given here.

The following strings can be placed in fronters; they well be
converted to the appropriate text when the fronter is inserted into
the message:

  \$LIST    - the name of the list
  \$VERSION - the version of Majordomo
  \$SENDER  - the person who sent the message
XXX (_SUBJECTS_) ???

Note that for multipart messages, fronters appear as separate parts at
the beginning of the message and that fronters are not added at all to
single part message that are not of type text/plain.  (This avoids
destroying the content of structured messages.)

The frequency with which fronters appear can be controlled with the
variable "message_fronter_frequency".
EOC
   },
   'message_fronter_frequency' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Controls how often a message_fronter will be added to outgoing
messages.  Set this to a number and on average fronters will be added
to that percentage of messagees.  If this is set to 100 or greater,
fronters will always be added.  If set to 0 or below, fronters will
never be added (even if fronters are defined).

Note that this only makes sense if one or more fronters have been set
in message_fronter.  Note also that this only controls the probability
that a fronter will be added; the process itself is random.
EOC
   },
   'message_footer' =>
   {
    'type'   => 'string_2darray',
    'groups' => [qw(resend digest)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
This contains blocks of text, called footers, that can be added to
the beginning of outgoing messages.  You can include multiple footers
here by separating them by blank lines.  When a footer is to be
added, it is chosen at random from the footers given here.

The following strings can be placed in footers; they well be
converted to the appropriate text when the footer is inserted into
the message:

  \$LIST    - the name of the list
  \$VERSION - the version of Majordomo
  \$SENDER  - the person who sent the message

Note that for multipart messages, footers appear as separate parts at
the end of the message and that footers are not added at all to single
part message that are not of type text/plain.  (This avoids destroying
the content of structured messages.)

The frequency with which footers appear can be controlled with the
variable "message_footer_frequency".
EOC
   },
   'message_footer_frequency' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Controls how often a message_footer will be added to outgoing
messages.  Set this to a number and on average footers will be added
to that percentage of messagees.  If this is set to 100 or greater,
footers will always be added.  If set to 0 or below, footers will
never be added (even if footers are defined).

Note that this only makes sense if one or more footers have been set
in message_footer.  Note also that this only controls the probability
that a footer will be added; the process itself is random.
EOC
   },
   'message_headers' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(resend digest)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
These headers will be appended to the headers of the posted message.
The text is expanded before being used.  The following expansion
tokens are defined:
  \$LIST    - the name of the current list,
  \$SENDER  - the sender as taken from the from line,
  \$SEQNO   - the contents of the sequence_number variable, which is
              automatically incremented each time a message is posted
  \$VERSION - the version of Majordomo.
EOC
   },
   'delete_headers' =>
   {
    'type'   => 'string_array',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Headers appearing in this list will be removed from the messages
before being passed on to the recipients or placed into the archive.
EOC
   },
   'subject_prefix' =>
   {
    'type'   => 'string',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
This word will be prefixed to the subject line, if it is not already
in the subject.  The text is expanded before being used.  The following
expansion tokens are defined:
  \$LIST    - the name of the current list
  \$SEQNO   - the contents of the sequence_number variable, which is
              automatically incremented each time a message is posted
  \$VERSION - the version of Majordomo
EOC
   },
   'admin_headers' =>
   {
    'type'   => 'taboo_headers',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If any of the headers matches one of these regexps, then the message
will be bounced for review. XXX Ugh.
EOC
   },
   'admin_body' =>
   {
    'type'   => 'taboo_body',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If any line of the body matches one of these regexps, then the message
will be bounced for review. XXX Ugh.
EOC
   },
   'taboo_headers' =>
   {
    'type'   => 'taboo_headers',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If any of the headers matches one of these regexps, then the message
will be bounced for review. XXX Ugh.
EOC
   },
   'taboo_body' =>
   {
    'type'   => 'taboo_body',
    'groups' => [qw(resend)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If any line of the body matches one of these regexps, then the message
will be bounced for review. XXX Ugh.
EOC
   },
   'digests' =>
   {
    'type'   => 'digests',
    'groups' => [qw(digest)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,

Data on the various digests that the list supports.  A digest is
defined by a name, a description, and several pieces of data that tell
Majordomo when an issue should be generated.  The following data can be given:

name     - A one-word name given to the digest.  It is unwise to name
           the digest "mime" or "nomime".

minsizes - The minimum amount of data (measured in messages or
           kilobytes) which must be collected before a digest will be
           generated.  10m gives a minimum size of 10 messages; 20k
           gives a minimum size of 20 kilobytes, and 10m, 20k will
           create a digest when either 10 messages or 20 kilobytes
           of message data have been collected.  The default is no
           minimum.

maxsizes - The maximum size of digest that will be created.  Specify
           either messages or kilobytes or both as with minsizes.  The
           default is no maximum.

maxage   - If an article is older than this, a digest will be created
           even if enough messages have not been collected.  This
           prevents messages from becoming "stale" on low traffic
           lists.  Specify hours like 12h, days like 4d and weeks like
           2w.  The default is no maximum age.

minage   - A digest will not be created if it most recent article is
           younger than this.  This is intended to prevent digest
           creation in the middle of active discussion.  The default
           is no minimum age.

runall   - Controls whether or not only one digest is created, or if
           digests are created until the pool of messages is exhausted
           to the point that the minimum digest size cannot be met.
           The default is to create multiple digests if necessary.

mime     - This specifies whether new subscribers recive the digest in
           MIME mode by default.  Subscribers can still specify MIME
           or non-MIME delivery explicitly.

time     - The times that digests are allowed to be created.  Times are
           specified as following:

            an integer from 0 to 23: digests will be created once,
            after this hour of the day.

            two integers separated by a dash: digests will be created
            anytime between these two hours.  If the second number is
            less than the first, the range continues into the next
            day.

            the name (or a unique portion) of a day of the week, or a
            day of the month (as an ordinal): digests will be created
            anytime during that day.  fri, tue, 1st, 26th

            a construct like fri(6) or 22nd(12-18) limits digest
            creation to those hours on those days.

           Commas can be used to make lists of hours or days, so you
           can have:

            mo(6,8,10), tu(12-18,22-6), we, 3rd(4,10-14)

           The default is to allow digest creation without regard to
           time.

These settings take precedence in the following order:

  A digest is always created when triggered if there is a waiting
  message older than 'maxage', even if this means violating minimum
  size limits.

  Otherwise, digests will only be created if there are enough messages
  (minsizes), the last mesage which would be included in the digest is
  old enough (minage) and the time is right (time), meaning that the
  day is proper and either the hour is in a given range or a single
  hour was given and no digest has been triggered in that hour.

Each digest is defined by two lines.  The first contains data in the
following order, separated by vertical bars (\'|\') or colons:

name    | minsizes | maxage | maxsizes | minage | runall | mime | time

The second line holds a description of the digest.

Here is an example, defining two digests:

daily   | 20K, 5m  | 3d     | 40K, 10m |        | no     | no   | 23
The test-list daily digest
weekly  | 20k, 5m  |        | 100k,30m |        | yes    | yes  | fr(23)
The test-list weekly digest

EOC
   },
   'addr_xforms' =>
   {
    'type'   => 'xform_array',
    'groups' => [qw(majordomo xform)],
    'visible'=> 0,
    'global' => 1,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
A list of transformations to be applied to addresses before comparing
them for equivalency.  This can be used to remove the '+mailbox' part
of an address, or to remove the machine name from addresses in a
domain.  Transforms should listed one per line, and should be in the
form /pattern/replacement/.  For example, /(.*)\\+.*(\\@.*)/\$1\$2/
removes the '+mailbox' specifier from an address.  NOTE: these
transforms must be idempotent; that is, they must give the same result
when applied multiple times in succession.
EOC
   },
   'apply_global_xforms' =>
   {
    'type'   => 'bool',
    'groups' => [qw(majordomo xform)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
Should the site-wide set of address transformations be applied, in
addition to the list-specific ones?
EOC
   },
   'master_password' =>
   {
    'type'   => 'pw',
    'groups' => [qw(password)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
This is the master password for the list.  A user having this password
can perform any list action and change any list data.
EOC
   },
   'passwords' =>
   {
    'type'   => 'passwords',
    'groups' => [qw(password)],
    'visible'=> 0,
    'local'  => 1,
    'global' => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
A table of passwords, the actions they allow a user to perform, and an
optional list of user names which they are bound to.  The table should
look like so:

  password1 : action, action, action
  password2 : action, action : user\@host.dom, blah\@urk.org

If no users are listed, the password can be used by all users.  Any
addresses listed are put through the transformation and aliasing
processes before being used.

The following actions are permitted:

  config_xyz - allows the user to view and alter the contents of
    config variables in the group "xyz".

 XXX List all of the actions here!
EOC
   },
   'welcome' =>
   {
    'type'   => 'bool',
    'groups' => [qw(majordomo welcome)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,
If this is on, new subscribers will be sent a welcome message.
EOC
   },
   'welcome_files' =>
   {
    'type'   => 'welcome_files',
    'groups' => [qw(majordomo welcome)],
    'visible'=> 0,
    'local'  => 1,
    'mutable'=> 1,
    'comment'=> <<EOC,

A table containing a list of files and descriptions that should be
sent to new subscribers, like so:

Welcome to the mailing list!
welcome
Picture of the list owner!
owner.jpg : P
Mailing list FAQ
faq.txt

Each table record takes two lines.  The first should be an explanatory
message, which will go in the subject or content-description header as
appropriate.  (If this is empty, the file\'s description will be used.)
The second is broken into fields by ":" or "|".

The first field is the name of the file, in the file space of the
list.

The second should be either "N", meaning that the file will be sent as
a separate piece of mail, or "P", meaning that the file will be
attached to the previous file.  The default is "N".  In addition, an
"S" can be added, indicating that the file should undergo variable
substitution.  Currently the following substitutions are supported:

 \$USER      - the address of the user
 \$LIST      - the list name
 \$REQUEST   - the list-request address
 \$MAJORDOMO - the address of the majordomo server
 \$OWNER     - the address of the majordomo owner

EOC
   },
   'filedir' =>
   {
    'type'   => 'directory',
    'groups' => [qw(filespace)],
    'global' => 1,
    'local'  => 1,
    'mutable'=> 0,
    'visible'=> 0,
    'comment'=> <<EOC,
The directory where the filespace for the list is kept.
EOC
   },
   'file_search' =>
   {
    'type'   => 'list_array',
    'groups' => [qw(filespace)],
    'local'  => 1,
    'comment'=> <<EOC,
This provides a search-path mechanism for filename lookup.  Entries are of
the form

  list:path

where \'list\' is the name of a list and path is the path within the
list\'s filespace.  \'list\' can be empty, in which case this list is used.
\'path\' can be empty, in which case the root of the filespace is used.
Thus \':\' refers to the top of the filespace of this list.

To access files of another list, that list must must contain this
list\'s name in its file_share variable.  If the referenced list does
not share with this list, the relevant entries will be ignored.

If \'\$LANG\' appears in the path portion, it is expanded to the user\'s
current language choice if one is available.  If one is not available,
entries containing \'\$LANG\' will be ignored.

Certain directories of the GLOBAL list are always searched to provide
defaults; these directories correspond to the following entries:

  GLOBAL:\$LANG
  GLOBAL:
  GLOBAL:stock/\$LANG
  GLOBAL:stock/en
EOC
   },
   'file_share' =>
   {
    'type'   => 'list_array',
    'groups' => [qw(filespace)],
    'local'  => 1,
    'comment'=> <<EOC,
This should contain the names (one per line) of every list which is
allowed to access files from this list\'s filespace.
EOC
   },
# Purely global configuration variables below
   
   'site_name' =>
   {
    'type'   => 'string',
    'groups' => [qw(majordomo)],
    'global' => 1,
    'visible'=> 1,
    'comment'=> <<EOC,
The name of the site that this Majordomo runs at.
EOC
   },
   'whereami' =>
   {
    'type'   => 'word',
    'groups' => [qw(majordomo)],
    'global' => 1,
    'visible'=> 1,
    'comment'=> <<EOC,
What machine is Majordomo running on?
EOC
   },
   'whoami' =>
   {
    'type'   => 'address',
    'groups' => [qw(majordomo)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
    'comment'=> <<EOC,
What address do users send requests to?
EOC
   },
   'whoami_owner' =>
   {
    'type'   => 'address',
    'groups' => [qw(majordomo)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
    'comment'=> <<EOC,
Where to bounces from the whoami address go?
EOC
   },
   'tmpdir' =>
   {
    'type'   => 'word',
    'groups' => ['majordomo'],
    'global' => 1,
    'visible'=> 1,
    'comment'=> <<EOC,
A directory in which to store temporary files.  For security reasons,
this should not be a directory that normal users have write access to.
EOC
   },
   'max_in_core' =>
   {
    'type'   => 'integer',
    'groups' => ['email'],
    'global' => 1,
    'visible'=> 1,
    'comment'=> <<EOC,
The maximum size of a message part to hold in memory; parts larger
than this will be held in temporary files.
EOC
   },
   'return_subject' =>
   {
    'type'   => 'bool',
    'groups' => ['email'],
    'global' => 1,
    'visible'=> 1,
    'comment'=> <<EOC,
Should the subject of an email request be returned as part of the
subject of the response?
EOC
   },
   'chunksize' =>
   {
    'type'   => 'integer',
    'groups' => ['majordomo'],
    'global' => 1,
    'visible'=> 1,
    'comment'=> <<EOC,
This controls the size of various internal structures.  Lowering this
value saves memory and decreases performance.  Setting it to 0
disables internal chunking, and can use very large amounts of memory.
EOC
   },
   'default_language' =>
   {
    'type'   => 'string',
    'groups' => [qw(language)],
    'global' => 1,
    'local'  => 1,
    'visible'=> 1,
    'comment'=> <<EOC,
This sets the default language for the list (or the installation).
This is overridable by the user in several ways.  Note that at this
time this is barely implemented.  (Only English messages are supported
at the moment.)
EOC
   },
   'default_lists_format' =>
   {
    'type'   => 'enum',
    'values' => [qw(tiny compact short long extended)],
    'groups' => ['lists'],
    'global' => 1,
    'visible'=> 0,
    'comment'=> <<EOC,
This defines the default output format for the lists command.
compact shows one list per line with short descriptions.
long shows long descriptions
extended shows long descriptions and extra information (whether or not
  the user is subscribed to the list, etc.)
EOC
   },
   'description_max_lines' =>
   {
    'type'   => 'integer',
    'groups' => ['lists'],
    'global' => 1,
    'visible'=> 0,
    'comment'=> <<EOC,
Sets the maximum number of lines of list description that will be
shown in a long or extended listing.  Setting this to zero will impose
no limit.
EOC
   },
   'confirm_url' =>
   {
    'type'   => 'string',
    'groups' => [qw(access token)],
    'local'  => 0,
    'global' => 1,
    'visible'=> 0,
    'comment'=> <<EOC,
The URL that is used to return confirmation tokens.  The only purpose
of this variable is to supply a value to be used in the confirmation
messages that are sent out.  The embedded variable \$TOKEN will be
expanded to the token being confirmed.
EOC
   },
   'token_remind' =>
   {
    'type'   => 'integer',
    'groups' => [qw(access token)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 0,
    'comment'=> <<EOC,
If a token exists longer than this many days, a reminder message will
be sent.  If this is unset or zero, no reminders will be sent.
EOC
   },
   'dup_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend majordomo)],
    'global' => 0,
    'local'  => 1,
    'visible'=> 0,
    'comment'=> <<EOC,
The number of days that entries in the duplicate databases will be
kept.  Majordomo saves information about Message-ID:s and various
checksums of messages that pass through the list in order to filter
out duplicates.  To limit database size and to cut down on the
possibility of false positives, these entries are periodically
trimmed after this number of days.
EOC
  },
   'session_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(majordomo)],
    'global' => 1,
    'visible'=> 0,
    'comment'=> <<EOC,
The number of days that information on all Majordomo sessions will be
kept.  Majordomo saves the complete headers of all emailed requests,
and all pertinent information for other types of requests.  These
files can occupy significant space on an active server, so they are
purged after this many days.
EOC
  },
   'token_lifetime' =>
   {
    'type'   => 'integer',
    'groups' => [qw(access token)],
    'local'  => 1,
    'global' => 1,
    'visible'=> 0,
    'comment'=> <<EOC,
The number of days that a token will be allowed to live without being
acknowledged (either approved or rejected).  Tokens existing longer
than this many days are deleted at every daily trigger.
EOC
   },
   'bounce_probe_frequency' =>
   {
    'type'   => 'integer',
    'groups' => [qw(resend deliver bounce)],
    'local'  => 1,
    'global' => 0,
    'visible'=> 0,
    'mutable'=> 0,
    'comment'=> <<EOC,
This variable controls how often bounce probes are sent out.

Bounce probing entails sending specially formatted messages such that the
address causing a bounce is immediately obvious when the bounce is
received.  This requires that each mail transaction send to only one
address, which places additional load on the mail server.  To counter this,
bounce probing is implemented in an incremental fashion.

The address list is split into \'bounce_probe_frequency\' pieces, and a
different piece is probed for each message sent to the list.  This lowers
the overall load while still allowing complete probes to be done in a
reasonable amount of time.

The proper setting depends on a number of factors; it is generally
desireable to probe the entire list once every several days and definitely
not more frequently than once a day.  Thus this should not be set lower
than the expected number of messages per day.  The upper bound depends on
how much additional load the mail server(s) can tolerate.

Setting this to zero disables regular bounce probing.  Setting this to one
probes every address for every message and may place an extreme load on the
server(s).  Note that this variable will be ignored if the MTA is qmail,
because qmail does an equivalent kind of bounce probing itself.
EOC
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

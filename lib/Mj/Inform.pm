=head1 NAME

Mj::Inform.pm - Routines to log and inform the list owner of actions.

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

These routines take care of notifying the list owner of things that
happened on and to the list.  Requests can be logged or ignored, or the
list owner can be immediately informed of them via email.  Logged requests
can be reported on and the log file truncated.  This enables an owner to
get a periodic summary of all list action without receiving individual
messages.

Logs are stored in a simple one-line-per-entry format.

=cut

package Mj::Inform;
use Mj::File;
use Mj::FileRepl;
use Mj::Log;
use strict;

use AutoLoader 'AUTOLOAD';

=head2 inform(list, request, requester, user, cmdline, success, override, comment)

This is the general-purpose information routine.  It makes use of the
inform variable, which should be the parsed version of the list config
variable which allows the owner to specify which requests are to be logged,
which are to be sent via email, and which are to be ignored.

list is the name of the list the request acted upon.

request is the actual request that was carried out.

requester is the address/user which made the request.

user is the address/user which the request affected.

cmdline is the actual command line which made the request.

int indicates the interface that was used to carry out the command.

status indicates whether the request failed (0), succeeded (>0) or stalled
(<0).

pass is true if a password was provided when the command was run.

override controls under what circumstances a message is sent to the owner:
  positive: never
  zero:     if the "inform" setting allows it
  negative: always

comment is an explanation of what took place.

=cut
sub inform {
  my($self, $list, $req, $requ, $user, $cmd, $int, $stat, $pass, $over, $comment) = @_;
  my $log  = new Log::In 150, "$list, $req";

  my $file = "$self->{'ldir'}/GLOBAL/_log";

  # Open the logfile
  my $fh = new Mj::File $file, '>>';
  $log->abort("Cannot open $file, $!")
    unless $fh;

  $user ||= ''; $requ ||= '';

  # Log the data
  my $line = join("\001", $list, $req, $requ, $user, $cmd, $int, $stat,
		  $pass, $self->{'sessionid'}, time);
  $line =~ tr/\n\t//d;
  $fh->print("$line\n") ||
    $log->abort("Cannot append to $file, $!");

  # Close the logfile
  $fh->close ||
    $log->abort("Cannot close $file, $!");

  # Update the session
  if ($self->{sessionfh}) {
    $self->{sessionfh}->print("$stat: $cmd\n");
  }

  # Decide whether or not to inform the owner
  my $data = $self->_list_config_get($list, 'inform');
  my $inf = $data->{$req}{'all'} || $data->{$req}{$stat} || 0;

  # Inform the owner (1 is log, 2 is inform); we inform on accepts
  # elsewhere.
  if (((($inf & 2) && !$over) || ($over < 0)) && $req ne 'reject') {
    $self->_inform_owner($list, $req, $requ, $user, $cmd, $int, $stat, $pass, $comment);
  }
  1;
}

1;
__END__

=head2 _mail_inform(list, request, requester, user, cmdline, interface, success, passworded)

This is a helper function for inform; it constructs a mesage and mails it
to the owner.  This is removed from inform so that MIME::Entity does not
have to be loaded for every log entry.

=cut
use MIME::Entity;
sub _inform_owner {  
  my($self, $list, $req, $requ, $user, $cmd, $int, $stat, $pass, $comment) = @_;
  my $log = new Log::In 150, "$list, $req";

  my $whereami = $self->_global_config_get('whereami');
  my $owner    = $self->_list_config_get($list, 'sender');
  my $sender   = $self->_global_config_get('whoami');
  my $statdesc = $stat < 0 ? 'stall' : $stat > 0 ? 'success' : 'failure';

  my ($message, %data) = $self->_list_file_get($list, 'inform');

  # Substitute in the header
  my $desc = $self->substitute_vars_string($data{'description'},
					   {
					    'UREQUEST' => uc($req),
					    'REQUEST'  => $req,
					    'LIST'     => $list,
					   },
					  );

  # Substitute in the body
  $message = $self->substitute_vars($message,
				    {
				     'VICTIM'    => $user,
				     'USER'      => $user,
				     'LIST'      => $list,
				     'REQUEST'   => $req,
				     'REQUESTER' => $requ,
				     'CMDLINE'   => $cmd,
				     'STATUS'    => $stat,
				     'STATDESC'  => $statdesc,
				     'INTERFACE' => $int,
				     'SESSIONID' => $self->{'sessionid'},
                     'COMMENT'   => $comment,
				     },
				   );
  my $ent = build MIME::Entity
    (
     Path        => $message,
     Type        => $data{'c_type'},
     Charset     => $data{'charset'},
     Encoding    => $data{'c_t_encoding'},
     Filename    => undef,
     -To         => $owner,
     -From       => $sender,
     -Subject    => $desc,
     'Content-Language:' => $data{'language'},
    );

  my $out = $self->mail_entity($sender, $ent, $owner);

  # Clean up our tempfiles.  Crap; this kills the return value.
  $ent->purge;

  $out;
}

=head2 report(logfile, inform_data, list, start_time, stop_time)

This formats and returns (in a string) a report of list activity.  The
report will include data from between start_time and stop_time.  start_time
defaults to 0 and end_time defaults to now.

If list is GLOBAL, only global ststistics (help, lists, and access
requests) will be reported.  If list is ALL, a summary report for all
activity will be generated.  Otherwise a report for the particular list
given will be generated.

XXX This should arguably return some complicated data structure containing
all of the statistics to be formatted by the interface.

=cut



=head2 truncate_log(logfile, time)

This will eliminate all log entries older than time.  This assumes that the
file is strictly ordered by date, which it should be unless something is
very wrong.

=cut


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

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

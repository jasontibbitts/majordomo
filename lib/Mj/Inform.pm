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
use Mj::CommandProps qw(:command);
use Mj::Lock;
use Mj::Log;
use Symbol;
use strict;

use AutoLoader 'AUTOLOAD';

=head2 inform(list, request, requester, user, cmdline, interface, status, password, override, comment, elapsed)

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

elapsed is the amount of time required for the command to execute.

=cut
sub inform {
  my($self, $list, $req, $requ, $user, $cmd, $int, 
     $stat, $pass, $over, $comment, $elapsed) = @_;
  my $log  = new Log::In 150, "$list, $req";
  my $lf = gensym();

  my $file = "$self->{'ldir'}/GLOBAL/_log";

  # Open the logfile
  my $fh = new Mj::Lock($file, 'exclusive');
  $log->abort("Cannot lock $file, $!")
    unless $fh;
  open ($lf, ">>$file") or
    $log->abort("Cannot open $file, $!");


  $user ||= ''; $requ ||= '';
  $elapsed = sprintf("%.3f", $elapsed);

  if (command_prop($req, 'real') and not command_prop($req, 'list')) {
    $list = 'GLOBAL';
  }

  # Log the data
  my $line = join("\001", $list, $req, $requ, $user, $cmd, $int, $stat,
		  $pass, $self->{'sessionid'}, time, $elapsed);
  $line =~ tr/\n\t//d;
  print($lf "$line\n") ||
    $log->abort("Cannot append to $file, $!");

  # Close the logfile
  close ($lf) or
    $log->abort("Unable to close file $file: $!");

  # Update the session
  if ($self->{sessionfh} and $req ne 'newtoken') {
    print {$self->{sessionfh}} ("$stat: $cmd\n");
  }

  # Decide whether or not to inform the owner
  my $data = $self->_list_config_get($list, 'inform');
  my $inf = $data->{$req}{$stat} || 0;

  # Inform the owner (1 is report, 2 is inform); we inform on accepts
  # elsewhere.
  if (((($inf & 2) && !$over) || ($over < 0)) && $req ne 'reject') {
    $self->_inform_owner($list, $req, $requ, $user, $cmd, $int, $stat, $pass, $comment, $elapsed);
  }
  1;
}

1;
__END__

=head2 _inform_owner(list, request, requester, user, cmdline, interface, success, passworded, comment)

This is a helper function for inform; it constructs a mesage and mails it
to the owner.  This is removed from inform so that MIME::Entity does not
have to be loaded for every log entry.

=cut
use Date::Format;
use MIME::Entity;
sub _inform_owner {  
  my($self, $list, $req, $requ, $user, $cmd, $int, $stat, $pass, 
     $comment, $elapsed) = @_;
  my $log = new Log::In 150, "$list, $req";
  my $strip;

  my $whereami = $self->_global_config_get('whereami');
  my $owner    = $self->_list_config_get($list, 'whoami_owner');
  return unless ($owner);
  my $sender   = $self->_global_config_get('whoami');
  my $statdesc = $stat < 0 ? 'stall' : $stat > 0 ? 'success' : 'failure';

  my ($message, %data) = $self->_list_file_get(list => $list,
					       file => 'inform',
					      );
  if (ref $user) { 
    $strip = $user->strip;
  }
  else {
    $strip = $user;
  }

  my $subs = {
               $self->standard_subs($list),
               'CMDLINE'   => $cmd,
	       'COMMAND'   => $req,
               'COMMENT'   => $comment,
	       'INTERFACE' => $int,
	       'REQUESTER' => $requ,
	       'SESSIONID' => $self->{'sessionid'} || '(none)',
	       'STATUS'    => $stat,
	       'STATDESC'  => $statdesc,
               'STRIPUSER' => $strip,
               'TIME'      => $elapsed,
	       'UCOMMAND'  => uc $req,
	       'USER'      => $user,
	       'VICTIM'    => $user,
	     };

  # Substitute in the header
  my $desc = $self->substitute_vars_string($data{'description'}, $subs);

  # Substitute in the body 
  $message = $self->substitute_vars($message, $subs);

  my $ent = build MIME::Entity
    (
     Path        => $message,
     Type        => $data{'c_type'},
     Charset     => $data{'charset'},
     Encoding    => $data{'c_t_encoding'},
     Filename    => undef,
     -To         => $owner,
     -From       => $sender,
     -Date       => time2str("%a, %d %b %Y %T %z", time),
     -Subject    => $desc,
     'Content-Language:' => $data{'language'},
    );

  my $out = $self->mail_entity($sender, $ent, $owner);

  # Clean up our tempfiles.  Crap; this kills the return value.
  $ent->purge;

  $out;
}

=head2 l_expire 

This will eliminate all log entries older than the log_lifetime setting.  

=cut
use Mj::FileRepl;
sub l_expire {
  my $self = shift;
  my $log = new Log::In 60;
  my (@entry, $count, $cutoff, $days, $fh, $line);

  $days = $self->_global_config_get('log_lifetime');
  return unless (defined $days and $days >= 0);

  $count = 0;
  $cutoff = time - ($days * 86400);

  $fh = new Mj::FileRepl("$self->{'ldir'}/GLOBAL/_log");
  return unless $fh;

  while ($line = $fh->{'oldhandle'}->getline) {
    @entry = split "\001", $line;
    if ($entry[9] and $entry[9] > $cutoff) {
      $fh->copy;
      $fh->commit;
      last;
    }
    $count++;
  }
  $count;
}

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

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

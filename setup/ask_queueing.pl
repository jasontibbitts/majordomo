sub ask_queueing {
  my($config) = @_;

  $msg = <<EOM;
Mail Handling Setup

How many queue servicing processes do you want to run concurrently?
  Queue runners will be created as necessary (not all at once), but under
  no circumstances will more than this number exist at the same time.
EOM
  $def = (defined $config->{'queue_concurrency'} ?
	  $config->{'queue_concurrency'} : 3);
  $config->{'queue_concurrency'} = get_str($msg, $def);

  $msg = <<EOM;
Mail Handling Setup

How long should queue servicing processes wait without doing any work
 before they exit?
 The queue runners will automatically exit after this many seconds of
  inactivity.
EOM
  $def = $config->{'queue_timeout'} || 120;
  $config->{'queue_timeout'} = get_str($msg, $def);

  #---- Ask about child process reaping
  $msg = <<EOM;
Mail Handling Setup

Does \$SIG{CHLD} = 'IGNORE' reap children on your system?
 On most systems, simply ignoring signals about the status of child
  processes will cause the system to clean them up for you.  On some,
  however, this will not happen and Majordomo must use a slightly messier
  method.
 If you do not know the answer, say yes.  If mj_queueserv starts to
  accumulate zombie children then reinstall and answer no.

EOM
  $def = defined($config->{'queue_chld_ignore'}) ?
    $config->{'queue_chld_ignore'} : 1;
  $config->{'queue_chld_ignore'} = get_bool($msg, $def);
}

=head1 COPYRIGHT

Copyright (c) 1999 Jason Tibbitts for The Majordomo Development
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
### cperl-label-offset:-1 ***
### indent-tabs-mode: nil ***
### End: ***

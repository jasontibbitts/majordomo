use vars qw($lang);

sub ask_queueing {
  my($config) = @_;
  my($def, $msg);

  #---- Number of concurrent queue runners
  $msg = retr_msg('queue_runners', $lang);
  $def = (defined $config->{'queue_concurrency'} ?
	  $config->{'queue_concurrency'} : 3);
  $config->{'queue_concurrency'} = get_str($msg, $def);

  #---- How long should runners wait before exiting?
  $msg = retr_msg('runner_wait', $lang);
  $def = $config->{'queue_timeout'} || 120;
  $config->{'queue_timeout'} = get_str($msg, $def);

  #---- Ask about child process reaping
  $msg = retr_msg('sig_chld', $lang);
  $def = defined($config->{'queue_chld_ignore'}) ?
    $config->{'queue_chld_ignore'} : 1;
  $config->{'queue_chld_ignore'} = get_bool($msg, $def);
}

=head1 COPYRIGHT

Copyright (c) 1999, 2002 Jason Tibbitts for The Majordomo Development
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
### cperl-label-offset:-1 ***
### indent-tabs-mode: nil ***
### End: ***

=head1 NAME

Mj::MTAConfig.pm - Mailer configuration routines for Majordomo

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This module contains functions which deal with MTA-specific configuration
issues.  Support of as many MTAs as possible is an important goal of the
Majordomo project.

There is an entry point per supported MTA which should return a string
containing information that will be sent to the responsible parties.
Future plans call for including the ability to have these functions
actually do some or all of the required configuration.

=cut

package Mj::MTAConfig;
use Mj::Log;
use strict;
use vars (qw(%sendsep %supported));

%sendsep = (
	    sendmail => '+'
	   );

%supported = (
	      'sendmail' => 'sendmail',
	     );

=head2 sendmail

This is the main interface to Sendmail configuration manipulation
functionality.

By default we want to call one_alias and return the results as we used to.

Given a list of [list, owner] pairs, we can call all_aliases.

Given the location of an alias file, we can append to it or rewrite it from
scratch.

=cut
sub sendmail {
  my %args = @_;
  my $log = new Log::In 150;

  Mj::MTAConfig::Sendmail::add_alias(%args);
}

package Mj::MTAConfig::Sendmail;
use Mj::File;
use Mj::FileRepl;

=head2 one_alias

This produces a block of aliases suitable for cut and paste into a sendmail
aliases file, along with a bit of explanation.

Things we need:

  list   => name of list (no list -> produce global aliases)
  bindir => path to executables
  domain => domain this list or majordomo is to serve
  debug  => whether or not copious debuging is called for

=cut
sub add_alias {
  my $log  = new Log::In 150;
  my %args = @_;
  my ($block, $debug, $fh, $head);
  my $bin  = $args{bindir} || $log->abort("bindir not specified");
  my $dom  = $args{domain} || $log->abort("domain not specified");
  my $list = $args{list}   || 'GLOBAL';
  my $who  = $args{whoami} || 'majordomo'; 

  if ($args{debug}) {
    $debug = " -v500";
  }
  else {
    $debug = '';
  }

  $head = <<EOS;
Please add the following lines to your aliases file, if they are not
already present.  You may have to run the "newaliases" command afterwards
to enable these aliases.
EOS

  if ($list eq 'GLOBAL') {
    $block = <<"EOB";
# Aliases for Majordomo at $dom
$who:       "|$bin/mj_email -m -d $dom$debug"
$who-owner: "|$bin/mj_email -o -d $dom$debug"
owner-$who: majordomo-owner,
# End aliases for Majordomo at $dom
EOB
  }
  else {
    $block = <<"EOB";
# Aliases for $list at $dom
$list:         "|$bin/mj_email -r -d $dom -l $list$debug"
$list-request: "|$bin/mj_email -q -d $dom -l $list$debug"
$list-owner:   "|$bin/mj_email -o -d $dom -l $list$debug"
owner-$list:   $list-owner,
# End aliases for $list at $dom
EOB
  }
  if ($args{aliasfile}) {
    $fh = new Mj::File($args{aliasfile}, '>>');
    $fh->print($block);
    $fh->close;
    return;
  }
  return ($head, $block);
}

=head2 del_alias

Deletes the aliases for a list from the alias file.

=cut
sub del_alias {
  my %args = @_;

}

=head2 regen_aliases

This generates a complete set of aliases from a set of lists.  add_alias is
called repeatedly to generate all of the necessary aliases.

=cut
sub regen_aliases {
  my %args = @_;
  my $fh = new Mj::FileRepl($args{aliasfile});

  # Sort list of lists.

  # Generate GLOBAL aliases.

  # Generate aliases for each given list.

  # Close the file.

}

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
### mode:cperl ***
### cperl-indent-level:2 ***
### End: ***

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
use vars (qw(%header %sendsep %supported));

%sendsep = (
	    sendmail => '+'
	   );

%supported = (
	      'sendmail' => 'sendmail',
	     );

%header = (
	   'sendmail' => <<EOM,
Please add the following lines to your aliases file, if they are not
already present.  You may have to run the "newaliases" command afterwards
to enable these aliases.
EOM
	  );

=head2 sendmail

This is the main interface to Sendmail configuration manipulation
functionality.

By default we want to call one_alias and return the results as we used to.

Given a list of list names, we can call all_aliases.

Given the location of an alias file, we can append to it or rewrite it from
scratch.

=cut
sub sendmail {
  my %args = @_;
  my $log = new Log::In 150;
  my $dom = $args{domain};

  if ($args{options}{maintain_config}) {
    $args{aliasfile} = "$args{topdir}/ALIASES/mj-alias-$dom";
    if ($args{options}{maintain_vut}) {
      $args{vutfile} = "$args{topdir}/ALIASES/mj-vut-$dom"
    }
  }

  if ($args{regenerate}) {
    return Mj::MTAConfig::Sendmail::regen_aliases(%args);
  }
  elsif ($args{'delete'}) {
    return Mj::MTAConfig::Sendmail::del_alias(%args);
  }
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
  my ($block, $debug, $fh, $vblock, $vut);
  my $bin  = $args{bindir} || $log->abort("bindir not specified");
  my $dom  = $args{domain} || $log->abort("domain not specified");
  my $list = $args{list}   || 'GLOBAL';
  my $who  = $args{whoami} || 'majordomo'; 
  my $umask= umask; # Stash the umask away

  if ($args{debug}) {
    $debug = " -v$args{debug}";
  }
  else {
    $debug = '';
  }

  if ($args{options}{maintain_vut}) {
    $vut = "-$dom";
  }
  else {
    $vut = '';
  }


  if ($list eq 'GLOBAL') {
    $block = <<"EOB";
# Aliases for Majordomo at $dom
$who$vut:       "|$bin/mj_email -m -d $dom$debug"
$who$vut-owner: "|$bin/mj_email -o -d $dom$debug"
owner-$who$vut: majordomo-owner,
# End aliases for Majordomo at $dom
EOB
    $vblock = <<"EOB";
# VUT entries for Majordomo at $dom
$who\@$dom         $who$vut
$who-owner\@$dom   $who$vut-owner
owner-$who-\@$dom  owner-$who$vut
# End VUT entries for Majordomo at $dom
EOB

  }
  else {
    $block = <<"EOB";
# Aliases for $list at $dom
$list$vut:         "|$bin/mj_email -r -d $dom -l $list$debug"
$list$vut-request: "|$bin/mj_email -q -d $dom -l $list$debug"
$list$vut-owner:   "|$bin/mj_email -o -d $dom -l $list$debug"
owner-$list$vut:   $list-owner,
# End aliases for $list at $dom
EOB
    $vblock = <<"EOB";
# VUT entries for $list at $dom
$list\@$dom          $list$vut
$list-request\@$dom  $list$vut-request
$list-owner\@$dom    $list$vut-owner
owner-$list\@$dom    owner-$list$vut
# End VUT entries for $list at $dom
EOB
  }
  if ($args{aliashandle}) {
    $args{aliashandle}->print("$block\n");
    if ($args{vuthandle}) {
      $args{vuthandle}->print("$vblock\n");
    }
    return;
  }
  elsif ($args{aliasfile}) {
    umask oct("077"); # Must have restrictive permissions
    $fh = new Mj::File($args{aliasfile}, '>>');
    $fh->print("$block\n");
    $fh->close;
    if ($vut) {
      $fh = new Mj::File($args{vutfile}, '>>');
      $fh->print("$vblock\n");
      $fh->close;
    }
    umask $umask;
    return '';
  }
  return $block;
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

  $args{lists} is a list of [name, debug, ...] listrefs.

=cut
sub regen_aliases {
  my %args = @_;
  my ($block, $body, $i, $umask);
  $body = '';
  $umask = umask;

  # Open the file
  if ($args{aliasfile}) {
    umask oct("077");
    $args{aliashandle} = new Mj::FileRepl($args{aliasfile});
    if ($args{options}{maintain_vut}) {
      $args{vuthandle} = new Mj::FileRepl($args{vutfile});
    }
  }

  # Generate aliases for each given list; do this twice to get GLOBAL out
  # first for aesthetic purposes.
  for $i (@{$args{lists}}) {
    next unless $i->[0] eq 'GLOBAL';
    $block = add_alias(%args, list => $i->[0], debug => $i->[1]);
    $body .= "$block\n" if $block;
  }

  for $i (@{$args{lists}}) {
    next if $i->[0] eq 'GLOBAL';
    $block = add_alias(%args, list => $i->[0], debug => $i->[1]);
    $body .= "$block\n" if $block;
  }

  # Close the file.
  if ($args{aliashandle}) {
    $args{aliashandle}->commit;
    if ($args{vuthandle}) {
      $args{vuthandle}->commit;
    }
    umask $umask;
  }
  $body;
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

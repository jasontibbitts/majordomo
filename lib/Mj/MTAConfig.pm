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
use vars (qw(%header %supported));

%supported = (
	      sendmail => 'sendmail',
	      qmail    => 'qmail',
	      exim     => 'exim',
	      postfix  => 'postfix',
	     );

%header = (
	   'sendmail' => <<EOM,
Please add (for createlist, if they are not already present)
or remove (for createlist-destroy if they still exist) the
following lines in your aliases file. You may have to run
the "newaliases" command afterwards to enable these aliases.
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

=head2 exim

Because Exim uses alias files in the same format as Sendmail does but
doesn''t need the virtusertable garbage, we can just call the simple
Sendmail routines.

=cut
sub exim {
  my %args = @_;
  my $log = new Log::In 150;
  my $dom = $args{domain};

  if ($args{options}{maintain_config}) {
    $args{aliasfile} = "$args{topdir}/ALIASES/mj-alias-$dom";
  }

  if ($args{regenerate}) {
    return Mj::MTAConfig::Sendmail::regen_aliases(%args);
  }
  elsif ($args{'delete'}) {
    return Mj::MTAConfig::Sendmail::del_alias(%args);
  }
  Mj::MTAConfig::Sendmail::add_alias(%args);
}

=head2 qmail

Because mj_email handles figuring out everything without additional config
information, we really have nothing to do here.

=cut
sub qmail {
  return 1;
}

=head2 postfix

This is the main interface to postfix configuration manipulation
functionality.

The code is very similar to that for sendmail.

=cut
sub postfix {
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

=head2 add_alias

This produces a block of aliases suitable for cut and paste into a sendmail
aliases file, along with a bit of explanation.

Things we need:

  list   => name of list (no list -> produce global aliases)
  bindir => path to executables
  domain => domain this list or majordomo is to serve
  debug  => debugging level
  priority => both domain and list, in queue mode only.

=cut
sub add_alias {
  my $log  = new Log::In 150;
  my %args = @_;
  my ($aliasfmt, $block, $debug, $dpri, $fh, 
      $pri, $program, $sublist, $vblock, $vut);
  my $bin  = $args{bindir} or $log->abort("bindir not specified");
  my $dom  = $args{domain} or $log->abort("domain not specified");
  my $list = $args{list}   || 'GLOBAL';
  my $who  = $args{whoami} || 'majordomo'; 
  my $umask= umask; # Stash the umask away

  return '' if ($list eq 'DEFAULT');

  if ($args{debug}) {
    $debug = " -v$args{debug}";
  }
  else {
    $debug = '';
  }

  $dpri = '';
  if (defined($args{domain_priority}) and $args{domain_priority} >= 0) {
    $dpri = " -P$args{domain_priority}" if ($args{queue_mode});
  }
  
  $pri = '';
  if (defined($args{priority}) and $args{priority} >= 0) {
    $pri = " -p$args{priority}" if ($args{queue_mode});
  }
  

  if ($args{options}{maintain_vut}) {
    $vut = "-$dom";
  }
  else {
    $vut = '';
  }

  if ($args{'queue_mode'}) {
    $program = "mj_enqueue";
  }
  else {
    $program = "mj_email";
  }

  if ($list eq 'GLOBAL') {
    $block = <<"EOB";
# Aliases for Majordomo at $dom
$who$vut:       "|$bin/$program -m -d $dom$debug$dpri$pri"
$who$vut-owner: "|$bin/$program -o -d $dom$debug$dpri$pri"
owner-$who$vut: $who$vut-owner
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
  #
  # Create aliases for one mailing list.
  # Which aliases are created will depend upon the 
  # "aliases" configuration setting.  If the
  # list is new, the default value will need to be
  # used.  The possible aliases settings are:
  #
  # auxiliary  An alias for each auxiliary list in the "sublists" setting.
  # moderator    LIST-moderator
  # owner        LIST-owner
  # request      LIST-request
  # resend       LIST
  # subscribe    LIST-subscribe
  # subscribe-*  LIST-subscribe-(various stuff)
  # unsubscribe  LIST-unsubscribe
  #
  # As implemented, owner, requiest, and resend are mandatory.
  else {
    $aliasfmt = "$list$vut%-12s \"|$bin/$program %s -d $dom -l $list$debug$dpri$pri\"\n";
    $block  = "# Aliases for $list at $dom\n";
    $block .= sprintf $aliasfmt, ':', '-r';
    $block .= sprintf $aliasfmt, '-request:', '-q';
    $block .= sprintf $aliasfmt, '-owner:', '-o';
    $block .= "owner-$list$vut:   $list$vut-owner\n";

    $vblock = <<"EOB";
# VUT entries for $list at $dom
$list\@$dom              $list$vut
$list-request\@$dom      $list$vut-request
$list-owner\@$dom        $list$vut-owner
owner-$list\@$dom        owner-$list$vut
EOB

    if (exists $args{'aliases'}->{'moderator'}) {
      $block .= sprintf $aliasfmt, '-moderator:', '-M';
      $vblock .= "$list-moderator\@$dom      $list$vut-moderator\n";
    }
    if (exists $args{'aliases'}->{'subscribe'}) {
      $block .= sprintf $aliasfmt, '-subscribe:', '-c subscribe';
      $vblock .= "$list-subscribe\@$dom      $list$vut-subscribe\n";
    }
    if (exists $args{'aliases'}->{'subscribe-digest'} and @{$args{'digests'}}) {
      $block .= sprintf $aliasfmt, '-subscribe-digest:', '-c subscribe --req setting=digest';
      $vblock .= "$list-subscribe-digest\@$dom    $list$vut-subscribe-digest\n";
    }
    if (exists $args{'aliases'}->{'subscribe-digest-all'} and @{$args{'digests'}}) {
      for my $i (@{$args{'digests'}}) {
        $block .= sprintf $aliasfmt, "-subscribe-digest-$i:", "-c subscribe --req setting=digest-$i";
        $vblock .= "$list-subscribe-digest-$i\@$dom    $list$vut-subscribe-digest-$i\n";
      }
    }
    if (exists $args{'aliases'}->{'subscribe-each'}) {
      $block .= sprintf $aliasfmt, '-subscribe-each:', '-c subscribe --req setting=each';
      $vblock .= "$list-subscribe-each\@$dom    $list$vut-subscribe-each\n";
    }
    if (exists $args{'aliases'}->{'subscribe-nomail'}) {
      $block .= sprintf $aliasfmt, '-subscribe-nomail:', '-c subscribe --req setting=nomail';
      $vblock .= "$list-subscribe-nomail\@$dom    $list$vut-subscribe-nomail\n";
    }
    if (exists $args{'aliases'}->{'unsubscribe'}) {
      $block .= sprintf $aliasfmt, '-unsubscribe:', '-c unsubscribe';
      $vblock .= "$list-unsubscribe\@$dom    $list$vut-unsubscribe\n";
    }

    if (exists $args{'aliases'}->{'auxiliary'} and @{$args{'sublists'}}) {
      for $sublist (@{$args{'sublists'}}) {
        next if ($sublist =~ /^(request|owner|subscribe|unsubscribe|moderator)$/);
        $block .= sprintf $aliasfmt, "-$sublist:", "-x $sublist";
        $vblock .= "$list-$sublist\@$dom    $list$vut-$sublist\n";
      }
    }

    $block .= "# End aliases for $list at $dom\n";
    $vblock .= "# End VUT entries for $list at $dom\n";
  }
  if ($args{aliashandle}) {
    $args{aliashandle}->print("$block\n");
    if ($args{vuthandle}) {
      $args{vuthandle}->print("$vblock\n");
    }
    return;
  }
  elsif ($args{aliasfile}) {
    umask (022 & $umask);
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
    umask (022 & $umask);
    $args{aliashandle} = new Mj::FileRepl($args{aliasfile});
    if ($args{options}{maintain_vut}) {
      $args{vuthandle} = new Mj::FileRepl($args{vutfile});
    }
  }

  # Sort the list of lists, for aesthetic purposes.
  for $i (sort {$a->{list} cmp $b->{list}} @{$args{lists}}) {
    $block = add_alias(%args, %{$i});
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

# This is the original qmail code by Russell Steinthal, but because we
# decided to use the .qmail-default system there is no real point to this
# any longer.  It may still be useful if some other method of qmail
# integration is desired.
# package Mj::MTAConfig::Qmail;
# use IO::File;
# use Mj::Log;
# sub add_alias {
#   my $log = new Log::In 150;
#   my %args = @_;
#   my($fn,$debug,$base,$file);
#   my $bin  = $args{bindir} or $log->abort("bindir not specified");
#   my $dom  = $args{domain} or $log->abort("domain not specified");
#   my $list = $args{list}   || 'GLOBAL';
#   my $who  = $args{whoami} || 'majordomo'; 
#   my $aliasdir = $args{aliasdir} or $log->abort("qmail aliasdir not specified");
#   my $domainprefix = "-$args{aliasprefix}" || ''; 

#   if ($args{debug}) {
#     $debug = " -v$args{debug}";
#   }
#   else {
#     $debug = '';
#   }

#   if ($list eq 'GLOBAL') {
#     $fn = "$aliasdir/.qmail$domainprefix" . "-$who";
#     my $file = new IO::File(">$fn");
#     $file->print("|$bin/mj_email -m -d $dom$debug\n");
#     $file->close;

#     $fn = "$aliasdir/.qmail$domainprefix" . "-$who" . "-owner";
#     $file = new IO::File(">$fn");
#     $file->print("|$bin/mj_email -o -d $dom$debug\n");
#     $file->close;

#     symlink($fn,"$aliasdir/.qmail$domainprefix"."-owner-$who");
#   }
#   else {
#     $fn = "$aliasdir/.qmail$domainprefix" . "-$list";
#     $file = new IO::File(">$fn");
#     $file->print("|$bin/mj_email -r -d $dom -l $list$debug\n");
#     $file->close;

#     $base = $fn;

#     $fn = $base . "-request";
#     $file = new IO::File(">$fn");
#     $file->print("|$bin/mj_email -q -d $dom -l $list$debug\n");
#     $file->close;

#     $fn = $base . "-owner";
#     $file = new IO::File(">$fn");
#     $file->print("|$bin/mj_email -o -d $dom -l $list$debug\n");
#     $file->close;

#     symlink($fn,"$aliasdir/.qmail$domainprefix"."owner-$list");
#   }

#   return "The appropriate alias files have been created in $aliasdir.\n";
# }

# sub del_alias {
#   my %args = @_;
#   my $list = $args{list};
#   my $log = new Log::In 150;
#   my $aliasdir = $args{aliasdir} or $log->abort("qmail aliasdir not specified");
#   my $domainprefix = "-$args{aliasprefix}" || '';

#   unlink "$aliasdir/.qmail$domainprefix" . "-$list";
#   unlink "$aliasdir/.qmail$domainprefix" . "-$list". "-owner";
#   unlink "$aliasdir/.qmail$domainprefix" . "-$list". "-request";
#   unlink "$aliasdir/.qmail$domainprefix" . "-owner-$list";
# }

# sub regen_aliases {
#   my %args = @_;
#   my($i,$block,$body);
#   for $i (@{$args{lists}}) {
#     $block = add_alias(%args,list => $i->[0],debug => $i->[1]);
#     $body .= "$block" if $block;
#   }
#   $body;
# }



=head1 COPYRIGHT

Copyright (c) 1997-1999 Jason Tibbitts for The Majordomo Development
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

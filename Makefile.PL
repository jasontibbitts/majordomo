use ExtUtils::MakeMaker "!prompt";
use File::Copy;
use strict;
$^W = 1;
$|  = 1;
use Carp;
use Config;
require "setup/query_util.pl";
require "setup/ask_basic.pl";
require "setup/setup_func.pl";

BEGIN {
  require 5.00401;
}

# A version variable we can use to force users to reconfigure when we add
# new questions.
my $config_version = 13;
my (@SIDSCRIPTS, @SCRIPTS, @EXES, $ok);
use vars qw(%have $lang);
$lang = ask_lang();

# Convert module file names to man page names.
my %MODULES = 
  map { my $a;
        # substitute two colons for a slash 
        ($a = $_) =~ s!/!::!g; 
        # remove ".pm" from each module name
        $a =~ s/\.p.$//; 
        ("lib/$_" => "\$(INST_MAN3DIR)/$a.\$(MAN3EXT)")
      }

   qw(Majordomo.pm Mj/Access.pm Mj/Addr.pm Mj/AddressList.pm
      Mj/AliasList.pm Mj/Archive.pm Mj/BounceHandler.pm Mj/BounceParser.pm
      Mj/Config.pm Mj/Deliver.pm Mj/Deliver/BSMTPEnvelope.pm
      Mj/Deliver/Connection.pm Mj/Deliver/Dest.pm Mj/Deliver/Envelope.pm
      Mj/Deliver/Prober.pm Mj/Deliver/QQEnvelope.pm Mj/Deliver/SMTP.pm
      Mj/Deliver/Sorter.pm Mj/Digest.pm Mj/Digest/Build.pm
      Mj/Digest/Index.pm Mj/Digest/MIME.pm Mj/Digest/Text.pm Mj/FakeLog.pm
      Mj/File.pm Mj/FileRepl.pm Mj/FileSpace.pm Mj/Format.pm Mj/Inform.pm
      Mj/List.pm Mj/Lock.pm Mj/Log.pm Mj/MailOut.pm Mj/MIMEParser.pm
      Mj/Parser.pm Mj/Resend.pm Mj/SimpleDB.pm Mj/SimpleDB/DB.pm
      Mj/SimpleDB/Text.pm Mj/SubscriberList.pm Mj/Token.pm Mj/TokenDB.pm
      Mj/Util.pm Bf/Sender.pm mj_cf_data.pl mj_cf_defs.pl );

get_str(retr_msg('check_modules', $lang));

#### Prerequisite checking
($ok, %have) = check_prereq
  (
   'Mail::Internet' => [1.30,  1],
   'Mail::Header'   => [1.10,  1],
   'MIME::Base64'   => [2.00,  1],
   'IO::Wrap'       => [1.101, 1],
   'MIME::Tools'    => [4.119, 1],
   'Data::Dumper'   => [2.07,  1],
   'Date::Manip'    => [5.10 , 1],
   'CGI'            => [2.36,  1],
   'Digest::SHA1'   => [0,     1],
   'Socket'         => [0,     1],
   'IO::File'       => [0,     1],
   'IO::Handle'	    => [0,     1],
   'Date::Format'   => [2.20,  1],
   'Date::Parse'    => [0,     1],
   'DirHandle'      => [0,     1],
   'Safe'           => [0,     1],
   'POSIX'          => [0,     1],
   'Net::Domain'    => [0,     1],
   'File::Basename' => [0,     1],
   'File::Copy'     => [0,     1],
   'Fcntl'          => [0,     1],
   'Carp'      	    => [0,     1],
   'Time::Local'    => [0,     1],
   'HTML::FormatText'  => [0,  1],
   'HTML::TreeBuilder' => [0,  1],
   'Text::Reflow'   => [1.04,  0],
   'Time::HiRes'    => [0,     0],
   'DB_File'        => [1.63,  0],
   'DBI'            => [1.28,  0],
   'DBD::Pg'        => [1.13,  0],
   'DBD::mysql'     => [2.1010,  0],
  );

unless (check_syslog() && $ok) {
  exit(1);
}

#### Interactive configuration
my $config = configure();

# Now we can set these up based on what we got from configure.
if ($config->{mta} eq 'sendmail') {
  @SIDSCRIPTS = qw(mj_email mj_enqueue mj_shell mj_confirm
                   mj_shutdown mj_wwwadm mj_wwwusr);
  @SCRIPTS = qw(mj_trigger mj_queueserv mj_queuerun mj_setup);
}
else {
  @SIDSCRIPTS = qw(mj_shell mj_confirm mj_shutdown mj_wwwadm mj_wwwusr);
  @SCRIPTS = qw(mj_email mj_enqueue mj_trigger mj_queueserv mj_queuerun
                mj_setup);
}

@EXES = map {" ./bin/$_"} @SIDSCRIPTS, @SCRIPTS;

my $prefix = $config->{'install_dir'};

#### Build the wrapper binaries if necessary

if ($config->{'wrappers'}) {
  generate_wrappers();
}

#### Override the installbin target
sub MY::installbin {
  package MY;
  my $str = shift->SUPER::installbin(@_);
  $str =~ s/^\tcp\s/\t\$(PERL) installbin /mg;
  return $str;
}

#### The makefile postamble.  This differs depending on what options the
#### user has chosen; we add rules to build the wrappers if necessary.  We
#### also add the postinstall target and some extra cleanup rules.
sub MY::postamble {
  my $a = '';

  if ($config->{'wrappers'}) {
    $a .= '

all :: wrappers

clean ::
	$(RM_RF) wrappers
';
    for my $i (@SIDSCRIPTS) {
      $a .= "\t\$(RM_F) ./bin/.$i\n";
    }

    $a .= 'wrappers :';
    for my $i (@SIDSCRIPTS) {
      $a .= " wrappers/$i";
    }

    $a .= "\n";

#    for my $i (@SIDSCRIPTS) {
#      $a .= "\t\$(CC) -o wrappers/$i wrappers/$i.c\n";
#      $a .= "\tstrip wrappers/$i\n";
#    }
  }

  $a .= '

domain ::
	$(PERL) -w setup/newdomain.pl

siteconfig ::
	$(PERL) -w setup/siteconfig.pl

install :: postinstall
postinstall ::
	$(PERL) -w postinstall
';

  $a;
}

#### Write out the Makefile
print "\n";
WriteMakefile
  (
   NAME           => 'Majordomo',
   VERSION_FROM   => './lib/Majordomo.pm',
   DISTNAME       => "Majordomo",
   EXE_FILES      => [@EXES],
   INSTALLDIRS    => 'perl',
   PREFIX         => $prefix,
   INSTALLSCRIPT  => '$(PREFIX)/bin',
   INSTALLPRIVLIB => '$(PREFIX)/lib',
   MAN1PODS       => {map {("bin/$_"=>"\$(INST_MAN1DIR)/$_.\$(MAN1EXT)")} @SIDSCRIPTS, @SCRIPTS},
   INSTALLMAN1DIR => '$(PREFIX)/man/man1',
   MAN3PODS       => \%MODULES,
   INSTALLMAN3DIR => '$(PREFIX)/man/man3',
   'dist'         => {
		      COMPRESS => 'gzip',
		      DIST_CP  => 'cp',
		      SUFFIX   => 'gz',
		     }
  );


&check_nr_install;

print retr_msg('run_make', $lang, 'INSTALL_DIR' => 
               $config->{'install_dir'});

exit;

#### Subroutines

use File::Basename;
sub check_nr_install {
  my (@dirstat, @grent, @pwent, @tmp, $dir, $dirg, $dirm, $diru,
      $g, $i, $major, $ok, $u);

  print retr_msg('non_root', $lang, 'UID' => $config->{'uid'});

  # Does the uid exist?
  @pwent = getpwnam($config->{'uid'});
  $u = $pwent[2];
  $g = $pwent[3];
  $major = ($u == $<);
  unless (@pwent) {
    print retr_msg('no_user', $lang, 'UID' => $config->{'uid'});
    return;
  }

  # Does the gid exist?
  @grent = getgrnam($config->{'gid'});
  unless (@grent) {
    print retr_msg('no_group', $lang, 'GID' => $config->{'gid'});
    return;
  }

  # Is the user in the group?
  @tmp = split " ", $grent[3];
  unless ((grep { $_ eq $config->{'uid'} } @tmp) or $g == $grent[2]) {
    print retr_msg('user_group_mismatch', $lang, 'UID' => $config->{'uid'}, 
                   'GID' => $config->{'gid'});
    return;
  }

  # Do the installation directories exist, and are they writable
DIR:
  for $i (qw(install_dir lists_dir tmpdir wtmpdir cgi_bin)) {
    next unless (defined $config->{$i});
    $dir = $config->{$i};
    while (! -d $dir) {
      if ($! =~ /Permission denied/) {
        if ($major) {
          print retr_msg('unwritable_dir', $lang, 'UID' => $config->{'uid'}, 
                         'DIRECTORY' => $dir);
        }
        else {
          print retr_msg('perm_unknown', $lang, 'UID' => $config->{'uid'}, 
                         'DIRECTORY' => $dir);
        }
        next DIR;
      }
      last unless (length $dir and $dir ne '/');
      $dir = File::Basename::dirname($dir);
    }

    next unless (-d $dir);
    # Stat the dir. Does it have user or group permissions that would
    # allow the majordomo user to install directories under it?

    @dirstat = stat $dir;
    $dirg = $dirstat[5];
    $diru = $dirstat[4];
    $dirm = $dirstat[2];
    if ((($dirm & 0700) == 0700) and ($diru == $u)) {
      # print qq(+ $dir is user-accessible, okay.\n);
      next;
    }
    if (($dirm & 070) == 070) {
      @dirstat = getgrgid($dirg);
      @tmp = split " ", $dirstat[3];
      if (grep { $_ eq $config->{'gid'} } @tmp) {
        # print qq(+ $dir is group-accessible, okay.\n);
        next;
      }
    }
    if (($dirm & 07) == 07) {
      # print qq(+ $dir is world-accessible, okay.\n);
      next;
    }
    print retr_msg('unwritable_dir', $lang, 'UID' => $config->{'uid'}, 
                   'DIRECTORY' => $dir);
  }
}

sub check_syslog {
  print "Checking for Sys::Syslog and headers     ";
  eval {require Sys::Syslog;};
  if ($@) {
    warn retr_msg('syslog_error', $lang, 'ERROR' => $@);
    return 0;
  }
  print "ok\n";
  1;
}

sub check_prereq {
  my (%have, @mods_needed, $i, $need, $ok, $pkg, $ver);
  $ok = 1;

  while (($pkg, $ver) = splice(@_, 0, 2)) {
    ($ver, $need) = ($ver->[0], $ver->[1]);
    if (have_vers($pkg => $ver)) {
      $have{$pkg} = 1;
    }
    else {
      if ($need) {
        $ok = 0;
        push @mods_needed, $pkg;
        if ($ver == 0) {
          warn retr_msg('version_any', $lang, 'MODULE' => $pkg);
        }
        else {
          warn retr_msg('version_needed', $lang, 'MODULE' => $pkg,
                        'VERSION' => $ver);
        }
      }
    }
  }
  if (@mods_needed) {
    print retr_msg('missing_modules', $lang);

    for $i (@mods_needed) {
      print "perl -MCPAN -e'CPAN::Shell->install(\"$i\")'\n";
    }
    print "\n";
  }

  ($ok, %have);
}

# This was originally clipped from the libnet Makefile.PL.
sub have_vers {
  my($pkg, $wanted, $msg, $vnum, $vstr) = @_;
  no strict 'refs';
  printf("Checking for %17s %-9s ", $pkg, $wanted==0?'(any)':"(v$wanted)");

  eval { my $p; ($p = $pkg . ".pm") =~ s!::!/!g; require $p; };

  $vnum = ${"${pkg}::VERSION"} || ${"${pkg}::Version"} || 0;
  $vnum = -1 if $@;

  if ($vnum < 0) {
    $vstr = "not found";
  }
  elsif ($vnum > 0) {
    $vstr = "found v$vnum";
  }
  else {
    $vstr = "found unknown version";
  }

  print (($vnum >= $wanted ? "ok: " : " "), "$vstr\n");
  $vnum >= $wanted;
}

sub configure {
  my ($i, $key, $val, $msg, $def);
  require Data::Dumper; import Data::Dumper 'Dumper';

  # Pull in an existing configuration.
  print "Checking for       Net::Config";
  eval {require Net::Config};
  print ' 'x11 . "done, status not checked\n";

  print "Checking for        .mj_config";
  $config = eval { require ".mj_config" };

  if (defined $config) { 
    print ' 'x11 . "found.\n"; 
  }
  else { 
    print ' 'x11 . "missing.\n"; 
  }

  get_str(retr_msg('begin', $lang));

  if (defined $config &&
      defined $config->{version} &&
      $config->{version} >= $config_version)
  {
      print retr_msg('mj_config_head', $lang);
      printhash($config);
      $msg = retr_msg('mj_config_foot', $lang);
      return $config unless get_bool($msg, 0);
  }
  elsif ($config) {
    get_str(retr_msg('mj_config_update', $lang));
  }
  else {
    $config = {};
  }
  get_str(retr_msg('welcome', $lang));

  ask_basic($config);

  $config->{version} = $config_version;

  #---- Save the configuration information in a file.
  save_mj_config($config);
  return $config;
}

# Recursively print out a hash.
# Assumes that longest key is 25 chars or less. 
# It cannot find the maximum length without recursing twice.
sub printhash {
  my $arg = shift;
  my $indent = shift || 0;
  my($key, $msg, $val);
  my $len = 25; # line up '=>' with spaces assuming this is longest key
  my $tab =  8; # indent nested hashes by this many spaces
  for $key (sort keys %$arg) {
    $val = $arg->{$key};
    if (UNIVERSAL::isa($val, 'ARRAY')) {
      $msg = join(', ', @{$val});
    }
    elsif (UNIVERSAL::isa($val, 'HASH')) {
      print " "x($tab * $indent);
      print ' 'x($len - length($key)), $key, " => ...\n";
      printhash($val, $indent+1);
      next;
    }
    else {
      $msg = $val;
    }
    print " "x($tab * $indent);
    print ' 'x($len - length($key)), $key, " => $msg\n";
  }
}

# Make the wrapper source files.  The make step will compile them.  Note
# that we nuke the EXES array and build a new one, and that we make extra
# copies of the real scripts because MakeMaker isn't quite as flexible as
# I'd like.  XXX This could probably use some error checking.
sub generate_wrappers {
  print retr_msg('build_wrappers', $lang);
  @EXES = ();

  unless (-d 'wrappers') {
    mkdir('wrappers', 0777) || die("Cannot create wrappers directory: $!");
  }

  for my $i (@SIDSCRIPTS) {
    if (-f "./bin/.$i") {
      unlink "./bin/.$i" || die("Unable to unlink bin/.$i: $!");
    }
    link("./bin/$i", "./bin/.$i")
      || die("Unable to create link for bin/.$i: $!");
    open(WRAP, ">wrappers/$i.c") || die("Cannot create wrappers/$i.c: $!");
    print WRAP "#include <unistd.h>
int main(int ac, char ** av)
{
  return execv(\"$config->{'install_dir'}/bin/.$i\", av);
}
";
    close WRAP;
    push @EXES, " ./bin/.$i";
    push @EXES, " ./wrappers/$i";
    push @EXES, map {" ./bin/$_"} @SCRIPTS;
  }
  print "ok.\n";
}

=head1 COPYRIGHT

Copyright (c) 1997, 1998, 2002, 2003 Jason Tibbitts for The Majordomo 
Development Group.  All rights reserved.

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

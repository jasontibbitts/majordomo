use ExtUtils::MakeMaker "!prompt";
use File::Copy;
use strict;
$^W = 1;
$|  = 1;
use Carp;
use Config;
require "setup/query_util.pl";

BEGIN {
  require 5.00401;
}

# A version variable we can use to force users to reconfigure when we add
# new questions.
my $config_version = 10;
my(@SIDSCRIPTS, @SCRIPTS, @EXES, $ok);
use vars qw(%have);

# MakeMaker has begun to displease me
my %MODULES = map {my $a; ($a=$_)=~s!/!::!g; $a=~s/\.p.$//; ("lib/$_" => "\$(INST_MAN3DIR)/$a.\$(MAN3EXT)")}

   qw(Majordomo.pm Mj/Access.pm Mj/Addr.pm Mj/AddressList.pm
      Mj/AliasList.pm Mj/Archive.pm Mj/BounceParser.pm Mj/Config.pm
      Mj/Deliver.pm Mj/Deliver/Connection.pm Mj/Deliver/Dest.pm
      Mj/Deliver/Envelope.pm Mj/Deliver/Prober.pm Mj/Deliver/QQEnvelope.pm
      Mj/Deliver/SMTP.pm Mj/Deliver/Sorter.pm Mj/Digest.pm
      Mj/Digest/Build.pm Mj/Digest/Index.pm Mj/Digest/MIME.pm
      Mj/Digest/Text.pm Mj/FakeLog.pm Mj/File.pm Mj/FileRepl.pm
      Mj/FileSpace.pm Mj/Format.pm Mj/Inform.pm Mj/List.pm Mj/Lock.pm
      Mj/Log.pm Mj/MailOut.pm Mj/MIMEParser.pm Mj/Parser.pm Mj/Resend.pm
      Mj/SimpleDB.pm Mj/SimpleDB/DB.pm Mj/SimpleDB/Text.pm
      Mj/SubscriberList.pm Mj/TextOutput.pm Mj/Token.pm Mj/TokenDB.pm
      Bf/Sender.pm mj_cf_data.pl mj_cf_defs.pl );

#### Prerequisite checking
($ok, %have) = check_prereq
  (
   'Mail::Internet' => [1.30,  1],
   'Mail::Header'   => [1.10,  1],
   'MIME::Base64'   => [2.00,  1],
   'IO::Wrap'       => [1.101, 1],
   'MIME::Tools'    => [4.119, 1],
   'Data::Dumper'   => [2.07,  1],
   #	     'Data::ShowTable'  => 0,  # Want 3.3, but the stupid module
   # doesn't have a version number
   'Date::Manip'    => [5.10 , 1],
   'CGI'            => [2.36,  1],
   'MD5'            => [1.7,   1],
   'IO::Socket'     => [1.1602,1],
   'IO::File'       => [0,     1],
   'IO::Handle'	    => [0,     1],
   'Date::Format'   => [0,     1],
   'DirHandle'      => [0,     1],
   'Safe'           => [0,     1],
   'POSIX'          => [0,     1],
   'Net::Domain'    => [0,     1],
   'File::Copy'     => [0,     1],
   'Fcntl'          => [0,     1],
   'Carp'      	    => [0,     1],
   'Time::Local'    => [0,     1],
   'DB_File'        => [1.63,  0],
  );

unless (check_syslog() && $ok) {
  print "Majordomo cannot run without its prerequisite modules.\n";
  exit(1);
}

#### Interactive configuration
my $config = configure();

# Now we can set these up based on what we got from configure.
if ($config->{mta} eq 'sendmail') {
  @SIDSCRIPTS = qw(mj_email mj_enqueue mj_shell mj_confirm 
                   mj_shutdown mj_wwwadm mj_wwwusr);
  @SCRIPTS = qw(mj_trigger mj_queueserv mj_queuerun);
}
else {
  @SIDSCRIPTS = qw(mj_shell mj_confirm mj_shutdown mj_wwwadm mj_wwwusr);
  @SCRIPTS = qw(mj_email mj_enqueue mj_trigger mj_queueserv mj_queuerun);
}
@EXES = map {"./bin/$_"} @SIDSCRIPTS, @SCRIPTS;

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
   INSTALLPRIVLIB => "$prefix/lib",
   MAN1PODS       => {map {("bin/$_"=>"\$(INST_MAN1DIR)/$_.\$(MAN1EXT)")} @SIDSCRIPTS, @SCRIPTS},
   INSTALLMAN1DIR => "$prefix/man/man1",
   MAN3PODS       => \%MODULES,
   INSTALLMAN3DIR => "$prefix/man/man3",
   'dist'         => {
		      COMPRESS => 'gzip',
		      DIST_CP  => 'cp',
		      SUFFIX   => 'gz',
		     }
  );


print <<EOM;

Now you should do the following:
  make (expect several warnings about truncation to 8 characters)
  make test (if you wish to run the paltry tests)
  make install (as root) and answer any questions that appear

EOM

exit;

#### Subroutines

sub check_syslog {
  my ($failed) = "the Sys::Syslog module";
  print "Checking for Sys::Syslog and headers   ";
  eval {require Sys::Syslog;};
  if ($@) {
    warn <<EOW;

**** Majordomo needs a properly configured Perl system.

We tried to use $failed, but it failed with the following error:

$@

Errors here are generally problems with the Perl installation.  Sys::Syslog
requires the file syslog.ph, which is supposed to be generated by running
the h2ph program.  If syslog.ph was not found, it can be 
generated by executing the following as root:

  cd /usr/include;h2ph * sys/*

Some machines may additionally require

  h2ph machine/*

and possibly other directories.

If there was a syntax error, it is possible that h2ph generated improper
code.  This should be investigated and possibly reported to the perl
developers.

Consult the Perl documentation for further information.  Majordomo will not
run until this is fixed.

EOW
    return 0;
  }
  print "ok\n";
  1;
}
      
sub check_prereq {
  my (%have, @mods_needed, $need, $pkg, $ver, $ok);
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
          warn <<EOW;
**** Majordomo requires $pkg (any version).
EOW
        }
        else {
          warn <<EOW;
**** Majordomo requires $pkg version $ver or greater!
EOW
        }
      }
    }
  }
  if (@mods_needed) {
    print <<EOP;

Some modules which Majordomo requires were not found.  You should fetch
them from a CPAN site of your choice, or, if the CPAN module is properly
set up, you can install them by running the following commands as a user
capable of installing modules:

EOP
    for my $i (@mods_needed) {
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
  printf("Checking for %15s %-9s ", $pkg, $wanted==0?'(any)':"(v$wanted)");

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
  print "Checking for     Net::Config";
  eval {require Net::Config};
  print ' 'x11 . "ok\n";

  print "Checking for      .mj_config";
  $config = eval { require ".mj_config" };
  print ' 'x11 . "ok\n";

  get_str("\nReady to configure; press enter");

  if (defined $config &&
      defined $config->{version} &&
      $config->{version} >= $config_version)
    {
      print "\nFound existing configuration:\n";
      printhash($config);
      $msg = "Do you want to modify your configuration?\n";
      return $config unless get_bool($msg, 0);
    }
  elsif ($config) {
    print "\nFound existing configuration, but it is out of date.\n";
  }
  else {
    $config = {};
  }
  print <<EOM;

Welcome to the Majordomo automatic configuration system!

This script will guide you through some of the Majordomo configuration
process.  Of course, it isn\'t finished....
EOM
  require "setup/ask_basic.pl";
  ask_basic($config);

  $config->{version} = $config_version;
  #---- Write out the config
  print "\n";
  open(CONFIG, ">.mj_config") || die("Can't create .mj_config: $!");
  print CONFIG Dumper($config);
  close CONFIG;
  if ($config->{save_passwords}) {
    chmod(0600, '.mj_config');
  }
  return $config;
}

# Recursively print out a hash
sub printhash {
  my $arg = shift;
  my $indent = shift || 0;
  my($key, $msg, $val);
  for $key (sort keys %$arg) {
    $val = $arg->{$key};
    if (UNIVERSAL::isa($val, 'ARRAY')) {
      $msg = join(', ', @{$val});
    }
    elsif (UNIVERSAL::isa($val, 'HASH')) {
      print "    "x$indent;
      printf ("%20s => ...\n", $key);
      printhash($val, $indent+1);
      next;
    }
    else {
      $msg = $val;
    }
    print "    "x$indent;
    printf ("%20s => %s\n", $key, $msg);
  }
}

# Make the wrapper source files.  The make step will compile them.  Note
# that we nuke the EXES array and build a new one, and that we make extra
# copies of the real scripts because MakeMaker isn't quite as flexible as
# I'd like.  XXX This could probably use some error checking.
sub generate_wrappers {
  print "\nGenerating the wrappers...";
  @EXES = ();

  unless (-d 'wrappers') {
    mkdir('wrappers', 0777) || die("Can't create wrappers dir: $!");
  }

  for my $i (@SIDSCRIPTS) {
    link("./bin/$i", "./bin/.$i");
    open(WRAP, ">wrappers/$i.c") || die("Can't create wrappers/$i.c: $!");
    print WRAP "main(ac, av)
    char **av;
{
  execv(\"$config->{'install_dir'}/bin/.$i\", av);
}
";
    close WRAP;
    push @EXES, "./bin/.$i";
    push @EXES, "./wrappers/$i";
    push @EXES, map {"./bin/$_"} @SCRIPTS;
  }
  print "done.\n";
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
### cperl-indent-level:2 ***
### cperl-label-offset:-1 ***
### indent-tabs-mode: nil ***
### End: ***

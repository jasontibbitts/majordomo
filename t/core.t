# Test Majordomo by calling core routines.
use lib "blib/lib";
use Carp qw(cluck);
use Data::Dumper;
use File::Copy 'copy';

$SIG{__WARN__} = sub {cluck "--== $_[0]"};

$| = 1;
$counter = 1;
$debug = 0;
$tmpdir = "/tmp/mjtest.$$";

$::LIBDIR = '.'; $::LIBDIR = '.'; # Nasty hack until config stuff is done

print "1..38\n";

print "Load the stashed configuration\n";
eval('$config = require ".mj_config"');
$a = $config;
undef $a;     # Quiet 'used only once' warning.
ok(1, !$@);

# Create the directory structure we need
mkdir "$tmpdir", 0700 || die;
mkdir "$tmpdir/locks", 0700 || die;
mkdir "$tmpdir/SITE", 0700 || die;
mkdir "$tmpdir/SITE/files", 0700 || die;
mkdir "$tmpdir/SITE/files/en", 0700 || die;
mkdir "$tmpdir/SITE/files/en/error", 0700 || die;
mkdir "$tmpdir/SITE/files/en/config", 0700 || die;

open FILE, ">$tmpdir/SITE/files/INDEX.pl";
print FILE "\$files = {}; \$dirs = []; [\$files, \$dirs];\n";
close FILE;

open FILE, ">$tmpdir/SITE/files/en/config/whereami";
print FILE "placeholder for whereami\n";
close FILE;

open FILE, ">$tmpdir/SITE/files/en/error/taboo_body";
print FILE "placeholder for taboo error\n";
close FILE;

mkdir "$tmpdir/test", 0700 || die;
mkdir "$tmpdir/test/GLOBAL", 0700 || die;
mkdir "$tmpdir/test/DEFAULT", 0700 || die;
mkdir "$tmpdir/test/GLOBAL/files", 0700 || die;
mkdir "$tmpdir/test/GLOBAL/sessions", 0700 || die;
mkdir "$tmpdir/test/GLOBAL/spool", 0700 || die;
copy  "t/global_config", "$tmpdir/test/GLOBAL/C_install" || die;
copy  "t/default_config", "$tmpdir/test/DEFAULT/C_install" || die;
$post1   = "$tmpdir/test/GLOBAL/spool/post_1";
copy  "t/post_1", $post1 || die;

open SITE,">$tmpdir/SITE/config.pl";
print SITE qq!
\$VAR1 = {
          'mta'           => '$config->{mta}',
          'mta_separator' => '$config->{mta_separator}',
          'cgi_bin'       => '$config->{cgi_bin}',
          'install_dir'   => '$config->{install_dir}',
          'site_password' => 'hurl',
	  'database_backend' => '$config->{database_backend}',
        };
!;
close SITE;

# Set up variables that need to be set; avoid warnings
$LOCKDIR = $::LOCKDIR = "$tmpdir/locks";
$TMPDIR = $::TMPDIR = "$tmpdir/locks";

print "Load the module\n";
eval "require Majordomo";
ok(1, !$@);

print "Load the logging module\n";
eval "require Mj::Log";
ok(1, !$@);

# Open a log
$::log = new Mj::Log;

if ($debug) {
  $::log->add(method      => 'handle',
	      id          => 'test',
	      handle      => \*STDERR,
	      level       => 5000,
	      subsystem   => 'mail',
	      log_entries => 1,
	      log_exits   => 1,
	      log_args    => 1,
	     );
}

print "Allocate a Majordomo object\n";
$mj = new Majordomo "$tmpdir", 'test';
ok(1, !!$mj);

print "Connect to it\n";
$ok = $mj->connect('testsuite', "Testing, pid $$\n",
                   'core_test@example.com');
ok(1, !!$ok);

print "Use the site password to set the domain's master password.\nScrew it up once just to check.\n";
$request = {password => 'badpass',
	    command  => 'configset',
	    list     => 'GLOBAL',
	    setting  => 'master_password',
	    value    => ['gonzo'],
	   };

$result = $mj->dispatch($request);
ok(0, $result->[0]);

print "Now use the proper password\n";
$request->{password} = 'hurl';
$result = $mj->dispatch($request);
ok(1, $result->[0]);

print "Set whereami\n";
$request->{password} = 'gonzo';
$request->{setting}  = 'whereami';
$request->{value}    = ['example.com'];
$result = $mj->dispatch($request);
ok(1, $result->[0]);

print "Set tmpdir\n";
$request->{password} = 'gonzo';
$request->{setting}  = 'tmpdir';
$request->{value}    = [$tmpdir];
$result = $mj->dispatch($request);
ok(1, $result->[0]);

print "Make sure whereami got set\n";
$request->{command}  = 'configshow';
$request->{groups}   = ['whereami'];
$result = $mj->dispatch($request);
ok('example.com', $result->[1][4]);

print "Set GLOBAL inform so we don't send any mail from owner synchronization\n";
$result = $mj->dispatch({user     => 'core_test@example.com',
			 password => 'hurl',
			 command  => 'configset',
			 list     => 'GLOBAL',
			 setting  => 'inform',
			 value    => ['subscribe   : all : ignore',
				      'unsubscribe : all : ignore'],
			 });
ok(1, $result->[0]);

print "Create a list\n";
$result = $mj->dispatch({user     => 'core_test@example.com',
			 password => 'gonzo',
			 command  => 'createlist',
			 mode     => 'nowelcome',
			 newlist  => 'bleeargh',
			 victims  => ['nobody@example.com']});
ok(1, $result->[0]);

print "Make sure the list was created\n";
$result = $mj->dispatch({user     => 'core_test@example.com',
			 command  => 'lists'});
ok('bleeargh', $result->[1]{list});

print "Set inform so we don't send any mail\n";
$result = $mj->dispatch({user     => 'core_test@example.com',
			 password => 'gonzo',
			 command  => 'configset',
			 list     => 'bleeargh',
			 setting  => 'inform',
			 value    => ['subscribe   : all : ignore',
				      'unsubscribe : all : ignore'],
			 });
ok(1, $result->[0]);

print "Set up some transforms\n";
$result = $mj->dispatch({user     => 'core_test@example.com',
			 password => 'gonzo',
			 command  => 'configset',
			 list     => 'GLOBAL',
			 setting  => 'addr_xforms',
			 value    => ['trim mbox',
				      'ignore case',
				      'map example.net to example.com',
				      'two level',
				     ],
			});
ok(1, $result->[0]);

print "Subscribe an address\n";
$result = $mj->dispatch({user     => 'core_test@example.com',
			 password => 'gonzo',
			 command  => 'subscribe',
			 mode     => 'quiet-nowelcome',
			 list     => 'bleeargh',
			 victims  => ['Frobozz <ZoRk+infocom@Trinity.Example.NET>'],
			});
ok(1, $result->[0]);

print "Make sure the subscribe worked\n";
$request = {user     => 'core_test@example.com',
	    password => 'gonzo',
	    command  => 'who_start',
	    list     => 'bleeargh',
	   };
$result = $mj->dispatch($request);

ok(1, $result->[0]);

$request->{command} = 'who_chunk';
$result = $mj->dispatch($request, 1000);

ok(1, $result->[0]);
ok('Frobozz <ZoRk+infocom@Trinity.Example.NET>',$result->[1]{fulladdr});
ok('ZoRk+infocom@trinity.example.net',          $result->[1]{stripaddr});
ok('zork@example.com',                          $result->[1]{canon});

$request->{command} = 'who_done';
$result = $mj->dispatch($request);
ok(1, $result->[0]);

print "Add an address to a sublist\n";
$result = $mj->dispatch({user     => 'core_test@example.com',
			 password => 'gonzo',
			 command  => 'subscribe',
			 mode     => 'quiet-nowelcome',
			 list     => 'bleeargh:harumph',
			 victims  => ['deadline@example.com'],
			});
ok(1, $result->[0]);

print "Make sure it worked\n";
$request = {user     => 'core_test@example.com',
	    password => 'gonzo',
	    command  => 'who_start',
	    list     => 'bleeargh:harumph',
	   };
$result = $mj->dispatch($request);
ok(1, $result->[0]);

$request->{command} = 'who_chunk';
$result = $mj->dispatch($request, 1000);
ok(1, $result->[0]);
ok('deadline@example.com', $result->[1]{fulladdr});

$request->{command} = 'who_done';
$result = $mj->dispatch($request);
ok(1, $result->[0]);

print "Add an alias\n";
$result = $mj->dispatch({user     => 'zork@example.com',
			 password => 'gonzo',
			 command  => 'alias',
			 newaddress=> 'enchanter@example.com',
			});
ok(1, $result->[0]);

print "Add an alias to the first alias\n";
$result = $mj->dispatch({user     => 'enchanter@example.com',
			 password => 'gonzo',
			 command  => 'alias',
			 newaddress=> 'planetfall@example.com',
			});
ok(1, $result->[0]);

print "Set a password\n";
$result = $mj->dispatch({user     => 'enchanter@example.com',
			 password => 'gonzo',
			 command  => 'password',
			 mode     => 'quiet',
			 newpasswd=> 'suspect',
			});
ok(1, $result->[0]);

print "Change the settings of the user using the user's password\n";
$result = $mj->dispatch({user     => 'enchanter@example.com',
			 password => 'suspect',
			 command  => 'set',
			 list     => 'bleeargh',
                         setting  => 'unique',
			});
ok(1, $result->[0]);

print "Check the address using the which command.\n";
$result = $mj->dispatch({user     => 'enchanter@example.com',
			 password => 'suspect',
			 command  => 'which',
			 regexp   => '',
			});
ok(1, $result->[0]);

print "Unsubscribe the (doubly) aliased address using the password\n";
$result = $mj->dispatch({user     => 'core_test@example.com',
			 password => 'suspect',
			 command  => 'unsubscribe',
			 list     => 'bleeargh',
			 victims  => ['planetfall@example.com'],
			});
ok(1, $result->[0]);


print "Remove the second alias from the canonical address\n";
$result = $mj->dispatch({user     => 'zork@example.com',
			 password => 'suspect',
			 command  => 'unalias',
			 victims  => ['planetfall@example.com'],
			});
ok(1, $result->[0]);

print "Change the address using the remaining alias.\n";
$result = $mj->dispatch({user     => 'xyz@example.com',
			 password => 'gonzo',
			 command  => 'changeaddr',
			 victims  => ['enchanter@example.com'],
			});
ok(1, $result->[0]);

print "Unregister the address using the remaining alias.\n";
$result = $mj->dispatch({user     => 'enchanter@example.com',
			 password => 'suspect',
			 command  => 'unregister',
			});
ok(1, $result->[0]);

print "Turn off administrivia.\n";
$result = $mj->dispatch({user     => 'core_test@example.com',
			 password => 'gonzo',
			 command  => 'configset',
			 list     => 'bleeargh',
			 setting  => 'administrivia',
			 value    => ['no'],
			});
ok(1, $result->[0]);

print "Post a complete message.\n";
$result = $mj->dispatch({user     => 'core_test@example.com',
                         command  => 'post',
			 list     => 'bleeargh',
                         file     => $post1,
                         mode     => '',
                         password => '',
                         sublist  => '',
                        });
ok(1, $result->[0]);

# Things left to test:

# access_rules

# show

# posting?  Allow addresses to be set, mail will be sent to them, which can
# be stored in a file and examimed for proper content?

# bounce processing?  parsing is already done, but no tests on actual
# handling of bounces.

# ???




undef $mj;
exit 0;

sub ok {
  my $expected = shift;
  my $result   = shift;
  if ($result eq $expected) {
    print "ok $counter\n";
  }
  else {
    print "not ok $counter\n";
  }
  chomp $result;
#  print STDERR "$result\n" if $verbose > 1;
  $counter++;
}

END {
  system("/bin/rm -rf $tmpdir");
}

#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

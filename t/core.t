# Test Majordomo by calling core routines.
$debug = 0;
$tmpdir = "/tmp/mjtest.$$";

use lib "blib/lib";
use Carp qw(cluck);
$SIG{__WARN__} = sub {cluck "--== $_[0]"};

print "1..12\n";

$| = 1;
$counter = 1;

# 1 - Load the stashed configuration
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
mkdir "$tmpdir/SITE/files/en/config", 0700 || die;

open FILE, ">$tmpdir/SITE/files/INDEX.pl";
print FILE "\$files = {}; \$dirs = []; [\$files, \$dirs];\n";
close FILE;

open FILE, ">$tmpdir/SITE/files/en/config/whereami";
print FILE "placeholder for whereami\n";
close FILE;


mkdir "$tmpdir/test", 0700 || die;
mkdir "$tmpdir/test/GLOBAL", 0700 || die;
mkdir "$tmpdir/test/DEFAULT", 0700 || die;
mkdir "$tmpdir/test/GLOBAL/files", 0700 || die;
mkdir "$tmpdir/test/GLOBAL/sessions", 0700 || die;


open SITE,">$tmpdir/SITE/config.pl";
print SITE qq!
\$VAR1 = {
          'mta'           => '$config->{mta}',
          'cgi_bin'       => '$config->{cgi_bin}',
          'install_dir'   => '$config->{install_dir}',
          'site_password' => 'hurl',
	  'database_backend' => '$config->{database_backend}',
        };
!;
close SITE;

# Set up variables that need to be set; avoid warnings
$::LOCKDIR = $::LOCKDIR = "$tmpdir/locks";

#2 - Load the module
eval "require Majordomo";
ok(1, !$@);

#3 - Load the logging module
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

#4 - Allocate a Majordomo object
$mj = new Majordomo "$tmpdir", 'test';
ok(1, !!$mj);

#5 - Connect to it
$ok = $mj->connect('testsuite', "Testing, pid $$\n");
ok(1, !!$ok);

#6 - Use the site password to set the domain's master password.  Screw it
#up once just to check.
$request = {password => 'badpass',
	    command  => 'configset',
	    list     => 'GLOBAL',
	    setting  => 'master_password',
	    value    => ['gonzo'],
	   };

$result = $mj->dispatch($request);
ok(0, $result->[0]);

#7 - Now use the proper password
$request->{password} = 'hurl';
$result = $mj->dispatch($request);
ok(1, $result->[0]);

#8 - Set whereami
$request->{password} = 'gonzo';
$request->{setting}  = 'whereami';
$request->{value}    = ['example.com'];
$result = $mj->dispatch($request);
ok(1, $result->[0]);

#9 - Make sure whereami got set
$request->{command}  = 'configshow';
$request->{groups}   = ['whereami'];
$result = $mj->dispatch($request);
ok('example.com', $result->[1][3]);

#10 - Create a list
$result = $mj->dispatch({user     => 'unknown@anonymous',
			 password => 'gonzo',
			 command  => 'createlist',
			 mode     => 'nowelcome',
			 newlist  => 'bleeargh',
			 victims  => ['nobody@example.com']});
ok(1, $result->[0]);

#11 - Make sure the list was created
$result = $mj->dispatch({user     => 'unknown@anonymous',
			 command  => 'lists'});
ok('bleeargh', $result->[1]{list});

#12 - Set inform so we don't send any mail
$result = $mj->dispatch({user     => 'unknown@anonymous',
			 password => 'gonzo',
			 command  => 'configset',
			 setting  => 'inform',
			 value    => ['subscribe   : all : ignore',
				      'unsubscribe : all : ignore'],
			 });
ok(1, $result->[0]);

# Shut things down and delete the temporary directory.  For some reason,
# some systems refuse to delete the directory.  I think this may have
# something to do with NFS.
undef $mj;
system("/bin/rm -rf $tmpdir");

exit 0;

sub ok {
  my $expected = shift;
  my $result   = shift;
  if ($result =~ /$expected/) {
    print "ok $counter\n";
  }
  else {
    print "not ok $counter\n";
  }
  chomp $result;
#  print STDERR "$result\n" if $verbose > 1;
  $counter++;
}

__END__

# 7. Subscribe an address, being careful not to send mail
$e = qq!\Qzork\@example.com was added to bleeargh.\n!;
$r = run('-p gonzo subscribe=quiet bleeargh zork@example.com');
ok($e, $r);

# 8. Make sure they're there
$e = qq!Members of list "bleeargh":\n  zork\@example.com\n1 listed subscriber\n!;
$r = run('who bleeargh');
ok($e, $r);

# 9. Add an address to an auxiliary list
$e = qq!\Qdeadline\@example.com was added to bleeargh:harumph.\n!;
$r = run('-p gonzo auxadd bleeargh harumph deadline\@example.com');
ok($e, $r);

# 10. Make sure it showed up
$e = qq!\QMembers of list "bleeargh:harumph":\n  deadline\@example.com\n1 listed subscriber\n!;
$r = run('-p gonzo auxwho bleeargh harumph');
ok($e, $r);

# 11. Add an alias
$e = qq!\Qenchanter\@example.com successfully aliased to zork\@example.com.\n!;
$r = run('-p gonzo -u zork@example.com alias enchanter@example.com');
ok($e, $r);

# 12. Add an alias to the first alias
$e = qq!\Qplanetfall\@example.com successfully aliased to enchanter\@example.com.\n!;
$r = run('-p gonzo -u enchanter@example.com alias planetfall@example.com');
ok($e, $r);

# 13. Set a password
$e = qq!\QPassword set.\n!;
$r = run('-p gonzo -u enchanter@example.com password-quiet suspect');
ok($e, $r);

# 14. Unsubscribe the aliased address using the set password
$e = qq!\Qzork\@example.com was removed from bleeargh.\n!;
$r = run('-p suspect unsubscribe bleeargh enchanter@example.com');
ok($e, $r);



sub run {
  if ($config->{'wrappers'}) {
    $cmd = "$^X -T -I. -Iblib/lib blib/script/.mj_shell -Z --lockdir $tmpdir/locks -t $tmpdir -d test " . shift;
  }
  else {
    $cmd = "$^X -T -I. -Iblib/lib blib/script/mj_shell -Z --lockdir $tmpdir/locks -t $tmpdir -d test " . shift;
  }
  $cmd .= " -D"
    if (shift());

#  warn "$cmd\n";
  return `$cmd`;
}

END {
  system("/bin/rm -rf $tmpdir");
}

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

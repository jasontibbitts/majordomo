print "1..15\n";

$| = 1;
$counter = 1;

eval('$config = require ".mj_config"');
$a = $config;
undef $a;     # Quiet 'used only once' warning.
ok(1, !$@);

# Create the directory structure we need
mkdir "tmp.$$", 0700 || die;
mkdir "tmp.$$/locks", 0700 || die;
mkdir "tmp.$$/test", 0700 || die;
mkdir "tmp.$$/test/GLOBAL", 0700 || die;
mkdir "tmp.$$/test/GLOBAL/files", 0700 || die;
mkdir "tmp.$$/test/GLOBAL/sessions", 0700 || die;

# Set a password
$e = qq!\Qmaster_password set to "gonzo".\n!;
$r = run('-p GLOBAL.pass configset GLOBAL master_password = gonzo');
ok($e, $r);

# Set the whereami variable; we have to have this or else some things warn
$e = qq!\Qwhereami set to "example.com".\n!;
$r = run('-p gonzo configset GLOBAL whereami = example.com');
ok($e, $r);

# Set the MTA so we can create a list
$e = qq!\Qmta set to "sendmail".\n!;
$r = run('-p gonzo configset GLOBAL mta = sendmail');
ok($e, $r);

# Create a list
$e = ".*";
$r = run('-p gonzo createlist bleeargh nobody@example.com');
ok($e, $r);

# Make sure it's there
$e = "\Qbleeargh\n";
$r = run('lists=tiny');
ok($e, $r);

# Have to turn off information or we die trying to inform the nonexistant owner
open(TEMP, ">var.$$");
print TEMP <<EOT;
subscribe   : all : ignore
unsubscribe : all : ignore
EOT
close TEMP;
$e = qq!\Qinform set to "subscribe   : all : ignore...".\n!;
$r = run("-p gonzo -f var.$$ configset bleeargh inform");
ok($e, $r);
unlink "var.$$";

# Subscribe an address, being careful not to send mail
$e = qq!\QThe following address was added to bleeargh:\n  zork\@example.com\n!;
$r = run('-p gonzo subscribe=quiet bleeargh zork@example.com');
ok($e, $r);

# Make sure they're there
$e = qq!Members of list "bleeargh":\n    zork\@example.com\n1 listed subscriber\n!;
$r = run('who bleeargh');
ok($e, $r);

# Add an address to an auxiliary list
$e = qq!\QThe following address was added to harumph:\n  deadline\@example.com\n!;
$r = run('-p gonzo auxadd bleeargh harumph deadline\@example.com');
ok($e, $r);

# Make sure it showed up
$e = qq!\QMembers of auxiliary list "bleeargh/harumph":\n    deadline\@example.com\n1 listed member\n!;
$r = run('-p gonzo auxwho bleeargh harumph');
ok($e, $r);

# Add an alias
$e = qq!\Qenchanter\@example.com successfully aliased to zork\@example.com.\n!;
$r = run('-p gonzo -u zork@example.com alias enchanter@example.com');
ok($e, $r);

# Add an alias to the first alias
$e = qq!\Qplanetfall\@example.com successfully aliased to enchanter\@example.com.\n!;
$r = run('-p gonzo -u enchanter@example.com alias planetfall@example.com');
ok($e, $r);

# Set a password
$e = qq!\QPassword set.\n!;
$r = run('-p gonzo -u enchanter@example.com password suspect');
ok($e, $r);

# Unsubscribe the aliased address using the set password
$e = qq!\QThe following address was removed from bleeargh:\n  zork\@example.com\n!;
$r = run('-p suspect unsubscribe bleeargh enchanter@example.com');
ok($e, $r);


sub ok {
  my $expected = shift;
  my $result   = shift;
  my $verb     = shift;
  if ($result =~ /$expected/) {
    print "ok $counter\n";
  }
  else {
    print "not ok $counter\n";
  }
  chomp $result;
  print STDERR "$result\n" if $verb;
  $counter++;
}

sub run {
  if ($config->{'wrappers'}) {
    $cmd = "$^X -T -I. -Iblib/lib blib/script/.mj_shell -Z --lockdir tmp.$$/locks -t tmp.$$ -d test " . shift;
  }
  else {
    $cmd = "$^X -T -I. -Iblib/lib blib/script/mj_shell -Z --lockdir tmp.$$/locks -t tmp.$$ -d test " . shift;
  }
  $cmd .= " -D"
    if (shift());

#  warn "$cmd\n";
  return `$cmd`;
}

END {
  system("/bin/rm -rf tmp.$$");
}

1;
#
### Local Variables: ***
### mode:cperl ***
### cperl-indent-level:2 ***
### End: ***

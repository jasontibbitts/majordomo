use File::Copy 'copy';

print "1..16\n";

$| = 1;
$counter = 1;

# 1
eval('$config = require ".mj_config"');
$a = $config;
undef $a;     # Quiet 'used only once' warning.
ok(1, !$@);

# Create the directory structure we need
mkdir "tmp.$$", 0700 || die;
mkdir "tmp.$$/bin", 0700 || die;
mkdir "tmp.$$/locks", 0700 || die;
mkdir "tmp.$$/SITE", 0700 || die;
mkdir "tmp.$$/test", 0700 || die;
mkdir "tmp.$$/test/GLOBAL", 0700 || die;
mkdir "tmp.$$/test/DEFAULT", 0700 || die;
mkdir "tmp.$$/test/GLOBAL/files", 0700 || die;
mkdir "tmp.$$/test/GLOBAL/sessions", 0700 || die;
symlink "../../files", "tmp.$$/SITE/files" || die;
copy  "t/global_config", "tmp.$$/test/GLOBAL/C_install" || die;
copy  "t/default_config", "tmp.$$/test/DEFAULT/C_install" || die;

# Make a copy of mj_shell, but delete the "use lib" line so we don't get
# any previously-installed libraries.
fixup_script();

open SITE,">tmp.$$/SITE/config.pl";
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

# 2-3. Relax some domain checks so you can run these tests on a machine not
# directly on the Internet.
$e = qq!\Qaddr_require_fqdn set to "0".\n!;
$r = run('-u nobody@anonymous -p hurl configset GLOBAL addr_require_fqdn = 0');
ok($e, $r);

$e = qq!\Qaddr_strict_domain_check set to "0".\n!;
$r = run('-u nobody@anonymous -p hurl configset GLOBAL addr_strict_domain_check = 0');
ok($e, $r);

# 4. Set a password
$e = qq!\Qmaster_password set to "gonzo".\n!;
$r = run('-p hurl configset GLOBAL master_password = gonzo');
ok($e, $r);


# 5. Set the whereami variable; we have to have this or else some things warn
$e = qq!\Qwhereami set to "example.com".\n!;
$r = run('-p gonzo configset GLOBAL whereami = example.com');
ok($e, $r);

open(TEMP, ">var.$$");
print TEMP <<EOT;
subscribe   : all : ignore
unsubscribe : all : ignore
EOT
close TEMP;
$e = qq!\Qinform set to "subscribe   : all : ignore...".\n!;
$r = run("-p gonzo -f var.$$ configset GLOBAL inform");
unlink "var.$$";

# 6. Create a list
$e = ".*";
$r = run('-p gonzo createlist-nowelcome bleeargh nobody@example.com');
ok($e, $r);

# 7. Make sure it's there
$e = "\Qbleeargh\n";
$r = run('lists=tiny');
ok($e, $r);

# 8. Have to turn off information or we die trying to inform the nonexistant owner
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

# 9. Subscribe an address, being careful not to send mail
$e = qq!\Qzork\@example.com was added to bleeargh.\n!;
$r = run('-p gonzo subscribe-quiet bleeargh zork@example.com');
ok($e, $r);

# 10. Make sure they're there
$e = qq!Members of the "bleeargh" list:\n  zork\@example.com!;
$r = run('who bleeargh');
ok($e, $r);

# 11. Add an address to an auxiliary list
$e = qq!\Qdeadline\@example.com was added to bleeargh:harumph.\n!;
$r = run('-p gonzo subscribe bleeargh:harumph deadline\@example.com');
ok($e, $r);

# 12. Make sure it showed up
$e = qq!\QMembers of the "bleeargh:harumph" list:\n  deadline\@example.com!;
$r = run('-p gonzo who bleeargh:harumph');
ok($e, $r);

# 13. Add an alias
$e = qq!\Qenchanter\@example.com successfully aliased to zork\@example.com.\n!;
$r = run('-p gonzo -u zork@example.com alias enchanter@example.com');
ok($e, $r);

# 14. Add an alias to the first alias
$e = qq!\Qplanetfall\@example.com successfully aliased to enchanter\@example.com.\n!;
$r = run('-p gonzo -u enchanter@example.com alias planetfall@example.com');
ok($e, $r);

# 15. Set a password
$e = qq!\QPassword set.\n!;
$r = run('-p gonzo -u enchanter@example.com password-quiet suspect');
ok($e, $r);

# 16. Unsubscribe the aliased address using the set password
$e = qq!\Qzork\@example.com was removed from bleeargh.\n!;
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
  $cmd = "$^X -T -I. -Iblib/lib tmp.$$/bin/mj_shell -Z --lockdir tmp.$$/locks -t tmp.$$ -d test " . shift;
  my $debug = shift;

  $cmd .= " -D" if $debug;

  warn "$cmd\n" if $debug;
  return `$cmd`;
}

sub fixup_script {
  my($dot, $line, $script);

  $dot = '';
  $dot='.' if $config->{'wrappers'};

  $script = "blib/script/${dot}mj_shell";
  open(OSCRIPT, "<$script") || die;
  open(NSCRIPT, ">tmp.$$/bin/mj_shell") || die;
  while (defined($line = <OSCRIPT>)) {
    if ($line =~ /^use lib .*;$/) {
      print NSCRIPT '$::LIBDIR = $::LIBDIR;', "\n";
      next;
    }
    print NSCRIPT $line;
  }
  close NSCRIPT;
  close OSCRIPT;
}

END {
  system("/bin/rm -rf tmp.$$");
}

1;
#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

#!/usr/local/bin/perl-latest -w
use Mj::Addr;
use Mj::Log;

$::log = new Mj::Log;
$::log->add   
    (   
     method      => 'handle',
     id          => 'text',
     handle      => \*STDERR,
     filename    => '/dev/null',
     level       => 0,
#    level       => 500,
     subsystem   => 'mail',
     log_entries => 1,
     log_exits   => 1,
     log_args    => 1,
    );


# Cool array of arrays containing tests; first value is expected return
# value from validate (unless -1, in which it means to call params with the
# rest of the values.  Second value is the address to validate; third value
# is the expected stripped address, and fourth is expected returned
# comments.  The final two may be blank if not expected.  If you add
# things, be sure to fix the test count at the end.
@t =
  (
#Good
   [1, q|Jason L Tibbitts <tibbs@uh.edu>|,
    'tibbs@uh.edu', 'Jason L Tibbitts'],
   [1, q|tibbs@uh.edu (Homey (  j (\(\() t ) Tibbs)|,
    'tibbs@uh.edu', 'Homey (  j (\(\() t ) Tibbs'],
   [1, q|"tibbs@home"@hpc.uh.edu (JLT )|,
    '"tibbs@home"@hpc.uh.edu', 'JLT '],
   [1, q| Muhammed.(I am  the greatest) Ali @(the)Vegas.nv.us  |,
    'Muhammed.Ali@vegas.nv.us', 'I am  the greatest the'],
   [1, q|tibbs@[129.7.3.5]|,
    'tibbs@[129.7.3.5]'],
   [1, q|A_Foriegner%across.the.pond@relay1.uu.net|,
    'A_Foriegner%across.the.pond@relay1.uu.net'],

#Bad    
   [0, q|tibbs@uh.edu Jason Tibbitts|],  # Full name illegally included
   [0, q|@uh.edu|],                      # Can't start with @
   [0, q|J <tibbs>|],                    # Not FQDN
   [0, q|tibbs@sina (J T)|],             # Not FQDN
   [0, q|<tibbs Da Man|],                # Unbalanced
   [0, q|Jason <tibbs>>|],               # Unbalanced
   [0, q|tibbs, nobody|],                # Multiple addresses not allowed
   [0, q|tibbs@.hpc|],                   # Illegal @.
   [0, q|<a@b>@c|],                      # @ illegal in phrase
   [0, q|<a@>|],                         # No hostname
   [0, q|<a@b>.abc|],                    # >. illegal
   [0, q|<a@b> blah <d@e>|],             # Two routes illegal
   [0, q|<tibbs<tib@a>@hpc.uh.edu>|],    # Nested routes illegal
   [0, q|[<tibbs@hpc.uh.edu>]|],         # Enclosed in []
   [0, q|tibbs@hpc,uh.edu|],             # Comma illegal
   [0, q|<a@b.cd> Me [blurfl] U|],       # Domain literals illegal in comment
   [0, q|tibbs@sina.hpc|],               # hpc not legal TLD
   [0, q|A B @ C <a@b.c>|],              # @ not legal in comment
   [0, q|blah . tibbs@|],                # Unquoted . not legal in comment
   [0, q|tibbs@hpc.uh.edu.|],            # Address ends with a dot
   [0, q|sina.hpc.uh.edu|],              # No local-part@
   [0, q|tibbs@129.7.3.5|],              # Forgot to enclose IP in []

#OK depending on settings
   # Bang path
   [0, q|blah!relay2%relay1|],
   [-1, 'allow_bang_paths', 1],
   [1, q|blah!relay2%relay1|,
    'blah!relay2%relay1'],

   # Comments after route
   [0, q|Blah <a@b.fi> More Blah|],
   [-1, 'allow_comments_after_route', 1],
   [1, q|Blah <a@b.fi> More Blah|,
    'a@b.fi', 'Blah More Blah'],

   # Length limitations
   [0, q|tibbs@123456789.123456789.123456789.123456789.123456789.1234567890123.com|],
   [-1, 'limit_length', 0],
   [1, q|tibbs@123456789.123456789.123456789.123456789.123456789.1234567890123.com|,
    'tibbs@123456789.123456789.123456789.123456789.123456789.1234567890123.com'],

  );

# Splitting tests
@s =
  (
   ['tibbs@hpc.uh.edu, tibbs@hpc.uh.edu', 'tibbs@hpc.uh.edu', 'tibbs@hpc.uh.edu'],
   ['tibbs@uh.edu (Homey (  j (\(\() t, ) Tibbs), nobody@example.com',
    'tibbs@uh.edu', 'nobody@example.com'],
   [q|"tib,bs@home"@hpc.uh.edu (J,LT ), Tibbs <tibbs@hpc.uh.edu>|,
    '"tib,bs@home"@hpc.uh.edu', 'Tibbs <tibbs@hpc.uh.edu>'],						 
  );

print "1..57\n";

# Allocate a validator with some default settings
Mj::Addr::set_params
   (
     'allow_at_in_phrase'          => 0,
     'allow_bang_paths'            => 0,
     'allow_comments_after_route'  => 0,
     'allow_ending_dot'            => 0,
     'limit_length'                => 1,
     'require_fqdn'                => 1,
     'strict_domain_check'         => 1,
    );

for ($i = 0; $i<@t; $i++) {
  if ($t[$i][0] < 0) {
    Mj::Addr::set_params($t[$i][1] => $t[$i][2]);
    print "ok\n";
    next;
  }

  $a = new Mj::Addr($t[$i][1]);
  $ok = $a->isvalid;
  $com  = $a->comment;
  $addr = $a->strip;
  if ($ok eq $t[$i][0]) {
    print "ok\n";

    if ($ok && $t[$i][2]) {
      if ($addr eq $t[$i][2]) {
	print "ok\n";
      }
      else {
	print "not ok\n";
	print STDERR "$t[$i][2]\n$addr\n";
      }
    }
    if ($ok && $t[$i][3]) {
      if ($com eq $t[$i][3]) {
	print "ok\n";
      }
      else {
	print "not ok\n";
	print STDERR "$t[$i][3]\n$com\n";
      }
    }
  }
  elsif ($ok == 1) {
    print "not ok\n";
    print STDERR "$t[$i][1]\n  expected to fail but didn't.\n"
  }
  else {
    print "not ok\n";
    print STDERR "$t[$i][1]\n$addr\n";
  }
  next;
}

# Check splitting
for $i (@s) {
  @out = Mj::Addr::separate($i->[0]);
#warn "$i->[0] - ", join ':', @out;
  for ($j = 1; $j < @{$i}; $j++) {
    if ($i->[$j] eq $out[$j-1]) {
      print "ok\n";
    }
    else {
      print "not ok\n";
      print STDERR "Expected $i->[$j], got $out[$j-1]\n";
    }
  }  
}

1;

#
### Local Variables: ***
### cperl-indent-level:2 ***
### End: ***

=head1 NAME

Mj::TextOutput - Display results of Majordomo commands in plain text

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This module contains the code for taking apart command lines coming
from the text parser, calling the core dispatch routine and calling
the formatting routines to output the results.

These routines will loop over any data present on an input handle (if
the function makes sense over a list of arguments) and call the core
dispatcher once per argument.  If the formatter will report on
multiple results, they are collected and sent at once.  Otherwise the
formatter is also called once per argument.

If the particular function requires iteration (multiple core calls to
collect the results) then the routine will set up the iteration but
the formatting function handles retrieving all of the values and
ending the iteration.

Each of these routines expects the following arguments:

 A Majordomo object
 The name the command is being called by (in case of aliasing)
 The user of the interface, authenticated to the best of the interface''s
   ability
 A password, if supplied by the user
 A currently unused authentication token (perhaps PGP key)
 The name of the interface (email, shell, telnet, web)
 A filehandle open for input holding arguments or data
 A filehandle open for output back to the user
 A mode string, which affects the behavior of the command
 A string containing the arguments on the command line
 An array of strings containing further arguments to the command

=cut

package Mj::TextOutput;
use Mj::Format;
use strict;

use AutoLoader 'AUTOLOAD';
1;
__END__

=head2 accept

Accepts a token, or a list of tokens.

=cut
sub accept {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my ($data, $i, $ok, $result, $rok, $tok);

  my @stuff = ($user, $passwd, $auth, $interface,
               "accept".($mode?"=$mode":"")." $args", $mode, $list, '');

  # Bomb unless we got a token
  unless (@arglist || $args || $infh) {
    print $outfh "**** No token supplied!\n";
    return;
  }

  if (!$infh && !@arglist) {
    @arglist = ($args);
  }

  while (1) {
    $i = $infh ? $infh->getline : shift @arglist;
    last unless $i;
    chomp $i;
    $rok =
      Mj::Format::accept($mj, $outfh, $outfh, 'text', @stuff, $i, '', '',
			 $mj->dispatch('accept', @stuff, $i)
			);
    
    $rok ||= $ok;
  }
  $rok;
}

=head2 alias

Adds an alias from one address to another.  The target address is taken to
be the user address.  (XXX After aliasing?)

This means that you add aliases to the account your posting from, not from
your current address to another.

The target address must be a subscriber.

XXX This needs a way to specify both addresses.  Use here args and reverse
the order?  This could alias several addresses to one.

=cut
sub alias {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $d, $args, @arglist) = @_;
  my $log = new Log::In 27, "$user, $args";
  my ($ok, $mess);

  my @stuff = ($user, $passwd, $auth, $interface,
	       "alias".($mode?"=$mode":"")." $args", $mode, '',
	       $user);

  Mj::Format::alias($mj, $outfh, $outfh, 'text', @stuff, $args, '','',
		    $mj->dispatch('alias', @stuff, $args)
		   );
}

=head2 archive

Retrieves files and indices from the archive.

=cut
sub archive {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27;
  my @args  = split(" ", $args);
  my @stuff = ($user, $passwd, $auth, $interface,
	       "archive".($mode?"-$mode":"")." $args", $mode, $list,
	       $user);

  Mj::Format::archive($mj, $outfh, $outfh, 'text', @stuff, $args, '', '',
		      $mj->dispatch('archive', @stuff, @args));
}


=head2 auxsubscribe

This adds an address to one of a list''s auxiliary lists.

=cut
sub auxadd {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27;
  my (@addresses, $file);

  ($file, @addresses) = (split(" ", $args, 2), @arglist);
  
  # Untaint $file;
  $file =~ /(.*)/;
  $file = $1;

   g_add($mj, $name, $user, $passwd, $auth, $interface,
	 $infh, $outfh, $mode, $list, $file, 1,
	 @addresses);
}

=head2 auxunsubscribe

This removes an address to one of a list''s auxiliary lists.

=cut
sub auxremove {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$list, $user, $args";
  my (@addresses, $file);
  
  ($file, @addresses) = (split(" ", $args, 2), @arglist);
  
  # Untaint $file;
  $file =~ /(.*)/;
  $file = $1;

  g_remove('auxremove', $mj, $name, $user, $passwd, $auth, $interface,
	   $infh, $outfh, $mode, $list, $file, 1, @addresses);
}

=head2 auxwho

Returns the addresses that are on an auxiliary list.

=cut
sub auxwho {
  my ($mj, $name, $user, $pass, $auth, $int,
      $infh, $outfh, $mode, $list, $tsublist, @arglist) = @_;
  my $log = new Log::In 27, "$list, $tsublist";
  my (@lines, @out, $chunksize, $count, $error, $i,
      $ok, $ret, $sublist);

  # Untaint $sublist
  $tsublist=~/(.*)/;
  $sublist = $1;

  my @stuff = ($user, $pass, $auth, $int,
	       "auxwho".($mode?"=$mode":"")." $list $sublist",
	       $mode, $list, $user, $sublist);

  Mj::Format::auxwho($mj, $outfh, $outfh, 'text', @stuff, '', '',
		     $mj->dispatch('auxwho_start', @stuff)
		    );
}

=head2 configdef

Completely removes the definition of a config variable, causing it to track
its default value.

=cut
sub configdef {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my ($ok, $mess);

  ($ok, $mess) =
    $mj->list_config_set_to_default($user, $passwd,
				    $auth, $interface,
				    $list, $args);

  print $outfh "**** $mess" if $mess;
  if ($ok) {
    print $outfh "$args set to default value.\n";
  }
  return $ok;
}

=head2 configset

This performs the configset command, which makes permanent changes to
configuration variables.

=cut
sub configset {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my ($line, $rest, $sep, $var, $ok, $mess);

  ($var, $rest)  = split(/\s*=\s*/, $args, 2);
  
  if (defined $rest) {
    @arglist = ($rest);
  }

  if (defined $infh) {
    @arglist = ();
    while (defined ($line = $infh->getline)) {
      chomp $line;
      push @arglist, $line;
    }
  }

  Mj::Format::configset
    ($mj, $outfh, $outfh, 'text', $user, $passwd, $auth, $interface,
     'configset', $mode, $list, $user, $var, join("\002", @arglist), '',
     $mj->list_config_set($user, $passwd, $auth, $interface, $list, $var,
			  @arglist));
}
  

=head2 configshow

This performs the configshow command, which returns a preformatted sequence
of configset commands to be edited and returned.

=cut
sub configshow {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my (%all_vars, @vars, $comment, $flag, $group, $groups,
      $message, $opts, $tag, $val, $var, $vars);

  my $log = new Log::In 27, $args;

  ($groups, $opts) = split(" ", $args);
  $groups .= join(',',@arglist);
  
  $groups ||= 'ALL';
  $mode   ||= 'nocomments';

  for $group (split /\s*,\s*/, $groups) {
    # This expands groups and checks visibility and existence of variables
    @vars = $mj->config_get_vars($user, $passwd, $auth, $interface,
				 $list, $group);
    unless (@vars) {
      print $outfh "**** No visible variables matching $group\n";
      return;
    }
    for $var (@vars) {
      $all_vars{$var}++;
    }
  }                        
  
  for $var (sort keys %all_vars) {
    # Process the options
    if ($mode !~ /nocomments/) {
      $comment = $mj->config_get_intro($list, $var) .
	$mj->config_get_comment($var);
      $comment =~ s/^/# /gm;
      print $outfh $comment;
    }
    if ($mj->config_get_isauto($var)) {
      print $outfh "# This variable is automatically maintained by Majordomo.  Uncomment to change.\n# ";
    }
    if ($mj->config_get_isarray($var)) {
      # Process as an array
      $tag = Majordomo::unique2();
      print $outfh "configset $list $var \<\< END$tag\n";
      for ($mj->list_config_get($user, $passwd, $auth, $interface,
				$list, $var, 1))
	{
	  print $outfh "$_\n" if defined $_;
	}
      print $outfh "END$tag\n\n";
    }
    else {
      # Process as a simple variable
      $val = $mj->list_config_get($user, $passwd, $auth, $interface,
				  $list, $var, 1);
      $val ||= "";
      print $outfh "configset $list $var =";
      if (length $val > 40) {
	print $outfh "\\\n   ";
      }
      print $outfh " $val\n";
      if ($mode !~ /nocomments/) {
	print $outfh "\n";
      }
    }
  }
  1;
}

sub createlist {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $dummy, $args, @arglist) = @_;
  # $list will not be defined in any useful way because we didn't ask for
  # one (see parser_data) because it doesn't exist to be validated by the
  # parser because we haven't created it yet.
  my $log = new Log::In 27, "$args";
  my($cmdline, $list, $owner);

  $cmdline = "createlist".($mode?"=$mode":"")." $args";

  # special split, ignores leading whitespace
  ($list, $owner) = split(' ', $args, 2);

  $list  ||= '';
  $owner ||= $user;

  Mj::Format::createlist($mj, $outfh, $outfh, 'text', $user, $passwd,
			 $auth, $interface, $cmdline, $mode, 'useless',
			 $owner, $list, '', '',
			 $mj->dispatch('createlist', $user, $passwd, $auth,
				       $interface, $cmdline, $mode, '',
				       $owner, $list));
}

sub faq {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my ($cmdline, $mess, $ok);

  $cmdline = "faq" . ($mode?"=$mode":"") . " $list";
  
  Mj::Format::faq($mj, $outfh, $outfh, 'text', $user, $passwd, $auth,
		   $interface, $cmdline, $mode, $list, $user, '', '', '',
		   $mj->dispatch('faq_start', $user, $passwd, $auth,
				 $interface, $cmdline, $mode, $list, $user)
		  );
}


# XXX This is nasty and needs to be done properly.
sub filesync {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, $list;

  $mj->list_file_sync($user, $passwd, $auth, $interface, '', '', $list);
  print $outfh "File database for $list synchronized.\n";
  1;
}

sub get {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my ($cmdline, $mess, $ok);

  $cmdline = "get" . ($mode?"=$mode":"") . " $list $args";

  Mj::Format::get($mj, $outfh, $outfh, 'text', $user, $passwd, $auth,
		   $interface, $cmdline, $mode, $list, $user, $args, '', '',
		   $mj->dispatch('get_start', $user, $passwd, $auth, $interface,
				 $cmdline, $mode, $list, $user, $args)
		  );
}

=head2 help

This retrieves a help file on a given topic.

Note that there''s no list.

=cut
sub help {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $dummy, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my ($cmdline, $mess, $ok, $topic);

  if ($args) {
    $topic = lc(join('_', split(/\s+/, $args)));
  }
  else {
    $topic = "default";
  }

  $cmdline = "help" . ($mode?"=$mode":"") . " $topic";

  Mj::Format::help($mj, $outfh, $outfh, 'text', $user, $passwd, $auth,
		   $interface, $cmdline, $mode, '', '', $topic, '', '',
		   $mj->dispatch('help_start', $user, $passwd, $auth, $interface,
				 $cmdline, $mode, '', '', $topic)
		  );
}

sub index {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my ($cmdline, $mess, $ok);

  $cmdline = "index" . ($mode?"=$mode":"") . " $list $args";

  Mj::Format::index($mj, $outfh, $outfh, 'text', $user, $passwd, $auth,
		    $interface, $cmdline, $mode, $list, $user, $args, '',
		    '',
		    $mj->dispatch('index', $user, $passwd, $auth,
				  $interface, $cmdline, $mode, $list,
				  $user, $args));
}

sub info {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my ($cmdline, $mess, $ok);

  $cmdline = "info" . ($mode?"-$mode":"") . " $list";
  
  Mj::Format::info($mj, $outfh, $outfh, 'text', $user, $passwd, $auth,
		   $interface, $cmdline, $mode, $list, $user, '', '', '',
		   $mj->dispatch('info_start', $user, $passwd, $auth,
				 $interface, $cmdline, $mode, $list, $user)
		  );
}

sub intro {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my ($cmdline, $mess, $ok);

  $cmdline = "intro" . ($mode?"-$mode":"") . " $list";
  
  Mj::Format::intro($mj, $outfh, $outfh, 'text', $user, $passwd, $auth,
		    $interface, $cmdline, $mode, $list, $user, '', '', '',
		    $mj->dispatch('intro_start', $user, $passwd, $auth,
				  $interface, $cmdline, $mode, $list,
				  $user)
		   );
}

# Carry out the "lists" command; this one's really simple
sub lists {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27;

  my @stuff = ($user, $passwd, $auth, $interface,
	       "lists".($mode?"-$mode":""), $mode, '', $user, '', '', '');

  Mj::Format::lists($mj, $outfh, $outfh, 'text', @stuff, 
		    $mj->dispatch('lists', @stuff)
		   );
}

=head2 newfaq, newinfo, newintro

These three are just aliases for put with various arguments.  If the
aliasing feature was more powerful, these could be done in the parser.


=cut
sub newfaq   {$_[10] = "/faq Frequently Asked Questions";      put(@_);}
sub newinfo  {$_[10] = "/info List Information";               put(@_);}
sub newintro {$_[10] = "/intro List Introductory Information"; put(@_);}

=head2 password

Allows the user to change their password (or have another one randomly
generated).

=cut
sub password {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my ($cmdline, $vict, $pass);

  $cmdline = "password" . ($mode?"=$mode":"") . " $args";

  if ($mode =~ /rand|gen/) {
    $pass = ''; $vict = $args;
   }
  else {
    ($pass, $vict) = split(' ', $args, 2);
  }
  $vict ||= $user;
  Mj::Format::password($mj, $outfh, $outfh, 'text', $user, $passwd, $auth,
		       $interface, $cmdline, $mode, $list, $vict, $pass,
		       '', '',
		       $mj->dispatch('password', $user, $passwd, $auth,
				     $interface, $cmdline, $mode, $list,
				     $vict, $pass));
}

=head2 post

This allows the posting of a message to a list without going through an
alias pointing at mj_resend.

XXX This currently has security implications; beware.

=cut
sub post {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$list";
  my (@out, @stuff, $i, $ok);

  @stuff = ($user, $passwd, $auth, $interface,
	    "post".($mode?"=$mode":"")." $list",
	    $mode, $list, '');

  ($ok, @out) = $mj->dispatch('post_start', @stuff);
  
  return Mj::Format::post($outfh, $outfh, 'text', @stuff, $ok, @out)
    unless $ok;
  
  while (1) {
    $i = $infh ? $infh->getline : shift @arglist;
    last unless defined $i;
    ($ok, @out) = $mj->dispatch('post_chunk', @stuff, $i);
  }
  
  Mj::Format::post($outfh, $outfh, 'text', @stuff, '', '', '',
		   $mj->dispatch('post_done', @stuff)
		  );
}  

=head2 put

This uploads a file to the server.  The first argument is the file name,
the second is the description of the file (which gets used as the subject
when the file is sent).

If mode =~ /data/ we expect four additional args before the desctiption:
content-type, charset, content-transfer-encoding and content-language.  All
must be specified.

=cut
sub put {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my(@out, @stuff, $chunk, $chunksize, $cmdline, $cset, $ct, $cte, $desc,
     $file, $i, $lang, $mess, $ok);

  # Pull apart the arguments
  if ($mode =~ /data/) {
    ($file, $ct, $cset, $cte, $lang, $desc) = split(/\s+/, $args, 6);
    $cmdline = "put".($mode?"-$mode":"")." $list $file $ct $cset $cte $lang $desc";
  }
  else {
    ($file, $desc) = split(/\s+/, $args, 2);
    $desc ||= '';
    $cmdline = "put".($mode?"-$mode":"")." $list $file $desc";
    $ct = ''; $cset = ''; $cte = ''; $lang = '';
  }

  # The last four arguments are the c-t, cset, c-t-e and language
  @stuff = ($user, $passwd, $auth, $interface, $cmdline, $mode, $list,
	    $user, $file, $desc);

  ($ok, @out) = $mj->dispatch('put_start', @stuff, $ct, $cset, $cte, $lang);

  # Quit now if we have an error or if we're making a directory
  return Mj::Format::put($mj, $outfh, $outfh, 'text', @stuff, '', $ok, @out)
    if !$ok || $mode =~ /dir/;

  $chunksize = $mj->global_config_get(undef, undef, undef, $interface,
				      "chunksize") * 80;

  while (1) {
    $i = $infh ? $infh->getline : shift @arglist;
    # Tack on a newline if pulling from a here doc
    if (defined($i)) {
      $i .= "\n" unless $infh;
      $chunk .= $i;
    }      
    if (length($chunk) > $chunksize || !defined($i)) {
      ($ok, @out) = 
	$mj->dispatch('put_chunk', $user, $passwd, $auth, $interface, '',
		      $mode, $list, '', $chunk);
      return Mj::Format::put($mj, $outfh, $outfh, 'text', @stuff, '', $ok, @out)
	unless $ok;
    }
    last unless defined $i;
  }

  Mj::Format::put($mj, $outfh, $outfh, 'text', @stuff, '',
		  $mj->dispatch('put_done', $user, $passwd, $auth,
				$interface, "", $mode, $list)
		 );
}

=head2 register

This adds a user to the registration database without adding them to any
lists.

Modes: randpassword - assign a random password

else a password is a required argument.

=cut
sub register {
  my ($mj, $name, $user, $passwd, $auth, $int,
      $infh, $outfh, $mode, $d, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my (@addresses, @bad, @good, @maybe, $arg1, $arg2, $cmd, $i, $mess, $ok,
      $pw);

  ($arg1, $arg2) = split(/\s+/, $args, 2);
  if ($infh && $mode =~ /randpass/) {
    $addresses[0] = $arg1; $pw = '';
    $cmd = "register".($mode?"=$mode":"")." ";
  }
  else {
    $addresses[0] = $arg2; $pw = $arg1;
    $cmd = "register".($mode?"=$mode":"")." $pw ";
  }
  @addresses = @arglist unless $addresses[0];
  @addresses = $user unless $addresses[0];

  while (1) {
    $i = $infh ? $infh->getline : shift @addresses;
    last unless $i;
    chomp $i;
    ($ok, $mess) =
      $mj->dispatch('register', $user, $passwd, $auth, $int, $cmd.$i, $mode,
		    '', $i, $pw);
 
    if   ($ok > 0) {
      push @good, ($i, $mess);
    }
    elsif ($ok < 0) {
      push @maybe, ($i, $mess);
    }
    else {
      push @bad, ($i, $mess);
    }
  }
  return
    Mj::Format::register($mj, $outfh, $outfh, 'text', $user, $passwd, $auth,
			  $int, '', $mode, '', '',
			  \@good, \@bad, \@maybe);
}
=head2 reject

This rejects a token or a list of tokens.

=cut
sub reject {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  defined($args)?1:($args='');
  my $log = new Log::In 27, "$args";
  my ($data, $i, $ok, $result, $rok, $tok);

  my @stuff = ($user, $passwd, $auth, $interface, '', $mode, $list,
	       '');

  if (!@arglist) {
    @arglist = ($args);
  }

  while (1) {
    $i = $infh ? $infh->getline : shift @arglist;
    last unless defined $i;
    chomp $i;
    $stuff[4]="reject".($mode?"=$mode":"")." $i";
    $rok =
      Mj::Format::reject($mj, $outfh, $outfh, 'text', @stuff, $i, '', '',
			 $mj->dispatch('reject', @stuff, $i)
			);
    $rok ||= $ok;
  }
  $rok;
}

=head2 rekey

This rekeys the databases.

XXX Handle 'ALL'

=cut
sub rekey {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";

  my @stuff = ($user, $passwd, $auth, $interface,
	       "rekey".($mode?"=$mode":"")." $list", $mode, $list, '');

  Mj::Format::rekey($mj, $outfh, $outfh, 'text', @stuff, '', '', '',
		    $mj->dispatch('rekey', @stuff)
		    );
}

=head2 sessioninfo

Give known information about a session.

=cut
sub sessioninfo {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $dummy, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my ($ok, $mess);

  my @stuff = ($user, $passwd, $auth, $interface,
	       "sessioninfo".($mode?"=$mode":"")." $args", $mode,
	       'GLOBAL' , $user);

  Mj::Format::sessioninfo($mj, $outfh, $outfh, 'text', @stuff, $args,
			  '','', $mj->dispatch('sessioninfo', @stuff,
					       $args)
			 );
}

=head2 set

This sets various subscriber flags and other data.  The format is
designed in such a way that all spaces are delimited in some way, so
that there''s no problem dealing with the user address.

=cut
sub set {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$list, $args";
  my (@addresses, @stuff, $action, $addr, $arg, $i, $ok, $rok);

  # Deal with action-(arg with spaces) address
  if ($args =~ /(\S+?)\-\((.*?)\)\s*(.*)/) {
    $action = $1;
    $arg = $2;
    $addr = $3;
  }
  # action-arg address
  elsif ($args =~ /(\S+?)-(\S+)\s*(.*)/) {
    $action = $1;
    $arg = $2;
    $addr = $3;
  }
  # action address
  else {
    $args =~ /(\S+)\s*(.*)/;
    $action = $1;
    $arg = '';
    $addr = $2;
  }

  @addresses = $addr || @arglist || $user;
  @stuff = ($user, $passwd, $auth, $interface,
	    "set".($mode?"=$mode":"")." $list $args", $mode, $list);

  while (1) {
    $i = $infh ? $infh->getline : shift @addresses;
    last unless $i;
    chomp $i;
    last unless $i;
    $rok =
      Mj::Format::set($mj, $outfh, $outfh, 'text', @stuff, $i, $action, $arg, '',
		      $mj->dispatch('set', @stuff, $i, $action, $arg)
		     );
    $rok ||= $ok;
  }
  
  $rok;
}  

=head2 show

This displays various types of subscriber information.

=cut
sub show {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my (@addresses, @stuff, $i, $ok, $rok);

  @addresses = $args || @arglist || $user;

  @stuff = ($user, $passwd, $auth, $interface,
	    "show".($mode?"=$mode":"")." $args",
	    $mode, $list);

  while (1) {
    $i = $infh ? $infh->getline : shift @addresses;
    last unless $i;
    chomp $i;
    last unless $i;
    $rok =
      Mj::Format::show($mj, $outfh, $outfh, 'text', @stuff, $i, '', '', '',
		       $mj->dispatch('show', @stuff, $i)
		      );
    $rok ||= $ok;
  }

  $rok;
}

=head2 showtokens

This shows a list of all tokens acting on a list.  The list can be GLOBAL.

=cut
sub showtokens {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$list, $args";
  my ($cmdline, $mess, $ok);

  $cmdline = "showtokens" . ($mode?"=$mode":"") . " $list";

  Mj::Format::showtokens($mj, $outfh, $outfh, 'text', $user, $passwd,
			 $auth, $interface, $cmdline, $mode, $list, $user,
			 '', '', '',
			 $mj->dispatch('showtokens', $user, $passwd, $auth,
				       $interface, $cmdline, $mode, $list,
				       $user)
			);
}

=head2 subscribe

This does the obvious.  Tries to extract a subscriber class and flags from
the the mode string, and looks at the given list for a possible digest
class.

=cut
sub subscribe {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$list, $args";
  my (@addresses, $ok);

  $addresses[0] = $args;
  @addresses = @arglist unless $args;
  @addresses = $user unless @addresses;

  $ok = g_add($mj, $name, $user, $passwd, $auth, $interface,
		    $infh, $outfh, $mode, $list,
		    undef, undef, @addresses);
  return $ok;
}

=head2 tokeninfo

Give pertinent info about a given token.

=cut
sub tokeninfo {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $dummy, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my ($ok, $mess);

  my @stuff = ($user, $passwd, $auth, $interface,
	       "tokeninfo".($mode?"=$mode":"")." $args", $mode,
	       'GLOBAL' , $user);

  Mj::Format::tokeninfo($mj, $outfh, $outfh, 'text', @stuff, $args, '','',
		      $mj->dispatch('tokeninfo', @stuff, $args)
		     );
}

=head2 unalias

Remove an alias coming from an address.  Since an address can only be
aliased to one other address, there is no need to specify a target
(although internal routines should check that it matches the user).

=cut
sub unalias {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";

  my @stuff = ($user, $passwd, $auth, $interface,
	       "alias".($mode?"=$mode":"")." $args", $mode, $list,
	       $args);
  
  Mj::Format::unalias($mj, $outfh, $outfh, 'text', @stuff, '', '','',
		      $mj->dispatch('unalias', @stuff)
		     );
}

sub unregister {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";
  my (@addresses);
  
  $addresses[0] = $args;
  @addresses = @arglist unless $args;
  @addresses = ($user) unless @addresses;

  g_remove('unregister', $mj, $name, $user, $passwd, $auth, $interface,
	   $infh, $outfh, $mode, $list, undef, undef, @addresses);
}

sub unsubscribe {
  my ($mj, $name, $user, $passwd, $auth, $interface,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27, "$list, $args";
  my (@addresses);
  
  $addresses[0] = $args;
  @addresses = @arglist unless $args;
  @addresses = ($user) unless @addresses;

  g_remove('unsubscribe', $mj, $name, $user, $passwd, $auth, $interface,
	   $infh, $outfh, $mode, $list, undef, undef, @addresses);
}

sub which {
  my ($mj, $name, $user, $pass, $auth, $int, $infh, $outfh, $mode, $list,
      $args, @arglist) = @_;
  my $log = new Log::In 27, "$args";

  my @stuff = ($user, $pass, $auth, $int, "which".($mode?"=$mode":"")."
               $args", $mode, $list, '');

  Mj::Format::which($mj, $outfh, $outfh, 'text', @stuff, $args, '','',
		    $mj->dispatch('which', @stuff, $args)
		   );
}

sub who {
  my ($mj, $name, $user, $pass, $auth, $int,
      $infh, $outfh, $mode, $list, $args, @arglist) = @_;
  my $log = new Log::In 27;

  my @stuff = ($user, $pass, $auth, $int,
               "who".($mode?"=$mode":"")." $list", $mode, $list, $user);

  Mj::Format::who($mj, $outfh, $outfh, 'text', @stuff, $args,'','',
		  $mj->dispatch('who_start', @stuff, $args)
		 );
}

=head2 g_add

Since the subscribe and auxsubscribe commands are so similar, this handles
the internals of both of them.

=cut
sub g_add {
  my ($mj, $name, $user, $pass, $auth, $int, $infh, $outfh, $mode,
      $list, $file, $aux, @addresses) = @_;
  my (@good, @bad, @maybe, $ok, $mess, $i);
  
  while (1) {
    $i = $infh ? $infh->getline : shift @addresses;
    last unless $i;
    chomp $i;
    
    if ($aux) {
      ($ok, $mess) =
	$mj->dispatch('auxadd', $user, $pass, $auth, $int, 
		      "auxadd".($mode?"=$mode":"")." $list $file $i",
		      $mode, $list, $i, $file);
    }
    else {
      ($ok, $mess) = 
	$mj->dispatch('subscribe', $user, $pass, $auth, $int,
		      "subscribe".($mode?"=$mode":"")." $list $i",
		      $mode, $list, $i);
    }
    if   ($ok > 0) {
      push @good, ($i, $mess);
    }
    elsif ($ok < 0) {
      push @maybe, ($i, $mess);
    }
    else {
      push @bad, ($i, $mess);
    }
  }

  # For auxlist stuff, just report the auxlist as the list name
  $list = $file if $aux;

  # Note that the command line and the victim are useless because
  # there can be many addresses
  return
    Mj::Format::subscribe($mj, $outfh, $outfh, 'text', $user, $pass, $auth,
			  $int, 'useless', $mode, $list, 'useless',
			  \@good, \@bad, \@maybe);
}

=head2 g_remove

This handles the internals of the unsubscribe and auxunsubscribe commands.

=cut
sub g_remove {
  my ($type, $mj, $name, $user, $pass, $auth, $int,
      $infh, $outfh, $mode, $list, $file, $aux,
      @addresses) = @_;
  my (@good, @bad, @maybe, @out, $ok, $mess, $i, $key);
  
  while (1) {
    $i = $infh ? $infh->getline : shift @addresses;
    last unless $i;
    chomp $i;

    if ($type eq 'auxremove') {
      ($ok, @out) =
	$mj->dispatch('auxremove', $user, $pass, $auth, $int, 
		      "auxremove".($mode?"-$mode":"")." $list $file $i",
		      $mode, $list, $i, $file);
    }
    elsif ($type eq 'unsubscribe') {
      ($ok, @out) = 
       $mj->dispatch('unsubscribe', $user, $pass, $auth, $int,
		     "unsubscribe".($mode?"-$mode":"")." $list $i",
		     $mode, $list, $i);
    }
    elsif ($type eq 'unregister') {
      ($ok, @out) =
	$mj->dispatch('unregister', $user, $pass, $auth, $int, 
		      "unregister".($mode?"-$mode":"")." $i",
		      $mode, $list, $i, $file);
    }
    else {
      $::log->abort("g_remove called illegally!");
    }

    # Successful removals carry no message, so we just add blanks
    if ($ok > 0) {
      for (my $j=0; $j < @out; $j++) {
	push @good, ($out[$j], '');
      }
    }
    # $out[0] holds the error message in case of an error.
    elsif ($ok < 0) {
      push @maybe, ($i, $out[0]);
    }
    else {
      push @bad, ($i, $out[0]);
    }
  }
  
  if ($type eq 'auxremove') {
    # For auxlist stuff, just report the auxlist as the list name
    $list = $file if $aux;
    $type = 'unsubscribe';
  }
  if ($type eq 'unsubscribe') {
    # Note that the command line and the victim are useless because
    # there can be many addresses
    return
      Mj::Format::unsubscribe($mj, $outfh, $outfh, 'text', $user, $pass, $auth,
			      $int, 'useless', $mode, $list, 'useless',
			      \@good, \@bad, \@maybe);
  }
  else { # unregister
    return
      Mj::Format::unregister($mj, $outfh, $outfh, 'text', $user, $pass, $auth,
			      $int, 'useless', $mode, $list, 'useless',
			      \@good, \@bad, \@maybe);
  }
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
### End: ***

=head1 NAME

Mj::Format - Turn the results of a core call into formatted output.

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This takes the values returned from a call to the Majordomo core and
formats them for human consumption.  The core return values are necessarily
simple (no compound data structures) because they were designed to cross a
network boundary and to be somewhat human-readable in raw form, and they
are (for the most part) unformatted because they are not bound to a
specific interface.

Format routines take:
  mj - a majordomo object, so that formatting routines can get config
    variables and call other core functions
  outfh - a filehendle to send output to
  errfh - a filehandle to send error ourput to
  output_type - text or html or ???
  user, password, auth, interface, cmd, mode, list, victim - the usual
    stuff
  arg1 - arg3 - three arguments to use in formatting.  These can be use for
    anything, but when called from a token accept, they are the three
    arguments stored with the token.
  command_return - everything that was returned from the core call.

Format routines return a flag indicating whether or not the command_return
indicates that the command completed successfully.

Note that at the moment the error handle isn't used; I'm not sure what
constitutes an error.  A stall isn't a success, but it isn't an error
either.

For iteration functions, we expect that the startup function will have
been called for us, so that we can process any error return, but we
will handle getting the rest of the output of the core.

=cut

package Mj::Format;
use strict;
use Mj::Log;

use AutoLoader 'AUTOLOAD';
1;
__END__

sub accept { 
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $arg1, $arg2, $arg2, $ok, $mess, $rreq, $ruser, $rcmd,
      $rmode, $rlist, $rvict, $rarg1, $rarg2, $rarg3, $rtime, $rsessionid,
      @extra) = @_;
  $rreq ||= '';
  my $log = new Log::In 29, "$type, $rreq";
  my ($start, $end);

  if ($ok <= 0) {
    eprint($err, $type, &indicate($mess, $ok));
    return $ok;
  }

  # Print some basic data
  eprint($out, $type, "Token for command:\n    $rcmd\n");
  eprint($out, $type, "issued at: ", scalar gmtime($rtime), " GMT\n");
  eprint($out, $type, "from sessionid: $rsessionid\n");

  # If we accepted a consult token, we can stop now.
  if ($rreq eq 'consult') {
    eprint($out, $type, "was accepted.\n\n");
    return 1;
  }
  eprint($out, $type, "was accepted with these results:\n\n");

  # Then call the appropriate formatting routine to format the real command
  # return.
  my $fun = "Mj::Format::$rreq";
  {
    no strict 'refs';
    # XXX Fix up arg returns here
    return
      &$fun($mj, $out, $err, $type, $ruser, $pass, $auth, $int, $rcmd,
	    $rmode, $rlist, $rvict, $rarg1, $rarg2, $rarg3, @extra);
  }
}

sub alias {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $arg1, $arg2, $arg3, $ok, $mess) = @_;

  if ($ok > 0) { 
    eprint($out, $type, "$arg1 successfully aliased to $user.\n");
  }
  else {
    eprint($out, $type, "$arg1 not successfully aliased to $user.\n");
    eprint($out, $type, &indicate($mess, $ok));
  }
  $ok;
}

sub archive {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $arg1, $arg2, $arg3, $ok, $mess, @in) = @_;
  
  if ($ok > 0) { 
    eprint($out, $type, "$mess");
  }
  else {
    eprint($out, $type, &indicate($mess, $ok));
  }
  $ok;
}

# auxsubscribe and auxunsubscribe are formatted by the sub and unsub
# routines.

# XXX Merge this with who below; they share most of their code.
sub auxwho  {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $sublist, $arg2, $arg3, $ok, $mess) = @_;
  my $log = new Log::In 29, "$type, $list, $sublist";
  my (@lines, @out, @stuff, $chunksize, $count, $error, $i, $ret);  

  if ($ok <= 0) {
    eprint($out, $type, "Could not access $sublist:\n");
    eprint($out, $type, &indicate($mess, $ok));
    return $ok;
  }
  
  # We know we succeeded
  $count = 0;
  @stuff = ($user, $pass, $auth, $int, $cmd, $mode, $list, $vict, $sublist);
  $chunksize = $mj->global_config_get($user, $pass, $auth, $int,
				      "chunksize");
  
  eprint($out, $type, "Members of auxiliary list \"$list/$sublist\":\n");
  
  while (1) {
    ($ret, @lines) = $mj->dispatch('auxwho_chunk', @stuff, $chunksize);
    
    last unless $ret > 0;
    for $i (@lines) {
      $count++;
      eprint($out, $type, "    $i\n");
    }
  }
  $mj->dispatch('auxwho_done', @stuff);
  
  eprintf($out, $type, "%s listed member%s\n",
    ($count || "No"),
    ($count == 1 ? "" : "s"));

  return $ok;
}

sub configdef {}

sub configset {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $var, $args, $arg3, $ok, $mess) = @_;
  my (@arglist);

  @arglist = split("\002", $args);
  eprint($out, $type, indicate($mess, 0)) if $mess;
  if ($ok) {
    eprintf($out, $type, "%s set to \"%s%s\".\n",
	    $var, $arglist[0] || '',
	    $arglist[1] ? "..." : "");
  }
  $ok;
}

sub configshow {}

sub createlist {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $dummy, $vict, $arg1, $arg2, $arg3, $ok, $mess) = @_;
  my $log = new Log::In 29;

  unless ($ok > 0) {
    eprint($out, $type, "Createlist failed.\n");
    eprint($out, $type, &indicate($mess, $ok));
    return $ok;
  }

  eprint($out, $type, "$mess") if $mess;

  $ok;
}

sub filesync {}

sub faq   {g_get("FAQ failed.",   @_)}
sub get   {g_get("Get failed.",   @_)}
sub help  {g_get("Help failed.",  @_)}
sub info  {g_get("Info failed.",  @_)}
sub intro {g_get("Intro failed.", @_)}

sub index {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $dir, $arg2, $arg3, $ok, $mess, @in) = @_;
  my (%legend, @index, @item, @width, $count, $i, $j);
  $count = 0;
  @width = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

  unless ($ok > 0) {
    eprint($out, $type, "Index failed.\n");
    eprint($out, $type, &indicate($mess, $ok));
    return $ok;
  }

  # Split up the index return array
  while (@item = splice(@in, 0, 8)) {
    push @index, [@item];
  }
  
  unless ($mode =~ /nosort/) {
    @index = sort {$a->[0] cmp $b->[0]} @index;
  }

  # Pretty-up the list
  unless ($mode =~ /ugly/) {
    for $i (@index) {
      # Turn path parts into spaces to give an indented look
      unless ($mode =~ /nosort|nodirs/) {
	1 while $i->[0] =~ s!(\s*)[^/]*/(.+)!$1  $2!g;
      }
      # Figure out the optimal width
      for $j (0, 3, 4, 5, 6, 7) {
	$width[$j] = (length($i->[$j]) > $width[$j]) ?
	  length($i->[$j]) : $width[$j];
      }
    }
  }
  $width[0] ||= 50; $width[3] ||= 12; $width[4] ||= 10; $width[5] ||= 12;
  $width[6] ||= 5; $width[7] ||= 5;

  if (@index) {
    eprint($out, $type, "Files in $dir:\n") unless $mode =~ /short/;
    for $i (@index) {
      $count++;
      if ($mode =~ /short/) {
	eprint($out, $type, "  $i->[0]\n");
	next;
      }
      elsif ($mode =~ /long/) {
	eprintf($out, $type,
		"  %2s %-$width[0]s %$width[7]s  %-$width[3]s  %-$width[4]s  %-$width[5]s  %-$width[6]s  %s\n",
		$i->[1], $i->[0], $i->[7], $i->[3], $i->[4], $i->[5], $i->[6], $i->[2]);
      }
      else { # normal
	eprintf($out, $type,
		"  %-$width[0]s %$width[6]d %s\n", $i->[0], $i->[7], $i->[2]);
      }
    }
    return 1 if $mode =~ /short/;
    eprint($out, $type, "\n");
    eprintf($out, $type, "%d file%s.\n", $count,$count==1?'':'s');
  }
  else {
    eprint($out, $type, "No files.\n");
  }
  1;
}

sub lists {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $arg1, $arg2, $arg3, $ok, $defmode, @lists) = @_;
  my (%lists, %legend, @desc, $category, $count, $desc, $flags, $site);
  select $out;
  $count = 0;

  $site   = $mj->global_config_get($user, $pass, $auth, $int, "site_name");
  $site ||= $mj->global_config_get($user, $pass, $auth, $int, "whoami");
  $mode ||= $defmode;

  if (@lists) {
    eprint($out, $type, 
	   "$site serves the following lists:\n\n")
      unless $mode =~ /compact|tiny/;
    
    while (($list, $category, $desc, $flags) = splice(@lists, 0, 4)) {
      # Build the data structure cat->list->[desc, flags]
      $lists{$category}{$list} = [$desc, $flags];
    }

    for $category (sort keys %lists) {
      if (length $category && $mode !~ /tiny/) {
	eprint($out, $type, "$category:\n");
      }
      for $list (sort keys %{$lists{$category}}) {
	$desc  = $lists{$category}{$list}[0];
	$flags = $lists{$category}{$list}[1];
	$count++;
	if ($mode =~ /tiny/) {
	  eprint($out, $type, "$list\n");
	  next;
	}
	$desc ||= "";
	@desc = split(/\n/,$desc);
	$desc[0] ||= "(no description)";
	for (@desc) {
	  $legend{'+'} = 1 if $flags =~ /S/;
	  eprintf($out, $type, " %s%-23s %s\n", 
		  $flags=~/S/ ? '+' : ' ',
		  $list,
		  $_);
	  $list  = '';
	  $flags = '';
	}
	eprint($out, $type, "\n") if $mode =~ /long|enhanced/;
      }
    }
  }
  return 1 if $mode =~ /compact|tiny/;
  eprint($out, $type, "\n") unless $mode =~ /long|enhanced/;
  eprintf($out, $type, "There %s %s list%s.\n", $count==1?("is",$count,""):("are",$count==0?"no":$count,"s"));
  if (%legend) {
    eprint($out, $type, "\n");
    eprint($out, $type, "Legend:\n");
    eprint($out, $type, " + - you are subscribed to the list\n") if $legend{'+'};
  }
  eprint($out, $type, "\n");
  if ($count) {
    eprint($out, $type, "Use the 'info listname' command to get more\n information about a specific list.\n");
  }
  1;
}

sub password {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $pass, $arg2, $arg3, $ok, $mess) = @_;
  my $log = new Log::In 29, "$type";
 
  if ($ok>0) {
    eprint($out, $type, "Password set.\n");
  }
  else {
    eprint($out, $type, "Password not set.\n");
  }
  if ($mess) {
    eprint($out, $type, &indicate($mess, $ok));
  }
  $ok;
}

sub post {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $arg1, $arg2, $arg3, $ok, $mess) = @_;

  select $out;
  if ($ok>0) {
    eprint($out, $type, "Post succeeded.\n");
  }
  else {
    eprint($out, $type, "Post failed.\n");
  }
  eprint($out, $type, indicate($mess, $ok, 1)) if $mess;

  return $ok;
}

sub put {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $file, $desc, $arg3, $ok, $mess) = @_;
  my ($act);

  if    ($file eq '/info' ) {$act = 'Newinfo' }
  elsif ($file eq '/intro') {$act = 'Newintro'}
  elsif ($file eq '/faq'  ) {$act = 'Newfaq'  }
  else                      {$act = 'Put'     }

  select $out;
  if ($ok>0) {
    eprint($out, $type, "$act succeeded.\n");
  }
  else {
    eprint($out, $type, "$act failed.\n");
  }
  eprint($out, $type, indicate($mess, $ok, 1)) if $mess;

  return $ok;
} 

sub register {
  g_sub('reg', @_)
}

sub reject {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $arg1, $arg2, $arg3, $ok, $mess, $token, $rreq,
      $ruser, $rcmd, $rmode, $rlist, $rvict, $rarg1, $rarg2, $rarg3,
      $rtime, $sessionid) = @_;
  my $log = new Log::In 29, "$type, $token";
  
  select $out;
  unless ($ok) {
    eprint($out, $type, indicate($mess, $ok));
    return $ok>0
  }

  eprint($out, $type, "Token '$token' for command:\n    $rcmd\n");
  eprint($out, $type, "issued at: ", scalar gmtime($rtime), " GMT\n");
  eprint($out, $type, "from session: $sessionid\n");
  eprint($out, $type, "has been rejected.  Further information about this\n");
  eprint($out, $type, "rejection is being sent to responsible parties.\n");
  $ok;
}

sub rekey {
 my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $arg1, $arg2, $arg3, $ok, $mess) = @_;
  my $log = new Log::In 29, "$type";
 
 if ($ok>0) {
   eprint($out, $type, "Databases rekeyed.\n");
 }
 else {
   eprint($out, $type, "Databases not rekeyed.\n");
   eprint($out, $type, &indicate($mess, $ok));
 }
 $ok;
}

sub sessioninfo {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $sid, $arg2, $arg3, $ok, $mess, $sess) = @_;

  unless ($ok>0) {
    eprint($out, $type, &indicate($mess, $ok));
    return ($ok>0);
  }
  eprint($out, $type, "Stored information from session $sid\n");
  eprint($out, $type, $sess);
  1;
}


sub set {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $action, $arg, $arg3, $ok, $mess) = @_;
  my $log = new Log::In 29, "$type, $vict";
  $mess ||= '';

  if ($ok>0) {
    eprint($out, $type, "Settings for $vict changed.\n");
  }
  else {
    eprint($out, $type, "Settings for $vict not changed.\n");
  }
  eprint($out, $type, &indicate($mess, $ok, 1));
  1;
}

sub show {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $arg1, $arg2, $arg3, $ok, $addr, $comm, $xform, $alias,
      $aliases, $flag1, $fulladdr, $stripaddr, $lang, $data1, $data2,
      $data3, $data4, $data5, $regtime, $changetime, $lists) =
	splice(@_, 0, 33);
  my $log = new Log::In 29, "$type, $vict";
  my (@lists, $class, $fl, $i, $lchangetime, $lclass, $lflags, $lfull,
      $subtime);

  eprint($out, $type, "  Address: $vict\n");

  # For validation failures, the dispatcher will do the verification and
  # return the error as the second argument.
  if ($ok == 0) {
    eprint($out, $type, "    Address is invalid.\n");
    $addr = prepend('      ', $addr);
    eprint($out, $type, "$addr\n");
    return $ok;
  }
  elsif ($ok < 0) {
    eprint($out, $type, "    Address is valid.\n");
    eprint($out, $type, "      Mailbox: $addr\n") if $addr ne $vict;
    eprint($out, $type, "      Comment: $comm\n") if defined $comm && $comm ne "";
    eprint($out, $type, indicate($xform, $ok));
    return $ok;
  }
   
  eprint($out, $type, "    Address is valid.\n");
  eprint($out, $type, "      Mailbox: $addr\n") if $addr ne $vict;
  eprint($out, $type, "      Comment: $comm\n") if defined $comm && $comm ne "";
  if ($addr ne $xform) {
    eprint($out, $type, "    Address transforms to:\n");
    eprint($out, $type, "      $xform\n");
  }
#  if ($xform ne $alias && $addr ne $alias && $stripaddr && $stripaddr ne $alias) {
  if ($addr ne $alias) {
    eprint($out, $type, "    Address aliased to:\n");
    eprint($out, $type, "      $alias\n");
  }
  if ($aliases) {
    $fl=0;
    for $i (split("\002",$aliases)) {
      next if $i eq $addr;
      eprint($out, $type, "    Address(es) aliased to this address:\n")
	unless ($fl);
      eprint($out, $type, "      $i\n");
      $fl=1;
    }
  }
  
  unless ($flag1) {
    eprint($out, $type, "    Address is not registered.\n");
    return 1;
  }
  eprint($out, $type, "    Address is registered as:\n");
  eprint($out, $type, "      $fulladdr\n");
  eprint($out, $type, "    Registered at ".gmtime($regtime)." GMT.\n");
  eprint($out, $type, "    Registration data last changed at ".gmtime($changetime)." GMT.\n");

  @lists = split("\002", $lists);
  unless (@lists) {
    eprint($out, $type, "    Address is not subscribed to any lists\n");
    return 1;
  }
  eprintf($out, $type, "    Address is subscribed to %s list%s:\n",
	  scalar(@lists), @lists == 1?'':'s');

  for $i (@lists) {
    ($lfull, $class, $subtime, $lchangetime, $lflags) = splice(@_, 0, 5);
    eprint($out, $type, "      $i:\n");
    eprint($out, $type, "        Subscribed as $lfull.\n") if $lfull ne $addr;
    eprint($out, $type, "        Subscribed at ".gmtime($subtime)." GMT.\n");
    eprint($out, $type, "        Receiving $class.\n");
    eprint($out, $type, "        Subscriber flags:\n");
    for $i (split(',',$lflags)) {
      eprint($out, $type, "          $i\n");
    }
    eprint($out, $type, "        Data last changed at ".
	   gmtime($lchangetime)." GMT.\n");
    
  }
  return 1;
}

use Date::Format;
sub showtokens {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $arg1, $arg2, $arg3, $ok, @tokens) = @_;
  my $log = new Log::In 29, "$list";
  my ($count, $tok, $treq, $trequ, $tcmd, $tmode, $tlist, $tvict, $targ1,
      $targ2, $targ3, $ttype, $tapp, $ttime, $tsess, $trem);

  unless (@tokens) {
    eprint($out, $type, "No tokens for $list.\n");
    return 1;
  }

  eprint($out, $type, "Pending tokens for $list:\n");
  if ($list eq 'ALL') {
    eprint($out, $type,
	   "Token          List         Req.    Date                User\n");
  }
  else {
    eprint($out, $type, "Token          Req.    Date                User\n");
  }

  while (($tok, $treq, $trequ, $tcmd, $tmode, $tlist, $tvict, $targ1, $targ2,
	 $targ3, $ttype, $tapp, $ttime, $tsess, $trem) =
	 splice(@tokens, 0, 15))
    {
      $count++;
      
      if ($list eq 'ALL') {
	eprintf($out, $type,
		"%13s %-12s %-7s %19s %s\n",
		$tok, $tlist, substr($treq, 0, 7),
		time2str('%Y-%m-%d %T', $ttime), $trequ);
      }
      else {
	eprintf($out, $type,
		"%13s %-7s %19s %s\n",
		$tok, substr($treq, 0, 7),
		time2str('%Y-%m-%d %T', $ttime), $trequ);
      }
    }
  eprintf($out, $type, "%s token%s shown.\n", $count, $count==1?'':'s');
  1;
}

sub subscribe {
  g_sub('sub', @_)
}

sub tokeninfo {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $token, $arg2, $arg3, $ok, $mess, $treq, $trequ, $tcmd,
      $tmode, $tlist, $tvict, $targ1, $targ2, $targ3, $ttype, $tapprovals,
      $ttime, $tsessid, $tsess) = @_;
  my $log = new Log::In 29, "$token";
  my ($time);
  select $out;

  unless ($ok>0) {
    eprint($out, $type, &indicate($mess, $ok));
    return ($ok>0);
  }
  
  $time = localtime($ttime);

  eprint($out, $type, <<EOM);
Information about token $token:
Generated at: $time
By:           $trequ
From command: $tcmd
EOM

  if ($tsess) {
    eprint($out, $type, "\nInformation about the session ($tsessid):\n$tsess");
  }
  1;
}

sub unalias {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $arg1, $arg2, $arg3, $ok, $mess) = @_;
  my $log = new Log::In 29, "$type, $vict, $arg1";
  if ($ok > 0) { 
    eprint($out, $type, "Alias from $arg1 to $vict successfully removed.\n");
  }
  else {
    eprint($out, $type, "Alias from $arg1 to $vict not successfully removed.\n");
    eprint($out, $type, &indicate($mess, $ok));
  }
  $ok;
}

sub unregister {
  g_sub('unreg', @_);
}

sub unsubscribe {
  g_sub('unsub', @_);
}

sub which {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $arg1, $arg2, $arg3, $ok, $mess, @matches) = @_;
  my $log = new Log::In 29, "$type";
  my ($last_list, $list_count, $match, $total_count, $whoami);

  # Deal with initial failure
  if ($ok <= 0) {
    eprint($out, $type, &indicate($mess, $ok));
    return $ok;
  }

  $whoami = $mj->global_config_get($user, $pass, $auth, $int,
				   'whoami');
  $last_list = ''; $list_count = 0; $total_count = 0;

  # Print the header if we got anything back.  Note that this list is
  # guaranteed to have some addresses if it is nonempty, even if it
  # contains messages.
  if (@matches) {
    if ($mode =~ /regexp/) {
      eprint($out, $type, "The expression '$arg1' matches the following\n");
    }
    else {
      eprint($out, $type, "The string '$arg1' appears in the following\n");
    }
    eprint($out, $type, "entries in lists served by $whoami:\n");
    eprintf($out, $type, "\n%-23s %s\n", "List", "Address");
    eprintf($out, $type, "%-23s %s\n",   "----", "-------");
  }

  while (($list, $match) = splice @matches, 0, 2) {
    
    # If $list is undef, we have a message instead.
    if (!$list) {
      eprint($out, $type, $match);
      next;
    }
    
    if ($list ne $last_list) {
      if ($list_count > 3) {
	eprint($out, $type, "-- $list_count matches this list\n");
      }
      $list_count = 0;
    }
    eprintf($out, $type, "%-23s %s\n", $list, $match);
    $list_count++;
    $total_count++;
    $last_list = $list;
  }

  if ($total_count) {
    eprintf($out, $type, "--- %s match%s total\n\n",
    $total_count, ($total_count == 1 ? "" : "es"));
  }
  else {
    if ($mode =~ /regexp/) {
      eprint($out, $type, "The expression '$arg1' appears in no lists\n");
    }
    else {
      eprint($out, $type, "The string '$arg1' appears in no lists\n");
    }
    eprint($out, $type, "served by $whoami.\n");
  }
  $ok;
}

# XXX Merge this with sub auxwho above.
sub who {
  my ($mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd, $mode,
      $list, $vict, $regexp, $arg2, $arg3, $ok, $mess) = @_;
  $regexp ||= '';
  my $log = new Log::In 29, "$type, $list, $regexp";
  my (@lines, @out, @stuff, $chunksize, $count, $error, $i, $ret);  

  if ($ok <= 0) {
    eprint($out, $type, "Could not access $list:\n");
    eprint($out, $type, &indicate($mess, $ok));
    return $ok;
  }
  
  # We know we succeeded
  $count = 0;
  @stuff = ($user, $pass, $auth, $int, $cmd, $mode, $list, $vict);
  $chunksize = $mj->global_config_get($user, $pass, $auth, $int,
				      "chunksize");
  
  eprint($out, $type, "Members of list \"$list\":\n");
  
  while (1) {
    ($ret, @lines) = $mj->dispatch('who_chunk', @stuff, $regexp, $chunksize);
    
    last unless $ret > 0;
    for $i (@lines) {
      $count++;
      eprint($out, $type, "    $i\n");
    }
  }
  $mj->dispatch('who_done', @stuff);
  
  eprintf($out, $type, "%s listed subscriber%s\n", 
    ($count || "No"),
    ($count == 1 ? "" : "s"));

  return $ok;
}

sub g_get {
  my ($fail, $mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd,
      $mode, $list, $vict, $arg1, $arg2, $arg3, $ok, $mess) = @_;
  my ($chunk, $chunksize);
  select $out;

  unless ($ok>0) {
    eprint($out, $type, "$fail\n");
  }
  eprint($out, $type, indicate($mess, $ok, 1)) if $mess;

  $chunksize = $mj->global_config_get($user, $pass, $auth, $int, "chunksize");

  while (1) {
    ($ok, $chunk) = $mj->dispatch('get_chunk', $user, $pass, $auth,
				  $int, $cmd, $mode, '', '',
				  $chunksize);
    last unless defined $chunk;
    eprint($out, $type, $chunk);
  }

  $mj->dispatch('get_done', $user, $pass, $auth, $int, $cmd, $mode);
  1;
}


=head2 g_sub($act, ..., $ok, $mess)

This function implements reporting subscribe/unsubscribe results (and
auxadd/auxremove results too).  If $arg1 - $arg3 are listrefs, it will
format them as a lists of successes/failures/stalls.  Otherwise it
takes $ok and $mess and figures out whether or not a single request
succeeded.

The listref hack is there so we can report results in bulk when a
bunch of core calls have been made and the results collected;
otherwise, we assume we''re being called from a token acceptance with
a single result.

$act controls the content of various messages; if eq 'sub', we used
"added to", otherwise we use "removed from".

=cut
sub g_sub {
  my ($act, $mj, $out, $err, $type, $user, $pass, $auth, $int, $cmd,
      $mode, $list, $vict, $arg1, $arg2, $arg3, $ok, $mess) = @_;
  my $log = new Log::In 29, "$act, $type";
  my ($fail, $good, $i, $pend);

  $tok = 0;
  if ($act eq 'sub') {
    $act = 'added to ';
  }
  elsif ($act eq 'reg') {
    $act = 'registered'; $list = '';
  }
  elsif ($act eq 'unreg') {
    $act = 'unregistered and removed from all lists'; $list = '';
  }
  else {
    $act = 'removed from ';
  }

  # If $arg1 isn't a listref, assume we're formating a single address
  # notice that came from a token acceptance and fake things up so
  # they look like a multi-address format.
  unless (ref($arg1) eq 'ARRAY') {
    $arg1 = []; $arg2 = []; $arg3 = [];
    if ($ok > 0) {
      push @$arg1, ($vict, $mess);
    }
    elsif ($ok == 0) {
      push @$arg2, ($vict, $mess);
    }
    else {
      push @$arg3, ($vict, $mess);
    }
  }

  # Now print the multi-address format.
  if (@$arg1) {
    $good = 1;
    eprintf($out, $type, ("The following address%s%s%s:\n",
		 @$arg1==2 ? " was " : "es were ",
		 $act, $list));
    while (($i, $mess) = splice @$arg1, 0, 2) {
      eprint($out, $type, "  $i\n");
      if ($mess) {
	$mess = prepend('    ', $mess);
	eprint($out, $type, "$mess\n");
      }
    }
  }
  if (@$arg2) {
    $fail = 1;
    eprint($out, $type, "\n") if @$arg1;
    eprintf($out, $type, ("**** The following %s not successfully %s%s:\n",
		 @$arg2==2 ? "was" : "were", $act, $list));
    while (($i, $mess) = splice @$arg2, 0, 2) {
      eprint($out, $type, "  $i\n");
      if ($mess) {
	$mess = prepend('    ', $mess);
	eprint($out, $type, "$mess\n");
      }
    }
  }
  if (@$arg3) {
    $pend = 1;
    eprint($out, $type, "\n") if @$arg1 || @$arg2;
    eprintf($out, $type, ("**** The following require%s additional action:\n",
		 @$arg3==2 ? "s" : ""));
    while (($i, $mess) = splice @$arg3, 0, 2) {
      eprint($out, $type, "  $i\n");
      if ($mess) {
	$mess = prepend('    ', $mess);
	eprint($out, $type, "$mess\n");
      }
    }
  }
  return  1 if $good && !($fail || $pend);
  return  0 if $fail && !($good || $pend);
  return -1 if $pend && !($good || $fail);
  return undef;
}

sub eprint {
  my $fh   = shift;
  my $type = shift;
  if ($type eq 'html') {
    print $fh &escape(join('', @_));
  }
  else {
    print $fh @_;
  }
}

sub eprintf {
  my $fh   = shift;
  my $type = shift;
  if ($type eq 'html') {
    print $fh &escape(sprintf(shift, @_));
  }
  else {
    printf $fh @_;
  }
}

# Basic idea from HTML::Stream, 
sub escape {
  local $_ = shift;
  my %esc = ( '&'=>'amp', '"'=>'quot', '<'=>'lt', '>'=>'gt');
  s/([<>\"&])/\&$esc{$1};/mg; 
  s/([\x80-\xFF])/'&#'.unpack('C',$1).';'/eg;
  $_;
}


# Prepends a string to every line of a string
sub prepend {
  my $pre = shift;
  $pre . join("$pre",split(/^/,shift));
}

# Prepends an indicator to a message, if necessary.  Indicators are
# nothing if the flag is 1, **** (indicating failure) if the flag is
# 0, and ---- (indicating a stall) if the flag is -1.  If $indent is
# true, the OK case will be indented five spaces to match the other
# returns.
sub indicate {
  my ($mess, $ok, $indent) = @_;
  if ($ok>0) {
    return $mess;
  }
  if ($ok<0) {
    return prepend('---- ', $mess);
  }
  return prepend('**** ',$mess);
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
### cperl-extra-perl-args:"-I/home/tibbs/mj/2.0/blib/lib" ***
### End: ***


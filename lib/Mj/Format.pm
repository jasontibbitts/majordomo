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
use IO::File;

use AutoLoader 'AUTOLOAD';
1;
__END__

sub accept { 
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($ok, $mess, $token, $data, $rresult, @tokens);

  @tokens = @$result;
  while (@tokens) {
    $ok  =  shift @tokens;
    ($mess, $data, $rresult) = @{shift @tokens};
    if ($ok <= 0) {
      eprint($err, $type, &indicate($mess, $ok));
      next;
    }

    # Print some basic data
    eprint($out, $type, "Token for command:\n    $data->{'cmdline'}\n");
    eprint($out, $type, "issued at: ", scalar gmtime($data->{'time'}), " GMT\n");
    eprint($out, $type, "from sessionid: $data->{'sessionid'}\n");

    # If we accepted a consult token, we can stop now.
    if ($data->{'type'} eq 'consult') {
      eprint($out, $type, "was accepted.\n\n");
      next;
    }
    eprint($out, $type, "was accepted with these results:\n\n");

    # Then call the appropriate formatting routine to format the real command
    # return.
    my $fun = "Mj::Format::$data->{'command'}";
    {
      no strict 'refs';
      &$fun($mj, $out, $err, $type, $data, $rresult);
    }
  }
}

sub alias {
  my ($mj, $out, $err, $type, $request, $result) = @_;

  my ($ok, $mess) = @$result;
  if ($ok > 0) { 
    eprint($out, $type, "$request->{'newaddress'} successfully aliased to $request->{'user'}.\n");
  }
  else {
    eprint($out, $type, "$request->{'newaddress'} not aliased to $request->{'user'}.\n");
    eprint($out, $type, &indicate($mess, $ok));
  }
  $ok;
}

sub archive {
  my ($mj, $out, $err, $type, $request, $result) = @_;
 
  my ($chunksize, $data, $i, $line, $lines, $mess, @tmp);
  my ($ok, @msgs) = @$result;

  if ($ok <= 0) { 
    eprint($out, $type, &indicate($msgs[0], $ok));
    return $ok;
  }
  unless (@msgs) {
    eprint($out, $type, "No messages were found.\n");
    return 1;
  }

  $request->{'command'} = "archive_chunk";

  # XXX Make this configurable so that it uses limits on
  # number of messages per digest or size of digest.
  if ($request->{'mode'} =~ /get/) {
    $chunksize = 
      $mj->global_config_get($request->{'user'}, $request->{'password'}, 
                             $request->{'auth'}, $request->{'interface'}, 
                             "chunksize");

    $lines = 0; @tmp = ();
    # Chunksize is 1000 lines by default.  If a group
    # of messages exceeds that size, dispatch the request
    # and print the result.
    for ($i = 0; $i <= $#msgs; $i++) {
      ($msg, $data) = @{$msgs[$i]};
      push @tmp, [$msg, $data];
      $lines += $data->{'lines'};
      if ($lines > $chunksize or $i == $#msgs) {
        ($ok, $mess) = @{$mj->dispatch($request, [@tmp])};
        $lines = 0; @tmp = ();
        eprint($out, $type, indicate($mess, $ok));
      }
    }
  }
  else {
    for $i (@msgs) {
      $data = $i->[1];
      $data->{'subject'} ||= "(no subject)";
      $data->{'from'} ||= "(author unknown)";
      $line = sprintf "%-10s : %s\n  %-50s %6d lines, %6d bytes\n\n", 
        $i->[0], $data->{'subject'}, $data->{'from'},
        $data->{'body_lines'}, $data->{'bytes'};
      eprint ($out, $type, $line);
    }
  }
 
  #  archive_done does nothing, so there is no need to call it.
  $ok;
}

# auxsubscribe and auxunsubscribe are formatted by the sub and unsub
# routines.
sub auxadd {
  subscribe(@_);
}

sub auxremove {
  unsubscribe(@_);
}

# XXX Merge this with who below; they share most of their code.
sub auxwho  {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'list'}, $request->{'sublist'}";
  my (@lines, $chunksize, $count, $error, $i, $ret);  

  my ($ok, $mess) = @$result;

  if ($ok <= 0) {
    eprint($out, $type, "Could not access $request->{'sublist'}:\n");
    eprint($out, $type, &indicate($mess, $ok));
    return $ok;
  }
  
  # We know we succeeded
  $count = 0;
  $chunksize = $mj->global_config_get($request->{'user'}, $request->{'password'},                                       $request->{'auth'}, $request->{'interface'},
                                      "chunksize");
  
  eprint($out, $type, "Members of auxiliary list \"$request->{'list'}:$request->{'sublist'}\":\n");
  
  $request->{'command'} = "auxwho_chunk";

  while (1) {
    ($ret, @lines) = 
      @{$mj->dispatch($request, $chunksize)};
    
    
    last unless $ret > 0;
    for $i (@lines) {
      $count++;
      eprint($out, $type, "  $i\n");
    }
  }
  $request->{'command'} = "auxwho_done";
  $mj->dispatch($request);
  
  eprintf($out, $type, "%s listed member%s\n",
    ($count || "No"),
    ($count == 1 ? "" : "s"));

  return $ok;
}

sub configdef {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'list'}";
  my ($ok, $mess, @arglist, $varresult, $var);

  for $varresult (@$result) {
    ($ok, $mess, $var) = @$varresult;

    eprint ($out, $type, indicate($mess,$ok)) if $mess;
    if ($ok) {
      eprintf($out, $type, "%s set to default value.\n", $var);
    }
  }
}

sub changeaddr {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'user'}";
  my ($ok, $mess) = @$result;

  if ($ok > 0) { 
    eprint($out, $type, "Address changed from $request->{'victim'} to $request->{'user'}.\n");
  }
  elsif ($ok < 0) {
    eprint($out, $type, "Change from $request->{'victim'} to $request->{'user'} stalled, awaiting approval.\n");
  }
  else {
    eprint($out, $type, "Address not changed from $request->{'vict'} to $request->{'user'}.\n");
    eprint($out, $type, &indicate($mess, $ok));
  }
  $ok;
}

sub configset {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'list'}";
  my ($ok, $mess) = @$result;
  eprint($out, $type, indicate($mess, $ok)) if $mess;
  if ($ok) {
    eprintf($out, $type, "%s set to \"%s%s\".\n",
            $request->{'setting'}, ${$request->{'value'}}[0] || '',
            ${$request->{'value'}}[1] ? "..." : "");
  }
  $ok;
}

sub configshow {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'list'}";
  my ($ok, $mess, $varresult, $var, $val, $tag, $auto);

  $ok = shift @$result;
  for $varresult (@$result) {
    ($ok, $mess, $var, $val) = @$varresult;
    if (! $ok) {
      eprint($out, $type, indicate($mess, $ok));
      return 0;
    }
    if ($request->{'mode'} !~ /nocomments/) {
      $mess =~ s/^/# /gm;
      eprint($out, $type, indicate($mess, 1));
    }
    $auto = '';
    if ($ok < 1) {
      $auto = '# ';
      $mess = "# This variable is automatically maintained by Majordomo.  Uncomment to change.\n";
      eprint($out, $type, indicate($mess, 1));
    }

    if (ref ($val) eq 'ARRAY') {
      # Process as an array
      $tag = Majordomo::unique2();
      eprint ($out, $type, 
              indicate("${auto}configset $request->{'list'} $var \<\< END$tag\n", 1));
      for (@$val) {
          eprint ($out, $type, indicate("$auto$_", 1)) if defined $_;
      }
      eprint ($out, $type, indicate("${auto}END$tag\n\n", 1));
    }
    else {
      # Process as a simple variable
      $val ||= "";
      if (length $val > 40) {
        eprint ($out, $type, 
          indicate("${auto}configset $request->{'list'} $var =\\\n    $auto$val\n", 1));
      }
      else {
        eprint ($out, $type, indicate("${auto}configset $request->{'list'} $var = $val\n", 1));
      }
      if ($request->{'mode'} !~ /nocomments/) {
        print $out "\n";
      }
    }
  }
  1;
}

sub createlist {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29;

  my ($ok, $mess) = @$result;

  unless ($ok > 0) {
    eprint($out, $type, "Createlist failed.\n");
    eprint($out, $type, &indicate($mess, $ok));
    return $ok;
  }

  eprint($out, $type, "$mess") if $mess;

  $ok;
}

sub digest {
  my ($mj, $out, $err, $type, $request, $result) = @_;

  my ($ok, $mess) = @$result;
  unless ($ok > 0) {
    eprint($out, $type, "Digest-$request->{'mode'} failed.\n");
    eprint($out, $type, &indicate($mess, $ok));
    return $ok;
  }

  eprint($out, $type, "$mess") if $mess;

  $ok;
}

sub faq   {g_get("FAQ failed.",   @_)}
sub get   {g_get("Get failed.",   @_)}
sub help  {g_get("Help failed.",  @_)}
sub info  {g_get("Info failed.",  @_)}
sub intro {g_get("Intro failed.", @_)}

sub index {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my (%legend, @index, @item, @width, $count, $i, $j);
  $count = 0;
  @width = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

  my ($ok, @in) = @$result;
  unless ($ok > 0) {
    eprint($out, $type, "Index failed.\n");
    eprint($out, $type, &indicate($in[0], $ok)) if $in[0];
    return $ok;
  }

  # Split up the index return array
  while (@item = splice(@in, 0, 8)) {
    push @index, [@item];
  }
  
  unless ($request->{'mode'} =~ /nosort/) {
    @index = sort {$a->[0] cmp $b->[0]} @index;
  }

  # Pretty-up the list
  unless ($request->{'mode'} =~ /ugly/) {
    for $i (@index) {
      # Turn path parts into spaces to give an indented look
      unless ($request->{'mode'} =~ /nosort|nodirs/) {
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
    eprint($out, $type, length($request->{'path'}) ?"Files in $request->{'path'}:\n" : "Public files:\n")
      unless $request->{'mode'} =~ /short/;
    for $i (@index) {
      $count++;
      if ($request->{'mode'} =~ /short/) {
        eprint($out, $type, "  $i->[0]\n");
        next;
      }
      elsif ($request->{'mode'} =~ /long/) {
        eprintf($out, $type,
                "  %2s %-$width[0]s %$width[7]s  %-$width[3]s  %-$width[4]s  %-$width[5]s  %-$width[6]s  %s\n",
                $i->[1], $i->[0], $i->[7], $i->[3], $i->[4], $i->[5], $i->[6], $i->[2]);
      }
      else { # normal
        eprintf($out, $type,
                "  %-$width[0]s %$width[6]d %s\n", $i->[0], $i->[7], $i->[2]);
      }
    }
    return 1 if $request->{'mode'} =~ /short/;
    eprint($out, $type, "\n");
    eprintf($out, $type, "%d file%s.\n", $count,$count==1?'':'s');
  }
  else {
    eprint($out, $type, "No files.\n");
  }
  1;
}

sub lists {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my (%lists, %legend, @desc, $list, $category, $count, $desc, $flags, $site);
  select $out;
  $count = 0;

  $site   = $mj->global_config_get($request->{'user'}, $request->{'pass'}, 
                                   $request->{'auth'}, $request->{'interface'}, 
                                   "site_name");
  $site ||= $mj->global_config_get($request->{'user'}, $request->{'pass'}, 
                                   $request->{'auth'}, $request->{'interface'}, 
                                   "whoami");

  my ($ok, $defmode, @lists) = @$result;

  if ($ok <= 0) {
    eprint($out, $type, "Lists failed: $defmode\n");
    return 1;
  }
  $request->{'mode'} ||= $defmode;
  
  if (@lists) {
    eprint($out, $type, 
           "$site serves the following lists:\n\n")
      unless $request->{'mode'} =~ /compact|tiny/;
    
    while (@lists) {
      ($list, $category, $desc, $flags) = @{shift @lists};
      # Build the data structure cat->list->[desc, flags]
      $lists{$category}{$list} = [$desc, $flags];
    }

    for $category (sort keys %lists) {
      if (length $category && $request->{'mode'} !~ /tiny/) {
        eprint($out, $type, "$category:\n");
      }
      for $list (sort keys %{$lists{$category}}) {
        $desc  = $lists{$category}{$list}->[0];
        $flags = $lists{$category}{$list}->[1];
        if ($request->{'mode'} =~ /tiny/) {
          eprint($out, $type, "$list\n");
          next;
        }
        $desc ||= "";
        $count++ unless ($desc =~ /auxiliary list/);
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
        eprint($out, $type, "\n") if $request->{'mode'} =~ /long|enhanced/;
      }
    }
  }
  return 1 if $request->{'mode'} =~ /compact|tiny/;
  eprint($out, $type, "\n") unless $request->{'mode'} =~ /long|enhanced/;
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
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type";

  my ($ok, $mess) = @$result; 

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
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($i, $ok, $mess); 
 
  $request->{'command'} = "post_chunk"; 
 
  # The message will have been posted already if this subroutine
  # is called by Mj::Token::t_accept . 
  if (exists $request->{'message'}) { 
    while (1) {
      $i = shift @{$request->{'message'}};
      last unless defined $i;
      # Mj::Parser creates an argument list without line feeds.
      $i .= "\n";
     
      # YYY  Needs check for errors 
      ($ok, $mess) = @{$mj->dispatch($request, $i)};
    }
    

    $request->{'command'} = "post_done"; 
    ($ok, $mess) = @{$mj->dispatch($request)};
  }
  else {
    ($ok, $mess) = @$result;
  }

  if ($ok>0) {
    eprint($out, $type, "Post succeeded.\nDetails:\n");
  }
  elsif ($ok<0) {
    eprint($out, $type, "Post stalled, awaiting approval.\nDetails:\n");
  }
  else {
    eprint($out, $type, "Post failed.\nDetails:\n");
  }
  eprint($out, $type, indicate($mess, $ok, 1)) if $mess;

  return $ok;
}

sub put {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($act, $i);
  my ($ok, $mess) = @$result;

  my ($chunksize) = $mj->global_config_get(undef, undef, undef, 
                           $request->{'interface'}, "chunksize") * 80;

  $request->{'command'} = "put_chunk"; 

  while (1) {
    $i = shift @{$request->{'contents'}};
    # Tack on a newline if pulling from a here doc
    if (defined($i)) {
      $i .= "\n";
      $chunk .= $i;
    }      
    if (length($chunk) > $chunksize || !defined($i)) {
      ($ok, $mess) = @{$mj->dispatch($request, $chunk)};
    }
    last unless (defined ($i) and $ok > 0);
  }

  $request->{'command'} = "put_done"; 
  ($ok, $mess) = @{$mj->dispatch($request)};

  if    ($request->{'file'} eq '/info' ) {$act = 'Newinfo' }
  elsif ($request->{'file'} eq '/intro') {$act = 'Newintro'}
  elsif ($request->{'file'} eq '/faq'  ) {$act = 'Newfaq'  }
  else                      {$act = 'Put'     }

  if ($ok > 0) {
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
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type";
  my ($token, $data, @tokens, $ok, $res);

  @tokens = @$result; 

  while (@tokens) { 
    ($ok, $res) = splice @tokens, 0, 2;
    ($token, $data) = @$res;
    unless ($ok) {
      eprint($out, $type, indicate($token, $ok));
      next;
    }
    eprint($out, $type, "Token '$token' for command:\n    $data->{'cmdline'}\n");
    eprint($out, $type, "issued at: ", scalar gmtime($data->{'time'}), " GMT\n");
    eprint($out, $type, "from session: $data->{'sessionid'}\n");
    eprint($out, $type, "has been rejected.  Further information about this\n");
    eprint($out, $type, "rejection is being sent to responsible parties.\n\n");
  }

  1;
}

sub rekey {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type";

  my ($ok, $mess) = @$result; 
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
  my ($mj, $out, $err, $type, $request, $result) = @_;

  my ($ok, $sess) = @$result; 
  unless ($ok>0) {
    eprint($out, $type, &indicate($sess, $ok)) if $sess;
    return ($ok>0);
  }
  eprint($out, $type, "Stored information from session $request->{'sessionid'}\n");
  g_get("Sessioninfo failed.", @_);
}


sub set {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'victim'}";
  my ($ok, $change, @changes);
 
  @changes = @$result; 
  while (@changes) {
    ($ok, $change) = splice @changes, 0, 2;
    if ($ok > 0) {
        eprint($out,
         $type,
         &indicate("New settings for $change->{'victim'}->{'stripaddr'} on $change->{'list'}:\n".
           "  Receiving $change->{'classdesc'}\n".
           "  Flags:\n    ".
           join("\n    ", @{$change->{'flagdesc'}}).
           "\n(see 'help set' for full explanation)\n",
           $ok, 1)
        );
    }
    # deal with partial failure
    else {
        eprint($out, $type, &indicate("$change\n", $ok, 1));
    }
  }

  1;
}

sub show {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'victim'}";
  my (@lists, $bouncedata, $strip);
  my ($ok, $data) = @$result;
    
  $strip = $data->{strip};

  # use Data::Dumper; print $out Dumper $data;

  eprint($out, $type, "  Address: $request->{'victim'}\n");

  # For validation failures, the dispatcher will do the verification and
  # return the error as the second argument.  For normal denials, $ok is
  # also 0, but a hashref is returned containing what information we could
  # get from the address.
  if ($ok == 0) {
    if (ref($data)) {
      eprint($out, $type, "    Show failed.\n");
      eprint($out, $type, prepend('    ',"$data->{error}\n"));
    }
    else {
      eprint($out, $type, "    Address is invalid.\n");
      eprint($out, $type, prepend('    ',"$data\n"));
    }
     
    eprint($out, $type, "    Address is valid.\n");
    eprint($out, $type, "      Mailbox: $strip\n")
      if $strip ne $request->{'victim'}->strip;
    eprint($out, $type, "      Comment: $data->{comment}\n")
      if defined $data->{comment} && length $data->{comment};
    eprint($out, $type, indicate($data->{error}, $ok));
    return $ok;
  }

  eprint($out, $type, "    Address is valid.\n");
  eprint($out, $type, "      Mailbox: $strip\n")
    if $strip ne $request->{'victim'}->strip;
  eprint($out, $type, "      Comment: $data->{comment}\n")
    if defined $data->{comment} && length $data->{comment};

  if ($strip ne $data->{xform}) {
    eprint($out, $type, "    Address transforms to:\n");
    eprint($out, $type, "      $data->{xform}\n");
  }
  if ($strip ne $data->{alias}) {
    eprint($out, $type, "    Address aliased to:\n");
    eprint($out, $type, "      $data->{alias}\n");
  }
  $fl=0;
  for $i (@{$data->{aliases}}) {
    next if $i eq $strip;
    eprint($out, $type, "    Address(es) aliased to this address:\n")
      unless ($fl);
    eprint($out, $type, "      $i\n");
    $fl=1;
  }

  unless ($data->{regdata}) {
    eprint($out, $type, "    Address is not registered.\n");
    return 1;
  }
  eprint($out, $type, "    Address is registered as:\n");
  eprint($out, $type, "      $data->{regdata}{fulladdr}\n");
  eprint($out, $type, "    Registered at ".gmtime($data->{regdata}{regtime})." GMT.\n");
  eprint($out, $type, "    Registration data last changed at ".
	 gmtime($data->{regdata}{changetime})." GMT.\n");

  @lists = keys %{$data->{lists}};
  unless (@lists) {
    eprint($out, $type, "    Address is not subscribed to any lists.\n");
    return 1;
  }
  eprintf($out, $type, "    Address is subscribed to %s list%s:\n",
	  scalar(@lists), @lists == 1?'':'s');

  for $i (@lists) {
    eprint($out, $type, "      $i:\n");
    eprint($out, $type, "        Subscribed as $data->{lists}{$i}{fulladdr}.\n")
      if $data->{lists}{$i}{fulladdr} ne $strip;
    eprint($out, $type, "        Subscribed at ".gmtime($data->{lists}{$i}{subtime})." GMT.\n");
    eprint($out, $type, "        Receiving $data->{lists}{$i}{classdesc}.\n");
    eprint($out, $type, "        Subscriber flags:\n");
    for $i (@{$data->{lists}{$i}{flags}}) {
      eprint($out, $type, "          $i\n");
    }
    $bouncedata = $data->{lists}{$i}{bouncedata};
    if ($bouncedata) {
      if (keys %{$bouncedata->{M}}) {
	eprint($out, $type, "        Has bounced the following messages:\n          ");
	eprint($out, $type, join(" ", keys %{$bouncedata->{M}})."\n" );
	if (@{$bouncedata->{UM}}) {
	  eprint($out, $type, "          (plus ".scalar(@{$bouncedata->{UM}})." unnumbered messages).\n");
	}
      }
      elsif (@{$bouncedata->{UM}}) {
	eprint($out, $type, "        Has bounced ".scalar(@{$bouncedata->{UM}})." unnumbered messages.\n");
      }
    }
    eprint($out, $type, "        Data last changed at ".
	   gmtime($data->{lists}{$i}{changetime})." GMT.\n");

  }
  1;
}

use Date::Format;
sub showtokens {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$request->{'list'}";
  my ($count, $token, $data);

  my ($ok, @tokens) = @$result;
  unless (@tokens) {
    eprint($out, $type, "No tokens for $request->{'list'}.\n");
    return 1;
  }
  unless ($ok>0) {
    eprint($out, $type, "No tokens shown.\n");
    eprint($out, $type, &indicate("$tokens[0]\n", $ok, 1));
    return 1;
  }

  eprint($out, $type, "Pending tokens for $request->{'list'}:\n");
  if ($request->{'list'} eq 'ALL') {
    eprint($out, $type,
           "Token          List         Req.    Date                User\n");
  }
  else {
    eprint($out, $type, "Token          Req.    Date                User\n");
  }

  while (@tokens) {
    ($token, $data) = splice @tokens, 0, 2;
    $count++;
      
    if ($request->{'list'} eq 'ALL') {
      eprintf($out, $type,
              "%13s %-12s %-7s %19s %s\n",
              $token, $data->{'list'}, substr($data->{'command'}, 0, 7),
              time2str('%Y-%m-%d %T', $data->{'time'}), $data->{'user'});
    }
    else {
      eprintf($out, $type,
              "%13s %-7s %19s %s\n",
              $token, substr($data->{'command'}, 0, 7),
              time2str('%Y-%m-%d %T', $data->{'time'}), $data->{'user'});
    }
  }
  eprintf($out, $type, "%s token%s shown.\n", $count, $count==1?'':'s');
  1;
}

sub subscribe {
  g_sub('sub', @_)
}

sub tokeninfo {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$request->{'token'}";
  my ($time);
  my ($ok, $data, $sess) = @$result;

  unless ($ok > 0) {
    eprint($out, $type, &indicate($data, $ok));
    return $ok;
  }
  
  $time = localtime($data->{'time'});

  eprint($out, $type, <<EOM);
Information about token $request->{'token'}:
Generated at: $time
By:           $data->{'user'}
Type:         $data->{'type'}
From command: $data->{'cmdline'}
EOM

  # Indicate reasons
  if ($data->{'arg2'}) {
    @reasons = split "\002", $data->{'arg2'};
    for (@reasons) {
      eprint($out, $type, "Reason: $_\n");
    }
  }
  if ($sess) {
    $request->{'sessionid'} = $data->{'sessionid'};
    Mj::Format::sessioninfo($mj, $out, $err, $type, $request, [1, '']);
  }

  1;
}

sub unalias {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'user'}, $request->{'victim'}";
  my ($ok, $mess) = @$result;

  if ($ok > 0) { 
    eprint($out, $type, "Alias from $request->{'victim'} to $request->{'user'} successfully removed.\n");
  }
  else {
    eprint($out, $type, "Alias from $request->{'victim'} to $request->{'user'} not removed.\n");
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
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type";
  my ($last_list, $list_count, $match, $total_count, $whoami, $list, $match);

  my ($ok, @matches) = @$result;
  # Deal with initial failure
  if ($ok <= 0) {
    eprint($out, $type, &indicate($matches[0], $ok)) if $matches[0];
    return $ok;
  }

  $whoami = $mj->global_config_get($request->{'user'}, $request->{'password'}, 
                                   $request->{'auth'}, $request->{'int'}, 'whoami');
  $last_list = ''; $list_count = 0; $total_count = 0;

  # Print the header if we got anything back.  Note that this list is
  # guaranteed to have some addresses if it is nonempty, even if it
  # contains messages.
  if (@matches) {
    if ($request->{'mode'} =~ /regexp/) {
      eprint($out, $type, "The expression \"$request->{'regexp'}\" matches the following\n");
    }
    else {
      eprint($out, $type, "The string \"$request->{'regexp'}\" appears in the following\n");
    }
    eprint($out, $type, "entries in lists served by $whoami:\n");
    eprintf($out, $type, "\n%-23s %s\n", "List", "Address");
    eprintf($out, $type, "%-23s %s\n",   "----", "-------");
  }

  while (@matches) {
    ($list, $match) = @{shift @matches};

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
    if ($request->{'mode'} =~ /regexp/) {
      eprint($out, $type, "The expression \"$request->{'regexp'}\" appears in no lists\n");
    }
    else {
      eprint($out, $type, "The string \"$request->{'arg1'}\" appears in no lists\n");
    }
    eprint($out, $type, "served by $whoami.\n");
  }
  $ok;
}

# XXX Merge this with sub auxwho above.
sub who {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'list'}, $request->{'regexp'}";
  my (@lines, @out, @stuff, $chunksize, $count, $error, $i, $ind, $ret);
  my ($template, $subs, $fh, $line, $mess);

  my ($ok, $regexp, $tmpl) = @$result;
  if ($ok <= 0) {
    eprint($out, $type, "Could not access $request->{'list'}:\n");
    eprint($out, $type, &indicate($regexp, $ok)) if $regexp;
    return $ok;
  }

  # We know we succeeded
  $count = 0;
  $chunksize = $mj->global_config_get($request->{'user'}, $request->{'password'}, 
                                      $request->{'auth'}, $request->{'interface'},
                                      "chunksize");
  return 0 unless $chunksize;  

  $ind = $template = '';

  unless ($request->{'mode'} =~ /export|short/) {
    eprint($out, $type, "Members of list \"$request->{'list'}\":\n");
    $ind = '  ';
  }

  if (ref ($tmpl) eq 'ARRAY') {
    $template = join ("", @$tmpl);
  }
  elsif ($request->{'list'} eq 'GLOBAL') {
    $template = '$FULLADDR $PAD $LISTS';
  }
  else {
    $template = '$FULLADDR $PAD $FLAGS $CLASS';
  }
 
  $request->{'command'} = "who_chunk";
 
  while (1) {
    ($ok, @lines) = @{$mj->dispatch($request, $chunksize)};
    
    last unless $ok > 0;
    for $i (@lines) {
      $subs = {};
      next unless (ref ($i) eq 'HASH');
      if ($request->{'mode'} =~ /enhanced/) {
        for $j (keys %$i) {
          $subs->{uc $j} = $i->{$j};
        }
        $subs->{'PAD'} = " " x (48 - length($i->{'fulladdr'}));
        if ($request->{'list'} ne 'GLOBAL') {
          my ($fullclass) = $i->{'class'};
          $fullclass .= "-" . $i->{'classarg'} if ($i->{'classarg'});
          $fullclass .= "-" . $i->{'classarg2'} if ($i->{'classarg2'});
          $subs->{'CLASS'} = $fullclass;
        }
        else {
          $subs->{'LISTS'} =~ s/\002/ /g;
        }
        my (@time) = localtime($i->{'changetime'});
        $subs->{'LASTCHANGE'} = 
          sprintf "%4d-%.2d-%.2d", $time[5]+1900, $time[4]+1, $time[3];
        $line = $mj->substitute_vars_string($template, $subs);
        chomp $line;
      }
      elsif ($request->{'mode'} =~ /export/ && $i->{'classdesc'} && $i->{'flagdesc'}) {
	$line = "subscribe-nowelcome $i->{'fulladdr'}\n";
	if ($i->{'origclassdesc'}) {
	  $line .= "set $i->{'origclassdesc'} $i->{'stripaddr'}\n";
	}
	$line .= "set $i->{'classdesc'},$i->{'flagdesc'} $i->{'stripaddr'}\n";
      }
      else {
        $line = $i->{'fulladdr'};
      }

      $count++;
      eprint($out, $type, "$ind$line\n");
      if ($request->{'mode'} =~ /bounces/ && exists $i->{'bouncestats'}) {
        my $tmp = "$ind  Bounces in the past week: $i->{'bouncestats'}->{'week'}\n";
        eprint($out, $type, $tmp);
      }
    }
  }
  $request->{'command'} = "who_done";
  $mj->dispatch($request);
  
  unless ($request->{'mode'} =~ /short|export/) {
    eprintf($out, $type, "%s listed subscriber%s\n", 
            ($count || "No"),
            ($count == 1 ? "" : "s"));
  }

  1;
}

sub g_get {
  my ($fail, $mj, $out, $err, $type, $request, $result) = @_;
  my ($chunk, $chunksize);
  my ($ok, $mess) = @$result;

  unless ($ok>0) {
    eprint($out, $type, "$fail\n");
  }
  eprint($out, $type, indicate($mess, $ok, 1)) if $mess;

  $chunksize = $mj->global_config_get($request->{'user'}, $request->{'password'},
                                      $request->{'auth'}, $request->{'int'}, 
                                      "chunksize");

  $request->{'command'} = "get_chunk";

  while (1) {
    ($ok, $chunk) = @{$mj->dispatch($request, $chunksize)};
    last unless defined $chunk;
    eprint($out, $type, $chunk);
  }

  $request->{'command'} = "get_done";
  $mj->dispatch($request);
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
  my ($act, $mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$act, $type";
  my ($addr, $i, $ok, @res);

  if ($act eq 'sub') {
    $act = 'added to LIST';
  }
  elsif ($act eq 'reg') {
    $act = 'registered'; 
  }
  elsif ($act eq 'unreg') {
    $act = 'unregistered and removed from all lists'; 
  }
  else {
    $act = 'removed from LIST';
  }

  @res = @$result;
  unless (scalar (@res)) {
    eprint($out, $type, "No addresses found\n");
    return 1;
  }
  # Now print the multi-address format.
  while (@res) {
    ($ok, $addr) = splice @res, 0, 2;
    unless ($ok > 0) {
      eprint($out, $type, "$addr\n");
      next;
    }
    for (@$addr) {
      my ($verb) = ($ok > 0)?  $act : "not $act";
      $verb =~ s/LIST/$request->{'list'}/;
      if (exists $request->{'sublist'}) {
        $verb .= ":$request->{'sublist'}";
      }
      eprint($out, $type, "$_ was $verb.\n");
    }
  }
  1;
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

Copyright (c) 1997-2000 Jason Tibbitts for The Majordomo Development
Group.  All rights reserved.

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
### cperl-extra-perl-args:"-I/home/tibbs/mj/2.0/blib/lib" ***
### End: ***


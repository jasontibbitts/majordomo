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
  errfh - a filehandle to send error output to
  output_type - text, wwwadm, or wwwusr
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
  my ($command, $ok, $mess, $token, $data, $rresult, @tokens);

  @tokens = @$result;
  while (@tokens) {
    $ok  =  shift @tokens;
    if ($ok == 0) {
      $mess = shift @tokens;
      eprint($err, $type, &indicate($mess, $ok));
      next;
    }
    ($mess, $data, $rresult) = @{shift @tokens};
    if ($ok < 0) {
      eprint($err, $type, &indicate($mess, $ok));
      next;
    }

    $command = $data->{'command'};
    # Print some basic data
    eprint($out, $type, "Token for command:\n    $data->{'cmdline'}\n");
    eprint($out, $type, "issued at: ", scalar gmtime($data->{'time'}), " GMT\n");
    eprint($out, $type, "from sessionid: $data->{'sessionid'}\n");

    # If we accepted a consult token, we can stop now.
    if ($data->{'type'} eq 'consult') {
      eprint($out, $type, "was accepted.\n");
      if ($data->{'ack'}) {
        eprint($out, $type, "$data->{'victim'} was notified.\n\n");
      }
      else {
        eprint($out, $type, "$data->{'victim'} was not notified.\n\n");
      }
      next;
    }
    eprint($out, $type, "was accepted with these results:\n\n");

    # Then call the appropriate formatting routine to format the real command
    # return.
    my $fun = "Mj::Format::$command";
    {
      no strict 'refs';
      $ok = &$fun($mj, $out, $err, $type, $data, $rresult);
    }
  }
  $ok;
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

sub announce {
  my ($mj, $out, $err, $type, $request, $result) = @_;

  my ($ok, $mess) = @$result;
  if ($ok > 0) { 
    eprint($out, $type, "The announcement was sent.\n");
  }
  else {
    eprint($out, $type, "The announcement was not sent.\n");
    eprint($out, $type, &indicate($mess, $ok));
  }
  $ok;
}

sub archive {
  my ($mj, $out, $err, $type, $request, $result) = @_;
 
  my ($chunksize, $data, $first, $i, $last, $line, $lines, 
      $mess, $msg, %stats, @tmp);
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

  if ($request->{'mode'} =~ /sync/) {
    for (@msgs) {
      ($ok, $mess) = @{$mj->dispatch($request, [$_])};
      eprint($out, $type, indicate($mess, $ok));
    }
  }
  elsif ($request->{'mode'} =~ /get|delete/) {
    $chunksize = 
      $mj->global_config_get($request->{'user'}, $request->{'password'}, 
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
  elsif ($request->{'mode'} =~ /stats/) {
    $first = time;
    $last = 0;
    $chunksize = scalar @msgs;
    for $i (@msgs) {
      $data = $i->[1];
      $first = $data->{'date'} if ($data->{'date'} < $first);
      $last = $data->{'date'} if ($data->{'date'} > $last);
      $stats{$data->{'from'}} = 0 
        unless (exists $stats{$data->{'from'}});
      $stats{$data->{'from'}}++;
    }
    $line = sprintf "Activity for %s from %s to %s\n\n", 
                    $request->{'list'}, 
                    scalar localtime $first, 
                    scalar localtime $last;
    eprint($out, $type, $line) if $line;
    $line = sprintf "%5d Total messages\n", $chunksize;
    eprint($out, $type, $line) if $line;
    for $i (sort { $stats{$b} <=> $stats{$a} } keys %stats) {
      $line = sprintf "%5d %s\n", $stats{$i}, $i;
      eprint($out, $type, $line) if $line;
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

  $request->{'command'} = "archive_done";
  $mj->dispatch($request); 
 
  $ok;
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
    eprint($out, $type, "Address not changed from $request->{'victim'} to $request->{'user'}.\n");
    eprint($out, $type, &indicate($mess, $ok));
  }
  $ok;
}

sub configdef {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'list'}";
  my ($ok, $mess, $var, @arglist, @results);

  @results = @$result;
  while (@results) {
    $ok = shift @results;
    ($mess, $var) = @{shift @results};

    eprint ($out, $type, indicate($mess,$ok)) if $mess;
    if ($ok > 0) {
      eprintf($out, $type, "%s set to default value.\n", $var);
    }
  }
  $ok;
}

sub configset {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'list'}";
  my ($ok, $mess) = @$result;
  my ($val) = ${$request->{'value'}}[0];
  $val = '' unless defined $val;
  eprint($out, $type, indicate($mess, $ok)) if $mess;
  if ($ok) {
    if ($request->{'mode'} =~ /append/) {
      eprintf($out, $type, "Value \"%s%s\" appended to %s.\n",
              $val, ${$request->{'value'}}[1] ? "..." : "",
              $request->{'setting'});
    }
    elsif ($request->{'mode'} =~ /extract/) {
      eprintf($out, $type, "Value \"%s%s\" extracted from %s.\n",
              $val, ${$request->{'value'}}[1] ? "..." : "",
              $request->{'setting'});
    }
    else {
      eprintf($out, $type, "%s set to \"%s%s\".\n",
              $request->{'setting'}, $val,
              ${$request->{'value'}}[1] ? "..." : "");
    }
  }
  $ok;
}

sub configshow {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'list'}";
  my ($array, $auto, $enum, $flags, $gen, $gsubs, $list, $mess, 
      $mode, $mode2, $ok, $short, $str, $subs,
      $tag, $tmp, $val, $var, $varresult);

  $request->{'cgiurl'} ||= '';

  if (exists $request->{'config'} and length $request->{'config'}) {
    $list = $request->{'config'};
  }
  else {
    $list = $request->{'list'};
    $list .= ":$request->{'sublist'}"
      if ($request->{'sublist'} and $request->{'sublist'} ne 'MAIN');
  }
  $mode = $mode2 = '';
  if ($request->{'mode'} =~ /append/) {
    $mode = '-append';
  }
  elsif ($request->{'mode'} =~ /extract/) {
    $mode = $mode2 = '-extract';
  }
  
   
  $gsubs = { $mj->standard_subs($list),
            'CGIURL'   => $request->{'cgiurl'},
            'PASSWORD' => $request->{'password'},
            'USER'     => "$request->{'user'}",
          };

  $ok = shift @$result;
  unless ($ok) {
    $mess = shift @$result;
    $gsubs->{'ERROR'} = $mess;
    $tmp = $mj->format_get_string($type, 'configshow_error');
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    eprint($out, $type, indicate("$str\n", $ok));
    return $ok;
  }

  unless (scalar @$result) {
    $tmp = $mj->format_get_string($type, 'configshow_none');
    $mess = $mj->substitute_vars_format($tmp, $gsubs);
    eprint($out, $type, indicate("$mess\n", $ok));
    return $ok;
  }

  if ($request->{'mode'} !~ /categories/) {
    $subs = {};
    $tmp = $mj->format_get_string($type, 'configshow_head');
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    eprint($out, $type, "$str\n");
  }
  else {
    $subs = { %$gsubs };
    $subs->{'CATEGORIES'} = [];
    $subs->{'COMMENT'} = [];
    $subs->{'COUNT'} = [];
  }

  $gen   = $mj->format_get_string($type, 'configshow');
  $array = $mj->format_get_string($type, 'configshow_array');
  $enum  = $mj->format_get_string($type, 'configshow_enum');
  $flags = $mj->format_get_string($type, 'configshow_flags');
  $short = $mj->format_get_string($type, 'configshow_short');

  for $varresult (@$result) {
    ($ok, $mess, $var, $val) = @$varresult;
    $subs->{'VARIABLE'} = $var;

    if (! $ok) {
      $subs->{'ERROR'} = $mess;
      $tmp = $mj->format_get_string($type, 'configshow_error');
      $str = $mj->substitute_vars_format($tmp, $subs);
      eprint($out, $type, indicate("$str\n", $ok));
      next;
    }

    if ($request->{'mode'} =~ /categories/) {
      push @{$subs->{'CATEGORIES'}}, $var;
      push @{$subs->{'COUNT'}}, $val;
      push @{$subs->{'COMMENT'}}, $mess;
      next;
    }
      

    $subs->{'COMMENT'} = '';
    if ($request->{'mode'} !~ /nocomments/) {
      $mess =~ s/^/# /gm if ($type eq 'text');
      chomp $mess;
      $mess = escape($mess, $type);
      $subs->{'COMMENT'} = $mess;
    }

    $auto = '';
    if ($ok < 1) {
      $auto = '# ';
    }

    if (ref ($val) eq 'ARRAY') {
      # Process as an array
      if ($type eq 'text') {
        $subs->{'LINES'} = scalar(@$val);
        for ($i = 0; $i < @$val; $i++) {
          $val->[$i] = "$auto$val->[$i]";
          chomp($val->[$i]);
        }
      }
      elsif ($type =~ /^www/) {
        $subs->{'LINES'} = (scalar(@$val) > 8)? scalar(@$val) : 8;
        for ($i = 0; $i < @$val; $i++) {
          $val->[$i] = escape($val->[$i], $type);
          chomp($val->[$i]);
        }
      }

      $tag = "END" . Majordomo::unique2();
      $subs->{'SETCOMMAND'} = 
        $auto . "configset$mode $list $var <<$tag\n";

      for $i (@$val) {
        $subs->{'SETCOMMAND'} .= "$i\n";
      }

      $subs->{'SETCOMMAND'} .= "$auto$tag\n";
      $subs->{'VALUE'} = join "\n", @$val; 

      $tmp = $array;
      $str = $mj->substitute_vars_format($tmp, $subs);
      eprint($out, $type, "$str\n");
    }
    else {
      # Process as a simple variable
      $subs->{'SETCOMMAND'} = 
        $auto . "configset$mode2 $list $var = ";

      $val = "" unless defined $val;
      $val = escape($val) if ($type =~ /^www/);

      if ($type eq 'text' and length $val > 40) {
        $auto = "\\\n    $auto";
      }

      $subs->{'SETCOMMAND'} .= "$auto$val\n";
      $subs->{'VALUE'} = $val;

      # Determine the type of the variable
      $vardata = $Mj::Config::vars{$var};

      if ($vardata->{'type'} =~ /^(integer|word|pw|bool)$/) {
        $tmp = $short;
      }
      elsif ($vardata->{'type'} =~ /^(enum|flags)$/) {
        $tmp = ($vardata->{'type'} eq 'enum') ? $enum : $flags;
        @possible = sort @{$vardata->{'values'}};
        if ($type =~ /^www/) {
          $subs->{'SETTINGS'} = [@possible];
          $subs->{'SELECTED'} = [];
          $subs->{'CHECKED'}  = [];
          for $str (@possible) {
            if ($val =~ /$str/) {
              push @{$subs->{'SELECTED'}}, "selected";
              push @{$subs->{'CHECKED'}}, "checked";
            }
            else {
              push @{$subs->{'SELECTED'}}, "";
              push @{$subs->{'CHECKED'}},  "";
            }
          }
        }
      }
      else {
        $tmp = $gen;
      }
  
      $str = $mj->substitute_vars_format($tmp, $subs);
      eprint($out, $type, "$str\n");
    }
  }

  if ($request->{'mode'} =~ /categories/) {
    $tmp = $mj->format_get_string($type, 'configshow_categories');
    $str = $mj->substitute_vars_format($tmp, $subs);
  }
  else {
    $tmp = $mj->format_get_string($type, 'configshow_foot');
    $str = $mj->substitute_vars_format($tmp, $gsubs);
  }
  print $out "$str\n";

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

use Mj::List qw(_time_to_str);
sub digest {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($comm, $digest, $i, $msgdata);
  my ($ok, $mess) = @$result;
  unless ($ok > 0) {
    eprint($out, $type, "Digest-$request->{'mode'} failed.\n");
    eprint($out, $type, &indicate($mess, $ok));
    return $ok;
  }

  if ($request->{'mode'} !~ /status/) {
    eprint($out, $type, "$mess") if $mess;
  }
  else {
    for $i (sort keys %$mess) {
      next if ($i eq 'default_digest');
      $digest = $mess->{$i};
      $comm =          "Digest Name                $i\n";
      $comm .= sprintf "Last delivered on          %s\n", 
                 scalar localtime($digest->{'lastrun'}) 
                 if $digest->{'lastrun'};
      $comm .= sprintf "Next delivery on or after  %s\n", 
                 scalar localtime($digest->{'lastrun'} + $digest->{'separate'}) 
                 if ($digest->{'lastrun'} and $digest->{'separate'});
      $comm .= sprintf "Age of oldest message      %s\n", 
                 Mj::List::_time_to_str(time - $digest->{'oldest'}, 1) 
                 if ($digest->{'oldest'});
      $comm .= sprintf "Oldest age allowed         %s\n", 
                 Mj::List::_time_to_str($digest->{'maxage'}, 1)
                 if ($digest->{'maxage'});
      $comm .= sprintf "Age of newest message      %s\n", 
                 Mj::List::_time_to_str(time - $digest->{'newest'}, 1)
                 if ($digest->{'newest'});
      $comm .= sprintf "Minimum age required       %s\n", 
                 Mj::List::_time_to_str($digest->{'minage'}, 1) 
                 if ($digest->{'minage'});
      $comm .= sprintf "Messages awaiting delivery %d\n", 
                 scalar @{$digest->{'messages'}} if ($digest->{'messages'});
      $comm .= sprintf "Minimum message count      %d\n", 
                 $digest->{'minmsg'} if ($digest->{'minmsg'});
      $comm .= sprintf "Message total size         %d bytes\n", 
                 $digest->{'bytecount'} if ($digest->{'bytecount'});
      $comm .= sprintf "Maximum size of a digest   %d bytes\n", 
                 $digest->{'maxsize'} if ($digest->{'maxsize'});
      for $msgdata (@{$digest->{'messages'}}) {
        $comm .= sprintf "%-14s %s\n", $msgdata->[0], 
                   substr($msgdata->[1]->{'subject'}, 0, 62); 
        $comm .= sprintf " by %-48s %s\n", 
                   substr($msgdata->[1]->{'from'}, 0, 48), 
                   scalar localtime($msgdata->[1]->{'date'}); 
      }
      eprint($out, $type, "$comm\n");
    } 
  }
  $ok;
}

sub faq   {g_get("FAQ failed.",   @_)}
sub get   {g_get("Get failed.",   @_)}
sub info  {g_get("Info failed.",  @_)}
sub intro {g_get("Intro failed.", @_)}

sub help {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, $request->{'topic'};
  my ($cgiurl, $chunk, $chunksize, $domain, $topic);
  my ($ok, $mess) = @$result;

  select $out;
  unless ($ok > 0) {
    print "Help $request->{'topic'} failed.\n$mess";
    return $ok;
  }

  $chunksize = $mj->global_config_get($request->{'user'}, $request->{'password'},
                                      "chunksize");
  return unless $chunksize;

  $cgiurl = $request->{'cgiurl'};
  $domain = $mj->{'domain'};

  $request->{'command'} = "get_chunk";

  while (1) {
    ($ok, $chunk) = @{$mj->dispatch($request, $chunksize)};
    last unless defined $chunk;
    if ($type =~ /www/) { 
      $chunk = escape($chunk);
      $chunk =~ s/(\s{3}|&quot;)(help\s)(configset|admin|mj) (?=\w)/$1$2$3_/g;
      $chunk =~ 
       s#(\s{3}|&quot;)(help\s)(\w+)#$1$2<a href="$cgiurl?domain=$domain&func=help&extra=$3">$3</a>#g;
    }
    print $chunk;
  }

  $request->{'command'} = "help_done";
  $mj->dispatch($request);
  select STDOUT;
}

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
  my (%lists, $basic_format, $cat_format, $category, $count, $data, 
      $desc, $flags, $global_subs, $i, $legend, $list, $site, $str, 
      $subs, $tmp);
  my $log = new Log::In 29, $type;
  select $out;
  $count = 0;

  ($site) = $mj->global_config_get($request->{'user'}, $request->{'pass'}, 
                                   "site_name");
  $site ||= $mj->global_config_get($request->{'user'}, $request->{'pass'}, 
                                   "whoami");

  my ($ok, @lists) = @$result;

  $global_subs = {
           $mj->standard_subs('GLOBAL'),
          };

  if ($ok <= 0) {
    $tmp = $mj->format_get_string($type, 'lists_error');
    $str = $mj->substitute_vars_format($tmp, $global_subs);
    eprint($out, $type, indicate("$str\n", $ok, 1));
    return 1;
  }
  
  if (@lists) {
    unless ($request->{'mode'} =~ /compact|tiny/) {
      $tmp = $mj->format_get_string($type, 'lists_head');
      $str = $mj->substitute_vars_format($tmp, $global_subs);
      eprint($out, $type, "$str\n");
    }
 
    if ($request->{'mode'} =~ /full/ and $request->{'mode'} !~ /config/) { 
      $basic_format = $mj->format_get_string($type, 'lists_full');
    }
    else {
      $basic_format = $mj->format_get_string($type, 'lists');
    }

    $cat_format = $mj->format_get_string($type, 'lists_category');

    while (@lists) {
      $data = shift @lists;
      next if ($data->{'list'} =~ /^DEFAULT/ and $request->{'mode'} !~ /config/);
      $lists{$data->{'category'}}{$data->{'list'}} = $data;
    }
    
    for $category (sort keys %lists) {
      if (length $category && $request->{'mode'} !~ /tiny/) {
        $subs->{'CATEGORY'} = $category;
        $str = $mj->substitute_vars_format($cat_format, $subs);
        eprint($out, $type, "$str\n");
      }
      for $list (sort keys %{$lists{$category}}) {
        $count++ unless ($list =~ /:/);
        $data = $lists{$category}{$list};
        $flags = $data->{'flags'} ? "+" : " ";
        if ($request->{'mode'} =~ /tiny/) {
          eprint($out, $type, "$list\n");
          next;
        }
        $legend++ if $data->{'flags'};
        $tmp  = $data->{'description'}
                 || "(no description)";
        $desc = [ split ("\n", $tmp) ];

        $digests = [];
        for $i (sort keys %{$data->{'digests'}}) {
          push @$digests, "$i:  $data->{'digests'}->{$i}";
        }
        $digests = ["(none)\n"] if ($list =~ /:/);

        $subs = { 
                  %{$global_subs},
                  'ARCURL'        => $data->{'archive'} || "?",
                  'CATEGORY'      => $category || "?",
                  'CGIURL'        => $request->{'cgiurl'} || "?",
                  'DESCRIPTION'   => $desc,
                  'DIGESTS'       => $digests,
                  'FLAGS'         => $flags,
                  'LIST'          => $list,
                  'OWNER'         => $data->{'owner'},
                  'PASSWORD'      => $request->{'password'},
                  'POSTS'         => $data->{'posts'},
                  'SUBS'          => $data->{'subs'},
                  'USER'          => "$request->{'user'}",
                  'WHOAMI'        => $data->{'address'},
                };
                  
        $str = $mj->substitute_vars_format($basic_format, $subs);
        eprint($out, $type, "$str\n");
      }
    }
  }
  else {
    # No lists were found.
    $subs = { 
              %{$global_subs},
              'CGIURL'        => $request->{'cgiurl'} || "?",
              'PASSWORD'      => $request->{'password'},
              'PATTERN'       => $request->{'regexp'},
              'USER'          => "$request->{'user'}",
            };
    $tmp = $mj->format_get_string($type, 'lists_none');
    $str = $mj->substitute_vars_format($tmp, $subs);
    eprint($out, $type, "$str\n");
  }

  return 1 if $request->{'mode'} =~ /compact|tiny/;

  $subs = {
            %{$global_subs},
            'COUNT' => $count,
          };
  $tmp = $mj->format_get_string($type, 'lists_foot');
  $str = $mj->substitute_vars_format($tmp, $subs);
  eprint($out, $type, "$str\n");

  if ($request->{'mode'} =~ /enhanced/) {
    $subs = {
              %{$global_subs},
              'COUNT'         =>  $count,
              'SUBSCRIPTIONS' =>  $legend,
              'USER'          => "$request->{'user'}",
            };
    $tmp = $mj->format_get_string($type, 'lists_enhanced');
    $str = $mj->substitute_vars_format($tmp, $subs);
    eprint($out, $type, "$str\n");
  }
  1;
}

sub password {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, $type;

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
  my ($i, $ok, $mess, $handled); 
  $handled = 0;
  $handled = 1 
    if (   ref $request->{'message'} eq 'IO::File'  
        or ref $request->{'message'} eq 'IO::Handle');
 
  $request->{'command'} = "post_chunk"; 
 
  # The message will have been posted already if this subroutine
  # is called by Mj::Token::t_accept . 
  if (exists $request->{'message'}) { 
    while (1) {
      $i = $handled ? 
        $request->{'message'}->getline :
        shift @{$request->{'message'}};
      last unless defined $i;
      # Mj::Parser creates an argument list without line feeds.
      $i .= "\n" unless $handled;
     
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
    eprint($out, $type, "Post succeeded.\n");
  }
  elsif ($ok<0) {
    eprint($out, $type, "Post stalled, awaiting approval.\nDetails:\n");
  }
  else {
    eprint($out, $type, "Post failed.\nDetails:\n");
  }
  # The "message" given by a success is only the poster's address.
  eprint($out, $type, indicate($mess, $ok, 1)) if ($mess and ($ok <= 0));

  return $ok;
}

sub put {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($act, $chunk, $handled, $i);
  my ($ok, $mess) = @$result;

  if    ($request->{'file'} eq '/info' ) {$act = 'Newinfo' }
  elsif ($request->{'file'} eq '/intro') {$act = 'Newintro'}
  elsif ($request->{'file'} eq '/faq'  ) {$act = 'Newfaq'  }
  else                                   {$act = 'Put'     }

  unless ($ok) {
    eprint($out, $type, "$act failed.\n");
    return $ok;
  }

  $handled = 0;
  if (   ref $request->{'contents'} eq 'IO::File'  
      or ref $request->{'contents'} eq 'IO::Handle') {
    $handled = 1;
  }

  my ($chunksize) = $mj->global_config_get(undef, undef, "chunksize") * 80;

  $request->{'command'} = "put_chunk"; 

  $chunk = '';
  while (1) {
    last if ($request->{'mode'} =~ /dir/);
    $i = $handled ? 
      $request->{'contents'}->getline :
      shift @{$request->{'contents'}};
    # Tack on a newline if pulling from a here doc
    if (defined($i)) {
      $i .= "\n" unless $handled;
      $chunk .= $i;
    }      
    if (length($chunk) > $chunksize || !defined($i)) {
      ($ok, $mess) = @{$mj->dispatch($request, $chunk)};
      $chunk = '';
    }
    last unless (defined $i and $ok > 0);
  }

  unless ($request->{'mode'} =~ /dir/) {
    $request->{'command'} = "put_done"; 
    ($ok, $mess) = @{$mj->dispatch($request)};
  }

  if ($ok > 0) {
    eprint($out, $type, "$act succeeded.\n");
  }
  elsif ($ok < 0) {
    eprint($out, $type, "$act stalled.\n");
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
  my ($data, $ok, $res, $token, @tokens);

  @tokens = @$result; 

  while (@tokens) { 
    ($ok, $res) = splice @tokens, 0, 2;
    unless ($ok) {
      eprint($out, $type, indicate($res, $ok));
      next;
    }
    ($token, $data) = @$res;
    eprint($out, $type, "Token '$token' for command:\n    $data->{'cmdline'}\n");
    eprint($out, $type, "issued at: ", scalar gmtime($data->{'time'}), " GMT\n");
    eprint($out, $type, "from session: $data->{'sessionid'}\n");
    eprint($out, $type, "has been rejected.\n");
    if ($data->{'type'} eq 'consult') {
      if ($data->{'ack'}) {
        eprint($out, $type, "$data->{'victim'} was notified.\n\n");
      }
      else {
        eprint($out, $type, "$data->{'victim'} was not notified.\n\n");
      }
    }
  }

  1;
}

sub rekey {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type";

  my ($ok, $mess) = @$result; 
  if ($ok>0) {
    eprint($out, $type, "Databases rekeyed.\n");
    eprint($out, $type, &indicate($mess, $ok)) if $mess;
  }
  else {
    eprint($out, $type, "Databases not rekeyed.\n");
    eprint($out, $type, &indicate($mess, $ok));
  }
  $ok;
}

use Date::Format;
sub report {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type";
  my (%outcomes, %stats, @tmp, $begin, $chunk, $chunksize, $data, $end, $victim);
  my ($ok, $mess) = @$result;

  unless ($ok > 0) {
    eprint($out, $type, "Unable to create report\n");
    eprint($out, $type, indicate($mess, $ok, 1)) if $mess;
    return $ok;
  }

  %outcomes = ( 1 => 'succeed',
                0 => 'fail',
               -1 => 'stall',
              );

  ($request->{'begin'}, $request->{'end'}) = @$mess;
  @tmp = localtime($request->{'begin'});
  $begin = strftime("%Y-%m-%d %H:%M", @tmp);
  @tmp = localtime($request->{'end'});
  $end = strftime("%Y-%m-%d %H:%M", @tmp);
  $today = '';

  $mess = sprintf "Activity for %s from %s to %s\n\n", 
                  $request->{'list'}, $begin, $end;
  eprint($out, $type, $mess) if $mess;

  $request->{'chunksize'} = 
    $mj->global_config_get($request->{'user'}, $request->{'password'},
                           "chunksize");

  $request->{'command'} = "report_chunk";

  while (1) {
    ($ok, $chunk) = @{$mj->dispatch($request)};
    unless ($ok) {
      eprint($out, $type, indicate($chunk, $ok, 1)) if $chunk;
      last;
    }
    last unless scalar @$chunk;
    for $data (@$chunk) {
      if ($request->{'mode'} !~ /summary/) {
        if ($data->[1] eq 'bounce') {
          ($victim = $data->[4]) =~ s/\(bounce from (.+)\)/$1/;
        }
        else {
          $victim = ($data->[1] =~ /post|owner/) ? $data->[2] : $data->[3];
          # Remove the comment from the victim's address.
          $victim =~ s/.*<([^>]+)>.*/$1/;
        }
        @tmp = localtime($data->[9]);
        $day = strftime("  %d %B %Y\n", @tmp);
        if ($day ne $today) {
          $today = $day;
          eprint($out, $type, $day);
        }
        $end = strftime("%H:%M", @tmp);
        if (defined $data->[10]) {
          $end .= " $data->[10]";
        }

        if ($request->{'list'} eq 'ALL') { 
          $mess = sprintf "%-11s %-16s %-30s %-7s %s\n", 
                          $data->[1], $data->[0], $victim,
                          $outcomes{$data->[6]}, $end;
        }
        else {
          $mess = sprintf "%-11s %-44s %-7s %s\n", $data->[1],
                  $victim, $outcomes{$data->[6]}, $end;
        }
     
        eprint($out, $type, indicate($mess, $ok, 1)) if $mess;
      }
      else {
        $stats{$data->[1]}{1}  ||= 0;
        $stats{$data->[1]}{-1} ||= 0;
        $stats{$data->[1]}{0}  ||= 0;
        $stats{$data->[1]}{$data->[6]}++;
        $stats{$data->[1]}{'total'}++;
      }
    }
  }
  if ($request->{'mode'} =~ /summary/) {
    if (scalar keys %stats) {
      $mess = sprintf "     Command: Total    Succeed Stall Fail\n";
    }
    else {
      $mess = "There was no activity.\n";
    }
    eprint($out, $type, indicate($mess, $ok, 1));
    for $end (sort keys %stats) {
      $mess = sprintf "%12s: %4d    %7d %5d %4d\n", $end, $stats{$end}{'total'},
        $stats{$end}{1}, $stats{$end}{'-1'}, $stats{$end}{'0'};
      eprint($out, $type, indicate($mess, $ok, 1)) if $mess;
    }
  }

  $request->{'command'} = "report_done";
  ($ok, @tmp) = @{$mj->dispatch($request)};
  1;
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
  my ($change, @changes, $list, $ok, $summary);
 
  @changes = @$result; 
  while (@changes) {
    ($ok, $change) = splice @changes, 0, 2;
    if ($ok > 0) {
      $list = $change->{'list'};
      if (length $change->{'sublist'} and $change->{'sublist'} ne 'MAIN') {
        $list .= ":$change->{'sublist'}";
      }
      $summary = <<EOM;
Settings for $change->{'victim'}->{'full'} on "$list":
  Receiving $change->{'classdesc'} %s
  Flags:
EOM
      $summary = sprintf $summary, ($change->{'class'}->[0] eq 'digest') ?
                 "(in $change->{'class'}->[2] format)" : '';
      $summary .=  "    " . join("\n    ", @{$change->{'flagdesc'}}) . "\n\n";
      eprint($out, $type, &indicate($summary, $ok, 1));
      if (exists $change->{'digest'} and ref $change->{'digest'}) {
        eprint($out, $type, "A partial digest of messages has been mailed.\n");
      }
    }
    # deal with partial failure
    else {
        eprint($out, $type, &indicate("$change\n", $ok, 1));
    }
  }
  eprint($out, $type, 
    "Use the 'help set' command to see an explanation of the settings.\n");

  $ok;
}

sub show {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'victim'}";
  my (@lists, $bouncedata, $error, $global_subs, $i, $j, $lsubs,
      $settings, $str, $subs, $tmp);
  my ($ok, $data) = @$result;
  $error = [];
  $global_subs = {
    $mj->standard_subs('GLOBAL'),
    'CGIURL' => $request->{'cgiurl'} || '',
    'VICTIM' => "$request->{'victim'}",
  };
 
  # use Data::Dumper; print $out Dumper $data;

  # For validation failures, the dispatcher will do the verification and
  # return the error as the second argument.  For normal denials, $ok is
  # also 0, but a hashref is returned containing what information we could
  # get from the address.
  if ($ok == 0) {
    if (ref($data)) {
      push @$error, "The show command failed.";
      push @$error, "$data->{error}";
    }
    else {
      push @$error, "Address is invalid.";
      push @$error, "$data";
    }

    $subs = { %$global_subs,
              'ERROR' => $error,
            };

    $tmp = $mj->format_get_string($type, 'show_error');
    $str = $mj->substitute_vars_format($tmp, $subs);
    eprint($out, $type, indicate("$str\n", $ok, 1));

    return $ok;
  }

  elsif ($ok < 0) {  
    push @$error, "Address is valid.";
    push @$error, "Mailbox: $data->{'strip'}";
    push @$error, "Comment: $data->{'comment'}"
      if (defined $data->{comment} && length $data->{comment});
    push @$error, indicate($data->{error}, $ok);

    $subs = { %$global_subs,
              'ERROR' => $error,
            };

    $tmp = $mj->format_get_string($type, 'show_error');
    $str = $mj->substitute_vars_format($tmp, $subs);
    eprint($out, $type, indicate("$str\n", $ok, 1));

    return $ok;
  }

  $subs = { %$global_subs };
  $subs->{'USER'}     = "$request->{'user'}";
  $subs->{'PASSWORD'} = $request->{'password'};

  for $i (keys %$data) {
    next if ($i eq 'lists' or $i eq 'regdata');
    $subs->{uc $i} = $data->{$i};
  }

  if ($data->{strip} eq $data->{xform}) {
    $subs->{'XFORM'} = '';
  }
  if ($data->{strip} eq $data->{alias}) {
    $subs->{'ALIAS'} = '';
  }

  unless ($data->{regdata}) {
    $tmp = $mj->format_get_string($type, 'show_none');
    $str = $mj->substitute_vars_format($tmp, $subs);
    eprint($out, $type, "$str\n");
    return 1;
  }
  for $i (keys %{$data->{'regdata'}}) {
    $subs->{uc $i} = $data->{'regdata'}{$i};
  }

  $subs->{'REGTIME'}    = gmtime($data->{'regdata'}{'regtime'});
  $subs->{'RCHANGETIME'} = gmtime($data->{'regdata'}{'changetime'});

  @lists = sort keys %{$data->{lists}};
  $subs->{'COUNT'} = scalar @lists;

  $subs->{'SETTINGS'} = [];
  $settings = $data->{'lists'}{$lists[0]}{'settings'};
  if ($settings) {
    for ($j = 0; $j < @{$settings->{'flags'}}; $j++) {
      push @{$subs->{'SETTINGS'}}, $settings->{'flags'}[$j]->{'name'};
    }
  }

  $tmp = $mj->format_get_string($type, 'show_head');
  $str = $mj->substitute_vars_format($tmp, $subs);
  eprint($out, $type, "$str\n");

  for $i (@lists) {
    $lsubs = { %$subs };
    # Per-list substitutions available directly include:
    #   changetime class classarg classarg2 classdesc flags flagdesc
    #   fulladdr subtime
    for $j (keys %{$data->{'lists'}{$i}}) {
      next if ($j eq 'bouncedata' or $j eq 'settings');
      $lsubs->{uc $j} = $data->{'lists'}{$i}{$j};
    }

    $lsubs->{'CHANGETIME'} = gmtime($data->{'lists'}{$i}{'changetime'});
    $lsubs->{'LIST'} = $i;
    $lsubs->{'NUMBERED_BOUNCES'} = '';
    $lsubs->{'SUBTIME'}    = gmtime($data->{'lists'}{$i}{'subtime'});
    $lsubs->{'UNNUMBERED_BOUNCES'} = '';

    $bouncedata = $data->{lists}{$i}{bouncedata};
    if ($bouncedata) {
      if (keys %{$bouncedata->{M}}) {
        $lsubs->{'NUMBERED_BOUNCES'} = 
          join(" ", keys %{$bouncedata->{M}});
      }
      if (@{$bouncedata->{UM}}) {
        $lsubs->{'UNNUMBERED_BOUNCES'} = scalar(@{$bouncedata->{UM}});
      }
    }
     
    # XXX Simple first approach: create CHECKBOX substitution.
    $settings = $data->{'lists'}{$i}{'settings'};
    $lsubs->{'CHECKBOX'}           = [];
    $lsubs->{'CLASS_DESCRIPTIONS'} = [];
    $lsubs->{'CLASSES'}            = [];
    $lsubs->{'SELECTED'}           = [];

    if ($settings) {
      for ($j = 0; $j < @{$settings->{'flags'}}; $j++) {
        $flag = $settings->{'flags'}[$j]->{'name'};
        # Is this setting set?
        $str = $settings->{'flags'}[$j]->{'abbrev'};
        if ($data->{'lists'}{$i}{'flags'} =~ /$str/) {
          $str = 'checked';
        }
        else {
          $str = '';
        }

        # Is this setting allowed?
        if ($settings->{'flags'}[$j]->{'allow'} or $type eq 'wwwadm') {
          push @{$lsubs->{'CHECKBOX'}}, 
            "<input name=\"$i;$flag\" type=\"checkbox\" $str>";
        }
        else {
          # Use an X or O to indicate a setting that has been disabled
          # by the allowed_flags configuration value.
          if ($str eq 'checked') {
            $str = 'X';
          }
          else {
            $str = 'O';
          }
          push @{$lsubs->{'CHECKBOX'}}, 
            "<input name=\"$i;$flag\" type=\"hidden\" value=\"disabled\">$str";
        }
      }
      for ($j = 0; $j < @{$settings->{'classes'}}; $j++) {
        $flag = $settings->{'classes'}[$j]->{'name'};
        if ($flag eq $data->{'lists'}{$i}{'class'} or $flag eq 
            "$data->{'lists'}{$i}{'class'}-$data->{'lists'}{$i}{'classarg'}") 
        {
          $str = 'selected';
        }
        else {
          $str = '';
        }

        if ($settings->{'classes'}[$j]->{'allow'} or $type eq 'wwwadm') {
          push @{$lsubs->{'CLASSES'}}, $flag;
          push @{$lsubs->{'SELECTED'}}, $str;
          push @{$lsubs->{'CLASS_DESCRIPTIONS'}}, 
               $settings->{'classes'}[$j]->{'desc'};
        }
      }    
    }

    $tmp = $mj->format_get_string($type, 'show');
    $str = $mj->substitute_vars_format($tmp, $lsubs);
    eprint($out, $type, "$str\n");
  }

  $tmp = $mj->format_get_string($type, 'show_foot');
  $str = $mj->substitute_vars_format($tmp, $subs);
  eprint($out, $type, "$str\n");

  1;
}

use Date::Format;
sub showtokens {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$request->{'list'}";
  my ($basic_format, $count, $data, $data_format, $global_subs, 
      $size, $str, $subs, $tmp, $token, $user);
  my (%type_abbrev) = (
                        'confirm' => 'S',
                        'consult' => 'O',
                        'delay'   => 'D',
                      );

  $global_subs = {
           $mj->standard_subs($request->{'list'}),
          };

  my ($ok, @tokens) = @$result;
  unless (@tokens) {
    $tmp = $mj->format_get_string($type, 'showtokens_none');
    $str = $mj->substitute_vars_format($tmp, $global_subs);
    eprint($out, $type, indicate("$str\n", $ok, 1));
    return $ok;
  }
  unless ($ok > 0) {
    $subs = {
             %{$global_subs},
             'ERROR'  => $tokens[0],
            };
    $tmp = $mj->format_get_string($type, 'showtokens_error');
    $str = $mj->substitute_vars_format($tmp, $subs);
    eprint($out, $type, indicate("$str\n", $ok, 1));
    return $ok;
  }

  if ($request->{'list'} eq 'ALL') {
    $basic_format = $mj->format_get_string($type, 'showtokens_all');
    $data_format = $mj->format_get_string($type, 'showtokens_all_data');
  }
  else {
    $basic_format = $mj->format_get_string($type, 'showtokens');
    $data_format = $mj->format_get_string($type, 'showtokens_data');
  }

  $tokendata = [];
  while (@tokens) {
    ($token, $data) = splice @tokens, 0, 2;
    $count++;
   
    $size = '';
    if ($data->{'size'}) {
      $size = sprintf "(%d kB)",  int(($data->{'size'} + 512)/1024);
    }

    if ($type ne 'text') {
      $user = escape($data->{'user'});
    }
    else {
      $user = $data->{'user'};
    }

    $subs = { 
              %{$global_subs},
              'ADATE'  => time2str('%m-%d %H:%M', $data->{'time'}), 
              'ATYPE'  => $type_abbrev{$data->{'type'}},
              'COMMAND'=> $data->{'command'},
              'CMDLINE'=> $data->{'cmdline'},
              'DATE'   => scalar localtime($data->{'time'}),
              'LIST'   => $data->{'list'},
              'SIZE'   => $size,
              'TOKEN'  => $token,
              'TYPE'   => $data->{'type'},
              'USER'   => $user,
            };
             
    push @{$tokendata}, $mj->substitute_vars_format($data_format, $subs);
  }
  $subs = {
           %{$global_subs},
           'COUNT'     => $count,
           'TOKENDATA' => $tokendata,
          };
              
  $str = $mj->substitute_vars_format($basic_format, $subs);
  eprint($out, $type, "$str\n");
  1;
}

sub subscribe {
  g_sub('sub', @_)
}

sub tokeninfo {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$request->{'token'}";
  my (@tmp, $expire, $str, $subs, $time, $tmp);
  my ($ok, $data, $sess) = @$result;

  $subs = { $mj->standard_subs('GLOBAL') };

  unless ($ok > 0) {
    $subs->{'ERROR'} = $data;
    $tmp = $mj->format_get_string($type, 'tokeninfo_error');
    $str = $mj->substitute_vars_format($tmp, $subs);
    eprint($out, $type, indicate("$str\n", $ok, 1));
    return $ok;
  }

  $subs->{'APPROVALS'}  = $data->{'approvals'};
  $subs->{'CMDLINE'} = escape($data->{'cmdline'}, $type);
  $subs->{'DATE'} = localtime($data->{'time'});
  $subs->{'EXPIRE'} = localtime($data->{'expire'});
  $subs->{'TOKEN'}  = $request->{'token'};
  $subs->{'TYPE'}  = $data->{'type'};
  $subs->{'USER'}  = escape($data->{'user'}, $type);

  # Indicate reasons
  $subs->{'REASONS'} = [];
  if ($data->{'reasons'}) {
    @tmp = split "\002", escape($data->{'reasons'}, $type);
    $subs->{'REASONS'} = [@tmp];
  }

  $tmp = $mj->format_get_string($type, 'tokeninfo_head');
  $str = $mj->substitute_vars_format($tmp, $subs);
  eprint($out, $type, "$str\n");

  if ($sess) {
    eprint($out, $type, "\n");
    $request->{'sessionid'} = $data->{'sessionid'};
    Mj::Format::sessioninfo($mj, $out, $err, $type, $request, [1, '']);
  }

  $tmp = $mj->format_get_string($type, 'tokeninfo_foot');
  $str = $mj->substitute_vars_format($tmp, $subs);
  eprint($out, $type, "$str\n");

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
  my ($last_list, $list_count, $match, $total_count, $whoami, $list);

  my ($ok, @matches) = @$result;
  # Deal with initial failure
  if ($ok <= 0) {
    eprint($out, $type, &indicate($matches[0], $ok)) if $matches[0];
    return $ok;
  }

  $whoami = $mj->global_config_get($request->{'user'}, $request->{'password'}, 
                                   'whoami');
  $last_list = ''; $list_count = 0; $total_count = 0;

  # Print the header if we got anything back.  Note that this list is
  # guaranteed to have some addresses if it is nonempty, even if it
  # contains messages.
  if (@matches) {
    if ($request->{'mode'} =~ /regex/) {
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
    if ($request->{'mode'} =~ /regex/) {
      eprint($out, $type, "The expression \"$request->{'regexp'}\" appears in no lists\n");
    }
    else {
      eprint($out, $type, "The string \"$request->{'regexp'}\" appears in no lists\n");
    }
    eprint($out, $type, "served by $whoami.\n");
  }
  $ok;
}

sub who {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my (%stats, @lines, @out, @stuff, @time, $chunksize, $count, 
      $error, $fh, $flag, $foot, $fullclass, $gsubs, $head, $i, 
      $j, $line, $list, $mess, $numbered, $ok, $regexp, $ret, 
      $settings, $source, $subs, $tmp);

  $request->{'sublist'} ||= 'MAIN';
  $source = $request->{'list'};
  $remove = "unsubscribe";

  if ($request->{'sublist'} ne 'MAIN') {
    $source .= ":$request->{'sublist'}";
    $tmp = $mj->format_get_string($type, 'who');
    $head = $mj->format_get_string($type, 'who_head');
    $foot = $mj->format_get_string($type, 'who_foot');
  }
  elsif ($source eq 'GLOBAL') {
    $remove = "unregister";
    $tmp = $mj->format_get_string($type, 'who_registry');
    $head = $mj->format_get_string($type, 'who_registry_head');
    $foot = $mj->format_get_string($type, 'who_registry_foot');
  }
  else {
    $tmp = $mj->format_get_string($type, 'who');
    $head = $mj->format_get_string($type, 'who_head');
    $foot = $mj->format_get_string($type, 'who_foot');
  }
 
  my $log = new Log::In 29, "$type, $source, $request->{'regexp'}";

  $gsubs = { 
            $mj->standard_subs($source),
            'CGIURL'   => $request->{'cgiurl'},
            'PASSWORD' => $request->{'password'},
            'PATTERN'  => $request->{'regexp'},
            'REMOVE'   => $remove,
            'USER'     => "$request->{'user'}",
           };

  ($ok, $regexp, $settings) = @$result;

  if ($ok <= 0) {
    $gsubs->{'ERROR'} = indicate($regexp, $ok);
    $tmp = $mj->format_get_string($type, 'who_error');
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out "$str\n";
    return $ok;
  }

  # Special substitutions for WWW interfaces.
  $gsubs->{'CLASS_SELECTED'}     = [];
  $gsubs->{'CLASS_DESCRIPTIONS'} = [];
  $gsubs->{'CLASSES'}            = [];
  $gsubs->{'SETTINGS'}           = [];
  $gsubs->{'SETTING_CHECKED'}    = [];

  for ($j = 0; $j < @{$settings->{'flags'}}; $j++) {
    push @{$gsubs->{'SETTINGS'}}, $settings->{'flags'}[$j]->{'name'};
    if ($settings->{'flags'}[$j]->{'default'}) {
      $str = 'checked';
    }
    else {
      $str = '';
    }
    push @{$gsubs->{'SETTING_CHECKED'}}, $str;
  }
  
  for ($j = 0; $j < @{$settings->{'classes'}}; $j++) {
    push @{$gsubs->{'CLASSES'}}, $settings->{'classes'}[$j]->{'name'};
    push @{$gsubs->{'CLASS_DESCRIPTIONS'}}, 
           $settings->{'classes'}[$j]->{'desc'};
    if ($settings->{'classes'}[$j]->{'default'})
    {
      $str = 'selected';
    }
    else {
      $str = '';
    }
    push @{$gsubs->{'CLASS_SELECTED'}}, $str;
  }    

  # We know we succeeded
  $count = 0;
  if (exists $request->{'chunksize'} and $request->{'chunksize'} > 0) {
    $chunksize = $request->{'chunk'} || 1000;
  }
  else {
    $chunksize = $mj->global_config_get($request->{'user'}, 
                                        $request->{'password'}, 
                                        "chunksize");
    $chunksize ||= 1000;  
  }
  $gsubs->{'CHUNKSIZE'} = $chunksize;


  unless ($request->{'mode'} =~ /export|short|alias/) {
    $str = $mj->substitute_vars_format($head, $gsubs);
    print $out "$str\n";
  }

  $request->{'command'} = "who_chunk";
  if (exists ($request->{'start'}) and ($request->{'start'} > 1)) {
    # discard results
    $mj->dispatch($request, $request->{'start'} - 1);
  }


  $subs = { %$gsubs };

  while (1) {
    ($ok, @lines) = @{$mj->dispatch($request, $chunksize)};
    
    last unless $ok > 0;
    for $i (@lines) {
      next unless (ref ($i) eq 'HASH');

      #----- Hard-coded formatting for who-export and who-alias -----#
      if ($request->{'mode'} =~ /export/ &&
             $request->{'list'} eq 'GLOBAL' &&
             $request->{'sublist'} eq 'MAIN') {
        $line = "register-pass $i->{'password'} $i->{'fulladdr'}";
        eprint($out, $type, "$line\n");
        next;
      }
      elsif ($request->{'mode'} =~ /alias/ &&
             $request->{'list'} eq 'GLOBAL') 
      {
        $line = "default user $i->{'target'}\n  alias $i->{'stripsource'}\n";
        eprint($out, $type, "$line\n");
        next;
      }
      elsif ($request->{'mode'} =~ /export/ && $i->{'classdesc'} 
             && $i->{'flagdesc'}) 
      {
	$line = "subscribe-nowelcome $list $i->{'fulladdr'}\n";
	if ($i->{'origclassdesc'}) {
	  $line .= "set $list $i->{'origclassdesc'} $i->{'stripaddr'}\n";
	}
	$line .= "set $list $i->{'classdesc'},$i->{'flagdesc'} $i->{'stripaddr'}\n";
        eprint($out, $type, "$line\n");
        next;
      }

      #----- Flexible formatting for who and who-enhanced -----#
      for $j (keys %$i) {
        if ($request->{'mode'} =~ /enhanced/) {
          $subs->{uc $j} = $i->{$j};
        }
        else {
          $subs->{uc $j} = '';
        }
      }

      $subs->{'FULLADDR'} = escape($i->{'fulladdr'}, $type);
      $subs->{'LASTCHANGE'} = '';
    
      $count++;

      if ($request->{'mode'} =~ /enhanced/) {
        if ($request->{'list'} ne 'GLOBAL' or $request->{'sublist'} ne 'MAIN') {
          $fullclass = $i->{'class'};
          $fullclass .= "-" . $i->{'classarg'} if ($i->{'classarg'});
          $fullclass .= "-" . $i->{'classarg2'} if ($i->{'classarg2'});
          $subs->{'CLASS'} = $fullclass;
        }
        $subs->{'LISTS'} =~ s/\002/ /g;
        if ($i->{'changetime'}) {
          @time = localtime($i->{'changetime'});
          $subs->{'LASTCHANGE'} = 
            sprintf "%4d-%.2d-%.2d", $time[5]+1900, $time[4]+1, $time[3];
        }
        else {
          $subs->{'LASTCHANGE'} = '';
        }

        # Special substitutions for WWW interfaces.
        $subs->{'CHECKBOX'}           = [];
        $subs->{'CLASS_DESCRIPTIONS'} = [];
        $subs->{'CLASSES'}            = [];
        $subs->{'SELECTED'}           = [];
        $subs->{'SETTINGS'}           = [];

        for ($j = 0; $j < @{$settings->{'flags'}}; $j++) {
          $flag = $settings->{'flags'}[$j]->{'name'};
          push @{$subs->{'SETTINGS'}}, $flag;
          # Is this setting set?
          $str = $settings->{'flags'}[$j]->{'abbrev'};
          if ($i->{'flags'} =~ /$str/) {
            $str = 'checked';
          }
          else {
            $str = '';
          }

          push @{$subs->{'CHECKBOX'}}, 
              "<input name=\"$i->{'stripaddr'};$flag\" type=\"checkbox\" $str>";
        }
        for ($j = 0; $j < @{$settings->{'classes'}}; $j++) {
          $flag = $settings->{'classes'}[$j]->{'name'};
          if ($flag eq $i->{'class'} or 
              $flag eq "$i->{'class'}-$i->{'classarg'}") 
          {
            $str = 'selected';
          }
          else {
            $str = '';
          }

          if ($settings->{'classes'}[$j]->{'allow'} or $type eq 'wwwadm') {
            push @{$subs->{'CLASSES'}}, $flag;
            push @{$subs->{'SELECTED'}}, $str;
            push @{$subs->{'CLASS_DESCRIPTIONS'}}, 
                 $settings->{'classes'}[$j]->{'desc'};
          }
        }    
      }

      $subs->{'BOUNCE_DIAGNOSTIC'} = ''; 
      $subs->{'BOUNCE_MONTH'} = ''; 
      $subs->{'BOUNCE_NUMBERS'} = ''; 
      $subs->{'BOUNCE_WEEK'} = ''; 

      if ($request->{'mode'} =~ /bounces/ && exists $i->{'bouncestats'}) {
        $subs->{'BOUNCE_DIAGNOSTIC'} = escape($i->{'diagnostic'}, $type);
        $subs->{'BOUNCE_WEEK'} = $i->{'bouncestats'}->{'week'};
        $subs->{'BOUNCE_MONTH'} = $i->{'bouncestats'}->{'month'};
        $numbered = join " ", sort {$a <=> $b} keys %{$i->{'bouncedata'}{'M'}};
        $subs->{'BOUNCE_NUMBERS'} = $numbered;
      }
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
    last if (exists $request->{'chunksize'} and $request->{'chunksize'} > 0);
  }

  $request->{'command'} = "who_done";
  $mj->dispatch($request);
     
  unless ($request->{'mode'} =~ /export|short|alias/) {
    $gsubs->{'COUNT'} = $count;
    $gsubs->{'PREVIOUS'} = '';
    $gsubs->{'NEXT'} = '';

    # Create next and previous markers if result sets are used.
    if (exists $request->{'chunksize'} and $request->{'chunksize'} > 0) {
      $gsubs->{'NEXT'} = $request->{'start'} + $request->{'chunksize'}
        if ($count >= $request->{'chunksize'});

      if ($request->{'chunksize'} >= $request->{'start'}) {
        if ($request->{'start'} > 1) {
          $gsubs->{'PREVIOUS'} = 1;
        }
        else {
          $gsubs->{'PREVIOUS'} = ''; 
        }
      }
      else {
        $gsubs->{'PREVIOUS'} = $request->{'start'} - $request->{'chunksize'};
      }
    }
      
    $str = $mj->substitute_vars_format($foot, $gsubs);
    print $out "$str\n";
  }

  1;
}

sub g_get {
  my ($fail, $mj, $out, $err, $type, $request, $result) = @_;
  my ($base, $chunk, $chunksize, $lastchar);
  my ($ok, $mess) = @$result;

  $base = $request->{'command'};
  $base =~ s/_start//;

  unless ($ok > 0) {
    eprint($out, $type, "$fail\n");
    eprint($out, $type, indicate($mess, $ok, 1)) if $mess;
    return $ok;
  }

  $chunksize = $mj->global_config_get($request->{'user'}, $request->{'password'},
                                      "chunksize");

  if ($base eq 'get' and $request->{'mode'} =~ /edit/) {
    $chunk = sprintf "put-data %s %s %s %s %s %s %s <<ADGBEH",
                     $request->{'list'}, $request->{'path'}, $mess->{'c-type'},
                     $mess->{'charset'}, $mess->{'c-t-encoding'},
                     $mess->{'language'}, $mess->{'description'};
    eprint($out, $type, "$chunk\n");
  }

  $request->{'command'} = "get_chunk";

  # In "edit" mode, determine if the text ends with a newline,
  # and add one if not.
  $lastchar = "\n";

  while (1) {
    ($ok, $chunk) = @{$mj->dispatch($request, $chunksize)};
    last unless defined $chunk;
    $lastchar = substr $chunk, -1;
    eprint($out, $type, escape($chunk, $type));
  }

  # Print the end of the here document in "edit" mode.
  if ($base eq 'get' and $request->{'mode'} =~ /edit/) {
    $chunk = ($lastchar eq "\n")?  '' : "\n";
    $chunk .= "ADGBEH";
    eprint($out, $type, "$chunk\n");
  }
    
  # Use the original command name for logging purposes.
  $request->{'command'} = $base . "_done";
  $mj->dispatch($request);
  1;
}


=head2 g_sub($act, ..., $ok, $mess)

This function implements reporting subscribe/unsubscribe results 
If $arg1 - $arg3 are listrefs, it will
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
      eprint($out, $type, indicate("$addr\n", $ok));
      next;
    }
    for (@$addr) {
      my ($verb) = ($ok > 0)?  $act : "not $act";
      $verb =~ s/LIST/$request->{'list'}/;
      if (exists $request->{'sublist'} and $request->{'sublist'} ne 'MAIN') {
        $verb .= ":$request->{'sublist'}";
      }
      eprint($out, $type, "$_ was $verb.\n");
    }
  }
  $ok;
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
  my $type = shift || '';
  return $_ if ($type eq 'text');
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


=head1 NAME

Mj::Format - Turn the results of a core call into formatted output.

=head1 SYNOPSIS

None.

=head1 DESCRIPTION

This takes the values returned from a call to the Majordomo core and
formats them for human consumption.  The core return values are simple
because they were designed to cross a network boundary.  The results are
(for the most part) unformatted because they are not bound to a specific
interface.

Format routines take:
  mj - a majordomo object, so that formatting routines can get config
    variables and call other core functions
  outfh - a filehandle to send output to
  errfh - a filehandle to send error output to
  type - the interface type: text, wwwadm, wwwconfirm, or wwwusr
  request - a hash reference of the data used to issue the command
  result -  a list reference containing the result of the command

Format routines return a value indicating whether or not 
the command completed successfully.

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
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my (@tokens, $data, $fun, $gsubs, $mess, $ok, $rresult, 
      $str, $subs, $tmp, $token);

  $gsubs = { $mj->standard_subs('GLOBAL'),
            'CGIDATA'  => $request->{'cgidata'},
            'CGIURL'   => $request->{'cgiurl'},
            'CMDPASS'  => $request->{'password'},
            'USER'     => &escape("$request->{'user'}", $type),
           };

  @tokens = @$result;
  while (@tokens) {
    $ok = shift @tokens;
    if ($ok == 0) {
      $mess = shift @tokens;
      $gsubs->{'ERROR'} = $mess;

      $tmp = $mj->format_get_string($type, 'accept_error');
      $str = $mj->substitute_vars_format($tmp, $gsubs);
      print $out &indicate($type, "$str\n", $ok); 

      next;
    }

    ($mess, $data, $rresult) = @{shift @tokens};

    $subs = { $mj->standard_subs($data->{'list'}),
              'CGIDATA'  => $request->{'cgidata'},
              'CGIURL'   => $request->{'cgiurl'},
              'CMDPASS'  => $request->{'password'},
              'ERROR'    => '',
              'FAIL'     => '',
              'NOTIFY'   => '',
              'STALL'    => '',
              'SUCCEED'  => '',
              'TOKEN'    => $mess,
              'USER'     => &escape("$request->{'user'}", $type),
            };

    for $tmp (keys %$data) {
      if ($tmp eq 'user') {
        $subs->{'REQUESTER'} = &escape($data->{'user'}, $type);
      }
      elsif ($tmp eq 'time') {
        $subs->{'DATE'} = scalar localtime($data->{'time'});
      }
      else {
        $subs->{uc $tmp} = &escape("$data->{$tmp}", $type);
      }
    }

    if ($ok < 0) {
      $subs->{'ERROR'} = $mess;

      $tmp = $mj->format_get_string($type, 'accept_error');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out &indicate($type, "$str\n", $ok); 
      next;
    }

    # If we accepted a consult token, we can stop now.
    if ($data->{'type'} eq 'consult') {
      if ($data->{'ack'}) {
        $subs->{'NOTIFY'} = " ";
        if (ref($rresult) eq 'ARRAY') {
          if ($rresult->[0] > 0) {
            $subs->{'SUCCEED'} = " ";
          }
          elsif ($rresult->[0] < 0) {
            $subs->{'STALL'} = " ";
          }
          else {
            $subs->{'FAIL'} = " ";
            $subs->{'ERROR'} = $rresult->[1];
          }
        }
      }

      $tmp = $mj->format_get_string($type, 'accept');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out &indicate($type, "$str\n", $ok); 
    }
    else {
      $tmp = $mj->format_get_string($type, 'accept_head');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out &indicate($type, "$str\n", $ok); 

      # Then call the appropriate formatting routine to format the real command
      # return.
      $fun = "Mj::Format::$data->{'command'}";
      {
        no strict 'refs';
        $ok = &$fun($mj, $out, $err, $type, $data, $rresult);
      }

      $tmp = $mj->format_get_string($type, 'accept_foot');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out &indicate($type, "$str\n", $ok); 
    }
  }
  $ok;
}

sub alias {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($ok, $mess) = @$result;

  if ($ok > 0) { 
    eprint($out, $type, "$request->{'newaddress'} was successfully aliased to $request->{'user'}.\n");
  }
  else {
    eprint($out, $type, &indicate($type, 
      qq(The address "$request->{'newaddress'}" was not aliased to "$request->{'user'}".\n), 
      $ok));
    eprint($out, $type, &indicate($type, $mess, $ok));
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
    eprint($out, $type, &indicate($type, $mess, $ok));
  }
  $ok;
}

use Date::Format;
sub archive {
  my ($mj, $out, $err, $type, $request, $result) = @_;
 
  my (%stats, @tmp, $chunksize, $data, $first, $i, $j, $last, 
      $line, $lines, $mess, $msg, $str, $size, $subs, $tmp);
  my ($ok, @msgs) = @$result;

  $subs = {
           $mj->standard_subs($request->{'list'}),
           'CGIDATA'     => $request->{'cgidata'} || '',
           'CGIURL'      => $request->{'cgiurl'} || '',
           'CMDPASS'     => $request->{'password'},
           'TOTAL_POSTS' => scalar @msgs,
           'USER'        => &escape("$request->{'user'}", $type),
          };

  if ($ok <= 0) { 
    $subs->{'ERROR'} = $msgs[0];
    $tmp = $mj->format_get_string($type, 'archive_error');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
    return $ok;
  }
  unless (@msgs) {
    $tmp = $mj->format_get_string($type, 'archive_none');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
    # reset the arcadmin flag.
    $request->{'command'} = "archive_done";
    $mj->dispatch($request);
    return 1;
  }

  $request->{'command'} = "archive_chunk";

  if ($request->{'mode'} =~ /sync/) {
    for (@msgs) {
      ($ok, $mess) = @{$mj->dispatch($request, [$_])};
      eprint($out, $type, indicate($type, $mess, $ok));
    }
  }
  elsif ($request->{'mode'} =~ /summary/) {
    $tmp = $mj->format_get_string($type, 'archive_summary_head');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";

    $tmp = $mj->format_get_string($type, 'archive_summary');

    for $i (@msgs) {
      ($mess, $data) = @$i;
      for $j (keys %$data) {
        $subs->{uc $j} = &escape($data->{$j}, $type);
      }
      $subs->{'FILE'} = $mess;
      $subs->{'SIZE'} = sprintf "%.1f", ($data->{'bytes'} / 1024);
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }

    $tmp = $mj->format_get_string($type, 'archive_summary_foot');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }
  elsif ($request->{'mode'} =~ /get|delete|edit|replace/) {
    if ($request->{'mode'} !~ /part|edit/) {
      $tmp = $mj->format_get_string($type, 'archive_get_head');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }

    $chunksize = 
      $mj->global_config_get($request->{'user'}, $request->{'password'}, 
                             "chunksize") || 1000;

    $lines = 0; @tmp = ();
    # Chunksize is 1000 lines by default.  If a group
    # of messages exceeds that size, dispatch the request
    # and print the result.
    for ($i = 0; $i <= $#msgs; $i++) {
      ($msg, $data) = @{$msgs[$i]};
      push @tmp, $msgs[$i];
      $lines += $data->{'lines'};
      if (($request->{'mode'} =~ /digest/ and $lines > $chunksize) 
          or $i == $#msgs) {

        if ($request->{'mode'} =~ /part|edit/) {
          _archive_part($mj, $out, $err, $type, $request, [@tmp]);
        }
        else {
          ($ok, $mess) = @{$mj->dispatch($request, [@tmp])};
          eprint($out, $type, indicate($type, $mess, $ok));
        }

        $lines = 0; @tmp = ();
      }
    }

    if ($request->{'mode'} !~ /part|edit/) {
      $tmp = $mj->format_get_string($type, 'archive_get_foot');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
  }
  elsif ($request->{'mode'} =~ /stats/) {
    $first = time;
    $last = 0;
    $size = 0;
    $chunksize = scalar @msgs;
    for $i (@msgs) {
      $data = $i->[1];
      $first = $data->{'date'} if ($data->{'date'} < $first);
      $last = $data->{'date'} if ($data->{'date'} > $last);
      unless (exists $stats{$data->{'from'}}) {
        $stats{$data->{'from'}}{'count'} = 0;
        $stats{$data->{'from'}}{'size'} = 0;
      }

      $stats{$data->{'from'}}{'count'}++;
      $stats{$data->{'from'}}{'size'} += $data->{'bytes'};
      $size += $data->{'bytes'};
    }
    @tmp = localtime $first;
    $subs->{'START'} = strftime("%Y-%m-%d %H:%M", @tmp);
    @tmp = localtime $last;
    $subs->{'FINISH'} = strftime("%Y-%m-%d %H:%M", @tmp);
    $subs->{'AUTHORS'} = [];
    $subs->{'POSTS'} = [];
    $subs->{'KILOBYTES'} = [];
    $subs->{'TOTAL_KILOBYTES'} = int(($size + 512) / 1024);
    for $i (sort { $stats{$b}{'count'} <=> $stats{$a}{'count'} } keys %stats) {
      push @{$subs->{'AUTHORS'}}, &escape($i, $type);
      push @{$subs->{'POSTS'}}, $stats{$i}{'count'};
      push @{$subs->{'KILOBYTES'}}, int(($stats{$i}{'size'} + 512) / 1024);
    }
    $tmp = $mj->format_get_string($type, 'archive_stats');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }
  else {
    # The archive-index command.
    $tmp = $mj->format_get_string($type, 'archive_head');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";

    $tmp = $mj->format_get_string($type, 'archive_index');
    for $i (@msgs) {
      $data = $i->[1];
      $data->{'subject'} ||= "(No Subject)";
      $data->{'from'} ||= "(Unknown Author)";
      # Include all archive data in the substitutions.
      for $j (keys %$data) {
        $subs->{uc $j} = &escape($data->{$j}, $type);
      }

      @tmp = localtime $data->{'date'};
      $subs->{'DATE'}  = strftime("%Y-%m-%d %H:%M", @tmp);
      $subs->{'MSGNO'} = $i->[0];
      $subs->{'SIZE'}  = sprintf "%.1f", (($data->{'bytes'})/1024);
      $subs->{'FROM'}  = &escape($data->{'from'}, $type);
      if (exists($data->{'hidden'}) and $data->{'hidden'}) {
        $subs->{'HIDDEN'} = '*';
      }
      else {
        $subs->{'HIDDEN'} = ' ';
      }
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }

    $tmp = $mj->format_get_string($type, 'archive_foot');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }

  $request->{'command'} = "archive_done";
  $mj->dispatch($request); 
 
  $ok;
}

use MIME::Head;
sub _archive_part {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, $request->{'args'};
  my (@tmp, $arc, $data, $expire, $fh, $head, $hsubs, $i, $j, $lastchar, 
      $msgdata, $msgno, $ok, $part, $showhead, $str, $subs, $tmp);

  $msgno   = $result->[0]->[0];
  $data    = $result->[0]->[1];
  $msgdata = $result->[0]->[2];
  ($arc) = $msgno =~ m!([^/]+)/.*!;

  unless (ref $msgdata eq 'HASH') {
    $subs = { $mj->standard_subs($request->{'list'}),
              'ARCHIVE' => $arc,
              'CGIDATA' => $request->{'cgidata'} || '',
              'CGIURL'  => $request->{'cgiurl'} || '',
              'CMDPASS' => $request->{'password'},
              'ERROR'   => "The structure of the message $msgno is invalid.\n",
              'MSGNO'   => $msgno,
              'USER'    => &escape("$request->{'user'}", $type),
            };
    $tmp = $mj->format_get_string($type, 'archive_error');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", 0, 1);
    return 0;
  }
 
  $subs = { $mj->standard_subs($request->{'list'}),
            'ARCHIVE' => $arc,
            'CGIDATA' => $request->{'cgidata'} || '',
            'CGIURL'  => $request->{'cgiurl'} || '',
            'CMDPASS' => &escape($request->{'password'}, $type),
            'MSGNO'   => $msgno,
            'PART'    => $request->{'part'},
            'USER'    => &escape("$request->{'user'}", $type),
          };

  # archive-get-part for a part other than 0
  # or archive-edit-part:
  # display the results without formatting.
  if (($request->{'mode'} =~ /get/ and $request->{'part'} ne '0') or
      $request->{'mode'} =~ /edit/
     ) {

    $part = $request->{'part'} || 0;
    if ($part =~ s/[hH]$//) {
      $subs->{'CONTENT_TYPE'} = "header";
      $subs->{'SIZE'} = 
        sprintf("%.1f", (length($msgdata->{$part}->{'header'}) + 51) / 1024);
      $showhead = 1;
    }
    else {
      $subs->{'CONTENT_TYPE'} = $msgdata->{$part}->{'type'};
      $subs->{'SIZE'} = $msgdata->{$part}->{'size'};
      $showhead = 0;
    }

    if ($request->{'mode'} =~ /edit/) {
      $tmp = $mj->format_get_string($type, 'archive_edit_head');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }

    # Display formatted part/header contents.
    if ($showhead) {
      print $out "$msgdata->{$part}->{'header'}\n";
      $lastchar = substr $msgdata->{$part}->{'header'}, -1;
    }
    else {
      $request->{'command'} = 'archive_chunk';

      # In "edit" mode, determine if the text ends with a newline,
      # and add one if not.
      $lastchar = "\n";

      ($ok, $tmp) = @{$mj->dispatch($request, $result)};
      $lastchar = substr $tmp, -1;
      print $out $tmp;
      last unless $ok;
    }

    if ($request->{'mode'} =~ /edit/) {
      $tmp = $mj->format_get_string($type, 'archive_edit_foot');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
  }

  # archive-replace-part or archive-delete-part 
  # or archive-get-part for part 0
  else {
    $request->{'command'} = 'archive_chunk';

    if ($request->{'mode'} =~ /delete/) {
      ($ok, $tmp) = @{$mj->dispatch($request, $result)};
      if ($ok) {
        $tmp = $mj->format_get_string($type, 'archive_part_delete');
      }
      else {
        $subs->{'ERROR'} = $tmp;
        $tmp = $mj->format_get_string($type, 'archive_error');
      }
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
    elsif ($request->{'mode'} =~ /replace/) {
      ($ok, $tmp) = @{$mj->dispatch($request, $result)};
      if ($ok) {
        $tmp = $mj->format_get_string($type, 'archive_part_replace');
      }
      else {
        $subs->{'ERROR'} = $tmp;
        $tmp = $mj->format_get_string($type, 'archive_error');
      }
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
 
    for $j (keys %$data) {
      $subs->{uc $j} = &escape($data->{$j}, $type);
    }

    $tmp = $mj->format_get_string($type, 'archive_msg_head');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";


    for $i (sort keys %$msgdata) {
      next if ($i eq '0');
      $subs->{'CONTENT_TYPE'} = $msgdata->{$i}->{'type'};
      $subs->{'PART'}         = $i;
      $subs->{'SIZE'}         = $msgdata->{$i}->{'size'};
      $subs->{'SUBPART'}      = $i eq '1' ? '' : " ";

      # Display formatted headers for the top-level part 
      # and for any nested messages.
      if ($i eq '1' or $msgdata->{$i}->{'header'} =~ /received:/i) {
        @tmp = split ("\n", $msgdata->{$i}->{'header'});
        $head = new MIME::Head \@tmp;
        if ($head) {
          $hsubs = { 
                    'HEADER_CC'      => '',
                    'HEADER_DATE'    => '',
                    'HEADER_FROM'    => '',
                    'HEADER_SUBJECT' => '',
                    'HEADER_TO'      => '',
                    'HEADER_X_ARCHIVE_NUMBER'  => '',
                    'HEADER_X_SEQUENCE_NUMBER' => '',
                   };
          for $j (map { uc $_ } $head->tags) {
            @tmp = map { chomp $_; &escape($_, $type) } $head->get($j);
            $j =~ s/[^A-Z]/_/g;
            if (scalar @tmp > 1) {
              $hsubs->{"HEADER_$j"} = [ @tmp ];
            }
            else {
              $hsubs->{"HEADER_$j"} = $tmp[0];
            }
          }
          $tmp = $mj->format_get_string($type, 'archive_header');
          $str = $mj->substitute_vars_format($tmp, $subs);
          $str = $mj->substitute_vars_format($str, $hsubs);
          print $out "$str\n";
        }
      }

      # Display the contents of plain text parts.
      if ($msgdata->{$i}->{'type'} =~ m#^text/plain#i) {
        $request->{'part'} = $i;
        $request->{'mode'} = 'get-part';
        $tmp = $mj->format_get_string($type, 'archive_text_head');
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";

        ($ok, $tmp) = @{$mj->dispatch($request, $result)};
        eprint($out, $type, $tmp);

        $tmp = $mj->format_get_string($type, 'archive_text_foot');
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }
      
      # Display images.
      elsif ($msgdata->{$i}->{'type'} =~ /^image/i) {
        $tmp = $mj->format_get_string($type, 'archive_image');
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }

      # Display containers, such as multipart types.
      elsif (! length ($msgdata->{$i}->{'size'})) {
        $tmp = $mj->format_get_string($type, 'archive_container');
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }

      # Display summaries of other body parts.
      else {
        $tmp = $mj->format_get_string($type, 'archive_attachment');
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }
    }

    $tmp = $mj->format_get_string($type, 'archive_msg_foot');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";

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
    eprint($out, $type, &indicate($type, 
      "Change from $request->{'victim'} to $request->{'user'} stalled, awaiting approval.\n",
      $ok));
    eprint($out, $type, &indicate($type, $mess, $ok)) if ($mess);
  }
  else {
    eprint($out, $type, &indicate($type, 
      "$request->{'victim'} was not changed to $request->{'user'}.\n",
      $ok));
    eprint($out, $type, &indicate($type, $mess, $ok)) if ($mess);
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

    eprint ($out, $type, indicate($type, $mess,$ok)) if $mess;
    if ($ok > 0) {
      eprint($out, $type, "The $var setting was reset to its default value.\n");
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
  eprint($out, $type, indicate($type, $mess, $ok)) if $mess;
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
  my (@possible, $array, $auto, $bool, $cgidata, $cgiurl, $data, 
      $earray, $enum, $gen, $gsubs, $i, $isauto, $list, $mess, 
      $mode, $mode2, $ok, $short, $str, $subs, $tag, $tmp, $val, 
      $var, $vardata, $varresult);

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
  elsif ($request->{'mode'} =~ /noforce/) {
    $mode = $mode2 = '-noforce';
  }

  $cgidata = $request->{'cgidata'} || '';
  $cgiurl  = $request->{'cgiurl'} || '';

  $gsubs = { $mj->standard_subs($list),
            'CGIDATA'  => $cgidata,
            'CGIURL'   => $cgiurl,
            'CMDPASS'  => $request->{'password'},
            'USER'     => &escape("$request->{'user'}", $type),
          };

  $ok = shift @$result;
  unless ($ok) {
    $mess = shift @$result;
    $gsubs->{'ERROR'} = $mess;
    $tmp = $mj->format_get_string($type, 'configshow_error');
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out &indicate($type, "$str\n", $ok);
    return $ok;
  }

  unless (scalar @$result) {
    $tmp = $mj->format_get_string($type, 'configshow_none');
    $mess = $mj->substitute_vars_format($tmp, $gsubs);
    print $out &indicate($type, "$mess\n", $ok);
    return $ok;
  }

  $gsubs->{'COMMENTS'} = ($request->{'mode'} !~ /nocomments/) ? '#' : '';
  $subs = { %$gsubs };
  $subs->{'COMMENT'} = '';

  if ($request->{'mode'} !~ /categories/) {
    $tmp = $mj->format_get_string($type, 'configshow_head');
    $gen   = $mj->format_get_string($type, 'configshow');
  }
  else {
    $tmp = $mj->format_get_string($type, 'configshow_categories_head');
    $gen = $mj->format_get_string($type, 'configshow_categories');
  }
  $str = $mj->substitute_vars_format($tmp, $gsubs);
  print $out "$str\n";

  $array = $mj->format_get_string($type, 'configshow_array');
  $bool  = $mj->format_get_string($type, 'configshow_bool');
  $enum  = $mj->format_get_string($type, 'configshow_enum');
  $earray= $mj->format_get_string($type, 'configshow_enum_array');
  $short = $mj->format_get_string($type, 'configshow_short');

  for $varresult (@$result) {
    ($ok, $mess, $data, $var, $val) = @$varresult;
    $subs->{'SETTING'} = $var;

    if (! $ok) {
      $subs->{'ERROR'} = $mess;
      $tmp = $mj->format_get_string($type, 'configshow_error');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out &indicate($type, "$str\n", $ok);
      next;
    }

    if ($request->{'mode'} =~ /categories/) {
      $subs->{'CATEGORY'} = $var;
      $subs->{'COMMENT'}  = $mess;
      next unless ($subs->{'COUNT'} = scalar (@$val));
      $subs->{'SETTING'}  = uc $var;
      @possible = sort @$val;
      $subs->{'SETTINGS'} = [ @possible ];
      $str = $mj->substitute_vars_format($gen, $subs);
      print $out &indicate($type, "$str\n", $ok);
      next;
    }
      
    $subs->{'COMMENT'}  = '';
    $subs->{'DEFAULTS'} = $data->{'defaults'};
    $subs->{'ENUM'}     = $data->{'enum'};
    $subs->{'GROUPS'}   = $data->{'groups'};

    if ($mj->{'interface'} =~ /^www/) {
      $subs->{'HELPLINK'} = 
      qq(<a href="$cgiurl?$cgidata\&amp;list=$list\&amp;func=help\&amp;extra=$var" target="_mj2help">$var</a>);
    }
    $subs->{'LEVEL'}    = $ok;
    $subs->{'TYPE'}     = $data->{'type'};

    if ($request->{'mode'} !~ /nocomments/) {
      $mess =~ s/^/# /gm if ($type eq 'text');
      chomp $mess;
      $mess = &escape($mess, $type);
      $subs->{'COMMENT'} = $mess;
    }

    $auto = '';
    if ($data->{'auto'}) {
      $auto = '# ';
    }

    # Determine the type of the variable
    $vardata = $Mj::Config::vars{$var};

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
          $val->[$i] = &escape($val->[$i], $type);
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

      if ($vardata->{'type'} eq 'enum_array') {
        $tmp = $earray;
        if ($type =~ /^www/) {
          @possible = sort @{$vardata->{'values'}};
          $subs->{'SETTINGS'} = [@possible];
          $subs->{'SELECTED'} = [];
          $subs->{'CHECKED'}  = [];
          for $str (@possible) {
            if (grep { $_ eq $str } @$val) {
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
        $tmp = $array;
      }
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
    else {
      # Process as a simple variable
      $subs->{'SETCOMMAND'} = 
        $auto . "configset$mode2 $list $var = ";

      $val = "" unless defined $val;
      $val = &escape($val) if ($type =~ /^www/);

      if ($type eq 'text' and length $val > 40) {
        $auto = "\\\n    $auto";
      }

      $subs->{'SETCOMMAND'} .= "$auto$val\n";
      $subs->{'VALUE'} = $val;

      if ($vardata->{'type'} =~ /^(integer|word|pw)$/) {
        $tmp = $short;
      }
      elsif ($vardata->{'type'} eq 'bool') {
        $tmp = $bool;
        if ($type =~ /^www/) {
          require Mj::Util;
          $str = &Mj::Util::str_to_bool($val);
          $subs->{'YES'} = ($str > 0) ? " " : '';
          $subs->{'NO'} = ($str == 0) ? " " : '';
        }
      }
      elsif ($vardata->{'type'} eq 'enum') {
        $tmp = $enum;
        if ($type =~ /^www/) {
          @possible = sort @{$vardata->{'values'}};
          $subs->{'SETTINGS'} = [@possible];
          $subs->{'SELECTED'} = [];
          $subs->{'CHECKED'}  = [];
          for $str (@possible) {
            if ($val eq $str) {
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
      print $out "$str\n";
    }
  }

  if ($request->{'mode'} =~ /categories/) {
    $tmp = $mj->format_get_string($type, 'configshow_categories_foot');
  }
  else {
    $tmp = $mj->format_get_string($type, 'configshow_foot');
  }
  $str = $mj->substitute_vars_format($tmp, $gsubs);
  print $out "$str\n";

  1;
}

sub createlist {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29;
  my ($i, $j, $str, $subs, $tmp);
  my ($ok, $mess) = @$result;

  $subs = {
           $mj->standard_subs('GLOBAL'),
           'CGIDATA' => $request->{'cgidata'} || '',
           'CGIURL'  => $request->{'cgiurl'} || '',
           'CMDPASS' => $request->{'password'},
           'USER'    => &escape("$request->{'user'}", $type),
          };

  unless ($ok > 0) {
    $subs->{'ERROR'} = $mess;
    $tmp = $mj->format_get_string($type, 'createlist_error');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
    return $ok;
  }

  for $j (keys %$mess) {
    $subs->{uc $j} = &escape($mess->{$j}, $type);
  }

  if ($request->{'mode'} =~ /destroy/) {
    $tmp = $mj->format_get_string($type, 'createlist_destroy');
  }
  elsif ($request->{'mode'} =~ /nocreate/) {
    $tmp = $mj->format_get_string($type, 'createlist_nocreate');
  }
  elsif ($request->{'mode'} =~ /regen/) {
    $tmp = $mj->format_get_string($type, 'createlist_regen');
  }
  elsif ($request->{'mode'} =~ /rename/) {
    $tmp = $mj->format_get_string($type, 'createlist_rename');
  }
  else {
    $tmp = $mj->format_get_string($type, 'createlist');
  }

  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out &indicate($type, "$str\n", $ok, 1);

  $ok;
}

use Mj::Util qw(str_to_offset time_to_str);
sub digest {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($comm, $digest, $i, $msgdata);
  my ($ok, $mess) = @$result;
  unless ($ok > 0) {
    eprint($out, $type, 
           &indicate($type, "The digest-$request->{'mode'} command failed.\n", $ok));
    eprint($out, $type, &indicate($type, $mess, $ok));
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
        scalar localtime($digest->{'lastrun'} + 
          str_to_offset($digest->{'separate'}, 1, 0, $digest->{'lastrun'})) 
                 if ($digest->{'lastrun'} and $digest->{'separate'});
      $comm .= sprintf "Age of oldest message      %s\n", 
                 time_to_str(time - $digest->{'oldest'}, 1)
                 if ($digest->{'oldest'});
      $comm .= sprintf "Oldest age allowed         %s\n", 
                 str_to_offset($digest->{'maxage'}, 0, 1)
                 if ($digest->{'maxage'});
      $comm .= sprintf "Age of newest message      %s\n", 
                 time_to_str(time - $digest->{'newest'}, 1)
                 if ($digest->{'newest'});
      $comm .= sprintf "Minimum age required       %s\n", 
                 str_to_offset($digest->{'minage'}, 0, 1)
                 if ($digest->{'minage'});
      $comm .= sprintf "Messages awaiting delivery %d\n", 
                 scalar @{$digest->{'messages'}} if ($digest->{'messages'});
      $comm .= sprintf "Minimum message count      %d\n", 
                 $digest->{'minmsg'} if ($digest->{'minmsg'});
      $comm .= sprintf "Maximum message count      %d\n", 
                 $digest->{'maxmsg'} if ($digest->{'maxmsg'});
      $comm .= sprintf "Minimum size of a digest   %d bytes\n", 
                 $digest->{'minsize'} if ($digest->{'minsize'});
      $comm .= sprintf "Maximum size of a digest   %d bytes\n", 
                 $digest->{'maxsize'} if ($digest->{'maxsize'});
      $comm .= sprintf "Message total size         %d bytes\n", 
                 $digest->{'bytecount'} if ($digest->{'bytecount'});
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

sub faq   {g_get("faq",   @_)}
sub get   {g_get("get",   @_)}
sub info  {g_get("info",  @_)}
sub intro {g_get("intro", @_)}

sub help {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, $request->{'topic'};
  my ($cgidata, $cgiurl, $chunk, $chunksize, $domain, 
      $hwin, $list, $tmp, $topic);
  my ($ok, $mess) = @$result;

  unless ($ok > 0) {
    print $out &indicate($type, "Help $request->{'topic'} failed.\n$mess", $ok);
    return $ok;
  }

  $chunksize = $mj->global_config_get($request->{'user'}, $request->{'password'},
                                      "chunksize") || 1000;
  $tmp = $mj->global_config_get($request->{'user'}, $request->{'password'},
                                'www_help_window');
  $hwin = $tmp ? ' target="mj2help"' : '';

  $cgidata = $request->{'cgidata'} || '';
  $cgiurl  = $request->{'cgiurl'} || '';
  $list    = $request->{'list'};
  $domain  = $mj->{'domain'};

  $request->{'command'} = "get_chunk";

  while (1) {
    ($ok, $chunk) = @{$mj->dispatch($request, $chunksize)};
    last unless defined $chunk;
    if ($type =~ /www/) { 
      $chunk = &escape($chunk);
      $chunk =~ s/(\s{3}|&quot;)(help\s)(configset|admin|mj) (?=\w)/$1$2$3_/g;
      $chunk =~ 
       s#(\s{3}|&quot;)(help\s)(\w+)#$1$2<a href="$cgiurl?\&amp;${cgidata}\&amp;list=${list}\&amp;func=help\&amp;extra=$3"$hwin>$3</a>#g;
    }
    print $out $chunk;
  }

  $request->{'command'} = "help_done";
  $mj->dispatch($request);
  1;
}

sub index {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my (%legend, @index, @item, @width, $count, $i, $j);
  $count = 0;
  @width = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

  my ($ok, @in) = @$result;
  unless ($ok > 0) {
    eprint($out, $type, &indicate($type, "The index command failed.\n", $ok));
    eprint($out, $type, &indicate($type, $in[0], $ok)) if $in[0];
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
                "  %-$width[0]s %$width[7]d %s\n", $i->[0], $i->[7], $i->[2]);
      }
    }
    return 1 if $request->{'mode'} =~ /short/;
    eprint($out, $type, "\n");
    eprintf($out, $type, "%d file%s.\n", $count,$count==1?'':'s');
  }
  else {
    eprint($out, $type, qq(The "$request->{'path'}" directory is empty .\n));
  }
  1;
}

sub lists {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my (%lists, $basic_format, $cat_format, $category, $count, $data, 
      $desc, $digests, $flags, $global_subs, $i, $legend, $list, 
      $site, $str, $subs, $tmp);
  my $log = new Log::In 29, $type;
  $count = 0;
  $legend = 0;

  ($site) = $mj->global_config_get($request->{'user'}, $request->{'pass'}, 
                                   'site_name');
  $site ||= $mj->global_config_get($request->{'user'}, $request->{'pass'}, 
                                   'whoami');

  my ($ok, @lists) = @$result;

  $global_subs = {
           $mj->standard_subs('GLOBAL'),
           'CGIDATA' => $request->{'cgidata'} || '',
           'CGIURL'  => $request->{'cgiurl'} || '',
           'CMDPASS' => $request->{'password'},
           'PATTERN' => $request->{'regexp'},
           'USER'    => &escape("$request->{'user'}", $type),
          };

  if ($ok <= 0) {
    $global_subs->{'ERROR'} = &escape($lists[0], $type);
    $tmp = $mj->format_get_string($type, 'lists_error');
    $str = $mj->substitute_vars_format($tmp, $global_subs);
    print $out &indicate($type, "$str\n", $ok, 1);
    return 1;
  }
  
  if (@lists) {
    unless ($request->{'mode'} =~ /compact|tiny/) {
      $tmp = $mj->format_get_string($type, 'lists_head');
      $str = $mj->substitute_vars_format($tmp, $global_subs);
      print $out "$str\n";
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
        print $out "$str\n";
      }
      for $list (sort keys %{$lists{$category}}) {
        $count++ unless ($list =~ /:/);
        $data = $lists{$category}{$list};
        $flags = $data->{'flags'} ? "+" : " ";
        if ($request->{'mode'} =~ /tiny/) {
          print $out "$list\n";
          next;
        }
        $legend++ if $data->{'flags'};
        $tmp  = $data->{'description'}
                 || "(no description)";
        $desc = [ split ("\n", $tmp) ];

        $digests = [];
        for $i (sort keys %{$data->{'digests'}}) {
          push @$digests, "$i: $data->{'digests'}->{$i}";
        }
        $digests = ["(none)\n"] if ($list =~ /:/);

        $subs = { 
                  %{$global_subs},
                  'ARCURL'        => $data->{'archive'} || "",
                  'CAN_READ'      => $data->{'can_read'} ? " " : '',
                  'CATEGORY'      => $category || "?",
                  'CGIURL'        => $request->{'cgiurl'} || "",
                  'CMDPASS'       => $request->{'password'},
                  'DESCRIPTION'   => $desc,
                  'DIGESTS'       => $digests,
                  'FLAGS'         => $flags,
                  'LIST'          => $list,
                  'OWNER'         => $data->{'owner'},
                  'POSTS'         => $data->{'posts'},
                  'SUBS'          => $data->{'subs'},
                  'USER'          => &escape("$request->{'user'}", $type),
                  'WHOAMI'        => $data->{'address'},
                };
                  
        $str = $mj->substitute_vars_format($basic_format, $subs);
        print $out "$str\n";
      }
    }
  }
  else {
    # No lists were found.
    $tmp = $mj->format_get_string($type, 'lists_none');
    $str = $mj->substitute_vars_format($tmp, $global_subs);
    print $out "$str\n";
  }

  return 1 if $request->{'mode'} =~ /compact|tiny/;

  $subs = {
            %{$global_subs},
            'COUNT' => $count,
          };
  $tmp = $mj->format_get_string($type, 'lists_foot');
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out "$str\n";

  if ($request->{'mode'} =~ /enhanced/) {
    $subs = {
              %{$global_subs},
              'COUNT'         =>  $count,
              'SUBSCRIPTIONS' =>  $legend,
              'USER'          => &escape("$request->{'user'}", $type),
            };
    $tmp = $mj->format_get_string($type, 'lists_enhanced');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }
  1;
}

sub password {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, $type;
  my ($str, $subs, $tmp);

  my ($ok, $mess) = @$result; 

  if ($ok>0) {
    $subs = {
             $mj->standard_subs('GLOBAL'),
             'VICTIM' => "$request->{'victim'}",
            };
    $tmp = $mj->format_get_string($type, 'password');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
  }
  else {
    eprint($out, $type, &indicate($type, "Password not set.\n", $ok));
  }
  if ($mess) {
    eprint($out, $type, &indicate($type, $mess, $ok));
  }
  $ok;
}

sub post {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($i, $ok, $mess, $handled); 
  $handled = 0;
  $handled = 1 if (ref ($request->{'message'}) =~ /^IO/);
 
  # The message will have been posted already if this subroutine
  # is called by Mj::Token::t_accept . 
  if (exists $request->{'message'}) { 
    $request->{'command'} = "post_chunk"; 
    while (1) {
      $i = $handled ? 
        $request->{'message'}->getline :
        shift @{$request->{'message'}};
      last unless defined $i;
      # Mj::Parser creates an argument list without line feeds.
      $i .= "\n" unless $handled;
     
      # YYY  Needs check for errors 
      ($ok, $mess) = @{$mj->dispatch($request, $i)};
      last unless $ok;
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
  eprint($out, $type, indicate($type, $mess, $ok, 1)) if ($mess and ($ok <= 0));

  return $ok;
}

sub put {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($act, $chunk, $chunksize, $handled, $i);
  my ($ok, $mess) = @$result;

  if    ($request->{'file'} eq '/info' ) {$act = 'newinfo' }
  elsif ($request->{'file'} eq '/intro') {$act = 'newintro'}
  elsif ($request->{'file'} eq '/faq'  ) {$act = 'newfaq'  }
  else                                   {$act = 'put'     }

  unless ($ok) {
    eprint($out, $type, &indicate($type, "The $act command failed.\n", $ok));
    eprint($out, $type, &indicate($type, $mess, $ok)) if $mess;
    return $ok;
  }

  $handled = 0;
  $handled = 1 if (ref ($request->{'contents'}) =~ /^IO/);

  $chunksize = $mj->global_config_get(undef, undef, "chunksize");
  $chunksize ||= 1000;
  $chunksize *= 80;

  $request->{'command'} = "put_chunk"; 

  $chunk = '';
  while (1) {
    last if ($request->{'mode'} =~ /dir|delete/);
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

  unless ($request->{'mode'} =~ /dir|delete/) {
    $request->{'command'} = "put_done"; 
    ($ok, $mess) = @{$mj->dispatch($request)};
  }

  if ($ok > 0) {
    eprint($out, $type, "The $act command succeeded.\n");
  }
  elsif ($ok < 0) {
    eprint($out, $type, &indicate($type, "The $act command stalled.\n", $ok));
  }
  else {
    eprint($out, $type, &indicate($type, "The $act command failed.\n", $ok));
  }
  eprint($out, $type, &indicate($type, $mess, $ok, 1)) if $mess;

  return $ok;
} 

sub register {
  g_sub('reg', @_)
}

sub reject {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, $type;
  my (@tokens, $data, $gsubs, $mess, $ok, $str, $subs, $tmp, $token);

  $gsubs = { $mj->standard_subs('GLOBAL'),
            'CGIDATA'  => $request->{'cgidata'},
            'CGIURL'   => $request->{'cgiurl'},
            'CMDPASS'  => $request->{'password'},
            'USER'     => &escape("$request->{'user'}", $type),
           };

  @tokens = @$result; 

  while (@tokens) {
    ($ok, $mess) = splice @tokens, 0, 2;
    unless ($ok) {
      $gsubs->{'ERROR'} = $mess;

      $tmp = $mj->format_get_string($type, 'reject_error');
      $str = $mj->substitute_vars_format($tmp, $gsubs);
      print $out &indicate($type, "$str\n", $ok); 

      next;
    }

    ($token, $data) = @$mess;

    $subs = { $mj->standard_subs($data->{'list'}),
              'CGIDATA'  => $request->{'cgidata'},
              'CGIURL'   => $request->{'cgiurl'},
              'CMDPASS'  => $request->{'password'},
              'ERROR'    => '',
              'NOTIFY'   => '',
              'TOKEN'    => $token,
              'USER'     => &escape("$request->{'user'}", $type),
            };

    for $tmp (keys %$data) {
      if ($tmp eq 'user') {
        $subs->{'REQUESTER'} = &escape($data->{'user'}, $type);
      }
      elsif ($tmp eq 'time') {
        $subs->{'DATE'} = scalar localtime($data->{'time'});
      }
      else {
        $subs->{uc $tmp} = &escape("$data->{$tmp}", $type);
      }
    }

    if ($ok < 0) {
      $subs->{'ERROR'} = $mess;

      $tmp = $mj->format_get_string($type, 'reject_error');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out &indicate($type, "$str\n", $ok); 
      next;
    }

    if ($request->{'mode'} !~ /quiet/ and 
        ($data->{'type'} ne 'consult' or $data->{'ack'})) 
    {
      $subs->{'NOTIFY'} = " ";
    }

    $tmp = $mj->format_get_string($type, 'reject');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok); 
  }

  1;
}

sub rekey {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'mode'}";
  my ($changed, $count, $i, $list, $unreg, $unsub);

  my ($ok, $ra, $rca, $aa, $aca) = @$result; 
  if ($ok > 0) {
    if ($request->{'mode'} =~ /repair/) {
      eprint($out, $type, "Repairing the registry and subscriber databases.\n");
      eprint($out, $type, "Mailing List         Number of repaired addresses\n");
      eprint($out, $type, "------------         ----------------------------\n");
    }
    elsif ($request->{'mode'} =~ /verify/) {
      eprint($out, $type, "Verifying the registry and subscriber databases.\n");
      eprint($out, $type, "Mailing List         Number of invalid addresses\n");
      eprint($out, $type, "------------         ---------------------------\n");
    }
    elsif ($request->{'mode'} =~ /noxform/) {
      eprint($out, $type, "Examining the registry and subscriber databases.\n\n");
      eprint($out, $type, "Mailing List         Number of miskeyed addresses\n");
      eprint($out, $type, "------------         ----------------------------\n");
      eprintf($out, $type, "global registry      %4d out of %d\n",
              $rca, $ra);
      eprintf($out, $type, "global aliases       %4d out of %d\n",
              $aca, $aa);

    }
    else {
      eprint($out, $type, "Applying address transformations.\n\n");
      eprint($out, $type, "Mailing List         Number of updated addresses\n");
      eprint($out, $type, "------------         ---------------------------\n");
      eprintf($out, $type, "global registry      %4d out of %d\n",
              $rca, $ra);
      eprintf($out, $type, "global aliases       %4d out of %d\n",
              $aca, $aa);
    }

    $request->{'command'} = "rekey_chunk";
    
    while (1) {
      ($ok, $list, $count, $unsub, $unreg, $changed) = 
        @{$mj->dispatch($request)};

      last unless (defined $ok);

      unless ($ok > 0) {
        eprint($out, $type, &indicate($type, $count, $ok));
        next;
      }

      next if ($list eq 'DEFAULT' or $list eq 'GLOBAL');

      eprintf($out, $type, "%-20s %4d out of %d\n", $list, $changed, 
              $count + scalar(keys %$unsub));
      if ($request->{'mode'} =~ /repair/) {
        for $i (keys %$unreg) {
          eprint($out, $type, "  The registry entry for $i was repaired.\n");
        }
        for $i (keys %$unsub) {
          eprint($out, $type, "  The subscription for $i was repaired.\n");
        }
      }
      elsif ($request->{'mode'} =~ /verify/) {
        for $i (keys %$unreg) {
          eprint($out, $type, "  The registry entry for $i is incorrect.\n");
        }
        for $i (keys %$unsub) {
          eprint($out, $type, "  The subscription for $i is missing.\n");
        }
      }
    }
  }
  else {
    eprint($out, $type, "The registry and subscriber databases were not rekeyed.\n");
    eprint($out, $type, &indicate($type, $ra, $ok));
    return 0;
  }
  
  $request->{'command'} = "rekey_done";
  $mj->dispatch($request);
  1;
}

use Date::Format;
sub report {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type";
  my (%outcomes, %stats, @tmp, $begin, $chunk, $chunksize, 
      $data, $day, $end, $today, $victim);
  my ($ok, $mess) = @$result;

  unless ($ok > 0) {
    eprint($out, $type, &indicate($type, "Unable to create report\n", $ok));
    eprint($out, $type, &indicate($type, $mess, $ok, 1)) if $mess;
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
                           "chunksize") || 1000;

  $request->{'command'} = "report_chunk";

  while (1) {
    ($ok, $chunk) = @{$mj->dispatch($request)};
    unless ($ok) {
      eprint($out, $type, &indicate($type, $chunk, $ok, 1)) if $chunk;
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

        # display the command, [list,] victim, result, time,
        # and duration of each command.
        if ($request->{'list'} eq 'ALL') { 
          $mess = sprintf "%-11s %-16s %-30s %-7s %s\n", 
                          $data->[1], $data->[0], $victim,
                          $outcomes{$data->[6]}, $end;
        }
        else {
          $mess = sprintf "%-11s %-44s %-7s %s\n", $data->[1],
                  $victim, $outcomes{$data->[6]}, $end;
        }

        if ($request->{'mode'} =~ /full/) {
          # display the command line, interface, and session ID.
          $mess .= sprintf "  %s\n  %-16s %s\n\n", 
                     $data->[4], $data->[5], $data->[8];
        }
     
        eprint($out, $type, &indicate($type, $mess, $ok, 1)) if $mess;
      }
      elsif ($request->{'list'} eq 'ALL') {
        
        # keep both per-list counts and overall totals for each command.
        $stats{$data->[1]}{$data->[0]}{1}  ||= 0;
        $stats{$data->[1]}{$data->[0]}{-1} ||= 0;
        $stats{$data->[1]}{$data->[0]}{0}  ||= 0;
        $stats{$data->[1]}{$data->[0]}{'time'} ||= 0;
        $stats{$data->[1]}{$data->[0]}{$data->[6]}++;
        $stats{$data->[1]}{$data->[0]}{'TOTAL'}++;
        $stats{$data->[1]}{$data->[0]}{'time'} += $data->[10];

        $stats{$data->[1]}{'TOTAL'}{1}  ||= 0;
        $stats{$data->[1]}{'TOTAL'}{-1} ||= 0;
        $stats{$data->[1]}{'TOTAL'}{0}  ||= 0;
        $stats{$data->[1]}{'TOTAL'}{'time'} ||= 0;
        $stats{$data->[1]}{'TOTAL'}{$data->[6]}++;
        $stats{$data->[1]}{'TOTAL'}{'TOTAL'}++;
        $stats{$data->[1]}{'TOTAL'}{'time'} += $data->[10];
      }
      else {
        $stats{$data->[1]}{1}  ||= 0;
        $stats{$data->[1]}{-1} ||= 0;
        $stats{$data->[1]}{0}  ||= 0;
        $stats{$data->[1]}{'time'}  ||= 0;
        $stats{$data->[1]}{$data->[6]}++;
        $stats{$data->[1]}{'TOTAL'}++;
        $stats{$data->[1]}{'time'} += $data->[10];
      }
    }
  }

  $request->{'command'} = "report_done";
  ($ok, @tmp) = @{$mj->dispatch($request)};

  if ($request->{'mode'} =~ /summary/) {
    if (scalar keys %stats) {
      if ($request->{'list'} eq 'ALL') {
        $mess = "     Command:" . " "x17 . 
                "List Total Succeed Stall  Fail   Time\n";
      }
      else {
        $mess = "     Command: Total Succeed Stall  Fail   Time\n";
      }
    }
    else {
      $mess = "There was no activity.\n";
    }
    eprint($out, $type, &indicate($type, $mess, $ok, 1));

    for $end (sort keys %stats) {
      if ($request->{'list'} eq  'ALL') {
        for $begin (sort keys %{$stats{$end}}) {
          # next if key is TOTAL and request is GLOBAL only.
          $mess = sprintf "%12s: %20s %5d   %5d %5d %5d %6.3f\n", 
                                 $end, $begin,
                                 $stats{$end}{$begin}{'TOTAL'},
                                 $stats{$end}{$begin}{1},
                                 $stats{$end}{$begin}{'-1'}, 
                                 $stats{$end}{$begin}{'0'},
                                 $stats{$end}{$begin}{'time'} / 
                                 $stats{$end}{$begin}{'TOTAL'};
          eprint($out, $type, &indicate($type, $mess, $ok, 1)) if $mess;
        }
      }
      else {
        $mess = sprintf "%12s: %5d   %5d %5d %5d %6.3f\n", 
                           $end, $stats{$end}{'TOTAL'}, $stats{$end}{1}, 
                           $stats{$end}{'-1'}, $stats{$end}{'0'},
                           $stats{$end}{'time'} / 
                           $stats{$end}{'TOTAL'};
        eprint($out, $type, &indicate($type, $mess, $ok, 1)) if $mess;
      }
    }
  }

  1;
}

sub sessioninfo {
  my ($mj, $out, $err, $type, $request, $result) = @_;

  my ($ok, $sess) = @$result; 
  unless ($ok>0) {
    eprint($out, $type, &indicate($type, $sess, $ok)) if $sess;
    return ($ok>0);
  }
  eprint($out, $type, 
         "Stored information from session $request->{'sessionid'}:\n");

  g_get("sessioninfo", @_);
}


sub set {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'victim'}";
  my (@changes, $change, $count, $files, $flag, $init, $j, $list, 
      $lsubs, $ok, $settings, $str, $subs);
 
  @changes = @$result; 
  $count = $init = 0;

  $subs = { $mj->standard_subs($request->{'list'}),
            'CGIDATA'  => $request->{'cgidata'} || '',
            'CGIURL'   => $request->{'cgiurl'} || '',
            'CMDPASS'  => $request->{'password'},
            'USER'     => &escape("$request->{'user'}", $type),
          };

  $files = {
            'error' => $mj->format_get_string($type, 'set_error'),
            'head' => $mj->format_get_string($type, 'set_head'),
            'foot' => $mj->format_get_string($type, 'set_foot'),
           };

  if ($request->{'mode'} =~ /check/) {
    $files->{'main'} = $mj->format_get_string($type, 'set_check');
    $str = $mj->substitute_vars_format($files->{'head'}, $subs);
    print $out "$str\n";
  }
  else {
    $files->{'main'} = $mj->format_get_string($type, 'set');
  }

  while (@changes) {
    ($ok, $change) = splice @changes, 0, 2;
    $lsubs = { 
              %$subs, 
              'SETTINGS' => [],
             };

    if ($ok > 0) {
      $count++;
      $list = $change->{'list'};
      if (length $change->{'sublist'} and $change->{'sublist'} ne 'MAIN') {
        $list .= ":$change->{'sublist'}";
      }

      for $j (keys %$change) {
        next if ($j eq 'partial' or $j eq 'settings');
        $lsubs->{uc $j} = &escape($change->{$j}, $type);
      }

      $lsubs->{'CHANGETIME'} = scalar localtime($change->{'changetime'});
      $lsubs->{'CLASS_DESCRIPTIONS'} = [];
      $lsubs->{'CLASSES'}            = [];
      $lsubs->{'LIST'}               = $list;
      $lsubs->{'SELECTED'}           = [];
      $lsubs->{'SUBTIME'}    = scalar localtime($change->{'subtime'});

      if ($change->{'partial'}) {
        $lsubs->{'PARTIAL'} = " ";
      }
      else {
        $lsubs->{'PARTIAL'} = '';
      }
      $settings = $change->{'settings'};

      for ($j = 0; $j < @{$settings->{'flags'}}; $j++) {
        $flag = $settings->{'flags'}[$j]->{'name'};
        push (@{$lsubs->{'SETTINGS'}}, $flag) unless ($init);

        # Is this setting set?
        $str = $settings->{'flags'}[$j]->{'abbrev'};

        if ($change->{'flags'} =~ /$str/) {
          $str = 'checked';
        }
        else {
          $str = '';
        }

        if ($type eq 'wwwadm') {
          $lsubs->{uc "${flag}_CHECKBOX"} =
            qq(<input name="$lsubs->{'VICTIM'}" value="$flag" type="checkbox" $str>);
        }
        elsif ($settings->{'flags'}[$j]->{'allow'}) {
          # This setting is allowed
          $lsubs->{uc "${flag}_CHECKBOX"} =
            "<input name=\"$list;$flag\" type=\"checkbox\" $str>";
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
          $lsubs->{uc "${flag}_CHECKBOX"} =
            "<input name=\"$list;$flag\" type=\"hidden\" value=\"disabled\">$str";
        }
      }
      for ($j = 0; $j < @{$settings->{'classes'}}; $j++) {
        $flag = $settings->{'classes'}[$j]->{'name'};
        if ($flag eq $change->{'class'}->[0] or 
            $flag eq join ("-", @{$change->{'class'}})) 
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
      $str = $mj->substitute_vars_format($files->{'main'}, $lsubs);
      print $out "$str\n";
      $init = 1;
    }

    # deal with partial failure
    else {
      $lsubs->{'ERROR'} = $change;
      $str = $mj->substitute_vars_format($files->{'error'}, $lsubs);
      print $out "$str\n";
    }
  }

  if ($request->{'mode'} =~ /check/) {
    $subs->{'COUNT'} = $count;
    $str = $mj->substitute_vars_format($files->{'foot'}, $subs);
    print $out "$str\n";
  }

  $ok;
}

sub show {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'victim'}";
  my (@lists, $bouncedata, $error, $flag, $global_subs, $i, $j, $lsubs,
      $settings, $show, $str, $subs, $tmp);
  my ($ok, $data) = @$result;
  $error = [];

  $global_subs = {
    $mj->standard_subs('GLOBAL'),
    'CGIDATA' => $request->{'cgidata'} || '',
    'CGIURL'  => $request->{'cgiurl'} || '',
    'CMDPASS' => $request->{'password'},
    'USER'    => &escape("$request->{'user'}", $type),
    'VICTIM'  => &escape("$request->{'victim'}", $type),
  };
 
  # use Data::Dumper; print $out Dumper $data;

  # For validation failures, the dispatcher will do the verification and
  # return the error as the second argument.  For normal denials, $ok is
  # also 0, but a hashref is returned containing what information we could
  # get from the address.
  if ($ok == 0) {
    if (ref($data)) {
      push @$error, 'The show command failed.';
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
    print $out &indicate($type, "$str\n", $ok, 1);

    return $ok;
  }

  elsif ($ok < 0) {  
    push @$error, "Address is valid.";
    push @$error, "Mailbox: $data->{'strip'}";
    push @$error, "Comment: $data->{'comment'}"
      if (defined $data->{comment} && length $data->{comment});
    push @$error, &indicate($type, $data->{error}, $ok);

    $subs = { %$global_subs,
              'ERROR' => $error,
            };

    $tmp = $mj->format_get_string($type, 'show_error');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);

    return $ok;
  }

  $subs = { %$global_subs };

  for $i (keys %$data) {
    next if ($i eq 'lists' or $i eq 'regdata');
    $subs->{uc $i} = &escape($data->{$i}, $type);
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
    print $out "$str\n";
    return 1;
  }
  for $i (keys %{$data->{'regdata'}}) {
    $subs->{uc $i} = &escape($data->{'regdata'}{$i}, $type);
  }

  $subs->{'REGTIME'}    = scalar localtime($data->{'regdata'}{'regtime'});
  $subs->{'RCHANGETIME'} = scalar localtime($data->{'regdata'}{'changetime'});

  @lists = sort keys %{$data->{lists}};
  $subs->{'COUNT'} = scalar @lists;

  $subs->{'SETTINGS'} = [];
  if (@lists) {
    $settings = $data->{'lists'}{$lists[0]}{'settings'};
    if ($settings) {
      for ($j = 0; $j < @{$settings->{'flags'}}; $j++) {
        push @{$subs->{'SETTINGS'}}, $settings->{'flags'}[$j]->{'name'};
      }
    }
  }

  $tmp = $mj->format_get_string($type, 'show_head');
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out "$str\n";

  $show = $mj->format_get_string($type, 'show');

  for $i (@lists) {
    $lsubs = { %$subs };
    # Per-list substitutions available directly include:
    #   changetime class classarg classarg2 classdesc flags flagdesc
    #   fulladdr subtime
    for $j (keys %{$data->{'lists'}{$i}}) {
      next if ($j eq 'bouncedata' or $j eq 'settings');
      $lsubs->{uc $j} = &escape($data->{'lists'}{$i}{$j}, $type);
    }

    $lsubs->{'CHANGETIME'} = scalar localtime($data->{'lists'}{$i}{'changetime'});
    $lsubs->{'LIST'} = $i;
    $lsubs->{'NUMBERED_BOUNCES'} = '';
    $lsubs->{'SUBTIME'}    = scalar localtime($data->{'lists'}{$i}{'subtime'});
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
            "$data->{'lists'}{$i}{'class'}-$data->{'lists'}{$i}{'classarg'}-$data->{'lists'}{$i}{'classarg2'}") 
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

    $str = $mj->substitute_vars_format($show, $lsubs);
    print $out "$str\n";
  }

  $tmp = $mj->format_get_string($type, 'show_foot');
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out "$str\n";

  1;
}

use Date::Format;
sub showtokens {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$request->{'list'}";
  my (@tokens, $bf, $count, $data, $df, $global_subs, 
      $list, $ok,  $size, $str, $subs, $tmp, $tokens, $user);
  my (%type_abbrev) = (
                        'alias'   => 'L',
                        'async'   => 'A',
                        'confirm' => 'S',
                        'consult' => 'O',
                        'delay'   => 'D',
                        'probe'   => 'P',
                      );

  $global_subs = {
           $mj->standard_subs($request->{'list'}),
           'CGIDATA' => $request->{'cgidata'} || '',
           'CGIURL'  => $request->{'cgiurl'} || '',
           'CMDPASS' => $request->{'password'},
           'USER'    => &escape("$request->{'user'}", $type),
          };

  ($ok, @tokens) = @$result;
  unless (@tokens) {
    $tmp = $mj->format_get_string($type, 'showtokens_none');
    $str = $mj->substitute_vars_format($tmp, $global_subs);
    print $out &indicate($type, "$str\n", $ok, 1);
    return $ok;
  }

  unless ($ok > 0) {
    $subs = {
             %{$global_subs},
             'ERROR'  => $tokens[0],
            };
    $tmp = $mj->format_get_string($type, 'showtokens_error');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
    return $ok;
  }

  @tokens = sort {
                   if ($a->{'list'} ne $b->{'list'}) {
                     return ($a->{'list'} cmp $b->{'list'});
                   }
                   return $a->{'time'} <=> $b->{'time'};
                 } @tokens;

  $bf = $mj->format_get_string($type, 'showtokens');
  $df = $mj->format_get_string($type, 'showtokens_data');
  $list = '';
  $count = 0;

  for $data (@tokens) {
    $count++;
    $size = '';

    if ($data->{'size'}) {
      $size = sprintf ("%.1f",  ($data->{'size'} + 51) / 1024);
    }

    $user = &escape($data->{'user'}, $type);

    $subs = { 
              %{$global_subs},
              'ADATE'  => time2str('%m-%d %H:%M', $data->{'time'}), 
              'ATYPE'  => $type_abbrev{$data->{'type'}},
              'COMMAND'=> $data->{'command'},
              'CMDLINE'=> $data->{'cmdline'},
              'DATE'   => scalar localtime($data->{'time'}),
              'LIST'   => $data->{'list'},
              'REQUESTER' => $user,
              'SIZE'   => $size,
              'TOKEN'  => $data->{'token'},
              'TYPE'   => $data->{'type'},
            };

    if ($data->{'list'} ne $list) {
      $str = $mj->substitute_vars_format($bf, $subs);
      print $out "$str\n";
      $list = $data->{'list'};
    }
             
    $str = $mj->substitute_vars_format($df, $subs);
    print $out "$str\n";
  }
  $subs = {
           %{$global_subs},
           'COUNT' => $count,
          };
              
  $tmp = $mj->format_get_string($type, 'showtokens_all');
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out "$str\n";
  1;
}

sub subscribe {
  g_sub('sub', @_)
}

sub tokeninfo {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, $request->{'id'};
  my (@tmp, $expire, $str, $subs, $tmp);
  my ($ok, $data, $sess) = @$result;

  unless ($ok > 0) {
    $subs = { $mj->standard_subs($request->{'list'}),
              'CGIDATA' => $request->{'cgidata'} || '',
              'CGIURL'  => $request->{'cgiurl'} || '',
              'CMDPASS' => $request->{'password'},
              'ERROR'   => $data,
              'USER'    => &escape("$request->{'user'}", $type),
            };
    $tmp = $mj->format_get_string($type, 'tokeninfo_error');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
    return $ok;
  }

  if ($data->{'command'} eq 'post') {
    return _tokeninfo_post($mj, $out, $err, $type, $request, $result);
  }

  $subs = { $mj->standard_subs($data->{'list'}),
            'APPROVALS' => $data->{'approvals'},
            'CGIDATA' => $request->{'cgidata'} || '',
            'CGIURL'  => $request->{'cgiurl'} || '',
            'CMDLINE' => &escape($data->{'cmdline'}, $type),
            'CMDPASS' => $request->{'password'},
            'CONSULT' => ($data->{'type'} eq 'consult') ? " " : '',
            'DATE'    => scalar localtime($data->{'time'}),
            'EXPIRE'  => scalar localtime($data->{'expire'}),
            'ISPOST'  => '',
            'LIST'    => $data->{'list'},
            'REQUESTER' => &escape($data->{'user'}, $type),
            'TOKEN'   => $request->{'id'},
            'TYPE'    => $data->{'type'},
            'USER'    => &escape("$request->{'user'}", $type),
            'VICTIM'  => &escape($data->{'victim'}, $type),
            'WILLACK' => $data->{'willack'},
          };

  # Indicate reasons
  $subs->{'REASONS'} = [];
  if ($data->{'reasons'}) {
    @tmp = split /\003|\002/, &escape($data->{'reasons'}, $type);
    $subs->{'REASONS'} = [@tmp];
  }

  if ($request->{'mode'} =~ /nosession/) {
    $tmp = $mj->format_get_string($type, "tokeninfo_nosession_$data->{'command'}");
    unless ($tmp) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_nosession');
    }
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
    return 1;
  }
  elsif ($request->{'mode'} =~ /remind/) {
    $tmp = $mj->format_get_string($type, "tokeninfo_remind");
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }

  $tmp = $mj->format_get_string($type, "tokeninfo_head_$data->{'command'}");
  unless ($tmp) {
    $tmp = $mj->format_get_string($type, 'tokeninfo_head');
  }
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out "$str\n";

  if ($sess and $request->{'mode'} !~ /remind/) {
    eprint($out, $type, "\n");
    $request->{'sessionid'} = $data->{'sessionid'};
    Mj::Format::sessioninfo($mj, $out, $err, $type, $request, [1, '']);
  }

  # Restore the command name (from get_done to tokeninfo_done).
  $request->{'command'} = 'tokeninfo_done';
  $mj->dispatch($request);

  $tmp = $mj->format_get_string($type, "tokeninfo_foot_$data->{'command'}");
  unless ($tmp) {
    $tmp = $mj->format_get_string($type, 'tokeninfo_foot');
  }
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out "$str\n";

  1;
}

use MIME::Head;
sub _tokeninfo_post {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, $request->{'id'};
  my (@tmp, $chunksize, $expire, $fh, $head, $hsubs, $i, $j, $lastchar, 
      $part, $showhead, $str, $subs, $tmp);
  my ($ok, $data, $msgdata) = @$result;

  unless (ref $msgdata eq 'HASH') {
    $subs = { $mj->standard_subs($request->{'list'}),
              'CGIDATA' => $request->{'cgidata'} || '',
              'CGIURL'  => $request->{'cgiurl'} || '',
              'CMDPASS' => $request->{'password'},
              'ERROR'   => "No message data was found.\n",
              'USER'    => &escape("$request->{'user'}", $type),
            };
    $tmp = $mj->format_get_string($type, 'tokeninfo_error');
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", 0, 1);
    return 0;
  }
 
  $subs = { $mj->standard_subs($data->{'list'}),
            'APPROVALS' => $data->{'approvals'},
            'CGIDATA' => $request->{'cgidata'} || '',
            'CGIURL'  => $request->{'cgiurl'} || '',
            'CMDLINE' => &escape($data->{'cmdline'}, $type),
            'CMDPASS' => &escape($request->{'password'}, $type),
            'CONSULT' => ($data->{'type'} eq 'consult') ? " " : '',
            'DATE'    => scalar localtime($data->{'time'}),
            'EXPIRE'  => scalar localtime($data->{'expire'}),
            'ISPOST'  => " ",
            'LIST'    => $data->{'list'},
            'PART'    => $request->{'part'},
            'REQUESTER' => &escape($data->{'user'}, $type),
            'TOKEN'   => $request->{'id'},
            'TYPE'    => $data->{'type'},
            'USER'    => &escape("$request->{'user'}", $type),
            'VICTIM'  => &escape($data->{'victim'}, $type),
            'WILLACK' => $data->{'willack'},
          };

  # Indicate reasons
  $subs->{'REASONS'} = [];
  if ($data->{'reasons'}) {
    @tmp = split /\003|\002/, &escape($data->{'reasons'}, $type);
    $subs->{'REASONS'} = [@tmp];
  }

  if ($request->{'mode'} =~ /nosession/) {
    $tmp = $mj->format_get_string($type, "tokeninfo_nosession_post");
    unless ($tmp) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_nosession');
    }
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }
  elsif ($request->{'mode'} =~ /part/ and 
         $request->{'mode'} !~ /replace|delete/) {

    $part = $request->{'part'};
    if ($part =~ s/[hH]$//) {
      $subs->{'CONTENT_TYPE'} = "header";
      $subs->{'SIZE'} = 
        sprintf("%.1f", (length($msgdata->{$part}->{'header'}) + 51) / 1024);
      $showhead = 1;
    }
    else {
      $subs->{'CONTENT_TYPE'} = $msgdata->{$part}->{'type'};
      $subs->{'SIZE'} = $msgdata->{$part}->{'size'};
      $showhead = 0;
    }

    # Display head file
    if ($request->{'mode'} =~ /edit/) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_edit_head');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }

    # Display formatted part/header contents.
    if ($showhead) {
      print $out "$msgdata->{$part}->{'header'}\n";
      $lastchar = substr $msgdata->{$part}->{'header'}, -1;
    }
    else {
      $request->{'command'} = 'tokeninfo_chunk';
      $chunksize = $mj->global_config_get($request->{'user'}, 
                                          $request->{'password'}, 'chunksize')
                   || 1000;

      # In "edit" mode, determine if the text ends with a newline,
      # and add one if not.
      $lastchar = "\n";

      while (1) {
        ($ok, $tmp) = @{$mj->dispatch($request, $chunksize)};
        last unless defined $tmp;
        $lastchar = substr $tmp, -1;
        print $out $tmp;
        last unless $ok;
      }
    }
      
    # Display foot file
    if ($request->{'mode'} =~ /edit/) {
      $tmp = ($lastchar eq "\n")? '' : '\n';
      $tmp .= $mj->format_get_string($type, 'tokeninfo_edit_foot');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
  }
  else {
    # Print result message.
    if ($request->{'mode'} =~ /delete/) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_delete');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
    elsif ($request->{'mode'} =~ /remind/) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_remind');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
    elsif ($request->{'mode'} =~ /replace/) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_replace');
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }

    # Print head.
    $tmp = $mj->format_get_string($type, 'tokeninfo_head_post');
    unless ($tmp) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_head');
    }
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  
    $request->{'command'} = 'tokeninfo_chunk';
    # Display the contents of the posted message.
    $chunksize = $mj->global_config_get($request->{'user'}, 
                                        $request->{'password'}, 'chunksize')
                 || 1000;

    for $i (sort keys %$msgdata) {
      next if ($i eq '0');
      $subs->{'CONTENT_TYPE'} = $msgdata->{$i}->{'type'};
      $subs->{'PART'}         = $i;
      $subs->{'SIZE'}         = $msgdata->{$i}->{'size'};
      $subs->{'SUBPART'}      = $i eq '1' ? '' : " ";

      # Display formatted headers for the top-level part 
      # and for any nested messages.
      if ($i eq '1' or $msgdata->{$i}->{'header'} =~ /received:/i) {
        @tmp = split ("\n", $msgdata->{$i}->{'header'});
        $head = new MIME::Head \@tmp;
        if ($head) {
          $hsubs = { 
                    'HEADER_CC'      => '',
                    'HEADER_DATE'    => '',
                    'HEADER_FROM'    => '',
                    'HEADER_SUBJECT' => '',
                    'HEADER_TO'      => '',
                   };
          for $j (map { uc $_ } $head->tags) {
            @tmp = map { chomp $_; &escape($_, $type) } $head->get($j);
            $j =~ s/[^A-Z]/_/g;
            if (scalar @tmp > 1) {
              $hsubs->{"HEADER_$j"} = [ @tmp ];
            }
            else {
              $hsubs->{"HEADER_$j"} = $tmp[0];
            }
          }
          $tmp = $mj->format_get_string($type, 'tokeninfo_header');
          $str = $mj->substitute_vars_format($tmp, $subs);
          $str = $mj->substitute_vars_format($str, $hsubs);
          print $out "$str\n";
        }
      }

      # Display the contents of plain text parts.
      if ($msgdata->{$i}->{'type'} =~ m#^text/plain#i) {
        $request->{'part'} = $i;
        $tmp = $mj->format_get_string($type, 'tokeninfo_text_head');
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";

        while (1) {
          ($ok, $tmp) = @{$mj->dispatch($request, $chunksize)};
          last unless defined $tmp;
          eprint($out, $type, $tmp);
          last unless $ok;
        }

        $tmp = $mj->format_get_string($type, 'tokeninfo_text_foot');
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }
      
      # Display images.
      elsif ($msgdata->{$i}->{'type'} =~ /^image/i) {
        $tmp = $mj->format_get_string($type, 'tokeninfo_image');
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }

      # Display containers, such as multipart types.
      elsif (! length ($msgdata->{$i}->{'size'})) {
        $tmp = $mj->format_get_string($type, 'tokeninfo_container');
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }

      # Display summaries of other body parts.
      else {
        $tmp = $mj->format_get_string($type, 'tokeninfo_attachment');
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }
    }
       
    # Print foot. 
    $tmp = $mj->format_get_string($type, 'tokeninfo_foot_post');
    unless ($tmp) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_foot');
    }
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }

  # Clean up the message parser temporary files.
  $request->{'command'} = 'tokeninfo_done';
  $mj->dispatch($request);
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
    eprint($out, $type, &indicate($type, $mess, $ok));
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
    eprint($out, $type, &indicate($type, $matches[0], $ok)) if $matches[0];
    return $ok;
  }

  $whoami = $mj->global_config_get($request->{'user'}, $request->{'password'}, 
                                   'whoami') || 'this site';
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
  my (%stats, @lines, @out, @time, @tmp, $chunksize, $count, 
      $error, $fh, $flag, $foot, $fullclass, $gsubs, $head, $i, 
      $j, $line, $mess, $numbered, $ok, $regexp, $remove, $ret, 
      $settings, $source, $str, $subs, $tmp);

  $request->{'sublist'} ||= 'MAIN';
  $request->{'start'} ||= 1;
  $source = $request->{'list'};
  $remove = "unsubscribe";
  $stats{'TOTAL'} = 0;

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
            'CGIDATA' => $request->{'cgidata'} || '',
            'CGIURL'  => $request->{'cgiurl'} || '',
            'CMDPASS' => $request->{'password'},
            'PATTERN' => $request->{'regexp'},
            'REMOVE'  => $remove,
            'START'   => $request->{'start'},
            'USER'    => &escape("$request->{'user'}", $type),
           };

  ($ok, $regexp, $settings) = @$result;

  if ($ok <= 0) {
    $gsubs->{'ERROR'} = &indicate($type, $regexp, $ok);
    $tmp = $mj->format_get_string($type, 'who_error');
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out "$str\n";
    return $ok;
  }

  if ($request->{'mode'} =~ /owners/ and $request->{'list'} eq 'GLOBAL') {
    for $i (sort keys %$regexp) {
      $j = join ", ", @{$regexp->{$i}};
      print $out sprintf "%-40s : %s\n", $i, $j;
    }
    return 1;
  }
  # Special substitutions for WWW interfaces.
  $gsubs->{'CLASS_SELECTED'}     = [];
  $gsubs->{'CLASS_DESCRIPTIONS'} = [];
  $gsubs->{'CLASSES'}            = [];
  $gsubs->{'SETTINGS'}           = [];
  $gsubs->{'SETTING_CHECKED'}    = [];
  $gsubs->{'SETTING_SELECTED'}    = [];

  for ($j = 0; $j < @{$settings->{'flags'}}; $j++) {
    push @{$gsubs->{'SETTINGS'}}, $settings->{'flags'}[$j]->{'name'};
    if ($settings->{'flags'}[$j]->{'default'}) {
      $str = 'checked';
      $line = 'selected';
    }
    else {
      $str = $line = '';
    }
    push @{$gsubs->{'SETTING_CHECKED'}}, $str;
    push @{$gsubs->{'SETTING_SELECTED'}}, $line;
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
    $chunksize = $request->{'chunksize'} || 1000;
    $gsubs->{'CHUNKSIZE'} = $chunksize;
  }
  else {
    $chunksize = $mj->global_config_get($request->{'user'}, 
                                        $request->{'password'}, 
                                        "chunksize");
    $chunksize ||= 1000;  
    $gsubs->{'CHUNKSIZE'} = '';
  }


  unless ($request->{'mode'} =~ /export|short|alias|summary/) {
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
      $count++;
      next unless (ref ($i) eq 'HASH');

      #----- Hard-coded formatting for who, who-export, and who-alias -----#
      if ($request->{'mode'} =~ /alias/ &&
             $request->{'list'} eq 'GLOBAL') 
      {
        $line = "default user $i->{'target'}\n  alias-noinform $i->{'stripsource'}\n";
        eprint($out, $type, "$line\n");
        next;
      }
      elsif ($request->{'mode'} =~ /export/ &&
             $request->{'list'} eq 'GLOBAL' &&
             $request->{'sublist'} eq 'MAIN') {
        $line = "register-pass-nowelcome-noinform $i->{'password'} $i->{'fulladdr'}";
        eprint($out, $type, "$line\n");
        next;
      }
      elsif ($request->{'mode'} =~ /export/ && $i->{'classdesc'} 
             && $i->{'flagdesc'}) 
      {
	$line = "subscribe-nowelcome-noinform $source $i->{'fulladdr'}\n";
	if ($i->{'origclassdesc'}) {
	  $line .= "set-noinform $source $i->{'origclassdesc'} $i->{'stripaddr'}\n";
	}
	$line .= "set-noinform $source $i->{'classdesc'},$i->{'flagdesc'} $i->{'stripaddr'}\n";
        eprint($out, $type, "$line\n");
        next;
      }
      elsif ($request->{'mode'} !~ /bounce|enhanced|summary/) {
        eprint($out, $type, "  $i->{'fulladdr'}\n");
        next;
      }

      #----- Flexible formatting for who-bounce and who-enhanced -----#
      for $j (keys %$i) {
        if ($request->{'mode'} =~ /enhanced/) {
          $subs->{uc $j} = &escape($i->{$j}, $type);
        }
        else {
          $subs->{uc $j} = '';
        }
      }

      $subs->{'FULLADDR'} = &escape($i->{'fulladdr'}, $type);
      $subs->{'LASTCHANGE'} = '';

      # Summary mode:  collect statistics instead of displaying 
      # information about individual subscribers.
      if ($request->{'mode'} =~ /summary/) {
        if ($request->{'list'} ne 'GLOBAL' or $request->{'sublist'} ne 'MAIN') {
          $stats{$i->{'class'}}++;
        }
        else {
          @tmp = split ("\002", $i->{'lists'});
          if (scalar @tmp) {
            for $tmp (@tmp) {
              $stats{$tmp}++;
            }
          }
          else {
            $stats{'NONE'}++;
          }
        }
        $stats{'TOTAL'}++;
        next;
      }
      elsif ($request->{'mode'} =~ /enhanced/) {
        if ($request->{'list'} ne 'GLOBAL' or $request->{'sublist'} ne 'MAIN') {
          $fullclass = $i->{'class'};
          $fullclass .= "-" . $i->{'classarg'} if ($i->{'classarg'});
          $fullclass .= "-" . $i->{'classarg2'} if ($i->{'classarg2'});
          $subs->{'CLASS'} = $fullclass;
        }
        $subs->{'LISTS'} =~ s/\002/ /g  if (exists $subs->{'LISTS'});
        if ($i->{'changetime'}) {
          @time = localtime($i->{'changetime'});
          $subs->{'LASTCHANGE'} = 
            sprintf "%4d-%.2d-%.2d", $time[5]+1900, $time[4]+1, $time[3];
        }
        else {
          $subs->{'LASTCHANGE'} = '';
        }

        # Special substitutions for WWW interfaces.
        if ($type ne 'text') {
          $subs->{'ADDRESS'}            = [];
          $subs->{'CLASS_SELECTED'}     = [];
          $subs->{'SETTING_CHECKED'}    = [];
          $subs->{'SETTING_SELECTED'}   = [];

          for ($j = 0; $j < @{$settings->{'flags'}}; $j++) {
            $str = $settings->{'flags'}[$j]->{'abbrev'};
            if ($i->{'flags'} =~ /$str/) {
              push @{$subs->{'SETTING_CHECKED'}}, 'checked';
              push @{$subs->{'SETTING_SELECTED'}}, 'selected';
            }
            else {
              push @{$subs->{'SETTING_CHECKED'}}, '';
              push @{$subs->{'SETTING_SELECTED'}}, '';
            }
            push @{$subs->{'ADDRESS'}}, $subs->{'STRIPADDR'}; 
          }

          for ($j = 0; $j < @{$settings->{'classes'}}; $j++) {
            last if ($request->{'list'} eq 'GLOBAL' and 
                     $request->{'sublist'} eq 'MAIN');
            $flag = $settings->{'classes'}[$j]->{'name'};
            
            if ($flag eq $i->{'class'} or 
                $flag eq "$i->{'class'}-$i->{'classarg'}-$i->{'classarg2'}") 
            {
              push @{$subs->{'CLASS_SELECTED'}}, 'selected';
            }
            else {
              push @{$subs->{'CLASS_SELECTED'}}, '';
            }
          }    
        }    
      } # enhanced mode

      $subs->{'BOUNCE_DIAGNOSTIC'} = ''; 
      $subs->{'BOUNCE_MONTH'} = ''; 
      $subs->{'BOUNCE_NUMBERS'} = ''; 
      $subs->{'BOUNCE_WEEK'} = ''; 

      if ($request->{'mode'} =~ /bounce/ && exists $i->{'bouncestats'}) {
        $subs->{'BOUNCE_DIAGNOSTIC'} = &escape($i->{'diagnostic'}, $type);
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
  
  if ($request->{'mode'} =~ /summary/) {
    print $out "<pre>\n" if ($type =~ /^www/);

    if ($request->{'list'} ne 'GLOBAL' or $request->{'sublist'} ne 'MAIN') {
      print $out sprintf("%-12s %s\n", 'Class', 'Subscribers');
      print $out sprintf("%-12s %5d\n", 'TOTAL', $stats{'TOTAL'});
      for $tmp (sort keys %stats) {
        next if ($tmp eq 'TOTAL');
        print $out sprintf("%-12s %5d\n", $tmp,  $stats{$tmp});
      }
    }
    else {
      print $out sprintf("%-20s %s\n", 'List', 'Subscribers');
      print $out sprintf("%-20s %5d\n", 'TOTAL', $stats{'TOTAL'});
      for $tmp (sort keys %stats) {
        next if ($tmp eq 'TOTAL');
        print $out sprintf("%-20s %5d\n", $tmp,  $stats{$tmp});
      }
    }
    print $out "</pre>\n" if ($type =~ /^www/);
  }   
  elsif ($request->{'mode'} !~ /export|short|alias/) {
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
  my ($base, $mj, $out, $err, $type, $request, $result) = @_;
  my ($chunk, $chunksize, $desc, $lastchar, $subs, $tmp);
  my ($ok, $mess) = @$result;

  unless ($ok > 0) {
    $subs = {
             $mj->standard_subs($request->{'list'}),
             'COMMAND' => $base,
             'ERROR' => $mess || '',
            };

    $tmp = $mj->format_get_string($type, 'get_error');
    $chunk = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$chunk\n", $ok);

    return $ok;
  }

  if ($base ne 'sessioninfo') {
    $subs = {
             $mj->standard_subs($request->{'list'}),
             'CGIDATA'  => $request->{'cgidata'} || '',
             'CGIURL'   => $request->{'cgiurl'} || '',
             'CMDPASS'  => $request->{'password'},
             'DESCRIPTION' => $mess->{'description'},
             'USER'     => &escape("$request->{'user'}", $type),
            };

    # include CMDLINE substitutions for the various files.
    if ($request->{'mode'} =~ /edit/) {
      if ($base eq 'get') {
        $desc = $mess->{'description'};
        $desc =~ s/\$/\\\$/g;
        $subs->{'REPLACECMD'} = 'put-data';
        $subs->{'CMDLINE'} = "put-data $request->{'list'}";
        $subs->{'CMDARGS'} = sprintf "%s %s %s %s %s %s",
                 $request->{'path'}, $mess->{'c-type'},
                 $mess->{'charset'}, $mess->{'c-t-encoding'},
                 $mess->{'language'}, $desc;
      }
      else {
        $subs->{'REPLACECMD'} = "new$base";
        $subs->{'CMDLINE'} = "new$base $request->{'list'}";
        $subs->{'CMDARGS'} = '';
      }
      $tmp = $mj->format_get_string($type, 'get_edit_head');
    }
    else {
      $tmp = $mj->format_get_string($type, 'get_head');
    }
    $chunk = $mj->substitute_vars_format($tmp, $subs);
    print $out "$chunk\n";
  }

  $chunksize = $mj->global_config_get($request->{'user'}, 
                                      $request->{'password'}, "chunksize")
                                     || 1000;

  $request->{'command'} = "get_chunk";

  # In "edit" mode, determine if the text ends with a newline,
  # and add one if not.
  $lastchar = "\n";

  while (1) {
    ($ok, $chunk) = @{$mj->dispatch($request, $chunksize)};
    last unless defined $chunk;
    $lastchar = substr $chunk, -1;
    eprint($out, $type, $chunk);
    last unless $ok;
  }

  # Print the end of the here document in "edit" mode.
  if ($base ne 'sessioninfo') {
    $chunk = ($lastchar eq "\n")?  '' : "\n";
    if ($request->{'mode'} =~ /edit/) {
      $tmp = $mj->format_get_string($type, 'get_edit_foot');
    }
    else {
      $tmp = $mj->format_get_string($type, 'get_foot');
    }
    $chunk .= $mj->substitute_vars_format($tmp, $subs);
    print $out "$chunk\n";
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
  my ($addr, $i, $list, $ok, @res);

  $list = $request->{'list'};
  if ((exists $request->{'sublist'}) and 
      length ($request->{'sublist'}) and
      $request->{'sublist'} ne 'MAIN') 
  {
    $list .= ":$request->{'sublist'}";
  }

  if ($act eq 'sub') {
    $act = "added to $list";
  }
  elsif ($act eq 'reg') {
    $act = 'registered'; 
  }
  elsif ($act eq 'unreg') {
    $act = 'unregistered and removed from all lists'; 
  }
  else {
    $act = "removed from $list";
  }

  @res = @$result;
  unless (scalar (@res)) {
    eprint($out, $type, "No addresses were found.\n");
    return 1;
  }
  # Now print the multi-address format.
  while (@res) {
    ($ok, $addr) = splice @res, 0, 2;
    unless ($ok > 0) {
      eprint($out, $type, &indicate($type, "$addr\n", $ok));
      next;
    }
    for (@$addr) {
      my ($verb) = ($ok > 0)?  $act : "not $act";
      eprint($out, $type, "$_ was $verb.\n");
    }
  }
  $ok;
}

=head2 cgidata(mj, request)

The cgidata method obtains the user address and password provided
in the request hash and formats them in a way that is suitable for
the query portion of a URL as displayed in an HTML document.

=cut
sub cgidata {
  my $mj = shift;
  my $request = shift;
  my (%esc, $addr, $i, $pass);

  return unless (ref $mj and ref $request);

  for $i (0..255) {
    $esc{chr($i)} = sprintf("%%%02X", $i);
  }

  $addr = $request->{'user'};
  $addr = qescape($addr);
 
  $pass = $request->{'password'}; 
  $pass = qescape($pass);
  
  return sprintf ('user=%s&amp;passw=%s', $addr, $pass);
}

sub eprint {
  my $fh   = shift;
  my $type = shift;
  if ($type eq 'html' or $type =~ /^www/) {
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

# Basic idea from HTML::Stream. 
sub escape {
  local $_ = shift;
  my $type = shift || '';
  return unless (defined $_);
  return $_ if ($type eq 'text');
  my %esc = ( '&'=>'amp', '"'=>'quot', '<'=>'lt', '>'=>'gt');
  s/([<>\"&])/\&$esc{$1};/mg; 
  s/([\x80-\xFF])/'&#'.unpack('C',$1).';'/eg;
  $_;
}

=head2 qescape(string, type)

The qescape function converts all special characters in the string
into a format suitable for the query portion of a URL.

Only letters, digits, the period, hyphen, and underscore are not
converted.

=cut
sub qescape {
  local $_ = shift;
  my $type = shift || '';
  my (%esc, $i);

  return $_ if ($type eq 'text');

  for $i (0..255) {
    $esc{chr($i)} = sprintf("%%%02X", $i);
  }

  s/([^A-Za-z0-9\-_.])/$esc{$1}/g;
  $_;
}

# Basic idea from URI::Escape.
sub uescape {
  local $_ = shift;
  my $type = shift || '';
  my (%esc, $i);

  return $_ if ($type eq 'text');

  for $i (0..255) {
    $esc{chr($i)} = sprintf("%%%02X", $i);
  }

  s/([^;\/?:@&=+\$,A-Za-z0-9\-_.!~*'()])/$esc{$1}/g;
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
  my ($type, $mess, $ok, $indent) = @_;
  if ($ok > 0 or $type =~ /^www/) {
    return $mess;
  }
  if ($ok < 0) {
    return prepend('---- ', $mess);
  }
  return prepend('**** ',$mess);
}

=head1 COPYRIGHT

Copyright (c) 1997-2002 Jason Tibbitts for The Majordomo Development
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


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
            'CMDPASS'  => &escape($request->{'password'}, $type),
            'USER'     => &escape("$request->{'user'}", $type),
           };

  @tokens = @$result;
  while (@tokens) {
    $ok = shift @tokens;
    if ($ok == 0) {
      $mess = shift @tokens;
      next if ($mess eq 'NONE');
      $gsubs->{'ERROR'} = $mess;

      $tmp = $mj->format_get_string($type, 'accept_error', $request->{'list'});
      $str = $mj->substitute_vars_format($tmp, $gsubs);
      print $out &indicate($type, "$str\n", $ok); 

      next;
    }

    ($mess, $data, $rresult) = @{shift @tokens};

    $subs = { $mj->standard_subs($data->{'list'}),
              'CGIDATA'  => $request->{'cgidata'},
              'CGIURL'   => $request->{'cgiurl'},
              'CMDPASS'  => &escape($request->{'password'}, $type),
              'ERROR'    => '',
              'FAIL'     => '',
              'NOTIFIED' => '',
              'STALL'    => '',
              'SUCCEED'  => '',
              'TOKEN'    => $data->{'token'},
              'USER'     => &escape("$request->{'user'}", $type),
            };

    for $tmp (keys %$data) {
      next if (ref $data->{$tmp} eq 'HASH');
      if ($tmp eq 'user') {
        $subs->{'REQUESTER'} = &escape("$data->{'user'}", $type);
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

      $tmp = $mj->format_get_string($type, 'accept_stall', $data->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out &indicate($type, "$str\n", $ok); 
      next;
    }

    # If we accepted a consult token, we can stop now.
    if ($data->{'type'} eq 'consult') {
      if ($data->{'ack'}) {
        $subs->{'NOTIFIED'} = " ";
        if (ref($rresult) eq 'ARRAY') {
          if ($rresult->[0] > 0) {
            $subs->{'SUCCEED'} = " ";
          }
          elsif ($rresult->[0] < 0) {
            $subs->{'STALL'} = " ";
          }
          else {
            $subs->{'FAIL'} = " ";
            $subs->{'ERROR'} = &escape($rresult->[1], $type);
          }
        }
      }

      $tmp = $mj->format_get_string($type, 'accept', $data->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out &indicate($type, "$str\n", $ok); 
    }
    else {
      $tmp = $mj->format_get_string($type, 'accept_head', $data->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out &indicate($type, "$str\n", $ok); 

      # Then call the appropriate formatting routine to format the real command
      # return.
      $fun = "Mj::Format::$data->{'command'}";
      {
        no strict 'refs';
        $ok = &$fun($mj, $out, $err, $type, $data, $rresult);
      }

      $tmp = $mj->format_get_string($type, 'accept_foot', $data->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out &indicate($type, "$str\n", $ok); 
    }
  }
  $ok;
}

sub alias {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($mess, $ok, $str, $subs, $tmp);
  ($ok, $mess) = @$result;
  return $ok if ($mess eq 'NONE');

  $subs = { $mj->standard_subs('GLOBAL'),
           'CGIDATA'  => $request->{'cgidata'},
           'CGIURL'   => $request->{'cgiurl'},
           'CMDPASS'  => &escape($request->{'password'}, $type),
           'USER'     => &escape("$request->{'user'}", $type),
           'VICTIM'   => &escape("$request->{'newaddress'}", $type),
          };

  if ($ok > 0) { 
    $tmp = $mj->format_get_string($type, 'alias', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
  }
  else {
    $subs->{'ERROR'} = &escape($mess, $type);
    $tmp = $mj->format_get_string($type, 'alias_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
  }

  $ok;
}

sub announce {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($mess, $ok, $str, $subs, $tmp);

  ($ok, $mess) = @$result;
  return $ok if ($mess eq 'NONE');

  $subs = { $mj->standard_subs($request->{'list'}),
           'CGIDATA'  => $request->{'cgidata'},
           'CGIURL'   => $request->{'cgiurl'},
           'CMDPASS'  => &escape($request->{'password'}, $type),
           'FILE'     => &escape($request->{'file'}, $type),
           'USER'     => &escape("$request->{'user'}", $type),
          };

  if ($ok > 0) { 
    $tmp = $mj->format_get_string($type, 'announce', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
  }
  else {
    $subs->{'ERROR'} = &escape($mess, $type);
    $tmp = $mj->format_get_string($type, 'announce_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
  }

  $ok;
}

use Date::Format;
sub archive {
  my ($mj, $out, $err, $type, $request, $result) = @_;
 
  my (%stats, @tmp, $chunksize, $data, $first, $i, $j, $last, 
      $line, $lines, $list, $mess, $mode, $msg, $str, $size, $subs, $tmp);
  my ($ok, @msgs) = @$result;

  $list = $request->{'list'};
  $mode = $request->{'mode'};

  $subs = {
           $mj->standard_subs($list),
           'CGIDATA'     => $request->{'cgidata'} || '',
           'CGIURL'      => $request->{'cgiurl'} || '',
           'CMDPASS'     => &escape($request->{'password'}, $type),
           'TOTAL_POSTS' => scalar @msgs,
           'USER'        => &escape("$request->{'user'}", $type),
           'VICTIM'      => &escape("$request->{'victim'}", $type),
          };

  if ($ok <= 0) { 
    return $ok if ($msgs[0] eq 'NONE');
    $subs->{'ERROR'} = $msgs[0];
    $tmp = $mj->format_get_string($type, 'archive_error', $list);
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
    return $ok;
  }
  unless (@msgs) {
    $tmp = $mj->format_get_string($type, 'archive_none', $list);
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
    # reset the arcadmin flag.
    $request->{'command'} = "archive_done";
    $mj->dispatch($request);
    return 1;
  }

  $request->{'command'} = "archive_chunk";

  if ($mode =~ /sync/) {
    for (@msgs) {
      ($ok, $mess) = @{$mj->dispatch($request, [$_])};
      eprint($out, $type, indicate($type, $mess, $ok));
    }
  }
  elsif ($mode =~ /summary/) {
    $tmp = $mj->format_get_string($type, 'archive_summary_head', $list);
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";

    $tmp = $mj->format_get_string($type, 'archive_summary', $list);
    @tmp = ();

    for $i (@msgs) {
      ($mess, $data) = @$i;

      # Save the archive years in an array.
      if ($mess =~ /^([^.]+\.)?(\d{4})/) {
        push (@tmp, $2) unless (grep {$_ eq $2} @tmp);
      }
      for $j (keys %$data) {
        next if (ref $data->{$j} eq 'HASH');
        $subs->{uc $j} = &escape($data->{$j}, $type);
      }
      $subs->{'FILE'} = $mess;
      $subs->{'SIZE'} = sprintf "%.1f", ($data->{'bytes'} / 1024);
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }

    $subs->{'YEARS'} = [ @tmp ];
    $tmp = $mj->format_get_string($type, 'archive_summary_foot', $list);
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }
  elsif ($mode =~ /get|delete|edit|replace/) {
    if ($mode !~ /part|edit/) {
      $tmp = $mj->format_get_string($type, 'archive_get_head', $list);
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
      if (($mode =~ /digest/ and $lines > $chunksize) or $i == $#msgs) {
        if ($mode =~ /part|edit/) {
          _archive_part($mj, $out, $err, $type, $request, [@tmp]);
        }
        else {
          ($ok, $mess) = @{$mj->dispatch($request, [@tmp])};
          if (!$ok or $mode =~ /immediate|delete/) {
            eprint($out, $type, indicate($type, $mess, $ok))
              if (defined $mess and length $mess);
          }
          elsif ($mode =~ /digest/) {
            $subs->{'MESSAGECOUNT'} = $mess;
            $tmp = $mj->format_get_string($type, 'archive_get_digest', $list);
            $str = $mj->substitute_vars_format($tmp, $subs);
            print $out "$str\n";
          }
          else {
            # get mode
            $subs->{'MESSAGECOUNT'} = $mess;
            $tmp = $mj->format_get_string($type, 'archive_get', $list);
            $str = $mj->substitute_vars_format($tmp, $subs);
            print $out "$str\n";
          }
        }

        $lines = 0; @tmp = ();
      }
    }

    if ($mode !~ /part|edit/) {
      $tmp = $mj->format_get_string($type, 'archive_get_foot', $list);
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
  }
  elsif ($mode =~ /stats/) {
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
    $tmp = $mj->format_get_string($type, 'archive_stats', $list);
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }
  else {
    # The archive-index command.
    $tmp = $mj->format_get_string($type, 'archive_head', $list);
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";

    $tmp = $mj->format_get_string($type, 'archive_index', $list);
    for $i (@msgs) {
      $data = $i->[1];
      $data->{'subject'} ||= "(No Subject)";
      $data->{'from'} ||= "(Unknown Author)";
      # Include all archive data in the substitutions.
      for $j (keys %$data) {
        next if (ref $data->{$j} eq 'HASH');
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

    $tmp = $mj->format_get_string($type, 'archive_foot', $list);
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
              'CMDPASS' => &escape($request->{'password'}, $type),
              'ERROR'   => "The structure of the message $msgno is invalid.\n",
              'MSGNO'   => $msgno,
              'USER'    => &escape("$request->{'user'}", $type),
            };
    $tmp = $mj->format_get_string($type, 'archive_error', $request->{'list'});
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
      $subs->{'CHARSET'} = "US-ASCII";
      $subs->{'SIZE'} = 
        sprintf("%.1f", (length($msgdata->{$part}->{'header'}) + 51) / 1024);
      $showhead = 1;
    }
    else {
      $subs->{'CONTENT_TYPE'} = $msgdata->{$part}->{'type'};
      $subs->{'CHARSET'} = $msgdata->{$part}->{'charset'};
      $subs->{'SIZE'} = $msgdata->{$part}->{'size'};
      $showhead = 0;
    }

    if ($request->{'mode'} =~ /edit/) {
      $tmp = $mj->format_get_string($type, 'archive_edit_head', $request->{'list'});
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
      $tmp = $mj->format_get_string($type, 'archive_edit_foot', $request->{'list'});
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
        $tmp = $mj->format_get_string($type, 'archive_part_delete', $request->{'list'});
      }
      else {
        $subs->{'ERROR'} = $tmp;
        $tmp = $mj->format_get_string($type, 'archive_error', $request->{'list'});
      }
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
    elsif ($request->{'mode'} =~ /replace/) {
      ($ok, $tmp) = @{$mj->dispatch($request, $result)};
      if ($ok) {
        $tmp = $mj->format_get_string($type, 'archive_part_replace', $request->{'list'});
      }
      else {
        $subs->{'ERROR'} = $tmp;
        $tmp = $mj->format_get_string($type, 'archive_error', $request->{'list'});
      }
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
 
    for $j (keys %$data) {
      next if (ref $data->{$j} eq 'HASH');
      $subs->{uc $j} = &escape($data->{$j}, $type);
    }

    $tmp = $mj->format_get_string($type, 'archive_msg_head', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";


    for $i (sort keys %$msgdata) {
      next if ($i eq '0');
      $subs->{'CONTENT_TYPE'} = $msgdata->{$i}->{'type'};
      $subs->{'CHARSET'}      = $msgdata->{$i}->{'charset'};
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
          $tmp = $mj->format_get_string($type, 'archive_header', $request->{'list'});
          $str = $mj->substitute_vars_format($tmp, $subs);
          $str = $mj->substitute_vars_format($str, $hsubs);
          print $out "$str\n";
        }
      }

      # Display the contents of plain text parts.
      if ($msgdata->{$i}->{'type'} =~ m#^text/plain#i) {
        $request->{'part'} = $i;
        $request->{'mode'} = 'get-part';
        $tmp = $mj->format_get_string($type, 'archive_text_head', $request->{'list'});
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";

        ($ok, $tmp) = @{$mj->dispatch($request, $result)};
        # Break long lines
        if ($type =~ /^www/) {
          $tmp = &escape($tmp);
          $tmp =~ s/\n/\&nbsp\;\<BR\>\n/g;
          $tmp =~ s/  /\&nbsp\; /g;
          $tmp =~ s/ \&nbsp\;/\&nbsp\;\&nbsp\;/g;
          $tmp =~ s/  /\&nbsp\; /g;
        }
        eprint($out, '', $tmp);

        $tmp = $mj->format_get_string($type, 'archive_text_foot', $request->{'list'});
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }
      
      # Display images.
      elsif ($msgdata->{$i}->{'type'} =~ /^image/i) {
        $tmp = $mj->format_get_string($type, 'archive_image', $request->{'list'});
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }

      # Display containers, such as multipart types.
      elsif (! length ($msgdata->{$i}->{'size'})) {
        $tmp = $mj->format_get_string($type, 'archive_container', $request->{'list'});
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }

      # Display summaries of other body parts.
      else {
        $tmp = $mj->format_get_string($type, 'archive_attachment', $request->{'list'});
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }
    }

    $tmp = $mj->format_get_string($type, 'archive_msg_foot', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";

  }
}

sub changeaddr {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($mess, $ok, $str, $subs, $tmp);
  ($ok, $mess) = @$result;

  $subs = { $mj->standard_subs('GLOBAL'),
           'CGIDATA'  => $request->{'cgidata'},
           'CGIURL'   => $request->{'cgiurl'},
           'CMDPASS'  => &escape($request->{'password'}, $type),
           'QSADDR'   => &qescape($request->{'user'}->strip, $type),
           'STRIPADDR' => &escape($request->{'user'}->strip, $type),
           'USER'     => &escape("$request->{'user'}", $type),
           'VICTIM'   => &escape("$request->{'victim'}", $type),
          };

  if ($ok > 0) { 
    $tmp = $mj->format_get_string($type, 'changeaddr', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
  }
  else {
    return $ok if ($mess eq 'NONE');
    $subs->{'ERROR'} = &escape($mess, $type);
    $tmp = $mj->format_get_string($type, 'changeaddr_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
  }

  $ok;
}

sub configdef {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'list'}";
  my (@results, $mess, $ok, $str, $subs, $tmp, $var);

  @results = @$result;

  $subs = { $mj->standard_subs($request->{'list'}),
           'CGIDATA'  => $request->{'cgidata'},
           'CGIURL'   => $request->{'cgiurl'},
           'CMDPASS'  => &escape($request->{'password'}, $type),
           'USER'     => &escape("$request->{'user'}", $type),
          };

  while (@results) {
    $ok = shift @results;
    ($mess, $var) = @{shift @results};
    $subs->{'SETTING'} = $var;

    if ($ok > 0) {
      $tmp = $mj->format_get_string($type, 'configdef', $request->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
    else {
      $subs->{'ERROR'} = &escape($mess, $type);
      $tmp = $mj->format_get_string($type, 'configdef_error', $request->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out &indicate($type, "$str\n", $ok);
    }
  }
  $ok;
}

sub configset {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'list'}";
  my ($ok, $mess, $str, $subs, $tmp, $val);

  ($ok, $mess) = @$result;
  $mess ||= '';

  $val = ${$request->{'value'}}[0];
  $val = '' unless defined $val;
  if (defined $request->{'value'}[1]) {
    $val .= '...';
  }

  $subs = { $mj->standard_subs($request->{'list'}),
           'CGIDATA'  => $request->{'cgidata'},
           'CGIURL'   => $request->{'cgiurl'},
           'CMDPASS'  => &escape($request->{'password'}, $type),
           'ERROR'    => &escape($mess, $type),
           'SETTING'  => &escape($request->{'setting'}, $type),
           'USER'     => &escape("$request->{'user'}", $type),
           'VALUE'    => &escape(&sescape($val), $type),
          };

  if ($ok > 0) {
    if ($request->{'mode'} =~ /append/) {
      $tmp = $mj->format_get_string($type, 'configset_append', $request->{'list'});
    }
    elsif ($request->{'mode'} =~ /extract/) {
      $tmp = $mj->format_get_string($type, 'configset_extract', $request->{'list'});
    }
    else {
      $tmp = $mj->format_get_string($type, 'configset', $request->{'list'});
    }
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }
  else {
    $tmp = $mj->format_get_string($type, 'configset_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok);
  }

  $ok;
}

use Mj::Util qw(text_to_html);
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
            'CMDPASS'  => &escape($request->{'password'}, $type),
            'USER'     => &escape("$request->{'user'}", $type),
          };

  $ok = shift @$result;
  unless ($ok) {
    $mess = shift @$result;
    $gsubs->{'ERROR'} = $mess;
    $tmp = $mj->format_get_string($type, 'configshow_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out &indicate($type, "$str\n", $ok);
    return $ok;
  }

  unless (scalar @$result) {
    $tmp = $mj->format_get_string($type, 'configshow_none', $request->{'list'});
    $mess = $mj->substitute_vars_format($tmp, $gsubs);
    print $out &indicate($type, "$mess\n", $ok);
    return $ok;
  }

  $gsubs->{'COMMENTS'} = ($request->{'mode'} !~ /nocomments/) ? '#' : '';
  $subs = { %$gsubs };
  $subs->{'COMMENT'} = '';

  if ($request->{'mode'} !~ /categories/) {
    $tmp = $mj->format_get_string($type, 'configshow_head', $request->{'list'});
    $gen   = $mj->format_get_string($type, 'configshow', $request->{'list'});
  }
  else {
    $tmp = $mj->format_get_string($type, 'configshow_categories_head', $request->{'list'});
    $gen = $mj->format_get_string($type, 'configshow_categories', $request->{'list'});
  }
  $str = $mj->substitute_vars_format($tmp, $gsubs);
  print $out "$str\n";

  $array = $mj->format_get_string($type, 'configshow_array', $request->{'list'});
  $bool  = $mj->format_get_string($type, 'configshow_bool', $request->{'list'});
  $enum  = $mj->format_get_string($type, 'configshow_enum', $request->{'list'});
  $earray= $mj->format_get_string($type, 'configshow_enum_array', $request->{'list'});
  $short = $mj->format_get_string($type, 'configshow_short', $request->{'list'});

  for $varresult (@$result) {
    ($ok, $mess, $data, $var, $val) = @$varresult;
    $subs->{'SETTING'} = $var;

    if (! $ok) {
      $subs->{'ERROR'} = $mess;
      $tmp = $mj->format_get_string($type, 'configshow_error', $request->{'list'});
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
      $mess = text_to_html($mess) if ($type ne 'text');
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
        $subs->{'SETCOMMAND'} .= &sescape("$i\n");
      }

      $subs->{'SETCOMMAND'} .= "$auto$tag\n";
      $subs->{'VALUE'} = &sescape(join("\n", @$val)); 

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
      $val = &sescape($val);
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
    $tmp = $mj->format_get_string($type, 'configshow_categories_foot', $request->{'list'});
  }
  else {
    $tmp = $mj->format_get_string($type, 'configshow_foot', $request->{'list'});
  }
  $str = $mj->substitute_vars_format($tmp, $gsubs);
  print $out "$str\n";

  1;
}

sub createlist {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29;
  my (@tmp, $i, $j, $str, $subs, $tmp);
  my ($ok, $mess) = @$result;

  $subs = {
           $mj->standard_subs('GLOBAL'),
           'CGIDATA' => $request->{'cgidata'} || '',
           'CGIURL'  => $request->{'cgiurl'} || '',
           'CMDPASS' => &escape($request->{'password'}, $type),
           'USER'    => &escape("$request->{'user'}", $type),
          };

  unless ($ok > 0) {
    return $ok if ($mess eq 'NONE');
    $subs->{'ERROR'} = $mess;
    $tmp = $mj->format_get_string($type, 'createlist_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
    return $ok;
  }

  for $j (keys %$mess) {
    next if (ref $mess->{$j} eq 'HASH');
    if (ref $mess->{$j} eq 'ARRAY') {
      @tmp = @{$mess->{$j}};
      for ($i = 0; $i < @tmp; $i++) {
        $tmp[$i] = &escape("$tmp[$i]", $type);
      }
      $subs->{uc $j} = [ @tmp ];
    }
    else {
      $subs->{uc $j} = &escape($mess->{$j}, $type);
    }
  }

  if ($request->{'mode'} =~ /destroy/) {
    $tmp = $mj->format_get_string($type, 'createlist_destroy', $request->{'list'});
  }
  elsif ($request->{'mode'} =~ /nocreate/) {
    $tmp = $mj->format_get_string($type, 'createlist_nocreate', $request->{'list'});
  }
  elsif ($request->{'mode'} =~ /regen/) {
    $tmp = $mj->format_get_string($type, 'createlist_regen', $request->{'list'});
  }
  elsif ($request->{'mode'} =~ /rename/) {
    $tmp = $mj->format_get_string($type, 'createlist_rename', $request->{'list'});
  }
  else {
    $tmp = $mj->format_get_string($type, 'createlist', $request->{'list'});
  }

  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out &indicate($type, "$str\n", $ok, 1);

  $ok;
}

use Mj::Util qw(str_to_offset time_to_str);
sub digest {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29;
  my ($date, $digest, $gsubs, $i, $j, $mess, $msgdata, $ok, 
      $str, $subs, $tmp);
  
  ($ok, $mess) = @$result;

  $gsubs = {
           $mj->standard_subs($request->{'list'}),
           'CGIDATA' => $request->{'cgidata'} || '',
           'CGIURL'  => $request->{'cgiurl'} || '',
           'CMDPASS' => &escape($request->{'password'}, $type),
           'USER'    => &escape("$request->{'user'}", $type),
          };

  unless ($ok > 0) {
    return $ok if ($mess eq 'NONE');
    $gsubs->{'ERROR'} = $mess;
    $tmp = $mj->format_get_string($type, 'digest_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out &indicate($type, "$str\n", $ok);
    return $ok;
  }

  if ($request->{'mode'} =~ /incvol/) {
    $tmp = $mj->format_get_string($type, 'digest_incvol', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out "$str\n";
  }
  elsif ($request->{'mode'} =~ /status/) {
    unless (ref $mess eq 'HASH') {
      $tmp = $mj->format_get_string($type, 'digest_none', $request->{'list'});
      $str = $mj->substitute_vars_format($tmp, $gsubs);
      print $out "$str\n";
      return 1;
    }

    for $i (sort keys %$mess) {
      next if ($i eq 'default_digest');
      $digest = $mess->{$i};

      $subs = { %$gsubs,
                'COUNT'       => '',
                'DESCRIPTION' => '',
                'DIGESTNAME'  => $i,
                'LAST_RUN'    => '',
                'MAX_AGE'     => '',
                'MAX_MSGS'    => '',
                'MAX_SIZE'    => '',
                'MIN_AGE'     => '',
                'MIN_MSGS'    => '',
                'MIN_SIZE'    => '',
                'NEWEST_AGE'  => '',
                'NEXT_RUN'    => '',
                'OLDEST_AGE'  => '',
                'SIZE'        => '',
              };

      $subs->{'DESCRIPTION'} = &escape($digest->{'description'})
        if $digest->{'desc'};

      $subs->{'LAST_RUN'} = scalar localtime($digest->{'lastrun'})
        if $digest->{'lastrun'};

      $subs->{'NEXT_RUN'} =
        scalar localtime($digest->{'lastrun'} + 
          str_to_offset($digest->{'separate'}, 1, 0, $digest->{'lastrun'})) 
        if ($digest->{'lastrun'} and $digest->{'separate'});

      $subs->{'OLDEST_AGE'} = time_to_str(time - $digest->{'oldest'}, 1)
        if ($digest->{'oldest'});

      $subs->{'MAX_AGE'} = str_to_offset($digest->{'maxage'}, 0, 1)
        if ($digest->{'maxage'});

      $subs->{'NEWEST_AGE'} = time_to_str(time - $digest->{'newest'}, 1)
        if ($digest->{'newest'});

      $subs->{'MIN_AGE'} = str_to_offset($digest->{'minage'}, 0, 1)
        if ($digest->{'minage'});

      $subs->{'COUNT'} = scalar @{$digest->{'messages'}} 
        if ($digest->{'messages'});

      $subs->{'MIN_MSGS'} = $digest->{'minmsg'} 
        if ($digest->{'minmsg'});

      $subs->{'MAX_MSGS'} = $digest->{'maxmsg'} 
        if ($digest->{'maxmsg'});

      $subs->{'MIN_SIZE'} = $digest->{'minsize'} 
        if ($digest->{'minsize'});

      $subs->{'MAX_SIZE'} = $digest->{'maxsize'} 
        if ($digest->{'maxsize'});

      $subs->{'SIZE'} = $digest->{'bytecount'} 
        if ($digest->{'bytecount'});

      $tmp = $mj->format_get_string($type, 'digest_status_head', $request->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";

      $tmp = $mj->format_get_string($type, 'digest_status', $request->{'list'});

      for $msgdata (@{$digest->{'messages'}}) {
        $subs->{'MSGNO'} = $msgdata->[0];
       
        for $j (keys %{$msgdata->[1]}) {
          if ($j eq 'changetime' or $j eq 'date') {
            $date = scalar localtime($msgdata->[1]->{$j});
            $subs->{uc $j} = &escape($date, $type);
          }
          else {
            $subs->{uc $j} = &escape($msgdata->[1]->{$j}, $type);
          }
        }
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }

      $tmp = $mj->format_get_string($type, 'digest_status_foot', $request->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    } 
  }
  else {
    $tmp = $mj->format_get_string($type, 'digest_head', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out "$str\n";

    # force or check mode
    if (ref $mess eq 'HASH' and scalar keys %$mess) {
      $subs = { %$gsubs };
      $tmp = $mj->format_get_string($type, 'digest', $request->{'list'});

      for $i (sort keys %$mess) {
        $subs->{'DIGESTNAME'} = &escape($i, $type);
        $subs->{'ISSUES'} = &escape($mess->{$i}, $type);
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }
    }
    else {
      $tmp = $mj->format_get_string($type, 'digest_none', $request->{'list'});
      $str = $mj->substitute_vars_format($tmp, $gsubs);
      print $out "$str\n";
    }

    $tmp = $mj->format_get_string($type, 'digest_foot', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out "$str\n";
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
  my ($cgidata, $cgiurl, $chunk, $chunksize, $domain, $hwin, $list, $mess, 
      $ok, $str, $subs, $tmp, $topic);

  ($ok, $mess) = @$result;

  $subs = { $mj->standard_subs($request->{'list'}),
           'CGIDATA'  => $request->{'cgidata'},
           'CGIURL'   => $request->{'cgiurl'},
           'CMDPASS'  => &escape($request->{'password'}, $type),
           'TOPIC'    => &escape($request->{'topic'}, $type),
           'USER'     => &escape("$request->{'user'}", $type),
          };

  unless ($ok > 0) {
    return $ok if ($mess eq 'NONE');
    $subs->{'ERROR'} = &escape($mess, $type);
    $tmp = $mj->format_get_string($type, 'help_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok);
    return $ok;
  }

  $tmp = $mj->format_get_string($type, 'help_head', $request->{'list'});
  if (defined $tmp and length $tmp) {
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n" if (length $str);
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

  $tmp = $mj->format_get_string($type, 'help_foot', $list);
  if (defined $tmp and length $tmp) {
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n" if (length $str);
  }

  1;
}

sub index {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my (%legend, %width, @fields, @index, @item, $count,
      $i, $j, $ok, $parent, $str, $subs, $tmp);
  $count = 0;

  @fields = qw(file c-type charset c-t-encoding language size);
  for $i (@fields) {
    $width{$i} = 0;
  }

  $tmp = $request->{'path'};
  if (length $tmp and $tmp !~ m#/$#) {
    $tmp .= '/';
  }
  $parent = '';
  if (length $tmp and $tmp !~ m#^/+$#) {
    $parent = $tmp;
    $parent =~ s#[^/]+/+$##;
  }

  $gsubs = { $mj->standard_subs($request->{'list'}),
             'CGIDATA'  => $request->{'cgidata'},
             'CGIURL'   => $request->{'cgiurl'},
             'CMDPASS'  => &escape($request->{'password'}, $type),
             'PARENT'   => &escape($parent, $type),
             'PATH'     => &escape($tmp, $type),
             'USER'     => &escape("$request->{'user'}", $type),
             'VICTIM'   => &escape("$request->{'victim'}", $type),
           };

  ($ok, @index) = @$result;
  unless ($ok > 0) {
    return $ok if ($index[0] eq 'NONE');
    $gsubs->{'ERROR'} = &escape($index[0]);
    $tmp = $mj->format_get_string($type, 'index_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out &indicate($type, $str, $ok);
    return $ok;
  }
  
  unless ($request->{'mode'} =~ /nosort/) {
    @index = sort {$a->{'file'} cmp $b->{'file'}} @index;
  }

  # Pretty-up the list
  unless ($request->{'mode'} =~ /ugly/) {
    for $i (@index) {
      # Turn path parts into spaces to give an indented look
      unless ($request->{'mode'} =~ /nosort|nodirs/) {
        1 while $i->{'file'} =~ s!(\s*)[^/]*/(.+)!$1  $2!g;
      }
      # Figure out the optimal width for each field.
      for $j (@fields) {
        $width{$j} = (length($i->{$j}) > $width{$j}) ?
          length($i->{$j}) : $width{$j};
      }
    }
  }

  $width{'file'}         ||= 50; 
  $width{'c-type'}       ||= 12; 
  $width{'charset'}      ||= 10; 
  $width{'c-t-encoding'} ||= 12;
  $width{'language'}     ||= 5; 
  $width{'size'}         ||= 5;

  unless (scalar @index and length $index[0]) {
    $tmp = $mj->format_get_string($type, 'index_none', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out "$str\n";
  }
  elsif ($type eq 'wwwadm' or $type eq 'wwwusr') {
    $tmp = $mj->format_get_string($type, 'index_head', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out "$str\n";

    $subs = { %$gsubs };
    for $i (@index) {
      $count++;
      $subs->{'CHARSET'}      = &escape($i->{'charset'});
      $subs->{'CONTENT_TYPE'} = &escape($i->{'c-type'});
      $subs->{'DESCRIPTION'}  = &escape($i->{'description'});
      $subs->{'ENCODING'}     = &escape($i->{'c-t-encoding'});
      $subs->{'FILE'}         = &escape($i->{'file'});
      $subs->{'LANGUAGE'}     = &escape($i->{'language'});
      $subs->{'PERMISSIONS'}  = &escape($i->{'permissions'});
      $subs->{'SIZE'}         = &escape($i->{'size'});
      if ($i->{'c-type'} eq '(dir)') {
        $tmp = $mj->format_get_string($type, 'index_dir', $request->{'list'});
      }
      elsif ($i->{'c-type'} =~ /^text/i) {
        $tmp = $mj->format_get_string($type, 'index_text', $request->{'list'});
      }
      else {
        $tmp = $mj->format_get_string($type, 'index_binary', $request->{'list'});
      }
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }

    $gsubs->{'COUNT'} = $count;
    $tmp = $mj->format_get_string($type, 'index_foot', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out "$str\n";
  }
  else {
    # index_head
    eprint($out, $type, length($request->{'path'}) ?"Files in $request->{'path'}:\n" : "Public files:\n")
      unless $request->{'mode'} =~ /short/;
    for $i (@index) {
      $count++;
      if ($request->{'mode'} =~ /short/) {
        eprint($out, $type, "  $i->{'file'}\n");
        next;
      }
      elsif ($request->{'mode'} =~ /long/) {
        eprintf($out, $type,
          "  %2s %-$width{'file'}s %$width{'size'}s %-$width{'c-type'}s" .
          " %-$width{'charset'}s  %-$width{'c-t-encoding'}s" .
          " %-$width{'language'}s  %s\n",
          $i->{'permissions'}, $i->{'file'}, $i->{'size'}, $i->{'c-type'}, 
          $i->{'charset'}, $i->{'c-t-encoding'}, $i->{'language'},
          $i->{'description'});
      }
      else { # normal
        eprintf($out, $type,
                "  %-$width{'file'}s %$width{'size'}d %s\n", 
                $i->{'file'}, $i->{'size'}, $i->{'description'});
      }
    }
    return 1 if $request->{'mode'} =~ /short/;
    eprint($out, $type, "\n");
    eprintf($out, $type, "%d file%s.\n", $count,$count==1?'':'s');
  }
  1;
}

sub lists {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my (%lists, $basic_format, $cat_format, $category, $count, $data, 
      $desc, $digests, $flags, $foot, $gsubs, $head, $i, $legend, $list, 
      $site, $str, $subs, $tmp);
  my $log = new Log::In 29, $type;
  $count = 0;
  $legend = 0;

  ($site) = $mj->global_config_get($request->{'user'}, $request->{'pass'}, 
                                   'site_name');
  $site ||= $mj->global_config_get($request->{'user'}, $request->{'pass'}, 
                                   'whoami');

  my ($ok, @lists) = @$result;

  $gsubs = {
           $mj->standard_subs('GLOBAL'),
           'CGIDATA' => $request->{'cgidata'} || '',
           'CGIURL'  => $request->{'cgiurl'} || '',
           'CMDPASS' => &escape($request->{'password'}, $type),
           'PATTERN' => &escape($request->{'regexp'}, $type),
           'USER'    => ("$request->{'user'}" =~ /\d\@example\.com$/) ? '' :
                        &escape("$request->{'user'}", $type),
          };

  if ($ok <= 0) {
    return $ok if ($lists[0] eq 'NONE');
    $gsubs->{'ERROR'} = &escape($lists[0], $type);
    $tmp = $mj->format_get_string($type, 'lists_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out &indicate($type, "$str\n", $ok, 1);
    return 1;
  }
  
  if (@lists) {
    if ($request->{'mode'} =~ /full/ and $request->{'mode'} !~ /config/) { 
      $basic_format = $mj->format_get_string($type, 'lists_full', $request->{'list'});
      $head = 'lists_full_head';
      $foot = 'lists_full_foot';
    }
    else {
      $basic_format = $mj->format_get_string($type, 'lists', $request->{'list'});
      $head = 'lists_head';
      $foot = 'lists_foot';
    }

    unless ($request->{'mode'} =~ /compact|tiny/) {
      $tmp = $mj->format_get_string($type, $head, $request->{'list'});
      $str = $mj->substitute_vars_format($tmp, $gsubs);
      print $out "$str\n";
    }
 
    $cat_format = $mj->format_get_string($type, 'lists_category', $request->{'list'});

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
        for ($i = 0; $i < @$desc; $i++) {
          $desc->[$i] = &escape($desc->[$i], $type);
        }

        $digests = [];
        for $i (sort keys %{$data->{'digests'}}) {
          push @$digests, &escape("$i: $data->{'digests'}->{$i}", $type);
        }
        $digests = ["(none)\n"] if ($list =~ /:/);

        $subs = { 
                  %{$gsubs},
                  'ARCURL'        => $data->{'archive'} || "",
                  'CAN_READ'      => $data->{'can_read'} ? " " : '',
                  'CATEGORY'      => &escape($category, $type) || "?",
                  'DESCRIPTION'   => $desc,
                  'DIGESTS'       => $digests,
                  'FLAGS'         => $flags,
                  'LIST'          => $list,
                  'OWNER'         => &escape($data->{'owner'}, $type),
                  'POSTS'         => $data->{'posts'},
                  'SUBS'          => $data->{'subs'},
                  'WHOAMI'        => &escape($data->{'address'}, $type),
                };
                  
        $str = $mj->substitute_vars_format($basic_format, $subs);
        print $out "$str\n";
      }
    }
  }
  else {
    # No lists were found.
    $tmp = $mj->format_get_string($type, 'lists_none', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out "$str\n";
    return 1;
  }

  return 1 if $request->{'mode'} =~ /compact|tiny/;

  $subs = {
            %{$gsubs},
            'COUNT' => $count,
          };
  $tmp = $mj->format_get_string($type, $foot, $request->{'list'});
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out "$str\n";

  if ($request->{'mode'} =~ /enhanced/) {
    $subs = {
              %{$gsubs},
              'COUNT'         => $count,
              'SUBSCRIPTIONS' => $legend,
              'USER'          => &escape("$request->{'user'}", $type),
            };
    $tmp = $mj->format_get_string($type, 'lists_enhanced', $request->{'list'});
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

  $subs = {
           $mj->standard_subs('GLOBAL'),
           'CGIDATA' => $request->{'cgidata'} || '',
           'CGIURL'  => $request->{'cgiurl'} || '',
           'CHANGED' => ($request->{'mode'} =~ /show/)? '' : " ",
           'CMDPASS' => &escape($request->{'password'}, $type),
           'NOTIFIED'=> " ",
           'USER'    => "$request->{'user'}",
           'VICTIM'  => "$request->{'victim'}",
          };

  if (ref $request->{'victim'} and $request->{'victim'}->isvalid) {
    $subs->{'QSADDR'} = &qescape($request->{'victim'}->strip, $type);
    $subs->{'STRIPADDR'} = $request->{'victim'}->strip;
  }

  if ($ok > 0) {
    $tmp = $mj->format_get_string($type, 'password', $request->{'list'});
    if ($request->{'mode'} =~ /quiet/) {
      $subs->{'NOTIFIED'} = '',
    }
  }
  else {
    return $ok if ($mess eq 'NONE');
    $tmp = $mj->format_get_string($type, 'password_error', $request->{'list'});
    $subs->{'ERROR'} = $mess;
  }
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out &indicate($type, "$str\n", $ok, 1);

  $ok;
}

sub post {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($handled, $i, $mess, $ok, $str, $subs, $tmp);

  $handled = 0;
  $handled = 1 if (ref ($request->{'message'}) =~ /^IO/);

  $subs = { $mj->standard_subs($request->{'list'}),
           'CGIDATA'  => $request->{'cgidata'},
           'CGIURL'   => $request->{'cgiurl'},
           'CMDPASS'  => &escape($request->{'password'}, $type),
           'USER'     => &escape("$request->{'user'}", $type),
          };
   
  # The message will have been posted already if this subroutine
  # is called by Mj::Token::t_accept(). 
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

  if ($ok > 0) {
    $tmp = $mj->format_get_string($type, 'post', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }
  else {
    return $ok if ($mess eq 'NONE');
    $subs->{'ERROR'} = &escape($mess, $type);
    $tmp = $mj->format_get_string($type, 'post_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok);
  }

  return $ok;
}

sub put {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($act, $chunk, $chunksize, $dir, $file, $handled, $i, $mess, 
      $ok, $parent, $path, $str, $subs, $tmp);
  ($ok, $mess) = @$result;

  if    ($request->{'file'} eq '/info' ) {$act = 'newinfo' }
  elsif ($request->{'file'} eq '/intro') {$act = 'newintro'}
  elsif ($request->{'file'} eq '/faq'  ) {$act = 'newfaq'  }
  else                                   {$act = 'put'     }

  $path = $file = $parent = $dir = '';
  $path = $request->{'file'};
  if ($path =~ m#(.*/)([^/]+)$#) {
    $dir = $1;
    $file = $2;
    ($parent = $dir) =~ s#[^/]+/+$##;
  }

  $subs = { $mj->standard_subs($request->{'list'}),
           'CGIDATA'  => $request->{'cgidata'},
           'CGIURL'   => $request->{'cgiurl'},
           'CMDPASS'  => &escape($request->{'password'}, $type),
           'COMMAND'  => $act,
           'FILE'     => &escape($file),
           'PARENT'   => &escape($parent),
           'PATH'     => &escape($dir),
           'USER'     => &escape("$request->{'user'}", $type),
          };

  unless ($ok) {
    return $ok if ($mess eq 'NONE');
    $subs->{'ERROR'} = &escape($mess, $type);
    $tmp = $mj->format_get_string($type, 'put_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok);
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
    $tmp = $mj->format_get_string($type, 'put', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }
  else {
    $subs->{'ERROR'} = &escape($mess, $type);
    $tmp = $mj->format_get_string($type, 'put_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok);
  }

  return $ok;
} 

sub register {
  g_sub('register', @_)
}

sub reject {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, $type;
  my (@tokens, $data, $gsubs, $mess, $ok, $str, $subs, $tmp, $token);

  $gsubs = { $mj->standard_subs('GLOBAL'),
            'CGIDATA'  => $request->{'cgidata'},
            'CGIURL'   => $request->{'cgiurl'},
            'CMDPASS'  => &escape($request->{'password'}, $type),
            'USER'     => &escape("$request->{'user'}", $type),
           };

  @tokens = @$result; 

  while (@tokens) {
    ($ok, $mess) = splice @tokens, 0, 2;
    unless ($ok) {
      $gsubs->{'ERROR'} = $mess;

      $tmp = $mj->format_get_string($type, 'reject_error', $request->{'list'});
      $str = $mj->substitute_vars_format($tmp, $gsubs);
      print $out &indicate($type, "$str\n", $ok); 

      next;
    }

    ($token, $data) = @$mess;

    $subs = { $mj->standard_subs($data->{'list'}),
              'CGIDATA'  => $request->{'cgidata'},
              'CGIURL'   => $request->{'cgiurl'},
              'CMDPASS'  => &escape($request->{'password'}, $type),
              'ERROR'    => '',
              'NOTIFIED' => '',
              'TOKEN'    => $token,
              'USER'     => &escape("$request->{'user'}", $type),
            };

    for $tmp (keys %$data) {
      next if (ref $data->{$tmp} eq 'HASH');
      if ($tmp eq 'user') {
        $subs->{'REQUESTER'} = &escape("$data->{'user'}", $type);
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

      $tmp = $mj->format_get_string($type, 'reject_error', $data->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out &indicate($type, "$str\n", $ok); 
      next;
    }

    if ($request->{'mode'} !~ /quiet/ and 
        ($data->{'type'} ne 'consult' or $data->{'ack'})) 
    {
      $subs->{'NOTIFIED'} = " ";
    }

    $tmp = $mj->format_get_string($type, 'reject', $data->{'list'});
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
    return 0 if ($ra eq 'NONE');
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
  my (%outcomes, %stats, @tmp, $chunk, $chunksize, $cmd, $count, $data, 
      $day, $df, $event, $gsubs, $list, $str, $subs, $time, $tmp, 
      $today, $victim);
  my ($ok, $mess) = @$result;

  $gsubs = { $mj->standard_subs($request->{'list'}),
             'CGIDATA'  => $request->{'cgidata'},
             'CGIURL'   => $request->{'cgiurl'},
             'CMDPASS'  => &escape($request->{'password'}, $type),
             'ERROR'    => '',
             'USER'     => &escape("$request->{'user'}", $type),
           };

  unless ($ok > 0) {
    return $ok if ($mess eq 'NONE');
    $gsubs->{'ERROR'} = &escape($mess, $type);
    $tmp = $mj->format_get_string($type, 'report_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out &indicate($type, "$str\n", $ok);
    return $ok;
  }

  %outcomes = ( 1 => 'succeed',
                0 => 'fail',
               -1 => 'stall',
              );

  ($request->{'begin'}, $request->{'end'}) = @$mess;
  @tmp = localtime($request->{'begin'});
  $gsubs->{'START'} = strftime("%Y-%m-%d %H:%M", @tmp);

  @tmp = localtime($request->{'end'});
  $gsubs->{'FINISH'} = strftime("%Y-%m-%d %H:%M", @tmp);

  $today = '';
  $count = 0;

  if ($request->{'mode'} =~ /summary/) {
    $tmp = $mj->format_get_string($type, 'report_summary_head', $request->{'list'});
  }
  else {
    $tmp = $mj->format_get_string($type, 'report_head', $request->{'list'});
  }
  $str = $mj->substitute_vars_format($tmp, $gsubs);
  print $out &indicate($type, "$str\n", $ok);

  $request->{'chunksize'} = 
    $mj->global_config_get($request->{'user'}, $request->{'password'},
                           "chunksize") || 1000;

  $request->{'command'} = "report_chunk";

  $df = $mj->format_get_string($type, 'report_day', $request->{'list'});
  if ($request->{'mode'} =~ /full/) {
    $event = $mj->format_get_string($type, 'report_full', $request->{'list'});
  }
  elsif ($request->{'mode'} =~ /summary/) {
    $event = $mj->format_get_string($type, 'report_summary', $request->{'list'});
  }
  else {
    $event = $mj->format_get_string($type, 'report', $request->{'list'});
  }

  while (1) {
    ($ok, $chunk) = @{$mj->dispatch($request)};
    unless ($ok) {
      $gsubs->{'ERROR'} = &escape($chunk, $type);
      $tmp = $mj->format_get_string($type, 'report_warning', $request->{'list'});
      $str = $mj->substitute_vars_format($tmp, $gsubs);
      print $out &indicate($type, "$str\n", $ok);
      last;
    }
    last unless scalar @$chunk;
    for $data (@$chunk) {
      $count++;
      if ($request->{'mode'} !~ /summary/) {

        if ($data->[1] eq 'bounce') {
          ($victim = $data->[4]) =~ s/\(bounce from (.+)\)/$1/;
        }
        else {
          $victim = ($data->[1] =~ /post|owner/) ? $data->[2] : $data->[3];
          # Remove the comment from the victim's address.
          $victim =~ s/.*<([^>]+)>.*/$1/;
        }
       
        @tmp   = localtime($data->[9]);
        $day   = strftime("%d %B %Y", @tmp);
        $time  = strftime("%H:%M", @tmp);

        $subs = { %$gsubs,
                  'LIST' => $data->[0],
                  'COMMAND' => $data->[1],
                  'REQUESTER' => &escape($data->[2], $type),
                  'USER' => &escape($data->[3], $type),
                  'VICTIM' => &escape($victim, $type),
                  'CMDLINE' => &escape($data->[4], $type),
                  'INTERFACE' => &escape($data->[5], $type),
                  'STATUS' => exists ($outcomes{$data->[6]}) ?
                                $outcomes{$data->[6]} : 'unknown',
                  'SESSIONID' => $data->[8],
                  'DATE' => $day,
                  'TIME' => $time,
                  'ELAPSED' => $data->[10] || 0,
                };
        
        if ($day ne $today) {
          $today = $day;
          $str = $mj->substitute_vars_format($df, $subs);
          print $out "$str\n";
        }

        $str = $mj->substitute_vars_format($event, $subs);
        print $out "$str\n";
      }
      else {
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
    }
  }

  $request->{'command'} = "report_done";
  ($ok, @tmp) = @{$mj->dispatch($request)};

  if (! $count) {
    $tmp = $mj->format_get_string($type, 'report_none', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out "$str\n";
  }
  elsif ($request->{'mode'} =~ /summary/) {
    $subs = { %$gsubs };
    for $cmd (sort keys %stats) {
      $subs->{'COMMAND'} = $cmd;
      for $list (sort keys %{$stats{$cmd}}) {
        next if ($list eq 'TOTAL' and $request->{'list'} ne 'ALL');
        $subs->{'LIST'}    = $list;
        $subs->{'COUNT'}   = $stats{$cmd}{$list}{'TOTAL'};
        $subs->{'SUCCEED'} = $stats{$cmd}{$list}{1};
        $subs->{'STALL'}   = $stats{$cmd}{$list}{'-1'}; 
        $subs->{'FAIL'}    = $stats{$cmd}{$list}{'0'};
        $subs->{'ELAPSED'} = sprintf "%.3f", 
          $stats{$cmd}{$list}{'time'} / $stats{$cmd}{$list}{'TOTAL'};
        $str = $mj->substitute_vars_format($event, $subs);
        print $out "$str\n";
      }
    }
  }

  $gsubs->{'COUNT'} = $count;

  if ($request->{'mode'} =~ /summary/) {
    $tmp = $mj->format_get_string($type, 'report_summary_foot', $request->{'list'});
  }
  else {
    $tmp = $mj->format_get_string($type, 'report_foot', $request->{'list'});
  }
  $str = $mj->substitute_vars_format($tmp, $gsubs);
  print $out "$str\n";

  1;
}

sub sessioninfo {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my ($mess, $ok, $str, $subs, $tmp);

  ($ok, $mess) = @$result; 

  $subs = { $mj->standard_subs($request->{'list'}),
           'CGIDATA'  => $request->{'cgidata'},
           'CGIURL'   => $request->{'cgiurl'},
           'CMDPASS'  => &escape($request->{'password'}, $type),
           'SESSIONID'=> $request->{'sessionid'},
           'USER'     => &escape("$request->{'user'}", $type),
          };

  if ($ok <= 0) {
    $subs->{'ERROR'} = &escape($mess, $type);
    $tmp = $mj->format_get_string($type, 'sessioninfo_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok);
    return $ok;
  }

  $tmp = $mj->format_get_string($type, 'sessioninfo_head', $request->{'list'});
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out "$str\n";

  g_get("sessioninfo", @_);

  $tmp = $mj->format_get_string($type, 'sessioninfo_foot', $request->{'list'});
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out "$str\n";

  1;
}


sub set {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type, $request->{'victim'}";
  my (@changes, @tmp, $change, $count, $files, $flag, $i, $init, 
      $j, $list, $lsubs, $ok, $settings, $str, $subs);
 
  @changes = @$result; 
  $count = $init = 0;

  $subs = { $mj->standard_subs($request->{'list'}),
            'CGIDATA'  => $request->{'cgidata'} || '',
            'CGIURL'   => $request->{'cgiurl'} || '',
            'CMDPASS'  => &escape($request->{'password'}, $type),
            'USER'     => &escape("$request->{'user'}", $type),
          };

  $files = {
            'error' => $mj->format_get_string($type, 'set_error', $request->{'list'}),
            'head' => $mj->format_get_string($type, 'set_head', $request->{'list'}),
            'foot' => $mj->format_get_string($type, 'set_foot', $request->{'list'}),
           };

  if ($request->{'mode'} =~ /check/) {
    $files->{'main'} = $mj->format_get_string($type, 'set_check', $request->{'list'});
    $str = $mj->substitute_vars_format($files->{'head'}, $subs);
    print $out "$str\n";
  }
  else {
    $files->{'main'} = $mj->format_get_string($type, 'set', $request->{'list'});
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
        next if (ref $change->{$j} eq 'HASH');
        next if ($j eq 'partial' or $j eq 'settings');

        if (ref $change->{$j} eq 'ARRAY') {
          @tmp = @{$change->{$j}};
          for ($i = 0; $i < @tmp; $i++) {
            $tmp[$i] = &escape("$tmp[$i]", $type);
          }
          $lsubs->{uc $j} = [ @tmp ];
        }
        else {
          $lsubs->{uc $j} = &escape($change->{$j}, $type);
        }

        if ($j eq 'stripaddr') {
          $lsubs->{'QSADDR'} = &qescape($change->{$j}, $type);
        }
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
      next if ($change eq 'NONE');
      $lsubs->{'ERROR'} = &escape($change, $type);
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
  my (@lists, @tmp, $bouncedata, $error, $flag, $gsubs, $i, $j, $k,
      $lsubs, $settings, $show, $str, $subs, $tmp, $tmp2);
  my ($ok, $data) = @$result;
  $error = [];

  $gsubs = {
            $mj->standard_subs('GLOBAL'),
            'CGIDATA' => $request->{'cgidata'} || '',
            'CGIURL'  => $request->{'cgiurl'} || '',
            'CMDPASS' => &escape($request->{'password'}, $type),
            'USER'    => &escape("$request->{'user'}", $type),
            'VICTIM'  => &escape("$request->{'victim'}", $type),
           };

  if (ref $request->{'victim'} and $request->{'victim'}->isvalid) {
    $gsubs->{'QSADDR'} = &qescape($request->{'victim'}->strip, $type);
    $gsubs->{'STRIPADDR'} = $request->{'victim'}->strip;
  }
 
  # use Data::Dumper; print $out Dumper $data;

  # For validation failures, the dispatcher will do the verification and
  # return the error as the second argument.  For normal denials, $ok is
  # also 0, but a hashref is returned containing what information we could
  # get from the address.
  if ($ok <= 0) {
    if (ref($data)) {
      $error = $data->{'error'};
    }
    else {
      $error = $data;
    }
    return $ok if ($error eq 'NONE');

    $subs = { %$gsubs,
              'ERROR' => $error,
            };

    $tmp = $mj->format_get_string($type, 'show_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok);

    return $ok;
  }

  $subs = { %$gsubs };

  for $i (keys %$data) {
    next if (ref $data->{$i} eq 'HASH');
    next if ($i eq 'lists' or $i eq 'regdata');
    if (ref $data->{$i} eq 'ARRAY') {
      @tmp = @{$data->{$i}};
      for ($j = 0; $j < @tmp; $j++) {
        $tmp[$j] = &escape("$tmp[$j]", $type);
      }
      $subs->{uc $i} = [ @tmp ];
    }
    else {
      $subs->{uc $i} = &escape($data->{$i}, $type);
    }
  }

  if ($data->{strip} eq $data->{xform}) {
    $subs->{'XFORM'} = '';
  }
  if ($data->{xform} eq $data->{alias}) {
    $subs->{'ALIAS'} = '';
  }

  unless ($data->{regdata}) {
    $tmp = $mj->format_get_string($type, 'show_none', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
    return 1;
  }
  for $i (keys %{$data->{'regdata'}}) {
    next if (ref $data->{'regdata'}{$i} eq 'HASH');
    if (ref $data->{'regdata'}{$i} eq 'ARRAY') {
      @tmp = @{$data->{'regdata'}{$i}};
      for ($j = 0; $j < @tmp; $j++) {
        $tmp[$j] = &escape("$tmp[$j]", $type);
      }
      $subs->{uc $i} = [ @tmp ];
    }
    else {
      $subs->{uc $i} = &escape($data->{'regdata'}{$i}, $type);
    }
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

  $tmp = $mj->format_get_string($type, 'show_head', $request->{'list'});
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out "$str\n";

  $show = $mj->format_get_string($type, 'show', $request->{'list'});

  for $i (@lists) {
    $lsubs = { %$subs };
    # Per-list substitutions available directly include:
    #   changetime class classarg classarg2 classdesc flags flagdesc
    #   fulladdr subtime
    for $j (keys %{$data->{'lists'}{$i}}) {
      next if (ref $data->{'lists'}{$i}{$j} eq 'HASH');
      next if ($j eq 'bouncedata' or $j eq 'settings');
      if (ref $data->{'lists'}{$i}{$j} eq 'ARRAY') {
        @tmp = @{$data->{'lists'}{$i}{$j}};
        for ($k = 0; $k < @tmp; $k++) {
          $tmp[$k] = &escape("$tmp[$k]", $type);
        }
        $lsubs->{uc $j} = [ @tmp ];
      }
      else {
        $lsubs->{uc $j} = &escape($data->{'lists'}{$i}{$j}, $type);
      }
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
        if ($settings->{'flags'}[$j]->{'allow'}) {
          $tmp = "<input name=\"$i;$flag\" type=\"checkbox\" $str>";
        }
        else {
          # Use an X or O to indicate a setting that has been disabled
          # by the allowed_flags configuration setting.
          if ($str eq 'checked') {
            $str = 'X';
          }
          else {
            $str = 'O';
          }
          
          $tmp = "<input name=\"$i;$flag\" type=\"hidden\" value=\"disabled\">$str";
        }
        push @{$lsubs->{'CHECKBOX'}}, $tmp;
        $tmp2 = uc($flag) . '_CHECKBOX';
        $lsubs->{$tmp2} = $tmp;
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

  $tmp = $mj->format_get_string($type, 'show_foot', $request->{'list'});
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out "$str\n";

  1;
}

use Date::Format;
sub showtokens {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$request->{'list'}";
  my (@tokens, $bf, $count, $data, $df, $gsubs, $list, $ok,  
      $size, $str, $subs, $tmp, $tokens, $user, $victim);
  my (%type_abbrev) = (
                        'alias'   => 'L',
                        'async'   => 'A',
                        'confirm' => 'S',
                        'consult' => 'O',
                        'delay'   => 'D',
                        'probe'   => 'P',
                      );

  $gsubs = {
            $mj->standard_subs($request->{'list'}),
            'CGIDATA' => $request->{'cgidata'} || '',
            'CGIURL'  => $request->{'cgiurl'} || '',
            'CMDPASS' => &escape($request->{'password'}, $type),
            'USER'    => &escape("$request->{'user'}", $type),
           };

  ($ok, @tokens) = @$result;
  unless (@tokens) {
    $tmp = $mj->format_get_string($type, 'showtokens_none', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out &indicate($type, "$str\n", $ok, 1);
    return $ok;
  }

  unless ($ok > 0) {
    return $ok if ($tokens[0] eq 'NONE');
    $subs = {
             %{$gsubs},
             'ERROR'  => $tokens[0],
            };
    $tmp = $mj->format_get_string($type, 'showtokens_error', $request->{'list'});
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

  $bf = $mj->format_get_string($type, 'showtokens', $request->{'list'});
  $df = $mj->format_get_string($type, 'showtokens_data', $request->{'list'});
  $list = '';
  $count = 0;

  for $data (@tokens) {
    $count++;
    $size = '';

    if ($data->{'size'}) {
      $size = sprintf ("%.1f",  ($data->{'size'} + 51) / 1024);
    }

    $user = &escape($data->{'user'}, $type);
    $victim = &escape($data->{'victim'}, $type);

    $subs = { 
              %{$gsubs},
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
              'VICTIM' => $victim,
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
           %{$gsubs},
           'COUNT' => $count,
          };
              
  $tmp = $mj->format_get_string($type, 'showtokens_all', $request->{'list'});
  $str = $mj->substitute_vars_format($tmp, $subs);
  print $out "$str\n";
  1;
}

sub subscribe {
  g_sub('subscribe', @_);
}

sub tokeninfo {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, $request->{'id'};
  my (@tmp, $expire, $str, $subs, $tmp);
  my ($ok, $data, $sess) = @$result;

  unless ($ok > 0) {
    return $ok if ($data eq 'NONE');
    $subs = { $mj->standard_subs($request->{'list'}),
              'CGIDATA' => $request->{'cgidata'} || '',
              'CGIURL'  => $request->{'cgiurl'} || '',
              'CMDPASS' => &escape($request->{'password'}, $type),
              'ERROR'   => $data,
              'USER'    => &escape("$request->{'user'}", $type),
            };
    $tmp = $mj->format_get_string($type, 'tokeninfo_error', $request->{'list'});
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
            'CMDPASS' => &escape($request->{'password'}, $type),
            'CONSULT' => ($data->{'type'} eq 'consult') ? " " : '',
            'DATE'    => scalar localtime($data->{'time'}),
            'EXPIRE'  => scalar localtime($data->{'expire'}),
            'ISPOST'  => '',
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
    $tmp = $mj->format_get_string($type, 
                                  "tokeninfo_nosession_$data->{'command'}",
                                  $data->{'list'});
    unless ($tmp) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_nosession', 
                                    $data->{'list'});
    }
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
    return 1;
  }
  elsif ($request->{'mode'} =~ /remind/) {
    $tmp = $mj->format_get_string($type, "tokeninfo_remind", 
                                  $data->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }

  $tmp = $mj->format_get_string($type, "tokeninfo_head_$data->{'command'}", 
                                $data->{'list'});
  unless ($tmp) {
    $tmp = $mj->format_get_string($type, 'tokeninfo_head', $data->{'list'});
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

  $tmp = $mj->format_get_string($type, "tokeninfo_foot_$data->{'command'}", 
                                $data->{'list'});
  unless ($tmp) {
    $tmp = $mj->format_get_string($type, 'tokeninfo_foot', 
                                  $data->{'list'});
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
    # XLANG
    $subs = { $mj->standard_subs($request->{'list'}),
              'CGIDATA' => $request->{'cgidata'} || '',
              'CGIURL'  => $request->{'cgiurl'} || '',
              'CMDPASS' => &escape($request->{'password'}, $type),
              'ERROR'   => "No message data was found.\n",
              'USER'    => &escape("$request->{'user'}", $type),
            };
    $tmp = $mj->format_get_string($type, 'tokeninfo_error', $request->{'list'});
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
    $tmp = $mj->format_get_string($type, "tokeninfo_nosession_post", 
                                  $data->{'list'});
    unless ($tmp) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_nosession', 
                                    $data->{'list'});
    }
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out "$str\n";
  }
  elsif ($request->{'mode'} =~ /part/ and 
         $request->{'mode'} !~ /replace|delete/) {

    $part = $request->{'part'};
    if ($part =~ s/[hH]$//) {
      $subs->{'CONTENT_TYPE'} = "header";
      $subs->{'CHARSET'} = "US-ASCII";
      $subs->{'SIZE'} = 
        sprintf("%.1f", (length($msgdata->{$part}->{'header'}) + 51) / 1024);
      $showhead = 1;
    }
    else {
      $subs->{'CONTENT_TYPE'} = $msgdata->{$part}->{'type'};
      $subs->{'CHARSET'} = $msgdata->{$part}->{'charset'};
      $subs->{'SIZE'} = $msgdata->{$part}->{'size'};
      $showhead = 0;
    }

    # Display head file
    if ($request->{'mode'} =~ /edit/) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_edit_head', 
                                    $data->{'list'});
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
      $tmp .= $mj->format_get_string($type, 'tokeninfo_edit_foot', 
                                     $data->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
  }
  else {
    # Print result message.
    if ($request->{'mode'} =~ /delete/) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_delete', 
                                    $data->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
    elsif ($request->{'mode'} =~ /remind/) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_remind', $data->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }
    elsif ($request->{'mode'} =~ /replace/) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_replace', $data->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
    }

    # Print head.
    $tmp = $mj->format_get_string($type, 'tokeninfo_head_post', $data->{'list'});
    unless ($tmp) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_head', $data->{'list'});
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
      $subs->{'CHARSET'}      = $msgdata->{$i}->{'charset'};
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
          $tmp = $mj->format_get_string($type, 'tokeninfo_header', 
                                        $data->{'list'});
          $str = $mj->substitute_vars_format($tmp, $subs);
          $str = $mj->substitute_vars_format($str, $hsubs);
          print $out "$str\n";
        }
      }

      # Display the contents of plain text parts.
      if ($msgdata->{$i}->{'type'} =~ m#^text/plain#i) {
        $request->{'part'} = $i;
        $tmp = $mj->format_get_string($type, 'tokeninfo_text_head', 
                                      $data->{'list'});
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";

        while (1) {
          ($ok, $tmp) = @{$mj->dispatch($request, $chunksize)};
          last unless defined $tmp;
          eprint($out, $type, $tmp);
          last unless $ok;
        }

        $tmp = $mj->format_get_string($type, 'tokeninfo_text_foot', 
                                      $data->{'list'});
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }
      
      # Display images.
      elsif ($msgdata->{$i}->{'type'} =~ /^image/i) {
        $tmp = $mj->format_get_string($type, 'tokeninfo_image', 
                                      $data->{'list'});
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }

      # Display containers, such as multipart types.
      elsif (! length ($msgdata->{$i}->{'size'})) {
        $tmp = $mj->format_get_string($type, 'tokeninfo_container', 
                                      $data->{'list'});
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }

      # Display summaries of other body parts.
      else {
        $tmp = $mj->format_get_string($type, 'tokeninfo_attachment', 
                                      $data->{'list'});
        $str = $mj->substitute_vars_format($tmp, $subs);
        print $out "$str\n";
      }
    }
       
    # Print foot. 
    $tmp = $mj->format_get_string($type, 'tokeninfo_foot_post', 
                                  $data->{'list'});
    unless ($tmp) {
      $tmp = $mj->format_get_string($type, 'tokeninfo_foot', $data->{'list'});
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
  my ($mess, $ok, $str, $subs, $tmp);
  ($ok, $mess) = @$result;

  $subs = { $mj->standard_subs('GLOBAL'),
           'CGIDATA'  => $request->{'cgidata'},
           'CGIURL'   => $request->{'cgiurl'},
           'CMDPASS'  => &escape($request->{'password'}, $type),
           'USER'     => &escape("$request->{'user'}", $type),
           'VICTIM'   => &escape("$request->{'victim'}", $type),
          };

  if ($ok > 0) { 
    $tmp = $mj->format_get_string($type, 'unalias', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
  }
  else {
    return $ok if ($mess eq 'NONE');
    $subs->{'ERROR'} = &escape($mess, $type);
    $tmp = $mj->format_get_string($type, 'unalias_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", $ok, 1);
  }

  $ok;
}

sub unregister {
  g_sub('unregister', @_);
}

sub unsubscribe {
  g_sub('unsubscribe', @_);
}

sub which {
  my ($mj, $out, $err, $type, $request, $result) = @_;
  my $log = new Log::In 29, "$type";
  my ($fmt, $last_list, $gsubs, $lfmt, $list, $match, $str, 
      $subs, $tmp, $total);
  my ($ok, @matches) = @$result;

  $gsubs = { $mj->standard_subs('GLOBAL'),
            'CGIDATA'  => $request->{'cgidata'},
            'CGIURL'   => $request->{'cgiurl'},
            'CHUNKSIZE'=> '',
            'CMDPASS'  => &escape($request->{'password'}, $type),
            'PATTERN'  => &escape($request->{'regexp'}, $type),
            'USER'     => &escape("$request->{'user'}", $type),
           };

  if (exists $request->{'chunksize'} and $request->{'chunksize'} > 0) {
    $gsubs->{'CHUNKSIZE'} = $request->{'chunksize'};
  }

  # Deal with initial failure
  if ($ok <= 0) {
    return $ok if ($matches[0] eq 'NONE');
    $gsubs->{'ERROR'} = &escape($matches[0], $type);
    $tmp = $mj->format_get_string($type, 'which_error', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out &indicate($type, "$str\n", $ok);
    return $ok;
  }

  $last_list = ''; 
  $total = 0;

  unless (scalar @matches) {
    $tmp = $mj->format_get_string($type, 'which_none', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out "$str\n";
    return $ok;
  }

  $tmp = $mj->format_get_string($type, 'which_head', $request->{'list'});
  $str = $mj->substitute_vars_format($tmp, $gsubs);
  print $out &indicate($type, "$str\n", $ok);

  $subs = { %$gsubs };
  $fmt = $mj->format_get_string($type, 'which_data', $request->{'list'});
  $lfmt = $mj->format_get_string($type, 'which', $request->{'list'});

  while (@matches) {
    ($list, $match) = @{shift @matches};

    # If $list is undefined, we have a message instead.
    unless (defined $list and length $list) {
      $subs->{'ERROR'} = $match;
      $tmp = $mj->format_get_string($type, 'which_warning', $request->{'list'});
      $str = $mj->substitute_vars_format($tmp, $subs);
      print $out "$str\n";
      next;
    }

    $subs->{'LIST'} = $list;
    $subs->{'STRIPADDR'} = &escape($match, $type);
    $subs->{'QSADDR'} = &qescape($match, $type);

    if ($list ne $last_list) {
      $str = $mj->substitute_vars_format($lfmt, $subs);
      print $out "$str\n";
    }

    $str = $mj->substitute_vars_format($fmt, $subs);
    print $out "$str\n";

    $total++;
    $last_list = $list;
  }

  $gsubs->{'COUNT'} = $total;
  $tmp = $mj->format_get_string($type, 'which_foot', $request->{'list'});
  $str = $mj->substitute_vars_format($tmp, $gsubs);
  print $out "$str\n";

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
    $tmp = $mj->format_get_string($type, 'who', $request->{'list'});
    $head = $mj->format_get_string($type, 'who_head', $request->{'list'});
    $foot = $mj->format_get_string($type, 'who_foot', $request->{'list'});
  }
  elsif ($source eq 'GLOBAL') {
    $remove = "unregister";
    $tmp = $mj->format_get_string($type, 'who_registry', $request->{'list'});
    $head = $mj->format_get_string($type, 'who_registry_head', $request->{'list'});
    $foot = $mj->format_get_string($type, 'who_registry_foot', $request->{'list'});
  }
  else {
    $tmp = $mj->format_get_string($type, 'who', $request->{'list'});
    $head = $mj->format_get_string($type, 'who_head', $request->{'list'});
    $foot = $mj->format_get_string($type, 'who_foot', $request->{'list'});
  }
 
  my $log = new Log::In 29, "$type, $source, $request->{'regexp'}";

  $gsubs = { 
            $mj->standard_subs($source),
            'CGIDATA' => $request->{'cgidata'} || '',
            'CGIURL'  => $request->{'cgiurl'} || '',
            'CMDPASS' => &escape($request->{'password'}, $type),
            'MODE'    => &escape($request->{'mode'}, $type),
            'PATTERN' => &escape($request->{'regexp'}, $type),
            'REMOVE'  => $remove,
            'START'   => $request->{'start'},
            'USER'    => &escape("$request->{'user'}", $type),
           };

  ($ok, $regexp, $settings) = @$result;

  if ($ok <= 0) {
    return $ok if ($regexp eq 'NONE');
    $gsubs->{'ERROR'} = &indicate($type, $regexp, $ok);
    $tmp = $mj->format_get_string($type, 'who_error', $request->{'list'});
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

  if ($type =~ /^w/ and $request->{'mode'} !~ /enhanced|summary/) {
    print $out "<pre>\n";
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
        next if (ref $i->{$j} eq 'HASH');
        if ($request->{'mode'} =~ /enhanced/) {
          $subs->{uc $j} = &escape($i->{$j}, $type);
        }
        else {
          $subs->{uc $j} = '';
        }
      }

      $subs->{'FULLADDR'} = &escape($i->{'fulladdr'}, $type);
      $subs->{'QSADDR'} = &qescape($i->{'stripaddr'}, $type);
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
          if ($i->{'class'} eq 'nomail' and $i->{'classarg'}) {
            @time = localtime($i->{'classarg'});
            $fullclass .= "-" . 
            sprintf "%4d-%.2d-%.2d %.2d:%.2d", $time[5]+1900, $time[4]+1, 
                     $time[3], $time[2], $time[1];
          }
          else {
            $fullclass .= "-" . $i->{'classarg'} if ($i->{'classarg'});
          }
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
 
  if ($type =~ /^w/ and $request->{'mode'} !~ /enhanced|summary/) {
    print $out "</pre>\n";
  }
 
  if ($request->{'mode'} =~ /summary/) {

    $gsubs->{'TOTAL'} = $stats{'TOTAL'};
    if ($request->{'list'} ne 'GLOBAL' or $request->{'sublist'} ne 'MAIN') {
      $tmp = $mj->format_get_string($type, 'who_summary', $request->{'list'});
      $gsubs->{'CLASS'} = [];
      $gsubs->{'SUBS'} = [];
      for $i (sort keys %stats) {
        next if ($i eq 'TOTAL');
        push @{$gsubs->{'CLASS'}}, $i;
        push @{$gsubs->{'SUBS'}}, $stats{$i};
      }
    }
    else {
      $tmp = $mj->format_get_string($type, 'who_registry_summary', 
                                    $request->{'list'});
      $gsubs->{'LISTS'} = [];
      $gsubs->{'SUBS'} = [];
      for $i (sort keys %stats) {
        next if ($i eq 'TOTAL');
        push @{$gsubs->{'LISTS'}}, $i;
        push @{$gsubs->{'SUBS'}}, $stats{$i};
      }
    }
    $str = $mj->substitute_vars_format($tmp, $gsubs);
    print $out "$str\n";
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
  my ($chunk, $chunksize, $desc, $dir, $file, $lastchar, $parent,
      $path, $subs, $tmp);
  my ($ok, $mess) = @$result;

  $path = $file = $parent = $dir = '';
  if ($base eq 'get') {
    $path = $request->{'path'};
    if ($path =~ m#(.*/)([^/]+)$#) {
      $dir = $1;
      $file = $2;
      ($parent = $dir) =~ s#[^/]+/+$##;
    }
    else {
      $file = $path;
    }
  }
 
  unless ($ok > 0) {
    return $ok if ($mess eq 'NONE');
    $subs = {
             $mj->standard_subs($request->{'list'}),
             'COMMAND' => &escape($base),
             'ERROR'   => &escape($mess || ''),
             'FILE'    => &escape($file),
             'PARENT'  => &escape($parent),
             'PATH'    => &escape($dir),
            };

    $tmp = $mj->format_get_string($type, 'get_error', $request->{'list'});
    $chunk = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$chunk\n", $ok);

    return $ok;
  }

  if ($base ne 'sessioninfo') {
    $subs = {
             $mj->standard_subs($request->{'list'}),
             'CGIDATA'  => $request->{'cgidata'} || '',
             'CGIURL'   => $request->{'cgiurl'} || '',
             'CMDPASS'  => &escape($request->{'password'}, $type),
             'COMMAND'  => &escape($base),
             'DESCRIPTION' => &escape($mess->{'description'}, $type),
             'FILE'    => &escape($file),
             'PARENT'  => &escape($parent),
             'PATH'    => &escape($dir),
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
      $tmp = $mj->format_get_string($type, 'get_edit_head', $request->{'list'});
    }
    else {
      $tmp = $mj->format_get_string($type, 'get_head', $request->{'list'});
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
      $tmp = $mj->format_get_string($type, 'get_edit_foot', $request->{'list'});
    }
    else {
      $tmp = $mj->format_get_string($type, 'get_foot', $request->{'list'});
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
  my (@res, $addr, $fail, $i, $list, $ok, $str, $subs, $succeed, $tmp);

  $list = $request->{'list'};
  if (exists ($request->{'sublist'}) and 
      length ($request->{'sublist'}) and
      $request->{'sublist'} ne 'MAIN') 
  {
    $list .= ":$request->{'sublist'}";
  }

  $subs = { $mj->standard_subs($list),
            'CGIDATA'  => $request->{'cgidata'},
            'CGIURL'   => $request->{'cgiurl'},
            'CMDPASS'  => &escape($request->{'password'}, $type),
            'USER'     => &escape("$request->{'user'}", $type),
          };

  $fail = $mj->format_get_string($type, "${act}_error", $request->{'list'});
  $succeed = $mj->format_get_string($type, $act, $request->{'list'});

  @res = @$result;
  unless (scalar (@res)) {
    $tmp = $mj->format_get_string($type, 'subscribe_none', $request->{'list'});
    $str = $mj->substitute_vars_format($tmp, $subs);
    print $out &indicate($type, "$str\n", 0); 

    return 1;
  }
  # Now print the multi-address format.
  while (@res) {
    ($ok, $addr) = splice @res, 0, 2;

    unless ($ok > 0) {
      next if ($addr eq 'NONE');
      $subs->{'ERROR'} = &escape($addr, $type);
      $str = $mj->substitute_vars_format($fail, $subs);
      print $out &indicate($type, "$str\n", $ok);

      next;
    }

    for $tmp (@$addr) {
      $subs->{'VICTIM'} = &escape("$tmp", $type);
      $str = $mj->substitute_vars_format($succeed, $subs);
      print $out &indicate($type, "$str\n", $ok); 
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

  $addr = "$request->{'user'}";
  if ($addr =~ /example.com$/i) {
    $addr = '';
  }
  else {
    $addr = qescape($addr);
  }
 
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
  return '' unless (defined $_);

  if (ref $_) {
    my $r = ref $_;
    warn "Mj::Format::escape cannot process $r objects.\n";
    return '';
  }

  return $_ if ($type eq 'text');
  my %esc = ( '&'=>'amp', '"'=>'quot', '<'=>'lt', '>'=>'gt');
  s/([<>\"&])/\&$esc{$1};/mg; 
  s/([\x80-\xFF])/'&#'.unpack('C',$1).';'/eg;
  $_;
}

=head2 sescape(string)

The sescape function places a backslash before '$' characters
to prevent variable substitution from taking place.

=cut
sub sescape {
  my $str = shift;

  return '' unless (defined $str and length $str);
  $str =~ s/\$/\\\$/g;
  return $str;
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

  return '' unless (defined $_);
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

  return '' unless (defined $_);
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


=head1 NAME

Mj::Parser - routines for parsing commands from files

=head1 SYNOPSIS

blah

=head1 DESCRIPTION

This file contains code for parsing commands from a filehandle and for
parsing the files out of a MIME entity.

=cut
package Mj::Parser;
use Mj::Log;
use strict;

use AutoLoader 'AUTOLOAD';
1;
__END__

=head2 parse_entity

This takes apart a MIME entity and parses each text/plain piece in turn.
It returns a list of entities.  This gets called recursively on each
sub-entity (if there are any) and is expected that after the recursion has
ended it will return the full list of entities parsed.

This has a tough problem to solve.  If seen in this stage, non-text parts
are ignored.  However, commands within a part may refer to other parts that
fall after it.  These parts can be of any type, and the part parser must
have access to them.  However, we must also be sensitive to horrible
mailers that might add an extra part before the message.

Currently, we''re less sensitive to mailers that add an extra part after the
main part but before any of the attachments.  The solution to this would be
to allow the attachments to be named instead of referred to by number.

=cut
use IO::File;
sub parse_entity {
  my $mj        = shift;
  my %args      = @_;
  my $entity    = $args{'entity'};
  my (%breaks, @attachments, @ents, @entities, @parts, $body, $count, 
      $formatter, $i, $infh, $list, $name, $outfh, $ok, $tree, $txtfile, 
      $type);

  $args{'title'} ||= 'toplevel';
  $::log->in(30, undef, "info", "Parsing entity $args{'title'}");

  if (defined $args{'deflist'} and length $args{'deflist'}) {
    $list = $args{'deflist'};
  }
  else {
    $list = 'GLOBAL';
  }

  return(0, $mj->format_error('unparsed_entity', $list)) 
    unless (defined $entity);

  @entities = ();
  @parts = $entity->parts;

  if (@parts) {
    # Loop over the parts, looking for one that has real commands in it.
    # We stop parsing when we find one with real commands and assume that
    # any other parts were attachments used as data for the commands.
    $count = $ok = 0;
    while (@parts) {
      ($ok, @ents) =
	parse_entity($mj,
		     %args,
		     title => "part $count of $args{'title'}",
		     entity => shift @parts,
		     parts  => \@parts,
		    );
      push @entities, @ents;
      if ($ok) {
        $::log->message(30, "info", "Parsed commands; not parsing attachments.");
        last;
      }
      $count++;
    }
    $::log->out;
    return ($ok, @entities);
  }
  # We've arrived at a single part whch doesn't contain others.
  $type = $entity->head->mime_type;
  if ($type !~ m!^text(/plain|/html)?$!i) {
    # We have something other than a plain text part
    push @entities, build MIME::Entity
      (
       Description => "Ignored part.",
       Top         => 0,
       Data        => [ $mj->format_error('ignored_part', $list,
                                          'CONTENT_TYPE' => $type) ],
      );
    $ok = 0;
  }
  else {
    if ($type =~ /html/) {
      $txtfile = "$args{'tmpdir'}/mje." . Majordomo::unique() . ".in";
      $outfh = new IO::File "> $txtfile";
      $::log->abort("Could not open file $txtfile: $!") unless ($outfh);
      
      $entity->print_body($outfh);
      $outfh->close() 
        or $::log->abort("Unable to close file $txtfile: $!");

      require HTML::TreeBuilder;
      $tree = HTML::TreeBuilder->new->parse_file($txtfile);
      unlink $txtfile;

      $txtfile = "$args{'tmpdir'}/mje." . Majordomo::unique() . ".in";
      $outfh = new IO::File "> $txtfile";
      $::log->abort("Unable to open file $txtfile: $!") unless ($outfh);
      %breaks =  ( 
                  'blockquote' => 3,
                  'body' => 2,
                  'br' => 1,
                  'h1' => 3,
                  'h2' => 3,
                  'h3' => 3,
                  'h4' => 3,
                  'h5' => 3,
                  'h6' => 3,
                  'hr' => 1,
                  'li' => 1,
                  'p'  => 2,
                  'pre' => 3,
                  'tr' => 1,
                 );

      $tree->traverse(
        sub {
            my ($node, $start, $depth) = @_;
            if (ref $node) {
              my $tag = $node->tag;
              if (defined($tag) and exists($breaks{$tag})) {
                print $outfh "\n" if ($start and ($breaks{$tag} & 1));
                print $outfh "\n" if (!$start and ($breaks{$tag} & 2));
              }
              return 1;
            }
            else {
              print $outfh $node;
            }
            1;
        }
      );

      $outfh->close() 
        or $::log->abort("Unable to close file $txtfile: $!");
      $tree->delete;

      $infh = new IO::File "$txtfile";
      $::log->abort("Could not open file $txtfile: $!") unless ($infh);
    }
    else {
      # We have a plain text part; parse it.
      $body = $entity->bodyhandle;
      if ($body) {
        $infh = $body->open("r");
      }
      unless ($body and $infh) {
        $::log->abort("Unable to open body part: $!");
      }
    }

    # Open handles for all of the attachments to this part
    for $i (@{$args{'parts'}}) {
      # Make sure we have a single part entity
      if (defined($i->is_multipart) && ($i->is_multipart == 0)
          && defined($i->bodyhandle)) {
        push @attachments, $i->bodyhandle->open("r");
      }
    }

    # Open a file to stuff the output in
    $name = "$args{'tmpdir'}/mje." . Majordomo::unique() . ".out";
    $outfh = new IO::File "> $name" or
      $::log->abort("Unable to open output file $name: $!");

    # XXX parse_part expects a hashref of "extra stuff" as its last
    # argument.  We just happen to have all of that in our argument hash,
    # so we pass it.  We should just pass a single hash.
    $ok = parse_part($mj,
		     %args,
		     infh        => $infh,
		     outfh       => $outfh,
		     attachments => \@attachments,
		    );
    $infh->close;
    $outfh->close()
      or $::log->abort("Unable to close file $name: $!");

    for $i (@attachments) {
      $i->close;
    }

    if (-s $name) {
      # XLANG
      push @entities, 
        build MIME::Entity(Path        => $name,
                           Filename    => undef,
                           Encoding    => '8bit',
                           Description => "Results from $args{'title'}",
                           Top         => 0,
                          );
    }

    # We could also add an entity containing the original message.  We could
    # also do a separate entity for each command, or for those which produce
    # a large amount of output.
  }

  unlink ($txtfile) if (defined $txtfile);
  $::log->out("executed $ok");
  return ($ok, @entities);
}

=head2 parse_part

The main parser.  This expects two already open IO handles, one for input
and one for output, and an arrayref containing handles open on each of the
parts attached to this part.  The input filehandle is expected to be
connected to the body of a message.  The output can go anywhere, but the
idea is that it eventually gets mailed to the user.

In addition, this takes a ref to an array containing filehandles open on
each of the attachments to the part, if there are any.

This also takes a title, which is just some kind of text description of
what we''re parsing, the name of the interface that called us, and a ref to
a hash containing additional data (currently reply_to, password, deflist,
and token).

=cut
use Date::Format;
use Mj::Util qw(re_match str_to_offset);
use Mj::CommandProps qw(:command :function);
use Mj::Format;
use IO::File;
use MIME::Entity;
sub parse_part {
  my $mj         = shift;
  my %args       = @_;
  my $inhandle    = $args{'infh'};
  my $outhandle   = $args{'outfh'};
  my $title       = $args{'title'};
  my $interface   = $mj->{'interface'};
  my $attachments = $args{'attachments'};
  my $list        = $args{'deflist'} || 'GLOBAL';

  my $log         = new Log::In 50, "$interface, $title";
  my (@arglist, @help, $action, $cmdargs, $attachhandle, $command, $count,
      $delay, $ent, $fail_count, $function, $garbage, $mess,
      $mode, $name, $ok, $ok_count, $out, $outfh, $password, 
      $pend_count, $replacement, $request, $result, $sender, $shown,
      $sigsep, $subject, $sublist, $subs, $tlist, $tmpdir, $true_command, 
      $unk_count, $user);

# use Data::Dumper;
# warn Dumper $mj;
# warn Dumper $args{'mj'};

  $count = $ok_count = $pend_count = $fail_count = $unk_count = $garbage = 0;
  $delay = 0;
  $shown = 0;
  $user = $args{'reply_to'};
  $sigsep = $mj->global_config_get(undef, undef, 'signature_separator');
  $interface =~ s/(\w+)-.+/$1/;

 CMDLINE:
  while (defined($_ = $inhandle->getline)) {

    # Skip comments
    next if /^\s*\#/;

    # Skip blank lines
    next if /^\s*$/;

    if (re_match($sigsep, $_)) {
      chomp $_;
      print $outhandle $mj->format_error('signature_separator', $list,
                                         'SEPARATOR' => $_); 
      last CMDLINE;
    }

    # request is a reference to a hash that is used
    # to marshal arguments for a call to majordomo core
    # functions via dispatch().
    $request = {};

    # We have something that looks like a command.  Process it and any here
    # arguments that may follow.
    ($out, $command, $cmdargs, $attachhandle, @arglist) =
      parse_line($mj, $inhandle, $outhandle, $attachments, $_);

    # If we hit EOF while processing the command line, we ignore it and let
    # the loop run its course.
    unless (defined $command) {
      print $outhandle "\n$out" if (defined $out and length $out);
      next CMDLINE;
    }

    # Check for legality of command
    if ($command eq '') {
      print $outhandle "\n$out";
      print $outhandle $mj->format_error('empty_command', $list);
      next CMDLINE;
    }

    # Pull off a command mode
    ($command, $mode) = $command =~ /([^=-]+)[=-]?(.*)/;
    next CMDLINE unless $command;
    $mode = '' unless defined $mode;

    $true_command = command_legal($command);
    $log->message(50, "info", "$command aliased to $true_command.")
      if (defined $true_command and $command ne $true_command);

    unless (defined($true_command) &&
            (command_prop($true_command, $interface) ||
            (command_prop($true_command, "${interface}_parsed"))))
      {
        unless ($garbage) {
          print $outhandle "\n$out";
          print $outhandle $mj->format_error('invalid_command', $list,
                                               'COMMAND' => $command);
        }
        $garbage++;
        next CMDLINE;
      }

    # The command is pretty close to legal; go ahead and print the line and
    # a message if we skipped any garbage.
    if ($garbage > 1) {
      print $outhandle $mj->format_error('skipped_lines', $list,
                                           'LINES' => $garbage - 1);
    }
    $garbage = 0;

    undef $password;

    # Deal with "approve" command; we do it here so that it can be aliased
    # by the above call to command_legal.
    if ($true_command eq "approve") {
      ($password, $command, $cmdargs) = split(" ", $cmdargs, 3);

      unless (defined $password) {
        print $outhandle "\n$out";
        print $outhandle $mj->format_error('approve_no_password', $list);
        next CMDLINE;
      }

      unless (defined $command) {
        print $outhandle "\n$out";
        print $outhandle $mj->format_error('approve_no_command', $list);
        next CMDLINE;
      }

      $cmdargs  = '' unless defined $cmdargs;

      # Pull off a command mode
      ($command, $mode) = $command =~ /([^=-]+)[=-]?(.*)/;
      $mode = '' unless defined $mode;

      $true_command = command_legal($command);
      $log->message(50, "info", "$command aliased to $true_command.")
        if defined $true_command and $command ne $true_command;
      unless (defined($true_command) &&
              command_prop($true_command, $interface))
        {
          print $outhandle "\n$out";
          print $outhandle $mj->format_error('invalid_command', $list,
                                             'COMMAND' => $command);
          next CMDLINE;
        }
    }

    # Deal with "end" command; again, this can be aliased
    if ($true_command eq "end") {
      print $outhandle "\n$out";
      print $outhandle $mj->format_error('end_command', $list);
      last CMDLINE;
    }

    # If necessary, we extract the list name from the arguments, accounting
    # for a possible default list in effect, and verify its validity
    if (command_prop($true_command, "list")) {
      $cmdargs = add_deflist($mj, $cmdargs, $args{'deflist'}, $args{'reply_to'});
      ($tlist, $cmdargs) = split(" ", $cmdargs, 2);
      unless (defined($tlist) && length($tlist)) {
        print $outhandle "\n$out";
        print $outhandle $mj->format_error('no_list', 'GLOBAL',
                                           'COMMAND' => $command);
        next CMDLINE;
      }
      ($list, $sublist, $mess) = $mj->valid_list($tlist,
                                  command_prop($true_command, 'all'),
                                  command_prop($true_command, 'global'));

      if (length $mess) { 
        print $outhandle "\n$out";
        print $outhandle "$mess\n";
      }
      unless (defined $list and length $list) {
        next CMDLINE;
      }
      $list .= ":$sublist" if (length $sublist);
    }
    # Bomb if given here args or an attachment when not supposed to
    if (command_prop($true_command, "nohereargs") &&
        (@arglist || $attachhandle))
      {
        print $outhandle "\n$out";
        print $outhandle $mj->format_error('invalid_hereargs', $list,
                                           'COMMAND' => $command);
        next CMDLINE;
      }

    # Warn if command takes no args
    if (command_prop($true_command, "noargs") &&
	($cmdargs || @arglist || $attachhandle))
      {
        print $outhandle "\n$out";
        print $outhandle $mj->format_error('invalid_arguments', $list,
                                           'COMMAND' => $command);
      }

    # Warn of obsolete usage
    if ($replacement = command_prop($true_command, "obsolete")) {
      print $outhandle "\n$out";
      print $outhandle $mj->format_error('obsolete_command', $list,
                                         'COMMAND' => $command,
                                         'NEWCOMMAND' => $replacement);
      next CMDLINE;
    }

    # We have a legal command.  Now we actually do something.
    $count++;
    $shown++;

    # First, handle the "default" command internally.
    if ($true_command eq 'default') {
      print $outhandle "\n$out";
      $ok_count++;
      ($action, $cmdargs) = split(" ", $cmdargs, 2);
      if ($action eq 'list') {
	$args{'deflist'} = $list = $cmdargs;
	print $outhandle $mj->format_error('default_set', $list, 
                                           'SETTING' => 'list',
                                           'VALUE' => $cmdargs);
      }
      elsif ($action =~ /^password|passwd$/) {
	$args{'password'} = $cmdargs;
	if (length($cmdargs)) {
          print $outhandle $mj->format_error('default_set', $list, 
                                             'SETTING' => 'password',
                                             'VALUE' => $cmdargs);
	}
	else {
          print $outhandle $mj->format_error('default_reset', $list, 
                                             'SETTING' => 'password');
	}
      }
      elsif ($action eq 'user') {
        if ($cmdargs) {
          $user = $cmdargs;
        }
        else {
          $user = $args{'reply_to'};
        }
        print $outhandle $mj->format_error('default_set', $list, 
                                           'SETTING' => 'user',
                                           'VALUE' => $user);
      }
      elsif ($action eq 'delay') {
        if ($cmdargs) {
          $delay = str_to_offset($cmdargs, 1, 0) || 0;
        }
        else {
          $delay = 0;
        }
        print $outhandle $mj->format_error('default_set', $list, 
                                           'SETTING' => 'password',
                                           'VALUE' => $user);
      }
      else {
        print $outhandle $mj->format_error('invalid_default', $list,
                                           'SETTING' => $action);
        $ok_count--;
        $fail_count++;
      }
    }
    else {
      # Handle default arguments for commands
      if ($true_command =~ /accept|reject/) {
        if ($cmdargs !~ /[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}/ && $args{token}) {
          $cmdargs = "$args{'token'} $cmdargs";
        }
      }
      elsif ($true_command =~ /new(faq|info|intro)/) {
        $cmdargs = "/$1 default";
        $true_command = "put";
      }
      elsif ($true_command =~ /configedit/) {
        $true_command = "configshow";
      }

      $cmdargs ||= '';

      # initialize basic information
      $request->{'command'}  = $true_command;
      $request->{'delay'}    = $delay;
      $request->{'list'}     = $list;
      $request->{'mode'}     = $mode;
      $request->{'password'} = $password || $args{'password'};
      $request->{'user'}     = $user;

      # deal with arguments
      parse_args($request, $cmdargs, \@arglist, $attachhandle);

      # XXX if there are no arguments, read attachment from attachhandle
      no strict 'refs';
      if (function_prop($true_command, 'iter')) {
        $request->{'command'} .= '_start';
      }
      $result = $mj->dispatch($request);

      if (ref $result eq 'ARRAY' and $result->[0] <= 0 
          and $result->[1] eq 'NONE')
      {
        $shown--;
        next CMDLINE;
      }

      print $outhandle "\n$out";

      # If a new identity has been assumed, send the output
      # of the command to the new address.
      if ($user ne $args{'reply_to'}) {
        $tmpdir = $mj->_global_config_get('tmpdir');
        $name = "$tmpdir/mje." . Majordomo::unique() . ".out";
        $outfh = new IO::File "> $name" or
          $::log->abort("Unable to open file $name: $!");
      }
      else {
        $outfh = $outhandle;
      }

      ($ok, @help) =
        &{"Mj::Format::$true_command"}($mj, $outfh, $outfh,
                                       'text', $request, $result);

      # Mail the result if posing.
      if ($user ne $args{'reply_to'}) {
        $outfh->close()
          or $::log->abort("Unable to close file $name: $!");

        $sender = $mj->_list_config_get($request->{'list'}, 'sender');

        if ($result->[0] and ref($result->[1]) eq 'HASH' and
            exists ($result->[1]->{'description'})) {
          # Use the file description in the title of the results.
          $subs = {
                    $mj->standard_subs($request->{'list'}),
                  };
          $mess = $mj->substitute_vars_string($result->[1]->{'description'},
                                              $subs);
        }
        else {
          $mess = $mj->format_error('command_results', $list,
                                    'COMMAND' => $true_command);
        }
        $ent = build MIME::Entity
          (
           From     => $args{'reply_to'},
           Date     => time2str("%a, %d %b %Y %T %z", time),
           Path     => $name,
           To       => $user,
           'Reply-To' => $sender,
	   Encoding => '8bit',
           Subject  => $mess,
           'MIME-Version' => "1.0",
          );

        if ($ent and -s $name) {
          $mj->mail_entity($sender, $ent, $user) if ($ent and -s $name);
          print $outhandle 
            $mj->format_error('results_mailed', $list,
                              'USER' => $user,
                              'SUCCEED' => $ok >0 ? " " : '',
                              'STALL'   => $ok <0 ? " " : '',
                              'FAIL'    => $ok==0 ? " " : '',
                             );
        }
        $ent->purge if $ent;
        unlink $name;
      }

      if (!defined $ok) {
        $unk_count++;
      }
      elsif ($ok > 0) {
        $ok_count++;
      }
      elsif ($ok < 0) {
        $pend_count++;
      }
      else { # $ok == 0
        $fail_count++;
      }
    }
  } # CMDLINE

  if ($garbage > 1) {
    print $outhandle $mj->format_error('skipped_lines', $list,
                                         'LINES' => $garbage - 1);
  }

  if ($shown or $garbage > 1) {
    print $outhandle "\n";
    print $outhandle
      $mj->format_error('commands_processed', $list,
                        'COUNT' => $shown,
                        'FAIL'  => $fail_count,
                        'STALL' => $pend_count,
                        'SUCCEED' => $ok_count,
                        'SESSIONID' => $mj->{'sessionid'},
                       );
  }

  if ($count == 0) {
    # No commands were found; log as an error under "parse".
    $mj->inform('GLOBAL', 'parse', $user, $user, '(no valid commands)',
                $mj->{'interface'}, 0, 0, 0, "No valid commands were found.",
                $::log->elapsed);

  }
  return $count;
}

=head2 parse_line

This parses a single command, including any lines specified by a << TAG
construct or an attachment specified by an <@ ID construct.

 In:  an input filehandle
      an output filehandle
      a string containing the first line of the command

 Out: the name of the command from the line
      the first-line arguments
      a filehandle from which to draw arguments
      the number of the attachment used
      an array of here arguments

=cut
sub parse_line {
  my $mj          = shift;
  my $inhandle    = shift;
  my $outhandle   = shift;
  my $attachments = shift;
  $_              = shift;
  my $log         = new Log::In 60;
  my (@arglist, $used, $line, $command, $tag, $attachhandle, $out);

  # Merge lines ending in backslashes, ignoring trailing white space, 
  # unless they are escaped as a double-backslash.
  chomp;
  while ( (/\\\s*$/) && !(/\\\\\s*$/) ) {
    s/\\\s*$/ /;
    $_ .= $inhandle->getline;
    chomp;
  }

  # Trim leading and trailing whitespace and remove tabs
  s/^\s*(.*?)\s*$/$1/;
  s/\t/ /g;

  # Reduce escaped backslash to a simple backslash
  s/\\\\$/\\/; 

  # Echo the line
  $out .= ">>>> $_\n" if (length $_);

  # Process an attachment with <@ num, where num is the attachment num.
  # <@1 would pull from the attachment immediately following this one.
  if (/^(.*)\s+<@\s*(\d*)$/) {
    $_    = $1;
    $used = ($2 || 1);
    if ($used > @{$attachments}) {
      $out .= $mj->format_error('invalid_attachment', 'GLOBAL',
                                'COUNT' => scalar @$attachments,
                               );
      return $out;
    }
    $log->message(80, "info", "Parsing attachment argument, #$used, rest $_.");
    $attachhandle = $attachments->[$used - 1];
  }

  # Handle a possible << STOP token.  We do this now because otherwise an
  # typing error in the command name would leave the input unsnarfed,
  # resulting in tons of error messages as that unsnarfed input also failed
  # syntax checks.  The tag can be uppercase letters or digits only, and
  # there can be no digits in the first three positions.
  #  elsif (/^(.*)\s+<<\s*([A-Z]{3}[A-Z0-9]*)$/) {
  elsif (/^(.*)\s+\<\<\s*([A-Z]{3}[A-Z0-9]*)$/) {

    # Trim the expression from the command line.
    $_ = $1;
    $tag = $2;
    $log->message(80, "info", "Parsing multiline argument, tag $tag, rest $_.");

    # We should scan through the remainder of the message looking for the
    # token.  If we don't find it, we know that something is bogus and we can
    # warn before eating all of the input.  Since it's possible (though
    # improbable) that an email address might end with something that looks
    # like a here document introducer, we need to do this.  It's also
    # possible to mistype the end    token in a way that the parser picks up
    # a whole additional command structure within the arglist.  So we should
    # warn (but not abort) if we see "^command\s+.* << [A-Z]+$" within the
    # arglist.

    # Since we can't yet seek and tell on $inputhandle, the best we can do
    # is go ahead and parse and if we notice that things are hosed, try not
    # to act on any bogus info we grab.  Eryq added seek and tell on
    # bodyhandles, so soon I'll be able to do this.

    # Grab input until see see the TAG or EOF.
    while (1) {
      $line = $inhandle->getline;

      # Did we run out of input?
      unless (defined $line) {
        $out .= $mj->format_error('missing_tag', 'GLOBAL', 
                                  'TAG' => $tag);
        return $out;
      }
      chomp $line;

      $log->message(90, "info", "grabbed line $line");

      # If a line ends in a single backslash, merge the following line.
      while ( ($line =~ /\\$/) && ($line !~ /\\\\$/) ) {
        $line =~ s/\\$/ /;
        $line .= $inhandle->getline;
        chomp $line;
      }
      # Change a trailing, escaped backslash to a simple backslash
      $line =~ s/\\\\$/\\/; 

      # Did we find the tag?
      if ($line eq $tag) {
        $out .= $mj->format_error('found_tag', 'GLOBAL', 'TAG' => $tag);
        last;
      }

      # XXX ? # Here warn if this looks like a command followed by another TAG.

      push @arglist, $line;

      # XXX ? # Here give some indication of the line that we snarfed.
    }
  }

  # Extract the command from the line
  $log->message(80, "info", "Extracting command from \"$_\"");
  ($command, $_) = /^(\S+)\s*(.*)$/;

  $log->message(81, "info", "Got command \"$command\", rest \"$_\"");

  return ($out, $command, $_, $attachhandle, @arglist);
}

=head2 add_deflist (line, deflist, reply_to)

=head2

This adds the default list to a command line if it is not already present.

=cut
sub add_deflist {
  my $mj        = shift;
  my $line      = shift;
  my $deflist   = shift;
  my $reply_to  = shift;
  my ($list, $tmp);

  # If no deflist, add nothing
  return $line unless $deflist;

  # If nothing on the line, return the deflist
  return $deflist unless $line;

  $line =~ /(\S+)(.*)/;
  $list = $1;
  $line = $2 || "";

  # XXX Possibly allow "list@host" and "list" to be equal?
  ($tmp) = $mj->valid_list($list, 1, 1);
  return "$list$line" if $tmp;

  return "$deflist $list$line";
}

use Mj::CommandProps qw(:function);
sub parse_args {
  my ($request, $args, $arglist, $attachh) = @_;
  my ($k, $arguments, @splitargs);
  my ($hereargs, @argnames, $argname);
  my $log = new Log::In 250;

  $hereargs  = function_prop($request->{'command'}, 'hereargs');
  $args =~ s/\s+$//;
  $request->{$hereargs} = [] if $hereargs;
  $arguments = function_prop($request->{'command'}, 'arguments');
  if (defined $arguments) {
    $arguments->{'split'} ||= '\s+';

    for (sort keys %$arguments) {
      next if ($_ eq 'split');
      next if (exists $arguments->{$_}->{'include'}
               and $request->{'mode'} !~ /$arguments->{$_}->{'include'}/);
      next if (exists $arguments->{$_}->{'exclude'}
               and $request->{'mode'} =~ /$arguments->{$_}->{'exclude'}/);
      push @argnames, $_;
    }

    @splitargs = split /$arguments->{'split'}/, $args, scalar @argnames;

    for $argname (@argnames) {
      $k = shift @splitargs;
      if ($arguments->{$argname}->{'type'} eq 'SCALAR') {
        $k = '' unless defined $k;
        $request->{$argname} = $k;
      }
      elsif ($arguments->{$argname}->{'type'} eq 'ARRAYELEM') {
        if (defined $k) {
          push @{$request->{$argname}}, $k;
        }
        else {
          $request->{$argname} = [];
        }
      }
      elsif ($arguments->{$argname}->{'type'} eq 'ARRAY') {
        unless (exists $request->{$argname}) {
          $request->{$argname} = [];
        }
        if ($k) {
          push @{$request->{$argname}}, split (/$arguments->{'split'}/, $k);
        }
      }
    }
  }
  # deal with hereargs
  if (defined $hereargs) {
    unless (exists $request->{$hereargs}) {
      $request->{$hereargs} = [];
    }
    if (scalar @$arglist) {
      push @{$request->{$hereargs}}, @$arglist;
    }
    elsif (ref ($attachh) =~ /^IO/) {
      # For iterated functions, pass the handle.
      if (function_prop($request->{'command'}, 'iter')) {
        $request->{$hereargs} = $attachh;
      }
      # Otherwise, read the contents into memory.
      else {
        while ($k = $attachh->getline) {
          chomp $k;
          push @{$request->{$hereargs}}, $k;
        }
      }
    }
  }
  1;
}

=head1 COPYRIGHT

Copyright (c) 1997, 1998, 2002 Jason Tibbitts for The Majordomo Development
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
### End: ***

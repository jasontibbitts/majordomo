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
use Mj::Format;
use Mj::CommandProps qw(:command :function);
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
sub parse_entity {
  my $mj        = shift;
  my %args      = @_;
  my $entity    = $args{'entity'};

  $args{'title'} ||= 'toplevel';

  my (@entities, @parts, @attachments, @ents, $body, $i, $infh, $name,
      $outfh, $type, $ok, $count);

  $::log->in(30, undef, "info", "Parsing entity $args{'title'}");
  @parts = $entity->parts;
  @entities = ();

  if (@parts) {
    # Loop over the parts, looking for one that has real commands in it.
    # We stop parsing when we find one with real commands and assume that
    # any other parts were attachments used as data for the commands.
    $count=0;
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
    return (0, @entities);
  }
  # We've arrived at a single part whch doesn't contain others.
  $type = $entity->head->mime_type;
  if ($type !~ m!^text(/plain)?$!i) {
    # We have something other than a plain text part
    push @entities, build MIME::Entity
      (
       Description => "Ignored part.",
       Top         => 0,
       Data        => ["Ignoring part of type $type.\n"]
      );
    $ok = 0;
  }
  else {
    # We have a plain text part; parse it.
    $body = $entity->bodyhandle;
    $infh = $body->open("r") or
      $::log->abort("Hosed! Couldn't open body part, $!");

    # Open handles for all of the attachments to this part
    for $i (@{$args{'parts'}}) {
      # Make sure we have a single part entity
      if (defined($i->is_multipart) && $i->is_multipart == 0) {
        push @attachments, $i->bodyhandle->open("r");
      }
    }

    # Open a file to stuff the output in
    $name = "$args{'tmpdir'}/mje." . Majordomo::unique() . ".out";
    $outfh = new IO::File "> $name" or
      $::log->abort("Hosed! Couldn't open output file $name, $!");

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
    $outfh->close;
    for $i (@attachments) {
      $i->close;
    }

    push @entities, build MIME::Entity(
				       Path        => $name,
				       Filename    => undef,
				       Description => "Results from $args{'title'}",
				       Top         => 0,
				      );

    # We could also add an entity containing the original message.  We could
    # also do a separate entity for each command, or for those which produce
    # a large amount of output.
  }
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
sub parse_part {
  my $mj         = shift;
  my %args       = @_;

#use Data::Dumper;
#warn Dumper $mj;
#warn Dumper $args{'mj'};

  my $inhandle    = $args{'infh'};
  my $outhandle   = $args{'outfh'};
  my $title       = $args{'title'};
  my $interface   = $args{'interface'};
  my $attachments = $args{'attachments'};

  my $log         = new Log::In 50, "$interface, $title";
  my (@arglist, @help, $action, $cmdargs, $attachhandle, $command, $count,
      $ent, $fail_count, $function, $garbage, $list, $mode, $name,
      $ok, $ok_count, $out, $outfh, $password, $pend_count, $replacement,
      $sigsep, $tlist, $true_command, $unk_count, $user);

  $count = $ok_count = $pend_count = $fail_count = $unk_count = $garbage = 0;
  $user = $args{'reply_to'};
  $sigsep = $mj->global_config_get(undef, undef, 'signature_separator');

 CMDLINE:
  while (defined($_ = $inhandle->getline)) {

    # Skip comments
    next if /^\s*\#/;

    # Skip blank lines
    next if /^\s*$/;

    # Stop parsing at a signature separator. XXX It is of dubious legality
    # to call a function in the Majordomo namespace from here.  We know the
    # module has been loaded because we have a valid Majordomo object, but
    # still, this is client-side.
    if (Majordomo::_re_match($sigsep, $_)) {
      print $outhandle ">>>> $_";
      print $outhandle "Stopping at signature separator.\n\n";
      last CMDLINE;
    }

    # request is a reference to a hash that is used
    # to marshal arguments for a call to majordomo core
    # functions via dispatch().
    my ($request) = {};

    # We have something that looks like a command.  Process it and any here
    # arguments that may follow.
    ($out, $command, $cmdargs, $attachhandle, @arglist) =
      parse_line($mj, $inhandle, $outhandle, $attachments, $_);

    # If we hit EOF while processing the command line, we ignore it and let
    # the loop run its course.
    unless (defined $command) {
      next CMDLINE;
    }

    # Check for legality of command
    if ($command eq '') {
      print $outhandle $out;
      print $outhandle "Found empty command!\n";
      next CMDLINE;
    }

    # Pull off a command mode
    ($command, $mode) = $command =~ /([^=-]+)[=-]?(.*)/;
    next CMDLINE unless $command;
    $mode = '' unless defined $mode;

    $true_command = command_legal($command);
    $log->message(50, "info", "$command aliased to $true_command.")
      if defined $true_command and $command ne $true_command;
    unless (defined($true_command) &&
            (command_prop($true_command, $mj->{interface}) ||
            (command_prop($true_command, "$mj->{interface}_parsed"))))
      {
        unless ($garbage) {
          print $outhandle $out;
          print $outhandle "**** Illegal command!\n\n";
        }
        $garbage++;
        next CMDLINE;
      }

    # The command is pretty close to legal; go ahead and print the line and
    # a message if we skipped any garbage
    if ($garbage > 1) {
      printf $outhandle ("**** Skipped %d additional line%s of unrecognized text.\n\n",
                         $garbage-1, $garbage==1?"":"s")
    }
    $garbage = 0;
    print $outhandle $out;

    undef $password;

    # Deal with "approve" command; we do it here so that it can be aliased
    # by the above call to command_legal.
    if ($true_command eq "approve") {
      ($password, $command, $cmdargs) = split(" ", $cmdargs, 3);

      # Pull off a command mode
      ($command, $mode) = $command =~ /([^=-]+)[=-]?(.*)/;
      $mode = '' unless defined $mode;

      $true_command = command_legal($command);
      $log->message(50, "info", "$command aliased to $true_command.")
        if defined $true_command and $command ne $true_command;
      unless (defined($true_command) &&
              command_prop($true_command, $mj->{interface}))
        {
          print $outhandle "Illegal command!\n";
          next CMDLINE;
        }
    }

    # Deal with "end" command; again, this can be aliased
    if ($true_command eq "end") {
      print $outhandle "End of commands.\n";
      last CMDLINE;
    }

    # If necessary, we extract the list name from the arguments, accounting
    # for a possible default list in effect, and verify its validity
    if (command_prop($true_command, "list")) {
      $cmdargs = add_deflist($mj, $cmdargs, $args{'deflist'}, $args{'reply_to'});
      ($tlist, $cmdargs) = split(" ", $cmdargs, 2);
      unless (defined($tlist) && length($tlist)) {
        print $outhandle "A list name is required.\n";
        next CMDLINE;
      }
      unless (defined
              ($list = $mj->valid_list
               ($tlist,
                command_prop($true_command, 'all'),
                command_prop($true_command, 'global'))))
        {
          print $outhandle "Illegal list \"$tlist\".\n";
          next CMDLINE;
        }
    }
    # Bomb if given here args or an attachment when not supposed to
    if (command_prop($true_command, "nohereargs") &&
        (@arglist || $attachhandle))
      {
        print $outhandle "Command $command doesn't take arguments with << TAG or <@.\n";
        next CMDLINE;
      }

    # Warn if command takes no args
    if (command_prop($true_command, "noargs") &&
	($cmdargs || @arglist || $attachhandle))
      {
        print $outhandle "Command $command will ignore any arguments.\n";
      }

    # Warn of obsolete usage
    if ($replacement = command_prop($true_command, "obsolete")) {
      print $outhandle "Command $command is obsolete; use $replacement instead.\n\n";
      next CMDLINE;
    }

    # We have a legal command.  Now we actually do something.
    $count++;

    # First, handle the "default" command internally.
    if ($true_command eq 'default') {
      $ok_count++;
      ($action, $cmdargs) = split(" ", $cmdargs, 2);
      if ($action eq 'list') {
	$args{'deflist'} = $cmdargs;
	print $outhandle "Default list set to \"$cmdargs\".\n";
      }
      elsif ($action =~ /^password|passwd$/) {
	$args{'password'} = $cmdargs;
	print $outhandle "Default password set to \"$args{'password'}\".\n";
      }
      elsif ($action eq 'user') {
        if ($cmdargs) {
          $user = $cmdargs;
        }
        else {
          $user = $args{'reply_to'};
        }
	    print $outhandle "User set to \"$user\".\n";
      }
      else {
        print $outhandle "Illegal action \"$action\" for default.\n";
        $ok_count--;
        $fail_count++;
      }
    }
    else {
      # Handle default arguments for commands
      if ($true_command =~ /accept|reject/) {
        unless ($cmdargs =~ /[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}/) {
          $cmdargs = "$args{'token'} $cmdargs";
        }
      }
      elsif ($true_command =~ /newfaq/) {
        $cmdargs = "/faq Frequently Asked Questions";
        $true_command = "put";
      }
      elsif ($true_command =~ /newinfo/) {
        $cmdargs = "/info List Information";
        $true_command = "put";
      }
      elsif ($true_command =~ /newintro/) {
        $cmdargs = "/intro List Introductory Information";
        $true_command = "put";
      }

      $cmdargs ||= '';

      # initialize basic information
      $request->{'command'} = $true_command;
      $request->{'user'} = $user;
      $request->{'password'} = $password || $args{'password'};
      $request->{'mode'} = $mode;
      $request->{'list'} = $list;
      # deal with arguments
      parse_args($request, $cmdargs, \@arglist, $attachhandle);

      # XXX if there are no arguments, read attachment from attachhandle
      no strict 'refs';
      if (function_prop($true_command, 'iter')) {
        $request->{'command'} .= '_start';
      }
      my $result = $mj->dispatch($request);

      # If a new identity has been assumed, send the output
      # of the command to the new address.
      if ($user ne $args{'reply_to'}) {
        my $tmpdir = $mj->_global_config_get('tmpdir');
        $name = "$tmpdir/mje." . Majordomo::unique() . ".out";
        $outfh = new IO::File "> $name" or
          $::log->abort("Hosed! Couldn't open output file $name, $!");
      }
      else {
        $outfh = $outhandle;
      }

      ($ok, @help) =
        &{"Mj::Format::$true_command"}($mj, $outfh, $outfh,
                                       'text', $request, $result);

      # Mail the result if posing.
      if ($user ne $args{'reply_to'}) {
        $outfh->close;
        my $sender = $mj->_global_config_get('sender');
        $ent = build MIME::Entity
          (
           From     => $args{'reply_to'},
           Path     => $name,
           To       => $user,
           'Reply-To' => $sender,
           Subject  => "Results from Majordomo Command \"$true_command\"",
           'MIME-Version' => "1.0",
          );
        $mj->mail_entity($sender, $ent, $user) if $ent;
        $ent->purge if $ent;
        unlink $name;
        print $outhandle $ok>0? "Succeeded" : $ok<0 ? "Stalled" : "Failed";
        print $outhandle ".  The results were mailed to $user.\n";
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
    print $outhandle "\n";
  }
  printf $outhandle "%s valid command%s processed",
    ("$count" || "No"), $count==1?"":"s";
  if ($count == 0) {
    # Nothing
  }
  elsif ($count == 1) {
    if ($fail_count == 1) {
      printf $outhandle "; it failed",
    }
    elsif ($pend_count == 1) {
      printf $outhandle "; it is pending",
    }
    elsif ($ok_count == 1) {
      printf $outhandle "; it was successful";
    }
    elsif ($unk_count == 1) {
      printf $outhandle "; its status is indeterminate";
    }
    else { # Huh?
      printf $outhandle "; we can't count";
    }
  }
  # We have a number of processed commands; some may be ok, pending,
  # mixed, or failed
  else {
    # Do $ok_count
    if ($ok_count == 0) {
      print $outhandle "; none were successful";
    }
    elsif ($ok_count == 1) {
      print $outhandle "; 1 was successful";
    }
    elsif ($ok_count == $count) {
      print $outhandle "; all were successful";
    }
    else {
      print $outhandle "; $ok_count were successful";
    }
    # Do $fail_count
    if ($fail_count == 0) {
      # Nothing
    }
    elsif ($fail_count == $count) {
      print $outhandle "; all failed";
    }
    else {
      print $outhandle "; $fail_count failed";
    }
    # Do $pend_count
    if ($pend_count == 0) {
      # Nothing
    }
    elsif ($pend_count == 1) {
      print $outhandle "; 1 is pending";
    }
    elsif ($pend_count == $count) {
      print $outhandle "; all are pending";
    }
    else {
      print $outhandle "; $pend_count are pending";
    }
    # Do $unk_count
    if ($unk_count == 0) {
      # Nothing
    }
    elsif ($unk_count == 1) {
      print $outhandle "; 1 was mixed";
    }
    elsif ($unk_count == $count) {
      print $outhandle "; all were mixed";
    }
    else {
      print $outhandle "; $unk_count were mixed";
    }
  }
  print $outhandle ".\n";
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

  # Merge lines ending in backslashes
  chomp;
  while (/\\\s*$/) {
    s/\\\s*$/ /;
    $_ .= $inhandle->getline;
    chomp;
  }

  # Trim leading and trailing whitespace and remove tabs
  s/^\s*(.*?)\s*$/$1/;
  s/\t/ /g;

  # Echo the line
  $out .= ">>>> $_\n";

  # Process an attachment with <@ num, where num is the attachment num.
  # <@1 would pull from the attachment immediately following this one.
  if (/^(.*)\s+<@\s*(\d*)$/) {
    $_    = $1;
    $used = ($2 || 1) -1;
    if ($used > @{$attachments}) {
      $out .= "**** Illegal attachment specified!\n";
      return $out;
    }
    $log->message(80, "info", "Parsing attachment argument, #$used, rest $_.");
    $attachhandle = $attachments->[$used];
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
        $out .= "Reached EOF without seeing tag $tag!\n";
        return $out;
      }
      chomp $line;

      $log->message(90, "info", "grabbed line $line");

      # Process backslashes
      while ($line =~ /\\\s*$/) {
        $line =~ s/\\\s*$/ /;
        $line .= $inhandle->getline;
        chomp $line;
      }

      # Did we find the tag?
      if ($line eq $tag) {
        $out .= ">>>> Found tag $tag.\n";
        last;
      }

      # process leading dashes in here documents
      # dash space         --> remove dash
      # doubled up         --> remove one dash
      # single dash        --> empty line
      # dash anything else --> don't change
      $line =~ s/^-([\s-]|$)/$1/;

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
  my $list;

  # If no deflist, add nothing
  return $line unless $deflist;

  # If nothing on the line, return the deflist
  return $deflist unless $line;

  $line =~ /(\S+)(.*)/;
  $list = $1;
  $line = $2 || "";

  return "$deflist $list$line" unless
    $mj->legal_list_name($list);


  # XXX Possibly allow "list@host" and "list" to be equal?
  if (grep {$list eq $_}
      $mj->get_all_lists($reply_to, undef, undef, "email"))
    {
      return "$list$line";
    }

  return "$deflist $list$line";
}

sub parse_args {
  my ($request, $args, $arglist, $attachh) = @_;
  my ($variable, $varcount, $useopts, $om, $k, $arguments, @splitargs);
  my ($hereargs);

  $hereargs  = function_prop($request->{'command'}, 'hereargs');
  $request->{$hereargs} = [] if $hereargs;
  $arguments = function_prop($request->{'command'}, 'arguments');
  if (defined $arguments) {
    $arguments->{'split'} ||= ' ';
    $arguments->{'optmode'} ||= '';
    # account for "optmode" and "split" when counting variables
    $varcount = scalar (keys %$arguments) - 2;
    $useopts = 1;
    my $om = $arguments->{'optmode'};

    # Do not use optional variables unless required
    if ($arguments->{'optmode'} and ($request->{'mode'} !~ /$om/)) {
      $useopts = 0;
      for $variable (keys %$arguments) {
        $varcount--
          if ($arguments->{$variable} =~ /OPT/);
      }
    }

    @splitargs = ();
    if ($varcount > 1) {
      @splitargs = split /$arguments->{'split'}/, $args, $varcount;
    }
    else {
      @splitargs = ($args);
    }
    $k = 0;
    for $variable (sort keys %$arguments) {
      next if ($variable eq 'optmode' or $variable eq 'split');
      next if (!$useopts and ($arguments->{$variable} =~ /OPT/));
      last unless defined ($splitargs[$k]);
      if ($arguments->{$variable} =~ /SCALAR/) {
        $request->{$variable} = $splitargs[$k];
      }
      elsif ($arguments->{$variable} eq 'ARRAYELEM') {
        $request->{$variable} = [$splitargs[$k]];
      }
      elsif ($arguments->{$variable} eq 'ARRAY') {
        unless (exists $request->{$variable}) {
          $request->{$variable} = [];
        }
        push @{$request->{$variable}}, split (" ", $splitargs[$k]);
      }
      $k++;
    }
  }
  # deal with hereargs
  if (defined $hereargs) {
    unless (exists $request->{$hereargs}) {
      $request->{$hereargs} = [];
    }
    if (@$arglist) {
      push @{$request->{$hereargs}}, @$arglist;
    }
    elsif (ref $attachh eq 'IO::File' or ref $attachh eq 'IO::Handle') {
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

Copyright (c) 1997, 1998 Jason Tibbitts for The Majordomo Development
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

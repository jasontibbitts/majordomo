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
use Mj::TextOutput;
require "parser_data.pl";
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
  my $title     = shift || "toplevel";
  my $interface = shift;
  my $tmpdir    = shift;
  my $extra     = shift;
  my $entity    = shift;
  my (@entities, @parts, @attachments, @ents,
      $body, $i, $infh, $name, $outfh, $type, $ok, $count);
  
  $::log->in(30, undef, "info", "Parsing entity $title");
  @parts = $entity->parts;
  @entities = ();

  if (@parts) {
    # Loop over the parts, looking for one that has real commands in it.
    # We stop parsing when we find one with real commands and assume that
    # any other parts were attachments used as data for the commands.
    $count=0;
    while (@parts) {
      ($ok, @ents) =
	parse_entity($mj, "part $count of $title", $interface, $tmpdir,
		     $extra, @parts);
      push @entities, @ents;
      if ($ok) {
	$::log->message(30, "info", "Parsed commands; not parsing attachments.");
	last;
      }
      $count++;
      shift @parts;
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
  }
  else {
    # We have a plain text part; parse it.
    $body = $entity->bodyhandle;
    $infh = $body->open("r") ||
      $::log->abort("Hosed! Couldn't open body part, $!");
    
    # Open handles for all of the attachments to this part
    while (@_) {
      push @attachments, shift->bodyhandle->open("r");
    }
    
    # Open a file to stuff the output in
    $name = "$tmpdir/mje." . $mj->unique . ".out";
    $outfh = new IO::File "> $name" ||
      $::log->abort("Hosed! Couldn't open output file $name, $!");
    
    $ok = parse_part($mj, $infh, $outfh, \@attachments,
		     $title, $interface, $extra);
    $infh->close;
    $outfh->close;
    for $i (@attachments) {
      $i->close;
    }
    
    push @entities, build MIME::Entity(
				       Path        => $name,
				       Filename    => undef,
				       Description => "Results from $title",
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
  my $mj          = shift;
  my $inhandle    = shift;
  my $outhandle   = shift;
  my $attachments = shift;
  my $title       = shift;
  my $interface   = shift;
  my $extra       = shift;
  my $log         = new Log::In 50, "$interface, $title";
  my (@arglist, @help, $action, $args, $attachhandle, $command, $count,
      $function, $garbage, $list, $mode, $ok, $ok_count, $out, $password,
      $replacement, $tlist, $true_command);

  $count    = 0;
  $ok_count = 0;
  $garbage  = 0;

 CMDLINE:
  while (defined($_ = $inhandle->getline)) {
    
    # Skip comments
    next if /^\s*\#/;
    
    # Skip blank lines
    next if /^\s*$/;
    
    # Stop parsing at a signature separator.  This has been relaxed to work
    # like Mj1 works, but it may be wise to make it configurable.
    # if (/^-- $/) {
    if (/^-/) {
      print $outhandle ">>>> $_";
      print $outhandle "Stopping at signature separator.\n\n";
      last CMDLINE;
    }

    # We have something that looks like a command.  Process it and any here
    # arguments that may follow.
    ($out, $command, $args, $attachhandle, @arglist) =
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
    ($command, $mode) = split(/\s*=\s*/, $command);
    $mode = '' unless defined $mode;
    
    $true_command = command_legal($command);
    $log->message(50, "info", "$command aliased to $true_command.")
      if defined $true_command and $command ne $true_command;
    unless (defined($true_command) &&
	    (command_property($true_command, $interface) ||
	    (command_property($true_command, "${interface}_parsed"))))
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
      ($password, $command, $args) = split(" ", $args, 3);

      # Pull off a command mode
      ($command, $mode) = split(/\s*=\s*/, $command);
      $mode = '' unless defined $mode;

      $true_command = command_legal($command);
      $log->message(50, "info", "$command aliased to $true_command.")
	if defined $true_command and $command ne $true_command;
      unless (defined($true_command) &&
	      command_property($true_command, $interface))
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
    if (command_property($true_command, "list")) {
      $args = add_deflist($mj, $args, $extra->{'deflist'},
			  $interface, $extra->{'reply_to'});
      ($tlist, $args) = split(" ", $args, 2);
      unless (defined ($list = $mj->valid_list($tlist,
				     command_property($true_command, 'all'),
				     command_property($true_command, 'global'))))
	{
	  print $outhandle "Illegal list \"$tlist\".\n";
	  next CMDLINE;
	}
    }
    # Bomb if given here args or an attachment when not supposed to
    if (command_property($true_command, "nohereargs") &&
	(@arglist || $attachhandle))
      {
	print $outhandle "Command $command doesn't take arguments with << TAG or <@.\n";
	next CMDLINE;
      }
      
    # Warn if command takes no args
    if (command_property($true_command, "noargs") &&
	($args || @arglist || $attachhandle))
      {
	print $outhandle "Command $command will ignore any arguments.\n";
      }

    # Warn of obsolete usage
    if ($replacement = command_property($true_command, "obsolete")) {
      print $outhandle "Command $command is obsolete; use $replacement instead.\n\n";
      next CMDLINE;
    }

    # We have a legal command.  Now we actually do something.
    $count++;

    # First, handle the "default" command internally.
    if ($true_command eq 'default') {
      $ok_count++;
      ($action, $args) = split(" ", $args, 2);
      if ($action eq 'list') {
	$extra->{'deflist'} = $args;
	print $outhandle "Default list set to \"$args\".\n";
      }
      elsif ($action =~ /^password|passwd$/) {
	$extra->{'password'} = $args;
	print $outhandle "Default password set to \"$extra->{'password'}\".\n";
      }
      else {
	print $outhandle "Illegal action \"$action\" for default.\n";
	$count--;
	$ok_count--;
      }
    }
    else {
      # Handle default arguments for commands
      if ($true_command =~ /accept|reject/) {
	$args ||= $extra->{'token'};
      }
      $args ||= '';
      no strict 'refs';
      ($ok, @help) =
	&{"Mj::TextOutput::$true_command"}($mj, $command,
					   $extra->{'reply_to'},
					   $password || $extra->{'password'},
					   undef, $interface,
					   $attachhandle, $outhandle,
					   $mode, $list, $args, @arglist);
      $ok_count++ if $ok;
    }
    print $outhandle "\n";
  }
  printf $outhandle "%s valid command%s processed",
    ("$count" || "No"), $count==1?"":"s";
  if ($count == 0) {
    # Nothing
  }
  elsif ($count == 1) {
    printf $outhandle "; it %s successful",
      $ok_count == 1 ? "was" : "was not";
  }
  elsif ($ok_count == 1) {
    print $outhandle "; 1 was successful";
  }
  elsif ($ok_count == 0) {
    print $outhandle "; none were successful";
  }
  else {
    print $outhandle "; $ok_count were successful";
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
      
      # Did we find the tag?
      if ($line eq $tag) {
	$out .= ">>>> Found tag $tag.\n";
	last;
      }
      
      # Here warn if this looks like a command followed by another TAG.
      
      push @arglist, $line;
      
      # Here give some indication of the line that we snarfed.
    }
  }
  
  # Extract the command from the line
  $log->message(80, "info", "Extracting command from \"$_\"");
  ($command, $_) = /^(\S+)\s*(.*)$/;
  $log->message(81, "info", "Got command \"$command\", rest \"$_\"");
  
  return ($out, $command, $_, $attachhandle, @arglist);
}

=head2 add_deflist (line, deflist, interface, reply_to)

=head2

This adds the default list to a command line if it is not already present.

=cut
sub add_deflist {
  my $mj        = shift;
  my $line      = shift;
  my $deflist   = shift;
  my $interface = shift;
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

# Nipped from MakeMaker.
sub prompt ($;$) {
  sep();
  my($mess,$def)=@_;
  my $ISA_TTY = -t STDIN && -t STDOUT ;
  Carp::confess("prompt function called without an argument") unless defined $mess;
  my $dispdef = defined $def ? "[$def] " : " ";
  $def = defined $def ? $def : "";
  my $ans;
  if ($ISA_TTY) {
    local $|=1;
    print "$mess $dispdef->";
    chomp($ans = <STDIN>);
  }
  return $ans || $def;
}

sub get_str {
  return prompt(shift, shift);
}

sub get_enum {
  my $msg  = shift;
  my $def  = shift;
  my $vals = shift;
  my $ans;
  while (1) {
    $ans = get_str($msg, $def);
    if (grep {$ans eq $_} @$vals) {
      return $ans;
    }
    $msg = "Allowed values are:\n";
    for my $i (@$vals) {
      $msg .= "  $i\n";
    }
  }
}

# Query for the existence of a file.
sub get_file {
  my ($msg, $def, $exist, $exe, $path, $force) = @_;
  my ($file);
 OUTER:
  while (1) {
    my $ans = prompt($msg, $def);
    $file = ($ans =~ /(\S*)/)[0];

    # We always require some input, else we wouldn't be asking
    unless (length $file) {
      $msg = "You must enter something.\n";
      next;
    }

    # If existence isn't required, we can exit as soon as we have anything
    # at all
    last if !$exist;

    # If it's executable, we're done.  If it simply exists and we don't
    # need executability, we're also done.
    last if -x $file;
    last if -f $file && !$exe;

    # Now we can run over the path
    if ($path) {
      for my $i (split(':', $ENV{PATH})) {
	last OUTER if -x "$i/$file";
      }
    }

    # So it didn't exist or wasn't executable.  Complain a bit.  If $force
    # is true, we require that the file be there and so we make another
    # round.  Otherwise we can just make sure that the user really intended
    # to type what they typed.
    if ($force) {
      if ($exe) {
        $msg = "You must enter the name of an existing executable file.\n";
        next;
      }
      $msg = "You must enter the name of an existing file.\n";
      next;
    }
    if ($exe) {
      last if get_bool("$file does not exist or is not executable; use anyway?");
    }
    else {
      last if get_bool("$file does not exist; use anyway?");
    }
  }
  $file;
}

sub get_dir {
  my ($msg, $def, $empty) = @_;
  my ($dir);
  while (1) {
    my $ans = prompt($msg, $def);
    $dir = ($ans =~ /(\S*)/)[0];
    last if !length $dir && $empty;
    next unless length $dir;
    unless ($dir =~ m!^/!) {
      $msg .= "\nYou must enter a complete pathname, beginning with '/'.";
      next;
    }
    last if -d $dir;
    last if get_bool("$dir does not exist; use anyway?");
  }
  $dir;
}

sub get_uid {
  my ($msg, $def) = @_;
  my ($uid);

  while (1) {
    my $ans = prompt($msg, $def);
    $uid = ($ans =~ /(\S*)/)[0];
    unless (length $uid) {
      $msg .= "\nYou must enter a real username or a numeric ID.\n";
      next;
    }
    last if getpwnam $uid ;
    last if $uid =~ /\d+/ && ($uid = getpwuid($uid));
    $msg .= "\n$uid can't be interpreted, please enter a valid user number.\n";
  }
  $uid;
}

sub get_gid {
  my ($msg, $def) = @_;
  my ($gid);

  while (1) {
    my $ans = prompt($msg, $def);
    $gid = ($ans =~ /(\S*)/)[0];
    unless (length $gid) {
      $msg .= "\nYou must enter a real groupname or a numeric ID.\n";
      next;
    }
    last if getgrnam $gid;
    last if $gid =~ /\d+/ && ($gid = getgrgid($gid));
    $msg .= "\n$gid can't be interpreted, please enter a valid group number.\n";
  }
  $gid;
}

sub get_bool {
  my ($msg, $def) = @_;
  chomp $msg;
  my $val = prompt($msg, $def ? "yes" : "no");
  $val =~ /^y/i ? 1:0;
}

sub get_list {
  my ($msg, $def, $empty) = @_;
  my ($elem, $list);
  sep();
  local $nosep = 1;
  $list = [];
  print $msg;

  while (1) {
    my $ans = prompt("", (@{$def} ? shift @{$def} : undef));
    $elem = ($ans =~ /(\S*)/)[0];
    unless (length $elem) {
      last if $empty;
      last if @{$list};
      print "Empty list not allowed!\n";
      next;
    }
    push @{$list}, $elem;
  }
  $list;
}

sub sep {
  return if $nosep;
  if ($sepclear) {
    print `clear`;
    return;
  }
  print "\n", '-'x76, "\n";
}

=head1 COPYRIGHT

Copyright (c) 1999 Jason Tibbitts for The Majordomo Development
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
### cperl-label-offset:-1 ***
### indent-tabs-mode: nil ***
### End: ***

# Nipped from MakeMaker.
require Carp;
use vars (qw($nosep $sepclear));
use lib "./lib";
use Mj::Addr;

sub prompt ($;$) {
  sep();
  my ($mess, $def) = @_;
  my $ISA_TTY = -t STDIN && (-t STDOUT || !(-f STDOUT || -c STDOUT));

  Carp::confess("prompt function called without an argument") 
    unless defined $mess;

  my $dispdef = defined $def ? "[$def] " : " ";
  $def = defined $def ? $def : "";

  my $ans;
  local $|=1;
  print "$mess $dispdef->";
  $ans = <STDIN>;
  chomp($ans) if (defined $ans);
  $ans ||= "";
  if (! $ISA_TTY) {
    # show the output if we're reading from a response file
    print $ans, "\n";
  }
  return $ans if(length $ans);
  return $def;
}

sub get_str {
  return prompt(shift, shift);
}

sub get_addr {
  my $msg = shift;
  my $def = shift;
  my $dom = shift;
  my $strict = shift;
  my ($addr, $ans, $full, $loc, $mess, $ok);

  while (1) {
    $ans = $full = get_str($msg, $def);
    unless ($full =~ /\@/) {
      if (length $dom) {
        $full .= "\@$dom";
      }
    }

    $addr = new Mj::Addr $full, 'strict_domain_check' => $strict;
    if (! defined $addr) {
      $mess = retr_error('undefined_address', $lang);
      $msg = retr_msg('invalid_address', $lang, 'ADDRESS' => $ans,
                      'ERROR' => $mess, 'LOCATION' => $loc);
    }
    else {
      ($ok, $mess, $loc) = $addr->valid;
      if ($ok) {
        return $ans;
      }
      else {
        $mess = retr_error($mess, $lang);
        $msg = retr_msg('invalid_address', $lang, 'ADDRESS' => $ans,
                        'ERROR' => $mess, 'LOCATION' => $loc);
      }
    }
  }
}

sub get_enum {
  my $msg  = shift;
  my $def  = shift;
  my $vals = shift;
  my (@tmp, $ans);

  while (1) {
    $ans = get_str($msg, $def);
    if (grep { $ans eq $_ } @$vals) {
      return $ans;
    }

    # Allow an abbreviation if it is unambiguous.
    @tmp = grep { $_ =~ /^$ans/i } @$vals;
    if (scalar @tmp == 1) {
      return $tmp[0];
    }

    local $sepclear = 0;
    local $nosep = 1;
    $msg = retr_msg('enum_values', $lang, 'VALUE' => $ans);
    for my $i (@$vals) {
      $msg .= "  $i\n";
    }
    $msg .= "\n";
  }
}

# Query for the existence of a file.
sub get_file {
  my ($msg, $def, $exist, $exe, $path, $force) = @_;
  my ($file, $loc);
 OUTER:
  while (1) {
    my $ans = prompt($msg, $def);
    $file = ($ans =~ /(\S*)/)[0];
    $loc = $file;

    # We always require some input, else we wouldn't be asking
    unless (length $file) {
      $msg = retr_msg('no_value', $lang);
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
	if (-x "$i/$file") {
          $loc = "$i/$file";
          last OUTER;
        } 
      }
    }

    # So it didn't exist or wasn't executable.  Complain a bit.  If $force
    # is true, we require that the file be there and so we make another
    # round.  Otherwise we can just make sure that the user really intended
    # to type what they typed.
    if ($force) {
      if ($exe and -f $loc) {
        $msg = retr_msg('not_executable', $lang, 'FILE' => $file);
        next;
      }
      $msg = retr_msg('nonexistent_file', $lang, 'FILE' => $file);
      next;
    }
    if ($exe and -f $loc) {
      last if get_bool(retr_msg('use_unexecutable', $lang, 'FILE' => $file));
    }
    else {
      last if get_bool(retr_msg('use_nonexistent', $lang, 'PATH' => $file));
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
      $msg = retr_msg('absolute_path', $lang, 'PATH' => $dir);
      next;
    }
    last if -d $dir;
    last if get_bool(retr_msg('use_nonexistent', $lang, 'PATH' => $dir));
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
      $msg = retr_msg('no_value', $lang);
      next;
    }
    last if getpwnam $uid ;
    if ($uid =~ /\d+/) { 
      last if ($uid = getpwuid($uid));
    }
    $msg = retr_msg('invalid_uid', $lang, 'UID' => $ans);
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
      $msg = retr_msg('no_value', $lang);
      next;
    }
    last if getgrnam $gid;
    last if $gid =~ /\d+/ && ($gid = getgrgid($gid));
    $msg = retr_msg('invalid_gid', $lang, 'GID' => $ans);
  }
  $gid;
}

sub get_bool {
  my ($msg, $def) = @_;
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
      print retr_msg('no_value', $lang);
      next;
    }
    # Hack to test for valid domains
    if ($elem =~ /[^a-zA-Z0-9\.\-]/) {
      print retr_msg('invalid_domain', $lang, 'DOMAIN' => $elem);
      next;
    }
    push @{$list}, $elem;
  }
  $list;
}

sub get_passwd {
  my $msg  = shift;
  my $def  = shift;
  my $ans;

  while (1) {
    $ans = prompt($msg, $def);
    $ans =~ s/^\s+//;
    $ans =~ s/\s+$//;

    if ($ans =~ /[\s,]/) {
      $msg = retr_msg('invalid_password', $lang, 'PASSWORD' => $ans);
      next;
    }

    unless (length $ans) {
      $msg = retr_msg('no_value', $lang);
      next;
    }
    
    return $ans; 
  }
}

sub sep {
  return if $nosep;
  if ($sepclear) {
    print `clear`;
    return;
  }
  print "\n", '-'x76, "\n";
}

sub retr_msg {
  my $file = shift;
  my $lang = shift || 'en';
  my $text;

  $text = retr_file("setup/messages/$lang/$file", @_);
  unless (defined $text and length $text) {
    $text = retr_file("setup/messages/en/$file", @_);
  }

  return $text;
}

sub retr_error {
  my $file = shift;
  my $lang = shift || 'en';
  my $text;

  $text = retr_file("files/$lang/error/$file", @_);
  unless (defined $text and length $text) {
    $text = retr_file("files/en/error/$file", @_);
  }

  return $text;
}

use Symbol;
sub retr_file {
  my ($file, %subs) = @_;
  my ($fh, $line, $text, $var);
  $lang ||= 'en';

  unless (-f $file) {
    warn qq(File "$message" could not be located);
  }

  $fh = gensym();
  unless (open ($fh, "< $file")) {
    warn qq(File "$message" could not be opened: $!);
    return;
  }

  while ($line = <$fh>) {
    $text .= $line;
  }

  for $var (keys %subs) {
    $text =~ s/([^\\]|^)\$\Q$var\E(\b|$)/$1$subs{$var}/g;
  }

  chomp $text;
  return $text;
}
    
=head1 COPYRIGHT

Copyright (c) 1999, 2002 Jason Tibbitts for The Majordomo Development
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
### cperl-label-offset:-1 ***
### indent-tabs-mode: nil ***
### End: ***

=head1 NAME

Bf::Sender.pm - Functions for setting the envelope sender

=head1 DESCRIPTION

Collection of various functions for setting the envelope sender for various
kinds of mail.

=head1 SYNOPSIS

 use Bf::Sender;
 $sender=Bf::Sender::M_regular_sender(sender, tag, msg_num);
 $sender=Bf::Sender::M_probe_sender(sender, tag, msg_num, addr);
 my($ok, $host, $addr, $type, $timestamp, $state, $file, @lists) 
    = Bf::Sender::parse_to($to);

=cut

package Bf::Sender;
$VERSION = "2.1004";
use strict;

=head2 envelope sender format

Bouncefilter uses envelope sender addresses that are in one of the
following formats:

(1)  list-owner+$type\@whereami

(2)  list-owner+$type=$host=$user\@whereami

(3)  list-owner+$type=$abbrev\@whereami

(4)  bouncefilter+$type=$abbrev\@whereami

(5)  bouncefilter+$type=$host=$user\@whereami

where $type is one of the following:

    B           - mail sent to bouncefilter-owner (when this fails,
		  bounces are forwarded to postmaster).
    C           - request for confirmation of a token (when this fails,
		  might want to notify whoever triggered token generation)
    D           - debugging output
    E           - error notification sent to user
    L           - mail sent to the list-owners (when this fails, bounces are
		  forwarded to the bouncefilter-owner).
    M1, M2, ... - regular messages on a mailing list. After the 'M' comes a
                  string which uniquely identifies the message. This can be a
                  message number, or e.g. something like "1045-1053" in case
                  of a digest.
    P1, P2, ... - various probe levels. The meaning of the number is how
                  many successive probes have failed by the time that this
                  probe is sent.
    R           - reply to a message sent to Majordomo
    U           - unsubscription notification
    W           - new subscriber's 'welcome' documentation

and the other parameters are as follows:

    $host   - subscriber's hostname
    $user   - subscriber's username
    $abbrev - e-mail address abbreviated to 20 characters and made unique

When sending mail to a list, normally format (1) is used. During probes,
normally format (2) is used unless if this would cause the 'mailbox'
part of the sender to exceed the limit of 64 characters, in which case
format (3) is used.

=head2 USE OF THE STRING 'bouncefilter' RESERVED

If you're using this module in some software other than Bouncefilter or
Majordomo, please do not use the string 'bouncefilter' in the envelope
sender, but instead replace it with some other string of your choice, 
which should be of the form /^[a-z0-9]*$/.

=cut

#my($ok, $host, $addr, $type, $timestamp, $state, $file, @lists) 
#   = Bf::Sender::parse_to($to);
#Has side effect of adding list to @lists array in database if appropriate
sub parse_to {
  my $to=shift;

  $to =~ /(.*)\@(.*)/;
  my $left=$1;
  my $host=$2;
  my($addr,$list,$type);
  if (!$host) {
    $::log->message(5, "mail", "parse_to: no '\@' in $to");
    return 0;
  }
  if ($left=~/^([^\=\+]*)-owner\+([^\=]*)=([^\=]*)=([^\=]*)/i) {
    # format (3)
    $list=$1;
    $type=$2;
    $addr="$4\@$3";
  } elsif ($left=~/^([^\=\+]*)-owner\+([^\=]*)=([^\=]*)/i) {
    # format (2)
    $list=$1;
    $type=$2;
    $addr=lookup_abbrev($3);
  } elsif ($left=~/^([^\=\+]*)-owner\+([^\=]*)/i) {
    # format (1)
    return (1, $host, 0, $2, time(), 0, '-', $1);
  } elsif ($left=~/^[a-z0-9]*\+([^\=]*)=([^\=]*)=([^\=]*)/i) {
    # format (4)
    $type=$1;
    $addr="$3\@$2";
  } elsif ($left=~/^[a-z0-9]*\+([^\=]*)=([^\=]*)/i) {
    # format (5)
    $type=$1;
    $addr=lookup_abbrev($2);
  } else {
    $::log->message(5, "mail", "parse_to: cannot parse  $addr");
    return 0;
  }
  if (!$addr) {
    $::log->message(5, "mail", "parse_to: no such abbrev  $addr");
    return 0;
  }
  my $ho=$::Bf->host($host);
  my ($time, $status, $file, @lists)=$ho->bf($addr);
  if ($list && @lists) {
    my $i;
    foreach $i (@lists) {
      last if ($i eq $list);
    } continue {
      push @lists, $list;
      $ho->set_bf($addr,$time, $status, $file, @lists);
    }
    return(1, $host, $addr, $type, $time, $status, $file, @lists);
  }
  if (!$list) {
    $::log->message(5, "mail", "parse_to: no entry in %bf for  $addr");
    return 0;
  }
  return(1, $host, $addr, $type, time(), 0, '-', $list);
}

sub M_regular_sender ($$$) {
  my $sender=shift;
  my $tag=shift;
  my $msg_num=shift;

  return $sender unless defined $msg_num;

  $sender=~/([^@]*)(.*)/;
  return "$1${tag}M$msg_num$2";
}

sub M_probe_sender ($$$$) {
  my $sender=shift;
  my $tag=shift;
  my $msg_num=shift;
  my $addr=shift;

  # Trim any existing mailbox argument
  $sender =~ s/\Q$tag\E[^@]*//;

  $addr=~/(.*)\@(.*)/;
  my $info="${tag}M$msg_num=$2=$1";
  $sender=~/([^@]*)(.*)/;

  # We might have to shorten something here
  if (length($1)+length($info)>63) {
    $info="${tag}M$msg_num=".make_abbrev($addr);
  }

  return "$1$info$2";
}

sub any_probe_sender ($$$$) {
  my $sender=shift;
  my $tag=shift;
  my $type=shift;
  my $addr=shift;

  # Trim any existing mailbox argument
  $sender =~ s/\Q$tag\E[^@]*//;

  $addr=~/(.*)\@(.*)/;
  my $info="$tag$type=$2=$1";
  $sender=~/([^@]*)(.*)/;
  if (length($1)+length($info)>63) {
    $info="$tag$type=".make_abbrev($addr);
  }
  return "$1$info$2";
}

sub any_regular_sender ($$$) {
  my $sender=shift;
  my $tag=shift;
  my $type=shift;
  
  if ($sender=~'@') {
    $sender=~s/(?=\@)/$tag$type/;
  } else {
    $sender.="$tag$type";
  }
  return $sender;
}

sub make_abbrev ($) {
  my $address=shift;

  my $addr=lc $address;
  my $i="1";
  my $addr2;

  if (!%Bf::Sender::abbrev) {
    &open_abbrev_database;
  }
  $addr=substr($addr,0,20);
  $addr=~tr/A-Z/a-z/; # More robust across gateways
  $addr=~s/[^a-z0-9]/-/g;
  while($addr2=$Bf::Sender::abbrev{$addr}) {
    last if($addr2 eq $address);
    $i++;
    substr($addr,-length($i)-1)="-$i";
  }
  $Bf::Sender::abbrev{$addr}=$address;
  return $addr;
}

sub lookup_abbrev ($) {
  my $addr=shift;
  $addr=~tr/A-Z/a-z/;

  if (!%Bf::Sender::abbrev) {
    &open_abbrev_database;
  }
  return $Bf::Sender::abbrev{$addr};
}

sub open_abbrev_database {
  # XXX - More work needed here. This is currently a NO-OP under Mj2

  use Fcntl;
  my $dir=eval('&Bf::Config::DataDir');
  if ($dir) {
    require AnyDBM_File;
    tie(%Bf::Sender::abbrev, "AnyDBM_File", "$dir/abbrev.AnyDBM", 
	O_RDWR|O_CREAT, 0644);
  }
}

=head1 RECENT CHANGES

NB, 18-03-1998: - Mj2-compliant copyright notice
                - updated to use global Bouncefilter object ::Bf
                - runs under 'use strict' now
                - abbrev algorithm modified to allow inclusion of as many digits
                  as possible without risking non-uniqueness of abbrevs
                - uses a limit of 63 characters now, one lower than the limit
                  specified in RFC821, to allow for broken MTAs which don't
                  count correctly
NB, 17-03-1998: - made *_sender functions robust in the case where $sender does
                  not contain '@', which can only happen during error conditions

=head1 COPYRIGHT

    Copyright 1998 by Norbert Bollow for The Majordomo Development Group.
    All rights reserved.

    This program is free software; you can redistribute it and/or modify 
    it under the terms of the license detailed in the LICENSE file which 
    is included in the Majordomo2 distribution.

    This program is distributed ``AS IS'', in the hope that it will be
    useful, but WITHOUT ANY WARRANTY; without even the implied warranty
    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
    Majordomo2 LICENSE file for more detailed information.

=cut

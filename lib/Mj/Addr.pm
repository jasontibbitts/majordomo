=head1 NAME

Mj::Addr - address manipulation functions for Majordomo

=head1 SYNOPSIS

 $av = new Mj::Addr(%params)
 ($ok, $strip, $comment) = $av->validate($address);

=head1 DESCRIPTION

This is a small module for checking the validity of addresses and
separating the mailbox and the comment portions from them.  It is placed in
the form of a module so that various parameters can be set for all
validations without setting global variables.

=cut

package Mj::Addr;
use strict;
use vars qw(%top_level_domains);
use Mj::Log;

=head2 new

This allocates an address validator object.  This is made an object so that
certain configuration values can be assigned to it without using package
globals.

The following parameters can be set to either 0 or 1:

  allow_at_in_phrase         - Allow '@' in the 'phrase' part of addresses
                               like this:   ph@rase <user@example.com>
  allow_bang_paths           - Allow old-style UUCP electronic-mail 
                               addresses like this:  abcvax!defvax!user
  allow_comments_after_route - Allow (illegal) e-mail addresses like this:
                                 <user@example.com> comment
                               (the address is illegal because the comment
                               should be before the <user@example.com> 
                               part and not after it.)
  allow_ending_dot           - Allow a dot at the end of an e-mail address
                               e.g. like this:  user@example.com.
  limit_length               - Limit the length of 'user' and 'host' parts
                               of user@host e-mail addresses to 64 
                               characters each, as required by section 
                               4.5.3 of RFC821.
  require_fqdn               - Require fully qualified domain names.
  strict_domain_check        - Check for valid top-level domain and for 
                               correct syntax of domain-literals. 

  NOTE: Checking for a valid top-level domain is currently done by means of
        a table which is hard-coded at the end of this file, and which might
        possibly be outdated by the time you''re reading this.

Example:

  $av = new Mj::Addr
    (
     allow_at_in_phrase          => 0,
     allow_bang_paths            => 0,
     allow_comments_after_route  => 0,
     allow_ending_dot            => 0,
     limit_length                => 1,
     require_fqdn                => 1,
     strict_domain_check         => 1,
    );

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;
  my $self  = {@_};
  my $log = new Log::In 150;
  bless $self, $class;
  $self;
}

=head2 params

This sets the validator parameters.  For bootstrapping purposes these must
be settable separately from allocation.

=cut
sub params {
  my $self = shift;
  my %params = @_;
  my($key, $val);
  while (($key, $val) = each %params) {
    $self->{$key} = $val;
  }
}

=head2 validate

Intended to check an address for validity and report back problems in a way
that the user can understand.  This is hard to do.  This routine tries to
do a "good job" in that it catches most forms of bad addresses and doesn''t
trap anything that is legal.  Some configuration variables are provided to
control certain aspects of its behavior and to allow certain types of
illegal addresses that are commonly allowed.

It currently does not properly handle non-ASCII characters in comments and
hostnames, nor does it handle address groups and route addresses with more
than one host.

=cut

sub validate {
  my $self  = shift;
  local($_) = shift;
  my $log = new Log::In 150, $_;
  my (@comment, @phrase, @route, @words, $angle, $bang_path, $comment,
      $domain_literal, $i, $right_of_route, $lhs_length, $nest, $rhs_length,
      $on_rhs, $subdomain, $word);

  my $specials = q|()<>@,;:\".[]|;

  $::log->in(130, $_);
  
  # We'll be interpolating arrays into strings and we don't want any
  # spaces.
  $"=''; #";


  # Trim trailing whitespace; it hoses the algorithm
  s/\s+$//;
  
  if ($_ eq "") {
    $::log->out("failed");
    return (0, "Nothing at all in that address.\n");
  }

  # We split the address into "words" of either atoms, quoted strings,
  # domain literals or parenthesized comments.  In the process we have an
  # implicit check for balance.
  # During tokenization, the following arrays are maintained:
  #  @comment - holds parenthesized comments
  #  @route   - holds elements of a route address
  #  @phrase  - holds all elements outside of a route address
  #  @words   - holds all but parenthesized comments
  # Later a determination of which holds the correct information is made.

  while ($_ ne "") {
    $word = "";
    s/^\s+//;  # Trim leading whitespace
    
    # Handle (ugh) nested parenthesized comments.  Man, RFC822 sucks.
    # Nested comments???  We do this first because otherwise the
    # parentheses get parsed separately as specials.  (Pulling out the
    # comments whole makes things easier.)
    if (/^\(/) {
      $comment = "";
      $nest = 0;
      while (s/^(\(([^\\\(\)]|\\.)*)//) {
	$comment .= $1;
	$nest++;
	while ($nest && s/^(([^\\\(\)]|\\.)*\)\s*)//) {
	  $nest--;
	  $comment .= $1;
	}
      }
      
      # If we don't have enough closing parentheses, we're hosed
      if ($nest) {
	$::log->out("failed");
	return (0, "Unmatched parenthesis in $comment $_\n");
      }
      
      # Trim parentheses and trailing space from the comment
      $comment =~ s/^\(//;
      $comment =~ s/\)\s*$//;
      push @comment, $comment;
      push @phrase,  $comment;
      next;
    }
    
    # Quoted strings are words; this leaves the quotes on the word/atom
    # unless it's part of the phrase.  XXX req #3
    if (s/^(\"(([^\"\\]|\\.)*)\")//) {
      push @words,  $1;
      push @phrase, $2 if !$angle;
      push @route,  $1 if $angle;
      next;
    }

    # Domain literals are words, but are only legal on the right hand side
    # of a mailbox.
    if (s/^(\[([^\[\\]|\\.)*\])//) {
      push @words,  $1;
      push @phrase, $1 if $angle;
      push @route,  $1 if $angle;

      unless ($on_rhs) {
	$::log->out("failed");
	return (0, "Domain literals (words in square brackets) are only permitted on
the right hand side of an address: $1 $_
Did you mistakenly enclose the entire address in square brackets?
");
      }
      unless ($words[-2] && $words[-2] =~ /^[.@]/) {
	$::log->out("failed");
	return (0, "Domain literals (words in square brackets) are only permitted after
a '.' or a '\@': $words[-2] _$1_$_\n");
      }
      next;
    }

    # Words made up of legal characters
    if (s/^(([^\s\Q$specials\E])+)//) {
      push @words,  $1;
      push @phrase, $1 if !$angle;
      push @route,  $1 if $angle;
      next;
    }

    # Single specials
    if (s/^([\Q$specials\E])//) {
      push @words, $1;
      push @route, $1 if $angle;

      # Deal with certain special specials

      # We disallow multiple addresses in From, Reply-To, or a sub/unsub
      # operation.

      # XXX #17 need to do something different here when in a route.
      if ($1 eq ',') {
	$::log->out("failed");
	if ($angle) {
	  return (0, "Source routes are not allowed, at
@words[0..$#words-1] _$1_ $_
Did you mistype a period as a comma?\n");
	}
	return (0, "Multiple addresses not allowed, at
@words[0..$#words-1] _$1_ $_
Did you mistype a period as a comma?\n");
      }
      
      # An '@' special puts us on the right hand side of an address
      if ($1 eq '@') {
	$on_rhs = 1;
      }

      # The specials are only allowed between two atoms (comments ignored),
      # but we only have the one to the right to look at.  So we make sure
      # that this special doesn't fall next to another one.
      # Deal with angle brackets (they must nest) and we can only have one
      # bracketed set in an address
      elsif ($1 eq '<') {
	$angle++;
	if ($angle > 1) {
	  $::log->out("failed");
	  return (0, "Angle brackets cannot nest at: $words[-2] _$1_ $_\n");
	}

	# Make sure we haven't already seen a route address
	if (@route) {
	  $::log->out("failed");
	  return (0, "Only one bracketed address permitted at: @words[0..$#words-1] _$1_ $_\n");
	}

      }
      elsif ($1 eq '>') {
	$angle--;
	pop @route;
	if ($angle < 0) {
	  $::log->out("failed");
	  return (0, sprintf("Too many closing angles at %s_%s_%s\n",
			    $words[-2]||"", $1, $_));
	}
	next;
      }

      # The following can be if instead of elsif, but we choose to postpone
      # some tests until later to give better messages.
      elsif ($words[-2] && $words[-2] =~ /^[\Q$specials\E]$/) {
	$::log->out("failed");
	return (0, sprintf("Illegal combination of characters at: %s _%s %s_ %s\n",
			  $words[-3]||"", $words[-2], $words[-1], $_));
      }
      next;
    }

    $::log->out("failed");
    return (0, "Unrecognized address component in $_\n");
  }
  if ($angle) {
    $::log->out("failed");
    return (0, "Unmatched open angle bracket in address.\n");
  }

  # So we have the address broken into pieces and have done a bunch of
  # syntax checks.  Now we decide if we have a route address or a simple
  # mailbox, check syntax accordingly, and build the address.

  if (@route) {
    # A route address was found during tokenizing.  We know that the @words
    # list has only one '<>' bracketed section, so we scan everything else
    # for specials and if none are found then the address is legal.
    $angle = 0;
    for $i (0..$#words) {

      # Quoted strings are OK, I think.
      next if $words[$i] =~ /^\"/;

      if ($words[$i] =~ /^\</) {
	$angle++;
	next;
      }
      if ($words[$i] =~ /^\>/) {
	$angle--;
	$right_of_route = 1;
	next;
      }

      # If in a bracketed section, specials are OK.
      next if $angle;
      
      # If we're right of the route address, nothing is allowed to appear.
      # This is common, however, and is overrideable.
      if (!$self->{'allow_comments_after_route'} && $right_of_route) {
	$::log->out("failed");
	return (0, "Nothing is allowed to the right of an address in angle brackets.\n");
      }

      # We might be lenient and allow '@' in the phrase
      if ($self->{'allow_at_in_phrase'} && $words[$i] =~ /^\@/) {
	next;
      }

      # Other specials are illegal 
      if ($words[$i] =~ /^[\Q$specials\E]/) {
	$::log->out("failed");
	return (0, sprintf("Illegal character in comment portion of address at: %s _%s_ %s\n",
			   $words[$i-1] || "", $words[$i], $words[$i+1] || ""));
      }
    }
    # We toss the other tokens, since we don't need them anymore.
    @words   = @route;
    @comment = @phrase;
  }
  # We have an addr-spec.  The address is then everything that isn't a
  # comment.  XXX We should make special allowances for the weird
  # @domain,@domain,@domain:addr@domain syntax.

  unless (@words) {
    $::log->out("failed");
    return (0, "Nothing but comments in that address.\n");
  }

  # In an addr-spec, every atom must be separated by either a '.' (dots are
  # OK on the LHS) or a '@', there must be only a single '@', the address
  # must begin and end with an atom.  (We can be lenient and allow it to
  # end with a '.', too.)
  if ($words[0] =~ /^[.@]/) {
    $::log->out("failed");
    return (0, "The address cannot begin with either '.' or '\@'.\n");
  }
  
  $on_rhs = 0;

  # We can bail out early if we have just a bang path
  if ($#words == 0 &&
      $self->{'allow_bang_paths'} &&
      $words[0] =~ /[a-z0-9]\![a-z]/i)
    {
      $::log->out;
      return (1, $words[0], join(" ", @comment)||"");
    }
  
  for $i (0..$#words) {
    if ($i > 0 &&$words[$i] !~ /^[.@]/ && $words[$i-1] && $words[$i-1] !~ /^[.@]/) {
      $::log->out("failed");
      return (0, "Individual words are not allowed without an intervening '.' or '\@'
at: $words[$i-1] $words[$i]
Did you supply just your full name?  Did you include your full name
along with your address without surrounding your name by parentheses?
Did you try to perform an action on two lists at once?
");
    }

    if ($words[$i] eq '@') {
      $on_rhs = 1;
      next;
    }

    if($on_rhs) {
      $words[$i] = lc($words[$i]);
      $rhs_length += length($words[$i]);
      if ($self->{'limit_length'} && $rhs_length > 64) {
	$::log->out("failed");
	return (0, "The hostname exceeds 64 characters in length.\n");
      }
      # Hostname components must be only alphabetics, ., or -; can't start
      # with -.  We also allow '[' and ']' for domain literals.
      if (($words[$i] =~ /[^a-zA-Z0-9.-]/ ||
	   $words[$i] =~ /^-/) && $words[$i] !~ /^[\[\]]/)
	{
	  $::log->out("failed");
	  return (0, "Host name component \"$words[$i]\" contains illegal characters.\n");
	}
    }
    else {
      $lhs_length += length($words[$i]);
      if ($self->{'limit_length'} && $lhs_length > 64) {
	$::log->out("failed");
	return (0, "The user name exceeds 64 characters in length.\n");
      }
      # Username components must lie betweem 040 and 0177.  (It's really
      # more complicated than that, but this will catch most of the
      # problems.)
      if ($words[$i] =~ /[^\040-\177]/) {
	$::log->out("failed");
	return (0, "User name component \"$words[$i]\" contains illegal characters.\n");
      }
    }
    
    if ($words[$i] !~ /^[.@]/ && $on_rhs) {
      $subdomain++;
    }

    if ($on_rhs && $words[$i] =~ /^\[/) {
      $domain_literal = 1;
    }
  }
  
  if ($self->{'require_fqdn'} && !$on_rhs) {
    if ($top_level_domains{lc($words[-1])}) {
      $::log->out("failed");
      return (0, "It looks like you have supplied just a domain name
without the rest of the address.\n");
    }
    else {
      $::log->out("failed");
      return (0, "You did not include a hostname as part of the address.\n");
    }
  }

  if ($words[-1] eq '@') {
    $::log->out("failed");
    return (0, "The address cannot end with an '\@'.  You must supply a hostname.\n");
  }

  if (!$self->{'allow_ending_dot'} && $words[-1] eq '.') {
    $::log->out("failed");
    return (0, "The address cannot end with a '.'.\n");
  }

  # Now check the validity of the domain part of the address.  If we've
  # seen a domain-literal, all bets are off.  Don't bother if we never even
  # got to the right hand side; this case will have bombed out earlier of a
  # domain name is required.
  if ($on_rhs) {
    if ($self->{'require_fqdn'} && $subdomain < 2 && !$domain_literal) {
      $::log->out("failed");
      return (0, "You did not include a complete hostname.\n");
    }
    if (($self->{'strict_domain_check'} &&
	 $words[-1] !~ /^\[/ &&
	 !$top_level_domains{lc($words[-1])}) ||
	$words[-1] !~ /[\w-]{2,5}/)
      {
	if ($words[-1] !~ /\D/ &&
	    $words[-3] && $words[-3] !~ /\D/ &&
	    $words[-5] && $words[-5] !~ /\D/ &&
	    $words[-7] && $words[-7] !~ /\D/)
	  {
	    $::log->out("failed");
	    return (0, "It looks like you are trying to supply your IP address
instead of a hostname.  To do, you must enclose it in
square brackets like so: [" . join("",@words[-7..-1]) . "]\n");
	  }
	
	$::log->out("failed");
	return (0, "The domain you provided, $words[-1], does not seem
to be a legal top-level domain.\n");
      }
  }

  my $addr = join("", @words);
  my $comm = join(" ", @comment) || "";

  $::log->out;
  (1, $addr, $comm);
}

%top_level_domains =
  (
   'com'   => 1,
   'edu'   => 1,
   'net'   => 1,
   'gov'   => 1,
   'mil'   => 1,
   'org'   => 1,
   'int'   => 1,
   'firm'  => 1,
   'store' => 1,
   'web'   => 1,
   'arts'  => 1,
   'rec'   => 1,
   'info'  => 1,
   'nom'   => 1,
   'arpa'  => 1,
   'uucp'  => 1,
   'bitnet' => 1,
   'ad' => 1,
   'ae' => 1,
   'af' => 1,
   'ag' => 1,
   'ai' => 1,
   'al' => 1,
   'am' => 1,
   'an' => 1,
   'ao' => 1,
   'aq' => 1,
   'ar' => 1,
   'as' => 1,
   'at' => 1, 
   'au' => 1,
   'aw' => 1,
   'az' => 1,
   'ba' => 1,
   'bb' => 1,
   'bd' => 1,
   'be' => 1,
   'bf' => 1,
   'bg' => 1,
   'bh' => 1,
   'bi' => 1,
   'bj' => 1,
   'bm' => 1,
   'bn' => 1,
   'bo' => 1,
   'br' => 1,
   'bs' => 1,
   'bt' => 1,
   'bv' => 1,
   'bw' => 1,
   'by' => 1,
   'bz' => 1,
   'ca' => 1,
   'cc' => 1,
   'cd' => 1,
   'cf' => 1,
   'cg' => 1,
   'ch' => 1,
   'ci' => 1,
   'ck' => 1,
   'cl' => 1,
   'cm' => 1,
   'cn' => 1,
   'co' => 1,
   'cr' => 1,
   'cu' => 1,
   'cv' => 1,
   'cx' => 1,
   'cy' => 1,
   'cz' => 1,
   'de' => 1,
   'dj' => 1,
   'dk' => 1,
   'dm' => 1,
   'do' => 1,
   'dz' => 1,
   'ec' => 1,
   'ee' => 1,
   'eg' => 1,
   'eh' => 1,
   'er' => 1,
   'es' => 1,
   'et' => 1,
   'fi' => 1,
   'fj' => 1,
   'fk' => 1,
   'fm' => 1,
   'fo' => 1,
   'fr' => 1,
   'fx' => 1,
   'ga' => 1,
   'gb' => 1,
   'gd' => 1,
   'ge' => 1,
   'gf' => 1,
   'gh' => 1,
   'gi' => 1,
   'gl' => 1,
   'gm' => 1,
   'gn' => 1,
   'gp' => 1,
   'gq' => 1,
   'gr' => 1,
   'gs' => 1,
   'gt' => 1,
   'gu' => 1,
   'gw' => 1,
   'gy' => 1,
   'hk' => 1,
   'hm' => 1,
   'hn' => 1,
   'hr' => 1,
   'ht' => 1,
   'hu' => 1,
   'id' => 1,
   'ie' => 1,
   'il' => 1,
   'in' => 1,
   'io' => 1,
   'iq' => 1,
   'ir' => 1,
   'is' => 1,
   'it' => 1,
   'jm' => 1,
   'jo' => 1,
   'jp' => 1,
   'ke' => 1,
   'kg' => 1,
   'kh' => 1,
   'ki' => 1,
   'km' => 1,
   'kn' => 1,
   'kp' => 1,
   'kr' => 1,
   'kw' => 1,
   'ky' => 1,
   'kz' => 1,
   'la' => 1,
   'lb' => 1,
   'lc' => 1,
   'li' => 1,
   'lk' => 1,
   'lr' => 1,
   'ls' => 1,
   'lt' => 1,
   'lu' => 1,
   'lv' => 1,
   'ly' => 1,
   'ma' => 1,
   'mc' => 1,
   'md' => 1,
   'mg' => 1,
   'mh' => 1,
   'mk' => 1,
   'ml' => 1,
   'mm' => 1,
   'mn' => 1,
   'mo' => 1,
   'mp' => 1,
   'mq' => 1,
   'mr' => 1,
   'ms' => 1,
   'mt' => 1,
   'mu' => 1,
   'mv' => 1,
   'mw' => 1,
   'mx' => 1,
   'my' => 1,
   'mz' => 1,
   'na' => 1,
   'nc' => 1,
   'ne' => 1,
   'nf' => 1,
   'ng' => 1,
   'ni' => 1,
   'nl' => 1,
   'no' => 1,
   'np' => 1,
   'nr' => 1,
   'nu' => 1,
   'nz' => 1,
   'om' => 1,
   'pa' => 1,
   'pe' => 1,
   'pf' => 1,
   'pg' => 1,
   'ph' => 1,
   'pk' => 1,
   'pl' => 1,
   'pm' => 1,
   'pn' => 1,
   'pr' => 1,
   'pt' => 1,
   'pw' => 1,
   'py' => 1,
   'qa' => 1,
   're' => 1,
   'ro' => 1,
   'ru' => 1,
   'rw' => 1,
   'sa' => 1,
   'sb' => 1,
   'sc' => 1,
   'sd' => 1,
   'se' => 1,
   'sg' => 1,
   'sh' => 1,
   'si' => 1,
   'sj' => 1,
   'sk' => 1,
   'sl' => 1,
   'sm' => 1,
   'sn' => 1,
   'so' => 1,
   'sr' => 1,
   'st' => 1,
   'su' => 1,
   'sv' => 1,
   'sy' => 1,
   'sz' => 1,
   'tc' => 1,
   'td' => 1,
   'tf' => 1,
   'tg' => 1,
   'th' => 1,
   'tj' => 1,
   'tk' => 1,
   'tm' => 1,
   'tn' => 1,
   'to' => 1,
   'tp' => 1,
   'tr' => 1,
   'tt' => 1,
   'tv' => 1,
   'tw' => 1,
   'tz' => 1,
   'ua' => 1,
   'ug' => 1,
   'uk' => 1,
   'um' => 1,
   'us' => 1,
   'uy' => 1,
   'uz' => 1,
   'va' => 1,
   'vc' => 1,
   've' => 1,
   'vg' => 1,
   'vi' => 1,
   'vn' => 1,
   'vu' => 1,
   'wf' => 1,
   'ws' => 1,
   'ye' => 1,
   'yt' => 1,
   'yu' => 1,
   'za' => 1,
   'zm' => 1,
   'zr' => 1,
   'zw' => 1,
);

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


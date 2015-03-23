=head1 NAME

Mj::Addr - Address object for Majordomo

=head1 SYNOPSIS

 Mj::Addr::set_params(%params);
 $addr = new Mj::Addr($string, %params);
 ($ok, $message, $loc) = $addr->valid; # Tests syntactic legality, returns
                                       # problem description and
                                       # location
 $strip   = $addr->strip;        # Remove comments
 $comment = $addr->comment;      # Extract comments

 if ($addr1->canon eq $addr2->canon) {
   # They are, after aliasing and transformation, equivalent
 }

=head1 DESCRIPTION

This module implements an object encapsulating an address.  Majordomo needs
to see several forms of an address at various times, and sometimes needs to
deal with more than one form at a time.  Majordomo needs these forms:

  full - the address and all of its comments
  stripped - the address without its comments
  comments - the comments without the address.  Note that you cannot deduce
             the full address from the stripped address and the comments.
  transformed - the address after transformations have been applied.
  canonical - the stripped address after both aliasing and transformation
              have taken place.  All comparisons should happen on canonical
              addresses, and can be carried out by comparing stringwise.

Majordomo also needs to check whether or not an address is valid, and upon
encountering an invalid address have access to a user-friendly (or at least
somewhat explanatory) message as to the nature of the syntactic anomaly.

=cut

package Mj::Addr;
use strict;
use vars qw($addr %defaults %top_level_domains);
#use Mj::Log;
use overload
  '=='   => \&match,
  'eq'   => \&match,
  '""'   => \&full,
  'bool' => \&isvalid;

# Some reasonable defaults; still require xforms and an aliaslist
%defaults = ('allow_at_in_phrase'          => 0,
	     'allow_bang_paths'            => 0,
	     'allow_comments_after_route'  => 0,
	     'allow_ending_dot'            => 0,
	     'limit_length'                => 1,
	     'require_fqdn'                => 1,
	     'strict_domain_check'         => 1,
	    );

=head2 set_params

This sets the defaults for all Mj::Addr objects allocated afterwards.  It
takes a hash of parameter, value pairs.  The parameters can be set all at
once or at various times.

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

The following parameters take other values:

  aliaslist - a reference to a Mj::AliasList object, used to perform alias
              lookups.

  xforms    - a reference to an array of address transforms, described in
              the Majordomo config file.

Example, illustrating the default settings:
  Mj::Addr::set_params
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
sub set_params {
  my %params = @_;
  my($key, $val);
  while (($key, $val) = each %params) {
    $defaults{$key} = $val;
  }
}

=head2 new($addr, %params)

This allocates and returns an Mj::Addr object using the given string as the
address.  Parameters not mentioned will be filled in with the defaults or
any previously set parameters.  If the passed valie is already an Mj::Addr
object, it will just be returned.  This lets you do

  $addr = new Mj::Addr($addr)

without worring about whether you were passed an address or not.  Cached
data is preserved by this, too.

The string does not have to be a valid address, but various calls will
return undef if it is not.  If having a valid address is important, a call
to the 'valid' method should be made shortly afterwards.

Class layout (hash):
  p - hashref parameters
  cache - hashref of cached data
  full - the full address
  strip - the stripped address
  comment - the comments
  xform - the transformed address
  alias - the full form of the address after aliasing
  canon - the canonical address (stripped form of address after aliasing)

  parsed - has the full address been parsed yet?
  valid  - is the address valid
  message - syntax error message

Only canonical addresses should be used for comparison.

The cache field is intended to be used to stuff additional data in an
address, so that it can carry it along as it is passed throughout the
system.  This is intended to eliminate some needless calls to retrieve
flags and such.

Be aware of stale data; these addresses will accumulate information and
cache it; this saves time but can cause interesting problems if the cached
data is outdated.  These objects should probably not live very long lives.
They should definitely not be cached between connections.

=cut
sub new {
  my $type  = shift;
  my $class = ref($type) || $type;
  my $self  = {};
  my $val = shift;
  my $key;

  # Bail if creating an Addr from an Addr
  return $val if (ref ($val) eq 'Mj::Addr');
  return unless (defined $val);

  # Unfold by removing only the CRLF.
  # (This is consistent with RFC 2822.)
  $val =~ s/\r?\n(\s)/$1/gs;

  # Untaint
  $val =~ /(.*)/; $val = $1 || "";
  # Avoid database overlaps.
  $val =~ s/\001/^A/g;

  $self->{'full'} = $val;
  return undef unless $self->{'full'};
#  my $log = new Log::In 150, $self->{'full'};
  bless $self, $class;

  if ($val =~ /(.+)\@anonymous$/) {
    $self->{'aliased'} = 1;
    $self->{'anon'} = 1;
    $self->{'parsed'} = 1;
    $self->{'valid'} = 1;
    $self->{'xformed'} = 1;
    $self->{'canon'} = $val;
    $self->{'strip'} = $val;
    $self->{'xform'} = $val;
    $self->{'local_part'} = $1;
    $self->{'domain'} = 'anonymous';
  }

  # Copy in defaults, then override.
  while (($key, $val) = each %defaults) {
    $self->{p}{$key} = $val;
  }
  while (@_) {
    ($key, $val) = splice(@_, 0, 2);
    $self->{p}{$key} = $val;
  }
  $self;
}

=head2 separate(string)

This takes a string, assumed to be a comma-separated list of addresses, and
returns a list containing the separate addresses.  Because of the bizarre
nature of RFC822 addresses, this is not a simple matter.

The returned values are strings, _NOT_ Mj::Addr objects.  They may or may
not be valid because only enough of the validation procedure to determine
where the splits occur is run.  If the procedure does detect an invalid
address, it will return the separated addresses to the left of the error
but not anything else.  The returned strings may or not be stripped
addresses; parenthesized comments will be removed but route addresses
will be left whole.

=cut
sub separate {
  my $str = shift;
  my(@out, $addr, $ok, $rest, $self);
  # Fake an addr object so we can call _validate
  $self = new Mj::Addr('unknown@anonymous');

  while (1) {
    $self->{'full'} = $str;
    ($ok, undef, $addr, $rest) = $self->_validate;
    # Three possibilities:
    if ($ok == 0) {
      # Some kind of syntax failure; bail with what we have
      return @out;
    }
    elsif ($ok > 0) {
      # The string was a real, valid address and there is no more to split
      $str =~ s/^\s+//; $str =~ s/\s+$//;
      push @out, $str;
      return @out;
    }
    else { # $ok < 0
      # Stripped one address; more to check
      push @out, $addr;
      $str = $rest;
    }
  }
}

=head2 reset(addr)

Clears out any cached data and resets the address to a new string.  This
has less overhead than destroying and creating anew large numbers of
Mj::Addr objects in a loop.

If $addr is not defined, just resets the cached data.

=cut
sub reset {
  my $self = shift;
  my $addr = shift;
#  my $log = new Log::In 150, $self->{'full'};

  delete $self->{'cache'};
  if ($addr) {
    $self->{'full'} = $addr;

    if ($addr =~ /(.+)\@anonymous$/) {
      $self->{'aliased'} = 1;
      $self->{'anon'} = 1;
      $self->{'parsed'} = 1;
      $self->{'valid'} = 1;
      $self->{'xformed'} = 1;
      $self->{'canon'} = $addr;
      $self->{'strip'} = $addr;
      $self->{'xform'} = $addr;
      $self->{'local_part'} = $1;
      $self->{'domain'} = 'anonymous';
    }

    else {
      delete $self->{'alias'};
      delete $self->{'canon'};
      delete $self->{'comment'};
      delete $self->{'domain'};
      delete $self->{'local_part'};
      delete $self->{'strip'};
      delete $self->{'xform'};
      delete $self->{'valid'};
      $self->{'parsed'} = 0;
      $self->{'aliased'} = 0;
      $self->{'xformed'} = 0;
    }
  }
}

=head2 setcomment(comment)
   
This changes the comment portion of an address.  As a side effect, it
will coerce the full address to name-addr form.

=cut
sub setcomment {
  my $self    = shift;
  my $comment = shift;
  my ($newaddr, $loc, $mess, $ok, $orig, $strip);

  $comment =~ s/^\s*["'](.*)["']\s*$/$1/;

  $strip = $self->strip;
  $orig = $self->full;

  # Add quotes to the comment if it contains special characters
  # and is not already quoted.
  if ($comment =~ /[^\w\s!#\$\%\&\@'*+\-\/=?\^`\{\}|~]/
      and $comment !~ /^\s*".*"\s*$/) {
    $newaddr = qq("$comment" <$strip>);
  }
  else {
    $newaddr = qq($comment <$strip>);
  }

  $self->reset($newaddr);

  ($ok, $mess, $loc) = $self->valid;
  unless ($ok) {
    $self->reset($orig);
  }

  return ($ok, $mess, $loc);
}

=head2 full

Extracts the full address.  This is in all cases just the string that was
passed in when the object was created.

=cut
sub full {
  my $self = shift;
#  my $log = new Log::In 150, $self->{'full'};
  $self->{'full'};
}

=head2 strip

Extracts the stripped address.

=cut
sub strip {
  my $self = shift;
#  my $log = new Log::In 150, $self->{'full'};

  $self->_parse unless $self->{parsed};
  $self->{'strip'};
}

=head2 comment

Extracts the comment.

=cut
sub comment {
  my $self = shift;
#  my $log = new Log::In 150, $self->{'full'};

  $self->_parse unless $self->{parsed};
  $self->{'comment'};
}

=head2 local_part

This routine returns the local part of an address.
For example, the address "fred@example.com" has the local
part "fred".

=cut
sub local_part {
  my $self = shift;
#  my $log = new Log::In 150, $self->{'full'};

  $self->_parse unless $self->{parsed};
  $self->{'local_part'};
}

=head2 domain

This routine returns the domain of an address.
For example, the address "fred@example.com" has the 
domain "example.com".

=cut
sub domain {
  my $self = shift;
#  my $log = new Log::In 150, $self->{'full'};

  $self->_parse unless $self->{parsed};
  $self->{'domain'};
}

=head2 valid, isvalid

Verifies that the address is valid and returns a list:
  flag    - true if the address is valid.
  message - a syntax error if the message is invalid.

isvalid returns only the flag.

=cut
sub valid {
  my $self = shift;
#  my $log = new Log::In 150, $self->{'full'};

#  use Data::Dumper; print Dumper $self;

  $self->_parse unless $self->{parsed};
  ($self->{'valid'}, $self->{message}, $self->{'error_location'});
}

sub isvalid {
  my $self = shift;
#  my $log = new Log::In 150, $self->{'full'};

  $self->_parse unless $self->{parsed};
  $self->{'valid'};
}

=head2 isanon

Returns true if the address is anonymous.

=cut
sub isanon {
  my $self = shift;
  return $self->{'anon'};
}

=head2 xform

Returns the transformed form of the address.  This will be equivalent to
the stripped form unless the xform parameter is set to something which
modifies the address.

=cut
sub xform {
  my $self = shift;
#  my $log = new Log::In 150, $self->{'full'};

  $self->_xform unless $self->{xformed};
  $self->{'xform'};
}

=head2 alias

Returns the aliased form of the address; that is, the full address
including comments that the address is aliased to.

=cut
sub alias {
  my $self = shift;
#  my $log = new Log::In 150, $self->{'full'};

  $self->_alias unless $self->{aliased};
  $self->{alias};
}

=head2 canon

Returns the canonical form of the address.  Will be the same as the xform
form unless the aliaslist parameter is set and the address aliases to
something.

=cut
sub canon {
  my $self = shift;
#  my $log = new Log::In 150, $self->{'full'};
  $self->_alias unless $self->{aliased};
  $self->{'canon'};
}

=head2 cache($tag, $data)

Caches some data within the Mj::Addr object.

=cut
sub cache {
  my ($self, $tag, $data) = @_;
#  my $log = new Log::In 150, $self->{'full'};
  $self->{'cache'}{$tag} = $data;
}

=head2 retrieve($tag)

Retrieves some cached data.

=cut
sub retrieve {
  my ($self, $tag) = @_;
#  my $log = new Log::In 150, "$self->{'full'}, $tag";
  $self->{'cache'}{$tag};
}

=head2 flush

Deletes any cached data.

=cut
sub flush {
  my $self = shift;
  delete $self->{'cache'};
}

=head2 match($addr1, $addr2)

Returns true if two Mj::Addr objects are equivalent, false otherwise.

=cut
sub match {
  my ($a1, $a2) = @_;

  return 0 unless $a1->isvalid;
  return 0 if     $a1->isanon;

  if (ref $a2 eq 'Mj::Addr') {
    return 0 unless $a2->isvalid;
    return 0 if     $a2->isanon;

    return $a1->canon eq $a2->canon;
  }
  $a1->canon eq $a2;
}

=head2 _parse

Parse an address, extracting the valid flag, a syntax error (if any), the
stripped address, the comments, and the local part.

=cut
sub _parse {
  my $self = shift;

  my ($ok, $v1, $v2, $v3, $v4) = $self->_validate;

  if ($ok > 0) {
    $self->{'strip'}   = $v1;
    $self->{'comment'} = $v2;
    $self->{'local_part'} = $v3;
    $self->{'domain'}   = $v4;
    $self->{'valid'}   = 1;
    $self->{'message'} = '';
    $self->{'error_location'} = '';
  }
  else {
    $self->{'strip'}   = undef;
    $self->{'comment'} = undef;
    $self->{'local_part'} = undef;
    $self->{'domain'}  = undef;
    $self->{'valid'}   = 0;
    $self->{'message'} = $v1;
    $self->{'error_location'} = $v2;
  }
  $self->{'parsed'} = 1;
  $self->{'valid'};
}

=head2 _xform

Apply transformations (if any) to the address.  They are applied in order;
care should be taken that they are idempotent and that the collection is
idempotent.  This means that the result of applying them repeatedly is the
same as the result of applying them once.

Transformations look somewhat like the usual regular expression transforms:

/(.*?)\+.*(\@.*)/$1$2/

removes the sendmail +mailbox specifier from the address, which turns
tibbs+blah@hurl.edu into tibbs@hurl.edu.  Note that applying this
repeatedly leaves the address alone.  When there is more than one plus, all
are removed.

/(.*\@).*?\.(hurl\.edu)/$1$2/

Removes the machine name from the hurl.edu domain, which turns
tibbs@a2.hurl.edu into tibbs@hurl.edu.  Note that applying this repeatedly
leaves the address alone.

No transformations are necessary to downcase hostnames in addresses; that
is done automatically by the address parser.

=cut
sub _xform {
  my $self = shift;
  my (@xforms, $cpt, $i, $eval);

#  my $log = new Log::In 120, $self->{'full'};

  # Parse the address if we need to; bomb if it is invalid
  return 0 unless $self->isvalid;

  # Exit successfully if we have nothing to do
  unless ($self->{p}{xforms} && @{$self->{p}{xforms}}) {
    $self->{'xform'} = $self->{'strip'};
    return 1;
  }

  local $addr = $self->{'strip'};

  # Set up the Safe compartment
  eval { require Safe; $cpt = new Safe; };
  $cpt->permit_only(qw(concat const lc leaveeval lineseq list padany
                       pushmark rv2sv subst uc rv2gv));
  $cpt->share('$addr');

  for $i (@{$self->{p}{xforms}}) {
    # Do the substitution in a _very_ restrictive Safe compartment
    $eval = "\$addr =~ s$i";
    $cpt->reval($eval);

    # Log any messages
    if ($@) {
warn $@;
#      $::log->message(10,
#		      "info",
#		      "Mj::Addr::xform: error in Safe compartment: $@"
#		     );
    }
  }
  $self->{'xform'} = $addr;
  1;
}

=head2 _alias

Do an alias lookup on an address.

=cut
sub _alias {
  my $self = shift;
  my $data;
#  my $log = new Log::In 150, $self->{'full'};

  # Make sure we've transformed first, and bomb if we can't.
  unless ($self->{xformed}) {
    return 0 unless $self->_xform;
  }

  # Copy over unaliased values and exit if we have nothing to do
  unless ($self->{p}{aliaslist}) {
    $self->{'canon'} = $self->{'xform'};
    $self->{'alias'} = $self->{'xform'};
    return 1;
  }

  $data = $self->{p}{aliaslist}->lookup($self->{'xform'});

  # Use the alias data except for bookkeeping aliases
  if ($data and $self->{'xform'} ne $data->{'target'}) {
    $self->{'canon'} = $data->{target};
    $self->{'alias'} = $data->{striptarget};
  }
  else {
    $self->{'canon'} = $self->{'xform'};
    $self->{'alias'} = $self->{'xform'};
  }
  $self->{aliased} = 1;
  1;
}

=head2 validate (internal method)

Intended to check an address for validity and report back problems in a way
that the user can understand.  This is hard to do.  This routine tries to
do a "good job" in that it catches most forms of bad addresses and doesn''t
trap anything that is legal.  Some configuration variables are provided to
control certain aspects of its behavior and to allow certain types of
illegal addresses that are commonly allowed.

It currently does not properly handle non-ASCII characters in comments and
hostnames, nor does it handle address groups and route addresses with more
than one host.

When a list of addresses separated by a comma is detected, a special error
value is returned along with a normal error message, the portion of the
address to the left of the comma and the portion to the right.  This can be
used to chip addresses off of the left hand side of an address list.

=cut

sub _validate {
  my $self  = shift;
  local($_) = $self->{'full'};
#  my $log = new Log::In 150, $_;
  my (@comment, @phrase, @route, @words, $angle, $bang_path, $comment,
      $domain_literal, $i, $right_of_route, $lhs_length, $nest, $rhs_length,
      $on_rhs, $subdomain, $word);

  my $specials    = q|()<>@,;:\".[]|;
  my $specials_nd = q|()<>@,;:\"[]|;  # No dot
  $lhs_length = $rhs_length = 0;

  # We'll be interpolating arrays into strings and we don't want any
  # spaces.
  local($") = ''; 

  # Trim leading and trailing whitespace; it hoses the algorithm
  s/^\s+//;
  s/\s+$//;

  if ($_ eq "") {
#    $log->out("failed");
    return (0, 'undefined_address');
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
#	$log->out("failed");
	return (0, 'unmatched_paren', "$comment $_");
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
#	$log->out("failed");
	return (0, 'lhs_domain_literal', "$1 $_");
      }
      unless ($words[-2] && $words[-2] =~ /^[.@]/) {
#	$log->out("failed");
	return (0, 'rhs_domain_literal', "$words[-2] _$1_$_");
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

      # According to RFC2822, dots are now legal in a phrase
      #if ($1 eq '.') {
      #push @phrase, $1 if !$angle;
      #}

      # We disallow multiple addresses in From, Reply-To, or a sub/unsub
      # operation.

      # XXX #17 need to do something different here when in a route.
      if ($1 eq ',') {
#	$log->out("failed");
	if ($angle) {
	  return (0, 'source_route', "@words[0..$#words-1] _$1_ $_");
	}
	pop @words;
	return (-1, 'multiple_addresses', join('',@words), $_);
      }

      # An '@' special puts us on the right hand side of an address
      if ($1 eq '@') {

	# But we might already be on the RHS
	if ($on_rhs) {
	  return (0, 'at_symbol', "$words[-1] _$1_ $_");
	}
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
#	  $log->out("failed");
	  return (0, 'nested_brackets', "$words[-2] _$1_ $_");
	}

	# Make sure we haven't already seen a route address
	if (@route) {
#	  $log->out("failed");
	  return (0, 'bracketed_addresses',  "@words[0..$#words-1] _$1_ $_");
	}

      }
      elsif ($1 eq '>') {
	$angle--;
	pop @route;
	if ($angle < 0) {
#	  $log->out("failed");
	  return (0, 'right_brackets', sprintf ("%s_%s_%s",
			    $words[-2] || "", $1, $_));
	}
	next;
      }

      # The following can be if instead of elsif, but we choose to postpone
      # some tests until later to give better messages.
      elsif ($words[-2] && $words[-2] =~ /^[\Q$specials\E]$/) {
#	$log->out("failed");
	return (0, 'invalid_char', sprintf("%s _%s %s_ %s",
                   $words[-3] || "", $words[-2], $words[-1], $_));
      }
      next;
    }

#    $log->out("failed");
    return (0, 'invalid_component', $_);
  }
  if ($angle) {
#    $log->out("failed");
    return (0, 'left_brackets', '<');
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
      if (!$self->{p}{'allow_comments_after_route'} && $right_of_route) {
#	$log->out("failed");
	return (0, 'after_route', $words[$i]);
      }

      # We might be lenient and allow '@' in the phrase
      if ($self->{p}{'allow_at_in_phrase'} && $words[$i] =~ /^\@/) {
	next;
      }

      # Other specials are illegal
      if ($words[$i] =~ /^[\Q$specials_nd\E]/) {
#	$log->out("failed");
	return (0, 'invalid_char', sprintf("%s _%s_ %s", $words[$i-1] || "", 
                                           $words[$i], $words[$i+1] || ""));
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
#    $log->out("failed");
    return (0, 'no_route', '');
  }

  # In an addr-spec, every atom must be separated by either a '.' (dots are
  # OK on the LHS) or a '@', there must be only a single '@', the address
  # must begin and end with an atom.  (We can be lenient and allow it to
  # end with a '.', too.)
  if ($words[0] =~ /^[.@]/) {
#    $log->out("failed");
    return (0, 'starting_char', $words[0]);
  }

  $on_rhs = 0;

  # We can bail out early if we have just a bang path
  if ($#words == 0 &&
      $self->{p}{'allow_bang_paths'} &&
      $words[0] =~ /[a-z0-9]\![a-z]/i)
    {
#      $log->out;
      return (1, $words[0], join(" ", @comment)||"");
    }

  for $i (0..$#words) {
    if ($i > 0 &&$words[$i] !~ /^[.@]/ && $words[$i-1] && $words[$i-1] !~ /^[.@]/) {
#      $log->out("failed");
      return (0, 'word_separator', "$words[$i-1] $words[$i]");
    }

    if ($words[$i] eq '@') {
      $on_rhs = 1;
      next;
    }

    if($on_rhs) {
      $words[$i] = lc($words[$i]);
      $rhs_length += length($words[$i]);
      if ($self->{p}{'limit_length'} && $rhs_length > 64) {
#	$log->out("failed");
	return (0, 'host_length', $words[$i]);
      }
      # Hostname components must be only alphabetics, ., or -; can't start
      # with -.  We also allow '[' and ']' for domain literals.
      if (($words[$i] =~ /[^a-zA-Z0-9.-]/ ||
	   $words[$i] =~ /^-/) && $words[$i] !~ /^[\[\]]/)
	{
#	  $log->out("failed");
	  return (0, 'invalid_char', "$words[$i]");
	}
    }
    else {
      $lhs_length += length($words[$i]);
      if ($self->{p}{'limit_length'} && $lhs_length > 64) {
#	$log->out("failed");
	return (0, 'local_part_length', $words[$i]);
      }
      # Username components must lie betweem 040 and 0177.  (It's really
      # more complicated than that, but this will catch most of the
      # problems.)
      if ($words[$i] =~ /[^\040-\177]/) {
#	$log->out("failed");
	return (0, 'invalid_char', "$words[$i]");
      }
    }

    if ($words[$i] !~ /^[.@]/ && $on_rhs) {
      $subdomain++;
    }

    if ($on_rhs && $words[$i] =~ /^\[/) {
      $domain_literal = 1;
    }
  }

  if ($self->{p}{'require_fqdn'} && !$on_rhs) {
    if ($top_level_domains{lc($words[-1])}) {
#      $log->out("failed");
      return (0, 'no_local_part', $words[-1]);
    }
    else {
#      $log->out("failed");
      return (0, 'no_domain', $words[-1]);
    }
  }

  if ($words[-1] eq '@') {
#    $log->out("failed");
    return (0, 'ending_at', '@');
  }

  if (!$self->{p}{'allow_ending_dot'} && $words[-1] eq '.') {
#    $log->out("failed");
    return (0, 'ending_period', '.');
  }

  # Now check the validity of the domain part of the address.  If we've
  # seen a domain-literal, all bets are off.  Don't bother if we never even
  # got to the right hand side; this case will have bombed out earlier of a
  # domain name is required.
  if ($on_rhs) {
    if ($self->{p}{'require_fqdn'} && $subdomain < 2 && !$domain_literal) {
#      $log->out("failed");
      return (0, 'incomplete_host', $words[-1]);
    }
    if (($self->{p}{'strict_domain_check'} &&
	 $words[-1] !~ /^\[/ &&
	 !$top_level_domains{lc($words[-1])}) ||
	$words[-1] !~ /[\w-]{2,5}/)
      {
	if ($words[-1] !~ /\D/ &&
	    $words[-3] && $words[-3] !~ /\D/ &&
	    $words[-5] && $words[-5] !~ /\D/ &&
	    $words[-7] && $words[-7] !~ /\D/)
	  {
#	    $log->out("failed");
	    return (0, 'ip_address', join("",@words[-7..-1]));
	  }
	
#	$log->out("failed");
	return (0, 'top_level_domain', $words[-1]);
      }
  }

  my $addr = join("", @words);
  my $comm = join(" ", @comment) || "";
  my $lp   = substr $addr, 0, $lhs_length;
  my $dom  = substr $addr, -$rhs_length, $rhs_length;

#  $log->out('ok');
  (1, $addr, $comm, $lp, $dom);
}

%top_level_domains =
  (
   'aero'  => 1,
   'asia'  => 1,
   'biz'   => 1,
   'cat'   => 1,
   'com'   => 1,
   'coop'  => 1,
   'edu'   => 1,
   'gov'   => 1,
   'info'  => 1,
   'jobs'  => 1,
   'int'   => 1,
   'mil'   => 1,
   'mobi'  => 1,
   'museum'=> 1,
   'name'  => 1,
   'net'   => 1,
   'org'   => 1,
   'pro'   => 1,
   'tel'   => 1,
   'travel'=> 1,
   'ac' => 1,
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
   'eu' => 1,
   'fi' => 1,
   'fj' => 1,
   'fk' => 1,
   'fm' => 1,
   'fo' => 1,
   'fr' => 1,
   'ga' => 1,
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
   'im' => 1,
   'in' => 1,
   'io' => 1,
   'iq' => 1,
   'ir' => 1,
   'is' => 1,
   'it' => 1,
   'je' => 1,
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
   'ps' => 1,
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
   'zw' => 1,
);

=head1 COPYRIGHT

Copyright (c) 1997, 1998, 2002, 2003 Jason Tibbitts for The Majordomo 
Development Group.  All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the license detailed in the LICENSE file of the
Majordomo2 distribution.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the Majordomo2 LICENSE file for more
detailed information.

=cut

1;


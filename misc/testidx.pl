sub idx_subject_author {
  my ($type, $msg, $data) = @_;
  my ($from, $sub, $width);

  $sub = $data->{'subject'};
  $sub = '(no subject)' unless length $sub;
  $from = $data->{from};

  if (length("$sub $data->{'from'}") > 72) {
    return "  $sub\n" . (' ' x int(74-length($from))) . "[$from]\n";
  }

  $width = length($from) + length($sub);
  return "  $sub " . (' ' x int(71 - $width)) . "[$from]\n";
}

@a = (['Re: handle bars', '"Emile Nossin" <Emile@Cybercomm.nl>'],
      ['Tires',           'DavidAklein@webtv.net (David Klein)'],
      ['helmet season coming', '"Paul B. Atkins" <patkins@mari.net>'],
      ['Re: Optimum Windscreen height', '"Steve Scudder, PCrdr, GBTTrdr, GHrscu" <97PC800@bizgroup.net>'],
      ['(no subject)',                  'Ron Grant <ultspnch@yahoo.com>'],
      ["a"x 35, "b"x 30],
      ["a"x 40, "b"x 30],
      ["a"x 41, "b"x 30],
      ["a"x 41, "b"x 31],
      ["a"x 42, "b"x 30],
      ["a"x 43, "b"x 30],
      ["a"x 42, "b"x 31],
      ["a"x 44, "b"x 30],
      ["a"x 47, "b"x 30],
      ["a"x 47, "b"x 35],
      ["a"x 47, "b"x 40],
      ["a"x 47, "b"x 45],
      ["a"x 47, "b"x 50],
      ["a"x 47, "b"x 72],
      ["a"x 47, "b"x 73],
      ["a"x 47, "b"x 74],
      ["a"x 47, "b"x 75],
      ["a"x 47, "b"x 76],

     );

for $i (@a) {
  print idx_subject_author('text', '199901/11', {subject => $i->[0],
						 from    => $i->[1],
						}
			  );
}

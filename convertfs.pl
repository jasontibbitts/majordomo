use File::Find;
find(\&wanted, '.');

sub wanted {
  return unless $_ eq '_filespace.T';
  open FS, '<_filespace.T';
  while (defined($line = <FS>)) {
    chomp $line;
    @data = split("\001", $line);
    $data[0] =~ m!^(.*/)?(.*?)$!;
    $dot = "$1.$2";
    open DF, ">$dot";
    print DF "$data[1]\n";
    print DF "$data[2]\n";
    print DF "$data[3]\n";
    print DF "$data[4]\n";
    print DF "$data[5]\n";
    print DF "$data[7]\n";
    close DF;
  }
  close FS;
}

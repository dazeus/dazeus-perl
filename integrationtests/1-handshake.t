use Test::More tests => 5;
use DaZeus;
use Try::Tiny;

@ARGV || die "Missing socket name";

my $dazeus;
try {
	$dazeus = DaZeus->connect($ARGV[0]);
	pass("connect()");
} catch {
	diag($_);
	fail("connect()");
	exit(1);
};

ok($dazeus, "DaZeus object created");
my $sock = $dazeus->socket();
ok($sock, "Socket created");
is($sock, $dazeus->socket(), "socket() is idempotent");
is(ref($dazeus->networks()), "ARRAY", "networks() contains an array");

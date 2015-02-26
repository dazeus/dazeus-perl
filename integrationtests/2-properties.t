use Test::More tests => 16;
use DaZeus;
use Try::Tiny;

@ARGV || die "Missing socket name";

my $dazeus = DaZeus->connect($ARGV[0]) or die $!;

$dazeus->setProperty("test.text", "foobar");
is($dazeus->getProperty("test.text"), "foobar", "Property was stored succesfully the same");

is($dazeus->getProperty("test.nonexistant"), undef, "Property never stored is undef");

$dazeus->setProperty("test.array", ["one", "two"]);
is_deeply($dazeus->getProperty("test.array"), ["one", "two"], "Array property was stored succesfully");

$dazeus->setProperty("test.hash", {one => "two", three => "four"});
is_deeply($dazeus->getProperty("test.hash"), {one => "two", three => "four"}, "Hash property was stored succesfully");

# Save variable in global scope
$dazeus->setProperty("test.scope", "bar");
# Retrieve it with a more specific scope
is($dazeus->getProperty("test.scope", "q"), "bar", "Initial variable could be requested with scope");

# Save overriding variable in network scope
$dazeus->setProperty("test.scope", "baz", "oftc");
# Retrieve the original one
is($dazeus->getProperty("test.scope", "q"), "bar", "Original scoping works correctly");
# Retrieve the scoped one
is($dazeus->getProperty("test.scope", "oftc"), "baz", "Network scoping works correctly");

# Unset overriding scope
$dazeus->unsetProperty("test.scope", "oftc");
# Retrieve the original one
is($dazeus->getProperty("test.scope", "q"), "bar", "Original scoping works correctly");
# Retrieve the scoped one
is($dazeus->getProperty("test.scope", "oftc"), "bar", "Network scoping unset correctly");
# Unset the original variable
$dazeus->unsetProperty("test.scope");
# Retrieve the original one
is($dazeus->getProperty("test.scope", "q"), undef, "Original scoping unset correctly");
# Retrieve the scoped one
is($dazeus->getProperty("test.scope", "oftc"), undef, "Network scoping unset correctly");

# Set in a scope, request in another
$dazeus->setProperty("test.scope", "bar", "oftc");
is($dazeus->getProperty("test.scope", "oftc"), "bar", "Matched network returns correctly");
is($dazeus->getProperty("test.scope", "q"), undef, "Mismatched network returns correctly");

# Long strings storing?
$dazeus->setProperty("test.longvalue", "0" x 2500);
is($dazeus->getProperty("test.longvalue"), "0" x 2500, "2500-byte value could be returned");
$dazeus->setProperty("test.longvalue", "0" x 5850);
is($dazeus->getProperty("test.longvalue"), "0" x 5850, "5850-byte value could be returned");
diag("TODO: known failure when retrieving values longer than 5850 bytes, fix this");
diag("TODO: add a test for retrieving property keys");

# Random byte storing?
my $str =
	"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f".
	"\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f".
	"\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f".
	"\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f".
	"\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f".
	"\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x5b\x5c\x5d\x5e\x5f".
	"\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f".
	"\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x7b\x7c\x7d\x7e\x7f".
	"\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f".
	"\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f".
	"\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf".
	"\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf".
	"\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf".
	"\xd0\xd1\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xdb\xdc\xdd\xde\xdf".
	"\xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb\xec\xed\xee\xef".
	"\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff";
$dazeus->setProperty("test.bytestring", $str);
is($dazeus->getProperty("test.bytestring"), $str, "String with all bytes in it could be returned");

#!/usr/bin/perl
use strict;
use warnings;
use DaZeus;
use Data::Dumper;

my ($socket, $network, $sender) = @ARGV;
if(!$socket) {
	die "Usage: $0 socket [network sender]\n";
}

my $dazeus = DaZeus->connect($socket);
$dazeus->subscribe_command("helloworld", sub {
	my (undef, $network, $sender, $channel, $command, $args, @args) = @_;
	print "$network $sender -> $channel: command $command, args: $args\n";
	if($channel eq $dazeus->getNick($network)) {
		$dazeus->message($network, $sender, "Hello world!");
	} else {
		$dazeus->message($network, $channel, "Hello world!");
	}
});

if($network && $sender) {
	$dazeus->subscribe_command("checkident", {network => $network, sender => $sender}, sub {
		my (undef, $network, $sender, $channel) = @_;
		if($channel eq $dazeus->getNick($network)) {
			$dazeus->message($network, $sender, "You're identified!");
		} else {
			$dazeus->message($network, $channel, "You're identified!");
		}
	});
}

while($dazeus->handleEvents()) {};

package DaZeus;

use strict;
use warnings;
use JSON;
use POSIX qw(:errno_h);
use Storable qw(thaw freeze);
use MIME::Base64 qw(encode_base64 decode_base64);
use Carp;

=head1 NAME

DaZeus - Perl interface to the DaZeus 2 Socket API

=head1 SYNOPSIS

  use DaZeus;
  my $dazeus = DaZeus->connect("unix:/tmp/dazeus.sock");
  # or:
  my $dazeus = DaZeus->connect("tcp:localhost:1234");

  # Get connection status
  my $networks = $dazeus->networks();
  foreach (@$networks) {
    my $channels = $dazeus->channels($n);
    print "$_:\n";
    foreach (@$channels) {
      print "  $_\n";
    }
  }

  $dazeus->subscribe("JOINED", sub { warn "JOINED event received!" });

  $dazeus->subscribe(qw/PRIVMSG NOTICE/);
  while(my $event = $dazeus->handleEvent()) {
    next if($event->{'event'} eq "JOINED");
    my ($network, $sender, $channel, $message)
      = @{$event->{'params'}};
    print "[$network $channel] <$sender> $message\n";
    my $destination = $channel eq "msg" ? $sender : $channel;
    $dazeus->message($network, $destination, $message);
  }

=head1 DESCRIPTION

This module provides a Perl interface to the DaZeus 2 Socket API, so a Perl
application can act as a DaZeus 2 plugin. The module supports receiving events
and sending messages. See also the "examples" directory that comes with the
Perl bindings.

=head1 METHODS

=cut

my ($HAS_INET, $HAS_UNIX);
BEGIN {
	$HAS_INET = eval 'use IO::Socket::INET; 1';
	$HAS_UNIX = eval 'use IO::Socket::UNIX; 1';
};

our $VERSION = '1.00';

=head2 C<connect($socket)>

Creates a DaZeus object connected to the given socket. Returns the object if
the initial connection succeeded; otherwise, calls die(). If, after this
initial connection, the connection fails, for example because the bot is
restarted, the module will re-connect.

The given socket name must either start with "tcp:" or "unix:"; in the case of
a UNIX socket it must contain a path to the UNIX socket, in the case of TCP it
may end in a port number. IPv6 addresses must have a port number attached, so
it can be distinguished from the rest of the address; in "tcp:2001:db8::1:1234"
1234 is the port number.

If you give an object through $socket, the module will attempt to use it
directly as the target socket.

=cut

sub connect {
	my ($pkg, $socket) = @_;

	my $self = {
		handlers => {},
		command_handlers => {},
		events => [],
		buffer => ''
	};
	bless $self, $pkg;

	if(ref($socket)) {
		$self->{sock} = $socket;
	} else {
		$self->{socketfile} = $socket;
	}

	return $self->_connect();
}

=head2 C<socket()>

Returns the internal UNIX or TCP socket used for communication. This call is
useful if you want to watch multiple sockets, for example, using the select()
call. Every time the socket can be read, you can call the handleEvents() method
to process any incoming events. Do not call read() or write() on this socket,
or other calls that change internal socket state.

If the given DaZeus object was not connected, a new connection is opened and
a valid socket will still be returned.

=cut

sub socket {
	my ($self) = @_;
	$self->_connect();
	return $self->{sock};
}

sub _connect {
	my ($self) = @_;
	if($self->{sock}) {
		return $self;
	}

	if($self->{socketfile} =~ /^tcp:(.+):(\d+)$/ || $self->{socketfile} =~ /^tcp:(.+)$/) {
		if(!$HAS_INET) {
			die "TCP connection requested, but IO::Socket::INET couldn't be loaded";
		}
		my $host = $1;
		my $port = $2;
		$self->{sock} = IO::Socket::INET->new(
			PeerAddr => $host,
			PeerPort => $port,
			Proto    => 'tcp',
			Type     => SOCK_STREAM,
			Blocking => 0,
		) or die $!;
	} elsif($self->{socketfile} =~ /^unix:(.+)$/) {
		if(!$HAS_UNIX) {
			die "UNIX connection requested, but IO::Socket::UNIX couldn't be loaded";
		}
		my $file = $1;
		$self->{sock} = IO::Socket::UNIX->new(
			Peer => $file,
			Type => SOCK_STREAM,
			Blocking => 0,
		) or die "Error opening UNIX socket $file: $!\n";
	} else {
		die "Didn't understand format of socketfile: " . $self->{socketfile} . " -- does it begin with unix: or tcp:?\n";
	}
	binmode($self->{sock}, ':bytes');

	return $self;
}

=head2 C<networks()>

Returns a list of active networks on this DaZeus instance, or calls
die() if communication failed.

=cut

sub networks {
	my ($self) = @_;
	$self->_send({get => "networks"});
	my $response = $self->_read();
	if($response->{success}) {
		return $response->{networks};
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<channels($network)>

Returns a list of joined channels on the given network, or calls
die() if communication failed.

=cut

sub channels {
	my ($self, $network) = @_;
	$self->_send({get => "channels", params => [$network]});
	my $response = $self->_read();
	if($response->{success}) {
		return $response->{channels};
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<message($network, $channel, $message)>

Sends given message to given channel on given network, or calls die()
if communication failed.

=cut

sub message {
	my ($self, $network, $channel, $message) = @_;
	$self->_send({do => "message", params => [$network, $channel, $message]});
	my $response = $self->_read();
	if($response->{success}) {
		return 1;
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<reply($response, $network, $sender, $channel)>

Sends a response to either the given channel or nick, depending on whether the
conversation takes place in a query.

=cut

sub reply {
	my ($self, $response, $network, $sender, $channel) = @_;

	if ($channel eq $self->getNick($network)) {
		$self->message($network, $sender, $response);
	} else {
		$self->message($network, $channel, $response);
	}
}

=head2 C<action($network, $channel, $message)>

Like message(), but sends the message as a CTCP ACTION (as if "/me" was used).

=cut

sub action {
	my ($self, $network, $channel, $message) = @_;
	$self->_send({do => "action", params => [$network, $channel, $message]});
	my $response = $self->_read();
	if($response->{success}) {
		return 1;
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<sendNames($network, $channel)>

Requests a NAMES command being sent for the given channel on the given network.
After this, a NAMES event will be produced using the normal event system
described below, if the IRC server behaves correctly. Calls die() if
communication failed.

=cut

sub sendNames {
	my ($self, $network, $channel) = @_;
	$self->_send({do => "names", params => [$network, $channel]});
	my $response = $self->_read();
	if($response->{success}) {
		return 1;
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<sendWhois($network, $nick)>

Requests a WHOIS command being sent for the given nick on the given network.
After this, a WHOIS event will be produced using the normal event system
described below, if the IRC server behaves correctly. Calls die() if
communication failed.

=cut

sub sendWhois {
	my ($self, $network, $nick) = @_;
	$self->_send({do => "whois", params => [$network, $nick]});
	my $response = $self->_read();
	if($response->{success}) {
		return 1;
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<join($network, $channel)>

Requests a JOIN command being sent for the given channel on the given network.
After this, a JOIN event will be produced using the normal event system
described below, if the IRC server behaves correctly and the channel was not
already joined. Calls die() if communication failed.

=cut

sub join {
	my ($self, $network, $channel) = @_;
	$self->_send({do => "join", params => [$network, $channel]});
	my $response = $self->_read();
	if($response->{success}) {
		return 1;
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<part($network, $channel)>

Requests a PART command being sent for the given channel on the given network.
After this, a PART event will be produced using the normal event system
described below, if the IRC server behaves correctly and the channel was
joined. Calls die() if communication failed.

=cut

sub part {
	my ($self, $network, $channel) = @_;
	$self->_send({do => "part", params => [$network, $channel]});
	my $response = $self->_read();
	if($response->{success}) {
		return 1;
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<getNick($network)>

Requests the current nickname on given network, and returns it. Calls die()
if communication failed.

=cut

sub getNick {
	my ($self, $network) = @_;
	$self->_send({get => "nick", params => [$network]});
	my $response = $self->_read();
	if($response->{success}) {
		return $response->{'nick'};
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

sub _addScope {
	my ($network, $receiver, $sender) = @_;
	return () if(!$network);
	my $scope = [$network];
	if($receiver) {
		push @$scope, $receiver;
		push @$scope, $sender if $sender;
	}
	return scope => \@$scope;
}

=head2 C<doHandshake($name, $version, [$configName])>

Does the optional DaZeus handshake, required for getting configuration later.
If the configuration name is not given, $name is used for it.

=cut

sub doHandshake {
	my ($self, $name, $version, $config) = @_;
	$config ||= $name;
	$self->_send({do => "handshake", params => [$name, $version, 1, $config]});
	my $response = $self->_read();
	if($response->{success}) {
		return 1;
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<getConfig($group, $name)>

Retrieves the given variable from the configuration file and returns
its value. Calls die() if communication failed. $group can be "core" or
"plugin"; "plugin" can only be used if you did a succesful handshake
earlier.

=cut

sub getConfig {
	my ($self, $group, $name) = @_;
	$self->_send({get => "config", params => [$group, $name]});
	my $response = $self->_read();
	if($response->{success}) {
		return $response->{value};
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<getProperty($name, [$network, [$receiver, [$sender]]])>

Retrieves the given variable from the persistent database and returns
its value. Optionally, context can be given for this property request,
so properties stored earlier using a specific scope can be correctly
matched against this request, and the most specific match will be
returned. Calls die() if communication failed.

=cut

sub getProperty {
	my ($self, $name, @scope) = @_;
	$self->_send({do => "property", params => ["get", $name], _addScope(@scope)});
	my $response = $self->_read();
	if($response->{success}) {
		my $value = $response->{'value'};
		# Newer properties are stored as a JSON string, but we try to be backwards compatible...
		$value = eval { thaw(decode_base64($value)) } || eval { decode_json($value) } || $value if defined $value;
		if(ref($value) eq "HASH" && $value->{'__dazeus_Storable_wrapped'}) {
			$value = $value->{'__wrapped_value'};
		}
		return $value;
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<setProperty($name, $value, [$network, [$receiver, [$sender]]])>

Stores the given variable to the persistent database. Optionally, context can
be given for this property, so multiple properties with the same name and
possibly overlapping context can be stored and later returned. This is useful
in situations where you want different settings per network, but also
overriding settings per channel. Calls die() if communication failed.

=cut

sub setProperty {
	my ($self, $name, $value, @scope) = @_;
	$value = encode_json($value);
	$self->_send({do => "property", params => ["set", $name, $value], _addScope(@scope)});
	my $response = $self->_read();
	if($response->{success}) {
		return 1;
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<unsetProperty($name, [$network, [$receiver, [$sender]]])>

Unsets the given variable with given context from the persistent database. If
no variable was found with the exact given context, no variables are removed.
Calls die() if communication failed.

=cut

sub unsetProperty {
	my ($self, $name, @scope) = @_;
	$self->_send({do => "property", params => ["unset", $name], _addScope(@scope)});
	my $response = $self->_read();
	if($response->{success}) {
		return 1;
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<getPropertyKeys($name, $network, [$receiver, [$sender]])>

Retrieves all keys in a given namespace. I.e. if example.foo and example.bar
were stored earlier, and getPropertyKeys("example") is called, "foo" and "bar"
will be returned from this method. Calls die() if communication failed.

=cut

sub getPropertyKeys {
	my ($self, $name, @scope) = @_;
	$self->_send({do => "property", params => ["keys", $name], _addScope(@scope)});
	my $response = $self->_read();
	if($response->{success}) {
		return $response->{keys};
	} else {
		$response->{error} ||= "Request failed, no error";
		croak $response->{error};
	}
}

=head2 C<subscribe($event, [$event, [$event, ..., [$coderef]]])>

Subscribes to the given events. If the last parameter is a code reference, it
will be called automatically every time one of the given events hits, with the
DaZeus object as the first parameter, and the received event as the second.

=cut

sub subscribe {
	my ($self, @events) = @_;
	if(ref($events[$#events]) eq "CODE") {
		my $handler = pop(@events);
		foreach(@events) {
			$self->{handlers}{uc($_)} = $handler;
		}
	}

	$self->_send({do => "subscribe", params => \@events});
	my $response = $self->_read();
	return $response->{added};
}

=head2 C<subscribe_command($command, [$filter], [$coderef])>

Subscribe to the given command. Filter is an optional hashref which looks like
one of:

  {network => 'name'}
  {network => 'name', sender => 'ircnick'}
  {network => 'name', receiver => 'ircnick'}

Multiple subscriptions to the same command with a different filter is possible,
but the last given coderef will be called for all of them.

=cut

sub subscribe_command {
	my ($self, $command, $filter, $coderef) = @_;
	if(ref($filter) eq "CODE") {
		$coderef = $filter;
		undef $filter;
	}

	$self->{command_handlers}{$command} = $coderef;

	my $params = [$command];
	if($filter) {
		push @$params, $filter->{'network'};
		if($filter->{'sender'}) {
			push @$params, "true", $filter->{'sender'};
		} elsif($filter->{'receiver'}) {
			push @$params, "false", $filter->{'receiver'};
		}
	}
	$self->_send({do => 'command', params => $params});
	my $response = $self->_read();
	return $response->{success};
}

=head2 C<unsubscribe($event, [$event, [$event, ...]])>

Unsubscribe from the given events. They will no longer be received, until
subscribe() is called again.

=cut

sub unsubscribe {
	my ($self, @events) = @_;
	$self->_send({do => "unsubscribe", params => \@events});
	my $response = $self->_read();
	return $response->{removed};
}

=head2 C<handleEvent($timeout)>

Returns all events that can be returned as soon as possible, but no longer
than the given $timeout. If $timeout is zero, do not block. If timeout is
undefined, wait forever until the first event arrives.

"As soon as possible" means that if there are cached events already read from
the socket earlier, the socket will not be touched. Otherwise, if events are
available for reading, they will be immediately read. Only if no events were
cached, none were available for reading, and $timeout is not zero will this
function block to retrieve events. (See also handleEvents().)

This method only returns a single event, in order of receiving. For every
returned event, the event handler (if given to subscribe()), is called.

=cut

sub handleEvent {
	my ($self, $timeout) = @_;
	if(@{$self->{events}} == 0) {
		my $packet = $self->_readPacket($timeout);
		if(!$packet) {
			return;
		}
		if(!$packet->{event}) {
			die "Error: Out of bound non-event packet received in handleEvent";
		}
		push @{$self->{events}}, $packet;
	}
	my $event = shift @{$self->{events}};
	my $handler = $self->{handlers}{$event->{event}};
	if($handler) {
		$handler->($self, $event);
	}
	if(lc($event->{event}) eq "command") {
		my $command = $event->{'params'}[3];
		$handler = $self->{command_handlers}{$command};
		if($handler) {
			$handler->($self, @{$event->{'params'}});
		}
	}
	return $event;
}

sub _retrieveFromSocket {
	my ($self) = @_;
	my $size = 1024;
	my $buf;

	if (defined($self->{sock}->recv($buf, $size))) {
		$self->{buffer} .= $buf;
	}

	# On OS X, if the other end closes the socket, recv() still returns success
	# values and sets no error; however, connected() will be undef there
	if(!defined($self->{sock}->connected())) {
	    delete $self->{sock};
	    die $!;
	}
}

sub _findMessage {
	my ($self) = @_;
	my $offset = 0;
	my $message_len = 0;

	# First, find the length of the next message.
	while ($offset < length($self->{buffer})) {
		# Check for a number
		if (substr($self->{buffer}, $offset, 1) =~ /[0-9]/) {
			$message_len *= 10;
			$message_len += substr($self->{buffer}, $offset, 1);
			$offset += 1;
		}
		elsif (substr($self->{buffer}, $offset, 1) =~ /[\n\r]/) {
			$offset += 1;
		}
		else {
			last;
		}
	}

	if ($message_len > 0 and length($self->{buffer}) >= $offset + $message_len) {
		return ($offset, $message_len);
	}
	else {
		return (undef, undef);
	}
}

sub _readPacket {
	use bytes;
	my ($self, $timeout) = @_;
	my $once = $timeout == 0 if(defined $timeout);
	my $stop_time = time() + $timeout if(defined $timeout);

	while ($once || !defined($stop_time) || time() < $stop_time) {
		my ($offset, $message_len) = $self->_findMessage();
		if (defined($offset)) {
			my $json = substr($self->{buffer}, $offset, $message_len);
			$self->{buffer} = substr($self->{buffer}, $offset + $message_len);
			return decode_json($json);
		}
		$self->_retrieveFromSocket();
	}
}

=head2 C<handleEvents()>

Handle and return as much events as possible without blocking. Also calls the
event handler for every returned event.

=cut

sub handleEvents {
	my ($self) = @_;
	my @events;
	while(my $event = $self->handleEvent(0)) {
		push @events, $event;
	}
	return @events;
}

# Read incoming JSON requests until a non-event comes in (blocking)
sub _read {
	my ($self) = @_;
	while(1) {
		my $packet = $self->_readPacket();
		if($packet->{'event'}) {
			push @{$self->{events}}, $packet;
		} else {
			return $packet;
		}
	}
}

sub _send {
	my ($self, $msg) = @_;
	my $json = encode_json($msg);
	$self->socket->write(bytes::length($json) . $json . "\r\n");
}

1;

__END__

=head1 AUTHOR

Sjors Gielen, E<lt>dazeus@sjorsgielen.nlE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by Sjors Gielen
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut

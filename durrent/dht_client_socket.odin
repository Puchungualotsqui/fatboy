package durrent

import "core:net"
import "core:time"

dht_configure_socket :: proc(socket: net.UDP_Socket, timeout: time.Duration) -> DHT_Error {
	if net.set_option(socket, .Receive_Timeout, timeout) != nil || net.set_option(socket, .Send_Timeout, timeout) != nil {
		return .Socket
	}
	return .None
}

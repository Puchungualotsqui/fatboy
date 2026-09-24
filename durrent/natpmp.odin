package durrent

import endian "core:encoding/endian"
import "core:net"
import "core:time"

NAT_PMP_Error :: enum {
	None,
	No_Gateway,
	Socket,
	Send,
	Receive,
	Invalid_Response,
	Rejected,
}

NAT_PMP_Mapping :: struct {
	Gateway:       net.Endpoint,
	Internal_Port:  u16,
	External_Port:  u16,
	Lifetime:       u32,
}

// NAT-PMP is a small UDP protocol commonly implemented by home routers.
// Callers should treat failure as non-fatal: manual forwarding and UPnP IGD are
// valid alternatives.
nat_pmp_map :: proc(internal_port, requested_external_port: u16, lifetime: u32, timeout: time.Duration, opcode: byte) -> (NAT_PMP_Mapping, NAT_PMP_Error) {
	if internal_port == 0 {
		return NAT_PMP_Mapping{}, .Invalid_Response
	}
	interfaces, interface_error := net.enumerate_interfaces(context.allocator)
	if interface_error != nil {
		return NAT_PMP_Mapping{}, .No_Gateway
	}
	defer net.destroy_interfaces(interfaces)

	gateway: net.Endpoint
	found_gateway := false
	for interface in interfaces {
		for address in interface.gateways {
			switch ip in address {
			case net.IP4_Address:
				gateway = net.Endpoint{address = ip, port = 5351}
				found_gateway = true
				break
			case net.IP6_Address:
				{}
			}
			if found_gateway {
				break
			}
		}
		if found_gateway {
			break
		}
	}
	if !found_gateway {
		return NAT_PMP_Mapping{}, .No_Gateway
	}

	socket, socket_error := net.make_unbound_udp_socket(.IP4)
	if socket_error != nil {
		return NAT_PMP_Mapping{}, .Socket
	}
	defer net.close(socket)
	if net.set_option(socket, .Receive_Timeout, timeout) != nil || net.set_option(socket, .Send_Timeout, timeout) != nil {
		return NAT_PMP_Mapping{}, .Socket
	}

	request: [12]byte
	request[0] = 0 // NAT-PMP version
	request[1] = opcode // 1 = UDP mapping, 2 = TCP mapping
	endian.put_u16(request[4:6], .Big, internal_port)
	endian.put_u16(request[6:8], .Big, requested_external_port)
	endian.put_u32(request[8:12], .Big, lifetime)
	if _, send_error := net.send_udp(socket, request[:], gateway); send_error != .None {
		return NAT_PMP_Mapping{}, .Send
	}

	response: [32]byte
	count, source, receive_error := net.recv_udp(socket, response[:])
	if receive_error != .None {
		return NAT_PMP_Mapping{}, .Receive
	}
	if source.address != gateway.address || count < 16 || response[0] != 0 || response[1] != byte(128+opcode) {
		return NAT_PMP_Mapping{}, .Invalid_Response
	}
	result_code, result_ok := endian.get_u16(response[2:4], .Big)
	internal, internal_ok := endian.get_u16(response[8:10], .Big)
	external, external_ok := endian.get_u16(response[10:12], .Big)
	mapped_lifetime, lifetime_ok := endian.get_u32(response[12:16], .Big)
	if !result_ok || !internal_ok || !external_ok || !lifetime_ok || internal != internal_port {
		return NAT_PMP_Mapping{}, .Invalid_Response
	}
	if result_code != 0 {
		return NAT_PMP_Mapping{}, .Rejected
	}
	return NAT_PMP_Mapping{
		Gateway = gateway,
		Internal_Port = internal,
		External_Port = external,
		Lifetime = mapped_lifetime,
	}, .None
}

NAT_PMP_Map_TCP :: proc(internal_port, requested_external_port: u16, lifetime: u32, timeout: time.Duration) -> (NAT_PMP_Mapping, NAT_PMP_Error) {
	return nat_pmp_map(internal_port, requested_external_port, lifetime, timeout, 2)
}

NAT_PMP_Map_UDP :: proc(internal_port, requested_external_port: u16, lifetime: u32, timeout: time.Duration) -> (NAT_PMP_Mapping, NAT_PMP_Error) {
	return nat_pmp_map(internal_port, requested_external_port, lifetime, timeout, 1)
}

package durrent

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Peer_Transport_Kind :: enum {
	TCP,
	UTP,
}

Peer_Transport_Error :: enum {
	None,
	Invalid_Transport,
	Already_Connected,
	Resolve,
	Connect,
	Timeout,
	Disconnected,
	Read,
	Write,
	Out_Of_Memory,
}

Peer_Dial_Job :: struct {
	Mutex:    sync.Mutex,
	Address:  string,
	Socket:   net.TCP_Socket,
	Error:    bool,
	Done:     bool,
	Canceled: bool,
	Detached: bool,
}

Peer_Transport :: struct {
	Kind:          Peer_Transport_Kind,
	Socket:        net.TCP_Socket,
	UTP:           UTP_Connection,
	Connected:     bool,
	Read_Timeout:  time.Duration,
	Write_Timeout: time.Duration,
	Write_Buffer:  [dynamic]byte,
	Pending_Dial:  ^Peer_Dial_Job,
}

Peer_Transport_Begin_Connect :: proc(transport: ^Peer_Transport, address: string) -> Peer_Transport_Error {
	if transport == nil {
		return .Invalid_Transport
	}
	if transport.Connected || transport.Pending_Dial != nil || len(address) == 0 {
		return .Already_Connected if transport.Connected else .Connect
	}
	if transport.Kind != .TCP {
		return .Connect
	}
	job := new(Peer_Dial_Job, context.allocator)
	job.Address = strings.clone(address, context.allocator)
	transport.Pending_Dial = job
	worker := thread.create_and_start_with_data(job, peer_dial_worker, nil, .Normal, true)
	if worker == nil {
		delete(job.Address)
		free(job)
		transport.Pending_Dial = nil
		return .Connect
	}
	return .None
}

// Polls a dial started by Peer_Transport_Begin_Connect. It never blocks: done
// is false while the resolver/TCP worker is still running.
Peer_Transport_Poll_Connect :: proc(transport: ^Peer_Transport, timeout: time.Duration) -> (done: bool, err: Peer_Transport_Error) {
	if transport == nil {
		return false, .Invalid_Transport
	}
	if transport.Connected {
		return true, .None
	}
	if transport.Kind == .UTP {
		utp_error := UTP_Connection_Poll(&transport.UTP)
		if utp_error != .None && utp_error != .Timeout {
			return true, .Connect
		}
		if transport.UTP.State == .Failed || transport.UTP.State == .Closed {
			return true, .Connect
		}
		if transport.UTP.State != .Connected {
			return false, .None
		}
		transport.Connected = true
		transport.Read_Timeout = 100 * time.Millisecond if timeout > 0 else time.Duration(0)
		transport.Write_Timeout = timeout
		return true, .None
	}
	job := transport.Pending_Dial
	if job == nil {
		return true, .Connect
	}
	sync.mutex_lock(&job.Mutex)
	if !job.Done {
		sync.mutex_unlock(&job.Mutex)
		return false, .None
	}
	socket := job.Socket
	dial_failed := job.Error
	sync.mutex_unlock(&job.Mutex)
	transport.Pending_Dial = nil
	delete(job.Address)
	free(job)
	if dial_failed {
		return true, .Resolve
	}
	read_timeout := 100 * time.Millisecond if timeout > 0 else time.Duration(0)
	if timeout > 0 && (net.set_option(socket, .Receive_Timeout, read_timeout) != nil || net.set_option(socket, .Send_Timeout, timeout) != nil) {
		net.close(socket)
		return true, .Timeout
	}
	transport.Socket = socket
	transport.Connected = true
	transport.Read_Timeout = read_timeout
	transport.Write_Timeout = timeout
	return true, .None
}

Peer_Transport_Connect :: proc(transport: ^Peer_Transport, address: string, timeout: time.Duration) -> Peer_Transport_Error {
	if transport == nil {
		return .Invalid_Transport
	}
	if transport.Connected || transport.Pending_Dial != nil || len(address) == 0 {
		return .Already_Connected if transport.Connected else .Connect
	}
	begin_error := Peer_Transport_Begin_Connect(transport, address)
	if begin_error != .None {
		return begin_error
	}
	job := transport.Pending_Dial
	started := time.now()
	for {
		sync.mutex_lock(&job.Mutex)
		done := job.Done
		if done {
			socket := job.Socket
			dial_failed := job.Error
			sync.mutex_unlock(&job.Mutex)
			transport.Pending_Dial = nil
			delete(job.Address)
			free(job)
			if dial_failed {
				return .Resolve
			}
			read_timeout := 100 * time.Millisecond if timeout > 0 else time.Duration(0)
			if timeout > 0 && (net.set_option(socket, .Receive_Timeout, read_timeout) != nil || net.set_option(socket, .Send_Timeout, timeout) != nil) {
				net.close(socket)
				return .Timeout
			}
			transport.Socket = socket
			transport.Connected = true
			transport.Read_Timeout = read_timeout
			transport.Write_Timeout = timeout
			return .None
		}
		if timeout > 0 && time.since(started) >= timeout {
			job.Canceled = true
			job.Detached = true
			sync.mutex_unlock(&job.Mutex)
			transport.Pending_Dial = nil
			return .Timeout
		}
		sync.mutex_unlock(&job.Mutex)
		time.sleep(time.Millisecond)
	}
}

// Peer_Transport_Begin_UTP_Connect opens an outbound BEP 29 stream. uTP is
// UDP based, so DNS is intentionally resolved by the caller before this point.
Peer_Transport_Begin_UTP_Connect :: proc(transport: ^Peer_Transport, remote: net.Endpoint) -> Peer_Transport_Error {
	if transport == nil || transport.Connected || transport.Pending_Dial != nil || transport.UTP.State != .Closed {
		return .Already_Connected if transport != nil && transport.Connected else .Connect
	}
	transport.Kind = .UTP
	utp_error := UTP_Connection_Begin(&transport.UTP, remote)
	if utp_error != .None {
		transport.Kind = .TCP
		return .Connect
	}
	return .None
}

Peer_Transport_Close :: proc(transport: ^Peer_Transport) {
	if transport == nil {
		return
	}
	if transport.Pending_Dial != nil {
		job := transport.Pending_Dial
		sync.mutex_lock(&job.Mutex)
		job.Canceled = true
		if job.Done {
			// A detached worker owns cleanup once it has observed
			// Detached. Do not free the job a second time here.
			if !job.Detached {
				delete(job.Address)
				free(job)
			}
		} else {
			job.Detached = true
		}
		sync.mutex_unlock(&job.Mutex)
		transport.Pending_Dial = nil
	}
	if transport.Kind == .UTP {
		UTP_Connection_Close(&transport.UTP)
	} else if transport.Connected {
		net.close(transport.Socket)
	}
	delete(transport.Write_Buffer)
	transport.Write_Buffer = nil
	transport.Socket = net.TCP_Socket(0)
	transport.Kind = .TCP
	transport.Connected = false
}

peer_dial_worker :: proc(data: rawptr) {
	job := cast(^Peer_Dial_Job)data
	if job == nil {
		return
	}
	socket, dial_error := net.dial_tcp_from_hostname_and_port_string(job.Address)
	sync.mutex_lock(&job.Mutex)
	if job.Canceled {
		if dial_error == nil {
			net.close(socket)
		}
	} else if dial_error == nil {
		job.Socket = socket
	} else {
		job.Error = true
	}
	job.Done = true
	detached := job.Detached
	sync.mutex_unlock(&job.Mutex)
	if detached {
		delete(job.Address)
		free(job)
	}
}

Peer_Transport_Adopt :: proc(transport: ^Peer_Transport, socket: net.TCP_Socket, timeout: time.Duration) -> Peer_Transport_Error {
	if transport == nil || transport.Connected || socket == net.TCP_Socket(0) {
		return .Invalid_Transport
	}
	read_timeout := 100 * time.Millisecond if timeout > 0 else time.Duration(0)
	if timeout > 0 && (net.set_option(socket, .Receive_Timeout, read_timeout) != nil || net.set_option(socket, .Send_Timeout, timeout) != nil) {
		net.close(socket)
		return .Timeout
	}
	transport.Socket = socket
	transport.Connected = true
	transport.Read_Timeout = read_timeout
	transport.Write_Timeout = timeout
	return .None
}

Peer_Transport_Queue :: proc(transport: ^Peer_Transport, data: []byte) -> Peer_Transport_Error {
	if transport == nil {
		return .Invalid_Transport
	}
	if !transport.Connected {
		return .Disconnected
	}
	if transport.Kind == .UTP {
		utp_error := UTP_Connection_Queue(&transport.UTP, data)
		return .None if utp_error == .None else .Write
	}
	append(&transport.Write_Buffer, ..data)
	return .None
}

Peer_Transport_Flush :: proc(transport: ^Peer_Transport) -> Peer_Transport_Error {
	if transport == nil {
		return .Invalid_Transport
	}
	if !transport.Connected {
		return .Disconnected
	}
	if transport.Kind == .UTP {
		utp_error := UTP_Connection_Poll(&transport.UTP)
		if utp_error == .None {
			return .None
		}
		return .Timeout if utp_error == .Timeout else .Write
	}
	if len(transport.Write_Buffer) == 0 {
		return .None
	}
	buffered := len(transport.Write_Buffer)
	sent, send_error := net.send_tcp(transport.Socket, transport.Write_Buffer[:])
	if send_error == net.TCP_Send_Error.Timeout || send_error == net.TCP_Send_Error.Would_Block {
		return .Timeout
	}
	if send_error != net.TCP_Send_Error.None {
		fmt.printf("[DURRENT-WIRE] send failed socket_error=%v sent=%d buffered=%d\n", send_error, sent, buffered)
		transport.Connected = false
		return .Write
	}
	if sent < 0 || sent > len(transport.Write_Buffer) {
		transport.Connected = false
		return .Write
	}
	if sent == len(transport.Write_Buffer) {
		resize(&transport.Write_Buffer, 0)
		return .None
	}
	if sent > 0 {
		remaining := len(transport.Write_Buffer)-sent
		fmt.printf("[DURRENT-WIRE] send partial sent=%d remaining=%d\n", sent, remaining)
		copy(transport.Write_Buffer[:remaining], transport.Write_Buffer[sent:])
		resize(&transport.Write_Buffer, remaining)
	}
	return .Timeout
}

Peer_Transport_Receive :: proc(transport: ^Peer_Transport, buffer: []byte) -> (int, Peer_Transport_Error) {
	if transport == nil {
		return 0, .Invalid_Transport
	}
	if !transport.Connected {
		return 0, .Disconnected
	}
	if transport.Kind == .UTP {
		utp_error := UTP_Connection_Poll(&transport.UTP)
		if utp_error != .None && utp_error != .Timeout {
			transport.Connected = false
			return 0, .Read
		}
		count := UTP_Connection_Take_Received(&transport.UTP, buffer)
		if count == 0 {
			return 0, .Timeout
		}
		return count, .None
	}
	count, recv_error := net.recv_tcp(transport.Socket, buffer)
	if recv_error == net.TCP_Recv_Error.Timeout || recv_error == net.TCP_Recv_Error.Would_Block {
		return 0, .Timeout
	}
	if recv_error != net.TCP_Recv_Error.None {
		transport.Connected = false
		return count, .Read
	}
	if count == 0 {
		transport.Connected = false
		return 0, .Disconnected
	}
	return count, .None
}

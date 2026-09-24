package durrent

import "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:time"
import "base:runtime"
import curl "vendor:curl"

UPnP_IGD_Protocol :: enum {
	TCP,
	UDP,
}

UPnP_IGD_Error :: enum {
	None,
	Invalid_Argument,
	Socket,
	Send,
	Receive,
	Discovery_Timeout,
	Invalid_SSDP_Response,
	Missing_Location,
	Curl_Init,
	HTTP_Transport,
	HTTP_Timeout,
	HTTP_Status,
	Response_Too_Large,
	Invalid_Description,
	No_WAN_Service,
	Invalid_Control_URL,
	SOAP_Fault,
	Out_Of_Memory,
}

UPnP_IGD_Options :: struct {
	Discovery_Timeout:     time.Duration,
	Discovery_Attempts:    int,
	HTTP_Connect_Timeout:  int,
	HTTP_Total_Timeout:    int,
	Max_Response_Bytes:    int,
}

UPnP_IGD_Default_Options :: proc() -> UPnP_IGD_Options {
	return UPnP_IGD_Options{
		Discovery_Timeout = 3 * time.Second,
		Discovery_Attempts = 2,
		HTTP_Connect_Timeout = 5,
		HTTP_Total_Timeout = 15,
		Max_Response_Bytes = 1024 * 1024,
	}
}

// UPnP_IGD owns all of its string fields. Release it with UPnP_IGD_Destroy.
UPnP_IGD :: struct {
	Location:     string,
	Service_Type: string,
	Control_URL:  string,
}

UPnP_IGD_Mapping :: struct {
	Protocol:          UPnP_IGD_Protocol,
	Internal_Client:   string,
	Internal_Port:     u16,
	External_Port:     u16,
	Remote_Host:       string,
	Description:       string,
	Enabled:           bool,
	Lease_Duration:    u32,
}

UPnP_IGD_HTTP_Body :: struct {
	Data:     [dynamic]byte,
	Limit:    int,
	Overflow: bool,
}

// Returns a LAN IPv4 address suitable for UPnP's NewInternalClient field.
// Prefer an interface with a configured gateway so containers, VPNs, and other
// local-only interfaces do not accidentally receive the router's mapping.
UPnP_IGD_Local_IPv4 :: proc() -> string {
	interfaces, interface_error := net.enumerate_interfaces(context.allocator)
	if interface_error != nil {
		return ""
	}
	defer net.destroy_interfaces(interfaces)
	for interface in interfaces {
		if len(interface.gateways) == 0 {
			continue
		}
		for lease in interface.unicast {
			switch ip in lease.address {
			case net.IP4_Address:
				if upnp_igd_usable_ipv4(ip) {
					return fmt.aprintf("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3])
				}
			case net.IP6_Address:
				{}
			}
		}
	}
	// Some operating systems do not expose gateway information through the
	// interface API. Fall back to any non-loopback, non-multicast IPv4 address.
	for interface in interfaces {
		for lease in interface.unicast {
			switch ip in lease.address {
			case net.IP4_Address:
				if upnp_igd_usable_ipv4(ip) {
					return fmt.aprintf("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3])
				}
			case net.IP6_Address:
				{}
			}
		}
	}
	return ""
}

upnp_igd_usable_ipv4 :: proc(ip: net.IP4_Address) -> bool {
	return ip[0] != 0 && ip[0] != 127 && ip[0] < 224
}

UPnP_IGD_Destroy :: proc(igd: ^UPnP_IGD) {
	if igd == nil {
		return
	}
	if len(igd.Location) > 0 {
		delete(igd.Location)
	}
	if len(igd.Service_Type) > 0 {
		delete(igd.Service_Type)
	}
	if len(igd.Control_URL) > 0 {
		delete(igd.Control_URL)
	}
	igd^ = UPnP_IGD{}
}

// UPnP_IGD_Discover sends an SSDP M-SEARCH for an Internet Gateway Device and
// fetches the matching device description before returning its WAN service.
UPnP_IGD_Discover :: proc(options := UPnP_IGD_Options{Discovery_Timeout = 3 * time.Second, Discovery_Attempts = 2, HTTP_Connect_Timeout = 5, HTTP_Total_Timeout = 15, Max_Response_Bytes = 1024 * 1024}) -> (UPnP_IGD, UPnP_IGD_Error) {
	timeout := options.Discovery_Timeout if options.Discovery_Timeout > 0 else UPnP_IGD_Default_Options().Discovery_Timeout
	attempts := options.Discovery_Attempts if options.Discovery_Attempts > 0 else UPnP_IGD_Default_Options().Discovery_Attempts

	socket, socket_error := net.make_unbound_udp_socket(.IP4)
	if socket_error != nil {
		return UPnP_IGD{}, .Socket
	}
	defer net.close(socket)
	if net.set_option(socket, .Receive_Timeout, timeout) != nil || net.set_option(socket, .Send_Timeout, timeout) != nil {
		return UPnP_IGD{}, .Socket
	}

	request := "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
	multicast := net.Endpoint{address = net.IP4_Address{239, 255, 255, 250}, port = 1900}
	response: [8192]byte
	found_response := false
	for attempt := 0; attempt < attempts; attempt += 1 {
		if _, send_error := net.send_udp(socket, transmute([]byte)request, multicast); send_error != .None {
			return UPnP_IGD{}, .Send
		}
		count, _, receive_error := net.recv_udp(socket, response[:])
		if receive_error == .Timeout || receive_error == .Would_Block {
			continue
		}
		if receive_error != .None {
			return UPnP_IGD{}, .Receive
		}
		found_response = true
		location, parse_error := upnp_igd_ssdp_location(string(response[:count]))
		if parse_error != .None {
			continue
		}
		defer delete(location)
		return UPnP_IGD_Describe(location, options)
	}
	if !found_response {
		return UPnP_IGD{}, .Discovery_Timeout
	}
	return UPnP_IGD{}, .Invalid_SSDP_Response
}

// UPnP_IGD_Describe fetches a device-description URL and finds a
// WANIPConnection or WANPPPConnection service control endpoint.
UPnP_IGD_Describe :: proc(location: string, options := UPnP_IGD_Options{Discovery_Timeout = 3 * time.Second, Discovery_Attempts = 2, HTTP_Connect_Timeout = 5, HTTP_Total_Timeout = 15, Max_Response_Bytes = 1024 * 1024}) -> (UPnP_IGD, UPnP_IGD_Error) {
	if !upnp_igd_url_supported(location) {
		return UPnP_IGD{}, .Invalid_Control_URL
	}
	body, _, request_error := upnp_igd_http_request(location, "", "", options)
	defer delete(body)
	if request_error != .None {
		return UPnP_IGD{}, request_error
	}

	service_type, control_path, service_error := upnp_igd_find_wan_service(string(body[:]))
	if service_error != .None {
		return UPnP_IGD{}, service_error
	}
	defer delete(control_path)

	url_base, has_url_base := upnp_igd_xml_element_value(string(body[:]), "URLBase")
	if has_url_base {
		defer delete(url_base)
	}
	base := url_base if has_url_base && len(url_base) > 0 else location
	control_url, resolve_error := upnp_igd_resolve_url(base, control_path)
	if resolve_error != .None {
		delete(service_type)
		return UPnP_IGD{}, resolve_error
	}

	return UPnP_IGD{
		Location = strings.clone(location, context.allocator),
		Service_Type = service_type,
		Control_URL = control_url,
	}, .None
}

// UPnP_IGD_Add_Port_Mapping creates or renews a TCP or UDP port mapping.
// Internal_Client must be the LAN address that will receive the traffic.
UPnP_IGD_Add_Port_Mapping :: proc(igd: ^UPnP_IGD, mapping: UPnP_IGD_Mapping, options := UPnP_IGD_Options{Discovery_Timeout = 3 * time.Second, Discovery_Attempts = 2, HTTP_Connect_Timeout = 5, HTTP_Total_Timeout = 15, Max_Response_Bytes = 1024 * 1024}) -> UPnP_IGD_Error {
	if igd == nil || len(igd.Control_URL) == 0 || len(igd.Service_Type) == 0 || len(mapping.Internal_Client) == 0 || mapping.Internal_Port == 0 || mapping.External_Port == 0 {
		return .Invalid_Argument
	}

	body := upnp_igd_add_mapping_body(igd.Service_Type, mapping)
	defer delete(body)
	return upnp_igd_soap_request(igd, "AddPortMapping", string(body[:]), options)
}

// UPnP_IGD_Delete_Port_Mapping removes a TCP or UDP mapping by external port.
UPnP_IGD_Delete_Port_Mapping :: proc(igd: ^UPnP_IGD, external_port: u16, protocol: UPnP_IGD_Protocol, remote_host := "", options := UPnP_IGD_Options{Discovery_Timeout = 3 * time.Second, Discovery_Attempts = 2, HTTP_Connect_Timeout = 5, HTTP_Total_Timeout = 15, Max_Response_Bytes = 1024 * 1024}) -> UPnP_IGD_Error {
	if igd == nil || len(igd.Control_URL) == 0 || len(igd.Service_Type) == 0 || external_port == 0 {
		return .Invalid_Argument
	}

	body := upnp_igd_delete_mapping_body(igd.Service_Type, external_port, protocol, remote_host)
	defer delete(body)
	return upnp_igd_soap_request(igd, "DeletePortMapping", string(body[:]), options)
}

upnp_igd_soap_request :: proc(igd: ^UPnP_IGD, action, payload: string, options: UPnP_IGD_Options) -> UPnP_IGD_Error {
	soap_action := fmt.aprintf("\"%s#%s\"", igd.Service_Type, action)
	defer delete(soap_action)
	response, status, request_error := upnp_igd_http_request(igd.Control_URL, soap_action, payload, options)
	defer delete(response)
	if request_error != .None {
		if request_error == .HTTP_Status && upnp_igd_contains_case_insensitive(string(response[:]), "<fault") {
			return .SOAP_Fault
		}
		return request_error
	}
	if upnp_igd_contains_case_insensitive(string(response[:]), "<fault") {
		return .SOAP_Fault
	}
	if status < 200 || status >= 300 {
		return .HTTP_Status
	}
	return .None
}

upnp_igd_http_request :: proc(url, soap_action, payload: string, options: UPnP_IGD_Options) -> ([dynamic]byte, int, UPnP_IGD_Error) {
	if !upnp_igd_url_supported(url) {
		return nil, 0, .Invalid_Control_URL
	}
	handle := curl.easy_init()
	if handle == nil {
		return nil, 0, .Curl_Init
	}
	defer curl.easy_cleanup(handle)

	url_cstr := strings.clone_to_cstring(url, context.allocator)
	if url_cstr == nil {
		return nil, 0, .Out_Of_Memory
	}
	defer delete(url_cstr)
	body: UPnP_IGD_HTTP_Body
	body.Limit = options.Max_Response_Bytes if options.Max_Response_Bytes > 0 else UPnP_IGD_Default_Options().Max_Response_Bytes
	connect_timeout := options.HTTP_Connect_Timeout if options.HTTP_Connect_Timeout > 0 else UPnP_IGD_Default_Options().HTTP_Connect_Timeout
	total_timeout := options.HTTP_Total_Timeout if options.HTTP_Total_Timeout > 0 else UPnP_IGD_Default_Options().HTTP_Total_Timeout

	curl.easy_setopt(handle, .URL, url_cstr)
	curl.easy_setopt(handle, .FOLLOWLOCATION, 1)
	curl.easy_setopt(handle, .CONNECTTIMEOUT, connect_timeout)
	curl.easy_setopt(handle, .TIMEOUT, total_timeout)
	curl.easy_setopt(handle, .USERAGENT, "durrent/0.1 UPnP-IGD")
	curl.easy_setopt(handle, .WRITEFUNCTION, upnp_igd_http_write_callback)
	curl.easy_setopt(handle, .WRITEDATA, &body)

	headers: ^curl.slist
	if len(soap_action) > 0 {
		action_header := fmt.aprintf("SOAPACTION: %s", soap_action)
		defer delete(action_header)
		action_header_cstr := strings.clone_to_cstring(action_header, context.allocator)
		if action_header_cstr == nil {
			return body.Data, 0, .Out_Of_Memory
		}
		defer delete(action_header_cstr)
		headers = curl.slist_append(headers, "Content-Type: text/xml; charset=\"utf-8\"")
		headers = curl.slist_append(headers, action_header_cstr)
		defer curl.slist_free_all(headers)
		payload_cstr := strings.clone_to_cstring(payload, context.allocator)
		if payload_cstr == nil {
			return body.Data, 0, .Out_Of_Memory
		}
		defer delete(payload_cstr)
		curl.easy_setopt(handle, .HTTPHEADER, headers)
		curl.easy_setopt(handle, .POST, libc.long(1))
		curl.easy_setopt(handle, .POSTFIELDSIZE, libc.long(len(payload)))
		curl.easy_setopt(handle, .COPYPOSTFIELDS, cast(rawptr)payload_cstr)
	}

	transport_result := curl.easy_perform(handle)
	status: libc.long
	curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
	if body.Overflow {
		return body.Data, int(status), .Response_Too_Large
	}
	if transport_result == .E_OPERATION_TIMEDOUT {
		return body.Data, int(status), .HTTP_Timeout
	}
	if transport_result != .E_OK {
		return body.Data, int(status), .HTTP_Transport
	}
	if status < 200 || status >= 300 {
		return body.Data, int(status), .HTTP_Status
	}
	return body.Data, int(status), .None
}

upnp_igd_http_write_callback :: proc "c" (ptr: rawptr, element_size, element_count: uint, user_data: rawptr) -> uint {
	context = runtime.default_context()
	if ptr == nil || user_data == nil {
		return 0
	}
	body := cast(^UPnP_IGD_HTTP_Body)user_data
	actual_size := element_size * element_count
	if actual_size == 0 {
		return 0
	}
	if body.Limit < 0 || len(body.Data) > body.Limit-int(actual_size) {
		body.Overflow = true
		return 0
	}
	data := mem.slice_ptr(cast(^byte)ptr, int(actual_size))
	append(&body.Data, ..data)
	return actual_size
}

upnp_igd_ssdp_location :: proc(response: string) -> (string, UPnP_IGD_Error) {
	first_line_end := upnp_igd_find_byte(response, '\n', 0)
	if first_line_end < 0 || !upnp_igd_contains_case_insensitive(response[:first_line_end], " 200") {
		return "", .Invalid_SSDP_Response
	}
	line_start := first_line_end + 1
	for line_start < len(response) {
		line_end := upnp_igd_find_byte(response, '\n', line_start)
		if line_end < 0 {
			line_end = len(response)
		}
		line := upnp_igd_trim(response[line_start:line_end])
		colon := upnp_igd_find_byte(line, ':', 0)
		if colon > 0 && upnp_igd_equal_case_insensitive(upnp_igd_trim(line[:colon]), "location") {
			location := upnp_igd_trim(line[colon+1:])
			if len(location) == 0 {
				return "", .Missing_Location
			}
			return strings.clone(location, context.allocator), .None
		}
		line_start = line_end + 1
	}
	return "", .Missing_Location
}

upnp_igd_find_wan_service :: proc(description: string) -> (string, string, UPnP_IGD_Error) {
	search_at := 0
	for search_at < len(description) {
		start := upnp_igd_find_case_insensitive_from(description, "<service", search_at)
		if start < 0 {
			break
		}
		after_name := start + len("<service")
		if after_name < len(description) && description[after_name] != '>' && description[after_name] != ' ' && description[after_name] != '\t' && description[after_name] != '\r' && description[after_name] != '\n' {
			search_at = after_name
			continue
		}
		open_end := upnp_igd_find_byte(description, '>', after_name)
		if open_end < 0 {
			return "", "", .Invalid_Description
		}
		end := upnp_igd_find_case_insensitive_from(description, "</service>", open_end+1)
		if end < 0 {
			return "", "", .Invalid_Description
		}
		service := description[open_end+1:end]
		service_type, has_type := upnp_igd_xml_element_value(service, "serviceType")
		control_url, has_control := upnp_igd_xml_element_value(service, "controlURL")
		if has_type && has_control && (upnp_igd_contains_case_insensitive(service_type, "wanipconnection") || upnp_igd_contains_case_insensitive(service_type, "wanpppconnection")) {
			if len(control_url) == 0 {
				delete(service_type)
				delete(control_url)
				return "", "", .Invalid_Description
			}
			return service_type, control_url, .None
		}
		if has_type {
			delete(service_type)
		}
		if has_control {
			delete(control_url)
		}
		search_at = end + len("</service>")
	}
	return "", "", .No_WAN_Service
}

upnp_igd_xml_element_value :: proc(xml, name: string) -> (string, bool) {
	needle := fmt.aprintf("<%s", name)
	defer delete(needle)
	search_at := 0
	for search_at < len(xml) {
		start := upnp_igd_find_case_insensitive_from(xml, needle, search_at)
		if start < 0 {
			return "", false
		}
		after_name := start + len(needle)
		if after_name < len(xml) && xml[after_name] != '>' && xml[after_name] != ' ' && xml[after_name] != '\t' && xml[after_name] != '\r' && xml[after_name] != '\n' {
			search_at = after_name
			continue
		}
		open_end := upnp_igd_find_byte(xml, '>', after_name)
		if open_end < 0 {
			return "", false
		}
		close := fmt.aprintf("</%s>", name)
		defer delete(close)
		close_start := upnp_igd_find_case_insensitive_from(xml, close, open_end+1)
		if close_start < 0 {
			return "", false
		}
		return strings.clone(upnp_igd_trim(xml[open_end+1:close_start]), context.allocator), true
	}
	return "", false
}

upnp_igd_resolve_url :: proc(base, path: string) -> (string, UPnP_IGD_Error) {
	if upnp_igd_url_supported(path) {
		return strings.clone(path, context.allocator), .None
	}
	if !upnp_igd_url_supported(base) || len(path) == 0 {
		return "", .Invalid_Control_URL
	}
	origin_end := upnp_igd_find_byte(base, '/', len("http://"))
	if len(base) >= len("https://") && base[:len("https://")] == "https://" {
		origin_end = upnp_igd_find_byte(base, '/', len("https://"))
	}
	if origin_end < 0 {
		origin_end = len(base)
	}
	if path[0] == '/' {
		return fmt.aprintf("%s%s", base[:origin_end], path), .None
	}
	base_end := len(base)
	for index := 0; index < len(base); index += 1 {
		if base[index] == '?' || base[index] == '#' {
			base_end = index
			break
		}
	}
	last_slash := origin_end
	for index := origin_end; index < base_end; index += 1 {
		if base[index] == '/' {
			last_slash = index
		}
	}
	return fmt.aprintf("%s/%s", base[:last_slash], path), .None
}

upnp_igd_add_mapping_body :: proc(service_type: string, mapping: UPnP_IGD_Mapping) -> [dynamic]byte {
	body: [dynamic]byte
	upnp_igd_append_soap_action_open(&body, "AddPortMapping", service_type)
	upnp_igd_append_xml_element(&body, "NewRemoteHost", mapping.Remote_Host)
	upnp_igd_append_xml_number_element(&body, "NewExternalPort", u64(mapping.External_Port))
	upnp_igd_append_xml_element(&body, "NewProtocol", upnp_igd_protocol_name(mapping.Protocol))
	upnp_igd_append_xml_number_element(&body, "NewInternalPort", u64(mapping.Internal_Port))
	upnp_igd_append_xml_element(&body, "NewInternalClient", mapping.Internal_Client)
	upnp_igd_append_xml_element(&body, "NewEnabled", "1" if mapping.Enabled else "0")
	upnp_igd_append_xml_element(&body, "NewPortMappingDescription", mapping.Description)
	upnp_igd_append_xml_number_element(&body, "NewLeaseDuration", u64(mapping.Lease_Duration))
	upnp_igd_append_xml(&body, "</u:AddPortMapping></s:Body></s:Envelope>")
	return body
}

upnp_igd_delete_mapping_body :: proc(service_type: string, external_port: u16, protocol: UPnP_IGD_Protocol, remote_host: string) -> [dynamic]byte {
	body: [dynamic]byte
	upnp_igd_append_soap_action_open(&body, "DeletePortMapping", service_type)
	upnp_igd_append_xml_element(&body, "NewRemoteHost", remote_host)
	upnp_igd_append_xml_number_element(&body, "NewExternalPort", u64(external_port))
	upnp_igd_append_xml_element(&body, "NewProtocol", upnp_igd_protocol_name(protocol))
	upnp_igd_append_xml(&body, "</u:DeletePortMapping></s:Body></s:Envelope>")
	return body
}

upnp_igd_append_soap_action_open :: proc(body: ^[dynamic]byte, action, service_type: string) {
	upnp_igd_append_xml(body, "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:")
	upnp_igd_append_xml(body, action)
	upnp_igd_append_xml(body, " xmlns:u=\"")
	upnp_igd_append_xml_escaped(body, service_type)
	upnp_igd_append_xml(body, "\">")
}

upnp_igd_append_xml_element :: proc(body: ^[dynamic]byte, name, value: string) {
	upnp_igd_append_xml(body, "<")
	upnp_igd_append_xml(body, name)
	upnp_igd_append_xml(body, ">")
	upnp_igd_append_xml_escaped(body, value)
	upnp_igd_append_xml(body, "</")
	upnp_igd_append_xml(body, name)
	upnp_igd_append_xml(body, ">")
}

upnp_igd_append_xml_number_element :: proc(body: ^[dynamic]byte, name: string, value: u64) {
	upnp_igd_append_xml(body, "<")
	upnp_igd_append_xml(body, name)
	upnp_igd_append_xml(body, ">")
	upnp_igd_append_decimal(body, value)
	upnp_igd_append_xml(body, "</")
	upnp_igd_append_xml(body, name)
	upnp_igd_append_xml(body, ">")
}

upnp_igd_append_decimal :: proc(body: ^[dynamic]byte, value: u64) {
	if value == 0 {
		append(body, byte('0'))
		return
	}
	digits: [20]byte
	count := 0
	remaining := value
	for remaining > 0 {
		digits[count] = byte(remaining % 10) + '0'
		remaining /= 10
		count += 1
	}
	for index := count - 1; index >= 0; index -= 1 {
		append(body, digits[index])
	}
}

upnp_igd_append_xml :: proc(body: ^[dynamic]byte, value: string) {
	append(body, ..transmute([]byte)value)
}

upnp_igd_append_xml_escaped :: proc(body: ^[dynamic]byte, value: string) {
	for character in value {
		switch character {
		case '&': upnp_igd_append_xml(body, "&amp;")
		case '<': upnp_igd_append_xml(body, "&lt;")
		case '>': upnp_igd_append_xml(body, "&gt;")
		case '\"': upnp_igd_append_xml(body, "&quot;")
		case '\'': upnp_igd_append_xml(body, "&apos;")
		case: append(body, byte(character))
		}
	}
}

upnp_igd_protocol_name :: proc(protocol: UPnP_IGD_Protocol) -> string {
	return "TCP" if protocol == .TCP else "UDP"
}

upnp_igd_url_supported :: proc(url: string) -> bool {
	return (len(url) >= 7 && url[:7] == "http://") || (len(url) >= 8 && url[:8] == "https://")
}

upnp_igd_contains_case_insensitive :: proc(value, needle: string) -> bool {
	return upnp_igd_find_case_insensitive_from(value, needle, 0) >= 0
}

upnp_igd_find_case_insensitive_from :: proc(value, needle: string, start: int) -> int {
	if len(needle) == 0 {
		return start
	}
	search_start := start if start >= 0 else 0
	for index := search_start; index+len(needle) <= len(value); index += 1 {
		matched := true
		for offset := 0; offset < len(needle); offset += 1 {
			if upnp_igd_ascii_lower(value[index+offset]) != upnp_igd_ascii_lower(needle[offset]) {
				matched = false
				break
			}
		}
		if matched {
			return index
		}
	}
	return -1
}

upnp_igd_equal_case_insensitive :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for index := 0; index < len(a); index += 1 {
		if upnp_igd_ascii_lower(a[index]) != upnp_igd_ascii_lower(b[index]) {
			return false
		}
	}
	return true
}

upnp_igd_ascii_lower :: proc(value: byte) -> byte {
	return value + ('a' - 'A') if value >= 'A' && value <= 'Z' else value
}

upnp_igd_find_byte :: proc(value: string, needle: byte, start: int) -> int {
	for index := start; index < len(value); index += 1 {
		if value[index] == needle {
			return index
		}
	}
	return -1
}

upnp_igd_trim :: proc(value: string) -> string {
	start := 0
	end := len(value)
	for start < end && (value[start] == ' ' || value[start] == '\t' || value[start] == '\r' || value[start] == '\n') {
		start += 1
	}
	for end > start && (value[end-1] == ' ' || value[end-1] == '\t' || value[end-1] == '\r' || value[end-1] == '\n') {
		end -= 1
	}
	return value[start:end]
}

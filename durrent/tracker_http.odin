package durrent

import "core:c/libc"
import "core:mem"
import "core:strings"
import "base:runtime"
import curl "vendor:curl"

Tracker_HTTP_Options :: struct {
	Connect_Timeout_Seconds: int,
	Total_Timeout_Seconds:   int,
	Max_Redirects:           int,
	Max_Response_Bytes:      int,
}

Tracker_HTTP_Default_Options :: proc() -> Tracker_HTTP_Options {
	return Tracker_HTTP_Options{
		Connect_Timeout_Seconds = 10,
		Total_Timeout_Seconds = 30,
		Max_Redirects = 5,
		Max_Response_Bytes = 4 * 1024 * 1024,
	}
}

Tracker_HTTP_Error :: enum {
	None,
	Invalid_URL,
	Unsupported_Scheme,
	Curl_Init,
	Transport,
	Timeout,
	HTTP_Status,
	Response_Too_Large,
	Invalid_Response,
	Tracker_Failure,
	Out_Of_Memory,
}

Tracker_HTTP_Body :: struct {
	Data:      [dynamic]byte,
	Limit:     int,
	Overflow:  bool,
}

Tracker_HTTP_Announce :: proc(
	base_url: string,
	request: Tracker_Announce_Request,
	options := Tracker_HTTP_Options{Connect_Timeout_Seconds = 10, Total_Timeout_Seconds = 30, Max_Redirects = 5, Max_Response_Bytes = 4 * 1024 * 1024},
) -> (Tracker_Announce_Response, int, Tracker_HTTP_Error) {
	if !tracker_http_url_supported(base_url) {
		return Tracker_Announce_Response{}, 0, .Unsupported_Scheme
	}
	url, url_error := Tracker_Build_Announce_URL(base_url, request)
	if url_error != .None {
		return Tracker_Announce_Response{}, 0, .Invalid_URL
	}
	defer delete(url)

	handle := curl.easy_init()
	if handle == nil {
		return Tracker_Announce_Response{}, 0, .Curl_Init
	}
	defer curl.easy_cleanup(handle)
	url_cstr := strings_clone_to_cstring(transmute(string)url)
	if url_cstr == nil {
		return Tracker_Announce_Response{}, 0, .Out_Of_Memory
	}
	defer delete(url_cstr)

	body: Tracker_HTTP_Body
	body.Limit = options.Max_Response_Bytes if options.Max_Response_Bytes > 0 else Tracker_HTTP_Default_Options().Max_Response_Bytes
	curl.easy_setopt(handle, .URL, url_cstr)
	curl.easy_setopt(handle, .FOLLOWLOCATION, 1)
	curl.easy_setopt(handle, .MAXREDIRS, options.Max_Redirects)
	curl.easy_setopt(handle, .CONNECTTIMEOUT, options.Connect_Timeout_Seconds)
	curl.easy_setopt(handle, .TIMEOUT, options.Total_Timeout_Seconds)
	curl.easy_setopt(handle, .USERAGENT, "durrent/0.1")
	curl.easy_setopt(handle, .WRITEFUNCTION, tracker_http_write_callback)
	curl.easy_setopt(handle, .WRITEDATA, &body)
	transport_result := curl.easy_perform(handle)
	status: libc.long = 0
	curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
	defer delete(body.Data)

	if body.Overflow {
		return Tracker_Announce_Response{}, int(status), .Response_Too_Large
	}
	if transport_result == .E_OPERATION_TIMEDOUT {
		return Tracker_Announce_Response{}, int(status), .Timeout
	}
	if transport_result != .E_OK {
		return Tracker_Announce_Response{}, int(status), .Transport
	}
	if status < 200 || status >= 300 {
		return Tracker_Announce_Response{}, int(status), .HTTP_Status
	}
	response, response_error := Tracker_Parse_Announce_Response(body.Data[:])
	if response_error == .Tracker_Failure {
		return response, int(status), .Tracker_Failure
	}
	if response_error != .None {
		return Tracker_Announce_Response{}, int(status), .Invalid_Response
	}
	return response, int(status), .None
}

tracker_http_write_callback :: proc "c" (ptr: rawptr, element_size, element_count: uint, user_data: rawptr) -> uint {
	context = runtime.default_context()
	if ptr == nil || user_data == nil {
		return 0
	}
	body := cast(^Tracker_HTTP_Body)user_data
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

tracker_http_url_supported :: proc(url: string) -> bool {
	return (len(url) >= 7 && url[:7] == "http://") || (len(url) >= 8 && url[:8] == "https://")
}

strings_clone_to_cstring :: proc(value: string) -> cstring {
	return strings.clone_to_cstring(value, context.allocator)
}

package durrent

import "core:sync"

Torrent_State :: enum {
	Queued,
	Downloading,
	Paused,
	Completed,
	Seeding,
	Failed,
	Stopped,
}

Torrent_Session_Error_Code :: enum {
	None,
	Unknown,
	Network,
	Protocol,
	Storage,
	Metadata,
	Shutdown,
}

Torrent_Session_Error :: struct {
	Code:    Torrent_Session_Error_Code,
	Message: []byte,
}

Torrent_Cancellation :: struct {
	Requested:   bool,
	Acknowledged: bool,
}

Torrent_Progress :: struct {
	Bytes_Downloaded: u64,
	Bytes_Uploaded:   u64,
	Bytes_Total:      u64,
	Fraction:         f64,
}

Torrent_Speed :: struct {
	Download_Bytes_Per_Second: f64,
	Upload_Bytes_Per_Second:   f64,
}

Torrent_Session_Options :: struct {
	Info_Hash:    Torrent_Hash,
	Name:         []byte,
	Total_Length: u64,
}

Torrent_Session_Snapshot :: struct {
	ID:           u64,
	State:        Torrent_State,
	Progress:     Torrent_Progress,
	Speed:        Torrent_Speed,
	Error:        Torrent_Session_Error,
	Cancellation: Torrent_Cancellation,
}

Torrent_Shutdown_Report :: struct {
	Requested:          bool,
	Completed:          bool,
	Sessions_Total:     u32,
	Sessions_Stopped:   u32,
	Sessions_Already_Stopped: u32,
}

Torrent_Client_Error :: enum {
	None,
	Invalid_Client,
	Already_Initialized,
	Not_Initialized,
	Invalid_Session,
	Invalid_State,
	Invalid_Progress,
	Out_Of_Memory,
}

Torrent_Session :: struct {
	ID:           u64,
	Info_Hash:    Torrent_Hash,
	Name:         []byte,
	Total_Length: u64,
	State:        Torrent_State,
	Bytes_Downloaded: u64,
	Bytes_Uploaded:   u64,
	Download_Bytes_Per_Second: f64,
	Upload_Bytes_Per_Second:   f64,
	Error:        Torrent_Session_Error,
	Cancellation: Torrent_Cancellation,
}

Torrent_Client :: struct {
	Mutex:       sync.Mutex,
	Sessions:    [dynamic]Torrent_Session,
	Next_ID:     u64,
	Initialized: bool,
}

Torrent_Client_Init :: proc(client: ^Torrent_Client) -> Torrent_Client_Error {
	if client == nil {
		return .Invalid_Client
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if client.Initialized {
		return .Already_Initialized
	}
	client.Next_ID = 1
	client.Initialized = true
	return .None
}

Torrent_Client_Destroy :: proc(client: ^Torrent_Client) {
	if client == nil {
		return
	}
	Torrent_Client_Shutdown(client)
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	for &session in client.Sessions {
		Destroy_Torrent_Session(&session)
	}
	delete(client.Sessions)
	client.Next_ID = 0
}

Torrent_Client_Add_Session :: proc(client: ^Torrent_Client, options: Torrent_Session_Options) -> (u64, Torrent_Client_Error) {
	if client == nil {
		return 0, .Invalid_Client
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Initialized {
		return 0, .Not_Initialized
	}
	name, name_ok := torrent_clone(options.Name)
	if !name_ok {
		return 0, .Out_Of_Memory
	}
	id := client.Next_ID
	client.Next_ID += 1
	if client.Next_ID == 0 {
		client.Next_ID = 1
	}
	append(&client.Sessions, Torrent_Session{
		ID = id,
		Info_Hash = options.Info_Hash,
		Name = name,
		Total_Length = options.Total_Length,
		State = .Queued,
	})
	return id, .None
}

Torrent_Client_Snapshot :: proc(client: ^Torrent_Client, id: u64) -> (Torrent_Session_Snapshot, Torrent_Client_Error) {
	if client == nil {
		return Torrent_Session_Snapshot{}, .Invalid_Client
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Initialized {
		return Torrent_Session_Snapshot{}, .Not_Initialized
	}
	session := torrent_client_find_session(client, id)
	if session == nil {
		return Torrent_Session_Snapshot{}, .Invalid_Session
	}
	result := Torrent_Session_Snapshot{
		ID = session.ID,
		State = session.State,
		Progress = torrent_session_progress(session),
		Speed = Torrent_Speed{
			Download_Bytes_Per_Second = session.Download_Bytes_Per_Second,
			Upload_Bytes_Per_Second = session.Upload_Bytes_Per_Second,
		},
		Cancellation = session.Cancellation,
		Error = Torrent_Session_Error{Code = session.Error.Code},
	}
	if len(session.Error.Message) > 0 {
		message, message_ok := torrent_clone(session.Error.Message)
		if !message_ok {
			return Torrent_Session_Snapshot{}, .Out_Of_Memory
		}
		result.Error.Message = message
	}
	return result, .None
}

Destroy_Torrent_Session_Snapshot :: proc(snapshot: ^Torrent_Session_Snapshot) {
	if snapshot == nil {
		return
	}
	delete(snapshot.Error.Message)
	snapshot^ = Torrent_Session_Snapshot{}
}

Torrent_Client_Start :: proc(client: ^Torrent_Client, id: u64) -> Torrent_Client_Error {
	return torrent_client_transition(client, id, .Downloading, .Queued)
}

Torrent_Client_Pause :: proc(client: ^Torrent_Client, id: u64) -> Torrent_Client_Error {
	return torrent_client_transition(client, id, .Paused, .Downloading)
}

Torrent_Client_Resume :: proc(client: ^Torrent_Client, id: u64) -> Torrent_Client_Error {
	return torrent_client_transition(client, id, .Downloading, .Paused)
}

Torrent_Client_Complete :: proc(client: ^Torrent_Client, id: u64) -> Torrent_Client_Error {
	return torrent_client_transition(client, id, .Completed, .Downloading)
}

Torrent_Client_Begin_Seeding :: proc(client: ^Torrent_Client, id: u64) -> Torrent_Client_Error {
	return torrent_client_transition(client, id, .Seeding, .Completed)
}

Torrent_Client_Retry :: proc(client: ^Torrent_Client, id: u64) -> Torrent_Client_Error {
	if client == nil {
		return .Invalid_Client
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Initialized {
		return .Not_Initialized
	}
	session := torrent_client_find_session(client, id)
	if session == nil {
		return .Invalid_Session
	}
	if session.State != .Failed {
		return .Invalid_State
	}
	session.State = .Queued
	Destroy_Torrent_Session_Error(&session.Error)
	session.Cancellation = Torrent_Cancellation{}
	return .None
}

Torrent_Client_Cancel :: proc(client: ^Torrent_Client, id: u64) -> Torrent_Client_Error {
	if client == nil {
		return .Invalid_Client
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Initialized {
		return .Not_Initialized
	}
	session := torrent_client_find_session(client, id)
	if session == nil {
		return .Invalid_Session
	}
	if session.State == .Stopped {
		return .Invalid_State
	}
	session.Cancellation = Torrent_Cancellation{Requested = true, Acknowledged = true}
	session.State = .Stopped
	return .None
}

Torrent_Client_Fail :: proc(client: ^Torrent_Client, id: u64, code: Torrent_Session_Error_Code, message: []byte) -> Torrent_Client_Error {
	if client == nil {
		return .Invalid_Client
	}
	if code == .None {
		return .Invalid_State
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Initialized {
		return .Not_Initialized
	}
	session := torrent_client_find_session(client, id)
	if session == nil {
		return .Invalid_Session
	}
	if session.State == .Stopped {
		return .Invalid_State
	}
	message_copy, message_ok := torrent_clone(message)
	if !message_ok {
		return .Out_Of_Memory
	}
	Destroy_Torrent_Session_Error(&session.Error)
	session.Error = Torrent_Session_Error{Code = code, Message = message_copy}
	session.State = .Failed
	return .None
}

Torrent_Client_Report_Progress :: proc(
	client: ^Torrent_Client,
	id: u64,
	bytes_downloaded, bytes_uploaded: u64,
	download_speed, upload_speed: f64,
) -> Torrent_Client_Error {
	if client == nil {
		return .Invalid_Client
	}
	if download_speed < 0 || upload_speed < 0 {
		return .Invalid_Progress
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Initialized {
		return .Not_Initialized
	}
	session := torrent_client_find_session(client, id)
	if session == nil {
		return .Invalid_Session
	}
	if bytes_downloaded > session.Total_Length || session.State == .Stopped {
		return .Invalid_Progress
	}
	session.Bytes_Downloaded = bytes_downloaded
	session.Bytes_Uploaded = bytes_uploaded
	session.Download_Bytes_Per_Second = download_speed
	session.Upload_Bytes_Per_Second = upload_speed
	return .None
}

Torrent_Client_Shutdown :: proc(client: ^Torrent_Client) -> (Torrent_Shutdown_Report, Torrent_Client_Error) {
	if client == nil {
		return Torrent_Shutdown_Report{}, .Invalid_Client
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Initialized {
		return Torrent_Shutdown_Report{}, .Not_Initialized
	}
	report := Torrent_Shutdown_Report{
		Requested = true,
		Completed = true,
		Sessions_Total = u32(len(client.Sessions)),
	}
	for &session in client.Sessions {
		if session.State == .Stopped {
			report.Sessions_Already_Stopped += 1
			continue
		}
		session.State = .Stopped
		report.Sessions_Stopped += 1
	}
	client.Initialized = false
	return report, .None
}

Destroy_Torrent_Session :: proc(session: ^Torrent_Session) {
	if session == nil {
		return
	}
	delete(session.Name)
	Destroy_Torrent_Session_Error(&session.Error)
	session^ = Torrent_Session{}
}

Destroy_Torrent_Session_Error :: proc(error: ^Torrent_Session_Error) {
	if error == nil {
		return
	}
	delete(error.Message)
	error^ = Torrent_Session_Error{}
}

torrent_client_find_session :: proc(client: ^Torrent_Client, id: u64) -> ^Torrent_Session {
	for &session in client.Sessions {
		if session.ID == id {
			return &session
		}
	}
	return nil
}

torrent_client_transition :: proc(client: ^Torrent_Client, id: u64, target, expected: Torrent_State) -> Torrent_Client_Error {
	if client == nil {
		return .Invalid_Client
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Initialized {
		return .Not_Initialized
	}
	session := torrent_client_find_session(client, id)
	if session == nil {
		return .Invalid_Session
	}
	if session.State != expected {
		return .Invalid_State
	}
	session.State = target
	return .None
}

torrent_session_progress :: proc(session: ^Torrent_Session) -> Torrent_Progress {
	if session == nil {
		return Torrent_Progress{}
	}
	fraction: f64
	if session.Total_Length == 0 {
		fraction = 1.0 if session.State == .Completed || session.State == .Seeding else 0.0
	} else {
		fraction = f64(session.Bytes_Downloaded) / f64(session.Total_Length)
	}
	return Torrent_Progress{
		Bytes_Downloaded = session.Bytes_Downloaded,
		Bytes_Uploaded = session.Bytes_Uploaded,
		Bytes_Total = session.Total_Length,
		Fraction = fraction,
	}
}

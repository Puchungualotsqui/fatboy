package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "base:runtime"


REALDEBRID_OAUTH_BASE :: "https://api.real-debrid.com/oauth/v2"
REALDEBRID_OPEN_SOURCE_CLIENT_ID :: "X245A4XAIBGVM"
REALDEBRID_DEVICE_GRANT_TYPE :: "http://oauth.net/grant_type/device/1.0"


RealDebridDeviceCode :: struct {
    device_code:     string `json:"device_code"`,
    user_code:       string `json:"user_code"`,
    interval:        int    `json:"interval"`,
    expires_in:      int    `json:"expires_in"`,
    verification_url: string `json:"verification_url"`,
}


RealDebridDeviceCredentials :: struct {
    client_id:     string `json:"client_id"`,
    client_secret: string `json:"client_secret"`,
}


RealDebridTokenResponse :: struct {
    access_token:  string `json:"access_token"`,
    refresh_token: string `json:"refresh_token"`,
    expires_in:    int    `json:"expires_in"`,
    token_type:    string `json:"token_type"`,
}


RealDebridAuthData :: struct {
    mutex: sync.Mutex,

    device_code:      string,
    user_code:        string,
    verification_url: string,
    interval:         int,
    expires_in:       int,

    status:        string,
    error_message: string,
    cancelled:     bool,
    success:       bool,

    access_token:  string,
    refresh_token: string,
    client_id:     string,
    client_secret: string,
}


RealDebridAuthSnapshot :: struct {
    status:           string,
    user_code:        string,
    verification_url: string,
}


// ---------------------------------------------------------
// OAuth REST calls
// ---------------------------------------------------------

RDRequestDeviceCode :: proc() -> (RealDebridDeviceCode, RealDebridError) {
    fmt.println("[AUTH] Requesting device code...")
    path := fmt.aprintf(
        "/device/code?client_id=%s&new_credentials=yes",
        REALDEBRID_OPEN_SOURCE_CLIENT_ID,
    )
    defer delete(path)

    body, err := rd_request(
        REALDEBRID_OAUTH_BASE,
        "",
        "GET",
        path,
        "",
    )
    if err.message != "" {
        fmt.printf(
            "[AUTH] Device-code request failed HTTP=%d API=%d: %s\n",
            err.http_status,
            err.api_code,
            err.message,
        )
        return {}, err
    }
    defer delete(body)

    fmt.printf("[AUTH] Device-code response received bytes=%d\n", len(body))
    result: RealDebridDeviceCode
    decode_err := rd_decode(body, &result)
    if decode_err.message != "" {
        fmt.printf("[AUTH] Device-code JSON decode failed: %s\n", decode_err.message)
        return {}, decode_err
    }
    fmt.printf(
        "[AUTH] Device code decoded user_code_length=%d interval=%d expires_in=%d\n",
        len(result.user_code),
        result.interval,
        result.expires_in,
    )
    return result, {}
}


RDGetDeviceCredentials :: proc(device_code: string) -> (RealDebridDeviceCredentials, RealDebridError) {
    fmt.println("[AUTH] Polling device credentials...")
    encoded_client_id := rd_url_encode(REALDEBRID_OPEN_SOURCE_CLIENT_ID)
    defer delete(encoded_client_id)
    encoded_code := rd_url_encode(device_code)
    defer delete(encoded_code)

    path := fmt.aprintf(
        "/device/credentials?client_id=%s&code=%s",
        encoded_client_id,
        encoded_code,
    )
    defer delete(path)

    fmt.println("[AUTH] Calling OAuth credentials endpoint")
    body, err := rd_request(
        REALDEBRID_OAUTH_BASE,
        "",
        "GET",
        path,
        "",
    )
    fmt.println("[AUTH] OAuth credentials endpoint returned to caller")
    if err.message != "" {
        fmt.printf(
            "[AUTH] Credentials poll pending/failed HTTP=%d API=%d: %s\n",
            err.http_status,
            err.api_code,
            err.message,
        )
        fmt.println("[AUTH] Returning pending/failed credentials result")
        return {}, err
    }
    defer delete(body)

    fmt.printf("[AUTH] Credentials response received bytes=%d\n", len(body))
    result: RealDebridDeviceCredentials
    decode_err := rd_decode(body, &result)
    if decode_err.message != "" {
        fmt.printf("[AUTH] Credentials JSON decode failed: %s\n", decode_err.message)
        return {}, decode_err
    }
    fmt.printf(
        "[AUTH] User-bound credentials decoded id_length=%d secret_length=%d\n",
        len(result.client_id),
        len(result.client_secret),
    )
    return result, {}
}


RDExchangeDeviceCode :: proc(
    client_id, client_secret, device_code: string,
) -> (RealDebridTokenResponse, RealDebridError) {
    return rd_exchange_token(
        client_id,
        client_secret,
        device_code,
    )
}


RDRefreshAccessToken :: proc(
    client_id, client_secret, refresh_token: string,
) -> (RealDebridTokenResponse, RealDebridError) {
    return rd_exchange_token(
        client_id,
        client_secret,
        refresh_token,
    )
}


rd_exchange_token :: proc(
    client_id, client_secret, code: string,
) -> (RealDebridTokenResponse, RealDebridError) {
    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)
    defer strings.builder_destroy(&builder)

    first := true
    rd_form_pair(&builder, "client_id", client_id, &first)
    rd_form_pair(&builder, "client_secret", client_secret, &first)
    rd_form_pair(&builder, "code", code, &first)
    rd_form_pair_raw(&builder, "grant_type", REALDEBRID_DEVICE_GRANT_TYPE, &first)

    fmt.printf(
        "[AUTH] Token request parameters client_id_length=%d secret_length=%d code_length=%d grant_type=%s\n",
        len(client_id),
        len(client_secret),
        len(code),
        REALDEBRID_DEVICE_GRANT_TYPE,
    )

    form_body := strings.clone(
        strings.to_string(builder),
        context.allocator,
    )
    defer delete(form_body)

    body, err := rd_request(
        REALDEBRID_OAUTH_BASE,
        "",
        "POST",
        "/token",
        form_body,
    )
    if err.message != "" {
        return {}, err
    }
    defer delete(body)

    result: RealDebridTokenResponse
    decode_err := rd_decode(body, &result)
    if decode_err.message != "" {
        return {}, decode_err
    }
    return result, {}
}


// ---------------------------------------------------------
// Device authorization lifecycle
// ---------------------------------------------------------

StartRealDebridAuth :: proc(app: ^App) -> bool {
    if app == nil || app.auth_thread != nil {
        return false
    }

    data := new(RealDebridAuthData)
    fmt.println("[AUTH] Starting device authorization thread")
    auth_set_status(data, "Requesting Real-Debrid device code...")

    thread_handle := thread.create(realdebrid_auth_proc)
    if thread_handle == nil {
        free(data)
        return false
    }

    thread_handle.data = data
    app.auth_data = data
    app.auth_thread = thread_handle
    thread.start(thread_handle)
    fmt.println("[AUTH] Device authorization thread started")
    return true
}


CancelRealDebridAuth :: proc(app: ^App) {
    if app == nil || app.auth_data == nil {
        return
    }

    sync.mutex_lock(&app.auth_data.mutex)
    app.auth_data.cancelled = true
    delete(app.auth_data.status)
    app.auth_data.status = strings.clone(
        "Cancelling Real-Debrid connection...",
        context.allocator,
    )
    sync.mutex_unlock(&app.auth_data.mutex)
}


ShutdownRealDebridAuth :: proc(app: ^App) {
    if app == nil {
        return
    }

    if app.auth_data != nil {
        sync.mutex_lock(&app.auth_data.mutex)
        app.auth_data.cancelled = true
        sync.mutex_unlock(&app.auth_data.mutex)
    }

    if app.auth_thread != nil {
        thread.destroy(app.auth_thread)
        app.auth_thread = nil
    }

    if app.auth_data != nil {
        realdebrid_auth_data_destroy(app.auth_data)
        free(app.auth_data)
        app.auth_data = nil
    }
}


ProcessRealDebridAuth :: proc(app: ^App) {
    if app == nil || app.auth_thread == nil {
        return
    }
    if !thread.is_done(app.auth_thread) {
        return
    }

    data := app.auth_data
    fmt.println("[AUTH] Authorization thread completed; joining it")
    thread.destroy(app.auth_thread)
    app.auth_thread = nil
    app.auth_data = nil

    if data == nil {
        app.status_message = "Real-Debrid connection returned no data."
        return
    }

    if data.success {
        fmt.println("[AUTH] Authorization succeeded; transferring credentials to app")
        delete(app.rd_key)
        delete(app.rd_refresh_token)
        delete(app.rd_client_id)
        delete(app.rd_client_secret)

        app.rd_key = data.access_token
        app.rd_refresh_token = data.refresh_token
        app.rd_client_id = data.client_id
        app.rd_client_secret = data.client_secret
        app.rd_token_expires_at = time.time_to_unix(time.now()) + i64(data.expires_in)

        data.access_token = ""
        data.refresh_token = ""
        data.client_id = ""
        data.client_secret = ""
        app.status_message = "Real-Debrid connected. Save settings to continue."
    } else if len(data.error_message) > 0 {
        fmt.println("[AUTH] Authorization failed; copying error to app state")
        // The previous status can be a string literal, so do not delete it.
        // Copy the worker-owned error before releasing auth data.
        app.status_message = strings.clone(data.error_message, context.allocator)
    } else {
        app.status_message = "Real-Debrid connection was cancelled."
    }

    realdebrid_auth_data_destroy(data)
    free(data)
    fmt.println("[AUTH] Authorization handoff complete")
}


RealDebridAuthSnapshotForApp :: proc(app: ^App) -> (snapshot: RealDebridAuthSnapshot, active: bool) {
    if app == nil || app.auth_data == nil {
        return {}, false
    }

    data := app.auth_data
    sync.mutex_lock(&data.mutex)
    snapshot.status = strings.clone(data.status, context.allocator)
    snapshot.user_code = strings.clone(data.user_code, context.allocator)
    snapshot.verification_url = strings.clone(data.verification_url, context.allocator)
    sync.mutex_unlock(&data.mutex)
    return snapshot, true
}


DestroyRealDebridAuthSnapshot :: proc(snapshot: ^RealDebridAuthSnapshot) {
    if snapshot == nil {
        return
    }
    if len(snapshot.status) > 0 { delete(snapshot.status) }
    if len(snapshot.user_code) > 0 { delete(snapshot.user_code) }
    if len(snapshot.verification_url) > 0 { delete(snapshot.verification_url) }
}


ClearRealDebridCredentials :: proc(app: ^App) {
    if app == nil {
        return
    }
    if len(app.rd_key) > 0 { delete(app.rd_key) }
    if len(app.rd_refresh_token) > 0 { delete(app.rd_refresh_token) }
    if len(app.rd_client_id) > 0 { delete(app.rd_client_id) }
    if len(app.rd_client_secret) > 0 { delete(app.rd_client_secret) }
    app.rd_token_expires_at = 0
}


EnsureRealDebridAccessToken :: proc(app: ^App) -> bool {
    if app == nil ||
       len(app.rd_key) == 0 ||
       len(app.rd_refresh_token) == 0 ||
       len(app.rd_client_id) == 0 ||
       len(app.rd_client_secret) == 0 {
        return false
    }

    now := time.time_to_unix(time.now())
    if app.rd_token_expires_at > now + 60 {
        return true
    }

    token, err := RDRefreshAccessToken(
        app.rd_client_id,
        app.rd_client_secret,
        app.rd_refresh_token,
    )
    if err.message != "" {
        fmt.printf(
            "[AUTH] Access token refresh failed (HTTP %d, API %d): %s\n",
            err.http_status,
            err.api_code,
            err.message,
        )
        DestroyRealDebridError(&err)
        return false
    }

    if len(token.access_token) == 0 || token.expires_in <= 0 {
        DestroyRealDebridTokenResponse(&token)
        return false
    }

    delete(app.rd_key)
    app.rd_key = token.access_token
    token.access_token = ""

    if len(token.refresh_token) > 0 {
        delete(app.rd_refresh_token)
        app.rd_refresh_token = token.refresh_token
        token.refresh_token = ""
    }

    app.rd_token_expires_at = now + i64(token.expires_in)
    DestroyRealDebridTokenResponse(&token)
    SaveSettings(app)
    return true
}


realdebrid_auth_proc :: proc(t: ^thread.Thread) {
    context = runtime.default_context()

    if t == nil {
        return
    }

    data := cast(^RealDebridAuthData)t.data
    if data == nil {
        return
    }

    fmt.println("[AUTH] Worker requesting device code")
    device, err := RDRequestDeviceCode()
    if err.message != "" {
        auth_fail(data, &err)
        return
    }

    auth_set_device(data, &device)
    fmt.printf(
        "[AUTH] Worker received device code user_code_length=%d verification_url_length=%d\n",
        len(device.user_code),
        len(device.verification_url),
    )
    device_code := strings.clone(device.device_code, context.allocator)
    interval := device.interval
    if interval <= 0 {
        interval = 5
    }
    expires_in := device.expires_in
    if expires_in <= 0 {
        expires_in = 1800
    }
    DestroyRealDebridDeviceCode(&device)

    if len(device_code) == 0 {
        auth_set_error(data, "Real-Debrid returned an empty device code.")
        delete(device_code)
        return
    }
    defer delete(device_code)

    auth_set_status(data, "Open the verification URL and enter the code.")
    fmt.printf(
        "[AUTH] Waiting for authorization interval=%d expires_in=%d\n",
        interval,
        expires_in,
    )
    deadline := time.time_to_unix(time.now()) + i64(expires_in)
    credentials: RealDebridDeviceCredentials

    for {
        if auth_cancelled(data) {
            return
        }
        if time.time_to_unix(time.now()) >= deadline {
            auth_set_error(data, "Real-Debrid device authorization expired.")
            return
        }

        fmt.println("[AUTH] Calling RDGetDeviceCredentials")
        credentials, err = RDGetDeviceCredentials(device_code)
        fmt.println("[AUTH] RDGetDeviceCredentials returned")
        if err.message == "" {
            fmt.println("[AUTH] Device authorization accepted")
            break
        }

        fmt.printf(
            "[AUTH] Authorization not complete; retrying API=%d HTTP=%d\n",
            err.api_code,
            err.http_status,
        )
        DestroyRealDebridError(&err)
        auth_set_status(data, "Waiting for Real-Debrid authorization...")
        time.sleep(time.Duration(interval) * time.Second)
    }

    if len(credentials.client_id) == 0 || len(credentials.client_secret) == 0 {
        DestroyRealDebridDeviceCredentials(&credentials)
        auth_set_error(data, "Real-Debrid returned incomplete client credentials.")
        return
    }

    if auth_cancelled(data) {
        DestroyRealDebridDeviceCredentials(&credentials)
        return
    }

    auth_set_status(data, "Authorization accepted. Requesting access token...")
    fmt.println("[AUTH] Exchanging device code for access token")
    token, token_err := RDExchangeDeviceCode(
        credentials.client_id,
        credentials.client_secret,
        device_code,
    )
    if token_err.message != "" {
        DestroyRealDebridDeviceCredentials(&credentials)
        auth_fail(data, &token_err)
        return
    }

    if len(token.access_token) == 0 || len(token.refresh_token) == 0 {
        DestroyRealDebridDeviceCredentials(&credentials)
        DestroyRealDebridTokenResponse(&token)
        auth_set_error(data, "Real-Debrid returned incomplete token credentials.")
        return
    }

    if auth_cancelled(data) {
        DestroyRealDebridDeviceCredentials(&credentials)
        DestroyRealDebridTokenResponse(&token)
        return
    }

    fmt.printf(
        "[AUTH] Token response accepted access_length=%d refresh_length=%d expires_in=%d\n",
        len(token.access_token),
        len(token.refresh_token),
        token.expires_in,
    )
    sync.mutex_lock(&data.mutex)
    data.access_token = token.access_token
    data.refresh_token = token.refresh_token
    data.client_id = credentials.client_id
    data.client_secret = credentials.client_secret
    data.expires_in = token.expires_in
    data.success = true
    delete(data.status)
    data.status = strings.clone(
        "Real-Debrid connected.",
        context.allocator,
    )
    sync.mutex_unlock(&data.mutex)

    token.access_token = ""
    token.refresh_token = ""
    credentials.client_id = ""
    credentials.client_secret = ""
    DestroyRealDebridTokenResponse(&token)
    DestroyRealDebridDeviceCredentials(&credentials)
}


// ---------------------------------------------------------
// Auth worker helpers
// ---------------------------------------------------------

auth_set_status :: proc(data: ^RealDebridAuthData, status: string) {
    sync.mutex_lock(&data.mutex)
    delete(data.status)
    data.status = strings.clone(status, context.allocator)
    sync.mutex_unlock(&data.mutex)
}


auth_set_error :: proc(data: ^RealDebridAuthData, message: string) {
    sync.mutex_lock(&data.mutex)
    delete(data.error_message)
    delete(data.status)
    data.error_message = strings.clone(message, context.allocator)
    data.status = strings.clone(message, context.allocator)
    sync.mutex_unlock(&data.mutex)
}


auth_set_device :: proc(data: ^RealDebridAuthData, device: ^RealDebridDeviceCode) {
    sync.mutex_lock(&data.mutex)
    data.device_code = strings.clone(device.device_code, context.allocator)
    data.user_code = strings.clone(device.user_code, context.allocator)
    data.verification_url = strings.clone(device.verification_url, context.allocator)
    data.interval = device.interval
    data.expires_in = device.expires_in
    sync.mutex_unlock(&data.mutex)
}


auth_cancelled :: proc(data: ^RealDebridAuthData) -> bool {
    sync.mutex_lock(&data.mutex)
    defer sync.mutex_unlock(&data.mutex)
    return data.cancelled
}


auth_fail :: proc(data: ^RealDebridAuthData, err: ^RealDebridError) {
    if err != nil && len(err.message) > 0 {
        auth_set_error(data, err.message)
        DestroyRealDebridError(err)
    } else {
        auth_set_error(data, "Real-Debrid authorization failed.")
    }
}


realdebrid_auth_data_destroy :: proc(data: ^RealDebridAuthData) {
    if data == nil {
        return
    }
    if len(data.device_code) > 0 { delete(data.device_code) }
    if len(data.user_code) > 0 { delete(data.user_code) }
    if len(data.verification_url) > 0 { delete(data.verification_url) }
    if len(data.status) > 0 { delete(data.status) }
    if len(data.error_message) > 0 { delete(data.error_message) }
    if len(data.access_token) > 0 { delete(data.access_token) }
    if len(data.refresh_token) > 0 { delete(data.refresh_token) }
    if len(data.client_id) > 0 { delete(data.client_id) }
    if len(data.client_secret) > 0 { delete(data.client_secret) }
}


DestroyRealDebridDeviceCode :: proc(value: ^RealDebridDeviceCode) {
    if value == nil { return }
    if len(value.device_code) > 0 { delete(value.device_code) }
    if len(value.user_code) > 0 { delete(value.user_code) }
    if len(value.verification_url) > 0 { delete(value.verification_url) }
}


DestroyRealDebridDeviceCredentials :: proc(value: ^RealDebridDeviceCredentials) {
    if value == nil { return }
    if len(value.client_id) > 0 { delete(value.client_id) }
    if len(value.client_secret) > 0 { delete(value.client_secret) }
}


DestroyRealDebridTokenResponse :: proc(value: ^RealDebridTokenResponse) {
    if value == nil { return }
    if len(value.access_token) > 0 { delete(value.access_token) }
    if len(value.refresh_token) > 0 { delete(value.refresh_token) }
    if len(value.token_type) > 0 { delete(value.token_type) }
}

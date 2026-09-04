package main

import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "base:runtime"

import curl "vendor:curl"


REALDEBRID_API_BASE :: "https://api.real-debrid.com/rest/1.0"
REALDEBRID_USER_AGENT :: "FitDeck/1.0"


// RealDebridClient does not own access_token. The caller must keep the
// token alive for as long as the client is used.
RealDebridClient :: struct {
    access_token: string,
    base_url:     string,
}


NewRealDebridClient :: proc(access_token: string) -> RealDebridClient {
    return RealDebridClient{
        access_token = access_token,
        base_url = REALDEBRID_API_BASE,
    }
}


RealDebridError :: struct {
    http_status:    int,
    api_code:       int,
    message:        string,
    transport_code: int,
}


DestroyRealDebridError :: proc(err: ^RealDebridError) {
    if err == nil {
        return
    }

    if len(err.message) > 0 {
        delete(err.message)
        err.message = ""
    }
}


// ---------------------------------------------------------
// API response models
// ---------------------------------------------------------

RealDebridUser :: struct {
    id:         int       `json:"id"`,
    username:   string    `json:"username"`,
    email:      string    `json:"email"`,
    points:     int       `json:"points"`,
    locale:     string    `json:"locale"`,
    avatar:     string    `json:"avatar"`,
    account_type: string  `json:"type"`,
    premium:    i64       `json:"premium"`,
    expiration: string    `json:"expiration"`,
}


RealDebridLinkCheck :: struct {
    host:       string `json:"host"`,
    link:       string `json:"link"`,
    filename:   string `json:"filename"`,
    filesize:   i64    `json:"filesize"`,
    supported:  bool   `json:"supported"`,
}


RealDebridUnrestrictedLink :: struct {
    id:         string `json:"id"`,
    filename:   string `json:"filename"`,
    mime_type:  string `json:"mimeType"`,
    filesize:   i64    `json:"filesize"`,
    link:       string `json:"link"`,
    host:       string `json:"host"`,
    chunks:     int    `json:"chunks"`,
    crc:        int    `json:"crc"`,
    download:   string `json:"download"`,
    streamable: int    `json:"streamable"`,
}


RealDebridTorrentCreated :: struct {
    id:  string `json:"id"`,
    uri: string `json:"uri"`,
}


RealDebridTorrentSummary :: struct {
    id:       string   `json:"id"`,
    filename: string   `json:"filename"`,
    hash:     string   `json:"hash"`,
    bytes:    i64      `json:"bytes"`,
    host:     string   `json:"host"`,
    split:    int      `json:"split"`,
    progress: f64      `json:"progress"`,
    status:   string   `json:"status"`,
    added:    string   `json:"added"`,
    links:    []string `json:"links"`,
}


RealDebridTorrentFile :: struct {
    id:       int    `json:"id"`,
    path:     string `json:"path"`,
    bytes:    i64    `json:"bytes"`,
    selected: int    `json:"selected"`,
}


RealDebridTorrentInfo :: struct {
    id:             string                   `json:"id"`,
    filename:       string                   `json:"filename"`,
    hash:           string                   `json:"hash"`,
    bytes:          i64                      `json:"bytes"`,
    original_bytes: i64                      `json:"original_bytes"`,
    progress:       f64                      `json:"progress"`,
    status:         string                   `json:"status"`,
    added:          string                   `json:"added"`,
    files:          []RealDebridTorrentFile `json:"files"`,
    links:          []string                 `json:"links"`,
}


RealDebridActiveTorrentCount :: struct {
    active: int `json:"nb"`,
    maximum: int `json:"limit"`,
}


RealDebridDownload :: struct {
    id:        string `json:"id"`,
    filename:  string `json:"filename"`,
    mime_type: string `json:"mimeType"`,
    filesize:  i64    `json:"filesize"`,
    link:      string `json:"link"`,
    host:      string `json:"host"`,
    chunks:    int    `json:"chunks"`,
    crc:       int    `json:"crc"`,
    download:  string `json:"download"`,
    generated: string `json:"generated"`,
}


// ---------------------------------------------------------
// HTTP implementation
// ---------------------------------------------------------

rd_url_encode :: proc(value: string) -> string {
    hex := "0123456789ABCDEF"
    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)

    for byte_value in transmute([]byte)value {
        allowed :=
            (byte_value >= 'a' && byte_value <= 'z') ||
            (byte_value >= 'A' && byte_value <= 'Z') ||
            (byte_value >= '0' && byte_value <= '9') ||
            byte_value == '-' || byte_value == '_' ||
            byte_value == '.' || byte_value == '~'

        if allowed {
            strings.write_byte(&builder, byte_value)
        } else {
            strings.write_byte(&builder, '%')
            strings.write_byte(&builder, hex[byte_value >> 4])
            strings.write_byte(&builder, hex[byte_value & 0x0f])
        }
    }

    return strings.to_string(builder)
}


rd_form_pair :: proc(builder: ^strings.Builder, name, value: string, first: ^bool) {
    if !(first^) {
        strings.write_byte(builder, '&')
    }

    strings.write_string(builder, name)
    strings.write_byte(builder, '=')

    encoded := rd_url_encode(value)
    defer delete(encoded)
    strings.write_string(builder, encoded)

    first^ = false
}


// The OAuth documentation shows the grant type unescaped in its curl
// example. Keep this helper for that parameter while encoding user values.
rd_form_pair_raw :: proc(builder: ^strings.Builder, name, value: string, first: ^bool) {
    if !(first^) {
        strings.write_byte(builder, '&')
    }

    strings.write_string(builder, name)
    strings.write_byte(builder, '=')
    strings.write_string(builder, value)
    first^ = false
}


rd_parse_error :: proc(body: string, http_status, transport_code: int) -> RealDebridError {
    result := RealDebridError{
        http_status = http_status,
        transport_code = transport_code,
        message = fmt.aprintf("Real-Debrid request failed (HTTP %d)", http_status),
    }

    // Error responses are also used by the OAuth device poller, where a 403
    // is a normal "not authorized yet" response. Avoid parsing a temporary
    // JSON DOM here: this path runs repeatedly and the response is only used
    // for two small diagnostic fields.
    if len(body) == 0 {
        return result
    }

    code_marker := "\"error_code\":"
    code_start := strings.index(body, code_marker)
    if code_start < 0 {
        code_marker = "\"error_code\": "
        code_start = strings.index(body, code_marker)
    }
    if code_start >= 0 {
        code_text := body[code_start+len(code_marker):]
        result.api_code = rd_parse_error_code(code_text)
    }

    message_marker := "\"error\":\""
    message_start := strings.index(body, message_marker)
    if message_start < 0 {
        message_marker = "\"error\": \""
        message_start = strings.index(body, message_marker)
    }
    if message_start >= 0 {
        message_text := body[message_start+len(message_marker):]
        message_end := strings.index(message_text, "\"")
        if message_end >= 0 {
            message := message_text[:message_end]
            if len(message) > 0 {
                delete(result.message)
                result.message = strings.clone(message, context.allocator)
            }
        }
    }

    return result
}


rd_parse_error_code :: proc(value: string) -> int {
    result := 0
    sign := 1
    index := 0

    for index < len(value) &&
         (value[index] == ' ' || value[index] == '\t' ||
          value[index] == '\r' || value[index] == '\n') {
        index += 1
    }

    if index < len(value) && value[index] == '-' {
        sign = -1
        index += 1
    }

    for index < len(value) {
        digit := value[index]
        if digit < '0' || digit > '9' {
            break
        }
        result = result * 10 + int(digit - '0')
        index += 1
    }

    return result * sign
}


// RDRequest returns an owned response body on success. The caller must
// delete the body after decoding it. An empty body is valid for 204 calls.
RDRequest :: proc(
    client: ^RealDebridClient,
    method, path, form_body: string,
) -> (body: string, err: RealDebridError) {
    if client == nil || len(client.access_token) == 0 {
        return "", RealDebridError{
            message = "Real-Debrid access token is empty",
        }
    }
    return rd_request(
        client.base_url,
        client.access_token,
        method,
        path,
        form_body,
    )
}


rd_request :: proc(
    base_url, access_token: string,
    method, path, form_body: string,
) -> (body: string, err: RealDebridError) {
    context = runtime.default_context()
    fmt.printf(
        "[RD HTTP] Starting %s request auth=%v body_bytes=%d\n",
        method,
        len(access_token) > 0,
        len(form_body),
    )

    url := fmt.aprintf("%s%s", base_url, path)
    defer delete(url)

    handle := curl.easy_init()
    if handle == nil {
        return "", RealDebridError{
            message = "Could not initialize libcurl",
        }
    }
    defer curl.easy_cleanup(handle)

    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)
    defer strings.builder_destroy(&builder)

    url_cstr := strings.clone_to_cstring(url, context.allocator)
    defer delete(url_cstr)

    user_agent_cstr := strings.clone_to_cstring(
        REALDEBRID_USER_AGENT,
        context.allocator,
    )
    defer delete(user_agent_cstr)

    headers: ^curl.slist
    if len(access_token) > 0 {
        auth := fmt.aprintf("Authorization: Bearer %s", access_token)
        defer delete(auth)
        auth_cstr := strings.clone_to_cstring(auth, context.allocator)
        defer delete(auth_cstr)
        headers = curl.slist_append(headers, auth_cstr)
    }
    headers = curl.slist_append(headers, "Accept: application/json")
    if method == "POST" || method == "PUT" {
        headers = curl.slist_append(
            headers,
            "Content-Type: application/x-www-form-urlencoded",
        )
    }
    defer curl.slist_free_all(headers)

    curl.easy_setopt(handle, .URL, url_cstr)
    curl.easy_setopt(handle, .FOLLOWLOCATION, curl.FOLLOW_ALL)
    // Keep form bodies when an API endpoint redirects. Without this,
    // libcurl may turn a redirected POST into a body-less GET, which makes
    // selectFiles report that its required files parameter is missing.
    curl.easy_setopt(handle, .POSTREDIR, curl.REDIR_POST_ALL)
    curl.easy_setopt(handle, .USERAGENT, user_agent_cstr)
    curl.easy_setopt(handle, .TIMEOUT, 30)
    curl.easy_setopt(handle, .HTTPHEADER, headers)
    curl.easy_setopt(handle, .WRITEFUNCTION, CurlWriteCallback)
    curl.easy_setopt(handle, .WRITEDATA, &builder)

    if method == "POST" {
        curl.easy_setopt(handle, .POST, 1)
    } else if method == "PUT" {
        put_cstr := strings.clone_to_cstring(
            "PUT",
            context.allocator,
        )
        defer delete(put_cstr)
        curl.easy_setopt(handle, .CUSTOMREQUEST, put_cstr)
    }

    if method == "POST" || method == "PUT" {
        if len(form_body) > 0 {
            form_cstr := strings.clone_to_cstring(
                form_body,
                context.allocator,
            )
            defer delete(form_cstr)

            curl.easy_setopt(handle, .POSTFIELDS, form_cstr)
            curl.easy_setopt(
                handle,
                .POSTFIELDSIZE,
                libc.long(len(form_body)),
            )
        }
    } else if method != "GET" {
        method_cstr := strings.clone_to_cstring(
            method,
            context.allocator,
        )
        defer delete(method_cstr)
        curl.easy_setopt(handle, .CUSTOMREQUEST, method_cstr)
    }

    transport_result := curl.easy_perform(handle)

    http_status: libc.long = 0
    redirect_count: libc.long = 0
    curl.easy_getinfo(handle, .RESPONSE_CODE, &http_status)
    curl.easy_getinfo(handle, .REDIRECT_COUNT, &redirect_count)
    fmt.printf(
        "[RD HTTP] Finished %s transport=%v http=%d redirects=%d response_bytes=%d\n",
        method,
        transport_result,
        http_status,
        redirect_count,
        len(builder.buf),
    )

    if transport_result != .E_OK {
        error_body := strings.clone(
            strings.to_string(builder),
            context.allocator,
        )
        defer delete(error_body)
        request_err := rd_parse_error(
            error_body,
            int(http_status),
            int(transport_result),
        )
        fmt.printf(
            "[RD HTTP] Transport error parsed api=%d message=%s\n",
            request_err.api_code,
            request_err.message,
        )
        return "", request_err
    }

    if http_status < 200 || http_status >= 300 {
        error_body := strings.clone(
            strings.to_string(builder),
            context.allocator,
        )
        defer delete(error_body)
        excerpt_length := min(len(error_body), 256)
        fmt.printf(
            "[RD HTTP] Error response excerpt=%s\n",
            error_body[:excerpt_length],
        )
        request_err := rd_parse_error(
            error_body,
            int(http_status),
            0,
        )
        fmt.printf(
            "[RD HTTP] HTTP error parsed api=%d message=%s\n",
            request_err.api_code,
            request_err.message,
        )
        return "", request_err
    }

    if len(builder.buf) == 0 {
        return "", RealDebridError{http_status = int(http_status)}
    }

    return strings.clone(
        strings.to_string(builder),
        context.allocator,
    ), RealDebridError{http_status = int(http_status)}
}


rd_decode :: proc(body: string, result: ^$T) -> RealDebridError {
    decode_err := json.unmarshal(
        transmute([]byte)body,
        result,
        allocator = context.allocator,
    )

    if decode_err != nil {
        return RealDebridError{
            message = fmt.aprintf("Invalid Real-Debrid JSON response: %v", decode_err),
        }
    }

    return {}
}


// ---------------------------------------------------------
// User and unrestrict endpoints
// ---------------------------------------------------------

RDGetUser :: proc(client: ^RealDebridClient) -> (RealDebridUser, RealDebridError) {
    body, err := RDRequest(client, "GET", "/user", "")
    if err.message != "" {
        return {}, err
    }
    defer delete(body)

    result: RealDebridUser
    decode_err := rd_decode(body, &result)
    if decode_err.message != "" {
        return {}, decode_err
    }
    return result, {}
}


RDCheckLink :: proc(client: ^RealDebridClient, link, password: string) -> (RealDebridLinkCheck, RealDebridError) {
    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)
    defer strings.builder_destroy(&builder)

    first := true
    rd_form_pair(&builder, "link", link, &first)
    if len(password) > 0 {
        rd_form_pair(&builder, "password", password, &first)
    }

    form_body := strings.clone(
        strings.to_string(builder),
        context.allocator,
    )
    defer delete(form_body)
    body, err := RDRequest(client, "POST", "/unrestrict/check", form_body)
    if err.message != "" {
        return {}, err
    }
    defer delete(body)

    result: RealDebridLinkCheck
    decode_err := rd_decode(body, &result)
    if decode_err.message != "" {
        return {}, decode_err
    }
    return result, {}
}


RDUnrestrictLink :: proc(client: ^RealDebridClient, link, password: string, remote := false) -> (RealDebridUnrestrictedLink, RealDebridError) {
    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)
    defer strings.builder_destroy(&builder)

    first := true
    rd_form_pair(&builder, "link", link, &first)
    if len(password) > 0 {
        rd_form_pair(&builder, "password", password, &first)
    }
    rd_form_pair(&builder, "remote", remote ? "1" : "0", &first)

    form_body := strings.clone(
        strings.to_string(builder),
        context.allocator,
    )
    defer delete(form_body)
    body, err := RDRequest(client, "POST", "/unrestrict/link", form_body)
    if err.message != "" {
        return {}, err
    }
    defer delete(body)

    result: RealDebridUnrestrictedLink
    decode_err := rd_decode(body, &result)
    if decode_err.message != "" {
        return {}, decode_err
    }
    return result, {}
}


// ---------------------------------------------------------
// Torrent endpoints
// ---------------------------------------------------------

RDAddMagnet :: proc(client: ^RealDebridClient, magnet, host: string) -> (RealDebridTorrentCreated, RealDebridError) {
    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)
    defer strings.builder_destroy(&builder)

    first := true
    rd_form_pair(&builder, "magnet", magnet, &first)
    if len(host) > 0 {
        rd_form_pair(&builder, "host", host, &first)
    }

    form_body := strings.clone(
        strings.to_string(builder),
        context.allocator,
    )
    defer delete(form_body)

    magnet_has_whitespace := strings.contains(magnet, " ") ||
        strings.contains(magnet, "\t") || strings.contains(magnet, "\r") ||
        strings.contains(magnet, "\n")
    magnet_has_html_entities := strings.contains(magnet, "&amp;") ||
        strings.contains(magnet, "&#038;") || strings.contains(magnet, "&#x26;")
    magnet_prefix_valid := len(magnet) >= len("magnet:?xt=urn:btih:") &&
        strings.index(magnet, "magnet:?xt=urn:btih:") == 0
    fmt.printf(
        "[RD TORRENT] addMagnet magnet_bytes=%d form_bytes=%d host_present=%v prefix_valid=%v html_entities=%v whitespace=%v\n",
        len(magnet),
        len(form_body),
        len(host) > 0,
        magnet_prefix_valid,
        magnet_has_html_entities,
        magnet_has_whitespace,
    )

    body, err := RDRequest(client, "POST", "/torrents/addMagnet", form_body)
    if err.message != "" {
        return {}, err
    }
    defer delete(body)

    result: RealDebridTorrentCreated
    decode_err := rd_decode(body, &result)
    if decode_err.message != "" {
        return {}, decode_err
    }
    return result, {}
}


RDGetTorrentInfo :: proc(client: ^RealDebridClient, torrent_id: string) -> (RealDebridTorrentInfo, RealDebridError) {
    encoded_id := rd_url_encode(torrent_id)
    defer delete(encoded_id)
    path := fmt.aprintf("/torrents/info/%s", encoded_id)
    defer delete(path)

    body, err := RDRequest(client, "GET", path, "")
    if err.message != "" {
        return {}, err
    }
    defer delete(body)

    result: RealDebridTorrentInfo
    decode_err := rd_decode(body, &result)
    if decode_err.message != "" {
        return {}, decode_err
    }
    return result, {}
}


RDSelectTorrentFiles :: proc(client: ^RealDebridClient, torrent_id, files: string) -> RealDebridError {
    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)
    defer strings.builder_destroy(&builder)

    first := true
    rd_form_pair(&builder, "files", files, &first)

    encoded_id := rd_url_encode(torrent_id)
    defer delete(encoded_id)
    path := fmt.aprintf("/torrents/selectFiles/%s", encoded_id)
    defer delete(path)

    form_body := strings.clone(
        strings.to_string(builder),
        context.allocator,
    )
    defer delete(form_body)
    fmt.printf(
        "[RD TORRENT] selectFiles torrent_id_bytes=%d files=%s form_bytes=%d\n",
        len(torrent_id),
        files,
        len(form_body),
    )
    _, err := RDRequest(client, "POST", path, form_body)
    return err
}


RDDeleteTorrent :: proc(client: ^RealDebridClient, torrent_id: string) -> RealDebridError {
    encoded_id := rd_url_encode(torrent_id)
    defer delete(encoded_id)
    path := fmt.aprintf("/torrents/delete/%s", encoded_id)
    defer delete(path)

    _, err := RDRequest(client, "DELETE", path, "")
    return err
}


RDListTorrents :: proc(
    client: ^RealDebridClient,
    filter: string,
    page, limit: int,
) -> ([]RealDebridTorrentSummary, RealDebridError) {
    path := fmt.aprintf(
        "/torrents?page=%d&limit=%d",
        page,
        limit,
    )
    if len(filter) > 0 {
        encoded_filter := rd_url_encode(filter)
        defer delete(encoded_filter)
        path_with_filter := fmt.aprintf(
            "%s&filter=%s",
            path,
            encoded_filter,
        )
        delete(path)
        path = path_with_filter
    }
    defer delete(path)

    body, err := RDRequest(client, "GET", path, "")
    if err.message != "" {
        return nil, err
    }
    defer delete(body)

    result: []RealDebridTorrentSummary
    decode_err := rd_decode(body, &result)
    if decode_err.message != "" {
        return nil, decode_err
    }
    return result, {}
}


RDGetActiveTorrentCount :: proc(client: ^RealDebridClient) -> (RealDebridActiveTorrentCount, RealDebridError) {
    body, err := RDRequest(client, "GET", "/torrents/activeCount", "")
    if err.message != "" {
        return {}, err
    }
    defer delete(body)

    result: RealDebridActiveTorrentCount
    decode_err := rd_decode(body, &result)
    if decode_err.message != "" {
        return {}, decode_err
    }
    return result, {}
}


RDListDownloads :: proc(
    client: ^RealDebridClient,
    page, limit: int,
) -> ([]RealDebridDownload, RealDebridError) {
    path := fmt.aprintf(
        "/downloads?page=%d&limit=%d",
        page,
        limit,
    )
    defer delete(path)

    body, err := RDRequest(client, "GET", path, "")
    if err.message != "" {
        return nil, err
    }
    defer delete(body)

    result: []RealDebridDownload
    decode_err := rd_decode(body, &result)
    if decode_err.message != "" {
        return nil, decode_err
    }
    return result, {}
}


RDDeleteDownload :: proc(client: ^RealDebridClient, download_id: string) -> RealDebridError {
    encoded_id := rd_url_encode(download_id)
    defer delete(encoded_id)
    path := fmt.aprintf("/downloads/delete/%s", encoded_id)
    defer delete(path)

    _, err := RDRequest(client, "DELETE", path, "")
    return err
}


// The JSON decoder allocates strings and slices using the current allocator.
// Call the matching destroy procedure after consuming a decoded response.
DestroyRealDebridUser :: proc(value: ^RealDebridUser) {
    if value == nil { return }
    delete(value.username)
    delete(value.email)
    delete(value.locale)
    delete(value.avatar)
    delete(value.expiration)
}


DestroyRealDebridLinkCheck :: proc(value: ^RealDebridLinkCheck) {
    if value == nil { return }
    delete(value.host)
    delete(value.link)
    delete(value.filename)
}


DestroyRealDebridUnrestrictedLink :: proc(value: ^RealDebridUnrestrictedLink) {
    if value == nil { return }
    delete(value.id)
    delete(value.filename)
    delete(value.mime_type)
    delete(value.link)
    delete(value.host)
    delete(value.download)
}


DestroyRealDebridTorrentCreated :: proc(value: ^RealDebridTorrentCreated) {
    if value == nil { return }
    delete(value.id)
    delete(value.uri)
}


DestroyRealDebridTorrentSummary :: proc(value: ^RealDebridTorrentSummary) {
    if value == nil { return }
    delete(value.id)
    delete(value.filename)
    delete(value.hash)
    delete(value.host)
    delete(value.status)
    delete(value.added)
    for link in value.links {
        delete(link)
    }
    delete(value.links)
}


DestroyRealDebridTorrentSummaries :: proc(values: []RealDebridTorrentSummary) {
    for &value in values {
        DestroyRealDebridTorrentSummary(&value)
    }
    delete(values)
}


DestroyRealDebridTorrentInfo :: proc(value: ^RealDebridTorrentInfo) {
    if value == nil { return }
    delete(value.id)
    delete(value.filename)
    delete(value.hash)
    delete(value.status)
    delete(value.added)
    for &file in value.files {
        delete(file.path)
    }
    delete(value.files)
    for link in value.links {
        delete(link)
    }
    delete(value.links)
}


DestroyRealDebridDownloads :: proc(values: []RealDebridDownload) {
    for &value in values {
        delete(value.id)
        delete(value.filename)
        delete(value.mime_type)
        delete(value.link)
        delete(value.host)
        delete(value.download)
        delete(value.generated)
    }
    delete(values)
}

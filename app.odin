package main

import "core:strings"
import "core:thread"
import rl "vendor:raylib"


WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 800
WINDOW_TITLE  :: "FitDeck"


RELEASE_ROW_HEIGHT :: 96
RELEASE_ROW_EXTENT :: 106


// ---------------------------------------------------------
// Palette
// ---------------------------------------------------------

APP_BACKGROUND        :: rl.Color{24, 24, 24, 255}
HEADER_BACKGROUND     :: rl.Color{32, 32, 32, 255}
LIST_BACKGROUND       :: rl.Color{24, 24, 24, 255}
ROW_BACKGROUND        :: rl.Color{38, 38, 38, 255}
ROW_HOVER_BACKGROUND  :: rl.Color{48, 48, 48, 255}
ROW_FOCUS_BACKGROUND  :: rl.Color{75, 75, 75, 255}
ACCENT_COLOR          :: rl.Color{180, 180, 180, 255}
TEXT_PRIMARY          :: rl.Color{225, 225, 225, 255}
TEXT_MUTED            :: rl.Color{140, 140, 140, 255}
BORDER_COLOR          :: rl.Color{55, 55, 55, 255}
STATUS_OK             :: rl.Color{120, 175, 135, 255}
STATUS_ERR            :: rl.Color{175, 120, 120, 255}


// ---------------------------------------------------------
// App State & Data Structures
// ---------------------------------------------------------

AppScreen :: enum {
    SetupKey,
    Loading,
    Library,
}


GameRelease :: struct {
    title:      string,
    magnetLink: string,
    coverUrl:   string,
    coverPath:  string,
    coverTex:   rl.Texture2D,
}


DownloadTask :: struct {
    game_ptr: ^GameRelease,
}


// LoaderData is exclusively owned by the loader thread until the
// loader thread finishes. The main thread only reads it after
// thread.is_done() + thread.destroy(), avoiding App data races.
LoaderData :: struct {
    games:         [dynamic]GameRelease,
    success:       bool,
    error_message: string,
}


App :: struct {
    screen:               AppScreen,
    rd_key:               string,
    rd_refresh_token:     string,
    rd_client_id:         string,
    rd_client_secret:     string,
    rd_token_expires_at:  i64,
    download_path:        string,
    use_ram_limit:        bool,

    load_status: string,
    games:       [dynamic]GameRelease,

    loader_thread: ^thread.Thread,
    loader_data:   ^LoaderData,

    download_manager: DownloadManager,

    auth_thread: ^thread.Thread,
    auth_data:   ^RealDebridAuthData,

    selected_game:  int,
    status_message: string,
}


// ---------------------------------------------------------
// Utility / Lifetime Functions
// ---------------------------------------------------------

sanitize_filename :: proc(
    name: string,
    alloc := context.allocator,
) -> string {
    b: strings.Builder
    strings.builder_init(&b, alloc)

    for r in name {
        if (r >= 'A' && r <= 'Z') ||
           (r >= 'a' && r <= 'z') ||
           (r >= '0' && r <= '9') {
            strings.write_rune(&b, r)
        } else if r == ' ' || r == '-' {
            strings.write_rune(&b, '_')
        }
    }

    // Ownership of the builder's backing buffer is intentionally
    // transferred to the returned string.
    return strings.to_string(b)
}


DestroyGame :: proc(game: ^GameRelease) {
    if game == nil {
        return
    }

    if game.coverTex.id != 0 {
        rl.UnloadTexture(game.coverTex)
        game.coverTex = {}
    }

    if len(game.title) > 0 {
        delete(game.title)
        game.title = ""
    }

    if len(game.magnetLink) > 0 {
        delete(game.magnetLink)
        game.magnetLink = ""
    }

    if len(game.coverUrl) > 0 {
        delete(game.coverUrl)
        game.coverUrl = ""
    }

    if len(game.coverPath) > 0 {
        delete(game.coverPath)
        game.coverPath = ""
    }
}


DestroyGames :: proc(games: [dynamic]GameRelease) {
    for &game in games {
        DestroyGame(&game)
    }

    delete(games)
}

# mdview

A fast, native Markdown viewer built with Zig. Cross-platform — Windows, Linux, and macOS.

Dark-themed, borderless floating window that renders Markdown with GitHub-dark styling. Rewrite of the [Rust version](https://github.com/nathannncurtis/mdview) — ~285 KB standalone binary, no webview, no runtime dependencies.

## Features

- **Cross-platform** — Windows (DirectWrite), Linux (X11 + Cairo + Pango), macOS (Cocoa + CoreText)
- **GitHub-dark theme** — easy on the eyes
- **Borderless floating window** — clean, minimal chrome
- **Syntax highlighting** in code blocks
- **Bold/italic** inline formatting
- **File watching** — auto-reloads when the file changes on disk
- **Drag & drop** — drop any `.md` file onto the window to open it
- **Scroll position memory** — remembers where you left off across sessions
- **Register as default viewer** — `--register` on Windows, `.desktop` file on Linux

## Install

Download from the [latest release](https://github.com/nathannncurtis/mdview-zig/releases/latest):

| Platform | Files |
|---|---|
| Windows | `mdview.exe` (portable) or `mdview-setup.exe` (installer) |
| Linux | `mdview-linux-x86_64` |
| macOS | `mdview-macos-arm64` |

The Windows installer can run per-user or system-wide and optionally associates `.md` / `.markdown` files with mdview.

## Usage

```
mdview README.md
mdview --register      # register as default .md viewer (Windows/Linux)
```

Or drag and drop a `.md` file onto the window.

## Keybindings

| Key | Action |
|---|---|
| Ctrl+Q | Quit |
| Alt+Drag | Move window |
| Scroll | Scroll content |

## Build from source

Requires [Zig 0.14+](https://ziglang.org/download/).

```
zig build -Doptimize=ReleaseSmall
```

### Platform dependencies

- **Windows** — none (uses system DirectWrite/Direct2D)
- **Linux** — `libx11-dev libcairo2-dev libpango1.0-dev`
- **macOS** — none (uses system Cocoa/CoreText frameworks)

## Logging

Logs are written to:
- **Windows** — `%LOCALAPPDATA%\mdview\mdview-zig.log`
- **Linux** — `~/.local/share/mdview/mdview-zig.log`
- **macOS** — `~/Library/Application Support/mdview/mdview-zig.log`

## License

[MIT](LICENSE)

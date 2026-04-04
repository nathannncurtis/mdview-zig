# mdview

A fast, native Markdown viewer for Windows built with Zig and DirectWrite.

Dark-themed, borderless floating window that renders Markdown with GitHub-dark styling. Rewrite of the [Rust version](https://github.com/nathannncurtis/mdview) in Zig, producing a ~240 KB standalone binary.

## Features

- **Native DirectWrite rendering** -- crisp, GPU-accelerated text on Windows
- **GitHub-dark theme** -- easy on the eyes
- **Borderless floating window** -- clean, minimal chrome
- **File watching** -- auto-reloads when the file changes on disk
- **Drag & drop** -- drop any `.md` file onto the window to open it
- **Scroll position memory** -- remembers where you left off across sessions
- **Register as default viewer** -- associate `.md` files system-wide with `--register`

## Install

Download `mdview.exe` (portable) or `mdview-setup.exe` (installer) from the
[latest release](https://github.com/nathannncurtis/mdview-zig/releases/latest).

The installer can run per-user or system-wide and optionally associates `.md` / `.markdown` files with mdview.

## Usage

```
mdview README.md
mdview --register      # register as the default .md viewer
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

The binary is written to `zig-out/bin/mdview.exe`.

## License

[MIT](LICENSE)

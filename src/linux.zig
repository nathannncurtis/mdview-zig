// Linux backend — X11 + Cairo + Pango
const std = @import("std");
const app = @import("main.zig");
const md = app.md;

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xatom.h");
    @cInclude("cairo/cairo.h");
    @cInclude("cairo/cairo-xlib.h");
    @cInclude("pango/pangocairo.h");
});

// POSIX for select()
const posix = @cImport({
    @cInclude("sys/select.h");
    @cInclude("sys/time.h");
    @cInclude("unistd.h");
});

// ============================================================
// State
// ============================================================
var display: ?*c.Display = null;
var window: c.Window = 0;
var needs_redraw: bool = true;
var wm_delete_window: c.Atom = 0;

// ============================================================
// Colors
// ============================================================
const Color = struct { r: f64, g: f64, b: f64 };

const col_bg = Color{ .r = 13.0 / 255.0, .g = 17.0 / 255.0, .b = 23.0 / 255.0 };
const col_text = Color{ .r = 201.0 / 255.0, .g = 209.0 / 255.0, .b = 217.0 / 255.0 };
const col_code_bg = Color{ .r = 22.0 / 255.0, .g = 27.0 / 255.0, .b = 34.0 / 255.0 };
const col_quote = Color{ .r = 139.0 / 255.0, .g = 148.0 / 255.0, .b = 158.0 / 255.0 };
const col_hr = Color{ .r = 33.0 / 255.0, .g = 38.0 / 255.0, .b = 45.0 / 255.0 };
const col_close = Color{ .r = 139.0 / 255.0, .g = 148.0 / 255.0, .b = 158.0 / 255.0 };

const col_hl_keyword = Color{ .r = 255.0 / 255.0, .g = 123.0 / 255.0, .b = 114.0 / 255.0 };
const col_hl_string = Color{ .r = 165.0 / 255.0, .g = 214.0 / 255.0, .b = 255.0 / 255.0 };
const col_hl_comment = Color{ .r = 139.0 / 255.0, .g = 148.0 / 255.0, .b = 158.0 / 255.0 };
const col_hl_number = Color{ .r = 121.0 / 255.0, .g = 192.0 / 255.0, .b = 255.0 / 255.0 };
const col_hl_type = Color{ .r = 255.0 / 255.0, .g = 166.0 / 255.0, .b = 87.0 / 255.0 };
const col_hl_func = Color{ .r = 210.0 / 255.0, .g = 168.0 / 255.0, .b = 255.0 / 255.0 };

// ============================================================
// Public API
// ============================================================
pub fn invalidate() void {
    needs_redraw = true;
    if (display) |dpy| {
        var ev: c.XEvent = undefined;
        ev.type = c.Expose;
        ev.xexpose.window = window;
        ev.xexpose.count = 0;
        _ = c.XSendEvent(dpy, window, 0, c.ExposureMask, &ev);
        _ = c.XFlush(dpy);
    }
}

pub fn run() void {
    display = c.XOpenDisplay(null);
    const dpy = display orelse {
        app.log("failed to open X display");
        return;
    };
    const screen = c.DefaultScreen(dpy);
    const root = c.RootWindow(dpy, screen);

    // Create window
    var attrs: c.XSetWindowAttributes = std.mem.zeroes(c.XSetWindowAttributes);
    attrs.background_pixel = c.BlackPixel(dpy, screen);
    attrs.event_mask = c.ExposureMask | c.KeyPressMask | c.ButtonPressMask |
        c.ButtonReleaseMask | c.StructureNotifyMask | c.PointerMotionMask;

    const width: c_uint = 900;
    const height: c_uint = 700;

    window = c.XCreateWindow(
        dpy,
        root,
        0,
        0,
        width,
        height,
        0,
        c.CopyFromParent,
        c.InputOutput,
        null,
        c.CWBackPixel | c.CWEventMask,
        &attrs,
    );

    app.window_width = @floatFromInt(width);
    app.window_height = @floatFromInt(height);

    // Set window title
    _ = c.XStoreName(dpy, window, "mdview");

    // Remove decorations via _MOTIF_WM_HINTS (keep resize)
    setMotifHints(dpy, window);

    // Register for WM_DELETE_WINDOW
    wm_delete_window = c.XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
    _ = c.XSetWMProtocols(dpy, window, &wm_delete_window, 1);

    // Map window
    _ = c.XMapWindow(dpy, window);
    _ = c.XFlush(dpy);

    app.log("X11 window created");

    // Event loop with select()-based timeout
    const x11_fd = c.ConnectionNumber(dpy);
    var last_save_time: i64 = std.time.milliTimestamp();
    var running = true;

    while (running) {
        // Process all pending events first
        while (c.XPending(dpy) > 0) {
            var ev: c.XEvent = undefined;
            _ = c.XNextEvent(dpy, &ev);

            switch (ev.type) {
                c.Expose => {
                    needs_redraw = true;
                },
                c.ConfigureNotify => {
                    const ce = ev.xconfigure;
                    app.window_width = @floatFromInt(ce.width);
                    app.window_height = @floatFromInt(ce.height);
                    needs_redraw = true;
                },
                c.KeyPress => {
                    const ke = ev.xkey;
                    var keysym: c.KeySym = 0;
                    _ = c.XLookupString(@constCast(&ke), null, 0, &keysym, null);
                    // Ctrl+Q to quit
                    if (keysym == 'q' and (ke.state & c.ControlMask) != 0) {
                        running = false;
                    }
                },
                c.ButtonPress => {
                    const be = ev.xbutton;
                    // Scroll up
                    if (be.button == 4) {
                        app.scroll_y -= 60;
                        if (app.scroll_y < 0) app.scroll_y = 0;
                        needs_redraw = true;
                    }
                    // Scroll down
                    else if (be.button == 5) {
                        app.scroll_y += 60;
                        const max_scroll = app.content_height - app.window_height + 40;
                        if (max_scroll > 0 and app.scroll_y > max_scroll) app.scroll_y = max_scroll;
                        needs_redraw = true;
                    }
                    // Left click
                    else if (be.button == 1) {
                        const bx: f32 = @floatFromInt(be.x);
                        const by: f32 = @floatFromInt(be.y);
                        // Close button: top-right area
                        if (bx > app.window_width - 40 and by < 36) {
                            running = false;
                        }
                        // Alt+click to move window
                        else if ((be.state & c.Mod1Mask) != 0) {
                            initiateMove(dpy, window, be.x_root, be.y_root);
                        }
                    }
                },
                c.ClientMessage => {
                    const cm = ev.xclient;
                    if (@as(c.Atom, @intCast(cm.data.l[0])) == wm_delete_window) {
                        running = false;
                    }
                },
                else => {},
            }
        }

        // Render if needed
        if (needs_redraw) {
            needs_redraw = false;
            render(dpy, window);
        }

        // Save scroll position periodically (every ~3 seconds)
        const now = std.time.milliTimestamp();
        if (now - last_save_time >= 3000) {
            app.saveScrollPosition();
            last_save_time = now;
        }

        // Use select() with 500ms timeout for file watching
        var fds: posix.fd_set = std.mem.zeroes(posix.fd_set);
        posix.__FD_SET(x11_fd, &fds);
        var tv: posix.struct_timeval = .{ .tv_sec = 0, .tv_usec = 500_000 };
        const sel = posix.select(x11_fd + 1, &fds, null, null, &tv);
        if (sel == 0) {
            // Timeout — check for file changes
            app.checkFileChanged();
        }
    }

    app.saveScrollPosition();
    _ = c.XDestroyWindow(dpy, window);
    _ = c.XCloseDisplay(dpy);
}

pub fn registerFileAssociation() void {
    // Create .desktop file for .md file association
    const home = std.process.getEnvVarOwned(app.allocator, "HOME") catch {
        app.log("cannot get HOME for .desktop file");
        return;
    };

    // Get our own executable path
    var exe_buf: [4096]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch {
        app.log("cannot get self exe path");
        return;
    };

    const desktop_dir = std.fmt.allocPrint(app.allocator, "{s}/.local/share/applications", .{home}) catch return;
    std.fs.cwd().makePath(desktop_dir) catch {};

    const desktop_path = std.fmt.allocPrint(app.allocator, "{s}/mdview.desktop", .{desktop_dir}) catch return;
    const desktop_content = std.fmt.allocPrint(app.allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=mdview
        \\Comment=Markdown Viewer
        \\Exec={s} %f
        \\MimeType=text/markdown;text/x-markdown;
        \\Terminal=false
        \\Categories=Utility;TextEditor;
        \\
    , .{exe_path}) catch return;

    const f = std.fs.cwd().createFile(desktop_path, .{ .truncate = true }) catch {
        app.log("failed to create .desktop file");
        return;
    };
    defer f.close();
    f.writeAll(desktop_content) catch return;

    // Also set the mime association
    const mimeapps_path = std.fmt.allocPrint(app.allocator, "{s}/.local/share/applications/mimeapps.list", .{home}) catch return;

    // Append to mimeapps.list
    if (std.fs.cwd().openFile(mimeapps_path, .{ .mode = .read_write })) |mf| {
        defer mf.close();
        const end = mf.getEndPos() catch return;
        mf.seekTo(end) catch return;
        mf.writeAll("text/markdown=mdview.desktop;\ntext/x-markdown=mdview.desktop;\n") catch return;
    } else |_| {
        const mf = std.fs.cwd().createFile(mimeapps_path, .{ .truncate = true }) catch return;
        defer mf.close();
        mf.writeAll("[Default Applications]\ntext/markdown=mdview.desktop;\ntext/x-markdown=mdview.desktop;\n") catch return;
    }

    const stdout = std.io.getStdOut().writer();
    stdout.writeAll("mdview registered as default viewer for .md and .markdown files.\n") catch {};
}

// ============================================================
// _MOTIF_WM_HINTS — remove title bar but keep resize
// ============================================================
const MotifWmHints = extern struct {
    flags: c_ulong,
    functions: c_ulong,
    decorations: c_ulong,
    input_mode: c_long,
    status: c_ulong,
};

fn setMotifHints(dpy: *c.Display, win: c.Window) void {
    const atom = c.XInternAtom(dpy, "_MOTIF_WM_HINTS", 0);
    if (atom == 0) return;
    // flags=2 means "decorations field is valid", decorations=0 means "no decorations"
    // functions=bit set for resize+move+close
    var hints = MotifWmHints{
        .flags = 1 | 2, // MWM_HINTS_FUNCTIONS | MWM_HINTS_DECORATIONS
        .functions = 1 | 2 | 4 | 32, // FUNC_ALL minus some, or RESIZE|MOVE|MINIMIZE|CLOSE
        .decorations = 0, // no decorations
        .input_mode = 0,
        .status = 0,
    };
    _ = c.XChangeProperty(
        dpy,
        win,
        atom,
        atom,
        32,
        c.PropModeReplace,
        @ptrCast(&hints),
        5,
    );
}

// ============================================================
// _NET_WM_MOVERESIZE — Alt+click to move window
// ============================================================
fn initiateMove(dpy: *c.Display, win: c.Window, root_x: c_int, root_y: c_int) void {
    const net_moveresize = c.XInternAtom(dpy, "_NET_WM_MOVERESIZE", 0);
    if (net_moveresize == 0) return;

    var ev: c.XEvent = std.mem.zeroes(c.XEvent);
    ev.type = c.ClientMessage;
    ev.xclient.window = win;
    ev.xclient.message_type = net_moveresize;
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = @intCast(root_x);
    ev.xclient.data.l[1] = @intCast(root_y);
    ev.xclient.data.l[2] = 8; // _NET_WM_MOVERESIZE_MOVE
    ev.xclient.data.l[3] = 1; // Button1
    ev.xclient.data.l[4] = 1; // source indication: normal app

    const root = c.DefaultRootWindow(dpy);
    _ = c.XUngrabPointer(dpy, c.CurrentTime);
    _ = c.XSendEvent(dpy, root, 0, c.SubstructureRedirectMask | c.SubstructureNotifyMask, &ev);
    _ = c.XFlush(dpy);
}

// ============================================================
// Rendering
// ============================================================
fn render(dpy: *c.Display, win: c.Window) void {
    const screen = c.DefaultScreen(dpy);
    const visual = c.DefaultVisual(dpy, screen);
    const w: c_int = @intFromFloat(app.window_width);
    const h: c_int = @intFromFloat(app.window_height);

    if (w <= 0 or h <= 0) return;

    // Create Cairo surface backed by X11
    const surface = c.cairo_xlib_surface_create(dpy, win, visual, w, h) orelse return;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return;
    defer c.cairo_destroy(cr);

    // Clear background
    setColor(cr, col_bg);
    c.cairo_paint(cr);

    // Create Pango layout
    const pango_layout = c.pango_cairo_create_layout(cr) orelse return;
    defer c.g_object_unref(pango_layout);

    const padding: f32 = 40;
    const max_width = @max(app.window_width - padding * 2, 100);
    var y: f32 = padding - app.scroll_y;

    var i: usize = 0;
    while (i < md.block_count) : (i += 1) {
        const block = &md.blocks[i];
        switch (block.kind) {
            .h1 => {
                y += 24;
                y += renderTextBlock(cr, pango_layout, block, padding, y, max_width, col_text, "Sans Bold 24");
                y += 8;
                // Underline
                setColor(cr, col_hr);
                c.cairo_rectangle(cr, padding, y, max_width, 1);
                c.cairo_fill(cr);
                y += 16;
            },
            .h2 => {
                y += 20;
                y += renderTextBlock(cr, pango_layout, block, padding, y, max_width, col_text, "Sans Bold 18");
                y += 6;
                setColor(cr, col_hr);
                c.cairo_rectangle(cr, padding, y, max_width, 1);
                c.cairo_fill(cr);
                y += 16;
            },
            .h3 => {
                y += 16;
                y += renderTextBlock(cr, pango_layout, block, padding, y, max_width, col_text, "Sans Bold 15");
                y += 12;
            },
            .paragraph => {
                y += renderTextBlock(cr, pango_layout, block, padding, y, max_width, col_text, "Sans 12");
                y += 16;
            },
            .list_item => {
                // Bullet
                setColor(cr, col_text);
                c.cairo_arc(cr, padding + 10, y + 9, 2.5, 0, 2.0 * std.math.pi);
                c.cairo_fill(cr);
                y += renderTextBlock(cr, pango_layout, block, padding + 24, y, max_width - 24, col_text, "Sans 12");
                y += 8;
            },
            .blockquote => {
                // Left bar
                setColor(cr, col_hr);
                c.cairo_rectangle(cr, padding, y, 3, 24);
                c.cairo_fill(cr);
                y += renderTextBlock(cr, pango_layout, block, padding + 16, y, max_width - 16, col_quote, "Sans Italic 12");
                y += 16;
            },
            .code_block => {
                y += renderCodeBlock(cr, pango_layout, block, padding, y, max_width);
                y += 16;
            },
            .hr => {
                y += 12;
                setColor(cr, col_hr);
                c.cairo_rectangle(cr, padding, y, max_width, 2);
                c.cairo_fill(cr);
                y += 14;
            },
            .blank => {},
        }
    }

    app.content_height = y + app.scroll_y + padding;

    // Close button (X) — drawn in screen coordinates (not scrolled)
    drawCloseButton(cr);

    _ = c.cairo_surface_flush(surface);
}

fn setColor(cr: *c.cairo_t, col: Color) void {
    c.cairo_set_source_rgb(cr, col.r, col.g, col.b);
}

fn renderTextBlock(
    cr: *c.cairo_t,
    pango_layout: *c.PangoLayout,
    block: *const md.Block,
    x: f32,
    y: f32,
    max_width: f32,
    color: Color,
    font_desc_str: [*:0]const u8,
) f32 {
    if (block.text.len == 0) return 0;

    const desc = c.pango_font_description_from_string(font_desc_str) orelse return 0;
    defer c.pango_font_description_free(desc);

    c.pango_layout_set_font_description(pango_layout, desc);
    c.pango_layout_set_width(pango_layout, @intFromFloat(max_width * @as(f32, c.PANGO_SCALE)));
    c.pango_layout_set_wrap(pango_layout, c.PANGO_WRAP_WORD_CHAR);
    c.pango_layout_set_text(pango_layout, block.text.ptr, @intCast(block.text.len));

    // Apply bold/italic via Pango attributes
    const attr_list = c.pango_attr_list_new() orelse return 0;
    defer c.pango_attr_list_unref(attr_list);

    var bi: u32 = 0;
    while (bi < block.bold_count) : (bi += 1) {
        const start = block.bold_ranges[bi][0];
        const length = block.bold_ranges[bi][1];
        const attr = c.pango_attr_weight_new(c.PANGO_WEIGHT_BOLD) orelse continue;
        attr.*.start_index = start;
        attr.*.end_index = start + length;
        c.pango_attr_list_insert(attr_list, attr);
    }

    var ii: u32 = 0;
    while (ii < block.italic_count) : (ii += 1) {
        const start = block.italic_ranges[ii][0];
        const length = block.italic_ranges[ii][1];
        const attr = c.pango_attr_style_new(c.PANGO_STYLE_ITALIC) orelse continue;
        attr.*.start_index = start;
        attr.*.end_index = start + length;
        c.pango_attr_list_insert(attr_list, attr);
    }

    // Inline code ranges: monospace + different color
    var ci: u32 = 0;
    while (ci < block.code_count) : (ci += 1) {
        const start = block.code_ranges[ci][0];
        const length = block.code_ranges[ci][1];
        const attr = c.pango_attr_family_new("monospace") orelse continue;
        attr.*.start_index = start;
        attr.*.end_index = start + length;
        c.pango_attr_list_insert(attr_list, attr);
        // Tint inline code slightly
        const col_attr = c.pango_attr_foreground_new(
            @intFromFloat(col_hl_string.r * 65535.0),
            @intFromFloat(col_hl_string.g * 65535.0),
            @intFromFloat(col_hl_string.b * 65535.0),
        ) orelse continue;
        col_attr.*.start_index = start;
        col_attr.*.end_index = start + length;
        c.pango_attr_list_insert(attr_list, col_attr);
    }

    c.pango_layout_set_attributes(pango_layout, attr_list);

    setColor(cr, color);
    c.cairo_move_to(cr, x, y);
    c.pango_cairo_show_layout(cr, pango_layout);

    // Get height
    var pw: c_int = 0;
    var ph: c_int = 0;
    c.pango_layout_get_pixel_size(pango_layout, &pw, &ph);

    // Clean up layout state for next use
    c.pango_layout_set_attributes(pango_layout, null);

    return @floatFromInt(ph);
}

fn renderCodeBlock(
    cr: *c.cairo_t,
    pango_layout: *c.PangoLayout,
    block: *const md.Block,
    x: f32,
    y: f32,
    max_width: f32,
) f32 {
    if (block.text.len == 0) return 0;

    const desc = c.pango_font_description_from_string("Monospace 10") orelse return 0;
    defer c.pango_font_description_free(desc);

    c.pango_layout_set_font_description(pango_layout, desc);
    c.pango_layout_set_width(pango_layout, @intFromFloat((max_width - 32) * @as(f32, c.PANGO_SCALE)));
    c.pango_layout_set_wrap(pango_layout, c.PANGO_WRAP_WORD_CHAR);
    c.pango_layout_set_text(pango_layout, block.text.ptr, @intCast(block.text.len));

    // Apply syntax highlighting as Pango attributes
    const attr_list = buildSyntaxAttributes(block.text);
    c.pango_layout_set_attributes(pango_layout, attr_list);
    defer if (attr_list) |al| c.pango_attr_list_unref(al);

    // Measure
    var pw: c_int = 0;
    var ph: c_int = 0;
    c.pango_layout_get_pixel_size(pango_layout, &pw, &ph);
    const block_height: f32 = @as(f32, @floatFromInt(ph)) + 24;

    // Draw rounded-rect background
    drawRoundedRect(cr, x, y, max_width, block_height, 6);
    setColor(cr, col_code_bg);
    c.cairo_fill(cr);

    // Draw text
    setColor(cr, col_text);
    c.cairo_move_to(cr, x + 16, y + 12);
    c.pango_cairo_show_layout(cr, pango_layout);

    c.pango_layout_set_attributes(pango_layout, null);

    return block_height;
}

fn drawRoundedRect(cr: *c.cairo_t, x: f32, y: f32, w: f32, h: f32, r: f32) void {
    const pi = std.math.pi;
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + w - r, y + r, r, -pi / 2.0, 0);
    c.cairo_arc(cr, x + w - r, y + h - r, r, 0, pi / 2.0);
    c.cairo_arc(cr, x + r, y + h - r, r, pi / 2.0, pi);
    c.cairo_arc(cr, x + r, y + r, r, pi, 3.0 * pi / 2.0);
    c.cairo_close_path(cr);
}

fn drawCloseButton(cr: *c.cairo_t) void {
    const bx = app.window_width - 36;
    setColor(cr, col_close);
    c.cairo_set_line_width(cr, 1.5);
    c.cairo_move_to(cr, bx + 4, 12);
    c.cairo_line_to(cr, bx + 20, 28);
    c.cairo_stroke(cr);
    c.cairo_move_to(cr, bx + 20, 12);
    c.cairo_line_to(cr, bx + 4, 28);
    c.cairo_stroke(cr);
}

// ============================================================
// Syntax highlighting
// ============================================================
fn buildSyntaxAttributes(text: []const u8) ?*c.PangoAttrList {
    const attr_list = c.pango_attr_list_new() orelse return null;
    const len: u32 = @intCast(text.len);
    var i: u32 = 0;

    while (i < len) {
        const ch = text[i];

        // Line comments: // or #
        if (ch == '/' and i + 1 < len and text[i + 1] == '/') {
            const start = i;
            while (i < len and text[i] != '\n') i += 1;
            addColorAttr(attr_list, col_hl_comment, start, i);
            continue;
        }
        if (ch == '#') {
            const start = i;
            while (i < len and text[i] != '\n') i += 1;
            addColorAttr(attr_list, col_hl_comment, start, i);
            continue;
        }
        // Block comments: /* ... */
        if (ch == '/' and i + 1 < len and text[i + 1] == '*') {
            const start = i;
            i += 2;
            while (i + 1 < len and !(text[i] == '*' and text[i + 1] == '/')) i += 1;
            if (i + 1 < len) i += 2;
            addColorAttr(attr_list, col_hl_comment, start, i);
            continue;
        }
        // Strings
        if (ch == '"' or ch == '\'') {
            const start = i;
            const quote = ch;
            i += 1;
            while (i < len and text[i] != quote and text[i] != '\n') {
                if (text[i] == '\\' and i + 1 < len) i += 1;
                i += 1;
            }
            if (i < len) i += 1;
            addColorAttr(attr_list, col_hl_string, start, i);
            continue;
        }
        // Numbers
        if (ch >= '0' and ch <= '9') {
            const start = i;
            while (i < len and ((text[i] >= '0' and text[i] <= '9') or text[i] == '.' or
                text[i] == 'x' or text[i] == 'b' or
                (text[i] >= 'a' and text[i] <= 'f') or
                (text[i] >= 'A' and text[i] <= 'F') or text[i] == '_'))
                i += 1;
            addColorAttr(attr_list, col_hl_number, start, i);
            continue;
        }
        // Identifiers / keywords / types / functions
        if (md.isIdentStart(ch)) {
            const start = i;
            while (i < len and md.isIdentChar(text[i])) i += 1;
            const word = text[start..i];

            // Check if followed by '(' => function call
            var j = i;
            while (j < len and text[j] == ' ') j += 1;
            if (j < len and text[j] == '(') {
                addColorAttr(attr_list, col_hl_func, start, i);
                continue;
            }

            // Check keywords
            var is_kw = false;
            for (md.hl_keywords) |kw| {
                if (std.mem.eql(u8, word, kw)) {
                    addColorAttr(attr_list, col_hl_keyword, start, i);
                    is_kw = true;
                    break;
                }
            }
            if (is_kw) continue;

            // Uppercase start => type
            if (ch >= 'A' and ch <= 'Z' and word.len > 1) {
                addColorAttr(attr_list, col_hl_type, start, i);
            }
            continue;
        }
        i += 1;
    }

    return attr_list;
}

fn addColorAttr(attr_list: *c.PangoAttrList, color: Color, start: u32, end: u32) void {
    const attr = c.pango_attr_foreground_new(
        @intFromFloat(color.r * 65535.0),
        @intFromFloat(color.g * 65535.0),
        @intFromFloat(color.b * 65535.0),
    ) orelse return;
    attr.*.start_index = start;
    attr.*.end_index = end;
    c.pango_attr_list_insert(attr_list, attr);
}

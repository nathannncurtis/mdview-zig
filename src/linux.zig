// Linux backend — X11 + Cairo + Pango
const std = @import("std");
const app = @import("main.zig");
const md = app.md;
const hl = @import("highlight.zig");

const c = @import("c");

const posix = std.posix;

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
const col_border = Color{ .r = 48.0 / 255.0, .g = 54.0 / 255.0, .b = 61.0 / 255.0 };
const col_close = Color{ .r = 139.0 / 255.0, .g = 148.0 / 255.0, .b = 158.0 / 255.0 };

const col_hl_string = Color{ .r = 165.0 / 255.0, .g = 214.0 / 255.0, .b = 255.0 / 255.0 };

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
    var last_save_time: i64 = std.Io.Timestamp.now(app.io, .awake).toMilliseconds();
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
        const now = std.Io.Timestamp.now(app.io, .awake).toMilliseconds();
        if (now - last_save_time >= 3000) {
            app.saveScrollPosition();
            last_save_time = now;
        }

        // Use poll() with 500ms timeout for file watching
        var pollfds = [_]posix.pollfd{.{ .fd = x11_fd, .events = posix.POLL.IN, .revents = 0 }};
        const poll_result = posix.poll(&pollfds, 500) catch 0;
        if (poll_result == 0) {
            app.checkFileChanged();
        }
    }

    app.saveScrollPosition();
    _ = c.XDestroyWindow(dpy, window);
    _ = c.XCloseDisplay(dpy);
}

pub fn registerFileAssociation() void {
    // Create .desktop file for .md file association
    const io = app.io;
    const cwd = std.Io.Dir.cwd();
    const home = app.environ.get("HOME") orelse {
        app.log("cannot get HOME for .desktop file");
        return;
    };

    // Get our own executable path
    var exe_buf: [4096]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch {
        app.log("cannot get self exe path");
        return;
    };
    const exe_path = exe_buf[0..exe_len];

    const desktop_dir = std.fmt.allocPrint(app.allocator, "{s}/.local/share/applications", .{home}) catch return;
    cwd.createDirPath(io, desktop_dir) catch {};

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

    const f = cwd.createFile(io, desktop_path, .{ .truncate = true }) catch {
        app.log("failed to create .desktop file");
        return;
    };
    defer f.close(io);
    f.writeStreamingAll(io, desktop_content) catch return;

    // Also set the mime association
    const mimeapps_path = std.fmt.allocPrint(app.allocator, "{s}/.local/share/applications/mimeapps.list", .{home}) catch return;

    // Append to mimeapps.list
    if (cwd.openFile(io, mimeapps_path, .{ .mode = .read_write })) |mf| {
        defer mf.close(io);
        const end = mf.length(io) catch return;
        mf.writePositionalAll(io, "text/markdown=mdview.desktop;\ntext/x-markdown=mdview.desktop;\n", end) catch return;
    } else |_| {
        const mf = cwd.createFile(io, mimeapps_path, .{ .truncate = true }) catch return;
        defer mf.close(io);
        mf.writeStreamingAll(io, "[Default Applications]\ntext/markdown=mdview.desktop;\ntext/x-markdown=mdview.desktop;\n") catch return;
    }

    std.Io.File.stdout().writeStreamingAll(io, "mdview registered as default viewer for .md and .markdown files.\n") catch {};
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

    for (app.blocks) |*block| {
        switch (block.kind) {
            .h1 => {
                y += 24;
                y += renderTextBlock(cr, pango_layout, block.content, padding, y, max_width, col_text, "Sans Bold 24");
                y += 8;
                // Underline
                setColor(cr, col_hr);
                c.cairo_rectangle(cr, padding, y, max_width, 1);
                c.cairo_fill(cr);
                y += 16;
            },
            .h2 => {
                y += 20;
                y += renderTextBlock(cr, pango_layout, block.content, padding, y, max_width, col_text, "Sans Bold 18");
                y += 6;
                setColor(cr, col_hr);
                c.cairo_rectangle(cr, padding, y, max_width, 1);
                c.cairo_fill(cr);
                y += 16;
            },
            .h3 => {
                y += 16;
                y += renderTextBlock(cr, pango_layout, block.content, padding, y, max_width, col_text, "Sans Bold 15");
                y += 12;
            },
            .paragraph => {
                y += renderTextBlock(cr, pango_layout, block.content, padding, y, max_width, col_text, "Sans 12");
                y += 16;
            },
            .list_item => {
                // Bullet
                setColor(cr, col_text);
                c.cairo_arc(cr, padding + 10, y + 9, 2.5, 0, 2.0 * std.math.pi);
                c.cairo_fill(cr);
                y += renderTextBlock(cr, pango_layout, block.content, padding + 24, y, max_width - 24, col_text, "Sans 12");
                y += 8;
            },
            .blockquote => {
                // Left bar
                setColor(cr, col_hr);
                c.cairo_rectangle(cr, padding, y, 3, 24);
                c.cairo_fill(cr);
                y += renderTextBlock(cr, pango_layout, block.content, padding + 16, y, max_width - 16, col_quote, "Sans Italic 12");
                y += 16;
            },
            .code_block => {
                y += renderCodeBlock(cr, pango_layout, block.content.text, block.tokens, padding, y, max_width);
                y += 16;
            },
            .table => {
                y += renderTable(cr, pango_layout, block.table, padding, y, max_width);
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
    content: md.Inline,
    x: f32,
    y: f32,
    max_width: f32,
    color: Color,
    font_desc_str: [*:0]const u8,
) f32 {
    if (content.text.len == 0) return 0;
    setInline(pango_layout, content, max_width, font_desc_str);

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

fn setInline(pango_layout: *c.PangoLayout, content: md.Inline, max_width: ?f32, font_desc_str: [*:0]const u8) void {
    const desc = c.pango_font_description_from_string(font_desc_str) orelse return;
    defer c.pango_font_description_free(desc);

    c.pango_layout_set_font_description(pango_layout, desc);
    c.pango_layout_set_width(pango_layout, if (max_width) |w| @intFromFloat(w * @as(f32, c.PANGO_SCALE)) else -1);
    c.pango_layout_set_wrap(pango_layout, c.PANGO_WRAP_WORD_CHAR);
    c.pango_layout_set_text(pango_layout, content.text.ptr, @intCast(content.text.len));

    // Apply bold/italic via Pango attributes
    const attr_list = c.pango_attr_list_new() orelse return;
    defer c.pango_attr_list_unref(attr_list);

    for (content.bold) |span| {
        const start = span[0];
        const length = span[1];
        const attr = c.pango_attr_weight_new(c.PANGO_WEIGHT_BOLD) orelse continue;
        attr.*.start_index = start;
        attr.*.end_index = start + length;
        c.pango_attr_list_insert(attr_list, attr);
    }

    for (content.italic) |span| {
        const start = span[0];
        const length = span[1];
        const attr = c.pango_attr_style_new(c.PANGO_STYLE_ITALIC) orelse continue;
        attr.*.start_index = start;
        attr.*.end_index = start + length;
        c.pango_attr_list_insert(attr_list, attr);
    }

    for (content.strike) |span| {
        const attr = c.pango_attr_strikethrough_new(1) orelse continue;
        attr.*.start_index = span[0];
        attr.*.end_index = span[0] + span[1];
        c.pango_attr_list_insert(attr_list, attr);
    }

    for (content.emoji) |span| {
        const attr = c.pango_attr_family_new("Noto Color Emoji,Twemoji,Emoji,Sans") orelse continue;
        attr.*.start_index = span[0];
        attr.*.end_index = span[0] + span[1];
        c.pango_attr_list_insert(attr_list, attr);
    }

    // Inline code ranges: monospace + different color
    for (content.code) |span| {
        const start = span[0];
        const length = span[1];
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
}

const cell_pad_x: f32 = 13;
const cell_pad_y: f32 = 6;

fn setCell(pango_layout: *c.PangoLayout, t: md.Table, row: usize, col: usize, width: ?f32) void {
    setInline(pango_layout, t.cell(row, col), width, if (row == 0) "Sans Bold 12" else "Sans 12");
    c.pango_layout_set_alignment(pango_layout, @intCast(switch (t.aligns[col]) {
        .none, .left => c.PANGO_ALIGN_LEFT,
        .center => c.PANGO_ALIGN_CENTER,
        .right => c.PANGO_ALIGN_RIGHT,
    }));
}

fn layoutPixelSize(pango_layout: *c.PangoLayout) [2]f32 {
    var pw: c_int = 0;
    var ph: c_int = 0;
    c.pango_layout_get_pixel_size(pango_layout, &pw, &ph);
    return .{ @floatFromInt(pw), @floatFromInt(ph) };
}

fn renderTable(cr: *c.cairo_t, pango_layout: *c.PangoLayout, t: md.Table, x: f32, y: f32, max_width: f32) f32 {
    const widths = app.gpa.alloc(f32, t.columns) catch return 0;
    defer app.gpa.free(widths);

    @memset(widths, 0);
    for (0..t.rows()) |row| {
        for (widths, 0..) |*w, col| {
            setCell(pango_layout, t, row, col, null);
            w.* = @max(w.*, layoutPixelSize(pango_layout)[0]);
        }
    }
    for (widths) |*w| w.* += cell_pad_x * 2 + 1;
    md.fitColumns(widths, max_width, cell_pad_x * 2 + 24);
    var table_w: f32 = 0;
    for (widths) |w| table_w += w;

    var row_y = y;
    for (0..t.rows()) |row| {
        var text_h: f32 = 0;
        for (widths, 0..) |w, col| {
            setCell(pango_layout, t, row, col, w - cell_pad_x * 2);
            text_h = @max(text_h, layoutPixelSize(pango_layout)[1]);
        }
        const row_h = text_h + cell_pad_y * 2;
        if (row == 0) {
            setColor(cr, col_code_bg);
            c.cairo_rectangle(cr, x, row_y, table_w, row_h);
            c.cairo_fill(cr);
        }
        var cx = x;
        for (widths, 0..) |w, col| {
            setCell(pango_layout, t, row, col, w - cell_pad_x * 2);
            setColor(cr, col_text);
            c.cairo_move_to(cr, cx + cell_pad_x, row_y + cell_pad_y);
            c.pango_cairo_show_layout(cr, pango_layout);
            cx += w;
        }
        setColor(cr, col_border);
        c.cairo_rectangle(cr, x, row_y, table_w, 1);
        c.cairo_fill(cr);
        row_y += row_h;
    }
    c.pango_layout_set_attributes(pango_layout, null);
    c.pango_layout_set_alignment(pango_layout, c.PANGO_ALIGN_LEFT);

    setColor(cr, col_border);
    c.cairo_rectangle(cr, x, row_y, table_w, 1);
    c.cairo_rectangle(cr, x, y, 1, row_y + 1 - y);
    var cx = x;
    for (widths) |w| {
        cx += w;
        c.cairo_rectangle(cr, cx - 1, y, 1, row_y + 1 - y);
    }
    c.cairo_fill(cr);
    return row_y + 1 - y;
}

fn renderCodeBlock(
    cr: *c.cairo_t,
    pango_layout: *c.PangoLayout,
    text: []const u8,
    toks: []const hl.Token,
    x: f32,
    y: f32,
    max_width: f32,
) f32 {
    if (text.len == 0) return 0;

    const desc = c.pango_font_description_from_string("Monospace 10") orelse return 0;
    defer c.pango_font_description_free(desc);

    c.pango_layout_set_font_description(pango_layout, desc);
    c.pango_layout_set_width(pango_layout, @intFromFloat((max_width - 32) * @as(f32, c.PANGO_SCALE)));
    c.pango_layout_set_wrap(pango_layout, c.PANGO_WRAP_WORD_CHAR);
    c.pango_layout_set_text(pango_layout, text.ptr, @intCast(text.len));


    // Apply syntax highlighting as Pango attributes
    const attr_list = buildSyntaxAttributes(toks);
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

    drawLineBackgrounds(cr, pango_layout, toks, x, y + 12, max_width);

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
fn rgbColor(rgb: u24) Color {
    return .{
        .r = @as(f64, @floatFromInt(rgb >> 16 & 0xff)) / 255.0,
        .g = @as(f64, @floatFromInt(rgb >> 8 & 0xff)) / 255.0,
        .b = @as(f64, @floatFromInt(rgb & 0xff)) / 255.0,
    };
}

fn buildSyntaxAttributes(toks: []const hl.Token) ?*c.PangoAttrList {
    const attr_list = c.pango_attr_list_new() orelse return null;
    for (toks) |tok| {
        const st = hl.style(tok.kind);
        if (st.fg) |rgb| addColorAttr(attr_list, rgbColor(rgb), tok.start, tok.end);
        if (st.bold) addAttr(attr_list, c.pango_attr_weight_new(c.PANGO_WEIGHT_BOLD), tok.start, tok.end);
        if (st.underline) addAttr(attr_list, c.pango_attr_underline_new(c.PANGO_UNDERLINE_SINGLE), tok.start, tok.end);
    }
    return attr_list;
}

fn addAttr(attr_list: *c.PangoAttrList, attr: ?*c.PangoAttribute, start: u32, end: u32) void {
    const a = attr orelse return;
    a.*.start_index = start;
    a.*.end_index = end;
    c.pango_attr_list_insert(attr_list, a);
}

fn drawLineBackgrounds(cr: *c.cairo_t, layout: *c.PangoLayout, toks: []const hl.Token, x: f32, y: f32, width: f32) void {
    const iter = c.pango_layout_get_iter(layout) orelse return;
    defer c.pango_layout_iter_free(iter);
    var i: usize = 0;
    while (true) {
        const start: u32 = @intCast(c.pango_layout_iter_get_index(iter));
        while (i < toks.len and (hl.style(toks[i].kind).bg == null or toks[i].end <= start)) i += 1;
        if (i < toks.len and toks[i].start <= start) {
            var r: c.PangoRectangle = undefined;
            c.pango_layout_iter_get_line_extents(iter, null, &r);
            const scale: f64 = c.PANGO_SCALE;
            setColor(cr, rgbColor(hl.style(toks[i].kind).bg.?));
            c.cairo_rectangle(cr, x, y + @as(f64, @floatFromInt(r.y)) / scale, width, @as(f64, @floatFromInt(r.height)) / scale);
            c.cairo_fill(cr);
        }
        if (c.pango_layout_iter_next_line(iter) == 0) break;
    }
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

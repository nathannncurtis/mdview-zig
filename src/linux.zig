// Linux backend — X11 + Cairo + Pango
const std = @import("std");
const app = @import("main.zig");
const md = app.md;
const hl = @import("highlight.zig");
const alerts = @import("alerts.zig");

const c = @import("c");

const posix = std.posix;

// ============================================================
// State
// ============================================================
var display: ?*c.Display = null;
var window: c.Window = 0;
var needs_redraw: bool = true;
var wm_delete_window: c.Atom = 0;
var hand_cursor: c.Cursor = 0;
var over_link = false;

// ============================================================
// Colors
// ============================================================
const Color = struct { r: f64, g: f64, b: f64 };

const col_bg = Color{ .r = 13.0 / 255.0, .g = 17.0 / 255.0, .b = 23.0 / 255.0 };
const col_text = Color{ .r = 201.0 / 255.0, .g = 209.0 / 255.0, .b = 217.0 / 255.0 };
const col_code_bg = Color{ .r = 22.0 / 255.0, .g = 27.0 / 255.0, .b = 34.0 / 255.0 };
const col_quote = Color{ .r = 139.0 / 255.0, .g = 148.0 / 255.0, .b = 158.0 / 255.0 };
const col_hr = Color{ .r = 33.0 / 255.0, .g = 38.0 / 255.0, .b = 45.0 / 255.0 };
const col_table_border = hexColor(0x3d444d);
const col_stripe = hexColor(0x151b23);
const col_close = Color{ .r = 139.0 / 255.0, .g = 148.0 / 255.0, .b = 158.0 / 255.0 };
const col_link = Color{ .r = 68.0 / 255.0, .g = 147.0 / 255.0, .b = 248.0 / 255.0 };

const col_hl_string = Color{ .r = 165.0 / 255.0, .g = 214.0 / 255.0, .b = 255.0 / 255.0 };

// ============================================================
// Public API
// ============================================================
pub fn invalidate() void {
    needs_redraw = true;
    if (display) |dpy| {
        // SAFETY: every field XSendEvent reads is set below
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
    hand_cursor = c.XCreateFontCursor(dpy, c.XC_hand2);

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
            // SAFETY: written by XNextEvent
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
                    if ((ke.state & c.Mod1Mask) != 0) {
                        if (keysym == 0xFF51) app.goBack();
                        if (keysym == 0xFF53) app.goForward();
                    }
                    // Ctrl+Q to quit
                    if (keysym == 'q' and (ke.state & c.ControlMask) != 0) {
                        running = false;
                    }
                },
                c.MotionNotify => {
                    const me = ev.xmotion;
                    const over = app.pointerMoved(@floatFromInt(me.x), @floatFromInt(me.y));
                    if (over != over_link) {
                        over_link = over;
                        if (over) _ = c.XDefineCursor(dpy, window, hand_cursor) else _ = c.XUndefineCursor(dpy, window);
                    }
                },
                c.ButtonRelease => {
                    const be = ev.xbutton;
                    if (be.button == 1) _ = app.mouseUp(@floatFromInt(be.x), @floatFromInt(be.y));
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
                    // Back and forward buttons
                    else if (be.button == 8) {
                        app.goBack();
                    } else if (be.button == 9) {
                        app.goForward();
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
                        } else {
                            _ = app.mouseDown(bx, by);
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
    cwd.createDirPath(io, desktop_dir) catch return;

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

    std.Io.File.stdout().writeStreamingAll(io, "mdview registered as default viewer for .md and .markdown files.\n") catch return;
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
    app.beginFrame();

    for (app.blocks) |*block| {
        app.noteBlock(y + app.scroll_y);
        const inset = block.inset();
        const x = padding + inset;
        const cw = @max(max_width - inset, 60);
        const top = y;
        var gap: f32 = 0;
        const text_col = if (block.muted()) col_quote else col_text;
        for (block.marks) |l| drawMarker(cr, pango_layout, l.mark, padding + l.inset, y);

        switch (block.kind) {
            .h1 => {
                y += 24;
                y += renderTextBlock(cr, pango_layout, block.content, x, y, cw, col_text, "Sans Bold 24");
                y += 8;
                setColor(cr, col_hr);
                c.cairo_rectangle(cr, x, y, cw, 1);
                c.cairo_fill(cr);
                y += 1;
                gap = 16;
            },
            .h2 => {
                y += 20;
                y += renderTextBlock(cr, pango_layout, block.content, x, y, cw, col_text, "Sans Bold 18");
                y += 6;
                setColor(cr, col_hr);
                c.cairo_rectangle(cr, x, y, cw, 1);
                c.cairo_fill(cr);
                y += 1;
                gap = 16;
            },
            .h3 => {
                y += 16;
                y += renderTextBlock(cr, pango_layout, block.content, x, y, cw, col_text, "Sans Bold 15");
                gap = 12;
            },
            .h4, .h5, .h6 => {
                y += 24;
                const font: [*:0]const u8 = switch (block.kind) {
                    .h4 => "Sans Bold 12",
                    .h5 => "Sans Bold 10.5",
                    else => "Sans Bold 10.2",
                };
                y += renderTextBlock(cr, pango_layout, block.content, x, y, cw, if (block.kind == .h6) col_quote else col_text, font);
                gap = 16;
            },
            .paragraph => {
                y += renderTextBlock(cr, pango_layout, block.content, x, y, cw, text_col, "Sans 12");
                gap = block.paragraphGap();
            },
            .alert_title => {
                const alert = block.frames[block.frames.len - 1].alert;
                y += 8;
                drawAlertIcon(cr, alert, x, y);
                _ = renderTextBlock(cr, pango_layout, block.content, x + 24, y - 2, cw - 24, hexColor(alerts.style(alert).fg), "Sans Bold 12");
                y += 16;
                gap = 16;
            },
            .error_box => {
                y += renderErrorBox(cr, pango_layout, block.content, x, y, cw);
                gap = 16;
            },
            .code_block => {
                y += renderCodeBlock(cr, pango_layout, block.content.text, block.tokens, x, y, cw);
                gap = 16;
            },
            .table => {
                y += renderTable(cr, pango_layout, block.table, x, y, cw, true, null);
                gap = 16;
            },
            .hr => {
                y += 12;
                setColor(cr, col_hr);
                c.cairo_rectangle(cr, x, y, cw, 2);
                c.cairo_fill(cr);
                y += 2;
                gap = 14;
            },
        }

        for (block.frames, 0..) |f, i| {
            if (f.kind != .quote) continue;
            if (f.alert != .none and !f.open) y += 8;
            setColor(cr, if (f.alert == .none) col_bar else hexColor(alerts.style(f.alert).border));
            c.cairo_rectangle(cr, padding + block.insetBefore(i), top, md.quote_bar, y + (if (f.open) gap else 0) - top);
            c.cairo_fill(cr);
        }
        y += gap;
    }

    app.content_height = y + app.scroll_y + padding;

    // Close button (X) — drawn in screen coordinates (not scrolled)
    drawCloseButton(cr);

    _ = c.cairo_surface_flush(surface);
    if (app.afterRender()) needs_redraw = true;
}

fn setColor(cr: *c.cairo_t, col: Color) void {
    c.cairo_set_source_rgb(cr, col.r, col.g, col.b);
}

const LineBox = struct { start: u32, y: c_int, height: c_int };

fn drawCodeBackgrounds(cr: *c.cairo_t, layout: *c.PangoLayout, content: md.Inline, x: f32, y: f32) void {
    if (content.code.len == 0) return;
    const scale: f64 = c.PANGO_SCALE;
    const desc = c.pango_layout_get_font_description(layout);
    const points: f64 = if (desc) |d| @as(f64, @floatFromInt(c.pango_font_description_get_size(d))) / scale else 12;
    const pad: f64 = md.code_pad_em * md.code_scale * points * 96.0 / 72.0;

    var lines: std.ArrayList(LineBox) = .empty;
    defer lines.deinit(app.gpa);
    const iter = c.pango_layout_get_iter(layout) orelse return;
    defer c.pango_layout_iter_free(iter);
    while (true) {
        // SAFETY: written by pango_layout_iter_get_line_extents
        var logical: c.PangoRectangle = undefined;
        c.pango_layout_iter_get_line_extents(iter, null, &logical);
        lines.append(app.gpa, .{ .start = @intCast(c.pango_layout_iter_get_index(iter)), .y = logical.y, .height = logical.height }) catch return;
        if (c.pango_layout_iter_next_line(iter) == 0) break;
    }

    const bg = rgbColor(md.code_bg);
    c.cairo_set_source_rgba(cr, bg.r, bg.g, bg.b, md.code_bg_alpha);
    var first: usize = 0;
    for (lines.items, 0..) |box, index| {
        const line_end: u32 = if (index + 1 < lines.items.len) lines.items[index + 1].start else @intCast(content.text.len);
        while (first < content.code.len and content.code[first][0] + content.code[first][1] <= box.start) first += 1;
        const line = c.pango_layout_get_line_readonly(layout, @intCast(index)) orelse continue;
        var k = first;
        while (k < content.code.len and content.code[k][0] < line_end) : (k += 1) {
            const span = content.code[k];
            const from = @max(span[0], box.start);
            const to = @min(span[0] + span[1], line_end);
            if (from >= to) continue;
            var found: ?[*]c_int = null;
            var n: c_int = 0;
            c.pango_layout_line_get_x_ranges(line, @intCast(from), @intCast(to), &found, &n);
            const ranges = found orelse continue;
            defer c.g_free(@ptrCast(ranges));
            const total: usize = @intCast(n);
            for (0..total) |i| {
                const left = @as(f64, @floatFromInt(ranges[i * 2])) / scale - (if (i == 0 and span[0] >= box.start) pad else 0);
                const right = @as(f64, @floatFromInt(ranges[i * 2 + 1])) / scale + (if (i + 1 == total and span[0] + span[1] <= line_end) pad else 0);
                drawRoundedRect(cr, x + @as(f32, @floatCast(left)), y + @as(f32, @floatFromInt(box.y)) / @as(f32, c.PANGO_SCALE), @floatCast(right - left), @as(f32, @floatFromInt(box.height)) / @as(f32, c.PANGO_SCALE), md.code_radius);
                c.cairo_fill(cr);
            }
        }
    }
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

    drawCodeBackgrounds(cr, pango_layout, content, x, y);
    setColor(cr, color);
    c.cairo_move_to(cr, x, y);
    c.pango_cairo_show_layout(cr, pango_layout);

    // Get height
    var pw: c_int = 0;
    var ph: c_int = 0;
    c.pango_layout_get_pixel_size(pango_layout, &pw, &ph);

    // Clean up layout state for next use
    c.pango_layout_set_attributes(pango_layout, null);

    app.noteHit(.{ .content = content, .x = x, .y = y + app.scroll_y, .w = max_width, .h = @floatFromInt(ph), .font = fontOfDesc(font_desc_str) });
    return @floatFromInt(ph);
}

fn fontOfDesc(desc: [*:0]const u8) app.Font {
    const names = [_]struct { []const u8, app.Font }{
        .{ "Sans Bold 24", .h1 },
        .{ "Sans Bold 18", .h2 },
        .{ "Sans Bold 15", .h3 },
        .{ "Sans Bold 12", .h4 },
        .{ "Sans Bold 10.5", .h5 },
        .{ "Sans Bold 10.2", .h6 },
    };
    for (names) |n| if (std.mem.eql(u8, std.mem.span(desc), n[0])) return n[1];
    return .body;
}

fn fontDesc(font: app.Font) [*:0]const u8 {
    return switch (font) {
        .body => "Sans 12",
        .h1 => "Sans Bold 24",
        .h2 => "Sans Bold 18",
        .h3 => "Sans Bold 15",
        .h4 => "Sans Bold 12",
        .h5 => "Sans Bold 10.5",
        .h6 => "Sans Bold 10.2",
    };
}

pub fn textIndexAt(hit: app.Hit, x: f32, y: f32) ?u32 {
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1) orelse return null;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return null;
    defer c.cairo_destroy(cr);
    const layout = c.pango_cairo_create_layout(cr) orelse return null;
    defer c.g_object_unref(layout);

    setInline(layout, hit.content, hit.w, if (hit.header) "Sans Bold 12" else fontDesc(hit.font));
    c.pango_layout_set_alignment(layout, @intCast(switch (hit.alignment) {
        .none, .left => c.PANGO_ALIGN_LEFT,
        .center => c.PANGO_ALIGN_CENTER,
        .right => c.PANGO_ALIGN_RIGHT,
    }));
    var index: c_int = 0;
    var trailing: c_int = 0;
    const scale: f32 = @floatFromInt(c.PANGO_SCALE);
    if (c.pango_layout_xy_to_index(layout, @intFromFloat(x * scale), @intFromFloat(y * scale), &index, &trailing) == 0) return null;
    return @intCast(index);
}

fn openUrl(url: []u8) void {
    defer app.gpa.free(url);
    var child = std.process.spawn(app.io, .{
        .argv = &.{ "xdg-open", url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(app.io) catch return;
}

pub fn openExternal(url: []const u8) void {
    const copy = app.gpa.dupe(u8, url) catch return;
    const thread = std.Thread.spawn(.{}, openUrl, .{copy}) catch {
        app.gpa.free(copy);
        return;
    };
    thread.detach();
}

fn spaceNeighbour(attr_list: *c.PangoAttrList, start: usize, end: usize, units: c_int) void {
    const attr = c.pango_attr_letter_spacing_new(units) orelse return;
    attr.*.start_index = @intCast(start);
    attr.*.end_index = @intCast(end);
    c.pango_attr_list_insert(attr_list, attr);
}

/// The code background pads the span like CSS; Pango can only widen a character on both sides, so the characters next to the span carry the room.
fn padCodeNeighbours(attr_list: *c.PangoAttrList, text: []const u8, span: md.Span, size_units: c_int) void {
    const units: c_int = @intFromFloat(2 * md.code_pad_em * md.code_scale * @as(f32, @floatFromInt(size_units)) * 96.0 / 72.0);
    if (span[0] > 0) {
        var from: usize = span[0] - 1;
        while (from > 0 and text[from] & 0xC0 == 0x80) from -= 1;
        spaceNeighbour(attr_list, from, span[0], units);
    }
    const end = span[0] + span[1];
    if (end < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
        spaceNeighbour(attr_list, end, @min(end + len, text.len), units);
    }
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
        if (c.pango_attr_scale_new(md.code_scale)) |size| {
            size.*.start_index = start;
            size.*.end_index = start + length;
            c.pango_attr_list_insert(attr_list, size);
        }
        padCodeNeighbours(attr_list, content.text, span, c.pango_font_description_get_size(desc));
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

    for (content.links) |l| {
        const color = c.pango_attr_foreground_new(
            @intFromFloat(col_link.r * 65535.0),
            @intFromFloat(col_link.g * 65535.0),
            @intFromFloat(col_link.b * 65535.0),
        ) orelse continue;
        color.*.start_index = l.start;
        color.*.end_index = l.start + l.len;
        c.pango_attr_list_insert(attr_list, color);
        if (app.isHover(content, l)) {
            const underline = c.pango_attr_underline_new(c.PANGO_UNDERLINE_SINGLE) orelse continue;
            underline.*.start_index = l.start;
            underline.*.end_index = l.start + l.len;
            c.pango_attr_list_insert(attr_list, underline);
        }
    }

    const rise: c_int = @intFromFloat(@as(f64, @floatFromInt(c.pango_font_description_get_size(desc))) * 0.4);
    for (content.sup) |span| {
        const scale = c.pango_attr_scale_new(0.7) orelse continue;
        scale.*.start_index = span[0];
        scale.*.end_index = span[0] + span[1];
        c.pango_attr_list_insert(attr_list, scale);
        const raise = c.pango_attr_rise_new(rise) orelse continue;
        raise.*.start_index = span[0];
        raise.*.end_index = span[0] + span[1];
        c.pango_attr_list_insert(attr_list, raise);
    }

    c.pango_layout_set_attributes(pango_layout, attr_list);
}

const cell_pad_x: f32 = 13;
const cell_pad_y: f32 = 6;

fn setCell(pango_layout: *c.PangoLayout, t: md.Table, row: usize, col: usize, width: ?f32) void {
    const bold = (row == 0 and t.header_row) or (col == 0 and t.header_col);
    setInline(pango_layout, t.cell(row, col), width, if (bold) "Sans Bold 12" else "Sans 12");
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

fn renderTable(cr: *c.cairo_t, pango_layout: *c.PangoLayout, t: md.Table, x: f32, y: f32, max_width: f32, draw: bool, out_width: ?*f32) f32 {
    if (out_width) |o| o.* = 0;
    if (t.rows() == 0) return 0;
    const widths = app.gpa.alloc(f32, t.columns) catch return 0;
    defer app.gpa.free(widths);

    @memset(widths, 0);
    for (0..t.rows()) |row| {
        for (widths, 0..) |*w, col| {
            if (t.nestedAt(row, col)) |nt| {
                var nw: f32 = 0;
                _ = renderTable(cr, pango_layout, nt, 0, 0, 100000, false, &nw);
                w.* = @max(w.*, nw);
                continue;
            }
            setCell(pango_layout, t, row, col, null);
            w.* = @max(w.*, layoutPixelSize(pango_layout)[0]);
        }
    }
    for (widths) |*w| w.* += cell_pad_x * 2 + 1;
    md.fitColumns(widths, max_width, cell_pad_x * 2 + 24);
    var table_w: f32 = 0;
    for (widths) |w| table_w += w;
    if (out_width) |o| o.* = table_w;

    var row_y = y;
    for (0..t.rows()) |row| {
        var text_h: f32 = 0;
        for (widths, 0..) |w, col| {
            if (t.nestedAt(row, col)) |nt| {
                text_h = @max(text_h, renderTable(cr, pango_layout, nt, 0, 0, w - cell_pad_x * 2, false, null) + md.nested_table_margin);
                continue;
            }
            setCell(pango_layout, t, row, col, w - cell_pad_x * 2);
            text_h = @max(text_h, layoutPixelSize(pango_layout)[1]);
        }
        const row_h = text_h + cell_pad_y * 2;
        if (draw) {
            if (md.Table.striped(t, row)) {
                setColor(cr, col_stripe);
                c.cairo_rectangle(cr, x, row_y, table_w, row_h);
                c.cairo_fill(cr);
            }
            var cx = x;
            for (widths, 0..) |w, col| {
                if (t.nestedAt(row, col)) |nt| {
                    _ = renderTable(cr, pango_layout, nt, cx + cell_pad_x, row_y + cell_pad_y, w - cell_pad_x * 2, true, null);
                } else {
                    setCell(pango_layout, t, row, col, w - cell_pad_x * 2);
                    drawCodeBackgrounds(cr, pango_layout, t.cell(row, col), cx + cell_pad_x, row_y + cell_pad_y);
                    setColor(cr, col_text);
                    c.cairo_move_to(cr, cx + cell_pad_x, row_y + cell_pad_y);
                    c.pango_cairo_show_layout(cr, pango_layout);
                    app.noteHit(.{
                        .content = t.cell(row, col), .x = cx + cell_pad_x, .y = row_y + cell_pad_y + app.scroll_y, .w = w - cell_pad_x * 2,
                        .h = text_h, .header = (row == 0 and t.header_row) or (col == 0 and t.header_col), .alignment = t.aligns[col],
                    });
                }
                cx += w;
            }
            setColor(cr, col_table_border);
            c.cairo_rectangle(cr, x, row_y, table_w, 1);
            c.cairo_fill(cr);
        }
        row_y += row_h;
    }
    c.pango_layout_set_attributes(pango_layout, null);
    c.pango_layout_set_alignment(pango_layout, c.PANGO_ALIGN_LEFT);

    if (draw) {
        setColor(cr, col_table_border);
        c.cairo_rectangle(cr, x, row_y, table_w, 1);
        c.cairo_rectangle(cr, x, y, 1, row_y + 1 - y);
        var cx = x;
        for (widths) |w| {
            cx += w;
            c.cairo_rectangle(cr, cx - 1, y, 1, row_y + 1 - y);
        }
        c.cairo_fill(cr);
    }
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

fn hexColor(hex: u24) Color {
    return .{
        .r = @as(f64, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
        .g = @as(f64, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
        .b = @as(f64, @floatFromInt(hex & 0xFF)) / 255.0,
    };
}

const col_bar = hexColor(0x3d444d);
const col_check = hexColor(0x1f6feb);
const col_err_bg = hexColor(0x25171c);
const col_err_border = hexColor(0x6b2b2b);

fn drawAlertIcon(cr: *c.cairo_t, alert: md.Alert, x: f32, y: f32) void {
    setColor(cr, hexColor(alerts.style(alert).fg));
    c.cairo_new_path(cr);
    for (alerts.icon(alert)) |op| switch (op) {
        .move => |p| c.cairo_move_to(cr, x + p[0], y + p[1]),
        .line => |p| c.cairo_line_to(cr, x + p[0], y + p[1]),
        .cubic => |q| c.cairo_curve_to(cr, x + q[0], y + q[1], x + q[2], y + q[3], x + q[4], y + q[5]),
        .close => c.cairo_close_path(cr),
    };
    c.cairo_set_fill_rule(cr, c.CAIRO_FILL_RULE_WINDING);
    c.cairo_fill(cr);
}

fn renderErrorBox(cr: *c.cairo_t, pango_layout: *c.PangoLayout, content: md.Inline, x: f32, y: f32, w: f32) f32 {
    setInline(pango_layout, content, @max(w - 34, 20), "Sans 12");
    const h = layoutPixelSize(pango_layout)[1] + 32;
    drawRoundedRect(cr, x, y, w, h, 6);
    setColor(cr, col_err_border);
    c.cairo_fill(cr);
    drawRoundedRect(cr, x + 1, y + 1, w - 2, h - 2, 5);
    setColor(cr, col_err_bg);
    c.cairo_fill(cr);
    setColor(cr, col_text);
    c.cairo_move_to(cr, x + 17, y + 16);
    c.pango_cairo_show_layout(cr, pango_layout);
    c.pango_layout_set_attributes(pango_layout, null);
    return h;
}

fn drawMarker(cr: *c.cairo_t, pango_layout: *c.PangoLayout, m: md.Mark, x: f32, y: f32) void {
    switch (m.kind) {
        .none => {},
        .bullet => {
            const cx = x - 13;
            const cy = y + 12;
            setColor(cr, col_text);
            switch (m.depth % 3) {
                0 => {
                    c.cairo_arc(cr, cx, cy, 2.8, 0, 2.0 * std.math.pi);
                    c.cairo_fill(cr);
                },
                1 => {
                    c.cairo_set_line_width(cr, 1);
                    c.cairo_arc(cr, cx, cy, 2.4, 0, 2.0 * std.math.pi);
                    c.cairo_stroke(cr);
                },
                else => {
                    c.cairo_rectangle(cr, cx - 2.5, cy - 2.5, 5, 5);
                    c.cairo_fill(cr);
                },
            }
        },
        .number => {
            var buf: [16]u8 = undefined;
            setInline(pango_layout, .{ .text = md.markerLabel(&buf, m) }, null, "Sans 12");
            const size = layoutPixelSize(pango_layout);
            setColor(cr, col_text);
            c.cairo_move_to(cr, x - 6 - size[0], y);
            c.pango_cairo_show_layout(cr, pango_layout);
            c.pango_layout_set_attributes(pango_layout, null);
        },
        .task_open, .task_done => {
            const bx = x - 23;
            const by = y + 5;
            c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
            if (m.kind == .task_done) {
                drawRoundedRect(cr, bx, by, 14, 14, 3);
                setColor(cr, col_check);
                c.cairo_fill(cr);
                c.cairo_set_source_rgb(cr, 1, 1, 1);
                c.cairo_set_line_width(cr, 1.8);
                c.cairo_move_to(cr, bx + 3.5, by + 7.5);
                c.cairo_line_to(cr, bx + 6, by + 10);
                c.cairo_line_to(cr, bx + 10.5, by + 4.5);
                c.cairo_stroke(cr);
            } else {
                drawRoundedRect(cr, bx + 0.5, by + 0.5, 13, 13, 2.5);
                setColor(cr, col_quote);
                c.cairo_set_line_width(cr, 1);
                c.cairo_stroke(cr);
            }
        },
    }
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
            // SAFETY: written by pango_layout_iter_get_line_extents
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

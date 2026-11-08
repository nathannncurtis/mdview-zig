// Linux backend — X11 + Cairo + Pango
const std = @import("std");
const app = @import("../../main.zig");
const md = app.md;
const hl = @import("../../markdown/highlight.zig");
const alerts = @import("../../markdown/alerts.zig");
const tl = @import("../../markdown/table_layout.zig");
const html = @import("html.zig");
const setAlign = html.setAlign;
const padded = html.padded;
const isKbd = html.isKbd;
const kbdScale = html.kbdScale;
const applyStyles = html.applyStyles;
const drawStyleRects = html.drawStyleRects;
const naturalSize = html.naturalSize;
const floatOnly = html.floatOnly;
const placeFloats = html.placeFloats;
const renderBeside = html.renderBeside;
const drawSummaryMarker = html.drawSummaryMarker;
const resetSplits = html.resetSplits;
const Bands = html.Bands;
const kbd_pad = html.kbd_pad;

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
/// Device pixels per layout unit; layout is in these units and the cairo context scales them up.
var g_scale: f32 = 1;

/// The `Xft.dpi` value of an X resource database, which is what desktops set for their text scale.
fn xftDpi(db: []const u8) ?f32 {
    var lines = std.mem.splitScalar(u8, db, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const key = "Xft.dpi:";
        if (!std.mem.startsWith(u8, line, key)) continue;
        const dpi = std.fmt.parseFloat(f32, std.mem.trim(u8, line[key.len..], " \t")) catch return null;
        return if (dpi > 0) dpi else null;
    }
    return null;
}

fn detectScale(dpy: *c.Display) f32 {
    const scale: f32 = blk: {
        if (c.XResourceManagerString(dpy)) |db| {
            if (xftDpi(std.mem.span(db))) |dpi| break :blk dpi / 96.0;
        }
        const gdk = app.environ.get("GDK_SCALE") orelse break :blk 1;
        break :blk std.fmt.parseFloat(f32, gdk) catch 1;
    };
    return std.math.clamp(scale, 0.75, 4);
}

// ============================================================
// Colors
// ============================================================
pub const Color = struct { r: f64, g: f64, b: f64 };

const col_bg = Color{ .r = 13.0 / 255.0, .g = 17.0 / 255.0, .b = 23.0 / 255.0 };
pub const col_text = Color{ .r = 201.0 / 255.0, .g = 209.0 / 255.0, .b = 217.0 / 255.0 };
const col_code_bg = Color{ .r = 22.0 / 255.0, .g = 27.0 / 255.0, .b = 34.0 / 255.0 };
pub const col_quote = Color{ .r = 139.0 / 255.0, .g = 148.0 / 255.0, .b = 158.0 / 255.0 };
const col_hr = Color{ .r = 33.0 / 255.0, .g = 38.0 / 255.0, .b = 45.0 / 255.0 };
pub const col_table_border = hexColor(0x3d444d);
pub const col_stripe = hexColor(0x151b23);
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

    g_scale = detectScale(dpy);
    app.images.dpi_scale = g_scale;
    const width: c_uint = @intFromFloat(900 * g_scale);
    const height: c_uint = @intFromFloat(700 * g_scale);

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

    app.window_width = 900;
    app.window_height = 700;
    hand_cursor = c.XCreateFontCursor(dpy, c.XC_hand2);
    app.images.create_native = createNative;
    app.images.free_native = freeNative;

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
    var last_file_check: i64 = last_save_time;
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
                    app.window_width = @as(f32, @floatFromInt(ce.width)) / g_scale;
                    app.window_height = @as(f32, @floatFromInt(ce.height)) / g_scale;
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
                    const over = app.pointerMoved(@as(f32, @floatFromInt(me.x)) / g_scale, @as(f32, @floatFromInt(me.y)) / g_scale);
                    if (over != over_link) {
                        over_link = over;
                        if (over) _ = c.XDefineCursor(dpy, window, hand_cursor) else _ = c.XUndefineCursor(dpy, window);
                    }
                },
                c.ButtonRelease => {
                    const be = ev.xbutton;
                    if (be.button == 1) _ = app.mouseUp(@as(f32, @floatFromInt(be.x)) / g_scale, @as(f32, @floatFromInt(be.y)) / g_scale);
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
                        const bx: f32 = @as(f32, @floatFromInt(be.x)) / g_scale;
                        const by: f32 = @as(f32, @floatFromInt(be.y)) / g_scale;
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

        if (app.images.tick()) needs_redraw = true;

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

        // Poll with a short timeout while an animation or a load is pending, otherwise 500ms for file watching
        var pollfds = [_]posix.pollfd{.{ .fd = x11_fd, .events = posix.POLL.IN, .revents = 0 }};
        const wait: i32 = if (app.images.timerDelay()) |d| @intCast(@min(d, 500)) else 500;
        const poll_result = posix.poll(&pollfds, wait) catch 0;
        const after = std.Io.Timestamp.now(app.io, .awake).toMilliseconds();
        if (poll_result == 0 and after - last_file_check >= 500) {
            app.checkFileChanged();
            last_file_check = after;
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
    const w: c_int = @intFromFloat(app.window_width * g_scale);
    const h: c_int = @intFromFloat(app.window_height * g_scale);

    if (w <= 0 or h <= 0) return;

    // Create Cairo surface backed by X11
    const surface = c.cairo_xlib_surface_create(dpy, win, visual, w, h) orelse return;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return;
    defer c.cairo_destroy(cr);

    // Clear background
    setColor(cr, col_bg);
    c.cairo_paint(cr);
    c.cairo_scale(cr, g_scale, g_scale);

    // Create Pango layout
    const pango_layout = c.pango_cairo_create_layout(cr) orelse return;
    defer c.g_object_unref(pango_layout);
    c.pango_cairo_context_set_shape_renderer(c.pango_layout_get_context(pango_layout), drawShape, null, null);
    resetBoxes();

    const padding: f32 = 40;
    const max_width = @max(app.window_width - padding * 2, 100);
    app.beginFrame();
    resetSplits();

    const y = layoutBlocks(cr, pango_layout, app.blocks, padding, max_width, padding - app.scroll_y);
    app.content_height = y + app.scroll_y + padding;

    // Close button (X) — drawn in screen coordinates (not scrolled)
    drawCloseButton(cr);
    if (app.tooltip) |t| drawTooltip(cr, t);

    _ = c.cairo_surface_flush(surface);
    if (app.afterRender()) needs_redraw = true;
}

/// Draws `blocks` between `left` and `left + width` from `y0` down and returns the y after the last one.
pub fn layoutBlocks(cr: *c.cairo_t, pango_layout: *c.PangoLayout, blocks: []const md.Block, left: f32, width: f32, y0: f32) f32 {
    var y = y0;
    var bands: Bands = .{};
    var prev_gap: f32 = 0;
    for (blocks) |*block| {
        if (!html.measuring and html.nested == 0) app.noteBlock(y + app.scroll_y);
        if (app.collapsed(block.*)) continue;
        const inset = block.inset();
        var x = left + inset;
        var cw = @max(width - inset, 60);
        const top = y;
        var gap: f32 = 0;
        const text_col = if (block.muted()) col_quote else col_text;
        html.block_align = block.alignment;
        for (block.marks) |l| drawMarker(cr, pango_layout, l.mark, left + l.inset, y);

        if (block.kind == .paragraph) placeFloats(cr, block, x, cw, y, &bands);
        const beside = bands.at(y);
        if (block.kind != .paragraph) {
            x += beside.left;
            cw = @max(cw - beside.left - beside.right, 60);
        }

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
            .paragraph => if (block.role == .empty) {
                gap = block.paragraphGap();
            } else if (block.role == .break_lines) {
                y += html.breakLinesHeight(block.content);
            } else if (!floatOnly(block.content)) {
                const before = y;
                y += renderBeside(cr, pango_layout, block.content, x, y, cw, text_col, "Sans 12", beside);
                if (block.role == .summary) drawSummaryMarker(cr, pango_layout, block, x + beside.left, before, y - before, cw - beside.left - beside.right);
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
                var tw: f32 = 0;
                const side = tableFloat(block.table);
                if (side == .none) {
                    y += renderTable(cr, pango_layout, block.table, x, y, cw, !html.measuring, &tw);
                    gap = 16;
                } else {
                    const th = renderTable(cr, pango_layout, block.table, x, y, cw, false, &tw);
                    const spot = bands.place(side == .left, x, cw, y, tw, th);
                    _ = renderTable(cr, pango_layout, block.table, spot.x, spot.y, cw, !html.measuring, null);
                }
                html.extent = @max(html.extent, x + tw);
            },
            .hr => {
                y += @max(md.hr_margin - prev_gap, 0);
                setColor(cr, col_table_border);
                c.cairo_rectangle(cr, x, y, cw, md.hr_height);
                c.cairo_fill(cr);
                y += md.hr_height;
                gap = md.hr_margin;
            },
        }

        for (block.frames, 0..) |f, i| {
            if (f.kind != .quote) continue;
            if (f.alert != .none and !f.open) y += 8;
            setColor(cr, if (f.alert == .none) col_bar else hexColor(alerts.style(f.alert).border));
            c.cairo_rectangle(cr, left + block.insetBefore(i), top, md.quote_bar, y + (if (f.open) gap else 0) - top);
            c.cairo_fill(cr);
        }
        y += gap;
        prev_gap = gap;
    }
    html.block_align = .none;
    return y;
}

pub fn setColor(cr: *c.cairo_t, col: Color) void {
    c.cairo_set_source_rgb(cr, col.r, col.g, col.b);
}

const LineBox = struct { start: u32, y: c_int, height: c_int };

fn drawCodeBackgrounds(cr: *c.cairo_t, layout: *c.PangoLayout, content_in: md.Inline, x: f32, y: f32) void {
    const content = padded(content_in);
    if (content.code.len == 0) return;
    const scale: f64 = c.PANGO_SCALE;

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

    const spans = content.code;
    const text_len = content.text.len + 2 * pad_len * spans.len;
    const bg = rgbColor(md.code_bg);
    c.cairo_set_source_rgba(cr, bg.r, bg.g, bg.b, md.code_bg_alpha);
    var first: usize = 0;
    for (lines.items, 0..) |box, index| {
        const line_end: u32 = if (index + 1 < lines.items.len) lines.items[index + 1].start else @intCast(text_len);
        while (first < spans.len and rightMark(spans, first) + pad_len <= box.start) first += 1;
        const line = c.pango_layout_get_line_readonly(layout, @intCast(index)) orelse continue;
        var k = first;
        while (k < spans.len and leftMark(spans, k) < line_end) : (k += 1) {
            const from = @max(leftMark(spans, k), box.start);
            const to = @min(rightMark(spans, k) + pad_len, line_end);
            if (from >= to or isKbd(content_in, spans[k])) continue;
            var found: ?[*]c_int = null;
            var n: c_int = 0;
            c.pango_layout_line_get_x_ranges(line, @intCast(from), @intCast(to), &found, &n);
            const ranges = found orelse continue;
            defer c.g_free(@ptrCast(ranges));
            for (0..@as(usize, @intCast(n))) |i| {
                const left = @as(f64, @floatFromInt(ranges[i * 2])) / scale;
                const right = @as(f64, @floatFromInt(ranges[i * 2 + 1])) / scale;
                drawRoundedRect(cr, x + @as(f32, @floatCast(left)), y + @as(f32, @floatFromInt(box.y)) / @as(f32, c.PANGO_SCALE), @floatCast(right - left), @as(f32, @floatFromInt(box.height)) / @as(f32, c.PANGO_SCALE), md.code_radius);
                c.cairo_fill(cr);
            }
        }
    }
}

pub fn renderTextBlock(cr: *c.cairo_t, pango_layout: *c.PangoLayout, content_in: md.Inline, x: f32, y: f32, max_width: f32, color: Color, font_desc_str: [*:0]const u8) f32 {
    return renderFlowed(cr, pango_layout, app.images.flow(content_in), x, y, max_width, color, font_desc_str);
}

pub fn renderFlowed(
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
    setAlign(pango_layout, html.block_align);

    drawCodeBackgrounds(cr, pango_layout, content, x, y);
    drawStyleRects(cr, pango_layout, content, x, y);
    setColor(cr, color);
    c.cairo_move_to(cr, x, y);
    c.pango_cairo_show_layout(cr, pango_layout);

    // Get height
    var pw: c_int = 0;
    var ph: c_int = 0;
    c.pango_layout_get_pixel_size(pango_layout, &pw, &ph);
    html.extent = @max(html.extent, x + @as(f32, @floatFromInt(pw)));

    // Clean up layout state for next use
    c.pango_layout_set_attributes(pango_layout, null);
    setAlign(pango_layout, .left);

    html.noteHit(.{ .content = content, .x = x, .y = y + app.scroll_y, .w = max_width, .h = @floatFromInt(ph), .font = fontOfDesc(font_desc_str), .alignment = html.block_align });
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
    resetBoxes();
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
    return @intCast(unmap(padded(hit.content).code, @intCast(index)));
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

const pad_mark = "\u{200d}";
pub const pad_len = pad_mark.len;

/// A code span is wrapped in two zero-width placeholders whose shape has the CSS padding as its width, so the neighbouring letters do not move.
fn paddedText(a: std.mem.Allocator, content: md.Inline) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pos: usize = 0;
    for (content.code) |span| {
        try out.appendSlice(a, content.text[pos..span[0]]);
        try out.appendSlice(a, pad_mark);
        try out.appendSlice(a, content.text[span[0] .. span[0] + span[1]]);
        try out.appendSlice(a, pad_mark);
        pos = span[0] + span[1];
    }
    try out.appendSlice(a, content.text[pos..]);
    return out.toOwnedSlice(a);
}

fn countBelow(spans: []const md.Span, i: usize, inclusive: bool, at_end: bool) usize {
    var lo: usize = 0;
    var hi: usize = spans.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const v = spans[mid][0] + if (at_end) spans[mid][1] else 0;
        if (v < i or (inclusive and v == i)) lo = mid + 1 else hi = mid;
    }
    return lo;
}

pub fn mapStart(spans: []const md.Span, i: usize) usize {
    return i + pad_len * (countBelow(spans, i, false, false) + countBelow(spans, i, false, true));
}

pub fn mapEnd(spans: []const md.Span, i: usize) usize {
    return i + pad_len * (countBelow(spans, i, true, false) + countBelow(spans, i, true, true));
}

pub fn leftMark(spans: []const md.Span, k: usize) usize {
    return spans[k][0] + 2 * pad_len * k;
}

pub fn rightMark(spans: []const md.Span, k: usize) usize {
    return spans[k][0] + spans[k][1] + pad_len * (2 * k + 1);
}

pub fn unmap(spans: []const md.Span, m: usize) usize {
    var lo: usize = 0;
    var hi: usize = 2 * spans.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const at = if (mid % 2 == 0) leftMark(spans, mid / 2) else rightMark(spans, mid / 2);
        if (at + pad_len <= m) lo = mid + 1 else hi = mid;
    }
    if (lo < 2 * spans.len) {
        const at = if (lo % 2 == 0) leftMark(spans, lo / 2) else rightMark(spans, lo / 2);
        if (at <= m) return at - pad_len * lo;
    }
    return m - pad_len * lo;
}

fn addShape(attr_list: *c.PangoAttrList, at: usize, width: c_int) void {
    const ink: c.PangoRectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const logical: c.PangoRectangle = .{ .x = 0, .y = 0, .width = width, .height = 0 };
    const attr = c.pango_attr_shape_new(&ink, &logical) orelse return;
    attr.*.start_index = @intCast(at);
    attr.*.end_index = @intCast(at + pad_len);
    c.pango_attr_list_insert(attr_list, attr);
}

pub fn insertRange(attr_list: *c.PangoAttrList, attr: ?*c.PangoAttribute, start: usize, end: usize) void {
    const a = attr orelse return;
    a.*.start_index = @intCast(start);
    a.*.end_index = @intCast(end);
    c.pango_attr_list_insert(attr_list, a);
}

fn padUnits(desc: *const c.PangoFontDescription) c_int {
    return @intFromFloat(md.code_pad_em * md.code_scale * @as(f32, @floatFromInt(c.pango_font_description_get_size(desc))) * 96.0 / 72.0);
}

const ImageKind = enum { pending, picture, broken };

/// Width of the broken image glyph with its gap to the alt text that follows, and its height.
const broken_w: f32 = 18;
const broken_h: f32 = 16;

/// One image in a layout, found again by the shape renderer through the attribute's data pointer.
pub const ImageBox = struct { w: f32, h: f32, kind: ImageKind, image: *const md.Image };

pub var boxes: ?std.heap.ArenaAllocator = null;

pub fn resetBoxes() void {
    if (boxes) |*a| _ = a.reset(.free_all);
}

fn setAlt(layout: *c.PangoLayout, alt: []const u8, width: f32) void {
    const desc = c.pango_font_description_from_string("Sans 12") orelse return;
    defer c.pango_font_description_free(desc);
    c.pango_layout_set_font_description(layout, desc);
    c.pango_layout_set_width(layout, @intFromFloat(width * @as(f32, c.PANGO_SCALE)));
    c.pango_layout_set_wrap(layout, c.PANGO_WRAP_WORD_CHAR);
    c.pango_layout_set_text(layout, alt.ptr, @intCast(alt.len));
}

pub fn imageBox(im: *const md.Image, avail: f32) ?*ImageBox {
    if (boxes == null) boxes = .init(app.gpa);
    const box = boxes.?.allocator().create(ImageBox) catch return null;
    box.* = .{ .w = 0, .h = 0, .kind = .pending, .image = im };
    if (im.float != .none and !html.sizing_float) return box;
    switch (app.images.look(im.target, avail)) {
        .pending => {},
        .picture => |s| {
            const size = if (im.width > 0 or im.height > 0) app.images.requested(naturalSize(im.target), im.width, im.height, avail) else s;
            box.w = size.w;
            box.h = size.h;
            box.kind = if (size.w > 0) .picture else .pending;
        },
        .missing => if (im.alt.len > 0) {
            box.w = broken_w;
            box.h = broken_h;
            box.kind = .broken;
        },
    }
    return box;
}

fn addImageShape(attr_list: *c.PangoAttrList, box: *ImageBox, start: usize, end: usize) void {
    const scale: f32 = c.PANGO_SCALE;
    const rect: c.PangoRectangle = .{ .x = 0, .y = -@as(c_int, @intFromFloat(box.h * scale)), .width = @intFromFloat(box.w * scale), .height = @intFromFloat(box.h * scale) };
    const attr = c.pango_attr_shape_new_with_data(&rect, &rect, box, null, null) orelse return;
    attr.*.start_index = @intCast(start);
    attr.*.end_index = @intCast(end);
    c.pango_attr_list_insert(attr_list, attr);
}

fn blit(ctx: *c.cairo_t, handle: *anyopaque, pw: u32, ph: u32, x: f64, y: f64, w: f64, h: f64) void {
    const native: *const Native = @ptrCast(@alignCast(handle));
    const iw: f64 = @floatFromInt(pw);
    const ih: f64 = @floatFromInt(ph);
    c.cairo_save(ctx);
    c.cairo_translate(ctx, x, y);
    c.cairo_scale(ctx, w / iw, h / ih);
    c.cairo_set_source_surface(ctx, native.surface, 0, 0);
    const pattern = c.cairo_get_source(ctx);
    c.cairo_pattern_set_filter(pattern, c.CAIRO_FILTER_BEST);
    c.cairo_pattern_set_extend(pattern, c.CAIRO_EXTEND_PAD);
    c.cairo_rectangle(ctx, 0, 0, iw, ih);
    c.cairo_fill(ctx);
    c.cairo_restore(ctx);
}

pub fn drawShape(cr: ?*c.cairo_t, attr: [*c]c.PangoAttrShape, _: c.gboolean, _: ?*anyopaque) callconv(.c) void {
    const ctx = cr orelse return;
    const box: *const ImageBox = @ptrCast(@alignCast(attr.*.data orelse return));
    var x: f64 = 0;
    var y: f64 = 0;
    c.cairo_get_current_point(ctx, &x, &y);
    const top = y - box.h;
    if (box.w <= 0 or top + box.h < 0 or top > app.window_height) return;
    switch (box.kind) {
        .pending => {},
        .picture => {
            const bm = app.images.bitmap(box.image.target, .{ .w = box.w, .h = box.h }) orelse return;
            blit(ctx, bm.native, bm.w, bm.h, x, top, box.w, box.h);
        },
        .broken => {
            if (app.images.brokenIcon()) |icon| {
                blit(ctx, icon.native, icon.pw, icon.ph, x, top, icon.w, icon.h);
                return;
            }
            setColor(ctx, col_quote);
            c.cairo_new_path(ctx);
            for (alerts.brokenImage()) |op| switch (op) {
                .move => |p| c.cairo_move_to(ctx, x + p[0], top + p[1]),
                .line => |p| c.cairo_line_to(ctx, x + p[0], top + p[1]),
                .cubic => |q| c.cairo_curve_to(ctx, x + q[0], top + q[1], x + q[2], top + q[3], x + q[4], top + q[5]),
                .close => c.cairo_close_path(ctx),
            };
            c.cairo_set_fill_rule(ctx, c.CAIRO_FILL_RULE_WINDING);
            c.cairo_fill(ctx);
        },
    }
}

const Native = struct { surface: *c.cairo_surface_t, data: []u8 };

fn createNative(rgba: []const u8, w: u32, h: u32) ?*anyopaque {
    const data = app.gpa.alloc(u8, rgba.len) catch return null;
    var i: usize = 0;
    while (i + 3 < rgba.len) : (i += 4) {
        const a: u32 = rgba[i + 3];
        data[i] = @intCast((@as(u32, rgba[i + 2]) * a + 127) / 255);
        data[i + 1] = @intCast((@as(u32, rgba[i + 1]) * a + 127) / 255);
        data[i + 2] = @intCast((@as(u32, rgba[i]) * a + 127) / 255);
        data[i + 3] = @intCast(a);
    }
    const surface = c.cairo_image_surface_create_for_data(data.ptr, c.CAIRO_FORMAT_ARGB32, @intCast(w), @intCast(h), @intCast(w * 4)) orelse {
        app.gpa.free(data);
        return null;
    };
    const native = app.gpa.create(Native) catch {
        c.cairo_surface_destroy(surface);
        app.gpa.free(data);
        return null;
    };
    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
        c.cairo_surface_destroy(surface);
        app.gpa.free(data);
        app.gpa.destroy(native);
        return null;
    }
    native.* = .{ .surface = surface, .data = data };
    return native;
}

fn freeNative(handle: ?*anyopaque) void {
    const native: *Native = @ptrCast(@alignCast(handle orelse return));
    c.cairo_surface_destroy(native.surface);
    app.gpa.free(native.data);
    app.gpa.destroy(native);
}

fn drawTooltip(cr: *c.cairo_t, t: app.Tooltip) void {
    const layout = c.pango_cairo_create_layout(cr) orelse return;
    defer c.g_object_unref(layout);
    setAlt(layout, t.text, 360);
    const size = layoutPixelSize(layout);
    const w = size[0] + 16;
    const h = size[1] + 10;
    const x = @min(t.x + 14, app.window_width - w - 4);
    const y = if (t.y + 22 + h > app.window_height) t.y - h - 6 else t.y + 22;
    setColor(cr, col_table_border);
    drawRoundedRect(cr, x - 1, y - 1, w + 2, h + 2, 5);
    c.cairo_fill(cr);
    setColor(cr, col_code_bg);
    drawRoundedRect(cr, x, y, w, h, 4);
    c.cairo_fill(cr);
    setColor(cr, col_text);
    c.cairo_move_to(cr, x + 8, y + 5);
    c.pango_cairo_show_layout(cr, layout);
}

pub fn setInline(pango_layout: *c.PangoLayout, content_in: md.Inline, max_width: ?f32, font_desc_str: [*:0]const u8) void {
    const content = padded(content_in);
    const desc = c.pango_font_description_from_string(font_desc_str) orelse return;
    defer c.pango_font_description_free(desc);

    c.pango_layout_set_font_description(pango_layout, desc);
    c.pango_layout_set_width(pango_layout, if (max_width) |w| @intFromFloat(w * @as(f32, c.PANGO_SCALE)) else -1);
    c.pango_layout_set_wrap(pango_layout, c.PANGO_WRAP_WORD_CHAR);

    var spans: []const md.Span = content.code;
    const owned: ?[]u8 = if (content.code.len == 0) null else paddedText(app.gpa, content) catch null;
    defer if (owned) |t| app.gpa.free(t);
    if (owned == null) spans = &.{};
    const text = owned orelse content.text;
    c.pango_layout_set_text(pango_layout, text.ptr, @intCast(text.len));

    const attr_list = c.pango_attr_list_new() orelse return;
    defer c.pango_attr_list_unref(attr_list);

    for (content.bold) |span| insertRange(attr_list, c.pango_attr_weight_new(c.PANGO_WEIGHT_BOLD), mapStart(spans, span[0]), mapEnd(spans, span[0] + span[1]));
    for (content.italic) |span| insertRange(attr_list, c.pango_attr_style_new(c.PANGO_STYLE_ITALIC), mapStart(spans, span[0]), mapEnd(spans, span[0] + span[1]));
    for (content.strike) |span| insertRange(attr_list, c.pango_attr_strikethrough_new(1), mapStart(spans, span[0]), mapEnd(spans, span[0] + span[1]));
    for (content.emoji) |span| insertRange(attr_list, c.pango_attr_family_new("Noto Color Emoji,Twemoji,Emoji,Sans"), mapStart(spans, span[0]), mapEnd(spans, span[0] + span[1]));

    const pad = padUnits(desc);
    for (content.code, 0..) |span, k| {
        const start = if (spans.len == 0) span[0] else leftMark(spans, k) + pad_len;
        const end = if (spans.len == 0) span[0] + span[1] else rightMark(spans, k);
        const kbd = isKbd(content_in, span);
        insertRange(attr_list, c.pango_attr_family_new("monospace"), start, end);
        insertRange(attr_list, c.pango_attr_scale_new(if (kbd) kbdScale(desc) else md.code_scale), start, end);
        if (!kbd) insertRange(attr_list, c.pango_attr_foreground_new(
            @intFromFloat(col_hl_string.r * 65535.0),
            @intFromFloat(col_hl_string.g * 65535.0),
            @intFromFloat(col_hl_string.b * 65535.0),
        ), start, end);
        if (spans.len > 0) {
            addShape(attr_list, leftMark(spans, k), if (kbd) kbd_pad else pad);
            addShape(attr_list, rightMark(spans, k), if (kbd) kbd_pad else pad);
        }
    }
    applyStyles(attr_list, content, spans, desc);

    for (content.links) |l| {
        const start = mapStart(spans, l.start);
        const end = mapEnd(spans, l.start + l.len);
        insertRange(attr_list, c.pango_attr_foreground_new(
            @intFromFloat(col_link.r * 65535.0),
            @intFromFloat(col_link.g * 65535.0),
            @intFromFloat(col_link.b * 65535.0),
        ), start, end);
        if (app.isHover(content, l)) insertRange(attr_list, c.pango_attr_underline_new(c.PANGO_UNDERLINE_SINGLE), start, end);
    }

    const rise: c_int = @intFromFloat(@as(f64, @floatFromInt(c.pango_font_description_get_size(desc))) * 0.4);
    for (content.sup) |span| {
        const start = mapStart(spans, span[0]);
        const end = mapEnd(spans, span[0] + span[1]);
        insertRange(attr_list, c.pango_attr_scale_new(0.7), start, end);
        insertRange(attr_list, c.pango_attr_rise_new(rise), start, end);
    }

    for (content.images) |*im| {
        const box = imageBox(im, max_width orelse 100000) orelse continue;
        addImageShape(attr_list, box, mapStart(spans, im.start), mapEnd(spans, im.start + im.len));
    }

    c.pango_layout_set_attributes(pango_layout, attr_list);
}

pub const cell_pad_x: f32 = 13;
pub const cell_pad_y: f32 = 6;

pub fn setCell(pango_layout: *c.PangoLayout, t: md.Table, row: usize, col: usize, width: ?f32) void {
    const bold = (row == 0 and t.header_row) or (col == 0 and t.header_col);
    setInline(pango_layout, app.images.flow(t.cell(row, col)), width, if (bold) "Sans Bold 12" else "Sans 12");
    setAlign(pango_layout, t.alignAt(row, col));
}

pub fn layoutPixelSize(pango_layout: *c.PangoLayout) [2]f32 {
    var pw: c_int = 0;
    var ph: c_int = 0;
    c.pango_layout_get_pixel_size(pango_layout, &pw, &ph);
    return .{ @floatFromInt(pw), @floatFromInt(ph) };
}

const FloatSide = @FieldType(md.Image, "float");

fn tableFloat(t: md.Table) FloatSide {
    if (comptime @hasField(md.Table, "float")) return @field(t, "float");
    return .none;
}

fn cellNatural(cr: *c.cairo_t, pango_layout: *c.PangoLayout, t: md.Table, row: usize, col: usize) f32 {
    const blocks = t.cellBlocks(row, col);
    if (blocks.len > 0) return html.measureBlocks(pango_layout, blocks, 100000).w;
    if (t.nestedAt(row, col)) |nt| {
        var nw: f32 = 0;
        _ = renderTable(cr, pango_layout, nt, 0, 0, 100000, false, &nw);
        return nw;
    }
    setCell(pango_layout, t, row, col, null);
    return layoutPixelSize(pango_layout)[0];
}

fn cellContentHeight(cr: *c.cairo_t, pango_layout: *c.PangoLayout, t: md.Table, row: usize, col: usize, width: f32) f32 {
    const blocks = t.cellBlocks(row, col);
    if (blocks.len > 0) return html.measureBlocks(pango_layout, blocks, width).h;
    if (t.nestedAt(row, col)) |nt| return renderTable(cr, pango_layout, nt, 0, 0, width, false, null) + md.nested_table_margin;
    setCell(pango_layout, t, row, col, width);
    return layoutPixelSize(pango_layout)[1];
}

pub fn renderTable(cr: *c.cairo_t, pango_layout: *c.PangoLayout, t: md.Table, x: f32, y: f32, max_width: f32, draw: bool, out_width: ?*f32) f32 {
    if (out_width) |o| o.* = 0;
    const rows = t.rows();
    if (rows == 0) return 0;
    const cols = t.columns;
    const count = rows * cols;
    const buf = app.gpa.alloc(f32, count * 2 + cols + rows) catch return 0;
    defer app.gpa.free(buf);
    @memset(buf, 0);
    const sizes_w = buf[0..count];
    const sizes_h = buf[count .. count * 2];
    const widths = buf[count * 2 ..][0..cols];
    const heights = buf[count * 2 + cols ..][0..rows];

    for (0..rows) |row| {
        for (0..cols) |col| {
            if (tl.covered(t, row, col)) continue;
            sizes_w[row * cols + col] = cellNatural(cr, pango_layout, t, row, col) + cell_pad_x * 2 + 1;
        }
    }
    tl.columnWidths(widths, sizes_w, t, max_width, cell_pad_x * 2 + 24);
    var table_w: f32 = 0;
    for (widths) |w| table_w += w;
    if (out_width) |o| o.* = table_w;

    for (0..rows) |row| {
        for (0..cols) |col| {
            if (tl.covered(t, row, col)) continue;
            const w = tl.cellWidth(t, widths, row, col);
            sizes_h[row * cols + col] = cellContentHeight(cr, pango_layout, t, row, col, w - cell_pad_x * 2) + cell_pad_y * 2;
        }
    }
    tl.solve(heights, sizes_h, t, .row);
    var table_h: f32 = 0;
    for (heights) |h| table_h += h;

    if (draw) {
        var row_y = y;
        for (0..rows) |row| {
            if (md.Table.striped(t, row)) {
                setColor(cr, col_stripe);
                c.cairo_rectangle(cr, x, row_y, table_w, heights[row]);
                c.cairo_fill(cr);
            }
            for (0..cols) |col| {
                if (tl.covered(t, row, col)) continue;
                const cx = x + tl.sum(widths, 0, col);
                const w = tl.cellWidth(t, widths, row, col);
                const h = tl.cellHeight(t, heights, row, col);
                const text_h = cellContentHeight(cr, pango_layout, t, row, col, w - cell_pad_x * 2);
                const ty = row_y + valignOffset(t, row, col, h, text_h);
                const blocks = t.cellBlocks(row, col);
                if (blocks.len > 0) {
                    html.nested += 1;
                    _ = layoutBlocks(cr, pango_layout, blocks, cx + cell_pad_x, w - cell_pad_x * 2, ty);
                    html.nested -= 1;
                } else if (t.nestedAt(row, col)) |nt| {
                    _ = renderTable(cr, pango_layout, nt, cx + cell_pad_x, ty, w - cell_pad_x * 2, true, null);
                } else {
                    const cell = app.images.flow(t.cell(row, col));
                    setCell(pango_layout, t, row, col, w - cell_pad_x * 2);
                    drawCodeBackgrounds(cr, pango_layout, cell, cx + cell_pad_x, ty);
                    drawStyleRects(cr, pango_layout, cell, cx + cell_pad_x, ty);
                    setColor(cr, col_text);
                    c.cairo_move_to(cr, cx + cell_pad_x, ty);
                    c.pango_cairo_show_layout(cr, pango_layout);
                    app.noteHit(.{
                        .content = cell, .x = cx + cell_pad_x, .y = ty + app.scroll_y, .w = w - cell_pad_x * 2,
                        .h = text_h, .header = (row == 0 and t.header_row) or (col == 0 and t.header_col), .alignment = t.alignAt(row, col),
                    });
                }
                setColor(cr, col_table_border);
                c.cairo_rectangle(cr, cx, row_y, w, 1);
                c.cairo_rectangle(cr, cx + w - 1, row_y, 1, h);
                if (col == 0) c.cairo_rectangle(cr, cx, row_y, 1, h);
                if (row + t.spanAt(row, col)[1] >= rows) c.cairo_rectangle(cr, cx, row_y + h, w, 1);
                c.cairo_fill(cr);
            }
            row_y += heights[row];
        }
    }
    c.pango_layout_set_attributes(pango_layout, null);
    setAlign(pango_layout, .left);
    return table_h + 1;
}

/// Spanned HTML cells centre by default as browsers do; plain Markdown cells keep their text at the top.
fn valignOffset(t: md.Table, row: usize, col: usize, cell_h: f32, text_h: f32) f32 {
    const v = t.valignAt(row, col);
    return switch (v) {
        .top => cell_pad_y,
        .bottom => @max(cell_h - text_h - cell_pad_y, cell_pad_y),
        .middle => @max((cell_h - text_h) / 2, cell_pad_y),
        .none => if (t.spans().len == 0) cell_pad_y else @max((cell_h - text_h) / 2, cell_pad_y),
    };
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

fn renderErrorBox(cr: *c.cairo_t, pango_layout: *c.PangoLayout, content_in: md.Inline, x: f32, y: f32, w: f32) f32 {
    const content = app.images.flow(content_in);
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

pub fn drawRoundedRect(cr: *c.cairo_t, x: f32, y: f32, w: f32, h: f32, r: f32) void {
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

pub fn glyphX(layout: *c.PangoLayout, byte: usize) c.PangoRectangle {
    // SAFETY: written by pango_layout_index_to_pos
    var r: c.PangoRectangle = undefined;
    c.pango_layout_index_to_pos(layout, @intCast(byte), &r);
    return r;
}

test "the code span padding keeps the neighbouring letters where they were" {
    app.gpa = std.testing.allocator;
    var doc = try md.parse(std.testing.allocator, "foo`bar`baz");
    defer doc.deinit();
    const content = doc.blocks[0].content;
    try std.testing.expectEqual(@as(usize, 1), content.code.len);

    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1) orelse return error.NoSurface;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return error.NoContext;
    defer c.cairo_destroy(cr);
    const with = c.pango_cairo_create_layout(cr) orelse return error.NoLayout;
    defer c.g_object_unref(with);
    const without = c.pango_cairo_create_layout(cr) orelse return error.NoLayout;
    defer c.g_object_unref(without);

    setInline(with, content, null, "Sans 12");
    var plain = content;
    plain.code = &.{};
    setInline(without, plain, null, "Sans 12");

    const spans = content.code;
    const o_with = glyphX(with, 2);
    const o_without = glyphX(without, 2);
    try std.testing.expectEqual(o_without.x, o_with.x);
    try std.testing.expectEqual(o_without.width, o_with.width);

    const desc = c.pango_font_description_from_string("Sans 12") orelse return error.NoFont;
    defer c.pango_font_description_free(desc);
    const pad = padUnits(desc);
    try std.testing.expect(pad > 0);

    const first_code = glyphX(with, mapEnd(spans, 3));
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(pad)), @as(f64, @floatFromInt(first_code.x - (o_with.x + o_with.width))), 2);

    const b_after = glyphX(with, mapEnd(spans, 6));
    const code_end = glyphX(with, rightMark(spans, 0) - 1);
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(pad)), @as(f64, @floatFromInt(b_after.x - (code_end.x + code_end.width))), 2);
    try std.testing.expectEqual(@as(usize, 6), unmap(spans, mapEnd(spans, 6)));
    try std.testing.expectEqual(@as(usize, 3), unmap(spans, mapEnd(spans, 3)));
}

pub fn imageLayoutSize(content: md.Inline, width: f32) ![2]f32 {
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1) orelse return error.NoSurface;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return error.NoContext;
    defer c.cairo_destroy(cr);
    const layout = c.pango_cairo_create_layout(cr) orelse return error.NoLayout;
    defer c.g_object_unref(layout);
    setInline(layout, content, width, "Sans 12");
    return layoutPixelSize(layout);
}

test "an image scales down to the layout width and is hit like a character" {
    app.gpa = std.testing.allocator;
    app.images.init(std.testing.allocator, std.testing.io);
    app.images.reset("", false);
    defer app.images.clearAll();
    defer resetBoxes();
    try app.images.injectReady("wide.png", 1000, 500);
    var doc = try md.parse(std.testing.allocator, "![w](wide.png) after");
    defer doc.deinit();
    const content = doc.blocks[0].content;

    const wide = try imageLayoutSize(content, 2000);
    try std.testing.expect(wide[0] >= 1000 and wide[1] >= 500);
    const narrow = try imageLayoutSize(content, 400);
    try std.testing.expect(narrow[0] <= 400.5);
    try std.testing.expect(narrow[1] >= 200 and narrow[1] < 260);

    const hit: app.Hit = .{ .content = content, .x = 0, .y = 0, .w = 400, .h = narrow[1] };
    const index = textIndexAt(hit, 100, 100) orelse return error.TestUnexpectedResult;
    try std.testing.expect(content.imageAt(index) != null);
}

test "a missing image lays out a glyph and its alt text in the flow and a reference image resolves" {
    app.gpa = std.testing.allocator;
    app.images.init(std.testing.allocator, std.testing.io);
    app.images.reset("", false);
    defer app.images.clearAll();
    defer resetBoxes();
    var doc = try md.parse(std.testing.allocator, "![a long alt text](gone.png)\n\n![ref image][r]\n\n[r]: gone.png");
    defer doc.deinit();
    try std.testing.expectEqualStrings("gone.png", doc.blocks[1].content.images[0].target);
    const deadline = app.images.now() + 5000;
    while (app.images.now() < deadline) {
        _ = app.images.tick();
        if (app.images.look("gone.png", 400) == .missing) break;
        std.Io.sleep(app.images.io, .fromMilliseconds(5), .awake) catch break;
    }
    try std.testing.expect(app.images.look("gone.png", 400) == .missing);
    const alt = try imageLayoutSize(app.images.flow(doc.blocks[0].content), 400);
    const plain = try imageLayoutSize(.{ .text = "a long alt text" }, 400);
    try std.testing.expectApproxEqAbs(plain[0] + broken_w, alt[0], 2);
    try std.testing.expectApproxEqAbs(plain[1], alt[1], 2);
}

test {
    _ = html;
}

test "the X resource database gives the text scale as Xft.dpi" {
    try std.testing.expectEqual(@as(?f32, 144), xftDpi("*background:\tblack\nXft.dpi:\t144\nXft.hinting: 1\n"));
    try std.testing.expectEqual(@as(?f32, 96), xftDpi("Xft.dpi: 96"));
    try std.testing.expectEqual(@as(?f32, null), xftDpi("Xft.hinting: 1\n"));
    try std.testing.expectEqual(@as(?f32, null), xftDpi("Xft.dpi: wide\n"));
    try std.testing.expectEqual(@as(?f32, null), xftDpi("Xft.dpi: 0\n"));
}

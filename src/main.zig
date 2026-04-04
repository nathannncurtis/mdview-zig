const std = @import("std");
const windows = std.os.windows;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

// ============================================================
// Win32 constants & types
// ============================================================
const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const LPARAM = windows.LPARAM;
const WPARAM = windows.WPARAM;
const LRESULT = windows.LRESULT;
const RECT = windows.RECT;
const POINT = windows.POINT;
const BOOL = windows.BOOL;
const HRESULT = windows.HRESULT;
const GUID = windows.GUID;

const WM_DESTROY: u32 = 0x0002;
const WM_SIZE: u32 = 0x0005;
const WM_PAINT: u32 = 0x000F;
const WM_KEYDOWN: u32 = 0x0100;
const WM_MOUSEWHEEL: u32 = 0x020A;
const WM_NCHITTEST: u32 = 0x0084;
const WM_CREATE: u32 = 0x0001;
const WM_NCCALCSIZE: u32 = 0x0083;
const VK_Q: usize = 0x51;
const VK_MENU: i32 = 0x12;
const VK_CONTROL: i32 = 0x11;
const CS_HREDRAW: u32 = 0x0002;
const CS_VREDRAW: u32 = 0x0001;
const WS_POPUP: u32 = 0x80000000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_THICKFRAME: u32 = 0x00040000;
const WS_SYSMENU: u32 = 0x00080000;
const WS_MINIMIZEBOX: u32 = 0x00020000;
const WS_MAXIMIZEBOX: u32 = 0x00010000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const SW_SHOW: i32 = 5;
const IDC_ARROW: usize = 32512;
const HTCLIENT: u32 = 1;
const HTCAPTION: u32 = 2;
const HTLEFT: u32 = 10;
const HTRIGHT: u32 = 11;
const HTTOP: u32 = 12;
const HTTOPLEFT: u32 = 13;
const HTTOPRIGHT: u32 = 14;
const HTBOTTOM: u32 = 15;
const HTBOTTOMLEFT: u32 = 16;
const HTBOTTOMRIGHT: u32 = 17;

const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: WPARAM, lParam: LPARAM, time: u32, pt: POINT };
const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: *const fn (HWND, u32, WPARAM, LPARAM) callconv(.C) LRESULT,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};
const PAINTSTRUCT = extern struct { hdc: ?*anyopaque, fErase: BOOL, rcPaint: RECT, fRestore: BOOL, fIncUpdate: BOOL, rgbReserved: [32]u8 };

extern "user32" fn CreateWindowExW(dwExStyle: u32, lpClassName: [*:0]const u16, lpWindowName: [*:0]const u16, dwStyle: u32, X: i32, Y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: ?*anyopaque, hInstance: ?HINSTANCE, lpParam: ?*anyopaque) callconv(.C) ?HWND;
extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.C) LRESULT;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.C) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.C) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.C) LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.C) void;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.C) BOOL;
extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.C) BOOL;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.C) BOOL;
extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.C) BOOL;
extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.C) u16;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: usize) callconv(.C) ?*anyopaque;
extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.C) i16;
extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.C) BOOL;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.C) ?*anyopaque;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.C) BOOL;
extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.C) HRESULT;
extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: u32, lpTimerFunc: ?*anyopaque) callconv(.C) usize;
extern "user32" fn DragAcceptFiles(hWnd: HWND, fAccept: BOOL) callconv(.C) void;
extern "shell32" fn DragQueryFileW(hDrop: *anyopaque, iFile: u32, lpszFile: ?[*]u16, cch: u32) callconv(.C) u32;
extern "shell32" fn DragFinish(hDrop: *anyopaque) callconv(.C) void;
extern "advapi32" fn RegCreateKeyExW(hKey: usize, lpSubKey: [*:0]const u16, Reserved: u32, lpClass: ?*anyopaque, dwOptions: u32, samDesired: u32, lpSecurityAttributes: ?*anyopaque, phkResult: *usize, lpdwDisposition: ?*u32) callconv(.C) i32;
extern "advapi32" fn RegSetValueExW(hKey: usize, lpValueName: ?[*:0]const u16, Reserved: u32, dwType: u32, lpData: [*]const u8, cbData: u32) callconv(.C) i32;
extern "advapi32" fn RegCloseKey(hKey: usize) callconv(.C) i32;
extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: u32) callconv(.C) u32;

const WM_TIMER: u32 = 0x0113;
const WM_DROPFILES: u32 = 0x0233;
const WS_EX_ACCEPTFILES: u32 = 0x00000010;
const HKEY_CURRENT_USER: usize = 0x80000001;
const KEY_WRITE: u32 = 0x20006;
const REG_SZ: u32 = 1;
const TIMER_FILE_WATCH: usize = 1;

// ============================================================
// Direct2D / DirectWrite COM interop
// ============================================================
const D2D1_COLOR_F = extern struct { r: f32, g: f32, b: f32, a: f32 };
const D2D1_POINT_2F = extern struct { x: f32, y: f32 };
const D2D1_SIZE_U = extern struct { width: u32, height: u32 };
const D2D1_RECT_F = extern struct { left: f32, top: f32, right: f32, bottom: f32 };
const D2D1_ROUNDED_RECT = extern struct { rect: D2D1_RECT_F, radiusX: f32, radiusY: f32 };
const D2D1_MATRIX_3X2_F = extern struct { m: [6]f32 };

const D2D1_RENDER_TARGET_PROPERTIES = extern struct {
    type: u32 = 0,
    pixel_format: extern struct { format: u32 = 0, alpha_mode: u32 = 0 } = .{},
    dpi_x: f32 = 0,
    dpi_y: f32 = 0,
    usage: u32 = 0,
    min_level: u32 = 0,
};
const D2D1_HWND_RENDER_TARGET_PROPERTIES = extern struct { hwnd: HWND, pixel_size: D2D1_SIZE_U, present_options: u32 = 0 };

extern "d2d1" fn D2D1CreateFactory(factoryType: u32, riid: *const GUID, pFactoryOptions: ?*const anyopaque, ppIFactory: *?*anyopaque) callconv(.C) HRESULT;
extern "dwrite" fn DWriteCreateFactory(factoryType: u32, iid: *const GUID, factory: *?*anyopaque) callconv(.C) HRESULT;

// ID2D1Factory vtable — we only need CreateHwndRenderTarget (index 14)
const ID2D1Factory_VTable = extern struct {
    // IUnknown (0-2)
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.C) u32,
    // ID2D1Factory methods (3-13) — we skip these
    _pad: [11]*const anyopaque,
    // Index 14: CreateHwndRenderTarget
    CreateHwndRenderTarget: *const fn (*anyopaque, *const D2D1_RENDER_TARGET_PROPERTIES, *const D2D1_HWND_RENDER_TARGET_PROPERTIES, *?*anyopaque) callconv(.C) HRESULT,
};

// ID2D1HwndRenderTarget vtable — inherits ID2D1RenderTarget
// We need: BeginDraw(48), EndDraw(49), Clear(47), FillRectangle(16), FillRoundedRectangle(18),
//          DrawTextLayout(27), DrawLine(15), CreateSolidColorBrush(8), Resize(57)
const ID2D1RT_VTable = extern struct {
    // IUnknown (0-2)
    QueryInterface: *const anyopaque, // 0
    AddRef: *const anyopaque, // 1
    Release: *const fn (*anyopaque) callconv(.C) u32, // 2
    // ID2D1Resource (3)
    GetFactory: *const anyopaque, // 3
    // ID2D1RenderTarget (4+)
    _pad4_7: [4]*const anyopaque, // 4-7
    CreateSolidColorBrush: *const fn (*anyopaque, *const D2D1_COLOR_F, ?*const anyopaque, *?*anyopaque) callconv(.C) HRESULT, // 8
    _pad9_14: [6]*const anyopaque, // 9-14
    DrawLine: *const fn (*anyopaque, D2D1_POINT_2F, D2D1_POINT_2F, *anyopaque, f32, ?*anyopaque) callconv(.C) void, // 15
    _pad16: *const anyopaque, // 16 DrawRectangle
    FillRectangle: *const fn (*anyopaque, *const D2D1_RECT_F, *anyopaque) callconv(.C) void, // 17
    _pad18: *const anyopaque, // 18 DrawRoundedRectangle
    FillRoundedRectangle: *const fn (*anyopaque, *const D2D1_ROUNDED_RECT, *anyopaque) callconv(.C) void, // 19
    _pad20_26: [7]*const anyopaque, // 20-26
    _pad27: *const anyopaque, // 27 DrawText
    DrawTextLayout: *const fn (*anyopaque, D2D1_POINT_2F, *anyopaque, *anyopaque, u32) callconv(.C) void, // 28
    _pad29: *const anyopaque, // 29 DrawGlyphRun
    SetTransform: *const fn (*anyopaque, *const D2D1_MATRIX_3X2_F) callconv(.C) void, // 30
    _pad31_46: [16]*const anyopaque, // 31-46
    Clear: *const fn (*anyopaque, *const D2D1_COLOR_F) callconv(.C) void, // 47
    BeginDraw: *const fn (*anyopaque) callconv(.C) void, // 48
    EndDraw: *const fn (*anyopaque, ?*u64, ?*u64) callconv(.C) HRESULT, // 49
    _pad50_56: [7]*const anyopaque, // 50-56
    // ID2D1HwndRenderTarget (57+)
    _pad57: *const anyopaque, // 57 CheckWindowState
    Resize: *const fn (*anyopaque, *const D2D1_SIZE_U) callconv(.C) HRESULT, // 58
};

// IDWriteFactory vtable — we need CreateTextFormat (index 15) and CreateTextLayout (index 18)
const IDWriteFactory_VTable = extern struct {
    // IUnknown (0-2)
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.C) u32,
    // IDWriteFactory methods (3-14) — skip
    _pad3_14: [12]*const anyopaque,
    // Index 15: CreateTextFormat
    CreateTextFormat: *const fn (*anyopaque, [*:0]const u16, ?*anyopaque, u32, u32, u32, f32, [*:0]const u16, *?*anyopaque) callconv(.C) HRESULT,
    _pad16_17: [2]*const anyopaque,
    // Index 18: CreateTextLayout
    CreateTextLayout: *const fn (*anyopaque, [*]const u16, u32, *anyopaque, f32, f32, *?*anyopaque) callconv(.C) HRESULT,
};

// IDWriteTextLayout vtable — inherits IDWriteTextFormat. We need GetMetrics (index 60) and SetFontWeight/Style/Size
const IDWriteTextLayout_VTable = extern struct {
    // IUnknown (0-2)
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.C) u32,
    // IDWriteTextFormat (3-24) — skip most
    _pad3_24: [22]*const anyopaque,
    // IDWriteTextLayout (25+)
    SetMaxWidth: *const fn (*anyopaque, f32) callconv(.C) HRESULT, // 25
    SetMaxHeight: *const fn (*anyopaque, f32) callconv(.C) HRESULT, // 26
    _pad27: *const anyopaque, // 27 SetFontCollection
    _pad28: *const anyopaque, // 28 SetFontFamilyName
    SetFontWeight: *const fn (*anyopaque, u32, DWRITE_TEXT_RANGE) callconv(.C) HRESULT, // 29
    SetFontStyle: *const fn (*anyopaque, u32, DWRITE_TEXT_RANGE) callconv(.C) HRESULT, // 30
    _pad31: *const anyopaque, // 31 SetFontStretch
    SetFontSize: *const fn (*anyopaque, f32, DWRITE_TEXT_RANGE) callconv(.C) HRESULT, // 32
    _pad33_59: [27]*const anyopaque, // 33-59
    GetMetrics: *const fn (*anyopaque, *DWRITE_TEXT_METRICS) callconv(.C) HRESULT, // 60
};

const DWRITE_TEXT_RANGE = extern struct { startPosition: u32, length: u32 };
const DWRITE_TEXT_METRICS = extern struct {
    left: f32,
    top: f32,
    width: f32,
    widthIncludingTrailingWhitespace: f32,
    height: f32,
    layoutWidth: f32,
    layoutHeight: f32,
    maxBidiReorderingDepth: u32,
    lineCount: u32,
};

fn vtable(comptime VT: type, obj: *anyopaque) *const VT {
    const pp: *const *const VT = @ptrCast(@alignCast(obj));
    return pp.*;
}

// GUIDs
const IID_ID2D1Factory = GUID{ .Data1 = 0x06152247, .Data2 = 0x6F50, .Data3 = 0x465A, .Data4 = .{ 0x92, 0x45, 0x11, 0x8B, 0xFD, 0x3B, 0x60, 0x07 } };
const IID_IDWriteFactory = GUID{ .Data1 = 0xb859ee5a, .Data2 = 0xd838, .Data3 = 0x4b5b, .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };

// ============================================================
// Markdown types
// ============================================================
const BlockKind = enum { h1, h2, h3, paragraph, code_block, blockquote, hr, list_item, blank };
const Block = struct { kind: BlockKind, text: []const u8, bold_ranges: [16][2]u32 = undefined, bold_count: u32 = 0, italic_ranges: [16][2]u32 = undefined, italic_count: u32 = 0, code_ranges: [16][2]u32 = undefined, code_count: u32 = 0 };

// ============================================================
// Logging
// ============================================================
var g_log_file: ?std.fs.File = null;

fn initLog() void {
    const appdata = std.process.getEnvVarOwned(std.heap.page_allocator, "LOCALAPPDATA") catch return;
    var buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&buf, "{s}\\mdview", .{appdata}) catch return;
    std.fs.cwd().makePath(dir_path) catch {};
    var buf2: [512]u8 = undefined;
    const log_path = std.fmt.bufPrint(&buf2, "{s}\\mdview\\mdview-zig.log", .{appdata}) catch return;
    g_log_file = std.fs.cwd().createFile(log_path, .{ .truncate = true }) catch null;
}

fn log(msg: []const u8) void {
    if (g_log_file) |f| {
        f.writer().writeAll(msg) catch {};
        f.writer().writeAll("\n") catch {};
    }
}

fn logFmt(comptime fmt: []const u8, args: anytype) void {
    if (g_log_file) |f| {
        f.writer().print(fmt ++ "\n", args) catch {};
    }
}

// ============================================================
// Globals
// ============================================================
var g_scroll_y: f32 = 0;
var g_content_height: f32 = 800;
var g_window_height: f32 = 700;
var g_window_width: f32 = 900;
var g_markdown: []const u8 = "";

var g_d2d_factory: ?*anyopaque = null;
var g_dwrite_factory: ?*anyopaque = null;
var g_render_target: ?*anyopaque = null;
var g_text_format: ?*anyopaque = null;
var g_text_format_h1: ?*anyopaque = null;
var g_text_format_h2: ?*anyopaque = null;
var g_text_format_h3: ?*anyopaque = null;
var g_text_format_code: ?*anyopaque = null;

var g_brush_text: ?*anyopaque = null;
var g_brush_heading: ?*anyopaque = null;
var g_brush_link: ?*anyopaque = null;
var g_brush_code_bg: ?*anyopaque = null;
var g_brush_code_text: ?*anyopaque = null;
var g_brush_quote: ?*anyopaque = null;
var g_brush_hr: ?*anyopaque = null;
var g_brush_close: ?*anyopaque = null;
var g_brush_close_hover: ?*anyopaque = null;

var g_blocks: [1024]Block = undefined;
var g_block_count: usize = 0;
var g_block_text_buf: [256 * 1024]u8 = undefined;
var g_block_text_len: usize = 0;

var g_file_path: []const u8 = "";
var g_file_mtime: i128 = 0;
var g_hwnd: ?HWND = null;
var g_allocator: std.mem.Allocator = undefined;

// ============================================================
// Entry points
// ============================================================
pub export fn wWinMain(hInstance: ?HINSTANCE, _: ?HINSTANCE, _: ?[*:0]const u16, _: i32) callconv(.C) i32 {
    return main_impl(hInstance) catch 1;
}

pub fn main() !void {
    _ = try main_impl(null);
}

fn main_impl(hInstance: ?HINSTANCE) !i32 {
    initLog();
    log("starting mdview-zig");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    g_allocator = allocator;
    const args = try std.process.argsAlloc(allocator);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--register")) {
        registerFileAssociation();
        return 0;
    }

    if (args.len < 2) {
        log("no file argument");
        return 1;
    }
    g_file_path = args[1];
    logFmt("opening: {s}", .{g_file_path});

    loadFile();
    logFmt("read {d} bytes", .{g_markdown.len});

    parseMarkdown();
    logFmt("parsed {d} blocks", .{g_block_count});

    _ = CoInitializeEx(null, 0x2);
    initD2D();
    log("d2d initialized");

    const class_name = L("mdview");
    _ = RegisterClassExW(&.{
        .style = CS_HREDRAW | CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .hInstance = hInstance,
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .lpszClassName = class_name,
    });

    const hwnd = CreateWindowExW(
        WS_EX_ACCEPTFILES, class_name, L("mdview"),
        WS_POPUP | WS_VISIBLE | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 900, 700,
        null, null, hInstance, null,
    ) orelse return 1;
    g_hwnd = hwnd;

    createRenderTarget(hwnd);
    if (g_render_target != null) log("render target created") else log("FAILED to create render target");

    // File watch timer — check every 500ms
    _ = SetTimer(hwnd, TIMER_FILE_WATCH, 500, null);

    _ = ShowWindow(hwnd, SW_SHOW);
    _ = UpdateWindow(hwnd);

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
    return 0;
}

// ============================================================
// D2D / DWrite initialization
// ============================================================
fn initD2D() void {
    _ = D2D1CreateFactory(0, &IID_ID2D1Factory, null, &g_d2d_factory);
    _ = DWriteCreateFactory(0, &IID_IDWriteFactory, &g_dwrite_factory);

    if (g_dwrite_factory) |dwf| {
        const vt = vtable(IDWriteFactory_VTable, dwf);
        const font = L("Segoe UI");
        const locale = L("en-us");
        _ = vt.CreateTextFormat(dwf, font, null, 400, 0, 5, 16.0, locale, &g_text_format);
        _ = vt.CreateTextFormat(dwf, font, null, 700, 0, 5, 32.0, locale, &g_text_format_h1);
        _ = vt.CreateTextFormat(dwf, font, null, 600, 0, 5, 24.0, locale, &g_text_format_h2);
        _ = vt.CreateTextFormat(dwf, font, null, 600, 0, 5, 20.0, locale, &g_text_format_h3);
        const code_font = L("Consolas");
        _ = vt.CreateTextFormat(dwf, code_font, null, 400, 0, 5, 14.0, locale, &g_text_format_code);
    }
}

fn createRenderTarget(hwnd: HWND) void {
    if (g_d2d_factory) |factory| {
        var rc: RECT = undefined;
        _ = GetClientRect(hwnd, &rc);
        const size = D2D1_SIZE_U{
            .width = @intCast(rc.right - rc.left),
            .height = @intCast(rc.bottom - rc.top),
        };
        const rt_props = D2D1_RENDER_TARGET_PROPERTIES{};
        const hwnd_props = D2D1_HWND_RENDER_TARGET_PROPERTIES{ .hwnd = hwnd, .pixel_size = size };
        const vt = vtable(ID2D1Factory_VTable, factory);
        _ = vt.CreateHwndRenderTarget(factory, &rt_props, &hwnd_props, &g_render_target);

        if (g_render_target) |rt| {
            createBrushes(rt);
        }
    }
}

fn createBrushes(rt: *anyopaque) void {
    const vt = vtable(ID2D1RT_VTable, rt);
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.788, .g = 0.820, .b = 0.851, .a = 1 }, null, &g_brush_text); // #c9d1d9
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.788, .g = 0.820, .b = 0.851, .a = 1 }, null, &g_brush_heading); // same
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.345, .g = 0.651, .b = 1.0, .a = 1 }, null, &g_brush_link); // #58a6ff
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.086, .g = 0.106, .b = 0.133, .a = 1 }, null, &g_brush_code_bg); // #161b22
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.788, .g = 0.820, .b = 0.851, .a = 1 }, null, &g_brush_code_text);
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.545, .g = 0.580, .b = 0.620, .a = 1 }, null, &g_brush_quote); // #8b949e
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.129, .g = 0.149, .b = 0.176, .a = 1 }, null, &g_brush_hr); // #21262d
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.545, .g = 0.580, .b = 0.620, .a = 1 }, null, &g_brush_close);
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.855, .g = 0.212, .b = 0.200, .a = 1 }, null, &g_brush_close_hover); // #da3633
}

// ============================================================
// Markdown parser (simple, line-based)
// ============================================================
fn parseMarkdown() void {
    g_block_count = 0;
    g_block_text_len = 0;

    var in_code = false;
    var code_start: usize = 0;
    var lines = std.mem.splitScalar(u8, g_markdown, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");

        if (std.mem.startsWith(u8, line, "```")) {
            if (in_code) {
                // End code block
                const text = g_block_text_buf[code_start..g_block_text_len];
                addBlock(.code_block, text);
                in_code = false;
            } else {
                in_code = true;
                code_start = g_block_text_len;
            }
            continue;
        }

        if (in_code) {
            appendText(line);
            appendText("\n");
            continue;
        }

        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "***") or std.mem.startsWith(u8, line, "___")) {
            addBlock(.hr, "");
            continue;
        }

        if (std.mem.startsWith(u8, line, "### ")) {
            addInlineBlock(.h3, line[4..]);
        } else if (std.mem.startsWith(u8, line, "## ")) {
            addInlineBlock(.h2, line[3..]);
        } else if (std.mem.startsWith(u8, line, "# ")) {
            addInlineBlock(.h1, line[2..]);
        } else if (std.mem.startsWith(u8, line, "> ")) {
            addInlineBlock(.blockquote, line[2..]);
        } else if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
            addInlineBlock(.list_item, line[2..]);
        } else if (line.len > 2 and line[0] >= '0' and line[0] <= '9' and std.mem.indexOf(u8, line, ". ") != null) {
            const dot = std.mem.indexOf(u8, line, ". ").?;
            addInlineBlock(.list_item, line[dot + 2 ..]);
        } else if (std.mem.startsWith(u8, line, "<")) {
            // Skip raw HTML
            continue;
        } else {
            addInlineBlock(.paragraph, line);
        }
    }
}

fn appendText(text: []const u8) void {
    if (g_block_text_len + text.len > g_block_text_buf.len) return;
    @memcpy(g_block_text_buf[g_block_text_len..][0..text.len], text);
    g_block_text_len += text.len;
}

fn addBlock(kind: BlockKind, text: []const u8) void {
    if (g_block_count >= g_blocks.len) return;
    g_blocks[g_block_count] = .{ .kind = kind, .text = text };
    g_block_count += 1;
}

fn addInlineBlock(kind: BlockKind, raw: []const u8) void {
    if (g_block_count >= g_blocks.len) return;
    const start = g_block_text_len;

    // Parse inline formatting (**bold**, *italic*, `code`)
    var block = Block{ .kind = kind, .text = undefined };
    var i: usize = 0;
    while (i < raw.len) {
        if (i + 1 < raw.len and raw[i] == '*' and raw[i + 1] == '*') {
            const end = std.mem.indexOf(u8, raw[i + 2 ..], "**");
            if (end) |e| {
                const pos: u32 = @intCast(g_block_text_len - start);
                appendText(raw[i + 2 ..][0..e]);
                if (block.bold_count < block.bold_ranges.len) {
                    block.bold_ranges[block.bold_count] = .{ pos, @intCast(e) };
                    block.bold_count += 1;
                }
                i += e + 4;
                continue;
            }
        }
        if (raw[i] == '*' and (i + 1 >= raw.len or raw[i + 1] != '*')) {
            const end = std.mem.indexOfScalarPos(u8, raw, i + 1, '*');
            if (end) |e| {
                const pos: u32 = @intCast(g_block_text_len - start);
                appendText(raw[i + 1 .. e]);
                if (block.italic_count < block.italic_ranges.len) {
                    block.italic_ranges[block.italic_count] = .{ pos, @intCast(e - i - 1) };
                    block.italic_count += 1;
                }
                i = e + 1;
                continue;
            }
        }
        if (raw[i] == '`') {
            const end = std.mem.indexOfScalarPos(u8, raw, i + 1, '`');
            if (end) |e| {
                const pos: u32 = @intCast(g_block_text_len - start);
                appendText(raw[i + 1 .. e]);
                if (block.code_count < block.code_ranges.len) {
                    block.code_ranges[block.code_count] = .{ pos, @intCast(e - i - 1) };
                    block.code_count += 1;
                }
                i = e + 1;
                continue;
            }
        }
        if (raw[i] == '[') {
            // [text](url) — just extract text
            const bracket_end = std.mem.indexOfScalarPos(u8, raw, i + 1, ']');
            if (bracket_end) |be| {
                if (be + 1 < raw.len and raw[be + 1] == '(') {
                    const paren_end = std.mem.indexOfScalarPos(u8, raw, be + 2, ')');
                    if (paren_end) |pe| {
                        appendText(raw[i + 1 .. be]);
                        i = pe + 1;
                        continue;
                    }
                }
            }
        }
        // Regular char
        appendByte(raw[i]);
        i += 1;
    }

    block.text = g_block_text_buf[start..g_block_text_len];
    g_blocks[g_block_count] = block;
    g_block_count += 1;
}

fn appendByte(b: u8) void {
    if (g_block_text_len < g_block_text_buf.len) {
        g_block_text_buf[g_block_text_len] = b;
        g_block_text_len += 1;
    }
}

// ============================================================
// Rendering
// ============================================================
fn render(hwnd: HWND) void {
    _ = hwnd;
    const rt = g_render_target orelse return;
    const vt_rt = vtable(ID2D1RT_VTable, rt);
    const dwf = g_dwrite_factory orelse return;
    const vt_dw = vtable(IDWriteFactory_VTable, dwf);

    vt_rt.BeginDraw(rt);

    // Clear background
    vt_rt.Clear(rt, &.{ .r = 0.051, .g = 0.067, .b = 0.090, .a = 1 }); // #0d1117

    // Set scroll transform
    const identity = D2D1_MATRIX_3X2_F{ .m = .{ 1, 0, 0, 1, 0, -g_scroll_y } };
    vt_rt.SetTransform(rt, &identity);

    const padding: f32 = 40;
    const max_width = @max(g_window_width - padding * 2, 100);
    var y: f32 = padding;

    // Draw close button (X) — fixed position, undo scroll
    // We'll draw it after content with identity transform

    // Render blocks
    var i: usize = 0;
    while (i < g_block_count) : (i += 1) {
        const block = &g_blocks[i];
        switch (block.kind) {
            .h1 => {
                y += 24;
                y += renderTextBlock(vt_rt, vt_dw, rt, dwf, block, g_text_format_h1.?, padding, y, max_width, g_brush_heading.?);
                y += 8;
                // Underline
                vt_rt.FillRectangle(rt, &.{ .left = padding, .top = y, .right = padding + max_width, .bottom = y + 1 }, g_brush_hr.?);
                y += 16;
            },
            .h2 => {
                y += 20;
                y += renderTextBlock(vt_rt, vt_dw, rt, dwf, block, g_text_format_h2.?, padding, y, max_width, g_brush_heading.?);
                y += 6;
                vt_rt.FillRectangle(rt, &.{ .left = padding, .top = y, .right = padding + max_width, .bottom = y + 1 }, g_brush_hr.?);
                y += 16;
            },
            .h3 => {
                y += 16;
                y += renderTextBlock(vt_rt, vt_dw, rt, dwf, block, g_text_format_h3.?, padding, y, max_width, g_brush_heading.?);
                y += 12;
            },
            .paragraph => {
                y += renderTextBlock(vt_rt, vt_dw, rt, dwf, block, g_text_format.?, padding, y, max_width, g_brush_text.?);
                y += 16;
            },
            .list_item => {
                // Bullet
                vt_rt.FillRectangle(rt, &.{ .left = padding + 8, .top = y + 7, .right = padding + 12, .bottom = y + 11 }, g_brush_text.?);
                y += renderTextBlock(vt_rt, vt_dw, rt, dwf, block, g_text_format.?, padding + 24, y, max_width - 24, g_brush_text.?);
                y += 8;
            },
            .blockquote => {
                // Left bar
                vt_rt.FillRectangle(rt, &.{ .left = padding, .top = y, .right = padding + 3, .bottom = y + 24 }, g_brush_hr.?);
                y += renderTextBlock(vt_rt, vt_dw, rt, dwf, block, g_text_format.?, padding + 16, y, max_width - 16, g_brush_quote.?);
                y += 16;
            },
            .code_block => {
                const h = renderCodeBlock(vt_rt, vt_dw, rt, dwf, block, padding, y, max_width);
                y += h + 16;
            },
            .hr => {
                y += 12;
                vt_rt.FillRectangle(rt, &.{ .left = padding, .top = y, .right = padding + max_width, .bottom = y + 2 }, g_brush_hr.?);
                y += 14;
            },
            .blank => {},
        }
    }

    g_content_height = y + padding;

    // Reset transform for fixed UI (close button)
    const no_scroll = D2D1_MATRIX_3X2_F{ .m = .{ 1, 0, 0, 1, 0, 0 } };
    vt_rt.SetTransform(rt, &no_scroll);

    // Close button "X"
    if (g_brush_close) |brush| {
        const bx = g_window_width - 36;
        const by: f32 = 8;
        // X lines
        vt_rt.DrawLine(rt, .{ .x = bx + 4, .y = by + 4 }, .{ .x = bx + 20, .y = by + 20 }, brush, 1.5, null);
        vt_rt.DrawLine(rt, .{ .x = bx + 20, .y = by + 4 }, .{ .x = bx + 4, .y = by + 20 }, brush, 1.5, null);
    }

    _ = vt_rt.EndDraw(rt, null, null);
}

fn renderTextBlock(
    vt_rt: *const ID2D1RT_VTable,
    vt_dw: *const IDWriteFactory_VTable,
    rt: *anyopaque,
    dwf: *anyopaque,
    block: *const Block,
    text_format: *anyopaque,
    x: f32,
    y: f32,
    max_width: f32,
    brush: *anyopaque,
) f32 {
    if (block.text.len == 0) return 0;

    // Convert UTF-8 to UTF-16
    var wide_buf: [8192]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, block.text) catch return 0;
    if (wide_len == 0) return 0;

    var layout: ?*anyopaque = null;
    _ = vt_dw.CreateTextLayout(dwf, &wide_buf, @intCast(wide_len), text_format, max_width, 10000, &layout);
    const lay = layout orelse return 0;
    defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);

    // TODO: bold/italic formatting via SetFontWeight/SetFontStyle

    // Get height
    var metrics: DWRITE_TEXT_METRICS = undefined;
    _ = vtable(IDWriteTextLayout_VTable, lay).GetMetrics(lay, &metrics);

    vt_rt.DrawTextLayout(rt, .{ .x = x, .y = y }, lay, brush, 0);

    return metrics.height;
}

fn renderCodeBlock(
    vt_rt: *const ID2D1RT_VTable,
    vt_dw: *const IDWriteFactory_VTable,
    rt: *anyopaque,
    dwf: *anyopaque,
    block: *const Block,
    x: f32,
    y: f32,
    max_width: f32,
) f32 {
    if (block.text.len == 0) return 0;

    var wide_buf: [8192]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, block.text) catch return 0;
    if (wide_len == 0) return 0;

    const fmt = g_text_format_code orelse return 0;
    var layout: ?*anyopaque = null;
    _ = vt_dw.CreateTextLayout(dwf, &wide_buf, @intCast(wide_len), fmt, max_width - 32, 10000, &layout);
    const lay = layout orelse return 0;
    defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);

    var metrics: DWRITE_TEXT_METRICS = undefined;
    _ = vtable(IDWriteTextLayout_VTable, lay).GetMetrics(lay, &metrics);

    const block_height = metrics.height + 24;

    // Background rounded rect
    if (g_brush_code_bg) |bg| {
        vt_rt.FillRoundedRectangle(rt, &.{
            .rect = .{ .left = x, .top = y, .right = x + max_width, .bottom = y + block_height },
            .radiusX = 6,
            .radiusY = 6,
        }, bg);
    }

    // Text
    if (g_brush_code_text) |brush| {
        vt_rt.DrawTextLayout(rt, .{ .x = x + 16, .y = y + 12 }, lay, brush, 0);
    }

    return block_height;
}

// ============================================================
// Window procedure
// ============================================================
fn wndProc(hwnd: HWND, msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.C) LRESULT {
    switch (msg) {
        WM_PAINT => {
            render(hwnd);
            // Validate the window
            var ps: PAINTSTRUCT = undefined;
            _ = BeginPaint(hwnd, &ps);
            _ = EndPaint(hwnd, &ps);
            return 0;
        },
        WM_SIZE => {
            const lp: usize = @bitCast(lParam);
            g_window_width = @floatFromInt(@as(u32, @truncate(lp & 0xFFFF)));
            g_window_height = @floatFromInt(@as(u32, @truncate((lp >> 16) & 0xFFFF)));
            if (g_render_target) |rt| {
                const size = D2D1_SIZE_U{
                    .width = @as(u32, @truncate(lp & 0xFFFF)),
                    .height = @as(u32, @truncate((lp >> 16) & 0xFFFF)),
                };
                _ = vtable(ID2D1RT_VTable, rt).Resize(rt, &size);
            }
            _ = InvalidateRect(hwnd, null, 0);
            return 0;
        },
        WM_MOUSEWHEEL => {
            const wp: usize = @bitCast(wParam);
            const raw: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
            const delta: f32 = @floatFromInt(raw);
            g_scroll_y -= delta / 120.0 * 60.0;
            if (g_scroll_y < 0) g_scroll_y = 0;
            const max_scroll = g_content_height - g_window_height + 40;
            if (max_scroll > 0 and g_scroll_y > max_scroll) g_scroll_y = max_scroll;
            _ = InvalidateRect(hwnd, null, 0);
            return 0;
        },
        WM_KEYDOWN => {
            if (wParam == VK_Q and (@as(u16, @bitCast(GetKeyState(VK_CONTROL))) & 0x8000) != 0) {
                PostQuitMessage(0);
                return 0;
            }
            return 0;
        },
        WM_NCHITTEST => {
            const lp: usize = @bitCast(lParam);
            const raw_x: i16 = @bitCast(@as(u16, @truncate(lp)));
            const raw_y: i16 = @bitCast(@as(u16, @truncate(lp >> 16)));
            var pt = POINT{ .x = raw_x, .y = raw_y };
            _ = ScreenToClient(hwnd, &pt);

            const border: i32 = 6;
            const w: i32 = @intFromFloat(g_window_width);
            const h: i32 = @intFromFloat(g_window_height);

            // Close button top-right
            if (pt.x > w - 40 and pt.y < 36) {
                PostQuitMessage(0);
                return 0;
            }

            if (pt.y < border) {
                if (pt.x < border) return HTTOPLEFT;
                if (pt.x > w - border) return HTTOPRIGHT;
                return HTTOP;
            }
            if (pt.y > h - border) {
                if (pt.x < border) return HTBOTTOMLEFT;
                if (pt.x > w - border) return HTBOTTOMRIGHT;
                return HTBOTTOM;
            }
            if (pt.x < border) return HTLEFT;
            if (pt.x > w - border) return HTRIGHT;
            if ((@as(u16, @bitCast(GetKeyState(VK_MENU))) & 0x8000) != 0) return HTCAPTION;
            return HTCLIENT;
        },
        WM_TIMER => {
            if (@as(usize, @bitCast(wParam)) == TIMER_FILE_WATCH) {
                checkFileChanged();
            }
            return 0;
        },
        WM_DROPFILES => {
            handleDrop(@ptrFromInt(@as(usize, @bitCast(wParam))));
            return 0;
        },
        WM_NCCALCSIZE => {
            if (wParam != 0) return 0;
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

// ============================================================
// File loading & watching
// ============================================================
fn loadFile() void {
    const file = std.fs.cwd().openFile(g_file_path, .{}) catch return;
    defer file.close();
    const stat = file.stat() catch return;
    g_file_mtime = stat.mtime;
    g_markdown = file.readToEndAlloc(g_allocator, 10 * 1024 * 1024) catch return;
    parseMarkdown();
}

fn checkFileChanged() void {
    const file = std.fs.cwd().openFile(g_file_path, .{}) catch return;
    defer file.close();
    const stat = file.stat() catch return;
    if (stat.mtime != g_file_mtime) {
        log("file changed, reloading");
        g_file_mtime = stat.mtime;
        g_markdown = file.readToEndAlloc(g_allocator, 10 * 1024 * 1024) catch return;
        parseMarkdown();
        if (g_hwnd) |h| _ = InvalidateRect(h, null, 0);
    }
}

fn handleDrop(hDrop: *anyopaque) void {
    var path_buf: [512]u16 = undefined;
    const len = DragQueryFileW(hDrop, 0, &path_buf, 512);
    DragFinish(hDrop);
    if (len == 0) return;

    // Convert UTF-16 to UTF-8
    var utf8_buf: [1024]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, path_buf[0..len]) catch return;
    const path = utf8_buf[0..utf8_len];

    // Check .md or .markdown extension
    if (!std.mem.endsWith(u8, path, ".md") and !std.mem.endsWith(u8, path, ".markdown")) return;

    g_file_path = g_allocator.dupe(u8, path) catch return;
    logFmt("dropped: {s}", .{g_file_path});
    loadFile();
    if (g_hwnd) |h| _ = InvalidateRect(h, null, 0);
}

// ============================================================
// --register: file association
// ============================================================
fn registerFileAssociation() void {
    var exe_buf: [512]u16 = undefined;
    const exe_len = GetModuleFileNameW(null, &exe_buf, 512);
    if (exe_len == 0) return;

    // Build command string: "path\to\mdview.exe" "%1"
    var cmd_buf: [600]u16 = undefined;
    var cmd_pos: usize = 0;
    cmd_buf[cmd_pos] = '"';
    cmd_pos += 1;
    @memcpy(cmd_buf[cmd_pos..][0..exe_len], exe_buf[0..exe_len]);
    cmd_pos += exe_len;
    const suffix = L("\" \"%1\"");
    @memcpy(cmd_buf[cmd_pos..][0..suffix.len], suffix);
    cmd_pos += suffix.len;
    cmd_buf[cmd_pos] = 0;

    setRegString(HKEY_CURRENT_USER, L("Software\\Classes\\mdview"), null, L("Markdown File"));
    setRegString(HKEY_CURRENT_USER, L("Software\\Classes\\mdview\\shell\\open\\command"), null, @ptrCast(&cmd_buf));
    setRegString(HKEY_CURRENT_USER, L("Software\\Classes\\.md"), null, L("mdview"));
    setRegString(HKEY_CURRENT_USER, L("Software\\Classes\\.markdown"), null, L("mdview"));

    // Print to stdout if possible
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll("mdview registered as default viewer for .md and .markdown files.\n") catch {};
}

fn setRegString(root: usize, subkey: [*:0]const u16, value_name: ?[*:0]const u16, data: [*:0]const u16) void {
    var hkey: usize = 0;
    if (RegCreateKeyExW(root, subkey, 0, null, 0, KEY_WRITE, null, &hkey, null) != 0) return;
    defer _ = RegCloseKey(hkey);
    // Calculate byte length of the string including null terminator
    var len: u32 = 0;
    while (data[len] != 0) len += 1;
    len += 1; // include null
    _ = RegSetValueExW(hkey, value_name, 0, REG_SZ, @ptrCast(data), len * 2);
}

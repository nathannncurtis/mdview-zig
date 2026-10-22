const std = @import("std");
const app = @import("main.zig");
const md = app.md;
const hl = @import("highlight.zig");
const alerts = @import("alerts.zig");
const windows = std.os.windows;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

// Types
const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const LPARAM = windows.LPARAM;
const WPARAM = usize;
const LRESULT = isize;
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const POINT = extern struct { x: i32, y: i32 };
const BOOL = i32;
const HRESULT = i32;
const GUID = windows.GUID;

// Constants
const WM_DESTROY: u32 = 0x0002;
const WM_SIZE: u32 = 0x0005;
const WM_PAINT: u32 = 0x000F;
const WM_KEYDOWN: u32 = 0x0100;
const WM_MOUSEWHEEL: u32 = 0x020A;
const WM_NCHITTEST: u32 = 0x0084;
const WM_NCCALCSIZE: u32 = 0x0083;
const WM_TIMER: u32 = 0x0113;
const WM_DROPFILES: u32 = 0x0233;
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
const WS_EX_ACCEPTFILES: u32 = 0x00000010;
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
const HKEY_CURRENT_USER: usize = 0x80000001;
const KEY_WRITE: u32 = 0x20006;
const REG_SZ: u32 = 1;
const TIMER_FILE_WATCH: usize = 1;
const TIMER_SCROLL_SAVE: usize = 2;

// Structs
const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: WPARAM, lParam: LPARAM, time: u32, pt: POINT };
const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW), style: u32 = 0,
    lpfnWndProc: *const fn (HWND, u32, WPARAM, LPARAM) callconv(.c) LRESULT,
    cbClsExtra: i32 = 0, cbWndExtra: i32 = 0, hInstance: ?HINSTANCE = null,
    hIcon: ?*anyopaque = null, hCursor: ?*anyopaque = null, hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null, lpszClassName: [*:0]const u16, hIconSm: ?*anyopaque = null,
};
const PAINTSTRUCT = extern struct { hdc: ?*anyopaque, fErase: BOOL, rcPaint: RECT, fRestore: BOOL, fIncUpdate: BOOL, rgbReserved: [32]u8 };

// Win32 externs
extern "user32" fn CreateWindowExW(dwExStyle: u32, lpClassName: [*:0]const u16, lpWindowName: [*:0]const u16, dwStyle: u32, X: i32, Y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: ?*anyopaque, hInstance: ?HINSTANCE, lpParam: ?*anyopaque) callconv(.c) ?HWND;
extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.c) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.c) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.c) LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.c) void;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.c) BOOL;
extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.c) BOOL;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.c) BOOL;
extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.c) u16;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: usize) callconv(.c) ?*anyopaque;
extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.c) i16;
extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.c) BOOL;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.c) ?*anyopaque;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.c) BOOL;
extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: u32, lpTimerFunc: ?*anyopaque) callconv(.c) usize;
extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.c) HRESULT;
extern "shell32" fn DragQueryFileW(hDrop: *anyopaque, iFile: u32, lpszFile: ?[*]u16, cch: u32) callconv(.c) u32;
extern "shell32" fn DragFinish(hDrop: *anyopaque) callconv(.c) void;
extern "advapi32" fn RegCreateKeyExW(hKey: usize, lpSubKey: [*:0]const u16, Reserved: u32, lpClass: ?*anyopaque, dwOptions: u32, samDesired: u32, lpSecurityAttributes: ?*anyopaque, phkResult: *usize, lpdwDisposition: ?*u32) callconv(.c) i32;
extern "advapi32" fn RegSetValueExW(hKey: usize, lpValueName: ?[*:0]const u16, Reserved: u32, dwType: u32, lpData: [*]const u8, cbData: u32) callconv(.c) i32;
extern "advapi32" fn RegCloseKey(hKey: usize) callconv(.c) i32;
extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: u32) callconv(.c) u32;

// D2D/DWrite types
const D2D1_COLOR_F = extern struct { r: f32, g: f32, b: f32, a: f32 };
const D2D1_POINT_2F = extern struct { x: f32, y: f32 };
const D2D1_SIZE_U = extern struct { width: u32, height: u32 };
const D2D1_RECT_F = extern struct { left: f32, top: f32, right: f32, bottom: f32 };
const D2D1_ROUNDED_RECT = extern struct { rect: D2D1_RECT_F, radiusX: f32, radiusY: f32 };
const D2D1_MATRIX_3X2_F = extern struct { m: [6]f32 };
const D2D1_RENDER_TARGET_PROPERTIES = extern struct {
    type: u32 = 0, pixel_format: extern struct { format: u32 = 0, alpha_mode: u32 = 0 } = .{},
    dpi_x: f32 = 0, dpi_y: f32 = 0, usage: u32 = 0, min_level: u32 = 0,
};
const D2D1_HWND_RENDER_TARGET_PROPERTIES = extern struct { hwnd: HWND, pixel_size: D2D1_SIZE_U, present_options: u32 = 0 };
const DWRITE_TEXT_RANGE = extern struct { startPosition: u32, length: u32 };
const DWRITE_HIT_TEST_METRICS = extern struct {
    textPosition: u32, length: u32, left: f32, top: f32, width: f32, height: f32, bidiLevel: u32, isText: BOOL, isTrimmed: BOOL,
};
const DWRITE_TEXT_METRICS = extern struct {
    left: f32, top: f32, width: f32, widthIncludingTrailingWhitespace: f32,
    height: f32, layoutWidth: f32, layoutHeight: f32, maxBidiReorderingDepth: u32, lineCount: u32,
};

extern "d2d1" fn D2D1CreateFactory(factoryType: u32, riid: *const GUID, pFactoryOptions: ?*const anyopaque, ppIFactory: *?*anyopaque) callconv(.c) HRESULT;
extern "dwrite" fn DWriteCreateFactory(factoryType: u32, iid: *const GUID, factory: *?*anyopaque) callconv(.c) HRESULT;

// COM vtables
const ID2D1Factory_VTable = extern struct {
    QueryInterface: *const anyopaque, AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32, _pad3_9: [7]*const anyopaque,
    CreatePathGeometry: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT, // 10
    _pad11_13: [3]*const anyopaque,
    CreateHwndRenderTarget: *const fn (*anyopaque, *const D2D1_RENDER_TARGET_PROPERTIES, *const D2D1_HWND_RENDER_TARGET_PROPERTIES, *?*anyopaque) callconv(.c) HRESULT,
};

const ID2D1RT_VTable = extern struct {
    QueryInterface: *const anyopaque, AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetFactory: *const anyopaque,
    _pad4_7: [4]*const anyopaque,
    CreateSolidColorBrush: *const fn (*anyopaque, *const D2D1_COLOR_F, ?*const anyopaque, *?*anyopaque) callconv(.c) HRESULT, // 8
    _pad9_14: [6]*const anyopaque,
    DrawLine: *const fn (*anyopaque, D2D1_POINT_2F, D2D1_POINT_2F, *anyopaque, f32, ?*anyopaque) callconv(.c) void, // 15
    _pad16: *const anyopaque,
    FillRectangle: *const fn (*anyopaque, *const D2D1_RECT_F, *anyopaque) callconv(.c) void, // 17
    _pad18: *const anyopaque,
    FillRoundedRectangle: *const fn (*anyopaque, *const D2D1_ROUNDED_RECT, *anyopaque) callconv(.c) void, // 19
    _pad20_22: [3]*const anyopaque,
    FillGeometry: *const fn (*anyopaque, *anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void, // 23
    _pad24_27: [4]*const anyopaque,
    DrawTextLayout: *const fn (*anyopaque, D2D1_POINT_2F, *anyopaque, *anyopaque, u32) callconv(.c) void, // 28
    _pad29: *const anyopaque,
    SetTransform: *const fn (*anyopaque, *const D2D1_MATRIX_3X2_F) callconv(.c) void, // 30
    _pad31_46: [16]*const anyopaque,
    Clear: *const fn (*anyopaque, *const D2D1_COLOR_F) callconv(.c) void, // 47
    BeginDraw: *const fn (*anyopaque) callconv(.c) void, // 48
    EndDraw: *const fn (*anyopaque, ?*u64, ?*u64) callconv(.c) HRESULT, // 49
    _pad50_56: [7]*const anyopaque,
    _pad57: *const anyopaque,
    Resize: *const fn (*anyopaque, *const D2D1_SIZE_U) callconv(.c) HRESULT, // 58
};

const IDWriteFactory_VTable = extern struct {
    QueryInterface: *const anyopaque, AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    _pad3_14: [12]*const anyopaque,
    CreateTextFormat: *const fn (*anyopaque, [*:0]const u16, ?*anyopaque, u32, u32, u32, f32, [*:0]const u16, *?*anyopaque) callconv(.c) HRESULT, // 15
    _pad16_17: [2]*const anyopaque,
    CreateTextLayout: *const fn (*anyopaque, [*]const u16, u32, *anyopaque, f32, f32, *?*anyopaque) callconv(.c) HRESULT, // 18
};

const IDWriteTextLayout_VTable = extern struct {
    QueryInterface: *const anyopaque, AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    SetTextAlignment: *const fn (*anyopaque, u32) callconv(.c) HRESULT, // 3
    _pad4_27: [24]*const anyopaque,
    SetMaxWidth: *const fn (*anyopaque, f32) callconv(.c) HRESULT, // 28
    SetMaxHeight: *const fn (*anyopaque, f32) callconv(.c) HRESULT, // 29
    _pad30: *const anyopaque,
    SetFontFamilyName: *const fn (*anyopaque, [*:0]const u16, DWRITE_TEXT_RANGE) callconv(.c) HRESULT, // 31
    SetFontWeight: *const fn (*anyopaque, u32, DWRITE_TEXT_RANGE) callconv(.c) HRESULT, // 32
    SetFontStyle: *const fn (*anyopaque, u32, DWRITE_TEXT_RANGE) callconv(.c) HRESULT, // 33
    _pad34: *const anyopaque,
    SetFontSize: *const fn (*anyopaque, f32, DWRITE_TEXT_RANGE) callconv(.c) HRESULT, // 35
    SetUnderline: *const fn (*anyopaque, BOOL, DWRITE_TEXT_RANGE) callconv(.c) HRESULT, // 36
    SetStrikethrough: *const fn (*anyopaque, BOOL, DWRITE_TEXT_RANGE) callconv(.c) HRESULT, // 37
    SetDrawingEffect: *const fn (*anyopaque, ?*anyopaque, DWRITE_TEXT_RANGE) callconv(.c) HRESULT, // 38
    _pad39_59: [21]*const anyopaque,
    GetMetrics: *const fn (*anyopaque, *DWRITE_TEXT_METRICS) callconv(.c) HRESULT, // 60
    _pad61_65: [5]*const anyopaque,
    HitTestTextRange: *const fn (*anyopaque, u32, u32, f32, f32, [*]DWRITE_HIT_TEST_METRICS, u32, *u32) callconv(.c) HRESULT, // 66
};

fn vtable(comptime VT: type, obj: *anyopaque) *const VT {
    const pp: *const *const VT = @ptrCast(@alignCast(obj));
    return pp.*;
}

const IID_ID2D1Factory = GUID{ .Data1 = 0x06152247, .Data2 = 0x6F50, .Data3 = 0x465A, .Data4 = .{ 0x92, 0x45, 0x11, 0x8B, 0xFD, 0x3B, 0x60, 0x07 } };
const IID_IDWriteFactory = GUID{ .Data1 = 0xb859ee5a, .Data2 = 0xd838, .Data3 = 0x4b5b, .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };

// State
pub var hinstance: ?*anyopaque = null;
var g_hwnd: ?HWND = null;
var g_d2d_factory: ?*anyopaque = null;
var g_dwrite_factory: ?*anyopaque = null;
var g_render_target: ?*anyopaque = null;
var g_text_format: ?*anyopaque = null;
var g_text_format_h1: ?*anyopaque = null;
var g_text_format_h2: ?*anyopaque = null;
var g_text_format_h3: ?*anyopaque = null;
var g_text_format_h4: ?*anyopaque = null;
var g_text_format_h5: ?*anyopaque = null;
var g_text_format_h6: ?*anyopaque = null;
var g_text_format_code: ?*anyopaque = null;
var g_brush_text: ?*anyopaque = null;
var g_brush_heading: ?*anyopaque = null;
var g_brush_code_bg: ?*anyopaque = null;
var g_brush_code_text: ?*anyopaque = null;
var g_brush_quote: ?*anyopaque = null;
var g_brush_hr: ?*anyopaque = null;
var g_brush_table_border: ?*anyopaque = null;
var g_brush_close: ?*anyopaque = null;
var g_brush_hl: [std.enums.values(hl.Kind).len]?*anyopaque = @splat(null);
var g_brush_hl_bg: [std.enums.values(hl.Kind).len]?*anyopaque = @splat(null);
var g_brush_bar: ?*anyopaque = null;
var g_brush_bg: ?*anyopaque = null;
var g_brush_check: ?*anyopaque = null;
var g_brush_white: ?*anyopaque = null;
var g_brush_err_bg: ?*anyopaque = null;
var g_brush_err_border: ?*anyopaque = null;
var g_alert_border: [5]?*anyopaque = @splat(null);
var g_alert_fg: [5]?*anyopaque = @splat(null);

pub fn invalidate() void {
    if (g_hwnd) |h| _ = InvalidateRect(h, null, 0);
}

pub fn run() void {
    _ = CoInitializeEx(null, 0x2);
    initD2D();
    app.log("d2d initialized");

    const hi: ?HINSTANCE = if (hinstance) |h| @ptrCast(h) else null;
    const class_name = L("mdview");
    _ = RegisterClassExW(&.{
        .style = CS_HREDRAW | CS_VREDRAW, .lpfnWndProc = &wndProc,
        .hInstance = hi, .hCursor = LoadCursorW(null, IDC_ARROW), .lpszClassName = class_name,
    });

    const hwnd = CreateWindowExW(
        WS_EX_ACCEPTFILES, class_name, L("mdview"),
        WS_POPUP | WS_VISIBLE | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 900, 700, null, null, hi, null,
    ) orelse return;
    g_hwnd = hwnd;

    createRenderTarget(hwnd);
    if (g_render_target != null) app.log("render target created") else app.log("FAILED to create render target");

    _ = SetTimer(hwnd, TIMER_FILE_WATCH, 500, null);
    _ = SetTimer(hwnd, TIMER_SCROLL_SAVE, 3000, null);
    _ = ShowWindow(hwnd, SW_SHOW);
    _ = UpdateWindow(hwnd);

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

fn initD2D() void {
    _ = D2D1CreateFactory(0, &IID_ID2D1Factory, null, &g_d2d_factory);
    _ = DWriteCreateFactory(0, &IID_IDWriteFactory, &g_dwrite_factory);
    if (g_d2d_factory) |f| createAlertGeometries(f);
    if (g_dwrite_factory) |dwf| {
        const vt = vtable(IDWriteFactory_VTable, dwf);
        const font = L("Segoe UI");
        const locale = L("en-us");
        _ = vt.CreateTextFormat(dwf, font, null, 400, 0, 5, 16.0, locale, &g_text_format);
        _ = vt.CreateTextFormat(dwf, font, null, 700, 0, 5, 32.0, locale, &g_text_format_h1);
        _ = vt.CreateTextFormat(dwf, font, null, 600, 0, 5, 24.0, locale, &g_text_format_h2);
        _ = vt.CreateTextFormat(dwf, font, null, 600, 0, 5, 20.0, locale, &g_text_format_h3);
        _ = vt.CreateTextFormat(dwf, font, null, 600, 0, 5, 16.0, locale, &g_text_format_h4);
        _ = vt.CreateTextFormat(dwf, font, null, 600, 0, 5, 14.0, locale, &g_text_format_h5);
        _ = vt.CreateTextFormat(dwf, font, null, 600, 0, 5, 13.6, locale, &g_text_format_h6);
        _ = vt.CreateTextFormat(dwf, L("Consolas"), null, 400, 0, 5, 14.0, locale, &g_text_format_code);
    }
}

fn createRenderTarget(hwnd: HWND) void {
    if (g_d2d_factory) |factory| {
        var rc: RECT = undefined;
        _ = GetClientRect(hwnd, &rc);
        const size = D2D1_SIZE_U{ .width = @intCast(rc.right - rc.left), .height = @intCast(rc.bottom - rc.top) };
        _ = vtable(ID2D1Factory_VTable, factory).CreateHwndRenderTarget(factory, &.{}, &.{ .hwnd = hwnd, .pixel_size = size }, &g_render_target);
        if (g_render_target) |rt| createBrushes(rt);
    }
}

fn rgbColor(rgb: u24) D2D1_COLOR_F {
    return .{
        .r = @as(f32, @floatFromInt(rgb >> 16 & 0xff)) / 255.0,
        .g = @as(f32, @floatFromInt(rgb >> 8 & 0xff)) / 255.0,
        .b = @as(f32, @floatFromInt(rgb & 0xff)) / 255.0,
        .a = 1,
    };
}

fn createBrushes(rt: *anyopaque) void {
    const vt = vtable(ID2D1RT_VTable, rt);
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.788, .g = 0.820, .b = 0.851, .a = 1 }, null, &g_brush_text);
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.788, .g = 0.820, .b = 0.851, .a = 1 }, null, &g_brush_heading);
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.086, .g = 0.106, .b = 0.133, .a = 1 }, null, &g_brush_code_bg);
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.788, .g = 0.820, .b = 0.851, .a = 1 }, null, &g_brush_code_text);
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.545, .g = 0.580, .b = 0.620, .a = 1 }, null, &g_brush_quote);
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.129, .g = 0.149, .b = 0.176, .a = 1 }, null, &g_brush_hr);
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.188, .g = 0.212, .b = 0.239, .a = 1 }, null, &g_brush_table_border);
    _ = vt.CreateSolidColorBrush(rt, &.{ .r = 0.545, .g = 0.580, .b = 0.620, .a = 1 }, null, &g_brush_close);
    for (0..g_brush_hl.len) |n| {
        const st = hl.style(@enumFromInt(n));
        if (st.fg) |rgb| _ = vt.CreateSolidColorBrush(rt, &rgbColor(rgb), null, &g_brush_hl[n]);
        if (st.bg) |rgb| _ = vt.CreateSolidColorBrush(rt, &rgbColor(rgb), null, &g_brush_hl_bg[n]);
    }
    g_brush_bar = solidBrush(rt, 0x3d444d);
    g_brush_bg = solidBrush(rt, 0x0d1117);
    g_brush_check = solidBrush(rt, 0x1f6feb);
    g_brush_white = solidBrush(rt, 0xffffff);
    g_brush_err_bg = solidBrush(rt, 0x25171c);
    g_brush_err_border = solidBrush(rt, 0x6b2b2b);
    for ([_]md.Alert{ .note, .tip, .important, .warning, .caution }) |a| {
        g_alert_border[@intFromEnum(a) - 1] = solidBrush(rt, alerts.style(a).border);
        g_alert_fg[@intFromEnum(a) - 1] = solidBrush(rt, alerts.style(a).fg);
    }
}

// ============================================================
// Rendering
// ============================================================
fn render() void {
    const rt = g_render_target orelse return;
    const vt_rt = vtable(ID2D1RT_VTable, rt);
    const dwf = g_dwrite_factory orelse return;
    const vt_dw = vtable(IDWriteFactory_VTable, dwf);

    vt_rt.BeginDraw(rt);
    vt_rt.Clear(rt, &.{ .r = 0.051, .g = 0.067, .b = 0.090, .a = 1 });
    vt_rt.SetTransform(rt, &.{ .m = .{ 1, 0, 0, 1, 0, -app.scroll_y } });

    const padding: f32 = 40;
    const max_width = @max(app.window_width - padding * 2, 100);
    var y: f32 = padding;

    for (app.blocks) |*block| {
        const inset = block.inset();
        const x = padding + inset;
        const w = @max(max_width - inset, 60);
        const top = y;
        var gap: f32 = 0;
        const text_brush = if (block.muted()) g_brush_quote.? else g_brush_text.?;
        for (block.marks) |l| drawMarker(vt_rt, vt_dw, rt, dwf, l.mark, padding + l.inset, y);

        switch (block.kind) {
            .h1 => {
                y += 24;
                y += renderTextBlock(vt_rt, vt_dw, rt, dwf, block.content, g_text_format_h1.?, x, y, w, g_brush_heading.?);
                y += 8;
                vt_rt.FillRectangle(rt, &.{ .left = x, .top = y, .right = x + w, .bottom = y + 1 }, g_brush_hr.?);
                y += 1;
                gap = 16;
            },
            .h2 => {
                y += 20;
                y += renderTextBlock(vt_rt, vt_dw, rt, dwf, block.content, g_text_format_h2.?, x, y, w, g_brush_heading.?);
                y += 6;
                vt_rt.FillRectangle(rt, &.{ .left = x, .top = y, .right = x + w, .bottom = y + 1 }, g_brush_hr.?);
                y += 1;
                gap = 16;
            },
            .h3 => {
                y += 16;
                y += renderTextBlock(vt_rt, vt_dw, rt, dwf, block.content, g_text_format_h3.?, x, y, w, g_brush_heading.?);
                gap = 12;
            },
            .h4, .h5, .h6 => {
                y += 24;
                const fmt = switch (block.kind) {
                    .h4 => g_text_format_h4,
                    .h5 => g_text_format_h5,
                    else => g_text_format_h6,
                };
                const brush = if (block.kind == .h6) g_brush_quote.? else g_brush_heading.?;
                y += renderTextBlock(vt_rt, vt_dw, rt, dwf, block.content, fmt.?, x, y, w, brush);
                gap = 16;
            },
            .paragraph => {
                y += renderTextBlock(vt_rt, vt_dw, rt, dwf, block.content, g_text_format.?, x, y, w, text_brush);
                gap = block.paragraphGap();
            },
            .alert_title => {
                const alert = block.frames[block.frames.len - 1].alert;
                y += 8;
                drawAlertIcon(vt_rt, rt, alert, x, y);
                _ = renderTextBlock(vt_rt, vt_dw, rt, dwf, block.content, g_text_format_h4.?, x + 24, y - 2, w - 24, g_alert_fg[@intFromEnum(alert) - 1].?);
                y += 16;
                gap = 16;
            },
            .error_box => {
                y += renderErrorBox(vt_rt, vt_dw, rt, dwf, block.content, x, y, w);
                gap = 16;
            },
            .code_block => {
                y += renderCodeBlock(vt_rt, vt_dw, rt, dwf, block.content.text, block.tokens, x, y, w);
                gap = 16;
            },
            .table => {
                y += renderTable(vt_rt, vt_dw, rt, dwf, block.table, x, y, w, true, null);
                gap = 16;
            },
            .hr => {
                y += 12;
                vt_rt.FillRectangle(rt, &.{ .left = x, .top = y, .right = x + w, .bottom = y + 2 }, g_brush_hr.?);
                y += 2;
                gap = 14;
            },
        }

        for (block.frames, 0..) |f, i| {
            if (f.kind != .quote) continue;
            if (f.alert != .none and !f.open) y += 8;
            const brush = if (f.alert == .none) g_brush_bar.? else g_alert_border[@intFromEnum(f.alert) - 1].?;
            const bar_x = padding + block.insetBefore(i);
            vt_rt.FillRectangle(rt, &.{ .left = bar_x, .top = top, .right = bar_x + md.quote_bar, .bottom = y + if (f.open) gap else 0 }, brush);
        }
        y += gap;
    }

    app.content_height = y + padding;

    // Close button
    vt_rt.SetTransform(rt, &.{ .m = .{ 1, 0, 0, 1, 0, 0 } });
    if (g_brush_close) |brush| {
        const bx = app.window_width - 36;
        vt_rt.DrawLine(rt, .{ .x = bx + 4, .y = 12 }, .{ .x = bx + 20, .y = 28 }, brush, 1.5, null);
        vt_rt.DrawLine(rt, .{ .x = bx + 20, .y = 12 }, .{ .x = bx + 4, .y = 28 }, brush, 1.5, null);
    }

    _ = vt_rt.EndDraw(rt, null, null);
}

fn solidBrush(rt: *anyopaque, hex: u24) ?*anyopaque {
    var brush: ?*anyopaque = null;
    const c: D2D1_COLOR_F = .{
        .r = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
        .g = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
        .b = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
        .a = 1,
    };
    _ = vtable(ID2D1RT_VTable, rt).CreateSolidColorBrush(rt, &c, null, &brush);
    return brush;
}

const D2D1_BEZIER_SEGMENT = extern struct { p1: D2D1_POINT_2F, p2: D2D1_POINT_2F, p3: D2D1_POINT_2F };

const ID2D1PathGeometry_VTable = extern struct {
    QueryInterface: *const anyopaque, AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    _pad3_16: [14]*const anyopaque,
    Open: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT, // 17
};

const ID2D1GeometrySink_VTable = extern struct {
    QueryInterface: *const anyopaque, AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    SetFillMode: *const fn (*anyopaque, u32) callconv(.c) void, // 3
    _pad4: *const anyopaque,
    BeginFigure: *const fn (*anyopaque, D2D1_POINT_2F, u32) callconv(.c) void, // 5
    _pad6_7: [2]*const anyopaque,
    EndFigure: *const fn (*anyopaque, u32) callconv(.c) void, // 8
    Close: *const fn (*anyopaque) callconv(.c) HRESULT, // 9
    AddLine: *const fn (*anyopaque, D2D1_POINT_2F) callconv(.c) void, // 10
    AddBezier: *const fn (*anyopaque, *const D2D1_BEZIER_SEGMENT) callconv(.c) void, // 11
};

var g_alert_geom: [5]?*anyopaque = @splat(null);

fn point(p: [2]f32) D2D1_POINT_2F {
    return .{ .x = p[0], .y = p[1] };
}

fn createAlertGeometries(factory: *anyopaque) void {
    const fvt = vtable(ID2D1Factory_VTable, factory);
    for ([_]md.Alert{ .note, .tip, .important, .warning, .caution }) |a| {
        var geom: ?*anyopaque = null;
        if (fvt.CreatePathGeometry(factory, &geom) < 0) continue;
        const g = geom orelse continue;
        var sink_ptr: ?*anyopaque = null;
        if (vtable(ID2D1PathGeometry_VTable, g).Open(g, &sink_ptr) < 0) continue;
        const sink = sink_ptr orelse continue;
        const sv = vtable(ID2D1GeometrySink_VTable, sink);
        sv.SetFillMode(sink, 1);
        var open = false;
        for (alerts.icon(a)) |op| switch (op) {
            .move => |p| {
                if (open) sv.EndFigure(sink, 0);
                sv.BeginFigure(sink, point(p), 0);
                open = true;
            },
            .line => |p| sv.AddLine(sink, point(p)),
            .cubic => |q| sv.AddBezier(sink, &.{ .p1 = point(.{ q[0], q[1] }), .p2 = point(.{ q[2], q[3] }), .p3 = point(.{ q[4], q[5] }) }),
            .close => {
                sv.EndFigure(sink, 1);
                open = false;
            },
        };
        if (open) sv.EndFigure(sink, 0);
        _ = sv.Close(sink);
        _ = sv.Release(sink);
        g_alert_geom[@intFromEnum(a) - 1] = g;
    }
}

fn drawAlertIcon(vt_rt: *const ID2D1RT_VTable, rt: *anyopaque, alert: md.Alert, x: f32, y: f32) void {
    const idx = @intFromEnum(alert) - 1;
    const geom = g_alert_geom[idx] orelse return;
    const brush = g_alert_fg[idx] orelse return;
    vt_rt.SetTransform(rt, &.{ .m = .{ 1, 0, 0, 1, x, y - app.scroll_y } });
    vt_rt.FillGeometry(rt, geom, brush, null);
    vt_rt.SetTransform(rt, &.{ .m = .{ 1, 0, 0, 1, 0, -app.scroll_y } });
}

fn renderErrorBox(vt_rt: *const ID2D1RT_VTable, vt_dw: *const IDWriteFactory_VTable, rt: *anyopaque, dwf: *anyopaque, content: md.Inline, x: f32, y: f32, w: f32) f32 {
    const lay = createLayout(vt_dw, dwf, content, g_text_format.?, @max(w - 34, 20)) orelse return 0;
    defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);
    var m: DWRITE_TEXT_METRICS = undefined;
    _ = vtable(IDWriteTextLayout_VTable, lay).GetMetrics(lay, &m);
    const h = m.height + 32;
    vt_rt.FillRoundedRectangle(rt, &.{ .rect = .{ .left = x, .top = y, .right = x + w, .bottom = y + h }, .radiusX = 6, .radiusY = 6 }, g_brush_err_border.?);
    vt_rt.FillRoundedRectangle(rt, &.{ .rect = .{ .left = x + 1, .top = y + 1, .right = x + w - 1, .bottom = y + h - 1 }, .radiusX = 5, .radiusY = 5 }, g_brush_err_bg.?);
    vt_rt.DrawTextLayout(rt, .{ .x = x + 17, .y = y + 16 }, lay, g_brush_text.?, 0);
    return h;
}

fn fillDisc(vt_rt: *const ID2D1RT_VTable, rt: *anyopaque, cx: f32, cy: f32, r: f32, brush: *anyopaque) void {
    vt_rt.FillRoundedRectangle(rt, &.{
        .rect = .{ .left = cx - r, .top = cy - r, .right = cx + r, .bottom = cy + r },
        .radiusX = r,
        .radiusY = r,
    }, brush);
}

fn fillBox(vt_rt: *const ID2D1RT_VTable, rt: *anyopaque, x: f32, y: f32, size: f32, radius: f32, brush: *anyopaque) void {
    vt_rt.FillRoundedRectangle(rt, &.{
        .rect = .{ .left = x, .top = y, .right = x + size, .bottom = y + size },
        .radiusX = radius,
        .radiusY = radius,
    }, brush);
}

fn drawMarker(vt_rt: *const ID2D1RT_VTable, vt_dw: *const IDWriteFactory_VTable, rt: *anyopaque, dwf: *anyopaque, m: md.Mark, x: f32, y: f32) void {
    const text = g_brush_text.?;
    switch (m.kind) {
        .none => {},
        .bullet => {
            const cx = x - 13;
            const cy = y + 12;
            switch (m.depth % 3) {
                0 => fillDisc(vt_rt, rt, cx, cy, 2.8, text),
                1 => {
                    fillDisc(vt_rt, rt, cx, cy, 2.8, text);
                    fillDisc(vt_rt, rt, cx, cy, 1.8, g_brush_bg.?);
                },
                else => vt_rt.FillRectangle(rt, &.{ .left = cx - 2.5, .top = cy - 2.5, .right = cx + 2.5, .bottom = cy + 2.5 }, text),
            }
        },
        .number => {
            var buf: [16]u8 = undefined;
            const lay = createLayout(vt_dw, dwf, .{ .text = md.markerLabel(&buf, m) }, g_text_format.?, 100) orelse return;
            defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);
            var met: DWRITE_TEXT_METRICS = undefined;
            _ = vtable(IDWriteTextLayout_VTable, lay).GetMetrics(lay, &met);
            vt_rt.DrawTextLayout(rt, .{ .x = x - 6 - met.width, .y = y }, lay, text, 0);
        },
        .task_open, .task_done => {
            const bx = x - 23;
            const by = y + 5;
            if (m.kind == .task_done) {
                fillBox(vt_rt, rt, bx, by, 14, 3, g_brush_check.?);
                const white = g_brush_white.?;
                vt_rt.DrawLine(rt, .{ .x = bx + 3.5, .y = by + 7.5 }, .{ .x = bx + 6, .y = by + 10 }, white, 1.8, null);
                vt_rt.DrawLine(rt, .{ .x = bx + 6, .y = by + 10 }, .{ .x = bx + 10.5, .y = by + 4.5 }, white, 1.8, null);
            } else {
                fillBox(vt_rt, rt, bx, by, 14, 3, g_brush_quote.?);
                fillBox(vt_rt, rt, bx + 1, by + 1, 12, 2, g_brush_bg.?);
            }
        },
    }
}

fn renderTextBlock(vt_rt: *const ID2D1RT_VTable, vt_dw: *const IDWriteFactory_VTable, rt: *anyopaque, dwf: *anyopaque, content: md.Inline, text_format: *anyopaque, x: f32, y: f32, max_width: f32, brush: *anyopaque) f32 {
    const lay = createLayout(vt_dw, dwf, content, text_format, max_width) orelse return 0;
    defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);
    var metrics: DWRITE_TEXT_METRICS = undefined;
    _ = vtable(IDWriteTextLayout_VTable, lay).GetMetrics(lay, &metrics);
    vt_rt.DrawTextLayout(rt, .{ .x = x, .y = y }, lay, brush, draw_color_font);
    return metrics.height;
}

const draw_color_font: u32 = 4; // D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT

fn createLayout(vt_dw: *const IDWriteFactory_VTable, dwf: *anyopaque, content: md.Inline, text_format: *anyopaque, max_width: f32) ?*anyopaque {
    if (content.text.len == 0) return null;
    const wide = std.unicode.utf8ToUtf16LeAlloc(app.gpa, content.text) catch return null;
    defer app.gpa.free(wide);

    var layout: ?*anyopaque = null;
    _ = vt_dw.CreateTextLayout(dwf, wide.ptr, @intCast(wide.len), text_format, max_width, 100000, &layout);
    const lay = layout orelse return null;

    const vt_layout = vtable(IDWriteTextLayout_VTable, lay);
    for (content.bold) |span| {
        _ = vt_layout.SetFontWeight(lay, 700, wideRange(content.text, span));
    }
    for (content.italic) |span| {
        _ = vt_layout.SetFontStyle(lay, 2, wideRange(content.text, span));
    }
    for (content.strike) |span| {
        _ = vt_layout.SetStrikethrough(lay, 1, wideRange(content.text, span));
    }
    for (content.code) |span| {
        _ = vt_layout.SetFontFamilyName(lay, std.unicode.utf8ToUtf16LeStringLiteral("Consolas"), wideRange(content.text, span));
    }
    for (content.emoji) |span| {
        _ = vt_layout.SetFontFamilyName(lay, std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Emoji"), wideRange(content.text, span));
    }
    return lay;
}

const cell_pad_x: f32 = 13;
const cell_pad_y: f32 = 6;

fn cellLayout(vt_dw: *const IDWriteFactory_VTable, dwf: *anyopaque, t: md.Table, row: usize, col: usize, width: f32) ?*anyopaque {
    const content = t.cell(row, col);
    const lay = createLayout(vt_dw, dwf, content, g_text_format orelse return null, width) orelse return null;
    const vt = vtable(IDWriteTextLayout_VTable, lay);
    if ((row == 0 and t.header_row) or (col == 0 and t.header_col)) _ = vt.SetFontWeight(lay, 700, wideRange(content.text, .{ 0, @intCast(content.text.len) }));
    _ = vt.SetTextAlignment(lay, switch (t.aligns[col]) {
        .none, .left => 0,
        .right => 1,
        .center => 2,
    });
    return lay;
}

fn renderTable(vt_rt: *const ID2D1RT_VTable, vt_dw: *const IDWriteFactory_VTable, rt: *anyopaque, dwf: *anyopaque, t: md.Table, x: f32, y: f32, max_width: f32, draw: bool, out_width: ?*f32) f32 {
    const border = g_brush_table_border orelse return 0;
    const widths = app.gpa.alloc(f32, t.columns) catch return 0;
    defer app.gpa.free(widths);
    const layouts = app.gpa.alloc(?*anyopaque, t.columns) catch return 0;
    defer app.gpa.free(layouts);

    @memset(widths, 0);
    for (0..t.rows()) |row| {
        for (widths, 0..) |*w, col| {
            if (t.nestedAt(row, col)) |nt| {
                var nw: f32 = 0;
                _ = renderTable(vt_rt, vt_dw, rt, dwf, nt, 0, 0, 100000, false, &nw);
                w.* = @max(w.*, nw);
                continue;
            }
            const lay = cellLayout(vt_dw, dwf, t, row, col, 100000) orelse continue;
            defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);
            var m: DWRITE_TEXT_METRICS = undefined;
            _ = vtable(IDWriteTextLayout_VTable, lay).GetMetrics(lay, &m);
            w.* = @max(w.*, m.widthIncludingTrailingWhitespace);
        }
    }
    var table_w: f32 = 0;
    for (widths) |*w| w.* += cell_pad_x * 2 + 1;
    md.fitColumns(widths, max_width, cell_pad_x * 2 + 24);
    for (widths) |w| table_w += w;
    if (out_width) |o| o.* = table_w;

    var row_y = y;
    for (0..t.rows()) |row| {
        var text_h: f32 = 21;
        for (layouts, 0..) |*lay, col| {
            lay.* = null;
            if (t.nestedAt(row, col)) |nt| {
                text_h = @max(text_h, renderTable(vt_rt, vt_dw, rt, dwf, nt, 0, 0, widths[col] - cell_pad_x * 2, false, null));
                continue;
            }
            lay.* = cellLayout(vt_dw, dwf, t, row, col, widths[col] - cell_pad_x * 2);
            if (lay.*) |l| {
                var m: DWRITE_TEXT_METRICS = undefined;
                _ = vtable(IDWriteTextLayout_VTable, l).GetMetrics(l, &m);
                text_h = @max(text_h, m.height);
            }
        }
        const row_h = text_h + cell_pad_y * 2;
        if (draw) {
            if (g_brush_code_bg) |bg| {
                if (row == 0 and t.header_row) {
                    vt_rt.FillRectangle(rt, &.{ .left = x, .top = row_y, .right = x + table_w, .bottom = row_y + row_h }, bg);
                } else if (t.header_col) {
                    vt_rt.FillRectangle(rt, &.{ .left = x, .top = row_y, .right = x + widths[0], .bottom = row_y + row_h }, bg);
                }
            }
        }
        var cx = x;
        for (layouts, widths, 0..) |lay, w, col| {
            if (draw) {
                if (t.nestedAt(row, col)) |nt| {
                    _ = renderTable(vt_rt, vt_dw, rt, dwf, nt, cx + cell_pad_x, row_y + cell_pad_y, w - cell_pad_x * 2, true, null);
                } else if (lay) |l| {
                    vt_rt.DrawTextLayout(rt, .{ .x = cx + cell_pad_x, .y = row_y + cell_pad_y }, l, g_brush_text.?, draw_color_font);
                }
            }
            if (lay) |l| _ = vtable(IDWriteTextLayout_VTable, l).Release(l);
            cx += w;
        }
        if (draw) vt_rt.FillRectangle(rt, &.{ .left = x, .top = row_y, .right = x + table_w, .bottom = row_y + 1 }, border);
        row_y += row_h;
    }
    if (draw) {
        vt_rt.FillRectangle(rt, &.{ .left = x, .top = row_y, .right = x + table_w, .bottom = row_y + 1 }, border);
        var cx = x;
        vt_rt.FillRectangle(rt, &.{ .left = cx, .top = y, .right = cx + 1, .bottom = row_y + 1 }, border);
        for (widths) |w| {
            cx += w;
            vt_rt.FillRectangle(rt, &.{ .left = cx - 1, .top = y, .right = cx, .bottom = row_y + 1 }, border);
        }
    }
    return row_y + 1 - y;
}

fn wideRange(text: []const u8, span: md.Span) DWRITE_TEXT_RANGE {
    const start = md.utf16Offset(text, span[0]);
    return .{ .startPosition = start, .length = md.utf16Offset(text, span[0] + span[1]) - start };
}

fn renderCodeBlock(vt_rt: *const ID2D1RT_VTable, vt_dw: *const IDWriteFactory_VTable, rt: *anyopaque, dwf: *anyopaque, text: []const u8, toks: []const hl.Token, x: f32, y: f32, max_width: f32) f32 {
    if (text.len == 0) return 0;
    const wide = std.unicode.utf8ToUtf16LeAlloc(app.gpa, text) catch return 0;
    defer app.gpa.free(wide);

    const fmt = g_text_format_code orelse return 0;
    var layout: ?*anyopaque = null;
    _ = vt_dw.CreateTextLayout(dwf, wide.ptr, @intCast(wide.len), fmt, max_width - 32, 100000, &layout);
    const lay = layout orelse return 0;
    defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);

    applySyntaxHighlighting(lay, text, toks);

    var metrics: DWRITE_TEXT_METRICS = undefined;
    _ = vtable(IDWriteTextLayout_VTable, lay).GetMetrics(lay, &metrics);
    const block_height = metrics.height + 24;

    if (g_brush_code_bg) |bg| {
        vt_rt.FillRoundedRectangle(rt, &.{
            .rect = .{ .left = x, .top = y, .right = x + max_width, .bottom = y + block_height },
            .radiusX = 6, .radiusY = 6,
        }, bg);
    }
    drawLineBackgrounds(vt_rt, rt, lay, text, toks, x, y + 12, max_width);
    if (g_brush_code_text) |brush| {
        vt_rt.DrawTextLayout(rt, .{ .x = x + 16, .y = y + 12 }, lay, brush, 0);
    }
    return block_height;
}

fn synRange(cursor: *md.Utf16Cursor, start: u32, end: u32) DWRITE_TEXT_RANGE {
    const lo = cursor.at(start);
    return .{ .startPosition = lo, .length = cursor.at(end) - lo };
}

fn applySyntaxHighlighting(lay: *anyopaque, text: []const u8, toks: []const hl.Token) void {
    const vt = vtable(IDWriteTextLayout_VTable, lay);
    var cursor: md.Utf16Cursor = .{ .text = text };
    for (toks) |tok| {
        const st = hl.style(tok.kind);
        const range = synRange(&cursor, tok.start, tok.end);
        if (g_brush_hl[@intFromEnum(tok.kind)]) |brush| _ = vt.SetDrawingEffect(lay, brush, range);
        if (st.bold) _ = vt.SetFontWeight(lay, 700, range);
        if (st.underline) _ = vt.SetUnderline(lay, 1, range);
    }
}

const E_NOT_SUFFICIENT_BUFFER: HRESULT = @bitCast(@as(u32, 0x8007007A));

fn drawLineBackgrounds(vt_rt: *const ID2D1RT_VTable, rt: *anyopaque, lay: *anyopaque, text: []const u8, toks: []const hl.Token, x: f32, top: f32, width: f32) void {
    const vt = vtable(IDWriteTextLayout_VTable, lay);
    var cursor: md.Utf16Cursor = .{ .text = text };
    for (toks) |tok| {
        const brush = g_brush_hl_bg[@intFromEnum(tok.kind)] orelse continue;
        const range = synRange(&cursor, tok.start, tok.end);
        var stack: [16]DWRITE_HIT_TEST_METRICS = undefined;
        var rects: []DWRITE_HIT_TEST_METRICS = &stack;
        var heap: ?[]DWRITE_HIT_TEST_METRICS = null;
        defer if (heap) |h| app.gpa.free(h);
        var count: u32 = 0;
        var hr = vt.HitTestTextRange(lay, range.startPosition, range.length, 0, 0, rects.ptr, @intCast(rects.len), &count);
        if (hr == E_NOT_SUFFICIENT_BUFFER) {
            heap = app.gpa.alloc(DWRITE_HIT_TEST_METRICS, count) catch continue;
            rects = heap.?;
            hr = vt.HitTestTextRange(lay, range.startPosition, range.length, 0, 0, rects.ptr, @intCast(rects.len), &count);
        }
        if (hr < 0) continue;
        for (rects[0..@min(count, rects.len)]) |r| {
            vt_rt.FillRectangle(rt, &.{ .left = x, .top = top + r.top, .right = x + width, .bottom = top + r.top + r.height }, brush);
        }
    }
}

// ============================================================
// Window procedure
// ============================================================
fn wndProc(hwnd: HWND, msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT {
    switch (msg) {
        WM_PAINT => {
            render();
            var ps: PAINTSTRUCT = undefined;
            _ = BeginPaint(hwnd, &ps);
            _ = EndPaint(hwnd, &ps);
            return 0;
        },
        WM_SIZE => {
            const lp: usize = @bitCast(lParam);
            app.window_width = @floatFromInt(@as(u32, @truncate(lp & 0xFFFF)));
            app.window_height = @floatFromInt(@as(u32, @truncate((lp >> 16) & 0xFFFF)));
            if (g_render_target) |rt| {
                _ = vtable(ID2D1RT_VTable, rt).Resize(rt, &.{
                    .width = @as(u32, @truncate(lp & 0xFFFF)),
                    .height = @as(u32, @truncate((lp >> 16) & 0xFFFF)),
                });
            }
            _ = InvalidateRect(hwnd, null, 0);
            return 0;
        },
        WM_MOUSEWHEEL => {
            const wp: usize = @bitCast(wParam);
            const raw: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
            const delta: f32 = @floatFromInt(raw);
            app.scroll_y -= delta / 120.0 * 60.0;
            if (app.scroll_y < 0) app.scroll_y = 0;
            const max_scroll = app.content_height - app.window_height + 40;
            if (max_scroll > 0 and app.scroll_y > max_scroll) app.scroll_y = max_scroll;
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
            const w: i32 = @intFromFloat(app.window_width);
            const h: i32 = @intFromFloat(app.window_height);
            if (pt.x > w - 40 and pt.y < 36) { PostQuitMessage(0); return 0; }
            if (pt.y < border) { if (pt.x < border) return HTTOPLEFT; if (pt.x > w - border) return HTTOPRIGHT; return HTTOP; }
            if (pt.y > h - border) { if (pt.x < border) return HTBOTTOMLEFT; if (pt.x > w - border) return HTBOTTOMRIGHT; return HTBOTTOM; }
            if (pt.x < border) return HTLEFT;
            if (pt.x > w - border) return HTRIGHT;
            if ((@as(u16, @bitCast(GetKeyState(VK_MENU))) & 0x8000) != 0) return HTCAPTION;
            return HTCLIENT;
        },
        WM_TIMER => {
            const timer_id = @as(usize, @bitCast(wParam));
            if (timer_id == TIMER_FILE_WATCH) app.checkFileChanged();
            if (timer_id == TIMER_SCROLL_SAVE) app.saveScrollPosition();
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
            app.saveScrollPosition();
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

fn handleDrop(hDrop: *anyopaque) void {
    var path_buf: [512]u16 = undefined;
    const len = DragQueryFileW(hDrop, 0, &path_buf, 512);
    DragFinish(hDrop);
    if (len == 0) return;
    var utf8_buf: [1024]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, path_buf[0..len]) catch return;
    const path = utf8_buf[0..utf8_len];
    if (!std.mem.endsWith(u8, path, ".md") and !std.mem.endsWith(u8, path, ".markdown")) return;
    app.file_path = app.allocator.dupe(u8, path) catch return;
    app.logFmt("dropped: {s}", .{app.file_path});
    app.loadFile();
    invalidate();
}

extern "kernel32" fn GetCurrentPackageFullName(length: *u32, name: ?[*]u16) callconv(.c) i32;

pub fn registerFileAssociation() void {
    var pkg_len: u32 = 0;
    if (GetCurrentPackageFullName(&pkg_len, null) != 15700) {
        std.Io.File.stdout().writeStreamingAll(app.io, "mdview is installed as a package, which already registers .md and .markdown. Choose mdview under Settings > Default apps.\n") catch {};
        return;
    }
    var exe_buf: [512]u16 = undefined;
    const exe_len = GetModuleFileNameW(null, &exe_buf, 512);
    if (exe_len == 0) return;
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
    std.Io.File.stdout().writeStreamingAll(app.io, "mdview registered as default viewer for .md and .markdown files.\n") catch {};
}

fn setRegString(root: usize, subkey: [*:0]const u16, value_name: ?[*:0]const u16, data: [*:0]const u16) void {
    var hkey: usize = 0;
    if (RegCreateKeyExW(root, subkey, 0, null, 0, KEY_WRITE, null, &hkey, null) != 0) return;
    defer _ = RegCloseKey(hkey);
    var len: u32 = 0;
    while (data[len] != 0) len += 1;
    len += 1;
    _ = RegSetValueExW(hkey, value_name, 0, REG_SZ, @ptrCast(data), len * 2);
}

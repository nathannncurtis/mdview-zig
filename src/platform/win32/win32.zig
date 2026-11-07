const std = @import("std");
const app = @import("../../main.zig");
const md = app.md;
const hl = @import("../../markdown/highlight.zig");
const alerts = @import("../../markdown/alerts.zig");
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
const WM_SETCURSOR: u32 = 0x0020;
const WM_MOUSEMOVE: u32 = 0x0200;
const WM_LBUTTONDOWN: u32 = 0x0201;
const WM_LBUTTONUP: u32 = 0x0202;
const WM_XBUTTONUP: u32 = 0x020C;
const WM_SYSKEYDOWN: u32 = 0x0104;
const VK_LEFT: usize = 0x25;
const VK_RIGHT: usize = 0x27;
const SW_SHOWNORMAL: i32 = 1;
const WM_NCCALCSIZE: u32 = 0x0083;
const WM_TIMER: u32 = 0x0113;
const WM_DROPFILES: u32 = 0x0233;
const VK_Q: usize = 0x51;
const VK_MENU: i32 = 0x12;
const VK_CONTROL: i32 = 0x11;
const CS_HREDRAW: u32 = 0x0002;
const CS_VREDRAW: u32 = 0x0001;
const WS_POPUP: u32 = 0x80000000;
const WS_THICKFRAME: u32 = 0x00040000;
const WS_SYSMENU: u32 = 0x00080000;
const WS_MINIMIZEBOX: u32 = 0x00020000;
const WS_MAXIMIZEBOX: u32 = 0x00010000;
const WS_EX_ACCEPTFILES: u32 = 0x00000010;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const SW_SHOW: i32 = 5;

const STARTUPINFOW = extern struct {
    cb: u32, reserved: ?[*:0]u16, desktop: ?[*:0]u16, title: ?[*:0]u16,
    x: u32, y: u32, x_size: u32, y_size: u32, x_chars: u32, y_chars: u32, fill: u32,
    flags: u32, show_window: u16, reserved2: u16, reserved3: ?*u8,
    std_input: ?*anyopaque, std_output: ?*anyopaque, std_error: ?*anyopaque,
};
extern "kernel32" fn GetStartupInfoW(info: *STARTUPINFOW) callconv(.c) void;

fn startupShowCommand() i32 {
    // SAFETY: filled by GetStartupInfoW
    var info: STARTUPINFOW = undefined;
    info.cb = @sizeOf(STARTUPINFOW);
    GetStartupInfoW(&info);
    const use_show_window = 0x1;
    return if (info.flags & use_show_window != 0 and info.show_window != 0) info.show_window else SW_SHOW;
}
const IDC_ARROW: usize = 32512;
const IDC_HAND: usize = 32649;
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
const TIMER_IMAGES: usize = 3;

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
extern "user32" fn SetCursor(hCursor: ?*anyopaque) callconv(.c) ?*anyopaque;
extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.c) i16;
extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.c) BOOL;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.c) ?*anyopaque;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.c) BOOL;
extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: u32, lpTimerFunc: ?*anyopaque) callconv(.c) usize;
extern "user32" fn KillTimer(hWnd: ?HWND, uIDEvent: usize) callconv(.c) BOOL;
extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.c) HRESULT;
extern "shell32" fn DragQueryFileW(hDrop: *anyopaque, iFile: u32, lpszFile: ?[*]u16, cch: u32) callconv(.c) u32;
extern "shell32" fn ShellExecuteW(hwnd: ?HWND, lpOperation: ?[*:0]const u16, lpFile: [*:0]const u16, lpParameters: ?[*:0]const u16, lpDirectory: ?[*:0]const u16, nShowCmd: i32) callconv(.c) ?*anyopaque;
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
const D2D1_BITMAP_PROPERTIES = extern struct { pixel_format: extern struct { format: u32, alpha_mode: u32 }, dpi_x: f32, dpi_y: f32 };
const D2D1_RENDER_TARGET_PROPERTIES = extern struct {
    type: u32 = 0, pixel_format: extern struct { format: u32 = 0, alpha_mode: u32 = 0 } = .{},
    dpi_x: f32 = 0, dpi_y: f32 = 0, usage: u32 = 0, min_level: u32 = 0,
};
const D2D1_HWND_RENDER_TARGET_PROPERTIES = extern struct { hwnd: HWND, pixel_size: D2D1_SIZE_U, present_options: u32 = 0 };
const DWRITE_TEXT_RANGE = extern struct { startPosition: u32, length: u32 };
const DWRITE_HIT_TEST_METRICS = extern struct {
    textPosition: u32, length: u32, left: f32, top: f32, width: f32, height: f32, bidiLevel: u32, isText: BOOL, isTrimmed: BOOL,
};
const DWRITE_GLYPH_RUN = extern struct {
    fontFace: ?*anyopaque, fontEmSize: f32, glyphCount: u32, glyphIndices: ?*const u16,
    glyphAdvances: ?*const f32, glyphOffsets: ?*const anyopaque, isSideways: BOOL, bidiLevel: u32,
};
const DWRITE_COLOR_F = extern struct { r: f32, g: f32, b: f32, a: f32 };
const DWRITE_COLOR_GLYPH_RUN = extern struct {
    glyphRun: DWRITE_GLYPH_RUN, glyphRunDescription: ?*const anyopaque, baselineOriginX: f32, baselineOriginY: f32,
    runColor: DWRITE_COLOR_F, paletteIndex: u16,
};
const DWRITE_UNDERLINE = extern struct {
    width: f32, thickness: f32, offset: f32, runHeight: f32, readingDirection: u32, flowDirection: u32,
    localeName: ?*const u16, measuringMode: u32,
};
const DWRITE_MATRIX = extern struct { m11: f32, m12: f32, m21: f32, m22: f32, dx: f32, dy: f32 };
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
    CreateBitmap: *const fn (*anyopaque, D2D1_SIZE_U, ?*const anyopaque, u32, *const D2D1_BITMAP_PROPERTIES, *?*anyopaque) callconv(.c) HRESULT, // 4
    _pad5_7: [3]*const anyopaque,
    CreateSolidColorBrush: *const fn (*anyopaque, *const D2D1_COLOR_F, ?*const anyopaque, *?*anyopaque) callconv(.c) HRESULT, // 8
    _pad9_14: [6]*const anyopaque,
    DrawLine: *const fn (*anyopaque, D2D1_POINT_2F, D2D1_POINT_2F, *anyopaque, f32, ?*anyopaque) callconv(.c) void, // 15
    _pad16: *const anyopaque,
    FillRectangle: *const fn (*anyopaque, *const D2D1_RECT_F, *anyopaque) callconv(.c) void, // 17
    _pad18: *const anyopaque,
    FillRoundedRectangle: *const fn (*anyopaque, *const D2D1_ROUNDED_RECT, *anyopaque) callconv(.c) void, // 19
    _pad20_22: [3]*const anyopaque,
    FillGeometry: *const fn (*anyopaque, *anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void, // 23
    _pad24_25: [2]*const anyopaque,
    DrawBitmap: *const fn (*anyopaque, *anyopaque, *const D2D1_RECT_F, f32, u32, ?*const D2D1_RECT_F) callconv(.c) void, // 26
    _pad27: *const anyopaque,
    DrawTextLayout: *const fn (*anyopaque, D2D1_POINT_2F, *anyopaque, *anyopaque, u32) callconv(.c) void, // 28
    DrawGlyphRun: *const fn (*anyopaque, D2D1_POINT_2F, *const DWRITE_GLYPH_RUN, *anyopaque, u32) callconv(.c) void, // 29
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

const IID_IDWriteTextLayout1 = GUID{ .Data1 = 0x9064d822, .Data2 = 0x80a7, .Data3 = 0x465c, .Data4 = .{ 0xa9, 0x86, 0xdf, 0x65, 0xf7, 0x8b, 0x8f, 0xeb } };

const IDWriteTextLayout1_VTable = extern struct {
    QueryInterface: *const anyopaque, AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    _pad3_68: [66]*const anyopaque,
    SetCharacterSpacing: *const fn (*anyopaque, f32, f32, f32, DWRITE_TEXT_RANGE) callconv(.c) HRESULT, // 69
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
    SetInlineObject: *const fn (*anyopaque, ?*anyopaque, DWRITE_TEXT_RANGE) callconv(.c) HRESULT, // 39
    _pad40_57: [18]*const anyopaque,
    Draw: *const fn (*anyopaque, ?*anyopaque, *anyopaque, f32, f32) callconv(.c) HRESULT, // 58
    _pad59: *const anyopaque,
    GetMetrics: *const fn (*anyopaque, *DWRITE_TEXT_METRICS) callconv(.c) HRESULT, // 60
    _pad61_63: [3]*const anyopaque,
    HitTestPoint: *const fn (*anyopaque, f32, f32, *BOOL, *BOOL, *DWRITE_HIT_TEST_METRICS) callconv(.c) HRESULT, // 64
    _pad65: *const anyopaque,
    HitTestTextRange: *const fn (*anyopaque, u32, u32, f32, f32, [*]DWRITE_HIT_TEST_METRICS, u32, *u32) callconv(.c) HRESULT, // 66
};

const IDWriteFactory2_VTable = extern struct {
    QueryInterface: *const anyopaque, AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    _pad3_27: [25]*const anyopaque,
    TranslateColorGlyphRun: *const fn (*anyopaque, f32, f32, *const DWRITE_GLYPH_RUN, ?*const anyopaque, u32, *const DWRITE_MATRIX, u32, *?*anyopaque) callconv(.c) HRESULT, // 28
};

const IDWriteColorGlyphRunEnumerator_VTable = extern struct {
    QueryInterface: *const anyopaque, AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    MoveNext: *const fn (*anyopaque, *BOOL) callconv(.c) HRESULT, // 3
    GetCurrentRun: *const fn (*anyopaque, *?*const DWRITE_COLOR_GLYPH_RUN) callconv(.c) HRESULT, // 4
};

const ID2D1SolidColorBrush_VTable = extern struct {
    QueryInterface: *const anyopaque, AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    _pad3_7: [5]*const anyopaque,
    SetColor: *const fn (*anyopaque, *const D2D1_COLOR_F) callconv(.c) void, // 8
};

const IID_IDWriteFactory2 = GUID{ .Data1 = 0x0439fc60, .Data2 = 0xca44, .Data3 = 0x4994, .Data4 = .{ 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec } };

const IDWriteTextRenderer_VTable = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    IsPixelSnappingDisabled: *const fn (*anyopaque, ?*anyopaque, *BOOL) callconv(.c) HRESULT,
    GetCurrentTransform: *const fn (*anyopaque, ?*anyopaque, *DWRITE_MATRIX) callconv(.c) HRESULT,
    GetPixelsPerDip: *const fn (*anyopaque, ?*anyopaque, *f32) callconv(.c) HRESULT,
    DrawGlyphRun: *const fn (*anyopaque, ?*anyopaque, f32, f32, u32, *const DWRITE_GLYPH_RUN, ?*const anyopaque, ?*anyopaque) callconv(.c) HRESULT,
    DrawUnderline: *const fn (*anyopaque, ?*anyopaque, f32, f32, *const DWRITE_UNDERLINE, ?*anyopaque) callconv(.c) HRESULT,
    DrawStrikethrough: *const fn (*anyopaque, ?*anyopaque, f32, f32, *const anyopaque, ?*anyopaque) callconv(.c) HRESULT,
    DrawInlineObject: *const fn (*anyopaque, ?*anyopaque, f32, f32, ?*anyopaque, BOOL, BOOL, ?*anyopaque) callconv(.c) HRESULT,
};

const TextRenderer = extern struct { vtbl: *const IDWriteTextRenderer_VTable };

const DrawContext = struct { rt: *anyopaque, brush: *anyopaque };

// Draws glyph runs itself so a run tagged with a sup brush can sit above the baseline.
const text_renderer_vtable = IDWriteTextRenderer_VTable{
    .QueryInterface = rendererQuery,
    .AddRef = rendererRef,
    .Release = rendererRef,
    .IsPixelSnappingDisabled = rendererSnapping,
    .GetCurrentTransform = rendererTransform,
    .GetPixelsPerDip = rendererDip,
    .DrawGlyphRun = rendererGlyphRun,
    .DrawUnderline = rendererUnderline,
    .DrawStrikethrough = rendererStrike,
    .DrawInlineObject = rendererInline,
};
var g_text_renderer = TextRenderer{ .vtbl = &text_renderer_vtable };

const IID_IUnknown = GUID{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_IDWritePixelSnapping = GUID{ .Data1 = 0xeaf3a2da, .Data2 = 0xecf4, .Data3 = 0x4d24, .Data4 = .{ 0xb6, 0x44, 0xb3, 0x4f, 0x68, 0x42, 0x02, 0x4b } };
const IID_IDWriteTextRenderer = GUID{ .Data1 = 0xef8a8135, .Data2 = 0x5cc6, .Data3 = 0x45fe, .Data4 = .{ 0x88, 0x25, 0xc5, 0xa0, 0x72, 0x4e, 0xb8, 0x19 } };

// Newer renderer interfaces must be refused: DrawGlyphRun differs there and the table ends early.
fn rendererQuery(self: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.c) HRESULT {
    inline for (.{ IID_IUnknown, IID_IDWritePixelSnapping, IID_IDWriteTextRenderer }) |known| {
        if (std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&known))) {
            out.* = self;
            return 0;
        }
    }
    out.* = null;
    return @bitCast(@as(u32, 0x80004002));
}
fn rendererRef(_: *anyopaque) callconv(.c) u32 {
    return 1;
}
fn rendererSnapping(_: *anyopaque, _: ?*anyopaque, out: *BOOL) callconv(.c) HRESULT {
    out.* = 0;
    return 0;
}
fn rendererTransform(_: *anyopaque, _: ?*anyopaque, out: *DWRITE_MATRIX) callconv(.c) HRESULT {
    out.* = .{ .m11 = 1, .m12 = 0, .m21 = 0, .m22 = 1, .dx = 0, .dy = 0 };
    return 0;
}
fn rendererDip(_: *anyopaque, _: ?*anyopaque, out: *f32) callconv(.c) HRESULT {
    out.* = 1;
    return 0;
}

fn isSupBrush(effect: ?*anyopaque) bool {
    const e = effect orelse return false;
    return e == g_brush_link_sup or e == g_brush_text_sup;
}

fn rendererGlyphRun(_: *anyopaque, ctx: ?*anyopaque, x: f32, y: f32, mode: u32, glyphs: *const DWRITE_GLYPH_RUN, desc: ?*const anyopaque, effect: ?*anyopaque) callconv(.c) HRESULT {
    const dc: *const DrawContext = @ptrCast(@alignCast(ctx orelse return 0));
    const raise: f32 = if (isSupBrush(effect)) glyphs.fontEmSize * sup_raise else 0;
    drawGlyphRun(dc, x, y - raise, mode, glyphs, desc, effect orelse dc.brush);
    return 0;
}

// Colour fonts (emoji) come as layers, each with its own palette colour; plain runs draw as one.
fn drawGlyphRun(dc: *const DrawContext, x: f32, y: f32, mode: u32, glyphs: *const DWRITE_GLYPH_RUN, desc: ?*const anyopaque, brush: *anyopaque) void {
    const vt_rt = vtable(ID2D1RT_VTable, dc.rt);
    if (g_dwrite_factory2) |f2| {
        var layers: ?*anyopaque = null;
        const identity = DWRITE_MATRIX{ .m11 = 1, .m12 = 0, .m21 = 0, .m22 = 1, .dx = 0, .dy = 0 };
        if (vtable(IDWriteFactory2_VTable, f2).TranslateColorGlyphRun(f2, x, y, glyphs, desc, mode, &identity, 0, &layers) >= 0) {
            if (layers) |en| {
                defer _ = vtable(IDWriteColorGlyphRunEnumerator_VTable, en).Release(en);
                const vt_en = vtable(IDWriteColorGlyphRunEnumerator_VTable, en);
                var more: BOOL = 0;
                while (vt_en.MoveNext(en, &more) >= 0 and more != 0) {
                    var layer: ?*const DWRITE_COLOR_GLYPH_RUN = null;
                    if (vt_en.GetCurrentRun(en, &layer) < 0) break;
                    const l = layer orelse break;
                    var use = brush;
                    if (l.paletteIndex != 0xFFFF) if (g_brush_color_layer) |lb| {
                        vtable(ID2D1SolidColorBrush_VTable, lb).SetColor(lb, &.{ .r = l.runColor.r, .g = l.runColor.g, .b = l.runColor.b, .a = l.runColor.a });
                        use = lb;
                    };
                    vt_rt.DrawGlyphRun(dc.rt, .{ .x = l.baselineOriginX, .y = l.baselineOriginY }, &l.glyphRun, use, mode);
                }
                if (!g_color_logged) {
                    g_color_logged = true;
                    app.log("colour glyph run drawn");
                }
                return;
            }
        }
    }
    vt_rt.DrawGlyphRun(dc.rt, .{ .x = x, .y = y }, glyphs, brush, mode);
}
fn rendererUnderline(_: *anyopaque, ctx: ?*anyopaque, x: f32, y: f32, u: *const DWRITE_UNDERLINE, effect: ?*anyopaque) callconv(.c) HRESULT {
    const dc: *const DrawContext = @ptrCast(@alignCast(ctx orelse return 0));
    const raise: f32 = if (isSupBrush(effect)) u.runHeight * sup_raise else 0;
    const top = y + u.offset - raise;
    vtable(ID2D1RT_VTable, dc.rt).FillRectangle(dc.rt, &.{ .left = x, .top = top, .right = x + u.width, .bottom = top + @max(u.thickness, 1) }, effect orelse dc.brush);
    return 0;
}
fn rendererStrike(_: *anyopaque, ctx: ?*anyopaque, x: f32, y: f32, u: *const anyopaque, effect: ?*anyopaque) callconv(.c) HRESULT {
    const dc: *const DrawContext = @ptrCast(@alignCast(ctx orelse return 0));
    const line: *const DWRITE_UNDERLINE = @ptrCast(@alignCast(u));
    const top = y + line.offset;
    vtable(ID2D1RT_VTable, dc.rt).FillRectangle(dc.rt, &.{ .left = x, .top = top, .right = x + line.width, .bottom = top + @max(line.thickness, 1) }, effect orelse dc.brush);
    return 0;
}
fn rendererInline(_: *anyopaque, ctx: ?*anyopaque, x: f32, y: f32, object: ?*anyopaque, _: BOOL, _: BOOL, effect: ?*anyopaque) callconv(.c) HRESULT {
    const dc: *const DrawContext = @ptrCast(@alignCast(ctx orelse return 0));
    const obj: *const ImageObject = @ptrCast(@alignCast(object orelse return 0));
    drawImageObject(dc, obj, x, y, effect orelse dc.brush);
    return 0;
}

const IID_IDWriteInlineObject = GUID{ .Data1 = 0x8339fde3, .Data2 = 0x106f, .Data3 = 0x47ab, .Data4 = .{ 0x83, 0x73, 0x1c, 0x62, 0x95, 0xeb, 0x10, 0xb3 } };
const DWRITE_INLINE_OBJECT_METRICS = extern struct { width: f32, height: f32, baseline: f32, supports_sideways: BOOL };
const DWRITE_OVERHANG_METRICS = extern struct { left: f32, top: f32, right: f32, bottom: f32 };

const InlineObject_VTable = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    Draw: *const fn (*anyopaque, ?*anyopaque, *anyopaque, f32, f32, BOOL, BOOL, ?*anyopaque) callconv(.c) HRESULT,
    GetMetrics: *const fn (*anyopaque, *DWRITE_INLINE_OBJECT_METRICS) callconv(.c) HRESULT,
    GetOverhangMetrics: *const fn (*anyopaque, *DWRITE_OVERHANG_METRICS) callconv(.c) HRESULT,
    GetBreakConditions: *const fn (*anyopaque, *u32, *u32) callconv(.c) HRESULT,
};

const inline_object_vtable = InlineObject_VTable{
    .QueryInterface = objectQuery,
    .AddRef = rendererRef,
    .Release = rendererRef,
    .Draw = objectDraw,
    .GetMetrics = objectMetrics,
    .GetOverhangMetrics = objectOverhang,
    .GetBreakConditions = objectBreaks,
};

const ImageKind = enum(u32) { pending, picture, alt };

/// One image in a layout; sits on the baseline and is painted by the text renderer, which receives this pointer back.
const ImageObject = extern struct {
    vtbl: *const InlineObject_VTable = &inline_object_vtable,
    w: f32,
    h: f32,
    kind: ImageKind,
    image: *const md.Image,
};

var g_objects: ?std.heap.ArenaAllocator = null;

fn resetObjects() void {
    if (g_objects) |*a| _ = a.reset(.free_all);
}

fn objectQuery(self: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.c) HRESULT {
    inline for (.{ IID_IUnknown, IID_IDWriteInlineObject }) |known| {
        if (std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&known))) {
            out.* = self;
            return 0;
        }
    }
    out.* = null;
    return @bitCast(@as(u32, 0x80004002));
}
fn objectDraw(_: *anyopaque, _: ?*anyopaque, _: *anyopaque, _: f32, _: f32, _: BOOL, _: BOOL, _: ?*anyopaque) callconv(.c) HRESULT {
    return 0;
}
fn objectMetrics(self: *anyopaque, out: *DWRITE_INLINE_OBJECT_METRICS) callconv(.c) HRESULT {
    const obj: *const ImageObject = @ptrCast(@alignCast(self));
    out.* = .{ .width = obj.w, .height = obj.h, .baseline = obj.h, .supports_sideways = 0 };
    return 0;
}
fn objectOverhang(_: *anyopaque, out: *DWRITE_OVERHANG_METRICS) callconv(.c) HRESULT {
    out.* = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    return 0;
}
fn objectBreaks(_: *anyopaque, before: *u32, after: *u32) callconv(.c) HRESULT {
    before.* = 0;
    after.* = 0;
    return 0;
}

fn imageObject(vt_dw: *const IDWriteFactory_VTable, dwf: *anyopaque, im: *const md.Image, max_width: f32) ?*ImageObject {
    if (g_objects == null) g_objects = .init(app.gpa);
    const obj = (g_objects.?.allocator().create(ImageObject) catch return null);
    obj.* = .{ .w = 0, .h = 0, .kind = .pending, .image = im };
    switch (app.images.look(im.target, max_width)) {
        .pending => {},
        .picture => |s| {
            obj.w = s.w;
            obj.h = s.h;
            obj.kind = if (s.w > 0) .picture else .pending;
        },
        .missing => if (im.alt.len > 0) {
            const lay = createLayout(vt_dw, dwf, .{ .text = im.alt }, g_text_format.?, max_width) orelse return obj;
            defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);
            // SAFETY: written by GetMetrics
            var m: DWRITE_TEXT_METRICS = undefined;
            _ = vtable(IDWriteTextLayout_VTable, lay).GetMetrics(lay, &m);
            obj.w = @min(@ceil(m.width), max_width);
            obj.h = m.height;
            obj.kind = .alt;
        },
    }
    return obj;
}

fn drawImageObject(dc: *const DrawContext, obj: *const ImageObject, x: f32, y: f32, brush: *anyopaque) void {
    const top = y - app.scroll_y;
    if (top + obj.h < 0 or top > app.window_height or obj.w <= 0) return;
    const vt_rt = vtable(ID2D1RT_VTable, dc.rt);
    switch (obj.kind) {
        .pending => {},
        .picture => {
            const bm = app.images.bitmap(obj.image.target, .{ .w = obj.w, .h = obj.h }) orelse return;
            vt_rt.DrawBitmap(dc.rt, bm.native, &.{ .left = x, .top = y, .right = x + obj.w, .bottom = y + obj.h }, 1, 1, null);
        },
        .alt => {
            const dwf = g_dwrite_factory orelse return;
            const lay = createLayout(vtable(IDWriteFactory_VTable, dwf), dwf, .{ .text = obj.image.alt }, g_text_format.?, obj.w) orelse return;
            defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);
            vt_rt.DrawTextLayout(dc.rt, .{ .x = x, .y = y }, lay, brush, draw_color_font);
        },
    }
}

fn createBitmapNative(rgba: []const u8, w: u32, h: u32) ?*anyopaque {
    const rt = g_render_target orelse return null;
    const buf = app.gpa.alloc(u8, rgba.len) catch return null;
    defer app.gpa.free(buf);
    var i: usize = 0;
    while (i + 3 < rgba.len) : (i += 4) {
        const a: u32 = rgba[i + 3];
        buf[i] = @intCast((@as(u32, rgba[i + 2]) * a + 127) / 255);
        buf[i + 1] = @intCast((@as(u32, rgba[i + 1]) * a + 127) / 255);
        buf[i + 2] = @intCast((@as(u32, rgba[i]) * a + 127) / 255);
        buf[i + 3] = @intCast(a);
    }
    var bmp: ?*anyopaque = null;
    const props = D2D1_BITMAP_PROPERTIES{ .pixel_format = .{ .format = 87, .alpha_mode = 1 }, .dpi_x = 96, .dpi_y = 96 };
    if (vtable(ID2D1RT_VTable, rt).CreateBitmap(rt, .{ .width = w, .height = h }, buf.ptr, w * 4, &props, &bmp) < 0) return null;
    return bmp;
}

fn freeBitmapNative(bmp: ?*anyopaque) void {
    const b = bmp orelse return;
    _ = vtable(ID2D1Factory_VTable, b).Release(b);
}

const sup_scale: f32 = 0.7;
const sup_raise: f32 = 0.5;

fn codeRects(lay: *anyopaque, content: md.Inline, out: *std.ArrayList(D2D1_RECT_F)) std.mem.Allocator.Error!void {
    const vt = vtable(IDWriteTextLayout_VTable, lay);
    for (content.code) |span| {
        const range = wideRange(content.text, span);
        if (range.length == 0) continue;
        var stack: [16]DWRITE_HIT_TEST_METRICS = undefined;
        var rects: []DWRITE_HIT_TEST_METRICS = &stack;
        var heap: ?[]DWRITE_HIT_TEST_METRICS = null;
        defer if (heap) |h| app.gpa.free(h);
        var count: u32 = 0;
        var hr = vt.HitTestTextRange(lay, range.startPosition, range.length, 0, 0, rects.ptr, @intCast(rects.len), &count);
        if (hr == E_NOT_SUFFICIENT_BUFFER) {
            heap = try app.gpa.alloc(DWRITE_HIT_TEST_METRICS, count);
            rects = heap.?;
            hr = vt.HitTestTextRange(lay, range.startPosition, range.length, 0, 0, rects.ptr, @intCast(rects.len), &count);
        }
        if (hr < 0) continue;
        const frags = rects[0..@min(count, rects.len)];
        for (frags) |r| {
            try out.append(app.gpa, .{ .left = r.left, .top = r.top, .right = r.left + r.width, .bottom = r.top + r.height });
        }
    }
}

fn drawCodeBackgrounds(vt_rt: *const ID2D1RT_VTable, rt: *anyopaque, lay: *anyopaque, x: f32, y: f32, content: md.Inline) void {
    const brush = g_brush_code_span orelse return;
    var rects: std.ArrayList(D2D1_RECT_F) = .empty;
    defer rects.deinit(app.gpa);
    codeRects(lay, content, &rects) catch return;
    for (rects.items) |r| {
        vt_rt.FillRoundedRectangle(rt, &.{
            .rect = .{ .left = x + r.left, .top = y + r.top, .right = x + r.right, .bottom = y + r.bottom },
            .radiusX = md.code_radius,
            .radiusY = md.code_radius,
        }, brush);
    }
}

fn drawLayout(vt_rt: *const ID2D1RT_VTable, rt: *anyopaque, lay: *anyopaque, x: f32, y: f32, brush: *anyopaque, content: md.Inline) void {
    if (content.code.len > 0) drawCodeBackgrounds(vt_rt, rt, lay, x, y, content);
    if (content.sup.len == 0 and content.images.len == 0) {
        vt_rt.DrawTextLayout(rt, .{ .x = x, .y = y }, lay, brush, draw_color_font);
        return;
    }
    var dc = DrawContext{ .rt = rt, .brush = brush };
    _ = vtable(IDWriteTextLayout_VTable, lay).Draw(lay, &dc, &g_text_renderer, x, y);
}

fn baseFontSize(format: *anyopaque) f32 {
    if (format == g_text_format_h1) return 32;
    if (format == g_text_format_h2) return 24;
    if (format == g_text_format_h3) return 20;
    if (format == g_text_format_h5) return 14;
    if (format == g_text_format_h6) return 13.6;
    return 16;
}

fn fontOf(format: *anyopaque) app.Font {
    if (format == g_text_format_h1) return .h1;
    if (format == g_text_format_h2) return .h2;
    if (format == g_text_format_h3) return .h3;
    if (format == g_text_format_h4) return .h4;
    if (format == g_text_format_h5) return .h5;
    if (format == g_text_format_h6) return .h6;
    return .body;
}

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
var g_brush_code_span: ?*anyopaque = null;
var g_brush_quote: ?*anyopaque = null;
var g_brush_hr: ?*anyopaque = null;
var g_brush_table_border: ?*anyopaque = null;
var g_brush_stripe: ?*anyopaque = null;
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
var g_brush_link: ?*anyopaque = null;
var g_brush_link_sup: ?*anyopaque = null;
var g_brush_text_sup: ?*anyopaque = null;
var g_brush_color_layer: ?*anyopaque = null;
var g_dwrite_factory2: ?*anyopaque = null;
var g_color_logged = false;
var g_cursor_hand: ?*anyopaque = null;
var g_over_link = false;

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
        WS_POPUP | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 900, 700, null, null, hi, null,
    ) orelse return;
    g_hwnd = hwnd;

    createRenderTarget(hwnd);
    if (g_render_target != null) app.log("render target created") else app.log("FAILED to create render target");

    _ = SetTimer(hwnd, TIMER_FILE_WATCH, 500, null);
    _ = SetTimer(hwnd, TIMER_SCROLL_SAVE, 3000, null);
    _ = ShowWindow(hwnd, startupShowCommand());
    _ = UpdateWindow(hwnd);

    // SAFETY: written by GetMessageW
    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

pub fn initD2D() void {
    _ = D2D1CreateFactory(0, &IID_ID2D1Factory, null, &g_d2d_factory);
    _ = DWriteCreateFactory(0, &IID_IDWriteFactory, &g_dwrite_factory);
    if (g_dwrite_factory) |dwf| {
        const query: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT = @ptrCast(vtable(IDWriteFactory_VTable, dwf).QueryInterface);
        _ = query(dwf, &IID_IDWriteFactory2, &g_dwrite_factory2);
    }
    if (g_d2d_factory) |f| createAlertGeometries(f);
    app.images.create_native = createBitmapNative;
    app.images.free_native = freeBitmapNative;
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
        // SAFETY: written by GetClientRect
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
    var span_color = rgbColor(md.code_bg);
    span_color.a = md.code_bg_alpha;
    _ = vt.CreateSolidColorBrush(rt, &span_color, null, &g_brush_code_span);
    g_brush_table_border = solidBrush(rt, 0x3d444d);
    g_brush_stripe = solidBrush(rt, 0x151b23);
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
    g_brush_link = solidBrush(rt, 0x4493f8);
    g_brush_link_sup = solidBrush(rt, 0x4493f8);
    g_brush_text_sup = solidBrush(rt, 0xc9d1d9);
    g_brush_color_layer = solidBrush(rt, 0xffffff);
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

    resetObjects();
    vt_rt.BeginDraw(rt);
    vt_rt.Clear(rt, &.{ .r = 0.051, .g = 0.067, .b = 0.090, .a = 1 });
    vt_rt.SetTransform(rt, &.{ .m = .{ 1, 0, 0, 1, 0, -app.scroll_y } });

    const padding: f32 = 40;
    const max_width = @max(app.window_width - padding * 2, 100);
    var y: f32 = padding;
    app.beginFrame();

    for (app.blocks) |*block| {
        app.noteBlock(y);
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
    if (app.tooltip) |t| drawTooltip(vt_rt, vt_dw, rt, dwf, t);
    if (g_brush_close) |brush| {
        const bx = app.window_width - 36;
        vt_rt.DrawLine(rt, .{ .x = bx + 4, .y = 12 }, .{ .x = bx + 20, .y = 28 }, brush, 1.5, null);
        vt_rt.DrawLine(rt, .{ .x = bx + 20, .y = 12 }, .{ .x = bx + 4, .y = 28 }, brush, 1.5, null);
    }

    _ = vt_rt.EndDraw(rt, null, null);
}

fn drawTooltip(vt_rt: *const ID2D1RT_VTable, vt_dw: *const IDWriteFactory_VTable, rt: *anyopaque, dwf: *anyopaque, t: app.Tooltip) void {
    const lay = createLayout(vt_dw, dwf, .{ .text = t.text }, g_text_format.?, 360) orelse return;
    defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);
    // SAFETY: written by GetMetrics
    var m: DWRITE_TEXT_METRICS = undefined;
    _ = vtable(IDWriteTextLayout_VTable, lay).GetMetrics(lay, &m);
    const w = m.widthIncludingTrailingWhitespace + 16;
    const h = m.height + 10;
    const x = @min(t.x + 14, app.window_width - w - 4);
    const y = if (t.y + 22 + h > app.window_height) t.y - h - 6 else t.y + 22;
    vt_rt.FillRoundedRectangle(rt, &.{ .rect = .{ .left = x - 1, .top = y - 1, .right = x + w + 1, .bottom = y + h + 1 }, .radiusX = 5, .radiusY = 5 }, g_brush_table_border.?);
    vt_rt.FillRoundedRectangle(rt, &.{ .rect = .{ .left = x, .top = y, .right = x + w, .bottom = y + h }, .radiusX = 4, .radiusY = 4 }, g_brush_code_bg.?);
    vt_rt.DrawTextLayout(rt, .{ .x = x + 8, .y = y + 5 }, lay, g_brush_text.?, 0);
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
    // SAFETY: written by GetMetrics
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
            // SAFETY: written by GetMetrics
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
    // SAFETY: written by GetMetrics
    var metrics: DWRITE_TEXT_METRICS = undefined;
    _ = vtable(IDWriteTextLayout_VTable, lay).GetMetrics(lay, &metrics);
    drawLayout(vt_rt, rt, lay, x, y, brush, content);
    app.noteHit(.{ .content = content, .x = x, .y = y, .w = max_width, .h = metrics.height, .font = fontOf(text_format) });
    return metrics.height;
}

const draw_color_font: u32 = 4; // D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT

fn formatFor(font: app.Font) ?*anyopaque {
    return switch (font) {
        .body => g_text_format,
        .h1 => g_text_format_h1,
        .h2 => g_text_format_h2,
        .h3 => g_text_format_h3,
        .h4 => g_text_format_h4,
        .h5 => g_text_format_h5,
        .h6 => g_text_format_h6,
    };
}

fn alignmentCode(a: md.Align) u32 {
    return switch (a) {
        .none, .left => 0,
        .right => 1,
        .center => 2,
    };
}

pub fn textIndexAt(hit: app.Hit, x: f32, y: f32) ?u32 {
    resetObjects();
    const dwf = g_dwrite_factory orelse return null;
    const lay = createLayout(vtable(IDWriteFactory_VTable, dwf), dwf, hit.content, formatFor(hit.font) orelse return null, hit.w) orelse return null;
    defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);
    const vt = vtable(IDWriteTextLayout_VTable, lay);
    if (hit.header) _ = vt.SetFontWeight(lay, 700, wideRange(hit.content.text, .{ 0, @intCast(hit.content.text.len) }));
    _ = vt.SetTextAlignment(lay, alignmentCode(hit.alignment));
    var trailing: BOOL = 0;
    var inside: BOOL = 0;
    // SAFETY: written by HitTestPoint
    var m: DWRITE_HIT_TEST_METRICS = undefined;
    if (vt.HitTestPoint(lay, x, y, &trailing, &inside, &m) < 0 or inside == 0) return null;
    return md.byteFromUtf16(hit.content.text, m.textPosition);
}

pub fn openExternal(url: []const u8) void {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(app.gpa, url) catch return;
    defer app.gpa.free(wide);
    _ = ShellExecuteW(null, L("open"), wide.ptr, null, null, SW_SHOWNORMAL);
}

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
        const range = wideRange(content.text, span);
        _ = vt_layout.SetFontFamilyName(lay, std.unicode.utf8ToUtf16LeStringLiteral("Consolas"), range);
        _ = vt_layout.SetFontSize(lay, baseFontSize(text_format) * md.code_scale, range);
    }
    if (content.code.len > 0) padCodeSpans(lay, content, baseFontSize(text_format));
    for (content.emoji) |span| {
        _ = vt_layout.SetFontFamilyName(lay, std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Emoji"), wideRange(content.text, span));
    }
    for (content.links) |l| {
        const range = wideRange(content.text, .{ l.start, l.len });
        if (g_brush_link) |b| _ = vt_layout.SetDrawingEffect(lay, b, range);
        if (app.isHover(content, l)) _ = vt_layout.SetUnderline(lay, 1, range);
    }
    for (content.sup) |span| {
        const range = wideRange(content.text, span);
        _ = vt_layout.SetFontSize(lay, baseFontSize(text_format) * sup_scale, range);
        const brush = if (content.linkAt(span[0]) != null) g_brush_link_sup else g_brush_text_sup;
        if (brush) |b| _ = vt_layout.SetDrawingEffect(lay, b, range);
    }
    for (content.images) |*im| {
        const obj = imageObject(vt_dw, dwf, im, max_width) orelse continue;
        _ = vt_layout.SetInlineObject(lay, obj, wideRange(content.text, .{ im.start, im.len }));
    }
    return lay;
}

fn padCodeSpans(lay: *anyopaque, content: md.Inline, font_size: f32) void {
    const query: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT = @ptrCast(vtable(IDWriteTextLayout_VTable, lay).QueryInterface);
    var l1: ?*anyopaque = null;
    if (query(lay, &IID_IDWriteTextLayout1, &l1) < 0) return;
    const layout1 = l1 orelse return;
    defer _ = vtable(IDWriteTextLayout1_VTable, layout1).Release(layout1);
    const set = vtable(IDWriteTextLayout1_VTable, layout1).SetCharacterSpacing;
    const pad = md.code_pad_em * md.code_scale * font_size;
    for (content.code) |span| {
        const range = wideRange(content.text, span);
        if (range.length == 0) continue;
        _ = set(layout1, pad, 0, 0, .{ .startPosition = range.startPosition, .length = 1 });
        _ = set(layout1, if (range.length == 1) pad else 0, pad, 0, .{ .startPosition = range.startPosition + range.length - 1, .length = 1 });
    }
}

const cell_pad_x: f32 = 13;
const nested_margin: f32 = md.nested_table_margin;
const cell_pad_y: f32 = 6;

fn cellLayout(vt_dw: *const IDWriteFactory_VTable, dwf: *anyopaque, t: md.Table, row: usize, col: usize, width: f32) ?*anyopaque {
    const content = t.cell(row, col);
    const lay = createLayout(vt_dw, dwf, content, g_text_format orelse return null, width) orelse return null;
    const vt = vtable(IDWriteTextLayout_VTable, lay);
    if ((row == 0 and t.header_row) or (col == 0 and t.header_col)) _ = vt.SetFontWeight(lay, 700, wideRange(content.text, .{ 0, @intCast(content.text.len) }));
    _ = vt.SetTextAlignment(lay, alignmentCode(t.aligns[col]));
    return lay;
}

fn renderTable(vt_rt: *const ID2D1RT_VTable, vt_dw: *const IDWriteFactory_VTable, rt: *anyopaque, dwf: *anyopaque, t: md.Table, x: f32, y: f32, max_width: f32, draw: bool, out_width: ?*f32) f32 {
    const border = g_brush_table_border orelse return 0;
    if (out_width) |o| o.* = 0;
    if (t.rows() == 0) return 0;
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
            // SAFETY: written by GetMetrics
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
                text_h = @max(text_h, renderTable(vt_rt, vt_dw, rt, dwf, nt, 0, 0, widths[col] - cell_pad_x * 2, false, null) + nested_margin);
                continue;
            }
            lay.* = cellLayout(vt_dw, dwf, t, row, col, widths[col] - cell_pad_x * 2);
            if (lay.*) |l| {
                // SAFETY: written by GetMetrics
                var m: DWRITE_TEXT_METRICS = undefined;
                _ = vtable(IDWriteTextLayout_VTable, l).GetMetrics(l, &m);
                text_h = @max(text_h, m.height);
            }
        }
        const row_h = text_h + cell_pad_y * 2;
        if (draw) {
            if (md.Table.striped(t, row)) {
                vt_rt.FillRectangle(rt, &.{ .left = x, .top = row_y, .right = x + table_w, .bottom = row_y + row_h }, g_brush_stripe.?);
            }
        }
        var cx = x;
        for (layouts, widths, 0..) |lay, w, col| {
            if (draw) {
                if (t.nestedAt(row, col)) |nt| {
                    _ = renderTable(vt_rt, vt_dw, rt, dwf, nt, cx + cell_pad_x, row_y + cell_pad_y, w - cell_pad_x * 2, true, null);
                } else if (lay) |l| {
                    drawLayout(vt_rt, rt, l, cx + cell_pad_x, row_y + cell_pad_y, g_brush_text.?, t.cell(row, col));
                    app.noteHit(.{
                        .content = t.cell(row, col), .x = cx + cell_pad_x, .y = row_y + cell_pad_y, .w = w - cell_pad_x * 2,
                        .h = text_h, .header = (row == 0 and t.header_row) or (col == 0 and t.header_col), .alignment = t.aligns[col],
                    });
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

    // SAFETY: written by GetMetrics
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
            scheduleImages(hwnd);
            // SAFETY: written by BeginPaint
            var ps: PAINTSTRUCT = undefined;
            _ = BeginPaint(hwnd, &ps);
            _ = EndPaint(hwnd, &ps);
            if (app.afterRender()) _ = InvalidateRect(hwnd, null, 0);
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
        WM_MOUSEMOVE => {
            const lp: usize = @bitCast(lParam);
            const x: i16 = @bitCast(@as(u16, @truncate(lp)));
            const y: i16 = @bitCast(@as(u16, @truncate(lp >> 16)));
            g_over_link = app.pointerMoved(@floatFromInt(x), @floatFromInt(y));
            return 0;
        },
        WM_SETCURSOR => {
            const lp: usize = @bitCast(lParam);
            if (g_over_link and @as(u16, @truncate(lp)) == HTCLIENT) {
                if (g_cursor_hand == null) g_cursor_hand = LoadCursorW(null, IDC_HAND);
                _ = SetCursor(g_cursor_hand);
                return 1;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_LBUTTONDOWN => {
            const lp: usize = @bitCast(lParam);
            const x: i16 = @bitCast(@as(u16, @truncate(lp)));
            const y: i16 = @bitCast(@as(u16, @truncate(lp >> 16)));
            _ = app.mouseDown(@floatFromInt(x), @floatFromInt(y));
            return 0;
        },
        WM_LBUTTONUP => {
            const lp: usize = @bitCast(lParam);
            const x: i16 = @bitCast(@as(u16, @truncate(lp)));
            const y: i16 = @bitCast(@as(u16, @truncate(lp >> 16)));
            _ = app.mouseUp(@floatFromInt(x), @floatFromInt(y));
            return 0;
        },
        WM_XBUTTONUP => {
            const wp: usize = @bitCast(wParam);
            switch (@as(u16, @truncate(wp >> 16))) {
                1 => app.goBack(),
                2 => app.goForward(),
                else => {},
            }
            return 1;
        },
        WM_SYSKEYDOWN => {
            if (wParam == VK_LEFT) {
                app.goBack();
                return 0;
            }
            if (wParam == VK_RIGHT) {
                app.goForward();
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
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
            const timer_id: usize = @bitCast(wParam);
            if (timer_id == TIMER_FILE_WATCH) app.checkFileChanged();
            if (timer_id == TIMER_SCROLL_SAVE) app.saveScrollPosition();
            if (timer_id == TIMER_IMAGES) {
                _ = KillTimer(hwnd, TIMER_IMAGES);
                if (app.images.tick()) _ = InvalidateRect(hwnd, null, 0) else scheduleImages(hwnd);
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
            app.saveScrollPosition();
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

fn scheduleImages(hwnd: HWND) void {
    if (app.images.timerDelay()) |ms| _ = SetTimer(hwnd, TIMER_IMAGES, @max(ms, 15), null);
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
        std.Io.File.stdout().writeStreamingAll(app.io, "mdview is installed as a package, which already registers .md and .markdown. Choose mdview under Settings > Default apps.\n") catch return;
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
    std.Io.File.stdout().writeStreamingAll(app.io, "mdview registered as default viewer for .md and .markdown files.\n") catch return;
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

const testing = std.testing;

test "hit testing maps the pointer to the character under it" {
    app.gpa = testing.allocator;
    _ = CoInitializeEx(null, 0x2);
    initD2D();
    var doc = try md.parse(testing.allocator, "Go to [the site](http://x.org) now");
    defer doc.deinit();
    const content = doc.blocks[0].content;
    const hit: app.Hit = .{ .content = content, .x = 0, .y = 0, .w = 500, .h = 30 };

    var first: ?u32 = null;
    var last: u32 = 0;
    var x: f32 = 1;
    while (x < 250) : (x += 1) {
        const index = textIndexAt(hit, x, 10) orelse continue;
        if (content.linkAt(index) == null) continue;
        if (first == null) first = index;
        last = index;
    }
    try testing.expectEqual(@as(?u32, 6), first);
    try testing.expectEqual(@as(u32, 13), last);
    try testing.expectEqual(@as(?u32, 0), textIndexAt(hit, 2, 10));
    try testing.expectEqual(@as(?u32, null), textIndexAt(hit, 480, 10));
}

test "an inline code span that wraps gets one background rect per line" {
    app.gpa = testing.allocator;
    _ = CoInitializeEx(null, 0x2);
    initD2D();
    var doc = try md.parse(testing.allocator, "intro `alpha beta gamma delta epsilon zeta eta theta` outro");
    defer doc.deinit();
    const content = doc.blocks[0].content;
    const dwf = g_dwrite_factory.?;
    var rects: std.ArrayList(D2D1_RECT_F) = .empty;
    defer rects.deinit(testing.allocator);

    const wide = createLayout(vtable(IDWriteFactory_VTable, dwf), dwf, content, g_text_format.?, 2000).?;
    defer _ = vtable(IDWriteTextLayout_VTable, wide).Release(wide);
    try codeRects(wide, content, &rects);
    try testing.expectEqual(@as(usize, 1), rects.items.len);

    rects.clearRetainingCapacity();
    const narrow = createLayout(vtable(IDWriteFactory_VTable, dwf), dwf, content, g_text_format.?, 120).?;
    defer _ = vtable(IDWriteTextLayout_VTable, narrow).Release(narrow);
    try codeRects(narrow, content, &rects);
    try testing.expect(rects.items.len >= 2);
    for (rects.items[1..], rects.items[0 .. rects.items.len - 1]) |next, prev| try testing.expect(next.top > prev.top);
}

test "the code background padding takes up space on both sides of the span" {
    app.gpa = testing.allocator;
    _ = CoInitializeEx(null, 0x2);
    initD2D();
    var doc = try md.parse(testing.allocator, "before `code` after");
    defer doc.deinit();
    const content = doc.blocks[0].content;
    const dwf = g_dwrite_factory.?;
    const lay = createLayout(vtable(IDWriteFactory_VTable, dwf), dwf, content, g_text_format.?, 2000).?;
    defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);
    const vt = vtable(IDWriteTextLayout_VTable, lay);

    // SAFETY: written by GetMetrics
    var padded: DWRITE_TEXT_METRICS = undefined;
    _ = vt.GetMetrics(lay, &padded);
    var rects: std.ArrayList(D2D1_RECT_F) = .empty;
    defer rects.deinit(testing.allocator);
    try codeRects(lay, content, &rects);
    const with_pad = rects.items[0].right - rects.items[0].left;

    var l1: ?*anyopaque = null;
    const query: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT = @ptrCast(vt.QueryInterface);
    const hr = query(lay, &IID_IDWriteTextLayout1, &l1);
    try testing.expect(hr >= 0);
    defer _ = vtable(IDWriteTextLayout1_VTable, l1.?).Release(l1.?);
    _ = vtable(IDWriteTextLayout1_VTable, l1.?).SetCharacterSpacing(l1.?, 0, 0, 0, .{ .startPosition = 0, .length = @intCast(content.text.len) });
    // SAFETY: written by GetMetrics
    var plain: DWRITE_TEXT_METRICS = undefined;
    _ = vt.GetMetrics(lay, &plain);
    rects.clearRetainingCapacity();
    try codeRects(lay, content, &rects);
    const without = rects.items[0].right - rects.items[0].left;

    const want = 2 * md.code_pad_em * md.code_scale * 16;
    try testing.expectApproxEqAbs(want, padded.widthIncludingTrailingWhitespace - plain.widthIncludingTrailingWhitespace, 0.5);
    try testing.expectApproxEqAbs(want, with_pad - without, 0.5);
}

fn layoutSize(content: md.Inline, width: f32) DWRITE_TEXT_METRICS {
    const dwf = g_dwrite_factory.?;
    const lay = createLayout(vtable(IDWriteFactory_VTable, dwf), dwf, content, g_text_format.?, width).?;
    defer _ = vtable(IDWriteTextLayout_VTable, lay).Release(lay);
    // SAFETY: written by GetMetrics
    var m: DWRITE_TEXT_METRICS = undefined;
    _ = vtable(IDWriteTextLayout_VTable, lay).GetMetrics(lay, &m);
    return m;
}

test "an image scales down to the layout width and is hit like a character" {
    app.gpa = testing.allocator;
    app.images.init(testing.allocator, testing.io);
    app.images.reset("", false);
    defer app.images.clearAll();
    defer resetObjects();
    _ = CoInitializeEx(null, 0x2);
    initD2D();
    try app.images.injectReady("wide.png", 1000, 500);
    var doc = try md.parse(testing.allocator, "![w](wide.png) after");
    defer doc.deinit();
    const content = doc.blocks[0].content;

    const wide = layoutSize(content, 2000);
    try testing.expect(wide.width >= 1000 and wide.height >= 500);
    const narrow = layoutSize(content, 400);
    try testing.expect(narrow.width <= 400.5);
    try testing.expect(narrow.height >= 200 and narrow.height < 260);

    const hit: app.Hit = .{ .content = content, .x = 0, .y = 0, .w = 400, .h = narrow.height };
    const index = textIndexAt(hit, 100, 100) orelse return error.TestUnexpectedResult;
    try testing.expect(content.imageAt(index) != null);
}

test "a missing image lays out its alt text and a reference image resolves" {
    app.gpa = testing.allocator;
    app.images.init(testing.allocator, testing.io);
    app.images.reset("", false);
    defer app.images.clearAll();
    defer resetObjects();
    _ = CoInitializeEx(null, 0x2);
    initD2D();
    var doc = try md.parse(testing.allocator, "![a long alt text](gone.png)\n\n![ref image][r]\n\n[r]: gone.png");
    defer doc.deinit();
    try testing.expectEqualStrings("gone.png", doc.blocks[1].content.images[0].target);
    const deadline = app.images.now() + 5000;
    while (app.images.now() < deadline) {
        _ = app.images.tick();
        if (app.images.look("gone.png", 400) == .missing) break;
        std.Io.sleep(app.images.io, .fromMilliseconds(5), .awake) catch {};
    }
    try testing.expect(app.images.look("gone.png", 400) == .missing);
    const alt = layoutSize(doc.blocks[0].content, 400);
    const plain = layoutSize(.{ .text = "a long alt text" }, 400);
    try testing.expectApproxEqAbs(plain.width, alt.width, 2);
    try testing.expectApproxEqAbs(plain.height, alt.height, 2);
}

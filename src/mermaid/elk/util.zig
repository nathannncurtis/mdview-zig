const std = @import("std");
const lg = @import("lgraph.zig");

// java.lang.Double.doubleToLongBits (canonical NaN)
pub fn doubleToLongBits(v: f64) i64 {
    if (std.math.isNan(v)) return 0x7ff8000000000000;
    return @bitCast(v);
}

// java.lang.Double.compare: -0.0 < 0.0, NaN above everything
pub fn doubleCompare(a: f64, b: f64) std.math.Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    return std.math.order(doubleToLongBits(a), doubleToLongBits(b));
}

const neg_zero_bits: u64 = 0x8000000000000000;

// java.lang.Math.min(double, double)
pub fn javaMin(a: f64, b: f64) f64 {
    if (a != a) return a;
    if (a == 0 and b == 0 and @as(u64, @bitCast(b)) == neg_zero_bits) return b;
    return if (a <= b) a else b;
}

// java.lang.Math.max(double, double)
pub fn javaMax(a: f64, b: f64) f64 {
    if (a != a) return a;
    if (a == 0 and b == 0 and @as(u64, @bitCast(a)) == neg_zero_bits) return b;
    return if (a >= b) a else b;
}

// elkjs (GWT) never narrows Java floats
pub fn toFloat(x: f64) f64 {
    return x;
}

// GWT java.util.Arrays.mergeSort as compiled into elkjs (Collections.sort, List.sort, Arrays.sort(Object[])).
// The exact sequence of compare calls matters for ELK's stateful model-order comparators.
pub fn javaSort(comptime T: type, a: std.mem.Allocator, items: []T, ctx: anytype, comptime cmp: fn (@TypeOf(ctx), T, T) lg.Error!i32) lg.Error!void {
    if (items.len < 2) return;
    const temp = try a.dupe(T, items);
    defer a.free(temp);
    try gwtMergeSort(T, temp, items, 0, items.len, ctx, cmp);
}

fn gwtMergeSort(comptime T: type, temp: []T, array: []T, low_in: usize, high: usize, ctx: anytype, comptime cmp: fn (@TypeOf(ctx), T, T) lg.Error!i32) lg.Error!void {
    var low = low_in;
    if (high - low < 7) {
        var i = low + 1;
        while (i < high) : (i += 1) {
            var j = i;
            while (j > low and try cmp(ctx, array[j - 1], array[j]) > 0) : (j -= 1) {
                const t = array[j];
                array[j] = array[j - 1];
                array[j - 1] = t;
            }
        }
        return;
    }
    var temp_low = low;
    const temp_mid = low + ((high - low) >> 1);
    try gwtMergeSort(T, array, temp, low, temp_mid, ctx, cmp);
    try gwtMergeSort(T, array, temp, temp_mid, high, ctx, cmp);
    if (try cmp(ctx, temp[temp_mid - 1], temp[temp_mid]) <= 0) {
        while (low < high) : (low += 1) {
            array[low] = temp[temp_low];
            temp_low += 1;
        }
        return;
    }
    var top = temp_mid;
    while (low < high) : (low += 1) {
        if (top >= high or (temp_low < temp_mid and try cmp(ctx, temp[temp_low], temp[top]) <= 0)) {
            array[low] = temp[temp_low];
            temp_low += 1;
        } else {
            array[low] = temp[top];
            top += 1;
        }
    }
}

// java.util.Random.next(bits) on lg.JavaRandom's state
pub fn randNext(r: *lg.JavaRandom, bits: u6) i32 {
    return r.next(bits);
}

// Random.nextFloat; elkjs (GWT) keeps floats in double precision
pub fn randNextFloat(r: *lg.JavaRandom) f64 {
    return @as(f64, @floatFromInt(randNext(r, 24))) / 16777216.0;
}

pub fn randNextLong(r: *lg.JavaRandom) i64 {
    const hi: i64 = randNext(r, 32);
    const lo: i64 = randNext(r, 32);
    return (hi << 32) +% lo;
}

// InternalProperties.RANDOM of a graph, created on first use as GraphConfigurator does (new Random(randomSeed))
pub fn graphRandom(g: *lg.LGraph) lg.Error!*lg.JavaRandom {
    if (g.p.random) |r| return r;
    const r = try g.a.create(lg.JavaRandom);
    r.* = lg.JavaRandom.init(g.p.random_seed);
    g.p.random = r;
    return r;
}

// V8's Math.log (fdlibm e_log.c); elkjs results come from it and std's @log differs in the last bit
pub fn fdlibmLog(x_in: f64) f64 {
    const ln2_hi = 6.93147180369123816490e-01;
    const ln2_lo = 1.90821492927058770002e-10;
    const two54 = 1.80143985094819840000e+16;
    const lg1 = 6.666666666666735130e-01;
    const lg2 = 3.999999999940941908e-01;
    const lg3 = 2.857142874366239149e-01;
    const lg4 = 2.222219843214978396e-01;
    const lg5 = 1.818357216161805012e-01;
    const lg6 = 1.531383769920937332e-01;
    const lg7 = 1.479819860511658591e-01;
    var x = x_in;
    var bits: u64 = @bitCast(x);
    var hx: i32 = @bitCast(@as(u32, @truncate(bits >> 32)));
    const lx: u32 = @truncate(bits);
    var k: i32 = 0;
    if (hx < 0x00100000) {
        if (((hx & 0x7fffffff) | @as(i32, @bitCast(lx))) == 0) return -std.math.inf(f64);
        if (hx < 0) return std.math.nan(f64);
        k -= 54;
        x *= two54;
        bits = @bitCast(x);
        hx = @bitCast(@as(u32, @truncate(bits >> 32)));
    }
    if (hx >= 0x7ff00000) return x + x;
    k += (hx >> 20) - 1023;
    hx &= 0x000fffff;
    var i: i32 = (hx + 0x95f64) & 0x100000;
    bits = @bitCast(x);
    const new_hi: u32 = @bitCast(hx | (i ^ 0x3ff00000));
    x = @bitCast((@as(u64, new_hi) << 32) | (bits & 0xffffffff));
    k += i >> 20;
    const f = x - 1.0;
    const dk: f64 = @floatFromInt(k);
    if ((0x000fffff & (2 + hx)) < 3) {
        if (f == 0) return if (k == 0) 0 else dk * ln2_hi + dk * ln2_lo;
        const r = f * f * (0.5 - 0.33333333333333333 * f);
        return if (k == 0) f - r else dk * ln2_hi - ((r - dk * ln2_lo) - f);
    }
    const s = f / (2.0 + f);
    const z = s * s;
    i = hx - 0x6147a;
    const w = z * z;
    const j = 0x6b851 - hx;
    const t1 = w * (lg2 + w * (lg4 + w * lg6));
    const t2 = z * (lg1 + w * (lg3 + w * (lg5 + w * lg7)));
    i |= j;
    const r = t2 + t1;
    if (i > 0) {
        const hfsq = 0.5 * f * f;
        return if (k == 0) f - (hfsq - s * (hfsq + r)) else dk * ln2_hi - ((hfsq - (s * (hfsq + r) + dk * ln2_lo)) - f);
    }
    return if (k == 0) f - s * (f - r) else dk * ln2_hi - ((s * (f - r) - dk * ln2_lo) - f);
}

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
    r.seed = (r.seed *% 0x5DEECE66D +% 0xB) & ((@as(u64, 1) << 48) - 1);
    return @bitCast(@as(u32, @truncate(r.seed >> @intCast(48 - @as(u7, bits)))));
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

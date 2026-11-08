const std = @import("std");
const lg = @import("../../lgraph.zig");

// BinaryIndexedTree; out-of-range indices are ignored instead of throwing
pub const BinaryIndexedTree = struct {
    binary_sums: []i32,
    nums_per_index: []i32,
    size: i32 = 0,

    pub fn init(a: std.mem.Allocator, max_num: usize) lg.Error!BinaryIndexedTree {
        const sums = try a.alloc(i32, max_num + 1);
        @memset(sums, 0);
        const nums = try a.alloc(i32, max_num);
        @memset(nums, 0);
        return .{ .binary_sums = sums, .nums_per_index = nums };
    }

    pub fn add(self: *BinaryIndexedTree, index: i32) void {
        if (index < 0 or index >= self.nums_per_index.len) return;
        self.size += 1;
        self.nums_per_index[@intCast(index)] += 1;
        var i: usize = @as(usize, @intCast(index)) + 1;
        while (i < self.binary_sums.len) {
            self.binary_sums[i] += 1;
            i += i & (~i +% 1);
        }
    }

    pub fn rank(self: *const BinaryIndexedTree, index: i32) i32 {
        var i: usize = @intCast(@max(0, @min(index, @as(i32, @intCast(self.binary_sums.len - 1)))));
        var sum: i32 = 0;
        while (i > 0) {
            sum += self.binary_sums[i];
            i -= i & (~i +% 1);
        }
        return sum;
    }

    pub fn removeAll(self: *BinaryIndexedTree, index: i32) void {
        if (index < 0 or index >= self.nums_per_index.len) return;
        const num_entries = self.nums_per_index[@intCast(index)];
        if (num_entries == 0) return;
        self.nums_per_index[@intCast(index)] = 0;
        self.size -= num_entries;
        var i: usize = @as(usize, @intCast(index)) + 1;
        while (i < self.binary_sums.len) {
            self.binary_sums[i] -= num_entries;
            i += i & (~i +% 1);
        }
    }

    pub fn clear(self: *BinaryIndexedTree) void {
        @memset(self.binary_sums, 0);
        @memset(self.nums_per_index, 0);
        self.size = 0;
    }

    pub fn isEmpty(self: *const BinaryIndexedTree) bool {
        return self.size == 0;
    }
};

const std = @import("std");
const unicode = @import("unicode.zig");

const isLetter = unicode.isLetter;
const isMark = unicode.isMark;
const isNumber = unicode.isNumber;
const isSpace = unicode.isSpace;
const isPunctuation = unicode.isPunctuation;
const isWhitespace = unicode.isWhitespace;
const lower = unicode.lower;
const fold = unicode.fold;

test "properties used by the parsers" {
    try std.testing.expect(isLetter('a') and isLetter(0xE9) and isLetter(0x4E2D));
    try std.testing.expect(isMark(0x301) and isNumber('7') and isNumber(0x0663));
    try std.testing.expect(isPunctuation('!') and isPunctuation('$') and isPunctuation(0x2014) and isPunctuation(0x20AC));
    try std.testing.expect(!isPunctuation('a') and !isPunctuation(' ') and !isPunctuation(0xE9));
    try std.testing.expect(isWhitespace(' ') and isWhitespace('\t') and isWhitespace(0xA0) and isWhitespace(0x3000));
    try std.testing.expect(!isWhitespace('a') and !isWhitespace(0x2028) and isSpace(0x2028));
    var out: [unicode.max_mapping_len]u21 = undefined;
    try std.testing.expectEqual(@as(usize, 1), lower('A', &out));
    try std.testing.expectEqual(@as(u21, 'a'), out[0]);
    try std.testing.expectEqual(@as(usize, 2), lower(0x130, &out));
    try std.testing.expectEqual(@as(usize, 2), fold(0xDF, &out));
    try std.testing.expectEqual(@as(u21, 's'), out[1]);
}

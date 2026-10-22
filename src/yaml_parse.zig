const std = @import("std");
const Allocator = std.mem.Allocator;
const scan = @import("yaml_scan.zig");
const Scanner = scan.Scanner;
const Mark = scan.Mark;
const Fail = scan.Fail;

pub const EventKind = enum {
    stream_start,
    stream_end,
    document_start,
    document_end,
    alias,
    scalar,
    sequence_start,
    sequence_end,
    mapping_start,
    mapping_end,
};

pub const Event = struct {
    kind: EventKind,
    anchor: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    value: []const u8 = "",
    style: scan.ScalarStyle = .plain,
    plain_implicit: bool = false,
    quoted_implicit: bool = false,
};

const State = enum {
    stream_start,
    implicit_document_start,
    document_start,
    document_content,
    document_end,
    block_node,
    block_node_or_indentless_sequence,
    flow_node,
    block_sequence_first_entry,
    block_sequence_entry,
    indentless_sequence_entry,
    block_mapping_first_key,
    block_mapping_key,
    block_mapping_value,
    flow_sequence_first_entry,
    flow_sequence_entry,
    flow_sequence_entry_mapping_key,
    flow_sequence_entry_mapping_value,
    flow_sequence_entry_mapping_end,
    flow_mapping_first_key,
    flow_mapping_key,
    flow_mapping_value,
    flow_mapping_empty_value,
    end,
};

const TagDirective = struct { handle: []const u8, prefix: []const u8 };

pub const Parser = struct {
    sc: *Scanner,
    a: Allocator,
    state: State = .stream_start,
    states: std.ArrayList(State) = .empty,
    marks: std.ArrayList(Mark) = .empty,
    tag_directives: std.ArrayList(TagDirective) = .empty,

    fn parserError(p: *Parser, problem: []const u8) Fail {
        return p.sc.fail(problem, null, .{});
    }

    fn parserErrorContext(p: *Parser, context: []const u8, context_mark: Mark, problem: []const u8) Fail {
        return p.sc.fail(problem, context, context_mark);
    }

    pub fn next(p: *Parser) Fail!Event {
        if (p.state == .end) return .{ .kind = .stream_end };
        return p.stateMachine();
    }

    fn pop(p: *Parser) State {
        return p.states.pop().?;
    }

    fn stateMachine(p: *Parser) Fail!Event {
        return switch (p.state) {
            .stream_start => p.parseStreamStart(),
            .implicit_document_start => p.parseDocumentStart(true),
            .document_start => p.parseDocumentStart(false),
            .document_content => p.parseDocumentContent(),
            .document_end => p.parseDocumentEnd(),
            .block_node => p.parseNode(true, false),
            .block_node_or_indentless_sequence => p.parseNode(true, true),
            .flow_node => p.parseNode(false, false),
            .block_sequence_first_entry => p.parseBlockSequenceEntry(true),
            .block_sequence_entry => p.parseBlockSequenceEntry(false),
            .indentless_sequence_entry => p.parseIndentlessSequenceEntry(),
            .block_mapping_first_key => p.parseBlockMappingKey(true),
            .block_mapping_key => p.parseBlockMappingKey(false),
            .block_mapping_value => p.parseBlockMappingValue(),
            .flow_sequence_first_entry => p.parseFlowSequenceEntry(true),
            .flow_sequence_entry => p.parseFlowSequenceEntry(false),
            .flow_sequence_entry_mapping_key => p.parseFlowSequenceEntryMappingKey(),
            .flow_sequence_entry_mapping_value => p.parseFlowSequenceEntryMappingValue(),
            .flow_sequence_entry_mapping_end => p.parseFlowSequenceEntryMappingEnd(),
            .flow_mapping_first_key => p.parseFlowMappingKey(true),
            .flow_mapping_key => p.parseFlowMappingKey(false),
            .flow_mapping_value => p.parseFlowMappingValue(false),
            .flow_mapping_empty_value => p.parseFlowMappingValue(true),
            .end => .{ .kind = .stream_end },
        };
    }

    fn parseStreamStart(p: *Parser) Fail!Event {
        const t = try p.sc.peekToken();
        if (t.kind != .stream_start) return p.parserError("did not find expected <stream-start>");
        p.state = .implicit_document_start;
        p.sc.skipToken();
        return .{ .kind = .stream_start };
    }

    fn parseDocumentStart(p: *Parser, implicit: bool) Fail!Event {
        var t = try p.sc.peekToken();
        if (!implicit) {
            while (t.kind == .document_end) {
                p.sc.skipToken();
                t = try p.sc.peekToken();
            }
        }
        if (implicit and t.kind != .version_directive and t.kind != .tag_directive and t.kind != .document_start and t.kind != .stream_end) {
            try p.processDirectives();
            try p.states.append(p.a, .document_end);
            p.state = .block_node;
            return .{ .kind = .document_start };
        } else if (t.kind != .stream_end) {
            try p.processDirectives();
            t = try p.sc.peekToken();
            if (t.kind != .document_start) return p.parserError("did not find expected <document start>");
            try p.states.append(p.a, .document_end);
            p.state = .document_content;
            p.sc.skipToken();
            return .{ .kind = .document_start };
        } else {
            p.state = .end;
            p.sc.skipToken();
            return .{ .kind = .stream_end };
        }
    }

    fn processDirectives(p: *Parser) Fail!void {
        var have_version = false;
        var t = try p.sc.peekToken();
        while (t.kind == .version_directive or t.kind == .tag_directive) {
            if (t.kind == .version_directive) {
                if (have_version) return p.parserError("found duplicate %YAML directive");
                if (t.major != 1 or (t.minor != 1 and t.minor != 2)) return p.parserError("found incompatible YAML document");
                have_version = true;
            } else {
                try p.appendTagDirective(t.handle, t.value, false);
            }
            p.sc.skipToken();
            t = try p.sc.peekToken();
        }
        try p.appendTagDirective("!", "!", true);
        try p.appendTagDirective("!!", "tag:yaml.org,2002:", true);
    }

    fn appendTagDirective(p: *Parser, handle: []const u8, prefix: []const u8, allow_duplicates: bool) Fail!void {
        for (p.tag_directives.items) |d| {
            if (std.mem.eql(u8, d.handle, handle)) {
                if (allow_duplicates) return;
                return p.parserError("found duplicate %TAG directive");
            }
        }
        try p.tag_directives.append(p.a, .{ .handle = handle, .prefix = prefix });
    }

    fn parseDocumentContent(p: *Parser) Fail!Event {
        const t = try p.sc.peekToken();
        switch (t.kind) {
            .version_directive, .tag_directive, .document_start, .document_end, .stream_end => {
                p.state = p.pop();
                return emptyScalar();
            },
            else => return p.parseNode(true, false),
        }
    }

    fn parseDocumentEnd(p: *Parser) Fail!Event {
        const t = try p.sc.peekToken();
        if (t.kind == .document_end) p.sc.skipToken();
        p.tag_directives.clearRetainingCapacity();
        p.state = .document_start;
        return .{ .kind = .document_end };
    }

    fn emptyScalar() Event {
        return .{ .kind = .scalar, .value = "", .plain_implicit = true, .style = .plain };
    }

    fn parseNode(p: *Parser, block: bool, indentless_sequence: bool) Fail!Event {
        var t = try p.sc.peekToken();
        if (t.kind == .alias) {
            const ev: Event = .{ .kind = .alias, .anchor = t.value };
            p.state = p.pop();
            p.sc.skipToken();
            return ev;
        }
        var start_mark = t.start;
        var anchor: ?[]const u8 = null;
        var tag_handle: ?[]const u8 = null;
        var tag_suffix: []const u8 = "";
        if (t.kind == .anchor) {
            anchor = t.value;
            start_mark = t.start;
            p.sc.skipToken();
            t = try p.sc.peekToken();
            if (t.kind == .tag) {
                tag_handle = t.handle;
                tag_suffix = t.value;
                p.sc.skipToken();
                t = try p.sc.peekToken();
            }
        } else if (t.kind == .tag) {
            tag_handle = t.handle;
            tag_suffix = t.value;
            start_mark = t.start;
            p.sc.skipToken();
            t = try p.sc.peekToken();
            if (t.kind == .anchor) {
                anchor = t.value;
                p.sc.skipToken();
                t = try p.sc.peekToken();
            }
        }
        var tag: ?[]const u8 = null;
        if (tag_handle) |h| {
            if (h.len == 0) {
                tag = tag_suffix;
            } else {
                for (p.tag_directives.items) |d| {
                    if (std.mem.eql(u8, d.handle, h)) {
                        tag = try std.mem.concat(p.a, u8, &.{ d.prefix, tag_suffix });
                        break;
                    }
                }
                if (tag == null) return p.parserErrorContext("while parsing a node", start_mark, "found undefined tag handle");
            }
        }
        const implicit = tag == null or tag.?.len == 0;

        if (indentless_sequence and t.kind == .block_entry) {
            p.state = .indentless_sequence_entry;
            return .{ .kind = .sequence_start, .anchor = anchor, .tag = tag };
        }
        switch (t.kind) {
            .scalar => {
                var plain_implicit = false;
                var quoted_implicit = false;
                if ((t.style == .plain and tag == null) or (tag != null and std.mem.eql(u8, tag.?, "!"))) {
                    plain_implicit = true;
                } else if (tag == null) quoted_implicit = true;
                const ev: Event = .{ .kind = .scalar, .anchor = anchor, .tag = tag, .value = t.value, .style = t.style, .plain_implicit = plain_implicit, .quoted_implicit = quoted_implicit };
                p.state = p.pop();
                p.sc.skipToken();
                return ev;
            },
            .flow_sequence_start => {
                p.state = .flow_sequence_first_entry;
                return .{ .kind = .sequence_start, .anchor = anchor, .tag = tag };
            },
            .flow_mapping_start => {
                p.state = .flow_mapping_first_key;
                return .{ .kind = .mapping_start, .anchor = anchor, .tag = tag };
            },
            .block_sequence_start => if (block) {
                p.state = .block_sequence_first_entry;
                return .{ .kind = .sequence_start, .anchor = anchor, .tag = tag };
            },
            .block_mapping_start => if (block) {
                p.state = .block_mapping_first_key;
                return .{ .kind = .mapping_start, .anchor = anchor, .tag = tag };
            },
            else => {},
        }
        if (anchor != null or tag != null) {
            p.state = p.pop();
            return .{ .kind = .scalar, .anchor = anchor, .tag = tag, .value = "", .plain_implicit = implicit, .style = .plain };
        }
        return p.parserErrorContext(if (block) "while parsing a block node" else "while parsing a flow node", start_mark, "did not find expected node content");
    }

    fn parseBlockSequenceEntry(p: *Parser, first: bool) Fail!Event {
        if (first) {
            const t = try p.sc.peekToken();
            try p.marks.append(p.a, t.start);
            p.sc.skipToken();
        }
        const t = try p.sc.peekToken();
        if (t.kind == .block_entry) {
            p.sc.skipToken();
            const n = try p.sc.peekToken();
            if (n.kind != .block_entry and n.kind != .block_end) {
                try p.states.append(p.a, .block_sequence_entry);
                return p.parseNode(true, false);
            }
            p.state = .block_sequence_entry;
            return emptyScalar();
        } else if (t.kind == .block_end) {
            p.state = p.pop();
            _ = p.marks.pop();
            p.sc.skipToken();
            return .{ .kind = .sequence_end };
        }
        const m = p.marks.pop().?;
        return p.parserErrorContext("while parsing a block collection", m, "did not find expected '-' indicator");
    }

    fn parseIndentlessSequenceEntry(p: *Parser) Fail!Event {
        const t = try p.sc.peekToken();
        if (t.kind == .block_entry) {
            p.sc.skipToken();
            const n = try p.sc.peekToken();
            if (n.kind != .block_entry and n.kind != .key and n.kind != .value and n.kind != .block_end) {
                try p.states.append(p.a, .indentless_sequence_entry);
                return p.parseNode(true, false);
            }
            p.state = .indentless_sequence_entry;
            return emptyScalar();
        }
        p.state = p.pop();
        return .{ .kind = .sequence_end };
    }

    fn parseBlockMappingKey(p: *Parser, first: bool) Fail!Event {
        if (first) {
            const t = try p.sc.peekToken();
            try p.marks.append(p.a, t.start);
            p.sc.skipToken();
        }
        const t = try p.sc.peekToken();
        if (t.kind == .key) {
            p.sc.skipToken();
            const n = try p.sc.peekToken();
            if (n.kind != .key and n.kind != .value and n.kind != .block_end) {
                try p.states.append(p.a, .block_mapping_value);
                return p.parseNode(true, true);
            }
            p.state = .block_mapping_value;
            return emptyScalar();
        } else if (t.kind == .block_end) {
            p.state = p.pop();
            _ = p.marks.pop();
            p.sc.skipToken();
            return .{ .kind = .mapping_end };
        }
        const m = p.marks.pop().?;
        return p.parserErrorContext("while parsing a block mapping", m, "did not find expected key");
    }

    fn parseBlockMappingValue(p: *Parser) Fail!Event {
        const t = try p.sc.peekToken();
        if (t.kind == .value) {
            p.sc.skipToken();
            const n = try p.sc.peekToken();
            if (n.kind != .key and n.kind != .value and n.kind != .block_end) {
                try p.states.append(p.a, .block_mapping_key);
                return p.parseNode(true, true);
            }
            p.state = .block_mapping_key;
            return emptyScalar();
        }
        p.state = .block_mapping_key;
        return emptyScalar();
    }

    fn parseFlowSequenceEntry(p: *Parser, first: bool) Fail!Event {
        if (first) {
            const t = try p.sc.peekToken();
            try p.marks.append(p.a, t.start);
            p.sc.skipToken();
        }
        var t = try p.sc.peekToken();
        if (t.kind != .flow_sequence_end) {
            if (!first) {
                if (t.kind == .flow_entry) {
                    p.sc.skipToken();
                    t = try p.sc.peekToken();
                } else {
                    const m = p.marks.pop().?;
                    return p.parserErrorContext("while parsing a flow sequence", m, "did not find expected ',' or ']'");
                }
            }
            if (t.kind == .key) {
                p.state = .flow_sequence_entry_mapping_key;
                p.sc.skipToken();
                return .{ .kind = .mapping_start };
            } else if (t.kind != .flow_sequence_end) {
                try p.states.append(p.a, .flow_sequence_entry);
                return p.parseNode(false, false);
            }
        }
        p.state = p.pop();
        _ = p.marks.pop();
        p.sc.skipToken();
        return .{ .kind = .sequence_end };
    }

    fn parseFlowSequenceEntryMappingKey(p: *Parser) Fail!Event {
        const t = try p.sc.peekToken();
        if (t.kind != .value and t.kind != .flow_entry and t.kind != .flow_sequence_end) {
            try p.states.append(p.a, .flow_sequence_entry_mapping_value);
            return p.parseNode(false, false);
        }
        p.sc.skipToken();
        p.state = .flow_sequence_entry_mapping_value;
        return emptyScalar();
    }

    fn parseFlowSequenceEntryMappingValue(p: *Parser) Fail!Event {
        var t = try p.sc.peekToken();
        if (t.kind == .value) {
            p.sc.skipToken();
            t = try p.sc.peekToken();
            if (t.kind != .flow_entry and t.kind != .flow_sequence_end) {
                try p.states.append(p.a, .flow_sequence_entry_mapping_end);
                return p.parseNode(false, false);
            }
        }
        p.state = .flow_sequence_entry_mapping_end;
        return emptyScalar();
    }

    fn parseFlowSequenceEntryMappingEnd(p: *Parser) Fail!Event {
        _ = try p.sc.peekToken();
        p.state = .flow_sequence_entry;
        return .{ .kind = .mapping_end };
    }

    fn parseFlowMappingKey(p: *Parser, first: bool) Fail!Event {
        if (first) {
            const t = try p.sc.peekToken();
            try p.marks.append(p.a, t.start);
            p.sc.skipToken();
        }
        var t = try p.sc.peekToken();
        if (t.kind != .flow_mapping_end) {
            if (!first) {
                if (t.kind == .flow_entry) {
                    p.sc.skipToken();
                    t = try p.sc.peekToken();
                } else {
                    const m = p.marks.pop().?;
                    return p.parserErrorContext("while parsing a flow mapping", m, "did not find expected ',' or '}'");
                }
            }
            if (t.kind == .key) {
                p.sc.skipToken();
                t = try p.sc.peekToken();
                if (t.kind != .value and t.kind != .flow_entry and t.kind != .flow_mapping_end) {
                    try p.states.append(p.a, .flow_mapping_value);
                    return p.parseNode(false, false);
                }
                p.state = .flow_mapping_value;
                return emptyScalar();
            } else if (t.kind != .flow_mapping_end) {
                try p.states.append(p.a, .flow_mapping_empty_value);
                return p.parseNode(false, false);
            }
        }
        p.state = p.pop();
        _ = p.marks.pop();
        p.sc.skipToken();
        return .{ .kind = .mapping_end };
    }

    fn parseFlowMappingValue(p: *Parser, empty: bool) Fail!Event {
        var t = try p.sc.peekToken();
        if (empty) {
            p.state = .flow_mapping_key;
            return emptyScalar();
        }
        if (t.kind == .value) {
            p.sc.skipToken();
            t = try p.sc.peekToken();
            if (t.kind != .flow_entry and t.kind != .flow_mapping_end) {
                try p.states.append(p.a, .flow_mapping_key);
                return p.parseNode(false, false);
            }
        }
        p.state = .flow_mapping_key;
        return emptyScalar();
    }
};

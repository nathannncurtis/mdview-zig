const lg = @import("../../lgraph.zig");
const HyperEdgeSegment = @import("hyper_edge_segment.zig").HyperEdgeSegment;

pub const DependencyType = enum { regular, critical };

pub const critical_dependency_weight: i32 = 1;

pub const HyperEdgeSegmentDependency = struct {
    type: DependencyType,
    source: ?*HyperEdgeSegment = null,
    target: ?*HyperEdgeSegment = null,
    weight: i32,

    fn create(t: DependencyType, source: *HyperEdgeSegment, target: *HyperEdgeSegment, weight: i32) lg.Error!*HyperEdgeSegmentDependency {
        const d = try source.a.create(HyperEdgeSegmentDependency);
        d.* = .{ .type = t, .weight = weight };
        try d.setSource(source);
        try d.setTarget(target);
        return d;
    }

    pub fn createAndAddRegular(source: *HyperEdgeSegment, target: *HyperEdgeSegment, weight: i32) lg.Error!*HyperEdgeSegmentDependency {
        return create(.regular, source, target, weight);
    }

    pub fn createAndAddCritical(source: *HyperEdgeSegment, target: *HyperEdgeSegment) lg.Error!*HyperEdgeSegmentDependency {
        return create(.critical, source, target, critical_dependency_weight);
    }

    pub fn remove(self: *HyperEdgeSegmentDependency) lg.Error!void {
        try self.setSource(null);
        try self.setTarget(null);
    }

    pub fn reverse(self: *HyperEdgeSegmentDependency) lg.Error!void {
        const old_source = self.source;
        const old_target = self.target;
        try self.setSource(old_target);
        try self.setTarget(old_source);
    }

    pub fn setSource(self: *HyperEdgeSegmentDependency, new_source: ?*HyperEdgeSegment) lg.Error!void {
        if (self.source) |s| lg.removeItem(HyperEdgeSegmentDependency, &s.outgoing_segment_dependencies, self);
        self.source = new_source;
        if (new_source) |s| try s.outgoing_segment_dependencies.append(s.a, self);
    }

    pub fn setTarget(self: *HyperEdgeSegmentDependency, new_target: ?*HyperEdgeSegment) lg.Error!void {
        if (self.target) |t| lg.removeItem(HyperEdgeSegmentDependency, &t.incoming_segment_dependencies, self);
        self.target = new_target;
        if (new_target) |t| try t.incoming_segment_dependencies.append(t.a, self);
    }
};

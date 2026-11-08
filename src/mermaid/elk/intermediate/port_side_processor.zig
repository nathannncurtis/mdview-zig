const lg = @import("../lgraph.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    for (g.layerless_nodes.items) |node| processNode(node);
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| processNode(node);
    }
}

fn processNode(node: *lg.LNode) void {
    if (node.p.port_constraints.isSideFixed()) {
        for (node.ports.items) |port| {
            if (port.side == .undefined) setPortSide(port);
        }
    } else {
        for (node.ports.items) |port| setPortSide(port);
        node.p.port_constraints = .fixed_side;
    }
}

pub fn setPortSide(port: *lg.LPort) void {
    if (port.p.port_dummy) |dummy| {
        port.setSide(dummy.p.ext_port_side);
    } else if (port.netFlow() > 0) {
        port.setSide(.east);
    } else {
        port.setSide(.west);
    }
}

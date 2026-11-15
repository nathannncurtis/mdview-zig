pub const OrderWeighting = enum { model_order, descendants, fan, constraint };

pub const TreeifyingOrder = enum { dfs, bfs };

pub const EdgeRoutingMode = enum { none, middle_to_middle, avoid_overlap };

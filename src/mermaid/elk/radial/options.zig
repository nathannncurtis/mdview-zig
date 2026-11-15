pub const CompactionStrategy = enum { none, radial_compaction, wedge_compaction };
pub const SortingStrategy = enum { none, polar_coordinate, id };
pub const AnnulusWedgeCriteria = enum { leaf_number, node_size };
pub const RadialTranslationStrategy = enum { none, edge_length, edge_length_by_position, crossing_minimization_by_position };

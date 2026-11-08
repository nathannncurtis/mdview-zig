# dagre parity fixtures

Graph-in, positions-out JSON made once by running dagre-d3-es 7.0.14 (the dagre build mermaid 11.16.1 pins) on Node 24.

Command: `npm i dagre-d3-es@7.0.14`, then a script that builds each case with `new Graph({ multigraph: true, compound: true })`,
`setGraph`, `setNode` for every node, `setParent` for every node with a parent, `setEdge` for every edge, calls
`layout(g)` from `dagre-d3-es/src/dagre/index.js`, and writes the node x/y (width/height for compound nodes),
every edge's points and label x/y, and the graph width/height, rounded to 3 decimals.
Random cases use a mulberry32 generator with fixed seeds.

Files: `dag`, `cyclic`, `compound`, `labels`, `dirs` (every rankdir and ranker, plus lower-case rankdir values and every `align`),
`special`, `large` (500 edges) hold 242 graphs. `crash.json` holds inputs that make dagre-d3-es throw (compound graphs with the
`tight-tree` or `longest-path` ranker); the port must return an error for them.

# ELK layout fixtures

Each `<name>.json` holds `{name, source, input, output}`:

- `source`: the Mermaid source, with `layout: elk` in its front matter.
- `input`: the ELK graph Mermaid 12.2.0's `layout: elk` hands to elkjs, trimmed to the fields ELK reads (`id`, `width`, `height`, `layoutOptions`, `labels`, `children`, `edges` with `sources`, `targets` and `labels`).
- `output`: what elkjs 0.9.3 returned for it: `x`, `y`, `width`, `height` of every node and label (relative to the parent), edge `sections` (`startPoint`, `bendPoints`, `endPoint`).

`input` is taken from Mermaid itself, so the options and sizes are exactly what GitHub's frame produces (Chromium with Trebuchet MS for the label sizes), including the subgraph handling in `render.ts`.

## How it was made

In an empty scratch folder:

```
npm install --legacy-peer-deps mermaid@12.2.0 playwright@1.58.0
```

`@mermaid-js/layout-elk` is not needed: 12.2.0 bundles the ELK layout (`dist/chunks/mermaid.esm/elk-*.mjs`) and imports `elkjs@0.9.3`. The elk chunk is edited in one place, the line `graph = await elk.layout(elkGraph);` becomes

```
{ const __in = JSON.parse(JSON.stringify(elkGraph)); graph = await elk.layout(elkGraph); (globalThis.__elkcap ??= []).push({ input: __in, output: JSON.parse(JSON.stringify(graph)) }); }
```

so every call is recorded. A small Playwright script (headless Chromium, dark colour scheme, GitHub's frame configuration from `testdata/mermaid/README.md`) loads `mermaid.esm.mjs`, runs `mermaid.render` for each source, and reads `globalThis.__elkcap`. The recorded `input` and `output` are then reduced to the fields listed above.

The sources are 101 generated graphs (seeded: DAGs, cycles, subgraphs with and without their own direction, edge labels, multi-edges, self loops, every direction, four graphs of 500 edges) and 218 flowchart cases of the harness corpus (the inputs of `testdata/mermaid/cases` that render) with `layout: elk` prepended (every shape, label and link type).

ELK Java 0.9.1 (tag v0.9.1 of eclipse/elk) is the version elkjs 0.9.3 is built from. GitHub's ELK chunk contains the same set of option ids as elkjs 0.9.3.

## e2e/cases.json

216 flowchart cases from `testdata/mermaid/refs` (the default ELK path of 12.2.0). Each holds the layout input as Mermaid's renderer builds it (nodes in layout order with parent, group flag, shape, measured size or group title size, subgraph direction; edges with start, end, label size and arrow types) and what the reference SVG shows (node translates, cluster rects, edge `data-points`, edge label centres). The input comes from the same capture run as the fixtures above (the recorded `elkGraph` before it is trimmed), the expected values are read from the reference SVGs by a scratch Node script. `src/mermaid/elk/e2e_test.zig` runs `mermaid.layout` on each case and compares.

## Node placement fixtures (`plc-*`)

`plc-<strategy>--<base>` takes the `input` of one of 13 existing fixtures (`syn-005-dag-TD`, `syn-017-dag-RL`, `syn-021-cyc-TB`, `syn-030-cyc-LR`, `syn-036-sub-TB`, `syn-044-sub-BT`, `syn-048-sub-LR`, `syn-062-multi`, `syn-098-subedge`, `c-flow-001-dir-tb`, `c-flow-116-link-self`, `c-flow-143-sub-basic`, `c-flow-241-decision-flow`), sets `elk.layered.nodePlacement.strategy` to `SIMPLE`, `LINEAR_SEGMENTS` or `NETWORK_SIMPLEX` on the root and on every subgraph (the way Mermaid's `elk.nodePlacementStrategy` does), and stores what elkjs 0.9.3 returns. `plc-bk-<alignment>--<base>` does the same with `BRANDES_KOEPF` and `elk.layered.nodePlacement.bk.fixedAlignment` set to `NONE`, `LEFTUP`, `LEFTDOWN`, `RIGHTUP`, `RIGHTDOWN` or `BALANCED` for `syn-005-dag-TD`, `syn-036-sub-TB` and `syn-030-cyc-LR`. `plc-genNN-<strategy>` are ten seeded graphs of 30 to 60 nodes (two to four subgraphs, some nested, labelled and unlabelled edges, self loops, multi-edges, all four directions) laid out under each of the three strategies; the root and subgraph options are copied from `syn-036-sub-TB`.

The generator is a small Node script that loads `elkjs@0.9.3` (`lib/elk.bundled.js`), edits the options, calls `elk.layout` and writes `{name, source: "", input, output}`; the random graphs use mulberry32 seeded with `9100 + NN`.


## lay-*.json

Layering strategy fixtures. `lay-<variant>--<base>.json` takes the `input` of an existing fixture, sets the root `elk.layered.layering.strategy` (variants: `longest` LONGEST_PATH, `longestsrc` LONGEST_PATH_SOURCE, `coffman4` / `coffman2` COFFMAN_GRAHAM with `coffmanGraham.layerBound` 4 / 2, `minwidth` MIN_WIDTH, `stretch` STRETCH_WIDTH, `interactive` INTERACTIVE) and stores what elkjs 0.9.3 returns. `lay-stretch--syn-036-sub-TB`, `--syn-048-sub-LR` and `--c-flow-143-sub-basic` are absent: elkjs never returns for them (StretchWidthLayerer loops forever on a nested graph whose edges all enter from hidden nodes).

`--big-NN` are ten seeded random graphs of 30 to 42 nodes (varied node heights, a few edge labels, some back edges on every third graph, directions DOWN, RIGHT, UP, LEFT in turn), with variants `coffman4`, `minwidth`, `stretch`, `minwidthmulti` (MIN_WIDTH with `minWidth.upperBoundOnWidth` and `upperLayerEstimationScalingFactor` both -1) and `interactive-pos` (INTERACTIVE with random node x/y in the input).

Each file is produced by running `elk.layout` of elkjs 0.9.3 on the modified `input` in Node.

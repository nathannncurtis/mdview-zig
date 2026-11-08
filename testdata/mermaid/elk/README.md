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

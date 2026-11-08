# Mermaid core reference data

Everything here was produced once with Mermaid 12.2.0, the version GitHub's Mermaid frame runs, and is only read by the tests in `src/mermaid`.
Chromium was the headless build that Puppeteer installs; nothing from Node is committed.

## `info/*.svg`

Written by the page script that repeats what GitHub's frame does, in headless Chromium with `mermaid@12.2.0`'s `dist/mermaid.min.js`:

```
mermaid.initialize({ startOnLoad: false, secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize'], securityLevel: 'antiscript', flowchart: { diagramPadding: 48 }, gantt: { useWidth: 1200 }, pie: { useWidth: 1200 }, sequence: { diagramMarginY: 40 }, theme: 'dark' })
const x = await mermaid.render('diagram', source, templateDiv)   // templateDiv: a div attached to the page
new XMLSerializer().serializeToString(holder.firstElementChild)   // holder.innerHTML = x.svg
```

The frame's own additions (`preserveAspectRatio`, a `height` attribute, `target="_parent"` on links) are not part of core output and are not in these files.

## `config/`

`config_defaults.json`: `mermaid.mermaidAPI.defaultConfig` from the same bundle, serialised with `JSON.stringify` (functions and `undefined` dropped) and without `themeVariables`.
`config_keys.json` is the sorted set of names `keyify(defaultConfig)` returns, which is what directives are checked against.

## `preprocess/`

`errors.json`: each source rendered with the script above; `ok: true` means it rendered, otherwise `message` is the exception's message.
`yaml_scalars.json`: `yaml.load('v: ' + scalar, { schema: yaml.JSON_SCHEMA })` with `js-yaml@4.1.0`, the type and `String(value)` of each scalar.

## `theme/vars_expected.json`

`getThemeVariables(overrides)` from `packages/mermaid/src/themes/theme-*.js` at the 12.2.0 tag (all eleven themes), run in Node with `khroma@2.1.0`, for eleven override sets per theme including nested `xyChart`, `radar`, `packet`, `cynefin` and `wardley` objects, flattened to dotted keys.
Case 0 of each theme is listed in full; the other cases list what differs from it.

## `unicode/`

`GraphemeBreakTest.txt` and `WordBreakTest.txt` from `https://www.unicode.org/Public/17.0.0/ucd/auxiliary/`, with the trailing comments removed.
`src/mermaid/segment_data.zig` is generated from the 17.0.0 property files by `tools/gen_segment.zig`.

## Regenerating the tables

```
zig build gen-mermaid-config -- config.schema.yaml src/mermaid/config_defaults.zig
zig build gen-segment -- GraphemeBreakProperty.txt WordBreakProperty.txt emoji-data.txt DerivedCoreProperties.txt src/mermaid/segment_data.zig
```

with `config.schema.yaml` from `packages/mermaid/src/schemas/` at the 12.2.0 tag. The `mermaid-data` workflow does this from pinned downloads and fails when the committed files differ.

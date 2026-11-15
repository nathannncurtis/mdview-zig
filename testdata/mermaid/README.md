# Mermaid reference data

Reference output for the Mermaid port, made once with Mermaid 12.2.0 in the same configuration GitHub uses for its Mermaid frame (viewscreen.githubusercontent.com, dark colour mode). Compared by `zig build mermaid-compare` (tools/mermaid_compare.zig).

- `cases/*.mmd`: inputs. `flow-*` flowcharts, `seq-*` sequence diagrams. Every case renders without error.
- `refs/<case>.svg`: the SVG GitHub's page would hold, serialised as XML. `refs/<case>.png`: the same SVG at natural size, transparent background, 1x.
- `refs/<case>.labels.json` (flowcharts): label id (node id, or edge `data-id`) to the measured size of the label's text, taken from the text node's client rects. Node labels in the SVG are clamped to 120 px wide, so this is the true text width. `ReplayMeasurer` uses it when present.
- `errors.txt`: broken inputs with the exact message GitHub shows under "Unable to render rich display". Format per record: `#### name`, the source, a line `#---`, the message. Sources end in a newline, as GitHub passes them.
- `GITHUB_FACTS.md`: what was observed on github.com, with the URLs.

## How it was made

Mermaid-cli 11.16.1 does not exist on npm and GitHub no longer runs 11.16.1 (its bundle calls `renderer.draw(..., "12.2.0")`). mermaid-cli itself also injects Font Awesome, Open Sans, Recursive and KaTeX CSS that GitHub's frame does not load, so it was not used for the references.

In a scratch folder (not committed):

```
npm install @mermaid-js/mermaid-cli@12.2.0 puppeteer@24.10.0 playwright --legacy-peer-deps   # package.json override: "mermaid": "12.2.0"
```

A small Node script then drives headless Chromium (Playwright's bundled build, `colorScheme: dark`, 4000x3000 viewport, Trebuchet MS installed from Windows) and, per case, repeats what GitHub's frame script does:

1. `mermaid.initialize({startOnLoad:false, secure:["secure","securityLevel","startOnLoad","maxTextSize"], securityLevel:"antiscript", flowchart:{diagramPadding:48}, gantt:{useWidth:1200}, pie:{useWidth:1200}, sequence:{diagramMarginY:40}, theme:"dark", handDrawnSeed:1})`. `handDrawnSeed:1` is the only addition: it makes the roughjs shapes of the default look repeatable (GitHub leaves it random).
2. `mermaid.render("diagram", source, template)` where `template` is a `div` with `min-width:1600px`.
3. DOMPurify with GitHub's allowed-tag list and `RETURN_DOM_FRAGMENT`, `preserveAspectRatio="xMinYMin"`, a `height` attribute from the viewBox, `target="_parent"` on links. Output is serialised with `XMLSerializer`. With HTML serialisation the SVGs were byte-identical to the DOM of eight GitHub diagrams checked (including ELK ones).
4. PNG: element screenshot of the SVG at its natural size, animations disabled, background omitted.
5. On a thrown error the message is written to `errors.txt` (these are GitHub's `reportError` text without the trailing docs link).

Sequence diagram ids such as `actor2` come from a counter that lives for the whole page, so they depend on how many diagrams were rendered before; render in one fixed order. Repeating the run gives byte-identical SVGs. PNGs agree to within a handful of anti-aliased pixels (two of 373 differed by up to 64 levels on 10 pixels between two runs), which the pixel tolerance absorbs.

## Using it

```
zig build mermaid-compare -- check
zig build mermaid-compare -- layout <dir with <case>.svg>
zig build mermaid-compare -- pixels <dir with <case>.png>
zig build mermaid-compare -- errors <file in errors.txt format>
zig build mermaid-compare -- labels <case>
```

Layout parity uses the replay measurer (`ReplayMeasurer` in the tool): label sizes come from the reference `foreignObject` sizes, so fonts are out of the picture. Node boxes and translates must agree within 0.5 px, edge points within 1 px, viewBox within 1 px. Pixel parity composites over the GitHub dark page colour, 16 levels per channel, at most 1% of pixels may differ.

# Mermaid core reference data (src/mermaid core, config, themes, info)

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
`src/mermaid/segment_data.zig` is generated from the 17.0.0 property files by `tools/gen/gen_segment.zig`.

## Regenerating the tables

```
zig build gen-mermaid-config -- config.schema.yaml src/mermaid/config_defaults.zig
zig build gen-segment -- GraphemeBreakProperty.txt WordBreakProperty.txt emoji-data.txt DerivedCoreProperties.txt src/mermaid/segment_data.zig
```

with `config.schema.yaml` from `packages/mermaid/src/schemas/` at the 12.2.0 tag. The `mermaid-data` workflow does this from pinned downloads and fails when the committed files differ.

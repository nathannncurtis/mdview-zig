# Mermaid reference data

Reference output for the Mermaid port, made once with Mermaid 12.2.0 in the same configuration GitHub uses for its Mermaid frame (viewscreen.githubusercontent.com, dark colour mode). Compared by `zig build mermaid-compare` (tools/mermaid_compare.zig).

- `cases/*.mmd`: inputs. `flow-*` flowcharts, `seq-*` sequence diagrams. Every case renders without error.
- `refs/<case>.svg`: the SVG GitHub's page would hold, serialised as XML. `refs/<case>.png`: the same SVG at natural size, transparent background, 1x.
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

Repeating the run gives byte-identical SVGs. PNGs agree to within a handful of anti-aliased pixels (two of 373 differed by up to 64 levels on 10 pixels between two runs), which the pixel tolerance absorbs.

## Using it

```
zig build mermaid-compare -- check
zig build mermaid-compare -- layout <dir with <case>.svg>
zig build mermaid-compare -- pixels <dir with <case>.png>
zig build mermaid-compare -- errors <file in errors.txt format>
zig build mermaid-compare -- labels <case>
```

Layout parity uses the replay measurer (`ReplayMeasurer` in the tool): label sizes come from the reference `foreignObject` sizes, so fonts are out of the picture. Node boxes and translates must agree within 0.5 px, edge points within 1 px, viewBox within 1 px. Pixel parity composites over the GitHub dark page colour, 16 levels per channel, at most 1% of pixels may differ.

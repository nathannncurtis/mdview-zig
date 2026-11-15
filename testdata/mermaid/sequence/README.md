# Sequence diagram data beyond the harness references

The 122 inputs (`../cases/seq-*.mmd`) and dark-theme references (`../refs/seq-*.svg`) are the harness's. This folder holds what the sequence parity test adds on top:

- `manifest.txt`: the case names the dark run walks.
- `measures.json`: the replay measurer's table. The harness's reference script was re-run with `SVGGraphicsElement.prototype.getBBox` wrapped, recording every `<text>` measurement as `[computed font-family, font-size, font-weight, text] -> width, height`. The SVGs it produced were byte-identical to `../refs`, so the table describes exactly those references.
- `themes.json`: the theme variables the sequence stylesheet and actor shapes read (`actorBorder`, `actorBkg`, `dropShadow`, ...) for `dark`, `default`, `forest`, `neutral` and `base`, taken from `mermaid.mermaidAPI.getConfig().themeVariables` in the same run.
- `refs_default`, `refs_forest`, `refs_neutral`: the first 38 cases rendered with the same script and `theme` changed. `themes_manifest.txt` lists them.

Made with mermaid 12.2.0 in the harness's configuration (see `../README.md`), once, in a scratch folder with `puppeteer-core` driving the Chromium that ships with Playwright. No JavaScript is committed.

## `extra/`

Cases the harness does not have, each with its reference `<case>.svg`, listed in `extra/manifest.txt`: math (`math-*`), math participant edge cases (`edge-*`), themes with every participant type (`theme-*`) and sanitizer inputs (`san-*`).

The references come from the same Mermaid 12.2.0 configuration as the harness (`../../README.md`), run once per case in a fresh page, then through the frame's DOMPurify call (its allow list of tags, `RETURN_DOM_FRAGMENT`, `HTML_INTEGRATION_POINTS: {foreignobject: true}`) with the `height` and `preserveAspectRatio` attributes and `target="_parent"` on links the frame adds. `measures.json` holds the numbers the replay measurer needs for them: the text sizes (`text`, same key as `../measures.json`), `calc` (what `calculateMathMLDimensions` returned, whole pixels) and `rect` (what `drawKatex` measured inside the SVG), both keyed by the label. Those two were recorded by wrapping the two functions in the page.

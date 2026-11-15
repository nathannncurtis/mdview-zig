# Sequence diagram data beyond the harness references

The 122 inputs (`../cases/seq-*.mmd`) and dark-theme references (`../refs/seq-*.svg`) are the harness's. This folder holds what the sequence parity test adds on top:

- `manifest.txt`: the case names the dark run walks.
- `measures.json`: the replay measurer's table. The harness's reference script was re-run with `SVGGraphicsElement.prototype.getBBox` wrapped, recording every `<text>` measurement as `[computed font-family, font-size, font-weight, text] -> width, height`. The SVGs it produced were byte-identical to `../refs`, so the table describes exactly those references.
- `themes.json`: the theme variables the sequence stylesheet and actor shapes read (`actorBorder`, `actorBkg`, `dropShadow`, ...) for `dark`, `default`, `forest`, `neutral` and `base`, taken from `mermaid.mermaidAPI.getConfig().themeVariables` in the same run.
- `refs_default`, `refs_forest`, `refs_neutral`: the first 38 cases rendered with the same script and `theme` changed. `themes_manifest.txt` lists them.

Made with mermaid 12.2.0 in the harness's configuration (see `../README.md`), once, in a scratch folder with `puppeteer-core` driving the Chromium that ships with Playwright. No JavaScript is committed.

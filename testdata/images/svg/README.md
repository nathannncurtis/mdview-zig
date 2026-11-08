# SVG test fixtures

`render_test.zig` renders each `*.svg` here with `svg.render` at the size listed in the test and compares it with the matching `*.rgba` file.

## Reference files

Each `*.rgba` is the raw straight (non-premultiplied) RGBA8 pixel data, row by row, of the same SVG rendered by headless Chromium at the same pixel size, on a transparent background. Nothing else is stored: no header, no PNG.

How they were made (the scripts are not part of the repo):

- Headless Chromium (the build bundled with Playwright), device scale factor 1, element screenshot with the page background omitted.
- SVGs without text were loaded as an `<img>` of the target size, which is how GitHub shows them: no scripts, no external resources.
- SVGs with text were placed inline in a page, because an image cannot use fonts the page loads. The page declared `@font-face` rules for the family names the fixtures use (`DejaVu Sans`, `Verdana`, `Geneva`, `Segoe UI`, `Ubuntu`, `Helvetica Neue`, `Arial`, `DejaVu Sans Mono`, `DejaVu Serif`, `Georgia`) pointing at the same DejaVu 2.37 glyphs the renderer embeds, so both sides draw the same outlines.
- The `card.svg` reference was taken after its CSS animations finished.

The comparison is on premultiplied channels. A fixture passes when the mean absolute error and the share of pixels with an error above 40/255 are under the limits in `render_test.zig`. Text fixtures have higher limits because Chromium's glyph rasterizer applies a contrast boost and vertical hinting that the renderer does not.

## Fixtures

| File | What it covers |
| --- | --- |
| `shapes.svg` | rect, rounded rect, circle, ellipse, line, polyline, polygon, fill and stroke opacity |
| `paths.svg` | cubic and quadratic curves with smooth shorthands, arcs, relative commands, even-odd and non-zero fill |
| `strokes.svg` | caps, joins, miter limit, dash arrays and offsets, dashed circle |
| `gradients.svg` | linear and radial gradients, spread methods, `gradientTransform`, `href` inheritance, bounding-box and user-space units, stop opacity |
| `icons.svg` | icon set through `symbol` and `use`, nested `svg`, `use` with transform and opacity |
| `badge.svg`, `badge_logo.svg` | shields.io-style flat badges: clip path, gradient overlay, `textLength` text |
| `logo.svg` | logo with gradients, clip path, mask, group opacity |
| `css.svg` | `<style>` rules with type, class, id, child and `:first-child` selectors, `style` attribute, `currentColor`, ignored `@media` |
| `filters.svg` | Gaussian blur, drop shadow built from primitives, colour matrix |
| `filters2.svg` | `feTurbulence` (fractal noise and turbulence), `feMorphology` erode and dilate |
| `filters3.svg` | `feDisplacementMap` driven by turbulence, `feConvolveMatrix` sharpen and emboss |
| `pattern_marker.svg` | user-space and bounding-box patterns, markers with `auto` orientation |
| `text.svg` | anchors, `tspan`, bold, italic, letter spacing, underline, per-character positions, mono and serif |
| `textpath.svg` | text along a `path` with `startOffset` and anchor |
| `clips.svg` | `clipPath` in both unit systems, `use` inside a clip path, clip path transform, clip with group opacity |
| `masks.svg` | luminance masks with `maskContentUnits`, gradient mask, mask region |
| `viewports.svg` | `symbol` and nested `svg` through `use` with `viewBox`, `preserveAspectRatio` and size overrides |
| `viewbox_slice.svg` | root `viewBox` with `slice` rendered at an aspect ratio different from the intrinsic one |
| `css_selectors.svg` | root, attribute, sibling, descendant and `:first-child` selectors, `font` shorthand |
| `units.svg` | `em`, `mm`, `pt` and percentage lengths in stroke width and dash arrays |
| `nested.svg` | `viewBox` with `slice`, nested viewport with `meet`, rotated and scaled groups, group opacity |
| `card.svg` | a stats-card style SVG with CSS `animation` and `fill-mode: forwards` |

The font files in `src/image/svg_font_*.ttf` are subsets of DejaVu Sans, Sans Mono and Serif 2.37 (Basic Latin, Latin-1 and common punctuation, without hinting or kerning). The licence is in `src/image/svg_font_LICENSE`.

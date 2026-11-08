# SVG test fixtures

`src/image/svg_test.zig` renders each `*.svg` here with `svg.render` at the size listed in the test and compares it with the matching `*.rgba` file.

## Reference files

Each `*.rgba` is the raw straight (non-premultiplied) RGBA8 pixel data, row by row, of the same SVG rendered by headless Chromium at the same pixel size, on a transparent background. Nothing else is stored: no header, no PNG.

How they were made (the scripts are not part of the repo):

- Headless Chromium (the build bundled with Playwright), device scale factor 1, element screenshot with the page background omitted.
- SVGs without text were loaded as an `<img>` of the target size, which is how GitHub shows them: no scripts, no external resources.
- SVGs with text, animation or keyframes were placed inline in a page, because an image cannot use fonts the page loads and cannot be paused. Text uses `font-family="mdview Sans"`, declared with `@font-face` from the unmodified Liberation Sans 2.1.5 files whose Latin subset the renderer bundles, so both sides draw the same outlines on every OS. Animated fixtures were paused and seeked with `SVGSVGElement.setCurrentTime` and `Animation.currentTime` to the time in the test table.
- The browser context used `prefers-color-scheme: dark`, as mdview is dark only.
- The `card.svg` reference was taken at the time in its table row (all its animations end before it).

The comparison is on premultiplied channels. A fixture passes when the mean absolute error and the share of pixels with an error above 40/255 are under the limits in `src/image/svg_test.zig`. Text fixtures have higher limits because the glyph rasterizers differ in hinting. Fixtures that exercise Chromium-specific corners (`feImage` placement, lighting) have the highest limits.

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
| `dark.svg` | `@media (prefers-color-scheme: dark)`, `@supports`, custom properties, `var()` with fallback, `calc()` |
| `anim_smil.svg` | `animate` with values, spline easing and freeze, `set`, `animateTransform`, `animateMotion`, colour interpolation (rendered at 1.2 s) |
| `anim_css.svg` | `@keyframes` with several stops, per-stop easing, `alternate`, `steps()`, `transform-origin` with `transform-box: fill-box` (rendered at 0.9 s) |
| `blend.svg` | `mix-blend-mode`, `isolation`, `vector-effect: non-scaling-stroke` |
| `cssfilters.svg` | CSS filter functions: blur, drop-shadow, grayscale, contrast, hue-rotate, saturate, sepia, brightness, invert, opacity |
| `tile.svg`, `feimage.svg` | `feImage` from an element with `feTile`, `feImage` from an element |
| `diffuse.svg`, `specular.svg` | diffuse lighting with a distant light, specular lighting with a point light |
| `nested.svg` | `viewBox` with `slice`, nested viewport with `meet`, rotated and scaled groups, group opacity |
| `card.svg` | a stats-card style SVG with CSS `animation` and `fill-mode: forwards` |

Text is drawn from the shared font layer in `src/font`: installed fonts resolved like a browser does, with the bundled Liberation Sans subset as the last resort.

# src/font

OpenType layer shared by the Mermaid layout, the SVG text renderer and math.

- `ttf.zig`: `Font`. cmap 4 and 12, glyf with composites, CFF Type 2 charstrings (`cff.zig`, name-keyed fonts), hmtx, TTC collections (`Font.init(data, face)`, `Font.open`, `Font.fromTtc`), `kern` and GPOS pair kerning, name lookup. `glyphFor`, `advance`, `kern`, `bbox`, `outline` (path sink with moveTo, lineTo, quadTo, cubicTo, close), `measure`.
- `math.zig`: the MATH table. `font.math.?.constants` (all MathConstants), `italicCorrection`, `topAccent`, `vertVariants` and `horizVariants` (`count`, `get(i)`), `assembly(gid, dir)` (`part(i)`), `min_connector_overlap`.
- `resolve.zig`: `resolve(io, "\"trebuchet ms\", verdana, sans-serif", weight, italic)` reads installed fonts by plain file reads and falls back to the bundled Liberation Sans. `mathFont(io, home)` finds a system math font (Cambria Math, STIX Two Math, or the Linux list) and falls back to the embedded STIX Two Math.
- `sans_regular.ttf`, `sans_bold.ttf`: Latin subsets of Liberation Sans 2.1.5, renamed "mdview Sans" as the SIL Open Font License requires for modified versions. License in `LICENSE-liberation-sans`.
- `stix_math.z`: deflated math subset of STIX Two Math, renamed "mdview Math". License in `LICENSE-stix-two-math`. Inflated once on first use.
- `math_ranges.zig`: the code points the math subset keeps; the subset tool and the tests share it.

Regenerate the Liberation subsets from `liberation-fonts-ttf-2.1.5.tar.gz` (sha256 `7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0`, https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-2.1.5.tar.gz):

```
zig build subset-font -- LiberationSans-Regular.ttf src/font/sans_regular.ttf "mdview Sans" Regular
zig build subset-font -- LiberationSans-Bold.ttf src/font/sans_bold.ttf "mdview Sans" Bold
```

Regenerate the math subset from STIX Two Math (`STIXTwoMath-Regular.otf` from CTAN `fonts/stix2-otf`, sha256 `95bc2729e41faf93b0bcae9e96c4dc4da45855067fd0581e621e30734fe8d90b`, https://tug.ctan.org/fonts/stix2-otf/STIXTwoMath-Regular.otf):

```
zig build subset-math-font -- STIXTwoMath-Regular.otf src/font/stix_math.z
```

The tools check the result against the source font before writing: advances, outlines, kerning (Liberation) and constants, italic corrections, accent attachments, variants and assemblies (STIX). The math subset keeps every glyph in `math_ranges.zig`, every size variant and assembly part those glyphs reference, and rewrites the MATH table, cmap and CFF (flattened charstrings, no subroutines or hints).

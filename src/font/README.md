# src/font

TrueType reader and font resolver shared by the Mermaid layout and the SVG text renderer.

- `ttf.zig`: `Font` (cmap 4 and 12, glyf with composites, hmtx, `kern` and GPOS pair kerning, TTC collections, name lookup), glyph outlines as `Path`, `measure`. CFF (`OTTO`) fonts return `error.Unsupported`.
- `resolve.zig`: `resolve(io, "\"trebuchet ms\", verdana, sans-serif", weight, italic)` reads installed fonts by plain file reads (Windows `C:\Windows\Fonts`, macOS `/System/Library/Fonts` and `Supplemental`, Linux `/usr/share/fonts` and `/usr/local/share/fonts`) and falls back to the bundled face.
- `sans_regular.ttf`, `sans_bold.ttf`: Latin subsets of Liberation Sans 2.1.5, renamed "mdview Sans" as the SIL Open Font License requires for modified versions. License in `LICENSE`.

Regenerate the subsets from `liberation-fonts-ttf-2.1.5.tar.gz` (sha256 `7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0`, https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-2.1.5.tar.gz):

```
zig build subset-font -- LiberationSans-Regular.ttf src/font/sans_regular.ttf "mdview Sans" Regular
zig build subset-font -- LiberationSans-Bold.ttf src/font/sans_bold.ttf "mdview Sans" Bold
```

The tool keeps Basic Latin, Latin-1, Latin Extended-A and common punctuation, rewrites kerning as a `kern` table, and checks advances, outlines and kerning against the source font before writing.

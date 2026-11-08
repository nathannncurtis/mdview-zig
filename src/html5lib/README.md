# HTML parser test data

`tree/*.dat` are tree-construction cases and `tokenizer/*.test` are tokenizer cases, copied unchanged from
https://github.com/web-platform-tests/wpt/tree/master/html/syntax/parsing/resources (the html5lib tree-construction
suite now lives there) and https://github.com/html5lib/html5lib-tests/tree/master/tokenizer. MIT licence, see `LICENSE`.
`src/html_test.zig` runs the subset that falls inside what `src/html.zig` implements and lists what it skips.

## GitHub expectations

`src/spec_html.json` holds the 64 "HTML blocks", "Raw HTML" and tagfilter examples of the GFM spec (`n`, `section`,
`md`, `html` from the spec) plus `github`, what GitHub's Markdown API returns for `md`. Regenerate with:

    zig build gen-spec-cases -- spec.txt src/spec_inline_cases.zig html_cases.json
    node src/html5lib/github_render.mjs html_cases.json src/spec_html.json

`spec.txt` is `test/spec.txt` of github/cmark-gfm. The script calls `gh api -X POST markdown -f text=<md> -f mode=markdown`,
which renders and stores nothing.

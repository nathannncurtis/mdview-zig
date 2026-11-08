<div align="center">

# Centred header

<img src="images/render_wide.svg" width="240" alt="wide logo">

<a href="https://example.org"><img src="images/render_badge.svg" alt="badge"></a> <a href="https://example.org/two"><img src="images/render_badge.svg" alt="badge two"></a>

A centred line of text inside a div.

</div>

<p align="right">Right aligned paragraph.</p>

<h3 align="center">A centred third level heading</h3>

## Inline styles

Press <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>P</kbd> to open the palette. Water is H<sub>2</sub>O and E = mc<sup>2</sup>. This is <ins>inserted</ins>, <mark>highlighted</mark>, <small>small print</small>, <abbr title="HyperText Markup Language">HTML</abbr> with a dotted line, <tt>teletype</tt>, <del>deleted</del> and a [link with <sub>sub</sub>](https://example.org).

## Definitions and figures

<dl>
<dt>First term</dt>
<dd>The first definition, indented by one rem.</dd>
<dt>Second term</dt>
<dd>The second definition.</dd>
</dl>

<figure>
<img src="images/render_badge.svg" alt="badge in a figure">
<figcaption>Figure caption below the picture.</figcaption>
</figure>

## Details

<details>
<summary>Closed by default</summary>

Hidden until the triangle is clicked.

- one
- two

</details>

<details open>
<summary>Open by default</summary>

Visible text, and a nested one:

<details>
<summary>Nested closed</summary>

Deep content.

</details>

</details>

## Tables

<table>
<caption>A table with spans</caption>
<tr><th colspan="2">Wide header</th><th>Plain</th></tr>
<tr><td rowspan="2" valign="middle">Tall cell</td><td>a</td><td align="right">right</td></tr>
<tr><td>b</td><td align="center">centre</td></tr>
<tr><td valign="bottom">bottom</td><td colspan="2">two columns of text that is long enough to be wider than the cells above it</td></tr>
</table>

## Float

<img src="images/render_badge.svg" align="right" width="160" alt="floated right">

This paragraph sits to the left of the picture. It runs long enough that its text wraps over several lines beside the floated image, which is what a browser does with an image that has an align attribute. More words follow so the line count is not trivially small, and the text keeps going down the page.

Another paragraph after the first, still beside the float if it is tall enough.

A third paragraph that may already be below the image.

<hr>

The end.

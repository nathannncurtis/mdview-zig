# Images

Every case below should show a picture or, where it says so, the alt text.

## Inline

An inline image with a title (hover it) sits in a line of text: ![small gif](images/gif_static.gif "A static GIF") and the text goes on after it.

A PNG ![png](images/png_rgba8.png), a JPEG ![jpeg](images/jpeg_420.jpg), a BMP ![bmp](images/bmp_rgb24.bmp) and an SVG badge ![badge](images/render_badge.svg) in one paragraph.

## Reference style

Full ![full ref][a], collapsed ![collapsed][], shortcut ![shortcut] and one with no definition ![nothing here][nope].

[a]: images/png_rgb8.png "Reference title"
[collapsed]: images/gif_trans.gif
[shortcut]: images/png_pal8.png

## Inside links

[![clickable image](images/png_rgba8.png "Opens the next section")](#animated)
[![clickable badge](images/render_badge.svg)](https://example.org/badge)

## Animated

A GIF that loops forever: ![forever](images/gif_anim_forever.gif)

A GIF that plays once: ![once](images/gif_anim_once.gif)

An animated PNG: ![apng](images/apng_basic.png)

## Scaling

This SVG is 1600 wide and scales down to the window, resize it to see it follow:

![wide](images/render_wide.svg)

A small image is never scaled up: ![tiny](images/png_tiny_1x1.png)

## Fallbacks

A file that does not exist: ![alt text for a missing file](images/does-not-exist.png)

A remote image that cannot load: ![alt text for a bad host](https://images.example.invalid/none.png)

A plain http source is never fetched: ![alt text for http](http://example.org/none.png)

A broken link-wrapped image: [![alt text inside a link](images/missing-too.png)](https://example.org/)

## In containers

| Picture | Name |
| --- | --- |
| ![cell gif](images/gif_static.gif) | gif |
| ![cell png](images/png_rgb8.png) | png |

- A list item with ![list image](images/png_rgba8.png)
- Another with ![list badge](images/render_badge.svg)

> A quote with ![quote image](images/jpeg_444.jpg "In a quote")

### A heading with an image ![heading image](images/gif_static.gif)

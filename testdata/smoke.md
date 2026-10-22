---
title: Smoke fixture
tags: [smoke, test]
author:
  name: CI
---

# Smoke fixture

Plain text with **bold**, *italic*, `code`, ~~strike~~ and a [link](https://example.com) plus <https://example.org>.

Emoji: :tada: :rocket: 😀 🦀

## Table

| Left | Center | Right |
|:-----|:------:|------:|
| a    |   b    |     c |
| 1    |   2    |     3 |

## Footnote

A claim with a note.[^1]

[^1]: The note text.

## Alerts

> [!NOTE]
> A note.

> [!WARNING]
> A warning.

## Code

```zig
const std = @import("std");
pub fn main() void {
    std.debug.print("hi {d}\n", .{42});
}
```

```python
def f(x):
    return x * 2
```

- [x] done
- [ ] open

1. one
2. two

---

[Back to top](#smoke-fixture)

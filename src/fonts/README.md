# Fonts

Embedded by `src/text.zig` (`@embedFile`) and installed next to the web build
(`zig-out/web/fonts/`, for `web/shell.html`). Both are under the SIL Open Font
License 1.1 (`OFL-*.txt`, kept with the files). Neither declares a Reserved Font
Name, so the subsets keep their names.

| File | Source | Used for |
|---|---|---|
| `Inter-SemiBold.ttf` | [Inter](https://github.com/rsms/inter) 4.1, `extras/ttf/Inter-SemiBold.ttf` | outputs, buttons, the web title |
| `JetBrainsMono-Regular.ttf` | [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono), `fonts/ttf/JetBrainsMono-Regular.ttf` | input (file) labels, the readout, the web subtitle |

Subset to Basic Latin plus `· – — … → −`, without hinting (stb_truetype
ignores it), about 26 KB together:

```sh
pyftsubset <font>.ttf --unicodes="U+0020-007E,U+00B7,U+2013,U+2014,U+2026,U+2192,U+2212" \
  --layout-features='kern' --no-hinting --desubroutinize --output-file=<font>.sub.ttf
```

A glyph outside that set draws as `?`. Add its code point both here and to
`codepoints` in `src/text.zig`.

# resid-mode

Emacs major mode for [Resid](https://github.com/larrydewey/Resid): highlighting,
indentation in the compiler's canonical style, imenu, compilation through
`residc` with clickable error locations, yasnippet snippets, and the Resid
language server (`residc lsp`) registered with Eglot and lsp-mode.

Vim users want [resid-vim](https://github.com/larrydewey/resid-vim) and Neovim
users [resid-nvim](https://github.com/larrydewey/resid-nvim).

Requires Emacs 29.1 or later.

## Install

With `use-package` and `package-vc` (Emacs 30+):

```elisp
(use-package resid-mode
  :vc (:url "https://github.com/larrydewey/resid-mode" :rev :newest)
  :hook (resid-mode . eglot-ensure))
```

Or from a clone:

```elisp
(add-to-list 'load-path "~/src/resid-mode")
(require 'resid-mode)
(add-hook 'resid-mode-hook #'eglot-ensure)   ; or #'lsp-deferred
```

You also need the compiler: `./install.sh` in the Resid repository puts
`residc` in `~/.resid/bin`. Inside a Resid checkout the mode uses that
checkout's `build/boot/stage2.bin` instead.

## What you get

- `*.resid` opens in `resid-mode`.
- Highlighting: keywords, types (`Int(N)`, `Dec(N)`, `Secret`, user types),
  `Some`/`None`/`Ok`/`Err`, annotations (`@requires`, `@needs`, `@trust`,
  ...), capability families and modes, built-ins (`assert`, `wrapping_*`,
  `checked_*`, `str_*`, `secret`, ...), function names at their definitions,
  numbers in every base and `m` decimals, `///` and `/** */` doc comments,
  string escapes (an escape the language refuses is shown as a warning), and
  `f"..."` holes with their format specs.
- Indentation (`TAB`, `indent-region`) in the canonical style: 4 spaces; a
  bracket followed by text aligns with the text; a continued expression or an
  `else` arm of an if-expression gets one more level. On the Resid repository's
  own sources (about 100,000 lines) it agrees with the code on all but about
  90 lines, which are hand alignments.
- `imenu`: functions, types, behaviors and tests.
- `C-c C-c` (`resid-compile`) compiles the file; `C-c C-t` (`resid-test`) runs
  its inline tests. `error[E....]` and `warning[E....]` reports link to their
  locations in the compilation buffer.
- yasnippet snippets in `snippets/resid-mode`, added to `yas-snippet-dirs`
  when yasnippet loads: `fn`, `pfn`, `main`, `match`, `for`, `test`,
  `behavior`, `spawn`, `importas`, ...

## Language server

`residc lsp` is the compiler's own front end on the buffer: diagnostics with
error codes, hover (signature, `///` docs, type, format specs), go to
definition across imports, document symbols, and completion. It is registered
with Eglot (`eglot-server-programs`) and, when installed, lsp-mode (server id
`residc`).

## Customization

| Variable | Default | |
|---|---|---|
| `resid-compiler` | `nil` | Path to the compiler; `nil` finds `build/boot/stage2.bin`, then `residc` |
| `resid-indent-offset` | `4` | Columns per level |
| `resid-lsp` | `t` | Register the server with Eglot and lsp-mode |

## Tests

```sh
test/run.sh
```

Byte-compiles with warnings as errors, then runs the ERT suite: highlighting,
a reindent fixed point (also from a fully flushed-left file), escapes, imenu,
the compilation regexp, and, when `residc` is installed, Eglot against the real
server (document symbols and a diagnostic for a type error).

## License

MIT

#!/bin/sh
# Byte-compile without warnings, then run the ERT suite in batch Emacs.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
emacs=${EMACS:-emacs}
"$emacs" -Q -batch -L "$here" \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "$here/resid-mode.el"
rm -f "$here/resid-mode.elc"
"$emacs" -Q -batch -L "$here" -L "$here/test" \
  -l resid-mode-tests -f ert-run-tests-batch-and-exit

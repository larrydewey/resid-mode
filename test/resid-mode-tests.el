;;; resid-mode-tests.el --- Tests for resid-mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with test/run.sh (emacs -batch).

;;; Code:

(require 'ert)
(require 'resid-mode)

(defconst resid-test-dir (file-name-directory (or load-file-name buffer-file-name)))

(defmacro resid-test-with-sample (&rest body)
  "Run BODY in a `resid-mode' buffer holding test/sample.resid."
  `(with-temp-buffer
     (insert-file-contents (expand-file-name "sample.resid" resid-test-dir))
     (resid-mode)
     (font-lock-ensure)
     ,@body))

(defun resid-test-face-at (pattern)
  "The face at the start of the first match of PATTERN."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward pattern)
    (let ((f (get-text-property (match-beginning 0) 'face)))
      (if (listp f) (car f) f))))

(ert-deftest resid-auto-mode ()
  (should (eq (cdr (assoc "\\.resid\\'" auto-mode-alist)) 'resid-mode)))

(ert-deftest resid-reindent-is-fixed-point ()
  (resid-test-with-sample
   (let ((before (buffer-string)))
     (indent-region (point-min) (point-max))
     (should (equal (buffer-string) before)))))

(ert-deftest resid-indent-from-flat ()
  "Every line flushed left comes back to the canonical indentation."
  (resid-test-with-sample
   (let ((before (buffer-string)))
     (goto-char (point-min))
     (while (not (eobp))
       (delete-horizontal-space)
       (forward-line 1))
     (indent-region (point-min) (point-max))
     (should (equal (buffer-string) before)))))

(ert-deftest resid-faces ()
  (resid-test-with-sample
   (should (eq (resid-test-face-at "\\_<behavior\\_>") 'font-lock-keyword-face))
   (should (eq (resid-test-face-at "@requires") 'font-lock-preprocessor-face))
   (should (eq (resid-test-face-at "filesystem") 'font-lock-variable-name-face))
   (should (eq (resid-test-face-at "\\_<Shape\\_> s") 'font-lock-type-face))
   (should (eq (resid-test-face-at "\\_<area\\_>(S") 'font-lock-function-name-face))
   (should (eq (resid-test-face-at "wrapping_add") 'font-lock-builtin-face))
   (should (eq (resid-test-face-at "^/// A point") 'font-lock-doc-face))
   (should (eq (resid-test-face-at "Indentation fixture") 'font-lock-comment-face))
   (should (eq (resid-test-face-at ":8}") 'font-lock-constant-face))
   (should (eq (resid-test-face-at "\\_<Empty\\_> =>") 'font-lock-type-face))))

(ert-deftest resid-escapes ()
  (with-temp-buffer
    (resid-mode)
    (insert "Str s = \"a\\n\\x41\\q\";\n")
    (font-lock-ensure)
    (should (eq (resid-test-face-at "\\\\n") 'font-lock-escape-face))
    (should (eq (resid-test-face-at "\\\\x41") 'font-lock-escape-face))
    (should (eq (resid-test-face-at "\\\\q") 'font-lock-warning-face))))

(ert-deftest resid-imenu ()
  (resid-test-with-sample
   (let ((index (funcall imenu-create-index-function)))
     (should (assoc "area" index))
     (should (assoc "Point" (cdr (assoc "Types" index))))
     (should (assoc "Name" (cdr (assoc "Behaviors" index))))
     (should (assoc "area" (cdr (assoc "Tests" index)))))))

(ert-deftest resid-compilation-regexp ()
  (with-temp-buffer
    (insert "error[E0001]: type error: binding x: expected Int, got Str\n"
            "  --> /tmp/x.resid:2:13\n2 |     Int x = \"a\";\n"
            "warning[E0291]: disclosure\n  --> /tmp/y.resid:7:1\n")
    (goto-char (point-min))
    (should (re-search-forward resid--compilation-regexp nil t))
    (should (equal (match-string 2) "/tmp/x.resid"))
    (should (equal (match-string 3) "2"))
    (should (equal (match-string 4) "13"))
    (should-not (match-string 1))
    (should (re-search-forward resid--compilation-regexp nil t))
    (should (match-string 1))
    (should (equal (match-string 2) "/tmp/y.resid"))))

(ert-deftest resid-eglot-registered ()
  (require 'eglot)
  (should (assoc 'resid-mode eglot-server-programs))
  (should (equal (cadr (resid-lsp-command)) "lsp")))

(ert-deftest resid-eglot-live ()
  "The language server end to end, when a compiler is installed."
  (skip-unless (executable-find (resid-compiler)))
  (require 'eglot)
  (let* ((dir (make-temp-file "resid-test" t))
         (file (expand-file-name "sample.resid" dir)))
    (unwind-protect
        (progn
          (copy-file (expand-file-name "sample.resid" resid-test-dir) file)
          (with-temp-file (expand-file-name "util.resid" dir)
            (insert "/// A helper.\npub Int helper() { return 1; }\n"))
          (with-temp-file (expand-file-name "resid.toml" dir))
          (with-current-buffer (find-file-noselect file)
            (let ((eglot-sync-connect 10))
              (apply #'eglot (eglot--guess-contact))
              (with-timeout (15 (ert-fail "no server"))
                (while (not (eglot-current-server)) (accept-process-output nil 0.1)))
              (let* ((server (eglot-current-server))
                     (symbols (jsonrpc-request
                               server :textDocument/documentSymbol
                               `(:textDocument ,(eglot--TextDocumentIdentifier)))))
                (should (seq-find (lambda (s) (equal (plist-get s :name) "area")) symbols))
                (goto-char (point-max))
                (insert "Int bad() { Int x = \"a\"; return x; }\n")
                (eglot--signal-textDocument/didChange)
                (with-timeout (15 (ert-fail "no diagnostic"))
                  (while (not (flymake-diagnostics))
                    (flymake-start)
                    (accept-process-output nil 0.2)))
                (should (string-match-p "E0" (flymake-diagnostic-text (car (flymake-diagnostics)))))
                (eglot-shutdown server)))
            (set-buffer-modified-p nil)
            (kill-buffer)))
      (delete-directory dir t))))

(provide 'resid-mode-tests)

;;; resid-mode-tests.el ends here

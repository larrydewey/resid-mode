;;; resid-mode.el --- Major mode for the Resid language -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Larry Dewey

;; Author: Larry Dewey
;; URL: https://github.com/larrydewey/resid-mode
;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Editing support for Resid (https://github.com/larrydewey/Resid):
;; highlighting, indentation in the compiler's canonical style, imenu,
;; compilation through `residc' with its error locations, yasnippet
;; snippets, and the Resid language server (`residc lsp') registered with
;; Eglot and lsp-mode.

;;; Code:

(require 'rx)
(require 'compile)

(defgroup resid nil
  "Support for the Resid language."
  :group 'languages
  :prefix "resid-")

(defcustom resid-compiler nil
  "Path to the Resid compiler.
When nil: the nearest build/boot/stage2.bin above the file (inside a
Resid checkout), then `residc' on `exec-path'."
  :type '(choice (const :tag "Find it" nil) file))

(defcustom resid-indent-offset 4
  "Indentation of a nested block, in columns."
  :type 'integer
  :safe #'integerp)

(defcustom resid-lsp t
  "When non-nil, register the language server with Eglot and lsp-mode."
  :type 'boolean)

;;; The compiler

(defun resid-compiler (&optional dir)
  "The compiler to run for a file in DIR (default: the current buffer's)."
  (or resid-compiler
      (let* ((dir (or dir default-directory))
             (root (locate-dominating-file
                    dir (lambda (d) (file-executable-p
                                     (expand-file-name "build/boot/stage2.bin" d))))))
        (if root
            (expand-file-name "build/boot/stage2.bin" root)
          (or (executable-find "residc") "residc")))))

(defun resid-lsp-command (&rest _)
  "The language server command: the compiler's own `lsp' subcommand."
  (list (resid-compiler) "lsp"))

;;; Syntax

(defconst resid--keywords
  '("if" "else" "match" "for" "while" "in" "return" "break" "continue"
    "with" "spawn" "sandbox" "lambda" "rt" "using" "as" "pub" "import"
    "type" "behavior" "test"))

(defconst resid--types
  '("Int" "UInt" "Float" "Dec" "ISize" "USize" "Str" "Bytes" "Bool"
    "Option" "Result" "List" "Map" "Set" "StrBuf" "ListBuf" "Secret"
    "RegionError" "SourceLoc"))

(defconst resid--constants
  '("true" "false" "null" "Some" "None" "Ok" "Err"))

(defconst resid--builtins
  '("assert" "rt_assert" "known" "rt_known" "comptime_print" "todo"
    "unimplemented" "ct_hide" "ct_public" "secret" "classify"
    "secret_split" "secret_join" "expect"))

(defconst resid--capabilities
  '("filesystem" "environment" "git" "args" "process" "network" "random"
    "terminal" "clock" "device" "display" "declassify" "provision" "assume"))

(defvar resid-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?/ ". 124b" table)
    (modify-syntax-entry ?* ". 23" table)
    (modify-syntax-entry ?\n "> b" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?' "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?@ "'" table)
    (modify-syntax-entry ?# "'" table)
    (dolist (c '(?+ ?- ?% ?= ?< ?> ?& ?| ?^ ?! ?~ ??))
      (modify-syntax-entry c "." table))
    table)
  "Syntax table for `resid-mode'.")

(defun resid--syntactic-face (state)
  "Doc comments (`///', `/**') get `font-lock-doc-face'; see STATE."
  (cond
   ((nth 3 state) 'font-lock-string-face)
   ((save-excursion
      (goto-char (nth 8 state))
      (and (looking-at (rx (or "///" (seq "/**" (not (any "/"))))))))
    'font-lock-doc-face)
   (t 'font-lock-comment-face)))

(defun resid--in-string-p (pos)
  "Non-nil when POS is inside a string literal."
  (nth 3 (save-excursion (syntax-ppss pos))))

(defun resid--match-escape (limit)
  "Find the next escape sequence in a string, up to LIMIT."
  (let (found)
    (while (and (not found)
                (re-search-forward (rx "\\" (or (any "ntr0\\\"'") (seq "x" xdigit xdigit) anything))
                                   limit t))
      (when (resid--in-string-p (match-beginning 0))
        (setq found t)))
    found))

(defun resid--escape-face ()
  "The face for the escape just matched: valid or not."
  (if (string-match-p (rx bos "\\" (or (any "ntr0\\\"'") (seq "x" xdigit xdigit)) eos)
                      (match-string 0))
      'font-lock-escape-face
    'font-lock-warning-face))

(defun resid--fstring-start (pos)
  "The start of the f-string containing POS, or nil."
  (let ((ppss (save-excursion (syntax-ppss pos))))
    (and (nth 3 ppss)
         (eq (char-after (nth 8 ppss)) ?\")
         (eq (char-before (nth 8 ppss)) ?f)
         (nth 8 ppss))))

(defun resid--match-hole (limit)
  "Find the next f-string hole `{expr:spec}' up to LIMIT.
Group 1 is the opening brace, 2 the spec, 3 the closing brace."
  (let (found)
    (while (and (not found) (re-search-forward "{" limit t))
      (let ((open (match-beginning 0)))
        (cond
         ((eq (char-after) ?{) (forward-char 1))          ; `{{' escape
         ((resid--fstring-start open)
          (let ((close (save-excursion (search-forward "}" limit t))))
            (when close
              (let* ((colon (save-excursion
                              (and (search-forward ":" (1- close) t) (1- (point)))))
                     (spec-beg (or colon (1- close))))
                (set-match-data (list open close open (1+ open)
                                      spec-beg (1- close) (1- close) close))
                (goto-char close)
                (setq found t))))))))
    found))

(defvar resid-font-lock-keywords
  `((,(regexp-opt resid--keywords 'symbols) . 'font-lock-keyword-face)
    (,(regexp-opt resid--constants 'symbols) . 'font-lock-constant-face)
    (,(regexp-opt resid--types 'symbols) . 'font-lock-type-face)
    (,(rx symbol-start (or "wrapping_" "saturating_" "checked_" "str_")
          (+ (or word (syntax symbol)))
          (* space) (group-n 1 "("))
     0 'font-lock-builtin-face)
    (,(rx symbol-start
          (or (seq (any "iu") (or "8" "16" "32" "64" "128" "256" "512" "size"))
              (seq "f" (or "16" "32" "64" "128"))
              (seq "d" (any "1-9") (* digit)))
          symbol-end (* space) "(")
     . 'font-lock-builtin-face)
    (,(concat (regexp-opt resid--builtins 'symbols) (rx (* space) "("))
     . 'font-lock-builtin-face)
    (,(rx "@" (+ (or word (syntax symbol)))) . 'font-lock-preprocessor-face)
    ("#location\\_>" . 'font-lock-preprocessor-face)
    (,(rx symbol-start (or (regexp (regexp-opt resid--capabilities))
                           (seq "native_" (+ (or word (syntax symbol)))))
          symbol-end (* space) (any "(,)"))
     . 'font-lock-variable-name-face)
    (,(rx "(" (group (or "readonly" "readwrite")) ")") 1 'font-lock-constant-face)
    ;; `type Name' and `behavior Name'
    (,(rx symbol-start (or "type" "behavior") (+ space)
          (group (any "A-Z") (* (or word (syntax symbol)))))
     1 'font-lock-type-face)
    ;; `Ret name(' at the start of a declaration
    (,(rx line-start (* space) (? "pub" (+ space))
          (any "A-Z") (* (or word (syntax symbol)))
          (? "(" (* (not (any "()"))) (* "(" (* (not (any "()"))) ")" (* (not (any "()")))) ")")
          (+ space) (group (any "a-zA-Z_") (* (or word (syntax symbol)))) (* space) "(")
     1 'font-lock-function-name-face)
    (,(rx symbol-start (any "A-Z") (* (or word (syntax symbol))) symbol-end)
     . 'font-lock-type-face)
    (,(rx symbol-start
          (or (seq "0x" (+ (any xdigit "_")))
              (seq "0o" (+ (any "0-7_")))
              (seq "0b" (+ (any "01_")))
              (seq digit (* (any digit "_"))
                   (? "." digit (* (any digit "_")))
                   (? (any "eE") (? (any "+-")) (+ digit))
                   (? "m")))
          symbol-end)
     . 'font-lock-number-face)
    (resid--match-escape (0 (resid--escape-face) prepend))
    (resid--match-hole (1 'font-lock-misc-punctuation-face prepend)
                       (2 'font-lock-constant-face prepend)
                       (3 'font-lock-misc-punctuation-face prepend)))
  "Highlighting for `resid-mode'.")

;;; Indentation

(defun resid--code-end ()
  "The last code character on the current line, skipping comments."
  (save-excursion
    (end-of-line)
    (let ((ppss (syntax-ppss)))
      (when (nth 4 ppss) (goto-char (nth 8 ppss))))
    (skip-chars-backward " \t")
    (let ((ppss (syntax-ppss)))
      (when (nth 4 ppss) (goto-char (nth 8 ppss)) (skip-chars-backward " \t")))
    (char-before)))

(defun resid--line-complete-p ()
  "Non-nil when the current line ends a statement or an item."
  (save-excursion
    (back-to-indentation)
    (or (looking-at-p "@")
        (looking-at-p "//\\|/\\*")
        (nth 4 (syntax-ppss))
        (let ((c (resid--code-end)))
          (or (null c) (memq c '(?\; ?{ ?} ?\( ?\[ ?,))
              (save-excursion
                (end-of-line)
                (skip-chars-backward " \t")
                (looking-back "=>" (line-beginning-position))))))))

(defun resid--prev-sibling (open)
  "Move to the previous code line after OPEN (a position or nil).
Return non-nil when there is one."
  (let (found)
    (while (and (not found)
                (zerop (forward-line -1))
                (or (null open) (> (line-beginning-position) open)))
      (back-to-indentation)
      (unless (or (eolp) (nth 4 (syntax-ppss)) (looking-at-p "//\\|/\\*"))
        (setq found t)))
    (and found (or (null open) (> (point) open)))))

(defun resid--anchor-indentation (pos)
  "The indentation of the statement holding the bracket at POS.
A line that starts inside a parenthesis or square bracket (a
continued parameter list) counts as part of the line that opened it."
  (save-excursion
    (goto-char pos)
    (back-to-indentation)
    (let (open)
      (while (and (setq open (nth 1 (syntax-ppss)))
                  (memq (char-after open) '(?\( ?\[)))
        (goto-char open)
        (back-to-indentation)))
    (current-indentation)))

(defun resid--indentation ()
  "The indentation the current line should have."
  (save-excursion
    (back-to-indentation)
    (let* ((ppss (syntax-ppss))
           (open (nth 1 ppss))
           (closer (looking-at-p "[]})]"))
           (else (looking-at-p "else\\_>")))
      (cond
       ;; Inside a block comment: align `*' under the opening `/*'.
       ((nth 4 ppss)
        (save-excursion
          (goto-char (nth 8 ppss))
          (+ (current-column) (if (looking-at-p "/\\*") 1 0))))
       ((nth 3 ppss) (current-indentation))
       (t
        (let ((base (cond
                     ((null open) 0)
                     (closer (resid--anchor-indentation open))
                     (t (save-excursion
                          (goto-char (1+ open))
                          (skip-chars-forward " \t")
                          (if (or (eolp) (looking-at-p "//"))
                              (+ (resid--anchor-indentation open) resid-indent-offset)
                            (current-column)))))))
          (if closer
              base
            (save-excursion
              ;; A continued expression, or the `else' of an if-expression.
              (if (and (resid--prev-sibling open) (or else (not (resid--line-complete-p))))
                  (let ((prev (current-indentation)))
                    (if (and (resid--prev-sibling open) (not (resid--line-complete-p)))
                        prev
                      (+ base resid-indent-offset)))
                base)))))))))

(defun resid-indent-line ()
  "Indent the current line in Resid's canonical style."
  (interactive)
  (let ((target (resid--indentation))
        (offset (- (current-column) (current-indentation))))
    (indent-line-to (max 0 target))
    (when (> offset 0) (forward-char offset))))

;;; Navigation

(defvar resid-imenu-generic-expression
  `(("Tests" ,(rx line-start "test" (+ space) "\"" (group (* (not (any "\"")))) "\"") 1)
    ("Behaviors" ,(rx line-start "behavior" (+ space) (group (+ (or word (syntax symbol))))) 1)
    ("Types" ,(rx line-start (? "pub" (+ space)) "type" (+ space) (group (+ (or word (syntax symbol))))) 1)
    (nil ,(rx line-start (? "pub" (+ space))
              (any "A-Z") (* (or word (syntax symbol)))
              (? "(" (* (not (any "()"))) (* "(" (* (not (any "()"))) ")" (* (not (any "()")))) ")")
              (+ space) (group (any "a-zA-Z_") (* (or word (syntax symbol)))) (* space) "(")
         1))
  "Imenu entries: functions, types, behaviors and tests.")

;;; Compilation

(defconst resid--compilation-regexp
  (rx line-start (or "error" (group "warning")) "[" (+ alnum) "]: " (* nonl) "\n"
      (+ space) "--> " (group (+? nonl)) ":" (group (+ digit)) ":" (group (+ digit)))
  "An `error[E....]' or `warning[E....]' report and its location line.")

(with-eval-after-load 'compile
  (add-to-list 'compilation-error-regexp-alist-alist
               `(resid ,resid--compilation-regexp 2 3 4 (1 . nil)))
  (add-to-list 'compilation-error-regexp-alist 'resid))

(defun resid-compile ()
  "Compile the current file with `residc'."
  (interactive)
  (let ((file (buffer-file-name)))
    (unless file (user-error "Buffer has no file"))
    (compile (format "%s %s -o %s"
                     (shell-quote-argument (resid-compiler))
                     (shell-quote-argument file)
                     (shell-quote-argument (file-name-sans-extension file))))))

(defun resid-test ()
  "Run the current file's inline tests with `residc test'."
  (interactive)
  (let ((file (buffer-file-name)))
    (unless file (user-error "Buffer has no file"))
    (compile (format "%s test %s" (shell-quote-argument (resid-compiler))
                     (shell-quote-argument file)))))

;;; Language server

(defun resid--eglot-contact (&rest _)
  "The server Eglot starts for a Resid buffer."
  (resid-lsp-command))

(defvar eglot-server-programs)

(with-eval-after-load 'eglot
  (when resid-lsp
    (add-to-list 'eglot-server-programs '(resid-mode . resid--eglot-contact))))

(declare-function lsp-register-client "lsp-mode")
(declare-function make-lsp-client "lsp-mode")
(declare-function lsp-stdio-connection "lsp-mode")
(declare-function lsp-activate-on "lsp-mode")
(defvar lsp-language-id-configuration)

(with-eval-after-load 'lsp-mode
  (when resid-lsp
    (add-to-list 'lsp-language-id-configuration '(resid-mode . "resid"))
    (lsp-register-client
     (make-lsp-client
      :new-connection (lsp-stdio-connection #'resid-lsp-command)
      :activation-fn (lsp-activate-on "resid")
      :server-id 'residc))))

;;; Snippets

(defconst resid-snippets-dir
  (expand-file-name "snippets" (file-name-directory (or load-file-name buffer-file-name "")))
  "The yasnippet snippets shipped with `resid-mode'.")

(defvar yas-snippet-dirs)
(declare-function yas-load-directory "yasnippet")

(with-eval-after-load 'yasnippet
  (when (file-directory-p resid-snippets-dir)
    (add-to-list 'yas-snippet-dirs resid-snippets-dir t)
    (yas-load-directory resid-snippets-dir t)))

;;; The mode

(defvar resid-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'resid-compile)
    (define-key map (kbd "C-c C-t") #'resid-test)
    map)
  "Keymap for `resid-mode'.")

;;;###autoload
(define-derived-mode resid-mode prog-mode "Resid"
  "Major mode for editing Resid source.

\\{resid-mode-map}"
  :syntax-table resid-mode-syntax-table
  (setq-local comment-start "// ")
  (setq-local comment-end "")
  (setq-local comment-start-skip (rx (or (seq "/" (+ "/")) (seq "/" (+ "*"))) (* space)))
  (setq-local comment-multi-line t)
  (setq-local font-lock-defaults
              '(resid-font-lock-keywords nil nil nil nil
                (font-lock-syntactic-face-function . resid--syntactic-face)))
  (setq-local indent-line-function #'resid-indent-line)
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width resid-indent-offset)
  (setq-local electric-indent-chars (append "{}()[]" electric-indent-chars))
  (setq-local imenu-generic-expression resid-imenu-generic-expression)
  (setq-local compile-command
              (when buffer-file-name
                (format "%s %s -o %s"
                        (shell-quote-argument (resid-compiler))
                        (shell-quote-argument buffer-file-name)
                        (shell-quote-argument (file-name-sans-extension buffer-file-name))))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.resid\\'" . resid-mode))

(provide 'resid-mode)

;;; resid-mode.el ends here

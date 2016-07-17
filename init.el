;;; init.el --- my emacs stuff
;;; Commentary:
;;; Code:
(setq load-path (cons "~/.emacs.d/lisp" load-path))
(setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
			 ("melpa" . "https://melpa.org/packages/")
			 ("melpa-stable" . "https://stable.melpa.org/packages/")
			 ))

(require 'ensure-packages)

(setq ensure-packages '(ac-cider
                        ac-ispell
                        ac-js2
                        ace-flyspell
                        ace-jump-mode
                        ag
                        airline-themes
                        auto-complete
                        cider
                        clj-refactor
                        clojure-mode
                        clojure-mode-extra-font-locking
                        clojure-snippets
                        dumb-jump
                        expand-region
                        flx-ido
                        flycheck
                        flycheck-clojure
                        flycheck-pos-tip
                        ggtags
                        gist
                        goto-last-change
                        git-commit
                        highlight-symbol
                        jedi
                        js2-mode
                        json-mode
                        json-reformat
                        iedit
                        magit
                        move-dup
                        nginx-mode
                        php-mode
                        pyvenv
                        smart-mode-line
			smart-mode-line-powerline-theme
                        rainbow-delimiters
                        react-snippets
                        restclient
                        smartparens
                        thrift
                        web-mode
                        yasnippet))

(ensure-packages-install-missing)

;; activate installed packages
(package-initialize)

;; (require 'powerline)

;; (require 'airline-themes)
;; (load-theme 'airline-dark t)
(setq mode-line-end-spaces t)
(setq sml/theme 'smart-mode-line-powerline)
;;(setq sml/theme 'dark)
;;(setq sml/mode-width 0)
(setq sml/name-width 0)
;; (setq sml/shorten-modes nil)
(setq sml/no-confirm-load-theme t)
(setq rm-blacklist (quote (
                           " AC"
                           " WS"
                           " yas"
                           " md"
                           " hs"
                           )))
(sml/setup)

(with-eval-after-load 'flycheck
  (flycheck-pos-tip-mode))

(require 'flycheck)

(setq inhibit-startup-message t)                 ;no splash screen
;; (set-frame-font "DejaVu Sans Mono-12")          ;default font
;; (add-to-list 'default-frame-alist '(font . "DejaVu Sans Mono-12"))
(setq inhibit-splash-screen t)                   ;Eliminate GNU splash screen
(fset 'yes-or-no-p 'y-or-n-p)                    ;replace y-e-s by y

(recentf-mode 1)                                 ;recently edited files in menu
(setq-default show-trailing-whitespace t)

(show-paren-mode 1)
(menu-bar-mode -1)
(scroll-bar-mode -1)
(tool-bar-mode -1)

(setq custom-file "~/.emacs.d/custom.el")
(load custom-file 'noerror)

(setq flycheck-keymap-prefix (kbd "C-c ,"))

(setq auto-save-file-name-transforms (quote ((".*" "~/.emacs.d/autosaves/\\1" t))))
(setq backup-directory-alist (quote ((".*" . "~/.emacs.d/backups/"))))
(column-number-mode t)
(delete-selection-mode t)

(add-hook 'text-mode-hook 'turn-on-auto-fill)
(add-hook 'before-save-hook 'delete-trailing-whitespace)

;; better frame title
(setq frame-title-format (list '(buffer-file-name "%f" (dired-directory dired-directory "%b"))))

;;no tabs
(setq-default indent-tabs-mode nil)

(global-set-key [f8] 'linum-mode)

(add-hook 'prog-mode-hook #'hs-minor-mode)
(add-hook 'prog-mode-hook #'subword-mode)

(global-set-key (kbd "C-'") 'hs-toggle-hiding)
(global-set-key [f7] 'hs-hide-all)

(autoload 'nginx-mode "nginx-mode" "Mode for editing nginx config files" t)

(add-to-list 'auto-mode-alist '("\\.jsx\\'" . web-mode))
(add-to-list 'auto-mode-alist '("\\.css$" . css-mode))
(add-to-list 'auto-mode-alist '("\\.pas$" . opascal-mode))
(add-to-list 'auto-mode-alist '("\\.dfm$" . opascal-mode))
(add-to-list 'auto-mode-alist '("\\.rnc$" . rnc-mode))
(add-to-list 'auto-mode-alist '("\\.org\\'" . org-mode))
(add-to-list 'auto-mode-alist '("\\.token\\'" . jinja2-mode))
(add-to-list 'auto-mode-alist '("\\.php$" . php-mode))
(add-to-list 'auto-mode-alist '("\\.restclient$" . restclient-mode))

(add-to-list 'auto-mode-alist
              (cons (concat "\\." (regexp-opt '("xml" "xsd" "sch" "rng" "xslt" "svg" "rss") t) "\\'")
                    'nxml-mode))

(add-to-list 'auto-mode-alist '("\\.html?\\'" . web-mode))


;; disable jshint since we prefer eslint checking
(setq-default flycheck-disabled-checkers
  (append flycheck-disabled-checkers
    '(javascript-jshint)))

;; use eslint with web-mode for jsx files
(flycheck-add-mode 'javascript-eslint 'web-mode)

(setq web-mode-comment-style 2)
(setq web-mode-enable-auto-quoting nil)

(defun my-web-mode-hook ()
  "Hooks for Web mode."
  (setq web-mode-markup-indent-offset 2)
  (setq web-mode-code-indent-offset 2)

  (auto-complete-mode 1)

  (setq web-mode-ac-sources-alist
        '(("css" . (ac-source-words-in-buffer ac-source-css-property))
          ("html" . (ac-source-words-in-buffer ac-source-abbrev))
          ("js" . (ac-source-words-in-buffer ac-source-words-in-same-mode-buffers))
          ("jsx" . (ac-source-words-in-buffer ac-source-words-in-same-mode-buffers))))
)

(add-hook 'web-mode-hook  'my-web-mode-hook)

(setq magic-mode-alist
      (cons '("<＼＼?xml " . nxml-mode)
	    magic-mode-alist))

(fset 'xml-mode 'nxml-mode)


(global-set-key "\C-cl" 'org-store-link)
(global-set-key "\C-ca" 'org-agenda)
(global-set-key "\C-cb" 'org-iswitchb)
(setq org-src-fontify-natively t)

;; Copy-Cut-Paste from clipboard with Super-C Super-X Super-V
(global-set-key (kbd "s-x") 'clipboard-kill-region) ;;cut
(global-set-key (kbd "s-c") 'clipboard-kill-ring-save) ;;copy
(global-set-key (kbd "s-v") 'clipboard-yank) ;;paste

(require 'move-dup)
(global-set-key (kbd "M-<up>") 'md/move-lines-up)
(global-set-key (kbd "M-<down>") 'md/move-lines-down)
(global-set-key (kbd "C-M-<up>") 'md/duplicate-up)
(global-set-key (kbd "C-M-<down>") 'md/duplicate-down)
(global-move-dup-mode)

(defun refresh-file ()
  (interactive)
  (revert-buffer t t t)
)

(global-set-key [f2] 'whitespace-mode)
(global-set-key [f5] 'refresh-file)
(global-set-key [f6] 'menu-bar-mode)
(global-set-key [f9] 'delete-trailing-whitespace)
(global-set-key (kbd "<C-tab>") 'imenu)
(global-set-key (kbd "M-8") 'pop-tag-mark)

(defun fullscreen ()
  (interactive)
  (set-frame-parameter nil 'fullscreen
		       (if (frame-parameter nil 'fullscreen) nil 'fullboth)))

(global-set-key [f11] 'sort-lines)

(autoload 'goto-last-change-with-auto-marks "goto-last-change" nil t)
(global-set-key (kbd "C-q") 'goto-last-change-with-auto-marks)
(global-set-key (kbd "C-S-q") 'quoted-insert)

(require 'color-theme)
(color-theme-initialize)
(load-library "color-theme-colorful-obsolescence")
(color-theme-colorful-obsolescence)

;; (load-theme 'sanityinc-tomorrow-bright t)
;; (load-theme 'solarized-dark t)
;; (load-theme 'wombat t)
;; (load-theme 'tango-dark t)
;; (load-theme 'base16-railscasts t)
;; (load-theme 'sanityinc-tomorrow-bright t)

(require 'flx-ido)
(ido-mode 1)
(ido-everywhere 1)
(flx-ido-mode 1)
;; disable ido faces to see flx highlights.
(setq ido-enable-flex-matching t)
(setq ido-use-faces nil)

(add-to-list 'auto-mode-alist '("\\.json$" . json-mode))

(add-to-list 'auto-mode-alist '("\\.tac$" . python-mode))

(global-set-key (kbd "M-g") 'goto-line)

(add-to-list 'auto-mode-alist '("\\.hs$" . haskell-mode))
(add-to-list 'auto-mode-alist '("\\.lhs$" . haskell-mode))
(add-hook 'haskell-mode-hook 'haskell-indentation-mode)
(add-hook 'haskell-mode-hook 'turn-on-haskell-doc-mode)
(add-hook 'haskell-mode-hook 'turn-on-haskell-indent)

(add-to-list 'auto-mode-alist '("\\.coffee$" . coffee-mode))
(add-to-list 'auto-mode-alist '("Cakefile" . coffee-mode))

(defun coffee-custom ()
  "coffee-mode-hook"
 (set (make-local-variable 'tab-width) 2))

(add-hook 'coffee-mode-hook
  '(lambda() (coffee-custom)))

(put 'upcase-region 'disabled nil)
(set-face-attribute 'mode-line nil :box nil)

(defun dedicatewindow ()
  (interactive)
  (set-window-dedicated-p (selected-window) (if (window-dedicated-p) nil t))
  (message "Window is now %s" (if (window-dedicated-p)
				  (format "dedicated to %s" (buffer-name))
				  "not dedicated"))
)

(global-set-key [f12] 'flycheck-next-error)
(global-set-key [(shift f12)] 'flycheck-previous-error)

(setq js2-auto-indent-p nil)
(setq js2-basic-offset 2)
(setq js2-bounce-indent-p nil)
(setq js2-cleanup-whitespace t)
(setq js2-enter-indents-newline t)
(setq js2-indent-on-enter-key nil)
(setq js2-mode-escape-quotes nil)
(setq js2-pretty-multiline-declarations t)

(add-to-list 'auto-mode-alist '("\\.js\\'" . web-mode))
(add-to-list 'auto-mode-alist '("\\.spec'" . rpm-spec-mode))
(add-to-list 'auto-mode-alist '("\\.spec\.in'" . rpm-spec-mode))

;; Turn on snippets
(require 'yasnippet)
(add-to-list 'yas-snippet-dirs "~/.emacs.d/snippets")
(yas-global-mode t)

;; Remove Yasnippet's default tab key binding
(define-key yas-minor-mode-map (kbd "<tab>") nil)
(define-key yas-minor-mode-map (kbd "TAB") nil)

;; Set Yasnippet's key binding to shift+tab
(define-key yas-minor-mode-map (kbd "<backtab>") 'yas-expand)

(require 'auto-complete-config)

(add-to-list 'ac-dictionary-directories "~/.emacs.d/ac-dict")
(ac-config-default)

(add-to-list 'ac-sources 'ac-source-yasnippet)

(define-key ac-mode-map (kbd "M-TAB") 'auto-complete)


;; create the autosave dir if necessary, since emacs won't.
(make-directory "~/.emacs.d/autosaves/" t)

(add-hook 'after-init-hook #'global-flycheck-mode)

(autoload 'jedi:setup "jedi" nil t)
(add-hook 'python-mode-hook 'jedi:setup)
(setq jedi:setup-keys t)
(setq jedi:complete-on-dot t)

(require 'highlight-symbol)
(global-set-key [(control f3)] 'highlight-symbol-at-point)

(defun bf-pretty-print-xml-region (begin end)
"Pretty format XML markup in region.
You need to have 'nxml-mode'
http://www.emacswiki.org/cgi-bin/wiki/NxmlMode installed to do
this.  The function inserts linebreaks to separate tags that have
nothing but whitespace between them.  It then indents the markup
by using nxml's indentation rules."
  (interactive "r")
  (save-excursion
    (nxml-mode)
    (goto-char begin)
    (while (search-forward-regexp "\>[ \\t]*\<" nil t)
      (backward-char) (insert "\n") (setq end (1+ end)))
    (indent-region begin end))
  (message "Ah, much better!"))


(defun pretty-xml ()
    (interactive)
    (save-excursion
        (shell-command-on-region (point-min) (point-max) "xmllint --format -" (buffer-name) t)))

(setq uniquify-buffer-name-style 'forward)
(require 'uniquify)

(setq warning-suppress-types '(mule))


(autoload 'jss-connect "jss" "FIXME: Autoload all of jss on connect" t nil)

(defun remove-dos-eol ()
  "Do not show ^M in files containing mixed UNIX and DOS line endings."
  (interactive)
  (setq buffer-display-table (make-display-table))
  (aset buffer-display-table ?\^M []))

(global-set-key (kbd "C-c C-m") 'remove-dos-eol)

(add-hook 'text-mode-hook 'remove-dos-eol)
(add-hook 'opascal-mode-hook 'remove-dos-eol)
(add-hook 'opascal-mode-hook 'ggtags-mode)

(require 'smartparens-config)
(require 'smartparens-keys)
(add-hook 'prog-mode-hook 'turn-on-smartparens-mode)


(require 'flycheck-clojure)
(eval-after-load 'flycheck '(flycheck-clojure-setup))
(require 'clojure-mode-extra-font-locking)
(add-hook 'clojure-mode-hook #'subword-mode)
(add-hook 'clojure-mode-hook #'rainbow-delimiters-mode)

(defun init-clj-refactor ()
  (clj-refactor-mode 1)
  (yas-minor-mode 1) ; for adding require/use/import statements
  ;; This choice of keybinding leaves cider-macroexpand-1 unbound
  (cljr-add-keybindings-with-prefix "C-c C-m"))

(add-hook 'clojure-mode-hook #'init-clj-refactor)

;; Taken from
;; http://sachachua.com/blog/2006/09/emacs-changing-the-font-size-on-the-fly/
(defun sacha/increase-font-size ()
  (interactive)
  (set-face-attribute 'default
                      nil
                      :height
                      (ceiling (* 1.10
                                  (face-attribute 'default :height)))))
(defun sacha/decrease-font-size ()
  (interactive)
  (set-face-attribute 'default
                      nil
                      :height
                      (floor (* 0.9
                                  (face-attribute 'default :height)))))
(global-set-key (kbd "C-+") 'sacha/increase-font-size)
(global-set-key (kbd "C--") 'sacha/decrease-font-size)


;;
;; ace jump mode major function
;;
(autoload
  'ace-jump-mode
  "ace-jump-mode"
  "Emacs quick move minor mode"
  t)
;; you can select the key you prefer to
(define-key global-map (kbd "C-c SPC") 'ace-jump-mode)

(require 'expand-region)
(global-set-key (kbd "C-=") 'er/expand-region)

;;
;; enable a more powerful jump back function from ace jump mode
;;
(autoload
  'ace-jump-mode-pop-mark
  "ace-jump-mode"
  "Ace jump back:-)"
  t)
(eval-after-load "ace-jump-mode"
  '(ace-jump-mode-enable-mark-sync))
(define-key global-map (kbd "C-x SPC") 'ace-jump-mode-pop-mark)

(global-set-key (kbd "M-o") 'ag)
(global-set-key (kbd "M-O") 'ag-project)

;; Completion words longer than 4 characters
(custom-set-variables
  '(ac-ispell-requires 4)
  '(ac-ispell-fuzzy-limit 2))

(eval-after-load "auto-complete"
  '(progn
      (ac-ispell-setup)))

(add-hook 'git-commit-mode-hook 'ac-ispell-ac-setup)
(add-hook 'mail-mode-hook 'ac-ispell-ac-setup)
(add-hook 'text-mode-hook 'ac-ispell-ac-setup)
(add-hook 'text-mode-hook 'flyspell-mode)

(require 'sql-indent)
(add-hook 'sql-mode-hook 'sqlind-setup)

(require 'react-snippets)

(setenv "HGPLAIN" "1")
(require 'clj-refactor)

(dumb-jump-mode)

(require 'iedit)
;;; init.el ends here

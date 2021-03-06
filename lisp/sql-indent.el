;;; sql-indent.el --- Support for indenting code in SQL files.
;; Copyright (C) 2015 Alex Harsanyi
;;
;; Author: Alex Harsanyi (AlexHarsanyi@gmail.com)
;; Created: 27 Sep 2006
;; Version: 1.0
;; Keywords: languages sql
;; Homepage: https://github.com/alex-hhh/emacs-sql-indent
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

;;; Commentary:
;;
;; Add suport for smart indentation when editing SQL files.  It is intended to
;; work as an "add on" to the existing sql-mode. This file defines the
;; `sqlind-indent-line' function that is suitable as a value for
;; `indent-line-function'.
;;
;; To use it, install the package, than add the following to your ~/.emacs.el:
;;
;; (eval-after-load "sql" '(progn (add-hook 'sql-mode-hook 'sqlind-setup)))
;;
;; To adjust the indentation, see `sqlind-basic-offset' and
;; `sqlind-indentation-offsets-alist' variables.

;;; Code:

(require 'sql)
(eval-when-compile (require 'cc-defs))  ; for c-point

;;;; General setup

(defvar sqlind-syntax-table
  (let ((table (make-syntax-table)))
    ;; C-style comments /**/ (see elisp manual "Syntax Flags"))
    (modify-syntax-entry ?/ ". 14" table)
    (modify-syntax-entry ?* ". 23" table)
    ;; double-dash starts comment
    (modify-syntax-entry ?- ". 12b" table)
    ;; newline and formfeed end coments
    (modify-syntax-entry ?\n "> b" table)
    (modify-syntax-entry ?\f "> b" table)
    ;; single quotes (') quotes delimit strings
    (modify-syntax-entry ?' "\"" table)
    ;; backslash is no escape character
    (modify-syntax-entry ?\\ "." table)

    ;; the following are symbol constituents.  Note that the dot '.'  is more
    ;; usefull as a symbol constituent than as a punctuation char.

    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?. "_" table)
    (modify-syntax-entry ?$ "_" table)
    (modify-syntax-entry ?# "_" table)
    (modify-syntax-entry ?% "_" table)

    table)
  "Syntax table used in `sql-mode' for editing SQL code.")


;;;; Syntactic analysis of SQL code

;;;;; Commentary

;; The following routines perform rudimentary syntactical analysis of SQL
;; code.  The indentation engine decides how to indent based on what this code
;; returns.  The main function is `sqlind-syntax-of-line'.
;;
;; To examine the syntax of the current line, you can use the
;; `sqlind-show-syntax-of-line'.  This is only useful if you want to debug this
;; package or are just curious.

;;;;; Utilities

(defconst sqlind-comment-start-skip "\\(--+\\|/\\*+\\)\\s *"
  "Regexp to match the start of a SQL comment.")

(defconst sqlind-comment-end "\\*+\\/"
  "Regexp to match the end of a multiline SQL comment.")

(defvar sqlind-comment-prefix "\\*+\\s "
  "Regexp to match the line prefix inside comments.
This is used to indent multi-line comments.")

(defsubst sqlind-in-comment-or-string (pos)
  "Return non nil if POS is inside a comment or a string.
We actually return 'string if POS is inside a string, 'comment if
POS is inside a comment, nil otherwise."
  (syntax-ppss-context (syntax-ppss pos)))

(defun sqlind-backward-syntactic-ws ()
  "Move point backwards over whitespace and comments.
Leave point on the first character which is not syntactic
whitespace, or at the beginning of the buffer."
  (catch 'done
    (while t
      (skip-chars-backward " \t\n\r\f\v")
      (unless (eq (point) (point-min))
	(forward-char -1))
      (let ((pps (syntax-ppss (point))))
	(if (nth 4 pps)                 ; inside a comment?
	    (goto-char (nth 8 pps))     ; move to comment start than repeat
	    (throw 'done (point))       ; done
	    )))))

(defun sqlind-forward-syntactic-ws ()
  "Move point forward over whitespace and comments.
Leave point at the first character which is not syntactic
whitespace, or at the end of the buffer."
  ;; if we are inside a comment, move to the comment start and scan
  ;; from there.
  (let ((pps (syntax-ppss (point))))
    (when (nth 4 pps)
      (goto-char (nth 8 pps))))
  (catch 'done
    (while t
      (skip-chars-forward " \t\n\r\f\v")
      (cond ((looking-at sqlind-comment-start-skip) (forward-comment 1))
            ;; a slash ("/") by itself is a SQL*plus directive and
            ;; counts as whitespace
            ((looking-at "/\\s *$") (goto-char (match-end 0)))
            (t (throw 'done (point)))))))

(defun sqlind-match-string (pos)
  "Return the match data at POS in the current buffer.
This is similar to `match-data', but the text is fetched without
text properties and it is conveted to lower case."
  (let ((start (match-beginning pos))
	(end (match-end pos)))
    (when (and start end)
      (downcase (buffer-substring-no-properties start end)))))

(defsubst sqlind-labels-match (lb1 lb2)
  "Return t when LB1 equals LB2 or LB1 is an empty string.
This is used to compare start/end block labels where the end
block label might be empty."
  (or (string= lb1 lb2)
      (string= lb1 "")))

(defun sqlind-same-level-statement (point start)
  "Return t if POINT is at the same syntactic level as START.
This means that POINT is at the same nesting level and not inside
a strinf or comment."
  (let ((parse-info (parse-partial-sexp start point)))
    (not (or (nth 3 parse-info)                 ; inside a string
	     (nth 4 parse-info)                 ; inside a comment
	     (> (nth 0 parse-info) 0))))) ; inside a nested paren

;;;;; Find the beginning of the current statement

(defconst sqlind-sqlplus-directive
  (concat "^"
	  (regexp-opt '("column" "set" "rem" "define" "spool") t)
	  "\\b")
  "Match an SQL*Plus directive at the beginning of a line.
A directive always stands on a line by itself -- we use that to
determine the statement start in SQL*Plus scripts.

NOTE: we don't allow spaces at the beginning of line, as that
would conflict with the 'set' keyword in an update statement.")

(defconst sqlind-sqlite-directive
  "^[.].*?\\>"
  "Match an SQLite directive at the beginning of a line.
A directive always stands on a line by itself -- we use that to
determine the statement start in SQLite scripts.

NOTE: we don't allow spaces at the beginning of line, as that
would conflict with the 'set' keyword in an update statement.")

(defconst sqlind-ms-directive
  (concat "^"
          (regexp-opt '("declare") t)
          "\\>")
  "Match an MS SQL Sever directive at the beginning of a line.")

(defun sqlind-begining-of-directive ()
  "Return the position of an SQL directive, or nil.
We will never move past one of these in our scan.  We also assume
they are one-line only directives."
  (when (boundp 'sql-product)
    (let ((rx (case sql-product
                (ms sqlind-ms-directive)
                (sqlite sqlind-sqlite-directive)
                (oracle sqlind-sqlplus-directive)
                (t nil))))
      (when rx
        (save-excursion
          (when (re-search-backward rx nil 'noerror)
            (forward-line 1)
            (point)))))))

(defun sqlind-beginning-of-statement-1 (limit)
  "Return the position of a block start, or nil.
But don't go before LIMIT."
  (save-excursion
    (catch 'done
      (while (not (eq (point) (or limit (point-min))))
        (when (re-search-backward
               ";\\|begin\\b\\|loop\\b\\|then\\b\\|else\\b\\|)"
               limit 'noerror)
          (let ((candidate-pos (match-end 0)))
            (cond ((looking-at ")")
                   ;; Skip parenthesis expressions, we don't want to find one
                   ;; of the keywords inside one of them and think this is a
                   ;; statement start.
                   (progn (forward-char 1) (forward-sexp -1)))
                  ((looking-at "\\bthen\\|else\\b")
                   ;; then and else start statements when they are inside
                   ;; blocks, not expressions.
                   (sqlind-backward-syntactic-ws)
                   (when (looking-at ";")
                     (throw 'done candidate-pos)))
                  ((not (sqlind-in-comment-or-string (point)))
                   (throw 'done candidate-pos)))))))))

(defun sqlind-beginning-of-statement ()
  "Move point to the beginning of the current statement."
  (interactive)
  (let* ((directive-start (sqlind-begining-of-directive))
         (statement-start
          (or
           ;; If we are inside a paranthesis expression, the start is the
           ;; start of that expression.
           (let ((ppss (syntax-ppss (point))))
             (when (> (nth 0 ppss) 0)
               (nth 1 ppss)))
           ;; Look for an ordinary statement start
           (sqlind-beginning-of-statement-1 directive-start)
           ;; Fall back on the directive position...
           directive-start
           ;; ... or point-min
           (point-min))))

    (goto-char statement-start)

    ;; a loop keyword might be part of an "end loop" statement, in that case,
    ;; the statement starts with the "end" keyword.  we use
    ;; skip-syntax-backward so we won't skip over a semicolon (;)
    (skip-syntax-backward "w")
    (when (looking-at "loop")
      (forward-word -1)
      (if (looking-at "\\bend\\b")
          (setq statement-start (match-beginning 0))))

    ;; now skip over any whitespace and comments until we find the
    ;; first character that is program code.
    (goto-char statement-start)
    (sqlind-forward-syntactic-ws)))

;;;;; Find the syntax and beginning of the current block

(defconst sqlind-end-statement-regexp
  "end\\_>\\(?:[ \n\r\t]*\\)\\(if\\_>\\|loop\\_>\\|case\\_>\\)?\\(?:[ \n\r\f]*\\)\\([a-z0-9_]+\\)?\\(?:[ \n\r\f]*\\);"
  "Match an end of statement.")

(defvar sqlind-end-stmt-stack nil
  "Stack of end-of-statement positions.
This is used by the sqlind-maybe-* functions to skip over SQL
programming blocks.  This variable is dynamically bound.")

(defun sqlind-maybe-end-statement ()
  "Look for SQL end statements return t if found one.
If (point) is at an end statement, add it to the
`sqlind-end-stmt-stack' and return t, otherwise return nil.

See also `sqlind-beginning-of-block'"
  (when (looking-at sqlind-end-statement-regexp)
    (prog1 t                            ; make sure we return t
      (let ((kind (or (sqlind-match-string 1) ""))
	    (label (or (sqlind-match-string 2) "")))
	(push (list (point) (if (equal kind "") nil (intern kind)) label)
	      sqlind-end-stmt-stack)))))

(defun sqlind-maybe-then-statement ()
  "When (point) is on a THEN statement, find the corresponding
start of the block and report its syntax.  This code will skip
over nested statements to determine the actual start.

Only keywords in program code are matched, not the ones inside
expressions.

See also `sqlind-beginning-of-block'"
  (when (looking-at "then")
    (prog1 t                            ; make sure we return t
      (let ((start-pos (point)))

	;; a then keyword at the begining of a line is a block start
	(when (null sqlind-end-stmt-stack)
	  (save-excursion
	    (back-to-indentation)
	    (when (eq (point) start-pos)
	      (throw 'finished (list 'in-block 'then "")))))

	;; if it is not at the beginning of a line, the beginning of
	;; the statement is the block start
	(ignore-errors (forward-char -1))
	(sqlind-beginning-of-statement)
	;; a then keyword only starts a block when it is part of an
	;; if, case/when or exception statement
	(cond
	  ((looking-at "\\(<<[a-z0-9_]+>>\\)?\\(?:[ \n\r\f]*\\)\\(\\(?:els\\)?if\\)\\_>")
	   (let ((if-label (sqlind-match-string 1))
		 (if-kind (intern (sqlind-match-string 2)))) ; can be if or elsif
	     (setq if-label (if if-label (substring if-label 2 -2) ""))
	     (if (null sqlind-end-stmt-stack)
		 (throw 'finished (list 'in-block if-kind if-label))
		 ;; "if" blocks (but not "elsif" blocks) need to be
		 ;; ended with "end if"
		 (when (eq if-kind 'if)
		   (destructuring-bind (pos kind label)
		       (pop sqlind-end-stmt-stack)
		     (unless (and (eq kind 'if)
				  (sqlind-labels-match label if-label))
		       (throw 'finished
			 (list 'syntax-error
			       "bad closing for if block" (point) pos))))))))
	  ((looking-at "\\(<<[a-z0-9_]+>>\\)?\\(?:[ \n\r\f]*\\)case\\_>")
	   ;; find the nearest when block, but only if there are no
	   ;; end statements in the stack
	   (let ((case-label (sqlind-match-string 1)))
	     (setq case-label
		   (if case-label (substring case-label 2 -2) ""))
	     (if (null sqlind-end-stmt-stack)
		 (let ((limit (point)))
		   (goto-char start-pos)
		   (while (re-search-backward "\\_<when\\_>" limit 'noerror)
		     (unless (sqlind-in-comment-or-string (point))
		       (throw 'finished
			 (list 'in-block 'case case-label)))))
		 ;; else
		 (destructuring-bind (pos kind label)
		     (pop sqlind-end-stmt-stack)
		   (unless (and (eq kind 'case)
				(sqlind-labels-match label case-label))
		     (throw 'finished
		       (list 'syntax-error
			     "bad closing for case block" (point) pos)))))))
	  ((looking-at "exception\\_>")
	   ;; an exception statement is a block start only if we have
	   ;; no end statements in the stack
	   (when (null sqlind-end-stmt-stack)
	     (throw 'finished (list 'in-block 'exception "")))))))))

(defun sqlind-maybe-else-statement ()
  "If (point) is on an ELSE statement, report its syntax.
Only keywords in program code are matched, not the ones inside
expressions.

See also `sqlind-beginning-of-block'"
  ;; an else statement is only a block start if the `sqlind-end-stmt-stack' is
  ;; empty, otherwise, we don't do anything.
  (when (and (looking-at "els\\(e\\|if\\)")
	     (null sqlind-end-stmt-stack))
    (throw 'finished (list 'in-block (intern (sqlind-match-string 0)) ""))))

(defun sqlind-maybe-loop-statement ()
  "If (point) is on a LOOP statement, report its syntax.
Only keywords in program code are matched, not the ones inside
expressions.

See also `sqlind-beginning-of-block'"
  (when (looking-at "loop")
    (prog1 t                          ; make sure we return t
      (sqlind-beginning-of-statement)
      ;; note that we might have found a loop in an "end loop;" statement.
      (or (sqlind-maybe-end-statement)
          (progn
            (let ((loop-label (if (looking-at "<<\\([a-z0-9_]+\\)>>")
                                  (sqlind-match-string 1) "")))
              ;; start of loop.  this always starts a block, we only check if
              ;; the labels match
              (if (null sqlind-end-stmt-stack)
                  (throw 'finished (list 'in-block 'loop loop-label))
                  (destructuring-bind (pos kind label)
                      (pop sqlind-end-stmt-stack)
                    (unless (and (eq kind 'loop)
                                 (sqlind-labels-match label loop-label))
                      (throw 'finshed
                        (list 'syntax-error
                              "bad closing for loop block" (point) pos)))))))))))

(defun sqlind-maybe-begin-statement ()
  "If (point) is on a BEGIN statement, report its syntax
Only keywords in program code are matched, not the ones inside
expressions.

See also `sqlind-beginning-of-block'"
  (when (looking-at "begin")
    ;; a begin statement starts a block unless it is the first begin in a
    ;; procedure over which we need to skip it.
    (prog1  t                           ; make sure we return t
      (let* ((saved-pos (point))
	     (begin-label (save-excursion
			    (sqlind-beginning-of-statement)
			    (if (looking-at "<<\\([a-z0-9_]+\\)>>\\_>")
				(sqlind-match-string 1) "")))
	     (previous-block (save-excursion
			       (forward-char -1)
			       (cons (sqlind-beginning-of-block) (point))))
	     (previous-block-kind (nth 0 previous-block)))

	(goto-char saved-pos)
	(when (null sqlind-end-stmt-stack)
	  (throw 'finished
	    (cond ((memq previous-block-kind '(toplevel declare-statement))
		   (list 'in-begin-block 'toplevel-block begin-label))
		  ((and (listp previous-block-kind)
			(eq (nth 0 previous-block-kind) 'defun-start))
		   (list 'in-begin-block 'defun (nth 1 previous-block-kind)))
		  (t
		   (list 'in-begin-block nil begin-label)))))

	(destructuring-bind (pos kind label) (pop sqlind-end-stmt-stack)
	  (cond
	    (kind
	     (throw 'finished
	       (list 'syntax-error "bad closing for begin block" (point) pos)))

	    ((not (equal begin-label ""))
	     ;; we have a begin label.  In this case it must match the end
	     ;; label
	     (unless (equal begin-label label)
	       (throw 'finished
		 (list 'syntax-error "mismatched block labels" (point) pos))))

	    (t
	     ;; we don't have a begin label.  In this case, the begin
	     ;; statement might not start a block if it is the begining of a
	     ;; procedure or declare block over which we need to skip.

	     (cond ((memq previous-block-kind '(toplevel declare-statement))
		    (goto-char (cdr previous-block)))
		   ((and (listp previous-block-kind)
			 (eq (nth 0 previous-block-kind) 'defun-start))
		    (unless (sqlind-labels-match
			     label (nth 1 previous-block-kind))
		      (throw 'finished
			(list 'syntax-error
			      "bad end label for defun" (point) pos)))
		    (goto-char (cdr previous-block)))))))))))

(defun sqlind-maybe-declare-statement ()
  "If (point) is on a DECLARE statement, report its syntax.
Only keywords in program code are matched, not the ones inside
expressions, also we don't match DECLARE directives here.

See also `sqlind-beginning-of-block'"
  (when (looking-at "declare")
    ;; a declare block is always toplevel, if it is not, its an error
    (throw 'finished
      (if (null sqlind-end-stmt-stack)
	  'declare-statement
	  (list 'syntax-error "nested declare block" (point) (point))))))

(defun sqlind-maybe-create-statement ()
  "If (point) is on a CREATE statement, report its syntax.
See also `sqlind-beginning-of-block'"
  (when (looking-at "create\\_>\\(?:[ \n\r\f]+\\)\\(or\\(?:[ \n\r\f]+\\)replace\\_>\\)?")
    (prog1 t                            ; make sure we return t
      (save-excursion
	;; let's see what are we creating
	(goto-char (match-end 0))
        (sqlind-forward-syntactic-ws)
	(let ((what (intern (downcase (buffer-substring-no-properties
				       (point)
				       (progn (forward-word) (point))))))
	      (name (downcase (buffer-substring-no-properties
			       (progn (sqlind-forward-syntactic-ws) (point))
			       (progn (skip-syntax-forward "w_") (point))))))
	  (when (and (eq what 'package) (equal name "body"))
	    (setq what 'package-body)
	    (setq name (downcase
			(buffer-substring-no-properties
			 (progn (sqlind-forward-syntactic-ws) (point))
			 (progn (skip-syntax-forward "w_") (point))))))

	  (if (memq what '(procedure function package package-body))
	    (if (null sqlind-end-stmt-stack)
		(throw 'finished
		  (list (if (memq what '(procedure function)) 'defun-start what)
			name))
		(destructuring-bind (pos kind label) (pop sqlind-end-stmt-stack)
		  (when (not (eq kind nil))
		    (throw 'finished
		      (list 'syntax-error
			    "bad closing for create block" (point) pos)))
		  (unless (sqlind-labels-match label name)
		    (throw 'finished
		      (list 'syntax-error
			    "label mismatch in create block" (point) pos)))))
	    ;; we are creating a non-code block thing: table, view,
	    ;; index, etc.  These things only exist at toplevel.
	    (unless (null sqlind-end-stmt-stack)
	      (throw 'finised
		(list 'syntax-error "nested create statement" (point) (point))))
	    (throw 'finished (list 'create-statement what name))))))))

(defun sqlind-maybe-defun-statement ()
  "If (point) is on a procedure definition statement, report its syntax.
See also `sqlind-beginning-of-block'"
  (catch 'exit
    (when (looking-at "\\(procedure\\|function\\)\\(?:[ \n\r\f]+\\)\\([a-z0-9_]+\\)")
      (prog1 t                          ; make sure we return t
	(let ((proc-name (sqlind-match-string 2)))
	  ;; need to find out if this is a procedure/function
	  ;; declaration or a definition
	  (save-excursion
	    (goto-char (match-end 0))
            (sqlind-forward-syntactic-ws)
	    ;; skip param list, if any.
	    (when (looking-at "(") (ignore-errors (forward-sexp 1)))
	    (sqlind-forward-syntactic-ws)
	    (when (looking-at ";")
	      ;; not a procedure after all.
	      (throw 'exit nil)))

	  ;; so it is a definition

	  ;; if the procedure starts with "create or replace", move
	  ;; point to the real start
	  (let ((real-start (point)))
	    (save-excursion
	      (forward-word -1)
	      (when (looking-at "replace")
		(forward-word -2))
	      (when (and (looking-at "create\\([ \t\r\n\f]+or[ \t\r\n\f]+replace\\)?")
			 (not (sqlind-in-comment-or-string (point))))
		(setq real-start (point))))
	    (goto-char real-start))

	  (when (null sqlind-end-stmt-stack)
	    (throw 'finished (list 'defun-start proc-name)))

	  (destructuring-bind (pos kind label) (pop sqlind-end-stmt-stack)
	    (unless (and (eq kind nil)
			 (sqlind-labels-match label proc-name))
	      (throw 'finished
		(list 'syntax-error "bad end label for defun" (point) pos)))))))))

(defconst sqlind-start-block-regexp
  (concat "\\(\\b"
	  (regexp-opt '("then" "else" "elsif" "loop"
			"begin" "declare" "create"
			"procedure" "function" "end") t)
	  "\\b\\)\\|)")
  "regexp to match the start of a block")

(defun sqlind-beginning-of-block (&optional end-statement-stack)
  "Find the start of the current block and return its syntax."
  (interactive)
  (catch 'finished
    (let ((sqlind-end-stmt-stack end-statement-stack))
      (while (re-search-backward sqlind-start-block-regexp nil 'noerror)
	(or (sqlind-in-comment-or-string (point))
	    (when (looking-at ")") (forward-char 1) (forward-sexp -1) t)
	    (sqlind-maybe-end-statement)
	    (sqlind-maybe-then-statement)
	    (sqlind-maybe-else-statement)
	    (sqlind-maybe-loop-statement)
	    (sqlind-maybe-begin-statement)
	    (sqlind-maybe-declare-statement)
	    (sqlind-maybe-create-statement)
	    (sqlind-maybe-defun-statement))))
    'toplevel))

;;;;; Determine the syntax inside a case expression

(defconst sqlind-case-clauses-regexp
  "\\_<\\(when\\|then\\|else\\|end\\)\\_>")

(defun sqlind-syntax-in-case (pos start)
  "Return the syntax inside a CASE expression begining at START."
  (save-excursion
    (goto-char pos)
    (cond ((looking-at "when\\|end")
           ;; A WHEN, or END clause is indented relative to the start of the case
           ;; expression
           (cons 'case-clause start))
          ((looking-at "then\\|else")
           ;; THEN and ELSE clauses are indented relative to the start of the
           ;; when clause, which we must find
           (while (not (and (re-search-backward "\\bwhen\\b")
                            (sqlind-same-level-statement (point) start)))
             nil)
           (cons 'case-clause-item (point)))
          (t
           ;; It is a statement continuation from the closest CASE element
           (while (not (and (re-search-backward sqlind-case-clauses-regexp start 'noerror)
                            (sqlind-same-level-statement (point) start)))
             nil)
           (cons 'case-clause-item-cont (point))))))

;;;;; Determine the syntax inside a with statement

(defconst sqlind-with-clauses-regexp
  "\\_<\\(with\\|recursive\\)\\_>")

(defun sqlind-syntax-in-with (pos start)
  "Return the syntax inside a WITH statement beginning at START."
  (save-excursion
    (catch 'finished
      (goto-char pos)
      (cond
        ((looking-at sqlind-with-clauses-regexp)
         (throw 'finished (cons 'with-clause start)))
        ((and (looking-at "\\_<select\\_>")
              (sqlind-same-level-statement (point) start))
         (throw 'finished (cons 'with-clause start))))
      (while (re-search-backward "\\_<select\\_>" start 'noerror)
        (when (sqlind-same-level-statement (point) start)
          (throw 'finished (sqlind-syntax-in-select pos (point)))))
      (goto-char pos)
      (when (looking-at "\\_<as\\_>")
        (throw 'finished (cons 'with-clause-cte-cont start)))
      (sqlind-backward-syntactic-ws)
      (when (looking-at ",")
        (throw 'finished (cons 'with-clause-cte start)))
      (forward-word -1)
      (when (looking-at sqlind-with-clauses-regexp)
        ;; We're right after the with (recursive keyword)
        (throw 'finished (cons 'with-clause-cte start)))
      (throw 'finished (cons 'with-clause-cte-cont start)))))

;;;;; Determine the syntax inside a select statement

(defconst sqlind-select-clauses-regexp
  (concat
   "\\_<\\("
   "\\(union\\|intersect\\|minus\\)?[ \t\r\n\f]*select\\|"
   "\\(bulk[ \t\r\n\f]+collect[ \t\r\n\f]+\\)?into\\|"
   "from\\|"
   "where\\|"
   "order[ \t\r\n\f]+by\\|"
   "having\\|"
   "group[ \t\r\n\f]+by"
   "\\)\\_>"))

(defconst sqlind-select-join-regexp
  (concat "\\b"
	  (regexp-opt '("inner" "left" "right" "natural" "cross") t)
	  "[ \t\r\n\f]*join"
	  "\\b"))

(defun sqlind-syntax-in-select (pos start)
  "Return the syntax inside a SELECT statement beginning at START"
  (save-excursion
    (catch 'finished
      (goto-char pos)

      ;; all select query components are indented relative to the
      ;; start of the select statement)
      (when (looking-at sqlind-select-clauses-regexp)
	(throw 'finished (cons 'select-clause start)))

      ;; when we are not looking at a select component, find the
      ;; nearest one from us.

      (while (re-search-backward sqlind-select-clauses-regexp start t)
	(let* ((match-pos (match-beginning 0))
	       (clause (sqlind-match-string 0)))
	  (setq clause (replace-regexp-in-string "[ \t\r\n\f]" " " clause))
	  (when (sqlind-same-level-statement (point) start)
	    (cond
	      ((looking-at "select\\(\\s *\\_<\\(top\\s +[0-9]+\\|distinct\\|unique\\)\\_>\\)?")
	       ;; we are in the column selection section.
	       (goto-char pos)
	       (sqlind-backward-syntactic-ws)
	       (throw 'finished
		 (cons (if (or (eq (match-end 0) (1+ (point)))
			       (looking-at ","))
			   'select-column
			   'select-column-continuation)
		       match-pos)))

	      ((looking-at "from")
	       ;; FROM is only keyword if the previous char is NOT a
	       ;; comma ','
	       (forward-char -1)
	       (sqlind-backward-syntactic-ws)
	       (unless (looking-at ",")
		 ;; yep, we are in the from section.
		 ;; if this line starts with 'on' or the previous line
		 ;; ends with 'on' we have a join condition
		 (goto-char pos)
		 (when (or (looking-at "on")
			   (progn (forward-word -1) (looking-at "on")))
		   ;; look for the join start, that will be the anchor
		   (while (re-search-backward sqlind-select-join-regexp start t)
		     (unless (sqlind-in-comment-or-string (point))
		       (throw 'finished
			 (cons 'select-join-condition (point))))))

		 ;; if this line starts with a ',' or the previous
		 ;; line starts with a ',', we have a new table
		 (goto-char pos)
		 (when (or (looking-at ",")
			   (progn
                             (sqlind-backward-syntactic-ws)
			     (looking-at ",")))
		   (throw 'finished (cons 'select-table match-pos)))

		 ;; otherwise, we continue the table definition from
		 ;; the previous line.
		 (throw 'finished (cons 'select-table-continuation match-pos))))

	      (t
	       (throw 'finished
		 (cons (list 'in-select-clause clause) match-pos))))))))))


;;;;; Determine the syntax inside an insert statement

(defconst sqlind-insert-clauses-regexp
   "\\_<\\(insert\\([ \t\r\n\f]+into\\)?\\|values\\|select\\)\\_>")

(defun sqlind-syntax-in-insert (pos start)
  "Return the syntax inside an INSERT statement starting at START."

  ;; The insert clause is really easy since it has the form insert into TABLE
  ;; (COLUMN_LIST) values (VALUE_LIST) or insert into TABLE select
  ;; SELECT_CLAUSE
  ;;
  ;; note that we will never be called when point is in COLUMN_LIST or
  ;; VALUE_LIST, as that is a nested-statement-continuation which starts with
  ;; the open paranthesis.
  ;;
  ;; if we are inside the SELECT_CLAUSE, we delegate the syntax to
  ;; `sqlind-syntax-in-select'

  (save-excursion
    (catch 'finished
      (goto-char pos)

      ;; all select query components are indented relative to the
      ;; start of the select statement)
      (when (looking-at sqlind-insert-clauses-regexp)
	(throw 'finished (cons 'insert-clause start)))

      (while (re-search-backward sqlind-insert-clauses-regexp start t)
	(let* ((match-pos (match-beginning 0))
	       (clause (sqlind-match-string 0)))
	  (setq clause (replace-regexp-in-string "[ \t\r\n\f]" " " clause))
	  (when (sqlind-same-level-statement (point) start)
	    (throw 'finished
	      (if (looking-at "select")
		  (sqlind-syntax-in-select pos match-pos)
		  (cons (list 'in-insert-clause clause) match-pos)))))))))


;;;;; Determine the syntax inside a delete statement

(defconst sqlind-delete-clauses-regexp
   "\\_<\\(delete\\([ \t\r\n\f]+from\\)?\\|where\\|returning\\|\\(bulk[ \t\r\n\f]collect[ \t\r\n\f]\\)?into\\)\\_>")

(defun sqlind-syntax-in-delete (pos start)
  "Return the syntax inside a DELETE statement starting at START."
  (save-excursion
    (catch 'finished
      (goto-char pos)

      ;; all select query components are indented relative to the
      ;; start of the select statement)
      (when (looking-at sqlind-delete-clauses-regexp)
	(throw 'finished (cons 'delete-clause start)))

      (while (re-search-backward sqlind-delete-clauses-regexp start t)
	(let* ((match-pos (match-beginning 0))
	       (clause (sqlind-match-string 0)))
	  (setq clause (replace-regexp-in-string "[ \t\r\n\f]" " " clause))
	  (when (sqlind-same-level-statement (point) start)
	    (throw 'finished
	      (cons (list 'in-delete-clause clause) match-pos))))))))


;;;;; Determine the syntax inside an update statement

(defconst sqlind-update-clauses-regexp
  "\\_<\\(update\\|set\\|where\\)\\_>")

(defun sqlind-syntax-in-update (pos start)
  "Return the syntax inside an UPDATE statement starting at START."
  (save-excursion
    (catch 'finished
      (goto-char pos)

      ;; all select query components are indented relative to the start of the
      ;; select statement)
      (when (looking-at sqlind-update-clauses-regexp)
	(throw 'finished (cons 'update-clause start)))

      (while (re-search-backward sqlind-update-clauses-regexp start t)
	(let* ((match-pos (match-beginning 0))
	       (clause (sqlind-match-string 0)))
	  (setq clause (replace-regexp-in-string "[ \t\r\n\f]" " " clause))
	  (when (sqlind-same-level-statement (point) start)
	    (throw 'finished
	      (cons (list 'in-update-clause clause) match-pos))))))))


;;;;; Refine the syntax of an end statement.

(defun sqlind-refine-end-syntax (end-kind end-label end-pos context)
  (catch 'done

    (when (null context)                ; can happen
      (throw 'done
        (cons (list 'syntax-error "end statement closes nothing"
                    end-pos end-pos)
              end-pos)))

    (let* ((syntax (car (car context)))
	   (anchor (cdr (car context)))
	   (syntax-symbol (if (symbolp syntax) syntax (nth 0 syntax))))
      (cond
	((memq syntax-symbol '(package package-body))
	 ;; we are closing a package declaration or body, `end-kind' must be
	 ;; empty, `end-label' can be empty or it must match the package name
	 (throw 'done
	   (cons
	    (cond (end-kind   ; no end-kind is allowed for a package
		   (list 'syntax-error
			 "bad closing for package" anchor end-pos))
		  ((sqlind-labels-match end-label (nth 1 syntax))
		   (list 'block-end syntax-symbol (nth 1 syntax)))
		  (t
		   (list 'syntax-error "mismatched end label for package"
			 anchor end-pos)))
	    anchor)))

	((eq syntax-symbol 'in-begin-block)
	 ;; we are closing a begin block (either toplevel, procedure/function
	 ;; or a simple begin block.  `end-kind' must be empty, `end-label'
	 ;; can be empty or it must match the pakage-name
	 (let ((block-label (nth 2 syntax)))
	   (throw 'done
	     (cons
	      (cond (end-kind ; no end-kind is allowed for a begin block
		     (list 'syntax-error
			   "bad closing for begin block" anchor end-pos))
		    ((sqlind-labels-match end-label block-label)
		     (list 'block-end (nth 1 syntax) block-label))
		    (t
		     (list 'syntax-error "mismatched end label for block"
			   anchor end-pos)))
	      anchor))))

	((eq syntax-symbol 'in-block)
	 (let ((block-kind (nth 1 syntax))
	       (block-label (nth 2 syntax)))
	   (cond
	     ((eq block-kind 'exception)
	      (goto-char anchor)
	      (forward-line -1)
	      (throw 'done
		(sqlind-refine-end-syntax
		 end-kind end-label end-pos (sqlind-syntax-of-line))))

	     ((eq block-kind 'loop)
	      (throw 'done
		(cons
		 (cond ((not (eq end-kind 'loop))
			(list 'syntax-error "bad closing for loop block"
			      anchor end-pos))
		       ((not (sqlind-labels-match end-label block-label))
			(list 'syntax-error "mismatched end label for loop"
			      anchor end-pos))
		       (t
			(list 'block-end block-kind block-label)))
		 anchor)))

	     ((eq block-kind 'then)
	      (goto-char anchor)

	      (catch 'found
		(while t
		  (let ((then-context (sqlind-syntax-of-line)))
		    (goto-char (cdar then-context))
		    (cond
		      ((looking-at "when\\_>\\|then\\_>") t)
		      ((looking-at "\\(?:<<\\([a-z0-9_]+\\)>>[ \t\r\n\f]*\\)?\\_<\\(if\\|case\\)\\_>")
		       (throw 'found t))
		      (t
		       (throw 'done
			 (cons
			  (list 'syntax-error "bad syntax start for then keyword"
				(point) (point))
			  anchor)))))))

	      (let ((start-label (or (sqlind-match-string 1) ""))
		    (start-kind (intern (sqlind-match-string 2))))
		(throw 'done
		  (cons
		   (cond ((not (or (null end-kind) (eq end-kind start-kind)))
			  (list 'syntax-error "bad closing for if/case block"
				(point) end-pos))
			 ((not (sqlind-labels-match end-label start-label))
			  (list 'syntax-error "mismatched labels for if/case block"
				(point) end-pos))
			 (t
			  (list 'block-end start-kind start-label)))
		   anchor))))

	     ((eq block-kind 'else)
	      ;; search the enclosing then context and refine form there.  The
	      ;; `cdr' in sqlind-syntax-of-line is used to remove the
	      ;; block-start context for the else clause
	      (goto-char anchor)
	      (throw 'done
		(sqlind-refine-end-syntax
		 end-kind end-label end-pos (cdr (sqlind-syntax-of-line)))))

	     ((memq block-kind '(if case))
	      (throw 'done
		(cons
		 (cond ((not (eq end-kind block-kind))
			(list 'syntax-error "bad closing for if/case block"
			      anchor end-pos))
		       ((not (sqlind-labels-match end-label block-label))
			(list 'syntax-error
			      "bad closing for if/case block (label mismatch)"
			      anchor end-pos))
		       (t (list 'block-end block-kind block-label)))
		 anchor)))
	     )))

	((memq syntax-symbol '(block-start comment-start))
	 ;; there is a more generic context following one of these
	 (throw 'done
	   (sqlind-refine-end-syntax
	    end-kind end-label end-pos (cdr context))))

	((eq syntax-symbol 'defun-start)
	 (throw 'done
	   (cons
	    (if (and (null end-kind)
		     (sqlind-labels-match end-label (nth 1 syntax)))
		(list 'block-end 'defun end-label)
		(list 'syntax-error "mismatched end label for defun"
		      anchor end-pos))
	    anchor)))

	((eq syntax-symbol 'block-end)
	 (goto-char anchor)
	 (forward-line -1)
	 (throw 'done
	   (sqlind-refine-end-syntax
	    end-kind end-label end-pos (sqlind-syntax-of-line)))))

      ;; if the above cond fell through, we have a syntax error
      (cons (list 'syntax-error "end statement closes nothing"
		  end-pos end-pos)
	    anchor))))


;;;;; sqlind-syntax-of-line

(defun sqlind-syntax-of-line ()
  "Return the syntax at the start of the current line.
The function returns a list of (SYNTAX . ANCHOR) cons cells.
SYNTAX is either a symbol or a list starting with a symbol,
ANCHOR is a buffer position which is the reference for the
SYNTAX. `sqlind-indentation-syntax-symbols' lists the syntax
symbols and their meaning.

Only the first element of this list is used for indentation, the
rest are 'less specific' syntaxes, mostly left in for debugging
purposes. "
  (save-excursion
    (let* ((pos (progn (back-to-indentation) (point)))
	   (context-start (progn (sqlind-beginning-of-statement) (point)))
	   (context (list (cons 'statement-continuation context-start)))
	   (have-block-context nil))

      (goto-char pos)
      (when (or (>= context-start pos)
		(save-excursion
		  (goto-char context-start)
		  (looking-at sqlind-start-block-regexp)))
	;; if we are at the start of a statement, or the nearest
	;; statement starts after us, make the enclosing block the
	;; starting context
        (setq have-block-context t)
	(let ((block-info (sqlind-beginning-of-block)))

          ;; certain kind of blocks end within a statement
          ;; (e.g. create view).  If we found one of those blocks and
          ;; it is not within our statement, we ignore the block info.

          (if (and (listp block-info)
                   (eq (nth 0 block-info) 'create-statement)
                   (not (memq (nth 1 block-info) '(function procedure)))
                   (not (eql context-start (point))))
              (progn 
                (setq context-start (point-min))
                (setq context (list (cons 'toplevel context-start))))
              ;; else
              (setq context-start (point))
              (setq context (list (cons block-info context-start))))))

      (let ((parse-info (parse-partial-sexp context-start pos)))
	(cond ((nth 4 parse-info)   ; inside a comment
	       (push (cons 'comment-continuation (nth 8 parse-info)) context))
	      ((nth 3 parse-info)   ; inside a string
	       (push (cons 'string-continuation (nth 8 parse-info)) context))
	      ((> (nth 0 parse-info) 0) ; nesting
	       (let ((start (nth 1 parse-info)))
		 (goto-char (1+ start))
		 (skip-chars-forward " \t\r\n\f\v" pos)
		 (push (cons
			(if (eq (point) pos)
			    'nested-statement-open
			    'nested-statement-continuation)
			start)
		       context)))))

      ;; now let's refine the syntax by adding info about the current line
      ;; into the mix.

      (let* ((most-inner-syntax (car context))
	     (syntax (car most-inner-syntax))
	     (anchor (cdr most-inner-syntax))
	     (syntax-symbol (if (symbolp syntax) syntax (nth 0 syntax))))
        
        (goto-char pos)
        
	(cond
	  ;; do we start a comment?
	  ((and (not (eq syntax-symbol 'comment-continuation))
		(looking-at sqlind-comment-start-skip))
	   (push (cons 'comment-start anchor) context))

	  ;; Refine a statement continuation
	  ((memq syntax-symbol '(statement-continuation nested-statement-continuation))

	   ;; a (nested) statement continuation which starts with loop
	   ;; or then is a block start
	   (if (and have-block-context (looking-at "\\(loop\\|then\\|when\\)\\_>"))
	       (push (cons (list 'block-start (intern (sqlind-match-string 0))) anchor)
		     context)
	       ;; else
	       (goto-char anchor)
	       (when (eq syntax 'nested-statement-continuation)
		 (forward-char 1)
		 (skip-chars-forward " \t\r\n\f\v")
		 (setq anchor (point)))

	       ;; when all we have before `pos' is a label, we have a
	       ;; labeled-statement-start
	       (if (looking-at "<<\\([a-z0-9_]+\\)>>")
		   (progn
		     (goto-char (match-end 0))
		     (forward-char 1)
                     (sqlind-forward-syntactic-ws)
		     (when (eq (point) pos)
		       (push (cons 'labeled-statement-start anchor) context)))

		   ;; else, maybe we have a DML statement (select, insert,
		   ;; update and delete)

		   ;; skip a cursor definition if it is before our point
		   (when (looking-at "cursor[ \t\r\n\f]+[a-z0-9_]+[ \t\r\n\f]+is[ \t\r\n\f]+")
		     (when (<= (match-end 0) pos)
		       (goto-char (match-end 0))))

		   ;; skip a forall statement if it is before our point
		   (when (looking-at "forall\\b")
		     (when (re-search-forward "\\b\\(select\\|update\\|delete\\|insert\\)\\b" pos 'noerror)
		       (goto-char (match-beginning 0))))

		   ;; only check for syntax inside DML clauses if we are not
		   ;; at the start of one.
		   (when (< (point) pos)
		     (cond
                       ;; NOTE: We only catch here "CASE" clauses which start
                       ;; inside a nested paranthesis
                       ((looking-at "case")
                        (push (sqlind-syntax-in-case pos (point)) context))
                       ((looking-at "with")
                        (push (sqlind-syntax-in-with pos (point)) context))
		       ((looking-at "select")
			(push (sqlind-syntax-in-select pos (point)) context))
		       ((looking-at "insert")
			(push (sqlind-syntax-in-insert pos (point)) context))
		       ((looking-at "delete")
			(push (sqlind-syntax-in-delete pos (point)) context))
		       ((looking-at "update")
			(push (sqlind-syntax-in-update pos (point)) context))))

                   ;; (when (eq (car (car context)) 'select-column-continuation)
                   ;;   ;; case expressions can show up here, maybe refine this
                   ;;   ;; syntax
                   ;;   t
                   ;;   )

                   )))

	  ;; create block start syntax if needed

	  ((and (eq syntax-symbol 'in-block)
		(memq (nth 1 syntax) '(if elsif then case))
		(looking-at "\\(then\\|\\(els\\(e\\|if\\)\\)\\)\\_>"))
	   (let ((what (intern (sqlind-match-string 0))))
	     ;; the only invalid combination is a then statement in
	     ;; an (in-block "then") context
	     (unless (and (eq what 'then) (equal (nth 1 syntax) 'then))
	       (push (cons (list 'block-start what) anchor) context))))

	  ;; note that begin is not a block-start in a 'in-begin-block
	  ;; context
	  ((and (memq syntax-symbol '(defun-start declare-statement toplevel))
		(looking-at "begin\\_>"))
	   (push (cons (list 'block-start 'begin) anchor) context))

	  ((and (memq syntax-symbol '(defun-start package package-body))
		(looking-at "\\(is\\|as\\)\\_>"))
	   (push (cons (list 'block-start 'is-or-as) anchor) context))

	  ((and (memq syntax-symbol '(in-begin-block in-block))
		(looking-at "exception\\_>"))
	   (push (cons (list 'block-start 'exception) anchor) context))

	  ((and (eq syntax-symbol 'in-block)
		(memq (nth 1 syntax) '(then case))
		(looking-at "when\\_>"))
	   (push (cons (list 'block-start 'when) anchor) context))

	  ;; indenting the select clause inside a view
	  ((and (eq syntax-symbol 'create-statement)
		(eq (nth 1 syntax) 'view))
	   (goto-char anchor)
	   (catch 'done
	     (while (re-search-forward "\\bselect\\b" pos 'noerror)
	       (goto-char (match-beginning 0))
	       (when (sqlind-same-level-statement (point) anchor)
		 (push (sqlind-syntax-in-select pos (point)) context)
		 (throw 'done nil))
	       (goto-char (match-end 0)))))

	  ;; create a block-end syntax if needed

	  ((and (not (eq syntax-symbol 'comment-continuation))
                (looking-at "end[ \t\r\n\f]*\\(\\_<\\(?:if\\|loop\\|case\\)\\_>\\)?[ \t\r\n\f]*\\(\\_<\\(?:[a-z0-9_]+\\)\\_>\\)?"))
	   ;; so we see the syntax which closes the current block.  We still
	   ;; need to check if the current end is a valid closing block
	   (let ((kind (or (sqlind-match-string 1) ""))
		 (label (or (sqlind-match-string 2) "")))
	     (push (sqlind-refine-end-syntax
		    (if (equal kind "") nil (intern kind))
		    label (point) context)
		   context)))))
      context)))

(defun sqlind-show-syntax-of-line ()
  "Print the syntax of the current line."
  (interactive)
  (prin1 (sqlind-syntax-of-line)))


;;;; Indentation of SQL code

(defvar sqlind-basic-offset 2
  "The basic indentaion amount for SQL code.
Indentation is usually done in multiples of this amount, but
special indentation functions can do other types of indentation
such as aligning.  See also `sqlind-indentation-offsets-alist'.")

(defvar sqlind-indentation-syntax-symbols '()
  "This variable exists just for its documentation.

The the SQL parsing code returns a syntax definition (either a
symbol or a list) and an anchor point, which is a buffer
position.  They syntax symbols can be used to define how to
indent each line, see `sqlind-indentation-offsets-alist'

The following syntax symbols are defined for SQL code:

- (syntax-error MESSAGE START END) -- this is returned when the
  parse failed.  MESSAGE is an informative message, START and END
  are buffer locations denoting the problematic region.  ANCHOR
  is undefined for this syntax info

- in-comment -- line is inside a multi line comment, ANCHOR is
  the start of the comment.

- comment-start -- line starts with a comment.  ANCHOR is the
  start of the enclosing block.

- in-string -- line is inside a string, ANCHOR denotes the start
  of the string.

- toplevel -- line is at toplevel (not inside any programming
  construct).  ANCHOR is usually (point-min).

- (in-block BLOCK-KIND LABEL) -- line is inside a block
  construct.  BLOCK-KIND (a symbol) is the actual block type and
  can be one of \"if\", \"case\", \"exception\", \"loop\" etc.
  If the block is labeled, LABEL contains the label.  ANCHOR is
  the start of the block.

- (in-begin-block KIND LABEL) -- line is inside a block started
  by a begin statement.  KIND (a symbol) is \"toplevel-block\"
  for a begin at toplevel, \"defun\" for a begin that starts the
  body of a procedure or function, nil for a begin that is none
  of the previous.  For a \"defun\", LABEL is the name of the
  procedure or function, for the other block types LABEL contains
  the block label, or the empty string if the block has no label.
  ANCHOR is the start of the block.

- (block-start KIND) -- line begins with a statement that starts
  a block.  KIND (a symbol) can be one of \"then\", \"else\" or
  \"loop\".  ANCHOR is the reference point for the block
  start (the coresponding if, case, etc).

- (block-end KIND LABEL) -- the line contains an end statement.
  KIND (a symbol) is the type of block we are closing, LABEL (a
  string) is the block label (or procedure name for an end
  defun).

- declare-statement -- line is after a declare keyword, but
  before the begin.  ANCHOR is the start of the declare
  statement.

- (package NAME) -- line is inside a package definition.  NAME is
  the name of the package, ANCHOR is the start of the package.

- (package-body NAME) -- line is inside a package body.  NAME is
  the name of the package, ANCHOR is the start of the package
  body.

- (create-statement WHAT NAME) -- line is inside a CREATE
  statement (other than create procedure or function).  WHAT is
  the thing being created, NAME is its name.  ANCHOR is the start
  of the create statement.

- (defun-start NAME) -- line is inside a procedure of function
  definition but before the begin block that starts the body.
  NAME is the name of the procedure/function, ANCHOR is the start
  of the procedure/function definition.

The following SYNTAX-es are for SQL statements.  For all of
them ANCHOR points to the start of a statement itself.

- labeled-statement-start -- line is just after a label.

- statement-continuation -- line is inside a statement which
  starts on a previous line.

- nested-statement-open -- line is just inside an opening
  bracket, but the actual bracket is on a previous line.

- nested-statement-continuation -- line is inside an opening
  bracket, but not the first element after the bracket.

The following SYNTAX-es are for statements which are SQL
code (DML statements).  They are pecialisations on the previous
statement syntaxes and for all of them a previous generic
statement syntax is present earlier in the SYNTAX list.  Unless
otherwise specified, ANCHOR points to the start of the
clause (select, from, where, etc) in which the current point is.

- with-clause -- line is inside a WITH clause, but before the
  main SELECT clause.

- with-clause-cte -- line is inside a with clause before a
  CTE (common table expression) declaration

- with-clause-cte-cont -- line is inside a with clause before a
  CTE definition

- case-clause -- line is on a CASE expression (WHEN or END
  clauses).  ANCHOR is the start of the CASE expression.

- case-clause-item -- line is on a CASE expression (THEN and ELSE
  clauses).  ANCHOR is the position of the case clause.

- case-clause-item-cont -- line is on a CASE expression but not
  on one of the CASE sub-keywords.  ANCHOR points to the case
  keyword that this line is a continuation of.

- select-clause -- line is inside a select statement, right
  before one of its clauses (from, where, order by, etc).

- select-column -- line is inside the select column section,
  after a full column was defined (and a new column definition is
  about to start).

- select-column-continuation -- line is inside the select column
  section, but in the middle of a column definition.  The defined
  column starts on a previous like.  Note that ANCHOR still
  points to the start of the select statement itself.

- select-join-condition -- line is right before or just after the ON clause
  for an INNER, LEFT or RIGHT join.  ANCHOR points to the join statement
  for which the ON is defined.

- select-table -- line is inside the from clause, just after a
  table was defined and a new one is about to start.

- select-table-continuation -- line is inside the from clause,
  inside a table definition which starts on a previous line. Note
  that ANCHOR still points to the start of the select statement
  itself.

- (in-select-clause CLAUSE) -- line is inside the select CLAUSE,
  which can be \"where\", \"order by\", \"group by\" or
  \"having\".  Note that CLAUSE can never be \"select\" and
  \"from\", because we have special syntaxes inside those
  clauses.

- insert-clause -- line is inside an insert statement, right
  before one of its clauses (values, select).

- (in-insert-clause CLAUSE) -- line is inside the insert CLAUSE,
  which can be \"insert into\" or \"values\".

- delete-clause -- line is inside a delete statement right before
  one of its clauses.

- (in-delete-clause CLAUSE) -- line is inside a delete CLAUSE,
  which can be \"delete from\" or \"where\".

- update-clause line is inside an update statement right before
  one of its clauses.

- (in-update-clause CLAUSE) -- line is inside an update CLAUSE,
  which can be \"update\", \"set\" or \"where\".")

(defvar sqlind-indentation-offsets-alist
  '((syntax-error                   sqlind-report-sytax-error)
    (in-string                      sqlind-report-runaway-string)

    (comment-continuation           sqlind-indent-comment-continuation)
    (comment-start                  sqlind-indent-comment-start)

    (toplevel                       0)
    (in-block                       +)
    (in-begin-block                 +)
    (block-start                    0)
    (block-end                      0)
    (declare-statement              +)
    (package                        ++)
    (package-body                   0)
    (create-statement               +)
    (defun-start                    +)
    (labeled-statement-start        0)
    (statement-continuation         +)
    (nested-statement-open          sqlind-use-anchor-indentation +)
    (nested-statement-continuation  sqlind-use-previous-line-indentation)

    (with-clause                    sqlind-use-anchor-indentation)
    (with-clause-cte                +)
    (with-clause-cte-cont           ++)
    (case-clause                    0)
    (case-clause-item               sqlind-use-anchor-indentation +)
    (case-clause-item-cont          sqlind-right-justify-clause)
    (select-clause                  sqlind-right-justify-clause)
    (select-column                  sqlind-indent-select-column)
    (select-column-continuation     sqlind-indent-select-column +)
    (select-join-condition          ++)
    (select-table                   sqlind-indent-select-table)
    (select-table-continuation      sqlind-indent-select-table +)
    (in-select-clause               sqlind-lineup-to-clause-end)
    (insert-clause                  sqlind-right-justify-clause)
    (in-insert-clause               sqlind-lineup-to-clause-end)
    (delete-clause                  sqlind-right-justify-clause)
    (in-delete-clause               sqlind-lineup-to-clause-end)
    (update-clause                  sqlind-right-justify-clause)
    (in-update-clause               sqlind-lineup-to-clause-end))
  "Define the indentation amount for each syntactic symbol.

The value of this variable is an ALIST with the format:

  ((SYNTACTIC-SYMBOL . INDENTATION-OFFSETS) ... )

`sqlind-indentation-syntax-symbols' documents the list of possible
SYNTACTIC-SYMBOL values.

INDENTATION-OFFSETS is a list of:

  a NUMBER -- the indentation offset will be set to that number

  '+ -- the current indentation offset is incremented by
	`sqlind-basic-offset'

  '++ -- the current indentation offset is indentation by 2 *
	 `sqlind-basic-offset'

  '- -- the current indentation offset is decremented by
	`sqlind-basic-offset'

  '-- -- the current indentation offset is decremented by 2 *
	 `sqlind-basic-offset'

  a FUNCTION -- the syntax and current indentation offset is
	 passed to the function and its result is used as the new
	 indentation offset.

See `sqlind-calculate-indentation' for how the indentation offset
is calculated.")

(defun sqlind-calculate-indentation (syntax &optional base-indentation)
  "Return the indentation that should be applied to the current line.
SYNTAX is the syntaxtic information as returned by
`sqlind-syntax-of-line', BASE-INDENTATION is an indentation offset
to start with.  When BASE-INDENTATION is nil, it is initialised
to the column of the anchor.

The indentation is done as follows: first, the indentation
offsets for the current syntactic symbol is looked up in
`sqlind-indentation-offsets-alist'.  Than, for each indentation
offset, BASE-INDENTATION is adjusted according to that
indentation offset.  The final value of BASE-INDENTATION is than
returned."
  (if (null syntax)
      base-indentation
      ;; else

      ;; when the user did not specify a base-indentation, we use the
      ;; column of the anchor as a starting point
      (when (null base-indentation)
	(setq base-indentation (save-excursion
				 (goto-char (cdar syntax))
				 (current-column))))

      (let* ((this-syntax (caar syntax))
	     (syntax-symbol (if (symbolp this-syntax)
				this-syntax
				(nth 0 this-syntax)))
	     (indent-info (cdr (assoc syntax-symbol
				      sqlind-indentation-offsets-alist)))
	     (new-indentation base-indentation))

	;; the funcall below can create a nil indentation symbol to
	;; abort the indentation process
	(while (and new-indentation indent-info)
	  (let ((i (car indent-info)))
	    (setq new-indentation
		  (cond
		    ((eq i '+) (+ new-indentation sqlind-basic-offset))
		    ((eq i '++) (+ new-indentation (* 2 sqlind-basic-offset)))
		    ((eq i '-) (- new-indentation sqlind-basic-offset))
		    ((eq i '--) (- new-indentation (* 2 sqlind-basic-offset)))
		    ((integerp i) (+ new-indentation i))
		    ((functionp i) (funcall i syntax new-indentation))
		    ;; ignore unknown symbols by default
		    (t new-indentation))))
	  (setq indent-info (cdr indent-info)))
	new-indentation)))

(defun sqlind-report-sytax-error (syntax base-indentation)
  (destructuring-bind (sym msg start end) (caar syntax)
    (message "%s (%d %d)" msg start end))
  nil)

(defun sqlind-report-runaway-string (syntax base-indentation)
  (message "runaway string constant")
  nil)

(defun sqlind-use-anchor-indentation (syntax base-indentation)
  "Return the indentation of the line containing ANCHOR.
By default, the column of the anchor position is uses as a base
indentation.  You can use this function to switch to using the
indentation of the anchor as the base indentation."
  (let ((anchor (cdar syntax)))
    (save-excursion
      (goto-char anchor)
      (current-indentation))))

(defun sqlind-use-previous-line-indentation (syntax base-indentation)
  "Return the indentation of the previous line.
If the start of the previous line is before the ANCHOR, use the
column of the ANCHOR + 1."
  (let ((anchor (cdar syntax)))
    (save-excursion
      (forward-line -1)
      (back-to-indentation)
      (if (< (point) anchor)
	  (progn
	    (goto-char anchor)
	    (1+ (current-column)))
	  (current-column)))))

(defun sqlind-indent-comment-continuation (syntax base-indentation)
  "Return the indentation proper for a line inside a comment.
If the current line matches `sqlind-comment-prefix' or
`sqlind-comment-end', we indent to one plus the column of the
comment start, which will make comments line up nicely, like
this:

   /* Some comment line
    * another comment line
    */

When the current line does not match `sqlind-comment-prefix', we
indent it so it lines up with the text of the start of the
comment, like this:

   /* Some comment line
      Some other comment line
    */
"
  (let ((anchor (cdar syntax)))
    (save-excursion
      (back-to-indentation)
      (if (or (looking-at sqlind-comment-prefix)
	      (looking-at sqlind-comment-end))
	  (progn
	    (goto-char anchor)
	    (1+ (current-column)))
	  ;; else
	  (goto-char anchor)
	  (when (looking-at sqlind-comment-start-skip)
	    (goto-char (match-end 0)))
	  (current-column)))))

(defun sqlind-indent-comment-start (syntax base-indentation)
  "Return the indentation for a comment start.
If we start a line comment (--) and the previous line also has a
line comment, we line up the two comments.  Otherwise we indent
in the previous context. "
  (save-excursion
    (back-to-indentation)
    (if (and (looking-at "\\s *--")
	     (progn
	       (forward-line -1)
	       (re-search-forward "--" (c-point 'eol) t)))
	(progn
	  (goto-char (match-beginning 0))
	  (current-column))
	(sqlind-calculate-indentation (cdr syntax) base-indentation))))

(defun sqlind-indent-select-column (syntax base-indentation)
  "Return the indentation for a column of a SELECT clause.
We try to align to the previous column start, but if we are the
first column after the SELECT clause we simply add
`sqlind-basic-offset'."
  (let ((anchor (cdar syntax)))
    (save-excursion
      (goto-char anchor)
      (when (looking-at "select\\s *\\(top\\s +[0-9]+\\|distinct\\|unique\\)?")
	(goto-char (match-end 0)))
      (skip-syntax-forward " ")
      (if (or (looking-at sqlind-comment-start-skip)
	      (looking-at "$"))
	  (+ base-indentation sqlind-basic-offset)
	  (current-column)))))

(defun sqlind-indent-select-table (syntax base-indentation)
  "Return the indentation for a table in the FROM section.
We try to align to the first table, but if we are the first
table, we simply add `sqlind-basic-offset'."
  (let ((anchor (cdar syntax)))
    (save-excursion
      (goto-char anchor)
      (when (looking-at "from")
	(goto-char (match-end 0)))
      (skip-syntax-forward " ")
      (if (or (looking-at sqlind-comment-start-skip)
	      (looking-at "$"))
	  (+ base-indentation sqlind-basic-offset)
	  (current-column)))))

(defun sqlind-lineup-to-clause-end (syntax base-indentation)
  "Line up the current line with the end of a query clause.

This assumes SYNTAX is one of in-select-clause, in-update-clause,
in-insert-clause or in-delete-clause.  It will return an
indentation so that:

If the clause is on a line by itself, the current line is
indented by `sqlind-basic-offset', otherwise the current line is
indented so that it starts in next column from where the clause
keyword ends.

An exception is made for a 'where' clause: if the current line
starts with an 'and' or an 'or' the line is indented so that the
and/or is right justified with the 'where' clause."
  (let ((origin (point)))
    (destructuring-bind ((sym clause) . anchor) (car syntax)
      (save-excursion
	(goto-char anchor)
	(forward-char (1+ (length clause)))
	(skip-syntax-forward " ")
	(if (or (looking-at sqlind-comment-start-skip)
		(looking-at "$"))
	    ;; if the clause is on a line by itself, indent this line
	    ;; with a sqlind-basic-offset
	    (+ base-indentation sqlind-basic-offset)
	    ;; otherwise, align to the end of the clause, with a few
	    ;; exceptions
	    (let ((indentation (current-column)))
	      (goto-char origin)
	      (back-to-indentation)
	      ;; when the line starts with an 'and' or an 'or', line
	      ;; it up so that the logic operator sits right under the
	      ;; where clause
	      (when (and (equal clause "where")
			 (looking-at "and\\|or"))
		(decf indentation (1+ (- (match-end 0) (match-beginning 0)))))
	      indentation))))))

(defun sqlind-right-justify-clause (syntax base-indentation)
  "Return an indentation which right-aligns the first word at
ANCHOR with the first word in the curent line.

This is intended to be used as an indentation function for
select-clause, update-clause, insert-clause and update-clause
syntaxes"
  (save-excursion
    (let ((clause-length 0)
	  (statement-keyword-length 0)
	  offset)
      (back-to-indentation)
      (when (looking-at "\\sw+\\b")
	(setq clause-length (- (match-end 0) (match-beginning 0))))
      (goto-char (cdar syntax))         ; move to ANCHOR
      (when (looking-at "\\sw+\\b")
	(setq statement-keyword-length (- (match-end 0) (match-beginning 0))))
      (setq offset (- statement-keyword-length clause-length))
      (if (> offset 0)
	  (+ base-indentation offset)
	  base-indentation))))



(defun sqlind-indent-line ()
  "Indent the current line according to SQL conventions.
`sqlind-basic-offset' defined the number of spaces in the basic
indentation unit and `sqlind-indentation-offsets-alist' is used to
determine how to indent each type of syntactic element."
  (let* ((syntax (sqlind-syntax-of-line))
	 (base-column (current-column))
	 (indent-column (sqlind-calculate-indentation syntax)))
    (when indent-column
      (back-to-indentation)
      (let ((offset (- base-column (current-column))))
	;; avoid modifying the buffer when the indentation does not
	;; have to change
	(unless (eq (current-column) indent-column)
	  (delete-horizontal-space)
	  (indent-to indent-column))
	(when (> offset 0)
	  (forward-char offset))))))

;;;; sqlind-setup

;;;###autoload
(defun sqlind-setup ()
  (set-syntax-table sqlind-syntax-table)
  (set (make-local-variable 'indent-line-function) 'sqlind-indent-line)
  (define-key sql-mode-map [remap beginning-of-defun] 'sqlind-beginning-of-statement))

(provide 'sql-indent)

;;; Local Variables:
;;; mode: emacs-lisp
;;; mode: outline-minor
;;; outline-regexp: ";;;;+"
;;; End:

;;; sql-indent.el ends here

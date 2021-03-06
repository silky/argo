;;; proto-test.el --- Test out our little protocol   -*- lexical-binding: t; -*-

;; Copyright (C) 2019  David Thrane Christiansen

;; Author: David Thrane Christiansen <dtc@000301-dtc>
;; Keywords: processes

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'cl-lib)
(require 'comint)
(require 'dired)
(require 'json)

(cl-defmacro proto-test-hash (&rest args)
  "Make a hash table of key-value lists in ARGS."
  (let ((table (cl-gensym "table")))
    `(let ((,table (make-hash-table)))
       ,@(cl-loop for item in args
                  collecting (pcase item
                               (`(,k ,v)
                                `(puthash ,k ,v ,table))))
       ,table)))


(defvar proto-test-proc nil "The process being tested.")
(defvar proto-test--output "" "The process's output so far.")
(defvar proto-test--state json-null "The method calls that make up the cryptol state.")

(defvar proto-test-receive-functions '(proto-test-record-reply proto-test--cryptol-listen)
  "A list of functions to be called with the decoded output from the process.")

(defvar proto-test--cryptol-continuations (make-hash-table))
(defvar proto-test--cryptol-failure-continuations (make-hash-table))

(defun proto-test--cryptol-listen (reply)
  "Listen for REPLY to known Cryptol messages."
  (let ((json-object-type 'hash-table)
        (json-key-type 'string))
    (let* ((decoded (json-read-from-string reply))
           (status (cond ((gethash "error" decoded nil) 'error)
                         ((gethash "result" decoded nil) 'result)
                         (t (error "Invalid response")))))
      (pcase status
        ('error
         (let ((the-id (gethash "id" decoded nil)))
           (when the-id
             (let ((fail-cont (gethash the-id proto-test--cryptol-failure-continuations))
                   (error-info (gethash "error" decoded)))
               (cond (fail-cont
                      (funcall fail-cont
                               (gethash "code" error-info)
                               (gethash "message" error-info)
                               (gethash "data" error-info)))
                     ((gethash the-id proto-test--cryptol-continuations)
                      (message "Got error response: %S" reply))
                     (t nil))))))
        ('result
         (let* ((the-id (gethash "id" decoded))
                (the-cont (gethash the-id proto-test--cryptol-continuations))
                (the-result (gethash "result" decoded))
                (the-answer (gethash "answer" the-result))
                (the-state (gethash "state" the-result)))
           (when the-state
             (setq proto-test--state the-state))
           (when the-cont
             (funcall the-cont the-answer))))))))

(defun proto-test--message-send (method params cont &optional fail-cont)
  "Send the message with METHOD and PARAMS as in `proto-test'.
Additionally register a continuation CONT to handle the reply,
and optionally a failure continuation FAIL-CONT to handle
errors."
  (let* ((the-id (proto-test--next-id))
         (message (list :jsonrpc "2.0"
                        :id the-id
                        :method method
                        :params (progn (puthash :state proto-test--state params)
                                       params))))
    (puthash the-id cont proto-test--cryptol-continuations)
    (when fail-cont (puthash the-id fail-cont proto-test--cryptol-failure-continuations))
    (proto-test-send (json-encode-plist message))))

(defun proto-test-cryptol-change-directory (dir)
  "Change to directory DIR in Cryptol."
  (interactive "DNew directory: ")
  (proto-test--message-send "change directory" (proto-test-hash (:directory dir))
                            (lambda (_)
                              (message "Changed directory"))))

(defun proto-test-cryptol-load-file (file)
  "Load FILE in Cryptol."
  (interactive "FFile to load: ")
  (proto-test--message-send "load file"
                            (proto-test-hash (:file file))
                            (lambda (res)
                              (message "Loaded file %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When loading file, got error %s (%S) with info %S" code err-message err-data))))

(defun proto-test-cryptol-load-module (module)
  "Load MODULE in Cryptol."
  (interactive "MModule to load: ")
  (proto-test--message-send "load module"
                            (proto-test-hash ("module name" module))
                            (lambda (res)
                              (message "Loaded module %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When loading module, got error %s (%S) with info %S" code err-message err-data))))


(defun proto-test-cryptol-eval (expr)
  "Eval EXPR in Cryptol."
  (interactive "MExpression to eval: ")
  (proto-test--message-send "evaluate expression"
                            (proto-test-hash (:expression expr))
                            (lambda (res)
                              (message "The result is %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When evaluating %S, got error %s (%S) with info %S"
                                     expr code err-message err-data))))

(defun proto-test-cryptol-check-type (expr)
  "Type check EXPR in Cryptol."
  (interactive (list (proto-test-cryptol-get-arg)))
  (proto-test--message-send "check type"
                            (proto-test-hash (:expression expr))
                            (lambda (res)
                              (message "The result is %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When checking %S, got error %s (%S) with info %S"
                                     expr code err-message err-data))))


(defun proto-test-cryptol-satisfy (expr)
  ":sat EXPR in Cryptol."
  (interactive (list (proto-test-cryptol-get-arg)))
  (proto-test--message-send "satisfy"
                            (proto-test-hash (:expression expr) (:prover "z3") ("result count" 10))
                            (lambda (res)
                              (message "The result is %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When checking %S, got error %s (%S) with info %S"
                                     expr code err-message err-data))))

(defun proto-test-cryptol-focused-module ()
  "Find the focused Cryptol module."
  (interactive)
  (proto-test--message-send "focused module" (proto-test-hash)
                            (lambda (res)
                              (message "The result is %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "Got error %s (%S) with info %S"
                                     code err-message err-data))))

(defun proto-test-cryptol-call (fun args)
  "Call FUN with ARGS."
  (interactive (let ((fun (read-string "Cryptol function to call: ")))
                 (list fun
                       (proto-test-cryptol-get-args fun))))
  (proto-test--message-send "call"
                            (proto-test-hash (:function fun) (:arguments (or args [])))
                            (lambda (res)
                              (message "The result is %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When calling %S with args %S, got error %s (%S) with info %S"
                                     fun args code err-message err-data))))

(defun proto-test-cryptol-visible-names ()
  "Get the list of available names from Cryptol."
  (interactive)
  (proto-test--message-send "visible names" (proto-test-hash)
                            (lambda (res)
                              (message "%s" res))))

(defun proto-test-saw-cryptol-start-setup (name)
  "Start setting up Cryptol in SAW, calling the result NAME."
  (interactive "MName for Cryptol setup: ")
  (proto-test--message-send "SAW/Cryptol/start setup" (proto-test-hash (:name name))
                            (lambda (res)
                              (message "The result is %S" res))))

(defun proto-test-saw-cryptol-load-file (file)
  "Load FILE in SAW Cryptol."
  (interactive "FFile to load: ")
  (proto-test--message-send "SAW/Cryptol/load file"
                            (proto-test-hash (:file file))
                            (lambda (res)
                              (message "Loaded file %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When loading file, got error %s (%S) with info %S" code err-message err-data))))

(defun proto-test-saw-cryptol-load-module (module)
  "Load MODULE in SAW Cryptol."
  (interactive "MModule: ")
  (proto-test--message-send "SAW/Cryptol/load module"
                            (proto-test-hash (:module module))
                            (lambda (res)
                              (message "Loaded module %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When loading module got error %s (%S) with info %S" code err-message err-data))))

(defun proto-test-saw-cryptol-finish-setup ()
  "Finish setting up SAW Cryptol."
  (interactive)
  (proto-test--message-send "SAW/Cryptol/finish setup"
                            (proto-test-hash)
                            (lambda (res)
                              (message "Finished setup %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When finishing setup got error %s (%S) with info %S" code err-message err-data))))

(defun proto-test-saw-llvm-start-setup (name)
  "Start setting up LLVM in SAW, calling the result NAME."
  (interactive "MName for LLVM setup: ")
  (proto-test--message-send "SAW/LLVM/start setup" (proto-test-hash (:name name))
                            (lambda (res)
                              (message "The result is %S" res))))

(defun proto-test-saw-llvm-finish-setup ()
  "Finish setting up SAW LLVM Crucible."
  (interactive)
  (proto-test--message-send "SAW/LLVM/finish setup"
                            (proto-test-hash)
                            (lambda (res)
                              (message "Finished setup %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When finishing setup got error %s (%S) with info %S" code err-message err-data))))


(defun proto-test-saw-llvm-load-module (name filename)
  "Load an LLVM module in FILENAME in SAW, saving it as NAME."
  (proto-test--message-send "SAW/LLVM/load module"
                            (proto-test-hash ("name" name) ("bitcode file" filename))
                            (lambda (res)
                              (message "Loaded module %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When loading LLVM module got error %s (%S) with info %S" code err-message err-data))))


(defun proto-test-saw-return (val)
  "Specify a return value VAL in LLVM."
  (interactive (list (proto-test-saw-get-setup-value)))
  (proto-test--message-send "SAW/LLVM/return"
                            (proto-test-hash ("value" val))
                            (lambda (res)
                              (message "Returned %s" res))
                            (lambda (code err-message &optional err-data)
                              (error "Failed in return of setup value: error %s (%S) with info %S" code error err-data))))


(defun proto-test-saw-save-term (name cryptol-setup expr)
  "Save Cryptol expression EXPR in configuration CRYPTOL-SETUP to NAME."
  (interactive (list (read-string "Name: ")
                     (read-string "Name of Cryptol config: ")
                     (proto-test-cryptol-get-arg)))
  (proto-test--message-send "SAW/Cryptol/save term"
                            (proto-test-hash ("name" name) ("cryptol setup" cryptol-setup) ("expression" expr))
                            (lambda (res)
                              (message "The result is %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When saving term, got error %s (%S) with info %S"
                                     code err-message err-data))))

(defun proto-test-saw-llvm-verify (module function lemmas check-sat setup tactic lemma-name)
  "Attempt LLVM verification for FUNCTION in MODULE, based on LEMMAS, with CHECK-SAT, using SETUP as a spec and TACTIC to invoke a prover, saving the result as LEMMA-NAME."
  (proto-test--message-send "SAW/LLVM/verify"
                            (proto-test-hash ("module" module)
                                             ("function" function)
                                             ("lemmas" lemmas)
                                             ("check sat" (if check-sat t json-false))
                                             ("setup" setup)
                                             ("tactic" tactic)
                                             ("lemma name" lemma-name))
                            (lambda (res)
                              (message "Verification result: %S" res))))


(defvar proto-test--saw-unique-string-counter 0)
(defun proto-test--saw-unique-name (&optional basis)
  "Compute a unique string name, optionally using starting string BASIS."
  (let ((x (or basis "x")))
    (incf proto-test--saw-unique-string-counter)
    (format "%s%s" x proto-test--saw-unique-string-counter)))

(defun proto-test--saw-multi-command-test-cryptol (file)
  "Run some test steps using FILE."
  (interactive "FPath to Foo.cry: ")
  (let ((setup-name (proto-test--saw-unique-name "setup"))
        (term-name (proto-test--saw-unique-name "term")))
    (proto-test-saw-cryptol-start-setup setup-name)
    (sit-for 1)
    (proto-test-saw-cryptol-load-file file)
    (sit-for 1)
    (proto-test-saw-cryptol-finish-setup)
    (sit-for 1)
    (proto-test-saw-save-term term-name setup-name (proto-test-cryptol-get-arg))))

(defun proto-test--saw-multi-command-test-llvm ()
  "Run some test steps."
  (interactive)
  (let ((setup-name (proto-test--saw-unique-name "setup"))
        (module-name (proto-test--saw-unique-name "module"))
        (lemma-out-name (proto-test--saw-unique-name "lemma-out")))
    (proto-test-saw-llvm-load-module module-name "seven.bc")
    (sit-for 1)
    (proto-test-saw-llvm-start-setup setup-name)
    (sit-for 1)
    (proto-test-saw-return "null")
    (sit-for 1)
    (proto-test-saw-llvm-finish-setup)
    (sit-for 1)
    (proto-test-saw-llvm-verify module-name "seven" '[] nil setup-name "abc" lemma-out-name)))

(defvar proto-test--cryptol-get-arg-context '()
  "The context to show in the argument-getting prompt.")

(cl-defun proto-test--cryptol-get-arg-prompt (str)
  "Get a prompt based on STR for an argument, taking into account `proto-test--cryptol-get-arg-context'."
  (if proto-test--cryptol-get-arg-context
      (concat "⟨" (mapconcat #'identity (reverse proto-test--cryptol-get-arg-context) " → ") "⟩ " str)
    str))

(cl-defmacro proto-test--with-arg-context (ctx &body body)
  "Evaluate BODY in a prompt context extended by CTX."
  (declare (indent 1))
  `(let ((proto-test--cryptol-get-arg-context (cons ,ctx proto-test--cryptol-get-arg-context)))
     ,@body))

(defun proto-test--to-ordinal (num)
  "Find a string that is the ordinal form of NUM."
  (format "%s%s"
          num
          (pcase (mod num 10)
            (1 "st")
            (2 "nd")
            (3 "rd")
            (_ "th"))))

(defun proto-test-cryptol-get-args (&optional fun)
  "Prompt for zero or more arguments to FUN, using `proto-test-cryptol-get-arg'."
  (interactive)
  (let ((args '())
        (go t))
    (while go
      (let ((the-arg
             (proto-test--with-arg-context (concat (proto-test--to-ordinal (1+ (length args)))
                                                   " arg"
                                                   (if fun (format " to %s" fun) ""))
               (proto-test-cryptol-get-arg))))
        (if the-arg
            (push the-arg args)
          (setq go nil))))
    (reverse args)))


(defun proto-test-cryptol-get-arg ()
  "Prompt the user for an argument to the \"call\" method.
Returns nil when no argument provided."
  (interactive)
  (pcase (completing-read (proto-test--cryptol-get-arg-prompt "What kind of argument? ")
                          '("literal code" "bitvector" "unit" "single bit"
                            "integer" "record" "sequence" "tuple"
                            "local let" "function application"))
    ("literal code"
     (proto-test--with-arg-context "literal code"
       (read-string (proto-test--cryptol-get-arg-prompt "Cryptol code: "))))

    ("bitvector"
     (proto-test--with-arg-context "a bitvector"
       (let* ((encoding (completing-read (proto-test--cryptol-get-arg-prompt "Which encoding? ")
                                         '("hex" "base64")))
              (width (read-number (proto-test--cryptol-get-arg-prompt "How many bits wide? ")))
              (the-data (read-string (proto-test--cryptol-get-arg-prompt (format "Data (%s): " encoding)))))
         (proto-test-hash (:expression "bits")
                          (:encoding encoding)
                          (:width width)
                          (:data the-data)))))
    ("unit" (proto-test-hash (:expression "unit")))
    ("single bit"
     (proto-test--with-arg-context "a single bit"
       (let ((b (completing-read (proto-test--cryptol-get-arg-prompt "Which bit?") '("true" "false"))))
         (pcase b
           ("true" t)
           ("false" json-false)))))
    ("integer"
     (proto-test--with-arg-context "an integer"
       (let ((input nil))
         (while (not (integerp input))
           (setq input (read (read-string (proto-test--cryptol-get-arg-prompt "Integer (base 10): "))))
           (unless (integerp input)
             (message "Not an integer: %s" input)))
         input)))
    ("record"
     (proto-test--with-arg-context "record"
       (let (fields
             (go t))
         (while go
           (let ((name (read-string (proto-test--cryptol-get-arg-prompt "Field name (empty when done): "))))
             (if (equal name "")
                 (setq go nil)
               (let ((value (proto-test--with-arg-context (concat "field " name)
                              (proto-test-cryptol-get-arg))))
                 (push (intern (concat ":" name)) fields)
                 (push value fields)))))
         (proto-test-hash (:expression "record")
                          (:data (reverse fields))))))
    ("sequence"
     (proto-test--with-arg-context "sequence"
       (let ((elts '())
             (go t))
         (while go
           (proto-test--with-arg-context (format "at %s" (length elts))
             (let ((this-elt (proto-test-cryptol-get-arg)))
               (if this-elt
                   (push this-elt elts)
                 (setq go nil)))))
         (proto-test-hash (:expression "sequence")
                          (:data (reverse elts))))))
    ("tuple"
     (proto-test--with-arg-context "tuple"
       (let ((size (read-number (proto-test--cryptol-get-arg-prompt "Size: "))))
         (proto-test-hash (:expression "tuple")
                          (:data (cl-loop for i from 0 to size
                                          collecting (proto-test--with-arg-context (format ".%s" i)
                                                       (proto-test-cryptol-get-arg))))))))
    ("local let"
     (proto-test--with-arg-context "let"
       (proto-test-hash (:expression "let")
                        (:binders (proto-test--with-arg-context "binders"
                                    (proto-test--get-binders)))
                        (:body (proto-test--with-arg-context "body"
                                 (proto-test-cryptol-get-arg))))))
    ("function application"
     (let ((rator (proto-test--with-arg-context "function"
                    (proto-test-cryptol-get-arg)))
           (rands (proto-test--with-arg-context "arguments"
                    (proto-test-cryptol-get-args))))
       (proto-test-hash (:expression "call")
                        (:function rator)
                        (:arguments rands))))
    (_ nil)))

(defun proto-test--get-binders ()
  "Get a series of binder objects for the let message."
  (let ((binders '())
        (go t))
    (while go
      (let ((one-binder (proto-test--get-binder)))
        (message "got %s" one-binder)
        (if one-binder
            (push one-binder binders)
          (setq go nil))))
    (reverse binders)))

(defun proto-test--get-binder ()
  "Read one name-val let binder."
  (let ((x (read-string (proto-test--cryptol-get-arg-prompt "Name (empty when done): "))))
    (if (string-blank-p x)
        nil
      (let ((val (proto-test--with-arg-context (concat x "=") (proto-test-cryptol-get-arg))))
        (proto-test-hash (:name x) (:definition val))))))

(defun proto-test-saw-get-setup-value ()
  "Prompt the user for a setup value."
  (interactive)
  (pcase (completing-read (proto-test--cryptol-get-arg-prompt "What kind of argument? ")
                          '("null pointer"))
    ("null pointer"
     "null")
    (_ nil)))

(defun proto-test-quit ()
  "Quit the test process."
  (interactive)
  (setq proto-test--output "")
  (setq proto-test--state json-null)
  (when proto-test-proc
    (ignore-errors (kill-process proto-test-proc))
    (setq proto-test-proc nil)))

(defun proto-test-start (prog)
  "Run the tester on PROG."
  (interactive
   (list
    (read-shell-command "Command: " nil nil
			(let ((filename
			       (cond
				(buffer-file-name)
				((eq major-mode 'dired-mode)
				 (dired-get-filename nil t)))))
			  (and filename (file-relative-name filename))))))
  (proto-test-quit)
  (setq proto-test-proc (apply #'start-process "the-test" "the-test" (split-string prog)))
  (set-process-filter proto-test-proc 'proto-test-process-filter)
  (setq proto-test--state json-null)
  (proto-test-record-history-item (format "Launched %s" prog) "restart"))


(defun proto-test-start-socket (port)
  "Run the tester for a socket on PORT."
  (interactive "nPort: ")
  (let ((port-string (format "%s" port)))
    (proto-test-quit)
    (setq proto-test-proc
          (open-network-stream "proto-connection" "foo" "127.0.0.1" port-string))
    (set-process-filter proto-test-proc 'proto-test-process-filter)
    (setq proto-test--state json-null)
    (proto-test-record-history-item (format "Socket on %s" port) "restart")    ))


(defun proto-test-process-filter (_proc output)
  "Save the OUTPUT from the process."
  (setq proto-test--output (concat proto-test--output (encode-coding-string output 'utf-8-unix t)))
  (let (decoded)
    (while (setq decoded (proto-test-decode-netstring proto-test--output))
      (setq proto-test--output (cdr decoded))
      (cl-loop for fun in proto-test-receive-functions do (funcall fun (car decoded))))))

(defun proto-test-encode-netstring (str)
  "Encode STR as a netstring."
  (let ((len (string-bytes str)))
    (concat (format "%s:" len) str ",")))

(defun proto-test-decode-netstring (str)
  "Attempt to decode a netstring as a prefix of STR.

On success, return a pair whose car is the decoded string and
whose cdr is the remainder of the original string (possibly empty).

If a failure results from STR being a valid prefix of an
incomplete netstring, return nil.  If failure results from STR
not being a well-formed netstring prefix, signal an error
instead."

  (let ((the-tag (cl-gensym "TAG"))
        (state 'init) ;; Valid values : 'init and 'body
        start end     ;; eventually the range of string that is our message
        len)          ;; after reading header, the length of the body

    (catch the-tag
      (cl-loop
       for ch across str
       for i from 0
       do (pcase state
            ;; in the init state, we are finding the length of the message
            ('init
             (if len ;; Is there a length discovered so far?
                 (pcase ch
                   (?:
                    (setq state 'body)
                    (setq start (1+ i)))
                   ((app cl-digit-char-p (and x (pred numberp)))
                    (setq len (+ (* len 10) x)))
                   (_ (error "Expected more length or colon, got '%c' at %s\nUnderlying message: %s" ch i str)))
               (pcase (cl-digit-char-p ch)
                 ('nil (error "Expected length, got '%c' at %s.\nUnderlying message: %s" ch i str))
                 (n (setq len n)))))
            ;; in the body state, we are finding the boundaries of the message
            ('body
             (cond ((> len 0)
                    (setq len (- len 1)))
                   ((equal ch ?,)
                    (setq end i)
                    (throw the-tag (cons (substring str start end) (substring str (1+ end)))))
                   (t (error "Expected literal comma, got '%c' at %s\nUnderlying message: %s" ch i str))))))
      (throw the-tag nil))))

(defun proto-test-send (str)
  "Send STR to the process."
  (unless proto-test-proc (error "Not a process: %s" proto-test-proc))
  (process-send-string proto-test-proc (proto-test-encode-netstring str))
  (proto-test-record-sent str))

(defvar proto-test-history-buffer nil
  "The buffer with the interaction history.")

(defun proto-test-ensure-history-buffer ()
  "Ensure that there is a history buffer."
  (unless (and proto-test-history-buffer
               (bufferp proto-test-history-buffer)
               (buffer-live-p proto-test-history-buffer))
    (setq proto-test-history-buffer (get-buffer-create "*Test History*"))
    (with-current-buffer proto-test-history-buffer
      (read-only-mode 1))))

(defun proto-test-clear-history-buffer ()
  "Clear the contents of the history buffer, if it exists."
  (interactive)
  (when (and proto-test-history-buffer
             (bufferp proto-test-history-buffer)
             (buffer-live-p proto-test-history-buffer))
    (with-current-buffer proto-test-history-buffer
      (let ((buffer-read-only nil))
        (erase-buffer)))))

(defun proto-test-record-history-item (str what)
  "Record a history entry of STR as a WHAT."
  (proto-test-ensure-history-buffer)
  (with-current-buffer proto-test-history-buffer
    (let ((buffer-read-only nil))
      (save-excursion
        (goto-char (point-max))
        (insert (format "%s\t%s\t%s\n" (format-time-string "%Y-%m-%d %H:%M:%S" (current-time)) what str))))))

(defun proto-test-record-reply (str)
  "Record a history of STR as a system response."
  (proto-test-record-history-item str "reply")
  (pop-to-buffer proto-test-history-buffer))

(defun proto-test-record-sent (str)
  "Record a history of STR as user message."
  (proto-test-record-history-item str "sent"))

(defvar proto-test--id-counter 0 "Internal counter for unique IDs.")
(defun proto-test--next-id ()
  "Get the next JSON-RPC message ID."
  (let ((id proto-test--id-counter))
    (setq proto-test--id-counter (1+ proto-test--id-counter))
    id))

(defun proto-test (method params)
  "Send a JSON-RPC message METHOD and PARAMS."
  (interactive (list (read-string "Method: ") (read t)))
  (let ((message (list :jsonrpc "2.0"
                       :id (proto-test--next-id)
                       :method method
                       :params params)))
    (proto-test-send (json-encode-plist message))))

(provide 'proto-test)
;;; proto-test.el ends here

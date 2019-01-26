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

(defvar proto-test-proc nil "The process being tested.")
(defvar proto-test--output "" "The process's output so far.")

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
               (if fail-cont
                   (funcall fail-cont
                            (gethash "code" error-info)
                            (gethash "message" error-info)
                            (gethash "data" error-info))
                 (error "Got error response: %S" reply))))))
        ('result
         (let* ((the-id (gethash "id" decoded))
                (the-cont (gethash the-id proto-test--cryptol-continuations)))
           (when the-cont
             (funcall the-cont (gethash "result" decoded)))))))))

(defun proto-test--cryptol-send (method params cont &optional fail-cont)
  "Send the message with METHOD and PARAMS as in `proto-test'.
Additionally register a continuation CONT to handle the reply,
and optionally a failure continuation FAIL-CONT to handle
errors."
  (let* ((the-id (proto-test--next-id))
         (message (list :jsonrpc "2.0"
                        :id the-id
                        :method method
                        :params params)))
    (puthash the-id cont proto-test--cryptol-continuations)
    (when fail-cont (puthash the-id fail-cont proto-test--cryptol-failure-continuations))
    (proto-test-send (json-encode-plist message))))

(defun proto-test-cryptol-change-directory (dir)
  "Change to directory DIR in Cryptol."
  (interactive "DNew directory: ")
  (proto-test--cryptol-send "change directory" `(:state [] :directory ,dir)
                            (lambda (_)
                              (message "Changed directory"))))

(defun proto-test-cryptol-load-file (file)
  "Load FILE in Cryptol."
  (interactive "fFile to load: ")
  (proto-test--cryptol-send "load module"
                            `(:state [] :file ,file)
                            (lambda (res)
                              (message "Loaded file %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When loading file, got error %s (%S) with info %S" code err-message err-data))))


(defun proto-test-cryptol-eval (expr)
  "Eval EXPR in Cryptol."
  (interactive "MExpression to eval: ")
  (proto-test--cryptol-send "evaluate expression"
                            `(:state [] :expression ,expr)
                            (lambda (res)
                              (message "The result is %S" res))
                            (lambda (code err-message &optional err-data)
                              (error "When evaluating %S, got error %s (%S) with info %S" expr code err-message err-data))))

(defun proto-test-quit ()
  "Quit the test process."
  (interactive)
  (when proto-test-proc
    (ignore-errors (kill-process proto-test-proc))
    (setq proto-test-proc nil)
    (setq proto-test--output "")))

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
  (set-process-filter proto-test-proc 'proto-test-process-filter))


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
                   (_ (error "Expected more length or colon, got '%c' at %s" ch i)))
               (pcase (cl-digit-char-p ch)
                 ('nil (error "Expected length, got '%c' at %s" ch i))
                 (n (setq len n)))))
            ;; in the body state, we are finding the boundaries of the message
            ('body
             (cond ((> len 0)
                    (setq len (- len 1)))
                   ((equal ch ?,)
                    (setq end i)
                    (throw the-tag (cons (substring str start end) (substring str (1+ end)))))
                   (t (error "Expected literal comma, got '%c' at %s" ch i))))))
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

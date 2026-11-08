;;;; SPDX-FileCopyrightText: 2026 Greg Wuller
;;;; SPDX-License-Identifier: MIT

;;;; tests.lisp --- daemon-free unit tests for cl-herdr-client
;;;;
;;;; FiveAM tests for the parts of the client that don't need a live
;;;; herdr-core: JSON object building, jsown round-trips, base64 helpers, the
;;;; API wrapper metadata, and a local unix-socket peer that checks reconnect
;;;; and close. End-to-end behaviour against a real daemon is exercised
;;;; separately by demo.lisp.
;;;;
;;;; Run with: (asdf:test-system :cl-herdr-client)
;;;; or:        (ql:quickload :cl-herdr-client/tests)

(defpackage #:cl-herdr-client/tests
  (:use #:cl #:fiveam #:cl-herdr-client))

(in-package #:cl-herdr-client/tests)

#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-bsd-sockets))

(def-suite :cl-herdr-client
  :description "Unit tests for the cl-herdr-client system (no daemon needed).")

(in-suite :cl-herdr-client)

;;; ---------------------------------------------------------------------------
;;; JSON building helpers
;;; ---------------------------------------------------------------------------

(test json-object-builders
  ;; obj drops nil values, object keeps them
  (is (string= "{}" (jto-json (obj))))
  (is (string= "{\"a\":1}" (jto-json (obj "a" 1 "b" nil))))
  (is (string= "{\"b\":null}" (jto-json (object "b" nil))))

  (is (string= "{\"size\":{\"cols\":80,\"rows\":24}}"
               (jto-json (obj "size" (object "cols" 80 "rows" 24)))))
  (is (string= "{\"argv\":[\"a\",\"b\"]}"
               (jto-json (obj "argv" (list "a" "b")))))

  (is (string= "{\"k\":\"v\"}" (jto-json (alist->js '(("k" . "v"))))))
  (is (string= "{\"x\":1}" (jto-json (plist->js (list "x" 1))))))

(test json-round-trip
  (let ((x (jparse "{\"a\":[1,2],\"o\":{\"b\":true}}")))
    (is (equal '(1 2) (jval x "a")))
    (is-true (jval (jval x "o") "b")))
  ;; parse -> re-emit is identity (modulo whitespace)
  (is (string= "{\"a\":1}"
               (jto-json (jparse (jto-json (obj "a" 1)))))))

(test base64
  (is (string= "aGVsbG8=" (base64-encode "hello")))
  (is (string= "hello" (base64-decode "aGVsbG8=")))
  (is (string= "hello" (base64-decode (base64-encode "hello"))))
  ;; a vector of octets encodes too (file.write, terminal.put payloads)
  (is (string= "AQID"
               (base64-encode (make-array 3 :element-type '(unsigned-byte 8)
                                            :initial-contents '(1 2 3))))))

;;; ---------------------------------------------------------------------------
;;; API wrapper metadata (define-hc-method records wire name + params)
;;; ---------------------------------------------------------------------------

(test api-metadata
  (multiple-value-bind (wire req opt) (method-info 'terminal-get)
    (is (string= "terminal.get" wire))
    (is (equal '("terminal") req))
    (is (equal '("caller") opt)))

  (multiple-value-bind (wire req opt) (method-info 'terminal-run)
    (is (string= "terminal.run" wire))
    ;; all of terminal.run's params are optional in the schema
    (is (null req))
    (is (member "name" opt :test #'string=))
    (is (member "line" opt :test #'string=))
    (is (member "outlive-parent" opt :test #'string=))
    (is (member "no-notify" opt :test #'string=)))

  (multiple-value-bind (wire req opt) (method-info 'file-write)
    (declare (ignorable opt))
    (is (string= "file.write" wire))
    (is (equal '("path" "data") req)))

  ;; doc.set is keyword-only
  (multiple-value-bind (wire req opt) (method-info 'doc-set)
    (declare (ignorable wire))
    (is (null req))
    (is (subsetp '("name" "value" "version") opt :test #'string=)))

  (multiple-value-bind (wire req opt) (method-info 'terminal-put)
    (declare (ignorable opt))
    (is (string= "terminal.put" wire))
    (is (member "data" req :test #'string=))))

;;; ---------------------------------------------------------------------------
;;; Local socket: disconnect must not let a stale reader consume the next
;;; connection's reply, and closing one connection must not stall another.
;;; ---------------------------------------------------------------------------

(defun test-socket-path ()
  (namestring
   (merge-pathnames (format nil "cl-herdr-client-test-~a.sock"
                            #+ccl "ccl" #+sbcl "sbcl" #-(or ccl sbcl) "lisp")
                    (uiop:temporary-directory))))

(defun accept-client (listener)
  #+ccl
  (ccl:accept-connection listener)
  #+sbcl
  (let ((client (sb-bsd-sockets:socket-accept listener)))
    (sb-bsd-sockets:socket-make-stream client
                                       :input t :output t
                                       :element-type 'character
                                       :external-format :utf-8
                                       :auto-close t
                                       :buffering :full)))

(defun make-test-listener (path)
  (ignore-errors (delete-file path))
  #+ccl
  (ccl:make-socket :address-family :file :connect :passive :local-filename path)
  #+sbcl
  (let ((sock (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (sb-bsd-sockets:socket-bind sock path)
    (sb-bsd-sockets:socket-listen sock 16)
    sock))

(defun close-listener (listener)
  #+ccl (ignore-errors (close listener))
  #+sbcl (ignore-errors (sb-bsd-sockets:socket-close listener)))

(defun serve-peer (stream)
  (unwind-protect
       (loop for line = (read-line stream nil nil)
             while line
             do (let ((id (jval-safe (jparse line) "id")))
                  (when id
                    (write-string
                     (jto-json (object "jsonrpc" "2.0"
                                       "id" id
                                       "result" (object "ok" t)))
                     stream)
                    (write-char #\Newline stream)
                    (finish-output stream))))
    (ignore-errors (close stream))))

(test socket-reconnect-and-close
  #+(or ccl sbcl)
  (let* ((path (test-socket-path))
         (listener (make-test-listener path))
         (accept (bordeaux-threads:make-thread
                  (lambda ()
                    (loop
                      (handler-case
                          (let ((peer (accept-client listener)))
                            (bordeaux-threads:make-thread
                             (lambda () (serve-peer peer))
                             :name "cl-herdr-client-test-peer"))
                        (error () (return)))))
                  :name "cl-herdr-client-test-accept")))
    (sleep 0.05)
    (unwind-protect
         (let ((*call-timeout* 2))
           (dotimes (i 30)
             (let ((conn (connect :path path :caller-name "reconnect")))
               (is (equal t (jval (call conn "ping") "ok")))
               (disconnect conn)
               (is-false (bordeaux-threads:thread-alive-p
                          (slot-value conn 'cl-herdr-client::reader-thread)))))
           (let ((main (connect :path path :caller-name "main"))
                 (other (connect :path path :caller-name "other")))
             (disconnect other)
             (is (equal t (jval (call main "after-close") "ok")))
             (disconnect main)))
      (ignore-errors (close-listener listener))
      (ignore-errors (bordeaux-threads:destroy-thread accept))
      (ignore-errors (delete-file path))))
  #-(or ccl sbcl)
  (skip "unix sockets are implemented for CCL and SBCL"))

;;; ---------------------------------------------------------------------------
;;; Typed results: every RPC wrapper returns an instance of the schema class
;;; (see src/classes.lisp), with accessors per property. These tests build
;;; jsown objects by hand and run the JVAL->CLASS converters directly, plus
;;; one end-to-end wrapper check with a stubbed transport.
;;; ---------------------------------------------------------------------------

(test typed-results
  ;; hello.result: nested core-info + (:list :string) props.
  (let* ((j (obj "core" (object "id" "1234" "name" "serve")
                 "features" (list "a" "b")
                 "framed" t
                 "generation" 3
                 "methods" (list "m1" "m2")
                 "version" "0.1.18"))
         (r (jval->hello-result j)))
    (is (typep r 'hello-result))
    (is (string= "0.1.18" (hello-result-version r)))
    (is (typep (hello-result-core r) 'core-info))
    (is (string= "1234" (core-info-id (hello-result-core r))))
    (is (string= "serve" (core-info-name (hello-result-core r))))
    (is (eq t (hello-result-framed r)))
    (is (eql 3 (hello-result-generation r)))
    (is (equal '("a" "b") (hello-result-features r)))
    (is (equal '("m1" "m2") (hello-result-methods r))))

  ;; machine-list.result: (:list machine-view).
  (let* ((r (jval->machine-list-result
             (obj "machines"
                  (list (object "id" "m1" "name" "alpha" "temporary" t)
                        (object "id" "m2" "name" "beta" "temporary" nil)))))
         (ms (machine-list-result-machines r)))
    (is (eql 2 (length ms)))
    (is (typep (first ms) 'machine-view))
    (is (string= "m1" (machine-view-id (first ms))))
    (is (string= "beta" (machine-view-name (second ms))))
    (is (null (machine-view-target (first ms)))))

  ;; run.result: nested refs, (:map ...) alists, and the rm/keep slots.
  (let* ((j (obj "address" "addr1"
                 "argv" (list "ls" "-la")
                 "first_message" (object "started" t "reason" "boot" "turn" 1)
                 "foreground" (object "name" "fg" "pid" 99 "cwd" "/tmp"
                                       "argv" (list "sh" "-c" "x"))
                 "labels" (object "k1" "v1" "k2" "v2")
                 "status" (object "state" "running" "title" "T" "progress" 50)
                 "records" (object "st1" (object "state" "done" "kind" "mk"))
                 "wait" (object "ended" t "exit-code" 0
                                 "children" (list (object "from" "c1")))
                 "rm" nil "keep" t
                 "name" "my-term" "notify" nil))
         (r (jval->run-result j)))
    (is (typep r 'run-result))
    (is (string= "addr1" (run-result-address r)))
    (is (equal '("ls" "-la") (run-result-argv r)))
    (is (typep (run-result-first-message r) 'first-message))
    (is (eq t (first-message-started (run-result-first-message r))))
    (is (eql 99 (foreground-pid (run-result-foreground r))))
    (is (string= "v1" (cdr (assoc "k1" (run-result-labels r) :test #'string=))))
    (is (string= "running" (status-state (run-result-status r))))
    (is (string= "done"
                 (status-state (cdr (assoc "st1" (run-result-records r)
                                           :test #'string=)))))
    (is (eq t (wait-result-ended (run-result-wait r))))
    (is (string= "c1"
                 (wait-result-from (first (wait-result-children
                                           (run-result-wait r))))))
    ;; rm/keep collide with the terminal.rm / terminal.keep RPC wrappers on
    ;; class terminal; on run-result they keep their plain names (both NIL here).
    (is (null (run-result-rm r)))
    (is (eq t (run-result-keep r)))
    (is (null (run-result-exit-code r))))

  ;; terminal: the rm / keep *properties* get -p accessors so they don't
  ;; shadow the terminal.rm / terminal.keep wrappers.
  (let* ((r (jval->terminal (obj "name" "t1" "rm" t "keep" nil "rows" 24))))
    (is (typep r 'terminal))
    (is (string= "t1" (terminal-name r)))
    (is (eq t (terminal-rm-p r)))
    (is (null (terminal-keep-p r)))
    (is (eql 24 (terminal-rows r)))
    ;; while the wrappers keep their names:
    (is (fboundp 'terminal-rm))
    (is-false (eq (symbol-function 'terminal-rm)
                  (symbol-function 'terminal-rm-p))))

  ;; subscribe.result: (:list terminal) inside the result.
  (let* ((r (jval->subscribe-result
             (obj "channel" 1 "seq" 42
                  "terminals" (list (object "name" "a" "rm" t))))))
    (is (eql 1 (subscribe-result-channel r)))
    (is (eql 42 (subscribe-result-seq r)))
    (is (eql 1 (length (subscribe-result-terminals r))))
    (is (string= "a" (terminal-name (first (subscribe-result-terminals r))))))

  ;; doc-get.result value is :any (opaque) -- a jsown object we set it to.
  (let* ((r (jval->doc-get-result
             (obj "value" (object "count" 1) "version" 7))))
    (is (eql 7 (doc-get-result-version r)))
    (is (eql 1 (jval (doc-get-result-value r) "count"))))

  ;; JSON null (parsed, not :null) and missing keys both read as NIL.
  (let* ((r (jval->machine (jparse "{\"id\":\"x\",\"name\":null}"))))
    (is (string= "x" (machine-id r)))
    (is (null (machine-name r)))
    (is (null (machine-target r))))

  ;; wire keys with underscores come from Lisp dashes (created-ms -> created_ms).
  (let* ((r (jval->run-result (obj "created_ms" 5 "paste_gap_ms" 20))))
    (is (eql 5 (run-result-created-ms r)))
    (is (eql 20 (run-result-paste-gap-ms r))))

  ;; machine.version's accessor would be CL:MACHINE-VERSION, so it is renamed:
  ;; the class exports MACHINE-VERSION-P and never MACHINE-VERSION.
  (let ((r (jval->machine (obj "version" "9.9"))))
    (is (string= "9.9" (machine-version-p r))))
  (multiple-value-bind (sym status) (find-symbol "MACHINE-VERSION" :cl-herdr-client)
    (declare (ignore sym))
    (is-false (eq status :external))))

;;; A wrapper end-to-end: stub the transport's CALL so server.status runs the
;;; real wrapper + converter and returns a STATUS-RESULT instance.
(defun stub-call (conn method &optional params &key timeout)
  (declare (ignore conn method params timeout))
  (object "core" (object "id" "c1" "name" "core")
          "finished" 1 "live" 2 "pid" 100 "version" "0.1.18"
          "holders" (list (object "current" t "terminals" 0))))

(test wrapper-returns-typed-instance
  (let ((old (fdefinition 'call)))
    (unwind-protect
         (progn
           (setf (fdefinition 'call) #'stub-call)
           (let ((r (server-status :fake-conn)))
             (is (typep r 'status-result))
             (is (string= "core" (core-info-name (status-result-core r))))
             (is (eq t (holder-info-current
                        (first (status-result-holders r)))))))
      (setf (fdefinition 'call) old))))

;;; ---------------------------------------------------------------------------
;;; Runner
;;; ---------------------------------------------------------------------------

(defun run-tests ()
  ;; run! prints the FiveAM report (checks run/failed counts) and returns
  ;; T when nothing failed; the suite is named by keyword :cl-herdr-client.
  (unless (run! :cl-herdr-client)
    (error "cl-herdr-client tests FAILED"))
  (values t))

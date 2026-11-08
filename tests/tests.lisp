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
;;; Runner
;;; ---------------------------------------------------------------------------

(defun run-tests ()
  ;; run! prints the FiveAM report (checks run/failed counts) and returns
  ;; T when nothing failed; the suite is named by keyword :cl-herdr-client.
  (unless (run! :cl-herdr-client)
    (error "cl-herdr-client tests FAILED"))
  (values t))

;;;; SPDX-FileCopyrightText: 2026 Greg Wuller
;;;; SPDX-License-Identifier: MIT

;;;; api.lisp --- one wrapper per OpenRPC method
;;;;
;;;; Every function takes the connection first, then the method's required
;;;; args positionally and its optional args as keywords. All optional args
;;;; default to NIL, and NIL-valued params are omitted from the request (so
;;;; you pass only what you mean). Results are jsown objects.

(in-package #:cl-herdr-client)

(defmacro define-hc-method (lisp-name wire-name required &optional optional)
  "Define LISP-NAME, a thin wrapper around the JSON-RPC method WIRE-NAME.
REQUIRED and OPTIONAL are lists of (arg-name &optional wire-key) specs; the
wire key defaults to the arg name downcased (note wire keys use underscores,
so pass the second element when they differ: (outlive-parent \"outlive_parent\"))."
  (labels ((specs (list)
             (mapcar (lambda (s)
                       (if (consp s)
                           (list (first s)
                                 (string-downcase (string (second s))))
                           (list s (string-downcase (string s)))))
                     list)))
    (let* ((req (specs required))
           (opt (specs optional))
           (all (append req opt)))
      `(progn
         (setf (get ',lisp-name 'hc/wire-name) ,wire-name)
         (setf (get ',lisp-name 'hc/required)
               ',(mapcar (lambda (s) (string-downcase (symbol-name (first s)))) req))
         (setf (get ',lisp-name 'hc/optional)
               ',(mapcar (lambda (s) (string-downcase (symbol-name (first s)))) opt))
         (defun ,lisp-name (conn ,@(mapcar #'first req)
                           &key ,@(mapcar (lambda (s) (list (first s) nil)) opt))
           (call conn ,wire-name
                 (obj ,@(mapcan (lambda (s) (list (second s) (first s))) all))))))))

(defun method-info (name)
  "Metadata a wrapper records about the underlying JSON-RPC method: three
values -- the wire method name, its required args and its optional args (the
latter two as lists of downcased Lisp argument names)."
  (values (get name 'hc/wire-name)
          (get name 'hc/required)
          (get name 'hc/optional)))

;;; ---------------------------------------------------------------------------
;;; Handshake / server
;;; ---------------------------------------------------------------------------

(define-hc-method hello "hello"
  () ((calls-you "calls_you") (core) (features) generation framed))

(define-hc-method server-status "server.status" ())
(define-hc-method server-stop "server.stop" ())
(define-hc-method server-restart "server.restart" ())
(define-hc-method rpc-discover "rpc.discover" ())

;;; ---------------------------------------------------------------------------
;;; Templates / terminals
;;; ---------------------------------------------------------------------------

(define-hc-method template-list "templates.list" ())

(define-hc-method terminal-list "terminal.list"
  () (all labels))

(define-hc-method terminal-get "terminal.get"
  (terminal) (caller))

(define-hc-method terminal-run "terminal.run"
  ()
  (argv line name cwd env labels keep rm wait timeout on caller
        (outlive-parent "outlive_parent") (no-parent "no_parent")
        (no-notify "no_notify") parent size))

(define-hc-method terminal-kill "terminal.kill" (terminal) (caller))
(define-hc-method terminal-rm "terminal.rm" (terminal) (caller))

(define-hc-method terminal-keep "terminal.keep" (terminal keep))

(define-hc-method terminal-label "terminal.label" (terminal labels))

(define-hc-method terminal-read "terminal.read"
  (terminal) (caller lines))

(define-hc-method terminal-send "terminal.send"
  (terminal text) (caller force if timeout wait))

(define-hc-method terminal-wait "terminal.wait"
  () (caller children output terminal timeout))

(define-hc-method terminal-keys "terminal.keys"
  (terminal keys) (caller))

(define-hc-method terminal-interrupt "terminal.interrupt"
  (terminal) (timeout))

(define-hc-method terminal-put "terminal.put"
  (terminal data name))

;;; ---------------------------------------------------------------------------
;;; Machines / files / documents
;;; ---------------------------------------------------------------------------

(define-hc-method machine-exec "machine.exec"
  () (argv cwd env input line on timeout))

(define-hc-method file-read "file.read"
  (path) (cwd limit offset on))

(define-hc-method file-write "file.write"
  (path data) (cwd on))

(define-hc-method file-edit "file.edit"
  (path edits) (cwd on))

(define-hc-method doc-get "doc.get" (name) (on))

(define-hc-method doc-set "doc.set"
  () (name value version on))

(define-hc-method machine-add "machine.add"
  () (target via name session temporary))

(define-hc-method machine-list "machine.list" ())

(define-hc-method machine-connect "machine.connect" (machine))

(define-hc-method machine-rename "machine.rename"
  (machine (new-name "new_name")))

(define-hc-method machine-rm "machine.rm" (machine))

;;; ---------------------------------------------------------------------------
;;; Events (the request side; events themselves arrive as notifications and
;;; land in the connection mailbox -- see events.lisp)
;;; ---------------------------------------------------------------------------

(define-hc-method events-subscribe "events.subscribe"
  () (terminal (children-of "children_of") labels))

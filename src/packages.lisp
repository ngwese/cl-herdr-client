;;;; SPDX-FileCopyrightText: 2026 Greg Wuller
;;;; SPDX-License-Identifier: MIT

;;;; packages.lisp --- cl-herdr-client package definition

(defpackage #:cl-herdr-client
  (:use #:cl)
  (:nicknames #:hc)
  (:documentation "Client for the herdr-core daemon (hc).

Results of the RPC calls are jsown objects (http://quickdocs.org/jsown/),
addressed with JSOWN:VAL / returned here as H:JVAL, and stringified with
H:JTO-JSON. Function params that are JSON objects accept either a jsown
object (built with H:OBJECT, H:OBJ, H:ALIST->JS or JSOWN:NEW-JS) or a plain
alist (HS:ALIST->JS).")

  (:export
   ;; ---- jsown re-exports ----
   #:jval                          ; (jval obj "key") => JSOWN:VAL
   #:jval-safe
   #:jto-json                      ; => JSOWN:TO-JSON
   #:jparse                        ; => JSOWN:PARSE
   #:js-alist                      ; jsown object -> alist
   ;; json building helpers (runtime)
   #:obj                           ; build object, dropping nil values
   #:object                        ; build object, keeping nil values
   #:alist->js
   #:plist->js
   ;; base64 helpers (file.write, machine.exec, terminal.put need it)
   #:base64-encode
   #:base64-decode

   ;; ---- connection ----
   #:herdr-connection
   #:connect                       ; &key path caller-name generation
   #:disconnect
   #:connected-p
   #:default-socket-path
   #:*default-socket-path*
   #:connection-hello             ; hello result from connect

   ;; ---- transport ----
   #:call                          ; (call conn "method" params)
   #:notify                        ; fire a notification, no reply expected
   #:*call-timeout*                ; default per-call timeout (seconds)
   #:method-info                   ; wire name / required / optional of a wrapper

   ;; ---- errors ----
   #:herdr-error
   #:herdr-rpc-error               ; JSON-RPC error response
   #:herdr-connection-error
   #:herdr-timeout
   #:herdr-error-message
   #:herdr-rpc-error-code
   #:herdr-rpc-error-kind

   ;; ---- events / notifications (async) ----
   #:event-subscription
   #:subscribe
   #:close-event-subscription
   #:next-event
   #:drain-events
   #:pending-events-p
   #:start-event-loop
   #:sub-connection
   #:sub-seq

   ;; ---- API methods (one function per OpenRPC method) ----
   #:hello
   #:server-status
   #:server-stop
   #:server-restart
   #:template-list
   #:terminal-list
   #:terminal-get
   #:terminal-run
   #:terminal-kill
   #:terminal-rm
   #:terminal-keep
   #:terminal-label
   #:terminal-read
   #:terminal-send
   #:terminal-wait
   #:terminal-keys
   #:terminal-interrupt
   #:terminal-put
   #:machine-exec
   #:file-read
   #:file-write
   #:file-edit
   #:doc-get
   #:doc-set
   #:events-subscribe
   #:machine-add
   #:machine-list
   #:machine-connect
   #:machine-rename
   #:machine-rm
   #:rpc-discover))

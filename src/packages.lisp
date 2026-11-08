;;;; SPDX-FileCopyrightText: 2026 Greg Wuller
;;;; SPDX-License-Identifier: MIT

;;;; packages.lisp --- cl-herdr-client package definition

(defpackage #:cl-herdr-client
  (:use #:cl)
  (:nicknames #:hc)
  (:documentation "Client for the herdr-core daemon (hc).

Every RPC wrapper returns a typed result: an instance of the class for the
method's result schema (see `hc schema`), with one slot per property. Nested
objects are instances of their own classes, arrays of objects are lists of
instances, and objects such as `labels`/`records` become alists. Each class
has accessors CLASS-SLOT; the underlying jsown object (from which instances
are built by JVAL->CLASS) is still available via H:JVAL / H:JTO-JSON if you
need it. Function params that are JSON objects accept either a jsown object
(built with H:OBJECT, H:OBJ, H:ALIST->JS or JSOWN:NEW-JS) or a plain alist
(H:ALIST->JS).")

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
   #:rpc-discover

   ;; ---- schema classes: one per herdr-core result schema (class + its slots) ----
   ;; Each class carries accessors CLASS-SLOT (e.g. TERMINAL-ADDRESS) and
   ;; JVAL->CLASS builds an instance from a raw jsown object.
   ;; hello-result + its slots
   #:hello-result
   #:jval->hello-result
   ;; core-info + its slots
   #:core-info
   #:jval->core-info
   ;; status-result + its slots
   #:status-result
   #:jval->status-result
   ;; holder-info + its slots
   #:holder-info
   #:jval->holder-info
   ;; stop-result + its slots
   #:stop-result
   #:jval->stop-result
   ;; run-result + its slots
   #:run-result
   #:jval->run-result
   ;; first-message + its slots
   #:first-message
   #:jval->first-message
   ;; foreground + its slots
   #:foreground
   #:jval->foreground
   ;; status + its slots
   #:status
   #:jval->status
   ;; wait-result + its slots
   #:wait-result
   #:jval->wait-result
   ;; templates-result + its slots
   #:templates-result
   #:jval->templates-result
   ;; template-info + its slots
   #:template-info
   #:jval->template-info
   ;; list-result + its slots
   #:list-result
   #:jval->list-result
   ;; machine-view + its slots
   #:machine-view
   #:jval->machine-view
   ;; terminal + its slots
   #:terminal
   #:jval->terminal
   ;; remove-result + its slots
   #:remove-result
   #:jval->remove-result
   ;; read-result + its slots
   #:read-result
   #:jval->read-result
   ;; attach-result + its slots
   #:attach-result
   #:jval->attach-result
   ;; send-result + its slots
   #:send-result
   #:jval->send-result
   ;; keys-result + its slots
   #:keys-result
   #:jval->keys-result
   ;; interrupt-result + its slots
   #:interrupt-result
   #:jval->interrupt-result
   ;; put-result + its slots
   #:put-result
   #:jval->put-result
   ;; exec-result + its slots
   #:exec-result
   #:jval->exec-result
   ;; file-read-result + its slots
   #:file-read-result
   #:jval->file-read-result
   ;; file-result + its slots
   #:file-result
   #:jval->file-result
   ;; doc-get-result + its slots
   #:doc-get-result
   #:jval->doc-get-result
   ;; doc-set-result + its slots
   #:doc-set-result
   #:jval->doc-set-result
   ;; subscribe-result + its slots
   #:subscribe-result
   #:jval->subscribe-result
   ;; machine + its slots
   #:machine
   #:jval->machine
   ;; machine-list-result + its slots
   #:machine-list-result
   #:jval->machine-list-result
   ;; rpc.discover returns an OpenRPC document (raw jsown), see rpc-discover-result
   #:rpc-discover-result
   #:jval->rpc-discover-result
   #:rpc-discover-result-document))

;;;; SPDX-FileCopyrightText: 2026 Greg Wuller
;;;; SPDX-License-Identifier: MIT

(asdf:defsystem "cl-herdr-client"
  :description "A Common Lisp client for the herdr-core daemon (hc).

herdr-core is the daemon behind the `hc` CLI: it keeps programs and coding
agents alive in persistent terminals. It speaks JSON-RPC 2.0, one message per
line, over a unix-domain socket on unix (and a named pipe on Windows); see
`hc schema` for the OpenRPC definition. This system provides an
authenticated-free JSON-RPC transport for that endpoint (connect,
request/response with id correlation, asynchronous notifications) plus thin
wrappers for every method in the schema (terminal.run, terminal.send,
terminal.wait, file.*, machine.*, doc.*, events.subscribe, ...).

Dependencies are pulled from Quicklisp:
  - jsown            JSON parser/writer (jsown objects)
  - bordeaux-threads reader thread + notification mailbox (async events)
  - cl-base64        base64 for file.write / machine.exec / terminal.put
  - alexandria       utilities

The only implementation-specific piece is the transport itself: Clozure CL's
native :address-family :file unix sockets, SBCL's sb-bsd-sockets (unix only),
or -- on Windows SBCL, where unix sockets don't exist -- a raw Win32
named-pipe transport (WaitNamedPipe/CreateFile) that follows the same
one-JSON-message-per-line protocol over the matching \\\\.\\pipe\\ endpoint."
  :author "Greg Wuller"
  :license "MIT"
  :version "0.1.0"
  :depends-on (:alexandria
               :jsown
               :bordeaux-threads
               :cl-base64)
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "transport")
                             (:file "classes")
                             (:file "api")
                             (:file "events"))))
  ;; test-op: `(asdf:test-system :cl-herdr-client)` runs the FiveAM suite.
  ;; The tests exercise the pure helpers (JSON building, base64, wrapper
  ;; metadata) and need no daemon.
  :in-order-to ((test-op (test-op "cl-herdr-client/tests"))))

(asdf:defsystem "cl-herdr-client/tests"
  :description "FiveAM unit tests for cl-herdr-client (no daemon required)."
  :author "Greg Wuller"
  :license "MIT"
  :version "0.1.0"
  :depends-on (:cl-herdr-client
               :fiveam)
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "tests"))))
  :perform (test-op (op c)
             (uiop:symbol-call :cl-herdr-client/tests :run-tests)))

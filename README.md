# cl-herdr-client

A Common Lisp client for the **herdr-core** daemon (`hc`).

herdr-core is the always-running daemon that supervises terminals, machines,
files and documents from the herdr project. It speaks **JSON-RPC 2.0**, one
JSON message per line, over a **unix-domain socket**. The method set is
discovered from `hc schema` and each method gets a thin, ergonomic Lisp
wrapper.

- Dependencies (all from Quicklisp): `jsown`, `bordeaux-threads`,
  `cl-base64`, `alexandria`, `uiop`.
- Every RPC wrapper returns a **typed result**: an instance of the class for
  the method's result schema (generated from `hc schema`), with one slot (and
  accessor `CLASS-SLOT`) per JSON property. Nested objects are instances of
  their own class, arrays of objects are lists of instances, and free-form
  objects (`labels`, `records`) become alists. See
  [Typed results](#typed-results).
- The only external dependency on the daemon is the socket — the tests are
  otherwise self-contained.

## Supports environments

| OS | SBCL | CCL |
| --- | --- | --- |
| Linux | yes | yes |
| macOS | yes | yes |
| Windows | yes | — |

---

## Loading

```lisp
;; with the repo in your asdf central registry / local-projects:
(ql:quickload :cl-herdr-client)      ; or (asdf:load-system :cl-herdr-client)
```

`cl-herdr-client` has a nickname **`hc`**; `(in-package :cl-herdr-client)` or use
the `hc:` prefix.

---

## Quick start

```lisp
(use-package :cl-herdr-client)

(setq conn (hc:connect))                            ; default socket, does the hello handshake
;; => <herdr-connection>, plus a second value: the hello RESULT instance

(let ((run (hc:terminal-run conn :name "echo" :line "echo hi there")))
  (format t "~a~%" (hc:run-result-address run)))    ; e.g. "t1x"

(hc:wait-result-reason (hc:terminal-wait conn :terminal "t1x" :timeout 10)) ; "exit"
(hc:read-result-text (hc:terminal-read conn "t1x" :lines 40))
(hc:terminal-rm conn "t1x")

(hc:disconnect conn)
```

`run-result` is the class for `terminal.run`'s result — the wrapper returned
an *instance* of it, and `run-result-address` is its accessor.

---

## Connections

```lisp
(connect &key (path (default-socket-path)) caller-name (generation 1))
```

- Opens the unix socket and performs the `hello` handshake. The default path
  follows herdr-core: `HC_SOCKET` if set, else
  `$XDG_RUNTIME_DIR/herdr-core/<session>.sock` (or `/run/user/<uid>/...` when
  that runtime dir exists), else
  `~/.local/state/herdr-core/<session>/<session>.sock` (the usual macOS
  fallback). Session is `HC_SESSION` or `default`. Override with `:path`.
- `(connection-hello conn)` returns the hello result instance — e.g.
  `(hello-result-version (connection-hello conn))`.
- `(disconnect conn)` closes the socket and fails any in-flight requests.
- `(connected-p conn)` — is the socket open and its reader thread alive?
- `default-socket-path` / `*default-socket-path*` — inspect or rebind.

Each connection runs a **background reader thread** that reads lines off the
socket, correlates responses to in-flight requests by `id`, and parks
asynchronous notifications in a thread-safe FIFO mailbox. Your calling thread
is never on the socket's read path.

---

## Talking JSON

Functions whose params are JSON objects accept a **jsown object** or a plain
**alist**. The helpers:

| Helper | Purpose |
|---|---|
| `(obj "a" 1 "b" "two")` | build an object, **dropping NIL values** (default for RPC params — pass only what you mean) |
| `(object "a" 1 "b" nil)` | build an object, **keeping NIL values as JSON `null`** |
| `(alist->js '(("a" . 1)))` / `(plist->js '("a" 1))` | build from existing data |
| `(jval o "key")` | value of a key (`jsown:val`) |
| `(jval-safe o "key")` | same, or NIL when absent |
| `(jto-json o)` | serialize an object to text |
| `(jparse text)` | parse JSON text into an object |
| `(js-alist o)` | object → alist |
| `(base64-encode data)` / `(base64-decode text)` | base64, as the daemon wants for `file.write`, `machine.exec` input and `terminal.put` (string → UTF-8 bytes, or pass an `(unsigned-byte 8)` vector) |

Gotcha: jsown represents JSON `null` as the keyword `:null`. A raw CL `NIL`
serializes as `[]` (an empty array), which is why `object` turns NIL into
`:null` and `obj` skips NIL keys entirely.

---

## Calling methods

Use the generated wrappers — one per OpenRPC method — or the raw transport
when you need to:

```lisp
;; wrapper: (name conn required-args... &key optional-args...)
(terminal-run conn :name "t" :line "sleep 5")
(terminal-send conn "t1x" "ls -la" :timeout 5)
(doc-set conn :name "my-doc" :value (object "count" 1) :version 3)

;; raw transport
(call conn "terminal.run" (obj "name" "t" "line" "sleep 5") :timeout 30)
(notify conn "something.event")          ; no reply expected

(method-info 'terminal-run)     ; => wire name, required args, optional args
```

Design notes:

- The connection is always the **first argument**.
- **Required** params are positional; **optional** params are keywords, all
  defaulting to NIL, and NIL-valued ones are omitted from the request.
- Wire keys use underscores where Lisp uses dashes; the wrappers translate
  (e.g. `:no-notify` → `"no_notify"`, `:outlive-parent` → `"outlive_parent"`).
- Return values are **typed instances** of the schema classes (see
  [Typed results](#typed-results)), not jsown objects. Optional `on` params let
  the daemon send a notification on an event connection instead of a live
  reply.
- `*call-timeout*` defaults to 300 s (per-call `:timeout` overrides).

### Full API reference (`hc:`/`cl-herdr-client:`)

| Function | JSON-RPC method |
|---|---|
| `hello` | `hello` |
| `server-status` `server-stop` `server-restart` `rpc-discover` | `server.*`, `rpc.discover` |
| `template-list` | `templates.list` |
| `terminal-list` `terminal-get` `terminal-run` `terminal-kill` `terminal-rm` `terminal-keep` `terminal-label` | `terminal.*` |
| `terminal-read` `terminal-send` `terminal-wait` `terminal-keys` `terminal-interrupt` `terminal-put` | `terminal.*` |
| `machine-exec` | `machine.exec` |
| `file-read` `file-write` `file-edit` | `file.*` |
| `doc-get` `doc-set` | `doc.*` |
| `machine-add` `machine-list` `machine-connect` `machine-rename` `machine-rm` | `machine.*` |
| `events-subscribe` | `events.subscribe` |

`(method-info 'terminal-run)` returns the wire name plus required/optional arg
lists for any of the above.

---

## Typed results

Each schema in `hc schema` becomes a CLOS class (see `src/classes.lisp`),
and every wrapper converts its reply into an instance (a collection of them
for list results) before returning, so you never touch raw jsown for results.

- **Class per schema**: `run-result`, `status-result`, `terminal`, `machine-view`,
  `hello-result`, … one slot per JSON property. The converter is
  `jval-><class>` (e.g. `(jval->run-result js)`) if you need it directly.
- **Accessors**: `CLASS-SLOT`, with JSON keys lower-cased and `_` ↔ `-`
  (`created_ms` → `run-result-created-ms`). A property whose plain accessor
  would collide with an RPC wrapper or a `:use`d package's symbol gets a `-p`
  suffix: `Terminal.rm`/`Terminal.keep` are `terminal-rm-p`/`terminal-keep-p`
  (so the `terminal.rm`/`terminal.keep` wrappers keep their names), and
  `machine.version` is `machine-version-p` (not `CL:MACHINE-VERSION`).
- **Nested objects** are instances of their own class —
  `(status-result-core st)` is a `core-info` instance with
  `(core-info-id …)`/`(core-info-name …)`.
- **Arrays of objects** are lists of instances —
  `(machine-list-result-machines r)` is a list of `machine-view`.
- **Free-form objects** (`labels`, `records`) are alists of `(key . value)`,
  values converted per schema (e.g. `run-result-records` maps to `status`
  instances).
- **Missing keys and JSON `null`** both read as `NIL`. `doc.get`/`doc.set`
  `value` is opaque (`:any`) and stays a jsown object — reach into it with
  `jval`/`jval-safe`.

```lisp
(let ((st (server-status conn)))        ; a status-result instance
  (core-info-name (status-result-core st)) ; "serve"
  (status-result-pid st))

(let ((lst (machine-list conn)))        ; a machine-list-result instance
  (mapcar #'machine-view-name (machine-list-result-machines lst)))
```

If you ever do need the raw jsown result, keep the connection's last raw reply
via `call`/`connect` internals, or build it back with `jto-json` — but the
accessors above are the intended interface.

---

## Errors

Conditions (all subclass `herdr-error`):

| Condition | Raised when |
|---|---|
| `herdr-rpc-error` | the daemon replies with a JSON-RPC `error` object |
| `herdr-connection-error` | socket/stream problems, closed connection, handshake failure |
| `herdr-timeout` | no response within the `:timeout`/`*call-timeout*` window |

Accessors: `herdr-error-message`, `herdr-rpc-error-code`, `herdr-rpc-error-kind`
(the daemon's `error.data.kind`, e.g. `not_found`).

---

## Asynchronous events (notifications)

**Protocol fact:** in the plain, unframed protocol the daemon uses, once you
call `events.subscribe` on a connection, *that connection now carries only
notifications and stops answering requests*. `cl-herdr-client` therefore does the
right thing for you:

> `subscribe` always opens its **own dedicated connection**. The
> request/response connection you normally use is never polluted.

```lisp
(let ((sub (subscribe :terminal "t1x")))       ; opens a dedicated connection
  (sub-seq sub)                                ; initial `seq` from the daemon
  ;; poll for notifications:
  (next-event (sub-connection sub) :timeout 2)
  ;;  → next event object, or NIL after 2 s
  (drain-events (sub-connection sub))          ; non-blocking: everything queued
  (close-event-subscription sub))              ; daemon has no unsubscribe;
;;                                              closing the connection ends it
```

- `subscribe &key path terminal children-of labels` → an `event-subscription`.
- `(pending-events-p conn)` — anything already in a connection's mailbox?
- `(start-event-loop on-event &key ...)` — subscribe and run `on-event` (a
  function of one argument, the event object) on a background thread until
  `close-event-subscription`.

Events are jsown objects like
`{"jsonrpc" "2.0", "method" "event", "params" {...}}`; the terminal address is
at `(jval (jval-safe e "params") "terminal")` and the type at
`(jval-safe (jval-safe e "params") "type")` (e.g. `started`, `output`, `exit`,
`removed`).

---

## Concurrency notes

- **Reader thread per connection**, named `cl-herdr-client-reader`; responses are
  matched by JSON-RPC `id`, notifications go to the mailbox. Lock usage is
  minimal and there are no shared mutable globals.
- `disconnect` shuts down the read side of the socket and **joins the reader
  before the descriptor is closed**. On Clozure, closing the fd while that
  thread is still blocked in `read-line` lets the kernel reuse the number for
  the next `connect`, and the stale reader consumes the new connection's
  reply. Joining first closes that window on both CCL and SBCL.
- Deadlines, not `condition-wait` return values: bordeaux-threads **0.9.4's**
  CCL backend makes `condition-wait` return `T` even on timeout. `call` and
  `next-event` therefore keep an absolute internal deadline and re-check
  completion, so `herdr-timeout` fires when it should. The same wait is a
  native condition variable on SBCL.

---

## Tests (`cl-herdr-client/tests`)

Structured with the **FiveAM** framework; no daemon needed.

```sh
ccl --batch --load ~/quicklisp/setup.lisp \
    --eval '(push #p"/path/to/this/repo/" asdf:*central-registry*)' \
    --eval '(asdf:test-system :cl-herdr-client)' \
    --eval '(ccl:quit)'

sbcl --noinform --disable-debugger --load ~/quicklisp/setup.lisp \
    --eval '(push #p"/path/to/this/repo/" asdf:*central-registry*)' \
    --eval '(asdf:test-system :cl-herdr-client)' \
    --eval '(sb-ext:quit)'
```

Current suites: `json-object-builders`, `json-round-trip`, `base64`,
`api-metadata`, `socket-reconnect-and-close` (30 reconnects, then a call on
one connection after another is closed), `typed-results` (converters,
accessors, nested instances, lists/maps, NIL-for-null) and
`wrapper-returns-typed-instance` (a wrapper + converter round-trip against a
stubbed transport). Status: **141 checks, 100% pass** on CCL and SBCL.

## Demo

`demo.lisp` is an end-to-end smoke test against a **live** daemon: hello,
server status, terminal run/wait/read/rm, an error round-trip, file
write/read, doc get/set, an events subscription, and a `terminal.send`-into-`cat`
exchange.

```sh
ccl --batch --load demo.lisp
sbcl --noinform --disable-debugger --load demo.lisp --eval '(sb-ext:quit)'
```

---

## File layout

```
cl-herdr-client.asd        ASDF system + cl-herdr-client/tests test system
src/packages.lisp       package + exports
src/transport.lisp      socket, reader thread, JSON helpers, call/notify, conditions
src/classes.lisp        schema classes (define-hc-schema) + jval->CLASS converters
src/api.lisp            one wrapper per OpenRPC method (+ method-info)
src/events.lisp         dedicated-connection event subscriptions
tests/tests.lisp        FiveAM suite
demo.lisp               live-daemon smoke test
```

;;;; SPDX-FileCopyrightText: 2026 Greg Wuller
;;;; SPDX-License-Identifier: MIT

;;;; transport.lisp --- backend-agnostic connection + JSON-RPC 2.0 core
;;;;
;;;; herdr-core speaks JSON-RPC 2.0, one message per line, over a unix-domain
;;;; socket on unix and a named pipe on Windows.  Endpoint plumbing -- opening
;;;; the stream (CONNECT-SOCKET), unblocking a polling reader
;;;; (SHUTDOWN-INPUT), and pumping lines off the stream (READER-RUN) -- depends
;;;; on the operating system and lives in transport-unix.lisp /
;;;; transport-win32.lisp; exactly one of those is compiled
;;;; (cl-herdr-client.asd).  This file holds what every backend shares: the
;;;; JSON helpers, the conditions, the connection object, the mailbox, the
;;;; reader-thread lifecycle, and the send / request-response machinery.

(in-package #:cl-herdr-client)

;; ---- transport protocol --------------------------------------------------
;; Implemented by transport-unix.lisp / transport-win32.lisp.  The ftype
;; declarations let this file compile before its backend is loaded; without
;; them SBCL warns that the functions are undefined at compile time.

(declaim (ftype (function (t) t) connect-socket shutdown-input))
(declaim (ftype (function (t t) t) reader-run))

;;; ---------------------------------------------------------------------------
;;; JSON helpers (runtime, since jsown:new-js / jsown:extend-js are macros)
;;; ---------------------------------------------------------------------------

(defun jval (obj key)
  "JSOWN:VAL with a shorter name: the value of KEY in the jsown object OBJ."
  (jsown:val obj key))

(defun jval-safe (obj key)
  "Like JSOWN:VAL-SAFE: value of KEY, or NIL when missing."
  (jsown:val-safe obj key))

(defun jto-json (obj)
  "Stringify a jsown object (or any CL value jsown can serialize)."
  (jsown:to-json obj))

(defun jparse (string)
  "Parse STRING as JSON into a jsown object."
  (jsown:parse string))

(defun js-alist (js)
  "A jsown JSON object -> an alist of its (key . value) pairs."
  (loop for (k . v) in (cdr js)
        collect (cons k v)))

(defun object (&rest key-values)
  "Build a jsown JSON object, keeping every key. NIL values become JSON null
(jsown represents null as the keyword :NULL; a raw NIL would otherwise be
serialized as an empty array). Contrast with OBJ, which drops NIL keys."
  (let ((js (jsown:empty-object)))
    (loop for (k v) on key-values by #'cddr
          do (setf (jsown:val js k) (if (null v) :null v)))
    js))

(defun obj (&rest key-values)
  "Build a jsown JSON object, dropping keys whose value is NIL.
Use for RPC params so optional arguments simply don't appear."
  (let ((js (jsown:empty-object)))
    (loop for (k v) on key-values by #'cddr
          when v do (setf (jsown:val js k) v))
    js))

(defun alist->js (alist)
  "An alist of (key . value) -> jsown JSON object."
  (let ((js (jsown:empty-object)))
    (dolist (p alist js)
      (setf (jsown:val js (car p)) (cdr p)))))

(defun plist->js (plist)
  "A plist key value key value ... -> jsown JSON object."
  (apply #'obj plist))

(defun base64-encode (data)
  "Encode DATA to its base64 text. DATA is a string (encoded as UTF-8) or a
vector of octets -- what the daemon wants for file.write, machine.exec input
and terminal.put."
  (etypecase data
    (string (cl-base64:string-to-base64-string data))
    ((vector (unsigned-byte 8))
     (cl-base64:usb8-array-to-base64-string data))))

(defun base64-decode (data)
  "Decode a base64 STRING back to its textual content (UTF-8)."
  (cl-base64:base64-string-to-string data))

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition herdr-error (error)
  ((message :initarg :message :initform nil :accessor herdr-error-message))
  (:report (lambda (c stream)
             (format stream "cl-herdr-client: ~a"
                     (or (herdr-error-message c) "error")))))

(define-condition herdr-rpc-error (herdr-error)
  ((code :initarg :code :initform nil :accessor herdr-rpc-error-code)
   (kind :initarg :kind :initform nil :accessor herdr-rpc-error-kind))
  (:report (lambda (c stream)
             (format stream "herdr RPC error ~a (~a): ~a"
                     (herdr-rpc-error-code c)
                     (or (herdr-rpc-error-kind c) "?")
                     (herdr-error-message c)))))

(define-condition herdr-connection-error (herdr-error) ())

(define-condition herdr-timeout (herdr-error) ())

;;; ---------------------------------------------------------------------------
;;; Endpoint path discovery
;;; ---------------------------------------------------------------------------

(defvar *default-socket-path* nil
  "Default location of the herdr-core endpoint: a unix socket path on unix,
the named pipe name on Windows.  The transport backend (transport-unix.lisp /
transport-win32.lisp) fills this in as it loads; override with CONNECT :PATH.")

(defun default-socket-path ()
  "The default endpoint, from *DEFAULT-SOCKET-PATH*."
  *default-socket-path*)

;;; ---------------------------------------------------------------------------
;;; Connection
;;; ---------------------------------------------------------------------------

(defstruct (pending (:constructor make-pending ()))
  (cond (bt:make-condition-variable))
  (lock (bt:make-lock "herdr pending"))
  done
  value)

(defclass herdr-connection ()
  ((socket     :reader conn-socket :initarg :socket)
   (lock       :reader conn-lock :initform (error "no lock") :initarg :lock)
   ;; pending requests: id -> pending
   (pending    :reader conn-pending :initform (make-hash-table))
   (pending-lock :reader conn-pending-lock :initarg :pending-lock)
   ;; mailbox of asynchronous notifications (a FIFO queue: front/back lists)
   (mb-front   :reader conn-mb-front :initform nil)
   (mb-back    :reader conn-mb-back :initform nil)
   (mb-lock    :reader conn-mb-lock :initarg :mb-lock)
   (mb-cond    :reader conn-mb-cond :initarg :mb-cond)
   (reader-thread :reader conn-reader-thread :initform nil)
   (next-id    :reader conn-next-id :initform 0)
   (closed     :reader conn-closed :initform nil)
   (hello      :reader conn-hello :initform nil)))

(defun connect (&key (path (default-socket-path))
                caller-name (generation 1))
  "Open a connection to the herdr-core daemon at PATH (default
*DEFAULT-SOCKET-PATH*). Performs the `hello` handshake and returns two values:
the connection and the hello result object."
  (let* ((stream (connect-socket path))
         (conn (make-instance 'herdr-connection
                              :socket stream
                              :lock (bt:make-lock "herdr write")
                              :pending-lock (bt:make-lock "herdr pending")
                              :mb-lock (bt:make-lock "herdr mailbox")
                              :mb-cond (bt:make-condition-variable))))
    (setf (slot-value conn 'reader-thread)
          (bt:make-thread (lambda () (reader-loop conn))
                          :name "cl-herdr-client-reader"))
    (handler-case
        (let ((hello-result
                (jval->hello-result
                 (call conn "hello" (obj "calls_you" caller-name
                                         "generation" generation)))))
          (setf (slot-value conn 'hello) hello-result)
          (values conn hello-result))
      (error (e)
        (ignore-errors (disconnect conn))
        (error 'herdr-connection-error
               :message (format nil "hello handshake with ~a failed: ~a" path e))))))

(defun connected-p (conn)
  "True when CONN's socket is open and its reader thread is alive."
  (and (not (slot-value conn 'closed))
       (let ((s (conn-socket conn)))
         (and s (open-stream-p s)))
       (bt:thread-alive-p (conn-reader-thread conn))))

(defun connection-hello (conn)
  "The hello result instance negotiated when CONN was opened, or NIL if the
handshake had not completed (e.g. the connection is in a transient state)."
  (conn-hello conn))

(defun wake-mailbox (conn)
  (bt:with-lock-held ((conn-mb-lock conn))
    (bt:condition-notify (conn-mb-cond conn))))

(defun disconnect (conn)
  "Close the connection and fail any in-flight requests.
The reader thread is joined before the descriptor is released, so a later
CONNECT cannot reuse it underneath a read that has not returned yet."
  (setf (slot-value conn 'closed) t)
  (let ((s (conn-socket conn)))
    (when (and s (open-stream-p s))
      (shutdown-input s)))
  (let ((thr (conn-reader-thread conn)))
    (when (and thr
               (not (eq thr (bt:current-thread)))
               (bt:thread-alive-p thr))
      (bt:join-thread thr)
      ;; bordeaux-threads' CCL backend joins the lisp thread as its function
      ;; returns, but the process is only marked not-alive a moment later, so
      ;; THREAD-ALIVE-P can still be true right after JOIN-THREAD. Wait that
      ;; finite window out so callers see a settled reader (and its fd is
      ;; really free) by the time DISCONNECT returns.
      (loop repeat 200 while (bt:thread-alive-p thr)
            do (sleep 0.001))))
  (let ((s (conn-socket conn)))
    (when (and s (open-stream-p s))
      (ignore-errors (close s))))
  (fail-all-pending conn :connection-closed)
  (wake-mailbox conn)
  (values))

;;; ---------------------------------------------------------------------------
;;; Mailbox (FIFO)
;;; ---------------------------------------------------------------------------

(defun queue-notification (conn msg)
  (let ((entry (list msg)))
    (bt:with-lock-held ((conn-mb-lock conn))
      (if (conn-mb-back conn)
          (setf (cdr (conn-mb-back conn)) entry
                (slot-value conn 'mb-back) entry)
          (setf (slot-value conn 'mb-front) entry
                (slot-value conn 'mb-back) entry))
      (bt:condition-notify (conn-mb-cond conn)))))

(defun pop-notification (conn)
  "Remove and return the next mailbox message. Caller holds CONN-MB-LOCK."
  (let ((front (conn-mb-front conn)))
    (when front
      (if (eq front (conn-mb-back conn))
          (setf (slot-value conn 'mb-front) nil
                (slot-value conn 'mb-back) nil)
          (setf (slot-value conn 'mb-front) (cdr front)))
      (car front))))

(defun dequeue-notification (conn)
  (bt:with-lock-held ((conn-mb-lock conn))
    (pop-notification conn)))

;;; ---------------------------------------------------------------------------
;;; Reader loop
;;; ---------------------------------------------------------------------------

(defun process-line (conn line)
  (let ((msg (jparse line)))
    (let ((id (jval-safe msg "id")))
      (if id
          (let ((pend (bt:with-lock-held ((conn-pending-lock conn))
                        (let ((p (gethash id (conn-pending conn))))
                          (when p (remhash id (conn-pending conn)))
                          p))))
            (when pend
              (bt:with-lock-held ((pending-lock pend))
                (setf (pending-value pend) msg
                      (pending-done pend) t)
                (bt:condition-notify (pending-cond pend)))))
          (queue-notification conn msg)))))

(defun reader-loop (conn)
  (let ((s (conn-socket conn)))
    (unwind-protect
         (reader-run conn s)
      ;; Close on this thread. The stream's descriptor stays ours until this
      ;; unwind finishes, which is before DISCONNECT's JOIN returns.
      (setf (slot-value conn 'closed) t)
      (fail-all-pending conn :connection-closed)
      (wake-mailbox conn)
      (when (and s (open-stream-p s))
        (ignore-errors (close s))))))

(defun process-line-ignoring-errors (conn line)
  (handler-case (process-line conn line)
    (error (e)
      (format *error-output*
              "cl-herdr-client: bad line ignored (~a): ~a~%"
              e line))))

(defun fail-all-pending (conn reason)
  (let ((pendings (bt:with-lock-held ((conn-pending-lock conn))
                    (let ((ps nil))
                      (maphash (lambda (id p)
                                 (declare (ignore id))
                                 (push p ps))
                               (conn-pending conn))
                      (clrhash (conn-pending conn))
                      ps))))
    (dolist (p pendings)
      (bt:with-lock-held ((pending-lock p))
        (setf (pending-value p) reason
              (pending-done p) t)
        (bt:condition-notify (pending-cond p))))))

;;; ---------------------------------------------------------------------------
;;; Send / request-response
;;; ---------------------------------------------------------------------------

(defvar *call-timeout* 300
  "Default seconds to wait for a JSON-RPC response before signalling
HERDR-TIMEOUT.")

(defun next-request-id (conn)
  (bt:with-lock-held ((conn-lock conn))
    (incf (slot-value conn 'next-id))))

(defun send-json (conn obj)
  (when (not (connected-p conn))
    (error 'herdr-connection-error :message "connection is closed"))
  (bt:with-lock-held ((conn-lock conn))
    (let ((s (conn-socket conn)))
      (write-string (jto-json obj) s)
      (write-char #\Newline s)
      (finish-output s))))

(defun call (conn method &optional params &key (timeout *call-timeout*))
  "Send a JSON-RPC request for METHOD (a string) with PARAMS (a jsown object,
HT:OBJ / HT:ALIST->JS, or NIL for none). Blocks for the response and returns
the `result` object. Signals HERDR-RPC-ERROR on an error response and
HERDR-TIMEOUT / HERDR-CONNECTION-ERROR on failure."
  (declare #+sbcl (sb-ext:muffle-conditions style-warning))
  ;; NB: SBCL alone warns about mixing &OPTIONAL and &KEY in one lambda list;
  ;; the combination is intentional and harmless elsewhere.
  (let* ((id (next-request-id conn))
         (pend (make-pending))
         (req (object "jsonrpc" "2.0"
                      "id" id
                      "method" method))
         (deadline (+ (get-internal-real-time)
                      (round (* timeout internal-time-units-per-second)))))
    (when params
      (setf (jsown:val req "params") params))
    (bt:with-lock-held ((conn-pending-lock conn))
      (setf (gethash id (conn-pending conn)) pend))
    (send-json conn req)
    ;; bordeaux-threads 0.9.4's CCL backend makes CONDITION-WAIT return T even
    ;; on timeout, so an absolute deadline and PENDING-DONE decide. The timeout
    ;; path takes the table lock before the per-request lock, matching
    ;; PROCESS-LINE, and still returns a reply that arrived as the deadline
    ;; expired.
    (loop
      (let (expired)
        (bt:with-lock-held ((pending-lock pend))
          (when (pending-done pend)
            (return))
          (let ((remaining (/ (- deadline (get-internal-real-time))
                              internal-time-units-per-second)))
            (if (<= remaining 0)
                (setf expired t)
                (bt:condition-wait (pending-cond pend) (pending-lock pend)
                                   :timeout remaining))))
        (when expired
          (let (done)
            (bt:with-lock-held ((conn-pending-lock conn))
              (bt:with-lock-held ((pending-lock pend))
                (setf done (pending-done pend))
                (unless done
                  (remhash id (conn-pending conn)))))
            (if done
                (return)
                (error 'herdr-timeout
                       :message (format nil "no response to ~a in ~a s"
                                        method timeout)))))))
    (let ((value (pending-value pend)))
      (cond
        ((eq value :connection-closed)
         (error 'herdr-connection-error
                :message (format nil "connection closed while awaiting ~a" method)))
        ((jval-safe value "error")
         (error (rpc-error-condition value)))
        (t (jval-safe value "result"))))))

(defun rpc-error-condition (msg)
  (let ((e (jval-safe msg "error")))
    (make-condition 'herdr-rpc-error
                    :code (jval-safe e "code")
                    :kind (jval-safe (jval-safe e "data") "kind")
                    :message (jval-safe e "message"))))

(defun notify (conn method &optional params)
  "Send a JSON-RPC notification (no id, no reply expected) for METHOD."
  (let ((req (object "jsonrpc" "2.0" "method" method)))
    (when params
      (setf (jsown:val req "params") params))
    (send-json conn req)))

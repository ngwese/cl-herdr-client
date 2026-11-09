;;;; SPDX-FileCopyrightText: 2026 Greg Wuller
;;;; SPDX-License-Identifier: MIT

;;;; transport-unix.lisp --- unix-domain socket backend
;;;;
;;;; Compiled only on non-Windows builds (cl-herdr-client.asd).  Provides the
;;;; transport protocol transport.lisp relies on, over a unix-domain socket:
;;;; Clozure CL's native :address-family :file sockets, or SBCL's
;;;; sb-bsd-sockets.  herdr-core listens there at
;;;; $XDG_RUNTIME_DIR/herdr-core/default.sock (or /run/user/<uid>/...).

#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-bsd-sockets))

(in-package #:cl-herdr-client)

;;; ---------------------------------------------------------------------------
;;; Endpoint discovery
;;; ---------------------------------------------------------------------------

(defun default-unix-socket-path ()
  "The default unix-domain socket herdr-core listens on."
  (or (let ((xdg (uiop:getenv "XDG_RUNTIME_DIR")))
        (when (and xdg (plusp (length xdg)))
          (namestring (merge-pathnames "herdr-core/default.sock"
                                       (uiop:ensure-directory-pathname xdg)))))
      "/run/user/1000/herdr-core/default.sock"))

;; Fills the endpoint slot transport.lisp declares.
(setf *default-socket-path* (default-unix-socket-path))

;;; ---------------------------------------------------------------------------
;;; Connection
;;; ---------------------------------------------------------------------------

(defun connect-socket (path)
  "Open a bidirectional character stream to the unix-domain socket at PATH.
Clozure uses its native AF_UNIX sockets; SBCL uses sb-bsd-sockets."
  #+ccl
  (ccl:make-socket :address-family :file :remote-filename (namestring path))
  #+sbcl
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (sb-bsd-sockets:socket-connect socket (namestring path))
    (sb-bsd-sockets:socket-make-stream socket
                                       :input t
                                       :output t
                                       :element-type 'character
                                       :external-format :utf-8
                                       :buffering :full
                                       :auto-close t))
  #-(or ccl sbcl)
  (error 'herdr-connection-error
         :message (format nil "cl-herdr-client: unix-domain sockets need Clozure CL or SBCL; got ~a"
                          (lisp-implementation-type))))

#+sbcl
(sb-alien:define-alien-routine ("shutdown" %socket-shutdown) sb-alien:int
  (fd sb-alien:int)
  (how sb-alien:int))

(defun shutdown-input (stream)
  "Make a blocked READ-LINE return without releasing the descriptor.
Closing the fd while the reader is still inside READ-LINE lets the kernel
hand that number to the next CONNECT.  On Clozure the old stream keeps the
number and reads the new connection's bytes, so the reply never reaches the
waiter.  Shutting down the read side unblocks the reader and leaves the fd
allocated until that thread has left the socket."
  #+ccl
  (ignore-errors (ccl:shutdown stream :direction :input))
  #+sbcl
  (let ((fd (sb-sys:fd-stream-fd stream)))
    (when (and (integerp fd) (>= fd 0))
      ;; 0 is SHUT_RD on Linux: further reads return EOF, the fd stays open.
      (%socket-shutdown fd 0)))
  #-(or ccl sbcl)
  nil
  nil)

;;; ---------------------------------------------------------------------------
;;; Reader
;;; ---------------------------------------------------------------------------

;;; unix-like builds block in READ-LINE; SHUTDOWN-INPUT makes it return EOF.
(defun reader-run (conn s)
  (loop
    (let ((line (handler-case (read-line s nil nil)
                  (error () :eof))))
      (cond
        ((or (eq line :eof) (null line)) (return))
        (t (process-line-ignoring-errors conn line))))))

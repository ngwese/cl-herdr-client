;;;; SPDX-FileCopyrightText: 2026 Greg Wuller
;;;; SPDX-License-Identifier: MIT

;;;; transport-win32.lisp --- Windows named-pipe backend (SBCL)
;;;;
;;;; Compiled only on Windows SBCL (cl-herdr-client.asd).  herdr-core on
;;;; Windows listens on a named pipe (\\.\pipe\herdr-core-<user>-<session>.sock)
;;;; rather than a unix-domain socket.  SBCL's file layer cannot open
;;;; \\.\pipe\... (it comes back with ERROR_PIPE_BUSY), so we open the pipe
;;;; with CreateFileW ourselves and wrap the resulting Win32 handle as an
;;;; fd-stream -- read-line / write-string / finish-output then behave like
;;;; any other stream.

(in-package #:cl-herdr-client)

;;; ---------------------------------------------------------------------------
;;; Win32 named-pipe plumbing
;;; ---------------------------------------------------------------------------

(defparameter +win32-generic-read+  #x80000000)
(defparameter +win32-generic-write+ #x40000000)
(defparameter +win32-open-existing+ 3)
(defparameter +win32-invalid-handle+ #xFFFFFFFF)

(defvar *pipe-open-timeout* 30
  "Seconds to wait for the daemon's named pipe to accept a client before
signalling HERDR-CONNECTION-ERROR.")

(sb-alien:define-alien-routine ("WaitNamedPipeW" %wait-named-pipe) sb-alien:int
  (name (sb-alien:* sb-alien:unsigned-char))
  (timeout sb-alien:unsigned-long))
(sb-alien:define-alien-routine ("CreateFileW" %create-file-w) sb-alien:unsigned-long
  (name (sb-alien:* sb-alien:unsigned-char))
  (access sb-alien:unsigned-long)
  (share sb-alien:unsigned-long)
  (secattr sb-alien:unsigned-long)
  (disp sb-alien:unsigned-long)
  (flags sb-alien:unsigned-long)
  (tmpl sb-alien:unsigned-long))
(sb-alien:define-alien-routine ("CloseHandle" %close-handle) sb-alien:int
  (handle sb-alien:unsigned-long))

(defun win32-wchar-buffer (string)
  "A NUL-terminated UTF-16LE copy of STRING, as an alien octet buffer."
  (let* ((bytes (sb-ext:string-to-octets string :external-format :utf-16le))
         (buf (sb-alien:make-alien sb-alien:unsigned-char (1+ (length bytes)))))
    (loop for b across bytes for i from 0
          do (setf (sb-alien:deref buf i) b))
    (setf (sb-alien:deref buf (length bytes)) 0)
    buf))

(defmacro with-win32-wchar ((ptr string) &body body)
  `(let* ((?buf (win32-wchar-buffer ,string))
          (,ptr (sb-alien:cast ?buf (sb-alien:* sb-alien:unsigned-char))))
     (unwind-protect (progn ,@body)
       (sb-alien:free-alien ?buf))))

(defparameter +win32-pipe-prefix+
  ;; the device namespace prefix `\\.\\pipe\\` as a native string
  (coerce (list #\\ #\\ #\. #\\ #\p #\i #\p #\e #\\) 'string))

(defun win32-device-path (path)
  "PATH may be a bare pipe name (herdr-core-g1988-default.sock) or a full
\\.\\pipe\\ name; always return the device path CreateFileW expects."
  (if (and (>= (length path) (length +win32-pipe-prefix+))
           (string-equal path +win32-pipe-prefix+
                         :end1 (length +win32-pipe-prefix+)))
      path
      (concatenate 'string +win32-pipe-prefix+ path)))

(defun win32-open-named-pipe (path &optional (timeout *pipe-open-timeout*))
  "Open the named pipe PATH (bare name or device path) and return a
bidirectional character stream over it. Waits up to TIMEOUT seconds for the
daemon's pipe to accept a client. Signals HERDR-CONNECTION-ERROR if it never
does (i.e. the daemon is not running)."
  (let ((device (win32-device-path path)))
    (with-win32-wchar (wpath device)
      (let ((deadline (+ (get-internal-real-time)
                         (round (* timeout internal-time-units-per-second)))))
        (loop
          ;; Give a moment for an instance to be free, then try to connect.
          (%wait-named-pipe wpath 200)
          (let ((h (%create-file-w wpath
                                   (logior +win32-generic-read+
                                           +win32-generic-write+)
                                   3 0
                                   +win32-open-existing+ 0 0)))
            (cond ((not (or (= h 0) (= h +win32-invalid-handle+)))
                   (return
                     (sb-sys:make-fd-stream h
                                            :input t
                                            :output t
                                            :element-type 'character
                                            :external-format :utf-8
                                            :buffering :full)))
                  ((>= (get-internal-real-time) deadline)
                   (return
                     (error 'herdr-connection-error
                            :message
                            (format nil
                                    "cannot connect to herdr-core named pipe ~a (is the daemon running?)"
                                    device)))))))))))

;;; ---------------------------------------------------------------------------
;;; Endpoint discovery
;;; ---------------------------------------------------------------------------

(defun windows-default-pipe ()
  "The named pipe herdr-core listens on for this user's `default` session:
\\.\pipe\herdr-core-<USER>-default.sock."
  (let ((user (or (uiop:getenv "USERNAME")
                  ;; fall back to the basename of %USERPROFILE%
                  (let ((home (uiop:getenv "USERPROFILE")))
                    (and home (file-namestring (uiop:parse-native-namestring home))))
                  "user")))
    (format nil "herdr-core-~a-default.sock" user)))

;; Fills the endpoint slot transport.lisp declares.
(setf *default-socket-path* (windows-default-pipe))

;;; ---------------------------------------------------------------------------
;;; Connection
;;; ---------------------------------------------------------------------------

(defun connect-socket (path)
  "Open a bidirectional character stream to the daemon's named pipe.
PATH may be a bare pipe name or a full \\.\\.pipe\\... device path."
  (win32-open-named-pipe (namestring path) *pipe-open-timeout*))

(defun shutdown-input (stream)
  "No-op: the Windows reader never blocks in READ-LINE (it polls), so there is
nothing to shut down -- DISCONNECT's stop flag is seen within a poll interval."
  (declare (ignore stream))
  nil)

;;; ---------------------------------------------------------------------------
;;; Reader
;;; ---------------------------------------------------------------------------

(defvar *reader-poll-seconds* 0.005
  "Seconds between named-pipe polls while no data is waiting.")

;;; A blocking READ-LINE over the named pipe handle cannot be interrupted
;;; (neither CancelIoEx nor CloseHandle unblocks it -- CloseHandle on a handle
;;; with a pending synchronous read in another thread deadlocks), so the
;;; reader polls the stream with a short sleep instead. It never blocks in
;;; READ-LINE: LISTEN says a character is ready / read-char reads one, and the
;;; loop returns to the poll (and the stop flag) between characters.
(defun reader-run (conn s)
  (let ((line (make-array 128 :element-type 'character
                          :fill-pointer 0 :adjustable t)))
    (loop
      (when (slot-value conn 'closed)
        (return))
      (if (and (open-stream-p s) (listen s))
          (let ((ch (read-char s nil :eof)))
            (cond
              ((or (eq ch :eof) (null ch)) (return))
              ((char= ch #\Newline)
               ;; NB: COERCE to STRING of an adjustable fill-pointered array
               ;; returns an alias (same object) on SBCL, so we must use
               ;; SUBSEQ to get a real copy: resetting the fill pointer below
               ;; would otherwise zero out the line we just parsed.
               (let ((done (subseq line 0 (fill-pointer line))))
                 (setf (fill-pointer line) 0)
                 (process-line-ignoring-errors conn done)))
              (t (vector-push-extend ch line))))
          (sleep *reader-poll-seconds*)))))

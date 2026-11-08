;;;; SPDX-FileCopyrightText: 2026 Greg Wuller
;;;; SPDX-License-Identifier: MIT

;;;; demo.lisp --- smoke-test / demo of the cl-herdr-client
;;;;
;;;; Exercises: connect/hello, server.status, terminal.run + terminal-wait +
;;;; terminal-read + terminal-rm, file.write + file.read, doc.get/set, error
;;;; handling, and an events subscription.
;;;;
;;;; Run:  ccl --batch --load demo.lisp
;;;;       sbcl --noinform --disable-debugger --load demo.lisp
;;;;            --eval '(sb-ext:quit)'
;;;; (loads cl-herdr-client from the directory this file lives in, and Quicklisp
;;;; from ~/quicklisp/setup.lisp when it is not already loaded)

(require :asdf)
#-quicklisp
(let ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file setup)
    (load setup)))
(defvar *here*
  (make-pathname :defaults (or *load-truename* *default-pathname-defaults*)
                 :name nil :type nil))
(push *here* asdf:*central-registry*)
(asdf:load-system :cl-herdr-client)

(defpackage #:herdr-demo (:use #:cl #:cl-herdr-client))
(in-package #:herdr-demo)

(defun main ()
  (format t "~%== cl-herdr-client demo ==~%")
  (multiple-value-bind (conn hello) (connect)
    (unwind-protect
         (progn
           (format t "~%[1] hello: core.name=~a version=~a~%"
                   (core-info-name (hello-result-core hello))
                   (hello-result-version hello))

           (let ((st (server-status conn)))
             (format t "[2] server.status: version=~a pid=~a live=~a~%"
                     (status-result-version st)
                     (status-result-pid st)
                     (status-result-live st)))

           (format t "[3] terminal.run a background echo...~%")
           ;; NB: herdr-core runs commands through the platform shell, so the
           ;; demo stays within the dialects understood on each host (cmd on
           ;; Windows, sh elsewhere).
           (let* ((line #-win32 "echo hello-from-cl-herdr-client; sleep 1"
                         #+win32 "echo hello-from-cl-herdr-client & timeout /t 1 /nobreak >nul")
                  (run (terminal-run conn :name "demo-echo"
                                     :line line
                                     :no-notify t))
                  (addr (run-result-address run)))
             (format t "    started: ~a~%" addr)
             (format t "    terminal-wait reason: ~a~%"
                     (wait-result-reason (terminal-wait conn :terminal addr)))
             (let ((r (terminal-read conn addr :lines 40)))
               (format t "    read text: ~a~%" (or (read-result-text r) "")))
             (terminal-rm conn addr))

           (format t "[4] error handling: get a bogus terminal...~%")
           (handler-case (terminal-get conn "definitely-not-a-terminal")
             (herdr-rpc-error (e)
               (format t "    caught herdr-rpc-error code=~a kind=~a~%"
                       (herdr-rpc-error-code e) (herdr-rpc-error-kind e))))

             (format t "[5] file.write + file.read roundtrip...~%")
           (let* ((path "/tmp/cl-herdr-client-demo.txt")
                  (payload "hello, cl-herdr-client!"))
             (file-write conn path (base64-encode payload))
             (let ((r (file-read conn path :limit 5)))
               (format t "    wrote+read: ~a~%" (file-read-result-text r))))

           (format t "[6] doc.get / doc.set (opaque JSON doc)...~%")
           (let ((before (doc-get conn "cl-herdr-client-demo-doc")))
             (format t "    before: version=~a value=~a~%"
                     (doc-get-result-version before)
                     (doc-get-result-value before))
             (doc-set conn :name "cl-herdr-client-demo-doc"
                      :value (object "count" 1 "who" "cl-herdr-client")
                      :version (doc-get-result-version before))
             (let ((after (doc-get conn "cl-herdr-client-demo-doc")))
               (format t "    after:  version=~a count=~a~%"
                       (doc-get-result-version after)
                       (jval (doc-get-result-value after) "count"))
               ;; tidy up
               (doc-set conn :name "cl-herdr-client-demo-doc"
                        :value (object)
                        :version (doc-get-result-version after))))

           (format t "[7] events on a dedicated connection...~%")
           (let* ((ev-addr (run-result-address
                            (terminal-run conn :name "demo-ev"
                                          :line "true"
                                          :no-notify t)))
                  (sub (subscribe :terminal ev-addr)))
             (format t "    subscribed, snapshot seq=~a (own connection)~%" (sub-seq sub))
             ;; grab whatever races in, up to ~2s
             (let ((deadline (+ (get-internal-real-time)
                                (* 2 internal-time-units-per-second))))
               (loop while (< (get-internal-real-time) deadline)
                     do (let ((next (next-event (sub-connection sub) :timeout 0.2)))
                          (when next
                            (format t "    event ~a~%" (jval-safe next "method"))))))
             (dolist (e (drain-events (sub-connection sub)))
               (format t "    drained event ~a~%" (jval-safe e "method")))
             (close-event-subscription sub)
             (terminal-rm conn ev-addr)
             (format t "    (subscription closed; terminal removed)~%"))

           (format t "[8] terminal.send into a reader, read it back, kill it...~%")
           ;; `cat` has no Windows equivalent in cmd; `more` reads stdin and
           ;; echoes it, staying alive until killed — the same behavior the
           ;; step needs on both platforms.
           (let* ((addr (run-result-address
                         (terminal-run conn :name "demo-cat"
                                       :line #-win32 "cat"
                                             #+win32 "more"
                                       :no-notify t))))
             (terminal-send conn addr "hi-from-client")
             ;; cat keeps running and never reports status, so a plain wait is
             ;; bounded by :timeout (a not-sent-by-us check-in, by design).
             (format t "    terminal-wait (2s) -> ~a~%"
                     (wait-result-reason
                      (terminal-wait conn :terminal addr :timeout 2)))
             (let ((r (terminal-read conn addr :lines 20)))
               (format t "    read text: ~a"
                       (string-trim "\r\n " (or (read-result-text r) ""))))
             (terminal-kill conn addr)
             (format t "    terminal-wait after kill -> ~a~%"
                     (wait-result-reason
                      (terminal-wait conn :terminal addr :timeout 10)))
             (terminal-rm conn addr))

           (format t "~%demo done.~%"))
      (disconnect conn)))
  (values))

(main)

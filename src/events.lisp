;;;; SPDX-FileCopyrightText: 2026 Greg Wuller
;;;; SPDX-License-Identifier: MIT

;;;; events.lisp --- subscriptions to daemon notifications
;;;;
;;;; IMPORTANT protocol fact (from hc schema, SubscribeResult.channel): in the
;;;; plain, unframed protocol the daemon uses, once you call events.subscribe
;;;; on a connection that connection now carries ONLY notifications -- it stops
;;;; answering requests. So SUBSCRIBE opens its OWN dedicated connection: the
;;;; request/response connection you normally use is never polluted, and the
;;;; event frames land in the dedicated connection's mailbox (a reader thread
;;;; already parks them there). Read them with NEXT-EVENT / DRAIN-EVENTS on
;;;; SUB-CONNECTION and end with CLOSE-EVENT-SUBSCRIPTION.

(in-package #:cl-herdr-client)

(defclass event-subscription ()
  ((connection :initarg :connection :reader sub-connection)
   (seq        :initarg :seq        :reader sub-seq)
   (active     :initform t          :accessor sub-active-p)))

(defun subscribe (&key path terminal (children-of nil) labels)
  "Open a dedicated connection and call events.subscribe on it. Returns an
EVENT-SUBSCRIPTION; its SUB-CONNECTION is the notifications-only connection.
The daemon has no unsubscribe method -- CLOSE-EVENT-SUBSCRIPTION (which drops
the connection) is how you end the subscription."
  (let ((conn (connect :path (or path (default-socket-path)))))
    (handler-case
        (let ((result (events-subscribe conn :terminal terminal
                                             :children-of children-of
                                             :labels labels)))
          (make-instance 'event-subscription
                         :connection conn
                         :seq (jval-safe result "seq")))
      (error (e)
        (ignore-errors (disconnect conn))
        (error e)))))

(defun close-event-subscription (sub)
  "End SUB by closing its dedicated connection."
  (setf (sub-active-p sub) nil)
  (disconnect (sub-connection sub))
  (values))

(defun pending-events-p (conn)
  "True if notifications are already waiting in CONN's mailbox."
  (bt:with-lock-held ((conn-mb-lock conn))
    (not (null (conn-mb-front conn)))))

(defun next-event (conn &key (timeout nil))
  "Block up to TIMEOUT seconds (NIL: forever) for the next notification on
CONN's mailbox. Returns its parsed jsown object, or NIL when TIMEOUT elapses
or CONN is closed and the mailbox is empty.
The empty-check and the wait share the mailbox lock, so a notification posted
in between cannot be lost. bordeaux-threads 0.9.4's CCL CONDITION-WAIT returns
T even on timeout, so an absolute deadline decides instead of that return value."
  (let ((deadline (and timeout
                       (+ (get-internal-real-time)
                          (round (* timeout internal-time-units-per-second))))))
    (bt:with-lock-held ((conn-mb-lock conn))
      (loop
        (let ((m (pop-notification conn)))
          (when m (return m)))
        (when (slot-value conn 'closed)
          (return nil))
        (let ((remaining (and deadline
                              (/ (- deadline (get-internal-real-time))
                                 internal-time-units-per-second))))
          (when (and remaining (<= remaining 0))
            (return nil))
          (bt:condition-wait (conn-mb-cond conn) (conn-mb-lock conn)
                             :timeout remaining))))))

(defun drain-events (conn)
  "Non-blocking: return a list of all notifications currently in the mailbox."
  (loop for m = (dequeue-notification conn)
        while m collect m))

(defun start-event-loop (on-event &key path terminal (children-of nil) labels)
  "Subscribe on a dedicated connection and run ON-EVENT (a function of one
argument, the event jsown object) for each notification, on a background
thread. Returns the EVENT-SUBSCRIPTION; CLOSE-EVENT-SUBSCRIPTION stops it."
  (let ((sub (subscribe :path path :terminal terminal
                             :children-of children-of
                             :labels labels)))
    (bt:make-thread
     (lambda ()
       (loop while (sub-active-p sub)
             do (let ((e (next-event (sub-connection sub) :timeout 30)))
                  (when e (funcall on-event e)))))
     :name "cl-herdr-client-event-loop")
    sub))

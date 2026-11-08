;;;; SPDX-FileCopyrightText: 2026 Greg Wuller
;;;; SPDX-License-Identifier: MIT

;;;; classes.lisp --- CLOS classes + converters for herdr-core schema results
;;;;
;;;; Generated from `hc schema` (OpenRPC, herdr-core 0.1.18). Each schema
;;;; type in components/schemas that is reachable from an RPC result becomes
;;;; a CLOS class (one slot per property) plus a converter function
;;;; `jval-><class>` that builds an instance from the jsown object the daemon
;;;; returns. The RPC wrappers in api.lisp run that converter on every result,
;;;; so callers get typed instances (and lists of them) instead of raw jsown
;;;; objects.
;;;;
;;;; Nested objects become instances of their own class, arrays of objects
;;;; become lists of instances, and free-form objects (`labels`, `records`)
;;;; become alists of (key . value), values converted according to the schema.

(in-package #:cl-herdr-client)

;;; ---------------------------------------------------------------------------
;;; Generator helpers (needed at macro-expansion time, so EVAL-WHEN all three)
;;; ---------------------------------------------------------------------------

(eval-when (:compile-toplevel :load-toplevel :execute)

  (defun hc-wire-key (slot)
    "The JSON key for slot name SLOT: '-' becomes '_' and the name is
  lower-cased (created-ms -> created_ms)."
    (string-downcase (substitute #\_ #\- (string slot))))

  (defun hc-initarg (slot)
    (intern (format nil ":~a" (string slot)) :keyword))

  (defun hc-intern-owned (name)
    "Return a symbol named NAME owned by the current package. When NAME is
  inherited from another package (e.g. the slot named version on class machine
  would otherwise resolve to CL:MACHINE-VERSION), shadow it so the accessor is
  our own symbol."
    (multiple-value-bind (sym status) (find-symbol name)
      (cond
        ((eq status :inherited)
         (shadow name)
         (intern name))
        (sym sym)
        (t (intern name)))))

  ;; RPC wrapper function names (see api.lisp). Accessors must never shadow a
  ;; wrapper: the schema's `terminal.rm` method and the `Terminal.rm` property
  ;; would both otherwise become TERMINAL-RM. Keep in sync with api.lisp.
  (defparameter *hc-protected-names*
    '("HELLO" "SERVER-STATUS" "SERVER-STOP" "SERVER-RESTART" "RPC-DISCOVER"
      "TEMPLATE-LIST"
      "TERMINAL-LIST" "TERMINAL-GET" "TERMINAL-RUN" "TERMINAL-KILL"
      "TERMINAL-RM" "TERMINAL-KEEP" "TERMINAL-LABEL" "TERMINAL-READ"
      "TERMINAL-SEND" "TERMINAL-WAIT" "TERMINAL-KEYS" "TERMINAL-INTERRUPT"
      "TERMINAL-PUT"
      "MACHINE-EXEC" "FILE-READ" "FILE-WRITE" "FILE-EDIT" "DOC-GET"
      "DOC-SET" "MACHINE-ADD" "MACHINE-LIST" "MACHINE-CONNECT"
      "MACHINE-RENAME" "MACHINE-RM" "EVENTS-SUBSCRIBE")
    "Wrapper function names (api.lisp) that slot accessors must not shadow.")

  (defun hc-accessor-name (hc-class slot)
    "The accessor symbol name (a string) for SLOT of HC-CLASS. Append a -P
  suffix when the plain name would collide with an RPC wrapper (see
  *HC-PROTECTED-NAMES*) or with a symbol the package cannot export because a
  `:use`d package owns it: e.g. the machine.version property would otherwise
  export MACHINE-VERSION, clashing with CL:MACHINE-VERSION, so it becomes
  MACHINE-VERSION-P."
    (let ((name (format nil "~A-~A" hc-class slot)))
      (cond
        ((member name *hc-protected-names* :test #'string=)
         ;; e.g. the Terminal.rm property gets TERMINAL-RM-P so the terminal.rm
         ;; RPC wrapper (TERMINAL-RM) keeps its name.
         (format nil "~A-P" name))
        ((multiple-value-bind (sym status) (find-symbol name :cl)
           (declare (ignore sym))
           (eq status :external))
         (format nil "~A-P" name))
        (t name))))

  (defun hc-accessor (hc-class slot)
    (hc-intern-owned (hc-accessor-name hc-class slot)))

  (defun hc-jval-name (class)
    "Converter function name for class CLASS: terminal -> JVAL->TERMINAL."
    (intern (format nil "JVAL->~a" class)))

  (defun hc-convert (code type)
    "Return code that converts the jsown value expressed by CODE into a CL
  value according to TYPE (see DEFINE-HC-SCHEMA). CODE is evaluated at most
  once."
    (cond
      ((member type '(:string :integer :number :boolean :any) :test #'eq)
       code)
      ((and (consp type) (eq (first type) :list))
       `(mapcar (lambda (v) ,(hc-convert 'v (second type)))
                (or ,code nil)))
      ((and (consp type) (eq (first type) :map))
       `(%jval-map ,code (lambda (v) ,(hc-convert 'v (second type)))))
      (t ; a ref to another schema: another jval->CLASS converter
       `(let ((v ,code))
          (and v (,(hc-jval-name type) v)))))))


(defmacro define-hc-schema (schema &body slot-specs)
  "Define a CLOS class for herdr-core schema type SCHEMA plus a converter
JVAL->SCHEMA that turns the jsown result object into an instance.

Each SLOT-SPEC is (slot-name type): slot-name is the Lisp property name (the
wire key is slot-name with '-' -> '_'), and type is one of
  :string :integer :number :boolean :any   primitive / opaque value
  schema-name                              a ref to another schema
  (:list TYPE)                             an array of TYPE
  (:map TYPE)                              an object of (key . value) pairs"
  (let* ((hc-class schema)
         ;; NB: let*, not let: ACCESSORS' initform must see HC-CLASS's binding.
         (accessors (mapcar (lambda (spec)
                              (hc-accessor hc-class (first spec)))
                            slot-specs)))
    `(progn
       (defclass ,hc-class ()
         ,(mapcar (lambda (spec)
                    (destructuring-bind (slot type) spec
                      (declare (ignore type))
                      `(,slot
                        :initarg ,(hc-initarg slot)
                        :accessor ,(hc-accessor hc-class slot)
                        :documentation ,(format nil "Schema property ~a (JSON key \"~a\")."
                                                (string-downcase (string slot))
                                                (hc-wire-key slot)))))
                  slot-specs)
         (:documentation ,(format nil "Result of a herdr-core RPC whose schema is ~a."
                                  (string-downcase (string schema)))))
       (defun ,(hc-jval-name hc-class) (obj)
         (make-instance ',hc-class
           ,@(mapcan (lambda (spec)
                       (destructuring-bind (slot type) spec
                         (list (hc-initarg slot)
                               (hc-convert `(jval-safe obj ,(hc-wire-key slot)) type))))
                     slot-specs)))
       ;; Make the class, its converter and all its slot accessors public.
       (export '(,hc-class ,(hc-jval-name hc-class) ,@accessors))
       ',hc-class)))

;;; ---------------------------------------------------------------------------
;;; Runtime helper
;;; ---------------------------------------------------------------------------

(defun %jval-map (o converter)
  "Convert a jsown object O (or NIL) into an alist of (key . value) pairs,
each value passed through CONVERTER."
  (when o
    (loop for (k . v) in (cdr o)
          collect (cons k (funcall converter v)))))

;;; ---------------------------------------------------------------------------
;;; Schema classes (from `hc schema`, herdr-core 0.1.18)
;;; ---------------------------------------------------------------------------

(define-hc-schema hello-result
  (core core-info)
  (features (:list :string))
  (framed :boolean)
  (generation :integer)
  (methods (:list :string))
  (version :string))

(define-hc-schema core-info
  (id :string)
  (name :string))

(define-hc-schema status-result
  (core core-info)
  (finished :integer)
  (holder holder-info)
  (holders (:list holder-info))
  (installed-by :string)
  (live :integer)
  (pid :integer)
  (uptime-ms :integer)
  (version :string))

(define-hc-schema holder-info
  (current :boolean)
  (instance :string)
  (pid :integer)
  (terminals :integer))

(define-hc-schema stop-result
  (stopped :boolean))

(define-hc-schema run-result
  (address :string)
  (argv (:list :string))
  (cols :integer)
  (created-ms :integer)
  (cwd :string)
  (die-with-parent :boolean)
  (exit-code :integer)
  (finished-ms :integer)
  (first-message first-message)
  (foreground foreground)
  (identity :string)
  (keep :boolean)
  (labels (:map :string))
  (name :string)
  (notify :boolean)
  (output :string)
  (parent :string)
  (paste-gap-ms :integer)
  (pid :integer)
  (reason :string)
  (records (:map status))
  (reported :boolean)
  (rm :boolean)
  (rows :integer)
  (screen :string)
  (signal :integer)
  (state :string)
  (status status)
  (status-ms :integer)
  (stop :string)
  (submit :string)
  (template :string)
  (title :string)
  (turn :integer)
  (wait wait-result))

(define-hc-schema first-message
  (reason :string)
  (sent :boolean)
  (started :boolean)
  (turn :integer))

(define-hc-schema foreground
  (argv (:list :string))
  (cwd :string)
  (name :string)
  (pid :integer))

(define-hc-schema status
  (app :string)
  (kind :string)
  (msg :string)
  (progress :integer)
  (state :string)
  (title :string))

(define-hc-schema wait-result
  (children (:list wait-result))
  (ended :boolean)
  (exit-code :integer)
  (from :string)
  (reason :string)
  (signal :integer)
  (status :string)
  (terminal :string)
  (turn :integer))

(define-hc-schema templates-result
  (templates (:list template-info)))

(define-hc-schema template-info
  (command :string)
  (description :string)
  (error :string)
  (name :string))

(define-hc-schema list-result
  (hidden-finished :integer)
  (machines (:list machine-view))
  (terminals (:list terminal)))

(define-hc-schema machine-view
  (host :string)
  (id :string)
  (name :string)
  (session :string)
  (since-ms :integer)
  (state :string)
  (target :string)
  (temporary :boolean)
  (version :string)
  (via :boolean)
  (why :string))

(define-hc-schema terminal
  (address :string)
  (argv (:list :string))
  (cols :integer)
  (created-ms :integer)
  (cwd :string)
  (die-with-parent :boolean)
  (exit-code :integer)
  (finished-ms :integer)
  (first-message first-message)
  (foreground foreground)
  (identity :string)
  (keep :boolean)
  (labels (:map :string))
  (name :string)
  (notify :boolean)
  (parent :string)
  (paste-gap-ms :integer)
  (pid :integer)
  (reason :string)
  (records (:map status))
  (reported :boolean)
  (rm :boolean)
  (rows :integer)
  (screen :string)
  (signal :integer)
  (state :string)
  (status status)
  (status-ms :integer)
  (stop :string)
  (submit :string)
  (template :string)
  (title :string)
  (turn :integer))

(define-hc-schema remove-result
  (removed :string))

(define-hc-schema read-result
  (complete :boolean)
  (how :string)
  (text :string)
  (why :string))

(define-hc-schema attach-result
  (automatic-input :boolean)
  (channel :integer)
  (resize-notifications :boolean)
  (terminal terminal))

(define-hc-schema send-result
  (started :boolean)
  (status :string)
  (turn :integer)
  (wait wait-result))

(define-hc-schema keys-result
  (status :string)
  (turn :integer))

(define-hc-schema interrupt-result
  (key :string)
  (outcome :string))

(define-hc-schema put-result
  (bytes :integer)
  (path :string))

(define-hc-schema exec-result
  (code :integer)
  (ms :integer)
  (signal :integer)
  (stderr :string)
  (stdout :string)
  (timed-out :boolean)
  (truncated :boolean))

(define-hc-schema file-read-result
  (first :integer)
  (last :integer)
  (lines :integer)
  (text :string))

(define-hc-schema file-result
  (bytes :integer)
  (path :string))

(define-hc-schema doc-get-result
  (value :any)
  (version :integer))

(define-hc-schema doc-set-result
  (version :integer))

(define-hc-schema subscribe-result
  (channel :integer)
  (seq :integer)
  (terminals (:list terminal)))

(define-hc-schema machine
  (host :string)
  (id :string)
  (name :string)
  (session :string)
  (target :string)
  (temporary :boolean)
  (version :string)
  (via :boolean))

(define-hc-schema machine-list-result
  (machines (:list machine-view)))

;;; ---------------------------------------------------------------------------
;;; rpc.discover returns the whole API as an OpenRPC document; its schema is an
;;; external reference (https://meta.open-rpc.org/), so we keep it as a raw
;;; jsown object instead of modelling the document.
;;; ---------------------------------------------------------------------------

(defclass rpc-discover-result ()
  ((document :initarg :document :accessor rpc-discover-result-document
             :documentation "The OpenRPC document returned by rpc.discover (a raw jsown object)."))
  (:documentation "Result of rpc.discover: the whole API as an OpenRPC document; an external schema, kept raw."))

(defun jval->rpc-discover-result (o)
  (make-instance 'rpc-discover-result :document o))

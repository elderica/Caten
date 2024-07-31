(in-package :caten/ajit)

(defstruct (Scheduled-Items
	    (:conc-name si-)
	    (:constructor make-scheduled-items (top)))
  "Top ... (top-node, top-buffer, top-id-in-nodes)"
  (nodes (list (first top)) :type list)
  (latest (second top) :type Buffer)
  (latest-id (third top) :type symbol)
  (name (intern (symbol-name (gensym "S")) "KEYWORD") :type keyword))

(defun si/append-item (scheduled-items node)
  (declare (type scheduled-items scheduled-items)
	   (type node node))
  ;; todo: optimize
  (push node (si-nodes scheduled-items)))

;; TODO Inline
(defun buffer-intersect-p (a b)
  "Returns T if two buffers a and b are mergeable."
  (declare (type Buffer a b))
  ;; either of buffers are scalar -> merge them
  (symbol-macrolet ((->ok (return-from buffer-intersect-p t))
		    (->ng (return-from buffer-intersect-p nil)))
    (when (or (= (buffer-nrank a) 0) (= 0 (buffer-nrank b)))->ok)
    ;; Contiguous buffer -> merge them
    (when (and (every #'null (buffer-views a)) (every #'null (buffer-views b)))->ok)
    ;; この下は一旦適当
    (when (every #'equal (buffer-shape a) (buffer-shape b))->ok)
    (when (every #'equal (buffer-views a) (buffer-views b))->ok)
    ->ng
    ))

(defun recursive-find-group (avm type-map scheduled-items)
  "Return -> (list scheduled-items ...)"
  (declare (type avm avm)
	   (type type-reporter type-map)
	   (type scheduled-items scheduled-items))
  (flet ((id->type (x) (map/type-of type-map x))
	 (explore (x) (when x (recursive-find-group avm type-map x))))
    (with-slots ((latest latest) (latest-id latest-id)) scheduled-items
      (when (find latest-id (rp-seen type-map))
	(return-from recursive-find-group))
      (let* ((node (id->value (avm-graph avm) latest-id))
	     (children (node-reads node))
	     (mergeable-list (map 'list #'(lambda (x) (or (numberp x) (buffer-intersect-p latest (id->type x)))) children)))
	(setf (rp-seen type-map) (append (rp-seen type-map) (node-writes node)))
	;; Top_ID <- F(Children[0], Children[1], ...)
	;;             mergeable[0] mergeable[1], ...
	(if (every #'identity mergeable-list)
	    (let ((parent-groups))
	      (dolist (c children)
		(when (not (numberp c))
		  (si/append-item scheduled-items (id->value (avm-graph avm) c))))
	      (dolist (c children)
		(when (not (numberp c))
		  (setf (si-latest scheduled-items) (id->type c)
			(si-latest-id scheduled-items) c)
		  (setf parent-groups (append parent-groups (cdr (explore scheduled-items))))))
	      (append (list scheduled-items) parent-groups))
	    (let ((new-groups
		    (map
		     'list
		     #'(lambda (x)
			 (when (not (numberp x))
			   (make-scheduled-items (list (id->value (avm-graph avm) x) (id->type x) x))))
		     children)))
	      (append
	       (list scheduled-items)
	       (loop for n in (map 'list #'explore new-groups) if n collect n))))))))

;; どっか移動する
(defun render-schedule (sched)
  (let* ((graph (apply #'make-graph (si-nodes sched)))
	 (avm (make-avm graph (si-name sched) (make-hash-table) nil nil)))
    ;;(caten::print-avm avm)
    ))
(defun print-schedules (list) (map 'list #'render-schedule list))

(defun create-schedule (avm)
  (declare (type avm avm))
  (let* ((type-map (run-type-infer avm))
	 (recursive-top-ids (append (avm-fw-outputs avm) (avm-bw-outputs avm))))
    ;;(caten::print-avm avm t)
    (flet ((id->buffer (id)
	     (assert (symbolp id) () "Graph should not return a number!")
	     (list (id->value (avm-graph avm) id) (map/type-of type-map id) id)))
      (let* ((schedules (map 'list (compose #'make-scheduled-items #'id->buffer) recursive-top-ids))
	     (scheduled (flatten (map 'list #'(lambda (x) (recursive-find-group avm type-map x)) schedules))))
	;; verify-graph assets no duplication in branches from recursive-top-ids
	;; ^ OK?
	(print-schedules (reverse scheduled))
	scheduled
	nil))))


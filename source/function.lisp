(in-package :caten)
;; Function creating a lazy computation node, should start with the prefix !.

(defclass Func () ((variables :initarg :variables :initform nil :accessor func-variables)))

(defgeneric lower (op &rest nodes)
  (:documentation "Lowers the Func into a list of `caten/air:node`. This should return caten/air:graph."))
(defgeneric forward (op &rest tensors)
  (:documentation "Create the type for the Tensor after computation. Be mindful of its lazy evaluation nature; do not perform the actual computation."))
(defgeneric backward (op prev-grad)
  (:documentation "Create the graph for backward of op given prev-grad. Return: `(values input_1.grad input_2.grad ...)`.
save-for-backward is determined automatically, so you do not have to consider about in-place operation."))

(defmethod forward :around ((op Func) &rest tensors)
  (let ((outs (handler-bind
		  ((error
		     #'(lambda (c) (error 'caten-forward-error :op op :inputs tensors :c c))))
		(multiple-value-list (call-next-method)))))
    (setf (func-variables op) tensors)
    (dolist (o outs)
      (assert (tensor-p o) ())
      (setf (tensor-variables o) tensors
	    (tensor-op o) op))
    (apply #'values outs)))
;; ~~ differentiable ops ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(defclass Allocate (Func)
  ((buffer :initarg :buffer :type Tensor :accessor alloc-buffer)
   (initial-element :initarg :initial-element :initform nil :accessor alloc-initial-element)))
(defmethod forward ((op Allocate) &rest tensors) (declare (ignore tensors)) (alloc-buffer op))
(defmethod backward ((op Allocate) dout)
  (let ((buff (alloc-buffer op)))
    (when (tensor-requires-grad buff)
      ;; op.grad += buff
      (values (!add (tensor-grad buff) dout :reduce t)))))
(defmethod lower ((op Allocate) &rest inputs)
  (declare (ignore inputs))
  (let ((buff (alloc-buffer op))
	(nodes))
    (flet ((->lower (obj) ;; If the shape includes a tensor, it also needs to be lowered
	     (if (or (numberp obj) (symbolp obj)) obj
		 (let ((g (%tensor->aasm obj)))
		   (and (push g nodes) (car (last (graph-nodes g))))))))
      (let ((g
	      (with-context
		(s (map 'list #'->lower (tensor-shape buff)))
		(a (%make-tensor s :dtype (tensor-dtype buff) :order (tensor-order buff) :id (tensor-id buff)))
		(a (when (alloc-initial-element op) (%load a (alloc-initial-element op)))))))
	(push g nodes)
	(apply #'make-graph (apply #'append (map 'list #'graph-nodes (reverse nodes))))))))

(defclass View (Func)
  ((views :initarg :views :type list :accessor view-views)
   (nrnak :initarg :nrank :accessor view-nrank)))
(defmethod backward ((op View) dout)
  (error "not implemented")
  ;; They are independent:
  ;; 1. reduction 2. slice/take 3. reshape 4. permute 5. broadcast
  ;; 5.と2.を同時に行わない仮定が必要
  )
(defmethod lower ((op View) &rest inputs)
  (let ((nrank (view-nrank op))
	(bs (car (func-variables op))))
    (flet ((subseq1p (x frm &optional to) (subseq x (1+ frm) (if to (1+ to)))))
      (with-context
	  (viewed (%view (car inputs)
			 (subseq1p inputs 0 nrank) (subseq1p inputs nrank (* 2 nrank))
			 (subseq1p inputs (* 2 nrank) (* 3 nrank)) (subseq1p inputs (* 3 nrank) (* 4 nrank))
			 (map 'list #'viewrange-broadcast (view-views op))
			 (let ((base-shape (subseq1p inputs (* 4 nrank) (* 5 nrank)))
			       (stride     (subseq1p inputs (* 5 nrank))))
			   (or stride (%stride base-shape (default-permute nrank (tensor-order bs)))))))))))
(defun !view (base &rest subscripts) (make-view-internal base subscripts))
;; !reshape
;; !permute
;; ~~ binary ops ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(defclass Add (Func) ((reduce :initarg :reduce :initform nil :accessor func-reduce)))
(defmethod forward ((op Add) &rest tensors) (st "A[~] B[~] -> A[~]" (tensors)))
(defmethod backward ((op Add) dout) (values dout dout))
(defmethod lower ((op Add) &rest inputs)
  (multiple-value-bind (a b) (apply #'values inputs)
    (with-context (out (%add a b :reduction (func-reduce op))))))

(defclass Mul (Func) ((reduce :initarg :reduce :initform nil :accessor func-reduce)))
(defmethod forward ((op Mul) &rest tensors) (st "A[~] B[~] -> A[~]" (tensors)))
(defmethod backward ((op Mul) dout)
  (multiple-value-bind (x y) (apply #'values (func-variables op))
    (values (!mul y dout) (!mul x dout))))
(defmethod lower ((op Mul) &rest inputs)
  (multiple-value-bind (a b) (apply #'values inputs)
    (with-context (out (%mul a b :reduction (func-reduce op))))))
;; Unary
(defclass Neg (Func) nil)
(defmethod forward ((op Neg) &rest tensors) (st "A[~] -> A[~]" (tensors)))
(defmethod backward ((op Neg) dout) (values (!neg dout)))
(defmethod lower ((op Neg) &rest inputs) (with-context (a (%neg (car inputs)))))

(defclass Recip (Func) nil)
(defmethod forward ((op Recip) &rest tensors) (st "A[~] -> A[~]" (tensors)))
(defmethod backward ((op Recip) dout)
  (let ((ret (!recip (car (func-variables op)))))
    (values (!mul (!mul (!neg dout) ret) ret)))) ;; -dout / x^2
(defmethod lower ((op Recip) &rest inputs) (with-context (a (%recip (car inputs)))))

(defclass Cast (Func)
  ((dtype-frm :initarg :dtype-frm :accessor cast-dtype-frm)
   (dtype-to :initarg :dtype-to   :accessor cast-dtype-to)))
(defmethod forward ((op Cast) &rest tensors) (st "A[~] B[~] -> A[~]" (tensors)))
(defmethod backward ((op Cast) prev-grad) (values prev-grad (!cast prev-grad (cast-dtype-frm op))))
(defmethod lower ((op Cast) &rest inputs) (with-context (a (%cast (first inputs) (second inputs) (cast-dtype-to op)))))
(defun !cast (x dtype &key (out (make-tensor (tensor-shape x) :dtype dtype :order (tensor-order x))))
  (declare (type tensor x out) (type dtype-t dtype))
  (forward (make-instance 'Cast :dtype-frm (tensor-dtype x) :dtype-to dtype) out x))
;; ~~ wrappers ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(declaim (ftype (function (Tensor Tensor &key (:reduce boolean)) (values Tensor &optional)) !add !sub !mul !div))
(defun !add (a b &key (reduce nil)) (forward (make-instance 'Add :reduce reduce) a b))
(defun !mul (a b &key (reduce nil)) (forward (make-instance 'Mul :reduce reduce) a b))
(defun !sub (a b &key (reduce nil)) (!add a (!neg b) :reduce reduce))
(defun !div (a b &key (reduce nil)) (!mul a (!recip b) :reduce reduce))
(macrolet ((def (name b) `(defun ,name (&rest args) (reduce ,b args))))
  (def !+ #'!add)
  (def !- #'!sub)
  (def !* #'!mul)
  (def !/ #'!div))
(macrolet ((def (name cls)
	     `(progn
		(declaim (ftype (function (Tensor) (values Tensor &optional)) ,name))
		(defun ,name (x) (declare (type Tensor x)) (forward (make-instance ',cls) x)))))
  (def !neg Neg)
  (def !recip Recip))
;;(declaim (ftype (function (Tensor) (values Tensor &optional)) !sign))
;;(defun !sign (x)
;;  (let ((zeros (!where (!eq x (make-scalar 0
;;  )

;; ~~ Compare Ops ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(macrolet ((def (name cls aop)
	     `(progn
		(defclass ,cls (Func) nil)
		(defmethod forward ((op ,cls) &rest tensors) (st "OUT[~] A[~] B[~] -> OUT[~]" (tensors)))
		(defmethod lower ((op ,cls) &rest inputs)
		  (with-context (out (,aop nil nil (nth 1 inputs) (nth 2 inputs) :out (nth 0 inputs)))))
		(defun ,name (x y &key (out (make-tensor (tensor-shape x) :dtype :bool :order (tensor-order x))))
		  (declare (type Tensor out))
		  (forward (make-instance ',cls) out x y)))))
  (def !<  LessThan     %<)
  (def !<= LessEqual    %<=)
  (def !>  GreaterThan  %>)
  (def !>= GreaterEqual %>=)
  (def !eq TensorEqual %=)
  (def !neq NotEqual %!=))
;; ~~ TernaryOps ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(defclass Where (Func) nil)
(defmethod forward ((op Where) &rest tensors)
  (assert (eql (tensor-dtype (nth 1 tensors)) (tensor-dtype (nth 2 tensors)))
	  ()
	  "Assertion Failed: A.dtype != B.dtype")
  (st "MAP[~] A[~] B[~] -> A[~]" (tensors)))
(defmethod backward ((op Where) prev-grad)
  (multiple-value-bind (c) (apply #'values (func-variables op))
    (values
     nil
     (!where c prev-grad (zeros-like prev-grad))
     (!where c (zeros-like prev-grad) prev-grad))))
(defmethod lower ((op Where) &rest inputs) (with-context (out (%where (nth 0 inputs) (nth 1 inputs) (nth 2 inputs)))))
(defun !where (condition x y)
  (declare (type Tensor condition x y))
  (forward (make-instance 'Where) condition x y))

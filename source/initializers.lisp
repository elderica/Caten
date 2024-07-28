(in-package :caten)

(defclass Linspace (Func) nil)
(defmethod forward ((op Linspace) &rest inputs) (st "A[] B[] X[~] -> X[~]" (inputs)))
(defmethod backward ((op Linspace) dout) (values nil nil nil))
(defmethod lower ((op Linspace) &rest inputs)
  (multiple-value-bind (a b x) (apply #'values inputs)
    (with-context
      (i (%index-components x))
      (t1 (%mul i a))
      (t2 (%add t1 b))
      (c  (%store x t2)))))
(defmethod ax+b (shape a b &key (dtype *default-float*) (order *default-order*) (requires-grad nil))
  "Initializes a tensor"
  (declare (type list shape))
  (flet ((->val (x) (->const x #'(lambda (x) (make-scalar x :dtype dtype :order order)))))
    (forward (make-instance 'Linspace)
	     (->val a) (->val b)
	     (make-tensor shape :dtype dtype :order order :requires-grad requires-grad))))
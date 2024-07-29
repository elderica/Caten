(in-package :caten)

(deftype axis-t () `(or number symbol Tensor))

(defstruct (ViewRange
	    (:constructor make-vrange (from to by broadcast size
				       &aux
					 (from (->iconst from))
					 (to (->iconst to))
					 (by (->iconst by))
					 (size (->iconst size)))))
  (from from :type Tensor) (to to :type Tensor)
  (by by :type Tensor) (broadcast broadcast :type boolean)
  (size size :type Tensor))

(defun vrange-size (vrange)
  (declare (type ViewRange vrange))
  (!div (!sub (viewrange-to vrange) (viewrange-from vrange)) (viewrange-by vrange)))

(defun parse-view-subscript (size subscript)
  (declare (type axis-t size))
  (flet ((normalize (x) (if (and (numberp x) (< x 0)) (!add (->iconst size) (iconst x)) x))
	 (1p (x) (if (tensor-p x) (!add x (iconst 1)) (!add (iconst x) (iconst 1)))))
    (ematch subscript
      ((list :~ n) (make-vrange 0 (normalize n) 1 t size))   ;; broadcasting (:~ N)
      ((eql t)  (make-vrange 0 size 1 nil size)) ;; nothing
      ((guard x (typep x 'axis-t)) (make-vrange (normalize x) (1p (normalize x)) 1 nil size)) ;; A[i]
      ((list (guard from (typep from 'axis-t)) (guard to (typep to 'axis-t)))
       (make-vrange (normalize from) (normalize to) 1 nil size)) ;; A[from:to]
      ((list (guard from (typep from 'axis-t)) (guard to (typep to 'axis-t)) (guard by (typep to 'axis-t)))
       (make-vrange (normalize from) (normalize to) by nil size))))) ;; A[from:to:by]

(defun .compose-views (old new)
  "
Applying a further slicing:
    (Range 2 10 2) ;; old
 +) (Range 0 4  2) ;; new
 ------------------
    (Range 2 6 2)
"
  (declare (type ViewRange old new))
  (with-slots ((frm1 from) (to1 to) (by1 by) (bc1 broadcast) (size size)) old
    (with-slots ((frm2 from) (to2 to) (by2 by) (bc2 broadcast)) new
      (let* ((offset (!where (!> by1 (iconst 0)) (!min frm1 to1) (!max frm1 to1)))
	     (from (!+ offset (!* (!signum by1) frm2)))
	     (to   (!+ offset (!* (!signum by1) to2)))
	     (step (!* (!signum (!* by1 by2)) (!lcm by1 by2))))
	(make-vrange from to step bc2 (if bc1 (iconst 1) size))))))

(defun merge-views (base subscripts)
  "Composes the two mergeable views"
  (declare (type Tensor base)
	   (type list subscripts))
  (let* ((parsed-subscripts (map 'list #'parse-view-subscript (tensor-shape base) subscripts)))
    (when (tensor-views base)
      (assert (= (length (tensor-views base)) (length subscripts)))
      ()
      "Cannot merge views with different ranks ~a and ~a" (tensor-views base) subscripts)
    (assert (= (ndim base) (length subscripts))
	    ()
	    "Nrank and subscript length should be the same. ~a vs ~a" (shape base) subscripts)
    (when (null (tensor-views base)) (return-from merge-views parsed-subscripts))
    (map 'list #'.compose-views (tensor-views base) parsed-subscripts)))

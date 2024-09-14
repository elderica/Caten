(in-package :caten/isl)

(define-isl-object multi-union-pw-aff
  :free %isl-multi-union-pw-aff-free
  :copy %isl-multi-union-pw-aff-copy
  :from-str t)

(defmethod print-object ((value set) stream)
  (print-unreadable-object (value stream :type t)
    (write-string (%isl-multi-union-pw-aff-to-str (set-handle value)) stream)))

(define-isl-function mupa-from-union-map %isl-multi-union-pw-aff-from-union-map
  (:give multi-union-pw-aff)
  (:take union-map))
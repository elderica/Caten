(in-package :caten/test-suite)

(deftest test-avg-pooling
  (with-given-dtype ((:float32 . "float32"))
    (with-no-grad
      (let ((input (rand `(10 3 25 25))))
        (assert-equal
            (:atol 1e-5 :rtol 1e-5)
            (with-torch (input)
              (->caten (f:avg_pool2d input `(2 2))))
            (proceed (!avgpool input :kernel-size `(2 2))))))))

(deftest test-max-pooling
  (with-given-dtype ((:float32 . "float32"))
    (with-no-grad
      (let ((input (rand `(10 3 25 25))))
        (assert-equal
            (:atol 1e-5 :rtol 1e-5)
            (with-torch (input)
              (->caten (f:max_pool2d input `(2 2))))
            (proceed (!maxpool input :kernel-size `(2 2))))))))
;; [TODO] Scheduling Test: Max/Avg Pooling should be a single kernel

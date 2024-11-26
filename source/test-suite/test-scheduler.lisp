(in-package :caten/test-suite)
;; Tests caten/codegen/scheduler.lisp
(defun schedule-with-vars (&rest tensors)
  (ctx:with-contextvar (:JIT 0)
    (let ((avm (apply #'caten tensors)))
      (caten/codegen/shape-inference:run-type-infer avm)
      (caten/codegen/rewriting-rules:apply-rewriting-rules avm)
      (values (graph-schedule (avm-graph avm)) avm))))

(defun gather-kernels (schedule-graph)
  (loop for node in (graph-nodes schedule-graph)
        if (getattr node :jitable)
          collect node))

(defun check-kernel (schedule-graph n-count &key (expect-failure nil))
  (if expect-failure
      (ng (= n-count (length (gather-kernels schedule-graph))) (format nil "[Expect Failure] Scheduled ~a, expected ~a" (length (gather-kernels schedule-graph)) n-count))
      (ok (= n-count (length (gather-kernels schedule-graph))) (format nil "Scheduled ~a, expected ~a" (length (gather-kernels schedule-graph)) n-count))))
;; ~~ Testing reduction ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(deftest test-double-reduction-separated
  (testing "Reduction with different axes are not fused into a single kernel"
    (let ((schedule (schedule-with-vars (!sum (!sum (make-tensor `(10 10)) :axis 0 :keepdims t) :axis 1 :keepdims t))))
      (check-kernel schedule 2)))
  (testing "Reduction with different axes are not fused into a single kernel"
    (let ((schedule (schedule-with-vars (!sum (!sum (make-tensor `(10 10)) :axis 0 :keepdims t) :axis 1 :keepdims t))))
      (check-kernel schedule 2))))

(deftest test-no-extra-loop-after-out-complex
  (multiple-value-bind (schedule avm)
      (schedule-with-vars (!matmul (make-tensor `(64 64)) (!gelu (!matmul (make-tensor `(64 64)) (make-tensor `(64 64))))))
    (check-kernel schedule 2)
    (caten/codegen/expr-cache:with-expr-cache ()
      (dolist (item (gather-kernels schedule))
        (let ((bp (caten/codegen/blueprint:lower-schedule-item item (avm-graph avm) schedule)))
          (ok (= 3 (count :FOR bp :key #'node-type)) (format nil "Expected 3 loops, got ~a" (count :FOR bp :key #'node-type))))))))

(deftest test-no-extra-loop-matmul-ln-matmul
  (multiple-value-bind (schedule avm)
      (schedule-with-vars (!matmul (make-tensor `(64 64)) (!layer-norm (!matmul (make-tensor `(64 64)) (make-tensor `(64 64))) `(64 64))))
    (check-kernel schedule 3)
    (caten/codegen/expr-cache:with-expr-cache ()
      (loop for item in (gather-kernels schedule)
            for count in `(4 3 3) do ;; LayerNorm -> Matmul -> Matmul
              (let ((bp (caten/codegen/blueprint:lower-schedule-item item (avm-graph avm) schedule)))
                (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type))))))))

(deftest test-serialize-reduction-loop
  (with-no-grad
    (testing "Serialized Reductions should belong to the same loop. (not creating a new inner loop!)"
      (testing "Add(Matmul, Matmul)"
        (multiple-value-bind (schedule avm)
            (schedule-with-vars (!add (!matmul (make-tensor `(64 64)) (make-tensor `(64 64)))
                                      (!matmul (make-tensor `(64 64)) (make-tensor `(64 64)))))
          (check-kernel schedule 1)
          (caten/codegen/expr-cache:with-expr-cache ()
            (loop for item in (gather-kernels schedule)
                  for count in `(3) do
                    (let ((bp (caten/codegen/blueprint:lower-schedule-item item (avm-graph avm) schedule)))
                      (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type))))))))
      (testing "Add(Embedding, Embedding)"
        (multiple-value-bind (schedule avm)
            (schedule-with-vars (!add (forward (Embedding 10 10) (make-tensor `(10 10))) (forward (Embedding 10 10) (make-tensor `(10 10)))))
          (check-kernel schedule 1)
          (caten/codegen/expr-cache:with-expr-cache ()
            (loop for item in (gather-kernels schedule)
                  for count in `(3) do
                    (let ((bp (caten/codegen/blueprint:lower-schedule-item item (avm-graph avm) schedule)))
                      (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))))))))))
;; ~~ Testing view merge ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(deftest test-chunk-schedule
  (multiple-value-bind (schedule avm)
      (schedule-with-vars (apply #'!matmul (multiple-value-list (!chunk (make-tensor `(2 64 64)) 2))))
    (check-kernel schedule 1)
    (caten/codegen/expr-cache:with-expr-cache ()
      (loop for item in (gather-kernels schedule)
            for count in `(4) do
              (let ((bp (caten/codegen/blueprint:lower-schedule-item item (avm-graph avm) schedule)))
                (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))
                (testing "Valid load is val_2 = val_1[(((4096*(1+_gid0))+_gid2)+64*_gid3)]"
                  (let ((loader (find-if #'(lambda (x) (and (eql (node-type x) :EXPR) (equalp (symbol-name (car (node-writes x))) "val_2"))) bp))
                        (wmma   (find-if #'(lambda (x)
                                             (and (eql (node-type x) :EXPR)
                                                  (getattr x :reduction :allow-undefined t)))
                                         bp))
                        (renderer 'caten/codegen/renderer:CStyle-Renderer)
                        (index-space (map 'list #'(lambda (x) (expr-const x :int64)) '(a b c d))))
                    (flet ((r (n)
                             (caten/codegen/renderer:render-expr renderer (getattr n :EXPR) :index-space index-space)))
                      (ok (equalp (r wmma) "(val_9+(val_1[(((4096*a)+(64*b))+d)]*val_2))") (format nil "WMMA Part is rendered as ~a" (r wmma)))
                      (ok (equalp (r loader) "val_1[(((4096*(1+a))+c)+(64*d))]") (format nil "Loader Part is rendered as ~a" (r loader)))
                      (let ((type (caten/codegen/shape-inference:read-type-relay loader)))
                        (ok (= (length (node-reads loader)) 1))
                        (ok (equal `(4096 0 1 64) (buffer-stride (car (caten/codegen/shape-inference:relay-reads type))))))))))))))

(deftest test-view-merge-failing-case
  (let ((schedule (schedule-with-vars (!gelu (!matmul (make-tensor `(1 64 64)) (!t (make-tensor `(1 64 64))))))))
    (check-kernel schedule 1)))
;; ~~ Test Matmul+Activation Fusion ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(deftest matmul-gelu-fuse-1
  (testing "Matmul(X, GeLU(X))"
    (multiple-value-bind (schedule avm) (schedule-with-vars (!matmul (make-tensor `(10 10)) (!gelu (!matmul (make-tensor `(10 10)) (make-tensor `(10 10))))))
      (check-kernel schedule 2)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(3 3) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (avm-graph avm) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))
                  (let* ((innermost-for
                           (position-if #'(lambda (x) (and (eql (node-type x) :FOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (innermost-endfor
                           (position-if #'(lambda (x) (and (eql (node-type x) :ENDFOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (_ (assert (and innermost-for innermost-endfor)))
                         (region (subseq bp (1+ innermost-for) innermost-endfor)))
                    (declare (ignore _))
                    ;; Activation should not be placed inside the innermost loop!
                    (let ((ng (some #'(lambda (x) (null (find (node-type x) '(:MOVE :LOAD :ADD :MUL :WMMA :AREF))))
                                    (apply #'append (map 'list #'(lambda (x) (graph-nodes (expr-graph (getattr x :EXPR)))) region)))))
                      (ng ng "The innnermost loop is consisted of only MOVE, LOAD, ADD, MUL, WMMA, AREF")))))))))

(deftest matmul-gelu-fuse-2
  (testing "Matmul(GeLU(X), X)"
    (multiple-value-bind (schedule avm) (schedule-with-vars (!matmul (!gelu (!matmul (make-tensor `(10 10)) (make-tensor `(10 10)))) (make-tensor `(10 10)) ))
      (check-kernel schedule 2)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(3 3) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (avm-graph avm) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))
                  (let* ((innermost-for
                           (position-if #'(lambda (x) (and (eql (node-type x) :FOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (innermost-endfor
                           (position-if #'(lambda (x) (and (eql (node-type x) :ENDFOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (_ (assert (and innermost-for innermost-endfor)))
                         (region (subseq bp (1+ innermost-for) innermost-endfor)))
                    (declare (ignore _))
                    ;; Activation should not be placed inside the innermost loop!
                    (let ((ng (some #'(lambda (x) (null (find (node-type x) '(:MOVE :LOAD :ADD :MUL :WMMA :AREF))))
                                    (apply #'append (map 'list #'(lambda (x) (graph-nodes (expr-graph (getattr x :EXPR)))) region)))))
                      (ng ng "The innnermost loop is consisted of only MOVE, LOAD, ADD, MUL, WMMA, AREF")))))))))

(deftest matmul-sin-fuse-1
  (testing "Matmul(X, sin(X))"
    (multiple-value-bind (schedule avm) (schedule-with-vars (!matmul (make-tensor `(10 10)) (!sin (!matmul (make-tensor `(10 10)) (make-tensor `(10 10))))))
      (check-kernel schedule 2)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(3 3) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (avm-graph avm) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))
                  (let* ((innermost-for
                           (position-if #'(lambda (x) (and (eql (node-type x) :FOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (innermost-endfor
                           (position-if #'(lambda (x) (and (eql (node-type x) :ENDFOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (_ (assert (and innermost-for innermost-endfor)))
                         (region (subseq bp (1+ innermost-for) innermost-endfor)))
                    (declare (ignore _))
                    ;; Activation should not be placed inside the innermost loop!
                    (let ((ng (some #'(lambda (x) (null (find (node-type x) '(:MOVE :LOAD :ADD :MUL :WMMA :AREF))))
                                    (apply #'append (map 'list #'(lambda (x) (graph-nodes (expr-graph (getattr x :EXPR)))) region)))))
                      (ng ng "The innnermost loop is consisted of only MOVE, LOAD, ADD, MUL, WMMA, AREF")))))))))

(deftest matmul-sin-fuse-2
  (testing "Matmul(sin(X), X)"
    (multiple-value-bind (schedule avm) (schedule-with-vars (!matmul (!sin (!matmul (make-tensor `(10 10)) (make-tensor `(10 10)))) (make-tensor `(10 10)) ))
      (check-kernel schedule 2)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(3 3) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (avm-graph avm) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))
                  (let* ((innermost-for
                           (position-if #'(lambda (x) (and (eql (node-type x) :FOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (innermost-endfor
                           (position-if #'(lambda (x) (and (eql (node-type x) :ENDFOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (_ (assert (and innermost-for innermost-endfor)))
                         (region (subseq bp (1+ innermost-for) innermost-endfor)))
                    (declare (ignore _))
                    ;; Activation should not be placed inside the innermost loop!
                    (let ((ng (some #'(lambda (x) (null (find (node-type x) '(:MOVE :LOAD :ADD :MUL :WMMA :AREF))))
                                    (apply #'append (map 'list #'(lambda (x) (graph-nodes (expr-graph (getattr x :EXPR)))) region)))))
                      (ng ng "The innnermost loop is consisted of only MOVE, LOAD, ADD, MUL, WMMA, AREF")))))))))
;;TODO:  ConvND batch_size=1
;; ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
;;
;; [Group1]
;;    |
;; [Group2]
;;    |
(defun schedule-from-graph (graph)
  (ctx:with-contextvar (:JIT 0)
    (let ((avm (make-avm graph :x nil (graph-outputs graph) nil))) 
      (caten/codegen/shape-inference:run-type-infer avm)
      (caten/codegen/rewriting-rules:apply-rewriting-rules avm)
      (values (graph-schedule (avm-graph avm)) avm))))
;; The most primitive way to write the fusion test
(deftest swizzle-permute-group-test ;; r1 = r2 in group-merge-p
  (let ((g (with-context
             (x  (%make-tensor `(10 10)))
             (x  (%view x `(10 10) `(0 0) `(10 10) `(1 1) `(nil nil) `(10 1))) ;; this view should be overwritten
             (y  (%make-tensor `(10 10)))
             (x  (%sin x)) ;; expect: x = sin(x[x+10*y])
             (x1 (%view x `(10 10) `(0 0) `(10 10) `(1 1) `(nil nil) `(1 10) :permute `(1 0))) ;; %sin should use this view
             (z  (%add x1 y :id 'out)))))
    (setf (graph-outputs g) (list 'out))
    (optimize-aasm g)
    ;;(->dot g)
    (multiple-value-bind (schedule avm) (schedule-from-graph g)
      (caten/codegen/expr-cache:with-expr-cache ()
        (check-kernel schedule 1)
        (let* ((kernel (car (gather-kernels schedule)))
               (bp (caten/codegen/blueprint:lower-schedule-item kernel (avm-graph avm) schedule)))
          (assert (= 1 (count :EXPR bp :key #'node-type)))
          ;; (caten/codegen/blueprint:print-blueprint bp t)
          (dolist (b bp)
            (when (eql (node-type b) :EXPR)
              (let ((val_1_type (second (caten/codegen/shape-inference:relay-reads (caten/codegen/shape-inference:read-type-relay b)))))
                (ok (equal `(1 10) (buffer-stride val_1_type)))))))))))


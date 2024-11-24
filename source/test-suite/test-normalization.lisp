(in-package :caten/test-suite)

(import-function "torch.var")
(import-function "torch.std")
(python-exec
 "
# Taken from https://pytorch.org/torchtune/0.2/_modules/torchtune/modules/rms_norm.html
def torch_rms_norm(x):
  # computation is in fp32
  x_fp32 = x.float()
  x_normed = (x_fp32 * torch.rsqrt(x_fp32.pow(2).mean(-1, keepdim=True) + 1e-5)).type_as(x)
  return x_normed
")
(import-function "torch_rms_norm")
;; [TODO] Fuse in a single kernel (var/std)
(deftest test-variance
  (with-given-dtype ((:float32 . "float32"))
    (let ((x (rand `(30 30))))
      (assert-equal
          (:atol 1e-5 :rtol 1e-6)
          (with-torch (x) (->caten (torch.var x :axis -1 :keepdims t :correction 1)))
          (proceed (!variance x :axis -1 :correction 1))))))

(deftest test-std
  (with-given-dtype ((:float32 . "float32"))
    (let ((x (rand `(30 30))))
      (assert-equal
          (:atol 1e-5 :rtol 1e-6)
          (with-torch (x) (->caten (torch.std x :axis -1 :keepdims t :correction 1)))
          (proceed (!std x :axis -1 :correction 1))))))
;; [TODO] BatchNorm (Fix the jit compiler issue first)
(deftest test-layer-norm
  (with-given-dtype ((:float32 . "float32"))
    (let ((x (rand `(30 40))))
      (assert-equal
          (:atol 1e-3 :rtol 1e-6)
          (with-torch (x) (->caten (f:layer_norm x `(40) :eps 1e-5)))
          (proceed (!layer-norm x `(40) :eps 1e-5))))))

(deftest test-rms-norm
  (with-given-dtype ((:float32 . "float32"))
    (let ((x (rand `(30 40))))
      (assert-equal
          (:atol 1e-3 :rtol 1e-6)
          (with-torch (x) (->caten (torch_rms_norm x)))
          (proceed (!rms-norm x `(40) :eps 1e-5))))))

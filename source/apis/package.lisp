(in-package :cl-user)
(defpackage :caten/apis
  (:nicknames :caten)
  (:documentation "Frontends for ASM/VM/JIT etc, including:
- AbstractTensor Frontend
- Shape Tracker
- Merge View Solver
- ASM Bindings
- Graph Caller")
  (:use :cl :alexandria :trivia :cl-ppcre :caten/aasm :caten/air :caten/avm)
  (:import-from
   :caten/common.dtype
   #:dtype-t
   #:dtype->lisp)
  ;; from tensor.lisp
  (:export
   #:make-tensor
   #:make-view-internal
   #:fconst #:uconst #:iconst
   
   #:Tensor
   #:tensor-p
   #:tensor-shape
   #:tensor-buffer
   #:tensor-dtype
   #:tensor-order
   #:tensor-id
   #:tensor-op
   #:tensor-views
   #:tensor-requires-grad
   #:tensor-grad
   #:tensor-variables
   #:grad
   #:shape
   #:ndim
   #:dtype-of
   #:order

   #:*external-simplifiers*
   #:proceed
   )
  ;; from conditions.lisp
  (:export
   #:caten-forward-error
   #:caten-backward-error)
  ;; from shape-tracker.lisp
  (:export #:st #:bc)

  ;; from module.lisp
  (:export
   #:Module
   #:impl
   #:defmodule
   #:module-outputs
   #:module-attrs
   #:module-sv4bws

   ;; reductions
   #:SumNode
   #:!sum
   #:MeanNode
   #:!mean
   #:!matmul
   
   )
  ;; from helpers.lisp
  (:export
   #:with-no-grad
   #:with-attrs
   #:print-avm)
  ;; from iseq.lisp
  (:export
   #:%compile-toplevel
   #:caten
   #:forward
   #:backward
   #:proceed)

  ;; from function.lisp
  (:export
   ;; shaping
   #:!view #:!view-from-base #:!reshape #:!repeat #:!contiguous #:!permute #:!t
   #:!uprank
   ;; Binary
   #:!add #:!+
   #:!sub #:!-
   #:!mul #:!*
   #:!div #:!/
   #:!move
   #:!max #:!min
   #:!gcd #:!lcm

   ;; Unary
   #:!neg #:!recip
   #:!cast #:!signum #:!abs
   #:!sin #:!cos #:!tan
   #:!exp #:!exp2
   #:!log #:!log2
   ;; Logical
   #:!< #:!> #:!<= #:!>= #:!eq #:!neq
   ;; TernaryOps
   #:!where
   )
  ;; from initializers.lisp
  (:export
   #:ax+b)
  )
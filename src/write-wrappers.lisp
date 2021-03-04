#|
 Copyright(c) 2021 - Lukas Herzberger <herzberger.lukas@gmail.com>
 SPDX-License-Identifier: MIT

 Copyright(c) 2015-2020 - NVIDIA CORPORATION
 SPDX-License-Identifier: Apache-2.0
|#

(in-package :vk-generator)

(defparameter *special-pointer-types*
  '("Display"
    "IDirectFB"
    "wl_display"
    "xcb_connection_t")
  "A sequence of pointer types which are never used as const-qualified call arguments, but are never used as return arguments.")

(defun split-len-by-struct-member (name)
  "Splits a given len NAME into two parts: the name of the referenced parameter and the slot name containing the length within the referenced parameter.
Returns NIL if the given NAME does not reference a slot of another parameter."
  (let ((name-parts (cl-ppcre:split "->" name)))
    (when (= (length name-parts) 1)
      ;; older version of the Vulkan API registry used the notation parameter::member instead of parameter->member
      (setf name-parts (cl-ppcre:split "::" name)))
    (when (and (= (length name-parts) 2))
      name-parts)))

(defun len-by-struct-member-p (name param vk-spec)
  "Checks if a given NAME references a MEMBER-DATA instance of a STRUCT instance and this STRUCT instances is the type of the given PARAM instance.
 
E.g.: In \"vkAllocateDescriptorSets\" the \"len\" \"pAllocateInfo->descriptorSetCount\" of parameter \"pDescriptorSets\" references the parameter \"pAllocateInfo\" of type \"VkDescriptorSetAllocateInfo\" which has a member named \"descriptorSetCount\".
"
  (let ((name-parts (cl-ppcre:split "->" name)))
    (when (= (length name-parts) 1)
      ;; older version of the Vulkan API registry used the notation parameter::member instead of parameter->member
      (setf name-parts (cl-ppcre:split "::" name)))
    (when (and (= (length name-parts) 2)
               (string= (first name-parts) (name param)))
      (let ((struct (gethash (type-name (type-info param)) (structures vk-spec))))
        (assert struct
                () "Undefined structure <~a>" (type-name (type-info param)))
        (assert (find-if (lambda (m)
                           (string= (second name-parts) (name m)))
                         (members struct))
                () "Structure <~a> has no member named <~a>" (name struct) (second name-parts))
        t))))

(defun structure-chain-anchor-p (struct-name vk-spec)
  "Determines if STRUCT-NAME names a struct type in the Vulkan API that is a structure chain anchor."
  (when (alexandria:starts-with-subseq "Vk" struct-name)
    (let ((struct (or (gethash struct-name (structures vk-spec))
                      (find-if (lambda (s)
                                 (find struct-name (aliases s) :test #'string=))
                               (alexandria:hash-table-values (structures vk-spec))))))
      (and struct
           (find (name struct) (extended-structs vk-spec) :test #'string=)))))

(defun determine-vector-param-indices (params vk-spec)
  "Creates a mapping of indices of array arguments to indices of the arguments specifying the number of elements within the array in a given sequence of PARAM instances.

E.g.: In \"vkQueueSubmit\" the parameter \"submitCount\" specifies the number of \"VkSubmitInfo\" instances in \"pSubmits\".
"
  (let ((vector-param-indices (make-hash-table :test 'equal)))
    (loop for param in params and param-index from 0
          for len = (len param)
          when len
          do (let ((len-param-index
                     (position-if
                      (lambda (p)
                        (or (string= len (name p))
                            (len-by-struct-member-p len p vk-spec)))
                      params)))
               (when len-param-index
                 (setf (gethash param-index vector-param-indices) len-param-index))))
    vector-param-indices))

(defun determine-non-const-pointer-param-indices (params)
  "Find all indices of PARAM instances describing output arguments in a given sequence of PARAM instances."
  (loop for param in params and param-index from 0
        when (and (non-const-pointer-p (type-info param))
                   (not (find (type-name (type-info param)) *special-pointer-types* :test #'string=)))
        collect param-index))

(defun determine-const-pointer-param-indices (params vk-spec)
  "Find all indices of PARAM instances describing input arguments in a given sequence of PARAM instances."
  (let ((non-const-pointer-param-indices (determine-non-const-pointer-param-indices params)))
    (loop for param-index from 0 to (1- (length params))
          unless (find param-index non-const-pointer-param-indices)
          collect param-index)))

(defun make-command-docstring (command required-params optional-params vk-spec)
  ;; todo: reference VkStructs, list arguments, document return type, if command starts with vkGet -> gets foo, if command is registered as a create-func or destroy-func -> Creates/Destroys a foo handle from bla belonging to a bar, document success codes, document error codes (= signalled conditions)
  (format nil "Represents <~a>"
          (name command)))

(defun reverse-hash-table (hash-table)
  (let ((result (make-hash-table)))
    (loop for k being each hash-key of hash-table using (hash-value v)
          do (push k (gethash v result)))
    result))


(defun format-required-args (required-args vk-spec)
  "Maps a list of PARAM-DATA instances into a list of argument names for the lambda list of a function in package VK."
  (loop for arg in required-args
        for i from 1
        collect (format nil "~(~a~)~@[ ~]"
                        (fix-slot-name (name arg) (type-name (type-info arg)) vk-spec)
                        (< i (length required-args)))))

(defun format-optional-args (optional-args vk-spec)
  "Maps a list of PARAM-DATA instances into a list of default argument lists for the lambda list of a function in package VK."
  (loop for arg in optional-args
        for i from 1
        collect (format nil "(~(~a ~a~))~@[ ~]"
                        (fix-slot-name (name arg) (type-name (type-info arg)) vk-spec)
                        (if (string= "pAllocator" (name arg))
                            "*default-allocator*"
                            (when (gethash (type-name (type-info arg)) (handles vk-spec))
                              "(cffi:null-pointer)"))
                        (< i (length optional-args)))))

(defun format-type-name (type-name vk-spec)
  (cond
    ((gethash type-name (structures vk-spec))
     (format nil "'(:~a %vk:~(~a~))"
             (if (is-union-p (gethash type-name (structures vk-spec)))
                 "union"
                 "struct")
             (fix-type-name type-name (tags vk-spec))))
    ((gethash type-name (handles vk-spec))
     (format nil "'%vk:~(~a~)" (fix-type-name type-name (tags vk-spec))))
    ((gethash type-name (enums vk-spec))
     (format nil "'%vk:~(~a~)" (fix-type-name type-name (tags vk-spec))))
    ((string= "void" type-name)
     "'(:pointer void)")
    ((string= "char" type-name)
     ":string")
    ((string= "size_t" type-name)
     "%vk:size-t")
    ((gethash type-name *vk-platform*)
     (format nil "~(~s~)" (gethash type-name *vk-platform*)))
    ((getf *misc-os-types* type-name)
     (format nil "~:[~;'~]~(~s~)"
             (consp (getf *misc-os-types* type-name))
             (gethash *misc-os-types* type-name)))
    ((and (gethash type-name (types vk-spec))
          (eq :requires (category (gethash type-name (types vk-spec)))))
     "'(:pointer void)")
    (t
     (format nil "'%vk:~(~a~)" (fix-type-name type-name (tags vk-spec))))))

(defun format-arg-type (arg vk-spec)
  ""
  (format-type-name (type-name (type-info arg)) vk-spec))

(defun format-len-provider (count-arg array-arg vk-spec)
  (if (gethash (type-name (type-info count-arg)) (structures vk-spec))
      (let* ((split-len-data (split-len-by-struct-member (len array-arg)))
             (count-slot ()))
        (format nil "(vk:~(~a ~a~))"
                "foo"
                "bar"))
      (format nil "(length ~(~a~))"
              (fix-slot-name (name array-arg) (type-name (type-info array-arg)) vk-spec))))

(defun make-arg-qualifier-list (arg output-params optional-params vk-spec)
  (let ((qualifiers nil))
    (when (find arg optional-params)
      (push :optional qualifiers))
    (when (or (gethash (type-name (type-info arg)) (handles vk-spec))
              (string= "void" (type-name (type-info arg)))
              (and (gethash (type-name (type-info arg)) (types vk-spec))
                   (eq :requires (category (gethash (type-name (type-info arg)) (types vk-spec))))))
      (push :handle qualifiers))
    (push (if (find arg output-params)
              :out
              :in)
          qualifiers)
    qualifiers))

(defun format-vk-args (vk-args count-to-vector-param-indices output-params optional-params vk-spec)
  ""
  (loop for arg in vk-args
        for i from 0
        collect (format nil "(~(~a ~a ~a~{ ~s~}~))~@[~%~]"
                        (fix-slot-name (name arg) (type-name (type-info arg)) vk-spec)
                        (format-arg-type arg vk-spec)
                        (if (and (gethash i count-to-vector-param-indices)
                                 (not (gethash (type-name (type-info arg))
                                               (structures vk-spec))))
                            ;; todo: first is most definitely not always correct here
                            (let ((array-arg (nth (first (gethash i count-to-vector-param-indices)) vk-args)))
                              (format nil "(length ~(~a~))"
                                      (fix-slot-name (name array-arg) (type-name (type-info array-arg)) vk-spec)))
                            (fix-slot-name (name arg) (type-name (type-info arg)) vk-spec))
                        (make-arg-qualifier-list arg output-params optional-params vk-spec)
                        (< (+ i 1) (length vk-args)))))

(defun write-simple-fun (out command fixed-function-name required-params optional-params output-params count-to-vector-param-indices vk-spec)
  (format out "(defvk-simple-fun (~(~a~)~%" fixed-function-name)
  (format out "                   ~(%vk:~a~)~%" fixed-function-name)
  (format out "                   ~s~%" (make-command-docstring command required-params optional-params vk-spec))
  (format out "                   (~(~{~a~}~))~%" (format-required-args required-params vk-spec))
  (format out "                   (~(~{~a~}~))" (format-optional-args optional-params vk-spec))
  (if (not (find (return-type command) '("void" "VkBool32" "VkResult") :test #'string=))
      (format out "~%                  ~(~a~))~%"
              (format-type-name (return-type command) vk-spec))
      (format out ")~%"))
  (format out "~{  ~(~a~)~})~%~%" (format-vk-args (params command) count-to-vector-param-indices output-params optional-params vk-spec)))

(defun write-command (out command vk-spec)
  (let* ((fixed-function-name (fix-function-name (name command) (tags vk-spec)))
         ;; maps from array-param to array-count-param
         (vector-param-indices (determine-vector-param-indices (params command) vk-spec))
         (count-to-vector-param-indices (reverse-hash-table vector-param-indices))
         (vector-params (loop for i in (alexandria:hash-table-keys vector-param-indices)
                              collect (nth i (params command))))
         (vector-count-params (loop for i in (alexandria:hash-table-values vector-param-indices)
                                    collect (nth i (params command))))
         (non-const-pointer-param-indices (determine-non-const-pointer-param-indices (params command)))
         (output-params (loop for i in non-const-pointer-param-indices
                              collect (nth i (params command))))
         (has-return-p (not (string= (return-type command) "void")))
         (handle-params (remove-if-not (lambda (p)
                                         (and (not (find p output-params))
                                              (gethash (type-name (type-info p)) (handles vk-spec))))
                                       (params command)))
         (non-struct-params (sorted-elements
                             (remove-if (lambda (p)
                                          (or (gethash (type-name (type-info p)) (structures vk-spec))
                                              (gethash (type-name (type-info p)) (handles vk-spec))
                                              (find p vector-count-params)
                                              (find p output-params)))
                                        (params command))))
         (struct-params (sorted-elements
                         (remove-if-not (lambda (p)
                                          (and (gethash (type-name (type-info p)) (structures vk-spec))
                                               (not (find p output-params))))
                                        (params command))))
         (required-handle-params (remove-if (lambda (p)
                                              (optional-p p))
                                            handle-params))
         (required-non-struct-params (remove-if (lambda (p)
                                                  (optional-p p))
                                                non-struct-params))
         (required-struct-params (remove-if (lambda (p)
                                              (optional-p p))
                                            struct-params))
         (optional-handle-params (remove-if-not (lambda (p)
                                                  (optional-p p))
                                                handle-params))
         (optional-non-struct-params (remove-if-not (lambda (p)
                                                      (optional-p p))
                                                    non-struct-params))
         (optional-struct-params (remove-if-not (lambda (p)
                                                  (optional-p p))
                                                struct-params))
         (required-params (concatenate 'list required-handle-params required-non-struct-params required-struct-params))
         (optional-params (concatenate 'list optional-handle-params optional-non-struct-params optional-struct-params))
         ;; collect redundant input parameters (i.e. if they specify the length of another input (!) parameter)
         (skipped-input-params (remove-if-not (lambda (p)
                                                (and (find p vector-count-params)
                                                     (not (intersection (gethash (position p (params command)) count-to-vector-param-indices)
                                                                        non-const-pointer-param-indices))))
                                              (concatenate 'list required-params optional-params)))
         (accumulated-indent "")
         (closing-parens 1))

    (when nil
      (format t "~%handle: ~{~a, ~}~%"
             (loop for p in handle-params 
                   collect (name p)))
     (format t "~%non-struct: ~{~a, ~}~%"
             (loop for p in non-struct-params
                   collect (name p)))
     (format t "~%struct: ~{~a, ~}~%"
             (loop for p in struct-params
                   collect (name p)))
     (format t "~%output: ~{~a, ~}~%"
             (loop for p in output-params
                   collect (name p))))

    #|
    ;; base defun
    (format out
            (create-base-defun command
                               fixed-function-name
                               required-params
                               optional-params
                               skipped-input-params
                               vk-spec))
    (setf accumulated-indent (concatenate 'string "  " accumulated-indent))
 
    ;; if the function has a return value (this will be VkResult or VkBool32) prepare a variable to store it
    (when (and has-return-p
               output-params)
      (incf closing-parens)
      (format out "~a(let ((~a nil))~%"
              accumulated-indent
              *result-var-name*)
      (setf accumulated-indent (concatenate 'string "  " accumulated-indent)))

    ;; if the function has primitive input args they need to be allocated
    (when non-struct-params
      (incf closing-parens)
      (format out "~a(cffi:with-foreign-objects (~(~{~a~}~))~%"
              accumulated-indent
              (loop for p in non-struct-params
                    for i from 0
                    collect (format nil "~@[~%~a~](~(p-~a ~a~@[ :count ~a~]~))"
                                    (unless (= i 0)
                                      (format nil "~a                            "
                                              accumulated-indent))
                                    (fix-slot-name (name p) (type-name (type-info p)) vk-spec)
                                    (if (string= (type-name (type-info p)) "char")
                                        ":string"
                                        (format nil "~(~s~)"
                                                (gethash (type-name (type-info p)) *vk-platform*)))
                                    (if (find p vector-params)
                                        (format nil "~(~a~)"
                                                (let ((count-param (nth (position p (params command)) (params command))))
                                                  (fix-slot-name (name count-param) (type-name (type-info count-param)) vk-spec)))
                                        nil))))
      (setf accumulated-indent (concatenate 'string "  " accumulated-indent))

      ;; map input params to allocated memory
      (when required-non-struct-params
        (format out "~(~{~a~%~}~)"
                (loop for p in required-non-struct-params
                      collect (format nil "~a~a"
                                      accumulated-indent
                                      (create-setting-primitive-allocated-param p
                                                                                command
                                                                                vector-params
                                                                                vector-count-params
                                                                                output-params
                                                                                vk-spec)))))

      ;; map optional input params to allocated memory (for the actual function call ~a-supplied-p must be checked again!)
      (when optional-non-struct-params
        (format out "~(~{~a~%~}~)"
                (loop for p in optional-non-struct-params
                      collect (format nil "~a(when ~a-supplied-p ~a)"
                                      accumulated-indent
                                      (fix-slot-name (name p) (type-name (type-info p)) vk-spec)
                                      (create-setting-primitive-allocated-param p
                                                                                command
                                                                                vector-params
                                                                                vector-count-params
                                                                                output-params
                                                                                vk-spec))))))

    ;; allocate and fill struct params
    (when struct-params
      (incf closing-parens)
      (format out (create-with-foreign-allocated-bloc struct-params accumulated-indent vk-spec))
      (setf accumulated-indent (concatenate 'string "  " accumulated-indent)))

|#
 ;; insert stuff from APPEND-COMMAND here
    ;; todo:
    (cond
      ((not output-params)
       (write-simple-fun out command fixed-function-name required-params optional-params output-params count-to-vector-param-indices vk-spec)
       #|
       ;; VkBool32 and VkResult are automatically translated, void just returns nil
       (if (find (return-type command) '("void" "VkBool32" "VkResult") :test #'string=)
           (format out "~a~a"
                   accumulated-indent
                   (create-call command output-params nil vk-spec nil))
           (progn  ;; not sure if there are functions like this
             (format out "~a(cffi:mem-aref ~a ~(~a~))"
                     accumulated-indent
                     (create-call command output-params nil vk-spec nil)
                     (if (gethash (return-type command) *vk-platform*)
                         (format nil "~s" (gethash (return-type command) *vk-platform*))
                         (format nil "'%vk:~a"(fix-type-name (return-type command) (tags vk-spec)))))))
       |#
       )
      ((= (length non-const-pointer-param-indices) 1)
       (let ((ret (first output-params)))
         ;; eight cases
         (if (gethash (type-name (type-info ret)) (handles vk-spec))
             ;; 1) handle type
             (if (not (find ret vector-params))
                 (progn
                   #|
                   (incf closing-parens)
                   (format out "~a(cffi:with-foreign-object (p-~(~a %vk:~a~))~%"
                           accumulated-indent
                           (fix-slot-name (name ret) (type-name (type-info ret)) vk-spec)
                           (fix-type-name (type-name (type-info ret)) (tags vk-spec)))
                   (setf accumulated-indent (concatenate 'string "  " accumulated-indent))
                   (format out "~a~a~%"
                           accumulated-indent
                           (create-call command output-params nil vk-spec (string= (return-type command) "VkResult")))
                   (if (string= (return-type command) "VkResult")
                       ;; 1a-1) single handle - e.g. vkCreateInstance
                       (format out "~a~a"
                               accumulated-indent
                               (create-return-form
                                (list (format nil "(cffi:mem-aref ~(p-~a '%vk:~a~))"
                                              (fix-slot-name (name ret) (type-name (type-info ret)) vk-spec)
                                              (fix-type-name (type-name (type-info ret)) (tags vk-spec))))))
                       ;; 1a-2) single handle but it is not created but "vkGet"-prefixed instead - e.g. vkGetDeviceQueue
                       (format out "~a(cffi:mem-aref ~(p-~a '%vk:~a~))"
                               accumulated-indent
                               (fix-slot-name (name ret) (type-name (type-info ret)) vk-spec)
                                              (fix-type-name (type-name (type-info ret)) (tags vk-spec))))|#)
                 (if (= (length vector-params) 2)
                     ;; 1b-1) vector of handles, where the output vector uses the same len as an input vector - e.g. vkCreateGraphicsPipelines
                     (progn
                       #|
                       (incf closing-parens)
                       (format out "~a(cffi:with-foreign-object (p-~(~a '%vk:~a (length ~a~))))~%"
                               accumulated-indent
                               (fix-slot-name (name ret) (type-name (type-info ret)) vk-spec)
                               (fix-type-name (type-name (type-info ret)) (tags vk-spec))
                               (let ((other-vec-param (find-if-not (lambda (p)
                                                                     (string= (name p) (name ret)))
                                                                   vector-params)))
                                 (fix-slot-name (name other-vec-param) (type-name (type-info other-vec-param)) vk-spec)))
                       (setf accumulated-indent (concatenate 'string "  " accumulated-indent))
                       (format out "~a~a~%"
                               accumulated-indent
                               (create-call command output-params nil vk-spec))
                       (format out "~a~a"
                               accumulated-indent
                               (create-return-form
                                (list
                                 (format nil "(loop for i from 0 below (length ~(~a~)) collect (cffi:mem-aref ~(p-~a '%vk:~a i~)))"
                                         (let ((other-vec-param (find-if-not (lambda (p)
                                                                               (string= (name p) (name ret)))
                                                                             vector-params)))
                                           (fix-slot-name (name other-vec-param) (type-name (type-info other-vec-param)) vk-spec))
                                         (fix-slot-name (name ret) (type-name (type-info ret)) vk-spec)
                                         (fix-type-name (type-name (type-info ret)) (tags vk-spec))))))|#)
                     ;; 1b-2) vector of handles using len-by-struct-member - e.g. vkAllocateCommandBuffers
                     (let* ((split-len-data (split-len-by-struct-member (len ret)))
                            ;; len-param
                            ;; fixed-len-param-name
                            ;; fixed-len-param-slot-name
                            )
                       #|
                       (incf closing-parens)
                       (format out "~a(cffi:with-foreign-object (p-~(~a '%vk~a (vk:~a ~a)~))~%"
                               accumulated-indent
                               (fix-slot-name (name ret) (type-name (type-info ret)) vk-spec)
                               (fix-type-name (type-name (type-info ret)) (tags vk-spec))
                               "ACCESSOR-OF-LEN"
                               "FIXED-SLOT-OF-LEN")
                       (setf accumulated-indent (concatenate 'string "  " accumulated-indent))
                       (format out "~a~a~%"
                               accumulated-indent
                               (create-call command output-params nil vk-spec))
                       (format out "~a~a"
                               accumulated-indent
                               (create-return-form
                                (list
                                 (format nil "(loop for i from 0 below (vk:~(~a ~a~)) collect (cffi:mem-aref ~(p-~a '%vk:~a i~)))"
                                         "ACCESSOR-OF-LEN"
                                         "FIXED-SLOT-OF-LEN"
                                         (fix-slot-name (name ret) (type-name (type-info ret)) vk-spec)
                                         (fix-type-name (type-name (type-info ret)) (tags vk-spec))))))|#)))
             ;; 2) structure chain anchor (wat?)
             (if (structure-chain-anchor-p (type-name (type-info (nth (first non-const-pointer-param-indices) (params command))))
                                           vk-spec)
                 ;; 2a)   appendCommandChained
                 (format t "1c-1: command: ~a param: ~a ~%" ;; vkGetPhysicalDeviceFeatures2 pFeatures
                         command
                         (nth (first non-const-pointer-param-indices) (params command)))
                 (if (not (gethash (first non-const-pointer-param-indices) vector-param-indices))
                     ;; 2b-1) returns VkBool32 || VkResult || void -> appendCommandStandardAndEnhanced
                     (format t "1c-2: command: ~a~%" command)
                     ;; 2b-2) appendCommandSingular
                     (format t "1d: command: ~a~%" command))))))
      ((= (length non-const-pointer-param-indices) 2)
       ;; four cases
       ;; 1) structure chain anchor (wat?) -> appendCommandVectorChained
       (if (structure-chain-anchor-p (type-name (type-info (nth (second non-const-pointer-param-indices) (params command))))
                                     vk-spec)
           (format t "2a: command: ~a ~%" command)
           (cond
             ;; 2) 0 vector-param-indices -> two returns and a non-trivial success code
             ((= (hash-table-count vector-param-indices) 0)
              (format t "!!!!!!!!!!!!!!!2b: command: ~a ~%" command))
             ;; 3) 1 vector-param-indices -> the size is a return value as well -> enumerate the values
             ((= (hash-table-count vector-param-indices) 1)
              (format t "2c: command: ~a length vector-params: ~a~%" command (length vector-params)))
             ;; 4) 2 vector-param-indices -> two returns and two vectors! But one input vector, one output vector of the same size, and one output value
             ((= (hash-table-count vector-param-indices) 2)
              (format t "2d: command: ~a ~%" command)))))
      ((= (length non-const-pointer-param-indices) 3)
       ;; 1 case
       ;; 1) the two vectors use the very same size parameter
       (format t "!!!!!!!!!!!!!!!!!!3: ~a~%" command)
       )
      (t (error "Never encountered a function like <~a>!" (name command))))

    (if (> (hash-table-count vector-param-indices) 0)
        nil nil
        ;;(format t "command ~a has vector params: ~a with indices: ~a~%" (name command) vector-params vector-param-indices)
        )

    #|
    ;; close all forms
    (format out "~{~a~}~%~%"
            (loop for i from 0 below closing-parens
                  collect ")"))|#))

(defun write-vk-functions (vk-functions-file vk-spec)
  (with-open-file (out vk-functions-file :direction :output :if-exists :supersede)
    (format out ";;; this file is automatically generated, do not edit~%")
    (format out "#||~%~a~%||#~%~%" (vulkan-license-header vk-spec))
    (format out "(in-package :vk)~%~%")

    
    (loop for command in (sorted-elements (alexandria:hash-table-values (commands vk-spec)))
          do (write-command out command vk-spec)
          ;; todo: as soon as %vk also contains aliases
          ;; when (alias command)
          ;; do (loop for alias in (alexandria:hash-table-values (alias command))
          ;;          do (write-command out (make-aliased-command command alias) vk-spec))
          )))

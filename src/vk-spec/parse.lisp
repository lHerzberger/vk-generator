
(in-package :vk-generator/vk-spec)

(defun begins-with-p (str substr)
  (declare (type string str))
  (declare (type string substr))
  "Checks whether or not the given string STR begins with the string SUBSTR."
  (string= (subseq str 0 (length substr)) substr))

(defun parse-boolean (node)
  "Checks whether or not the given node NODE holds a string that equals 'true'."
  (let ((str (xps node)))
    (and str (string= str "true"))))

(defun parse-modifiers (node)
  (let ((array-sizes nil)
        (bit-count nil))
    (unless (xpath:node-set-empty-p node)
      (let ((value (xps (xpath:evaluate "text()" node))))
        (when (and value
                   (> (length value) 0))
          (cond
            ((string= (first value) "[")
             (let ((end-pos 0))
               (loop while (not (= (+ end-pos) (length value)))
                     do (let ((start-pos (position #\[ :start end-pos)))
                          (assert start-pos
                                  () "could not find '[' in <~a>" value)
                          (setf end-pos (position #\] :start start-pos))
                          (assert end-pos
                                  () "could not find ']' in <~a>" value)
                          (assert (<= (+ start-pos 2) end-pos)
                                  () "missing content between '[' and ']' in <~a>" value)
                          (push (subseq value (1+ start-pos) (- end-pos start-pos 1))
                                array-sizes)))))
            ((string= (first value) ":")
             (setf bit-count (cdr value))
             )
            (t
             (assert (or (string= (first value) ";")
                         (string= (first value) ")"))
                     () "unknown modifier <~a>" value))))))
    (values array-sizes bit-count)))

(defun parse-name-data (node)
  "TODO"
  ;; todo: check attributes
  (let ((name (xps (xpath:evaluate "name" node))))
    (multiple-value-bind (array-sizes bit-count)
        (parse-modifiers (xpath:evaluate "name/following-sibling" node))
      (make-instance 'name-data
                     :name name
                     :array-sizes array-sizes
                     :bit-count bit-count))))

(defun parse-type-info (node)
  "TODO"
  ;; todo: check attributes
  (let ((type-name (xps (xpath:evaluate "type" node)))
        (prefix (xps (xpath:evaluate "type/preceding-sibling::text()" node)))
        (postfix (xps (xpath:evaluate "type/following-sibling::text()" node))))
    (make-instance 'type-info
                   :type-name (or type-name "")
                   :prefix prefix
                   :postfix postfix)))

(defun parse-basetype (node vk-spec)
  "TODO"
  ;; todo: check attributes
  (let* ((attributes (attrib-names node))
         (name-data (parse-name-data node))
         (type-info (parse-type-info node)))
    (assert (not (array-sizes name-data))
            () "name <~a> with unsupported array-sizes" (name name-data))
    (assert (not (bit-count name-data))
            () "name <~a> with unsupported bit-count <~a>" (name name-data) (bit-count name-data))
    (assert (or (= (length (type-name type-info)) 0)
                (string= (prefix type-info) "typedef"))
            () "unexpected type prefix <~a>" (prefix type))
    (assert (or (= (length (prefix type-info)) 0)
                (string= (prefix type-info) "typedef"))
            () "unexpected type prefix <~a>" (prefix type))
    (assert (= (length (postfix type-info)) 0)
            () "unexpected type postfix <~a>" (postfix type))
    (when (> (length (type-name type-info)) 0)
      (assert (not (gethash (name name-data) (base-types vk-spec)))
              () "basetype <~a> already specified" (name name-data))
      (setf (gethash (name name-data) (base-types vk-spec))
            (make-instance 'base-type
                           :name (name name-data)
                           :type-name (type-name type-info))))
    (assert (not (gethash (name name-data) (types vk-spec)))
            () "basetype <~a> already specified as a type" (name name-data))
    (setf (gethash (name name-data) (types vk-spec)) :basetype)))

(defun parse-bitmask (node vk-spec)
  "TODO"
  (let ((alias (xps (xpath:evaluate "@alias" node))))
    (if alias
        (let* ((alias (xps (xpath:evaluate "@alias" node)))
               (name (xps (xpath:evaluate "@name" node)))
               (bitmask (gethash alias (bitmasks vk-spec))))
          (assert bitmask
                  () "missing alias <~a>" alias)
          (assert (= (length (alias bitmask)))
                  () "alias for bitmask <~a> already specified as <~a>" (name bitmask) (alias bitmask))
          (setf (alias bitmask) name)
          (assert (not (gethash name (types vk-spec)))
                  () "aliased bitmask <~a> already specified as a type" name)
          (setf (gethash name (types vk-spec)) :bitmask))
        (let ((name-data (parse-name-data node))
              (type-info (parse-type-info node))
              (requires (xps (xpath:evaluate "@requires" node))))
          (assert (begins-with-p (name name-data) "Vk")
                  () "name <~a> does not begin with <VK>" (name name-data))
          (assert (= (length (array-sizes name-data)) 0)
                  () "name <~a> with unsupported array-sizes" (array-sizes name-data))
          (when (find (type-name type-info) '("VkFlags" "VkFlags64"))
            (warn "unexpected bitmask type <~a>" (type-name type-info)))
          (assert (string= (prefix type-info) "typedef")
                  () "unexpected type prefix <~a>" (prefix type-info))
          (assert (= (length (postfix type-info)) 0)
                  () "unexpected type postfix <~a>" (postfix type-info))
          (assert (not (gethash (name name-data) (commands vk-spec)))
                  () "command <~a> already specified" (name name-data))
          (setf (gethash (name name-data) (bitmasks vk-spec))
                (make-instance 'bitmask
                               :name (name name-data)
                               :type-name (type-name type-info)
                               :requires requires))
          (assert (not (gethash (name name-data) (types vk-spec)))
                  () "bitmask <~a> already specified as a type" (name name-data))
          (setf (gethash (name name-data) (types vk-spec)) :bitmask)))))

(defun parse-define (node vk-spec)
  "TODO"
  (let* ((name (xps (xpath:evaluate "name" node)))
         (@name (xps (xpath:evaluate "@name" node)))
         (type (xps (xpath:evaluate "type" node)))
         (requires (xps (xpath:evaluate "@requires" node)))
         (args (xps (xpath:evaluate (cond
                                      (type "type/following-sibling::text()")
                                      (name "name/following-sibling::text()")
                                      (@name "text()")
                                      (t (error "unknown define args path for define")))
                                    node)))
         (is-value-p (begins-with-p args "("))
         (is-struct-p (search "struct" (xps node))))
    (when is-struct-p
        (assert (not (gethash name (types vk-spec)))
                () "type <~a> has already been specified" name)
        (setf (gethash (or name @name) (types vk-spec))
              :define))
    (when @name
      (assert (string= @name "VK_DEFINE_NON_DISPATCHABLE_HANDLE")
              () "unknown category=define name <~a>" @name)
      (setf name @name)
      (setf is-value-p nil)
      (setf args (xps node)))    
    (assert (not (gethash name (defines vk-spec)))
            () "define <~a> has already been specified" name)
    (setf (gethash name (defines vk-spec))
          (make-instance 'define
                         :name name
                         :is-value-p is-value-p
                         :is-struct-p is-struct-p
                         :requires requires
                         :calls type
                         :args args))))

(defun parse-enum-type (node vk-spec)
  "TODO"
  (let ((alias (xps (xpath:evaluate "@alias" node)))
        (name (xps (xpath:evaluate "@name" node))))
    (if alias
        (progn
          (assert (> (length alias) 0)
                  () "enum with empty alias")
          (let ((enum (gethash alias (enums vk-spec))))
            (assert enum
                    () "enum with unknown alias <~a>" alias)
            (assert (= (length (alias enum)) 0)
                    () "enum <~a> already has an alias <~a>" (name enum) (alias enum))
            (setf (alias enum) alias)))
        (progn
          (assert (not (gethash name (enums vk-spec)))
                  () "enum <~a> already specified" name)
          (setf (gethash name (enums vk-spec))
                (make-instance 'enum
                               :name name
                               :alias alias))))
    (assert (not (gethash name (types vk-spec)))
            () "enum <~a> already specified as a type" name)
    (setf (gethash name (types vk-spec))
          :enum)))

(defun str-not-empty-p (str)
  (and str (> (length str) 0)))

(defun parse-funcpointer (node vk-spec)
  "TODO"
  (let ((requirements (xps (xpath:evaluate "@requires" node)))
        (name (xps (xpath:evaluate "name" node))))
    (assert (str-not-empty-p name)
            () "funcpointer with empty name")
    (assert (not (gethash name (func-pointers vk-spec)))
            () "funcpointer <~a> already specified" name)
    (setf (gethash name (func-pointers vk-spec))
          (make-instance 'func-pointer
                         :name name
                         :requirements requirements))
    (assert (not (gethash name (types vk-spec)))
            () "funcpointer <~a> already specified as a type" name)
    (setf (gethash name (types vk-spec))
          :funcpointer)
    (let* ((types (mapcar 'xps (xpath:all-nodes (xpath:evaluate "type" node)))))
      (loop for type in types
            do (progn
                 (assert (str-not-empty-p type)
                         () "funcpointer argument with empty type")
                 (assert (or (gethash type (types vk-spec))
                             (string= type requirements))
                         () "funcpointer argument of unknown type <~a>" type))))))

(defun parse-handle (node vk-spec)
  "TODO"
  (let ((alias (xps (xpath:evaluate "@alias" node))))
    (if alias
        (let ((handle (gethash alias (handles vk-spec)))
              (name (xps (xpath:evaluate "@name" node))))
          (assert handle
                  () "using unspecified alias <~a>" alias)
          (assert (not (alias handle))
                  () "handle <~a> already has an alias <~a>" (name handle) (alias name))
          (setf (alias handle) name)
          (assert (not (gethash name (types vk-spec)))
                  () "handle alias <~a> already specified as a type" name)
          (setf (gethash name (types vk-spec))
                :handle))
        (let ((parent (xps (xpath:evaluate "@parent" node)))
              (name-data (parse-name-data node))
              (type-info (parse-type-info node)))
          (assert (begins-with-p (name name-data) "Vk")
                  () "name <~a> does not begin with <Vk>" (name name-data))
          (assert (= (length (array-sizes name-data)) 0)
                  () "name <~a> with unsupported array-sizes" (name name-data))
          (assert (= (length (bit-count name-data)) 0)
                  () "name <~a> with unsupported bit-count <~a>" (name name-data) (bit-count name-data))
          (assert (or (string= (type-name type-info) "VK_DEFINE_HANDLE")
                      (string= (type-name type-info) "VK_DEFINE_NON_DISPATCHABLE_HANDLE"))
                  () "handle with invalid type <~a>" (type-name type-info))
          (assert (= (length (prefix type-info)) 0)
                  () "unexpected type prefix <~a>" (prefix type-info))
          (assert (string= (postfix type-info) "(")
                  () "unexpected type postfix <~a>" (postfix type-info))
          (assert (not (gethash (name name-data) (handles vk-spec)))
                  () "handle <~a> already specified" (name name-data))
          (setf (gethash (name name-data) (handles vk-spec))
                (make-instance 'handle
                               :name (name name-data)
                               :parents (split-sequence:split-sequence #\, parent)))
          (assert (not (gethash (name name-data) (types vk-spec)))
                  () "handle <~a> already specified as a type" (name name-data))
          (setf (gethash (name name-data) (types vk-spec))
                :handle)))))

(defun parse-type-include (node vk-spec)
  "TODO"
  (let ((name (xps (xpath:evaluate "@name" node))))
    (assert (not (find name (includes vk-spec)))
            () "include named <~a> already specified" name)
    (push name (includes vk-spec))))

(defun determine-sub-struct (structure vk-spec)
  "TODO"
  (loop for other-struct being each hash-values of (structures vk-spec)
        when (and (string= (name structure) (name other-struct))
                      (< (length (member-values other-struct))
                         (length (member-values structure)))
                      (not (string= (first (member-values other-struct))
                                    "sType"))
                      (every (lambda (m1 m2)
                               (and (string= (type-name m1)
                                             (type-name m2))
                                    (string= (name m1)
                                             (name m2))))
                             (member-values other-struct)
                             (subseq (member-values structure)
                                     0 (length (member-values other-struct)))))
        return (name other-struct)))

(defparameter *ignore-lens*
  '("null-terminated"
    "latexmath:[\\lceil{\\mathit{rasterizationSamples} \\over 32}\\rceil]"
    "2*VK_UUID_SIZE"
    "2*ename:VK_UUID_SIZE")
  "A list of <len> attributes in <member> tags.")

(defun parse-struct-member (node structure vk-spec)
  "TODO"
  (let* ((name-data (parse-name-data node))
         (type-info (parse-type-info node))
         (enum (xps (xpath:evaluate "enum" node)))
         (len (xps (xpath:evaluate "@len" node)))
         (no-autovalidity-p (parse-boolean (xpath:evaluate "@noautovalidity" node)))
         (optional-p (parse-boolean (xpath:evaluate "@optional" node)))
         (selection (xps (xpath:evaluate "@selection" node)))
         (selector (xps (xpath:evaluate "@selector" node)))
         (member-values (split-sequence:split-sequence #\, (xps (xpath:evaluate "@values" node))))
         (comment (xps (xpath:evaluate "comment" node)))
         (member-data (make-instance 'member-data
                                     :name (name name-data)
                                     :comment comment
                                     :array-sizes (array-sizes name-data)
                                     :bit-count (bit-count name-data)
                                     :type-info type-info
                                     :no-autovalidity-p no-autovalidity-p
                                     :optional-p optional-p
                                     :selection selection
                                     :selector selector
                                     :member-values member-values)))
    (assert (not (find-if (lambda (m) (string= (name member-data) (name m)))
                          (member-values structure)))
            () "structure member name <~a> already used" (name member-data))
    (when enum
      ;; this is fucked up: enum/preceding-sibling::text() is always NIL, so let's hope that <name> always comes before <enum>...
      (let ((enum-prefix (xps (xpath:evaluate "name/following-sibling::text()" node)))
            (enum-postfix (xps (xpath:evaluate "enum/following-sibling::text()" node))))
        (assert (and enum-prefix (string= enum-prefix "[")
                     enum-postfix (string= enum-postfix "]"))
                () "structure member array specification is ill-formatted: <~a>" enum)
        (push enum (array-sizes member-data))))
    (when len
      (setf (len member-data) (split-sequence:split-sequence #\, len))
      (assert (<= (length (len member-data)) 2)
              () "member attribute <len> holds unknown number of data: ~a" (length (len member-data)))
      (let* ((first-len (first (len member-data)))
             (len-member (find-if (lambda (m) (string= first-len (name m)))
                                  (member-values structure))))
        (assert (or len-member
                    (find first-len *ignore-lens* :test #'string=)
                    (string= first-len "latexmath:[\\textrm{codeSize} \\over 4]"))
                () "member attribute <len> holds unknown value <~a>" first-len)
        (when len-member
          (assert (and (not (prefix (type-info len-member)))
                       (not (postfix (type-info len-member))))
                  () "member attribute <len> references a member of unexpected type <~a>" (type-info len-member)))
        (when (< 1 (length (len member-data)))
          (assert (find (second (len member-data)) '("1" "null-terminated") :test #'string=)
                  () "member attribute <len> holds unknown second value <~a>" (second (len member-data))))))
    (when selection
      (assert (is-union-p structure)
              () "attribute <selection> is used with non-union structure."))
    (when selector
      (let ((member-selector (find-if (lambda (m) (string= selector (name m)))
                                      (member-values structure))))
        (assert member-selector
                () "member attribute <selector> holds unknown value <~a>" selector)
        (assert (gethash (type-name (type-info member-selector)) (enums vk-spec))
                () "member attribute references unknown enum type <~a>" (type-name (type-info member-selector)))))
    member-data))

(defun parse-struct (node vk-spec)
  "TODO"
  (let ((alias (xps (xpath:evaluate "@alias" node)))
        (name (xps (xpath:evaluate "@name" node))))
    (if alias
        (let ((struct (gethash alias (structures vk-spec))))
          (assert struct
                  () "missing alias <~a>" alias)
          (assert (not (find name (aliases struct)))
                  () "struct <~a> already uses alias <~a>" alias name)
          (push name (aliases struct))
          (assert (not (gethash name (structure-aliases vk-spec)))
                  () "structure alias <~a> already used" name)
          (setf (gethash name (structure-aliases vk-spec))
                alias)
          (assert (not (gethash name (types vk-spec)))
                  () "struct <~a> already specified as a type" name)
          (setf (gethash name (types vk-spec))
                :struct))
        (let ((allow-duplicate-p (parse-boolean (xpath:evaluate "@allowduplicate" node)))
              (is-union-p (string= (xps (xpath:evaluate "@category" node)) "union"))
              (returned-only-p (parse-boolean (xpath:evaluate "@returnedonly" node)))
              (struct-extends (split-sequence:split-sequence #\, (xps (xpath:evaluate "@structextends" node)))))
          (assert name
                  () "struct has no name")
          ;; todo: this should be an assert in a future version
          (when (and allow-duplicate-p
                     (> (length struct-extends) 0))
            (warn "attribute <allowduplicate> is true, but no structures are listed in <structextends>"))
          (assert (not (gethash name (structures vk-spec)))
                  () "struct <~a> already specified" name)
          (setf (gethash name (structures vk-spec))
                (make-instance 'struct
                               :name name
                               :struct-extends struct-extends
                               :allow-duplicate-p allow-duplicate-p
                               :returned-only-p returned-only-p
                               :is-union-p is-union-p))
          (xpath:do-node-set (member-node (xpath:evaluate "member" node))
            (push (parse-struct-member member-node
                                       (gethash name (structures vk-spec))
                                       vk-spec)
                  (member-values (gethash name (structures vk-spec)))))
          (setf (sub-struct (gethash name (structures vk-spec)))
                (determine-sub-struct (gethash name (structures vk-spec))
                                      vk-spec))
          (setf (extended-structs vk-spec)
                (remove-duplicates
                 (append struct-extends (extended-structs vk-spec))
                 :test #'string=))
          (assert (not (gethash name (types vk-spec)))
                  () "struct <~a> already specified as a type" name)
          (setf (gethash name (types vk-spec))
                (if is-union-p
                    :union
                    :struct))))))


(defun parse-requires (node vk-spec)
  "TODO"
  (let ((name (xps (xpath:evaluate "@name" node)))
        (requires (xps (xpath:evaluate "@requires" node))))
    (assert (not (gethash name (types vk-spec)))
            () "type <~a> already specified as a type" name)
    (if requires
        (progn
          (assert (find requires (includes vk-spec) :test #'string=)
                  () "type requires unknown include <~a>" requires)
          (setf (gethash name (types vk-spec))
                :requires))
        (progn
          (assert (string= name "int")
                  () "unknown type")
          (setf (gethash name (types vk-spec))
                :unknown)))))

(defun parse-types (vk.xml vk-spec)
  "TODO"
  (xpath:do-node-set (node (xpath:evaluate "/registry/types/type[(@category=\"include\")]" vk.xml))
    (parse-type-include node vk-spec))
  (xpath:do-node-set (node (xpath:evaluate "/registry/types/type[not(@category)]" vk.xml))
    (parse-requires node vk-spec))
  (xpath:do-node-set (node (xpath:evaluate "/registry/types/type[@category=\"basetype\"]" vk.xml))
    (parse-basetype node vk-spec))
  (xpath:do-node-set (node (xpath:evaluate "/registry/types/type[@category=\"bitmask\"]" vk.xml))
    (parse-bitmask node vk-spec))
  (xpath:do-node-set (node (xpath:evaluate "/registry/types/type[@category=\"define\"]" vk.xml))
    (parse-define node vk-spec))
  (xpath:do-node-set (node (xpath:evaluate "/registry/types/type[@category=\"enum\"]" vk.xml))
    (parse-enum-type node vk-spec))
  (xpath:do-node-set (node (xpath:evaluate "/registry/types/type[@category=\"handle\"]" vk.xml))
    (parse-handle node vk-spec))
  (xpath:do-node-set (node (xpath:evaluate "/registry/types/type[@category=\"struct\" or @category=\"union\"]" vk.xml))
    (parse-struct node vk-spec))
  (xpath:do-node-set (node (xpath:evaluate "/registry/types/type[@category=\"funcpointer\"]" vk.xml))
    (parse-funcpointer node vk-spec)))

(defun parse-enum-contant (node vk-spec)
  "TODO"
  (let ((name (xps (xpath:evaluate "@name" node)))
        (alias (xps (xpath:evaluate "@alias" node)))
        (comment (xps (xpath:evaluate "@comment" node))))
    (if alias
        (let ((constant (gethash alias (constants vk-spec))))
          (assert constant
                  () "unknown enum constant alias <~a>" alias)
          (setf (gethash name (constants vk-spec))
                (make-instance 'api-constant
                               :name name
                               :alias alias
                               :comment comment
                               :number-value (number-value constant)
                               :string-value (string-value constant)
                               :vk-hpp-name (vk-hpp-name constant)
                               :single-bit-p (single-bit-p constant))))
        (let* ((string-value (xps (xpath:evaluate "@value" node)))
               (number-value (numeric-value string-value)))
          (assert (not (gethash name (constants vk-spec)))
                  () "already specified enum constant <~a>" name)
          (assert number-value
                  () "non-alias enum constant <~a> has no value" name)
          (setf (gethash name (constants vk-spec))
                (make-instance 'api-constant
                               :name name
                               :comment comment
                               :number-value number-value
                               :string-value string-value))))))

(defun to-upper-snake (str)
  "Transforms a given string to a snake-cased string, but all characters are uppercased.

E.g.: \"VkResult\" becomes \"VK_RESULT\". 
"
  (string-upcase (kebab:to-snake-case str)))

(defun is-vk-result (str)
  "Checks if a string is equal to \"VkResult\"."
  (string= str "VkResult"))

(defun get-enum-prefix (name is-bitmaks-p)
  "TODO"
  (cond
    ((is-vk-result name) "VK_")
    (is-bitmaks-p
     (let ((flag-bits-pos (search "FlagBits" name)))
       (assert flag-bits-pos
               () "bitmask <~a> does not contain <FlagBits> as substring")
       (concatenate 'string (to-upper-snake (subseq name 0 flag-bits-pos)) "_")))
    (t
     (concatenate 'string (to-upper-snake name) "_"))))

(defun get-enum-pre-and-postfix (name is-bitmask-p tags)
  (let ((prefix (get-enum-prefix name is-bitmask-p))
        (postfix ""))
    (unless (is-vk-result name)
      (let ((tag (find-if (lambda (tag)
                            (or (alexandria:ends-with-subseq (concatenate 'string tag "_") prefix)
                                (alexandria:ends-with-subseq tag name)))
                          tags)))
        (when tag
          (when (alexandria:ends-with-subseq (concatenate 'string tag "_") prefix)
            (setf prefix (subseq prefix 0 (- (length prefix) (length tag) 1))))
          (setf postfix (concatenate 'string "_" tag)))))
    (values prefix postfix)))

(defun find-tag (tags name postfix)
  "TODO"
  (or
   (find-if (lambda (tag)
              (alexandria:ends-with-subseq
               (concatenate 'string tag postfix)
               name))
            tags)
   ""))

(defun strip-prefix (str prefix)
  (if (and prefix
           (> (length prefix) 0)
           (alexandria:starts-with-subseq prefix str))
      (subseq str (length prefix))
      str))

(defun strip-postfix (str postfix)
  (if (and postfix
           (> (length postfix) 0)
           (alexandria:ends-with-subseq postfix str))
      (subseq str 0 (search postfix str))
      str))

(defun upper-snake-to-pascal-case (str)
  "Transforms a string in uppercased snake-case to a pascal-cased string.

E.g. \"VK_RESULT\" becomes \"VkResult\".
"
  (kebab:to-pascal-case (string-downcase str)))

(defun create-enum-vk-hpp-name (name prefix postfix is-bitmask-p tag)
  "TODO"
  (let ((result (concatenate
                 'string
                 "e"
                 (upper-snake-to-pascal-case
                  (strip-postfix (strip-prefix name prefix) postfix)))))
    (when is-bitmask-p
      (setf result (subseq result 0 (search "Bit" result))))
    (when (and (> (length tag) 0)
               (string= (upper-snake-to-camel-case tag)
                        (subseq result 0 (- (length result) (length tag)))))
      (setf result (subseq result 0 (- (length result) (length tag)))))
    result))

(defun add-enum-value (enum))

(defun add-enum-alias (enum name alias-name vk-hpp-name)
  (let ((alias (gethash alias-name (aliases enum))))
    (assert (or (find-if (lambda (v)
                           (string= alias-name (name v)))
                         (enum-values enum))
                alias)
            () "unknown enum alias <~a>" alias-name)
    (assert (or (not alias)
                (string= (first alias) alias-name))
            () "enum alias <~a> already listed for a different enum value")
    ;; only list aliaes that map to different vk-hpp-names
    (setf alias (find-if (lambda (alias-data)
                           (string= vk-hpp-name (second alias-data)))
                         (alexandria:hash-table-values (aliases enum))))
    (unless alias
      (setf (gethash name (aliases enum))
            (list alias-name vk-hpp-name)))))

(defun parse-enum-value (node enum is-bitmask-p prefix postfix vk-spec)
  "TODO"
  (let* ((name (xps (xpath:evaluate "@name" node)))
         (alias (xps (xpath:evaluate "@alias" node)))
         (tag (find-tag (tags vk-spec) name postfix))
         (vk-hpp-name
           (create-enum-vk-hpp-name name
                                    prefix
                                    postfix
                                    is-bitmask-p
                                    tag))
         (comment (xps (xpath:evaluate "@comment" node))))
    (if alias
        (add-enum-alias enum name alias vk-hpp-name)
        (let* ((bitpos-string (xps (xpath:evaluate "@bitpos" node)))
               (value-string (xps (xpath:evaluate "@value" node)))
               (bitpos (numeric-value bitpos-string))
               (value (numeric-value value-string))
               (enum-value (find-if (lambda (e)
                                      (string= (vk-hpp-name e) vk-hpp-name))
                                    (enum-values enum))))
          (assert (or (and (not bitpos) value)
                      (and bitpos (not value)))
                  () "invalid set of attributes for enum <~a> name")
          (if enum-value
              (assert (string= (name enum-value) name)
                      () "enum value <~a> maps to same vk-hpp-name as <~a>" name (name enum-value))
              (push (make-instance 'enum-value
                                   :name name
                                   :comment comment
                                   :number-value (or value (ash 1 bitpos))
                                   :string-value (or value-string bitpos-string)
                                   :vk-hpp-name vk-hpp-name
                                   :single-bit-p (not value))
                    (enum-values enum)))))))

(defun parse-enums (vk.xml vk-spec)
  "TODO"
  (xpath:do-node-set (node (xpath:evaluate "/registry/enums[@name=\"API Constants\"]/enum" vk.xml))
    (parse-enum-contant node vk-spec))
  (xpath:do-node-set (node (xpath:evaluate "/registry/enums[not(@name=\"API Constants\")]" vk.xml))
    (let* ((name (xps (xpath:evaluate "@name" node)))
           (type (xps (xpath:evaluate "@type" node)))
           (comment (xps (xpath:evaluate "@comment" node)))
           (is-bitmask-p (string= type "bitmask"))
           (enum (gethash name (enums vk-spec))))
      (unless enum
        (warn "enum <~a> is not listed as enum in the types section" name)
        (setf (gethash name (enums vk-spec))
              (make-instance 'enum
                             :name name
                             :is-bitmask-p is-bitmask-p
                             :comment comment))
        (assert (not (gethash name (types vk-spec)))
                () "enum <~a> already specified as a type" name)
        (setf (gethash name (types vk-spec))
              :enum)
        (setf enum (gethash name (enums vk-spec))))
      (assert (not (enum-values enum))
              () "enum <~a> already holds values" name)
      (setf (is-bitmask-p enum) is-bitmask-p)
      (setf (comment enum) comment)
      (when is-bitmask-p
        (let ((bitmask (loop for b being each hash-values of (bitmasks vk-spec)
                             when (string= (requires b) name)
                             return b)))
          (unless bitmask
            (warn "enum <~a> is not listed as an requires for any bitmask in the types section" name)
            (let ((flag-bits-pos (search "FlagBits" name)))
              (assert flag-bits-pos
                      () "enum <~a> does not contain <FlagBits> as substring")
              (let* ((bitmask-name (concatenate 'string
                                                (subseq name 0 flag-bits-pos)
                                                "Flags"
                                                (subseq name (+ flag-bits-pos 8)))))
                (setf bitmask (gethash bitmask-name (bitmasks vk-spec)))
                (assert bitmask
                        () "enum <~a> has no corresponding bitmask <~a> listed in the types section" name bitmask-name)
                (setf (requires bitmask) name))))))
      (multiple-value-bind (prefix postfix) (get-enum-pre-and-postfix name is-bitmask-p (tags vk-spec))
        (xpath:do-node-set (enum-value-node (xpath:evaluate "enum" node))
          (parse-enum-value enum-value-node enum is-bitmask-p prefix postfix vk-spec))))))


(defun parse-tags (vk.xml vk-spec)
  "TODO"
  (xpath:do-node-set (node (xpath:evaluate "/registry/tags/tag" vk.xml))
    (let ((name (xps (xpath:evaluate "@name" node))))
      (assert (not (find name (tags vk-spec)))
              () "tag named <~a> has already been specified")
      (push name (tags vk-spec)))))

(defun parse-vk-xml (version vk-xml-pathname)
  "Parses the vk.xml file at VK-XML-PATHNAME into a VK-SPEC instance."
  (let* ((vk.xml (cxml:parse-file vk-xml-pathname
                                  (cxml:make-whitespace-normalizer
                                   (stp:make-builder))))
         (vk-spec (make-instance 'vulkan-spec)))
    (parse-tags vk.xml vk-spec)
    (parse-types vk.xml vk-spec)
    (parse-enums vk.xml vk-spec)
    vk-spec))
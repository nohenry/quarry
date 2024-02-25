(identifier) @variable

; ((type) @type
;  (#match? @type "^[A-Z][a-zA-Z0-9]*"))

(base_type) @type

(number) @number
(comment) @comment

((identifier) @variable.builtin
 (#lua-match? @variable.builtin "^:[a-zA-Z0-9]*")
)

(call_expression
  function: (expression (primary_expression (identifier) @function)))

(call_expression
  function: (expression (primary_expression (identifier) @function.builtin (#lua-match? @function.builtin "^:[a-zA-Z0-9]*"))))

(record_field
  name: (identifier) @variable.member
)


; (variant name: (identifier) @constant)
; (field name: (identifier) @field)

(binding 
    name: (identifier) @type
    value: (type)
)

(binding 
    name: (identifier) @variable
    value: (type (expression))
)

(binding 
    name: (identifier) @function
    value: (type (expression (primary_expression (closure))))
)

(union_member 
  (identifier) @constant
)

(file_item (type (expression (primary_expression (identifier) @attribute (#match? "^:[a-zA-Z0-9]+")))))

[
    (true)
    (false)
    (none)
] @constant.builtin

[
    ":"
    "{"
    "}"
    "["
    "]"
    ","
] @punctuation.delimiter

[
    "+"
    "-"
    "*"
    "/"
    "!"
    "&"
    ":"
    ">"
    ">="
    "<"
    "<="
    "|>"
    "?"
    "=="
    "!="
    "="
] @operator

; (field ":" @punctuation.delimiter)

[
  "("
  ")"
]  @punctuation.bracket

[
    "const"
    "let"
    "if"
    "loop"
    "else"
    "finally"
    "mut"
    "type"
    "protocol"
] @keyword

((identifier) @type
 (#eq? @type "Self")
 )

;; "else"
;; "if"
;; "let"
;; "loop"
;; "match"
;; "module"

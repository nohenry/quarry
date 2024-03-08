function commaSep1(rule, sep) {
    return seq(rule, repeat(seq(sep, rule)))
}

function commaSep(rule, sep) {
    return optional(commaSep1(rule, sep))
}

const operators = [
    [".", "member"],
    ["::", "union_init"],
    ["+", "binary_plus"],
    ["-", "binary_plus"],
    ["*", "binary_times"],
    ["/", "binary_times"],
    ["%", "binary_times"],
    ["<", "binary_relation"],
    ["<=", "binary_relation"],
    ["==", "binary_equality"],
    ["!=", "binary_equality"],
    [">=", "binary_relation"],
    [">", "binary_relation"],
    ["|>", "binary_pipe"],
    ["+=", "assign"],
    ["-=", "assign"],
    ["*=", "assign"],
    ["/=", "assign"],
    ["&=", "assign"],
    ["|=", "assign"],
    ["^=", "assign"],
]

/* eslint-disable arrow-parens */
/* eslint-disable camelcase */
/* eslint-disable-next-line spaced-comment */
/// <reference types="tree-sitter-cli/dsl" />
// @ts-check
module.exports = grammar({
    name: "quarry",

    extras: ($) => [$.comment, /[\s\p{Zs}\uFEFF\u2028\u2029\u2060\u200B]/],

    inline: ($) => [$.type_array_slice],

    precedences: ($) => [
        [
            'member',
            "call",
            "unary_void",
            "post_expr",
            "binary_times",
            "binary_plus",
            "binary_relation",
            "binary_equality",
            "binary_pipe",
            "union_init",
            "assign",
            $.closure,
            $.const_expr,
        ],
        [
            $.type_record,
            $.type_slice,
            $.type_array,
        ]
    ],

    conflicts: ($) => [
        [$.primary_expression, $.closure],
        [$.expression, $.type],
        [$.primary_expression, $.type],
    ],

    rules: {
        source_file: ($) => repeat1(seq($.file_item, '\n')),

        // variant: $ => prec('member', seq(field('name', $.identifier), optional(seq('::', field('type', $.type))))),
        // field: $ => prec('member', seq(field('name', $.identifier), seq(':', field('type', $.type)))),

        file_item: ($) => choice(
            $.binding,
            seq($.expression, '=', $.expression),
            $.type,
        ),
        block_stmts: ($) => repeat1(seq(choice($.file_item), '\n')),

        binding: ($) =>
            seq(
                optional('public'),
                optional('export'),
                optional('extern'),
                choice("let", $.type),
                optional("mut"),
                field("name", $.identifier),
                "=",
                field("value", $.type)
            ),

        expression: ($) =>
            choice(
                $.primary_expression,
                $.unary_expression,
                $.implicit_variant,
                $.binary_expression,
                $.identifier,

                $.if_expr,
                $.loop_expr,
                $.call_expression,
                $.subscript_expression,
                $.const_expr,
                prec.left(20, seq($.expression, '.*')),
                prec.left(20, seq($.expression, '.&')),
                // seq($.expression, '.&'),
            ),
        const_expr: $ => seq('const', $.expression),
        const_block: $ => seq('const', $.if_block),
        implicit_variant: $ => seq('.', $.identifier),

        type: ($) =>
            choice(
                $.protocol,

                $.type_ref,
                $.type_opt,
                $.type_array_slice,
                prec(10, $.type_record),
                // $.if_type_expr,
                $.expression,
                $.base_type,
            ),
        base_type: $ => choice(
            $.type_identifier,
            "any",
            "anytype",
            /[u]?int[0-9]*/,
            /float[0-9]*/,
            "bool",
        ),
        type_ref: ($) => seq($.type, optional("mut"), "&"),
        type_opt: ($) => seq($.type, "?"),

        type_array_slice: ($) => choice($.type_slice, $.type_array),
        type_slice: ($) => seq("[", optional(field("mut", "mut")), $.type, "]"),
        type_array: ($) =>
            seq("[", $.type, seq(":", field("size", $.expression)), "]"),
        type_record: $ => prec(10, seq(
            "type",
            optional(seq('(', $.type, ')')),
            choice(
                $.record_block,
                prec(2, $.type_union),
                prec(2, $.type),
            ),
        )),
        record_block: $ => prec(5, seq(
            "[",
            repeat(seq($.record_field, ",")),
            "]",
        )),
        record_field: $ => seq(field('type', $.type), field('name', $.identifier), optional(seq('=', $.type))),
        type_union: $ => prec.left(seq($.union_member, repeat(seq("|", $.union_member)))),
        union_member: $ => prec.left(10, seq(
            $.type,
            $.identifier,
            optional(seq("=", $.expression)),
        )),

        protocol: $ => seq(
            'protocol',
            $.proto_block,
        ),
        proto_block: $ => seq(
            '{',
                repeat(choice(
                    seq($.fn_proto, '\n')
                )),
            '}'
        ),
        fn_proto: $ => seq('let', $.identifier, '=', prec.right(
            seq(
                field("parameters", $.paramater_list),
                optional(field('ret_ty', $.type)),
            )
        )),

        if_type_expr: ($) =>
            seq("if", $.expression, optional($.capture), $.if_exp_block, "else", $.if_exp_block),
        if_exp_block: $ => seq('{', $.type, '}'),

        capture: ($) => seq("(", commaSep($.identifier, ","), ")"),

        if_expr: ($) =>
            seq(
                "if",
                $.expression,
                optional(seq('=>', $.capture)),
                $.if_block,
                optional(seq('else', $.if_block)),
            ),
        if_block: $ => seq(
            "{",
            optional($.block_stmts),
            "}"
        ),

        match_expr: $ => seq("match", $.expression, "do", commaSep($.match_arm, ','), ":;"),
        match_arm: $ => seq($.expression, '=>', $.block_stmts),

        loop_expr: ($) =>
            seq(
                "loop",
                $.expression,
                optional(seq('=>', $.capture)),
                $.if_block,
                optional(seq('else', $.if_block)),
                optional(seq('finally', $.if_block)),
            ),

        closure: ($) =>
            prec.right(seq(
                field("parameters", $.paramater_list),
                optional(field('ret_ty', $.type)),
                choice($.if_block, '\n'),
            )),

        argument_list: ($) => seq("(", commaSep(seq(field('name', optional(seq($.identifier, ':'))), $.expression), ","), ")"),

        paramater_list: ($) =>
            seq(
                "(",
                commaSep(
                    seq(
                        // optional("const"),
                        choice($.type, "let"),
                        $.identifier,
                        optional(field('default', seq('=', $.type)))
                    ),
                    ","
                ),
                ")"
            ),

        primary_expression: ($) =>
            prec.right(
                choice(
                    $.number,
                    $.true,
                    $.false,
                    $.none,

                    // $.if_expr,
                    // $.
                    // $.match_expr,
                    // $.do_block,
                    $.closure,
                    // $.identifier,
                    $.array_or_record_expr,

                    // prec("do_expr", $.type)
                )
            ),
        // choice($.number, $.true, $.false, $.none),

        array_or_record_expr: $ => prec(10, seq(
            '[',
            repeat(seq($.expression, optional(seq(':', field('value', $.expression))), ',')),
            seq($.expression, optional(seq(':', $.expression))),
            ']'
        )),

        call_expression: ($) =>
            prec(
                "call",
                seq(
                    field("function", $.expression),
                    field("arguments", $.argument_list)
                )
            ),
        subscript_expression: ($) =>
            prec(
                "call",
                seq(
                    field("expr", $.expression),
                    '[',
                    field("subscript", $.expression),
                    ']',
                )
            ),

        // implicit_expression: $ => prec.left(
        //     'unary_implicit',
        //     seq(':', )
        // ),

        binary_expression: ($) =>
            choice(
                ...operators.map(([operator, precedence]) =>
                    prec.left(
                        precedence,
                        seq(
                            field("left", $.expression),
                            field("operator", operator),
                            field("right", $.expression)
                        )
                    )
                )
            ),

        unary_expression: ($) =>
            prec.left(
                "unary_void",
                seq(
                    field("operator", choice("!", "-")),
                    field("argument", $.expression)
                )
            ),

        post_expression: ($) =>
            prec.left(
                "post_expr",
                // choice(
                seq(
                    field("argument", $.expression),
                    field("operator", choice(".*", ".?", ".&"))
                )
                // )
            ),

        true: (_) => "true",
        false: (_) => "false",
        none: (_) => "none",
        module: (_) => "box",

        identifier: ($) => /[:a-zA-Z_][a-z_A-Z0-9]*/,
        type_identifier: ($) => /[A-Z][a-z_A-Z0-9]*/,

        number: ($) => /\d+/,
        comment: (_) =>
            token(
                choice(
                    seq("//", /.*/),
                    seq("/*", /[^*]*\*+([^/*][^*]*\*+)*/, "/")
                )
            ),
    },
})

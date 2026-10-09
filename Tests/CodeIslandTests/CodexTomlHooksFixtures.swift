import Foundation

/// Shared local/remote cases: expected text also locks down preservation and
/// idempotence. A nil expectation means the original must be left untouched.
struct CodexTomlHooksFixture {
    let name: String
    let original: String
    let expected: String?

    static let cases: [CodexTomlHooksFixture] = [
        .init(name: "empty", original: "", expected: "features.hooks = true\n"),
        .init(
            name: "issue354",
            original: "\"features\".\"hooks\" = true\nmodel = \"gpt-6-sol\"\n\n[features.context_management]\nexperimental_mode = true\n",
            expected: "\"features\".\"hooks\" = true\nmodel = \"gpt-6-sol\"\n\n[features.context_management]\nexperimental_mode = true\n"
        ),
        .init(name: "dotted false", original: "  features . 'hooks' = false  # keep\n", expected: "  features . 'hooks' = true  # keep\n"),
        .init(name: "escaped dotted keys", original: "\"\\u0066eatures\".\"\\U00000068ooks\" = false\n", expected: "\"\\u0066eatures\".\"\\U00000068ooks\" = true\n"),
        .init(name: "quoted bare false", original: "[\"features\"]\n\"hooks\" = false # disabled\n", expected: "[\"features\"]\n\"hooks\" = true # disabled\n"),
        .init(name: "literal bare true", original: "['features']\n'hooks' = true\n", expected: "['features']\n'hooks' = true\n"),
        .init(name: "escaped bare key", original: "[features]\n\"\\u0068ooks\" = false\n", expected: "[features]\n\"\\u0068ooks\" = true\n"),
        .init(name: "quoted header", original: "[ \"features\" ] # keep\nother = true\n", expected: "[ \"features\" ] # keep\nhooks = true\nother = true\n"),
        .init(name: "header at EOF", original: "[features]", expected: "[features]\nhooks = true\n"),
        .init(name: "root keys only", original: "model = \"example\"\n", expected: "model = \"example\"\nfeatures.hooks = true\n"),
        .init(name: "commented table", original: "[tui] # UI options\nmax_input_chars = 10\n", expected: "features.hooks = true\n[tui] # UI options\nmax_input_chars = 10\n"),
        .init(name: "commented subtable", original: "[features.context_management] # keep\nexperimental_mode = true\n", expected: "features.hooks = true\n[features.context_management] # keep\nexperimental_mode = true\n"),
        .init(name: "quoted hash in header", original: "[\"tui#view\"] # keep\nvalue = 1\n", expected: "features.hooks = true\n[\"tui#view\"] # keep\nvalue = 1\n"),
        .init(name: "profile flag is not root", original: "[profiles.work]\nfeatures.hooks = false\n", expected: "features.hooks = true\n[profiles.work]\nfeatures.hooks = false\n"),
        .init(name: "unrelated bare flag first", original: "[tui]\nhooks = false\n[features]\nhooks = false\n", expected: "[tui]\nhooks = false\n[features]\nhooks = true\n"),
        .init(name: "root bare hooks is not feature", original: "hooks = true\n", expected: "hooks = true\nfeatures.hooks = true\n"),
        .init(name: "array table", original: "[[agents]] # keep\nhooks = false\n", expected: "features.hooks = true\n[[agents]] # keep\nhooks = false\n"),
        .init(name: "multiline array", original: "values = [\n  \"[features]\",\n  \"features.hooks = false\", # keep\n]\n[tui]\nvalue = 1\n", expected: "values = [\n  \"[features]\",\n  \"features.hooks = false\", # keep\n]\nfeatures.hooks = true\n[tui]\nvalue = 1\n"),
        .init(name: "unrelated inline table", original: "other = { text = \"[features] # not a table\", hooks = false }\n", expected: "other = { text = \"[features] # not a table\", hooks = false }\nfeatures.hooks = true\n"),
        .init(name: "basic multiline string", original: "developer_instructions = \"\"\"\nfeatures.hooks = false\n[features]\n\"\"\"\n[tui]\nvalue = 1\n", expected: "developer_instructions = \"\"\"\nfeatures.hooks = false\n[features]\n\"\"\"\nfeatures.hooks = true\n[tui]\nvalue = 1\n"),
        .init(name: "literal multiline string", original: "developer_instructions = '''\nfeatures.hooks = false\n[features]\n'''\n", expected: "developer_instructions = '''\nfeatures.hooks = false\n[features]\n'''\nfeatures.hooks = true\n"),
        .init(name: "four closing quotes", original: "developer_instructions = \"\"\"text\"\"\"\"\n[tui]\n", expected: "developer_instructions = \"\"\"text\"\"\"\"\nfeatures.hooks = true\n[tui]\n"),
        .init(name: "five closing quotes", original: "developer_instructions = '''text'''''\n[tui]\n", expected: "developer_instructions = '''text'''''\nfeatures.hooks = true\n[tui]\n"),
        .init(name: "CRLF", original: "[features] # keep\r\n\"hooks\" = false # keep\r\n", expected: "[features] # keep\r\n\"hooks\" = true # keep\r\n"),
        .init(name: "comment is not a flag", original: "# features.hooks = false\n# [features]\n", expected: "# features.hooks = false\n# [features]\nfeatures.hooks = true\n"),
        .init(name: "legacy table key", original: "[features]\n'codex_hooks' = false # keep\n", expected: "[features]\nhooks = true # keep\n"),
        .init(name: "legacy dotted key", original: "\"features\".\"codex_hooks\" = true # keep\n", expected: "features.hooks = true # keep\n"),
        .init(name: "remove scoped legacy only", original: "[tui]\ncodex_hooks = false\n[features]\nhooks = true\ncodex_hooks = true\n", expected: "[tui]\ncodex_hooks = false\n[features]\nhooks = true\n"),
        .init(name: "remove dotted legacy", original: "features.hooks = false\nfeatures.codex_hooks = true\n", expected: "features.hooks = true\n"),
        // CodeIsland 1.0.35 and earlier appended this block even when the
        // table already existed; Codex then refused to start (#354).
        .init(
            name: "heal pre-fix block after dotted flag",
            original: "\"features\".\"hooks\" = true\nmodel = \"gpt-6-sol\"\n\n[features.context_management]\nexperimental_mode = true\n\n[features]\nhooks = true",
            expected: "\"features\".\"hooks\" = true\nmodel = \"gpt-6-sol\"\n\n[features.context_management]\nexperimental_mode = true\n"
        ),
        .init(
            name: "heal pre-fix block after dotted feature",
            original: "features.other = true\n\n[tui]\nx = 1\n\n[features]\nhooks = true\n",
            expected: "features.other = true\n\nfeatures.hooks = true\n[tui]\nx = 1\n"
        ),
        .init(
            name: "heal pre-fix block after commented header",
            original: "[features] # flags\r\nother = true\r\n\n[features]\nhooks = true\n",
            expected: "[features] # flags\r\nhooks = true\r\nother = true\r\n"
        ),
        .init(name: "dotted feature plus table is unsafe", original: "features.other = true\n[features]\nhooks = true\nmodel = \"x\"\n", expected: nil),
        .init(name: "edited pre-fix block is not healed", original: "features.other = true\n\n[features]\n# mine\nhooks = true\n", expected: nil),
        .init(name: "inline features is unsafe", original: "features = { hooks = false }\n", expected: nil),
        .init(name: "nonboolean hooks is unsafe", original: "[features]\nhooks = \"false\"\n", expected: nil),
        .init(name: "hooks subtable is unsafe", original: "[features.hooks]\nvalue = true\n", expected: nil),
        .init(name: "features array is unsafe", original: "[[features]]\nhooks = false\n", expected: nil),
        .init(name: "duplicate hooks is unsafe", original: "features.hooks = true\nfeatures.hooks = false\n", expected: nil),
        .init(name: "unclosed string is unsafe", original: "developer_instructions = \"\"\"\nfeatures.hooks = false\n", expected: nil),
    ]
}

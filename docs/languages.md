# Current language capabilities

The development build provides bounded lexical colors, not complete language grammars or semantic intelligence. No language currently has semantic completion, type checking, go-to-definition, folding or snippets. Those requirements remain outstanding.

Choose the language using **Document language** above the editor. **plainText** removes lexical colors. Filename extensions select an initial language; Python and shell shebangs are also recognized when the extension is unknown. Manual choices are included in normal-quit session metadata.

| Language choice | Recognized extensions | Comment commands | Lexical outline |
| --- | --- | --- | --- |
| plainText | Fallback | None | None |
| swift | swift | `//`, `/* … */` | Named functions and type declarations |
| python | py | `#` | Named functions and classes |
| javascript | js, jsx | `//`, `/* … */` | Named functions and classes |
| typescript | ts, tsx | `//`, `/* … */` | Named functions, classes, interfaces, types and enums |
| json | json | None | None |
| html | html, htm | `<!-- … -->` | None |
| xml | xml, svg | `<!-- … -->` | None |
| css | css | `/* … */` | None |
| shell | sh, zsh, bash | `#` | None |
| c | c, h | `//`, `/* … */` | None |
| cpp | cc, cpp, hpp | `//`, `/* … */` | None |
| java | java | `//`, `/* … */` | None |
| rust | rs | `//`, `/* … */` | None |
| go | go | `//`, `/* … */` | None |
| yaml | yaml, yml | `#` | None |
| toml | toml | `#` | None |
| markdown | md | `<!-- … -->` | Headings |

Colors cover selected keywords, simple quoted strings, numbers and comment forms. HTML/XML tags and Markdown headings receive basic markup coloring. The scanner is intentionally incomplete: nested/embedded languages, interpolation, raw and multiline string dialects, escaped identifiers, numeric dialects and complete language-specific keywords are not reliably recognized. JSX/TSX extension recognition does not imply JSX parsing. CSS comments use only the block form; protocol slashes in an unquoted URL are not line comments.

Highlighting runs after a short debounce on a background task and recolors only the current text revision. It scans the full bounded document rather than incrementally reparsing changed regions. Colors use temporary layout attributes and do not change saved text or undo history. Above 2 million UTF-16 units, lexical coloring is disabled. The token limit is 100,000.

The outline is textual declaration discovery, not a symbol index. It can miss declarations or report false positives in unsupported syntax. Its bounds are 2 million UTF-16 units, 20,000 lines, 10,000 symbols and 512 UTF-16 units per name. Unsupported language choices show an explanation instead of fabricated symbols.

Line/block comment commands act on selected text without inferring string literals or embedded languages. They reject unsupported forms and unsafe embedded block delimiters. Their limit is 2 million UTF-16 units and 20,000 lines. Language indentation recommendations exist in the core configuration but do not yet replace the user's indentation settings automatically; language-specific defaults remain incomplete.

**Format JSON** validates and formats JSON while preserving number, key and string lexemes. It accepts at most 2 MB UTF-8 input and 8 MB output. It does not provide live diagnostics. XML/HTML formatting is not implemented. Markdown preview is a separate inert native text presentation; it neither executes embedded HTML nor loads remote resources.

Implementation: `Sources/PadCore/LanguageService.swift`, `LanguageEditing.swift`, `DocumentOutline.swift` and `Sources/TheOnlyPad/NativeSyntaxHighlighter.swift`. Unit/native evidence covers subsets; comprehensive grammar fixtures, full language acceptance and desktop workflows remain outstanding. See the requirements matrix, especially D-01 through D-09.

# GitHub Copilot Instructions

1. Run `git submodule update --init --recursive` before writing any code.
2. Read the upstream Go implementation in `upstream/confluence-md/` first, then port it to PowerShell.
3. Never implement from scratch — always adapt the upstream logic.

## PowerShell compatibility

4. All `.ps1` files must be compatible with **PowerShell 5.1** (Windows PowerShell) as well as PS 7.
5. **Avoid emoji and non-ASCII literals** in `.ps1` files. PS 5.1 reads files without a UTF-8 BOM using the system code page (CP1252), where multi-byte UTF-8 sequences can be mis-parsed as string delimiters (e.g. byte `0x92` → U+2019 RIGHT SINGLE QUOTATION MARK). If emoji are needed in tests, save the file with a UTF-8 BOM (`EF BB BF`) so PS 5.1 reads it correctly, or express them via `[char]::ConvertFromUtf32(0x...)`.
6. **Here-string closing delimiter** (`'@` or `"@`) must begin at column 1 — no leading whitespace.
7. **`Join-Path`**: the `-AdditionalChildPath` parameter requires PS 6+. Use nested calls instead: `Join-Path (Join-Path $root '..') 'file.ps1'`.
8. **No Unicode-only separators** in string literals — use plain ASCII (e.g. `-` instead of `━`).

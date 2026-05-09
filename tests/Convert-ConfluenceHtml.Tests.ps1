#Requires -Modules Pester
<#
.SYNOPSIS
    Pester 5 tests for Convert-ConfluenceHtml.ps1.

.DESCRIPTION
    Tests are tagged to distinguish their origin:

      [Upstream] - Ported from jackchuka/confluence-md Go test suite.
                   Source files are cross-referenced in each test's comment.

      [Custom]   - Written for the PowerShell port; cover PS-specific behaviour,
                   edge-cases not present in the upstream suite, or integration
                   aspects that are unique to this wrapper script.

    The tests exercise the converter end-to-end via temp files (same style as
    the upstream Go tests which call conv.ConvertHTML() on an in-memory string
    and inspect the result).
#>

BeforeAll {
    $converterScript = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Convert-ConfluenceHtml.ps1'
    $converterScript = (Resolve-Path $converterScript).Path

    # Helper: run the converter script on an HTML string and return the markdown
    function Invoke-Converter ([string]$Html, [string]$ImageFolder = 'assets') {
        $tmpIn  = [System.IO.Path]::GetTempFileName()
        $tmpOut = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -LiteralPath $tmpIn  -Value $Html -Encoding UTF8
            & $converterScript -InputFile $tmpIn -OutputFile $tmpOut -ImageFolder $ImageFolder
            return (Get-Content -LiteralPath $tmpOut -Raw -Encoding UTF8)
        }
        finally {
            Remove-Item -LiteralPath $tmpIn  -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
        }
    }
}

# =============================================================================
# CDATA preprocessing
# Upstream source: converter_test.go :: TestConverterPreprocessCDATA
# =============================================================================
Describe 'CDATA preprocessing' -Tag 'Upstream' {
    # Upstream: TestConverterPreprocessCDATA
    It 'wraps CDATA in a pre block and HTML-encodes content' {
        $md = Invoke-Converter '<![CDATA[<tag>&value]]>'
        # The CDATA is processed and the pre block content flows through to markdown
        $md | Should -Not -BeNullOrEmpty
    }

    It 'removes the CDATA markers from output' {
        $md = Invoke-Converter '<![CDATA[some content]]>'
        $md | Should -Not -Match '<!\[CDATA\['
    }
}

# =============================================================================
# Code macro  (handleCodeMacro)
# Upstream source: confluence_test.go :: TestHandleCodeMacro
# =============================================================================
Describe 'Code macro (ac:structured-macro name=code)' -Tag 'Upstream' {
    # Upstream: TestHandleCodeMacro
    It 'wraps content in a fenced code block with language' {
        $html = @'
<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">go</ac:parameter>
  <ac:plain-text-body><!--[CDATA[fmt.Println("ok")]]></ac:plain-text-body>
</ac:structured-macro>
'@
        $md = Invoke-Converter $html
        $md | Should -Match '```go'
        $md | Should -Match 'fmt\.Println'
        $md | Should -Match '```'
    }

    It 'produces a fenced code block without language when none is specified' -Tag 'Custom' {
        $html = '<ac:structured-macro ac:name="code"><ac:plain-text-body>hello world</ac:plain-text-body></ac:structured-macro>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '```'
        $md   | Should -Match 'hello world'
    }

    It 'handles CDATA with raw storage format' {
        $html = '<ac:structured-macro ac:name="code"><ac:parameter ac:name="language">python</ac:parameter><ac:plain-text-body><![CDATA[print("hello")]]></ac:plain-text-body></ac:structured-macro>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '```python'
        $md   | Should -Match 'print\("hello"\)'
    }
}

# =============================================================================
# ac:image  (handleImage)
# Upstream source: confluence_test.go :: TestHandleImage
# =============================================================================
Describe 'Image handling (ac:image)' -Tag 'Upstream' {
    # Upstream: TestHandleImage
    It 'converts ac:image with ri:filename to a markdown image reference' {
        $md = Invoke-Converter '<ac:image ri:filename="diagram.png"></ac:image>'
        $md | Should -Match '!\[diagram\.png\]'
        $md | Should -Match 'diagram\.png'
    }

    It 'uses the configured image folder in the image path' {
        $md = Invoke-Converter '<ac:image ri:filename="diagram.png"></ac:image>' -ImageFolder 'images'
        $md | Should -Match 'images'
    }

    It 'emits a comment when filename attribute is missing' -Tag 'Custom' {
        $md = Invoke-Converter '<ac:image></ac:image>'
        $md | Should -Match '<!--'
    }
}

# =============================================================================
# ac:emoticon  (handleEmoticon)
# Upstream source: confluence_test.go :: TestHandleEmoticon
# =============================================================================
Describe 'Emoticon handling (ac:emoticon)' -Tag 'Upstream' {
    # Upstream: TestHandleEmoticon
    It 'emits the emoji fallback character followed by a space' {
        $md = Invoke-Converter '<p>Hello <ac:emoticon ac:emoji-fallback="😊" ac:name="smile"/></p>'
        $md | Should -Match '😊'
        # Must not leave a stray > from the self-closing tag
        $md | Should -Not -Match '😊\s*>'
    }

    It 'falls back to shortname when emoji-fallback is absent' -Tag 'Custom' {
        $md = Invoke-Converter '<ac:emoticon ac:emoji-shortname=":thumbsup:"/>'
        $md | Should -Match ':thumbsup:'
    }

    It 'falls back to :name: form when only ac:name is present' -Tag 'Custom' {
        $md = Invoke-Converter '<ac:emoticon ac:name="warning"/>'
        $md | Should -Match ':warning:'
    }
}

# =============================================================================
# TOC macro  (handleTocMacro)
# Upstream source: confluence_test.go :: TestHandleTocMacro
# =============================================================================
Describe 'TOC macro (ac:structured-macro name=toc)' -Tag 'Upstream' {
    # Upstream: TestHandleTocMacro
    It 'emits a Table of Contents HTML comment' {
        $md = Invoke-Converter '<ac:structured-macro ac:name="toc"/>'
        $md | Should -Match '<!-- Table of Contents -->'
    }

    It 'still emits the comment when parameters are present' {
        $html = '<ac:structured-macro ac:name="toc"><ac:parameter ac:name="maxLevel">3</ac:parameter></ac:structured-macro>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '<!-- Table of Contents -->'
    }
}

# =============================================================================
# Mermaid macro  (handleMermaidMacro)
# Upstream source: confluence_test.go :: TestHandleMermaidCloudMacroMissingResolver
# =============================================================================
Describe 'Mermaid macro (ac:structured-macro name=mermaid-cloud)' -Tag 'Upstream' {
    # Upstream: TestHandleMermaidCloudMacroMissingResolver
    # (We can't fetch attachments from a script without an API client, so this
    #  is the "missing resolver" code path.)
    It 'emits an unavailability comment with the filename' {
        $html = '<ac:structured-macro ac:name="mermaid-cloud"><ac:parameter ac:name="filename">diagram</ac:parameter></ac:structured-macro>'
        $md   = Invoke-Converter $html
        $md   | Should -Match 'Mermaid attachment diagram unavailable'
    }

    It 'emits a comment when filename parameter is missing' -Tag 'Custom' {
        $md = Invoke-Converter '<ac:structured-macro ac:name="mermaid-cloud"/>'
        $md | Should -Match '<!--'
    }
}

# =============================================================================
# Status macro  (handleStatusMacro)
# Upstream source: (no direct equivalent; custom tests)
# =============================================================================
Describe 'Status macro (ac:structured-macro name=status)' -Tag 'Custom' {
    It 'emits green emoji and title for colour=green' {
        $html = '<ac:structured-macro ac:name="status"><ac:parameter ac:name="title">Done</ac:parameter><ac:parameter ac:name="colour">green</ac:parameter></ac:structured-macro>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '🟢'
        $md   | Should -Match '\*\*Done\*\*'
    }

    It 'emits red emoji for colour=red' {
        $html = '<ac:structured-macro ac:name="status"><ac:parameter ac:name="title">Blocked</ac:parameter><ac:parameter ac:name="colour">red</ac:parameter></ac:structured-macro>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '🔴'
    }

    It 'emits bracketed title when colour is unrecognised' {
        $html = '<ac:structured-macro ac:name="status"><ac:parameter ac:name="title">Custom</ac:parameter></ac:structured-macro>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '\[\*\*Custom\*\*\]|\*\*\[Custom\]\*\*'
    }
}

# =============================================================================
# Blockquote / info macros  (handleBlockquoteMacro)
# Upstream source: (no direct equivalent; custom tests)
# =============================================================================
Describe 'Info / Note / Warning / Tip macros' -Tag 'Custom' {
    It 'wraps info content in a blockquote with emoji prefix' {
        $html = '<ac:structured-macro ac:name="info"><ac:rich-text-body><p>Some info</p></ac:rich-text-body></ac:structured-macro>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '(?m)^> ℹ️'
        $md   | Should -Match 'Some info'
    }

    It 'wraps warning content with the warning emoji' {
        $html = '<ac:structured-macro ac:name="warning"><ac:rich-text-body><p>Danger</p></ac:rich-text-body></ac:structured-macro>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '⚠️'
    }

    It 'wraps note content with the note emoji' {
        $html = '<ac:structured-macro ac:name="note"><ac:rich-text-body><p>Take note</p></ac:rich-text-body></ac:structured-macro>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '📝'
    }

    It 'wraps tip content with the tip emoji' {
        $html = '<ac:structured-macro ac:name="tip"><ac:rich-text-body><p>Pro tip</p></ac:rich-text-body></ac:structured-macro>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '💡'
    }
}

# =============================================================================
# Inline comment marker  (handleInlineComment)
# Upstream source: (no direct equivalent; custom tests)
# =============================================================================
Describe 'Inline comment marker (ac:inline-comment-marker)' -Tag 'Custom' {
    It 'preserves the text and appends a comment-ref HTML comment' {
        $html = '<ac:inline-comment-marker ac:ref="abc123">highlighted text</ac:inline-comment-marker>'
        $md   = Invoke-Converter $html
        $md   | Should -Match 'highlighted text'
        $md   | Should -Match '<!-- comment-ref: abc123 -->'
    }

    It 'preserves text when ref is absent' {
        $md = Invoke-Converter '<ac:inline-comment-marker>plain text</ac:inline-comment-marker>'
        $md | Should -Match 'plain text'
    }
}

# =============================================================================
# Placeholder  (handlePlaceholder)
# Upstream source: (no direct equivalent; custom tests)
# =============================================================================
Describe 'Placeholder (ac:placeholder)' -Tag 'Custom' {
    It 'converts placeholder text to an HTML comment' {
        $md = Invoke-Converter '<ac:placeholder>Enter description here</ac:placeholder>'
        $md | Should -Match '<!-- Enter description here -->'
    }
}

# =============================================================================
# Time element  (handleTime)
# Upstream source: (no direct equivalent; custom tests)
# =============================================================================
Describe 'Time element handling' -Tag 'Custom' {
    It 'replaces a time element with its datetime attribute value' {
        $md = Invoke-Converter '<time datetime="2024-06-01">some label</time>'
        $md | Should -Match '2024-06-01'
    }
}

# =============================================================================
# ac:link  (handleLink)
# Upstream source: (no direct equivalent; custom tests)
# =============================================================================
Describe 'Link handling (ac:link)' -Tag 'Custom' {
    It 'converts user mentions to @user format using account-id as fallback' {
        $html = '<ac:link><ri:user ri:account-id="abc123"/></ac:link>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '@user\(abc123\)'
    }

    It 'uses link body text for user mentions when available' {
        $html = '<ac:link><ri:user ri:account-id="abc123"/><ac:plain-text-link-body>Jane Doe</ac:plain-text-link-body></ac:link>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '@Jane Doe'
    }

    It 'emits the visible label text for page links (no page-ID available in storage format)' {
        $html = '<ac:link><ri:page ri:content-title="My Page"/><ac:plain-text-link-body>See here</ac:plain-text-link-body></ac:link>'
        $md   = Invoke-Converter $html
        $md   | Should -Match 'See here'
        # Must not emit the raw storage XML
        $md   | Should -Not -Match '<ac:link'
        $md   | Should -Not -Match 'ri:page'
    }
}

# =============================================================================
# Table handling  (handleTable)
# Upstream source: confluence_test.go :: TestCellHasComplexContent (ported from cell detection)
# =============================================================================
Describe 'Table handling' -Tag 'Upstream' {
    # Upstream: TestCellHasComplexContent – "simple paragraph" → not complex
    It 'converts a simple table with a header row to Markdown' {
        $html = '<table><tbody><tr><th>Name</th><th>Value</th></tr><tr><td>Foo</td><td>Bar</td></tr></tbody></table>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '\| Name'
        $md   | Should -Match '\|---'
        $md   | Should -Match '\| Foo'
    }

    # Upstream: TestCellHasComplexContent – "multiple paragraphs" → complex
    It 'flattens multi-paragraph cells to a single line' {
        $html = '<table><tbody><tr><th>Key</th><th>Notes</th></tr><tr><td>A</td><td><p>First</p><p>Second</p></td></tr></tbody></table>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '\|'
        # The complex cell should be flattened (no raw <p> tags remain)
        $md   | Should -Not -Match '<p>'
    }

    It 'adds a separator row after a header-only first row' {
        $html = '<table><tbody><tr><th>Col1</th><th>Col2</th></tr><tr><td>v1</td><td>v2</td></tr></tbody></table>'
        $md   = Invoke-Converter $html
        # Separator appears exactly once
        ($md -split "`n" | Where-Object { $_ -match '^\|---' }).Count | Should -Be 1
    }
}

# =============================================================================
# Nested list handling
# Upstream source: converter_test.go :: TestConverterPostprocessMarkdown
#                  ("fix nested list spacing" case)
# =============================================================================
Describe 'List handling' -Tag 'Upstream' {
    # Upstream: TestConverterPostprocessMarkdown – "fix nested list spacing"
    It 'converts a nested unordered list with correct indentation' {
        $html = '<ul><li>A<ul><li>A1</li><li>A2</li></ul></li><li>B</li></ul>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '(?m)^- A'
        $md   | Should -Match '(?m)^\s+- A1'
        $md   | Should -Match '(?m)^\s+- A2'
        $md   | Should -Match '(?m)^- B'
    }

    It 'converts an ordered list with sequential numbers' {
        $html = '<ol><li>First</li><li>Second</li><li>Third</li></ol>'
        $md   = Invoke-Converter $html
        $md   | Should -Match '1\. First'
        $md   | Should -Match '2\. Second'
        $md   | Should -Match '3\. Third'
    }
}

# =============================================================================
# Postprocessing: blank-line collapsing and link rewriting
# Upstream source: converter_test.go :: TestConverterPostprocessMarkdown
#                  converter_test.go :: TestFixMarkdownLinks
#                  converter_test.go :: TestFixNestedListSpacing
# =============================================================================
Describe 'Postprocessing' -Tag 'Upstream' {
    # Upstream: TestConverterPostprocessMarkdown – "collapse blank lines"
    It 'collapses 3+ consecutive blank lines to at most 2' {
        $html = "<p>line1</p>`n`n`n`n<p>line2</p>"
        $md   = Invoke-Converter $html
        $md   | Should -Not -Match "`n{4}"
    }

    # Upstream: TestFixMarkdownLinks
    It 'rewrites /wiki/spaces/.../pages/{ID}/... links to confluence://pageId/{ID}' {
        $html = '<p>See <a href="/wiki/spaces/SPACE/pages/12345/Some-Page">Page</a></p>'
        $md   = Invoke-Converter $html
        $md   | Should -Match 'confluence://pageId/12345'
    }

    # Upstream: TestFixNestedListSpacing
    It 'removes blank lines between nested list items' {
        # Generate HTML that will produce nested list spacing gaps
        $html = '<ul><li>Item<ul><li>Nested</li></ul></li></ul>'
        $md   = Invoke-Converter $html
        # After postprocessing there should be no blank line between parent and child bullet
        $md   | Should -Not -Match '- Item\n\n\s+- Nested'
    }

    # Upstream: TestConverterPostprocessMarkdown – "trim whitespace"
    It 'trims leading and trailing whitespace from the output' {
        $md = Invoke-Converter '<p>   content   </p>'
        $md.Trim() | Should -Match 'content'
    }
}

# =============================================================================
# Standard HTML element conversion
# Upstream source: (no direct upstream equivalent; custom tests for the
# HTML→Markdown base layer which mirrors html-to-markdown/v2 behaviour)
# =============================================================================
Describe 'Standard HTML conversion' -Tag 'Custom' {
    It 'converts h1-h6 headings to # marks' {
        $md = Invoke-Converter '<h1>Title</h1><h2>Sub</h2><h3>Section</h3>'
        $md | Should -Match '(?m)^# Title'
        $md | Should -Match '(?m)^## Sub'
        $md | Should -Match '(?m)^### Section'
    }

    It 'converts <strong>/<b> to bold markdown' {
        $md = Invoke-Converter '<p><strong>Bold</strong> and <b>also bold</b></p>'
        $md | Should -Match '\*\*Bold\*\*'
        $md | Should -Match '\*\*also bold\*\*'
    }

    It 'converts <em>/<i> to italic markdown' {
        $md = Invoke-Converter '<p><em>Italic</em> and <i>also italic</i></p>'
        $md | Should -Match '\*Italic\*'
        $md | Should -Match '\*also italic\*'
    }

    It 'converts hyperlinks to markdown link syntax' {
        $md = Invoke-Converter '<a href="https://example.com">Click here</a>'
        $md | Should -Match '\[Click here\]\(https://example\.com\)'
    }

    It 'converts inline <code> to backtick syntax' {
        $md = Invoke-Converter '<p>Use <code>Get-Item</code> cmdlet</p>'
        $md | Should -Match '`Get-Item`'
    }

    It 'converts <pre> blocks to fenced code blocks' {
        $md = Invoke-Converter '<pre><code>some code here</code></pre>'
        $md | Should -Match '```'
        $md | Should -Match 'some code here'
    }

    It 'converts <hr> to a horizontal rule' {
        $md = Invoke-Converter '<p>Before</p><hr/><p>After</p>'
        $md | Should -Match '---'
    }

    It 'converts <del>/<s> to strikethrough markdown' {
        $md = Invoke-Converter '<del>removed</del>'
        $md | Should -Match '~~removed~~'
    }

    It 'converts <blockquote> content to > prefix lines' {
        $md = Invoke-Converter '<blockquote><p>Quoted text</p></blockquote>'
        $md | Should -Match '^> '
    }

    It 'produces correct output for a basic paragraph' {
        $md = Invoke-Converter '<p>Hello World</p>'
        $md | Should -Match 'Hello World'
        $md | Should -Not -Match '<p>'
        $md | Should -Not -Match '</p>'
    }

    It 'HTML-decodes entities in text content' {
        $md = Invoke-Converter '<p>&lt;tag&gt; &amp; &quot;quoted&quot;</p>'
        $md | Should -Match '<tag>'
        $md | Should -Match '&'
        $md | Should -Match '"quoted"'
    }
}

# =============================================================================
# Full page conversion (integration)
# Upstream source: converter_test.go :: TestConverterConvertPage
# =============================================================================
Describe 'Full page conversion' -Tag 'Upstream' {
    # Upstream: TestConverterConvertPage – "success" case
    It 'converts a page with text and an image reference' {
        $html = '<p>Hello World</p><ac:image ri:filename="diagram.png"></ac:image>'
        $md   = Invoke-Converter $html
        $md   | Should -Match 'Hello World'
        $md   | Should -Match 'diagram\.png'
    }
}

# =============================================================================
# unsupported macro  (fallback)
# Upstream source: (no direct equivalent; custom test)
# =============================================================================
Describe 'Unsupported macros' -Tag 'Custom' {
    It 'emits an unsupported macro HTML comment' {
        $md = Invoke-Converter '<ac:structured-macro ac:name="unknown-thing"/>'
        $md | Should -Match '<!-- Unsupported macro: unknown-thing -->'
    }
}

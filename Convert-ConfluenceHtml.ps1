<#
.SYNOPSIS
    Converts a Confluence HTML (storage-format) file to Markdown.
.DESCRIPTION
    PowerShell port of jackchuka/confluence-md (Go).
    Mirrors the conversion pipeline in:
      internal/converter/processing.go   (preprocessCDATA, postprocessMarkdown,
                                          fixMarkdownLinks, fixNestedListSpacing)
      internal/converter/plugin/confluence.go  (handleMacro and sub-handlers,
                                                handleImage, handleEmoticon,
                                                handleLink, handleInlineComment,
                                                handlePlaceholder, handleTime,
                                                handleTable)
      internal/converter/plugin/utils.go  (extractCodeContent,
                                           extractLanguageParameter)
.PARAMETER InputFile
    Path to the Confluence storage-format HTML input file.
.PARAMETER OutputFile
    Path to write the Markdown output.
.PARAMETER ImageFolder
    Relative folder name used when referencing downloaded images in the output.
    Defaults to 'assets' (same default as the upstream --image-folder flag).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [string]$ImageFolder = 'assets'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# CDATA preprocessing
# Port of: internal/converter/processing.go :: preprocessCDATA()
# Converts <![CDATA[...]]> sections to <pre data-cdata='true'>...</pre> so
# the rest of the pipeline can treat the content as escaped HTML text.
# ---------------------------------------------------------------------------
function Invoke-PreprocessCDATA ([string]$Html) {
    $pattern = [regex] '<!\[CDATA\[([\s\S]*?)\]\]>'
    return $pattern.Replace($Html, {
        param($m)
        $content = $m.Groups[1].Value
        $content = $content.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
        "<pre data-cdata='true'>$content</pre>"
    })
}

# ---------------------------------------------------------------------------
# Code-content extraction helpers
# Port of: internal/converter/plugin/utils.go :: extractLanguageParameter()
#           internal/converter/plugin/utils.go :: extractCodeContent()
#           internal/converter/plugin/confluence.go :: extractPlainTextBodyContent()
# ---------------------------------------------------------------------------

# Extracts the language value from <ac:parameter ac:name="language">...</ac:parameter>
function Get-MacroLanguage ([string]$MacroHtml) {
    $m = [regex]::Match($MacroHtml, '<ac:parameter[^>]*ac:name="language"[^>]*>([^<]+)</ac:parameter>')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

# Extracts the value of any named ac:parameter element.
function Get-MacroParameter ([string]$MacroHtml, [string]$Name) {
    $escaped = [regex]::Escape($Name)
    $m = [regex]::Match($MacroHtml, "<ac:parameter[^>]*ac:name=`"$escaped`"[^>]*>([^<]+)</ac:parameter>")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

# Returns the plain-text code content from inside an ac:structured-macro.
# Handles three representations that may appear after preprocessCDATA:
#   1. <pre data-cdata='true'>...html-escaped...</pre>  (output of preprocessCDATA)
#   2. <!--[CDATA[...]]-->  (goquery's serialisation of CDATA)
#   3. <![CDATA[...]]>      (raw storage format)
function Get-PlainTextBody ([string]$MacroHtml) {
    # Narrow search to the ac:plain-text-body region first.
    $bodyM = [regex]::Match($MacroHtml, '<ac:plain-text-body[^>]*>([\s\S]*?)</ac:plain-text-body>')
    $region = if ($bodyM.Success) { $bodyM.Groups[1].Value } else { $MacroHtml }

    # Case 1: preprocessCDATA already ran → <pre data-cdata='true'>...</pre>
    $preM = [regex]::Match($region, "<pre data-cdata='true'>([\s\S]*?)</pre>")
    if ($preM.Success) {
        $code = $preM.Groups[1].Value
        $code = $code.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&amp;', '&')
        return $code.Trim()
    }

    # Cases 2 & 3: extract raw content and strip CDATA wrappers
    $content = [System.Net.WebUtility]::HtmlDecode($region)
    $content = $content -replace '^<!--\[CDATA\[', ''
    $content = $content -replace '\]\]-->$', ''
    $content = $content -replace '^<!\[CDATA\[', ''
    $content = $content -replace '\]\]>$', ''
    return $content.Trim()
}

# ---------------------------------------------------------------------------
# Rich-text-body extraction
# Used by blockquote macros (info/warning/note/tip) and expand/details.
# Port of: confluence.go :: convertNestedHTML() / findRichTextBodyNode()
# ---------------------------------------------------------------------------
function Get-RichTextBodyContent ([string]$MacroHtml) {
    $m = [regex]::Match($MacroHtml, '<ac:rich-text-body[^>]*>([\s\S]*?)</ac:rich-text-body>')
    if (-not $m.Success) { return '' }
    # Recursively convert the inner HTML with the same pipeline.
    return (Invoke-ConvertHtml $m.Groups[1].Value).Trim()
}

# ---------------------------------------------------------------------------
# Confluence macro handler
# Port of: confluence.go :: handleMacro() and each sub-handler
# ---------------------------------------------------------------------------
function Convert-ConfluenceMacro ([string]$MacroHtml) {
    $nameM = [regex]::Match($MacroHtml, 'ac:name="([^"]+)"')
    $macroName = if ($nameM.Success) { $nameM.Groups[1].Value } else { 'unknown' }

    $fence = '```'

    switch ($macroName) {
        # --- handleCodeMacro() -----------------------------------------------
        'code' {
            $lang = Get-MacroLanguage $MacroHtml
            $code = Get-PlainTextBody $MacroHtml
            if ($lang) { return "${fence}${lang}`n${code}`n${fence}`n" }
            return "${fence}`n${code}`n${fence}`n"
        }

        # --- handleBlockquoteMacro() -----------------------------------------
        'info'    { return Convert-BlockquoteMacro $MacroHtml 'ℹ️'  'Info'    }
        'warning' { return Convert-BlockquoteMacro $MacroHtml '⚠️'  'Warning' }
        'note'    { return Convert-BlockquoteMacro $MacroHtml '📝'  'Note'    }
        'tip'     { return Convert-BlockquoteMacro $MacroHtml '💡'  'Tip'     }

        # --- handleMermaidMacro() --------------------------------------------
        # The converter script has no API client, so it cannot fetch mermaid
        # attachment content (same comment as the upstream when client is nil).
        'mermaid-cloud' {
            $filename = Get-MacroParameter $MacroHtml 'filename'
            if (-not $filename) { return '<!-- Mermaid macro missing filename -->' }
            return "<!-- Mermaid attachment $filename unavailable -->"
        }

        # --- handleExpandMacro() / handleDetailsMacro() ----------------------
        'expand'  {
            $content = Get-RichTextBodyContent $MacroHtml
            if ($content) { return "$content`n`n" }
            return ''
        }
        'details' {
            $content = Get-RichTextBodyContent $MacroHtml
            if ($content) { return "$content`n`n" }
            return ''
        }

        # --- handleTocMacro() ------------------------------------------------
        'toc' { return '<!-- Table of Contents -->' }

        # --- handleStatusMacro() ---------------------------------------------
        'status' {
            $title  = Get-MacroParameter $MacroHtml 'title'
            $colour = Get-MacroParameter $MacroHtml 'colour'
            $emoji  = switch ($colour.ToLower()) {
                'red'                      { '🔴' }
                'yellow'                   { '🟡' }
                'green'                    { '🟢' }
                'blue'                     { '🔵' }
                { $_ -in 'grey', 'gray' }  { '⚪' }
                default                    { ''   }
            }
            if ($title) {
                if ($emoji) { return "$emoji **$title**" }
                return "**[$title]**"
            }
            return ''
        }

        'children' { return '<!-- Child Pages -->' }

        default { return "<!-- Unsupported macro: $macroName -->" }
    }
}

# Port of: confluence.go :: handleBlockquoteMacro()
function Convert-BlockquoteMacro ([string]$MacroHtml, [string]$Emoji, [string]$Label) {
    $content = Get-RichTextBodyContent $MacroHtml
    $prefix  = "$Emoji **${Label}:**"

    if (-not $content) { return "> $prefix" }

    $lines = $content -split "`n"
    if ($lines.Count -gt 1) {
        $result = "> $prefix`n"
        foreach ($line in $lines) {
            if ($line.Trim()) { $result += "> $line`n" }
            else              { $result += ">`n"       }
        }
        return $result.TrimEnd("`n")
    }
    return "> $prefix $content"
}

# ---------------------------------------------------------------------------
# ac:image → markdown image
# Port of: confluence.go :: handleImage()
# Output format: ![filename](imageFolder/url-encoded-filename)
# ---------------------------------------------------------------------------
function Convert-ConfluenceImages ([string]$Html) {
    $pattern = [regex] '<ac:image[^>]*>([\s\S]*?)</ac:image>'
    return $pattern.Replace($Html, {
        param($m)
        $fnM = [regex]::Match($m.Value, 'ri:filename="([^"]+)"')
        if (-not $fnM.Success) { return '<!-- Image attachment not found -->' }
        $filename = $fnM.Groups[1].Value
        # Port of: url.PathEscape(localPath) where localPath = imageFolder + "/" + filename
        $encoded  = [Uri]::EscapeDataString($filename)
        $localPath = "$ImageFolder/$encoded"
        "![$filename]($localPath)"
    })
}

# ---------------------------------------------------------------------------
# ac:emoticon → emoji text
# Port of: confluence.go :: handleEmoticon()
# Priority order: ac:emoji-fallback → ac:emoji-shortname → ac:name → :emoji:
# ---------------------------------------------------------------------------
function Convert-ConfluenceEmoticons ([string]$Html) {
    # Use />  (self-closing) as one alternative so the > is fully consumed.
    $pattern = [regex] '<ac:emoticon([^>/]*)(?:/>|>[\s\S]*?</ac:emoticon>)'
    return $pattern.Replace($Html, {
        param($m)
        $attrs = $m.Groups[1].Value
        $em = [regex]::Match($attrs, 'ac:emoji-fallback="([^"]+)"')
        if ($em.Success) { return $em.Groups[1].Value + ' ' }
        $em = [regex]::Match($attrs, 'ac:emoji-shortname="([^"]+)"')
        if ($em.Success) { return $em.Groups[1].Value + ' ' }
        $em = [regex]::Match($attrs, 'ac:name="([^"]+)"')
        if ($em.Success) { return ':' + $em.Groups[1].Value + ': ' }
        return ':emoji: '
    })
}

# ---------------------------------------------------------------------------
# ac:link → user mention or page link
# Port of: confluence.go :: handleLink()
# User links emit "@DisplayName"; unknown links are left for default processing.
# ---------------------------------------------------------------------------
function Convert-ConfluenceLinks ([string]$Html) {
    $pattern = [regex] '<ac:link[^>]*>([\s\S]*?)</ac:link>'
    return $pattern.Replace($Html, {
        param($m)
        $inner = $m.Groups[1].Value

        # ri:user child → @mention
        $userM = [regex]::Match($inner, 'ri:account-id="([^"]+)"')
        if ($userM.Success) {
            $accountId = $userM.Groups[1].Value
            $bodyM = [regex]::Match($inner, '<ac:plain-text-link-body[^>]*>([^<]+)</ac:plain-text-link-body>')
            if ($bodyM.Success) { return " @$($bodyM.Groups[1].Value) " }
            return " @user($accountId) "
        }

        # ri:page child → inline link
        $pageM = [regex]::Match($inner, 'ri:content-title="([^"]+)"')
        if ($pageM.Success) {
            $title = $pageM.Groups[1].Value
            $bodyM = [regex]::Match($inner, '<ac:plain-text-link-body[^>]*>([^<]+)</ac:plain-text-link-body>')
            $label = if ($bodyM.Success) { $bodyM.Groups[1].Value } else { $title }
            return "[$label]($title)"
        }

        # Anything else: keep the raw element so the standard pass can handle it.
        return $m.Value
    })
}

# ---------------------------------------------------------------------------
# ac:inline-comment-marker → text + HTML comment
# Port of: confluence.go :: handleInlineComment()
# ---------------------------------------------------------------------------
function Convert-InlineComments ([string]$Html) {
    $pattern = [regex] '<ac:inline-comment-marker[^>]*ac:ref="([^"]*)"[^>]*>([\s\S]*?)</ac:inline-comment-marker>'
    return $pattern.Replace($Html, {
        param($m)
        $ref  = $m.Groups[1].Value
        $text = $m.Groups[2].Value
        if ($ref) { return "${text}<!-- comment-ref: $ref -->" }
        return $text
    })
}

# ---------------------------------------------------------------------------
# ac:placeholder → HTML comment
# Port of: confluence.go :: handlePlaceholder()
# ---------------------------------------------------------------------------
function Convert-Placeholders ([string]$Html) {
    $pattern = [regex] '<ac:placeholder[^>]*>([\s\S]*?)</ac:placeholder>'
    return $pattern.Replace($Html, {
        param($m)
        $text = $m.Groups[1].Value.Trim()
        if ($text) { return "<!-- $text -->" }
        return ''
    })
}

# ---------------------------------------------------------------------------
# <time datetime="..."> → datetime string
# Port of: confluence.go :: handleTime()
# ---------------------------------------------------------------------------
function Convert-TimeElements ([string]$Html) {
    $pattern = [regex] '<time[^>]*datetime="([^"]*)"[^>]*>[\s\S]*?</time>'
    return $pattern.Replace($Html, {
        param($m)
        $dt = $m.Groups[1].Value
        if ($dt) { return "$dt " }
        return ''
    })
}

# ---------------------------------------------------------------------------
# Table handler
# Port of: confluence.go :: handleTable()
# Detects complex cells (multiple block elements, lists, br tags) and flattens
# them; simple cells are converted inline.  Header rows are rows where ALL
# cells are <th>.  A separator row is emitted after the first row (whether it
# is a header row or not).
# ---------------------------------------------------------------------------
function Convert-Tables ([string]$Html) {
    $tablePattern = [regex] '<table[^>]*>([\s\S]*?)</table>'
    return $tablePattern.Replace($Html, {
        param($m)
        $tableInner = $m.Groups[1].Value

        $tbodyM   = [regex]::Match($tableInner, '<tbody[^>]*>([\s\S]*?)</tbody>')
        $bodyHtml = if ($tbodyM.Success) { $tbodyM.Groups[1].Value } else { $tableInner }

        $rows        = [System.Collections.Generic.List[string[]]]::new()
        $isHeaderRow = [System.Collections.Generic.List[bool]]::new()

        $trPattern   = [regex] '<tr[^>]*>([\s\S]*?)</tr>'
        $cellPattern = [regex] '<(td|th)[^>]*>([\s\S]*?)</(td|th)>'

        foreach ($trM in $trPattern.Matches($bodyHtml)) {
            $rowHtml       = $trM.Groups[1].Value
            $cells         = [System.Collections.Generic.List[string]]::new()
            $hasOnlyTh     = $true
            $hasTd         = $false

            foreach ($cellM in $cellPattern.Matches($rowHtml)) {
                $cellType    = $cellM.Groups[1].Value.ToLower()
                $cellContent = $cellM.Groups[2].Value

                if ($cellType -eq 'td') { $hasTd = $true; $hasOnlyTh = $false }

                # Detect complex cells: lists, multiple block elements, or <br>
                # Port of: cellHasComplexContent()
                $isComplex = (
                    $cellContent -match '<(ul|ol|div|blockquote|pre|table|ac:task-list)[^>]*>' -or
                    ([regex]::Matches($cellContent, '<(p|h[1-6])[^>]*>').Count -gt 1) -or
                    $cellContent -match '<br[^>]*/?>|-containsBrTag'
                )

                if ($isComplex) {
                    # Flatten complex content: collapse block elements to spaces,
                    # strip all tags, then collapse whitespace.
                    # Port of: getCellHTMLContent() / flattenCellContent()
                    $flat = $cellContent -replace '<br[^>]*/?>',         ' '
                    $flat = $flat        -replace '</?p[^>]*>',          ' '
                    $flat = $flat        -replace '<[^>]+>',             ''
                    $flat = [System.Net.WebUtility]::HtmlDecode($flat)
                    $flat = ($flat -split '\s+' | Where-Object { $_ }) -join ' '
                    $cells.Add($(if ($flat.Trim()) { $flat.Trim() } else { ' ' }))
                } else {
                    $converted = (Invoke-ConvertHtml $cellContent).Trim()
                    $cells.Add($(if ($converted -and $converted -ne '&nbsp;') { $converted } else { ' ' }))
                }
            }

            if ($cells.Count -gt 0) {
                $rows.Add($cells.ToArray())
                $isHeaderRow.Add($hasOnlyTh -and -not $hasTd)
            }
        }

        if ($rows.Count -eq 0) { return $m.Value }

        $maxCols = ($rows | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum

        # Pad all rows to the same width
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $row = [System.Collections.Generic.List[string]] $rows[$i]
            while ($row.Count -lt $maxCols) { $row.Add(' ') }
            $rows[$i] = $row.ToArray()
        }

        $hasAnyHeader = $isHeaderRow -contains $true
        $result       = "`n"

        for ($i = 0; $i -lt $rows.Count; $i++) {
            $result += '| ' + ($rows[$i] -join ' | ') + " |`n"

            # Emit separator after header row, or after the first row when there
            # is no header row (key-value table).
            # Port of: the i==0 && isHeaderRow[0] || i==0 && !hasHeaderRow logic
            if (($i -eq 0 -and $isHeaderRow[$i]) -or ($i -eq 0 -and -not $hasAnyHeader)) {
                $result += '|' + ('---|' * $maxCols) + "`n"
            }
        }

        $result
    })
}

# ---------------------------------------------------------------------------
# List conversion helper used by the standard HTML pass.
# Processes innermost lists first (those with no nested ul/ol), then
# repeats until all levels are converted — mirroring the recursive DOM
# traversal used by html-to-markdown/v2's commonmark plugin.
# ---------------------------------------------------------------------------
function Convert-HtmlLists ([string]$Html) {
    # The inner pattern (?:(?!<ul|<ol)[\s\S])*? matches any characters that
    # do NOT start a nested <ul or <ol, guaranteeing inside-out processing.
    $changed = $true
    while ($changed) {
        $newHtml = $Html

        # Ordered lists (innermost only)
        $newHtml = [regex]::Replace($newHtml,
            '<ol[^>]*>((?:(?!<ul|<ol)[\s\S])*?)</ol>', {
            param($m)
            $idx    = 1
            $result = "`n"
            foreach ($liM in [regex]::Matches($m.Groups[1].Value, '<li[^>]*>([\s\S]*?)</li>')) {
                $raw   = [regex]::Replace($liM.Groups[1].Value, '<(?!!--)[^>]+>', '', 'Singleline')
                $raw   = [System.Net.WebUtility]::HtmlDecode($raw)
                $lines = @(($raw -split "`n") | Where-Object { $_.Trim() })
                if ($lines.Count -gt 0) {
                    $result += "$idx. $($lines[0].Trim())`n"
                    foreach ($line in ($lines | Select-Object -Skip 1)) {
                        $result += "   $($line.TrimEnd())`n"
                    }
                    $idx++
                }
            }
            $result
        }, 'IgnoreCase, Singleline')

        # Unordered lists (innermost only)
        $newHtml = [regex]::Replace($newHtml,
            '<ul[^>]*>((?:(?!<ul|<ol)[\s\S])*?)</ul>', {
            param($m)
            $result = "`n"
            foreach ($liM in [regex]::Matches($m.Groups[1].Value, '<li[^>]*>([\s\S]*?)</li>')) {
                $raw   = [regex]::Replace($liM.Groups[1].Value, '<(?!!--)[^>]+>', '', 'Singleline')
                $raw   = [System.Net.WebUtility]::HtmlDecode($raw)
                $lines = @(($raw -split "`n") | Where-Object { $_.Trim() })
                if ($lines.Count -gt 0) {
                    $result += "- $($lines[0].Trim())`n"
                    foreach ($line in ($lines | Select-Object -Skip 1)) {
                        $result += "  $($line.TrimEnd())`n"
                    }
                }
            }
            $result
        }, 'IgnoreCase, Singleline')

        $changed = ($newHtml -ne $Html)
        $Html    = $newHtml
    }
    return $Html
}

# ---------------------------------------------------------------------------
# Standard HTML → Markdown
# Port of the base + commonmark plugin from html-to-markdown/v2.
# Processes the remaining (non-Confluence) HTML elements.
# ---------------------------------------------------------------------------
function Convert-StandardHtml ([string]$Html) {
    $md = $Html

    # Headings h1-h6
    for ($level = 6; $level -ge 1; $level--) {
        $hashes = '#' * $level
        $md = [regex]::Replace($md, "<h$level[^>]*>([\s\S]*?)</h$level>",
            "`n$hashes `$1`n", 'IgnoreCase, Singleline')
    }

    # Horizontal rule
    $md = [regex]::Replace($md, '<hr[^>]*/?>',  "`n---`n", 'IgnoreCase')

    # Line breaks
    $md = [regex]::Replace($md, '<br[^>]*/?>',  "`n", 'IgnoreCase')

    # Pre blocks with CDATA marker (output of preprocessCDATA, not yet converted)
    $fence = '```'
    $md = [regex]::Replace($md, "<pre data-cdata='true'>([\s\S]*?)</pre>", {
        param($m)
        $code = $m.Groups[1].Value
        $code = $code.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&amp;', '&')
        "${fence}`n$code`n${fence}"
    }, 'IgnoreCase, Singleline')

    # Generic pre / code-block
    $md = [regex]::Replace($md, '<pre[^>]*>([\s\S]*?)</pre>', {
        param($m)
        $code = [regex]::Replace($m.Groups[1].Value, '</?code[^>]*>', '')
        $code = [System.Net.WebUtility]::HtmlDecode($code).Trim()
        "${fence}`n$code`n${fence}"
    }, 'IgnoreCase, Singleline')

    # Inline code (before bold/italic to avoid mangling)
    $md = [regex]::Replace($md, '<code[^>]*>([^<]*)</code>', '`$1`', 'IgnoreCase')

    # Bold
    $md = [regex]::Replace($md, '<(?:strong|b)[^>]*>([\s\S]*?)</(?:strong|b)>',
        '**$1**', 'IgnoreCase, Singleline')

    # Italic
    $md = [regex]::Replace($md, '<(?:em|i)[^>]*>([\s\S]*?)</(?:em|i)>',
        '*$1*', 'IgnoreCase, Singleline')

    # Strikethrough
    $md = [regex]::Replace($md, '<(?:del|s|strike)[^>]*>([\s\S]*?)</(?:del|s|strike)>',
        '~~$1~~', 'IgnoreCase, Singleline')

    # Links
    $md = [regex]::Replace($md, '<a[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>', {
        param($m)
        $href = $m.Groups[1].Value
        $text = [regex]::Replace($m.Groups[2].Value, '<[^>]+>', '')
        $text = [System.Net.WebUtility]::HtmlDecode($text).Trim()
        if ($text) { "[$text]($href)" } else { $href }
    }, 'IgnoreCase, Singleline')

    # Images (alt before src, src before alt, src only)
    $md = [regex]::Replace($md, '<img[^>]*alt="([^"]*)"[^>]*src="([^"]*)"[^>]*/?>',
        '![$1]($2)', 'IgnoreCase')
    $md = [regex]::Replace($md, '<img[^>]*src="([^"]*)"[^>]*alt="([^"]*)"[^>]*/?>',
        '![$2]($1)', 'IgnoreCase')
    $md = [regex]::Replace($md, '<img[^>]*src="([^"]*)"[^>]*/?>',
        '![]($1)', 'IgnoreCase')

    # Blockquote
    $md = [regex]::Replace($md, '<blockquote[^>]*>([\s\S]*?)</blockquote>', {
        param($m)
        $lines = $m.Groups[1].Value.Trim() -split "`n"
        ($lines | ForEach-Object { "> $_" }) -join "`n"
    }, 'IgnoreCase, Singleline')

    # Lists (ol/ul/li)
    $md = Convert-HtmlLists $md

    # Paragraphs
    $md = [regex]::Replace($md, '</p>',    "`n`n", 'IgnoreCase')
    $md = [regex]::Replace($md, '<p[^>]*>', '',   'IgnoreCase')

    # Divs
    $md = [regex]::Replace($md, '</div>',    "`n", 'IgnoreCase')
    $md = [regex]::Replace($md, '<div[^>]*>', '',  'IgnoreCase')

    # Strip all remaining HTML tags, but PRESERVE HTML comments (<!-- ... -->)
    # so that macro outputs like <!-- Table of Contents --> survive.
    $md = [regex]::Replace($md, '<(?!!--)[^>]+>', '', 'Singleline')

    # HTML entity decode
    $md = [System.Net.WebUtility]::HtmlDecode($md)

    return $md
}

# ---------------------------------------------------------------------------
# Postprocessing
# Port of: processing.go :: postprocessMarkdown()
# ---------------------------------------------------------------------------
function Invoke-PostprocessMarkdown ([string]$Markdown) {
    # Collapse 3+ consecutive blank lines to exactly two.
    $md = [regex]::Replace($Markdown, "`n{3,}", "`n`n")

    # Remove blank lines between nested list items.
    # Port of: fixNestedListSpacing()
    $listMarker = '(?:[-*+]\s|\d+\.\s)'
    $nestPat    = [regex] "(\n\s*$listMarker[^\n]*)\n\s*\n(\s{2,}$listMarker)"
    $prev       = ''
    while ($prev -ne $md) {
        $prev = $md
        $md   = $nestPat.Replace($md, "`$1`n`$2")
    }

    # Rewrite Confluence page links to internal references.
    # Port of: fixMarkdownLinks()
    $md = [regex]::Replace($md,
        '\[([^\]]+)\]\(/wiki/spaces/([^/]+)/pages/(\d+)/[^)]+\)',
        '[${1}](confluence://pageId/${3})')

    return $md.Trim()
}

# ---------------------------------------------------------------------------
# Top-level conversion pipeline
# Port of: processing.go :: convertHtml()
# ---------------------------------------------------------------------------
function Invoke-ConvertHtml ([string]$Html) {
    # Step 1: Preprocess CDATA → <pre data-cdata='true'>
    $h = Invoke-PreprocessCDATA $Html

    # Step 2: Handle Confluence structured macros (self-closing and block forms)
    $h = [regex]::Replace($h, '<ac:structured-macro[^>]*/>', {
        param($m) Convert-ConfluenceMacro $m.Value
    }, 'IgnoreCase')
    $h = [regex]::Replace($h, '<ac:structured-macro[^>]*>([\s\S]*?)</ac:structured-macro>', {
        param($m) Convert-ConfluenceMacro $m.Value
    }, 'IgnoreCase, Singleline')

    # Step 3: ac:image → ![filename](imageFolder/filename)
    $h = Convert-ConfluenceImages $h

    # Step 4: ac:emoticon → emoji text
    $h = Convert-ConfluenceEmoticons $h

    # Step 5: ac:link → @user or page link
    $h = Convert-ConfluenceLinks $h

    # Step 6: ac:inline-comment-marker → text + <!-- comment-ref -->
    $h = Convert-InlineComments $h

    # Step 7: ac:placeholder → <!-- text -->
    $h = Convert-Placeholders $h

    # Step 8: <time datetime="..."> → datetime string
    $h = Convert-TimeElements $h

    # Step 9: Tables (before general HTML so cells can be introspected)
    $h = Convert-Tables $h

    # Step 10: Standard HTML elements → Markdown
    return Convert-StandardHtml $h
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
    throw "Input file not found: $InputFile"
}

$inputPath = (Resolve-Path -LiteralPath $InputFile).Path
$outputDir = Split-Path -Path $OutputFile -Parent
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$html     = Get-Content -LiteralPath $inputPath -Raw -Encoding UTF8
$markdown = Invoke-ConvertHtml $html
$markdown = Invoke-PostprocessMarkdown $markdown

Set-Content -LiteralPath $OutputFile -Value ($markdown + "`n") -Encoding UTF8
Write-Host "Markdown written to: $OutputFile"

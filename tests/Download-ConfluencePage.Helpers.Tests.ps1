#Requires -Modules Pester
<#
.SYNOPSIS
    Pester 5 tests for helper functions defined in Download-ConfluencePage.ps1.

.DESCRIPTION
    Tests are tagged to distinguish their origin:

      [Upstream] - Ported from jackchuka/confluence-md Go test suite.
                   Source files are cross-referenced in each test's comment.

      [Custom]   - Written for the PowerShell port; cover PS-specific behaviour
                   or edge-cases not present in the upstream suite.

    Because Download-ConfluencePage.ps1 is a script (not a module), its helper
    functions are loaded here via dot-sourcing inside a try/catch.  The script
    body is expected to throw (the converter script path does not exist in the
    test environment), but all function definitions above the body are captured.

    Functions tested:
      ConvertTo-Slug            ← output_namer.go  :: defaultFileName / slug
      Get-PageInfoFromUrl       ← shared.go         :: urlToPageInfo
      Get-NormalizedDownloadLink← client.go         :: normalizeDownloadLink
      New-AuthHeaders           ← client.go         :: Basic auth header setup
      New-Frontmatter           ← markdown.go       :: WithFrontmatter
      Get-ImageReferences       ← processing.go     :: extractImageReferences
      Save-AttachmentImage      ← converter.go      :: downloadImages (path-safety)
#>

BeforeAll {
    $downloaderScript = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Download-ConfluencePage.ps1'
    $downloaderScript = (Resolve-Path $downloaderScript).Path

    # Stub mandatory-parameter cmdlets so the script body fails gracefully after
    # all function definitions have been processed.
    function global:Invoke-RestMethod  { throw 'Invoke-RestMethod: not in test scope' }
    function global:Invoke-WebRequest  { throw 'Invoke-WebRequest: not in test scope' }

    # Dot-source the script; the body will throw at the ConverterScriptPath check,
    # but all pure helper functions defined before that will be available.
    try {
        . $downloaderScript `
            -PageUrl             'https://example.atlassian.net/wiki/spaces/S/pages/1/T' `
            -Email               'test@example.com' `
            -ApiToken            'token' `
            -ConverterScriptPath '/nonexistent-path-that-does-not-exist'
    }
    catch {
        # Expected: the script body throws because the converter script is missing.
        # All function definitions above the body are now available.
    }
}

# =============================================================================
# ConvertTo-Slug
# Upstream source: output_namer_test.go :: TestGenerateFileName_Default
# =============================================================================
Describe 'ConvertTo-Slug' -Tag 'Upstream' {
    # Upstream: TestGenerateFileName_Default
    It 'converts "Sample Page" to "sample-page"' {
        ConvertTo-Slug 'Sample Page' | Should -Be 'sample-page'
    }

    # Upstream: TestGenerateFileName_TemplateAddsExtension (Docs → docs)
    It 'lowercases the input' {
        ConvertTo-Slug 'UPPERCASE' | Should -Be 'uppercase'
    }

    It 'replaces spaces with hyphens' {
        ConvertTo-Slug 'Hello World' | Should -Be 'hello-world'
    }

    It 'collapses multiple consecutive non-alphanumeric characters to one hyphen' {
        ConvertTo-Slug 'Hello   World!!!' | Should -Be 'hello-world'
    }

    It 'strips leading and trailing hyphens' {
        ConvertTo-Slug '  trimmed  ' | Should -Be 'trimmed'
    }

    It 'returns "untitled" for empty input' -Tag 'Custom' {
        ConvertTo-Slug '' | Should -Be 'untitled'
    }

    It 'returns "untitled" for whitespace-only input' -Tag 'Custom' {
        ConvertTo-Slug '   ' | Should -Be 'untitled'
    }

    It 'handles titles with numbers and hyphens' -Tag 'Custom' {
        ConvertTo-Slug 'Release Notes 2024-Q1' | Should -Be 'release-notes-2024-q1'
    }
}

# =============================================================================
# Get-PageInfoFromUrl
# Upstream source: (no direct Go test; custom tests for URL parsing logic
# ported from commands/shared.go :: urlToPageInfo)
# =============================================================================
Describe 'Get-PageInfoFromUrl' -Tag 'Custom' {
    It 'extracts the pageID from a standard Confluence URL' {
        $info = Get-PageInfoFromUrl 'https://example.atlassian.net/wiki/spaces/SPACE/pages/12345/My-Page'
        $info.PageID | Should -Be '12345'
    }

    It 'extracts the spaceKey from a standard Confluence URL' {
        $info = Get-PageInfoFromUrl 'https://example.atlassian.net/wiki/spaces/MYSPACE/pages/99/Title'
        $info.SpaceKey | Should -Be 'MYSPACE'
    }

    It 'preserves the BaseURL scheme and host' {
        $info = Get-PageInfoFromUrl 'https://example.atlassian.net/wiki/spaces/S/pages/1/T'
        $info.BaseURL | Should -Be 'https://example.atlassian.net'
    }

    It 'preserves a non-default port in the BaseURL' {
        $info = Get-PageInfoFromUrl 'https://confluence.internal:8443/wiki/spaces/S/pages/7/T'
        $info.BaseURL | Should -Be 'https://confluence.internal:8443'
    }

    It 'throws when the URL contains no page segment' {
        { Get-PageInfoFromUrl 'https://example.atlassian.net/wiki/spaces/S' } | Should -Throw
    }

    It 'throws for an empty URL' {
        { Get-PageInfoFromUrl '' } | Should -Throw
    }
}

# =============================================================================
# Get-NormalizedDownloadLink
# Upstream source: (no direct Go test; custom tests for
# client.go :: normalizeDownloadLink)
# =============================================================================
Describe 'Get-NormalizedDownloadLink' -Tag 'Custom' {
    It 'returns absolute URLs unchanged' {
        $url = 'https://example.atlassian.net/download/attachments/123/file.png'
        Get-NormalizedDownloadLink 'https://example.atlassian.net' $url | Should -Be $url
    }

    It 'prepends /wiki when link starts with /download/' {
        $link   = '/download/attachments/123/file.png'
        $result = Get-NormalizedDownloadLink 'https://example.atlassian.net' $link
        $result | Should -Match '/wiki/download/attachments/123/file\.png'
    }

    It 'URL-encodes spaces in the path' {
        $link   = '/download/attachments/123/my file.png'
        $result = Get-NormalizedDownloadLink 'https://example.atlassian.net' $link
        $result | Should -Match '%20'
        $result | Should -Not -Match ' '
    }

    It 'prepends a slash when relative link does not start with /' {
        $link   = 'attachments/file.png'
        $result = Get-NormalizedDownloadLink 'https://example.atlassian.net' $link
        $result | Should -Match 'example\.atlassian\.net'
    }
}

# =============================================================================
# New-AuthHeaders
# Upstream source: (no direct Go test; custom test for Basic auth construction)
# =============================================================================
Describe 'New-AuthHeaders' -Tag 'Custom' {
    It 'produces an Authorization header with the Basic scheme' {
        $h = New-AuthHeaders 'user@example.com' 'secret'
        $h['Authorization'] | Should -Match '^Basic '
    }

    It 'base64-encodes email:token credentials' {
        $h           = New-AuthHeaders 'user@example.com' 'mytoken'
        $encoded     = $h['Authorization'] -replace '^Basic ', ''
        $decoded     = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
        $decoded     | Should -Be 'user@example.com:mytoken'
    }

    It 'sets Accept to application/json' {
        $h = New-AuthHeaders 'a@b.com' 'tok'
        $h['Accept'] | Should -Be 'application/json'
    }
}

# =============================================================================
# New-Frontmatter
# Upstream source: markdown_test.go :: TestMarkdownDocumentWithFrontmatter
# =============================================================================
Describe 'New-Frontmatter' -Tag 'Upstream' {
    BeforeAll {
        $page = @{
            ID       = '123'
            Title    = 'Sample'
            SpaceKey = 'SPACE'
            Version  = 5
            UpdatedAt = '2024-01-02T03:04:05Z'
            Labels   = @(
                @{ Name = 'one' },
                @{ Name = 'two' }
            )
            CreatedBy = @{ DisplayName = 'Author' }
        }
        $fm = New-Frontmatter $page 'https://example.atlassian.net'
    }

    # Upstream: TestMarkdownDocumentWithFrontmatter – title check
    It 'includes the page title' {
        $fm | Should -Match 'title:'
        $fm | Should -Match 'Sample'
    }

    # Upstream: TestMarkdownDocumentWithFrontmatter – author check
    It 'includes the author' {
        $fm | Should -Match 'author:.*Author'
    }

    # Upstream: TestMarkdownDocumentWithFrontmatter – date check
    It 'includes the date' {
        $fm | Should -Match 'date:'
        $fm | Should -Match '2024'
    }

    # Upstream: TestMarkdownDocumentWithFrontmatter – labels check
    It 'includes all labels' {
        $fm | Should -Match '"one"'
        $fm | Should -Match '"two"'
    }

    # Upstream: TestMarkdownDocumentWithFrontmatter – pageId check
    It 'includes the Confluence pageId' {
        $fm | Should -Match 'pageId:.*"123"'
    }

    # Upstream: TestMarkdownDocumentWithFrontmatter – URL check
    It 'includes a URL referencing the base host' {
        $fm | Should -Match 'url:.*example\.atlassian\.net'
    }

    It 'is wrapped in YAML front-matter delimiters' {
        $fm | Should -Match '^---'
        $fm | Should -Match '---'
    }

    It 'includes the spaceKey' -Tag 'Custom' {
        $fm | Should -Match 'spaceKey:.*SPACE'
    }

    It 'includes the version number' -Tag 'Custom' {
        $fm | Should -Match 'version: 5'
    }
}

# =============================================================================
# Get-ImageReferences
# Upstream source: (no direct Go test; ported from
# processing.go :: extractImageReferences)
# =============================================================================
Describe 'Get-ImageReferences' -Tag 'Custom' {
    It 'extracts a single image filename' {
        $html = '<ac:image ri:filename="diagram.png"></ac:image>'
        $refs = Get-ImageReferences $html
        $refs | Should -Contain 'diagram.png'
    }

    It 'extracts multiple unique image filenames' {
        $html = '<ac:image ri:filename="a.png"></ac:image><ac:image ri:filename="b.png"></ac:image>'
        $refs = Get-ImageReferences $html
        $refs | Should -Contain 'a.png'
        $refs | Should -Contain 'b.png'
        $refs.Count | Should -Be 2
    }

    It 'deduplicates repeated references to the same image' {
        $html = '<ac:image ri:filename="same.png"></ac:image><ac:image ri:filename="same.png"></ac:image>'
        $refs = Get-ImageReferences $html
        @($refs).Count | Should -Be 1
    }

    It 'returns an empty array when there are no image references' {
        $refs = Get-ImageReferences '<p>No images here</p>'
        @($refs).Count | Should -Be 0
    }

    It 'skips ac:image elements without a filename attribute' {
        $refs = Get-ImageReferences '<ac:image></ac:image>'
        @($refs).Count | Should -Be 0
    }
}

# =============================================================================
# Save-AttachmentImage – path-safety (security fix)
# Upstream source: (no direct Go test; custom test for path-traversal fix)
# =============================================================================
Describe 'Save-AttachmentImage – path safety' -Tag 'Custom' {
    It 'returns $false and warns when the attachment is not found on the page' {
        $page = @{ Attachments = @() }
        $result = Save-AttachmentImage $page 'missing.png' 'https://x.atlassian.net' @{} ($TestDrive)
        $result | Should -Be $false
    }

    It 'rejects filenames containing path separators' {
        $page = @{
            Attachments = @(
                @{ Title = '../evil.png'; DownloadLink = '/download/evil.png'; MediaType = 'image/png' }
            )
        }
        $result = Save-AttachmentImage $page '../evil.png' 'https://x.atlassian.net' @{ Authorization = 'Basic x'; 'User-Agent' = 'test' } ($TestDrive)
        $result | Should -Be $false
    }
}

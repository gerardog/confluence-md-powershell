[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-HtmlToMarkdown {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html
    )

    $markdown = $Html
    $markdown = [regex]::Replace($markdown, '<\s*script[^>]*>.*?<\s*/\s*script\s*>', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<\s*style[^>]*>.*?<\s*/\s*style\s*>', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<h1[^>]*>(.*?)</h1>', "`n# `$1`n", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<h2[^>]*>(.*?)</h2>', "`n## `$1`n", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<h3[^>]*>(.*?)</h3>', "`n### `$1`n", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<h4[^>]*>(.*?)</h4>', "`n#### `$1`n", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<h5[^>]*>(.*?)</h5>', "`n##### `$1`n", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<h6[^>]*>(.*?)</h6>', "`n###### `$1`n", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<\s*br\s*/?\s*>', "`n", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $markdown = [regex]::Replace($markdown, '<\s*/\s*p\s*>', "`n`n", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $markdown = [regex]::Replace($markdown, '<\s*p[^>]*>', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $markdown = [regex]::Replace($markdown, '<\s*strong[^>]*>(.*?)<\s*/\s*strong\s*>', '**$1**', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<\s*b[^>]*>(.*?)<\s*/\s*b\s*>', '**$1**', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<\s*em[^>]*>(.*?)<\s*/\s*em\s*>', '*$1*', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<\s*i[^>]*>(.*?)<\s*/\s*i\s*>', '*$1*', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<a[^>]*href\s*=\s*["'']([^"'']+)["''][^>]*>(.*?)</a>', '[$2]($1)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<img[^>]*alt\s*=\s*["'']([^"'']*)["''][^>]*src\s*=\s*["'']([^"'']+)["''][^>]*>', '![$1]($2)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $markdown = [regex]::Replace($markdown, '<img[^>]*src\s*=\s*["'']([^"'']+)["''][^>]*alt\s*=\s*["'']([^"'']*)["''][^>]*>', '![$2]($1)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $markdown = [regex]::Replace($markdown, '<\s*li[^>]*>(.*?)<\s*/\s*li\s*>', "- `$1`n", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [regex]::Replace($markdown, '<\s*/?\s*(ul|ol)[^>]*>', "`n", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $markdown = [regex]::Replace($markdown, '<[^>]+>', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $markdown = [System.Net.WebUtility]::HtmlDecode($markdown)
    $markdown = [regex]::Replace($markdown, "[`t ]+`n", "`n")
    $markdown = [regex]::Replace($markdown, "`n{3,}", "`n`n")
    return $markdown.Trim() + "`n"
}

if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
    throw "Input file not found: $InputFile"
}

$inputPath = (Resolve-Path -LiteralPath $InputFile).Path
$outputDirectory = Split-Path -Path $OutputFile -Parent

if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$html = Get-Content -LiteralPath $inputPath -Raw -Encoding UTF8
$markdown = Convert-HtmlToMarkdown -Html $html
Set-Content -LiteralPath $OutputFile -Value $markdown -Encoding UTF8

Write-Host "Markdown written to: $OutputFile"

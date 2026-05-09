[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PageUrl,

    [Parameter(Mandatory = $true)]
    [string]$Email,

    [Parameter(Mandatory = $true)]
    [string]$ApiToken,

    [string]$OutputDir = '.',

    [string]$HtmlFileName = 'page.html',

    [string]$MarkdownFileName = 'page.md',

    [string]$ConverterScriptPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Convert-ConfluenceHtml.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfluencePageIdFromUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $match = [regex]::Match($Url, '/pages/(\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "Unable to find page ID in URL: $Url"
    }

    return $match.Groups[1].Value
}

function Get-ConfluenceApiBaseUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $uri = [System.Uri]$Url
    return '{0}://{1}/wiki' -f $uri.Scheme, $uri.Host
}

if (-not (Test-Path -LiteralPath $ConverterScriptPath -PathType Leaf)) {
    throw "Converter script not found at: $ConverterScriptPath"
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$pageId = Get-ConfluencePageIdFromUrl -Url $PageUrl
$apiBase = Get-ConfluenceApiBaseUrl -Url $PageUrl
$requestUrl = '{0}/rest/api/content/{1}?expand=body.storage' -f $apiBase, $pageId

$basicAuth = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$Email`:$ApiToken"))
$headers = @{
    Authorization = "Basic $basicAuth"
    Accept        = 'application/json'
}

$response = Invoke-RestMethod -Method Get -Uri $requestUrl -Headers $headers

if (-not $response.body.storage.value) {
    throw "Confluence API returned no HTML content for page ID $pageId."
}

$htmlOutputPath = Join-Path -Path $OutputDir -ChildPath $HtmlFileName
$markdownOutputPath = Join-Path -Path $OutputDir -ChildPath $MarkdownFileName

Set-Content -LiteralPath $htmlOutputPath -Value $response.body.storage.value -Encoding UTF8

& $ConverterScriptPath -InputFile $htmlOutputPath -OutputFile $markdownOutputPath

Write-Host "Downloaded HTML to: $htmlOutputPath"
Write-Host "Converted Markdown to: $markdownOutputPath"

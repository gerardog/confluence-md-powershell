<#
.SYNOPSIS
    Downloads a Confluence page and converts it to Markdown.
.DESCRIPTION
    PowerShell port of jackchuka/confluence-md (Go).
    Mirrors the behaviour of:
      cmd/confluence-md/commands/page.go    (runPage)
      cmd/confluence-md/commands/shared.go  (urlToPageInfo, convertSinglePage,
                                             printConversionResult)
      internal/confluence/client.go         (NewClient, GetPage,
                                             DownloadAttachmentContent,
                                             normalizeDownloadLink)
      internal/confluence/model/api.go      (ConvertAPIPageToModel)
      internal/converter/model/markdown.go  (NewMarkdownDocument, WithFrontmatter)
      internal/converter/output_namer.go    (defaultFileName / slug)
      internal/converter/processing.go      (extractImageReferences)
.PARAMETER PageUrl
    Full Confluence Cloud page URL, e.g.
    https://example.atlassian.net/wiki/spaces/SPACE/pages/12345/Title
.PARAMETER Email
    Confluence user e-mail address used for Basic authentication.
.PARAMETER ApiToken
    Confluence API token (generate at id.atlassian.com).
.PARAMETER OutputDir
    Directory to write the Markdown file and images into.  Defaults to './output'
    (same default as the upstream --output flag).
.PARAMETER ImageFolder
    Sub-folder inside OutputDir used for downloaded images.  Defaults to 'assets'
    (same default as the upstream --image-folder flag).
.PARAMETER DownloadImages
    When $true (default) attached images referenced by <ac:image> elements are
    downloaded into ImageFolder.
.PARAMETER IncludeMetadata
    When $true (default) a YAML frontmatter block is prepended to the Markdown
    output.
.PARAMETER ConverterScriptPath
    Path to Convert-ConfluenceHtml.ps1.  Defaults to the sibling script in the
    same directory as this script.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PageUrl,

    [Parameter(Mandatory = $true)]
    [string]$Email,

    [Parameter(Mandatory = $true)]
    [string]$ApiToken,

    [string]$OutputDir    = './output',
    [string]$ImageFolder  = 'assets',
    [bool]  $DownloadImages  = $true,
    [bool]  $IncludeMetadata = $true,

    [string]$ConverterScriptPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Convert-ConfluenceHtml.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Slug helper
# Port of: gosimple/slug :: MakeLang(text, "en")
# Used by defaultFileName() in output_namer.go
# ---------------------------------------------------------------------------
function ConvertTo-Slug ([string]$Text) {
    if (-not $Text.Trim()) { return 'untitled' }
    $slug = $Text.ToLower()
    $slug = [regex]::Replace($slug, '[^a-z0-9]+', '-')
    $slug = $slug.Trim('-')
    if (-not $slug) { return 'untitled' }
    return $slug
}

# ---------------------------------------------------------------------------
# URL parsing
# Port of: commands/shared.go :: urlToPageInfo()
# Extracts BaseURL, SpaceKey, PageID, and Title from a Confluence page URL.
# Path format: /wiki/spaces/{SPACE}/pages/{ID}/{Title}
# ---------------------------------------------------------------------------
function Get-PageInfoFromUrl ([string]$Url) {
    if (-not $Url) { throw 'Page URL is empty.' }

    $uri     = [System.Uri] $Url
    # Use Authority (host+port) to preserve non-default ports.
    # Port of: commands/shared.go :: urlToPageInfo() – fmt.Sprintf("%s://%s", u.Scheme, u.Host)
    # Note: Go's u.Host includes the port when non-default; [System.Uri].Authority does too.
    $baseURL = "$($uri.Scheme)://$($uri.Authority)"

    $parts    = $uri.AbsolutePath -split '/'
    $pageID   = ''
    $spaceKey = ''
    $title    = ''

    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -eq 'spaces' -and $i + 1 -lt $parts.Count) {
            $spaceKey = $parts[$i + 1]
        }
        if ($parts[$i] -eq 'pages' -and $i + 1 -lt $parts.Count) {
            $pageID = $parts[$i + 1]
        }
    }
    if ($parts.Count -gt 0) { $title = $parts[-1] }

    if (-not $pageID) { throw "Could not extract page ID from URL: $Url" }

    return @{
        BaseURL  = $baseURL
        SpaceKey = $spaceKey
        PageID   = $pageID
        Title    = $title
    }
}

# ---------------------------------------------------------------------------
# Download-link normalisation
# Port of: client.go :: normalizeDownloadLink()
# ---------------------------------------------------------------------------
function Get-NormalizedDownloadLink ([string]$BaseUrl, [string]$Link) {
    if ($Link -match '^https?://') { return $Link }

    if (-not $Link.StartsWith('/')) { $Link = '/' + $Link }
    if ($Link.StartsWith('/download/')) { $Link = '/wiki' + $Link }
    if ($Link.StartsWith('download/'))  { $Link = '/wiki/' + $Link }
    $Link = $Link.Replace(' ', '%20')

    $full   = $BaseUrl.TrimEnd('/') + $Link
    $parsed = [System.Uri] $full
    return $parsed.AbsoluteUri
}

# ---------------------------------------------------------------------------
# Build Basic-auth headers
# Port of: client.go – req.SetBasicAuth() and header setup
# Uses UTF-8 encoding for the credential payload (RFC 7617 recommendation).
# ---------------------------------------------------------------------------
function New-AuthHeaders ([string]$Email, [string]$ApiToken) {
    $credentials = [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes("${Email}:${ApiToken}")
    )
    return @{
        Authorization = "Basic $credentials"
        Accept        = 'application/json'
        'User-Agent'  = 'ConfluenceMd/ps'
    }
}

# ---------------------------------------------------------------------------
# Fetch page from Confluence REST API
# Port of: client.go :: GetPage()
# Expand set mirrors the upstream: body.storage, metadata.labels, version,
# space, history, children.attachment
# ---------------------------------------------------------------------------
function Get-ConfluencePage ([string]$BaseUrl, [string]$PageID, [hashtable]$Headers) {
    $expand = 'body.storage,metadata.labels,version,space,history,children.attachment'
    $apiUrl = "$BaseUrl/wiki/rest/api/content/$PageID`?expand=$expand"
    $r      = Invoke-RestMethod -Method Get -Uri $apiUrl -Headers $Headers -ErrorAction Stop

    # Port of: model/api.go :: ConvertAPIPageToModel()
    # Guard against missing metadata/labels nodes (API change, permission differences)
    $labels = @()
    $labelResults = if ($null -ne $r.PSObject.Properties['metadata'] -and
                        $null -ne $r.metadata.PSObject.Properties['labels'] -and
                        $null -ne $r.metadata.labels.PSObject.Properties['results']) {
        $r.metadata.labels.results
    } else { @() }
    foreach ($lbl in $labelResults) {
        $labels += @{ ID = $lbl.id; Name = $lbl.name }
    }

    # Guard against missing children/attachment nodes
    $attachments = @()
    $attachResults = if ($null -ne $r.PSObject.Properties['children'] -and
                         $null -ne $r.children.PSObject.Properties['attachment'] -and
                         $null -ne $r.children.attachment.PSObject.Properties['results']) {
        $r.children.attachment.results
    } else { @() }
    foreach ($att in $attachResults) {
        $attachments += @{
            ID           = $att.id
            Title        = $att.title
            MediaType    = $att.extensions.mediaType
            FileSize     = $att.extensions.fileSize
            DownloadLink = $att._links.download
            Version      = $att.version.number
        }
    }

    return @{
        ID          = $r.id
        Title       = $r.title
        SpaceKey    = $r.space.key
        Version     = $r.version.number
        UpdatedAt   = $r.version.when
        CreatedAt   = $r.history.createdDate
        HtmlContent = $r.body.storage.value
        Labels      = $labels
        Attachments = $attachments
        CreatedBy   = @{
            AccountID   = $r.history.createdBy.accountId
            DisplayName = $r.history.createdBy.displayName
            Email       = $r.history.createdBy.email
        }
        UpdatedBy   = @{
            AccountID   = $r.version.by.accountId
            DisplayName = $r.version.by.displayName
            Email       = $r.version.by.email
        }
    }
}

# ---------------------------------------------------------------------------
# YAML frontmatter
# Port of: model/markdown.go :: WithFrontmatter()
# ---------------------------------------------------------------------------
function New-Frontmatter ([hashtable]$Page, [string]$BaseUrl) {
    $spaceKey = $Page.SpaceKey
    $pageId   = $Page.ID
    $title    = $Page.Title
    $encoded  = [Uri]::EscapeDataString($title)
    $pageUrl  = "$BaseUrl/wiki/spaces/$spaceKey/pages/$pageId/$encoded"
    $author   = $Page.CreatedBy.DisplayName

    $date = ''
    if ($Page.UpdatedAt) {
        $date = [datetime]$Page.UpdatedAt | Get-Date -Format 'o'
    }

    $fm  = "---`n"
    $fm += "title: `"$($title.Replace('"','\"'))`"`n"
    $fm += "author: `"$($author.Replace('"','\"'))`"`n"
    $fm += "date: `"$date`"`n"

    if ($Page.Labels.Count -gt 0) {
        $fm += "labels:`n"
        foreach ($lbl in $Page.Labels) {
            $fm += "  - `"$($lbl.Name.Replace('"','\"'))`"`n"
        }
    }

    $fm += "confluence:`n"
    $fm += "  pageId: `"$pageId`"`n"
    $fm += "  spaceKey: `"$spaceKey`"`n"
    $fm += "  version: $($Page.Version)`n"
    $fm += "  url: `"$pageUrl`"`n"
    $fm += "---`n`n"
    return $fm
}

# ---------------------------------------------------------------------------
# Extract image attachment filenames referenced in Confluence HTML
# Port of: converter/processing.go :: extractImageReferences()
# ---------------------------------------------------------------------------
function Get-ImageReferences ([string]$Html) {
    $refs    = @()
    $pattern = [regex] '<ac:image[^>]*>([\s\S]*?)</ac:image>'
    foreach ($m in $pattern.Matches($Html)) {
        $fnM = [regex]::Match($m.Value, 'ri:filename="([^"]+)"')
        if ($fnM.Success) { $refs += $fnM.Groups[1].Value }
    }
    return @($refs | Select-Object -Unique)
}

# ---------------------------------------------------------------------------
# Download one attachment image to disk
# Port of: client.go :: DownloadAttachmentContent() and
#           converter.go :: downloadImages()
# ---------------------------------------------------------------------------
function Save-AttachmentImage (
    [hashtable] $Page,
    [string]    $Filename,
    [string]    $BaseUrl,
    [hashtable] $Headers,
    [string]    $DestDir
) {
    # Port of: attachments/resolver.go :: selectAttachment()
    $attachment = $Page.Attachments |
        Where-Object { $_.Title -ieq $Filename } |
        Select-Object -First 1

    if (-not $attachment) {
        Write-Warning "Attachment not found on page: $Filename"
        return $false
    }

    $downloadUrl = Get-NormalizedDownloadLink $BaseUrl $attachment.DownloadLink

    $dlHeaders = @{
        Authorization = $Headers['Authorization']
        Accept        = '*/*'
        'User-Agent'  = $Headers['User-Agent']
    }

    # Sanitize filename to a safe leaf name, preventing path traversal.
    # Port of: converter.go :: downloadImages() – saves files by attachment title only.
    $safeFilename = [System.IO.Path]::GetFileName($Filename)
    if (-not $safeFilename -or $safeFilename -ne $Filename) {
        Write-Warning "Skipping unsafe attachment filename: $Filename"
        return $false
    }

    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    $destPath = Join-Path -Path $DestDir -ChildPath $safeFilename
    Invoke-WebRequest -Uri $downloadUrl -Headers $dlHeaders -OutFile $destPath -ErrorAction Stop
    Write-Host "  📥 Downloaded image: $Filename"
    return $true
}

# ---------------------------------------------------------------------------
# Main workflow
# Port of: commands/page.go :: runPage() + shared.go :: convertSinglePage()
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ConverterScriptPath -PathType Leaf)) {
    throw "Converter script not found at: $ConverterScriptPath"
}

$pageInfo = Get-PageInfoFromUrl $PageUrl
$baseUrl  = $pageInfo.BaseURL
$pageID   = $pageInfo.PageID

$headers = New-AuthHeaders $Email $ApiToken

Write-Host "Fetching page $pageID from $baseUrl ..."
$page = Get-ConfluencePage $baseUrl $pageID $headers

# Port of: output_namer.go :: defaultFileName()
$slug     = ConvertTo-Slug $page.Title
$fileName = "$slug.md"

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$outputPath = Join-Path -Path $OutputDir -ChildPath $fileName

# Write storage HTML to a temp file and run the converter script.
# GetTempFileName() creates the temp file; use it directly to avoid leaking a second file.
$tmpHtml = [System.IO.Path]::GetTempFileName()
try {
    Set-Content -LiteralPath $tmpHtml -Value $page.HtmlContent -Encoding UTF8

    & $ConverterScriptPath `
        -InputFile   $tmpHtml `
        -OutputFile  $outputPath `
        -ImageFolder $ImageFolder
}
finally {
    if (Test-Path -LiteralPath $tmpHtml) { Remove-Item -LiteralPath $tmpHtml -Force }
}

# Optionally prepend YAML frontmatter
# Port of: converter/writer.go :: SaveMarkdownDocument() with withFrontmatter=true
if ($IncludeMetadata) {
    $body        = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8
    $frontmatter = New-Frontmatter $page $baseUrl
    Set-Content -LiteralPath $outputPath -Value ($frontmatter + $body) -Encoding UTF8
}

# Optionally download referenced attachment images
# Port of: converter.go :: downloadImages() + processing.go :: extractImageReferences()
$imagesDownloaded = 0
if ($DownloadImages) {
    $imageDest = Join-Path -Path $OutputDir -ChildPath $ImageFolder
    $refs      = Get-ImageReferences $page.HtmlContent

    foreach ($filename in $refs) {
        if (Save-AttachmentImage $page $filename $baseUrl $headers $imageDest) {
            $imagesDownloaded++
        }
    }
}

# Port of: shared.go :: printConversionResult()
Write-Host ''
Write-Host "✅ Successfully converted page: $outputPath"
Write-Host "   Page ID: $pageID"
Write-Host "   Title:   $($page.Title)"
if ($imagesDownloaded -gt 0) {
    Write-Host "   📥 Images downloaded: $imagesDownloaded"
}
Write-Host ''

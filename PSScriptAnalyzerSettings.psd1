@{
    # Suppress Write-Host warnings — it is used intentionally for progress output
    # in interactive scripts (Convert-ConfluenceHtml.ps1, Download-ConfluencePage.ps1).
    ExcludeRules = @('PSAvoidUsingWriteHost')
}

<#
.SYNOPSIS
    Runs the Pester 5 test suite for the confluence-md-powershell scripts.

.DESCRIPTION
    Tests are tagged to indicate their origin:

      Upstream - Ported from the upstream jackchuka/confluence-md Go test suite.
                 See upstream/confluence-md/**/*_test.go for the source tests.

      Custom   - Written specifically for the PowerShell port; cover PS-specific
                 behaviour, edge-cases not present in the upstream suite, or
                 integration aspects unique to this wrapper.

.PARAMETER Tags
    Run only tests matching the specified tags. Valid values: Upstream, Custom.
    When omitted all tests are run.

.PARAMETER TestPath
    Root directory containing the .Tests.ps1 files. Defaults to './tests'.

.EXAMPLE
    # Run all tests
    ./tests/Run-Tests.ps1

.EXAMPLE
    # Run only tests ported from the upstream Go test suite
    ./tests/Run-Tests.ps1 -Tags Upstream

.EXAMPLE
    # Run only tests we authored for the PowerShell port
    ./tests/Run-Tests.ps1 -Tags Custom
#>
[CmdletBinding()]
param(
    [ValidateSet('Upstream', 'Custom')]
    [string[]] $Tags,

    [string] $TestPath = (Join-Path -Path $PSScriptRoot -ChildPath '.')
)

$pesterModule = Get-Module -Name Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pesterModule) {
    Write-Error "Pester module not found. Install it with: Install-Module Pester -Force"
    exit 1
}

Import-Module Pester -MinimumVersion '5.0.0' -Force

$config = New-PesterConfiguration
$config.Run.Path = $TestPath
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'TestResults.xml'

if ($Tags) {
    $config.Filter.Tag = $Tags
    Write-Host "Running tests tagged: $($Tags -join ', ')"
} else {
    Write-Host "Running all tests (Upstream + Custom)"
}

$result = Invoke-Pester -Configuration $config

Write-Host ""
Write-Host "---------------------------------------------"
if ($null -ne $result) {
    Write-Host "  Tests passed:  $($result.PassedCount)"
    Write-Host "  Tests failed:  $($result.FailedCount)"
    Write-Host "  Tests skipped: $($result.SkippedCount)"
    if ($result.FailedCount -gt 0) {
        Write-Host "---------------------------------------------"
        exit 1
    }
}
Write-Host "---------------------------------------------"

[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "", Justification = "Test doubles preserve production command signatures.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidOverwritingBuiltInCmdlets", "", Justification = "The process lookup is replaced with an isolated deterministic test double.")]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root '.github/scripts/Invoke-CandidatePplBuild.ps1')

function Assert-Failure {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $false
    try { & $Action } catch {
        $caught = $true
        if ($_.Exception.Message -notlike $Pattern) { throw }
    }
    if (-not $caught) { throw "Expected failure matching '$Pattern'." }
}

$script:responses = @()
$script:buildCalls = [System.Collections.Generic.List[object]]::new()
$script:labviewRunning = $true
function Invoke-ProducerVipmBuildOnce {
    param($Arguments, $WorkingDirectory, $OutputDirectory, $Attempt)
    $script:buildCalls.Add([pscustomobject]@{ Attempt = $Attempt; Arguments = @($Arguments); WorkingDirectory = $WorkingDirectory; OutputDirectory = $OutputDirectory })
    return $script:responses[$script:buildCalls.Count - 1]
}
function Get-Process {
    param($Name, $ErrorAction)
    if ($Name -eq 'LabVIEW' -and $script:labviewRunning) { [pscustomobject]@{ Name = $Name } }
}

$arguments = @('--labview-version', '2026', '--labview-bitness', '64', 'build', 'Dependencies.lvproj')
$script:responses = @(
    [pscustomobject]@{ ExitCode = 1; Output = 'Build failed (code 1130): Call By Reference'; LogPaths = @() },
    [pscustomobject]@{ ExitCode = 0; Output = 'Build succeeded'; LogPaths = @() }
)
$result = Invoke-ProducerVipmBuild -Arguments $arguments -WorkingDirectory 'fixture' -OutputDirectory 'output'
if ($result.ExitCode -ne 0 -or $script:buildCalls.Count -ne 2 -or $script:buildCalls[1].Attempt -ne 2 -or
    $script:buildCalls[0].OutputDirectory -cne 'output') {
    throw 'A cold-start code 1130 was not retried exactly once.'
}

$script:buildCalls.Clear()
$script:responses = @([pscustomobject]@{ ExitCode = 1; Output = 'Build failed (code 1130): Call By Reference'; LogPaths = @() })
$script:labviewRunning = $false
$result = Invoke-ProducerVipmBuild -Arguments $arguments -WorkingDirectory 'fixture' -OutputDirectory 'output'
if ($result.ExitCode -ne 1 -or $script:buildCalls.Count -ne 1) { throw 'Code 1130 was retried without a running LabVIEW process.' }

$script:buildCalls.Clear()
$script:responses = @([pscustomobject]@{ ExitCode = 1; Output = 'App Builder error 1003'; LogPaths = @() })
$script:labviewRunning = $true
$result = Invoke-ProducerVipmBuild -Arguments $arguments -WorkingDirectory 'fixture' -OutputDirectory 'output'
if ($result.ExitCode -ne 1 -or $script:buildCalls.Count -ne 1) { throw 'A non-1130 build failure was retried.' }

$script:buildCalls.Clear()
$script:responses = @(
    [pscustomobject]@{ ExitCode = 1; Output = 'Build failed (code 1130): Call By Reference'; LogPaths = @() },
    [pscustomobject]@{ ExitCode = 1; Output = 'App Builder error 1003'; LogPaths = @() }
)
Assert-Failure {
    $result = Invoke-ProducerVipmBuild -Arguments $arguments -WorkingDirectory 'fixture' -OutputDirectory 'output'
    if ($result.ExitCode -ne 0) { throw 'VIPM candidate build failed after the bounded retry.' }
} '*bounded retry*'
if ($script:buildCalls.Count -ne 2) { throw 'A failed 1130 retry was not bounded to one retry.' }

$workflow = [System.IO.File]::ReadAllText((Join-Path $root '.github/workflows/build-lvlibp-candidate.yml'))
if (-not $workflow.Contains("Invoke-ProducerVipmBuild -Arguments `$buildArguments")) {
    throw 'The producer candidate workflow must use the bounded build helper.'
}
Write-Output 'PASS: producer PPL build retry is restricted to one cold-start 1130 retry.'
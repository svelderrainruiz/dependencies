[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "", Justification = "Test doubles preserve production command signatures.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidOverwritingBuiltInCmdlets", "", Justification = "Process command doubles replace external process behavior deterministically.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "The test double returns an in-memory process object and never launches a process.")]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root '.github/scripts/Invoke-CandidatePplBuild.ps1')
$script:productionBuildOnce = (Get-Command -Name Invoke-ProducerVipmBuildOnce -CommandType Function).ScriptBlock

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
function Get-Command {
    param($Name, $CommandType, $ErrorAction)
    if ($Name -eq 'vipm') { return [pscustomobject]@{ Source = 'vipm.exe' } }
    return Microsoft.PowerShell.Core\Get-Command -Name $Name -CommandType $CommandType -ErrorAction $ErrorAction
}
function Start-Process {
    param($FilePath, $ArgumentList, $WorkingDirectory, [switch]$NoNewWindow, $RedirectStandardOutput, $RedirectStandardError, [switch]$PassThru)
    return $script:timeoutProcess
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
$script:responses = @([pscustomobject]@{
    ExitCode = 124
    Output = 'VIPM timed out after a code 1130 response.'
    LogPaths = @()
    TimedOut = $true
    TimeoutSeconds = 1800
})
$result = Invoke-ProducerVipmBuild -Arguments $arguments -WorkingDirectory 'fixture' -OutputDirectory 'output'
if ($result.ExitCode -ne 124 -or -not $result.TimedOut -or $script:buildCalls.Count -ne 1) {
    throw 'A timed-out VIPM process was retried or lost its timeout result.'
}

$script:timeoutProcess = [pscustomobject]@{
    Id = 1234
    ExitCode = 0
    Killed = $false
    WaitCalls = [System.Collections.Generic.List[int]]::new()
}
$script:timeoutProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    param([int]$Milliseconds)
    $null = $this.WaitCalls.Add($Milliseconds)
    return $this.Killed
}
$script:timeoutProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value {
    param([bool]$EntireProcessTree)
    $this.Killed = $EntireProcessTree
}
$timeoutResponse = & $script:productionBuildOnce -Arguments $arguments -WorkingDirectory 'fixture' `
    -OutputDirectory 'output' -Attempt 1 -TimeoutSeconds 1
if (-not $timeoutResponse.TimedOut -or $timeoutResponse.ExitCode -ne 124 -or
    -not $script:timeoutProcess.Killed -or $script:timeoutProcess.WaitCalls[0] -ne 1000 -or
    $script:timeoutProcess.WaitCalls[1] -ne 10000) {
    throw "The VIPM process timeout did not terminate and reap the full process tree: timedOut=$($timeoutResponse.TimedOut), exitCode=$($timeoutResponse.ExitCode), killed=$($script:timeoutProcess.Killed), waits=$($script:timeoutProcess.WaitCalls -join ',')."
}

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
$timeoutGuard = $workflow.IndexOf('if ($buildResult.TimedOut)', [System.StringComparison]::Ordinal)
$diagnosticSbom = $workflow.IndexOf('$diagnosticSbomPath', [System.StringComparison]::Ordinal)
if ($timeoutGuard -lt 0 -or $diagnosticSbom -lt 0 -or $timeoutGuard -gt $diagnosticSbom) {
    throw 'The producer candidate workflow must skip the diagnostic SBOM scan when VIPM times out.'
}
$diagnosticUploadCondition = "if: always() && (steps.build.outcome == 'failure' || steps.build.outcome == 'cancelled')"
if (-not $workflow.Contains($diagnosticUploadCondition)) {
    throw 'The producer candidate workflow must upload diagnostics when the build step is canceled.'
}
Write-Output 'PASS: producer PPL build has a bounded process wait and retries only a cold-start 1130.'
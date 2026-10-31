function Invoke-ProducerVipmBuildOnce {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][int]$Attempt
    )

    $vipmPath = (Get-Command vipm -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $argumentLine = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
    }) -join ' '
    $stdoutPath = Join-Path $OutputDirectory "vipm-build-attempt-$Attempt.stdout.log"
    $stderrPath = Join-Path $OutputDirectory "vipm-build-attempt-$Attempt.stderr.log"
    $process = Start-Process -FilePath $vipmPath -ArgumentList $argumentLine -WorkingDirectory $WorkingDirectory -NoNewWindow `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    $output = @($stdout, $stderr | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace($output)) { Write-Host $output }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
        LogPaths = @($stdoutPath, $stderrPath)
    }
}

function Invoke-ProducerVipmBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $response = Invoke-ProducerVipmBuildOnce -Arguments $Arguments -WorkingDirectory $WorkingDirectory `
            -OutputDirectory $OutputDirectory -Attempt $attempt
        if ($response.ExitCode -eq 0) {
            foreach ($path in @($response.LogPaths)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            }
            return $response
        }
        $labviewRunning = @(Get-Process -Name LabVIEW -ErrorAction SilentlyContinue).Count -gt 0
        if ($attempt -eq 1 -and $response.Output -match '\(code 1130\)' -and $labviewRunning) {
            Write-Warning 'VIPM build failed with code 1130 after launching LabVIEW; retrying once with LabVIEW already running.'
            continue
        }
        return $response
    }
    throw 'VIPM build retry loop terminated unexpectedly.'
}
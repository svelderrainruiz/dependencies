[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root '.github/scripts/Assert-CandidateSbomPackage.ps1')

function Assert-Failure {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $false
    try { & $Action } catch {
        $caught = $true
        if ($_.Exception.Message -notlike $Pattern) { throw }
    }
    if (-not $caught) { throw "Expected failure matching '$Pattern'." }
}

$packageName = 'jdp_science_lib_common_utilities'
$packageRef = 'pkg:vipm/jdp_science_lib_common_utilities@1.4.2.19'
$parentRef = 'pkg:vipm/jdp_science_jsontext@1.9.1.125'
$inventory = [pscustomobject]@{ dependencies = @(
        [pscustomobject]@{ name = 'jdp_science_jsontext'; installed_version = '1.9.1.125'; status = 'installed' },
        [pscustomobject]@{ name = $packageName; installed_version = '1.4.2.19'; status = 'installed' },
        [pscustomobject]@{ name = 'unused_installed_package'; installed_version = '2.0'; status = 'installed' }
    ) }
$sbom = [pscustomobject]@{
    metadata = [pscustomobject]@{ component = [pscustomobject]@{ 'bom-ref' = 'ppl' } }
    components = @([pscustomobject]@{ 'bom-ref' = $parentRef; name = 'jdp_science_jsontext'; version = '1.9.1.125'; purl = $parentRef })
    dependencies = @([pscustomobject]@{ ref = 'ppl'; dependsOn = @($parentRef) })
}
$jsonTextFile = 'C:\Program Files\National Instruments\LabVIEW 2026\vi.lib\JDP Science\JSONtext\JSON Value.vi'
$commonFile = 'C:\Program Files\National Instruments\LabVIEW 2026\vi.lib\JDP Science\JDP Science Common Utilities\Cluster to Array of Variants.vi'
$sourceLogPath = Join-Path ([System.IO.Path]::GetTempPath()) ("producer-source-log-" + [guid]::NewGuid())
try {
    [System.IO.File]::WriteAllLines($sourceLogPath, @(
            '[Source Files]'
            "$jsonTextFile  10/31/2026 6:00:00 PM 1"
            "$commonFile 10/31/2026 6:00:00 PM 1"
            'C:\workspace\dependencies\src\dependencies.lvlib  10/31/2026 6:00:00 PM 1.0.0.0'
            '[Output File Version]'
        ), [System.Text.UTF8Encoding]::new($false))
    $sourceFiles = Read-ProducerPplSourceFile -BuildLogPath $sourceLogPath
} finally {
    if (Test-Path -LiteralPath $sourceLogPath) { Remove-Item -LiteralPath $sourceLogPath -Force }
}
$script:ownershipFiles = @{
    jdp_science_jsontext = @($jsonTextFile)
    jdp_science_lib_common_utilities = @($commonFile)
    unused_installed_package = @('C:\Program Files\NI\unrelated\unused.vi')
}
$script:inventoryQueries = [System.Collections.Generic.List[string]]::new()
function vipm {
    $name = [string]$args[6]
    $script:inventoryQueries.Add($name)
    $global:LASTEXITCODE = 0
    @{ installed_files = @($script:ownershipFiles[$name] | ForEach-Object { @{ path = $_ } }) } | ConvertTo-Json -Depth 5
}
$packageFiles = Get-ProducerVipmPackageFileInventory -Inventory $inventory
if (($script:inventoryQueries -join ',') -cne 'jdp_science_jsontext,jdp_science_lib_common_utilities,unused_installed_package') {
    throw 'VIPM installed-file lookup did not query each exact inventory package.'
}
$requiredPackages = @($packageName)

Assert-Failure {
    Assert-ProducerSbomCoverage -Sbom $sbom -Inventory $inventory -PackageFiles $packageFiles `
        -SourceFiles $sourceFiles -RequiredPackages $requiredPackages
} '*jdp_science_lib_common_utilities*1.4.2.19*'
$manifestSbom = [pscustomobject]@{
    bomFormat = 'CycloneDX'; specVersion = '1.5'
    components = @(
        $sbom.components[0]
        [pscustomobject]@{
            'bom-ref' = $packageRef; name = $packageName; version = '1.4.2.19'; purl = $packageRef
            licenses = @([pscustomobject]@{ license = [pscustomobject]@{ id = 'BSD-3-Clause' } })
        }
    )
}
$sourcePackages = Get-ProducerPplVipmSourcePackage -Inventory $inventory -PackageFiles $packageFiles `
    -SourceFiles $sourceFiles -RequiredPackages $requiredPackages
$mergedSbom = $sbom | ConvertTo-Json -Depth 20 | ConvertFrom-Json
Merge-ProducerSbomVipmSourceComponent -Sbom $mergedSbom -ManifestSbom $manifestSbom `
    -SourcePackages $sourcePackages | Out-Null
Assert-ProducerSbomCoverage -Sbom $mergedSbom -Inventory $inventory -PackageFiles $packageFiles `
    -SourceFiles $sourceFiles -RequiredPackages $requiredPackages | Out-Null
$mergedComponent = @($mergedSbom.components | Where-Object { $_.purl -ceq $packageRef })[0]
if ($mergedComponent.licenses[0].license.id -cne 'BSD-3-Clause' -or
    @($mergedSbom.dependencies[0].dependsOn) -notcontains $packageRef) {
    throw 'Manifest SBOM enrichment must preserve component metadata and link source-owned packages to the PPL.'
}
$missingManifestSbom = [pscustomobject]@{
    bomFormat = 'CycloneDX'; specVersion = '1.5'; components = @($sbom.components[0])
}
Assert-Failure {
    $copy = $sbom | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    Merge-ProducerSbomVipmSourceComponent -Sbom $copy -ManifestSbom $missingManifestSbom -SourcePackages $sourcePackages
} '*jdp_science_lib_common_utilities*1.4.2.19*manifest SBOM*'
$wrongManifestSbom = [pscustomobject]@{
    bomFormat = 'CycloneDX'; specVersion = '1.5'
    components = @(
        $sbom.components[0]
        [pscustomobject]@{ 'bom-ref' = 'wrong'; name = $packageName; version = '1.4.2.20'; purl = 'pkg:vipm/jdp_science_lib_common_utilities@1.4.2.20' }
    )
}
Assert-Failure {
    $copy = $sbom | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    Merge-ProducerSbomVipmSourceComponent -Sbom $copy -ManifestSbom $wrongManifestSbom -SourcePackages $sourcePackages
} '*jdp_science_lib_common_utilities*1.4.2.19*manifest SBOM*'
$sbom.components += [pscustomobject]@{ 'bom-ref' = $packageRef; name = $packageName; version = '1.4.2.19'; purl = $packageRef }
Assert-Failure {
    Assert-ProducerSbomCoverage -Sbom $sbom -Inventory $inventory -PackageFiles $packageFiles `
        -SourceFiles $sourceFiles -RequiredPackages $requiredPackages
} '*not reachable*'
$sbom.dependencies += [pscustomobject]@{ ref = $parentRef; dependsOn = @($packageRef) }
$sourcePackages = Assert-ProducerSbomCoverage -Sbom $sbom -Inventory $inventory -PackageFiles $packageFiles `
    -SourceFiles $sourceFiles -RequiredPackages $requiredPackages
if ($sourcePackages.Count -ne 2 -or $sourcePackages.ContainsKey('unused_installed_package')) {
    throw 'An installed but unused VIPM package was reported as part of the PPL.'
}
if ($sourcePackages[$packageName].sourceFiles.Count -ne 1 -or $sourcePackages[$packageName].sourceFiles[0] -cne $commonFile) {
    throw 'Candidate ownership evidence must retain the exact PPL source path.'
}
$ambiguousPackageFiles = @{} + $script:ownershipFiles
$ambiguousPackageFiles['unused_installed_package'] = @($commonFile)
Assert-Failure {
    Assert-ProducerSbomCoverage -Sbom $sbom -Inventory $inventory -PackageFiles $ambiguousPackageFiles `
        -SourceFiles $sourceFiles -RequiredPackages $requiredPackages
} '*ambiguous VIPM package ownership*'
$missingRequiredFiles = @{} + $script:ownershipFiles
$missingRequiredFiles[$packageName] = @('C:\Program Files\NI\unrelated\missing.vi')
Assert-Failure {
    Assert-ProducerSbomCoverage -Sbom $sbom -Inventory $inventory -PackageFiles $missingRequiredFiles `
        -SourceFiles $sourceFiles -RequiredPackages $requiredPackages
} '*Required VIPM package*jdp_science_lib_common_utilities*owns no PPL source files*'

$sbom.components[1].purl = 'pkg:vipm/other@1.4.2.19'
Assert-Failure {
    Assert-ProducerSbomCoverage -Sbom $sbom -Inventory $inventory -PackageFiles $packageFiles `
        -SourceFiles $sourceFiles -RequiredPackages $requiredPackages
} '*jdp_science_lib_common_utilities*1.4.2.19*'
$sbom.components[1].purl = $packageRef
$sbom.components[1].'bom-ref' = 'ppl'
Assert-Failure {
    Assert-ProducerSbomCoverage -Sbom $sbom -Inventory $inventory -PackageFiles $packageFiles `
        -SourceFiles $sourceFiles -RequiredPackages $requiredPackages
} '*reference*unique*'
$sbom.components[1].'bom-ref' = $packageRef
$sbom.components += [pscustomobject]@{ 'bom-ref' = $packageRef; name = 'other'; version = '1'; purl = 'pkg:vipm/other@1' }
Assert-Failure {
    Assert-ProducerSbomCoverage -Sbom $sbom -Inventory $inventory -PackageFiles $packageFiles `
        -SourceFiles $sourceFiles -RequiredPackages $requiredPackages
} '*reference*unique*'
$sbom.components = @($sbom.components[0..1])
$inventory.dependencies[1].installed_version = '1.4.2.20'
Assert-Failure {
    Assert-ProducerSbomCoverage -Sbom $sbom -Inventory $inventory -PackageFiles $packageFiles `
        -SourceFiles $sourceFiles -RequiredPackages $requiredPackages
} '*jdp_science_lib_common_utilities*1.4.2.20*'
$inventory.dependencies[1].installed_version = '1.4.2.19'
[void]$packageFiles.Remove($packageName)
Assert-Failure {
    Assert-ProducerSbomCoverage -Sbom $sbom -Inventory $inventory -PackageFiles $packageFiles `
        -SourceFiles $sourceFiles -RequiredPackages $requiredPackages
} '*no authoritative installed-file inventory*'
$packageFiles[$packageName] = @((ConvertTo-ProducerPathKey -Path $commonFile))
$inventory.dependencies[1].status = 'missing'
Assert-Failure {
    Assert-ProducerSbomCoverage -Sbom $sbom -Inventory $inventory -PackageFiles $packageFiles `
        -SourceFiles $sourceFiles -RequiredPackages $requiredPackages
} '*status installed*'

$packageInfo = '{"package":{"installed_files":[{"path":"' + $commonFile.Replace('\', '\\') + '"}]}}' | ConvertFrom-Json -AsHashtable
$parsedFiles = @(Get-ProducerVipmInstalledFilePath -PackageInfo $packageInfo)
if ($parsedFiles.Count -ne 1 -or $parsedFiles[0] -cne $commonFile.ToUpperInvariant()) {
    throw 'VIPM installed-files JSON parser did not preserve the owned path.'
}
Assert-Failure { Get-ProducerVipmInstalledFilePath -PackageInfo @{ installed_files = @('relative/file.vi') } } '*non-absolute path*'
Assert-Failure { Get-ProducerVipmInstalledFilePath -PackageInfo @{ packages = @() } } '*exactly one installed-files collection*'

$workflow = [System.IO.File]::ReadAllText((Join-Path $root '.github/workflows/build-lvlibp-candidate.yml'))
if (-not $workflow.Contains('Assert-ProducerSbomCoverage -Sbom $sbom -Inventory $vipmInventory') -or
    -not $workflow.Contains('list --installed --json') -or
    $workflow.Contains('list --installed --vipm') -or
    -not $workflow.Contains("-RequiredPackages @('$packageName')") -or
    -not $workflow.Contains('sbom $manifestPath') -or
    -not $workflow.Contains('Merge-ProducerSbomVipmSourceComponent -Sbom $sbom -ManifestSbom $manifestSbom') -or
    -not $workflow.Contains('manifestSbom = [ordered]@{')) {
    throw 'The producer candidate workflow must enforce source-owned Common Utilities SBOM coverage.'
}
Write-Output 'PASS: producer source ownership, SBOM coverage, and workflow wiring.'
function ConvertTo-ProducerPathKey {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Trim().Trim('"').Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -notmatch '^(?:[A-Za-z]:\\|\\\\)') {
        throw "Installed-file inventory contains a non-absolute path: '$Path'."
    }
    if ($IsWindows) { $normalized = [System.IO.Path]::GetFullPath($normalized) }
    return $normalized.TrimEnd('\').ToUpperInvariant()
}

function Get-ProducerVipmInstalledFilePath {
    param([Parameter(Mandatory = $true)]$PackageInfo)

    $fileCollections = [System.Collections.Generic.List[object]]::new()
    $visit = {
        param($Value)
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                $normalizedKey = ([string]$key -replace '[^A-Za-z]', '').ToLowerInvariant()
                if ($normalizedKey -in @('installedfiles', 'installedfilepaths', 'files')) {
                    $fileCollections.Add($Value[$key])
                } elseif ($Value[$key] -is [System.Collections.IDictionary] -or
                    ($Value[$key] -is [System.Collections.IEnumerable] -and $Value[$key] -isnot [string])) {
                    & $visit $Value[$key]
                }
            }
        } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
            foreach ($item in $Value) { & $visit $item }
        }
    }
    & $visit $PackageInfo
    if ($fileCollections.Count -ne 1) { throw 'VIPM package information must contain exactly one installed-files collection.' }

    $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($fileCollections[0])) {
        $path = if ($entry -is [string]) { $entry } else {
            foreach ($field in @('path', 'filePath', 'file_path', 'fullPath', 'full_path', 'file')) {
                if ($entry -is [System.Collections.IDictionary] -and $entry.Contains($field) -and
                    -not [string]::IsNullOrWhiteSpace([string]$entry[$field])) {
                    [string]$entry[$field]
                    break
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($path)) { throw 'VIPM installed-files collection contains an invalid entry.' }
        [void]$paths.Add((ConvertTo-ProducerPathKey -Path $path))
    }
    if ($paths.Count -eq 0) { throw 'VIPM package information returned no installed files.' }
    return ,([string[]]@($paths))
}

function Read-ProducerPplSourceFile {
    param([Parameter(Mandatory = $true)][string]$BuildLogPath)

    $sourceFiles = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $inSourceFiles = $false
    foreach ($line in [System.IO.File]::ReadAllLines($BuildLogPath)) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            if ($inSourceFiles) { break }
            $inSourceFiles = $Matches[1] -ceq 'Source Files'
            continue
        }
        if (-not $inSourceFiles -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^(?<path>.+?)\s+\d{1,2}/\d{1,2}/\d{4}\s') {
            throw "PPL build log contains an unreadable Source Files entry: '$line'."
        }
        $path = $Matches['path'].Trim()
        $sourceFiles[(ConvertTo-ProducerPathKey -Path $path)] = $path
    }
    if (-not $inSourceFiles -or $sourceFiles.Count -eq 0) { throw 'PPL build log is missing a non-empty [Source Files] section.' }
    return $sourceFiles
}

function Get-ProducerVipmPackageFileInventory {
    param($Inventory)

    if ($null -eq $Inventory.dependencies -or @($Inventory.dependencies).Count -eq 0) {
        throw 'VIPM installed-package inventory is missing or empty.'
    }
    $filesByPackage = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($package in @($Inventory.dependencies)) {
        $name = [string]$package.name
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'VIPM installed-package inventory has a package with no name.' }
        if ($package.status -cne 'installed') { throw "VIPM inventory package '$name' does not have status installed." }
        if ([string]::IsNullOrWhiteSpace([string]$package.installed_version)) {
            throw "VIPM installed-package inventory has no version for '$name'."
        }
        if ($filesByPackage.ContainsKey($name)) { throw "VIPM installed-package inventory has duplicate package '$name'." }
        $packageInfoJson = & vipm --labview-version 2026 --labview-bitness 64 --json info $name --installed-files
        if ($LASTEXITCODE -ne 0) { throw "Could not inspect installed files for VIPM package '$name'; vipm exited with code $LASTEXITCODE." }
        try {
            $packageInfo = ($packageInfoJson -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        } catch {
            throw "VIPM installed-file response for '$name' is invalid JSON: $($_.Exception.Message)"
        }
        $filesByPackage.Add($name, (Get-ProducerVipmInstalledFilePath -PackageInfo $packageInfo))
    }
    return $filesByPackage
}

function Get-ProducerPplVipmSourcePackage {
    param($Inventory, $PackageFiles, $SourceFiles, [string[]]$RequiredPackages = @())

    if ($null -eq $Inventory.dependencies -or @($Inventory.dependencies).Count -eq 0) { throw 'VIPM installed-package inventory is missing or empty.' }
    if ($null -eq $SourceFiles -or $SourceFiles.Count -eq 0) { throw 'PPL source-file inventory is missing or empty.' }
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ownersBySource = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sourcePackages = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($package in @($Inventory.dependencies)) {
        $name = [string]$package.name
        $version = [string]$package.installed_version
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($version) -or -not $names.Add($name)) {
            throw 'VIPM installed-package inventory has a missing or duplicate package identity.'
        }
        if ($package.status -cne 'installed') { throw "VIPM inventory package '$name' does not have status installed." }
        if (-not $PackageFiles.ContainsKey($name) -or @($PackageFiles[$name]).Count -eq 0) {
            throw "Installed VIPM package '$name' has no authoritative installed-file inventory."
        }
        $ownedFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in @($PackageFiles[$name])) { [void]$ownedFiles.Add((ConvertTo-ProducerPathKey -Path ([string]$path))) }
        foreach ($sourceKey in $SourceFiles.Keys) {
            if (-not $ownedFiles.Contains([string]$sourceKey)) { continue }
            if ($ownersBySource.ContainsKey([string]$sourceKey)) { throw "PPL source file '$($SourceFiles[$sourceKey])' has ambiguous VIPM package ownership." }
            $ownersBySource.Add([string]$sourceKey, $name)
            if (-not $sourcePackages.ContainsKey($name)) {
                $sourcePackages.Add($name, [ordered]@{ version = $version; sourceFiles = [System.Collections.Generic.List[string]]::new() })
            }
            $sourcePackages[$name].sourceFiles.Add([string]$SourceFiles[$sourceKey])
        }
    }
    foreach ($requiredPackage in $RequiredPackages) {
        if (-not $sourcePackages.ContainsKey($requiredPackage)) { throw "Required VIPM package '$requiredPackage' owns no PPL source files." }
    }
    return $sourcePackages
}

function Merge-ProducerSbomVipmSourceComponent {
    param($Sbom, $ManifestSbom, $SourcePackages)

    if ($ManifestSbom.bomFormat -cne 'CycloneDX' -or $ManifestSbom.specVersion -cne '1.5') {
        throw 'VIPM manifest SBOM must be CycloneDX 1.5.'
    }
    $rootRef = [string]$Sbom.metadata.component.'bom-ref'
    if ([string]::IsNullOrWhiteSpace($rootRef)) { throw 'PPL SBOM product reference is missing.' }
    $components = [System.Collections.Generic.List[object]]::new()
    if ($Sbom.components) { $components.AddRange([object[]]@($Sbom.components)) }
    $knownRefs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$knownRefs.Add($rootRef)
    foreach ($component in $components) {
        $reference = [string]$component.'bom-ref'
        if ([string]::IsNullOrWhiteSpace($reference) -or -not $knownRefs.Add($reference)) {
            throw 'PPL SBOM component references must be present and unique before enrichment.'
        }
    }
    $dependencies = [System.Collections.Generic.List[object]]::new()
    if ($Sbom.dependencies) { $dependencies.AddRange([object[]]@($Sbom.dependencies)) }
    $rootNodes = @($dependencies | Where-Object { $_.ref -ceq $rootRef })
    if ($rootNodes.Count -ne 1) { throw 'PPL SBOM must contain exactly one product dependency node.' }
    $rootDependsOn = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($reference in @($rootNodes[0].dependsOn)) { if ($reference) { [void]$rootDependsOn.Add([string]$reference) } }

    foreach ($name in $sourcePackages.Keys) {
        $version = [string]$sourcePackages[$name].version
        $expectedPurl = 'pkg:vipm/{0}@{1}' -f [uri]::EscapeDataString($name.ToLowerInvariant()), [uri]::EscapeDataString($version)
        $manifestComponents = @($ManifestSbom.components | Where-Object { $_.name -ieq $name -and $_.version -ceq $version -and $_.purl -ceq $expectedPurl })
        if ($manifestComponents.Count -ne 1) {
            throw "Installed VIPM package '$name' version '$version' expects PURL '$expectedPurl', but the VIPM manifest SBOM has $($manifestComponents.Count) exact matches."
        }
        $matchingComponents = @($components | Where-Object { $_.name -ieq $name -and $_.version -ceq $version -and $_.purl -ceq $expectedPurl })
        if ($matchingComponents.Count -gt 1) { throw "Installed VIPM package '$name' version '$version' is ambiguous in the PPL SBOM." }
        if ($matchingComponents.Count -eq 1) {
            $componentRef = [string]$matchingComponents[0].'bom-ref'
        } else {
            $componentRef = [string]$manifestComponents[0].'bom-ref'
            if ([string]::IsNullOrWhiteSpace($componentRef) -or -not $knownRefs.Add($componentRef)) {
                throw "VIPM manifest component '$name' has a missing or duplicate bom-ref."
            }
            $components.Add($manifestComponents[0])
        }
        if ([string]::IsNullOrWhiteSpace($componentRef)) { throw "VIPM component '$name' has no bom-ref." }
        [void]$rootDependsOn.Add($componentRef)
    }
    $rootNodes[0].dependsOn = @($rootDependsOn)
    $Sbom.components = $components.ToArray()
    $Sbom.dependencies = $dependencies.ToArray()
    return $Sbom
}

function Assert-ProducerSbomCoverage {
    param($Sbom, $Inventory, $PackageFiles, $SourceFiles, [string[]]$RequiredPackages = @())

    $sourcePackages = Get-ProducerPplVipmSourcePackage -Inventory $Inventory -PackageFiles $PackageFiles `
        -SourceFiles $SourceFiles -RequiredPackages $RequiredPackages
    $rootRef = [string]$Sbom.metadata.component.'bom-ref'
    if ([string]::IsNullOrWhiteSpace($rootRef)) { throw 'SBOM product reference is missing.' }
    $componentRefs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$componentRefs.Add($rootRef)
    foreach ($component in @($Sbom.components)) {
        $reference = [string]$component.'bom-ref'
        if ([string]::IsNullOrWhiteSpace($reference) -or -not $componentRefs.Add($reference)) { throw 'SBOM component references must be present and unique.' }
    }
    $nodes = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($node in @($Sbom.dependencies)) {
        $reference = [string]$node.ref
        if ([string]::IsNullOrWhiteSpace($reference) -or $nodes.ContainsKey($reference)) { throw 'SBOM dependency graph has a missing or duplicate reference.' }
        $nodes.Add($reference, $node)
    }
    if (-not $nodes.ContainsKey($rootRef)) { throw 'SBOM dependency graph has no product node.' }
    $reachable = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($rootRef)
    while ($queue.Count -gt 0) {
        $reference = $queue.Dequeue()
        if (-not $reachable.Add($reference) -or -not $nodes.ContainsKey($reference)) { continue }
        foreach ($child in @($nodes[$reference].dependsOn)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$child)) { $queue.Enqueue([string]$child) }
        }
    }
    foreach ($name in $sourcePackages.Keys) {
        $version = [string]$sourcePackages[$name].version
        $expectedPurl = 'pkg:vipm/{0}@{1}' -f [uri]::EscapeDataString($name.ToLowerInvariant()), [uri]::EscapeDataString($version)
        $components = @($Sbom.components | Where-Object { $_.name -ieq $name -and $_.version -ceq $version -and $_.purl -ceq $expectedPurl })
        if ($components.Count -ne 1) { throw "PPL source uses VIPM package '$name' version '$version', but the SBOM component is missing or ambiguous." }
        $componentRef = [string]$components[0].'bom-ref'
        if ([string]::IsNullOrWhiteSpace($componentRef) -or -not $reachable.Contains($componentRef)) {
            throw "VIPM package '$name' is not reachable from the SBOM product."
        }
    }
    return $sourcePackages
}
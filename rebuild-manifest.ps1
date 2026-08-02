$repoRoot = "E:\wallscreenhub-assets"
$manifestPath = "$repoRoot\manifest.json"
$githubUser = "RealNajeebBaloch"
$githubRepo = "wallscreenhub-assets"

$categoryFolders = Get-ChildItem -Path "$repoRoot\wallpapers" -Directory

$categories = @()

foreach ($catFolder in $categoryFolders) {
    $categoryId = $catFolder.Name
    $categoryName = (Get-Culture).TextInfo.ToTitleCase($categoryId)

    $fullFiles = Get-ChildItem -Path $catFolder.FullName -Filter "*.webp" -File |
        Where-Object { $_.Name -ne ".webp" } |
        Sort-Object Name

    $wallpapers = @()
    foreach ($f in $fullFiles) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $thumbPath = "$($catFolder.FullName)\thumbs\$($f.Name)"

        if (-not (Test-Path $thumbPath)) {
            Write-Warning "Skipping $id - no matching thumb found at $thumbPath"
            continue
        }

        $wallpapers += [PSCustomObject]@{
            id = $id
            full = "wallpapers/$categoryId/$($f.Name)"
            thumb = "wallpapers/$categoryId/thumbs/$($f.Name)"
        }
    }

    if ($wallpapers.Count -gt 0) {
        $categories += [PSCustomObject]@{
            id = $categoryId
            name = $categoryName
            wallpapers = $wallpapers
        }
    } else {
        Write-Warning "Category '$categoryId' has zero valid wallpapers - excluded from manifest"
    }
}

$manifest = [PSCustomObject]@{
    version = 1
    categories = $categories
}

$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath
Write-Host "Rebuilt manifest.json from $($categories.Count) categories on disk."

# --- Sanity check before publishing anything ---
$rawJson = Get-Content $manifestPath -Raw
if ($rawJson -match '"id"\s*:\s*null') {
    Write-Error "manifest.json still contains null ids after rebuild - aborting publish. Check for stray/misnamed files on disk."
    exit 1
}

# --- Commit and push to main ---
Push-Location $repoRoot
git add -A
$commitMessage = "Update wallpapers/manifest - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
git commit -m $commitMessage

if ($LASTEXITCODE -ne 0) {
    Write-Warning "Nothing to commit, or commit failed. Skipping push/purge."
    Pop-Location
    exit 0
}

git push origin main
Pop-Location

if ($LASTEXITCODE -ne 0) {
    Write-Error "git push failed - not purging jsDelivr since the pushed content may not be live yet."
    exit 1
}

# --- Purge jsDelivr so the update is live immediately instead of waiting on branch cache TTL ---
Write-Host "Purging jsDelivr cache for manifest.json..."
$purgeUrl = "https://purge.jsdelivr.net/gh/$githubUser/$githubRepo@main/manifest.json"
try {
    $purgeResult = Invoke-RestMethod -Uri $purgeUrl -Method Get
    Write-Host "Purge status: $($purgeResult.status)"
    $pathResult = $purgeResult.paths.PSObject.Properties.Value | Select-Object -First 1
    if ($pathResult.throttled) {
        Write-Warning "Purge was throttled - jsDelivr will still refresh on its own within the branch cache TTL, just not instantly."
    }
} catch {
    Write-Warning "Purge request failed: $_. The push succeeded, but the CDN update may take a little longer to show up."
}

Write-Host "Publish complete."
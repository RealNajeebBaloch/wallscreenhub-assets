$repoRoot = "E:\wallscreenhub-assets"

# Old category id -> new category id. Add/remove entries here for future renames.
$renames = @{
    "cyberpunk" = "futuristic"
    "anime"     = "illustrated"
    "surreal"   = "dreamy"
}

Push-Location $repoRoot

foreach ($old in $renames.Keys) {
    $new = $renames[$old]
    $oldDir = "wallpapers\$old"
    $newDir = "wallpapers\$new"

    if (-not (Test-Path $oldDir)) {
        Write-Warning "Skipping '$old' - folder not found at $oldDir"
        continue
    }

    Write-Host "Renaming $old -> $new ..."

    # Move the whole folder (including thumbs subfolder) in one go.
    git mv $oldDir $newDir

    # Rename the files inside to match the new category prefix, so future
    # convert-and-publish.ps1 runs auto-number correctly for this category.
    $fullDir = "$newDir"
    $thumbDir = "$newDir\thumbs"

    $pattern = "^" + [regex]::Escape($old) + "_(\d+)\.webp$"

    foreach ($dir in @($fullDir, $thumbDir)) {
        if (-not (Test-Path $dir)) { continue }

        Get-ChildItem -Path $dir -Filter "*.webp" -File | ForEach-Object {
            if ($_.Name -match $pattern) {
                $number = $Matches[1]
                $newName = "${new}_${number}.webp"
                $oldPath = "$dir\$($_.Name)"
                $newPath = "$dir\$newName"
                git mv $oldPath $newPath
            }
        }
    }
}

Write-Host "All renames done. Rebuilding manifest and publishing..."
& "$repoRoot\rebuild-manifest.ps1"

Pop-Location
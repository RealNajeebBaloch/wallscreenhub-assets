$libwebpBin = "$env:USERPROFILE\libwebp\libwebp-1.4.0-windows-x64\bin"
$cwebp = "$libwebpBin\cwebp.exe"
$dwebp = "$libwebpBin\dwebp.exe"
$sourceRoot = "E:\wallpaper-sources"
$repoRoot = "E:\wallscreenhub-assets"

# NOTE: this script no longer reads or patches manifest.json directly.
# Incremental JSON patching was the root cause of the earlier corruption
# (null-id entries, misplaced files). This script ONLY converts/copies
# images into the correct folders with correctly numbered filenames.
# rebuild-manifest.ps1 is always called at the end to regenerate
# manifest.json fresh from what's actually on disk.

$categories = Get-ChildItem -Path $sourceRoot -Directory

foreach ($catFolder in $categories) {
    $categoryId = $catFolder.Name

    $fullDir = "$repoRoot\wallpapers\$categoryId"
    $thumbDir = "$fullDir\thumbs"
    New-Item -ItemType Directory -Force -Path $fullDir | Out-Null
    New-Item -ItemType Directory -Force -Path $thumbDir | Out-Null

    # Defensive numbering: only look at files that actually match the
    # expected "<categoryId>_<digits>.webp" pattern. Anything else already
    # sitting in the folder (a stray/misnamed file, a leftover corrupted
    # entry, etc.) is ignored instead of crashing the whole run.
    $pattern = "^" + [regex]::Escape($categoryId) + "_(\d+)$"
    $existingNumbers = @(
        Get-ChildItem -Path $fullDir -Filter "*.webp" -File |
            ForEach-Object {
                $name = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                if ($name -match $pattern) {
                    [int]$Matches[1]
                }
            }
    )

    $nextNumber = 1
    if ($existingNumbers.Count -gt 0) {
        $nextNumber = ($existingNumbers | Measure-Object -Maximum).Maximum + 1
    }

    # Accept already-webp sources too, not just png/jpg/jpeg.
    $sourceImages = Get-ChildItem -Path $catFolder.FullName -Include *.png,*.jpg,*.jpeg,*.webp -Recurse

    foreach ($img in $sourceImages) {
        $wallpaperId = "{0}_{1:D3}" -f $categoryId, $nextNumber
        $fullOut = "$fullDir\$wallpaperId.webp"
        $thumbOut = "$thumbDir\$wallpaperId.webp"

        # Guard: never let a blank id reach cwebp/copy, no matter what.
        if ([string]::IsNullOrWhiteSpace($wallpaperId)) {
            Write-Warning "Skipping $($img.Name) - failed to compute a valid wallpaper id."
            continue
        }

        Write-Host "Processing $($img.Name) -> $wallpaperId"

        if ($img.Extension -ieq ".webp") {
            # Already WebP: cwebp can't re-encode a WebP input, so copy the
            # full version as-is, then decode it to a temp PNG purely to
            # generate the resized thumbnail from it.
            Copy-Item -Path $img.FullName -Destination $fullOut -Force

            $tempPng = [System.IO.Path]::Combine($env:TEMP, "$wallpaperId-temp.png")
            & $dwebp "$($img.FullName)" -o "$tempPng" | Out-Null

            if (Test-Path $tempPng) {
                & $cwebp -q 70 -resize 500 0 "$tempPng" -o "$thumbOut" | Out-Null
                Remove-Item $tempPng -Force
            } else {
                Write-Warning "Could not decode $($img.Name) to generate a thumbnail - full image was still copied."
            }
        } else {
            & $cwebp -q 80 "$($img.FullName)" -o "$fullOut" | Out-Null
            & $cwebp -q 70 -resize 500 0 "$($img.FullName)" -o "$thumbOut" | Out-Null
        }

        $nextNumber++
    }
}

Write-Host "Conversion done. Rebuilding manifest from disk..."
& "$PSScriptRoot\rebuild-manifest.ps1"
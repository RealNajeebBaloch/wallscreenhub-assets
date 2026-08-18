$ErrorActionPreference = "Stop"

$libwebpBin = "$env:USERPROFILE\libwebp\libwebp-1.4.0-windows-x64\bin"
$cwebp = "$libwebpBin\cwebp.exe"
$dwebp = "$libwebpBin\dwebp.exe"

$sourceRoot = "E:\wallpaper-sources"
$repoRoot = "E:\wallscreenhub-assets"

$wallpapersRoot = "$repoRoot\wallpapers"

$fullQuality = 80
$thumbQuality = 70
$thumbWidth = 500

$allowedExtensions = @(
    ".png",
    ".jpg",
    ".jpeg",
    ".webp"
)

# ============================================================
# VALIDATION
# ============================================================

if (-not (Test-Path $cwebp)) {
    throw "cwebp.exe not found at: $cwebp"
}

if (-not (Test-Path $dwebp)) {
    throw "dwebp.exe not found at: $dwebp"
}

if (-not (Test-Path $sourceRoot)) {
    throw "Source directory does not exist: $sourceRoot"
}

if (-not (Test-Path $repoRoot)) {
    throw "Repository directory does not exist: $repoRoot"
}

New-Item `
    -ItemType Directory `
    -Force `
    -Path $wallpapersRoot |
    Out-Null


# ============================================================
# SHA-256
#
# IMPORTANT:
# This works even if a WebP is corrupted/undecodable.
# We DO NOT use dwebp to determine whether an existing
# wallpaper is valid.
# ============================================================

function Get-FileHashValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (
        Get-FileHash `
            -Path $Path `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}


# ============================================================
# CREATE THUMBNAIL FROM WEBP
#
# dwebp is only used here, when a thumbnail actually needs
# to be created.
# ============================================================

function New-ThumbnailFromWebP {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebPPath,

        [Parameter(Mandatory = $true)]
        [string]$ThumbPath
    )

    $tempPng = Join-Path `
        $env:TEMP `
        ("wallpaper-thumb-" + [guid]::NewGuid().ToString("N") + ".png")

    try {

        & $dwebp `
            $WebPPath `
            -o $tempPng

        if (
            $LASTEXITCODE -ne 0 -or
            -not (Test-Path $tempPng)
        ) {
            throw "dwebp could not decode: $WebPPath"
        }

        & $cwebp `
            -q $thumbQuality `
            -resize $thumbWidth 0 `
            $tempPng `
            -o $ThumbPath

        if (
            $LASTEXITCODE -ne 0 -or
            -not (Test-Path $ThumbPath)
        ) {
            throw "Could not create thumbnail: $ThumbPath"
        }

    }
    finally {

        if (Test-Path $tempPng) {
            Remove-Item `
                $tempPng `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}


# ============================================================
# CONVERT SOURCE TO TEMP WEBP
#
# For JPG/PNG:
#   JPG/PNG -> cwebp -> temporary WebP
#
# For WebP:
#   simply copy the source to a temporary location.
#
# The resulting temporary WebP is then hashed.
# ============================================================

function Convert-ToTemporaryWebP {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    $tempWebP = Join-Path `
        $env:TEMP `
        ("wallpaper-source-" + [guid]::NewGuid().ToString("N") + ".webp")

    try {

        $extension = [System.IO.Path]::GetExtension(
            $SourcePath
        ).ToLowerInvariant()

        if ($extension -eq ".webp") {

            Copy-Item `
                -Path $SourcePath `
                -Destination $tempWebP `
                -Force
        }
        else {

            & $cwebp `
                -q $fullQuality `
                $SourcePath `
                -o $tempWebP

            if (
                $LASTEXITCODE -ne 0 -or
                -not (Test-Path $tempWebP)
            ) {
                throw "cwebp failed to convert source: $SourcePath"
            }
        }

        return $tempWebP
    }
    catch {

        if (Test-Path $tempWebP) {
            Remove-Item `
                $tempWebP `
                -Force `
                -ErrorAction SilentlyContinue
        }

        throw
    }
}


# ============================================================
# CREATE FINAL WEBP FROM SOURCE
# ============================================================

function Create-FinalWebP {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $extension = [System.IO.Path]::GetExtension(
        $SourcePath
    ).ToLowerInvariant()

    if ($extension -eq ".webp") {

        Copy-Item `
            -Path $SourcePath `
            -Destination $OutputPath `
            -Force

        return
    }

    & $cwebp `
        -q $fullQuality `
        $SourcePath `
        -o $OutputPath

    if (
        $LASTEXITCODE -ne 0 -or
        -not (Test-Path $OutputPath)
    ) {
        throw "cwebp failed to create: $OutputPath"
    }
}


# ============================================================
# DISCOVER ALL SOURCE CATEGORIES
#
# This happens on EVERY run.
# New category folders therefore work automatically.
# ============================================================

$sourceCategories = Get-ChildItem `
    -Path $sourceRoot `
    -Directory `
    -ErrorAction SilentlyContinue |
    Sort-Object Name

Write-Host ""
Write-Host "============================================================"
Write-Host "SOURCE CATEGORIES"
Write-Host "============================================================"
Write-Host ""

foreach ($folder in $sourceCategories) {
    Write-Host "Found category: $($folder.Name)"
}

Write-Host ""


# ============================================================
# INDEX EXISTING REPOSITORY WALLPAPERS
#
# NO dwebp here.
#
# Every existing WebP gets a SHA-256 hash directly from disk.
#
# This is the crucial part that prevents duplicates.
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "INDEXING EXISTING WALLPAPERS"
Write-Host "============================================================"
Write-Host ""

$existingByHash = @{}

$repoCategoryFolders = Get-ChildItem `
    -Path $wallpapersRoot `
    -Directory `
    -ErrorAction SilentlyContinue

$existingCount = 0

foreach ($categoryFolder in $repoCategoryFolders) {

    $categoryId = $categoryFolder.Name

    $files = Get-ChildItem `
        -Path $categoryFolder.FullName `
        -Filter "*.webp" `
        -File `
        -ErrorAction SilentlyContinue

    foreach ($file in $files) {

        $id = [System.IO.Path]::GetFileNameWithoutExtension(
            $file.Name
        )

        $hash = Get-FileHashValue $file.FullName

        $thumbPath = Join-Path `
            $categoryFolder.FullName `
            "thumbs\$($file.Name)"

        $existingByHash[$hash] = @{
            id       = $id
            category = $categoryId
            full     = $file.FullName
            thumb    = $thumbPath
        }

        $existingCount++
    }
}

Write-Host "Existing wallpapers indexed: $existingCount"


# ============================================================
# DETERMINE NEXT NUMBER PER CATEGORY
# ============================================================

$nextNumbers = @{}

foreach ($categoryFolder in $sourceCategories) {

    $categoryId = $categoryFolder.Name

    $fullDir = Join-Path `
        $wallpapersRoot `
        $categoryId

    $thumbDir = Join-Path `
        $fullDir `
        "thumbs"

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $fullDir |
        Out-Null

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $thumbDir |
        Out-Null

    $pattern = "^" + [regex]::Escape($categoryId) + "_(\d+)$"

    $numbers = @(
        Get-ChildItem `
            -Path $fullDir `
            -Filter "*.webp" `
            -File `
            -ErrorAction SilentlyContinue |
        ForEach-Object {

            $name = [System.IO.Path]::GetFileNameWithoutExtension(
                $_.Name
            )

            if ($name -match $pattern) {
                [int]$Matches[1]
            }
        }
    )

    if ($numbers.Count -gt 0) {

        $nextNumbers[$categoryId] =
            [int](($numbers | Measure-Object -Maximum).Maximum) + 1
    }
    else {

        $nextNumbers[$categoryId] = 1
    }
}


# ============================================================
# COUNTERS
# ============================================================

$newCount = 0
$existingCountRun = 0
$movedCount = 0
$thumbnailCount = 0
$duplicateSourceCount = 0


# ============================================================
# PROCESS EVERY SOURCE CATEGORY
# ============================================================

foreach ($categoryFolder in $sourceCategories) {

    $categoryId = $categoryFolder.Name

    $fullDir = Join-Path `
        $wallpapersRoot `
        $categoryId

    $thumbDir = Join-Path `
        $fullDir `
        "thumbs"

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "CATEGORY: $categoryId"
    Write-Host "============================================================"
    Write-Host ""

    # --------------------------------------------------------
    # Recursive scan.
    # This means new files in subfolders are also detected.
    # --------------------------------------------------------

    $sourceImages = Get-ChildItem `
        -Path $categoryFolder.FullName `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $allowedExtensions -contains $_.Extension.ToLowerInvariant()
        } |
        Sort-Object FullName

    # Used only during THIS run to prevent duplicate source
    # files from being processed twice.
    $seenThisRun = @{}

    foreach ($img in $sourceImages) {

        Write-Host ""
        Write-Host "Checking: $($img.FullName)"

        $tempWebP = $null

        try {

            # ------------------------------------------------
            # Convert source to temporary WebP.
            # ------------------------------------------------

            $tempWebP = Convert-ToTemporaryWebP `
                -SourcePath $img.FullName

            # ------------------------------------------------
            # Identify the actual wallpaper by its WebP hash.
            # ------------------------------------------------

            $sourceHash = Get-FileHashValue `
                -Path $tempWebP

            # ------------------------------------------------
            # Same source image appears more than once in the
            # source tree during THIS run.
            # ------------------------------------------------

            if ($seenThisRun.ContainsKey($sourceHash)) {

                Write-Warning "Duplicate source detected - skipping:"
                Write-Warning $img.FullName

                $duplicateSourceCount++
                continue
            }

            $seenThisRun[$sourceHash] = $true


            # =================================================
            # EXISTING WALLPAPER
            # =================================================

            if ($existingByHash.ContainsKey($sourceHash)) {

                $existing = $existingByHash[$sourceHash]

                $oldCategory = $existing.category
                $oldId = $existing.id
                $oldFull = $existing.full
                $oldThumb = $existing.thumb

                # ------------------------------------------------
                # SAME CATEGORY
                # ------------------------------------------------

                if ($oldCategory -eq $categoryId) {

                    Write-Host "Already exists: $oldId"

                    # Don't regenerate the wallpaper.
                    # Only create the thumbnail if it doesn't exist.
                    #
                    # IMPORTANT:
                    # We deliberately DO NOT run dwebp here unless
                    # the thumbnail is missing.
                    # ------------------------------------------------

                    if (-not (Test-Path $oldThumb)) {

                        Write-Host "Thumbnail missing - creating..."

                        try {

                            New-ThumbnailFromWebP `
                                -WebPPath $oldFull `
                                -ThumbPath $oldThumb

                            $thumbnailCount++

                        }
                        catch {

                            Write-Warning ""
                            Write-Warning "Could not create thumbnail for:"
                            Write-Warning $oldFull
                            Write-Warning $_
                            Write-Warning ""
                        }
                    }

                    $existingCountRun++
                    continue
                }


                # =================================================
                # WALLPAPER MOVED TO A DIFFERENT CATEGORY
                # =================================================

                Write-Host ""
                Write-Host "Wallpaper moved:"
                Write-Host "  From: $oldCategory"
                Write-Host "  To:   $categoryId"
                Write-Host "  Old:  $oldId"
                Write-Host ""

                $newNumber = [int]$nextNumbers[$categoryId]

                $newId = "{0}_{1:D3}" -f `
                    $categoryId,
                    $newNumber

                $newFull = Join-Path `
                    $fullDir `
                    "$newId.webp"

                $newThumb = Join-Path `
                    $thumbDir `
                    "$newId.webp"

                # Move existing full WebP.
                Move-Item `
                    -Path $oldFull `
                    -Destination $newFull `
                    -Force

                # Move thumbnail if it exists.
                if (Test-Path $oldThumb) {

                    Move-Item `
                        -Path $oldThumb `
                        -Destination $newThumb `
                        -Force
                }
                else {

                    # If thumbnail didn't exist, try to create it.
                    try {

                        New-ThumbnailFromWebP `
                            -WebPPath $newFull `
                            -ThumbPath $newThumb

                        $thumbnailCount++
                    }
                    catch {

                        Write-Warning "Could not create thumbnail for moved wallpaper: $newId"
                    }
                }

                # Remove old hash entry and create new one.
                $existingByHash.Remove($sourceHash)

                $existingByHash[$sourceHash] = @{
                    id       = $newId
                    category = $categoryId
                    full     = $newFull
                    thumb    = $newThumb
                }

                $nextNumbers[$categoryId] = $newNumber + 1

                Write-Host "Moved successfully: $newId"

                $movedCount++
                continue
            }


            # =================================================
            # NEW WALLPAPER
            # =================================================

            $nextNumber = [int]$nextNumbers[$categoryId]

            $wallpaperId = "{0}_{1:D3}" -f `
                $categoryId,
                $nextNumber

            $fullOut = Join-Path `
                $fullDir `
                "$wallpaperId.webp"

            $thumbOut = Join-Path `
                $thumbDir `
                "$wallpaperId.webp"

            Write-Host ""
            Write-Host "NEW WALLPAPER"
            Write-Host "  Source: $($img.Name)"
            Write-Host "  ID:     $wallpaperId"
            Write-Host ""

            # ------------------------------------------------
            # Create final WebP.
            # ------------------------------------------------

            Create-FinalWebP `
                -SourcePath $img.FullName `
                -OutputPath $fullOut

            # ------------------------------------------------
            # Create thumbnail.
            #
            # For JPG/PNG we can directly use cwebp.
            # For WebP we must use dwebp.
            # ------------------------------------------------

            if ($img.Extension -ieq ".webp") {

                try {

                    New-ThumbnailFromWebP `
                        -WebPPath $fullOut `
                        -ThumbPath $thumbOut

                }
                catch {

                    # The full wallpaper was created, but its
                    # thumbnail could not be generated.
                    #
                    # Do NOT delete the valid/full source automatically.
                    Write-Warning ""
                    Write-Warning "Could not create thumbnail for $wallpaperId"
                    Write-Warning $_
                    Write-Warning ""
                }

            }
            else {

                & $cwebp `
                    -q $thumbQuality `
                    -resize $thumbWidth 0 `
                    $img.FullName `
                    -o $thumbOut

                if (
                    $LASTEXITCODE -ne 0 -or
                    -not (Test-Path $thumbOut)
                ) {

                    Write-Warning "Could not create thumbnail for $wallpaperId"
                }
            }

            # ------------------------------------------------
            # Add the new wallpaper to our in-memory index.
            #
            # This is CRITICAL:
            #
            # If two source files have the same content, the
            # second one will now see this hash and will NOT
            # create another wallpaper.
            # ------------------------------------------------

            $existingByHash[$sourceHash] = @{
                id       = $wallpaperId
                category = $categoryId
                full     = $fullOut
                thumb    = $thumbOut
            }

            $nextNumbers[$categoryId] = $nextNumber + 1

            Write-Host "Created: $wallpaperId"

            $newCount++
        }
        catch {

            Write-Error ""
            Write-Error "FAILED PROCESSING:"
            Write-Error $img.FullName
            Write-Error ""
            Write-Error $_
            Write-Error ""

            throw
        }
        finally {

            if ($tempWebP -and (Test-Path $tempWebP)) {

                Remove-Item `
                    $tempWebP `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
}


# ============================================================
# SUMMARY
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "SYNCHRONIZATION SUMMARY"
Write-Host "============================================================"
Write-Host "New wallpapers:          $newCount"
Write-Host "Already existing:        $existingCountRun"
Write-Host "Moved categories:        $movedCount"
Write-Host "New thumbnails:           $thumbnailCount"
Write-Host "Duplicate source images:  $duplicateSourceCount"
Write-Host "============================================================"
Write-Host ""


# ============================================================
# REBUILD MANIFEST
# ============================================================

Write-Host "Conversion complete."
Write-Host "Rebuilding manifest from disk..."
Write-Host ""

& "$PSScriptRoot\rebuild-manifest.ps1"

if ($LASTEXITCODE -ne 0) {

    throw "rebuild-manifest.ps1 failed."
}

Write-Host ""
Write-Host "============================================================"
Write-Host "WALLPAPER PUBLISH COMPLETE"
Write-Host "============================================================"
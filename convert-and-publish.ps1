param(
    # Skip git push, CDN purge and CDN verification.
    [switch]$NoPush,

    # Verify EVERY wallpaper on the CDN, not just the ones changed this run.
    [switch]$VerifyAll,

    # Do NOT remove repo categories whose source folder was deleted.
    [switch]$NoPrune,

    # Allow removing MORE than half of the repo categories in one run
    # (normally blocked as a safety net against a wrong/partial source drive).
    [switch]$ForcePrune
)

$ErrorActionPreference = "Stop"

$libwebpBin = "$env:USERPROFILE\libwebp\libwebp-1.4.0-windows-x64\bin"
$cwebp = "$libwebpBin\cwebp.exe"
$dwebp = "$libwebpBin\dwebp.exe"

$sourceRoot = "E:\wallpaper-sources"
$repoRoot = "E:\wallscreenhub-assets"

# Broken files are moved here (OUTSIDE the git repo) instead of being published.
$quarantineRoot = "E:\wallscreenhub-quarantine"

# GitHub / jsDelivr publishing
$githubUser = "RealNajeebBaloch"
$githubRepo = "wallscreenhub-assets"
$gitBranch  = "main"

$cdnBase   = "https://cdn.jsdelivr.net/gh/$githubUser/$githubRepo@$gitBranch"
$purgeBase = "https://purge.jsdelivr.net/gh/$githubUser/$githubRepo@$gitBranch"

$wallpapersRoot = "$repoRoot\wallpapers"

# IMPORTANT: do not change $fullQuality or the cwebp options used for the
# full wallpaper. The SHA-256 of the converted output is how existing
# wallpapers are recognised. Changing them would duplicate everything.
$fullQuality = 80
$thumbQuality = 70
$thumbWidth = 500

$allowedExtensions = @(
    ".png",
    ".jpg",
    ".jpeg",
    ".webp"
)

# Everything that goes wrong for a specific file is collected here and
# printed at the end. One bad file never stops the run.
$problems = New-Object System.Collections.ArrayList


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
# SMALL HELPERS
# ============================================================

function Add-Problem {
    param([string]$Message)

    [void]$script:problems.Add($Message)
    Write-Warning $Message
}

function New-TempPath {
    param(
        [string]$Prefix,
        [string]$Extension
    )

    return (Join-Path `
        $env:TEMP `
        ($Prefix + [guid]::NewGuid().ToString("N") + $Extension))
}

function Remove-IfExists {
    param([string]$Path)

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item `
            -LiteralPath $Path `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

function Get-FileHashValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (
        Get-FileHash `
            -LiteralPath $Path `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

# Runs a native tool WITHOUT letting its stderr output trigger
# $ErrorActionPreference = "Stop". Returns exit code + captured output.
function Invoke-Tool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $output = & $Exe @Arguments 2>&1
        $code = $LASTEXITCODE

        return @{
            ExitCode = $code
            Output   = ($output | Out-String)
        }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Test-FileHasContent {
    param([string]$Path)

    return (
        (Test-Path -LiteralPath $Path) -and
        ((Get-Item -LiteralPath $Path).Length -gt 0)
    )
}


# ============================================================
# DETECT REAL IMAGE FORMAT FROM THE FIRST BYTES
#
# File extensions lie (a JPEG saved as ".webp" is common).
# Returns: webp | jpeg | png | unknown
# ============================================================

function Get-ImageFormat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $buffer = New-Object byte[] 12
    $read = 0

    $stream = [System.IO.File]::OpenRead($Path)

    try {
        $read = $stream.Read($buffer, 0, 12)
    }
    finally {
        $stream.Dispose()
    }

    # RIFF....WEBP
    if (
        $read -ge 12 -and
        $buffer[0] -eq 0x52 -and $buffer[1] -eq 0x49 -and
        $buffer[2] -eq 0x46 -and $buffer[3] -eq 0x46 -and
        $buffer[8] -eq 0x57 -and $buffer[9] -eq 0x45 -and
        $buffer[10] -eq 0x42 -and $buffer[11] -eq 0x50
    ) {
        return "webp"
    }

    # FF D8 FF
    if (
        $read -ge 3 -and
        $buffer[0] -eq 0xFF -and
        $buffer[1] -eq 0xD8 -and
        $buffer[2] -eq 0xFF
    ) {
        return "jpeg"
    }

    # 89 50 4E 47
    if (
        $read -ge 4 -and
        $buffer[0] -eq 0x89 -and
        $buffer[1] -eq 0x50 -and
        $buffer[2] -eq 0x4E -and
        $buffer[3] -eq 0x47
    ) {
        return "png"
    }

    return "unknown"
}


# ============================================================
# CONVERSION HELPERS
# ============================================================

# JPEG/PNG (any extension) -> WebP. cwebp reads the real content,
# so a JPEG named ".webp" converts fine.
function Convert-ToWebP {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $result = Invoke-Tool -Exe $cwebp -Arguments @(
        "-quiet",
        "-q", "$fullQuality",
        $InputPath,
        "-o", $OutputPath
    )

    if ($result.ExitCode -ne 0 -or -not (Test-FileHasContent $OutputPath)) {

        Remove-IfExists $OutputPath

        throw "cwebp failed for '$InputPath'. $($result.Output.Trim())"
    }
}

# WebP -> PNG. Returns $true only if the WebP decoded completely.
# This doubles as the "is this WebP valid?" test.
function Convert-WebPToPng {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebPPath,

        [Parameter(Mandatory = $true)]
        [string]$PngPath
    )

    $result = Invoke-Tool -Exe $dwebp -Arguments @(
        "-quiet",
        $WebPPath,
        "-o", $PngPath
    )

    if ($result.ExitCode -ne 0 -or -not (Test-FileHasContent $PngPath)) {

        Remove-IfExists $PngPath

        return $false
    }

    return $true
}

# JPEG/PNG (or temp PNG) -> thumbnail WebP
function New-ThumbnailFromImage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [string]$ThumbPath
    )

    $result = Invoke-Tool -Exe $cwebp -Arguments @(
        "-quiet",
        "-q", "$thumbQuality",
        "-resize", "$thumbWidth", "0",
        $InputPath,
        "-o", $ThumbPath
    )

    if ($result.ExitCode -ne 0 -or -not (Test-FileHasContent $ThumbPath)) {

        Remove-IfExists $ThumbPath

        throw "Could not create thumbnail: $ThumbPath. $($result.Output.Trim())"
    }
}

# Existing full WebP -> thumbnail WebP (via a temporary PNG)
function New-ThumbnailFromWebP {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebPPath,

        [Parameter(Mandatory = $true)]
        [string]$ThumbPath
    )

    $tempPng = New-TempPath "wallpaper-thumb-" ".png"

    try {

        if (-not (Convert-WebPToPng -WebPPath $WebPPath -PngPath $tempPng)) {
            throw "dwebp could not decode: $WebPPath"
        }

        New-ThumbnailFromImage `
            -InputPath $tempPng `
            -ThumbPath $ThumbPath
    }
    finally {
        Remove-IfExists $tempPng
    }
}

function Move-ToQuarantine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    $destDir = Join-Path $quarantineRoot $Category

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $destDir |
        Out-Null

    $destPath = Join-Path $destDir ([System.IO.Path]::GetFileName($Path))

    Move-Item `
        -LiteralPath $Path `
        -Destination $destPath `
        -Force

    Add-Problem "QUARANTINED $Path -> $destPath ($Reason)"
}


# ============================================================
# DISCOVER ALL SOURCE CATEGORIES
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
# DETECT CATEGORIES DELETED FROM THE SOURCE
#
# The source folders are the master list of categories. A
# category folder in the repo with no matching folder in
# $sourceRoot was deleted on purpose, so it is removed from the
# repo too (images + thumbnails). The manifest is rebuilt from
# disk afterwards, so it drops that category automatically.
#
# Detection happens here, but the actual deletion happens AFTER
# the source categories are processed. That way images you moved
# or renamed into another source folder are MOVED (as always)
# instead of being deleted and converted again.
# ============================================================

$sourceCategoryNames = @{}

foreach ($folder in $sourceCategories) {
    $sourceCategoryNames[$folder.Name] = $true
}

$repoCategoriesNow = @(
    Get-ChildItem `
        -Path $wallpapersRoot `
        -Directory `
        -ErrorAction SilentlyContinue
)

$staleCategoryFolders = @(
    $repoCategoriesNow |
        Where-Object { -not $sourceCategoryNames.ContainsKey($_.Name) }
)

$pruneEnabled = $false
$stalePruneLookup = @{}
$prunedCategoryCount = 0
$prunedWallpaperCount = 0

Write-Host "============================================================"
Write-Host "CATEGORIES DELETED FROM SOURCE"
Write-Host "============================================================"
Write-Host ""

if ($staleCategoryFolders.Count -eq 0) {

    Write-Host "None. Repo categories match the source folders."
}
elseif ($NoPrune) {

    Write-Warning "-NoPrune given: $($staleCategoryFolders.Count) repo categories have no source folder but will be KEPT: $(($staleCategoryFolders | ForEach-Object { $_.Name }) -join ', ')"
}
elseif ($sourceCategoryNames.Count -eq 0) {

    Add-Problem "SAFETY STOP: no category folders were found in $sourceRoot, so nothing was removed from the repo (is the drive/folder empty or unavailable?)."
}
elseif (
    $staleCategoryFolders.Count -ge 2 -and
    ($staleCategoryFolders.Count * 2) -gt $repoCategoriesNow.Count -and
    -not $ForcePrune
) {

    Add-Problem "SAFETY STOP: $($staleCategoryFolders.Count) of $($repoCategoriesNow.Count) repo categories have no source folder ($(($staleCategoryFolders | ForEach-Object { $_.Name }) -join ', ')). That is more than half, so nothing was removed. If this is intentional, run again with -ForcePrune."
}
else {

    $pruneEnabled = $true

    foreach ($stale in $staleCategoryFolders) {

        $staleCount = @(
            Get-ChildItem `
                -LiteralPath $stale.FullName `
                -Filter "*.webp" `
                -File `
                -ErrorAction SilentlyContinue
        ).Count

        Write-Host "Will remove category '$($stale.Name)' ($staleCount wallpapers) - its source folder no longer exists."

        $stalePruneLookup[$stale.Name] = $true
    }
}

Write-Host ""


# ============================================================
# REPAIR EXISTING REPOSITORY FILES
#
# Earlier runs copied ".webp" sources byte-for-byte. If such a
# file was really a JPEG/PNG, the repo now holds an undecodable
# "fake WebP". Detect that from the header (no decoding) and
# convert it in place. The ID stays the same, and the old
# thumbnail (if any) is removed so it gets rebuilt.
#
# The conversion uses the same cwebp settings as a normal
# source conversion, so the resulting hash matches the source
# and no duplicate will be created.
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "REPAIRING EXISTING WALLPAPERS (fake WebP files)"
Write-Host "============================================================"
Write-Host ""

$repairedCount = 0

$repoCategoryFolders = Get-ChildItem `
    -Path $wallpapersRoot `
    -Directory `
    -ErrorAction SilentlyContinue |
    Where-Object { -not $stalePruneLookup.ContainsKey($_.Name) }

foreach ($categoryFolder in $repoCategoryFolders) {

    $categoryId = $categoryFolder.Name

    $files = Get-ChildItem `
        -Path $categoryFolder.FullName `
        -Filter "*.webp" `
        -File `
        -ErrorAction SilentlyContinue

    foreach ($file in $files) {

        $format = Get-ImageFormat -Path $file.FullName

        if ($format -eq "webp") {
            continue
        }

        $thumbPath = Join-Path `
            $categoryFolder.FullName `
            "thumbs\$($file.Name)"

        if ($format -eq "jpeg" -or $format -eq "png") {

            Write-Host "Repairing $($file.Name): real format is $format, converting to WebP"

            $tempRepair = New-TempPath "wallpaper-repair-" ".webp"

            try {

                Convert-ToWebP `
                    -InputPath $file.FullName `
                    -OutputPath $tempRepair

                Move-Item `
                    -LiteralPath $tempRepair `
                    -Destination $file.FullName `
                    -Force

                Remove-IfExists $thumbPath

                $repairedCount++
            }
            catch {

                Remove-IfExists $tempRepair

                Add-Problem "Could not repair $($file.FullName): $($_.Exception.Message)"
            }
        }
        else {

            Remove-IfExists $thumbPath

            Move-ToQuarantine `
                -Path $file.FullName `
                -Category $categoryId `
                -Reason "unrecognized file format"
        }
    }
}

Write-Host "Repaired in place: $repairedCount"


# ============================================================
# INDEX EXISTING REPOSITORY WALLPAPERS
#
# SHA-256 of every existing WebP, straight from disk.
# This is what prevents duplicates.
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "INDEXING EXISTING WALLPAPERS"
Write-Host "============================================================"
Write-Host ""

$existingByHash = @{}
$existingCount = 0

$repoCategoryFolders = Get-ChildItem `
    -Path $wallpapersRoot `
    -Directory `
    -ErrorAction SilentlyContinue

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

    $sourceImages = Get-ChildItem `
        -Path $categoryFolder.FullName `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $allowedExtensions -contains $_.Extension.ToLowerInvariant()
        } |
        Sort-Object FullName

    $seenThisRun = @{}

    foreach ($img in $sourceImages) {

        Write-Host ""
        Write-Host "Checking: $($img.FullName)"

        $tempWebP = $null
        $tempPng = $null

        try {

            # ------------------------------------------------
            # Real format (from the header, not the extension).
            # ------------------------------------------------

            $format = Get-ImageFormat -Path $img.FullName

            if ($format -eq "unknown") {

                Add-Problem "Unsupported or damaged source (not WebP/JPEG/PNG): $($img.FullName)"
                continue
            }

            $expectedFormat = switch ($img.Extension.ToLowerInvariant()) {
                ".jpg"  { "jpeg" }
                ".jpeg" { "jpeg" }
                ".png"  { "png" }
                ".webp" { "webp" }
                default { "" }
            }

            if ($expectedFormat -ne $format) {

                Write-Warning "Extension '$($img.Extension)' but real format is '$format' - handling it as $format."
            }

            # ------------------------------------------------
            # Identify the wallpaper by the hash of its WebP form.
            #   webp      -> hash the source file itself
            #   jpeg/png  -> convert to a temp WebP and hash that
            # ------------------------------------------------

            if ($format -eq "webp") {

                $hashPath = $img.FullName
            }
            else {

                $tempWebP = New-TempPath "wallpaper-source-" ".webp"

                Convert-ToWebP `
                    -InputPath $img.FullName `
                    -OutputPath $tempWebP

                $hashPath = $tempWebP
            }

            $sourceHash = Get-FileHashValue -Path $hashPath

            # ------------------------------------------------
            # Same content twice in the source tree.
            # ------------------------------------------------

            if ($seenThisRun.ContainsKey($sourceHash)) {

                Write-Warning "Duplicate source detected - skipping: $($img.FullName)"

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
                #
                # Missing thumbnails are handled by the VERIFY
                # step at the end of the run.
                # ------------------------------------------------

                if ($oldCategory -eq $categoryId) {

                    Write-Host "Already exists: $oldId"

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

                Move-Item `
                    -LiteralPath $oldFull `
                    -Destination $newFull `
                    -Force

                # Thumbnail is moved if it exists; otherwise the
                # VERIFY step creates it.
                if (Test-Path -LiteralPath $oldThumb) {

                    Move-Item `
                        -LiteralPath $oldThumb `
                        -Destination $newThumb `
                        -Force
                }

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

            # ------------------------------------------------
            # A real WebP source must decode completely BEFORE
            # it is accepted. A damaged one gets no ID and is
            # reported instead of being published broken.
            # ------------------------------------------------

            if ($format -eq "webp") {

                $tempPng = New-TempPath "wallpaper-decode-" ".png"

                if (-not (Convert-WebPToPng -WebPPath $img.FullName -PngPath $tempPng)) {

                    Add-Problem "CORRUPT WebP source (header is WebP but the image data cannot be decoded - damaged/truncated download). Re-download it: $($img.FullName)"
                    continue
                }
            }

            Write-Host ""
            Write-Host "NEW WALLPAPER"
            Write-Host "  Source: $($img.Name)"
            Write-Host "  Format: $format"
            Write-Host "  ID:     $wallpaperId"
            Write-Host ""

            try {

                if ($format -eq "webp") {

                    Copy-Item `
                        -LiteralPath $img.FullName `
                        -Destination $fullOut `
                        -Force

                    New-ThumbnailFromImage `
                        -InputPath $tempPng `
                        -ThumbPath $thumbOut
                }
                else {

                    # The temp WebP is exactly what cwebp would
                    # produce again, so reuse it.
                    Copy-Item `
                        -LiteralPath $tempWebP `
                        -Destination $fullOut `
                        -Force

                    New-ThumbnailFromImage `
                        -InputPath $img.FullName `
                        -ThumbPath $thumbOut
                }

                $thumbnailCount++
            }
            catch {

                # Never leave a half-created wallpaper behind.
                Remove-IfExists $fullOut
                Remove-IfExists $thumbOut

                Add-Problem "Could not create wallpaper/thumbnail for $($img.FullName): $($_.Exception.Message)"
                continue
            }

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

            Add-Problem "FAILED processing $($img.FullName): $($_.Exception.Message)"
        }
        finally {

            Remove-IfExists $tempWebP
            Remove-IfExists $tempPng
        }
    }
}


# ============================================================
# REMOVE CATEGORIES DELETED FROM THE SOURCE
#
# Runs after all source categories were processed, so anything
# that was moved out of a deleted category is already safe in its
# new category. Whatever is left in the folder is removed
# (full images + thumbs). Git sees these as deletions, and the
# publish step purges them from the CDN.
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "REMOVING CATEGORIES DELETED FROM SOURCE"
Write-Host "============================================================"
Write-Host ""

if (-not $pruneEnabled) {

    Write-Host "Nothing to remove."
}
else {

    foreach ($stale in $staleCategoryFolders) {

        $folderPath = $stale.FullName

        if (-not (Test-Path -LiteralPath $folderPath)) {
            continue
        }

        # Never delete anything outside the wallpapers folder.
        if (-not $folderPath.StartsWith(
                ($wallpapersRoot + ""),
                [System.StringComparison]::OrdinalIgnoreCase)) {

            Add-Problem "Refused to remove folder outside the wallpapers directory: $folderPath"
            continue
        }

        $leftCount = @(
            Get-ChildItem `
                -LiteralPath $folderPath `
                -Filter "*.webp" `
                -File `
                -ErrorAction SilentlyContinue
        ).Count

        try {

            Remove-Item `
                -LiteralPath $folderPath `
                -Recurse `
                -Force `
                -ErrorAction Stop

            Write-Host "Removed category '$($stale.Name)' ($leftCount wallpapers + thumbnails)."

            $prunedCategoryCount++
            $prunedWallpaperCount += $leftCount
        }
        catch {

            Add-Problem "Could not remove category folder $folderPath : $($_.Exception.Message)"
        }
    }
}


# ============================================================
# VERIFY: EVERY PUBLISHED WALLPAPER MUST HAVE A THUMBNAIL
#
# Covers existing wallpapers whose thumbnail is missing (or
# empty), moved wallpapers, and wallpapers whose source file no
# longer exists. If a thumbnail still cannot be built, the full
# image is undecodable, so it is quarantined rather than
# published broken.
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "VERIFYING THUMBNAILS"
Write-Host "============================================================"
Write-Host ""

$repoCategoryFolders = Get-ChildItem `
    -Path $wallpapersRoot `
    -Directory `
    -ErrorAction SilentlyContinue

foreach ($categoryFolder in $repoCategoryFolders) {

    $categoryId = $categoryFolder.Name

    $thumbDir = Join-Path $categoryFolder.FullName "thumbs"

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $thumbDir |
        Out-Null

    $files = Get-ChildItem `
        -Path $categoryFolder.FullName `
        -Filter "*.webp" `
        -File `
        -ErrorAction SilentlyContinue

    foreach ($file in $files) {

        $thumbPath = Join-Path $thumbDir $file.Name

        if (Test-FileHasContent $thumbPath) {
            continue
        }

        Write-Host "Thumbnail missing - creating: $($file.Name)"

        try {

            New-ThumbnailFromWebP `
                -WebPPath $file.FullName `
                -ThumbPath $thumbPath

            $thumbnailCount++
        }
        catch {

            Remove-IfExists $thumbPath

            Move-ToQuarantine `
                -Path $file.FullName `
                -Category $categoryId `
                -Reason "full image cannot be decoded, so no thumbnail is possible"
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
Write-Host "New wallpapers:           $newCount"
Write-Host "Already existing:         $existingCountRun"
Write-Host "Moved categories:         $movedCount"
Write-Host "Thumbnails created:       $thumbnailCount"
Write-Host "Repaired (fake WebP):     $repairedCount"
Write-Host "Duplicate source images:  $duplicateSourceCount"
Write-Host "Categories removed:       $prunedCategoryCount"
Write-Host "Wallpapers removed:       $prunedWallpaperCount"
Write-Host "Problems / skipped:       $($problems.Count)"
Write-Host "============================================================"
Write-Host ""

if ($problems.Count -gt 0) {

    Write-Host "============================================================"
    Write-Host "FILES THAT NEED YOUR ATTENTION"
    Write-Host "============================================================"

    foreach ($problem in $problems) {
        Write-Host " - $problem"
    }

    Write-Host ""
    Write-Host "Damaged files were NOT published. Re-download or replace"
    Write-Host "them in $sourceRoot and run this script again."
    Write-Host "Quarantined files are in: $quarantineRoot"
    Write-Host ""
}


# ============================================================
# REBUILD MANIFEST
# ============================================================

Write-Host "Conversion complete."
Write-Host "Rebuilding manifest from disk..."
Write-Host ""

# Reset so a stale exit code from dwebp/cwebp can't cause a false failure.
$global:LASTEXITCODE = 0

& "$PSScriptRoot\rebuild-manifest.ps1"

if ($LASTEXITCODE -ne 0) {

    throw "rebuild-manifest.ps1 failed."
}

# Safety net: the manifest must not list a category that no longer
# has a source folder (only checked when removal was active).
if ($pruneEnabled) {

    $builtManifest = Get-Content `
        -LiteralPath "$repoRoot\manifest.json" `
        -Raw |
        ConvertFrom-Json

    $staleInManifest = @(
        @($builtManifest.categories) |
            Where-Object { -not $sourceCategoryNames.ContainsKey([string]$_.id) } |
            ForEach-Object { $_.id }
    )

    if ($staleInManifest.Count -gt 0) {

        Add-Problem "manifest.json still lists categories that have no source folder: $($staleInManifest -join ', '). rebuild-manifest.ps1 may be keeping its own category list."
    }
    elseif ($prunedCategoryCount -gt 0) {

        Write-Host "Manifest rebuilt without the $prunedCategoryCount removed categor$(if ($prunedCategoryCount -eq 1) { 'y' } else { 'ies' })."
    }
}


# ============================================================
# PUBLISH: GIT PUSH -> CDN PURGE -> CDN VERIFY
# ============================================================

function Invoke-Git {
    param([string[]]$GitArguments)

    return Invoke-Tool -Exe "git" -Arguments (@("-C", $repoRoot) + $GitArguments)
}

$cdnManifestOk = $null
$cdnImagesChecked = 0
$cdnImagesMissing = @()

if ($NoPush) {

    Write-Host ""
    Write-Host "-NoPush given: skipping git push, CDN purge and CDN verification."
}
else {

    # --------------------------------------------------------
    # 1) COMMIT + PUSH
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "PUBLISHING TO GITHUB"
    Write-Host "============================================================"
    Write-Host ""

    $purgePaths = New-Object System.Collections.ArrayList
    $verifyPaths = New-Object System.Collections.ArrayList

    # The manifest is an existing file, so its old copy is what the
    # CDN caches. It is always purged.
    [void]$purgePaths.Add("manifest.json")

    $committed = $false

    $status = Invoke-Git @("status", "--porcelain")

    if ($status.ExitCode -ne 0) {
        throw "git status failed: $($status.Output.Trim())"
    }

    if (-not [string]::IsNullOrWhiteSpace($status.Output)) {

        $result = Invoke-Git @("add", "-A")

        if ($result.ExitCode -ne 0) {
            throw "git add failed: $($result.Output.Trim())"
        }

        $message = "Update wallpapers ({0})" -f (Get-Date -Format "yyyy-MM-dd HH:mm")

        $result = Invoke-Git @("commit", "-m", $message)

        if ($result.ExitCode -ne 0) {
            throw "git commit failed: $($result.Output.Trim())"
        }

        Write-Host "Committed: $message"

        $committed = $true
    }
    else {

        Write-Host "No new changes to commit."
    }

    # Push even when nothing was committed: a previous manual commit
    # may not have been pushed yet. If it is already up to date this
    # does nothing.
    $result = Invoke-Git @("push", "origin", $gitBranch)

    if ($result.ExitCode -ne 0) {

        throw "git push failed (your wallpapers are converted locally; fix the problem and run the script again, it is safe to repeat): $($result.Output.Trim())"
    }

    Write-Host "Pushed to origin/$gitBranch."

    # --------------------------------------------------------
    # Work out which files this commit added / modified / deleted.
    #   modified or deleted -> CDN may hold an old copy -> purge
    #   added or modified .webp -> must be served -> verify
    # --------------------------------------------------------

    if ($committed) {

        $diff = Invoke-Git @("diff", "--name-status", "--no-renames", "HEAD~1", "HEAD")

        if ($diff.ExitCode -eq 0) {

            foreach ($line in ($diff.Output -split "`r?`n")) {

                if ([string]::IsNullOrWhiteSpace($line)) { continue }

                $parts = $line -split "`t", 2

                if ($parts.Count -lt 2) { continue }

                $code = $parts[0].Trim()
                $path = $parts[1].Trim().Trim('"')

                if (
                    $path -ne "manifest.json" -and
                    ($code -eq "M" -or $code -eq "D")
                ) {
                    [void]$purgePaths.Add($path)
                }

                if (
                    ($code -eq "A" -or $code -eq "M") -and
                    $path -like "*.webp"
                ) {
                    [void]$verifyPaths.Add($path)
                }
            }
        }
        else {

            Write-Warning "Could not list changed files (git diff failed). Only the manifest will be purged."
        }
    }

    if ($VerifyAll) {

        $verifyPaths.Clear()

        Get-ChildItem `
            -Path $wallpapersRoot `
            -Recurse `
            -Filter "*.webp" `
            -File |
            ForEach-Object {

                $relative = $_.FullName.Substring($repoRoot.Length + 1).Replace("\", "/")

                [void]$verifyPaths.Add($relative)
            }
    }


    # --------------------------------------------------------
    # 2) PURGE THE CDN CACHE
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "PURGING CDN CACHE"
    Write-Host "============================================================"
    Write-Host ""

    $purgeList = @($purgePaths | Select-Object -First 100)

    if ($purgePaths.Count -gt 100) {

        Write-Warning "$($purgePaths.Count) files need purging; only the first 100 are purged (purge limits). The rest expire from the cache on their own."
    }

    foreach ($purgePath in $purgeList) {

        try {

            Invoke-WebRequest `
                -Uri "$purgeBase/$purgePath" `
                -UseBasicParsing |
                Out-Null

            Write-Host "Purged: $purgePath"
        }
        catch {

            Write-Warning "Purge failed for $purgePath : $($_.Exception.Message)"
        }
    }


    # --------------------------------------------------------
    # 3) CHECK THE CDN MANIFEST MATCHES THE LOCAL ONE
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "VERIFYING CDN"
    Write-Host "============================================================"
    Write-Host ""

    $localManifest = Get-Content `
        -LiteralPath "$repoRoot\manifest.json" `
        -Raw |
        ConvertFrom-Json

    $localCounts = @{}

    foreach ($category in $localManifest.categories) {

        $localCounts[$category.id] = @($category.wallpapers).Count
    }

    $cdnManifestOk = $false
    $lastMismatch = @()

    for ($attempt = 1; $attempt -le 6; $attempt++) {

        try {

            $cdnManifest = (
                Invoke-WebRequest `
                    -Uri "$cdnBase/manifest.json" `
                    -UseBasicParsing `
                    -Headers @{ "Cache-Control" = "no-cache" }
            ).Content | ConvertFrom-Json

            $lastMismatch = @()

            foreach ($id in $localCounts.Keys) {

                $cdnCategory = $cdnManifest.categories |
                    Where-Object { $_.id -eq $id }

                $cdnCount = 0

                if ($cdnCategory) {
                    $cdnCount = @($cdnCategory.wallpapers).Count
                }

                if ($cdnCount -ne $localCounts[$id]) {

                    $lastMismatch += "$id (local $($localCounts[$id]), CDN $cdnCount)"
                }
            }

            # Categories removed locally must disappear from the CDN manifest too.
            foreach ($cdnCat in @($cdnManifest.categories)) {

                if (-not $localCounts.ContainsKey([string]$cdnCat.id)) {

                    $lastMismatch += "$($cdnCat.id) (removed locally, CDN still lists $(@($cdnCat.wallpapers).Count))"
                }
            }

            if ($lastMismatch.Count -eq 0) {

                $cdnManifestOk = $true
                break
            }

            Write-Host "Attempt $attempt/6: CDN manifest not updated yet: $($lastMismatch -join ', ')"
        }
        catch {

            Write-Host "Attempt $attempt/6: could not fetch CDN manifest: $($_.Exception.Message)"
        }

        if ($attempt -lt 6) {
            Start-Sleep -Seconds 10
        }
    }

    if ($cdnManifestOk) {

        $totalLocal = ($localCounts.Values | Measure-Object -Sum).Sum

        Write-Host "CDN manifest matches local manifest ($totalLocal wallpapers)."
    }
    else {

        Write-Warning "CDN manifest still differs after retries: $($lastMismatch -join ', ')"
        Write-Warning "Usually jsDelivr cache lag. Re-run this script in a few minutes (safe) or purge manually."
    }


    # --------------------------------------------------------
    # 4) CHECK EVERY NEW / CHANGED IMAGE IS SERVED
    # --------------------------------------------------------

    $remaining = @($verifyPaths)
    $cdnImagesChecked = $remaining.Count

    for ($attempt = 1; $attempt -le 3 -and $remaining.Count -gt 0; $attempt++) {

        $stillMissing = @()

        foreach ($relative in $remaining) {

            try {

                $response = Invoke-WebRequest `
                    -Uri "$cdnBase/$relative" `
                    -Method Head `
                    -UseBasicParsing

                if ($response.StatusCode -ne 200) {
                    throw "status $($response.StatusCode)"
                }
            }
            catch {

                $stillMissing += $relative
            }
        }

        $remaining = $stillMissing

        if ($remaining.Count -gt 0 -and $attempt -lt 3) {

            Write-Host "Attempt $attempt/3: $($remaining.Count) file(s) not served yet, retrying..."

            Start-Sleep -Seconds 10
        }
    }

    $cdnImagesMissing = @($remaining)

    Write-Host ""
    Write-Host "Images checked on CDN: $cdnImagesChecked"

    if ($cdnImagesMissing.Count -gt 0) {

        Write-Warning "Not served by the CDN: $($cdnImagesMissing.Count)"

        foreach ($relative in $cdnImagesMissing) {
            Write-Host " - $cdnBase/$relative" -ForegroundColor Red
        }
    }
    else {

        Write-Host "All checked images are being served."
    }
}


# ============================================================
# FINAL REPORT
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "WALLPAPER PUBLISH COMPLETE"
Write-Host "============================================================"

if ($NoPush) {

    Write-Host "Local only (-NoPush): nothing was pushed."
}
elseif ($cdnManifestOk -and $cdnImagesMissing.Count -eq 0) {

    Write-Host "Everything is live on the CDN."
    Write-Host "If the app still shows fewer wallpapers, it is using its own cached manifest."
}
else {

    Write-Host "Published to GitHub, but the CDN is not fully caught up yet (see warnings above)."
}

if ($problems.Count -gt 0) {

    Write-Host ""
    Write-Host "Reminder: $($problems.Count) source file problem(s) were reported earlier in this run."
}
param(
    [string]$CsvPath = "servers.csv",
    [string]$JsonPath = "servers.json",
    [string]$OutSvg = "servers-per-day.svg",
    [string]$OutMd = "summary.md"
)

# Ensure script stops on errors
$ErrorActionPreference = 'Stop'

function ConvertTo-DateTime {
    param([string]$s)
    if (-not $s) { return $null }
    [string[]]$formats = @(
        "yyyy-MM-ddTHH:mm:ss.fffffffZ",
        "yyyy-MM-ddTHH:mm:ss.ffffffZ",
        "yyyy-MM-ddTHH:mm:ssZ",
        "yyyy-MM-ddTHH:mm:ss",
        "M/d/yyyy h:mm:ss tt",
        "M/d/yyyy h:mm tt",
        "M/d/yyyy H:mm:ss",
        "M/d/yyyy"
    )
    $dt = $null
    foreach ($fmt in $formats) {
        try {
            $tmp = [DateTime]::ParseExact([string]$s, $fmt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
            return $tmp.ToUniversalTime()
        } catch {
            # ignore and try next format
        }
    }
    try {
        $tmp = [DateTime]::Parse([string]$s)
        return $tmp.ToUniversalTime()
    } catch {
        try {
            $tmp2 = Get-Date -Date $s -ErrorAction Stop
            return $tmp2.ToUniversalTime()
        } catch {
            return $null
        }
    }
}

$records = @()
$jsonCategoryMap = @{} # name -> object with PackageCategories (HashSet) and HasRemote

# Helper to derive package categories from a JSON server object
function Get-PackageCategoriesFromJsonObject {
    param([psobject]$obj)
    $categories = [System.Collections.Generic.HashSet[string]]::new()
    # Support both old schema (packages at top-level) and new schema (packages under server.packages)
    $pkgContainer = $null
    if ($obj.packages) { $pkgContainer = $obj.packages }
    elseif ($obj.server -and $obj.server.packages) { $pkgContainer = $obj.server.packages }
    if ($pkgContainer) {
        foreach ($pkg in $pkgContainer) {
            $rt = $pkg.registryType
            if (-not $rt -and $pkg.registryType) { $rt = $pkg.registryType }
            if ($rt) { $categories.Add($rt.ToLowerInvariant()) | Out-Null }
        }
    }
    return ,$categories
}

function Get-HasRemoteFromJsonObject {
    param([psobject]$obj)
    # Support remotes either at top-level (old) or under server.remotes (new)
    if ($obj.remotes -and $obj.remotes.Count -gt 0) { return $true }
    if ($obj.server -and $obj.server.remotes -and $obj.server.remotes.Count -gt 0) { return $true }
    return $false
}

if (Test-Path $CsvPath) {
    Write-Host "Reading CSV: $CsvPath"
    try {
        Import-Csv -Path $CsvPath | ForEach-Object {
            $name = $_.name
            $p = $_.publishedAt
            $dt = ConvertTo-DateTime $p
            if ($null -ne $dt -and $name) {
                $records += [PSCustomObject]@{ Name = $name; PublishedAt = $dt }
            }
        }
    } catch {
        Write-Warning "Failed to read CSV: $_"
    }
}

if (Test-Path $JsonPath) {
    Write-host "Reading JSON: $JsonPath"
    try {
        $json = Get-Content -Raw -Path $JsonPath | ConvertFrom-Json
    # $json can be an array of PSObjects; check for IEnumerable with count
        if ($json -and ($json -is [System.Collections.IEnumerable]) -and $json.Count -gt 0) {
            foreach ($item in $json) {
                # Name detection (support old schema: name at top-level; new schema: server.name)
                $name = $item.name; if (-not $name) { $name = $item.Name }
                if (-not $name -and $item.server -and $item.server.name) { $name = $item.server.name }

                # PublishedAt detection (support old schema: publishedAt at top-level; new schema: _meta."io.modelcontextprotocol.registry/official".publishedAt)
                $p = $item.publishedAt; if (-not $p) { $p = $item.publishedAt }
                if (-not $p -and $item._meta -and $item._meta.'io.modelcontextprotocol.registry/official' -and $item._meta.'io.modelcontextprotocol.registry/official'.publishedAt) {
                    $p = $item._meta.'io.modelcontextprotocol.registry/official'.publishedAt
                }
                $dt = ConvertTo-DateTime $p
                if ($null -ne $dt -and $name) {
                    $records += [PSCustomObject]@{ Name = $name; PublishedAt = $dt }
                }
                if ($name) {
                    if (-not $jsonCategoryMap.ContainsKey($name)) {
                        $jsonCategoryMap[$name] = [PSCustomObject]@{ PackageCategories = [System.Collections.Generic.HashSet[string]]::new(); HasRemote = $false }
                    }
                    $entry = $jsonCategoryMap[$name]
                    # Pass entire item; helper handles both schemas
                    $pkgCats = Get-PackageCategoriesFromJsonObject -obj $item
                    foreach ($c in $pkgCats) { if ($c) { $entry.PackageCategories.Add($c) | Out-Null } }
                    if ((Get-HasRemoteFromJsonObject -obj $item)) { $entry.HasRemote = $true }
                }
            }
            Write-Host "Parsed $($records.Count) records (including JSON) so far." -ForegroundColor Green
        }
    } catch {
        Write-Warning "Failed to read JSON: $_"
    }
}

if ($records.Count -eq 0) {
    Write-Warning "No records found in $CsvPath or $JsonPath. Exiting."
    exit 0
}

# Normalize date (UTC date string yyyy-MM-dd)
$records | ForEach-Object { $_ | Add-Member -NotePropertyName PublishedDate -NotePropertyValue ($_.PublishedAt.ToString('yyyy-MM-dd')) -Force }

# Compute unique server names per day
$perDay = @{}
foreach ($r in $records) {
    $d = $r.PublishedDate
    if (-not $perDay.ContainsKey($d)) { $perDay[$d] = [System.Collections.Generic.HashSet[string]]::new() }
    $perDay[$d].Add($r.Name) | Out-Null
}

# Convert to array of objects sorted by date
$series = $perDay.GetEnumerator() | ForEach-Object {
    [PSCustomObject]@{ Date = $_.Key; UniqueCount = ($_.Value.Count) }
} | Sort-Object { [DateTime]::ParseExact($_.Date,'yyyy-MM-dd',[System.Globalization.CultureInfo]::InvariantCulture) }

# Basic stats
$totalRecords = $records.Count
$totalUniqueNames = ($records | Select-Object -ExpandProperty Name | Sort-Object -Unique).Count
$firstDate = ($series | Select-Object -First 1).Date
$lastDate = ($series | Select-Object -Last 1).Date
$maxEntry = $series | Sort-Object -Property UniqueCount -Descending | Select-Object -First 1
$avg = [math]::Round(($series | Measure-Object -Property UniqueCount -Average).Average,2)

# Vega-Lite spec generation and rendering via npx vl2svg (no custom JS needed)
try {
    # compute an appropriate chart width/height for Vega-Lite based on number of columns
    $labelRotation = -45
    $marginLeft = 40
    $marginRight = 40
    $marginBottom = if ($labelRotation -ne 0) { 120 } else { 80 }
    $perBarWidthEstimate = 36
    $minWidth = 700
    $chartWidth = [Math]::Max($minWidth, ($series.Count * $perBarWidthEstimate) + $marginLeft + $marginRight)
    $chartWidth = [Math]::Min($chartWidth, 3000)
    $chartHeight = 480

     # Build line + moving-average layered Vega-Lite spec
     $avgValue = [math]::Round((($series | Measure-Object -Property UniqueCount -Average).Average),2)
         $vl = [ordered]@{
          '$schema' = 'https://vega.github.io/schema/vega-lite/v5.json'
          description = 'Unique servers published per day (line + 7d moving average)'
          background = 'white'
          width = $chartWidth
          height = $chartHeight
          data = @{ values = @() }
        transform = @(
            @{ window = @(@{ op='mean'; field='count'; as='ma7' }); frame = @(-6,0); sort = @(@{ field='date' }) }
            @{ joinaggregate = @(@{ op='argmax'; field='count'; as='peakRow' }) }
            @{ window = @(@{ op='row_number'; as='rowNumber' }); sort = @(@{ field='date' }) }
            @{ joinaggregate = @(@{ op='max'; field='rowNumber'; as='lastRow' }) }
            @{ calculate = 'datum.rowNumber === datum.lastRow'; as = 'isLast' }
            @{ calculate = 'datum.count === datum.peakRow.count ? true : false'; as = 'isPeak' }  # boolean expression inside Vega (string retained)
        )
          layer = @(
                # Subtle area backdrop
                @{ mark = @{ type='area'; interpolate='monotone'; opacity=0.18; color='#4e79a7' }
                    encoding = @{ x = @{ field='date'; type='temporal'; axis=@{ labelAngle = $labelRotation; format='%Y-%m-%d'; title='Date'; grid=$false } }
                                      y = @{ field='count'; type='quantitative'; axis=@{ title='Unique server names'; grid=$true } } }
                }
                # Raw line
                     @{ mark = @{ type='line'; interpolate='monotone'; stroke='#4e79a7'; strokeWidth=2 }
                    encoding = @{ x = @{ field='date'; type='temporal' }
                                      y = @{ field='count'; type='quantitative' } }
                }
                # Moving average line
                @{ mark = @{ type='line'; interpolate='monotone'; stroke='#d62728'; strokeWidth=2; strokeDash=@(6,4) }
                    encoding = @{ x = @{ field='date'; type='temporal' }
                                      y = @{ field='ma7'; type='quantitative' } }
                }
                # Points with tooltip
                @{ mark = @{ type='point'; filled=$true; size=50; color='#4e79a7' }
                    selection = @{ hover = @{ type='single'; on='mouseover'; nearest=$true; empty='none' } }
                    encoding = @{ x = @{ field='date'; type='temporal' }
                                      y = @{ field='count'; type='quantitative' }
                                      tooltip = @(
                                          @{ field='date'; type='temporal'; title='Date' }
                                          @{ field='count'; type='quantitative'; title='Daily unique' }
                                          @{ field='ma7'; type='quantitative'; title='7d avg' }
                                      )
                                      opacity = @{ condition = @{ selection='hover'; value=1 }; value=0.55 } }
                }
                # Peak highlight
                @{ mark = @{ type='point'; shape='diamond'; size=140; filled=$true; color='#ff9900'; stroke='#b36b00'; strokeWidth=1.5 }
                    encoding = @{ x = @{ field='date'; type='temporal' }
                                      y = @{ field='count'; type='quantitative' }
                                      opacity = @{ condition = @{ test='datum.isPeak == true'; value=1 }; value=0 }
                                      tooltip = @(
                                          @{ field='date'; type='temporal'; title='Peak date' }
                                          @{ field='count'; type='quantitative'; title='Peak unique count' }
                                      ) }
                }
                # Average reference rule
                @{ mark = @{ type='rule'; color='#d62728'; strokeDash=@(4,4); strokeWidth=1.5 }
                    encoding = @{ y = @{ datum = $avgValue } }
                }
                # Average label (set at last date via isLast flag)
                @{ transform = @(@{ filter = 'datum.isLast == true' })
                   mark = @{ type='text'; align='left'; dx=6; dy=-6; fontSize=12; color='#d62728' }
                   encoding = @{ x = @{ field='date'; type='temporal' }
                                     y = @{ datum = $avgValue }
                                     text = @{ value = "Avg: $avgValue" } }
                }
          )
          config = @{ axis = @{ labelFont='Segoe UI'; titleFont='Segoe UI'; labelFontSize=11; titleFontSize=13; tickColor='#bbb'; domainColor='#888' }
                            view = @{ stroke='transparent' } }
     }
    foreach ($p in $series) { $vl.data.values += @{ date = $p.Date; count = $p.UniqueCount } }
    $vlPath = Join-Path -Path (Get-Location) -ChildPath 'servers-per-day.vl.json'
    $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $False
    [System.IO.File]::WriteAllLines($vlPath, ($vl | ConvertTo-Json -Depth 100), $Utf8NoBomEncoding)

    # Use vega-cli (provides vl2svg) explicitly with vega & vega-lite, fallback to node renderer.
    $output = npx -y -p vega-cli -p vega -p vega-lite -- vl2svg $vlPath
    if ($LASTEXITCODE -eq 0) {
        [System.IO.File]::WriteAllLines($OutSvg, $output, $Utf8NoBomEncoding)
        Write-Host "Vega rendered to $OutSvg via vega-cli" -ForegroundColor Green
    } else {
        Write-Warning "vl2svg (vega-cli) failed (exit $LASTEXITCODE)."
    }
} catch {
    Write-Warning "Exception during Vega rendering: $_"
}

# Derive classification per unique server name
# Strategy: for each unique Name, union all package categories observed; set HasRemote true if any record has remote.
$byName = $records | Group-Object -Property Name
$nameClassifications = @{}
foreach ($g in $byName) {
    $name = $g.Name
    $unionCats = [System.Collections.Generic.HashSet[string]]::new()
    $anyRemote = $false
    if ($jsonCategoryMap.ContainsKey($name)) {
        $entry = $jsonCategoryMap[$name]
        foreach ($c in $entry.PackageCategories) { if ($c) { $unionCats.Add($c) | Out-Null } }
        if ($entry.HasRemote) { $anyRemote = $true }
    }
    # Determine final category label
    $label = $null
    if ($unionCats.Count -gt 0) {
        if ($unionCats.Count -eq 1) { $label = ($unionCats | Select-Object -First 1) }
        else { $label = ($unionCats | Sort-Object) -join '+' }
    } elseif ($anyRemote) {
        $label = 'remote'
    } else {
        $label = 'none'
    }
    $nameClassifications[$name] = [PSCustomObject]@{ Name = $name; Category = $label }
}

# Aggregate counts per category (unique names)
$categoryCounts = $nameClassifications.Values | Group-Object -Property Category | ForEach-Object {
    [PSCustomObject]@{ Category = $_.Name; UniqueNames = $_.Count }
} | Sort-Object -Property UniqueNames, Category -Descending

$categoryTotal = ($nameClassifications.Count)
foreach ($row in $categoryCounts) {
    $row | Add-Member -NotePropertyName Percent -NotePropertyValue ([math]::Round(($row.UniqueNames / $categoryTotal) * 100,2)) -Force
}

# Debug stats (comment out later if noisy)
$namesWithPkg = ($nameClassifications.Keys | Where-Object { $jsonCategoryMap.ContainsKey($_) -and $jsonCategoryMap[$_].PackageCategories.Count -gt 0 }).Count
$namesWithRemote = ($nameClassifications.Keys | Where-Object { $jsonCategoryMap.ContainsKey($_) -and $jsonCategoryMap[$_].HasRemote }).Count
Write-Host "Unique names with at least one package category: $namesWithPkg" -ForegroundColor Cyan
Write-Host "Unique names with remote definitions: $namesWithRemote" -ForegroundColor Cyan

# Derive top domains (normalized) from unique server names
# Each server Name is assumed to start with a reversed domain segment (e.g. "io.github.example/whatever").
# We take the substring before the first '/', lowercase it, reverse the dot segments to restore the canonical domain
# (e.g. "io.github.example" -> "example.github.io"), then count how many unique server names map to that domain.
$domainCounts = @{}
foreach ($g in $byName) {
    $fullName = $g.Name
    if (-not $fullName) { continue }
    $prefix = ($fullName -split '/',2)[0]
    if (-not $prefix) { continue }
    # strip any port if present
    $prefix = ($prefix -split ':',2)[0]
    $prefix = $prefix.ToLowerInvariant()
    $parts = $prefix -split '\.'
    if ($parts.Length -gt 1) {
        $rev = $parts.Clone()
        [array]::Reverse($rev)
        $normDomain = ($rev -join '.')
    } else {
        $normDomain = $prefix
    }
    if (-not $domainCounts.ContainsKey($normDomain)) {
        $domainCounts[$normDomain] = [System.Collections.Generic.HashSet[string]]::new()
    }
    $domainCounts[$normDomain].Add($fullName) | Out-Null
}

$domainStats = $domainCounts.GetEnumerator() | ForEach-Object {
    $domain = $_.Key
    $nameSet = $_.Value
    $catSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($n in $nameSet) {
        if ($nameClassifications.ContainsKey($n)) {
            $c = $nameClassifications[$n].Category
            if ($c) { $catSet.Add($c) | Out-Null }
        }
    }
    if ($catSet.Count -eq 0) { $catSet.Add('none') | Out-Null }
    $catList = ($catSet | Sort-Object) -join ', '
    [PSCustomObject]@{ Domain = $domain; UniqueServerNames = $nameSet.Count; Categories = $catList }
} | Sort-Object -Property UniqueServerNames, Domain -Descending | Select-Object -First 20

# Build summary.md content
$md = @()
$md += "# Servers published summary"
$md += ""
$md += "Generated on: $(Get-Date -Format o)"
$md += ""
$md += "![Unique servers per day]($OutSvg)"
$md += ""
$md += "## Quick facts"
$md += "- Total records processed: $totalRecords"
$md += "- Total unique server names: $totalUniqueNames"
$md += "- Date range: $firstDate to $lastDate"
$md += "- Peak day: $($maxEntry.Date) with $($maxEntry.UniqueCount) unique server names"
$md += "- Average unique server names per day: $avg"

$md += ""
$md += "## Top 5 busiest days"
$top5 = $series | Sort-Object -Property UniqueCount -Descending | Select-Object -First 5
foreach ($t in $top5) { $md += "- $($t.Date): $($t.UniqueCount) unique servers" }

$md += ""
$md += "## Unique server names by category"
$md += ""
$md += "| Category | Unique Server Names | % of Total |"
$md += "|----------|---------------------:|-----------:|"
foreach ($row in $categoryCounts) {
    $md += "| $($row.Category) | $($row.UniqueNames) | $($row.Percent)% |"
}
if ($categoryCounts.Count -eq 0) { $md += "| (none) | 0 | 0% |" }

$md += ""
$md += "## Top 20 domains by unique server names"
$md += ""
$md += "| Domain | Unique Server Names | Categories |"
$md += "|--------|---------------------:|------------|"
if ($domainStats -and $domainStats.Count -gt 0) {
    foreach ($d in $domainStats) {
        $md += "| $($d.Domain) | $($d.UniqueServerNames) | $($d.Categories) |"
    }
} else {
    $md += "| (none) | 0 | (none) |"
}

# Save summary.md
try {
    $md -join "`n" | Set-Content -Path $OutMd -Encoding UTF8
    Write-Host "Wrote summary to $OutMd"
} catch {
    Write-Warning "Failed to write summary: $_"
}

Write-Host "Done. Open $OutMd to see the summary and $OutSvg for the chart."
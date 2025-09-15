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

if (Test-Path $CsvPath) {
    Write-Host "Reading CSV: $CsvPath"
    try {
        Import-Csv -Path $CsvPath | ForEach-Object {
            $name = $_.name
            $p = $_.published_at
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
        if ($json -is [System.Management.Automation.PSObject] -and $json.Count -gt 0) {
            foreach ($item in $json) {
                $name = $item.name
                if (-not $name) { $name = $item.Name }
                $p = $item.published_at; if (-not $p) { $p = $item.publishedAt }
                $dt = ConvertTo-DateTime $p
                if ($null -ne $dt -and $name) {
                    $records += [PSCustomObject]@{ Name = $name; PublishedAt = $dt }
                }
            }
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
    $vl | ConvertTo-Json -Depth 6 | Set-Content -Path $vlPath -Encoding UTF8

    if (Get-Command npx -ErrorAction SilentlyContinue) {
        # Use vl2svg to directly produce SVG
        & npx -y -p vega -p vega-lite vl2svg $vlPath > $OutSvg
        if ($LASTEXITCODE -eq 0 -and (Test-Path $OutSvg)) {
            Write-Host "Vega rendered to $OutSvg"
        } else {
            Write-Warning "vl2svg failed (exit $LASTEXITCODE). SVG not generated."
        }
    } else {
        Write-Warning "npx not found in PATH. Install Node.js (which provides npx) to enable Vega rendering."
    }
} catch {
    Write-Warning "Exception during Vega rendering: $_"
}

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

# Compute simple growth between first and last day
$firstCount = ($series | Select-Object -First 1).UniqueCount
$lastCount = ($series | Select-Object -Last 1).UniqueCount
if ($firstCount -ne 0) {
    $pct = [math]::Round((($lastCount - $firstCount) / $firstCount) * 100,2)
    $md += "- Change from first to last day: $pct% ($firstCount -> $lastCount)"
} else {
    $md += "- Change from first to last day: N/A (first day had zero unique servers)"
}

$md += ""
$md += "## Top 5 busiest days"
$top5 = $series | Sort-Object -Property UniqueCount -Descending | Select-Object -First 5
foreach ($t in $top5) { $md += "- $($t.Date): $($t.UniqueCount) unique servers" }

# Save summary.md
try {
    $md -join "`n" | Set-Content -Path $OutMd -Encoding UTF8
    Write-Host "Wrote summary to $OutMd"
} catch {
    Write-Warning "Failed to write summary: $_"
}

Write-Host "Done. Open $OutMd to see the summary and $OutSvg for the chart."
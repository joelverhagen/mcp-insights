<#
pull-data.ps1

Fetch all MCP server metadata from the official registry and write a
formatted JSON array of servers sorted by a stable key.

Usage examples:
  .\pull-data.ps1                 # writes servers.json next to the script
  .\pull-data.ps1 -OutputFile c:\tmp\all-servers.json -FilterActive
#>

param(
    [string]
    $BaseUrl = 'https://registry.modelcontextprotocol.io',

    [string]
    $OutputFile = (Join-Path -Path $PSScriptRoot -ChildPath 'servers.json'),

    [int]
    $MaxRetries = 3,

    [int]
    $RetryDelaySeconds = 2,

    [int]
    $RequestTimeoutSeconds = 30,

    [switch]
    $FilterActive
)

function Invoke-LogRequest {
    param(
        [string]$Uri,
        [int]$Attempt = 0,
        [string]$Result = 'INFO',
        [string]$Message = ''
    )

    # Print a timestamped log line to the console so the user sees every
    # request and its outcome in real time.
    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $line = "$timestamp`t$Result`tAttempt:$Attempt`t$Uri`t$Message"
    Write-Host $line
}

# Helper: perform GET with simple retry/backoff and handle 429 Retry-After.
function Invoke-GetWithRetry {
    param(
        [string]$Uri,
        [int]$Attempts = $MaxRetries
    )

    $headers = @{
        'Accept' = 'application/json'
        'User-Agent' = 'mcp-insights/0.1 (https://github.com/joelverhagen/mcp-insights)'
    }

    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Write-Verbose "GET $Uri (attempt $i)"
            Invoke-LogRequest -Uri $Uri -Attempt $i -Result 'START' -Message ''
            $response = Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -TimeoutSec $RequestTimeoutSeconds -ErrorAction Stop
            Invoke-LogRequest -Uri $Uri -Attempt $i -Result 'SUCCESS' -Message 'OK'
            return $response
        }
        catch {
            $err = $_
            Invoke-LogRequest -Uri $Uri -Attempt $i -Result 'ERROR' -Message $err.Exception.Message
            # If server returned a 429 with Retry-After header, wait the specified seconds
            if ($err.Exception -and $err.Exception.Response -and $err.Exception.Response.Headers) {
                $retryAfter = $err.Exception.Response.Headers['Retry-After']
                if ($retryAfter) {
                    $wait = 0
                    if ([int]::TryParse($retryAfter, [ref]$wait)) {
                        Invoke-LogRequest -Uri $Uri -Attempt $i -Result 'RETRY' -Message "Retry-After:$wait"
                        Write-Verbose "Received Retry-After: waiting $wait seconds"
                        Start-Sleep -Seconds $wait
                        continue
                    }
                }
            }

            if ($i -lt $Attempts) {
                $backoff = $RetryDelaySeconds * [math]::Pow(2, $i - 1)
                Invoke-LogRequest -Uri $Uri -Attempt $i -Result 'RETRY' -Message "Backoff:${backoff}s"
                Write-Verbose "Request failed (attempt $i/$Attempts). Backing off ${backoff}s and retrying. Error: $($_.Exception.Message)"
                Start-Sleep -Seconds $backoff
                continue
            }

            throw "Failed to GET $Uri after $Attempts attempts: $($_.Exception.Message)"
        }
    }
}

# Build a well-formed full URI for the /v0/servers endpoint, safely handling
# cursor values that may include stray characters. This prevents malformed
# URIs like "=16e0..." from being used in requests.
function Build-ServersUri {
    param(
        [string]$BaseUrl,
        [string]$Cursor
    )

    $baseUri = [System.Uri]::new($BaseUrl)
    $builder = New-Object System.UriBuilder($baseUri)

    # Ensure the endpoint path is appended exactly once.
    $builder.Path = ($builder.Path.TrimEnd('/') + '/v0/servers')

    $builder.Query = 'limit=100'

    if (-not [string]::IsNullOrWhiteSpace($Cursor)) {
        $builder.Query += "&cursor=$([System.Net.WebUtility]::UrlEncode($Cursor))"
    }

    return $builder.Uri.AbsoluteUri
}

# Collect all pages
$allServers = @()
$cursor = $null
$page = 0

do {
    $page++
    # Use the helper to always get a valid, full URL for the request.
    $uri = Build-ServersUri -BaseUrl $BaseUrl -Cursor $cursor

    Write-Verbose "Fetching page $page - $uri"
    try {
        $resp = Invoke-GetWithRetry -Uri $uri
    }
    catch {
        Write-Error $_
        break
    }

    if (-not $resp) {
        Write-Warning "Empty response for page $page; stopping."
        break
    }

    if ($null -ne $resp.servers) {
        # Ensure we append each server object
        foreach ($s in $resp.servers) {
            $allServers += $s
        }
    }

    # metadata.next_cursor is provided when there are more pages
    $cursor = if ($resp.metadata -and $resp.metadata.next_cursor) { $resp.metadata.next_cursor } else { $null }

    # Be polite with the registry
    Start-Sleep -Milliseconds 1000

} while ($cursor)

Write-Verbose "Fetched total servers: $($allServers.Count)"

if ($FilterActive) {
    $countBefore = $allServers.Count
    $allServers = $allServers | Where-Object { $_.status -eq 'active' }
    Write-Verbose "Filtered active servers: $($allServers.Count) (from $countBefore)"
}

# Require publishedAt to be present for every server and error out if missing.
$missing = $allServers | Where-Object {
    -not ($_. _meta -and $_._meta.'io.modelcontextprotocol.registry/official' -and $_._meta.'io.modelcontextprotocol.registry/official'.publishedAt)
}
if ($missing -and $missing.Count -gt 0) {
    $first = $missing[0]
    $identity = if ($first.name) { "name='$($first.name)'" } else { "index=$([Array]::IndexOf($allServers, $first))" }
    throw "Missing required publishedAt in _meta.io.modelcontextprotocol.registry/official for server $identity. Aborting."
}

# Sort by publishedAt as strings (ISO 8601 UTC strings sort lexicographically correctly).
# To make ordering deterministic for equal timestamps, pre-sort by name ascending so
# name acts as a stable tie-breaker.
$allServers = $allServers | Sort-Object -Property 'name'
$sorted = $allServers | Sort-Object -Property { $_._meta.'io.modelcontextprotocol.registry/official'.publishedAt }

# Write formatted JSON (increase depth to accommodate nested objects)
$depth = 100
$json = $sorted | ConvertTo-Json -Depth $depth

# Ensure directory exists
$dir = Split-Path -Path $OutputFile -Parent
if (-not (Test-Path -Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

# Write file using UTF8 without BOM. Use GetFullPath instead of Resolve-Path so
# the output path can be computed even when the file does not yet exist.
try {
    $fullPath = [System.IO.Path]::GetFullPath($OutputFile)
    [System.IO.File]::WriteAllText($fullPath, $json, [System.Text.Encoding]::UTF8)
    Write-Output "Wrote $($sorted.Count) servers to $fullPath"
}
catch {
    throw "Failed to write to output file '$OutputFile': $($_.Exception.Message)"
}

# Create a compact CSV summary with selected fields
try {
    $serverRecords = $sorted | ForEach-Object {
        $meta = $null
        if ($_. _meta -and $_._meta.'io.modelcontextprotocol.registry/official') {
            $meta = $_._meta.'io.modelcontextprotocol.registry/official'
        }

        [PSCustomObject]@{
            name = $_.name
            version = $_.version
            id = if ($meta) { $meta.id } else { $null }
            publishedAt = if ($meta) { $meta.publishedAt } else { $null }
            updatedAt = if ($meta) { $meta.updatedAt } else { $null }
        }
    }

    $csvPath = Join-Path -Path $dir -ChildPath 'servers.csv'
    $serverRecords | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Output "Wrote CSV ($($serverRecords.Count) rows) to $csvPath"
}
catch {
    throw "Failed to write CSV: $($_.Exception.Message)"
}

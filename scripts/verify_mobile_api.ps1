$ErrorActionPreference = "Stop"

$apiBase = if ($env:RCMCA_API_URL) { $env:RCMCA_API_URL.TrimEnd("/") } else { "http://127.0.0.1:8001" }
$issueId = $null
$seed = Get-Random -Minimum 1000 -Maximum 900000
$latitude = 17.17 + ($seed / 10000000.0)
$longitude = 78.61 + ($seed / 10000000.0)

try {
    $firstBody = @{
        category = "pothole"
        description = "Mobile capture metadata integration check."
        latitude = $latitude
        longitude = $longitude
        severity = 3
        evidence_image_url = "https://cdn.example.invalid/evidence/first.jpg"
        capture_accuracy_m = 4.2
        capture_heading_degrees = 122.5
        captured_at = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json
    $first = Invoke-RestMethod -Method Post -Uri "$apiBase/api/v1/issues/report" `
        -ContentType "application/json" -Body $firstBody -TimeoutSec 15
    $issueId = [string]$first.issue.id
    if ($first.issue.evidence.Count -ne 1 -or
        [math]::Abs($first.issue.evidence[0].accuracy_m - 4.2) -gt 0.001 -or
        [math]::Abs($first.issue.evidence[0].heading_degrees - 122.5) -gt 0.001) {
        throw "First report evidence metadata was not persisted"
    }

    $secondBody = @{
        category = "pothole"
        description = "Second nearby mobile capture evidence."
        latitude = $latitude + 0.00004
        longitude = $longitude
        severity = 4
        evidence_image_url = "https://cdn.example.invalid/evidence/second.jpg"
        capture_accuracy_m = 8.6
        capture_heading_degrees = 239.0
        captured_at = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json
    $second = Invoke-RestMethod -Method Post -Uri "$apiBase/api/v1/issues/report" `
        -ContentType "application/json" -Body $secondBody -TimeoutSec 15
    if (-not $second.deduplicated -or $second.issue.id -ne $issueId -or
        $second.issue.report_count -ne 2 -or $second.issue.evidence.Count -ne 2) {
        throw "Nearby report did not merge while retaining both evidence items"
    }

    $stored = Invoke-RestMethod -Method Get -Uri "$apiBase/api/v1/issues/$issueId" -TimeoutSec 15
    if ($stored.evidence.Count -ne 2 -or
        $stored.evidence[0].image_url -ne "https://cdn.example.invalid/evidence/first.jpg" -or
        $stored.evidence[1].image_url -ne "https://cdn.example.invalid/evidence/second.jpg") {
        throw "Issue detail endpoint did not return the full evidence gallery"
    }

    [pscustomobject]@{
        createdIssue = $issueId
        nearbyReportDeduplicated = $second.deduplicated
        reportCount = $stored.report_count
        evidenceCount = $stored.evidence.Count
        captureAccuracyM = $stored.evidence[0].accuracy_m
        captureHeadingDegrees = $stored.evidence[0].heading_degrees
    } | ConvertTo-Json -Compress
}
finally {
    if ($issueId -match "^[0-9a-fA-F-]{36}$") {
        docker compose exec -T postgis psql -v ON_ERROR_STOP=1 -U postgres -d road_intelligence `
            -c "DELETE FROM road_issues WHERE id = '$issueId'" | Out-Null
    }
}

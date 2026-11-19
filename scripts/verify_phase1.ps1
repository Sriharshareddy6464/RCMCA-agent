$ErrorActionPreference = "Stop"

$apiBase = if ($env:RCMCA_API_URL) { $env:RCMCA_API_URL.TrimEnd("/") } else { "http://127.0.0.1:8001" }
$issueId = $null

try {
    $health = Invoke-RestMethod -Method Get -Uri "$apiBase/health" -TimeoutSec 10
    if ($health.status -ne "ok") { throw "Health endpoint did not return ok" }

    $routeBody = @{
        origin = @{ latitude = 17.437; longitude = 78.448 }
        destination = @{ latitude = 17.443; longitude = 78.376 }
    } | ConvertTo-Json -Depth 5
    $route = Invoke-RestMethod -Method Post -Uri "$apiBase/api/v1/routes/plan" `
        -ContentType "application/json" -Body $routeBody -TimeoutSec 30
    if ($route.distance_m -le 0 -or $route.duration_s -le 0 -or $route.alternatives_considered -lt 1) {
        throw "Route response was incomplete"
    }

    $reportBody = @{
        category = "pothole"
        description = "RCMCA integration smoke test issue."
        latitude = 17.3201
        longitude = 78.6701
        severity = 2
    } | ConvertTo-Json
    $first = Invoke-RestMethod -Method Post -Uri "$apiBase/api/v1/issues/report" `
        -ContentType "application/json" -Body $reportBody -TimeoutSec 15
    $issueId = [string]$first.issue.id
    if ($first.deduplicated -or $first.issue.report_count -ne 1) {
        throw "Initial report was not inserted correctly"
    }

    $duplicateBody = @{
        category = "pothole"
        description = "RCMCA duplicate report for deduplication check."
        latitude = 17.32015
        longitude = 78.6701
        severity = 4
    } | ConvertTo-Json
    $duplicate = Invoke-RestMethod -Method Post -Uri "$apiBase/api/v1/issues/report" `
        -ContentType "application/json" -Body $duplicateBody -TimeoutSec 15
    if (-not $duplicate.deduplicated -or $duplicate.issue.id -ne $issueId -or
        $duplicate.issue.report_count -ne 2 -or $duplicate.issue.severity -ne 4) {
        throw "25m deduplication did not merge the report as expected"
    }

    $confirmBody = @{
        issue_id = $issueId
        user_id = "6e6b4e3b-5a0e-45d3-b5ea-82e625e87f57"
        vote_type = "CONFIRM"
    } | ConvertTo-Json
    $confirmed = Invoke-RestMethod -Method Post -Uri "$apiBase/api/v1/issues/verify" `
        -ContentType "application/json" -Body $confirmBody -TimeoutSec 15
    $repeated = Invoke-RestMethod -Method Post -Uri "$apiBase/api/v1/issues/verify" `
        -ContentType "application/json" -Body $confirmBody -TimeoutSec 15
    if ($confirmed.confidence_score -ne 1.5 -or $confirmed.status -ne "active_hazard" -or
        $repeated.confidence_score -ne 1.5) {
        throw "Confirm vote confidence/status was incorrect"
    }

    foreach ($userId in @("be473fe4-1c7a-4bca-840b-2123c0bbf1f1", "a8c3b4b3-d047-4cb4-8413-ce19f5d52239")) {
        $resolveBody = @{
            issue_id = $issueId
            user_id = $userId
            vote_type = "RESOLVED"
        } | ConvertTo-Json
        $resolved = Invoke-RestMethod -Method Post -Uri "$apiBase/api/v1/issues/verify" `
            -ContentType "application/json" -Body $resolveBody -TimeoutSec 15
    }
    if ($resolved.confidence_score -ne 0 -or $resolved.status -ne "resolved") {
        throw "Resolution confidence/status was incorrect"
    }

    [pscustomobject]@{
        health = $health.status
        routeMeters = $route.distance_m
        routeAlternatives = $route.alternatives_considered
        deduplicated = $duplicate.deduplicated
        mergedReportCount = $duplicate.issue.report_count
        repeatedVoteConfidence = $repeated.confidence_score
        resolvedConfidence = $resolved.confidence_score
        resolvedStatus = $resolved.status
    } | ConvertTo-Json -Compress
}
finally {
    if ($issueId -match "^[0-9a-fA-F-]{36}$") {
        docker compose exec -T postgis psql -v ON_ERROR_STOP=1 -U postgres -d road_intelligence `
            -c "DELETE FROM road_issues WHERE id = '$issueId'" | Out-Null
    }
}

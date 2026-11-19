$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$dataDirectory = Join-Path $projectRoot "osrm-data"
$regionalExtract = Join-Path $dataDirectory "southern-zone-latest.osm.pbf"
if (-not (Test-Path -LiteralPath $regionalExtract)) {
    throw "OSM input is missing. Run: python scripts/download_osm.py"
}

$mountPath = (Resolve-Path -LiteralPath $dataDirectory).Path
$osmiumImage = "rcmca/osmium-tool:local"
$osrmImage = "ghcr.io/project-osrm/osrm-backend:v5.27.1"

docker build -t $osmiumImage -f (Join-Path $projectRoot "Dockerfile.osmium") $projectRoot
if ($LASTEXITCODE -ne 0) { throw "Could not build the Osmium helper image" }

docker run --rm --volume "${mountPath}:/data" $osmiumImage extract `
    -b 78.15,17.15,78.72,17.62 --strategy=complete_ways `
    /data/southern-zone-latest.osm.pbf -o /data/hyderabad.osm.pbf --overwrite
if ($LASTEXITCODE -ne 0) { throw "Could not clip the Hyderabad OSM extract" }

docker pull $osrmImage
if ($LASTEXITCODE -ne 0) { throw "Could not pull the OSRM image" }

docker run --rm --volume "${mountPath}:/data" $osrmImage `
    osrm-extract -p /opt/car.lua /data/hyderabad.osm.pbf
if ($LASTEXITCODE -ne 0) { throw "OSRM extraction failed" }

docker run --rm --volume "${mountPath}:/data" $osrmImage `
    osrm-partition /data/hyderabad.osrm
if ($LASTEXITCODE -ne 0) { throw "OSRM partition failed" }

docker run --rm --volume "${mountPath}:/data" $osrmImage `
    osrm-customize /data/hyderabad.osrm
if ($LASTEXITCODE -ne 0) { throw "OSRM customization failed" }

Write-Host "OSRM data is ready. Start the application with: docker compose up --build"

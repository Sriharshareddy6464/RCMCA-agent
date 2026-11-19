param(
    [Parameter(Mandatory = $true)][string]$AwsAccountId,
    [string]$AwsRegion = "ap-south-1"
)

$ErrorActionPreference = "Stop"
$tag = Get-Date -Format "yyyyMMddHHmmss"
$registry = "$AwsAccountId.dkr.ecr.$AwsRegion.amazonaws.com"

aws ecr get-login-password --region $AwsRegion | docker login --username AWS --password-stdin $registry
if ($LASTEXITCODE -ne 0) { throw "ECR login failed." }

$apiImage = "$registry/rcmca/api:$tag"
$osrmImage = "$registry/rcmca/osrm:$tag"
docker build --file Dockerfile --tag $apiImage .
if ($LASTEXITCODE -ne 0) { throw "API image build failed." }
docker build --file Dockerfile.osrm --tag $osrmImage .
if ($LASTEXITCODE -ne 0) { throw "OSRM image build failed. Run scripts/prepare_osrm_data.ps1 first." }
docker push $apiImage
if ($LASTEXITCODE -ne 0) { throw "API image push failed." }
docker push $osrmImage
if ($LASTEXITCODE -ne 0) { throw "OSRM image push failed." }

$model = Join-Path $PSScriptRoot "..\models\road_damage.onnx"
if (-not (Test-Path -LiteralPath $model)) { throw "Local model artifact is missing at $model." }
$bucket = (terraform -chdir=infra/aws output -raw evidence_bucket).Trim()
if (-not $bucket) { throw "Terraform evidence_bucket output is unavailable; provision the bucket first." }
aws s3 cp $model "s3://$bucket/models/road_damage.onnx" --region $AwsRegion
if ($LASTEXITCODE -ne 0) { throw "Vision model upload failed." }

Write-Output "API_IMAGE=$apiImage"
Write-Output "OSRM_IMAGE=$osrmImage"

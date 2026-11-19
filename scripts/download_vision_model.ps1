$ErrorActionPreference = "Stop"

$modelDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) "models"
$modelPath = Join-Path $modelDirectory "road_damage.onnx"
$downloadPath = Join-Path $modelDirectory "road_damage.onnx.download"
$modelUri = "https://huggingface.co/peterhdd/pothole-detection-yolov8/resolve/main/best.onnx?download=true"
$expectedSha256 = "91DD7DE7A110C61314EA19A958FCC85C7B3461CC6D60D87FEFC08B41AC6E32C5"

New-Item -ItemType Directory -Force -Path $modelDirectory | Out-Null
if (Test-Path -LiteralPath $modelPath) {
    $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $modelPath).Hash
    if ($existingHash -eq $expectedSha256) {
        Write-Output "Starter model already present and verified: $modelPath"
        exit 0
    }
    throw "Refusing to overwrite a different model file: $modelPath"
}

try {
    Invoke-WebRequest -Uri $modelUri -OutFile $downloadPath
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash
    if ($actualHash -ne $expectedSha256) {
        throw "Model SHA-256 mismatch. Expected $expectedSha256; got $actualHash"
    }
    Move-Item -LiteralPath $downloadPath -Destination $modelPath
    Write-Output "Downloaded and verified starter model: $modelPath"
}
finally {
    if (Test-Path -LiteralPath $downloadPath) {
        Remove-Item -LiteralPath $downloadPath
    }
}

# download-model.ps1 — Download or convert any HuggingFace model for NoLlama
#
# Usage:
#     .\download-model.ps1 OpenVINO/Qwen3-8B-int4-cw-ov          # pre-exported, just download
#     .\download-model.ps1 Qwen/Qwen2.5-VL-3B-Instruct --convert --weight int8
#     .\download-model.ps1 Qwen/Qwen2.5-VL-3B-Instruct --convert --weight int4 --trust
#
# Downloads to ~/models/<repo-name>/ by default.
# Use --output to override the target directory.

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$HfId,

    [switch]$Convert,

    [string]$Weight = "int4",

    [switch]$Trust,

    [string]$Output = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Activate venv
$VenvActivate = Join-Path $ScriptDir "venv\Scripts\Activate.ps1"
if (Test-Path $VenvActivate) {
    & $VenvActivate
} else {
    Write-Host "WARNING: No venv found. Using system Python." -ForegroundColor Yellow
}

# Determine target directory
$RepoName = ($HfId -split '/')[-1]
if (-not $Output) {
    $Output = Join-Path $HOME "models" $RepoName
}

Write-Host ""
Write-Host "=== NoLlama Model Download ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Model:  $HfId"
Write-Host "  Target: $Output"
if ($Convert) {
    Write-Host "  Mode:   Convert (optimum-cli, $Weight)"
} else {
    Write-Host "  Mode:   Download (pre-exported)"
}
Write-Host ""

if (Test-Path $Output) {
    Write-Host "Target directory already exists: $Output" -ForegroundColor Yellow
    $reply = Read-Host "Overwrite? [y/N]"
    if ($reply -notin @("y", "Y", "yes")) {
        Write-Host "Aborted."
        exit 0
    }
    $item = Get-Item $Output
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        cmd /c rmdir "`"$Output`""
    } else {
        Remove-Item -Recurse -Force $Output
    }
}

if ($Convert) {
    Write-Host "Converting $HfId to OpenVINO ($Weight)..." -ForegroundColor Cyan
    Write-Host "  This may take 5-30 minutes depending on model size."
    Write-Host ""

    $args = @("export", "openvino", "--model", $HfId, "--weight-format", $Weight)
    if ($Trust) { $args += "--trust-remote-code" }
    $args += $Output

    Write-Host "Running: optimum-cli $($args -join ' ')" -ForegroundColor DarkGray
    Write-Host ""
    & optimum-cli @args
    if (-not $?) {
        Write-Host ""
        Write-Host "ERROR: Conversion failed." -ForegroundColor Red
        Write-Host "  Common fixes:" -ForegroundColor Yellow
        Write-Host "    - Add --trust if the model needs trust-remote-code" -ForegroundColor Yellow
        Write-Host "    - Check that optimum-intel is installed: pip install optimum[openvino]" -ForegroundColor Yellow
        Write-Host "    - Some architectures aren't supported yet by optimum-intel" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "Downloading $HfId..." -ForegroundColor Cyan
    Write-Host ""

    $env:PYTHONIOENCODING = "utf-8"
    hf download $HfId --local-dir $Output
    if (-not $?) {
        Write-Host ""
        Write-Host "ERROR: Download failed." -ForegroundColor Red
        Write-Host "  If 401/403: run 'huggingface-cli login' first" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host ""
Write-Host "[OK] Model ready at: $Output" -ForegroundColor Green
Write-Host ""
Write-Host "To use with NoLlama:"
Write-Host "  python nollama.py --model-dir `"$Output`" --device GPU"
Write-Host "  python nollama.py --gpu-model-dir `"$Output`""
Write-Host ""

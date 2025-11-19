# Test script to reproduce Windows concurrent cache access issue
# Based on reproduction steps from https://github.com/astral-sh/uv/issues/11002

param(
    [int]$JobCount = 20
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Windows Concurrent Cache Access Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Define the cache directory path
$cacheDir = "$env:RUNNER_TEMP\uv-cache"
$pythonDir = "$env:RUNNER_TEMP\uv-python"

# Clear the cache directory if it exists
if (Test-Path $cacheDir) {
    Write-Host "Cleaning cache directory: $cacheDir"
    Remove-Item -Recurse -Force $cacheDir
}
if (Test-Path $pythonDir) {
    Write-Host "Cleaning python directory: $pythonDir"
    Remove-Item -Recurse -Force $pythonDir
}

# Create the cache directory
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
New-Item -ItemType Directory -Force -Path $pythonDir | Out-Null

# Set environment variables
$env:UV_CACHE_DIR = $cacheDir
$env:UV_PYTHON_INSTALL_DIR = $pythonDir

Write-Host "Cache directory: $cacheDir"
Write-Host "Python directory: $pythonDir"
Write-Host ""

# Create test script
$testScript = @"
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "oslex==0.1.3",
#   "comtypes==1.4.9",
# ]
# ///
print("Hello, world!")
"@

$scriptPath = "$env:RUNNER_TEMP\hello.py"
Set-Content -Path $scriptPath -Value $testScript
Write-Host "Created test script: $scriptPath"
Write-Host ""

Write-Host "Starting $JobCount concurrent uv run tests..." -ForegroundColor Yellow
Write-Host "This test reproduces the Windows concurrent cache access issue"
Write-Host ""

# Run concurrent instances
$jobs = @()
for ($i = 1; $i -le $JobCount; $i++) {
    $jobs += Start-Job -ScriptBlock {
        param($scriptPath, $cacheDir, $pythonDir, $uvPath)
        $env:UV_CACHE_DIR = $cacheDir
        $env:UV_PYTHON_INSTALL_DIR = $pythonDir
        $env:Path = "$uvPath;$env:Path"
        & uv run $scriptPath 2>&1
    } -ArgumentList $scriptPath, $cacheDir, $pythonDir, "$pwd\target\release"
}

# Wait for all jobs to complete
Write-Host "Waiting for jobs to complete..."
$jobs | Wait-Job | Out-Null

# Collect results
$failedJobs = 0
$successJobs = 0
$errors = @()

foreach ($job in $jobs) {
    $output = Receive-Job -Job $job
    $outputStr = $output -join "`n"
    
    if ($outputStr -match "error|Error|ERROR" -and $outputStr -notmatch "Hello, world!") {
        $failedJobs++
        $errors += "Job $($job.Id):`n$outputStr"
        Write-Host "Job $($job.Id) FAILED" -ForegroundColor Red
    } else {
        $successJobs++
        Write-Host "Job $($job.Id) succeeded" -ForegroundColor Green
    }
}

# Clean up jobs
$jobs | Remove-Job

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Results:" -ForegroundColor Cyan
Write-Host "  Total Jobs: $JobCount" -ForegroundColor Cyan
Write-Host "  Successful: $successJobs" -ForegroundColor Green
Write-Host "  Failed: $failedJobs" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Cyan

if ($failedJobs -gt 0) {
    Write-Host ""
    Write-Host "Sample errors (first 3):" -ForegroundColor Red
    $errors | Select-Object -First 3 | ForEach-Object {
        Write-Host $_ -ForegroundColor Red
        Write-Host "---" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "TEST FAILED: Concurrent cache access errors detected!" -ForegroundColor Red
    exit 1
} else {
    Write-Host ""
    Write-Host "TEST PASSED: All tests passed! No concurrent cache access errors detected." -ForegroundColor Green
    exit 0
}

# Test script to reproduce Windows concurrent cache access issue
# Based on reproduction steps from https://github.com/astral-sh/uv/issues/11002

param(
    [int]$JobCount = 40,
    [int]$Iterations = 3
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Windows Concurrent Cache Access Test" -ForegroundColor Cyan
Write-Host "  Job Count: $JobCount" -ForegroundColor Cyan
Write-Host "  Iterations: $Iterations" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Define the cache directory path
$cacheDir = "$env:RUNNER_TEMP\uv-cache"
$pythonDir = "$env:RUNNER_TEMP\uv-python"

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

# Track overall results across all iterations
$totalFailedJobs = 0
$totalSuccessJobs = 0
$allErrors = @()
$failedIteration = -1

# Run multiple iterations to increase chance of triggering race condition
for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "ITERATION $iteration of $Iterations" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""
    
    # Clear the cache directory before each iteration
    if (Test-Path $cacheDir) {
        Write-Host "Cleaning cache directory: $cacheDir"
        Remove-Item -Recurse -Force $cacheDir -ErrorAction SilentlyContinue
    }
    if (Test-Path $pythonDir) {
        Write-Host "Cleaning python directory: $pythonDir"
        Remove-Item -Recurse -Force $pythonDir -ErrorAction SilentlyContinue
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
            $errors += "Iteration $iteration - Job $($job.Id):`n$outputStr"
            Write-Host "Job $($job.Id) FAILED" -ForegroundColor Red
        } else {
            $successJobs++
            Write-Host "Job $($job.Id) succeeded" -ForegroundColor Green
        }
    }
    
    # Clean up jobs
    $jobs | Remove-Job
    
    Write-Host ""
    Write-Host "Iteration $iteration Results:" -ForegroundColor Cyan
    Write-Host "  Total Jobs: $JobCount" -ForegroundColor Cyan
    Write-Host "  Successful: $successJobs" -ForegroundColor Green
    Write-Host "  Failed: $failedJobs" -ForegroundColor Red
    Write-Host ""
    
    # Update overall totals
    $totalFailedJobs += $failedJobs
    $totalSuccessJobs += $successJobs
    $allErrors += $errors
    
    # Fail fast on first failure
    if ($failedJobs -gt 0) {
        $failedIteration = $iteration
        Write-Host "STOPPING: Concurrent cache access errors detected in iteration $iteration!" -ForegroundColor Red
        break
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "OVERALL TEST RESULTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Iterations Run: $(if ($failedIteration -gt 0) { $failedIteration } else { $Iterations })" -ForegroundColor Cyan
Write-Host "  Total Jobs: $($totalSuccessJobs + $totalFailedJobs)" -ForegroundColor Cyan
Write-Host "  Total Successful: $totalSuccessJobs" -ForegroundColor Green
Write-Host "  Total Failed: $totalFailedJobs" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Cyan

if ($totalFailedJobs -gt 0) {
    Write-Host ""
    Write-Host "Sample errors (first 3):" -ForegroundColor Red
    $allErrors | Select-Object -First 3 | ForEach-Object {
        Write-Host $_ -ForegroundColor Red
        Write-Host "---" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "TEST FAILED: Concurrent cache access errors detected!" -ForegroundColor Red
    Write-Host "Failed in iteration: $failedIteration" -ForegroundColor Red
    exit 1
} else {
    Write-Host ""
    Write-Host "TEST PASSED: All $Iterations iterations passed! No concurrent cache access errors detected." -ForegroundColor Green
    exit 0
}

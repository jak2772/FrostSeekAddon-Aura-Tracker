param(
    [Parameter(Mandatory=$true)]
    [string]$Repo,

    [string]$Version = "v1.1.3"
)

$ErrorActionPreference = "Stop"

Write-Host "Publishing FrostSeek Aura Tracker $Version to $Repo"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git is not installed or not on PATH."
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is not installed or not on PATH."
}

gh auth status

if (-not (Test-Path ".git")) {
    git init
    git branch -M main
}

git add .
git commit -m "Release $Version" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "No new commit created; continuing."
}

$remoteExists = git remote 2>$null | Select-String "^origin$"
if (-not $remoteExists) {
    git remote add origin "https://github.com/$Repo.git"
}

git push -u origin main

git tag -f $Version
git push origin $Version --force

gh release create $Version `
    "dist/FrostSeek_AuraTracker-v1.1.3.zip" `
    --repo $Repo `
    --title "FrostSeek Aura Tracker $Version" `
    --notes-file "RELEASE_v1.1.3.md"

Write-Host "Release published."

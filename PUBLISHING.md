# Publishing

## Prerequisites

Install:

- Git
- GitHub CLI (`gh`)

Authenticate once:

```powershell
gh auth login
```

## Create an empty GitHub repository

Create the repository in GitHub first, without adding a README/license/gitignore there.

Suggested repository name:

```text
FrostSeek-Aura-Tracker
```

## Publish

Open PowerShell inside this repository folder and run:

```powershell
.\publish-release.ps1 -Repo "YOUR_GITHUB_USERNAME/FrostSeek-Aura-Tracker"
```

The script will:

1. initialize Git if required
2. commit the repository
3. push `main`
4. create/update tag `v1.3.0`
5. create GitHub Release `v1.3.0`
6. attach `dist/FrostSeek_AuraTracker-v1.3.0.zip`
7. use `RELEASE_v1.3.0.md` as the release notes

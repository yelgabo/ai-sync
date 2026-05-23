# ai-sync Windows installer
# Usage: iwr -useb https://raw.githubusercontent.com/yelgabo/ai-sync/main/install.ps1 | iex
#
# To uninstall:
#   $env:AI_SYNC_UNINSTALL = "1"; iwr -useb https://raw.githubusercontent.com/yelgabo/ai-sync/main/install.ps1 | iex
#
# This script must be `iex`-pipeable, which means it cannot use `param()` at
# the top level (Invoke-Expression parses its input as an expression, not as a
# script file). All knobs are read from environment variables.

$Uninstall = [bool]$env:AI_SYNC_UNINSTALL
$ErrorActionPreference = "Stop"

$Repo = "yelgabo/ai-sync"
$InstallDir = if ($env:AI_SYNC_INSTALL_DIR) { $env:AI_SYNC_INSTALL_DIR } else { Join-Path $env:USERPROFILE ".ai-sync-cli" }
$SyncDir = Join-Path $env:USERPROFILE ".ai-sync"
$DefaultRepoName = "ai-config"
$NodeMajor = 22

function Write-Info  { param($Msg) Write-Host $Msg -ForegroundColor Blue }
function Write-Ok    { param($Msg) Write-Host $Msg -ForegroundColor Green }
function Write-Warn  { param($Msg) Write-Host $Msg -ForegroundColor Yellow }
function Write-Err   { param($Msg) Write-Host "Error: $Msg" -ForegroundColor Red; exit 1 }

# Read user input — returns the default when piped/non-interactive
function Read-Prompt {
	param([string]$Message, [string]$Default = "")
	# When PowerShell is launched with -NonInteractive or stdin is redirected
	# (the common `iwr | iex` case), Read-Host throws. Treat that as "no
	# input available" and fall back to the default. [Environment]::UserInteractive
	# alone is unreliable here — it can return true while Read-Host still fails.
	$display = $Message
	if ($Default) { $display = $Message + " [" + $Default + "]" }
	try {
		$reply = Read-Host $display
	} catch {
		return $Default
	}
	if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
	return $reply
}

# Refresh PATH from the registry so a winget-installed Node shows up in this session
function Refresh-Path {
	$machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
	$user = [Environment]::GetEnvironmentVariable("Path", "User")
	$env:PATH = "$machine;$user"
}

# ── uninstall ─────────────────────────────────────────────────────

if ($Uninstall) {
	Write-Info "Uninstalling ai-sync..."

	# Remove npm global link if present
	if (Get-Command npm -ErrorAction SilentlyContinue) {
		Push-Location $InstallDir -ErrorAction SilentlyContinue
		if ($?) {
			try { & npm unlink -g 2>$null | Out-Null } catch {}
			Pop-Location
		}
	}

	# Remove install directory
	if (Test-Path $InstallDir) {
		Remove-Item -Recurse -Force $InstallDir
		Write-Ok "Removed install directory: $InstallDir"
	}

	Write-Host ""
	Write-Ok "ai-sync uninstalled."
	Write-Host ""
	Write-Host "Your sync repo and backups were NOT removed:"
	Write-Host "  Sync repo: $SyncDir"
	Write-Host "  Backups:   $env:USERPROFILE\.ai-sync-backups\"
	Write-Host ""
	Write-Host "To remove them too:"
	Write-Host "  Remove-Item -Recurse -Force `"$SyncDir`", `"$env:USERPROFILE\.ai-sync-backups`""
	exit 0
}

# ── preflight ──────────────────────────────────────────────────────

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
	Write-Err "git is required but not installed. Install it from https://git-scm.com/download/win or with: winget install -e --id Git.Git"
}

function Test-NodeNeedsInstall {
	if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $true }
	$ver = (& node --version) -replace '^v', ''
	$major = [int]($ver -split '\.')[0]
	return $major -lt $NodeMajor
}

function Install-Node {
	Write-Info "Node.js $NodeMajor+ is required. Attempting to install..."

	if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
		Write-Err "winget is not available. Install Node.js $NodeMajor+ manually from https://nodejs.org/, then re-run this installer."
	}

	# OpenJS.NodeJS.LTS tracks the current LTS line (currently 22+).
	& winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements --silent
	if ($LASTEXITCODE -ne 0) {
		Write-Err "winget failed to install Node.js. Install it manually from https://nodejs.org/ and re-run."
	}
	Refresh-Path
}

if (Test-NodeNeedsInstall) {
	if (Get-Command node -ErrorAction SilentlyContinue) {
		$ver = (& node --version) -replace '^v', ''
		Write-Warn "Node.js $ver found, but $NodeMajor+ is required"
	}
	Install-Node
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
	Write-Err "Node.js install completed but `node` is still not on PATH. Open a new PowerShell window and re-run the installer."
}
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
	Write-Err "npm not found after Node.js install."
}

$nodeVer = (& node --version) -replace '^v', ''
$nodeMajor = [int]($nodeVer -split '\.')[0]
if ($nodeMajor -lt $NodeMajor) {
	Write-Err "Node.js $NodeMajor+ is required (found v$nodeVer after install attempt)"
}
Write-Ok "Node.js $nodeVer found"

# ── install ────────────────────────────────────────────────────────

if (Test-Path (Join-Path $InstallDir ".git")) {
	Write-Info "Updating existing installation in $InstallDir..."
	& git -C $InstallDir fetch --depth 1 origin main
	& git -C $InstallDir reset --hard origin/main
} else {
	Write-Info "Cloning ai-sync into $InstallDir..."
	& git clone --depth 1 "https://github.com/$Repo.git" $InstallDir
}
if ($LASTEXITCODE -ne 0) { Write-Err "git clone/update failed" }

Push-Location $InstallDir
try {
	Write-Info "Installing dependencies..."
	& npm install --no-fund --no-audit --loglevel=error
	if ($LASTEXITCODE -ne 0) { Write-Err "npm install failed" }

	Write-Info "Building..."
	& npm run build --silent
	if ($LASTEXITCODE -ne 0) { Write-Err "npm run build failed" }

	# ── link ───────────────────────────────────────────────────────────

	Write-Info "Linking ai-sync globally..."
	& npm link --silent
	if ($LASTEXITCODE -ne 0) {
		$cliPath = Join-Path $InstallDir "dist\cli.js"
		Write-Warn ("npm link failed - run ai-sync directly via: node '" + $cliPath + "' COMMAND")
	} else {
		# npm link puts shims in %APPDATA%\npm — verify it's on PATH
		$npmGlobalBin = & npm prefix -g 2>$null
		if ($npmGlobalBin -and -not ($env:PATH -split ';' | Where-Object { $_ -eq $npmGlobalBin })) {
			Write-Warn "npm global bin ($npmGlobalBin) is not on PATH. Add it and restart your shell:"
			Write-Host "  setx PATH `"$npmGlobalBin;`$env:PATH`""
		}
	}
} finally {
	Pop-Location
}

Write-Host ""
Write-Ok "ai-sync installed successfully!"

# Use the built CLI directly — the npm shim may not be visible until shell restart
$AiSync = { param($Args) & node (Join-Path $InstallDir "dist\cli.js") @Args }

# ── environment selection ──────────────────────────────────────────

Write-Info "Which environments do you want to sync?"
Write-Host "  1) Claude Code only (default)"
Write-Host "  2) OpenCode only"
Write-Host "  3) Both Claude Code and OpenCode"
$envChoice = Read-Prompt "Choose" "1"

$envJson = '["claude"]'
if ($envChoice -eq "2") {
	$envJson = '["opencode"]'
} elseif ($envChoice -eq "3") {
	$envJson = '["claude","opencode"]'
} elseif ($envChoice -ne "1") {
	Write-Warn "Invalid choice '$envChoice', using Claude Code only"
}
Set-Content -Path (Join-Path $InstallDir ".environments.json") -Value $envJson -Encoding utf8

Write-Info "Installing slash command skills..."
try {
	& $AiSync @("install-skills", "--no-update-check") 2>$null
	Write-Ok "Slash commands installed"
} catch {
	Write-Warn "Skill installation skipped (run 'ai-sync install-skills' later)"
}

# ── setup sync repo ───────────────────────────────────────────────

if (Test-Path (Join-Path $SyncDir ".git")) {
	Write-Host ""
	Write-Ok "Sync repo already configured at $SyncDir"
	Write-Host "  ai-sync push    # push local changes"
	Write-Host "  ai-sync pull    # pull remote changes"
	Write-Host "  ai-sync status  # check sync state"
	exit 0
}

$claudeDir = Join-Path $env:USERPROFILE ".claude"
if (-not (Test-Path $claudeDir)) {
	Write-Host ""
	Write-Warn "No $claudeDir directory found. Run Claude Code first to generate config,"
	Write-Host "then run: ai-sync init"
	Write-Host ""
	exit 0
}

Write-Host ""
Write-Info "Let's set up your sync repo."
Write-Host ""

# gh CLI is optional
$hasGh = [bool](Get-Command gh -ErrorAction SilentlyContinue)
if (-not $hasGh) {
	Write-Warn "GitHub CLI (gh) not found — skipping automatic repo creation."
	Write-Host ""
	Write-Host "Create a repo on GitHub manually, then run:"
	Write-Host "  ai-sync init"
	Write-Host "  cd $SyncDir; git remote add origin [repo-url]"
	Write-Host "  ai-sync push"
	exit 0
}

$ghAuthOk = $false
try {
	& gh auth status 2>$null | Out-Null
	$ghAuthOk = ($LASTEXITCODE -eq 0)
} catch {}
if (-not $ghAuthOk) {
	Write-Warn "GitHub CLI not authenticated — skipping automatic repo creation."
	Write-Host "Run 'gh auth login' first, then:"
	Write-Host "  ai-sync init"
	Write-Host "  cd $SyncDir; git remote add origin [repo-url]"
	Write-Host "  ai-sync push"
	exit 0
}

$ghUser = ""
try {
	$ghApiArgs = @("api", "user", "--jq", ".login")
	$rawUser = & gh @ghApiArgs 2>$null
	if ($rawUser) { $ghUser = ([string]$rawUser).Trim() }
} catch {}
if (-not $ghUser) {
	Write-Warn "Could not determine GitHub username — skipping automatic repo creation."
	Write-Host "  ai-sync init"
	Write-Host "  cd $SyncDir; git remote add origin [repo-url]"
	Write-Host "  ai-sync push"
	exit 0
}

$repoName = Read-Prompt "Repository name" $DefaultRepoName
# Sanitize: lowercase, replace non-safe chars with hyphens, strip leading/trailing hyphens
$repoName = ($repoName.ToLower() -replace '[^a-z0-9._-]', '-').Trim('-')
if (-not $repoName) { $repoName = $DefaultRepoName }

$repoVisibility = Read-Prompt "Visibility (private/public)" "private"
if ($repoVisibility -notin @("private", "public")) {
	Write-Warn "Invalid visibility '$repoVisibility', using 'private'"
	$repoVisibility = "private"
}

# HTTPS for cross-platform — SSH works too, but HTTPS works without an ssh-agent
$remoteUrl = "https://github.com/$ghUser/$repoName.git"

Write-Host ""
Write-Info "Creating $repoVisibility repo: $ghUser/$repoName"

$ghOutput = ""
$repoExisted = $false
$visibilityFlag = "--" + $repoVisibility
$ghDescription = "AI tool config synced by ai-sync"
$ghOutput = & gh repo create $repoName $visibilityFlag --description $ghDescription 2>$null | Out-String
if ($LASTEXITCODE -eq 0) {
	Write-Ok "GitHub repo created"
} elseif ($ghOutput -match "already exists") {
	$repoExisted = $true
	Write-Ok "Repository $ghUser/$repoName already exists - will bootstrap from it"
} else {
	Write-Err ("Failed to create repo: " + $ghOutput)
}

if ($repoExisted) {
	Write-Info "Bootstrapping from existing repo..."
	& $AiSync @("bootstrap", $remoteUrl)
} else {
	Write-Info "Initializing sync repo..."
	& $AiSync @("init")

	Write-Info "Adding remote and pushing..."
	try { & git -C $SyncDir remote add origin $remoteUrl 2>$null } catch {}
	if ($LASTEXITCODE -ne 0) { & git -C $SyncDir remote set-url origin $remoteUrl }
	& $AiSync @("push")
}

Write-Host ""
Write-Ok "All done! Your config is synced to $remoteUrl"
Write-Host ""
$installUrl = "https://raw.githubusercontent.com/$Repo/main/install.ps1"
Write-Host "On other Windows machines, run:"
Write-Host ("  iwr -useb " + $installUrl + " | iex")
Write-Host ""

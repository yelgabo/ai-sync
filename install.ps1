# ai-sync Windows installer
# Usage: iwr -useb https://raw.githubusercontent.com/yelgabo/ai-sync/main/install.ps1 | iex
#
# To uninstall:
#   $env:AI_SYNC_UNINSTALL = "1"; iwr -useb https://raw.githubusercontent.com/yelgabo/ai-sync/main/install.ps1 | iex
#
# This script must be `iex`-pipeable. Two constraints follow:
#   1. No `param()` at top level — Invoke-Expression parses its input as an
#      expression, not as a script file. Knobs come from env vars instead.
#   2. The entire body lives inside a function. When piped through `iex` the
#      script runs IN the caller's shell, so any top-level `exit` would close
#      the user's PowerShell window. Inside a function, `exit` only returns
#      from the function and the shell survives.

function Invoke-AiSyncInstaller {
	$Uninstall = [bool]$env:AI_SYNC_UNINSTALL
	# Scope ErrorActionPreference to this function so we don't leave the user's
	# shell with Stop after the script ends.
	$local:ErrorActionPreference = "Stop"

	$Repo = "yelgabo/ai-sync"
	$InstallDir = if ($env:AI_SYNC_INSTALL_DIR) { $env:AI_SYNC_INSTALL_DIR } else { Join-Path $env:USERPROFILE ".ai-sync-cli" }
	$SyncDir = Join-Path $env:USERPROFILE ".ai-sync"
	$DefaultRepoName = "ai-config"
	$NodeMajor = 22

	function Write-Info  { param($Msg) Write-Host $Msg -ForegroundColor Blue }
	function Write-Ok    { param($Msg) Write-Host $Msg -ForegroundColor Green }
	function Write-Warn  { param($Msg) Write-Host $Msg -ForegroundColor Yellow }
	# Throws an exception caught by the outer invocation. We cannot use `exit`
	# inside a function when piped via `iex` because `exit` terminates the
	# whole PowerShell host, not just the function.
	function Write-Err   { param($Msg) throw "ai-sync-installer-error: $Msg" }

# Read user input - returns the default when piped/non-interactive
function Read-Prompt {
	param([string]$Message, [string]$Default = "")
	# When PowerShell is launched with -NonInteractive or stdin is redirected
	# (the common `iwr | iex` case), Read-Host throws. Treat that as "no
	# input available" and fall back to the default. [Environment]::UserInteractive
	# alone is unreliable here - it can return true while Read-Host still fails.
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

# -- uninstall -----------------------------------------------------

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
	return
}

# -- preflight ------------------------------------------------------

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

# -- install --------------------------------------------------------

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

	# -- link -----------------------------------------------------------

	Write-Info "Linking ai-sync globally..."
	& npm link --silent
	if ($LASTEXITCODE -ne 0) {
		$cliPath = Join-Path $InstallDir "dist\cli.js"
		Write-Warn ("npm link failed - run ai-sync directly via: node '" + $cliPath + "' COMMAND")
	} else {
		# npm link puts shims in %APPDATA%\npm - verify it's on PATH
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

# Use the built CLI directly - the npm shim may not be visible until shell restart
$AiSync = { param($Args) & node (Join-Path $InstallDir "dist\cli.js") @Args }

# -- environment selection ------------------------------------------

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

# -- setup sync repo -----------------------------------------------

if (Test-Path (Join-Path $SyncDir ".git")) {
	Write-Host ""
	Write-Ok "Sync repo already configured at $SyncDir"
	Write-Host "  ai-sync push    # push local changes"
	Write-Host "  ai-sync pull    # pull remote changes"
	Write-Host "  ai-sync status  # check sync state"
	return
}

$claudeDir = Join-Path $env:USERPROFILE ".claude"
if (-not (Test-Path $claudeDir)) {
	Write-Host ""
	Write-Warn "No $claudeDir directory found. Run Claude Code first to generate config,"
	Write-Host "then run: ai-sync init"
	Write-Host ""
	return
}

Write-Host ""
Write-Info "Let's set up your sync repo."
Write-Host ""

# gh CLI is optional, but if missing we try to winget-install it the same way
# we install Node — consistent UX. Set $env:AI_SYNC_SKIP_GH=1 to skip this.
$hasGh = [bool](Get-Command gh -ErrorAction SilentlyContinue)
if (-not $hasGh -and -not $env:AI_SYNC_SKIP_GH -and (Get-Command winget -ErrorAction SilentlyContinue)) {
	Write-Info "GitHub CLI (gh) not found - installing via winget..."
	& winget install -e --id GitHub.cli --accept-package-agreements --accept-source-agreements --silent
	if ($LASTEXITCODE -eq 0) {
		Refresh-Path
		$hasGh = [bool](Get-Command gh -ErrorAction SilentlyContinue)
		if ($hasGh) { Write-Ok "GitHub CLI installed" }
	}
}
if (-not $hasGh) {
	Write-Warn "GitHub CLI (gh) not available - skipping automatic repo creation."
	Write-Host ""
	Write-Host "Install gh manually (winget install -e --id GitHub.cli), then run:"
	Write-Host "  ai-sync init"
	Write-Host "  cd $SyncDir; git remote add origin [repo-url]"
	Write-Host "  ai-sync push"
	return
}

$ghAuthOk = $false
try {
	& gh auth status 2>$null | Out-Null
	$ghAuthOk = ($LASTEXITCODE -eq 0)
} catch {}
if (-not $ghAuthOk -and -not $env:AI_SYNC_SKIP_GH) {
	Write-Info "GitHub CLI is not authenticated - launching 'gh auth login'..."
	Write-Host "  (this is interactive: gh will guide you through browser login)"
	# Hand the terminal to gh; it manages its own stdio.
	& gh auth login
	try {
		& gh auth status 2>$null | Out-Null
		$ghAuthOk = ($LASTEXITCODE -eq 0)
	} catch {}
}
if (-not $ghAuthOk) {
	Write-Warn "GitHub CLI not authenticated - skipping automatic repo creation."
	Write-Host "Authenticate later with 'gh auth login', then:"
	Write-Host "  ai-sync init"
	Write-Host "  cd $SyncDir; git remote add origin [repo-url]"
	Write-Host "  ai-sync push"
	return
}

$ghUser = ""
try {
	$ghApiArgs = @("api", "user", "--jq", ".login")
	$rawUser = & gh @ghApiArgs 2>$null
	if ($rawUser) { $ghUser = ([string]$rawUser).Trim() }
} catch {}
if (-not $ghUser) {
	Write-Warn "Could not determine GitHub username - skipping automatic repo creation."
	Write-Host "  ai-sync init"
	Write-Host "  cd $SyncDir; git remote add origin [repo-url]"
	Write-Host "  ai-sync push"
	return
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

# HTTPS for cross-platform - SSH works too, but HTTPS works without an ssh-agent
$remoteUrl = "https://github.com/$ghUser/$repoName.git"

Write-Host ""

# Detect whether the repo already exists. Using `gh repo view` instead of
# parsing the "already exists" string out of `gh repo create`'s stderr —
# the previous approach silently failed because stderr was suppressed by
# `2>$null` and the match never fired, sending the installer down the
# Write-Err path even when the repo just happened to exist.
& gh repo view "$ghUser/$repoName" 2>&1 | Out-Null
$repoExisted = ($LASTEXITCODE -eq 0)

if ($repoExisted) {
	Write-Ok "Repository $ghUser/$repoName already exists - will bootstrap from it"
} else {
	Write-Info "Creating $repoVisibility repo: $ghUser/$repoName"
	$visibilityFlag = "--" + $repoVisibility
	$ghDescription = "AI tool config synced by ai-sync"
	# Merge stderr to stdout so any error text reaches the failure message.
	$ghOutput = (& gh repo create $repoName $visibilityFlag --description $ghDescription 2>&1) | Out-String
	if ($LASTEXITCODE -ne 0) {
		Write-Err ("Failed to create repo: " + $ghOutput.Trim())
	}
	Write-Ok "GitHub repo created"
}

if ($repoExisted) {
	Write-Info "Bootstrapping from existing repo..."
	& $AiSync @("bootstrap", $remoteUrl)
} else {
	Write-Info "Initializing sync repo..."
	& $AiSync @("init")

	Write-Info "Adding remote and pushing..."
	# `git remote add` exits non-zero if a remote named 'origin' already exists
	# (left over from a partial previous run); fall back to set-url in that case.
	& git -C $SyncDir remote add origin $remoteUrl 2>&1 | Out-Null
	if ($LASTEXITCODE -ne 0) { & git -C $SyncDir remote set-url origin $remoteUrl }
	# Initial push must `--set-upstream`; `ai-sync push` short-circuits to
	# "no changes to push" when the local tree matches HEAD, leaving the
	# remote branch missing. Do the upstream push directly here.
	& git -C $SyncDir push -u origin main 2>&1 | ForEach-Object { Write-Host $_ }
	if ($LASTEXITCODE -ne 0) {
		Write-Err "git push failed - check your authentication and try `git -C $SyncDir push -u origin main` manually."
	}
}

Write-Host ""
Write-Ok "All done! Your config is synced to $remoteUrl"
Write-Host ""
$installUrl = "https://raw.githubusercontent.com/$Repo/main/install.ps1"
Write-Host "On other Windows machines, run:"
Write-Host ("  iwr -useb " + $installUrl + " | iex")
Write-Host ""
}

# Invoke the wrapped installer. `Write-Err` throws a sentinel exception that
# we catch here so a fatal error prints cleanly without dragging the user's
# shell down with it.
try {
	Invoke-AiSyncInstaller
} catch {
	$msg = $_.Exception.Message
	if ($msg -like "ai-sync-installer-error: *") {
		Write-Host ("Error: " + $msg.Substring("ai-sync-installer-error: ".Length)) -ForegroundColor Red
	} else {
		Write-Host ("Installer aborted: " + $msg) -ForegroundColor Red
	}
}

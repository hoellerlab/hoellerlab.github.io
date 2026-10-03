# Build the site and copy it to https://academicweb.nd.edu/hoellerlab/ (ND academicweb server).
# The server is only reachable on campus or over the ND VPN.
#
# Usage (from the repo root, PowerShell):
#   _deploy\deploy-nd.cmd            # build, upload, verify
#   _deploy\deploy-nd.cmd -DryRun    # build and package only; print what would be run
#   _deploy\deploy-nd.cmd -Yes       # skip the "uncommitted / unpushed changes" prompt
param(
    [string]$User = "jhoeller",
    [string]$Server = "login.academicweb.nd.edu",
    # ND's internal DNS for the server is unreliable over the VPN; fall back to its IP.
    [string]$ServerIP = "172.22.53.39",
    [switch]$DryRun,
    [switch]$Yes
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$siteUrl = "https://academicweb.nd.edu/hoellerlab/"
Set-Location $repo
# Use Windows' own tools: Anaconda / Git Bash put GNU tar, ssh etc. earlier on PATH,
# and GNU tar misreads "C:\..." as a remote host.
$sys = "$env:SystemRoot\System32"
$tar = "$sys\tar.exe"; $ssh = "$sys\OpenSSH\ssh.exe"; $scp = "$sys\OpenSSH\scp.exe"; $curl = "$sys\curl.exe"

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# 1. Warn if the ND copy would differ from what's on GitHub.
$dirty = git status --porcelain
git fetch --quiet origin main
$unpushed = git log --oneline origin/main..HEAD
if (($dirty -or $unpushed) -and -not $Yes) {
    Write-Host "Warning: uncommitted or unpushed changes - the ND site will differ from hoellerlab.github.io." -ForegroundColor Yellow
    if ($dirty) { $dirty | ForEach-Object { Write-Host "  $_" } }
    if ($unpushed) { $unpushed | ForEach-Object { Write-Host "  unpushed: $_" } }
    if ((Read-Host "Deploy anyway? [y/N]") -ne "y") { exit 1 }
}

# 2. Build.
Write-Host "Rendering site..."
quarto render
if ($LASTEXITCODE -ne 0) { Fail "quarto render failed" }
if (-not (Test-Path "_site\index.html")) { Fail "_site\index.html missing after render" }

# 3. Package _site plus the .htaccess into one tarball.
$tmp = Join-Path $env:TEMP "hoellerlab-deploy"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $tmp | Out-Null
Copy-Item "_site" "$tmp\site" -Recurse
Copy-Item "_deploy\nd.htaccess" "$tmp\site\.htaccess"
$tgz = "$tmp\hoellerlab-site.tgz"
& $tar -czf $tgz -C "$tmp\site" .
if ($LASTEXITCODE -ne 0) { Fail "tar failed" }
$nFiles = (Get-ChildItem "$tmp\site" -Recurse -File -Force).Count
Write-Host "Packaged $nFiles files."

# On the server: unpack into a staging dir, then swap it into ~/hoellerlab.
# Keeps .htaccess.redirect (the old github.io redirect) as a fallback.
$remote = 'set -e; cd ~; rm -rf hoellerlab.new; mkdir hoellerlab.new; ' +
          'tar -xzf hoellerlab-site.tgz -C hoellerlab.new; rm -f hoellerlab-site.tgz; ' +
          'chmod -R u=rwX,g=rX,o= hoellerlab.new; ' +
          'find hoellerlab -mindepth 1 -maxdepth 1 ! -name .htaccess.redirect -exec rm -rf {} +; ' +
          'shopt -s dotglob; mv hoellerlab.new/* hoellerlab/; rmdir hoellerlab.new; ' +
          'echo "Server: $(find hoellerlab -type f ! -name .htaccess.redirect | wc -l) files deployed"'

if ($DryRun) {
    Write-Host "Dry run - would run:"
    Write-Host "  scp `"$tgz`" ${User}@<server>:hoellerlab-site.tgz"
    Write-Host "  ssh ${User}@<server> '$remote'"
    exit 0
}

# 4. Find the server (needs VPN).
$hostName = $Server
try { Resolve-DnsName $Server -ErrorAction Stop | Out-Null } catch { $hostName = $ServerIP }
$tcp = New-Object System.Net.Sockets.TcpClient
try { $tcp.ConnectAsync($hostName, 22).Wait(5000) | Out-Null } catch {}
$ok = $tcp.Connected; $tcp.Close()
if (-not $ok) { Fail "can't reach $hostName on port 22 - are you on the ND VPN?" }

# 5. Upload and swap (asks for your password twice unless you use an SSH key).
Write-Host "Uploading to ${User}@${hostName}..."
& $scp $tgz "${User}@${hostName}:hoellerlab-site.tgz"
if ($LASTEXITCODE -ne 0) { Fail "upload failed" }
& $ssh "${User}@${hostName}" $remote
if ($LASTEXITCODE -ne 0) { Fail "unpacking on the server failed" }

# 6. Verify the live site matches the local build.
$live = "$tmp\live-index.html"
$code = & $curl -s -o $live -w "%{http_code}" $siteUrl
$csp = (& $curl -sI $siteUrl | Select-String "Content-Security-Policy") -join ""
if ($code -ne "200") { Fail "$siteUrl returned HTTP $code" }
if ((Get-FileHash $live).Hash -ne (Get-FileHash "_site\index.html").Hash) { Fail "live index.html differs from the local build" }
if ($csp -notmatch "script-src 'self' 'unsafe-inline'") { Write-Host "Warning: ND's own Content-Security-Policy is still in effect; some page features may break." -ForegroundColor Yellow }
Write-Host "Deployed: $siteUrl" -ForegroundColor Green

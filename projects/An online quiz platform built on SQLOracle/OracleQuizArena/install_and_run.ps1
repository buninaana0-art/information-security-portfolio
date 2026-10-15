param(
    [switch]$UseExistingDatabase,
    [switch]$NoLaunch,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ProjectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$LocalRoot = Join-Path $ProjectRoot '.local'
$VenvRoot = Join-Path $ProjectRoot 'python\.venv'
$VenvPython = Join-Path $VenvRoot 'Scripts\python.exe'
$RuntimeRoot = Join-Path $LocalRoot 'python-runtime'
$DockerRoot = Join-Path $LocalRoot 'docker-desktop'
$DockerData = Join-Path $LocalRoot 'docker-data'
$DownloadRoot = Join-Path $LocalRoot 'downloads'

function Find-Python {
    $candidates = @($VenvPython, (Join-Path $RuntimeRoot 'python.exe'))
    foreach ($name in @('py.exe', 'python.exe')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source -notlike '*WindowsApps*') {
            $candidates += $command.Source
        }
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $arguments = @('-c', 'import sys,struct,tkinter,venv; assert sys.version_info >= (3,10); assert struct.calcsize(chr(80))==8; print(sys.executable)')
            if ([IO.Path]::GetFileName($candidate) -eq 'py.exe') { $arguments = @('-3') + $arguments }
            $result = & $candidate @arguments 2>$null
            if ($LASTEXITCODE -eq 0 -and $result) { return ([string]($result | Select-Object -Last 1)).Trim() }
        } catch { }
    }
    return $null
}

function Download-Installer($Url, $Target, $Publisher, $Sha256 = '') {
    if (-not (Test-Path -LiteralPath $Target)) {
        Write-Host "Downloading $Url"
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile ($Target + '.part')
        Move-Item -LiteralPath ($Target + '.part') -Destination $Target -Force
    }
    if ($Sha256 -and (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash -ne $Sha256) {
        throw "Installer checksum mismatch: $Target. Delete that download and retry."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Target
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $Publisher) {
        throw "Installer signature could not be verified: $Target"
    }
}

function Find-DockerDesktop {
    $paths = @(
        (Join-Path $DockerRoot 'Docker Desktop.exe'),
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe')
    )
    $dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($dockerCommand) {
        $paths += Join-Path (Split-Path (Split-Path (Split-Path $dockerCommand.Source))) 'Docker Desktop.exe'
    }
    return $paths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

try {
    Set-Location -LiteralPath $ProjectRoot
    if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        throw 'This installer supports Windows x64. Local Oracle requires virtualization.'
    }
    $PythonExe = Find-Python
    $DesktopExe = Find-DockerDesktop
    Write-Host "Project: $ProjectRoot"
    Write-Host "Virtual environment: $VenvRoot"
    Write-Host "New downloads and runtimes: $LocalRoot"
    Write-Host "Python found: $PythonExe"
    Write-Host "Docker Desktop found: $DesktopExe"
    if ($CheckOnly) {
        Write-Host 'CHECK ONLY: nothing installed or started.'
        exit 0
    }
    foreach ($path in @($LocalRoot, $DownloadRoot, (Join-Path $LocalRoot 'temp'))) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    $env:TEMP = Join-Path $LocalRoot 'temp'
    $env:TMP = $env:TEMP
    $env:PIP_CACHE_DIR = Join-Path $LocalRoot 'pip-cache'
    $env:PYTHONUTF8 = '1'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not $PythonExe) {
        $installer = Join-Path $DownloadRoot 'python-3.13.15-amd64.exe'
        Download-Installer 'https://www.python.org/ftp/python/3.13.15/python-3.13.15-amd64.exe' $installer 'Python Software Foundation' 'edec09c4853aeae9ac36efb8c9f95b6b8e2fee65eee56d9767a8b7c69c574403'
        $arguments = '/quiet InstallAllUsers=0 Include_launcher=0 Include_test=0 Include_doc=0 Include_pip=1 Include_tcltk=1 Shortcuts=0 PrependPath=0 TargetDir="' + $RuntimeRoot + '"'
        $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -notin @(0, 3010)) { throw "Python installation failed: $($process.ExitCode)" }
        $PythonExe = Find-Python
        if (-not $PythonExe) { throw 'Python with Tkinter was not found after installation.' }
    }

    $venvWorks = $false
    if (Test-Path -LiteralPath $VenvPython) {
        try {
            & $VenvPython -c 'import sys, tkinter; assert sys.prefix != sys.base_prefix' 2>$null
            $venvWorks = ($LASTEXITCODE -eq 0)
        } catch { }
    }
    if (-not $venvWorks) {
        if ((Test-Path -LiteralPath $VenvRoot) -and ((Get-Item -LiteralPath $VenvRoot).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing to recreate a virtual environment through a junction or symlink.'
        }
        if ([IO.Path]::GetFullPath($VenvRoot) -ne (Join-Path $ProjectRoot 'python\.venv')) {
            throw 'Unexpected virtual environment path.'
        }
        & $PythonExe -m venv --clear $VenvRoot
        if ($LASTEXITCODE -ne 0) { throw 'Could not create virtual environment.' }
    }
    & $VenvPython -m pip install --disable-pip-version-check --prefer-binary -r (Join-Path $ProjectRoot 'python\requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Python dependency installation failed. Check your internet connection.' }

    if (-not $UseExistingDatabase) {
        if (-not $DesktopExe) {
            $wslReady = $false
            try { & wsl.exe --status *> $null; $wslReady = ($LASTEXITCODE -eq 0) } catch { }
            if (-not $wslReady) {
                Write-Host 'Enabling WSL 2. Windows may ask for administrator permission and a restart.'
                $process = Start-Process -FilePath 'wsl.exe' -ArgumentList '--install --no-distribution' -Verb RunAs -Wait -PassThru -WindowStyle Hidden
                if ($process.ExitCode -notin @(0, 3010)) { throw 'WSL installation failed. Enable virtualization and install WSL 2.' }
                Write-Host 'Restart Windows, then run INSTALL_AND_RUN.cmd again. Your progress is saved.'
                exit 3010
            }
            $installer = Join-Path $DownloadRoot 'DockerDesktopInstaller.exe'
            Download-Installer 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' $installer 'Docker'
            $arguments = 'install --quiet --accept-license --backend=wsl-2 --no-windows-containers --installation-dir="' + $DockerRoot + '" --wsl-default-data-root="' + $DockerData + '"'
            $process = Start-Process -FilePath $installer -ArgumentList $arguments -Verb RunAs -Wait -PassThru -WindowStyle Hidden
            if ($process.ExitCode -eq 3010) {
                Write-Host 'Restart Windows, then run INSTALL_AND_RUN.cmd again.'
                exit 3010
            }
            if ($process.ExitCode -ne 0) { throw "Docker installation failed: $($process.ExitCode)" }
            $DesktopExe = Find-DockerDesktop
        }
        if (-not $DesktopExe) { throw 'Docker Desktop executable was not found.' }
        $env:PATH = (Join-Path (Split-Path $DesktopExe) 'resources\bin') + ';' + $env:PATH
        $engineReady = $false
        try { & docker.exe info *> $null; $engineReady = ($LASTEXITCODE -eq 0) } catch { }
        if (-not $engineReady) {
            Start-Process -FilePath $DesktopExe -WindowStyle Hidden
            Write-Host 'Waiting for Docker Desktop. Complete its first-run dialog if shown.'
            for ($attempt = 0; $attempt -lt 60; $attempt++) {
                Start-Sleep -Seconds 5
                try { & docker.exe info *> $null; $engineReady = ($LASTEXITCODE -eq 0) } catch { }
                if ($engineReady) { break }
                if ($attempt % 6 -eq 0) { Write-Host 'Docker is still starting...' }
            }
        }
        if (-not $engineReady) { throw 'Docker engine is unavailable. Finish Docker setup or restart Windows, then rerun.' }
    }
    $setupArguments = @((Join-Path $ProjectRoot 'setup_game.py'))
    if ($UseExistingDatabase) { $setupArguments += '--existing-database' }
    if ($NoLaunch) { $setupArguments += '--no-launch' }
    & $VenvPython @setupArguments
    if ($LASTEXITCODE -ne 0) { throw 'Database setup did not complete. See the error above; existing data was preserved.' }
    Write-Host 'Oracle Quiz Arena is ready.'
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

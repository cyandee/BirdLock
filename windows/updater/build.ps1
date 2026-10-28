param([string]$SourceRoot=$PSScriptRoot, [string]$Config = "$PSScriptRoot\..\..\SharedResources\Updates\config.json", [string]$Output = "$PSScriptRoot\dist\BirdLockUpdater.exe")
$ErrorActionPreference = "Stop"
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (!(Test-Path $csc)) { throw '.NET Framework 4.x compiler is required to build the updater' }
New-Item -ItemType Directory -Force (Split-Path $Output) | Out-Null
& $csc /nologo /codepage:65001 /optimize+ /target:exe /platform:x64 "/out:$Output" "/resource:$Config,UpdateConfig" /reference:System.Web.Extensions.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll "$SourceRoot\Updater.cs" "$SourceRoot\Program.cs"
if ($LASTEXITCODE -ne 0) { throw 'Updater compilation failed' }
if ((Get-Item $Output).Length -gt 3MB) { throw 'Updater exceeds the 3 MB target' }

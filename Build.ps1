$ErrorActionPreference='Stop'
$compiler=Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if(!(Test-Path -LiteralPath $compiler)){throw 'The .NET Framework C# compiler is required.'}
& $compiler /nologo /target:winexe /platform:anycpu /reference:System.Windows.Forms.dll (('/out:{0}' -f (Join-Path $PSScriptRoot 'UsageMonitor.exe'))) (Join-Path $PSScriptRoot 'Launcher.cs')
if($LASTEXITCODE -ne 0){throw 'Launcher build failed'}
$check=Start-Process -FilePath (Join-Path $PSScriptRoot 'UsageMonitor.exe') -ArgumentList '--check' -WindowStyle Hidden -PassThru -Wait
if($check.ExitCode -ne 0){throw 'Launcher file check failed'}
'PASS: launcher built and file check passed. This executable is unsigned.'

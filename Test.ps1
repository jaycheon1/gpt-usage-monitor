$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Monitor.ps1') -LibraryOnly
if($script:proc){throw 'Offline test unexpectedly started a service'}
if($script:pollSeconds -ne 900){throw 'Expected 15-minute polling'}
if((Format-Wait 900) -ne '15분 00초'){throw 'Countdown format'}
Draw-Window 'Primary' $null
if($c.PrimaryValue.Text -ne '—'){throw 'Missing value must remain unknown'}
Draw-Window 'Primary' ([pscustomobject]@{usedPercent=100;windowDurationMins=300;resetsAt=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-1)})
if($c.PrimaryValue.Text -ne '0%' -or $c.PrimaryCountdown.Text -ne '초기화 확인 대기'){throw 'Reset must not invent a new balance'}
Apply-Limits ([pscustomobject]@{rateLimitsByLimitId=[pscustomobject]@{codex=[pscustomobject]@{limitId='codex';primary=[pscustomobject]@{usedPercent=25;windowDurationMins=300;resetsAt=$null}};other=[pscustomobject]@{limitId='other'}}})
if($c.PrimaryValue.Text -ne '75%'){throw 'Remaining quota calculation'}
$c.Bucket.SelectedItem='other'
if((Get-Bucket).limitId -ne 'other'){throw 'Bucket selection'}
$script:lastOK=[DateTime]::UtcNow.AddMinutes(-18);Render-Limits
if($c.Updated.Text -notmatch '오래된 데이터'){throw 'Stale indicator'}
$c.Pause.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
if(!$script:paused){throw 'Pause event'}
$script:nextPoll=[DateTime]::UtcNow.AddSeconds(-1);Pump
if($script:proc){throw 'Paused mode made a connection'}
$script:pending['test']=@{method='initialize';sent=[DateTime]::UtcNow};Render-Limits
if($c.Refresh.IsEnabled){throw 'Duplicate request prevention'}
$script:pending=@{}
$rejected=$false
try {Send-Rpc 'turn/start'}catch{$rejected=($_.Exception.Message -eq 'Unsupported operation')}
if(!$rejected){throw 'Model inference operation was not blocked'}
$errors=$null;$tokens=$null
foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1'){
 [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ('PowerShell syntax error: '+$file.Name)}
}
[xml]$layout=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Monitor.xaml'))
Stop-Bridge
'PASS: no-network tests, 15-minute interval, missing data, elapsed reset, multiple buckets, stale display, pause, duplicate prevention, inference rejection, syntax'

param([switch]$Verify, [string]$PreviewPath, [switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:ui = [Windows.Markup.XamlReader]::Load([System.Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'Monitor.xaml')))
$script:c = @{}
foreach($name in @('Bucket','Pin','Locate','Status','PrimaryTitle','PrimaryValue','PrimaryBar','PrimaryUsed','PrimaryCountdown','PrimaryTime','PrimaryReset','SecondaryTitle','SecondaryValue','SecondaryBar','SecondaryUsed','SecondaryCountdown','SecondaryTime','SecondaryReset','Tokens','TokenDate','Credits','ResetCredits','Refresh','Pause','Updated','Next')) { $c[$name]=$ui.FindName($name) }
$script:codexOverride=$null
$script:proc=$null; $script:readTask=$null; $script:ready=$false; $script:pending=@{}; $script:seq=1
$script:pollSeconds=15*60; $script:staleSeconds=$script:pollSeconds+120
$script:limits=$null; $script:lastOK=$null; $script:nextPoll=[DateTime]::UtcNow; $script:paused=$false; $script:rebuilding=$false
$script:usageOK=$false; $script:limitOK=$false; $script:tokenOK=$null
$script:zone=[TimeZoneInfo]::FindSystemTimeZoneById('Korea Standard Time')
function Seoul([DateTime]$value) { [TimeZoneInfo]::ConvertTimeFromUtc($value.ToUniversalTime(),$script:zone).ToString('MM/dd HH:mm:ss') }
function Set-State([string]$text,[bool]$good=$false) { $c.Status.Text=$text; $c.Status.Foreground=if($good){'#7DE0C4'}else{'#FFD38C'} }
function Format-Wait([double]$seconds) {
 $whole=[int][Math]::Max(0,[Math]::Ceiling($seconds))
 return ('{0}분 {1:00}초' -f [Math]::Floor($whole/60),($whole % 60))
}
function Stop-Bridge {
 if($script:proc){try {if(!$script:proc.HasExited){$script:proc.Kill()};$script:proc.Dispose()}catch{}}
 $script:proc=$null;$script:ready=$false;$script:pending=@{};$script:readTask=$null
}
function Send-Rpc([string]$method,$parameters=$null) {
 if($method -notin @('initialize','account/rateLimits/read','account/usage/read')){throw 'Unsupported operation'}
 $script:seq++;$id=$script:seq
 $payload=@{id=$id;method=$method}; if($null -ne $parameters){$payload.params=$parameters}
 $script:proc.StandardInput.WriteLine(($payload | ConvertTo-Json -Depth 8 -Compress));$script:proc.StandardInput.Flush()
 $script:pending[[string]$id]=@{method=$method;sent=[DateTime]::UtcNow}
}
function Find-Codex {
 if($script:codexOverride -and (Test-Path -LiteralPath $script:codexOverride -PathType Leaf)){return $script:codexOverride}
 $command=Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
 if($command){return $command.Source}
 $bin=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OpenAI/Codex/bin'
 if(Test-Path -LiteralPath $bin){
  $candidate=Get-ChildItem -LiteralPath $bin -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {Join-Path $_.FullName 'codex.exe'} | Where-Object {Test-Path -LiteralPath $_ -PathType Leaf} | Select-Object -First 1
  if($candidate){return $candidate}
 }
 return $null
}
function Start-Bridge {
 Stop-Bridge
 $executable=Find-Codex
 if(!$executable){Set-State 'Codex를 찾을 수 없습니다. 설치 후 Codex 위치 선택으로 codex.exe를 지정하세요.'; $script:nextPoll=[DateTime]::UtcNow.AddSeconds($script:pollSeconds);return}
 try {
  $script:proc=New-Object Diagnostics.Process
  $script:proc.StartInfo.FileName=$executable
  $script:proc.StartInfo.Arguments='app-server --listen stdio://'
  $script:proc.StartInfo.WorkingDirectory=$PSScriptRoot
  $script:proc.StartInfo.UseShellExecute=$false
  $script:proc.StartInfo.CreateNoWindow=$true
  $script:proc.StartInfo.RedirectStandardInput=$true
  $script:proc.StartInfo.RedirectStandardOutput=$true
  $script:proc.StartInfo.RedirectStandardError=$true
  [void]$script:proc.Start()
  $script:errTask=$script:proc.StandardError.ReadToEndAsync()
  $script:readTask=$script:proc.StandardOutput.ReadLineAsync()
  Send-Rpc 'initialize' @{clientInfo=@{name='gpt_usage_monitor';title='GPT Usage Monitor';version='1.2.0-beta.1'}}
  Set-State '계정 연결 중…'
 } catch { Stop-Bridge;Set-State '연결 프로그램을 시작하지 못했습니다. Codex 앱 로그인과 실행 권한을 확인하세요.';$script:nextPoll=[DateTime]::UtcNow.AddSeconds($script:pollSeconds) }
}
function Poll-Usage {
 if($script:pending.Count -gt 0){return}
 $script:usageOK=$false;$script:limitOK=$false
 Send-Rpc 'account/rateLimits/read'
 Send-Rpc 'account/usage/read'
 $script:nextPoll=[DateTime]::UtcNow.AddSeconds($script:pollSeconds)
 Set-State '최신 사용량 조회 중…'
}
function Get-Bucket {
 if(!$script:limits){return $null}
 $key=[string]$c.Bucket.SelectedItem
 if($script:limits.rateLimitsByLimitId -and $script:limits.rateLimitsByLimitId.PSObject.Properties[$key]) {return $script:limits.rateLimitsByLimitId.PSObject.Properties[$key].Value}
 return $script:limits.rateLimits
}
function Draw-Window([string]$prefix,$data) {
 $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
 if($null -eq $data){
  $c[$prefix+'Title'].Text=if($prefix -eq 'Primary'){'단기 한도'}else{'장기 한도'}
  $c[$prefix+'Value'].Text='—';$c[$prefix+'Bar'].Value=0;$c[$prefix+'Used'].Text=if($script:lastOK){'이 한도는 제공되지 않습니다.'}else{'조회 대기 · 연결 상태를 확인하세요.'}
  $c[$prefix+'Countdown'].Text='—';$c[$prefix+'Time'].Value=0;$c[$prefix+'Reset'].Text='';return
 }
 $mins=$data.windowDurationMins
 $c[$prefix+'Title'].Text=if($null -eq $mins){'사용 한도'}elseif($mins -eq 10080){'주간 한도 · 남은 비율'}elseif($mins % 60 -eq 0){"$($mins/60)시간 한도 · 남은 비율"}else{"$mins 분 한도 · 남은 비율"}
 if($null -ne $data.usedPercent){
  $left=[Math]::Max(0,[Math]::Min(100,100-[double]$data.usedPercent))
  $c[$prefix+'Value'].Text=('{0:0.#}%' -f $left);$c[$prefix+'Bar'].Value=$left
  $c[$prefix+'Bar'].Foreground=if($left -le 15){'#FFB478'}else{'#7DE0C4'}
  $c[$prefix+'Used'].Text=('사용 {0:0.#}% · 마지막 조회 기준' -f $data.usedPercent)
 } else {$c[$prefix+'Value'].Text='—';$c[$prefix+'Bar'].Value=0;$c[$prefix+'Used'].Text='사용 비율 미제공'}
 if($null -ne $data.resetsAt){
  $seconds=[double]$data.resetsAt-$now
  if($seconds -le 0){$c[$prefix+'Countdown'].Text='초기화 확인 대기'}else{
   $span=[TimeSpan]::FromSeconds($seconds)
   $c[$prefix+'Countdown'].Text=if($span.Days -gt 0){'{0}일 {1:00}:{2:00}:{3:00}' -f $span.Days,$span.Hours,$span.Minutes,$span.Seconds}else{'{0:00}:{1:00}:{2:00}' -f $span.Hours,$span.Minutes,$span.Seconds}
  }
  $c[$prefix+'Reset'].Text=(Seoul ([DateTimeOffset]::FromUnixTimeSeconds([long]$data.resetsAt).UtcDateTime))+' KST 초기화 예정'
  $c[$prefix+'Time'].Value=if($mins -gt 0){[Math]::Max(0,[Math]::Min(100,(1-$seconds/($mins*60))*100))}else{0}
 }else{$c[$prefix+'Countdown'].Text='시각 미제공';$c[$prefix+'Reset'].Text='';$c[$prefix+'Time'].Value=0}
}
function Render-Limits {
 $bucket=Get-Bucket
 Draw-Window 'Primary' $bucket.primary;Draw-Window 'Secondary' $bucket.secondary
 if($bucket){
  $credit=$bucket.credits
  $c.Credits.Text=if($null -eq $credit){'추가 크레딧: 미제공'}elseif($credit.unlimited){'추가 크레딧: 무제한'}elseif($null -ne $credit.balance){'추가 크레딧: '+$credit.balance}else{'추가 크레딧 잔액: 미제공'}
  $count=$script:limits.rateLimitResetCredits.availableCount
  $c.ResetCredits.Text=if($null -ne $count){"사용 가능한 한도 초기화권: $count 개 · 조회만 수행"}else{'한도 초기화권 정보: 미제공'}
 }
 if($script:lastOK){$age=([DateTime]::UtcNow-$script:lastOK).TotalSeconds;$c.Updated.Text='한도 조회: '+(Seoul $script:lastOK)+' KST'+$(if($age -gt $script:staleSeconds){' · 오래된 데이터'}else{''})}
 $c.Next.Text=if($script:paused){'자동 조회 중지 · 카운트다운만 계속 갱신'}elseif($script:pending.Count -gt 0){'서버 응답 대기 중'}else{'다음 조회까지 '+(Format-Wait (($script:nextPoll-[DateTime]::UtcNow).TotalSeconds))}
 $c.Refresh.IsEnabled=($script:pending.Count -eq 0)
 $c.Refresh.Content=if($script:pending.Count -gt 0){'조회 중…'}else{'지금 새로고침'}
 if($script:paused -and $script:ready -and $script:pending.Count -eq 0 -and $script:limitOK -and $script:usageOK){Set-State '자동 조회 일시정지 · 마지막 확인 데이터 표시'}
}
function Apply-Limits($result){
 $script:limits=$result;$script:lastOK=[DateTime]::UtcNow;$script:limitOK=$true
 $old=[string]$c.Bucket.SelectedItem;$script:rebuilding=$true;$c.Bucket.Items.Clear()
 if($result.rateLimitsByLimitId){foreach($property in $result.rateLimitsByLimitId.PSObject.Properties){[void]$c.Bucket.Items.Add($property.Name)}}
 if($c.Bucket.Items.Count -eq 0 -and $result.rateLimits){[void]$c.Bucket.Items.Add([string]$result.rateLimits.limitId)}
 if($c.Bucket.Items.Contains($old)){$c.Bucket.SelectedItem=$old}elseif($c.Bucket.Items.Contains('codex')){$c.Bucket.SelectedItem='codex'}elseif($c.Bucket.Items.Count -gt 0){$c.Bucket.SelectedIndex=0}
 $script:rebuilding=$false;Render-Limits
}
function Apply-Tokens($result){
 $script:usageOK=$true;$script:tokenOK=[DateTime]::UtcNow
 $total=$result.summary.lifetimeTokens
 $c.Tokens.Text=if($null -eq $total){'누적 토큰 정보 미제공'}else{('{0:N0} 토큰 · 누적 사용' -f [double]$total)}
 $buckets=@($result.dailyUsageBuckets | Where-Object {$null -ne $_} | Sort-Object startDate)
 $recent=if($buckets.Count -gt 0){$buckets[-1]}else{$null}
 $c.TokenDate.Text='토큰 조회: '+(Seoul $script:tokenOK)+' KST'+$(if($recent){"`n최근 서버 집계일 $($recent.startDate): $('{0:N0}' -f $recent.tokens) 토큰"}else{"`n일별 집계 미제공"})
}
function Pump {
 try {
  if($script:proc -and $script:proc.HasExited){throw 'Bridge stopped'}
  $processed=0
  while($script:readTask -and $script:readTask.IsCompleted -and $processed -lt 100){
   $raw=$script:readTask.GetAwaiter().GetResult();if($null -eq $raw){throw 'Bridge closed'}
   $script:readTask=$script:proc.StandardOutput.ReadLineAsync();$processed++
   $msg=$raw | ConvertFrom-Json
   if($null -ne $msg.id -and $script:pending.ContainsKey([string]$msg.id)){
    $method=$script:pending[[string]$msg.id].method;$script:pending.Remove([string]$msg.id)
    if($msg.error){
     if($method -eq 'initialize'){throw 'Initialization failed'}
     if($method -eq 'account/usage/read'){
      if(!$script:tokenOK){$c.Tokens.Text='누적 토큰 조회 실패'}
      $c.TokenDate.Text='토큰 조회 실패 · '+$(if($script:tokenOK){'마지막 성공 '+(Seoul $script:tokenOK)+' KST'}else{'로그인 또는 서비스 지원 여부를 확인하세요.'})
     }
     Set-State '조회 일부 실패 · 마지막 성공 값 표시. Codex 로그인 또는 연결을 확인하세요.'
    }elseif($method -eq 'initialize'){
     $script:proc.StandardInput.WriteLine('{"method":"initialized"}');$script:proc.StandardInput.Flush();$script:ready=$true;Poll-Usage
    }elseif($method -eq 'account/rateLimits/read'){Apply-Limits $msg.result
    }elseif($method -eq 'account/usage/read'){Apply-Tokens $msg.result}
    if($script:pending.Count -eq 0 -and $script:ready -and $script:limitOK -and $script:usageOK){Set-State '연결됨 · 실제 계정 데이터 · 15분 주기 조회' $true}
   }elseif($msg.method -eq 'account/rateLimits/updated'){Apply-Limits $msg.params}
  }
  foreach($request in @($script:pending.Values)){if(([DateTime]::UtcNow-$request.sent).TotalSeconds -gt 25){throw 'Read timeout'}}
  if(!$script:paused -and $script:pending.Count -eq 0 -and [DateTime]::UtcNow -ge $script:nextPoll){if($script:ready){Poll-Usage}else{Start-Bridge}}
 }catch{Stop-Bridge;Set-State '연결 끊김 · 마지막 조회 값 유지 · 15분 후 재연결';$script:nextPoll=[DateTime]::UtcNow.AddSeconds($script:pollSeconds)}
 Render-Limits
}
$c.Refresh.Add_Click({try{if($script:ready){Poll-Usage}else{Start-Bridge}}catch{Set-State '새로고침 실패 · 잠시 후 다시 시도하세요.'}})
$c.Pause.Add_Click({$script:paused=!$script:paused;$c.Pause.Content=if($script:paused){'자동 조회 재개'}else{'자동 조회 일시정지'};if(!$script:paused){$script:nextPoll=[DateTime]::UtcNow};Render-Limits})
$c.Pin.Add_Click({$ui.Topmost=[bool]$c.Pin.IsChecked})
$c.Locate.Add_Click({
 $picker=New-Object Microsoft.Win32.OpenFileDialog
 $picker.Title='설치된 공식 Codex의 codex.exe 선택';$picker.Filter='Codex executable (codex.exe)|codex.exe'
 if($picker.ShowDialog($ui)){$script:codexOverride=$picker.FileName;Start-Bridge}
})
$c.Bucket.Add_SelectionChanged({if(!$script:rebuilding){Render-Limits}})
$script:timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromSeconds(1);$timer.Add_Tick({Pump})
$ui.Add_Closed({$timer.Stop();Stop-Bridge})
if($LibraryOnly){return}
try {
 Start-Bridge
 if($Verify){
  $deadline=[DateTime]::UtcNow.AddSeconds(35)
  while([DateTime]::UtcNow -lt $deadline -and !($script:limitOK -and $script:usageOK)){Pump;Start-Sleep -Milliseconds 100}
  if(!$script:limitOK){throw 'Live quota verification failed'}
  Render-Limits
  if($PreviewPath){
   $ui.Content.Background=$ui.Background;$ui.Content.Measure([Windows.Size]::new(740,820));$ui.Content.Arrange([Windows.Rect]::new(0,0,740,820));$ui.Content.UpdateLayout()
   $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(740,820,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($ui.Content)
   $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
   $stream=[IO.File]::Create($PreviewPath);try{$encoder.Save($stream)}finally{$stream.Dispose()}
  }
  [pscustomobject]@{status=$c.Status.Text;primary=$c.PrimaryValue.Text;secondary=$c.SecondaryValue.Text;tokens=$c.Tokens.Text;reset=$c.PrimaryReset.Text} | ConvertTo-Json -Compress
 } else {$timer.Start();[void]$ui.ShowDialog()}
} finally { $timer.Stop();Stop-Bridge }

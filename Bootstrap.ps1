$ErrorActionPreference='Stop'
try {
 if($PSVersionTable.PSVersion.Major -lt 5){throw 'Windows PowerShell 5.1 or later is required.'}
 & (Join-Path $PSScriptRoot 'Monitor.ps1')
}catch{
 Add-Type -AssemblyName PresentationFramework
 [void][Windows.MessageBox]::Show('프로그램을 시작하지 못했습니다. ZIP 전체를 압축 해제하고 Windows PowerShell 5.1 및 Codex 설치를 확인하세요. 회사 PC에서는 관리자 정책을 확인하세요.','Usage Monitor - 실행 오류','OK','Error')
 exit 1
}

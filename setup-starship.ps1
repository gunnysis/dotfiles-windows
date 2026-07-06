#Requires -Version 7
<#
.SYNOPSIS
  PowerShell 7 + Starship 프롬프트 + Nerd Font 자동 설치/설정 스크립트 (이식성/멱등)

.DESCRIPTION
  다른 PC에서도 이 파일 하나만 복사해 실행하면 동일 환경이 구성됩니다.
  - 멱등(re-runnable): 이미 설치/설정된 항목은 건너뜀
  - 안전: 덮어쓰기 전 항상 .bak-<timestamp> 백업
  - 무재시작: 현재 세션 PATH를 갱신해 곧바로 starship 사용 가능
  - starship.toml 내장 → 추가 파일 불필요

.PARAMETER Font
  터미널에 지정할 Nerd Font 패밀리명. 기본: 'JetBrainsMono Nerd Font'

.PARAMETER FontId
  폰트 winget 패키지 ID. 기본: 'DEVCOM.JetBrainsMonoNerdFont'

.PARAMETER MachineScope
  모든 사용자용(machine scope)으로 설치. 관리자 권한 필요 → 자동 권한 상승 시도.

.PARAMETER SkipTerminalFont
  Windows Terminal settings.json 자동 수정을 건너뜀.

.EXAMPLE
  # 표준(권한 불필요, 현재 사용자)
  pwsh -ExecutionPolicy Bypass -File .\setup-starship.ps1

.EXAMPLE
  # 모든 사용자용 + 다른 폰트
  pwsh -File .\setup-starship.ps1 -MachineScope -Font 'CaskaydiaCove Nerd Font' -FontId 'DEVCOM.CascadiaCodeNerdFont'
#>
[CmdletBinding()]
param(
  [string]$Font   = 'JetBrainsMono Nerd Font',
  [string]$FontId = 'DEVCOM.JetBrainsMonoNerdFont',
  [switch]$MachineScope,
  [switch]$SkipTerminalFont
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
function Info($m){ Write-Host "[i]  $m" -ForegroundColor Cyan }
function Ok($m){   Write-Host "[ok] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!]  $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "[x]  $m" -ForegroundColor Red }
function Backup($path){ if(Test-Path $path){ $b="$path.bak-$stamp"; Copy-Item $path $b -Force; Warn "백업: $b" } }

# --- 0. 사전 점검: winget + (필요 시) 관리자 권한 --------------------------
if(-not (Get-Command winget -ErrorAction SilentlyContinue)){
  Fail "winget(앱 설치 관리자)이 없습니다. Microsoft Store에서 '앱 설치 관리자'를 설치 후 다시 실행하세요."
  exit 1
}
$scopeArgs = @()
if($MachineScope){
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if(-not $isAdmin){
    Warn "-MachineScope 는 관리자 권한이 필요합니다. 권한 상승 후 재실행합니다..."
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",
                 '-MachineScope','-Font',"`"$Font`"",'-FontId',"`"$FontId`"")
    if($SkipTerminalFont){ $argList += '-SkipTerminalFont' }
    Start-Process (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList
    exit 0
  }
  $scopeArgs = @('--scope','machine')
  Info "설치 범위: machine (모든 사용자)"
} else {
  Info "설치 범위: user (현재 사용자, 권한 불필요)"
}

# --- 1. Starship 설치 -------------------------------------------------------
if(Get-Command starship -ErrorAction SilentlyContinue){
  Ok "starship 이미 설치됨 ($((starship --version) -split "`n" | Select-Object -First 1))"
} else {
  Info "starship 설치 (winget)..."
  winget install --id Starship.Starship -e --source winget @scopeArgs `
    --accept-package-agreements --accept-source-agreements --silent
  Ok "starship 설치 완료"
}

# --- 2. Nerd Font 설치 ------------------------------------------------------
Add-Type -AssemblyName System.Drawing
$fontFamilyKey = ($Font -replace '\s*Nerd Font.*$','').Trim()   # 예: 'JetBrainsMono'
$fontInstalled = (New-Object System.Drawing.Text.InstalledFontCollection).Families |
  Where-Object { $_.Name -match [regex]::Escape($fontFamilyKey) }
if($fontInstalled){
  Ok "$Font 이미 설치됨"
} else {
  Info "$Font 설치 (winget: $FontId)..."
  winget install --id $FontId -e --source winget @scopeArgs `
    --accept-package-agreements --accept-source-agreements --silent
  Ok "폰트 설치 완료 (터미널 재시작 후 목록에 반영)"
}

# --- 3. 현재 세션 PATH 갱신 (재시작 없이 starship 인식) ---------------------
$env:Path = (
  [Environment]::GetEnvironmentVariable('Path','Machine'),
  [Environment]::GetEnvironmentVariable('Path','User')
) -join ';'

# --- 4. PowerShell 프로파일에 starship 초기화 훅 (멱등) ---------------------
$profileDir = Split-Path $PROFILE -Parent
if(-not (Test-Path $profileDir)){ New-Item -ItemType Directory -Path $profileDir -Force | Out-Null; Info "프로파일 폴더 생성: $profileDir" }
if(-not (Test-Path $PROFILE)){ New-Item -ItemType File -Path $PROFILE | Out-Null; Info "프로파일 생성: $PROFILE" }

$profileText = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if($profileText -and $profileText -match 'starship init powershell'){
  Ok "프로파일에 starship 훅 이미 존재"
} else {
  Backup $PROFILE
  $block = @"

# --- Starship prompt (added $stamp) ---
if (Get-Command starship -ErrorAction SilentlyContinue) {
    `$env:STARSHIP_CONFIG = "`$HOME\.config\starship.toml"
    Invoke-Expression (&starship init powershell)
}
"@
  Add-Content -Path $PROFILE -Value $block
  Ok "프로파일에 starship 훅 추가"
}

# --- 5. starship.toml 배치 (성능 튜닝 포함) --------------------------------
$cfgDir = Join-Path $HOME '.config'
if(-not (Test-Path $cfgDir)){ New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
$cfgPath = Join-Path $cfgDir 'starship.toml'
$toml = @'
"$schema" = 'https://starship.rs/config-schema.json'

# 성능: Windows에서 느린 명령(git 등)이 프롬프트를 막지 않도록 타임아웃
command_timeout = 1000
scan_timeout = 30
add_newline = true

[character]
success_symbol = '[❯](bold green)'
error_symbol = '[❯](bold red)'
vimcmd_symbol = '[❮](bold green)'

[directory]
truncation_length = 3
truncate_to_repo = true
style = 'bold cyan'

[git_branch]
symbol = ' '

[git_status]
style = 'bold yellow'

[cmd_duration]
min_time = 2000
format = 'took [$duration](bold yellow) '
'@
Backup $cfgPath
Set-Content -Path $cfgPath -Value $toml -Encoding UTF8
Ok "starship.toml 작성: $cfgPath"

# --- 6. Windows Terminal 폰트 설정 -----------------------------------------
if($SkipTerminalFont){
  Info "Windows Terminal 폰트 설정 건너뜀(-SkipTerminalFont). 수동: 설정>기본값>모양>글꼴 = '$Font'"
} else {
  $wt = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
  if(Test-Path $wt){
    try {
      $json = Get-Content $wt -Raw | ConvertFrom-Json
      if(-not $json.profiles){ $json | Add-Member profiles ([pscustomobject]@{}) -Force }
      if(-not $json.profiles.defaults){ $json.profiles | Add-Member defaults ([pscustomobject]@{}) -Force }
      if($json.profiles.defaults.font.face -eq $Font){
        Ok "Windows Terminal 폰트 이미 '$Font'"
      } else {
        Backup $wt
        if(-not $json.profiles.defaults.font){ $json.profiles.defaults | Add-Member font ([pscustomobject]@{}) -Force }
        $json.profiles.defaults.font | Add-Member face $Font -Force
        $json | ConvertTo-Json -Depth 32 | Set-Content $wt -Encoding UTF8
        Ok "Windows Terminal 기본 폰트 → $Font"
      }
    } catch {
      Warn "Windows Terminal 자동 수정 실패: $($_.Exception.Message)"
      Warn "수동: 설정 > 기본값 > 모양 > 글꼴 = '$Font'"
    }
  } else {
    Warn "Windows Terminal settings.json 없음 — 폰트 수동 설정 필요('$Font')"
  }
}

Write-Host ""
Ok "완료. 새 PowerShell 창을 열거나 '. `$PROFILE' 로 적용을 확인하세요."
Info "디버깅: starship timings (모듈별 소요) | starship config (설정 열기) | `$env:STARSHIP_LOG='trace'"

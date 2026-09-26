<#
============================================================================
 AIStack · установщик для Windows (нативно: PowerShell, без WSL) · v1.5

   Запуск (PowerShell, права администратора не нужны):
     iwr -useb https://aistack-app.github.io/aistack-installer/install.ps1 -OutFile "$env:TEMP\aistack-install.ps1"
     powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\aistack-install.ps1" ВАШ-КЛЮЧ

   Тестовый прогон без установки: добавьте -DryRun (или AISTACK_DRY_RUN=1).

 Что делает: проверяет Windows и PowerShell, ставит OpenClaw официальным
 установщиком (install.ps1 -Tag <пин> -NoOnboard; Node он ставит сам), кладёт
 шаблоны 3 ролей сборки COACH, спрашивает ключ/модель/токены/папку памяти,
 регистрирует агентов, ставит gateway как Scheduled Task (так делает OpenClaw).
 Hermes в Windows-версии не устанавливается. Пока поддерживается только COACH.

 Совместимость: Windows PowerShell 5.1+ (без синтаксиса PowerShell 7).
 Файл сохранён в UTF-8 с BOM — иначе PowerShell 5.1 искажает кириллицу.
============================================================================
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Key = '',
  [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
# Windows PowerShell 5.1 на части систем по умолчанию не включает TLS 1.2 для
# Invoke-WebRequest — без него скачивание с GitHub/openclaw.ai падает
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$script:OpenClawPin  = if ($env:AISTACK_OPENCLAW_PIN) { $env:AISTACK_OPENCLAW_PIN } else { '2026.6.5' }
$script:BaseUrl      = if ($env:AISTACK_BASE_URL) { $env:AISTACK_BASE_URL } else { 'https://aistack-app.github.io/aistack-installer' }
$script:TemplatesZip = if ($env:AISTACK_TEMPLATES_ZIP_URL) { $env:AISTACK_TEMPLATES_ZIP_URL } else { 'https://github.com/aistack-app/aistack-installer/zipball/main' }
$script:DryRun       = [bool]$DryRun -or ($env:AISTACK_DRY_RUN -eq '1')
$script:Utf8         = New-Object System.Text.UTF8Encoding $false
$script:ApiKey       = ''
$script:Work         = ''
$script:Problems     = @()
$script:TgTokens     = @()

# ── Вывод ────────────────────────────────────────────────────────────────────
function Write-AisOk([string]$m)   { Write-Host ('✓ ' + $m) -ForegroundColor Green }
function Write-AisSay([string]$m)  { Write-Host ('▸ ' + $m) -ForegroundColor Cyan }
function Write-AisWarn([string]$m) { Write-Host ('! ' + $m) -ForegroundColor Yellow }
function Write-AisErr([string]$m)  { Write-Host ('❌ ' + $m) -ForegroundColor Red }
function Write-AisStage([string]$m) { Write-Host ''; Write-Host ('▶ ' + $m) -ForegroundColor Magenta }

function Get-AisHome {
  if ($env:USERPROFILE) { return $env:USERPROFILE }
  return $HOME
}

# ── Лог: уникальный временный файл пользователя; симлинк отклоняется ────────
function Initialize-AisLog {
  if ($env:AISTACK_LOG) {
    $p = $env:AISTACK_LOG
    if (Test-Path -LiteralPath $p) {
      $it = Get-Item -LiteralPath $p -Force
      if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-AisErr ("AISTACK_LOG=$p — символическая ссылка. Укажите обычный файл.")
        exit 1
      }
    }
    [IO.File]::WriteAllText($p, '', $script:Utf8)
    $script:Log = $p
  } else {
    # GetTempFileName создаёт новый уникальный файл во временной папке пользователя
    $script:Log = [IO.Path]::GetTempFileName()
  }
}

# ── Маскировка секретов (как redact/mask_secrets в lib/helpers.sh) ──────────
function Protect-AisText([string]$s) {
  if ($null -eq $s) { return '' }
  $vals = @($script:ApiKey) + @($script:TgTokens)
  foreach ($v in $vals) {
    if ($v) { $s = $s.Replace([string]$v, '[REDACTED]') }
  }
  $s = [regex]::Replace($s, '[0-9]{8,12}:[A-Za-z0-9_-]{30,}', '[TG_TOKEN]')
  $s = [regex]::Replace($s, 'sk-[A-Za-z0-9_-]{20,}', 'sk-[REDACTED]')
  $s = [regex]::Replace($s, 'AIza[A-Za-z0-9_-]{30,}', 'AIza[REDACTED]')
  $s = [regex]::Replace($s, '(API_KEY[^=]*=)[^ ]+', '${1}[REDACTED]')
  return $s
}

function Add-AisLog([string]$line) {
  [IO.File]::AppendAllText($script:Log, $line + [Environment]::NewLine, $script:Utf8)
}

# Invoke-AisNative <exe> <args[]> → код возврата; вывод — в лог, с маскировкой.
# В dry-run команда только пишется в лог.
function Invoke-AisNative([string]$Exe, [string[]]$ArgList) {
  $line = ((@($Exe) + @($ArgList)) -join ' ')
  if ($script:DryRun) { Add-AisLog ('[dry-run] ' + (Protect-AisText $line)); return 0 }
  if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) {
    Add-AisLog ("команда не найдена: $Exe"); return 127
  }
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'   # PS 5.1: stderr нативной команды ≠ исключение
  $code = 0
  try {
    & $Exe @ArgList 2>&1 | ForEach-Object { Add-AisLog (Protect-AisText ([string]$_)) }
    $code = $LASTEXITCODE
  } catch {
    Add-AisLog (Protect-AisText $_.Exception.Message)
    $code = 1
  } finally { $ErrorActionPreference = $eap }
  if ($null -eq $code) { $code = 0 }
  return [int]$code
}

function Invoke-AisStep([string]$Msg, [string]$Exe, [string[]]$ArgList, [switch]$Soft) {
  Write-Host ('  · ' + $Msg)
  $code = Invoke-AisNative $Exe $ArgList
  if ($code -eq 0) { Write-Host ('  ✓ ' + $Msg) -ForegroundColor Green; return $true }
  if ($Soft) { Write-AisWarn ("$Msg — не критично (см. лог: $($script:Log))"); return $false }
  Write-AisErr ("Не удалось: $Msg")
  Write-Host ("     лог: $($script:Log) (последние строки):") -ForegroundColor Red
  Get-Content -LiteralPath $script:Log -Tail 15 -Encoding UTF8 | ForEach-Object { Write-Host ('       ' + $_) }
  exit 1
}

# ── Ключ доступа (паритет с parse_key из lib/helpers.sh) ────────────────────
function ConvertFrom-AisKey([string]$Raw) {
  $r = @{ Valid = $false; Error = ''; Tariff = ''; PresetId = ''; Agents = ''; AgentCount = 0
          HasCritic = $false; HasLessons = $false; IsPersonal = $false }
  $k = ([string]$Raw) -replace '\s', ''
  if (-not $k) { $r.Error = 'Ключ не указан. Запустите команду с ключом из письма.'; return $r }
  $up = $k.ToUpperInvariant()
  if ($up.StartsWith('OPENCLAW') -or $up.StartsWith('OPCLAW')) {
    $r.Error = 'Этот ключ устарел. Новые начинаются с AIS-. Поддержка: @superwalletsru.'; return $r
  }
  $i = $up.IndexOf('-')
  if ($i -lt 0 -or $up.Substring(0, $i) -ne 'AIS') { $r.Error = 'Неправильный формат. Ожидается AIS-TARIFF-PRESET-RANDOM.'; return $r }
  $rest = $up.Substring($i + 1)
  $i = $rest.IndexOf('-')
  if ($i -lt 0) { $r.Error = 'Неправильный формат. Не хватает частей ключа.'; return $r }
  $tariff = $rest.Substring(0, $i); $rest = $rest.Substring($i + 1)
  $i = $rest.IndexOf('-')
  if ($i -lt 0 -or $i -eq $rest.Length - 1) { $r.Error = 'Неправильный формат. Не хватает случайной части ключа.'; return $r }
  $preset = $rest.Substring(0, $i); $random = $rest.Substring($i + 1).Replace('-', '')

  if (@('MINI', 'START', 'PROFI', 'TEAM', 'PERSONAL') -notcontains $tariff) {
    $r.Error = "Неизвестный тариф: $tariff. Допустимы: MINI, START, PROFI, TEAM, PERSONAL."; return $r
  }
  if (@('PROFI', 'TEAM', 'PERSONAL') -contains $tariff) {
    if (@('FULL', 'SMALLBIZ', 'COACH') -notcontains $preset) {
      $r.Error = "Тариф $tariff требует сборку FULL, SMALLBIZ или COACH (в ключе: $preset). Поддержка: @superwalletsru."; return $r
    }
  } elseif (@('CONTENT', 'SALES', 'EXPERT', 'BUSINESS', 'SCHOOL', 'TECH', 'SMALLBIZ', 'ADMIN', 'COACH') -notcontains $preset) {
    $r.Error = "Сборка $preset не существует. Для $tariff допустимы: CONTENT, SALES, EXPERT, BUSINESS, SCHOOL, TECH, SMALLBIZ, ADMIN, COACH."; return $r
  }
  if ($random -cnotmatch '^[A-Z0-9]{6,12}$') {
    $r.Error = 'Случайная часть ключа некорректна (ожидается 6–12 символов A–Z / 0–9).'; return $r
  }
  $map = @{
    CONTENT  = @('content-team',  'copywriter contentmaker designer')
    SALES    = @('sales-team',    'coordinator negotiator marketer')
    EXPERT   = @('expert-team',   'coordinator copywriter negotiator')
    BUSINESS = @('business-team', 'producer marketer negotiator')
    SCHOOL   = @('school-team',   'coordinator producer copywriter')
    TECH     = @('tech-team',     'coordinator tech')
    FULL     = @('full-team',     'coordinator tech producer marketer designer copywriter contentmaker negotiator')
    SMALLBIZ = @('smallbiz-team', 'voice pero rost chasy khozyain')
    ADMIN    = @('admin-solo',    'admin')
    COACH    = @('coach-team',    'coordinator designer copywriter')
  }
  $r.PresetId = $map[$preset][0]; $r.Agents = $map[$preset][1]
  $r.AgentCount = @($r.Agents -split ' ').Count
  $r.Tariff = $tariff.ToLowerInvariant()
  $r.HasCritic = @('TEAM', 'PERSONAL') -contains $tariff
  $r.HasLessons = @('START', 'TEAM', 'PERSONAL') -contains $tariff
  $r.IsPersonal = ($tariff -eq 'PERSONAL')
  $r.Valid = $true
  return $r
}

# ── Офлайн-проверки ключей (fail-closed; паритет с lib/wizard.sh) ───────────
# Отсекают пустое, заглушки и явно неверный формат; рабочий ли ключ — только живая проверка.
function Test-AisPlaceholder([string]$v) {
  foreach ($m in @('PLACEHOLDER', 'placeholder', 'EXAMPLE', 'example', 'not-real', 'NOT-REAL', 'REPLACE', '<', '>', '...', '…')) {
    if ($v.Contains($m)) { return $true }
  }
  return $v.StartsWith('000000:')
}
function Get-AisApiKeyProblem([string]$k) {
  if (-not $k) { return 'ключ пуст' }
  if (Test-AisPlaceholder $k) { return 'это заглушка/пример, а не ваш ключ' }
  if ($k -match '\s') { return 'в ключе есть пробелы — скопируйте его целиком без переносов' }
  if ($k.Length -lt 20) { return 'слишком короткий для API-ключа' }
  return ''
}
function Get-AisTgTokenProblem([string]$t) {
  if (-not $t) { return 'токен пуст' }
  if (Test-AisPlaceholder $t) { return 'это заглушка/пример, а не токен бота' }
  if ($t -cnotmatch '^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$') { return 'не похоже на токен @BotFather (ожидается 123456789:AA…)' }
  return ''
}
function Get-AisOwnerTgIdProblem([string]$id) {
  if (-not $id) { return 'нужен Telegram ID владельца (узнать через @userinfobot)' }
  if ($id -notmatch '^[0-9]{5,12}$') { return 'нужен числовой Telegram ID (5–12 цифр)' }
  return ''
}

# ── Провайдер и модель (общий офлайн-список lib/models.tsv) ─────────────────
function Get-AisProvider([string]$k) {
  if ($k.StartsWith('sk-ant-')) { return 'anthropic' }
  if ($k.StartsWith('sk-or-')) { return 'openrouter' }
  if ($k.StartsWith('AIza')) { return 'google' }   # id провайдера в OpenClaw (ключ — GEMINI_API_KEY)
  if ($env:AISTACK_PROVIDER) { return $env:AISTACK_PROVIDER }
  return 'openai'   # sk-… и неизвестный формат: клиенты чаще всего на GPT
}
function Get-AisModelRows {
  $p = $script:ModelsFile
  if (-not $p -or -not (Test-Path -LiteralPath $p)) { return @() }
  $rows = @()
  foreach ($line in [IO.File]::ReadAllLines($p, $script:Utf8)) {
    if ($line.StartsWith('#') -or -not $line) { continue }
    $f = $line.Split("`t")
    if ($f.Count -ge 3) { $rows += , @($f[0], $f[1], $f[2]) }
  }
  return $rows
}
function Get-AisModels([string]$provider) {
  $out = @(); foreach ($r in (Get-AisModelRows)) { if ($r[0] -eq $provider) { $out += $r[1] } }; return $out
}
function Get-AisDefaultModel([string]$provider) {
  foreach ($r in (Get-AisModelRows)) { if ($r[0] -eq $provider -and $r[2] -eq '1') { return $r[1] } }
  return ''
}
function Get-AisModelProblem([string]$provider, [string]$m) {
  if (-not $m) { return 'модель не выбрана' }
  if ($m -cnotmatch '^[a-z0-9-]+/[A-Za-z0-9._:/-]+$') { return 'id модели пишется как провайдер/модель, например openai/gpt-5.5' }
  if ($m.Split('/')[0] -ne $provider) { return "модель $m не относится к провайдеру $provider" }
  return ''
}

# ── Vault (память команды) ──────────────────────────────────────────────────
function Expand-AisHome([string]$p) {
  $h = Get-AisHome
  if ($p -eq '~') { return $h }
  if ($p.StartsWith('~/') -or $p.StartsWith('~\')) { return (Join-Path $h $p.Substring(2)) }
  return $p
}
function Get-AisVaultProblem([string]$p) {
  if (-not $p) { return 'путь пуст' }
  if (-not [IO.Path]::IsPathRooted($p)) { return ('нужен полный путь (например ' + (Join-Path (Get-AisHome) 'AIStack-Vault') + ')') }
  $h = (Get-AisHome).TrimEnd('\', '/')
  $n = $p.TrimEnd('\', '/')
  $oc = Join-Path $h '.openclaw'
  if ($n -eq $h -or $n -eq $oc -or $n.StartsWith($oc + [IO.Path]::DirectorySeparatorChar) -or $n.StartsWith($oc + '/')) {
    return 'нужна отдельная папка, не сам домашний каталог и не .openclaw'
  }
  return ''
}

# ── Мастер настройки ────────────────────────────────────────────────────────
function Test-AisNonInteractive {
  if ($env:AISTACK_NONINTERACTIVE -eq '1' -or $script:DryRun) { return $true }
  try { return [Console]::IsInputRedirected } catch { return $true }
}
function Read-AisSecret([string]$prompt) {
  $sec = Read-Host -Prompt $prompt -AsSecureString
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Invoke-AisWizard($K) {
  $script:Business = ''; $script:OwnerTgId = ''; $script:Model = ''; $script:VaultPath = ''
  $count = $K.AgentCount; $agents = @($K.Agents -split ' ')
  $defVault = Join-Path (Get-AisHome) 'AIStack-Vault'

  if (Test-AisNonInteractive) {
    $script:Business = if ($env:AISTACK_BUSINESS) { $env:AISTACK_BUSINESS } else { 'Demo Project' }
    $script:OwnerTgId = [string]$env:AISTACK_OWNER_TG_ID
    $script:ApiKey = [string]$env:AISTACK_API_KEY
    $script:TgTokens = @(([string]$env:AISTACK_TG_TOKENS) -split '\s+' | Where-Object { $_ })
    if ($script:DryRun -and -not $script:ApiKey -and $script:TgTokens.Count -eq 0) {
      Write-AisSay 'Dry-run без ключей — подставляю заглушки (в реальной установке это запрещено).'
      $script:ApiKey = 'sk-DEV-PLACEHOLDER'
      $script:TgTokens = @(); for ($i = 0; $i -lt $count; $i++) { $script:TgTokens += "000000:DEV-PLACEHOLDER-$i" }
    } else {
      Write-AisSay 'Неинтерактивный режим — беру ключ и токены из окружения.'
      $p = Get-AisApiKeyProblem $script:ApiKey
      if ($p) { Write-AisErr "AISTACK_API_KEY: $p. Без рабочего ключа установка не продолжается."; exit 1 }
      if ($script:TgTokens.Count -ne $count) {
        Write-AisErr "AISTACK_TG_TOKENS: нужно $count токен(ов) через пробел (по одному на агента: $($K.Agents)), передано $($script:TgTokens.Count)."; exit 1
      }
      for ($i = 0; $i -lt $count; $i++) {
        $p = Get-AisTgTokenProblem $script:TgTokens[$i]
        if ($p) { Write-AisErr "AISTACK_TG_TOKENS, токен $($i + 1): $p."; exit 1 }
      }
    }
    if (-not $script:DryRun) {
      $p = Get-AisOwnerTgIdProblem $script:OwnerTgId
      if ($p) { Write-AisErr "AISTACK_OWNER_TG_ID: $p. Без доступа владельца COACH не устанавливается."; exit 1 }
    } elseif ($script:OwnerTgId) {
      $p = Get-AisOwnerTgIdProblem $script:OwnerTgId
      if ($p) { Write-AisErr "AISTACK_OWNER_TG_ID: $p."; exit 1 }
    }
    $script:Provider = Get-AisProvider $script:ApiKey
    $script:Model = if ($env:AISTACK_MODEL) { $env:AISTACK_MODEL } else { Get-AisDefaultModel $script:Provider }
    if ($script:Model) {
      $p = Get-AisModelProblem $script:Provider $script:Model
      if ($p) { Write-AisErr "AISTACK_MODEL: $p."; exit 1 }
    }
    $script:VaultPath = Expand-AisHome $(if ($env:AISTACK_VAULT) { $env:AISTACK_VAULT } else { $defVault })
    $p = Get-AisVaultProblem $script:VaultPath
    if ($p) { Write-AisErr "AISTACK_VAULT: $p."; exit 1 }
    Write-AisOk ("Конфиг принят (provider: $($script:Provider), модель: " + $(if ($script:Model) { $script:Model } else { 'выбрать позже' }) + ", токенов: $($script:TgTokens.Count))")
    return
  }

  Write-AisStage 'Настройка'
  Write-Host '  Вставьте API-ключ нейросети (OpenAI sk-… / Anthropic sk-ant-… / OpenRouter sk-or-…):'
  $script:ApiKey = Read-AisSecret '  ключ'
  while ($p = Get-AisApiKeyProblem $script:ApiKey) { $script:ApiKey = Read-AisSecret "  $p. Вставьте ключ ещё раз" }
  $script:Provider = Get-AisProvider $script:ApiKey
  if (-not ($script:ApiKey.StartsWith('sk-') -or $script:ApiKey.StartsWith('AIza'))) {
    $a = Read-Host '  Чей это ключ?  1) OpenAI (GPT)   2) Anthropic (Claude)   3) OpenRouter  [Enter — 1]'
    $script:Provider = switch ($a) { '2' { 'anthropic' } '3' { 'openrouter' } default { 'openai' } }
  }
  Write-AisOk "Провайдер: $($script:Provider)"

  $list = @(Get-AisModels $script:Provider); $def = Get-AisDefaultModel $script:Provider
  if ($list.Count -eq 0) {
    Write-AisWarn "Для провайдера $($script:Provider) нет готового списка моделей — выберете после установки (openclaw models set)."
  } else {
    Write-Host '  Модель для команды:'
    for ($i = 0; $i -lt $list.Count; $i++) {
      $tag = if ($list[$i] -eq $def) { '  (рекомендуется)' } else { '' }
      Write-Host ("    {0}) {1}{2}" -f ($i + 1), $list[$i], $tag)
    }
    Write-Host '    или впишите свой id (провайдер/модель)'
    while ($true) {
      $a = Read-Host "  номер или id [Enter — $def]"
      if (-not $a) { $m = $def } elseif ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $list.Count) { $m = $list[[int]$a - 1] } else { $m = $a }
      $p = Get-AisModelProblem $script:Provider $m
      if (-not $p) { break }
      Write-AisWarn $p
    }
    $script:Model = $m
    Write-AisOk "Модель: $m (доступ к ней проверяется при первом запуске)"
  }

  $script:Business = Read-Host '  Название вашего проекта/бизнеса [Enter — пропустить]'
  if (-not $script:Business) { $script:Business = 'Мой проект' }

  Write-Host ''
  Write-Host '  Память команды — папка с заметками на этом компьютере (открывается в Obsidian).'
  while ($true) {
    $a = Read-Host "  Где создать [Enter — $defVault]"
    $v = Expand-AisHome $(if ($a) { $a } else { $defVault })
    $p = Get-AisVaultProblem $v
    if (-not $p) { break }
    Write-AisWarn $p
  }
  $script:VaultPath = $v
  Write-AisOk "Память команды: $v"

  Write-Host ''
  Write-Host '  Ваш Telegram ID — чтобы боты отвечали только вам (узнать: @userinfobot).'
  while ($true) {
    $script:OwnerTgId = Read-Host '  Telegram ID владельца (обязательно для COACH)'
    $p = Get-AisOwnerTgIdProblem $script:OwnerTgId
    if (-not $p) { break }
    Write-AisWarn $p
  }

  Write-Host ''
  Write-Host "  Создайте $count ботов в @BotFather (/newbot) и вставьте токены по одному (формат 123456789:AA...)."
  $titles = @{ coordinator = 'Координатор-технарь'; designer = 'Дизайнер · креативы'; copywriter = 'Копирайтер · тексты' }
  $script:TgTokens = @()
  for ($i = 0; $i -lt $count; $i++) {
    $ag = $agents[$i]; $t = if ($titles.ContainsKey($ag)) { $titles[$ag] } else { $ag }
    $tok = Read-Host ("  токен {0}/{1} ({2})" -f ($i + 1), $count, $t)
    while ($p = Get-AisTgTokenProblem $tok) { $tok = Read-Host "  $p — вставьте токен ещё раз" }
    $script:TgTokens += $tok
  }
  Write-AisOk "Принято токенов: $($script:TgTokens.Count)"
}

# ── Шаблоны, vault, персонализация ──────────────────────────────────────────
function Copy-AisMissing([string]$Src, [string]$Dst) {
  $base = (Resolve-Path -LiteralPath $Src).Path.TrimEnd('\', '/')
  foreach ($f in (Get-ChildItem -LiteralPath $base -Recurse -File -Force)) {
    $rel = $f.FullName.Substring($base.Length).TrimStart('\', '/')
    $to = Join-Path $Dst $rel
    if (Test-Path -LiteralPath $to) { continue }
    $dir = Split-Path -Parent $to
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $to
  }
}
function Update-AisPlaceholders([string]$File, [hashtable]$Map) {
  $t = [IO.File]::ReadAllText($File, $script:Utf8)
  $n = $t
  foreach ($k in $Map.Keys) { $n = $n.Replace($k, [string]$Map[$k]) }
  if ($n -ne $t) { [IO.File]::WriteAllText($File, $n, $script:Utf8) }
}

function Get-AisTemplatesDir {
  if ($env:AISTACK_TEMPLATES_DIR) {
    if (-not (Test-Path -LiteralPath $env:AISTACK_TEMPLATES_DIR)) { Write-AisErr "AISTACK_TEMPLATES_DIR=$env:AISTACK_TEMPLATES_DIR — каталог не найден."; exit 1 }
    return $env:AISTACK_TEMPLATES_DIR
  }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('aistack-templates-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'templates.zip'
  Write-Host '  · Скачиваю шаблоны команды'
  Invoke-WebRequest -UseBasicParsing -Uri $script:TemplatesZip -OutFile $zip
  Expand-Archive -LiteralPath $zip -DestinationPath $tmp
  $root = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
  if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root.FullName 'templates'))) {
    Write-AisErr 'В архиве шаблонов нет templates/. Проверьте AISTACK_TEMPLATES_ZIP_URL.'; exit 1
  }
  return (Join-Path $root.FullName 'templates')
}

function Install-AisWorkspaces($K) {
  $wsBase = Join-Path (Get-AisHome) '.openclaw'
  $agents = @($K.Agents -split ' ')
  if ($script:DryRun) {
    foreach ($a in $agents) { Add-AisLog ('[dry-run] mkdir ' + (Join-Path $wsBase "workspace-$a")); Write-AisOk "workspace-$a (dry-run)" }
    return
  }
  $script:TemplatesSrc = Get-AisTemplatesDir
  $preset = Join-Path (Join-Path $script:TemplatesSrc '_presets') $K.PresetId
  foreach ($a in $agents) {
    $src = Join-Path $preset $a
    if (-not (Test-Path -LiteralPath $src)) { Write-AisErr "Нет шаблона роли $a для сборки $($K.PresetId)."; exit 1 }
    $ws = Join-Path $wsBase "workspace-$a"
    New-Item -ItemType Directory -Path $ws -Force | Out-Null
    Copy-AisMissing $src $ws
    Write-AisOk "workspace-$a (сборка $($K.PresetId))"
  }
}

function New-AisVault {
  if ($script:DryRun) { Add-AisLog ('[dry-run] mkdir ' + $script:VaultPath); Write-AisOk "Память команды: $($script:VaultPath) (dry-run)"; return }
  $src = Join-Path $script:TemplatesSrc '_vault'
  if (-not (Test-Path -LiteralPath $src)) { Write-AisErr 'В шаблонах нет _vault/ — не могу создать память команды.'; exit 1 }
  New-Item -ItemType Directory -Path $script:VaultPath -Force | Out-Null
  Copy-AisMissing $src $script:VaultPath
  foreach ($f in (Get-ChildItem -LiteralPath $script:VaultPath -Recurse -File -Filter '*.md')) {
    Update-AisPlaceholders $f.FullName @{ '{{STUDIO_NAME}}' = $script:Business }
  }
  Write-AisOk "Память команды: $($script:VaultPath) (ваши существующие файлы не тронуты)"
}

function Update-AisWorkspaces($K) {
  if ($script:DryRun) { Write-AisOk 'Персонализация (dry-run)'; return }
  $wsBase = Join-Path (Get-AisHome) '.openclaw'
  $model = if ($script:Model) { $script:Model } else { 'не выбрана — openclaw models set' }
  $map = @{ '{{STUDIO_NAME}}' = $script:Business; '{{CHANNEL_ID}}' = 'ЗАПОЛНИТЕ-ПОЗЖЕ'; '{{VAULT_PATH}}' = $script:VaultPath; '{{MODEL}}' = $model }
  foreach ($a in @($K.Agents -split ' ')) {
    $ws = Join-Path $wsBase "workspace-$a"
    if (-not (Test-Path -LiteralPath $ws)) { continue }
    foreach ($t in (Get-ChildItem -LiteralPath $ws -File -Filter '*.template')) {
      $target = $t.FullName.Substring(0, $t.FullName.Length - '.template'.Length)
      if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $t.FullName -Destination $target }
    }
    foreach ($f in (Get-ChildItem -LiteralPath $ws -Recurse -Depth 1 -File | Where-Object { $_.Extension -eq '.md' -or $_.Extension -eq '.json' })) {
      Update-AisPlaceholders $f.FullName $map
    }
  }
  Write-AisOk "Воркспейсы персонализированы: «$($script:Business)»"
}

# ── OpenClaw ────────────────────────────────────────────────────────────────
function Get-AisOpenClawVersion {
  try {
    $v = (& openclaw --version 2>$null | Out-String)
    $m = [regex]::Match($v, '[0-9]{4}\.[0-9]+\.[0-9]+')
    if ($m.Success) { return $m.Value }
  } catch { }
  return ''
}

function Install-AisOpenClaw {
  # dry-run: установленный OpenClaw не запускаем даже для --version (CLI может писать в профиль)
  $cur = if ($script:DryRun) { '' } else { Get-AisOpenClawVersion }
  if ($cur -eq $script:OpenClawPin) { Write-AisOk "OpenClaw $($script:OpenClawPin) уже установлен"; return }
  if ($cur) { Write-AisWarn "Найден OpenClaw $cur — ставлю протестированную версию $($script:OpenClawPin)" }
  if ($script:DryRun) {
    Add-AisLog ("[dry-run] openclaw install.ps1 -Tag $($script:OpenClawPin) -NoOnboard")
    Write-AisOk 'OpenClaw OK (dry-run)'; return
  }
  # Официальный установщик OpenClaw (сам ставит Node через winget/Chocolatey/Scoop
  # или portable-zip). Запуск через -File — так ошибка даёт ненулевой код.
  $ps1 = Join-Path ([IO.Path]::GetTempPath()) ('openclaw-install-' + [Guid]::NewGuid().ToString('N') + '.ps1')
  Invoke-WebRequest -UseBasicParsing -Uri 'https://openclaw.ai/install.ps1' -OutFile $ps1
  $host_ = (Get-Process -Id $PID).Path
  Invoke-AisStep "Ставлю OpenClaw $($script:OpenClawPin) (официальный установщик)" $host_ @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps1, '-Tag', $script:OpenClawPin, '-NoOnboard') | Out-Null
  # установщик добавляет путь в PATH пользователя — подхватываем его в этой сессии
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $cur = Get-AisOpenClawVersion
  if ($cur -ne $script:OpenClawPin) {
    Write-AisErr "OpenClaw $($script:OpenClawPin) не подтвердился (фактически: $(if ($cur) { $cur } else { 'не найден' })). Откройте новое окно PowerShell и запустите установку заново."
    exit 1
  }
  Write-AisOk "OpenClaw OK ($cur)"
}

# ── Секреты — файлами, а не аргументами (argv виден другим процессам) ──────
# Рабочий каталог запуска: уникальный, во временной папке пользователя, удаляется в конце.
function Get-AisWork {
  if (-not $script:Work) {
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('aistack-work-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Work | Out-Null
  }
  return $script:Work
}
function Protect-AisFile([string]$Path) {
  # На Windows файлы в профиле пользователя закрыты его ACL; на macOS/Linux (pwsh) — chmod 600
  if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { & chmod 600 $Path }
}
# Invoke-AisPatch <текст JSON5> <сообщение> — openclaw config patch --file (файл удаляется)
function Invoke-AisPatch([string]$Json5, [string]$Msg) {
  $f = Join-Path (Get-AisWork) ('patch-' + [Guid]::NewGuid().ToString('N') + '.json5')
  if (-not $script:DryRun) { [IO.File]::WriteAllText($f, $Json5, $script:Utf8); Protect-AisFile $f }
  try { Invoke-AisStep $Msg 'openclaw' @('config', 'patch', '--file', $f) -Soft | Out-Null }
  finally { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
}
function ConvertTo-AisJsonStr([string]$v) { return '"' + $v.Replace('\', '\\').Replace('"', '\"') + '"' }
# Файл токена бота: постоянный (OpenClaw хранит путь tokenFile и читает его при работе)
function Get-AisTokenFile([string]$Account, [string]$Token) {
  $d = Join-Path (Join-Path (Get-AisHome) '.openclaw') 'aistack-secrets'
  $f = Join-Path $d "telegram-$Account.token"
  if (-not $script:DryRun) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { & chmod 700 $d }
    [IO.File]::WriteAllText($f, $Token, $script:Utf8); Protect-AisFile $f
  }
  return $f
}

function Set-AisProvider {
  $envvar = if ($script:Provider -eq 'google') { 'GEMINI_API_KEY' } else { $script:Provider.ToUpperInvariant() + '_API_KEY' }
  Invoke-AisPatch ('{ env: { vars: { ' + $envvar + ': ' + (ConvertTo-AisJsonStr $script:ApiKey) + ' } } }') "Сохраняю API-ключ (env.vars.$envvar, через файл)"
  # TO-VERIFY (живой запуск): агентные openai/* модели по документации пина идут
  # через Codex-harness; одного OPENAI_API_KEY может не хватить.
  if ($script:Model) {
    Invoke-AisStep "Модель по умолчанию: $($script:Model)" 'openclaw' @('config', 'set', 'agents.defaults.model.primary', $script:Model) -Soft | Out-Null
  } else { Write-AisWarn 'Модель не выбрана — выберите после установки: openclaw models set <провайдер/модель>' }
}

function Register-AisBots($K) {
  $wsBase = Join-Path (Get-AisHome) '.openclaw'
  $agents = @($K.Agents -split ' ')
  for ($i = 0; $i -lt $agents.Count; $i++) {
    $a = $agents[$i]
    $tf = Get-AisTokenFile $a $script:TgTokens[$i]
    Invoke-AisStep "Telegram-аккаунт: $a" 'openclaw' @('channels', 'add', '--channel', 'telegram', '--account', $a, '--token-file', $tf) -Soft | Out-Null
    $code = Invoke-AisNative 'openclaw' @('agents', 'add', $a, '--non-interactive', '--workspace', (Join-Path $wsBase "workspace-$a"), '--bind', "telegram:$a")
    # Код agents add — только сведения; есть ли агент и привязка, решает
    # Test-AisTeam (чтение конфига), а не догадка «наверное, уже существует»
    if ($code -eq 0) { Write-AisOk "Агент: $a" } else { Write-AisWarn "Агент $a`: agents add не отработал (возможно, уже существует) — проверю чтением конфига" }
    if (-not $script:DryRun -and $i -lt $agents.Count - 1) { Start-Sleep -Seconds 2 }
  }
  if ($script:OwnerTgId) {
    # Одним файлом-патчем: в аргументах native-команд нет кавычек, которые
    # Windows PowerShell 5.1 (legacy-передача аргументов) срезал бы: ["123"] → [123]
    $acc = @(); foreach ($a in $agents) { $acc += ($a + ': { dmPolicy: "allowlist", allowFrom: ["' + $script:OwnerTgId + '"] }') }
    Invoke-AisPatch ('{ channels: { telegram: { accounts: { ' + ($acc -join ', ') + ' } } }, commands: { ownerAllowFrom: ["telegram:' + $script:OwnerTgId + '"] } }') "Доступ только владельцу: $($script:OwnerTgId)"
  }
  if (-not $script:DryRun) {
    if ((Invoke-AisNative 'openclaw' @('config', 'validate')) -ne 0) {
      Write-AisErr "Конфиг не прошёл валидацию после регистрации агентов. Лог: $($script:Log)"; exit 1
    }
    Write-AisOk 'Конфиг валиден'
  }
  Test-AisTeam $K
}

# ── Итог: успех — только если всё подтверждено ─────────────────────────────
function Add-AisProblem([string]$m) { $script:Problems += $m; Write-AisWarn $m }
function Get-AisProp($o, [string]$name) {
  if ($null -eq $o) { return $null }
  $p = $o.PSObject.Properties[$name]
  if ($p) { return $p.Value }
  return $null
}
# openclaw config get <путь> --json → объект (или $null). Вывод не пишется в лог.
function Get-AisConfigJson([string]$Path) {
  if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) { return $null }
  $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $raw = ''
  try { $raw = (& openclaw config get $Path --json 2>$null | Out-String) } catch { $raw = '' }
  finally { $ErrorActionPreference = $eap }
  if (-not $raw -or -not $raw.Trim()) { return $null }
  try { return (ConvertFrom-Json $raw) } catch { return $null }
}
function ConvertTo-AisList($x) {
  # PS 5.1 отдаёт JSON-массив из ConvertFrom-Json одним объектом — разворачиваем
  $out = @(); if ($null -ne $x) { foreach ($i in $x) { $out += , $i } }; return , $out
}
function Test-AisSamePath([string]$Got, [string]$Want, [string]$Agent) {
  if (-not $Got) { return $false }
  $g = $Got.TrimEnd('\', '/'); $w = $Want.TrimEnd('\', '/')
  if ($g -eq ('~/.openclaw/workspace-' + $Agent) -or $g -eq ('~\.openclaw\workspace-' + $Agent)) { return $true }
  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return ($g.Replace('/', '\') -ieq $w.Replace('/', '\')) }
  return ($g -eq $w)
}
# Test-AisTeam — read-back: для каждой роли в конфиге OpenClaw есть Telegram-
# аккаунт с токеном, агент с НАШИМ рабочим каталогом и привязка telegram:<роль>
function Test-AisTeam($K) {
  if ($script:DryRun) { return }
  $wsBase = Join-Path (Get-AisHome) '.openclaw'
  $al = ConvertTo-AisList (Get-AisConfigJson 'agents.list')
  $bl = ConvertTo-AisList (Get-AisConfigJson 'bindings')
  $cl = Get-AisConfigJson 'channels.telegram.accounts'
  $before = $script:Problems.Count
  if (-not $script:OwnerTgId) { Add-AisProblem 'Не задан Telegram ID владельца COACH' }
  foreach ($a in @($K.Agents -split ' ')) {
    $acc = Get-AisProp $cl $a
    if (-not ((Get-AisProp $acc 'tokenFile') -or (Get-AisProp $acc 'botToken'))) {
      Add-AisProblem "Telegram-аккаунт $a не найден в конфиге OpenClaw (бот не подключён)"
    }
    if ($script:OwnerTgId) {
      $allowed = ConvertTo-AisList (Get-AisProp $acc 'allowFrom')
      if ((Get-AisProp $acc 'dmPolicy') -cne 'allowlist' -or $allowed.Count -ne 1 -or [string]$allowed[0] -cne $script:OwnerTgId) {
        Add-AisProblem "Не подтверждён доступ владельца к боту $a (dmPolicy/allowFrom)"
      }
    }
    $want = Join-Path $wsBase "workspace-$a"
    $ag = $null; foreach ($x in $al) { if ((Get-AisProp $x 'id') -eq $a) { $ag = $x; break } }
    if (-not $ag -or -not (Test-AisSamePath ([string](Get-AisProp $ag 'workspace')) $want $a)) {
      Add-AisProblem "Агент $a не найден в конфиге или работает из другого каталога (нужен $want)"
    }
    $bound = $false
    foreach ($b in $bl) {
      $m = Get-AisProp $b 'match'
      if ((Get-AisProp $b 'agentId') -eq $a -and (Get-AisProp $m 'channel') -eq 'telegram' -and (Get-AisProp $m 'accountId') -eq $a) { $bound = $true; break }
    }
    if (-not $bound) { Add-AisProblem "Агент $a не привязан к боту telegram:$a" }
  }
  if ($script:OwnerTgId) {
    $commandsOwner = ConvertTo-AisList (Get-AisConfigJson 'commands.ownerAllowFrom')
    if ($commandsOwner.Count -ne 1 -or [string]$commandsOwner[0] -cne ('telegram:' + $script:OwnerTgId)) {
      Add-AisProblem 'Владелец команд не подтверждён в конфиге (commands.ownerAllowFrom)'
    }
  }
  if ($script:Problems.Count -eq $before) { Write-AisOk ("Команда подтверждена чтением конфига: " + $K.Agents) }
}

function Start-AisGateway {
  # На Windows gateway ставится как Scheduled Task (запасной вариант OpenClaw —
  # ярлык в папке автозагрузки пользователя)
  Invoke-AisStep 'Ставлю gateway как сервис (Scheduled Task, автозапуск)' 'openclaw' @('gateway', 'install') -Soft | Out-Null
  Invoke-AisStep 'Запускаю gateway' 'openclaw' @('gateway', 'start') -Soft | Out-Null
  if ($script:DryRun) { Write-AisOk 'Gateway OK (dry-run)'; return }
  # Подтверждение — код `gateway status --require-rpc` (docs пина), а не текст
  for ($t = 0; $t -lt 10; $t++) {
    if ((Invoke-AisNative 'openclaw' @('gateway', 'status', '--require-rpc')) -eq 0) { Write-AisOk 'Gateway работает (RPC-проба прошла)'; return }
    Start-Sleep -Seconds 3
  }
  Add-AisProblem 'Gateway не ответил на RPC-пробу за 30 с (проверка: openclaw gateway status --require-rpc)'
}

# ── Главный сценарий ────────────────────────────────────────────────────────
function Invoke-AisMain {
  Initialize-AisLog
  Write-Host ''
  Write-Host '  AIStack  ·  AI-команда в одну команду  ·  Windows (без WSL)' -ForegroundColor Magenta
  Write-Host ''

  $K = ConvertFrom-AisKey $Key
  if (-not $K.Valid) { Write-AisErr $K.Error; exit 1 }
  if ($K.PresetId -ne 'coach-team') {
    Write-AisErr "На Windows пока доступна только сборка COACH (в ключе: $($K.PresetId)). Для других сборок — macOS/Linux или поддержка: @superwalletsru."
    exit 1
  }
  Write-AisOk "Ключ принят · тариф: $($K.Tariff) · сборка: $($K.PresetId) · агентов: $($K.AgentCount)"

  Write-AisStage 'ШАГ 1/6 · проверка системы'
  $isWin = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
  if (-not $isWin -and $env:AISTACK_TEST_ALLOW_NONWINDOWS -ne '1') {
    Write-AisErr 'Этот установщик — для Windows. На macOS/Linux используйте install.sh.'; exit 1
  }
  if ($PSVersionTable.PSVersion.Major -lt 5) { Write-AisErr 'Нужен PowerShell 5 или новее.'; exit 1 }
  if ($isWin) {
    $b = [Environment]::OSVersion.Version.Build
    if ($b -lt 19042) { Write-AisWarn "Windows build ${b}: OpenClaw Windows-поддержка описана для Windows 10 20H2+ и Windows 11." }
  }
  Write-AisOk ("PowerShell " + $PSVersionTable.PSVersion.ToString())

  # Настройка ДО установки: без годных ключей ничего не ставим (fail-closed),
  # а дальше установка идёт без участия человека
  Write-AisStage 'ШАГ 2/6 · настройка'
  Invoke-AisWizard $K

  Write-AisStage 'ШАГ 3/6 · OpenClaw (официальный установщик, без WSL)'
  Install-AisOpenClaw
  Invoke-AisStep 'Отключаю автообновление движка' 'openclaw' @('config', 'set', 'update.auto.enabled', 'false', '--strict-json') -Soft | Out-Null

  Write-AisStage 'ШАГ 4/6 · шаблоны и память команды'
  Install-AisWorkspaces $K
  Set-AisProvider
  New-AisVault
  Update-AisWorkspaces $K

  Write-AisStage 'ШАГ 5/6 · регистрация агентов'
  Register-AisBots $K

  Write-AisStage 'ШАГ 6/6 · запуск'
  Start-AisGateway

  # Итог — только по фактам: dry-run ничего не ставит; любая проблема → код 1
  if ($script:DryRun) {
    Write-Host ''
    Write-Host ("  Dry-run завершён: ничего не установлено и не запущено. Команды — в логе: " + $script:Log)
    return
  }
  if ($script:Problems.Count -gt 0) {
    Write-Host ''
    Write-AisErr 'Установка НЕ завершена — команда не готова к работе'
    foreach ($p in $script:Problems) { Write-Host ('  - ' + $p) -ForegroundColor Red }
    Write-Host ('  Лог: ' + $script:Log)
    Write-Host '  Исправьте причину и запустите установку ещё раз (готовые шаги повторятся безопасно).'
    exit 1
  }

  Write-Host ''
  Write-Host '  🚀  AIStack установлен: настройки подтверждены' -ForegroundColor Green
  Write-Host ''
  Write-Host '  Проверено установщиком:'
  Write-Host ("  ✓ Боты Telegram:   {0}/{0} в конфиге OpenClaw, каждый привязан к своей роли — {1}" -f $K.AgentCount, $K.Agents)
  Write-Host ("  ✓ Конфиг OpenClaw: валиден (сборка {0}, {1})" -f $K.PresetId, $K.Tariff)
  Write-Host '  ✓ Gateway:         ответил на RPC-пробу (dashboard http://localhost:18789)'
  Write-Host ("  ✓ Память команды:  {0}  (можно открыть в Obsidian)" -f $script:VaultPath)
  Write-Host ''
  Write-Host '  НЕ проверено установщиком (нужен живой запуск):'
  Write-Host ("  ? ответ модели " + $(if ($script:Model) { $script:Model } else { '(не выбрана: openclaw.cmd models set)' }) + ' с вашим ключом/подпиской')
  Write-Host ("  ? ответы ботов — напишите каждому из {0} ботов «привет»; нет ответа → openclaw.cmd models status" -f $K.AgentCount)
  # openclaw.cmd, а не openclaw: в новом окне PowerShell с политикой по умолчанию
  # «openclaw» может попасть на npm-обёртку openclaw.ps1 и упасть на ExecutionPolicy
  Write-Host '  🩺 Диагностика без изменений: openclaw.cmd status'
  Write-Host ("  Лог установки: " + $script:Log)
}

# Для офлайн-тестов: AISTACK_PS_LIBONLY=1 — только определить функции.
$script:ModelsFile = $env:AISTACK_MODELS_FILE
if (-not $script:ModelsFile -and $PSScriptRoot) { $script:ModelsFile = Join-Path (Join-Path $PSScriptRoot 'lib') 'models.tsv' }
if ($env:AISTACK_PS_LIBONLY -eq '1') { return }
if (-not $script:ModelsFile -or -not (Test-Path -LiteralPath $script:ModelsFile)) {
  $script:ModelsFile = Join-Path ([IO.Path]::GetTempPath()) ('aistack-models-' + [Guid]::NewGuid().ToString('N') + '.tsv')
  try { Invoke-WebRequest -UseBasicParsing -Uri ($script:BaseUrl + '/lib/models.tsv') -OutFile $script:ModelsFile }
  catch { Write-AisErr "Не удалось скачать lib/models.tsv с $($script:BaseUrl). Проверьте интернет."; exit 1 }
}
try { Invoke-AisMain }
finally { if ($script:Work -and (Test-Path -LiteralPath $script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force } }

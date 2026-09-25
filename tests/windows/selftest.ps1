<#
============================================================================
 Самопроверка Windows-установщика (install.ps1) на НАТИВНОЙ Windows PowerShell 5.1.
 Без реальных ключей, без прав администратора, без сети и без установки OpenClaw.

   powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\selftest.ps1

 Что делает:
   1) Снимает сведения об окружении ТОЛЬКО ЧТЕНИЕМ: версия PowerShell, сборка
      Windows, кодовая страница, ExecutionPolicy, чем разрешаются npm/openclaw
      (.ps1 или .cmd), есть ли winget. Ничего не меняет.
   2) Создаёт песочницу во %TEMP% с профилем «Профиль Нина Лебедева» (кириллица
      и пробел) и заглушками openclaw.cmd / openclaw.ps1 (как у npm), которые
      только записывают вызовы и помнят «состояние» конфига.
   3) Запускает install.ps1 через powershell.exe (5.1) по сценариям:
      dry-run, без ключей, штатный, отказ agents add, неответивший gateway.
   4) Пишет отчёт selftest-report.txt и выходит с кодом 0 (всё ок) или 1.

 Ключи и токены — выдуманные, формально корректные. Заглушка НЕ является
 авторизацией: сценарий проверяет установщик, а не модель и не ботов.
 -Keep — не удалять песочницу. Файл в UTF-8 с BOM (иначе 5.1 искажает кириллицу).
============================================================================
#>
[CmdletBinding()]
param([switch]$Keep)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

$Utf8 = New-Object System.Text.UTF8Encoding $false
$IsWin = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$Repo = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
$Installer = Join-Path $Repo 'install.ps1'
$Report = New-Object System.Collections.Generic.List[string]
$script:Fails = 0
function Say([string]$m) { Write-Host $m; $Report.Add($m) }
function Pass([string]$m) { Say ('  ok   - ' + $m) }
function Fail([string]$m) { Say ('  FAIL - ' + $m); $script:Fails++ }

# ── 1) Окружение: только чтение ─────────────────────────────────────────────
Say '# Окружение (только чтение)'
Say ('  PowerShell: {0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
Say ('  ОС: {0}' -f [Environment]::OSVersion.VersionString)
try { Say ('  Кодовая страница консоли: {0}' -f [Console]::OutputEncoding.CodePage) } catch { }
Say ('  Профиль пользователя: {0} (не-ASCII: {1}, пробел: {2})' -f $env:USERPROFILE, ($env:USERPROFILE -match '[^\x00-\x7F]'), ($env:USERPROFILE -match ' '))
$script:Elevated = $false
if ($IsWin) {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $script:Elevated = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  Say ('  Запуск с повышенными правами (администратор): ' + $script:Elevated)
  foreach ($p in (Get-ExecutionPolicy -List)) { Say ('  ExecutionPolicy {0}: {1}' -f $p.Scope, $p.ExecutionPolicy) }
  Say ('  Действующая ExecutionPolicy: {0}' -f (Get-ExecutionPolicy))
}
foreach ($n in @('winget', 'node', 'npm', 'openclaw')) {
  $cmds = @(Get-Command $n -All -ErrorAction SilentlyContinue)
  if ($cmds.Count -eq 0) { Say ('  {0}: не найден' -f $n); continue }
  foreach ($c in $cmds) { Say ('  {0}: {1} → {2}' -f $n, $c.CommandType, $c.Source) }
}
if ($IsWin) {
  $npm = Get-Command npm -ErrorAction SilentlyContinue
  $eff = [string](Get-ExecutionPolicy)
  if ($npm -and $npm.Source -like '*.ps1' -and @('Restricted', 'AllSigned') -contains $eff) {
    Say '  ВНИМАНИЕ: в обычном окне «npm» попадёт на npm.ps1 и упадёт на ExecutionPolicy (симптом «npm.ps1 cannot be loaded»); используйте npm.cmd'
  }
}

# ── 2) Песочница и заглушки ─────────────────────────────────────────────────
$root = Join-Path ([IO.Path]::GetTempPath()) ('aistack selftest ' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$prof = Join-Path $root 'Профиль Нина Лебедева'
$tmp = Join-Path $root 'tmp'
$stubs = Join-Path $root 'stubs'
foreach ($d in @($prof, $tmp, $stubs)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
$calls = Join-Path $root 'calls.log'
Say ('# Песочница: ' + $root)

# Заглушка openclaw «с состоянием» — PowerShell-скрипт; первый аргумент — какая
# обёртка вызвала (cmd|ps1|sh). Отказы: ST_FAIL_AGENTS_ADD=1, ST_GATEWAY_DOWN=1.
$stubPs1 = @'
$shim = $args[0]; $a = @($args | Select-Object -Skip 1)
$calls = $env:ST_CALLS; $st = $calls + '.state'
$u8 = New-Object System.Text.UTF8Encoding $false
[IO.File]::AppendAllText($calls, ('[' + $shim + '] openclaw ' + ($a -join ' ') + [Environment]::NewLine), $u8)
function ArgVal([string]$k) { for ($i = 0; $i -lt $a.Count - 1; $i++) { if ($a[$i] -eq $k) { return $a[$i + 1] } }; return $null }
function Lines([string]$f) { if (Test-Path -LiteralPath $f) { return @([IO.File]::ReadAllLines($f, $u8) | Where-Object { $_ }) }; return @() }
function Esc([string]$s) { return $s.Replace('\', '\\').Replace('"', '\"') }
$k = ''; if ($a.Count -ge 2) { $k = $a[0] + ' ' + $a[1] } elseif ($a.Count -eq 1) { $k = $a[0] }
switch -Wildcard ($k) {
  '--version*' { 'OpenClaw 2026.6.5'; exit 0 }
  'gateway status' { if ($env:ST_GATEWAY_DOWN) { 'Gateway: stopped'; exit 1 }; 'Gateway: running'; exit 0 }
  'config get' {
    switch ($a[2]) {
      'agents.list' { $o = @(); foreach ($l in (Lines "$st.agents")) { $p = $l.Split("`t"); $o += ('{"id": "' + $p[0] + '", "workspace": "' + (Esc $p[1]) + '"}') }; '[' + ($o -join ', ') + ']' }
      'bindings' { $o = @(); foreach ($l in (Lines "$st.agents")) { $p = $l.Split("`t"); $o += ('{"agentId": "' + $p[0] + '", "match": {"channel": "telegram", "accountId": "' + $p[0] + '"}}') }; '[' + ($o -join ', ') + ']' }
      'channels.telegram.accounts' { $o = @(); foreach ($l in (Lines "$st.accounts")) { $p = $l.Split("`t"); $o += ('"' + $p[0] + '": {"tokenFile": "' + (Esc $p[1]) + '"}') }; '{' + ($o -join ', ') + '}' }
    }
    exit 0
  }
  'config patch' {
    $f = ArgVal '--file'
    if ($f -and (Test-Path -LiteralPath $f)) { [IO.File]::AppendAllText("$calls.patches", ([IO.File]::ReadAllText($f, $u8) + [Environment]::NewLine), $u8) }
    else { [IO.File]::AppendAllText("$calls.files", ('PATCH missing' + [Environment]::NewLine), $u8) }
    exit 0
  }
  'channels add' {
    $acc = ArgVal '--account'; $f = ArgVal '--token-file'
    if ($f -and (Test-Path -LiteralPath $f)) {
      $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
      [IO.File]::AppendAllText("$calls.files", ('TOKEN ' + $acc + ' ' + $h + [Environment]::NewLine), $u8)
      [IO.File]::AppendAllText("$st.accounts", ($acc + "`t" + $f + [Environment]::NewLine), $u8)
    }
    exit 0
  }
  'agents add' {
    $ag = $a[2]; $ws = ArgVal '--workspace'
    if ($env:ST_FAIL_AGENTS_ADD) { 'Error: agents add failed'; exit 9 }
    [IO.File]::AppendAllText("$st.agents", ($ag + "`t" + $ws + [Environment]::NewLine), $u8)
    exit 0
  }
  default { exit 0 }
}
'@
[IO.File]::WriteAllText((Join-Path $stubs 'openclaw-stub.ps1'), $stubPs1, (New-Object System.Text.UTF8Encoding $true))
if ($IsWin) {
  $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  # как npm: openclaw.cmd и openclaw.ps1 рядом; какая сработала — видно в calls.log
  $cmd = "@echo off`r`n`"$ps51`" -NoProfile -ExecutionPolicy Bypass -File `"$stubs\openclaw-stub.ps1`" cmd %*`r`nexit /b %ERRORLEVEL%`r`n"
  [IO.File]::WriteAllText((Join-Path $stubs 'openclaw.cmd'), $cmd, (New-Object System.Text.UTF8Encoding $false))
  [IO.File]::WriteAllText((Join-Path $stubs 'openclaw.ps1'), ("& `"$stubs\openclaw-stub.ps1`" ps1 @args`r`nexit `$LASTEXITCODE`r`n"), (New-Object System.Text.UTF8Encoding $true))
  $hostExe = $ps51
} else {
  # не Windows (только для проверки логики самого selftest): заглушка — sh-обёртка
  $self = (Get-Process -Id $PID).Path
  [IO.File]::WriteAllText((Join-Path $stubs 'openclaw'), ("#!/bin/sh`nexec `"$self`" -NoProfile -File `"$stubs/openclaw-stub.ps1`" sh `"`$@`"`n"), $Utf8)
  & chmod +x (Join-Path $stubs 'openclaw')
  $hostExe = $self
}

# ── 3) Сценарии ─────────────────────────────────────────────────────────────
$Key = 'sk-proj-FAKEselftestFAKEselftestFAKE01'
$Toks = @('111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001', '222222222:FAKEtokenFAKEtokenFAKEtokenFAKE0002', '333333333:FAKEtokenFAKEtokenFAKEtokenFAKE0003')
$saved = @{}
foreach ($n in @('USERPROFILE', 'TEMP', 'TMP', 'TMPDIR', 'PATH', 'HOME')) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }

function Invoke-Scenario([string]$Name, [hashtable]$Vars, [string[]]$HostArgs = @()) {
  foreach ($f in @($calls, "$calls.files", "$calls.patches", "$calls.state.agents", "$calls.state.accounts")) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
  if (Test-Path -LiteralPath $prof) { Remove-Item -LiteralPath $prof -Recurse -Force }
  New-Item -ItemType Directory -Path $prof -Force | Out-Null
  $all = @{ USERPROFILE = $prof; TEMP = $tmp; TMP = $tmp; TMPDIR = $tmp; PATH = ($stubs + [IO.Path]::PathSeparator + $saved['PATH'])
            ST_CALLS = $calls; AISTACK_NONINTERACTIVE = '1'; AISTACK_TEMPLATES_DIR = (Join-Path $Repo 'templates')
            AISTACK_LOG = (Join-Path $tmp "install-$Name.log"); AISTACK_BUSINESS = 'Нина Лебедева · сон & отдых' }
  if (-not $IsWin) { $all['AISTACK_TEST_ALLOW_NONWINDOWS'] = '1'; $all['HOME'] = (Join-Path $root 'pwsh-home') }
  foreach ($k in $Vars.Keys) { $all[$k] = $Vars[$k] }
  $names = @('AISTACK_DRY_RUN', 'AISTACK_API_KEY', 'AISTACK_TG_TOKENS', 'ST_FAIL_AGENTS_ADD', 'ST_GATEWAY_DOWN', 'AISTACK_OWNER_TG_ID') + @($all.Keys)
  foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $null) }
  foreach ($k in $all.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$all[$k]) }
  $out = Join-Path $root "out-$Name.txt"; $err = Join-Path $root "err-$Name.txt"
  try {
    if ($HostArgs.Count -eq 0) { $HostArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Installer + '"'), 'AIS-START-COACH-TEST0001') }
    $p = Start-Process -FilePath $hostExe -ArgumentList $HostArgs `
      -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $code = $p.ExitCode
  } finally {
    foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $null) }
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
  }
  $text = ''
  foreach ($f in @($out, $err)) { if (Test-Path -LiteralPath $f) { $text += [IO.File]::ReadAllText($f, $Utf8) } }
  $callText = ''; if (Test-Path -LiteralPath $calls) { $callText = [IO.File]::ReadAllText($calls, $Utf8) }
  # дерево профиля — СРАЗУ после сценария (следующий сценарий профиль очистит);
  # сохраняется в tree-<сценарий>.txt рядом с out-/err-файлами (видно с -Keep)
  $tree = @(Get-TreeList)
  [IO.File]::WriteAllLines((Join-Path $root "tree-$Name.txt"), [string[]]$tree, (New-Object System.Text.UTF8Encoding $true))
  return @{ Code = $code; Text = $text; Calls = $callText; Marks = ([regex]::Matches($text, 'AIStack установлен')).Count; Tree = $tree }
}
function Get-TreeList {
  if (-not (Test-Path -LiteralPath $prof)) { return @() }
  return @(Get-ChildItem -LiteralPath $prof -Recurse -Force | ForEach-Object { $_.FullName.Substring($prof.Length) } | Sort-Object)
}
# Test-Parts <название> <[ordered] часть→bool> <подробности при провале>: ok только
# если ВСЕ части истинны; иначе FAIL с каждой частью отдельно
function Test-Parts([string]$Title, $Parts, [string[]]$Details = @()) {
  $bad = @(); foreach ($k in $Parts.Keys) { if (-not $Parts[$k]) { $bad += $k } }
  if ($bad.Count -eq 0) { Pass $Title; return }
  Fail ($Title + ' — не выполнено: ' + ($bad -join '; '))
  foreach ($k in $Parts.Keys) { Say ('         [{0}] {1}' -f $(if ($Parts[$k]) { 'да ' } else { 'НЕТ' }), $k) }
  foreach ($d in $Details) { Say ('         ' + $d) }
}

Say ('# Сценарии (install.ps1 через ' + $hostExe + ')')
# ВНИМАНИЕ: переменные PowerShell нечувствительны к регистру — не называть $toks
$TokLine = $Toks -join ' '

# Контроль: тот же хост и то же окружение (USERPROFILE = песочница), но без
# установщика. Показывает, что пишет в профиль САМ PowerShell (например, если
# известные папки вида %USERPROFILE%\AppData\Local раскрываются в песочницу).
$ctl = Invoke-Scenario 'host-control' @{} @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'exit 0')
Say ('  инфо - контроль (powershell.exe -Command "exit 0", без установщика): код {0}, объектов в профиле: {1}' -f $ctl.Code, $ctl.Tree.Count)
foreach ($t in ($ctl.Tree | Select-Object -First 15)) { Say ('         контроль: ' + $t) }

$r = Invoke-Scenario 'dry' @{ AISTACK_DRY_RUN = '1'; AISTACK_API_KEY = $Key; AISTACK_TG_TOKENS = $TokLine }
$phrase = 'ничего не установлено'
$tail = @(($r.Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 3)
$onlyDry = @($r.Tree | Where-Object { $ctl.Tree -notcontains $_ })
$details = @()
$details += ('код выхода: {0}; «AIStack установлен»×{1}; вызовов openclaw: {2} байт' -f $r.Code, $r.Marks, $r.Calls.Length)
$details += ('фраза «{0}» в выводе: {1}; последние строки вывода: {2}' -f $phrase, $r.Text.Contains($phrase), (($tail | ForEach-Object { '«' + $_.Trim() + '»' }) -join ' | '))
$details += ('объектов в профиле после dry-run: {0} (из них нет в контроле: {1}); список — tree-dry.txt' -f $r.Tree.Count, $onlyDry.Count)
foreach ($t in ($r.Tree | Select-Object -First 15)) { $details += ('профиль после dry-run: ' + $t + $(if ($ctl.Tree -contains $t) { '   [есть и в контроле]' } else { '' })) }
$parts = [ordered]@{
  'код выхода 0'                           = ($r.Code -eq 0)
  'нет «AIStack установлен»'              = ($r.Marks -eq 0)
  ('в выводе есть «' + $phrase + '»')      = $r.Text.Contains($phrase)
  'профиль после dry-run пуст'             = ($r.Tree.Count -eq 0)
  'ни одного вызова openclaw'              = (-not $r.Calls)
}
Test-Parts 'dry-run: exit 0, без «AIStack установлен», профиль пуст, ни одного вызова openclaw' $parts $details

$r = Invoke-Scenario 'nokeys' @{}
if ($r.Code -ne 0 -and $r.Marks -eq 0 -and $r.Text -match 'AISTACK_API_KEY' -and -not $r.Calls) { Pass 'без ключей: отказ до любых вызовов openclaw' }
else { Fail ("без ключей: exit={0}, маркер×{1}" -f $r.Code, $r.Marks) }

$r = Invoke-Scenario 'happy' @{ AISTACK_API_KEY = $Key; AISTACK_TG_TOKENS = $TokLine; AISTACK_OWNER_TG_ID = '123456789' }
if ($r.Code -eq 0 -and $r.Marks -eq 1 -and $r.Text -match 'НЕ проверено установщиком') { Pass 'штатный прогон: exit 0, «AIStack установлен» 1 раз, с явным «НЕ проверено»' }
else { Fail ("штатный прогон: exit={0}, маркер×{1}: {2}" -f $r.Code, $r.Marks, ($r.Text -split "`n" | Select-String -Pattern '❌|Exception|НЕ завершена' | Select-Object -First 2)) }
$leak = @(); foreach ($s in @($Key) + $Toks) { if ($r.Calls.Contains($s) -or $r.Text.Contains($s)) { $leak += $s.Substring(0, 12) + '…' } }
if ($leak.Count -eq 0) { Pass 'ключ и токены не попали в аргументы openclaw и в вывод' } else { Fail ('утечка: ' + ($leak -join ', ')) }
if (-not $r.Calls.Contains('"')) { Pass 'в аргументах openclaw нет кавычек (legacy-передача аргументов 5.1 их не исказит)' } else { Fail 'в аргументах openclaw есть кавычки' }
$shims = @([regex]::Matches($r.Calls, '^\[(\w+)\]', 'Multiline') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Say ('  инфо - install.ps1 вызывал обёртку: ' + ($shims -join ', ') + ' (при openclaw.cmd и openclaw.ps1 рядом)')
$files = ''; if (Test-Path -LiteralPath "$calls.files") { $files = [IO.File]::ReadAllText("$calls.files", $Utf8) }
$tokOk = $true
$sha = [Security.Cryptography.SHA256]::Create()
for ($i = 0; $i -lt 3; $i++) {
  $role = @('coordinator', 'designer', 'copywriter')[$i]
  $want = (($sha.ComputeHash($Utf8.GetBytes($Toks[$i])) | ForEach-Object { $_.ToString('X2') }) -join '')
  if ($files -notmatch ("TOKEN $role $want")) { $tokOk = $false }
}
if ($tokOk) { Pass 'каждая роль получила свой токен через --token-file' } else { Fail ('токены: ' + $files.Trim()) }
$patches = ''; if (Test-Path -LiteralPath "$calls.patches") { $patches = [IO.File]::ReadAllText("$calls.patches", $Utf8) }
if ($patches.Contains('OPENAI_API_KEY: "' + $Key + '"') -and $patches.Contains('ownerAllowFrom: ["telegram:123456789"]')) { Pass 'ключ и доступ владельца переданы файлами-патчами' } else { Fail 'патчи не содержат ключ/доступ владельца' }
$left = @(Get-ChildItem -LiteralPath $tmp -Directory -Filter 'aistack-work-*' -ErrorAction SilentlyContinue)
if ($left.Count -eq 0) { Pass 'рабочий каталог с временными патчами удалён' } else { Fail ('остался: ' + $left[0].Name) }
$exp = Join-Path (Join-Path (Join-Path $prof 'AIStack-Vault') 'profile') 'expert.md'
if ((Test-Path -LiteralPath $exp) -and ([IO.File]::ReadAllText($exp, $Utf8)).Contains('Нина Лебедева · сон & отдых')) { Pass 'vault в профиле с кириллицей и пробелом создан, название записано в UTF-8 без искажений' }
else { Fail 'vault/кодировка: profile\expert.md не найден или название искажено' }

$r = Invoke-Scenario 'agentsfail' @{ AISTACK_API_KEY = $Key; AISTACK_TG_TOKENS = $TokLine; ST_FAIL_AGENTS_ADD = '1' }
if ($r.Code -ne 0 -and $r.Marks -eq 0 -and $r.Text -match 'НЕ завершена') { Pass 'agents add падает → «НЕ завершена», код ≠ 0, маркера нет' } else { Fail ("agents add: exit={0}, маркер×{1}" -f $r.Code, $r.Marks) }

$r = Invoke-Scenario 'gwdown' @{ AISTACK_API_KEY = $Key; AISTACK_TG_TOKENS = $TokLine; ST_GATEWAY_DOWN = '1' }
if ($r.Code -ne 0 -and $r.Marks -eq 0 -and $r.Text -match 'Gateway') { Pass 'gateway не отвечает → «НЕ завершена», код ≠ 0, маркера нет' } else { Fail ("gateway: exit={0}, маркер×{1}" -f $r.Code, $r.Marks) }

# ── 4) Итог ─────────────────────────────────────────────────────────────────
if ($script:Elevated) { Fail 'запуск с повышенными правами: приёмка требует обычного окна PowerShell (не «от имени администратора»)' }
Say ''
if ($script:Fails -eq 0) { Say 'SELFTEST: ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ' } else { Say ("SELFTEST: ПРОВАЛЕНО ПРОВЕРОК: {0}" -f $script:Fails) }
Say 'Это проверка установщика на заглушках: модель, авторизация, Telegram и реальный OpenClaw НЕ проверялись.'
$rep = Join-Path ([IO.Path]::GetTempPath()) ('aistack-selftest-report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
[IO.File]::WriteAllLines($rep, $Report, (New-Object System.Text.UTF8Encoding $true))
Write-Host ('Отчёт: ' + $rep)
if (-not $Keep) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } else { Write-Host ('Песочница сохранена: ' + $root) }
if ($script:Fails -eq 0) { exit 0 } else { exit 1 }

# Пакетный вызов функций install.ps1 для тестов паритета с bash.
# stdin: строки «op<TAB>arg1<TAB>arg2»; stdout: одна строка результата на строку.
$ErrorActionPreference = 'Stop'
$env:AISTACK_PS_LIBONLY = '1'
. (Join-Path (Join-Path $PSScriptRoot '..') '../install.ps1')
$script:ApiKey = [string]$env:PARITY_API_KEY
$script:TgTokens = @(([string]$env:PARITY_TG) -split ' ' | Where-Object { $_ })
function B([bool]$v) { if ($v) { 'true' } else { 'false' } }
foreach ($line in [Console]::In.ReadToEnd().Split("`n")) {
  if (-not $line) { continue }
  $f = $line.Split("`t"); $a1 = ''; $a2 = ''
  if ($f.Count -gt 1) { $a1 = $f[1] }
  if ($f.Count -gt 2) { $a2 = $f[2] }
  switch ($f[0]) {
    'key' {
      $r = ConvertFrom-AisKey $a1
      $rc = if ($r.Valid) { 0 } else { 1 }
      '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}' -f $rc, $r.PresetId, $r.Agents, $r.AgentCount, $r.Tariff, (B $r.HasCritic), (B $r.HasLessons), (B $r.IsPersonal), $r.Error
    }
    'apikey'   { Get-AisApiKeyProblem $a1 }
    'tg'       { Get-AisTgTokenProblem $a1 }
    'prov'     { Get-AisProvider $a1 }
    'defmodel' { Get-AisDefaultModel $a1 }
    'models'   { (Get-AisModels $a1) -join ' ' }
    'modelp'   { Get-AisModelProblem $a1 $a2 }
    'vaultp'   { Get-AisVaultProblem $a1 }
    'expand'   { Expand-AisHome $a1 }
    'mask'     { Protect-AisText $a1 }
    default    { "unknown op $($f[0])" }
  }
}

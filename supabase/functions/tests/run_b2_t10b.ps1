<#
  run_b2_t10b.ps1 — безопасная проверка parent-bot-api с одноразовыми приглашениями
  (B2-T10B, T10-10B, migration 044). Windows PowerShell 5.1.
  НЕ печатает PARENT_BOT_API_SECRET.

  ПОРЯДОК:
    1) применить database/migrations/044_t10_parent_invites.sql в dev;
    2) выполнить SQL "ПОДГОТОВКА" — скрипт печатает его сам:
         .\run_b2_t10b.ps1 -ShowPrepSql
       (скопировать в Supabase SQL editor и выполнить);
    3) задеплоить parent-bot-api и запустить проверку:
         .\run_b2_t10b.ps1 -FunctionUrl "https://<ref>.functions.supabase.co/parent-bot-api"
    4) выполнить SQL "ОЧИСТКА" — скрипт печатает его в конце (и по -ShowCleanupSql).

  Токены тестовых приглашений детерминированы и заданы ниже: их hash считает SQL подготовки,
  поэтому Mini App для прогона не нужен. Это ТЕСТОВЫЕ токены синтетических учеников —
  секретами не являются.
#>
param(
  [string]$FunctionUrl,
  [switch]$ShowPrepSql,
  [switch]$ShowCleanupSql,
  [long]$ParentA  = 995100001,
  [long]$ParentB  = 995100002,
  [long]$StudentA = 995000020,
  [long]$StudentB = 995000021
)

$ErrorActionPreference = 'Stop'

# --- Тестовые токены (48 символов, тот же алфавит, что выдаёт create_parent_invite_self) --------
$TokenValid    = 'b2t10bvalid0000000000000000000000000000000000001'
$TokenExpired  = 'b2t10bexpired00000000000000000000000000000000002'
$TokenRace     = 'b2t10brace00000000000000000000000000000000000004'
$TokenStudentB = 'b2t10bstudentb0000000000000000000000000000000005'
$TokenForged   = 'b2t10bforged000000000000000000000000000000000666'  # в БД НЕ вставляется

function Get-PrepSql {
  return @"
-- ПОДГОТОВКА B2-T10B (выполнить в Supabase SQL editor ПОСЛЕ миграции 044).
-- Создаёт двух синтетических учеников, немного учебных данных и четыре приглашения
-- с заранее известными токенами (в таблицу кладётся только их SHA-256 hash).

insert into public.students (telegram_id, name)
values ($StudentA, 'B2-T10B ученик A'), ($StudentB, 'B2-T10B ученик B')
on conflict (telegram_id) do nothing;

-- Немного заданий ученику A, чтобы progress/неделя были не пустыми
insert into public.assignments (student_id, type, title, activation_status, status, approval_status, scheduled_date)
values
  ($StudentA, 'daily', 'B2-T10B daily 1', 'active', 'checked', 'approved', current_date),
  ($StudentA, 'daily', 'B2-T10B daily 2', 'active', 'assigned', null,      current_date),
  ($StudentA, 'weekly','B2-T10B weekly',  'active', 'assigned', null,      current_date)
on conflict do nothing;

-- Пробники ученику A (источник траектории U05A/U05B)
insert into public.weekly_mock_exams (student_id, week_start, score)
values
  ($StudentA, public.week_start_of(current_date - 14), 62),
  ($StudentA, public.week_start_of(current_date - 7),  70)
on conflict do nothing;

-- Приглашения: hash считается тем же способом, что и в create_parent_invite_self
insert into public.parent_invites (student_id, token_hash, expires_at)
values
  ($StudentA, encode(sha256(convert_to('$TokenValid',    'UTF8')), 'hex'), now() + interval '24 hours'),
  ($StudentA, encode(sha256(convert_to('$TokenExpired',  'UTF8')), 'hex'), now() - interval '1 hour'),
  ($StudentA, encode(sha256(convert_to('$TokenRace',     'UTF8')), 'hex'), now() + interval '24 hours'),
  ($StudentB, encode(sha256(convert_to('$TokenStudentB', 'UTF8')), 'hex'), now() + interval '24 hours')
on conflict (token_hash) do nothing;

-- контроль: должно вернуть 4
select count(*) from public.parent_invites where student_id in ($StudentA, $StudentB);
"@
}

function Get-CleanupSql {
  return @"
-- ОЧИСТКА B2-T10B (выполнить в Supabase SQL editor после прогона).
-- parent_links чистится по student_id, а НЕ только по двум основным родителям: кейс 13
-- (concurrent consume) привязывает победителя из диапазона 995200000-995200007, и без этого
-- удаление students падает на FK parent_links_student_id_fkey.
delete from public.parent_invites     where student_id in ($StudentA, $StudentB);
delete from public.parent_links       where student_id in ($StudentA, $StudentB)
                                         or parent_telegram_id in ($ParentA, $ParentB);
delete from public.weekly_mock_exams  where student_id in ($StudentA, $StudentB);
delete from public.assignments        where student_id in ($StudentA, $StudentB);
delete from public.students           where telegram_id in ($StudentA, $StudentB);

-- контроль: все три выборки должны вернуть 0
select count(*) from public.parent_invites where student_id in ($StudentA, $StudentB);
select count(*) from public.parent_links   where student_id in ($StudentA, $StudentB);
select count(*) from public.students       where telegram_id in ($StudentA, $StudentB);
"@
}

if ($ShowPrepSql)    { Get-PrepSql;    return }
if ($ShowCleanupSql) { Get-CleanupSql; return }
if (-not $FunctionUrl) { throw "Укажите -FunctionUrl (или -ShowPrepSql / -ShowCleanupSql)." }

$secSecret = Read-Host -AsSecureString "Введите PARENT_BOT_API_SECRET (ввод скрыт)"
function Get-PlainSecret([System.Security.SecureString]$sec) {
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$results = New-Object System.Collections.ArrayList
function Add-Check([string]$Case, [string]$Expected, [string]$Actual, [bool]$Pass) {
  $r = 'FAIL'; if ($Pass) { $r = 'PASS' }
  [void]$results.Add([pscustomobject]@{ Case = $Case; Expected = $Expected; Actual = $Actual; Result = $r })
}
function Add-Info([string]$Case, [string]$Note) {
  [void]$results.Add([pscustomobject]@{ Case = $Case; Expected = '-'; Actual = $Note; Result = 'INFO' })
}

function Send-ParentApi($BodyObj, [string]$Secret, [string]$Method = 'Post') {
  $headers = @{}
  if ($null -ne $Secret) { $headers['X-Parent-Bot-Secret'] = $Secret }
  $body = $null
  if ($BodyObj -ne $null) { $body = ($BodyObj | ConvertTo-Json -Compress) }
  try {
    $params = @{ Uri = $FunctionUrl; Method = $Method; UseBasicParsing = $true; Headers = $headers }
    if ($body) { $params['ContentType'] = 'application/json'; $params['Body'] = $body }
    $resp = Invoke-WebRequest @params
    $json = $null
    try { $json = $resp.Content | ConvertFrom-Json } catch {}
    return @{ Status = [int]$resp.StatusCode; Error = $null; Data = $json.data }
  } catch {
    $r = $_.Exception.Response
    if ($r -ne $null) {
      $status = [int]$r.StatusCode
      $reader = New-Object IO.StreamReader($r.GetResponseStream())
      $content = $reader.ReadToEnd(); $reader.Close()
      $err = 'unknown'
      try { $err = ($content | ConvertFrom-Json).error } catch {}
      return @{ Status = $status; Error = $err; Data = $null }
    }
    return @{ Status = 0; Error = 'neterror'; Data = $null }
  }
}

# Рекурсивный поиск запрещённого ключа в любом месте ответа (приватность формы ответа).
function Test-ForbiddenKey($node, [string[]]$Forbidden) {
  if ($null -eq $node) { return @() }
  $found = @()
  if ($node -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $node.PSObject.Properties) {
      if ($Forbidden -contains $p.Name) { $found += $p.Name }
      $found += Test-ForbiddenKey $p.Value $Forbidden
    }
  } elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
    foreach ($item in $node) { $found += Test-ForbiddenKey $item $Forbidden }
  }
  return $found
}

$secret = Get-PlainSecret $secSecret
try {

  # --- Секрет и базовый контракт ---
  $r = Send-ParentApi @{ action = 'linked_students'; parent_id = $ParentA } $null
  Add-Check '01 missing secret' '401/unauthorized' "$($r.Status)/$($r.Error)" ($r.Status -eq 401 -and $r.Error -eq 'unauthorized')

  $r = Send-ParentApi @{ action = 'linked_students'; parent_id = $ParentA } 'obviously-wrong-secret-value'
  Add-Check '02 wrong secret' '401/unauthorized' "$($r.Status)/$($r.Error)" ($r.Status -eq 401 -and $r.Error -eq 'unauthorized')

  $r = Send-ParentApi @{ action = 'drop_everything' } $secret
  Add-Check '03 unknown action' '400/bad_request' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_request')

  $r = Send-ParentApi $null $secret 'Get'
  Add-Check '04 GET method' '405/method_not_allowed' "$($r.Status)/$($r.Error)" ($r.Status -eq 405)

  # --- link больше НЕ принимает student_id ---
  $r = Send-ParentApi @{ action = 'link'; parent_id = $ParentA; student_id = $StudentA } $secret
  Add-Check '05 link по student_id (старый способ)' '200, linked=false' "HTTP $($r.Status) linked=$($r.Data.linked)" ($r.Status -eq 200 -and $r.Data.linked -eq $false)

  # --- malformed / forged токены: одинаковый безопасный отказ ---
  $r = Send-ParentApi @{ action = 'link'; parent_id = $ParentA; token = 'short' } $secret
  Add-Check '06 malformed token' '200, linked=false, name=null' "HTTP $($r.Status) linked=$($r.Data.linked) name=$($r.Data.name)" ($r.Status -eq 200 -and $r.Data.linked -eq $false -and $null -eq $r.Data.name)

  $r = Send-ParentApi @{ action = 'link'; parent_id = $ParentA; token = "$TokenForged" } $secret
  Add-Check '07 forged token' '200, linked=false, name=null' "HTTP $($r.Status) linked=$($r.Data.linked) name=$($r.Data.name)" ($r.Status -eq 200 -and $r.Data.linked -eq $false -and $null -eq $r.Data.name)

  $r = Send-ParentApi @{ action = 'link'; parent_id = $ParentA; token = "$TokenExpired" } $secret
  Add-Check '08 expired token' '200, linked=false, name=null' "HTTP $($r.Status) linked=$($r.Data.linked) name=$($r.Data.name)" ($r.Status -eq 200 -and $r.Data.linked -eq $false -and $null -eq $r.Data.name)

  # --- valid consume ---
  $r = Send-ParentApi @{ action = 'link'; parent_id = $ParentA; token = "$TokenValid" } $secret
  Add-Check '09 valid consume' '200, linked=true, есть имя' "HTTP $($r.Status) linked=$($r.Data.linked) name=$($r.Data.name)" ($r.Status -eq 200 -and $r.Data.linked -eq $true -and $r.Data.name)

  # --- retry ТЕМ ЖЕ родителем: идемпотентный успех ---
  $r = Send-ParentApi @{ action = 'link'; parent_id = $ParentA; token = "$TokenValid" } $secret
  Add-Check '10 retry того же родителя' '200, linked=true (идемпотентно)' "HTTP $($r.Status) linked=$($r.Data.linked)" ($r.Status -eq 200 -and $r.Data.linked -eq $true)

  # --- ВТОРОЙ родитель с тем же токеном: отказ ---
  $r = Send-ParentApi @{ action = 'link'; parent_id = $ParentB; token = "$TokenValid" } $secret
  Add-Check '11 второй родитель по использованному токену' '200, linked=false' "HTTP $($r.Status) linked=$($r.Data.linked)" ($r.Status -eq 200 -and $r.Data.linked -eq $false)

  # и он действительно не получил доступ
  $r = Send-ParentApi @{ action = 'progress'; parent_id = $ParentB; student_id = $StudentA } $secret
  Add-Check '12 второй родитель не получил доступ' '403/forbidden' "$($r.Status)/$($r.Error)" ($r.Status -eq 403 -and $r.Error -eq 'forbidden')

  # --- concurrent consume: 8 одновременных попыток одного свежего токена ---
  $sb = {
    param($Url, $Secret, $Token, $ParentId)
    try {
      $body = (@{ action = 'link'; parent_id = $ParentId; token = $Token } | ConvertTo-Json -Compress)
      $resp = Invoke-WebRequest -Uri $Url -Method Post -ContentType 'application/json' `
        -Headers @{ 'X-Parent-Bot-Secret' = $Secret } -Body $body -UseBasicParsing
      $d = ($resp.Content | ConvertFrom-Json).data
      if ($d.linked -eq $true) { "OK" } else { "REJECTED" }
    } catch { "ERR" }
  }
  # Разные parent_id => идемпотентный retry не может замаскировать двойное поглощение.
  $jobs = 0..7 | ForEach-Object {
    Start-Job -ScriptBlock $sb -ArgumentList $FunctionUrl, $secret, $TokenRace, (995200000 + $_)
  }
  $out = $jobs | Wait-Job | Receive-Job
  $jobs | Remove-Job
  $okCount = @($out | Where-Object { $_ -eq 'OK' }).Count
  Add-Check '13 concurrent consume (8 параллельно)' 'ровно 1 OK' "OK=$okCount, всего=$(@($out).Count) [$($out -join ',')]" ($okCount -eq 1)

  # --- foreign progress: родитель A и чужой ученик B ---
  $r = Send-ParentApi @{ action = 'progress'; parent_id = $ParentA; student_id = $StudentB } $secret
  Add-Check '14 родитель A просит ЧУЖОГО ученика B' '403/forbidden' "$($r.Status)/$($r.Error)" ($r.Status -eq 403 -and $r.Error -eq 'forbidden')

  $r = Send-ParentApi @{ action = 'progress'; parent_id = $ParentA; student_id = 999999999999 } $secret
  Add-Check '15 подделанный student_id в progress' '403/forbidden' "$($r.Status)/$($r.Error)" ($r.Status -eq 403 -and $r.Error -eq 'forbidden')

  # --- свой ребёнок: данные и приватность ответа ---
  $r = Send-ParentApi @{ action = 'linked_students'; parent_id = $ParentA } $secret
  $listA = @($r.Data.students)
  $entryA = $listA | Where-Object { $_.student_id -eq $StudentA } | Select-Object -First 1
  $keysOk = $false
  if ($entryA) { $keysOk = (@($entryA.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'name,student_id' }
  Add-Check '16 linked_students' 'содержит ученика A, поля ровно student_id+name' "HTTP $($r.Status) count=$($listA.Count) keys=$(@($entryA.PSObject.Properties.Name) -join ',')" ($r.Status -eq 200 -and $entryA -and $keysOk)

  $r = Send-ParentApi @{ action = 'progress'; parent_id = $ParentA; student_id = $StudentA } $secret
  $report = $r.Data
  Add-Check '17 progress своего ребёнка' '200, есть name/progress' "HTTP $($r.Status) name=$($report.name) rows=$(@($report.progress).Count)" ($r.Status -eq 200 -and $report.name)

  $topKeys = @($report.PSObject.Properties.Name | Sort-Object) -join ','
  Add-Check '18 форма ответа progress' 'ровно name,progress,trajectory,week' $topKeys ($topKeys -eq 'name,progress,trajectory,week')

  $forbidden = @('huikons','balance','rating','reward_forecast','season_points','inventory',
                 'life_quest','life_quest_id','daily_quest','daily_quest_id','template_code',
                 'assignment_id','telegram_id','group_name','parent_telegram_id',
                 'token','token_hash','student_id')
  $leaks = @(Test-ForbiddenKey $report $forbidden | Sort-Object -Unique)
  Add-Check '19 privacy response' 'нет денег/инвентаря/life-quest/токенов/служебных ID' "leaks=[$($leaks -join ',')]" ($leaks.Count -eq 0)

  $points = @($report.trajectory.points)
  Add-Check '20 траектория пробников' 'минимум 2 точки (из подготовки)' "count=$($report.trajectory.count) points=$($points.Count)" ($points.Count -ge 2)

  $week = $report.week
  if ($week) {
    $weekKeysOk = ($week.PSObject.Properties.Name -contains 'n') -and ($week.PSObject.Properties.Name -contains 's')
    Add-Check '21 недельный блок (щиты)' 'есть n/a/s/e' "n=$($week.n) a=$($week.a) s=$($week.s) e=$($week.e)" $weekKeysOk
  } else {
    Add-Info '21 недельный блок (щиты)' 'week=null — по контракту /progress продолжает работать'
  }

  # --- ребёнок без данных ---
  $r = Send-ParentApi @{ action = 'link'; parent_id = $ParentB; token = "$TokenStudentB" } $secret
  Add-Check '22 link второго родителя к ученику B' '200, linked=true' "HTTP $($r.Status) linked=$($r.Data.linked)" ($r.Status -eq 200 -and $r.Data.linked -eq $true)

  $r = Send-ParentApi @{ action = 'progress'; parent_id = $ParentB; student_id = $StudentB } $secret
  Add-Check '23 ребёнок без заданий/пробников' '200, ответ не падает' "HTTP $($r.Status) rows=$(@($r.Data.progress).Count) points=$(@($r.Data.trajectory.points).Count)" ($r.Status -eq 200 -and $r.Data.name)

} finally { $secret = $null }

Write-Host ""
Write-Host "===== B2-T10B результаты =====" -ForegroundColor Cyan
$results | Format-List
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
if ($failed -eq 0) { Write-Host "ИТОГ: FAIL нет" -ForegroundColor Green }
else {
  Write-Host "ИТОГ: $failed FAIL" -ForegroundColor Red
  Write-Host ""
  Write-Host "===== Только FAIL =====" -ForegroundColor Red
  $results | Where-Object { $_.Result -eq 'FAIL' } | Format-List
}

Write-Host ""
Write-Host "===== ОЧИСТКА (Supabase SQL editor; секретов нет) =====" -ForegroundColor Cyan
Write-Host (Get-CleanupSql)
Write-Host ""
Write-Host "Не проверено этим скриптом (эксплуатационный smoke):" -ForegroundColor Yellow
Write-Host "  - выпуск токена учеником в Mini App (create_parent_invite_self под реальным student JWT);" -ForegroundColor Yellow
Write-Host "  - живые /start по ссылке и /progress в самом боте, доставка Telegram, график matplotlib;" -ForegroundColor Yellow
Write-Host "  - Supabase outage/restart (parent_bot.py: те же except-ветки и NETWORK_ERROR_TEXT)." -ForegroundColor Yellow

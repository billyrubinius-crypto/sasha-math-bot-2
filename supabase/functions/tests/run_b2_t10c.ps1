<#
  run_b2_t10c.ps1 — безопасная проверка sheets-sync-api (B2-T10C, T10-10C).
  Windows PowerShell 5.1. НЕ печатает SHEETS_SYNC_API_SECRET.

  ПОРЯДОК:
    1) SQL подготовки (скрипт печатает сам):     .\run_b2_t10c.ps1 -ShowPrepSql
    2) задеплоить sheets-sync-api и прогнать:    .\run_b2_t10c.ps1 -FunctionUrl "https://<ref>.functions.supabase.co/sheets-sync-api"
    3) SQL сверки результата (печатает сам):     .\run_b2_t10c.ps1 -ShowVerifySql
       (он сам выводит PASS/FAIL по каждой проверке — сравнивать глазами ничего не нужно)
    4) SQL очистки (печатает сам):               .\run_b2_t10c.ps1 -ShowCleanupSql

  Миграция для T10-10C НЕ нужна: on-conflict ключи (student_payments.student_id PK и
  mock_exam_results unique(student_id, exam_name)) уже есть в схеме.
#>
param(
  [string]$FunctionUrl,
  [switch]$ShowPrepSql,
  [switch]$ShowVerifySql,
  [switch]$ShowCleanupSql,
  [long]$StudentA = 995000030,
  [long]$StudentB = 995000031
)

$ErrorActionPreference = 'Stop'

$UserA = 'b2t10c_user_a'
$UserB = 'b2t10c_user_b'
$UserMissing = 'b2t10c_never_logged_in'

function Get-PrepSql {
  return @"
-- ПОДГОТОВКА B2-T10C (Supabase SQL editor). Миграция не требуется.
-- Два синтетических ученика с username; группа и платежи намеренно пустые — их проставит sync.
insert into public.students (telegram_id, name, telegram_username, group_name, huikons, rating)
values
  ($StudentA, 'B2-T10C ученик A', '$UserA', null, 0, 0),
  ($StudentB, 'B2-T10C ученик B', '$UserB', null, 0, 0)
on conflict (telegram_id) do nothing;

-- Пробник с уже заполненной датой: проверим, что пустая дата её НЕ затрёт.
insert into public.mock_exam_results (student_id, exam_name, score, exam_date)
values ($StudentA, 'B2-T10C пробник с датой', '55', date '2026-01-15')
on conflict (student_id, exam_name) do update set score = excluded.score, exam_date = excluded.exam_date;

-- контроль: должно вернуть 2
select count(*) from public.students where telegram_id in ($StudentA, $StudentB);
"@
}

function Get-VerifySql {
  return @"
-- СВЕРКА B2-T10C (Supabase SQL editor, после прогона скрипта).
-- Каждая строка сама печатает PASS или FAIL.
select 'V1 группа записана'            as check_name,
       case when (select group_name from public.students where telegram_id = $StudentA) = '10А'
            then 'PASS' else 'FAIL' end as result
union all
select 'V2 дата оплаты в student_payments',
       case when (select payment_date from public.student_payments where student_id = $StudentA) = date '2026-07-22'
            then 'PASS' else 'FAIL' end
union all
select 'V3 huikons НЕ изменён игровым полем в запросе',
       case when (select huikons from public.students where telegram_id = $StudentA) = 0
            then 'PASS' else 'FAIL' end
union all
select 'V4 rating НЕ изменён',
       case when (select rating from public.students where telegram_id = $StudentA) = 0
            then 'PASS' else 'FAIL' end
union all
select 'V5 пробник импортирован (строка есть, дата сохранена)',
       case when (select count(*) from public.mock_exam_results
                   where student_id = $StudentA and exam_name = 'B2-T10C пробник'
                     and exam_date = date '2026-07-01') = 1
            then 'PASS' else 'FAIL' end
union all
select 'V6 повтор пробника без дубля (ровно 1 строка)',
       case when (select count(*) from public.mock_exam_results
                   where student_id = $StudentA and exam_name = 'B2-T10C пробник') = 1
            then 'PASS' else 'FAIL' end
union all
select 'V7 повтор обновил балл (85)',
       case when (select score from public.mock_exam_results
                   where student_id = $StudentA and exam_name = 'B2-T10C пробник') = '85'
            then 'PASS' else 'FAIL' end
union all
select 'V8 пустая дата НЕ затёрла сохранённый exam_date',
       case when (select exam_date from public.mock_exam_results
                   where student_id = $StudentA and exam_name = 'B2-T10C пробник с датой') = date '2026-01-15'
            then 'PASS' else 'FAIL' end
union all
select 'V9 ученик B не тронут (группа пустая)',
       case when (select group_name from public.students where telegram_id = $StudentB) is null
            then 'PASS' else 'FAIL' end
union all
select 'V10 отклонённая строка не записалась (нет пробника с битой датой)',
       case when (select count(*) from public.mock_exam_results
                   where student_id = $StudentA and exam_name = 'B2-T10C битая дата') = 0
            then 'PASS' else 'FAIL' end;
"@
}

function Get-CleanupSql {
  return @"
-- ОЧИСТКА B2-T10C (Supabase SQL editor).
delete from public.mock_exam_results where student_id in ($StudentA, $StudentB);
delete from public.student_payments  where student_id in ($StudentA, $StudentB);
delete from public.students          where telegram_id in ($StudentA, $StudentB);

-- контроль: обе выборки должны вернуть 0
select count(*) from public.mock_exam_results where student_id in ($StudentA, $StudentB);
select count(*) from public.students          where telegram_id in ($StudentA, $StudentB);
"@
}

if ($ShowPrepSql)    { Get-PrepSql;    return }
if ($ShowVerifySql)  { Get-VerifySql;  return }
if ($ShowCleanupSql) { Get-CleanupSql; return }
if (-not $FunctionUrl) { throw "Укажите -FunctionUrl (или -ShowPrepSql / -ShowVerifySql / -ShowCleanupSql)." }

$secSecret = Read-Host -AsSecureString "Введите SHEETS_SYNC_API_SECRET (ввод скрыт)"
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

# ВАЖНО: тело отправляется БАЙТАМИ в UTF-8. PowerShell 5.1, получив -Body строкой без charset в
# ContentType, кодирует её как latin-1 — кириллица (группа «10А», названия пробников) уезжает
# искажённой и ложится в базу мусором. Apps Script (UrlFetchApp) шлёт UTF-8 сам, так что это
# ограничение только тестового харнесса, но проверка обязана слать ровно те же байты.
function Send-SheetsApi($BodyObj, [string]$Secret, [string]$Method = 'Post') {
  $headers = @{}
  if ($null -ne $Secret) { $headers['X-Sheets-Secret'] = $Secret }
  $body = $null
  if ($BodyObj -ne $null) { $body = [Text.Encoding]::UTF8.GetBytes(($BodyObj | ConvertTo-Json -Compress)) }
  try {
    $params = @{ Uri = $FunctionUrl; Method = $Method; UseBasicParsing = $true; Headers = $headers }
    if ($body) { $params['ContentType'] = 'application/json; charset=utf-8'; $params['Body'] = $body }
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

$secret = Get-PlainSecret $secSecret
try {

  # --- Секрет и контракт ---
  $r = Send-SheetsApi @{ action = 'student_lookup'; username = $UserA } $null
  Add-Check '01 missing secret' '401/unauthorized' "$($r.Status)/$($r.Error)" ($r.Status -eq 401 -and $r.Error -eq 'unauthorized')

  $r = Send-SheetsApi @{ action = 'student_lookup'; username = $UserA } 'obviously-wrong-secret-value'
  Add-Check '02 wrong secret' '401/unauthorized' "$($r.Status)/$($r.Error)" ($r.Status -eq 401 -and $r.Error -eq 'unauthorized')

  $r = Send-SheetsApi @{ action = 'delete_students' } $secret
  Add-Check '03 unknown action' '400/bad_request' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_request')

  $r = Send-SheetsApi $null $secret 'Get'
  Add-Check '04 GET method' '405/method_not_allowed' "$($r.Status)/$($r.Error)" ($r.Status -eq 405)

  # --- S01: поиск существующего ученика ---
  $r = Send-SheetsApi @{ action = 'student_lookup'; username = $UserA } $secret
  $idA = $r.Data.telegram_id
  Add-Check 'S01 lookup существующего username' "200, telegram_id=$StudentA" "HTTP $($r.Status) id=$idA" ($r.Status -eq 200 -and $idA -eq $StudentA)

  # регистр и @ не мешают (нормализация как в Apps Script)
  $r = Send-SheetsApi @{ action = 'student_lookup'; username = ('@' + $UserA.ToUpper()) } $secret
  Add-Check 'S02 lookup нечувствителен к @ и регистру' "200, telegram_id=$StudentA" "HTTP $($r.Status) id=$($r.Data.telegram_id)" ($r.Status -eq 200 -and $r.Data.telegram_id -eq $StudentA)

  # --- S03: «ученик ещё не входил» => null, ученик НЕ создаётся ---
  $r = Send-SheetsApi @{ action = 'student_lookup'; username = $UserMissing } $secret
  Add-Check 'S03 ученик ещё не входил' '200, telegram_id=null' "HTTP $($r.Status) id=$($r.Data.telegram_id)" ($r.Status -eq 200 -and $null -eq $r.Data.telegram_id)

  # --- S04: группа + дата оплаты; игровые поля в теле запроса игнорируются ---
  $r = Send-SheetsApi @{ action = 'student_sync'; telegram_id = $StudentA; group_name = '10А'; payment_date = '2026-07-22';
                         huikons = 999999; rating = 999999; approval_status = 'approved' } $secret
  Add-Check 'S04 student_sync + запрещённые игровые поля в теле' '200, ok=true (поля проигнорированы)' "HTTP $($r.Status) ok=$($r.Data.ok)" ($r.Status -eq 200 -and $r.Data.ok -eq $true)
  Add-Info 'S04a проверка последствий' 'huikons/rating сверяются SQL-блоком -ShowVerifySql (V3/V4)'

  # --- S05: импорт пробника + идемпотентный повтор ---
  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = 'B2-T10C пробник'; score = '78'; exam_date = '2026-07-01' } $secret
  Add-Check 'S05 импорт пробника' '200, ok=true' "HTTP $($r.Status) ok=$($r.Data.ok)" ($r.Status -eq 200 -and $r.Data.ok -eq $true)

  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = 'B2-T10C пробник'; score = '85'; exam_date = '2026-07-01' } $secret
  Add-Check '06 повтор sync того же пробника' '200 (обновление, без дубля)' "HTTP $($r.Status) ok=$($r.Data.ok)" ($r.Status -eq 200 -and $r.Data.ok -eq $true)

  # пустая дата не должна затирать сохранённую (проверка последствий — V8)
  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = 'B2-T10C пробник с датой'; score = '60' } $secret
  Add-Check '07 пробник без даты' '200, ok=true' "HTTP $($r.Status) ok=$($r.Data.ok)" ($r.Status -eq 200 -and $r.Data.ok -eq $true)

  # --- Невалидные данные помощника: понятный код поля, запись не происходит ---
  $r = Send-SheetsApi @{ action = 'student_sync'; telegram_id = $StudentA; group_name = ('Г' * 150); payment_date = $null } $secret
  Add-Check '08 invalid group' '400/bad_group' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_group')

  $r = Send-SheetsApi @{ action = 'student_sync'; telegram_id = $StudentA; group_name = '10А'; payment_date = '22.07.2026' } $secret
  Add-Check '09 invalid payment date' '400/bad_payment_date' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_payment_date')

  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = 'B2-T10C битая дата'; score = '70'; exam_date = '15.01.2026' } $secret
  Add-Check '10 invalid exam date' '400/bad_exam_date' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_exam_date')

  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = ''; score = '70' } $secret
  Add-Check '11 пустое имя пробника' '400/bad_exam_name' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_exam_name')

  $r = Send-SheetsApi @{ action = 'student_lookup'; username = 'иван петров' } $secret
  Add-Check '12 мусорный username' '400/bad_username' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_username')

  # --- partial failure: битая строка не мешает следующей ---
  $bad = Send-SheetsApi @{ action = 'student_sync'; telegram_id = $StudentB; group_name = '10Б'; payment_date = 'вчера' } $secret
  $good = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentB; exam_name = 'B2-T10C после сбоя'; score = '50' } $secret
  Add-Check '13 partial failure: следующая строка проходит' 'битая 400, следующая 200' "bad=$($bad.Status)/$($bad.Error), next=$($good.Status)" ($bad.Status -eq 400 -and $good.Status -eq 200)

  # --- helper-readable error: код ошибки распознаётся словарём Apps Script ---
  $knownCodes = @('unauthorized','rate_limited','bad_username','bad_telegram_id','bad_group',
                  'bad_payment_date','bad_exam_name','bad_score','bad_exam_date','bad_request',
                  'server_misconfigured','db_error')
  $r = Send-SheetsApi @{ action = 'student_sync'; telegram_id = $StudentA; group_name = '10А'; payment_date = 'вчера' } $secret
  Add-Check '14 helper-readable error code' 'код из словаря Code.gs' "$($r.Error)" ($knownCodes -contains $r.Error)

  # --- dev/prod separation ---
  $isDev = $FunctionUrl -like '*ewwmsoecabfdldccrjfc*'
  Add-Check '15 dev/prod separation' 'URL указывает на dev-проект Bot 2.0' "url dev=$isDev" $isDev

  # --- нет произвольного Data API: чужие действия недоступны ---
  foreach ($a in @('students_select','add_huikons','sql','rpc')) {
    $r = Send-SheetsApi @{ action = $a } $secret
    Add-Check "16 запрещённое действие '$a'" '400/bad_request' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_request')
  }

} finally { $secret = $null }

Write-Host ""
Write-Host "===== B2-T10C результаты =====" -ForegroundColor Cyan
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
Write-Host "СЛЕДУЮЩИЙ ШАГ: выполнить SQL-сверку последствий (сам печатает PASS/FAIL):" -ForegroundColor Cyan
Write-Host "  .\run_b2_t10c.ps1 -ShowVerifySql" -ForegroundColor Cyan
Write-Host "Затем очистка:  .\run_b2_t10c.ps1 -ShowCleanupSql" -ForegroundColor Cyan
Write-Host ""
Write-Host "Не проверено этим скриптом (эксплуатационный smoke в самой таблице):" -ForegroundColor Yellow
Write-Host "  - статусы 🟢/🟡/🔴 в листе «Ученики» и пересборка листов групп;" -ForegroundColor Yellow
Write-Host "  - триггеры Apps Script (расписание/onEdit) и лимит выполнения;" -ForegroundColor Yellow
Write-Host "  - что в Script Properties dev-таблицы НЕТ service-role ключа." -ForegroundColor Yellow

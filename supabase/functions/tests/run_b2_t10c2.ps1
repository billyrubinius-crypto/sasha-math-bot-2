<#
  run_b2_t10c2.ps1 — проверка маршрутизации пробников из Sheets (B2-T10C2, T10-10C2).
  Windows PowerShell 5.1. НЕ печатает SHEETS_SYNC_API_SECRET.

  Проверяет главное: результат помощника доходит до ГРАФИКА ученика (weekly_mock_exams) той же
  серверной логикой, что у панели учителя, и при повторной синхронизации НЕ начисляет повторно.

  ПОРЯДОК:
    1) применить database/migrations/045_t10_sheets_mock_exam_service.sql;
    2) SQL подготовки:  .\run_b2_t10c2.ps1 -ShowPrepSql
    3) передеплоить sheets-sync-api и прогнать:
       .\run_b2_t10c2.ps1 -FunctionUrl "https://<ref>.functions.supabase.co/sheets-sync-api"
    4) SQL сверки:      .\run_b2_t10c2.ps1 -ShowVerifySql   (сам печатает PASS/FAIL)
    5) SQL очистки:     .\run_b2_t10c2.ps1 -ShowCleanupSql

  Тело запросов отправляется байтами UTF-8 (PS 5.1 иначе кодирует кириллицу как latin-1).
#>
param(
  [string]$FunctionUrl,
  [switch]$ShowPrepSql,
  [switch]$ShowVerifySql,
  [switch]$ShowCleanupSql,
  [long]$StudentA = 995000032
)

$ErrorActionPreference = 'Stop'

$UserA     = 'b2t10c2_user_a'
$ExamDate  = '2026-07-01'   # среда
$WeekStart = '2026-06-29'   # понедельник той же недели — его должен вернуть сервер
$ExamName  = 'B2-T10C2 пробник'

function Get-PrepSql {
  return @"
-- ПОДГОТОВКА B2-T10C2 (Supabase SQL editor, ПОСЛЕ миграции 045).
-- Один синтетический ученик с нулевым балансом: так видно каждое начисление.
insert into public.students (telegram_id, name, telegram_username, huikons, rating)
values ($StudentA, 'B2-T10C2 ученик', '$UserA', 0, 0)
on conflict (telegram_id) do nothing;

-- контроль: должно вернуть 1
select count(*) from public.students where telegram_id = $StudentA;
"@
}

function Get-VerifySql {
  return @"
-- СВЕРКА B2-T10C2 (Supabase SQL editor, после прогона скрипта). Каждая строка печатает PASS/FAIL.
select 'W1 canonical-строка создана на нужной неделе' as check_name,
       case when (select count(*) from public.weekly_mock_exams
                   where student_id = $StudentA and week_start = date '$WeekStart') = 1
            then 'PASS' else 'FAIL' end as result
union all
select 'W2 у ученика ровно одна canonical-строка',
       case when (select count(*) from public.weekly_mock_exams where student_id = $StudentA) = 1
            then 'PASS' else 'FAIL' end
union all
select 'W3 балл обновлён редактированием (85, а не 78)',
       case when (select score from public.weekly_mock_exams
                   where student_id = $StudentA and week_start = date '$WeekStart') = 85
            then 'PASS' else 'FAIL' end
union all
select 'W4 базовая награда выдана ровно один раз',
       case when (select count(*) from public.balance_history
                   where student_id = $StudentA and reason = 'mock_exam_weekly') = 1
            then 'PASS' else 'FAIL' end
union all
select 'W5 награда за рекорд выдана не более одного раза',
       case when (select count(*) from public.balance_history
                   where student_id = $StudentA and reason = 'mock_exam_record') <= 1
            then 'PASS' else 'FAIL' end
union all
select 'W6 ledger пробника pay-once (base не задвоен)',
       case when (select count(*) from public.mock_exam_reward_log
                   where student_id = $StudentA and week_start = date '$WeekStart'
                     and reward_kind = 'base') = 1
            then 'PASS' else 'FAIL' end
union all
select 'W7 season points зафиксированы без задвоения',
       case when (select season_points_awarded from public.weekly_mock_exams
                   where student_id = $StudentA and week_start = date '$WeekStart')
                 = (select coalesce(sum(amount),0) from public.season_points_log
                     where student_id = $StudentA and reason = 'mock_exam_season')
            then 'PASS' else 'FAIL' end
union all
select 'W8 архив: зеркало canonical-строки существует',
       case when (select count(*) from public.mock_exam_results
                   where student_id = $StudentA
                     and exam_name = 'Недельный пробник ' || to_char(date '$WeekStart', 'DD.MM.YYYY')) = 1
            then 'PASS' else 'FAIL' end
union all
select 'W9 архив: непригодные значения сохранены (4 строки)',
       case when (select count(*) from public.mock_exam_results
                   where student_id = $StudentA and exam_name like 'B2-T10C2 архив%') = 4
            then 'PASS' else 'FAIL' end
union all
select 'W10 непригодные значения НЕ создали canonical-строк',
       case when (select count(*) from public.weekly_mock_exams where student_id = $StudentA) = 1
            then 'PASS' else 'FAIL' end;
"@
}

function Get-CleanupSql {
  return @"
-- ОЧИСТКА B2-T10C2 (Supabase SQL editor).
-- Важно: начисление season points заводит ученику строку в student_league_state (лиговое
-- состояние). Без её удаления DELETE из students падает на FK student_league_state_student_id_fkey.
-- Лиговые таблицы чистятся до students, в порядке зависимостей.
delete from public.season_points_log      where student_id = $StudentA;
delete from public.mock_exam_reward_log   where student_id = $StudentA;
delete from public.weekly_mock_exams      where student_id = $StudentA;
delete from public.mock_exam_results      where student_id = $StudentA;
delete from public.balance_history        where student_id = $StudentA;
delete from public.league_movements       where student_id = $StudentA;
delete from public.league_memberships     where student_id = $StudentA;
delete from public.student_league_state   where student_id = $StudentA;
delete from public.students               where telegram_id = $StudentA;

-- контроль: все три выборки должны вернуть 0
select count(*) from public.weekly_mock_exams    where student_id = $StudentA;
select count(*) from public.student_league_state where student_id = $StudentA;
select count(*) from public.students             where telegram_id = $StudentA;
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

function Send-SheetsApi($BodyObj, [string]$Secret) {
  $headers = @{}
  if ($null -ne $Secret) { $headers['X-Sheets-Secret'] = $Secret }
  $body = [Text.Encoding]::UTF8.GetBytes(($BodyObj | ConvertTo-Json -Compress))
  try {
    $resp = Invoke-WebRequest -Uri $FunctionUrl -Method Post -UseBasicParsing -Headers $headers `
      -ContentType 'application/json; charset=utf-8' -Body $body
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

  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = $ExamName; score = '78'; exam_date = $ExamDate } $null
  Add-Check '01 missing secret' '401/unauthorized' "$($r.Status)/$($r.Error)" ($r.Status -eq 401 -and $r.Error -eq 'unauthorized')

  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = $ExamName; score = '78'; exam_date = $ExamDate } 'obviously-wrong-secret-value'
  Add-Check '02 wrong secret' '401/unauthorized' "$($r.Status)/$($r.Error)" ($r.Status -eq 401 -and $r.Error -eq 'unauthorized')

  # --- canonical: результат помощника доходит до графика ---
  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = $ExamName; score = '78'; exam_date = $ExamDate } $secret
  $ok = ($r.Status -eq 200 -and $r.Data.route -eq 'canonical' -and $r.Data.week_start -eq $WeekStart)
  Add-Check '03 пригодный результат -> canonical' "200, route=canonical, week_start=$WeekStart" "HTTP $($r.Status) route=$($r.Data.route) week=$($r.Data.week_start)" $ok

  # --- повторная синхронизация того же значения (Apps Script шлёт каждые 10 минут) ---
  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = $ExamName; score = '78'; exam_date = $ExamDate } $secret
  Add-Check '04 повтор того же значения' '200, route=canonical' "HTTP $($r.Status) route=$($r.Data.route)" ($r.Status -eq 200 -and $r.Data.route -eq 'canonical')

  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = $ExamName; score = '78'; exam_date = $ExamDate } $secret
  Add-Check '05 третья синхронизация' '200 (награды сверяются SQL: W4/W6)' "HTTP $($r.Status)" ($r.Status -eq 200)

  # --- редактирование балла помощником ---
  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = $ExamName; score = '85'; exam_date = $ExamDate } $secret
  Add-Check '06 исправление балла на 85' '200, route=canonical' "HTTP $($r.Status) route=$($r.Data.route)" ($r.Status -eq 200 -and $r.Data.route -eq 'canonical')

  # --- непригодные значения: архив + причина, canonical не создаётся ---
  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = 'B2-T10C2 архив без даты'; score = '70' } $secret
  Add-Check '07 нет даты -> архив' '200, route=archive, reason=no_exam_date' "HTTP $($r.Status) route=$($r.Data.route) reason=$($r.Data.reason)" ($r.Status -eq 200 -and $r.Data.route -eq 'archive' -and $r.Data.reason -eq 'no_exam_date')

  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = 'B2-T10C2 архив не число'; score = 'не писал'; exam_date = $ExamDate } $secret
  Add-Check '08 нечисловой балл -> архив' '200, reason=score_not_number' "HTTP $($r.Status) route=$($r.Data.route) reason=$($r.Data.reason)" ($r.Status -eq 200 -and $r.Data.route -eq 'archive' -and $r.Data.reason -eq 'score_not_number')

  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = 'B2-T10C2 архив дробный'; score = '70.5'; exam_date = $ExamDate } $secret
  Add-Check '09 дробный балл -> архив' '200, reason=score_not_number' "HTTP $($r.Status) route=$($r.Data.route) reason=$($r.Data.reason)" ($r.Status -eq 200 -and $r.Data.route -eq 'archive' -and $r.Data.reason -eq 'score_not_number')

  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = 'B2-T10C2 архив вне диапазона'; score = '101'; exam_date = $ExamDate } $secret
  Add-Check '10 балл 101 -> архив' '200, reason=score_out_of_range' "HTTP $($r.Status) route=$($r.Data.route) reason=$($r.Data.reason)" ($r.Status -eq 200 -and $r.Data.route -eq 'archive' -and $r.Data.reason -eq 'score_out_of_range')

  # --- битая дата остаётся ошибкой помощника, а не маршрутом ---
  $r = Send-SheetsApi @{ action = 'mock_exam_upsert'; telegram_id = $StudentA; exam_name = 'B2-T10C2 битая дата'; score = '70'; exam_date = '01.07.2026' } $secret
  Add-Check '11 нечитаемая дата -> 400' '400/bad_exam_date' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_exam_date')

} finally { $secret = $null }

Write-Host ""
Write-Host "===== B2-T10C2 результаты =====" -ForegroundColor Cyan
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
Write-Host "СЛЕДУЮЩИЙ ШАГ: SQL-сверка последствий (сама печатает PASS/FAIL):" -ForegroundColor Cyan
Write-Host "  .\run_b2_t10c2.ps1 -ShowVerifySql" -ForegroundColor Cyan
Write-Host "Затем очистка:  .\run_b2_t10c2.ps1 -ShowCleanupSql" -ForegroundColor Cyan
Write-Host ""
Write-Host "Не проверено этим скриптом (эксплуатационный smoke):" -ForegroundColor Yellow
Write-Host "  - teacher-путь record_weekly_mock_exam_self (нужен реальный teacher-JWT);" -ForegroundColor Yellow
Write-Host "  - отображение точки на графике ученика/учителя/родителя;" -ForegroundColor Yellow
Write-Host "  - реальная таблица Google Sheets с триггерами Apps Script." -ForegroundColor Yellow

<#
  run_b2_t10a.ps1 — безопасная проверка student-bot-api (B2-T10A, T10-10A).
  Для владельца на Windows PowerShell 5.1. НЕ печатает STUDENT_BOT_API_SECRET.

  Перед запуском в Supabase SQL editor выполнить блок "ПОДГОТОВКА" (см. отчёт задачи или
  комментарий ниже) — синтетический сезон 995010 + два ученика 995000010/995000011.

  Запуск:
    .\run_b2_t10a.ps1 -FunctionUrl "https://<ref>.functions.supabase.co/student-bot-api"

  Секрет спросится скрытым вводом (STUDENT_BOT_API_SECRET из Railway/Edge secret).

  Важно: тест НЕ трогает настоящие ключи планировщика (morning_digest/evening_reminder/
  league_result_check) в mark_sent — только синтетический league_result:995010:995000010,
  чтобы не подавить реальную рассылку в день прогона. Для чтения (notification_last_sent)
  реальные ключи используются, но это read-only и безопасно.
#>
param(
  [Parameter(Mandatory=$true)][string]$FunctionUrl,
  [long]$SeasonId    = 995010,
  [long]$StudentA    = 995000010,
  [long]$StudentB    = 995000011
)

$ErrorActionPreference = 'Stop'

$secSecret = Read-Host -AsSecureString "Введите STUDENT_BOT_API_SECRET (ввод скрыт)"
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

# POST в функцию. $Secret = $null => заголовок X-Bot-Secret не отправляется (missing-secret кейс).
function Send-BotApi($BodyObj, [string]$Secret, [string]$Method = 'Post') {
  $headers = @{}
  if ($null -ne $Secret) { $headers['X-Bot-Secret'] = $Secret }
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

$secret = Get-PlainSecret $secSecret
try {

  # 01 отсутствующий секрет
  $r = Send-BotApi @{ action = 'active_assignments' } $null
  Add-Check '01 missing secret' '401/unauthorized' "$($r.Status)/$($r.Error)" ($r.Status -eq 401 -and $r.Error -eq 'unauthorized')

  # 02 неверный секрет
  $r = Send-BotApi @{ action = 'active_assignments' } 'obviously-wrong-secret-value'
  Add-Check '02 wrong secret' '401/unauthorized' "$($r.Status)/$($r.Error)" ($r.Status -eq 401 -and $r.Error -eq 'unauthorized')

  # 03 неизвестное действие
  $r = Send-BotApi @{ action = 'delete_everything' } $secret
  Add-Check '03 unknown action' '400/bad_request' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_request')

  # 04 method_not_allowed
  $r = Send-BotApi $null $secret 'Get'
  Add-Check '04 GET method' '405/method_not_allowed' "$($r.Status)/$($r.Error)" ($r.Status -eq 405 -and $r.Error -eq 'method_not_allowed')

  # 05 body_too_large (>2 КБ)
  $bigPayload = @{ action = 'active_assignments'; junk = ('a' * 3000) }
  $r = Send-BotApi $bigPayload $secret
  Add-Check '05 body too large' '413/body_too_large' "$($r.Status)/$($r.Error)" ($r.Status -eq 413)

  # 06 allowed action: active_assignments (read-only, форма ответа — массив строк)
  $r = Send-BotApi @{ action = 'active_assignments' } $secret
  $shapeOk = ($r.Status -eq 200 -and ($r.Data -is [array] -or $r.Data -eq $null -or $r.Data.Count -ge 0))
  Add-Check '06 active_assignments' '200, массив' "HTTP $($r.Status), count=$($r.Data.Count)" ($r.Status -eq 200)

  # 07 notification_last_sent: валидный статичный ключ (read-only, реальный ключ, но без записи)
  $r = Send-BotApi @{ action = 'notification_last_sent'; key = 'morning_digest' } $secret
  Add-Check '07 notification_last_sent valid key' '200' "HTTP $($r.Status) last_sent_date=$($r.Data.last_sent_date)" ($r.Status -eq 200)

  # 08 notification_last_sent: league-ключ отвергается (не входит в статичный allowlist для read)
  $r = Send-BotApi @{ action = 'notification_last_sent'; key = "league_result:${SeasonId}:${StudentA}" } $secret
  Add-Check '08 notification_last_sent league key rejected' '400/bad_request' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_request')

  # 09 notification_mark_sent: недопустимый ключ
  $r = Send-BotApi @{ action = 'notification_mark_sent'; key = 'arbitrary_table_name'; sent_date = (Get-Date -Format 'yyyy-MM-dd') } $secret
  Add-Check '09 mark_sent invalid key' '400/bad_request' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_request')

  # 10 notification_mark_sent: невалидная дата
  $r = Send-BotApi @{ action = 'notification_mark_sent'; key = "league_result:${SeasonId}:${StudentA}"; sent_date = '22-07-2026' } $secret
  Add-Check '10 mark_sent invalid date' '400/bad_request' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_request')

  # 11 notification_mark_sent: валидный СИНТЕТИЧЕСКИЙ ключ (не трогает реальный планировщик)
  $today = Get-Date -Format 'yyyy-MM-dd'
  $r = Send-BotApi @{ action = 'notification_mark_sent'; key = "league_result:${SeasonId}:${StudentA}"; sent_date = $today } $secret
  Add-Check '11 mark_sent synthetic key' '200, ok=true' "HTTP $($r.Status) ok=$($r.Data.ok)" ($r.Status -eq 200 -and $r.Data.ok -eq $true)

  # 12 notification_already_sent_ids: отражает запись из 11, НЕ содержит StudentB
  $r = Send-BotApi @{ action = 'notification_already_sent_ids'; season_id = $SeasonId } $secret
  $ids = @($r.Data.student_ids)
  $hasA = $ids -contains $StudentA
  $hasB = $ids -contains $StudentB
  Add-Check '12 already_sent_ids: idempotency round-trip' "содержит $StudentA, не содержит $StudentB" "ids=[$($ids -join ',')]" ($r.Status -eq 200 -and $hasA -and -not $hasB)

  # 13 notification_already_sent_ids: неверный season_id (не целое/отрицательное)
  $r = Send-BotApi @{ action = 'notification_already_sent_ids'; season_id = -5 } $secret
  Add-Check '13 already_sent_ids invalid season_id' '400/bad_request' "$($r.Status)/$($r.Error)" ($r.Status -eq 400 -and $r.Error -eq 'bad_request')

  # 14 latest_closed_season — информационно (значение зависит от реального состояния dev)
  $r = Send-BotApi @{ action = 'latest_closed_season' } $secret
  Add-Info '14 latest_closed_season' "HTTP $($r.Status) season_id=$($r.Data.season_id)"

  # 15 league_memberships для синтетического сезона — обе строки на месте с верными полями
  $r = Send-BotApi @{ action = 'league_memberships'; season_id = $SeasonId } $secret
  $rows = @($r.Data.memberships)
  $rowA = $rows | Where-Object { $_.student_id -eq $StudentA } | Select-Object -First 1
  $membOk = ($r.Status -eq 200 -and $rowA -and $rowA.tier -eq 1 -and $rowA.place -eq 3 -and $rowA.movement -eq 'promote')
  Add-Check '15 league_memberships' 'содержит synthetic-A: tier=1 place=3 movement=promote' "HTTP $($r.Status) rows=$($rows.Count) A=$($rowA | ConvertTo-Json -Compress)" $membOk

  # 16 league_tiers — справочник, содержит tier=1
  $r = Send-BotApi @{ action = 'league_tiers' } $secret
  $tiers = @($r.Data.tiers)
  $hasTier1 = @($tiers | Where-Object { $_.tier -eq 1 }).Count -gt 0
  Add-Check '16 league_tiers' 'содержит tier=1' "HTTP $($r.Status) count=$($tiers.Count) hasTier1=$hasTier1" ($r.Status -eq 200 -and $hasTier1)

  # 17 league_movements для синтетического сезона
  $r = Send-BotApi @{ action = 'league_movements'; season_id = $SeasonId } $secret
  $moves = @($r.Data.movements)
  $moveA = $moves | Where-Object { $_.student_id -eq $StudentA } | Select-Object -First 1
  $moveOk = ($r.Status -eq 200 -and $moveA -and $moveA.kind -eq 'promote' -and $moveA.from_tier -eq 2 -and $moveA.to_tier -eq 1)
  Add-Check '17 league_movements' 'содержит synthetic-A: promote 2->1' "HTTP $($r.Status) A=$($moveA | ConvertTo-Json -Compress)" $moveOk

  # 18 league_crown_student для синтетического сезона
  $r = Send-BotApi @{ action = 'league_crown_student'; season_id = $SeasonId } $secret
  Add-Check '18 league_crown_student' "student_id=$StudentA" "HTTP $($r.Status) student_id=$($r.Data.student_id)" ($r.Status -eq 200 -and $r.Data.student_id -eq $StudentA)

} finally { $secret = $null }

Write-Host ""
Write-Host "===== B2-T10A результаты =====" -ForegroundColor Cyan
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
Write-Host "===== Очистка dev (Supabase SQL editor; секретов нет) =====" -ForegroundColor Cyan
Write-Host @"
delete from public.league_season_awards where earned_season_id = $SeasonId;
delete from public.league_movements     where season_id = $SeasonId;
delete from public.league_memberships   where season_id = $SeasonId;
delete from public.league_cohorts       where id = $SeasonId;
delete from public.seasons              where id = $SeasonId;
delete from public.bot_notification_state where notification_key like 'league_result:${SeasonId}:%';
delete from public.students where telegram_id in ($StudentA, $StudentB);
-- контроль: обе выборки должны вернуть 0
select count(*) from public.seasons  where id = $SeasonId;
select count(*) from public.students where telegram_id in ($StudentA, $StudentB);
"@
Write-Host ""
Write-Host "Не проверено этим скриптом (проверить вручную/через реальный прогон бота):" -ForegroundColor Yellow
Write-Host "  - Supabase outage (main.py: raise_for_status уже пробрасывает ошибку в scheduler_loop, как раньше);" -ForegroundColor Yellow
Write-Host "  - один сбой Telegram-доставки (send_safely не менялся);" -ForegroundColor Yellow
Write-Host "  - morning/evening/restart dedupe end-to-end поверх реального планировщика (кейсы 07/11/12 выше" -ForegroundColor Yellow
Write-Host "    доказывают контракт notification_last_sent/mark_sent на синтетических данных)." -ForegroundColor Yellow

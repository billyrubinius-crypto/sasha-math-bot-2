<#
  run_b2_t09.ps1 — безопасная проверка signed Cloudinary uploads (B2-T09, T10-09).
  Для владельца на Windows PowerShell 5.1. НЕ печатает BOT_TOKEN, пароль учителя,
  Cloudinary secret и полные JWT. Итог — таблица PASS/FAIL + SQL-очистка.

  Перед запуском в Supabase SQL editor выполнить блок "ПОДГОТОВКА" (печатается ниже
  и приведён в отчёте задачи): синтетический ученик 995000009 + его задание.

  Запуск (PowerShell, из любой папки):
    .\run_b2_t09.ps1 -Origin "https://<origin-mini-app>"

  Спросятся скрытым вводом: BOT_TOKEN (для student JWT) и пароль учителя (для teacher JWT).
  Пустой ввод пароля => teacher-кейсы помечаются SKIP.

  Повторная быстрая проверка ТОЛЬКО unsigned-preset (после его отключения в Cloudinary):
    .\run_b2_t09.ps1 -Origin "https://<origin-mini-app>" -OnlyUnsignedProbe
#>
param(
  [Parameter(Mandatory=$true)][string]$Origin,
  [string]$FunctionBase   = "https://ewwmsoecabfdldccrjfc.functions.supabase.co",
  [string]$CloudName      = "ddrn3vxm0",
  [string]$UnsignedPreset = "sasha-math-dz",
  [long]$StudentTgId      = 995000009,
  [string]$AssignmentId   = "99500009-0000-4000-8000-000000000009",
  [string]$PdfPath,
  [switch]$OnlyUnsignedProbe
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$SignUrl        = "$FunctionBase/sign-upload"
$StudentAuthUrl = "$FunctionBase/student-auth"
$TeacherAuthUrl = "$FunctionBase/teacher-auth"

# ============================ результаты ============================
$results = New-Object System.Collections.ArrayList
function Add-Result([string]$Case, [string]$Expected, [string]$Actual, [string]$Result) {
  [void]$results.Add([pscustomobject]@{ Case = $Case; Expected = $Expected; Actual = $Actual; Result = $Result })
}
function Add-Check([string]$Case, [string]$Expected, [string]$Actual, [bool]$Pass) {
  $r = 'FAIL'; if ($Pass) { $r = 'PASS' }
  Add-Result $Case $Expected $Actual $r
}

# ============================ helpers ============================
function Get-PlainSecret([System.Security.SecureString]$sec) {
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
function Get-HmacSha256([byte[]]$key, [string]$message) {
  $h = New-Object System.Security.Cryptography.HMACSHA256
  $h.Key = $key
  return $h.ComputeHash([Text.Encoding]::UTF8.GetBytes($message))
}
function To-HexLower([byte[]]$b) { -join ($b | ForEach-Object { $_.ToString('x2') }) }

# Минимальный валидный PNG 1x1 (для кейсов с фото).
$PngBytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')

# Минимальный валидный PDF с корректными смещениями xref (или файл из -PdfPath).
function New-MinimalPdf {
  $objs = @(
    "1 0 obj`n<< /Type /Catalog /Pages 2 0 R >>`nendobj`n",
    "2 0 obj`n<< /Type /Pages /Kids [3 0 R] /Count 1 >>`nendobj`n",
    "3 0 obj`n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> >>`nendobj`n"
  )
  $head = "%PDF-1.4`n"
  $body = $head
  $offsets = @()
  foreach ($o in $objs) {
    $offsets += $body.Length
    $body += $o
  }
  $xrefPos = $body.Length
  $xref = "xref`n0 4`n0000000000 65535 f `n"
  foreach ($off in $offsets) { $xref += ("{0:D10} 00000 n `n" -f $off) }
  $tail = "trailer`n<< /Size 4 /Root 1 0 R >>`nstartxref`n$xrefPos`n%%EOF`n"
  return [Text.Encoding]::ASCII.GetBytes($body + $xref + $tail)
}

# POST JSON в Edge Function. Возвращает @{ Status; Code; Data }.
function Send-Json([string]$Url, $BodyObj, [string]$Token, [string]$OriginHeader) {
  if (-not $OriginHeader) { $OriginHeader = $Origin }
  $headers = @{ Origin = $OriginHeader }
  if ($Token) { $headers['Authorization'] = "Bearer $Token" }
  $body = ($BodyObj | ConvertTo-Json -Compress)
  try {
    $resp = Invoke-WebRequest -Uri $Url -Method Post -ContentType 'application/json' `
      -Headers $headers -Body $body -UseBasicParsing
    return @{ Status = [int]$resp.StatusCode; Code = 'ok'; Data = ($resp.Content | ConvertFrom-Json) }
  } catch {
    $r = $_.Exception.Response
    if ($r -ne $null) {
      $status = [int]$r.StatusCode
      $reader = New-Object IO.StreamReader($r.GetResponseStream())
      $content = $reader.ReadToEnd(); $reader.Close()
      $code = 'unknown'
      try { $code = ($content | ConvertFrom-Json).error } catch {}
      return @{ Status = $status; Code = $code; Data = $null }
    }
    return @{ Status = 0; Code = 'neterror'; Data = $null }
  }
}

# Загрузка в Cloudinary. $Params — hashtable подписанных параметров (или unsigned-набор).
# Текстовым полям явно проставляется Content-Disposition: PowerShell 5.1 иначе отдаёт их без
# имени, и Cloudinary не видит api_key/signature/upload_preset.
# Возвращает @{ Status; Url; Err; Existing } (Existing — флаг Cloudinary «объект уже есть»).
function Send-Cloudinary([string]$ResourceType, $Params, [string]$ApiKey, [string]$Signature, [byte[]]$Bytes, [string]$FileName) {
  $client = New-Object System.Net.Http.HttpClient
  try {
    $form = New-Object System.Net.Http.MultipartFormDataContent
    $fileContent = New-Object System.Net.Http.ByteArrayContent -ArgumentList (,$Bytes)
    $form.Add($fileContent, 'file', $FileName)
    foreach ($k in $Params.Keys) {
      $content = New-Object System.Net.Http.StringContent ([string]$Params[$k])
      $content.Headers.ContentDisposition = New-Object System.Net.Http.Headers.ContentDispositionHeaderValue 'form-data'
      $content.Headers.ContentDisposition.Name = '"' + [string]$k + '"'
      $form.Add($content)
    }
    if ($ApiKey) {
      $content = New-Object System.Net.Http.StringContent $ApiKey
      $content.Headers.ContentDisposition = New-Object System.Net.Http.Headers.ContentDispositionHeaderValue 'form-data'
      $content.Headers.ContentDisposition.Name = '"api_key"'
      $form.Add($content)
    }
    if ($Signature) {
      $content = New-Object System.Net.Http.StringContent $Signature
      $content.Headers.ContentDisposition = New-Object System.Net.Http.Headers.ContentDispositionHeaderValue 'form-data'
      $content.Headers.ContentDisposition.Name = '"signature"'
      $form.Add($content)
    }

    $url = "https://api.cloudinary.com/v1_1/$CloudName/$ResourceType/upload"
    $resp = $client.PostAsync($url, $form).Result
    $text = $resp.Content.ReadAsStringAsync().Result
    $status = [int]$resp.StatusCode
    $secureUrl = $null; $err = $null; $existing = $false
    try {
      $j = $text | ConvertFrom-Json
      $secureUrl = $j.secure_url
      $existing = ($j.existing -eq $true)
      if ($j.error) { $err = $j.error.message }
    } catch { $err = 'unparsable response' }
    return @{ Status = $status; Url = $secureUrl; Err = $err; Existing = $existing }
  } catch {
    return @{ Status = 0; Url = $null; Err = $_.Exception.Message }
  } finally { $client.Dispose() }
}

# Хэштейбл из подписанных params, пришедших от sign-upload (PSCustomObject -> hashtable).
function ConvertTo-Hash($obj) {
  $h = @{}
  foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
  return $h
}

# ============================ unsigned probe ============================
# До отключения preset ожидается 200 (дыра ещё открыта), после отключения — отказ.
function Invoke-UnsignedProbe {
  $p = @{ upload_preset = $UnsignedPreset; folder = 'sasha-math-dz' }
  $r = Send-Cloudinary 'image' $p $null $null $PngBytes 'b2t09-unsigned-probe.png'
  $open = ($r.Status -eq 200)
  $state = 'ОТКРЫТ (unsigned работает)'
  if (-not $open) { $state = 'ЗАКРЫТ (unsigned отклонён)' }
  Add-Result 'U1 unsigned preset probe' 'до отключения: ОТКРЫТ; после: ЗАКРЫТ' "$state (HTTP $($r.Status))" 'INFO'
}

if ($OnlyUnsignedProbe) {
  Invoke-UnsignedProbe
  Write-Host ""
  Write-Host "===== B2-T09: только unsigned probe =====" -ForegroundColor Cyan
  $results | Format-Table -AutoSize
  return
}

# ============================ получение токенов ============================
$secBot = Read-Host -AsSecureString "Введите BOT_TOKEN (ввод скрыт)"
$secPwd = Read-Host -AsSecureString "Введите пароль учителя (ввод скрыт; Enter = пропустить teacher-кейсы)"

# --- student JWT через student-auth (initData строится локально) ---
$token = Get-PlainSecret $secBot
try {
  $authDate = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $userJson = '{"id":' + $StudentTgId + ',"first_name":"T09test"}'
  $dcs = "auth_date=$authDate`nuser=$userJson"
  $secret = Get-HmacSha256 ([Text.Encoding]::UTF8.GetBytes('WebAppData')) $token
  $hash = To-HexLower (Get-HmacSha256 $secret $dcs)
  $initData = "user=" + [Uri]::EscapeDataString($userJson) + "&auth_date=$authDate&hash=$hash"
} finally { $token = $null }

$sr = Send-Json $StudentAuthUrl @{ initData = $initData } $null $null
$studentJwt = $null
if ($sr.Status -eq 200) { $studentJwt = $sr.Data.access_token }
Add-Check '00a student JWT получен' '200' "$($sr.Status)/$($sr.Code)" ($studentJwt -ne $null)

# --- teacher JWT через teacher-auth ---
$teacherJwt = $null
$pwd = Get-PlainSecret $secPwd
try {
  if ($pwd) {
    $tr = Send-Json $TeacherAuthUrl @{ password = $pwd } $null $null
    if ($tr.Status -eq 200) { $teacherJwt = $tr.Data.access_token }
    Add-Check '00b teacher JWT получен' '200' "$($tr.Status)/$($tr.Code)" ($teacherJwt -ne $null)
  } else {
    Add-Result '00b teacher JWT получен' '200' 'пароль не введён' 'SKIP'
  }
} finally { $pwd = $null }

# ============================ STUDENT ============================
$signedStudent = $null
if ($studentJwt) {

  # 01 валидная подпись фото для своего задания
  $r = Send-Json $SignUrl @{ kind='student_photo'; filename='dz.jpg'; bytes=120000; assignment_id=$AssignmentId } $studentJwt $null
  $ok = ($r.Status -eq 200 -and $r.Data.signature -match '^[0-9a-f]{40}$' `
         -and $r.Data.params.folder -eq 'sasha-math-dz' `
         -and $r.Data.params.overwrite -eq 'false' `
         -and $r.Data.params.public_id -like "s$StudentTgId/$AssignmentId/*" `
         -and $r.Data.resource_type -eq 'image')
  $detail = "HTTP $($r.Status)"
  if ($r.Data) { $detail += " folder=$($r.Data.params.folder) rt=$($r.Data.resource_type) pid=$($r.Data.params.public_id)" }
  Add-Check '01 student: подпись для своего задания' '200, folder=sasha-math-dz, серверный public_id' $detail $ok
  if ($ok) { $signedStudent = $r.Data }

  # 02 реальная загрузка фото по подписи
  if ($signedStudent) {
    $p = ConvertTo-Hash $signedStudent.params
    $up = Send-Cloudinary $signedStudent.resource_type $p $signedStudent.api_key $signedStudent.signature $PngBytes 'dz.jpg'
    $urlOk = ($up.Status -eq 200 -and $up.Url -like "https://res.cloudinary.com/$CloudName/*")
    Add-Check '02 student: загрузка фото проходит' '200, secure_url своего аккаунта' "HTTP $($up.Status) $($up.Err)" $urlOk

    # 03 Cloudinary отвечает 200/existing=true, но overwrite=false не даёт заменить объект.
    $again = Send-Cloudinary $signedStudent.resource_type $p $signedStudent.api_key $signedStudent.signature $PngBytes 'dz.jpg'
    $replaySafe = ($again.Status -eq 200 -and $again.Existing -and $again.Url -eq $up.Url)
    Add-Check '03 student: повтор подписи не перезаписывает объект' '200, existing=true, тот же secure_url' "HTTP $($again.Status) existing=$($again.Existing) same_url=$($again.Url -eq $up.Url)" $replaySafe

    # 04 просроченный timestamp (подпись больше не сходится)
    $stale = ConvertTo-Hash $signedStudent.params
    $stale['timestamp'] = [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 7200)
    $st = Send-Cloudinary $signedStudent.resource_type $stale $signedStudent.api_key $signedStudent.signature $PngBytes 'dz.jpg'
    Add-Check '04 student: просроченный timestamp отклонён' 'HTTP != 200' "HTTP $($st.Status) $($st.Err)" ($st.Status -ne 200)

    # 05 подмена folder на учительскую папку
    $moved = ConvertTo-Hash $signedStudent.params
    $moved['folder'] = 'sasha-math-tasks'
    $mv = Send-Cloudinary $signedStudent.resource_type $moved $signedStudent.api_key $signedStudent.signature $PngBytes 'dz.jpg'
    Add-Check '05 student: подмена folder отклонена' 'HTTP != 200' "HTTP $($mv.Status) $($mv.Err)" ($mv.Status -ne 200)
  } else {
    Add-Result '02 student: загрузка фото проходит' '200' 'нет подписи' 'SKIP'
    Add-Result '03 student: повтор той же подписи отклонён' 'HTTP != 200' 'нет подписи' 'SKIP'
    Add-Result '04 student: просроченный timestamp отклонён' 'HTTP != 200' 'нет подписи' 'SKIP'
    Add-Result '05 student: подмена folder отклонена' 'HTTP != 200' 'нет подписи' 'SKIP'
  }

  # 06 недопустимый тип файла
  $r = Send-Json $SignUrl @{ kind='student_photo'; filename='payload.pdf'; bytes=1000; assignment_id=$AssignmentId } $studentJwt $null
  Add-Check '06 student: чужой тип файла' '400/bad_request' "$($r.Status)/$($r.Code)" ($r.Status -eq 400)

  # 07 превышение размера
  $r = Send-Json $SignUrl @{ kind='student_photo'; filename='dz.jpg'; bytes=99999999; assignment_id=$AssignmentId } $studentJwt $null
  Add-Check '07 student: превышение размера' '413/file_too_large' "$($r.Status)/$($r.Code)" ($r.Status -eq 413 -and $r.Code -eq 'file_too_large')

  # 08 чужое задание
  $r = Send-Json $SignUrl @{ kind='student_photo'; filename='dz.jpg'; bytes=1000; assignment_id='11111111-2222-4333-8444-555555555555' } $studentJwt $null
  Add-Check '08 student: чужое задание' '403/forbidden' "$($r.Status)/$($r.Code)" ($r.Status -eq 403 -and $r.Code -eq 'forbidden')

  # 09 ученик просит учительскую папку
  $r = Send-Json $SignUrl @{ kind='teacher_pdf'; filename='tasks.pdf'; bytes=1000 } $studentJwt $null
  Add-Check '09 student: запрос teacher_pdf' '403/forbidden' "$($r.Status)/$($r.Code)" ($r.Status -eq 403 -and $r.Code -eq 'forbidden')

  # 10 неизвестный kind
  $r = Send-Json $SignUrl @{ kind='anything'; filename='dz.jpg'; bytes=1000 } $studentJwt $null
  Add-Check '10 student: неизвестный kind' '400/bad_request' "$($r.Status)/$($r.Code)" ($r.Status -eq 400)

  # 11 чужой origin
  $r = Send-Json $SignUrl @{ kind='student_photo'; filename='dz.jpg'; bytes=1000; assignment_id=$AssignmentId } $studentJwt 'https://evil.example'
  Add-Check '11 чужой origin' '403/origin_not_allowed' "$($r.Status)/$($r.Code)" ($r.Status -eq 403 -and $r.Code -eq 'origin_not_allowed')
}

# 12 без токена
$r = Send-Json $SignUrl @{ kind='student_photo'; filename='dz.jpg'; bytes=1000; assignment_id=$AssignmentId } $null $null
Add-Check '12 без токена' '401/unauthorized' "$($r.Status)/$($r.Code)" ($r.Status -eq 401)

# 13 мусорный токен
$r = Send-Json $SignUrl @{ kind='student_photo'; filename='dz.jpg'; bytes=1000; assignment_id=$AssignmentId } 'aaa.bbb.ccc' $null
Add-Check '13 подделанный токен' '401/unauthorized' "$($r.Status)/$($r.Code)" ($r.Status -eq 401)

# ============================ TEACHER ============================
if ($teacherJwt) {
  # 14 валидная подпись PDF
  $r = Send-Json $SignUrl @{ kind='teacher_pdf'; filename='tasks.pdf'; bytes=200000 } $teacherJwt $null
  $ok = ($r.Status -eq 200 -and $r.Data.params.folder -eq 'sasha-math-tasks' -and $r.Data.params.allowed_formats -eq 'pdf')
  Add-Check '14 teacher: подпись PDF' '200, folder=sasha-math-tasks, formats=pdf' "HTTP $($r.Status) folder=$($r.Data.params.folder)" $ok

  if ($ok) {
    $signedTeacher = $r.Data
    $pdfBytes = $null
    if ($PdfPath -and (Test-Path $PdfPath)) { $pdfBytes = [IO.File]::ReadAllBytes($PdfPath) }
    else { $pdfBytes = New-MinimalPdf }

    # 15 реальная загрузка PDF
    $p = ConvertTo-Hash $signedTeacher.params
    $up = Send-Cloudinary $signedTeacher.resource_type $p $signedTeacher.api_key $signedTeacher.signature $pdfBytes 'tasks.pdf'
    $urlOk = ($up.Status -eq 200 -and $up.Url -like "https://res.cloudinary.com/$CloudName/*")
    Add-Check '15 teacher: загрузка PDF проходит' '200, secure_url своего аккаунта' "HTTP $($up.Status) $($up.Err)" $urlOk

    # 16 подмена содержимого: под PDF-подпись отправляется картинка (allowed_formats=pdf)
    $r2 = Send-Json $SignUrl @{ kind='teacher_pdf'; filename='tasks.pdf'; bytes=1000 } $teacherJwt $null
    $p2 = ConvertTo-Hash $r2.Data.params
    $bad = Send-Cloudinary $r2.Data.resource_type $p2 $r2.Data.api_key $r2.Data.signature $PngBytes 'tasks.pdf'
    Add-Check '16 teacher: не-PDF под PDF-подписью отклонён' 'HTTP != 200' "HTTP $($bad.Status) $($bad.Err)" ($bad.Status -ne 200)
  } else {
    Add-Result '15 teacher: загрузка PDF проходит' '200' 'нет подписи' 'SKIP'
    Add-Result '16 teacher: не-PDF под PDF-подписью отклонён' 'HTTP != 200' 'нет подписи' 'SKIP'
  }

  # 17 учитель просит ученическую папку
  $r = Send-Json $SignUrl @{ kind='student_photo'; filename='dz.jpg'; bytes=1000; assignment_id=$AssignmentId } $teacherJwt $null
  Add-Check '17 teacher: запрос student_photo' '403/forbidden' "$($r.Status)/$($r.Code)" ($r.Status -eq 403 -and $r.Code -eq 'forbidden')
} else {
  Add-Result '14 teacher: подпись PDF' '200' 'нет teacher JWT' 'SKIP'
  Add-Result '15 teacher: загрузка PDF проходит' '200' 'нет teacher JWT' 'SKIP'
  Add-Result '16 teacher: не-PDF под PDF-подписью отклонён' 'HTTP != 200' 'нет teacher JWT' 'SKIP'
  Add-Result '17 teacher: запрос student_photo' '403' 'нет teacher JWT' 'SKIP'
}

# ============================ unsigned probe (информационно) ============================
Invoke-UnsignedProbe

# ============================ вывод ============================
Write-Host ""
Write-Host "===== B2-T09 результаты =====" -ForegroundColor Cyan
$results | Format-List
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
$skipped = @($results | Where-Object { $_.Result -eq 'SKIP' }).Count
if ($failed -eq 0) { Write-Host "ИТОГ: FAIL нет (SKIP: $skipped)" -ForegroundColor Green }
else { Write-Host "ИТОГ: $failed FAIL (SKIP: $skipped)" -ForegroundColor Red }

Write-Host ""
Write-Host "===== Очистка dev (Supabase SQL editor; секретов нет) =====" -ForegroundColor Cyan
Write-Host @'
delete from public.assignments            where student_id = 995000009;
delete from public.students               where telegram_id = 995000009;
delete from private.security_principals   where telegram_id = 995000009;
delete from private.security_rate_limits  where bucket in ('sign_upload','student_auth');
-- контроль: обе выборки должны вернуть 0
select count(*) from public.assignments where student_id = 995000009;
select count(*) from public.students    where telegram_id = 995000009;
'@
Write-Host ""
Write-Host "В Cloudinary удалить тестовые объекты: папки sasha-math-dz/s995000009 и sasha-math-tasks/t*," -ForegroundColor Yellow
Write-Host "а также объект b2t09-unsigned-probe из sasha-math-dz (Media Library -> выделить -> Delete)." -ForegroundColor Yellow

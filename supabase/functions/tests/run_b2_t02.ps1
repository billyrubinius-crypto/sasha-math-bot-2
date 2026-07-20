<#
  run_b2_t02.ps1 — безопасный harness проверки student-auth (B2-T02, T10-02).
  Для владельца на Windows. НЕ печатает BOT_TOKEN, initData, hash или полный JWT.
  НЕ использует service-role. JWKS — публичный. Итог — таблица PASS/FAIL + cleanup SQL.

  Запуск (PowerShell):
    .\run_b2_t02.ps1 -FunctionUrl "https://<ref>.functions.supabase.co/student-auth" `
                     -Origin "https://<mini-app-origin>" `
                     -Kid "a657ba08-f043-4dea-ac7b-617120e912d7"
  BOT_TOKEN спросится скрытым вводом. Опционально: -JwksUrl "https://<ref>.supabase.co/auth/v1/.well-known/jwks.json"
#>
param(
  [Parameter(Mandatory=$true)][string]$FunctionUrl,
  [Parameter(Mandatory=$true)][string]$Origin,
  [Parameter(Mandatory=$true)][string]$Kid,
  [string]$JwksUrl
)

$ErrorActionPreference = 'Stop'

# --- Скрытый ввод BOT_TOKEN (значение нигде не печатается) ---
$secureToken = Read-Host -AsSecureString "Введите BOT_TOKEN (ввод скрыт)"

# --- JWKS URL: derive из FunctionUrl, если не задан ---
if (-not $JwksUrl) {
  try {
    $h = ([Uri]$FunctionUrl).Host           # <ref>.functions.supabase.co
    $ref = $h.Split('.')[0]
    $JwksUrl = "https://$ref.supabase.co/auth/v1/.well-known/jwks.json"
  } catch {
    Write-Host "Не удалось вывести JwksUrl из FunctionUrl — задайте -JwksUrl вручную." -ForegroundColor Yellow
    throw
  }
}

# ============================ helpers ============================
function ConvertFrom-Base64Url([string]$s) {
  $s = $s.Replace('-','+').Replace('_','/')
  switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
  return [Convert]::FromBase64String($s)
}
function Get-HmacSha256([byte[]]$key, [string]$message) {
  $h = New-Object System.Security.Cryptography.HMACSHA256
  $h.Key = $key
  return $h.ComputeHash([Text.Encoding]::UTF8.GetBytes($message))
}
function To-HexLower([byte[]]$b) { -join ($b | ForEach-Object { $_.ToString('x2') }) }

# Достаём plaintext токена ТОЛЬКО внутри построения initData; сразу зануляем.
function Get-PlainToken([System.Security.SecureString]$sec) {
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Строит валидный initData (или с заданной "порчей"). token берётся из SecureString.
function New-InitData {
  param([long]$Id, [int]$OffsetSec = 0, [switch]$MalformedUser)
  $token = Get-PlainToken $secureToken
  try {
    $authDate = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $OffsetSec
    if ($MalformedUser) { $userJson = '{not json' }
    else { $userJson = '{"id":' + $Id + ',"first_name":"T10test"}' }
    $fields = @{ user = $userJson; auth_date = "$authDate" }
    $dcs = ($fields.Keys | Sort-Object | ForEach-Object { "$_=$($fields[$_])" }) -join "`n"
    $secret = Get-HmacSha256 ([Text.Encoding]::UTF8.GetBytes('WebAppData')) $token
    $hash = To-HexLower (Get-HmacSha256 $secret $dcs)
    return ("user=" + [Uri]::EscapeDataString($userJson) + "&auth_date=$authDate&hash=$hash")
  } finally { $token = $null }
}

# POST в функцию; возвращает @{ Status; Code; Token } (Token наружу не печатается).
function Send-Auth([string]$InitData, [string]$OriginHeader = $Origin) {
  $body = (@{ initData = $InitData } | ConvertTo-Json -Compress)
  try {
    $resp = Invoke-WebRequest -Uri $FunctionUrl -Method Post -ContentType 'application/json' `
      -Headers @{ Origin = $OriginHeader } -Body $body -UseBasicParsing
    $json = $resp.Content | ConvertFrom-Json
    return @{ Status = [int]$resp.StatusCode; Code = 'ok'; Token = $json.access_token }
  } catch {
    $r = $_.Exception.Response
    if ($r -ne $null) {
      $status = [int]$r.StatusCode
      $reader = New-Object IO.StreamReader($r.GetResponseStream())
      $content = $reader.ReadToEnd(); $reader.Close()
      $code = 'unknown'
      try { $code = ($content | ConvertFrom-Json).error } catch {}
      return @{ Status = $status; Code = $code; Token = $null }
    }
    return @{ Status = 0; Code = 'neterror'; Token = $null }
  }
}

function Get-JwtPayload([string]$jwt) {
  $p = $jwt.Split('.')[1]
  return [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $p)) | ConvertFrom-Json
}
function Get-JwtHeader([string]$jwt) {
  $h = $jwt.Split('.')[0]
  return [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $h)) | ConvertFrom-Json
}

$results = New-Object System.Collections.ArrayList
function Add-Result([string]$Case, [string]$Expected, [string]$Actual, [bool]$Pass) {
  [void]$results.Add([pscustomobject]@{
    Case = $Case; Expected = $Expected; Actual = $Actual
    Result = $(if ($Pass) { 'PASS' } else { 'FAIL' })
  })
}

# ============================ cases ============================
$good = New-InitData -Id 995000001 -OffsetSec 0

# 1. valid fixture
$r = Send-Auth $good
Add-Result '01 valid fixture' '200/ok' "$($r.Status)/$($r.Code)" ($r.Status -eq 200 -and $r.Code -eq 'ok')
$validToken = $r.Token

# 2. retry same initData -> 200 и тот же principal (sub)
$r2 = Send-Auth $good
$sub1 = $null; $sub2 = $null
if ($validToken) { $sub1 = (Get-JwtPayload $validToken).sub }
if ($r2.Token)   { $sub2 = (Get-JwtPayload $r2.Token).sub }
Add-Result '02 retry same initData' '200, same sub' "$($r2.Status), same=$($sub1 -eq $sub2)" ($r2.Status -eq 200 -and $sub1 -and $sub1 -eq $sub2)

# 3. bad hash
$bad = ($good -replace 'hash=[0-9a-f]+', ('hash=' + ('0' * 64)))
$r = Send-Auth $bad
Add-Result '03 bad hash' '401/bad_hash' "$($r.Status)/$($r.Code)" ($r.Status -eq 401 -and $r.Code -eq 'bad_hash')

# 4. changed user (hash не пересчитан)
$other = [Uri]::EscapeDataString('{"id":995000999,"first_name":"X"}')
$changed = ($good -replace 'user=[^&]+', ("user=" + $other))
$r = Send-Auth $changed
Add-Result '04 changed user' '401/bad_hash' "$($r.Status)/$($r.Code)" ($r.Status -eq 401 -and $r.Code -eq 'bad_hash')

# 5. missing hash
$missing = ($good -replace '&hash=[0-9a-f]+', '')
$r = Send-Auth $missing
Add-Result '05 missing hash' '401/bad_hash' "$($r.Status)/$($r.Code)" ($r.Status -eq 401 -and $r.Code -eq 'bad_hash')

# 6. duplicate hash
$dup = $good + '&hash=' + ('a' * 64)
$r = Send-Auth $dup
Add-Result '06 duplicate hash' '401/bad_hash' "$($r.Status)/$($r.Code)" ($r.Status -eq 401 -and $r.Code -eq 'bad_hash')

# 7. old auth_date (> 24h)
$old = New-InitData -Id 995000002 -OffsetSec (-90000)
$r = Send-Auth $old
Add-Result '07 old auth_date' '401/expired_auth_date' "$($r.Status)/$($r.Code)" ($r.Status -eq 401 -and $r.Code -eq 'expired_auth_date')

# 8. future auth_date (> 5m)
$future = New-InitData -Id 995000002 -OffsetSec 600
$r = Send-Auth $future
Add-Result '08 future auth_date' '401/future_auth_date' "$($r.Status)/$($r.Code)" ($r.Status -eq 401 -and $r.Code -eq 'future_auth_date')

# 9. malformed user (hash валиден для битого user)
$mal = New-InitData -Id 995000003 -MalformedUser
$r = Send-Auth $mal
Add-Result '09 malformed user' '401/malformed_user' "$($r.Status)/$($r.Code)" ($r.Status -eq 401 -and $r.Code -eq 'malformed_user')

# 10. oversized body (initData > 8 КБ)
$big = 'a' * 9000
$r = Send-Auth $big
Add-Result '10 oversized body' '400/bad_request' "$($r.Status)/$($r.Code)" ($r.Status -eq 400)

# 11. wrong origin
$r = Send-Auth $good 'https://evil.example'
Add-Result '11 wrong origin' '403/origin_not_allowed' "$($r.Status)/$($r.Code)" ($r.Status -eq 403 -and $r.Code -eq 'origin_not_allowed')

# 12. JWT signature verify против JWKS (current kid)
$verifyOk = $false; $verifyDetail = 'no token'
if ($validToken) {
  try {
    $hdr = Get-JwtHeader $validToken
    $jwks = Invoke-RestMethod -Uri $JwksUrl -UseBasicParsing
    $jwk = $jwks.keys | Where-Object { $_.kid -eq $Kid } | Select-Object -First 1
    if (-not $jwk) { $verifyDetail = "kid $Kid не найден в JWKS" }
    else {
      $ec = New-Object System.Security.Cryptography.ECParameters
      $ec.Curve = [System.Security.Cryptography.ECCurve+NamedCurves]::nistP256
      # ECPoint/ECParameters are value types. Windows PowerShell 5 mutates a
      # temporary copy for `$ec.Q.X = ...`, leaving Q empty at ImportParameters.
      $point = New-Object System.Security.Cryptography.ECPoint
      $point.X = ConvertFrom-Base64Url $jwk.x
      $point.Y = ConvertFrom-Base64Url $jwk.y
      $ec.Q = $point
      $ecdsa = [System.Security.Cryptography.ECDsa]::Create()
      $ecdsa.ImportParameters($ec)
      $parts = $validToken.Split('.')
      $data = [Text.Encoding]::UTF8.GetBytes($parts[0] + '.' + $parts[1])
      $sig  = ConvertFrom-Base64Url $parts[2]   # r||s (IEEE P1363) == JWS ES256
      $verifyOk = $ecdsa.VerifyData($data, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
      $verifyDetail = "header.kid == current == $($hdr.kid -eq $Kid); sig verify == $verifyOk"
    }
  } catch { $verifyDetail = "verify error: $($_.Exception.Message)" }
}
Add-Result '12 JWT verify vs JWKS' 'sig verify true, kid=current' $verifyDetail $verifyOk

# 13. claims/expiry
$claimsOk = $false; $claimsDetail = 'no token'
if ($validToken) {
  $pl = Get-JwtPayload $validToken
  $ttl = [int]$pl.exp - [int]$pl.iat
  $claimsOk = ($pl.role -eq 'authenticated') -and ($pl.app_role -eq 'student') `
    -and ($pl.telegram_id -eq '995000001') -and ($pl.aud -eq 'authenticated') `
    -and ($pl.sub -match '^[0-9a-fA-F-]{36}$') -and ($ttl -eq 3600)
  $claimsDetail = "role=$($pl.role) app_role=$($pl.app_role) tg=$($pl.telegram_id) aud=$($pl.aud) ttl=$ttl subUUID=$($pl.sub -match '^[0-9a-fA-F-]{36}$')"
}
Add-Result '13 claims/expiry' 'authenticated/student/tg/aud/60m/uuid' $claimsDetail $claimsOk

# 14. concurrent first login -> один principal (одинаковый sub у всех)
$concInit = New-InitData -Id 995000010 -OffsetSec 0
$sb = {
  param($Url, $Origin, $InitData)
  try {
    $body = (@{ initData = $InitData } | ConvertTo-Json -Compress)
    $resp = Invoke-WebRequest -Uri $Url -Method Post -ContentType 'application/json' `
      -Headers @{ Origin = $Origin } -Body $body -UseBasicParsing
    $tok = ($resp.Content | ConvertFrom-Json).access_token
    $p = $tok.Split('.')[1].Replace('-','+').Replace('_','/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    $sub = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json).sub
    "OK:$sub"
  } catch { "ERR" }
}
$jobs = 1..8 | ForEach-Object { Start-Job -ScriptBlock $sb -ArgumentList $FunctionUrl, $Origin, $concInit }
$out = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job
$oks = @($out | Where-Object { $_ -like 'OK:*' })
$distinct = @($oks | ForEach-Object { $_.Substring(3) } | Select-Object -Unique)
$concPass = ($oks.Count -eq 8 -and $distinct.Count -eq 1)
Add-Result '14 concurrent first login' '8x200, 1 principal' "ok=$($oks.Count), distinct_sub=$($distinct.Count)" $concPass

# ============================ вывод ============================
Write-Host ""
Write-Host "===== B2-T02 результаты =====" -ForegroundColor Cyan
$results | Format-Table -AutoSize
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
if ($failed -eq 0) { Write-Host "ИТОГ: ВСЕ PASS" -ForegroundColor Green }
else { Write-Host "ИТОГ: $failed FAIL" -ForegroundColor Red }

Write-Host ""
Write-Host "===== Очистка dev (выполнить в Supabase SQL editor; секретов нет) =====" -ForegroundColor Cyan
Write-Host @'
delete from private.security_principals where telegram_id >= 995000000;
delete from public.students             where telegram_id >= 995000000;
delete from private.security_rate_limits where bucket = 'student_auth';
-- контроль единичности principal (до очистки), под service_role в самом редакторе:
-- select count(*) from private.security_principals where telegram_id = 995000001;  -- ожидаем 1
'@

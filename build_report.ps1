#Requires -Version 5.1
# ΓòöΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòù
# Γòæ  Quicker ΓÇö build_report.ps1         Γòæ
# Γòæ  Concatenates ReportStages\ into    Γòæ
# Γòæ  Report.html. Run after any stage   Γòæ
# Γòæ  file change.                       Γòæ
# ΓòáΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòú
# Γòæ  Usage  : .\build_report.ps1        Γòæ
# Γòæ  Output : Report.html               Γòæ
# ΓòÜΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓò¥
$stages = Get-ChildItem (Join-Path $PSScriptRoot "ReportStages") | Sort-Object Name
$output = ""
foreach ($s in $stages) {
    $output += [System.IO.File]::ReadAllText($s.FullName, [System.Text.Encoding]::UTF8)
}
#region --- Embed tools.json as JS variable ---
$toolsJsonPath = Join-Path $PSScriptRoot "tools.json"
if (Test-Path $toolsJsonPath) {
    $toolsJson = [System.IO.File]::ReadAllText($toolsJsonPath, [System.Text.Encoding]::UTF8).Trim()
    $embed = "`nvar _embeddedToolsManifest = $toolsJson;`n"
} else {
    $embed = "`nvar _embeddedToolsManifest = null;`n"
}
$output = $output.Replace('<script>', "<script>$embed")
#endregion

#region --- Embed tool-defaults.json as JS variable ---
$defaultsPath = Join-Path $PSScriptRoot "tool-defaults.json"
if (Test-Path $defaultsPath) {
    $defaultsJson = [System.IO.File]::ReadAllText($defaultsPath, [System.Text.Encoding]::UTF8).Trim()
    $embedDefaults = "`nvar _toolDefaults = $defaultsJson;`n"
} else {
    $embedDefaults = "`nvar _toolDefaults = null;`n"
}
$output = $output.Replace($embed, "$embed$embedDefaults")
#endregion

$outPath = Join-Path $PSScriptRoot "Report.html"
[System.IO.File]::WriteAllText($outPath, $output, [System.Text.Encoding]::UTF8)
$size = (Get-Item $outPath).Length
Write-Host "Report.html built ΓÇö $([math]::Round($size/1kb,1)) KB"
function Test-ReportHtml {
  param([string]$Path)
  $html = Get-Content $Path -Raw
  $pass = $true

  $opens = ([regex]::Matches($html, '<script>')).Count
  if ($opens -ne 1) {
    Write-Host "FAIL: $opens <script> tags found (expected 1)" -ForegroundColor Red
    $pass = $false
  }

  $closes = ([regex]::Matches($html, '</script>')).Count
  if ($closes -ne 1) {
    Write-Host "FAIL: $closes </script> tags found (expected 1)" -ForegroundColor Red
    $pass = $false
  }

  $openIdx  = $html.IndexOf('<script>')
  $closeIdx = $html.LastIndexOf('</script>')
  if ($openIdx -gt $closeIdx) {
    Write-Host "FAIL: </script> before <script>" -ForegroundColor Red
    $pass = $false
  }

  $jsLen = $closeIdx - $openIdx
  if ($jsLen -lt 50000) {
    Write-Host "FAIL: JS content only $jsLen chars (expected >50000)" -ForegroundColor Red
    $pass = $false
  }

  $fileSize = (Get-Item $Path).Length
  if ($fileSize -lt 50kb) {
    Write-Host "FAIL: file size $fileSize bytes (expected >50KB)" -ForegroundColor Red
    $pass = $false
  }

  if ($pass) {
    Write-Host "BUILD OK -- all checks passed ($([math]::Round($fileSize/1kb,1)) KB)" -ForegroundColor Green
  } else {
    Write-Host "BUILD FAILED -- fix stage files" -ForegroundColor Red
    exit 1
  }
}

Test-ReportHtml -Path $outPath

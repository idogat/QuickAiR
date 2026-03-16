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
$outPath = Join-Path $PSScriptRoot "Report.html"
[System.IO.File]::WriteAllText($outPath, $output, [System.Text.Encoding]::UTF8)
$size = (Get-Item $outPath).Length
Write-Host "Report.html built ΓÇö $([math]::Round($size/1kb,1)) KB"
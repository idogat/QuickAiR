#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  QuickAiR — DateTime.psm1            ║
# ║  UTC normalization, DMTF to ISO 8601║
# ╠══════════════════════════════════════╣
# ║  Exports   : ConvertTo-UtcIso       ║
# ║  Inputs    : $Value (str/datetime)  ║
# ║              $FallbackOffsetMin     ║
# ║  Output    : UTC ISO 8601 string    ║
# ║  Depends   : none                   ║
# ║  PS compat : 2.0+                   ║
# ║  Version   : 2.2                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ConvertTo-UtcIso: Convert WMI DMTF string or [datetime] to UTC ISO 8601 string
# WMI DMTF format: "20240115143022.000000+060" (offset in minutes east of UTC)
function ConvertTo-UtcIso {
    param([object]$Value, [int]$FallbackOffsetMin = 0)
    if ($null -eq $Value -or $Value -eq '') { return $null }

    # Already a [DateTime]
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Utc) {
            return $Value.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    $s = $Value.ToString().Trim()

    # DMTF format
    if ($s -match '^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\.\d+([+-]\d+)$') {
        try {
            $yr = [int]$Matches[1]; $mo = [int]$Matches[2]; $dy = [int]$Matches[3]
            $hr = [int]$Matches[4]; $mi = [int]$Matches[5]; $sc = [int]$Matches[6]
            $off = [int]$Matches[7]
            $local = [datetime]::new($yr, $mo, $dy, $hr, $mi, $sc)
            return $local.AddMinutes(-$off).ToString('yyyy-MM-ddTHH:mm:ssZ')
        } catch {
            Write-Warning "DMTF parse failed for value '$s': $($_.Exception.Message)"
            return $null
        }
    }

    # Partial DMTF — looks like DMTF but malformed, don't guess
    if ($s -match '^\d{14}') {
        Write-Warning "Malformed DMTF string (partial match, no offset): '$s'"
        return $null
    }

    # Generic parse fallback
    try {
        $dt = [datetime]::Parse($s)
        return $dt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    } catch { return $null }
}

Export-ModuleMember -Function ConvertTo-UtcIso

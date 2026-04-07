#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  QuickAiR -- DateTime.psm1            ║
# ║  UTC normalization, DMTF to ISO 8601║
# ╠══════════════════════════════════════╣
# ║  Exports   : ConvertTo-UtcIso       ║
# ║  Inputs    : $Value (str/datetime)  ║
# ║              $FallbackOffsetMin     ║
# ║  Output    : UTC ISO 8601 string    ║
# ║  Depends   : none                   ║
# ║  PS compat : 5.1 (analyst machine)  ║
# ║  Version   : 2.6                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ConvertTo-UtcIso: Convert WMI DMTF string or [datetime] to UTC ISO 8601 string
# WMI DMTF format: "20240115143022.000000+060" (offset in minutes east of UTC)
function ConvertTo-UtcIso {
    param([object]$Value, $FallbackOffsetMin = $null)
    if ($null -eq $Value -or $Value -eq '') { return $null }

    # W3-DT-01: reject unexpected types (e.g., integers that produce plausible but wrong dates)
    if ($Value -isnot [string] -and $Value -isnot [datetime]) {
        Write-Warning "ConvertTo-UtcIso: unexpected type $($Value.GetType().Name) for value '$Value'"
        return $null
    }

    # Already a [DateTime]
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Utc) {
            return $Value.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        # Kind=Unspecified: apply target timezone offset if provided, not analyst-local
        if ($Value.Kind -eq [DateTimeKind]::Unspecified -and $null -ne $FallbackOffsetMin) {
            return $Value.AddMinutes(-[int]$FallbackOffsetMin).ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
            # No offset available -- assume UTC rather than silently using analyst-local timezone
            Write-Warning "ConvertTo-UtcIso: DateTime Kind=Unspecified with no FallbackOffsetMin -- treating as UTC"
            return $Value.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        # Kind=Local -- analyst-local ToUniversalTime() is correct
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

    # Partial DMTF -- looks like DMTF but malformed, don't guess
    if ($s -match '^\d{14}') {
        Write-Warning "Malformed DMTF string (partial match, no offset): '$s'"
        return $null
    }

    # Generic parse fallback -- apply target timezone offset, not analyst-local
    try {
        $dt = [datetime]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture,
                                [System.Globalization.DateTimeStyles]::None)
        if ($dt.Kind -eq [DateTimeKind]::Utc) {
            return $dt.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        # If offset explicitly provided (including 0 for UTC targets), apply it
        if ($null -ne $FallbackOffsetMin) {
            return $dt.AddMinutes(-[int]$FallbackOffsetMin).ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        # No offset info -- assume UTC rather than silently using analyst-local timezone
        Write-Warning "ConvertTo-UtcIso: parsed datetime with no FallbackOffsetMin -- treating as UTC"
        return $dt.ToString('yyyy-MM-ddTHH:mm:ssZ')
    } catch { return $null }
}

Export-ModuleMember -Function ConvertTo-UtcIso

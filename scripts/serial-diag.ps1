# Read the ESP32 boot log over serial. Hardware bring-up helper.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/serial-diag.ps1
#   powershell ... -File scripts/serial-diag.ps1 -Port COM4 -Baud 115200 -Seconds 3
#
# How it works: pulses RTS (wired to EN on the common auto-download circuit) to
# reset the chip, then captures UART0 output. The ESP32-S3 ROM boot log runs at
# 115200 8N1.
#
# ASCII only: Windows PowerShell 5.1 parses a .ps1 without a BOM as ANSI and
# mangles non-ASCII bytes, which can break quoting and fail parsing.

param(
    [string]$Port = 'COM4',
    [int]$Baud = 115200,
    [int]$Seconds = 3
)

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200

try {
    $sp.Open()

    # Auto-download circuit: RTS -> EN, DTR -> IO0.
    $sp.DtrEnable = $false
    $sp.RtsEnable = $true
    Start-Sleep -Milliseconds 100
    $sp.RtsEnable = $false

    $deadline = (Get-Date).AddSeconds($Seconds)
    $sb = New-Object System.Text.StringBuilder
    while ((Get-Date) -lt $deadline) {
        try { [void]$sb.Append($sp.ReadExisting()) } catch { }
        Start-Sleep -Milliseconds 50
    }

    $text = $sb.ToString()
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-Output "(no serial output within ${Seconds}s)"
        Write-Output 'Possible causes: board unpowered, firmware prints nothing, wrong baud (try -Baud 74880)'
    }
    else {
        Write-Output '--- begin ---'
        Write-Output $text
        Write-Output '--- end ---'
    }
}
catch {
    Write-Output ('Failed to open port: ' + $_.Exception.Message)
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
}

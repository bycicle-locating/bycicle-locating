# Execute a code snippet on the ESP32 through the MicroPython raw REPL.
#
# Why this exists: hardware bring-up. When the board runs MicroPython you can
# verify UART/peripheral wiring without installing ESP-IDF.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/mpy-exec.ps1 -CodeFile scripts/at-probe.py -Port COM4 -TimeoutMs 10000
#
# Notes:
#   - ASCII only in this file. Windows PowerShell 5.1 parses a .ps1 without a
#     BOM as ANSI, which mangles non-ASCII bytes and breaks quoting.
#   - Do not toggle RTS/DTR here: that resets the board and loses the REPL.
#   - Code is sent in small chunks. A single large write overflows the ESP32
#     UART RX buffer and the snippet arrives truncated (SyntaxError).
#   - Diagnostic tool only. Production firmware is ESP-IDF
#     (see docs/adr/0002-tier-stack.md).

param(
    [Parameter(Mandatory = $true)][string]$CodeFile,
    [string]$Port = 'COM4',
    [int]$Baud = 115200,
    [int]$TimeoutMs = 10000,
    [int]$ChunkSize = 96
)

$CTRL_C = [string][char]3
$CTRL_A = [string][char]1
$CTRL_D = [string][char]4

function Read-For {
    param([System.IO.Ports.SerialPort]$P, [int]$Ms)
    $buf = New-Object System.Collections.Generic.List[byte]
    $deadline = (Get-Date).AddMilliseconds($Ms)
    while ((Get-Date) -lt $deadline) {
        $n = $P.BytesToRead
        if ($n -gt 0) {
            $bytes = New-Object byte[] $n
            [void]$P.Read($bytes, 0, $n)
            $buf.AddRange($bytes)
        }
        else {
            Start-Sleep -Milliseconds 40
        }
    }
    return $buf.ToArray()
}

function Show-Bytes {
    param([byte[]]$Bytes)
    if ($Bytes.Length -eq 0) {
        Write-Output '(no output)'
        return
    }
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes)
    # Raw REPL separates stdout/stderr with 0x04.
    $text = $text -replace [string][char]4, "`n---`n"
    $text = $text -replace [string][char]1, ''
    $text = $text -replace [string][char]2, ''
    $text = $text -replace "`r", ''
    Write-Output $text
}

if (-not (Test-Path $CodeFile)) {
    Write-Output "Code file not found: $CodeFile"
    exit 1
}

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200
$sp.WriteTimeout = 2000
$sp.DtrEnable = $false
$sp.RtsEnable = $false

try {
    $sp.Open()
    Start-Sleep -Milliseconds 300
    [void]$sp.ReadExisting()

    # Interrupt anything running, then switch to raw REPL.
    $sp.Write($CTRL_C)
    Start-Sleep -Milliseconds 300
    $sp.Write($CTRL_A)
    Start-Sleep -Milliseconds 400
    $hello = Read-For -P $sp -Ms 300
    if (-not ([System.Text.Encoding]::ASCII.GetString($hello) -match 'raw REPL')) {
        Write-Output 'WARN: raw REPL not detected, output may be unreliable'
    }

    $code = Get-Content -Raw -Encoding UTF8 $CodeFile
    $code = $code -replace "`r`n", "`n"

    # Chunked write: MicroPython's stdin reader is slower than the UART.
    for ($i = 0; $i -lt $code.Length; $i += $ChunkSize) {
        $len = [Math]::Min($ChunkSize, $code.Length - $i)
        $sp.Write($code.Substring($i, $len))
        Start-Sleep -Milliseconds 15
    }
    $sp.Write("`n")
    Start-Sleep -Milliseconds 100
    $sp.Write($CTRL_D)

    $out = Read-For -P $sp -Ms $TimeoutMs
    Show-Bytes -Bytes $out

    # Return to the friendly REPL.
    $sp.Write($CTRL_C)
    Start-Sleep -Milliseconds 200
}
catch {
    Write-Output ('FAILED: ' + $_.Exception.Message)
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
}

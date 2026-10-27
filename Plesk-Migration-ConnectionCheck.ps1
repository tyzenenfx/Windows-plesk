
# ============================================================
# Windows Plesk Migration - Post Connection Check
# Checks required TCP ports and performs optional UDP checks
# Generates a CSV report
# ============================================================

$ErrorActionPreference = "Continue"

# Ask for source server IP
$RemoteServer = Read-Host "Enter Source Windows Server IP Address or Hostname"

if ([string]::IsNullOrWhiteSpace($RemoteServer)) {
    Write-Host "ERROR: Source server IP is required." -ForegroundColor Red
    exit 1
}

# Validate hostname/IP resolution
try {
    $Resolved = Resolve-DnsName -Name $RemoteServer -ErrorAction Stop |
        Select-Object -First 1

    Write-Host "Target resolved successfully." -ForegroundColor Green
}
catch {
    Write-Host "WARNING: Could not resolve the target. Continuing with connection tests." `
        -ForegroundColor Yellow
}

# Report file
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputCsv = Join-Path (Get-Location) "Plesk_Migration_Check_$Timestamp.csv"

# TCP ports
$TcpPorts = @(
    [PSCustomObject]@{ Port = 135;   Service = "RPC Endpoint Mapper"; Required = "Yes" }
    [PSCustomObject]@{ Port = 139;   Service = "NetBIOS Session"; Required = "Yes" }
    [PSCustomObject]@{ Port = 445;   Service = "SMB File Sharing"; Required = "Yes" }
    [PSCustomObject]@{ Port = 1433;  Service = "SQL Server Default Instance"; Required = "Conditional" }
    [PSCustomObject]@{ Port = 10155; Service = "Plesk Migrator Service"; Required = "Yes" }
    [PSCustomObject]@{ Port = 10156; Service = "Rsync Service"; Required = "Yes" }
    [PSCustomObject]@{ Port = 8443;  Service = "Plesk XML API"; Required = "If Plesk" }
    [PSCustomObject]@{ Port = 110;   Service = "POP3"; Required = "If Used" }
    [PSCustomObject]@{ Port = 143;   Service = "IMAP"; Required = "If Used" }
)

# UDP ports
$UdpPorts = @(
    [PSCustomObject]@{ Port = 137;  Service = "NetBIOS Name Service" }
    [PSCustomObject]@{ Port = 138;  Service = "NetBIOS Datagram Service" }
    [PSCustomObject]@{ Port = 1434; Service = "SQL Server Browser" }
)

$Results = [System.Collections.Generic.List[object]]::new()

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " WINDOWS PLESK MIGRATION CONNECTION CHECK" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Local Server : $env:COMPUTERNAME"
Write-Host "Remote Server: $RemoteServer"
Write-Host "Started      : $(Get-Date)"
Write-Host ""

# ------------------------------------------------------------
# TCP checks
# ------------------------------------------------------------
Write-Host "Starting TCP port checks..." -ForegroundColor Cyan

foreach ($Item in $TcpPorts) {
    $Port = $Item.Port

    Write-Host "Checking TCP port $Port ($($Item.Service))..." `
        -NoNewline

    try {
        $Connected = Test-NetConnection `
            -ComputerName $RemoteServer `
            -Port $Port `
            -InformationLevel Quiet `
            -WarningAction SilentlyContinue `
            -ErrorAction Stop

        if ($Connected) {
            $Status = "PASS"
            $Details = "TCP connection successful"
            Write-Host " PASS" -ForegroundColor Green
        }
        else {
            $Status = "FAIL"
            $Details = "Connection failed, filtered, or service unavailable"
            Write-Host " FAIL" -ForegroundColor Red
        }
    }
    catch {
        $Status = "ERROR"
        $Details = $_.Exception.Message
        Write-Host " ERROR" -ForegroundColor Red
    }

    $Results.Add([PSCustomObject]@{
        SourceServer = $env:COMPUTERNAME
        RemoteServer = $RemoteServer
        Protocol     = "TCP"
        Port         = $Port
        Service      = $Item.Service
        Requirement  = $Item.Required
        Status       = $Status
        Details      = $Details
        CheckedAt    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    })
}

# ------------------------------------------------------------
# UDP checks
# UDP cannot be reliably validated with a TCP connection test.
# PortQry is used when installed.
# ------------------------------------------------------------
Write-Host ""
Write-Host "Starting UDP diagnostics..." -ForegroundColor Cyan

$PortQry = Get-Command "portqry.exe" -ErrorAction SilentlyContinue

foreach ($Item in $UdpPorts) {
    $Port = $Item.Port
    $Status = "MANUAL CHECK"
    $Details = "UDP status cannot be confirmed using TCP tests."

    Write-Host "Checking UDP port $Port ($($Item.Service))..." `
        -NoNewline

    if ($PortQry) {
        try {
            $PortQryOutput = & $PortQry.Source `
                -n $RemoteServer -p UDP -e $Port 2>&1

            $Text = $PortQryOutput -join "`n"

            if ($Text -match "LISTENING") {
                $Status = "RESPONDING"
                $Details = "UDP service responded according to PortQry."
                Write-Host " RESPONDING" -ForegroundColor Green
            }
            elseif ($Text -match "NOT LISTENING") {
                $Status = "NOT LISTENING"
                $Details = "No listener response; verify service and firewall."
                Write-Host " NOT LISTENING" -ForegroundColor Yellow
            }
            elseif ($Text -match "FILTERED") {
                $Status = "FILTERED / UNKNOWN"
                $Details = "No conclusive UDP response; filtering possible."
                Write-Host " FILTERED / UNKNOWN" -ForegroundColor Yellow
            }
            else {
                $Status = "INCONCLUSIVE"
                $Details = "Review PortQry output. UDP may not respond."
                Write-Host " INCONCLUSIVE" -ForegroundColor Yellow
            }
        }
        catch {
            $Status = "ERROR"
            $Details = $_.Exception.Message
            Write-Host " ERROR" -ForegroundColor Red
        }
    }
    else {
        Write-Host " MANUAL CHECK (PortQry not installed)" `
            -ForegroundColor Yellow
    }

    $Results.Add([PSCustomObject]@{
        SourceServer = $env:COMPUTERNAME
        RemoteServer = $RemoteServer
        Protocol     = "UDP"
        Port         = $Port
        Service      = $Item.Service
        Requirement  = "Conditional / verify configuration"
        Status       = $Status
        Details      = $Details
        CheckedAt    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    })
}

# ------------------------------------------------------------
# Export results
# ------------------------------------------------------------
$Results | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " CHECK SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$Results |
    Group-Object -Property Status |
    ForEach-Object {
        Write-Host ("{0,-22}: {1}" -f $_.Name, $_.Count)
    }

Write-Host ""
Write-Host "CSV Report: $OutputCsv" -ForegroundColor Green
Write-Host "Completed : $(Get-Date)"
Write-Host ""
Write-Host "IMPORTANT:"
Write-Host "1. Run this script from the destination to the source."
Write-Host "2. Repeat from the source to the destination."
Write-Host "3. TCP PASS confirms connectivity only, not migration readiness."
Write-Host "4. Review conditional SQL, Plesk, and mail ports."
Write-Host "5. UDP results may be inconclusive; verify firewall rules."
Write-Host "============================================================" -ForegroundColor Cyan

# DadLAN-Diagnostics.ps1
# Contains predefined DadLAN diagnostics definitions.

$script:DadLANDiagnostics = @{
    "System Snapshot" = "REPLACE_WITH_SYSTEM_SNAPSHOT_PKG_ID"
}

function Get-DadLANDiagnosticList {
    return $script:DadLANDiagnostics.Keys | Sort-Object
}

function Get-DadLANDiagnosticPackageId {
    param([string]$ActionName)
    return $script:DadLANDiagnostics[$ActionName]
}

# The actual diagnostic script payload to be manually uploaded to Action1 Software Repository:
<#
[CmdletBinding()]
param()
$results = @{
    Hostname = $env:COMPUTERNAME
    Uptime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    CPU_Model = (Get-CimInstance Win32_Processor).Name
    CPU_Usage = (Get-WmiObject Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    RAM_TotalGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB, 2)
    RAM_FreeGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 2)
    Disk_FreeGB = [math]::Round(((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace) / 1GB, 2)
    OS = (Get-CimInstance Win32_OperatingSystem).Caption
    PythonStatus = if (Get-Command python -ErrorAction SilentlyContinue) { (python --version 2>&1) -join '' } else { "Not Installed" }
    GitStatus = if (Get-Command git -ErrorAction SilentlyContinue) { (git --version 2>&1) -join '' } else { "Not Installed" }
    ForgeGridStatus = if (Get-Service -Name "ForgeGrid*" -ErrorAction SilentlyContinue) { "Service Found" } elseif (Test-Path "C:\dev\GithubActions\ForgeGrid") { "Directory Found" } else { "Not Installed" }
}
$results | ConvertTo-Json
#>

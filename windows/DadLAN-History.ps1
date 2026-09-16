# DadLAN-History.ps1
# Handles local metadata database and activity history

$script:MetaPath = Join-Path -Path $PSScriptRoot -ChildPath "DadLAN-Machines.json"
$script:LogPath = Join-Path -Path $PSScriptRoot -ChildPath "DadLAN-ActivityLog.json"
$script:DadLANMetadata = @{}
$script:DadLANLog = @()

function Import-DadLANHistory {
    if (Test-Path $script:MetaPath) {
        try {
            $json = Get-Content $script:MetaPath -Raw | ConvertFrom-Json
            $script:DadLANMetadata = @{}
            foreach ($item in $json) {
                $script:DadLANMetadata[$item.endpointId] = $item
            }
        } catch { }
    }
    
    if (Test-Path $script:LogPath) {
        try {
            $script:DadLANLog = @(Get-Content $script:LogPath -Raw | ConvertFrom-Json)
        } catch { }
    }
}

function Save-DadLANHistory {
    try {
        $arr = @()
        foreach ($val in $script:DadLANMetadata.Values) { $arr += $val }
        $arr | ConvertTo-Json -Depth 5 | Set-Content $script:MetaPath
        
        # Keep last 1000 logs
        if ($script:DadLANLog.Count -gt 1000) { $script:DadLANLog = $script:DadLANLog[0..999] }
        $script:DadLANLog | ConvertTo-Json -Depth 5 | Set-Content $script:LogPath
    } catch { }
}

function Get-DadLANMetadata {
    param ($ep)
    $id = $ep.id
    if (-not $script:DadLANMetadata.ContainsKey($id)) {
        $name = $ep.name
        $numStr = ""
        $role = "Unknown"
        $prot = $false
        
        if ($name -match "(?i)Laptop\s*#?0?(\d+)") {
            $n = [int]$matches[1]
            $numStr = $n.ToString("00")
            if ($n -eq 1) { $role = "Controller"; $prot = $true }
            elseif ($n -ge 2 -and $n -le 8) { $role = "Worker" }
            elseif ($n -ge 9 -and $n -le 10) { $role = "Legacy Worker" }
        }

        $script:DadLANMetadata[$id] = [PSCustomObject]@{
            laptopNumber = $numStr
            endpointId = $id
            friendlyName = $name
            role = $role
            notes = ""
            protected = $prot
        }
        Save-DadLANHistory
    }
    return $script:DadLANMetadata[$id]
}

function Record-DadLANEvent {
    param($Laptop, $Action, $Status, $Details, $Duration = "")
    $entry = [PSCustomObject]@{
        Time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Laptop = $Laptop
        Action = $Action
        Status = $Status
        Details = $Details
        Duration = $Duration
    }
    $script:DadLANLog = @($entry) + $script:DadLANLog
    Save-DadLANHistory
    return $entry
}

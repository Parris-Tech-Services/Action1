# DadLAN-Control.ps1
# v0.3: Modular Diagnostic Framework

[CmdletBinding()]
param (
    [switch]$TestMode = $true
)

$script:AppVersion = "v0.3"

# Load modules
. (Join-Path $PSScriptRoot "DadLAN-Action1Api.ps1")
. (Join-Path $PSScriptRoot "DadLAN-Diagnostics.ps1")
. (Join-Path $PSScriptRoot "DadLAN-History.ps1")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:EndpointsCache = @()
$script:SelectedEndpointId = $null
$script:globalModVer = "Unknown"
$script:globalOrgName = "None"
$script:globalRefreshTime = "Never"
$script:IsUpdatingGrid = $false

Import-DadLANHistory

# ==============================================================================
# GUI SETUP
# ==============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "DadLAN Command Centre $script:AppVersion" + $(if($TestMode){" [SAFE TEST MODE]"})
$form.Size = New-Object System.Drawing.Size(1366, 768)
$form.MinimumSize = New-Object System.Drawing.Size(1100, 700)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.BackColor = [System.Drawing.Color]::WhiteSmoke

# --- TOP PANEL ---
$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = [System.Windows.Forms.DockStyle]::Top
$panelTop.Height = 100
$panelTop.BackColor = [System.Drawing.Color]::White
$panelTop.Padding = New-Object System.Windows.Forms.Padding(10)
$form.Controls.Add($panelTop)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "DadLAN Command Centre"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(10, 10)
$panelTop.Controls.Add($lblTitle)

$pnlTopRight = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlTopRight.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
$pnlTopRight.Dock = [System.Windows.Forms.DockStyle]::Right
$pnlTopRight.Width = 600
$panelTop.Controls.Add($pnlTopRight)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh"
$btnRefresh.Size = New-Object System.Drawing.Size(120, 35)
$btnRefresh.BackColor = [System.Drawing.Color]::LightGreen
$btnRefresh.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRefresh.Enabled = $false
$pnlTopRight.Controls.Add($btnRefresh)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Connect"
$btnConnect.Size = New-Object System.Drawing.Size(120, 35)
$btnConnect.BackColor = [System.Drawing.Color]::LightSteelBlue
$btnConnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$pnlTopRight.Controls.Add($btnConnect)

$lblStatusText = New-Object System.Windows.Forms.Label
$lblStatusText.Size = New-Object System.Drawing.Size(300, 70)
$lblStatusText.TextAlign = [System.Drawing.ContentAlignment]::TopRight
$lblStatusText.Text = "Action1: Disconnected`nOrg: N/A`nPSAction1: N/A`nRefreshed: Never"
$lblStatusText.Margin = New-Object System.Windows.Forms.Padding(0, 5, 20, 0)
$pnlTopRight.Controls.Add($lblStatusText)

# --- BOTTOM PANEL ---
$panelBottom = New-Object System.Windows.Forms.Panel
$panelBottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
$panelBottom.Height = 200
$panelBottom.BackColor = [System.Drawing.Color]::White
$panelBottom.Padding = New-Object System.Windows.Forms.Padding(5)
$form.Controls.Add($panelBottom)

$lblLogTitle = New-Object System.Windows.Forms.Label
$lblLogTitle.Text = "DadLAN Activity"
$lblLogTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblLogTitle.Dock = [System.Windows.Forms.DockStyle]::Top
$lblLogTitle.Height = 25
$panelBottom.Controls.Add($lblLogTitle)

$lvLog = New-Object System.Windows.Forms.ListView
$lvLog.Dock = [System.Windows.Forms.DockStyle]::Fill
$lvLog.View = [System.Windows.Forms.View]::Details
$lvLog.FullRowSelect = $true
$lvLog.GridLines = $true
$lvLog.Columns.Add("Time", 80) | Out-Null
$lvLog.Columns.Add("Laptop", 120) | Out-Null
$lvLog.Columns.Add("Action", 150) | Out-Null
$lvLog.Columns.Add("Status", 100) | Out-Null
$lvLog.Columns.Add("Duration", 80) | Out-Null
$lvLog.Columns.Add("Details", 800) | Out-Null
$panelBottom.Controls.Add($lvLog)

# --- LEFT PANEL (Filters) ---
$panelLeft = New-Object System.Windows.Forms.Panel
$panelLeft.Dock = [System.Windows.Forms.DockStyle]::Left
$panelLeft.Width = 220
$panelLeft.BackColor = [System.Drawing.Color]::White
$panelLeft.Padding = New-Object System.Windows.Forms.Padding(10)
$form.Controls.Add($panelLeft)

$lstFilters = New-Object System.Windows.Forms.ListBox
$lstFilters.Dock = [System.Windows.Forms.DockStyle]::Fill
$lstFilters.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$lstFilters.Items.AddRange(@("All", "Online", "Offline", "Controller", "Workers", "Legacy", "Problems"))
$lstFilters.SelectedIndex = 0
$panelLeft.Controls.Add($lstFilters)

# --- RIGHT PANEL (Details & Diagnostics) ---
$panelRight = New-Object System.Windows.Forms.Panel
$panelRight.Dock = [System.Windows.Forms.DockStyle]::Right
$panelRight.Width = 360
$panelRight.BackColor = [System.Drawing.Color]::White
$panelRight.Padding = New-Object System.Windows.Forms.Padding(15)
$form.Controls.Add($panelRight)

$lblDetTitle = New-Object System.Windows.Forms.Label
$lblDetTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblDetTitle.Dock = [System.Windows.Forms.DockStyle]::Top
$lblDetTitle.AutoSize = $true
$lblDetTitle.MaximumSize = New-Object System.Drawing.Size(330, 0)
$panelRight.Controls.Add($lblDetTitle)

$lblDetStatus = New-Object System.Windows.Forms.Label
$lblDetStatus.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblDetStatus.Dock = [System.Windows.Forms.DockStyle]::Top
$lblDetStatus.Height = 25
$panelRight.Controls.Add($lblDetStatus)

$lblDetFacts = New-Object System.Windows.Forms.Label
$lblDetFacts.Dock = [System.Windows.Forms.DockStyle]::Top
$lblDetFacts.Height = 160
$panelRight.Controls.Add($lblDetFacts)

$rtbDetails = New-Object System.Windows.Forms.RichTextBox
$rtbDetails.Dock = [System.Windows.Forms.DockStyle]::Fill
$rtbDetails.ReadOnly = $true
$rtbDetails.BackColor = [System.Drawing.Color]::WhiteSmoke
$panelRight.Controls.Add($rtbDetails)

$pnlDetActions = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlDetActions.Dock = [System.Windows.Forms.DockStyle]::Bottom
$pnlDetActions.Height = 200
$panelRight.Controls.Add($pnlDetActions)

$lblActionTitle = New-Object System.Windows.Forms.Label
$lblActionTitle.Text = "Safe Remote Diagnostics"
$lblActionTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblActionTitle.AutoSize = $true
$lblActionTitle.Width = 330
$pnlDetActions.Controls.Add($lblActionTitle)

$cmbDiag = New-Object System.Windows.Forms.ComboBox
$cmbDiag.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbDiag.Width = 300
$cmbDiag.Items.AddRange((Get-DadLANDiagnosticList))
if ($cmbDiag.Items.Count -gt 0) { $cmbDiag.SelectedIndex = 0 }
$pnlDetActions.Controls.Add($cmbDiag)

$btnRunDiag = New-Object System.Windows.Forms.Button
$btnRunDiag.Text = "▶ Run Diagnostic"
$btnRunDiag.Size = New-Object System.Drawing.Size(150, 35)
$btnRunDiag.Enabled = $false
$btnRunDiag.BackColor = [System.Drawing.Color]::LightCyan
$pnlDetActions.Controls.Add($btnRunDiag)

if ($TestMode) {
    $lblSafe = New-Object System.Windows.Forms.Label
    $lblSafe.Text = "Safe Test Mode ON (Read-only)"
    $lblSafe.ForeColor = [System.Drawing.Color]::DarkOrange
    $lblSafe.AutoSize = $true
    $pnlDetActions.Controls.Add($lblSafe)
}

# --- CENTER PANEL (Grid) ---
$panelMain = New-Object System.Windows.Forms.Panel
$panelMain.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelMain.Padding = New-Object System.Windows.Forms.Padding(5)
$form.Controls.Add($panelMain)

$dataGridView = New-Object System.Windows.Forms.DataGridView
$dataGridView.Dock = [System.Windows.Forms.DockStyle]::Fill
$dataGridView.ReadOnly = $true
$dataGridView.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dataGridView.AllowUserToAddRows = $false
$dataGridView.BackgroundColor = [System.Drawing.Color]::White
$dataGridView.RowHeadersVisible = $false
$panelMain.Controls.Add($dataGridView)

$panelTop.BringToFront(); $panelBottom.BringToFront(); $panelLeft.BringToFront(); $panelRight.BringToFront(); $panelMain.BringToFront()
$lblDetTitle.BringToFront(); $lblDetStatus.BringToFront(); $lblDetFacts.BringToFront(); $pnlDetActions.BringToFront(); $rtbDetails.BringToFront()

# ==============================================================================
# LOGIC & EVENTS
# ==============================================================================
function GUI-Log {
    param($Laptop, $Action, $Status, $Details, $Duration = "")
    $entry = Record-DadLANEvent -Laptop $Laptop -Action $Action -Status $Status -Details $Details -Duration $Duration
    $item = New-Object System.Windows.Forms.ListViewItem($entry.Time.Substring(11))
    $item.SubItems.Add($entry.Laptop) | Out-Null
    $item.SubItems.Add($entry.Action) | Out-Null
    $item.SubItems.Add($entry.Status) | Out-Null
    $item.SubItems.Add($entry.Duration) | Out-Null
    $item.SubItems.Add($entry.Details) | Out-Null
    
    if ($Status -eq "Error") { $item.ForeColor = [System.Drawing.Color]::Red }
    elseif ($Status -eq "Warning") { $item.ForeColor = [System.Drawing.Color]::DarkOrange }
    elseif ($Status -eq "Success") { $item.ForeColor = [System.Drawing.Color]::DarkGreen }
    
    $lvLog.Items.Insert(0, $item) | Out-Null
    if ($lvLog.Items.Count -gt 200) { $lvLog.Items.RemoveAt(200) }
}

$btnConnect.Add_Click({
    $credForm = New-Object System.Windows.Forms.Form
    $credForm.Text = "Action1 Authentication"
    $credForm.Size = New-Object System.Drawing.Size(400, 220)
    $credForm.StartPosition = "CenterParent"
    
    $lblId = New-Object System.Windows.Forms.Label
    $lblId.Text = "Client ID:"
    $lblId.Location = New-Object System.Drawing.Point(20, 20)
    $lblId.AutoSize = $true
    $credForm.Controls.Add($lblId)
    
    $txtId = New-Object System.Windows.Forms.TextBox
    $txtId.Location = New-Object System.Drawing.Point(20, 40)
    $txtId.Size = New-Object System.Drawing.Size(340, 20)
    $txtId.Text = "api-key-d11f37bc-ada3-4680-82eb-fc96c295ec4969fe44d8-7071-7077-2e1e-13f09fe33ba1@action1.com"
    $credForm.Controls.Add($txtId)
    
    $lblSecret = New-Object System.Windows.Forms.Label
    $lblSecret.Text = "Client Secret:"
    $lblSecret.Location = New-Object System.Drawing.Point(20, 70)
    $lblSecret.AutoSize = $true
    $credForm.Controls.Add($lblSecret)
    
    $txtSecret = New-Object System.Windows.Forms.TextBox
    $txtSecret.Location = New-Object System.Drawing.Point(20, 90)
    $txtSecret.Size = New-Object System.Drawing.Size(340, 20)
    $txtSecret.UseSystemPasswordChar = $true
    $credForm.Controls.Add($txtSecret)
    
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Login"
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOk.Location = New-Object System.Drawing.Point(260, 130)
    $credForm.Controls.Add($btnOk)
    $credForm.AcceptButton = $btnOk

    if ($credForm.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $clientId = $txtId.Text
    $clientSecret = $txtSecret.Text
    $txtSecret.Text = ""

    if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($clientSecret)) {
        [System.Windows.Forms.MessageBox]::Show($form, "Credentials required.")
        return
    }

    $lblStatusText.Text = "Connecting..."
    $form.Refresh()

    try {
        # 1. Action1ApiClient Auth (Memory Only OAuth)
        Connect-DadLANApi -ClientId $clientId -ClientSecret $clientSecret | Out-Null
        GUI-Log "System" "API Client Auth" "Success" "OAuth token secured in memory."

        # 2. PSAction1 Module Auth (For read-only grid integration)
        Import-Module PSAction1 -ErrorAction Stop
        $script:globalModVer = (Get-Module PSAction1).Version.ToString()
        Set-Action1Region -Region Australia -ErrorAction Stop
        Set-Action1Credentials -APIKey $clientId -Secret $clientSecret -ErrorAction Stop
        $clientSecret = $null

        $orgs = Get-Action1Organizations -ErrorAction Stop
        $selectedOrg = $orgs[0]
        Set-Action1DefaultOrg -Org_ID $selectedOrg.Org_ID -ErrorAction Stop
        $script:globalOrgName = $selectedOrg.Org_Name
        
        GUI-Log "System" "PSAction1 Auth" "Success" "Connected to $($selectedOrg.Org_Name)"
        $btnRefresh.Enabled = $true
        $btnRefresh.PerformClick()
    } catch {
        $clientSecret = $null
        GUI-Log "System" "Authentication" "Error" $_.Exception.Message
        $lblStatusText.Text = "Connection Failed"
    }
})

$btnRefresh.Add_Click({
    if ($script:globalOrgName -eq "None") { return }
    $lblStatusText.Text = "Refreshing..."
    $form.Refresh()
    
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $script:EndpointsCache = @(Get-Action1Endpoints -ErrorAction Stop)
        $sw.Stop()
        $script:globalRefreshTime = (Get-Date).ToString("HH:mm:ss")
        GUI-Log "System" "Refresh Grid" "Success" "Fetched $($script:EndpointsCache.Count) endpoints." "$($sw.ElapsedMilliseconds)ms"
    } catch {
        GUI-Log "System" "Refresh Grid" "Error" $_.Exception.Message
        $lblStatusText.Text = "Refresh Failed"
        return
    }

    $dt = New-Object System.Data.DataTable
    $dt.Columns.Add("Health"); $dt.Columns.Add("Num"); $dt.Columns.Add("Name"); $dt.Columns.Add("Role")
    $dt.Columns.Add("Status"); $dt.Columns.Add("OS"); $dt.Columns.Add("ID")

    foreach ($ep in $script:EndpointsCache) {
        $meta = Get-DadLANMetadata $ep
        $health = if ($ep.status -ne "Connected") { "Offline" } else { "Healthy" }
        $row = $dt.NewRow()
        $row["Health"] = if ($health -eq "Healthy") { "OK" } else { "OFFLINE" }
        $row["Num"] = $meta.laptopNumber
        $row["Name"] = $meta.friendlyName
        $row["Role"] = $meta.role
        $row["Status"] = $ep.status
        $row["OS"] = $ep.OS
        $row["ID"] = $ep.id
        $dt.Rows.Add($row)
    }

    $dataGridView.DataSource = $dt
    $dataGridView.Columns["ID"].Visible = $false
    $dataGridView.Columns["Health"].Width = 55
    $dataGridView.Columns["Num"].Width = 45
    $dataGridView.Columns["Name"].AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $dataGridView.Columns["Role"].Width = 100
    
    $lblStatusText.Text = "Action1: Connected`nOrg: $($script:globalOrgName)`nPSAction1: $($script:globalModVer)`nRefreshed: $($script:globalRefreshTime)"
})

$dataGridView.Add_SelectionChanged({
    if ($dataGridView.SelectedRows.Count -eq 1) {
        $id = $dataGridView.SelectedRows[0].Cells["ID"].Value
        $script:SelectedEndpointId = $id
        
        $ep = $script:EndpointsCache | Where-Object id -eq $id
        $meta = Get-DadLANMetadata $ep

        $lblDetTitle.Text = $meta.friendlyName
        if ($meta.protected) {
            $lblDetStatus.Text = "PROTECTED CONTROLLER"
            $lblDetStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        } else {
            $lblDetStatus.Text = "Standard Endpoint"
            $lblDetStatus.ForeColor = [System.Drawing.Color]::Black
        }
        $lblDetFacts.Text = "OS: $($ep.OS)`nIP: $($ep.address)"
        $btnRunDiag.Enabled = $true
    } else {
        $btnRunDiag.Enabled = $false
        $script:SelectedEndpointId = $null
    }
})

$btnRunDiag.Add_Click({
    if (-not $script:SelectedEndpointId) { return }
    $diagName = $cmbDiag.SelectedItem
    $pkgId = Get-DadLANDiagnosticPackageId $diagName
    
    $ep = $script:EndpointsCache | Where-Object id -eq $script:SelectedEndpointId
    $meta = Get-DadLANMetadata $ep

    if ($meta.protected) {
        [System.Windows.Forms.MessageBox]::Show($form, "Cannot run diagnostics on Laptop #$($meta.laptopNumber). This endpoint is PROTECTED.", "Blocked", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    if ($pkgId -match "REPLACE_WITH") {
        [System.Windows.Forms.MessageBox]::Show($form, "You must configure the Action1 Package ID for '$diagName' in DadLAN-Diagnostics.ps1 first.", "Configuration Missing", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $res = [System.Windows.Forms.MessageBox]::Show($form, "Execute '$diagName' on $($ep.name)?", "Confirm", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($res -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    GUI-Log $ep.name "Diag: $diagName" "Running" "Submitting deployment to Action1 API..."
    
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $apiResult = Start-DadLANDiagnostic -EndpointId $ep.id -PackageId $pkgId
        $sw.Stop()
        GUI-Log $ep.name "Diag: $diagName" "Running" "Deployment triggered (Instance: $($apiResult.id)). Waiting for results..." "$($sw.ElapsedMilliseconds)ms"
        $rtbDetails.AppendText("`n[$diagName Triggered - $($apiResult.id)]`nPolling Action1 for results...\n")
        $form.Refresh()

        $isComplete = $false
        $outputLog = ""
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 5
            $status = Get-DadLANDiagnosticResult -InstanceId $apiResult.id
            if ($status -and $status.status -ne "PENDING" -and $status.status -ne "RUNNING") {
                $isComplete = $true
                $outputLog = $status.output
                break
            }
        }
        
        if ($isComplete) {
            GUI-Log $ep.name "Diag: $diagName" "Success" "Execution finished."
            $rtbDetails.AppendText("`n[RESULT]`n$outputLog`n")
        } else {
            GUI-Log $ep.name "Diag: $diagName" "Warning" "Execution timed out or still pending."
            $rtbDetails.AppendText("`n[TIMEOUT] The diagnostic is still running. Check Action1 console.`n")
        }
    } catch {
        GUI-Log $ep.name "Diag: $diagName" "Error" $_.Exception.Message
    }
})

$form.ShowDialog() | Out-Null

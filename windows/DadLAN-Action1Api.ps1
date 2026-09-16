# DadLAN-Action1Api.ps1
# Contains purely documented Action1 REST API logic. No PSAction1 dependencies.

$script:ApiBaseUrl = "https://app.au.action1.com/api/3.0"
$script:ApiToken = $null
$script:ApiOrgId = $null

function Connect-DadLANApi {
    param([string]$ClientId, [string]$ClientSecret)
    
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
    }
    
    $res = Invoke-RestMethod -Uri "$script:ApiBaseUrl/oauth2/token" -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
    if ($res.access_token) {
        $script:ApiToken = $res.access_token
        
        # Get Organization ID
        $orgs = Invoke-DadLANApi -EndpointPath "/organizations"
        if ($orgs.items -and $orgs.items.Count -gt 0) {
            $script:ApiOrgId = $orgs.items[0].id
        } else {
            throw "No organizations found in Action1."
        }
        return $true
    }
    return $false
}

function Invoke-DadLANApi {
    param(
        [string]$EndpointPath,
        [string]$Method = "GET",
        $BodyPayload = $null
    )
    
    if (-not $script:ApiToken) { throw "Action1 API not authenticated." }
    
    $headers = @{
        "Authorization" = "Bearer $($script:ApiToken)"
        "Accept"        = "application/json"
    }

    $splat = @{
        Uri     = "$script:ApiBaseUrl$EndpointPath"
        Method  = $Method
        Headers = $headers
    }

    if ($BodyPayload) {
        $splat.Body = ($BodyPayload | ConvertTo-Json -Compress -Depth 5)
        $headers["Content-Type"] = "application/json"
    }

    return Invoke-RestMethod @splat
}

function Get-DadLANEndpoints {
    # Fetch all endpoints from the organization
    $res = Invoke-DadLANApi -EndpointPath "/endpoints/managed/$script:ApiOrgId"
    return $res.items
}

function Start-DadLANDiagnostic {
    param([string]$EndpointId, [string]$PackageId)
    
    $payload = @{
        type = "Manual"
        endpoints_ids = @($EndpointId)
        parameters = @{}
    }
    
    # Trigger deployment
    $res = Invoke-DadLANApi -EndpointPath "/software-repository/packages/$PackageId/deployment" -Method POST -BodyPayload $payload
    return $res
}

function Get-DadLANDiagnosticResult {
    param([string]$InstanceId)
    # Poll policy instance for results
    $res = Invoke-DadLANApi -EndpointPath "/policies/instances/$script:ApiOrgId/$InstanceId"
    return $res
}

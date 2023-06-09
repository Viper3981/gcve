<#
.SYNOPSIS
Automate authentication to VMware vCenter and VMware NSX in a GCVE private cloud

.DESCRIPTION
Requires properly configured gcloud CLI and adequate Google Cloud IAM permissions

Set the project and zone with:
gcloud config set core/project <project> 
gcloud config set compute/zone <zone>
#>
#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules VMware.Sdk.Nsx.Policy

    
function Test-GcpZoneProject {
    <#
    .SYNOPSIS
    Verify that gcloud configuration is set for subsequent commands to succeed
    #>

    $ZoneSet = $(gcloud config get compute/zone) 
    $ProjectSet = $(gcloud config get core/project)

    if (-not ($ZoneSet -and $ProjectSet)) {
        throw "Location not set. Run 'gcloud config set compute/zone <zone>' to configure."
    }
}

function Connect-NsxServerGcve {
    <#
    .SYNOPSIS
    Run Connect-NsxServer with credentials pulled from GCVE automatically, if possible
    #>
    
    param (
        [Parameter(Mandatory)][string]
        # Name of private cloud
        $PrivateCloud 
    )
    while ($null -eq $Global:defaultNsxConnections) {
        try {
            $cred = Get-GcveNsxCredentials -PrivateCloud $PrivateCloud
            $nsxmanager = (Get-GcveFqdn -PrivateCloud $PrivateCloud).nsx
        }
        catch {
            $cred = Get-Credential
            $nsxmanager = Read-Host -Prompt "NSX Manager hostname or IP" 
        }
        Connect-NsxServer -Server $nsxmanager -Credential $cred | Out-Null
    }
    Write-Host "Connected to $($global:defaultNsxConnections.Name)" -ForegroundColor Green
}

function Connect-VIServerGcve {
    <#
    .SYNOPSIS
    Run Connect-VIServer with credentials pulled from GCVE automatically, if possible
    #>

    param (
        [Parameter(Mandatory)][string]
        # Name of private cloud
        $PrivateCloud 
    )
    while ($null -eq $global:DefaultVIServers) {
        try {
            $cred = Get-GcveVcenterCredentials -PrivateCloud $PrivateCloud
            $vcenter = (Get-GcveFqdn -PrivateCloud $PrivateCloud).vcenter
        }
        catch {
            $cred = Get-Credential
            $vcenter = Read-Host -Prompt "VMware vCenter hostname or IP" 
        }
        Connect-VIServer -Server $vcenter -Credential $cred | Out-Null
    }
    Write-Host "Connected to $($global:DefaultVIServers.Name)" -ForegroundColor Green
}

function Get-GcveNsxCredentials {
    <#
    .SYNOPSIS
    Use gcloud CLI to fetch NSX credentials for a private cloud
    .OUTPUTS
    PSCredential object
    .EXAMPLE
    (Get-GcveNsxCredentials -PrivateCloud orange).Password |
        ConvertFrom-SecureString -AsPlainText
    #>

    param (
        [Parameter(Mandatory)][string]
        # Name of private cloud
        $PrivateCloud 
    )

    Test-GcpZoneProject

    $nsxCredentials = (gcloud vmware private-clouds nsx credentials describe --private-cloud=$PrivateCloud --format=json) | 
    ConvertFrom-Json
    
    $password = ConvertTo-SecureString $nsxCredentials.password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($nsxCredentials.username, $password)
    return $credential
}

function Get-GcveVcenterCredentials {
    <#
    .SYNOPSIS
    Use gcloud CLI to fetch VMware vCenter credentials for a private cloud
    .OUTPUTS
    PSCredential object
    .EXAMPLE
    (Get-GcveVcenterCredentials -PrivateCloud orange).Password |
        ConvertFrom-SecureString -AsPlainText
    #>

    param (
        [Parameter(Mandatory)][string]
        # Name of private cloud
        $PrivateCloud 
    )

    Test-GcpZoneProject

    $vcCredentials = (gcloud vmware private-clouds vcenter credentials describe --private-cloud=$PrivateCloud --format=json) | 
    ConvertFrom-Json
    
    $password = ConvertTo-SecureString $vcCredentials.password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($vcCredentials.username, $password)
    return $credential
}

function Get-GcveFqdn {
    <#
    .SYNOPSIS
    Use gcloud CLI to fetch NSX and vCenter hostnames for a private cloud
    .DESCRIPTION
    Get the FQDN of vCenter and NSX management endpoints (in .gve.goog domain).

    Optionally launch local browser to open URLs as a convenience.
    .OUTPUTS
    Hashtable
    .EXAMPLE
    Get-GcveFqdn -PrivateCloud orange -LaunchVcenter
    Get-GcveFqdn -PrivateCloud orange -LaunchNsx
    .LINK
    Get-GcveNsxCredentials
    Get-GcveVcenterCredentials
    #>

    param (
        [Parameter(Mandatory)][string]
        # Name of Private Cloud
        $PrivateCloud,
        [switch]
        # Open default web browser to vCenter URL
        $LaunchVcenter,
        [switch]
        # Open default web browser to NSX URL
        $LaunchNsx
    )

    Test-GcpZoneProject

    $pc = (gcloud vmware private-clouds describe $PrivateCloud --format=json) | ConvertFrom-Json

    $fqdn = @{"nsx" = $pc.nsx.fqdn; "vcenter" = $pc.vcenter.fqdn }

    if ($LaunchVcenter) { Start-Process "https://$($fqdn.vcenter)/ui/" }
    if ($LaunchNsx) { Start-Process "https://$($fqdn.nsx)" }

    return $fqdn
}


Export-ModuleMember -Function Connect-VIServerGcve,
Connect-NsxServerGcve, 
Get-GcveNsxCredentials,
Get-GcveVcenterCredentials,
Get-GcveFqdn

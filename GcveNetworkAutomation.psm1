<#
.SYNOPSIS
Set up initial NSX configuration on GCVE

.DESCRIPTION
High-level cmdlets to create DHCP service profile, Tier-1 gateway, and network segment

Requires authenticated connection to the NSX manager, run Connect-NsxServer beforehand
#>
#Requires -Modules VMware.Sdk.Nsx.Policy

    
function Get-EdgePath {
    param (
        [string]
        # Name of edge cluster; GCVE default is "edge-cluster"
        $Name = "edge-cluster"
    )
    $edges = Invoke-ListEdgeClustersForEnforcementPoint -SiteId default -EnforcementpointId default
    $edge = $edges.Results | Where-Object { $_.DisplayName -eq $Name }   
    return $edge.Path
}

function Write-ApiErrorMessage {
    $errMsg = ($_.Exception.ErrorContent | ConvertFrom-Json).error_message
    Write-Host "Error: $errMsg" -ForegroundColor Red
}

function New-Tier1 {
    <#
    .SYNOPSIS
    Create a new Tier-1 gateway. Note that GCVE has a default Tier-1, so this is not mandatory.
    #>

    param (
        [Parameter(Mandatory)][string]
        # Display name of new Tier-1 gateway
        $Name,
        [string]
        # Name of existing Tier-0 gateway; GCVE deploys with "Provider-LR" T0 by default
        $TierZero = "Provider-LR"
    )

    $t0 = (Invoke-ListTier0s).Results | Where-Object { $_.DisplayName -eq $TierZero }
    if ((Invoke-ListTier1).Results.DisplayName -contains $Name) {
        Write-Host "Tier-1 '$Name' alreay exists, not creating" -ForegroundColor Blue
    
    }
    elseif ($t0) {
        try {
            $t1 = Initialize-Tier1 -DisplayName $Name -RouteAdvertisementTypes CONNECTED -Tier0Path $t0.Path 
            Invoke-CreateOrReplaceTier1 -Tier1Id $Name -Tier1 $t1 | Out-Null
        } 
        catch {
            Write-ApiErrorMessage 
        }
        $localeService = Initialize-LocaleServices -EdgeClusterPath (Get-EdgePath) -DisplayName default -Id default
        Invoke-PatchTier1LocaleServices -Tier1Id $Name -LocaleServices $localeService -LocaleServicesId default
    }
    else {
        Write-Host "Tier-0 '$TierZero' does not exist, not creating new Tier-1 gateway" -ForegroundColor Red
    }
}

function New-DhcpServer {
    <#
    .SYNOPSIS
    Create a new DHCP server profile
    #>

    param (
        [Parameter(Mandatory)][string]
        # Display name of the new DHCP server
        $Name
    )
    if ((Invoke-ListDhcpServerConfig).Results.DisplayName -contains $Name) {
        Write-Host "DHCP Server '$Name' exists, not creating" -ForegroundColor Blue
    }
    else {
        Write-Host "Creating DHCP Server: $Name" -ForegroundColor Yellow
    
        $newDhcp = Initialize-DhcpServerConfig -EdgeClusterPath (Get-EdgePath) -DisplayName $Name
        Invoke-CreateOrReplaceDhcpServerConfig -DhcpServerConfig $newDhcp -DhcpServerConfigId $Name | Out-Null
        sleep 1
    }
}
function Set-DhcpServerOnTier1 {
    <#
    .SYNOPSIS
    Add an existing DHCP server profile to a Tier-1 gateway
    #>

    param (
        [Parameter(Mandatory)][string]
        # Display name of the new DHCP server
        $Name,
        [string]
        # Name of Tier-1 gateway, if not the default of "Tier1"
        $Tier1Gateway = "Tier1"
    )
    if ((Invoke-ListDhcpServerConfig).Results.DisplayName -notcontains $Name) {
        Write-Host "DHCP Server '$Name' does not exist, cannot add to Tier-1" -ForegroundColor Blue
    }
    elseif ((Invoke-ListTier1).Results.DisplayName -notcontains $Tier1Gateway) {
        Write-Host "Tier-1 '$Tier1Gateway' does not exist, cannot add DHCP server profile" -ForegroundColor Blue
    }
    else {
        $t1Cfg = Initialize-Tier1 -DhcpConfigPaths (Invoke-ReadDhcpServerConfig -DhcpServerConfigId $Name).Path
        try {
            Invoke-PatchTier1 -Tier1Id $Tier1Gateway -Tier1 $t1Cfg
        }
        catch {
            Write-ApiErrorMessage
        }
    }
}

function New-Segment {
    <#
    .SYNOPSIS
    Create new NSX segment for virtual machines
    .DESCRIPTION
    Wrapper for various VMware.Sdk.Nsx.Policy cmdlets to simplify creation of a VMware NSX-T
    network segment on GCVE, including settings required to enable DHCP on the segment.
    .EXAMPLE
    New-Segment -Name "workload-net" -GatewayAddress 10.88.10.1/24 `
    -DhcpRange 10.88.10.100-10.88.10.200 -DnsServers 10.88.0.2, 10.88.1.2 -DomainName multicloud.internal
    .LINK
    Connect-NsxServerGcve
    New-DhcpServer
    Set-DhcpServerOnTier1
    #>

    param(
        [Parameter(ParameterSetName = "static", Mandatory)]
        [Parameter(ParameterSetName = "dhcp", Mandatory)][string]
        # Display name of new segment for virtual machines
        $Name,
        [Parameter(ParameterSetName = "static", Mandatory)]
        [Parameter(ParameterSetName = "dhcp", Mandatory)][string]
        # Desired gateway IP address with subnet mask in CIDR notation
        $GatewayAddress,
        [string]
        # Tier-1 gateway for this segment, default on GCVE is named "Tier1"
        $Tier1Gateway = "Tier1",
        [Parameter(ParameterSetName = "dhcp", Mandatory)][string]
        # Range (beginning-end) of IP addresses to be used for DHCP clients
        $DhcpRange,
        [Parameter(ParameterSetName = "dhcp")][string[]]
        # List of DNS servers to be used for DHCP clients
        $DnsServers = @("1.1.1.1", "8.8.8.8"),
        [Parameter(ParameterSetName = "dhcp", Mandatory)][string]
        # Domain name associated with segment - will be sent to DHCP clients
        $DomainName,
        [Parameter(ParameterSetName = "dhcp")][int]
        # DHCP lease time
        $LeaseTime = 86400
    )
    if ((Invoke-ListAllInfraSegments).Results.DisplayName -contains $Name) {
        Write-Host "Segment $Name exists, not creating" -ForegroundColor Blue
    }
    elseif ((Invoke-ListTier1).Results.DisplayName -notcontains $Tier1Gateway) {
        Write-Host "Tier-1 '$Tier1Gateway' does not exist, cannot create segment" -ForegroundColor Red
    }
    else {
        Write-Host "Creating Segment: $Name" -ForegroundColor Yellow
        $transportZones = Invoke-ListTransportZonesForEnforcementPoint -EnforcementpointId "default" -SiteId "default" 
        $tz = $transportZones.Results | Where-Object { $_.DisplayName -eq "TZ-OVERLAY" }# | Select-Object -First 1 
        $t1 = Invoke-ReadTier1 -Tier1Id $Tier1Gateway
        if ($DhcpRange) {
            $dhcpConfig = Initialize-SegmentDhcpConfig -DnsServers $DnsServers -ResourceType SegmentDhcpV4Config `
                -LeaseTime $LeaseTime 
            $subnet = Initialize-SegmentSubnet -DhcpRanges $DhcpRange -GatewayAddress $GatewayAddress `
                -DhcpConfig $dhcpConfig
        }
        else {
            $subnet = Initialize-SegmentSubnet -GatewayAddress $GatewayAddress
        }
        $segment = Initialize-Segment -DisplayName $Name -TransportZonePath $tz.Path -Subnets $subnet `
            -ConnectivityPath $t1.Path -DomainName $DomainName -Description "Created with PowerCLI"
        try {
            $res = Invoke-CreateOrReplaceInfraSegment -Segment $segment -SegmentId $Name
            Write-Host "Created $Name, network: $($res.Subnets[0].Network)" -ForegroundColor Blue
        }
        catch {
            Write-ApiErrorMessage
        }
    }
}

function Get-Segments {
    <#
    .SYNOPSIS
    Convenience wrapper for Invoke-ListAllInfraSegments
    .LINK
    Invoke-ListAllInfraSegments
    #>

    (Invoke-ListAllInfraSegments).Results.DisplayName

}


Export-ModuleMember -Function New-Segment,
New-Tier1,
New-DhcpServer,
Set-DhcpServerOnTier1,
Get-Segments

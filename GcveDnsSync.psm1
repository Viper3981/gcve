#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules GoogleCloud

function Sync-DnsRecordsFromVm {
    <#
    .SYNOPSIS
    Accepts list of VMware VM objects (from Get-VM) and creates forward and reverse
    DNS zone records with corresponding guest OS hostname and IP address, as reported 
    by VMware Tools.

    .DESCRIPTION
    Requires properly configured gcloud CLI and adequate Google Cloud IAM permissions

    .INPUTS
    VMware VM object(s) output from Get-VM 

    .EXAMPLE
    Get-VM -Name web* | Sync-DnsRecordsFromVm -DomainName multicloud.internal `
        -ReverseDomainName 88.10.in-addr.arpa -ShowDetails -DryRun

    .EXAMPLE
    Sync-DnsRecordsFromVm -VMs (Get-VM ubun*) -DomainName multicloud.internal `
        -ReverseDomainName 88.10.in-addr.arpa.

    .LINK
    https://github.com/ericgray/gcve-automation
    
    .LINK
    Get-GcdResourceRecordSet
    Get-GcdManagedZone
    #>


    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]
        $VMs,
        [Parameter(Mandatory)][string]
        # DNS domain name to update, in dotted format
        $DomainName,
        [Parameter(Mandatory)][string]
        # Reverse DNS domain name (ending in .in-addr.arpa.)
        $ReverseDomainName,
        [int]
        # Time to live, in seconds (default 301)
        $Ttl = 301,
        [switch]
        # Only remove records that match VMs, do not create
        $PurgeOnly,
        [switch]
        # Display extra info about the changes to add and remove
        $ShowDetails,
        [switch]
        # Test run without removing or creating any records
        $DryRun
    )

    begin {
        $vmList = @()
    }
  
    process {
        # loop over incoming pipeline and add each item to list
        # only match ipv4 addresses that contain a "." - not ipv6
        if ($VMs.Guest.ExtensionData.IpAddress -match "\.") {
            $vmList += $VMs
        }
        else {
            Write-Host "No IP address for $($VMs), skipping" -ForegroundColor Red 
        }
    }

    end {
        Write-Host "Processing DNS sync for $($vmList.Count) VMs:" -ForegroundColor Blue
        $vmList | ForEach-Object { Write-Host $_.Name -ForegroundColor Yellow }

        if ($DomainName[-1] -ne ".") { $DomainName += "." }  # ensure the domain ends in dot
        if ($ReverseDomainName[-1] -ne ".") { $ReverseDomainName += "." }  

        $allZones = Get-GcdManagedZone
        $managedZone = $allZones | Where-Object { $_.DnsName -eq $DomainName }
        $managedReverse = $allZones | Where-Object { $_.DnsName -eq $ReverseDomainName } 

        if (-not ($managedZone)) {
            throw "Managed zone name for $DomainName not found!"
        } 
        if (-not ($managedReverse)) {
            throw "Managed zone name for $ReverseDomainName not found!"
        }

        $recordSet = @()
        $reverseSet = @()
        foreach ($vm in $vmList) {
            # guest OS may report FQDN or just short hostname, so remove domain name if it is present
            $hostname = $vm.Guest.ExtensionData.HostName.split(".")[0] + "." + $DomainName
            $ipAddress = $vm.Guest.ExtensionData.IpAddress
            $reverseName = Get-ReverseName -IpAddress $ipAddress

            $recordSet += New-GcdResourceRecordSet -Name $hostname -Rrdata $ipAddress -Type A -Ttl $Ttl
            $reverseSet += New-GcdResourceRecordSet -Name $reverseName -Rrdata $hostname -Type PTR -Ttl $Ttl
        }

        $existingRecords = Get-GcdResourceRecordSet -Zone $managedZone.Name  -Filter A
        $removeRecords = Get-RemoveSet -RecordsToAdd $recordSet -ExistingRecords $existingRecords 

        $existingReverse = Get-GcdResourceRecordSet -Zone $managedReverse.Name -Filter PTR
        $removeReverse = Get-RemoveSet -RecordsToAdd $reverseSet -ExistingRecords $existingReverse

        if ($ShowDetails) {
            if ($PurgeOnly) {
                Write-Host "PurgeOnly selected - nothing will be added" -ForegroundColor Blue
            }
            Write-Host "Records to add:" -ForegroundColor Yellow
            $recordSet
            Write-Host "Reverse records to add:" -ForegroundColor Yellow
            $reverseSet
            Write-Host "Records to remove so they can be replaced:" -ForegroundColor Yellow
            $removeRecords
            Write-Host "Reverse records to remove so they can be replaced:" -ForegroundColor Yellow
            $removeReverse
        }
    
        Write-Host "Attempting to make changes (forward / reverse)..." -ForegroundColor Blue

        if ($DryRun) {
            Write-Host "Dry run selected, not making changes!" -ForegroundColor Magenta
            Write-Host "Records to add: $($recordSet.Count) / $($reverseSet.Count)" -NoNewline -ForegroundColor Yellow
            Write-Host " | $($removeRecords.Count) / $($removeReverse.Count) are updates." -ForegroundColor Yellow
        }
        elseif ($PurgeOnly) {
            Write-Host "Number of deletions: $($removeRecords.Count) / $($removeReverse.Count)"
            Add-GcdChange -Zone $managedZone.Name -Remove $removeRecords
            Add-GcdChange -Zone $managedReverse.Name -Remove $removeReverse
        }
        else {
            Write-Host "Records to add: $($recordSet.Count) / $($reverseSet.Count)" -NoNewline -ForegroundColor Yellow
            Write-Host " | $($removeRecords.Count) / $($removeReverse.Count) are updates." -ForegroundColor Yellow
            Add-GcdChange -Zone $managedZone.Name -Add $recordSet -Remove $removeRecords
            Add-GcdChange -Zone $managedReverse.Name -Add $reverseSet -Remove $removeReverse
        }
    }
}

function Get-RemoveSet {
    # return a list of existing records to search for ones that need to be removed and replaced
    param(
        $ExistingRecords,
        $RecordsToAdd
    )
    $removeSet = @()
    foreach ($record in $existingRecords) {
        if ($RecordsToAdd.Name -contains $record.Name) {
            $removeSet += $record
        }
    }

    return @($removeSet)
}

function Get-ReverseName {
    # reverse the octets in an IP address to create a reverse DNS name
    param(
        [string]
        $IpAddress
    )

    $octets = $IpAddress.Split(".")
    [array]::Reverse($octets) 
    return ($octets -join "." ) + ".in-addr.arpa."
}

# helpers for argument completions
Register-ArgumentCompleter -CommandName Sync-DnsRecordsFromVm -ParameterName DomainName -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    (Get-GcdManagedZone).DnsName | Where-Object { ($_ -like "$wordToComplete*") -and ($_ -notmatch "in-addr.arpa") } | ForEach-Object { "$_" }
}

Register-ArgumentCompleter -CommandName Sync-DnsRecordsFromVm -ParameterName ReverseDomainName -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    (Get-GcdManagedZone).DnsName | Where-Object { ($_ -like "$wordToComplete*") -and ($_ -match "in-addr.arpa") } | ForEach-Object { "$_" }
}

Export-ModuleMember -Function Sync-DnsRecordsFromVm

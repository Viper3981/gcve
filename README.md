# Google Cloud VMware Engine (GCVE) Automation Examples

Scripts and examples to automate Google Cloud VMware Engine (GCVE) administration with PowerCLI.

## Overview

These are example scripts that demonstrate how to get started with various GCVE automation tasks. This is provided for convenience and not supported by VMware or Google Cloud. You must make sure you review, and potentially adjust the contents, before attempting to use in your own environment.

## VMware NSX Automation Capabilities

These modules include commands for seting up authenticated connections and creating key network components. Note that GCVE is based on NSX-T, but there is a shift underway to simply call it NSX.

| Command               | Purpose                                                          |
| --------------------- | ---------------------------------------------------------------- |
| Connect-NsxServerGcve | Run Connect-NsxServer with credentials pulled from Google Cloud  |
| Connect-VIServerGcve  | Run Connect-VIServer with credentials pulled from Google Cloud   |
| Get-GcveFqdn          | Get FQDN for VMware vCenter and VMware NSX management interfaces |
| New-DhcpServer        | Create new VMware NSX DHCP server object                         |
| Set-DhcpServerOnTier1 | Attach a DHCP server to a Tier-1 router                          |
| New-Segment           | Create new VMware NSX segment for VMs                            |

For a full list of commands:

```powershell
Get-Command -Module GcveAuthentication
Get-Command -Module GcveNetworkAutomation
```

## Sync VMware vSphere VM IP Addresses to Google Cloud DNS

The `GcveDnsSync.psm1` module has a single command that can add, update, or remove Google Cloud DNS records from forward/reverse zones. Read the module help for more info on parameters or check out this [quick demo](images/sync_dns_demo.gif).

```powershell
Import-Module ./GcveDnsSync.psm1
Get-VM web* | Sync-DnsRecordsFromVm -DomainName multicloud.internal `
-ReverseDomainName 88.10.in-addr.arpa
```

## Sync Google Cloud Storage Bucket to Content Library

The `GcveContentSync.psm1` module has the `Sync-ContentFromBucket` command that copies ISO/OVA images from a Google Cloud Storage bucket to a content library. This works with GCVE private clouds or other VMware vSphere environments. Read the module help for parameter details or [see it in action](images/sync_content_demo.gif).

```powershell
Import-Module ./GcveContentSync.psm1
Sync-ContentFromBucket -BucketName mybucket
```

## Prerequisites

The authentication module leverages the [gcloud CLI](https://cloud.google.com/sdk/docs/install) to authenticate with Google Cloud. This provides for seamless access to your GCVE private cloud management credentials for VMware vCenter and VMware NSX. Ensure `gcloud` is properly [initialized](https://cloud.google.com/sdk/gcloud/reference/init) with your credentials as well as project ID and GCP zone where your private cloud is deployed. For example:

```bash
gcloud config set core/project <project ID>
gcloud config set compute/zone <GCVE zone>
```

If you prefer not to use the authentication provided by the `GcveAuthentication.psm1` module, simply use the standard PowerCLI `Connect-NsxServer` cmdlet.

The PowerShell scripts require VMware PowerCLI, which is a module that can be downloaded automatically, the following commands will get you started:

```powershell
Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted
Install-Module -Name VMware.PowerCLI
```

On Windows, PowerShell [execution policy](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-7.3) may block these samples. To quickly change the policy, run:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
```

These samples were developed using PowerShell 7.3.1 and PowerCLI 12.7, 13.0

To learn more, see the [PowerCLI documentation](https://developer.vmware.com/powercli).

## Authentication and Networking Examples

```powershell
# Import the modules, connect to vCenter using GCVE credentials:
Import-Module ./GcveNetworkAutomation.psm1,./GcveAuthentication.psm1 -Force
Connect-VIServerGcve -PrivateCloud orange

# Then, use PowerCLI cmdlets as usual with vCenter on GCVE:
Get-VM
Get-Datacenter

# Set up an NSX network segment for VMs after initial
# GCVE private cloud deployment (with or without DHCP)
Connect-NsxServerGcve -PrivateCloud orange

New-DhcpServer -Name dhcp0
Set-DhcpServerOnTier1 -Name dhcp0

New-Segment -Name workload8810 -GatewayAddress 10.88.10.1/24 `
    -DhcpRange 10.88.10.100-10.88.10.200 `
    -DnsServers 10.88.0.2,10.88.1.2 `
    -DomainName multicloud.internal

New-Segment -Name workload8811 -GatewayAddress 10.88.11.1/24
```

## Command Help

View the help for any command using standard PowerShell techniques:

```powershell
Get-GcveFqdn -?
Get-Help New-Segment -Full
```

## Demo

![Demo creating an NSX segment](images/gcve_powercli_create_nsxt_segment.gif?raw=true)

## References

[VMware NSX-T Policy Objects](https://github.com/madhukark/powercli126notes)

[MIT License](LICENSE.txt)

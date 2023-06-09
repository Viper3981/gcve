#Requires -Modules GoogleCloud
#Requires -Modules VMware.VimAutomation.Core


function Sync-ContentFromBucket {
    <#
    .SYNOPSIS
    Copy OVA/ISO files from Google Cloud Storage to a VMware Content Library.

    .DESCRIPTION
    Sync the contents of a Google Cloud Storage bucket with a content library,
    either directly or by first downloading locally and then uploading.

    For direct transfer, the bucket access control must be "fine-grained" not
    "uniform." The ACL for each object will automatically be set to allow public
    access (allUsers) during the download, if it does not already.

    When downloading locally prior to upload, bucket can be configured for
    uniform access control and non-public access. There are obvious tradeoffs. 

    Specify an optional -Prefix to limit download to a certain path or individual file.


    The following parameters have automatic tab completion for arguments:

    ContentLibrary
    BucketName
    Prefix

    Requires VMware PowerCLI and Google Cloud PowerShell modules.

    See:
    https://developer.vmware.com/powercli
    https://googlecloudplatform.github.io/google-cloud-powershell/#/google-cloud-storage


    .EXAMPLE
    Sync-ContentFromBucket -BucketName mycontent -Prefix v1/

    Sync-ContentFromBucket -BucketName template-bucket -Prefix win -DownloadLocalFirst

    .LINK
    https://github.com/ericgray/gcve-automation

    .LINK
    Connect-VIServer
    Get-VM -Name myvm | Export-VApp -Destination . -Format Ova
    Get-GcsBucket
    Get-GcsObject
    #>

    param (
        [Parameter(Mandatory)][string]
        # Google Cloud Storage bucket that contains OVA/ISO image files
        $BucketName,
        [Parameter()][string]
        # Process only objects in the bucket that matches this prefix
        $Prefix,
        [bool]
        # Grant read access to allUsers temporarily to allow downloading directly to GCVE
        $EnableAclModification = $true,
        [switch]
        # Even if an object was already publicly accessible, remove allUsers ACL after downloading
        $AlwaysRemoveAcl,
        [switch]
        # For buckets that do not permit public access, download locally then upload to Content Library
        $DownloadLocalFirst,
        [string]
        # Optionally specify a temporary directory for downloading files - default is OS temp directory
        $DownloadDirectory,
        [object]
        # Specify a Content Library - by default a GCVE private cloud has a library named "ContentLibrary"
        $ContentLibrary = (Get-ContentLibrary)[0]
    )

    $clNote = "Copied from Google Cloud Storage bucket '$($BucketName)'"

    if (-not (Test-GcsBucket -Name $BucketName)) {
        throw "Bucket $($BucketName) not found"
    }

    $library = Get-ContentLibrary -Name $ContentLibrary -ErrorAction Stop 
    Write-Host "Using Content Library: $($library.Name)" -ForegroundColor Yellow

    if ($Prefix) {
        $gcObjects = Get-GcsObject -Bucket (Get-GcsBucket -Name $BucketName) -Prefix $Prefix 
    }
    else {
        $gcObjects = Get-GcsObject -Bucket (Get-GcsBucket -Name $BucketName) 
    }

    $gcObjects = $gcObjects | Where-Object { $_.Name -imatch "OVA$|ISO$" } 

    if (-not $gcObjects) {
        throw "No Cloud Storage objects found matching $($BucketName)/$($Prefix)"
    }
    else {
        Write-Host "Copying these objects:" -ForegroundColor Yellow
        foreach ($o in $gcObjects) {
            $size = [Math]::Round($o.Size / 1MB, 0)
            Write-Host "$($size)MB`t$($o.Name)"  -ForegroundColor Blue
        }
    }

    $existingContentItems = (Get-ContentLibraryItem -ContentLibrary $library).Name
    
    foreach ($gcObject in $gcObjects) {
        $objectName = $gcObject.Name
        $fileName = Split-Path $objectName -Leaf
        $fileNameBase = Split-Path $fileName -LeafBase # this will be used for content library item name

        if ($existingContentItems -icontains $fileNameBase) {
            Write-Host "Content Library already contains item named $($fileNameBase), skipping" -ForegroundColor Red
            continue 
        }

        if ($DownloadLocalFirst) {
            if ($DownloadDirectory) {
                $tmpDownloadDir = $DownloadDirectory
            }
            else {
                $tmpDownloadDir = Get-RandomDirectory
            }
            $localFilePath = Join-Path -Path $tmpDownloadDir -ChildPath $fileName

            New-Item -ItemType Directory -Path $tmpDownloadDir -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Downloading $($fileName) from Google Cloud Storage..." -ForegroundColor Yellow
            Write-Update "Starting"
            Read-GcsObject -InputObject $gcObject -OutFile $localFilePath -Force
            Write-Update "Complete"

            Write-Host "Uploading to Content Library..." -ForegroundColor Yellow
            Write-Update "Starting"
            New-ContentLibraryItem -ContentLibrary $library -Name $fileNameBase -Files $localFilePath `
                -Notes $clNote -ErrorAction Continue | Out-Null
            Write-Update "Complete"

            Write-Host "Processed $($fileName), deleting local copy" -ForegroundColor Blue
            Remove-Item -Path $localFilePath | Out-Null  # delete the local temp copy
            Remove-Item -Path $tmpDownloadDir  # clean up the temp dir
        }
        else {
            if (-not ((Get-GcsBucket -Name $BucketName).Acl)) {
                throw "Uniform bucket-level access enabled - cannot modify ACLs for this bucket. Try -DownloadLocalFirst switch."
            }

            $aclCheck = Get-GcsObjectAcl -Bucket $BucketName -ObjectName $objectName | 
            Where-Object { $_.Entity -eq "allUsers" } -ErrorAction SilentlyContinue

            if (-not $aclCheck) {
                $accessWasEnabled = $false # flag to track toggling ACL later
                Write-Host "Object $($objectName) not accessible to 'allUsers'" -ForegroundColor Yellow
                if ($EnableAclModification) {
                    Write-Host "Attempting to add ACL to enable 'allUsers' access" -ForegroundColor Yellow
                    Add-GcsObjectAcl -Bucket $BucketName -ObjectName $objectName -Role Reader -AllUsers | Out-Null
                    $accessWasEnabled = $true
                }
                else {
                    continue 
                }
            }
            else {
                Write-Host "Object $($objectName) already accessible to 'allUsers'" -ForegroundColor Yellow
            }

            # vCenter on GCVE has an HTTPS proxy configured and will not work with this URL:
            # $fullUrl = $gcObject.MediaLink
            # Throws: "Invalid response code: 404, note that HTTP/s proxy is configured for the transfer"
            # however, this works, assuming the pattern is consistent
            $fullUrl = "https://storage.googleapis.com/$($BucketName)/$($objectName)"
            
            Write-Update "Starting"
            New-ContentLibraryItem -ContentLibrary $library -Name $fileNameBase -Uri $fullUrl -FileName $fileName `
                -Notes $clNote -ErrorAction Continue | Out-Null
            Write-Update "Complete" 
            
            if ($accessWasEnabled -or $AlwaysRemoveAcl) {
                Write-Host "Restoring ACL to remove 'allUsers' access" -ForegroundColor Yellow
                Remove-GcsObjectAcl -Bucket $BucketName -ObjectName $objectName -AllUsers | Out-Null
            }
        }
        
    }
}

function Write-Update {
    param($Message)
    Write-Host (Get-Date).ToString("h:mm:ss tt") $Message -ForegroundColor Cyan
}

function Get-RandomDirectory {
    [char[]]$chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
    $tempDir = [IO.Path]::GetTempPath()
    $randomDirName = -join ($chars | Get-Random -Count 16)
    $randomDirPath = Join-Path -Path $tempDir -ChildPath $randomDirName
    return $randomDirPath
}

# below are bonus argument completion helpers for several of the parameters
# see https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/register-argumentcompleter?view=powershell-7.3

Register-ArgumentCompleter -CommandName Sync-ContentFromBucket -ParameterName ContentLibrary -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    (Get-ContentLibrary).Name | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object { "$_" }
}

Register-ArgumentCompleter -CommandName Sync-ContentFromBucket -ParameterName BucketName -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    (Get-GcsBucket).Name | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object { "$_" }
}

Register-ArgumentCompleter -CommandName Sync-ContentFromBucket -ParameterName Prefix -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    # this is based on the above parameter argument
    if ($fakeBoundParameters.ContainsKey('BucketName')) {
        (Get-GcsObject -Bucket $fakeBoundParameters['BucketName'] | ForEach-Object {
            $objectName = $_.Name
            if ($objectName.EndsWith("/ ")) {
                $objectName.TrimEnd("/ ")
            }
            elseif ($objectName -match "OVA$|ISO$") {
                $objectName
            }
        }) | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object { "$_" }
    }
}


Export-ModuleMember -Function Sync-ContentFromBucket

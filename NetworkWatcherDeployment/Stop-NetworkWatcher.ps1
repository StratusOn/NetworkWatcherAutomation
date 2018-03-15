#Requires -Version 5.0
<#
    .DESCRIPTION
    This runbook is intended to stop Azure Network Watcher that is running on a list of VMs . 
    
    This runbook requires MSI to be enabled on an Azure Function using https://github.com/StratusOn/MSI-GetToken-FunctionAppand an MSI URL to be provided.

    .PARAMETER  
    Parameters are read in from Azure Automation variables.  

    Start Azure Network Watcher variables:
    - TargetResourceGroup: The resource group that contains the VMs that need to have Azure Network Watcher started on them.
    - TargetVirtualMachines: The list of VMs in the resource group specified in the TargetResourceGroup variable.
    - TenantId: The tenant id.
    - SubscriptionId: The subscription id.
    - MsiGetDefaultTokenEndpoint: The MSI endpoint URL for retrieving an access token.
#>
workflow Stop-NetworkWatcher {
    function Get-AccessToken {
        param(
            [string] $MsiGetDefaultTokenEndpoint,
            [int] $MaxRetryCount,
            [int] $RetryIntervalInSeconds
        )

        # Get the access token.
        $retry = 0
        $success = $false
        do
        {
            try
            {
                Write-Verbose "Getting Access Token retry #$retry"

                $accessToken = Invoke-WebRequest -Uri $MsiGetDefaultTokenEndpoint -Method GET -UseBasicParsing
                $success = $true
            }
            catch
            {
                $errorMessage = $_.Exception.Message
                $stackTrace = $_.Exception.StackTrace
                Write-Warning "Error getting access token: $errorMessage, stack: $stackTrace."
                $retry++
                if ($retry -lt $MaxRetryCount)
                {
                    Write-Verbose "Sleeeping for $RetryIntervalInSeconds seconds..."
                    Start-Sleep $RetryIntervalInSeconds
                    Write-Verbose "Retrying attempt #$retry"
                }
                else
                {
                    Write-Error $_
                }
            }
        }
        while(!$success)

        $accessToken
    }

    function Authenticate-AccessToken {
        param(
            [string] $AccessToken,
            [string] $SubscriptionId,
            [int] $MaxRetryCount,
            [int] $RetryIntervalInSeconds
        )

        # Use the access token to authenticate.
        $retry = 0
        $success = $false
        do
        {
            try
            {
                Write-Verbose "Logging in retry #$retry"
                $loginResult = Connect-AzureRmAccount -AccessToken "$AccessToken" -AccountId $SubscriptionId
                if ($loginResult.Context.Subscription.Id -eq $SubscriptionId)
                {
                    echo "Logged in successfully."
                    $success = $true
                }
                else 
                {
                    Write-Error "Subscription Id $SubscriptionId was not found in the current context." -ErrorAction Stop
                }

            }
            catch
            {
                $errorMessage = $_.Exception.Message
                $stackTrace = $_.Exception.StackTrace
                $message = "Error logging in: Message: $errorMessage`nStack Trace:`n$stackTrace."
                Write-Warning $message
                $retry++
                if ($retry -lt $MaxRetryCount)
                {
                    Write-Verbose "Sleeeping for $RetryIntervalInSeconds seconds ..."
                    Start-Sleep $RetryIntervalInSeconds
                    Write-Verbose "Retrying attempt #$retry"
                }
                else
                {
                    Write-Error $message
                }
            }
        }
        while(!$success)
    }

    function Stop-NetworkWatcherForVm {
        param($VmName, $ResourceGroupName)
    
        $ErrorActionPreference = 'Stop'

        $retry = 0
        $success = $false
        
        # Reference: https://docs.microsoft.com/en-us/azure/network-watcher/network-watcher-packet-capture-manage-powershell
        $vm = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status -ErrorAction Stop
        if ($vm)
        {
            # Write VM info to Output log.
            #echo "VM properties:"
            #echo "=============="
            #$vm
            #echo "VM Statuses:"
            #echo "============"
            #$vm.Statuses

            # VM is running if Code is 'PowerState/running' (DisplayStatus is 'VM running').
            if (-not ($vm.Statuses[1].Code -like "*running*"))
            {
                $vmStatus = $vm.Statuses[1].DisplayStatus
                $message = "[VM '$VmName']: Skipping VM since it is not in running state (status: $vmStatus)."
                echo $message
                Write-Warning $message
                Return
            }

            # Get the VM properties, including the VM ID.
            $vm = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VmName
            # Check whether the Network Watcher VM extension is installed.
            $extensionName = "AzureNetworkWatcherExtension"
            $vmExtension = Get-AzureRmVMExtension -ResourceGroupName $ResourceGroupName -VMName $VmName -Name $extensionName
            if ($vmExtension -and $vmExtension.ProvisioningState -eq "Succeeded")
            {
                echo "[VM '$VmName']: Found Network Watcher Extension installed on VM."
                $region = $vmExtension.Location
                $nw = Get-AzureRmResource | Where {$_.ResourceType -eq "Microsoft.Network/networkWatchers" -and $_.Location -eq "$region" }
                if ($nw -eq $null)
                {
                    $message = "[VM '$VmName']: Skipping VM since Network Watcher was not found enabled in region '$region'."
                    echo $message
                    Write-Warning $message
                    Return
                }

                echo "[VM '$VmName']: Found Network Watcher enabled for VM in '$region'."
                $networkWatcher = Get-AzureRmNetworkWatcher -Name $nw.Name -ResourceGroupName $nw.ResourceGroupName
                $packetCapture = Get-AzureRmNetworkWatcherPacketCapture -NetworkWatcher $networkWatcher | Where {$_.Target -eq $vm.Id} | Where {$_.PacketCaptureStatus -eq "Running" -or $_.PacketCaptureStatus -eq $null}
                if ($packetCapture -eq $null)
                {
                    $message = "[VM '$VmName']: Could not find a Network Watcher capture in a Running state on VM."
                    echo $message
                    Write-Warning $message
                }
                else
                {
                    $packetCaptureName = $packetCapture.Name
                    $message = "[VM '$VmName']: Found Network Watcher capture '$packetCaptureName' on VM."
                    echo $message

                    Stop-AzureRmNetworkWatcherPacketCapture -NetworkWatcher $networkWatcher -PacketCaptureName "$packetCaptureName"
                    $message = "[VM '$VmName']: Stopped Network Watcher capture '$packetCaptureName' on VM."
                    echo $message
                }
            }
            else
            {
                $message = "[VM '$VmName']: Skipping VM since it does not have the Network Watcher extension and agent installed."
                echo $message
                Write-Warning $message
            }
        }
        else
        {
            $message = "[VM '$VmName']: Could not get information for VM. Make sure the correct VM name is specified in the 'TargetVirtualMachines' variable and that the VM is in the Resource Group specified in the 'TargetResourceGroup' variable."
            echo $message
            throw $message
        }
    }

    #
    # Stop_NetworkWatcher.ps1
    #

    $ErrorActionPreference = 'Stop'

    $scriptPath = ($pwd).path
    #echo "Current Path: $scriptPath"
    #Get-ChildItem Env:

    $currentTime = (Get-Date).ToUniversalTime()
    $maxRetryCount = 5
    $retryIntervalInSeconds = 30

    echo "=============== Runbook started ==============="
    echo "Current UTC time [$($currentTime.ToString("dddd, yyyy MMM dd HH:mm:ss"))]"

    $targetResourceGroup = Get-AutomationVariable -Name 'TargetResourceGroup'
    $targetVirtualMachines = Get-AutomationVariable -Name 'TargetVirtualMachines'
    $tenantId = Get-AutomationVariable -Name 'TenantId'
    $subscriptionId = Get-AutomationVariable -Name 'SubscriptionId'
    $msiGetDefaultTokenEndpoint = Get-AutomationVariable -Name 'MsiGetDefaultTokenEndpoint'
    
    echo "-- Target Resource Groups: $targetResourceGroup"
    echo "-- Target Virtual Machines: $targetVirtualMachines"
    echo "-- Tenant Id: $tenantId"
    echo "-- Subscription Id: $subscriptionId"
    echo "-- MSI Get Default Token Endpoint: $msiGetDefaultTokenEndpoint"

    # Variables sanity checks.
    if ($targetResourceGroup -eq $null -or $targetResourceGroup -eq '')
    {
        $message = "TargetResourceGroup not specified."
        Write-Error $message -ErrorAction Stop
    }

    if ($targetVirtualMachines -eq $null -or $targetVirtualMachines -eq '')
    {
        $message = "TargetVirtualMachines not specified."
        Write-Error $message -ErrorAction Stop
    }

    if ($tenantId -eq $null -or $tenantId -eq '')
    {
        $message = "TenantId not specified."
        Write-Error $message -ErrorAction Stop
    }

    if ($subscriptionId -eq $null -or $subscriptionId -eq '')
    {
        $message = "SubscriptionId not specified."
        Write-Error $message -ErrorAction Stop
    }

    if ($msiGetDefaultTokenEndpoint -eq $null -or $msiGetDefaultTokenEndpoint -eq '')
    {
        $message = "MsiGetDefaultTokenEndpoint not specified."
        Write-Error $message -ErrorAction Stop
    }

    # Get the access token.
    $accessToken = Get-AccessToken -MsiGetDefaultTokenEndpoint $msiGetDefaultTokenEndpoint -MaxRetryCount $maxRetryCount -RetryIntervalInSeconds $retryIntervalInSeconds
    Write-Verbose "Access Token: $accessToken"

    # Use the access token to authenticate.
    Authenticate-AccessToken -AccessToken $accessToken -SubscriptionId $subscriptionId -MaxRetryCount $maxRetryCount -RetryIntervalInSeconds $retryIntervalInSeconds -ErrorAction Stop

    $startTime = Get-Date
    # Stop the packet capture on each VM specified:
    $vmNames = $targetVirtualMachines -split ','

    $errorMessages = ""
    ForEach -Parallel ($vmName in $vmNames)
    {
        try
        {
            Stop-NetworkWatcherForVm -VmName $vmName -ResourceGroupName $targetResourceGroup
        }
        catch
        {
            $errorMessage = $_.Message
            echo "*** Error processing VM '$vmName' ***: $errorMessage"
            $WORKFLOW:errorMessages += "Error [$vmName]: $errorMessage`n"
        }
    }

    $endTime = Get-Date
    echo ("Stopping Network Watcher jobs took {0}." -f ($endTime - $startTime))

    # End of runbook
    echo "=============== Runbook completed ==============="

    if ($errorMessages -ne "")
    {
        Write-Error "Error(s) occurred while stopping network watchers:`n$errorMessages" -ErrorAction Stop
    }
}

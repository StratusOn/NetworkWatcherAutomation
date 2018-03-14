#Requires -Version 5.0
<#
    .DESCRIPTION
    This runbook is intended to start Azure Network Watcher on a list of VMs . 
    
    This runbook requires MSI to be enabled on an Azure Function using https://github.com/StratusOn/MSI-GetToken-FunctionAppand an MSI URL to be provided.

    .PARAMETER  
    Parameters are read in from Azure Automation variables.  

    Start Azure Network Watcher variables:
    - TargetResourceGroup: The resource group that contains the VMs that need to have Azure Network Watcher started on them.
    - TargetVirtualMachines: The list of VMs in the resource group specified in the TargetResourceGroup variable.
    - TenantId: The tenant id.
    - SubscriptionId: The subscription id.
    - MsiGetDefaultTokenEndpoint: The MSI endpoint URL for retrieving an access token.
    - MaxCaptureTimeInMinutes: The maximum time in minutes for a packet capture.
    - NetworkWatcherStorageAccountName: The name of the Azure Storage Account where the Network Watcher packet capture logs will be written.
    - NetworkWatcherStorageAccountResourceGroupName: The name of the Resource Group that contains the Azure Storage Account where the Network Watcher packet capture logs will be written.
    - PacketCaptureFilterProtocol: The protocol of the packet capture filter. This can be either UDP or TCP.
    - PacketCaptureFilterRemoteIpAddress: The remote IP address of the packet capture filter. This can be a single IP address or a range. e.g. 1.1.1.1-255.255.255.255.
    - PacketCaptureFilterRemotePort: The remote port of the packet capture filter. This can be a single number or semi-colon separated port numbers. e.g. 20;80;443.
    - PacketCaptureFilterLocalIpAddress: The local IP address of the packet capture filter. This can be a single IP address or a range. e.g. 1.1.1.1-255.255.255.255.
    - PacketCaptureFilterLocalPort: The local port of the packet capture filter. This can be a single number or a port range. e.g. 1-65535.
#>
workflow Start-NetworkWatcher {
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

    function Start-NetworkWatcherForVm {
        param($VmName, $ResourceGroupName, $NetworkWatcherStorageAccountName, $NetworkWatcherStorageAccountResourceGroupName, $MaxCaptureTimeInMinutes,
              $PacketCaptureFilterProtocol, $PacketCaptureFilterRemoteIpAddress, $PacketCaptureFilterRemotePort, $PacketCaptureFilterLocalIpAddress, $PacketCaptureFilterLocalPort)
    
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
                $message = "[VM '$VmName']: Skipping VM since it is not in running state (status: $vmStatus). Start the VM and then resume this runbook."
                echo $message
                throw $message
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
                    $message = "[VM '$VmName']: Skipping VM since Network Watcher was not found enabled in region '$region'. Enable Network Watcher for the region and then resume this runbook."
                    echo $message
                    throw $message
                }

                echo "[VM '$VmName']: Found Network Watcher enabled for VM in '$region'."
                $networkWatcher = Get-AzureRmNetworkWatcher -Name $nw.Name -ResourceGroupName $nw.ResourceGroupName
                $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $NetworkWatcherStorageAccountResourceGroupName -Name $NetworkWatcherStorageAccountName
                $filter1 = New-AzureRmPacketCaptureFilterConfig -Protocol $PacketCaptureFilterProtocol -RemoteIPAddress "$PacketCaptureFilterRemoteIpAddress" -RemotePort "$PacketCaptureFilterRemotePort" -LocalIPAddress "$PacketCaptureFilterLocalIpAddress" -LocalPort "$PacketCaptureFilterLocalPort"
                $formattedDateTime = Get-Date -format "yyyyMMdd-hhmmss"
                $packetCaptureName = "PacketCapture-$VmName-$formattedDateTime"
                $timeLimitInMinutes = [int]$MaxCaptureTimeInMinutes
                $timeLimitInSeconds = $timeLimitInMinutes*60
                $packetCapture = New-AzureRmNetworkWatcherPacketCapture -NetworkWatcher $networkWatcher -TargetVirtualMachineId $vm.Id -PacketCaptureName $packetCaptureName -StorageAccountId $storageAccount.id -TimeLimitInSeconds $timeLimitInSeconds -Filter $filter1
                if ($packetCapture -eq $null)
                {
                    $message = "[VM '$VmName']: Could not start Network Watcher capture '$packetCaptureName' on VM. If a capture with the same name already exists, delete the capture and resume this runbook."
                    echo $message
                    throw $message
                }
                else
                {
                    $message = "[VM '$VmName']: Started Network Watcher capture '$packetCaptureName' on VM. The capture will stop after $MaxCaptureTimeInMinutes minutes. This runbook can be stopped to end the capture at any time."
                    echo $message

                    #Write-Verbose "[VM '$VmName'] Packet Capture ($packetCaptureName):"
                    #Write-Verbose $packetCapture
                    #$packetCapture = Get-AzureRmNetworkWatcherPacketCapture -NetworkWatcher $networkWatcher -PacketCaptureName $packetCaptureName
                }
            }
            else
            {
                $message = "[VM '$VmName']: Skipping VM since it does not have the Network Watcher extension and agent installed. Install VM extension and then resume this runbook."
                echo $message
                throw $message
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
    # Start_NetworkWatcher.ps1
    #

    $ErrorActionPreference = 'Stop'

    $scriptPath = ($pwd).path
    #echo "Current Path: $scriptPath"
    #Get-ChildItem Env:

    $currentTime = (Get-Date).ToUniversalTime()
    $maxCaptureTimeInMinutesUpperLimit = 300 # No more than 5 hours allowed. If this value is changed to more than 5 hours, Network Watcher will return an error.
    $maxRetryCount = 5
    $retryIntervalInSeconds = 30

    echo "=============== Runbook started ==============="
    echo "Current UTC time [$($currentTime.ToString("dddd, yyyy MMM dd HH:mm:ss"))]"

    $targetResourceGroup = Get-AutomationVariable -Name 'TargetResourceGroup'
    $targetVirtualMachines = Get-AutomationVariable -Name 'TargetVirtualMachines'
    $tenantId = Get-AutomationVariable -Name 'TenantId'
    $subscriptionId = Get-AutomationVariable -Name 'SubscriptionId'
    $msiGetDefaultTokenEndpoint = Get-AutomationVariable -Name 'MsiGetDefaultTokenEndpoint'
    $maxCaptureTimeInMinutes = Get-AutomationVariable -Name 'MaxCaptureTimeInMinutes'
    $networkWatcherStorageAccountName = Get-AutomationVariable -Name 'NetworkWatcherStorageAccountName'
    $networkWatcherStorageAccountResourceGroupName = Get-AutomationVariable -Name 'NetworkWatcherStorageAccountResourceGroupName'
    $packetCaptureFilterProtocol = Get-AutomationVariable -Name 'PacketCaptureFilterProtocol'
    $packetCaptureFilterRemoteIpAddress = Get-AutomationVariable -Name 'PacketCaptureFilterRemoteIpAddress'
    $packetCaptureFilterRemotePort = Get-AutomationVariable -Name 'PacketCaptureFilterRemotePort'
    $packetCaptureFilterLocalIpAddress = Get-AutomationVariable -Name 'PacketCaptureFilterLocalIpAddress'
    $packetCaptureFilterLocalPort = Get-AutomationVariable -Name 'PacketCaptureFilterLocalPort'
    
    echo "-- Target Resource Groups: $targetResourceGroup"
    echo "-- Target Virtual Machines: $targetVirtualMachines"
    echo "-- Tenant Id: $tenantId"
    echo "-- Subscription Id: $subscriptionId"
    echo "-- MSI Get Default Token Endpoint: $msiGetDefaultTokenEndpoint"
    echo "-- Max Capture Time In Minutes: $maxCaptureTimeInMinutes"
    echo "-- Network Watcher Storage Account Name: $networkWatcherStorageAccountName"
    echo "-- Network Watcher Storage Account Resource Group Name: $networkWatcherStorageAccountResourceGroupName"
    echo "-- Network Watcher Filter Protocol: $packetCaptureFilterProtocol"
    echo "-- Network Watcher Filter Remote IP Address: $packetCaptureFilterRemoteIpAddress"
    echo "-- Network Watcher Filter Remote Port: $packetCaptureFilterRemotePort"
    echo "-- Network Watcher Filter Local IP Address: $packetCaptureFilterLocalIpAddress"
    echo "-- Network Watcher Filter Local Port: $packetCaptureFilterLocalPort"

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

    if ($maxCaptureTimeInMinutes -le 0)
    {
        $message = "MaxCaptureTimeInMinutes must be greater than 0 and less or equal to $maxCaptureTimeInMinutesUpperLimit minutes."
        Write-Error $message -ErrorAction Stop
    }
    else
    {
        if ($maxCaptureTimeInMinutes -gt $maxCaptureTimeInMinutesUpperLimit)
        {
            $message = "MaxCaptureTimeInMinutes cannot be greater than $maxCaptureTimeInMinutesUpperLimit minutes. Forcing current value ($maxCaptureTimeInMinutes) to $maxCaptureTimeInMinutesUpperLimit."
            Write-Warning $message
            $maxCaptureTimeInMinutes = $maxCaptureTimeInMinutesUpperLimit
        }
    }

    if ($networkWatcherStorageAccountName -eq $null -or $networkWatcherStorageAccountName -eq '')
    {
        $message = "NetworkWatcherStorageAccountName not specified."
        Write-Error $message -ErrorAction Stop
    }

    if ($networkWatcherStorageAccountResourceGroupName -eq $null -or $networkWatcherStorageAccountResourceGroupName -eq '')
    {
        $message = "NetworkWatcherStorageAccountResourceGroupName not specified."
        Write-Error $message -ErrorAction Stop
    }

    if ($packetCaptureFilterProtocol -eq '')
    {
        $packetCaptureFilterProtocol = "UDP"
        echo "-- Network Watcher Filter Protocol (updated): $packetCaptureFilterProtocol"
    }

    if ($packetCaptureFilterRemoteIpAddress -eq '')
    {
        $packetCaptureFilterRemoteIpAddress = "1.1.1.1-255.255.255.255"
        echo "-- Network Watcher Filter Remote IP Address (updated): $packetCaptureFilterRemoteIpAddress"
    }

    if ($packetCaptureFilterRemotePort -eq '')
    {
        $packetCaptureFilterRemotePort = "1-65535"
        echo "-- Network Watcher Filter Remote Port (updated): $packetCaptureFilterRemotePort"
    }

    if ($packetCaptureFilterLocalIpAddress -eq '')
    {
        $packetCaptureFilterLocalIpAddress = "1.1.1.1-255.255.255.255"
        echo "-- Network Watcher Filter Local IP Address (updated): $packetCaptureFilterLocalIpAddress"
    }

    if ($packetCaptureFilterLocalPort -eq '')
    {
        $packetCaptureFilterLocalPort = "1-65535"
        echo "-- Network Watcher Filter Local Port (updated): $packetCaptureFilterLocalPort"
    }

    # Get the access token.
    $accessToken = Get-AccessToken -MsiGetDefaultTokenEndpoint $msiGetDefaultTokenEndpoint -MaxRetryCount $maxRetryCount -RetryIntervalInSeconds $retryIntervalInSeconds
    Write-Verbose "Access Token: $accessToken"

    # Use the access token to authenticate.
    Authenticate-AccessToken -AccessToken $accessToken -SubscriptionId $subscriptionId -MaxRetryCount $maxRetryCount -RetryIntervalInSeconds $retryIntervalInSeconds -ErrorAction Stop

    $startTime = Get-Date
    # Start a packet capture for each VM specified:
    $vmNames = $targetVirtualMachines -split ','

    $errorMessages = ""
    ForEach -Parallel ($vmName in $vmNames)
    {
        try
        {
            Start-NetworkWatcherForVm -VmName $vmName -ResourceGroupName $targetResourceGroup -NetworkWatcherStorageAccountName $networkWatcherStorageAccountName -NetworkWatcherStorageAccountResourceGroupName $networkWatcherStorageAccountResourceGroupName -MaxCaptureTimeInMinutes $maxCaptureTimeInMinutes `
                                      -PacketCaptureFilterProtocol $packetCaptureFilterProtocol -PacketCaptureFilterRemoteIpAddress $packetCaptureFilterRemoteIpAddress -PacketCaptureFilterRemotePort $packetCaptureFilterRemotePort -PacketCaptureFilterLocalIpAddress $packetCaptureFilterLocalIpAddress -PacketCaptureFilterLocalPort $packetCaptureFilterLocalPort
        }
        catch
        {
            $errorMessage = $_.Message
            echo "*** Error processing VM '$vmName' ***: $errorMessage"
            $WORKFLOW:errorMessages += "Error [$vmName]: $errorMessage`n"
        }
    }

    $endTime = Get-Date
    echo ("Starting Network Watcher jobs took {0}." -f ($endTime - $startTime))

    if ($errorMessages -ne "")
    {
        Write-Error "Error(s) occurred while starting network watchers:`n$errorMessages" -ErrorAction Stop
    }

    # End of runbook
    echo "=============== Runbook completed ==============="
}

Start-Transcript "C:\ArcBox\LogonScript.log"

$ArcBoxDir = "C:\ArcBox"
$vmDir = "C:\ArcBox\Virtual Machines"
$agentScript = "C:\ArcBox\agentScript"
$tempDir = "C:\Temp"

Function Set-VMNetworkConfiguration {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true,
                   Position=1,
                   ParameterSetName='DHCP',
                   ValueFromPipeline=$true)]
        [Parameter(Mandatory=$true,
                   Position=0,
                   ParameterSetName='Static',
                   ValueFromPipeline=$true)]
        [Microsoft.HyperV.PowerShell.VMNetworkAdapter]$NetworkAdapter,

        [Parameter(Mandatory=$true,
                   Position=1,
                   ParameterSetName='Static')]
        [String[]]$IPAddress=@(),

        [Parameter(Mandatory=$false,
                   Position=2,
                   ParameterSetName='Static')]
        [String[]]$Subnet=@(),

        [Parameter(Mandatory=$false,
                   Position=3,
                   ParameterSetName='Static')]
        [String[]]$DefaultGateway = @(),

        [Parameter(Mandatory=$false,
                   Position=4,
                   ParameterSetName='Static')]
        [String[]]$DNSServer = @(),

        [Parameter(Mandatory=$false,
                   Position=0,
                   ParameterSetName='DHCP')]
        [Switch]$Dhcp
    )

    $VM = Get-WmiObject -Namespace 'root\virtualization\v2' -Class 'Msvm_ComputerSystem' | Where-Object { $_.ElementName -eq $NetworkAdapter.VMName } 
    $VMSettings = $vm.GetRelated('Msvm_VirtualSystemSettingData') | Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }    
    $VMNetAdapters = $VMSettings.GetRelated('Msvm_SyntheticEthernetPortSettingData') 

    $NetworkSettings = @()
    foreach ($NetAdapter in $VMNetAdapters) {
        if ($NetAdapter.Address -eq $NetworkAdapter.MacAddress) {
            $NetworkSettings = $NetworkSettings + $NetAdapter.GetRelated("Msvm_GuestNetworkAdapterConfiguration")
        }
    }

    $NetworkSettings[0].IPAddresses = $IPAddress
    $NetworkSettings[0].Subnets = $Subnet
    $NetworkSettings[0].DefaultGateways = $DefaultGateway
    $NetworkSettings[0].DNSServers = $DNSServer
    $NetworkSettings[0].ProtocolIFType = 4096

    if ($dhcp) {
        $NetworkSettings[0].DHCPEnabled = $true
    } else {
        $NetworkSettings[0].DHCPEnabled = $false
    }

    $Service = Get-WmiObject -Class "Msvm_VirtualSystemManagementService" -Namespace "root\virtualization\v2"
    $setIP = $Service.SetGuestNetworkAdapterConfiguration($VM, $NetworkSettings[0].GetText(1))

    if ($setip.ReturnValue -eq 4096) {
        $job=[WMI]$setip.job 

        while ($job.JobState -eq 3 -or $job.JobState -eq 4) {
            Start-Sleep 1
            $job=[WMI]$setip.job
        }

        if ($job.JobState -eq 7) {
            Write-Output "Success"
        }
        else {
            $job.GetError()
        }
    } elseif($setip.ReturnValue -eq 0) {
        Write-Output "Success"
    }
}

# Install and configure DHCP service (used by Hyper-V nested VMs)
Write-Output "Configure DHCP service"
$dnsClient = Get-DnsClient | Where-Object {$_.InterfaceAlias -eq "Ethernet" }
Add-DhcpServerv4Scope -Name "ArcBox" -StartRange 10.10.1.1 -EndRange 10.10.1.254 -SubnetMask 255.0.0.0 -State Active
Add-DhcpServerv4ExclusionRange -ScopeID 10.10.1.0 -StartRange 10.10.1.101 -EndRange 10.10.1.120
Set-DhcpServerv4OptionValue -DnsDomain $dnsClient.ConnectionSpecificSuffix -DnsServer 168.63.129.16
Set-DhcpServerv4OptionValue -OptionID 3 -Value 10.10.1.1 -ScopeID 10.10.1.0
Set-DhcpServerv4Scope -ScopeId 10.10.1.0 -LeaseDuration 1.00:00:00
Set-DhcpServerv4OptionValue -ComputerName localhost -ScopeId 10.10.10.0 -DnsServer 8.8.8.8
Restart-Service dhcpserver

# Create the NAT network
Write-Output "Create internal NAT"
$natName = "InternalNat"
New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix 10.10.0.0/16

# Create an internal switch with NAT
Write-Output "Create internal switch"
$switchName = 'InternalNATSwitch'
New-VMSwitch -Name $switchName -SwitchType Internal
$adapter = Get-NetAdapter | Where-Object { $_.Name -like "*"+$switchName+"*" }

# Create an internal network (gateway first)
Write-Output "Create gateway"
New-NetIPAddress -IPAddress 10.10.1.1 -PrefixLength 24 -InterfaceIndex $adapter.ifIndex

# Enable Enhanced Session Mode on Host
Write-Output "Enable Enhanced Session Mode"
Set-VMHost -EnableEnhancedSessionMode $true

# Downloading and extracting the 3 VMs
Write-Output "Downloading and extracting the 3 VMs. This can take some time, hold tight..."
# Invoke-WebRequest "https://arcinbox.blob.core.windows.net/vhds/ArcBoxUbuntu.zip" -OutFile "C:\Temp\ArcBoxUbuntu.zip"
# Invoke-WebRequest "https://arcinbox.blob.core.windows.net/vhds/MyApp.zip" -OutFile "C:\Temp\MyApp.zip"
# Invoke-WebRequest "https://arcinbox.blob.core.windows.net/vhds/SQL.zip" -OutFile "C:\Temp\SQL.zip"
# Download "Arc in a Box" VMs for Azure Arc enabled servers from blob storage
Write-Output "Download nested VM zip files using AzCopy"
$sourceFolder = 'https://arcinbox.blob.core.windows.net/vhds'
azcopy cp --check-md5 FailIfDifferentOrMissing $sourceFolder/*? $tempDir --recursive
$command = "7z x '$tempDir' -o'$vmDir'"
Invoke-Expression $command

# Create the nested VMs
Write-Output "Create Hyper-V VMs"
New-VM -Name ArcBoxWin -MemoryStartupBytes 12GB -BootDevice VHD -VHDPath "$vmdir\MyApp\Virtual Hard Disks\MyApp.vhdx" -Path $vmdir -Generation 2 -Switch $switchName
Set-VMProcessor -VMName ArcBoxWin -Count 2

New-VM -Name ArcBoxSQL -MemoryStartupBytes 12GB -BootDevice VHD -VHDPath "$vmdir\SQL\Virtual Hard Disks\SQL.vhdx" -Path $vmdir -Generation 2 -Switch $switchName
Set-VMProcessor -VMName ArcBoxSQL -Count 2

New-VM -Name ArcBoxUbuntu -MemoryStartupBytes 12GB -BootDevice VHD -VHDPath "$vmdir\ArcBoxUbuntu\Virtual Hard Disks\ArcBoxUbuntu.vhdx" -Path $vmdir -Generation 2 -Switch $switchName
Set-VMFirmware -VMName ArcBoxUbuntu -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
Set-VMProcessor -VMName ArcBoxUbuntu -Count 2

# We always want the VMs to start with the host and shut down cleanly with the host
Write-Output "Set VM auto start/stop"
Set-VM -Name ArcBoxWin -AutomaticStartAction Start -AutomaticStopAction ShutDown
Set-VM -Name ArcBoxSQL -AutomaticStartAction Start -AutomaticStopAction ShutDown
Set-VM -Name ArcBoxUbuntu -AutomaticStartAction Start -AutomaticStopAction ShutDown

Write-Output "Enabling Guest Integration Service"
Get-VM | Get-VMIntegrationService | ? {-not($_.Enabled)} | Enable-VMIntegrationService -Verbose

# Start all the VMs
Write-Output "Start VMs"
Start-VM -Name ArcBoxWin
Start-VM -Name ArcBoxSQL
Start-VM -Name ArcBoxUbuntu

Start-Sleep -s 20
$username = "Administrator"
$password = "ArcDemo123!!"
$secstr = New-Object -TypeName System.Security.SecureString
$password.ToCharArray() | ForEach-Object {$secstr.AppendChar($_)}
$cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $username, $secstr
Invoke-Command -VMName ArcBoxWin -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $cred
Invoke-Command -VMName ArcBoxSQL -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $cred

Start-Sleep -s 5

# Configure the ArcBox VM to allow the nested VMs onboard as Azure Arc enabled servers
Write-Output "Configure the ArcBox VM to allow the nested VMs onboard as Azure Arc enabled servers"
Set-Service WindowsAzureGuestAgent -StartupType Disabled -Verbose
Stop-Service WindowsAzureGuestAgent -Force -Verbose
New-NetFirewallRule -Name BlockAzureIMDS -DisplayName "Block access to Azure IMDS" -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.254

# Hard-coded username and password for the nested Windows VMs
$nestedWindowsUsername = "Administrator"
$nestedWindowsPassword = "ArcDemo123!!"
# $nestedLinuxUsername = "Administrator"
# $nestedLinuxPassword = "ArcDemo123!!"

# Copying the Azure Arc Connected Agent to nested VMs
Write-Output "Copying the Azure Arc Connected Agent to nested VMs"
(Get-Content -path "C:\ArcBox\installArcAgent.ps1" -Raw) -replace '\$spnClientId',"'$env:spnClientId'" | Set-Content -Path "C:\ArcBox\$agentScript\1.ps1"
(Get-Content -path "C:\ArcBox\$agentScript\1.ps1" -Raw) -replace '\$spnClientSecret',"'$env:spnClientSecret'" | Set-Content -Path "C:\ArcBox\$agentScript\2.ps1"
(Get-Content -path "C:\ArcBox\$agentScript\2.ps1" -Raw) -replace '\$resourceGroup',"'$env:resourceGroup'" | Set-Content -Path "C:\ArcBox\$agentScript\3.ps1"
(Get-Content -path "C:\ArcBox\$agentScript\3.ps1" -Raw) -replace '\$spnTenantId',"'$env:spnTenantId'" | Set-Content -Path "C:\ArcBox\$agentScript\4.ps1"
(Get-Content -path "C:\ArcBox\$agentScript\4.ps1" -Raw) -replace '\$Azurelocation',"'$env:Azurelocation'" | Set-Content -Path "C:\ArcBox\$agentScript\5.ps1"
(Get-Content -path "C:\ArcBox\$agentScript\5.ps1" -Raw) -replace '\$subscriptionId',"'$env:subscriptionId'" | Set-Content -Path "C:\ArcBox\$agentScript\installArcAgentModified.ps1"

Copy-VMFile "ArcBoxWin" -SourcePath "C:\ArcBox\$agentScript\installArcAgentModified.ps1" -DestinationPath C:\Temp\installArcAgent.ps1 -CreateFullPath -FileSource Host

# Onboarding the nested VMs as Azure Arc enabled servers
Write-Output "Onboarding the nested VMs as Azure Arc enabled servers"
$secstr = New-Object -TypeName System.Security.SecureString
$nestedWindowsPassword.ToCharArray() | ForEach-Object {$secstr.AppendChar($_)}
$cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $nestedWindowsUsername, $secstr

Invoke-Command -VMName ArcBoxWin -ScriptBlock { powershell -File C:\Temp\installArcAgent.ps1 } -Credential $cred




# Remove-Item "C:\ArcBox\$agentScript" -Recurse -Force



# Creating Hyper-V Manager desktop shortcut
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk" -Destination "C:\Users\All Users\Desktop" -Force

# Starting Hyper-V Manager
Start-Process -FilePath "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk" -WindowStyle Maximized

# Removing the LogonScript Scheduled Task so it won't run on next reboot
Unregister-ScheduledTask -TaskName "LogonScript" -Confirm:$false

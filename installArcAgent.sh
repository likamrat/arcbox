#!/bin/sh

apt-get update

# Download the installation package
wget https://aka.ms/azcmagent -O ~/install_linux_azcmagent.sh

# Install the hybrid agent
bash ~/install_linux_azcmagent.sh

# Run connect command
azcmagent connect --service-principal-id $spnClientId --service-principal-secret $spnClientSecret --resource-group $resourceGroup --tenant-id $spnTenantId --location $Azurelocation --subscription-id $subscriptionId --resource-name "ArcBoxUbuntu" --cloud "AzureCloud" --tags "Project=jumpstart_azure_arc_servers"

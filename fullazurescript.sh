#!/bin/bash
set -euo pipefail 

echo "Schritt 1: Variablen werden erstellt"
rg=$(az group list --query "[0].name" --output tsv)
dashless_rg=${rg//-/}
storage_name="mystartupstorage$dashless_rg" 
short_storage_name="${storage_name:0:24}"

echo "Schritt 2: Virtuelles Netzwerk myStartuVnet und Subnetz dbSubnet mit entsprechenden Adressbereichen werden erstellt"
az network vnet create \
      --resource-group $rg \
      --name myStartupVNet \
      --address-prefixes 10.0.0.0/16 \
      --subnet-name dbSubnet \
      --subnet-prefixes 10.0.0.0/24 \
      --location westeurope

echo "Schritt 3: Netzwerksicherheitsgruppe dbSubnet-nsg wird erstellt "
az network nsg create --resource-group $rg --name dbSubnet-nsg --location westeurope

echo "Schritt 4: Sicherheitsrichtlinien von dbSubnet-nsg werden mit dbSubnet verknüpft"
az network vnet subnet update \
      --resource-group $rg \
      --vnet-name myStartupVNet \
      --name dbSubnet \
      --network-security-group dbSubnet-nsg 

echo "Schritt 5: Subnetz webappSubnet für Azure App Services (Web Apps) wird erstellt"
az network vnet subnet create \
      --resource-group $rg \
      --vnet-name myStartupVNet \
      --name webappSubnet \
      --address-prefixes 10.0.1.0/24 \
      --delegations Microsoft.Web/serverFarms 

echo "Schritt 6: Neue Regel in Network Security Group (NSG) dbSubnet-nsg wird erstellt"
az network nsg rule create \
      --resource-group $rg \
      --nsg-name dbSubnet-nsg \
      --name Allow-Postgres-From-WebSubnet \
      --priority 100 \
      --source-address-prefixes 10.0.1.0/24 \
      --destination-address-prefixes 10.0.0.0/24 \
      --destination-port-ranges 5432 \
      --protocol Tcp --access Allow 

echo "Schritt 7: Azure PostgreSQL Flexible Server wird erstellt"
subnet_id=$(az network vnet subnet show --resource-group $rg --vnet-name myStartupVNet --name dbSubnet --query "id" --output tsv) 

az postgres flexible-server create \
   --resource-group $rg \
   --name "mypgserver$dashless_rg" \
   --location westeurope \
   --admin-user pgadmin \
   --admin-password "YourStrongPassword123" \
   --subnet $subnet_id \
   --private-dns-zone mystartup-postgres.private.postgres.database.azure.com \
   --yes 

echo "Schritt 8: Azure Storage-Konto zur dauerhaften Speicherung von Daten wird erstellt"
az storage account create \
   --resource-group $rg \
   --name $short_storage_name \
   --location westeurope \
   --sku Standard_LRS 

echo "Schritt 9: Statische Website-Hosting-Funktion für Azure Storage-Konto wird angelegt. index.html als Startseite der Website festgelegt."
az storage blob service-properties update \
   --account-name $short_storage_name \
   --static-website \
   --index-document index.html 

echo "Schritt 10: Azure Container Registry (ACR) zum Speichern und Verwalten von Docker-Container-Images wird angelegt"
az acr create \
   --resource-group $rg \
   --name "mystartupacr$dashless_rg" \
   --location westeurope \
   --sku Basic \
   --admin-enabled true 

echo "Schritt 11: Azure App Service-Plan zur Definition von Rechenressourcen und Hosting-Umgebung wird angelegt"
az appservice plan create \
   --resource-group $rg \
   --name myAppServicePlan \
   --is-linux \
   --location westeurope \
   --sku S1 

echo "Schritt 12: Auf Linux basierendem App-Service-Plan laufende Azure Web App wird erstellt. Container aus öffentlichem Container wird deployt"
az webapp create \
   --resource-group $rg \
   --plan myAppServicePlan \
   --name "myexpressappbackend$dashless_rg" \
   --deployment-container-image-name mcr.microsoft.com/mcr/hello-world:v1.0

max_attempts=30
attempt=0

while true; do
  state=$(az webapp show --resource-group $rg --name "myexpressappbackend$dashless_rg" --query "state" --output tsv)
  if [ "$state" == "Running" ]; then
    echo "Web App läuft."
    break
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "Timeout beim Erstellen der Webapp erreicht."
    exit 1
  fi
  sleep 5
done

echo "Schritt 13: Netzwerkintegration für die Web App mit dem Subnetz myStartupVNet wird hergestellt"
az webapp vnet-integration add \
   --resource-group $rg \
   --name "myexpressappbackend$dashless_rg" \
   --vnet myStartupVNet \
   --subnet webappSubnet 

echo "Schritt 14: Aller ausgehender Netzwerkverkehr für die Azure Web App wird über das integrierte virtuelle Netzwerk geleitet"
az webapp config set \
   --resource-group $rg \
   --name "myexpressappbackend$dashless_rg" \
   --generic-configurations '{"vnetRouteAllEnabled": true}'

echo "Schritt 15: Environment Variables für Postgres-Datenbank werden gesetzt"
az webapp config appsettings set \
  --resource-group $rg \
  --name "myexpressappbackend$dashless_rg" \
  --settings \
    DBHOST="mypgserver$dashless_rg.postgres.database.azure.com" \
    DBNAME="postgres" \
    DBUSER="pgadmin" \
    DBPASS="YourStrongPassword123" 

echo "Script erfolgreich ausgeführt"    
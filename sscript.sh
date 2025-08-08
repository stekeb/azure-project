RG=$(az group list --query "[0].name" --output tsv) 


#Schritt 2:
az network vnet create \
      --resource-group $RG \
      --name myStartupVNet \
      --address-prefixes 10.0.0.0/16 \
      --subnet-name dbSubnet \
      --subnet-prefixes 10.0.0.0/24 \
      --location westeurope
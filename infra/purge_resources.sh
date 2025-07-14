#!/bin/bash

echo "Purging Azure resources..."

# Check if user is logged in to Azure
if ! az account show >/dev/null 2>&1; then
  echo "Error: You are not logged in to Azure."
  echo "Please run 'az login' first."
  exit -1
fi

# Show current Azure context
echo "Current Azure context:"
az account show --query "{subscriptionId: id, subscriptionName: name, tenantId: tenantId}" -o table

# Get subscription ID
SUBSCRIPTION_ID=$(az account show --query id --output tsv)

# Look for resource groups that match the pattern
echo "Searching for Agent Workshop resource groups..."

# Find resource groups that start with "rg-agent-workshop"
RESOURCE_GROUPS=$(az group list --query "[?starts_with(name, 'rg-agent-workshop')].name" -o tsv)

if [ -z "$RESOURCE_GROUPS" ]; then
    echo "No Agent Workshop resource groups found."
    echo "Looking for any resource groups containing 'agent'..."
    
    # Broader search for any resource groups containing "agent"
    RESOURCE_GROUPS=$(az group list --query "[?contains(name, 'agent')].name" -o tsv)
    
    if [ -z "$RESOURCE_GROUPS" ]; then
        echo "No resource groups found containing 'agent'."
        echo ""
        echo "You can manually specify a resource group name:"
        echo "Usage: bash purge_resources.sh <resource-group-name>"
        echo ""
        echo "Or list all resource groups to find the correct one:"
        echo "az group list --query '[].name' -o table"
        exit 0
    fi
fi

echo "Found the following resource groups:"
echo "$RESOURCE_GROUPS"

# If a specific resource group was passed as argument
if [ $# -eq 1 ]; then
    RESOURCE_GROUP_NAME="$1"
    echo "Using specified resource group: $RESOURCE_GROUP_NAME"
else
    # If multiple resource groups found, ask user to choose
    if [ $(echo "$RESOURCE_GROUPS" | wc -l) -gt 1 ]; then
        echo ""
        echo "Multiple resource groups found. Please run the script with a specific resource group:"
        echo "bash purge_resources.sh <resource-group-name>"
        echo ""
        echo "Available resource groups:"
        echo "$RESOURCE_GROUPS"
        exit 0
    else
        RESOURCE_GROUP_NAME="$RESOURCE_GROUPS"
    fi
fi

# Confirm deletion
echo ""
echo "⚠️  WARNING: This will permanently delete the following resource group and ALL its contents:"
echo "Resource Group: $RESOURCE_GROUP_NAME"
echo "Subscription: $SUBSCRIPTION_ID"
echo ""

# Show what resources will be deleted
echo "Resources that will be deleted:"
az resource list --resource-group "$RESOURCE_GROUP_NAME" --query "[].{Name:name, Type:type, Location:location}" -o table

echo ""
read -p "Are you sure you want to delete this resource group and all its resources? (yes/no): " -r
echo

if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Deletion cancelled."
    exit 0
fi

# Delete the resource group
echo "Deleting resource group: $RESOURCE_GROUP_NAME"
echo "This may take several minutes..."

if az group delete --name "$RESOURCE_GROUP_NAME" --yes --no-wait; then
    echo "✓ Resource group deletion initiated successfully."
    echo "The deletion is running in the background."
    echo ""
    echo "To check the status:"
    echo "az group show --name '$RESOURCE_GROUP_NAME'"
    echo ""
    echo "The command will return an error when the resource group is fully deleted."
else
    echo "❌ Failed to delete resource group."
    exit 1
fi

# Clean up local files
echo "Cleaning up local files..."

# Remove .env file
ENV_FILE_PATH="../src/python/workshop/.env"
if [ -f "$ENV_FILE_PATH" ]; then
    rm "$ENV_FILE_PATH"
    echo "✓ Removed $ENV_FILE_PATH"
fi

# Clear C# user secrets
CSHARP_PROJECT_PATH="../src/csharp/workshop/AgentWorkshop.Client/AgentWorkshop.Client.csproj"
if [ -f "$CSHARP_PROJECT_PATH" ]; then
    echo "Clearing C# user secrets..."
    dotnet user-secrets clear --project "$CSHARP_PROJECT_PATH" 2>/dev/null
    echo "✓ Cleared C# user secrets"
fi

# Remove any leftover output files
rm -f output.json
rm -f "output.json"

# Purge soft-deleted Cognitive Services accounts
echo "Checking for soft-deleted Cognitive Services accounts..."
LOCATION="eastus"

# List and purge soft-deleted accounts related to this resource group
DELETED_ACCOUNTS=$(az cognitiveservices account list-deleted --query "[?resourceGroup=='$RESOURCE_GROUP_NAME'].name" -o tsv 2>/dev/null)

if [ ! -z "$DELETED_ACCOUNTS" ]; then
    echo "Found soft-deleted Cognitive Services accounts to purge:"
    echo "$DELETED_ACCOUNTS"
    
    for account in $DELETED_ACCOUNTS; do
        echo "Purging soft-deleted account: $account"
        az resource delete --ids "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.CognitiveServices/locations/$LOCATION/resourceGroups/$RESOURCE_GROUP_NAME/deletedAccounts/$account" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "✓ Successfully purged: $account"
        else
            echo "⚠️  Could not purge: $account (may already be purged or require manual deletion)"
        fi
    done
else
    echo "No soft-deleted Cognitive Services accounts found."
fi

echo ""
echo "✅ Purge process completed!"
echo "All Azure resources have been scheduled for deletion."
echo "Soft-deleted resources have been purged."
echo "Local configuration files have been cleaned up."

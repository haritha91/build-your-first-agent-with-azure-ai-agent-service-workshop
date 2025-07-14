#!/bin/bash

echo "Fixing Azure CLI authentication issues..."

# Clear all Azure CLI cache and authentication
echo "1. Clearing Azure CLI cache..."
az account clear

# Clear any cached tokens
echo "2. Clearing cached tokens..."
rm -rf ~/.azure/accessTokens.json 2>/dev/null
rm -rf ~/.azure/azureProfile.json 2>/dev/null

# Log out completely
echo "3. Logging out from Azure CLI..."
az logout 2>/dev/null

echo "4. Authentication cache cleared successfully!"
echo ""
echo "Now please run the following command to re-authenticate:"
echo "az login"
echo ""
echo "After successful login, you can run the deployment script again:"
echo "bash deploy_unix.sh"

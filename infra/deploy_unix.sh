#!/bin/bash

echo "Deploying the Azure resources..."

# Pre-deployment checks
echo "Running pre-deployment checks..."

# Check if user is logged in to Azure
if ! az account show >/dev/null 2>&1; then
  echo "Error: You are not logged in to Azure."
  echo "Please run 'az login' first."
  exit -1
fi

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is not installed or not in PATH."
  echo "jq is required to parse JSON output from Azure CLI."
  exit -1
fi

# Show current Azure context
echo "Current Azure context:"
az account show --query "{subscriptionId: id, subscriptionName: name, tenantId: tenantId}" -o table

# Clean up any existing output files
rm -f output.json

# Define resource group parameters
RG_LOCATION="eastus"
MODEL_NAME="gpt-4o"
MODEL_VERSION="2024-11-20"
AI_PROJECT_FRIENDLY_NAME="Agent Service Workshop"
MODEL_CAPACITY=140

# Deploy the Azure resources and save output to JSON
echo "Starting Azure deployment..."
echo "This may take several minutes..."

if ! az deployment sub create \
  --name "azure-ai-agent-service-lab" \
  --location "$RG_LOCATION" \
  --template-file main.bicep \
  --parameters \
      aiProjectFriendlyName="$AI_PROJECT_FRIENDLY_NAME" \
      modelName="$MODEL_NAME" \
      modelCapacity="$MODEL_CAPACITY" \
      modelVersion="$MODEL_VERSION" \
      location="$RG_LOCATION" > output.json; then
  
  echo "Error: Azure deployment failed."
  echo "Please check the error messages above."
  
  # If output.json exists, try to show error details
  if [ -f output.json ]; then
    echo ""
    echo "Deployment output:"
    cat output.json
  fi
  
  # Clean up
  rm -f output.json
  exit -1
fi

echo "✓ Azure deployment completed successfully!"

# Parse the JSON file manually using jq
if [ ! -f output.json ]; then
  echo "Error: output.json not found."
  echo "This usually means the Azure deployment failed or was interrupted."
  echo "Please check the deployment logs above for any error messages."
  exit -1
fi

# Check if the output.json file is valid JSON
if ! jq empty output.json 2>/dev/null; then
  echo "Error: output.json contains invalid JSON."
  echo "This indicates the Azure deployment failed or was interrupted."
  echo "Here's the content of output.json:"
  cat output.json
  echo ""
  echo "Please check the Azure deployment logs above for error details."
  exit -1
fi

# Check if the deployment was successful
deployment_state=$(jq -r '.properties.provisioningState // "Unknown"' output.json)
if [ "$deployment_state" != "Succeeded" ]; then
  echo "Error: Azure deployment did not succeed."
  echo "Deployment state: $deployment_state"
  echo "Please check the deployment details:"
  jq -r '.properties.error // "No error details available"' output.json
  exit -1
fi

# Extract values with error checking
PROJECTS_ENDPOINT=$(jq -r '.properties.outputs.projectsEndpoint.value // empty' output.json)
RESOURCE_GROUP_NAME=$(jq -r '.properties.outputs.resourceGroupName.value // empty' output.json)
SUBSCRIPTION_ID=$(jq -r '.properties.outputs.subscriptionId.value // empty' output.json)
AI_SERVICE_NAME=$(jq -r '.properties.outputs.aiAccountName.value // empty' output.json)
AI_PROJECT_NAME=$(jq -r '.properties.outputs.aiProjectName.value // empty' output.json)
BING_RESOURCE_NAME="groundingwithbingsearch"

# Validate all required outputs are present
missing_outputs=()
[ -z "$PROJECTS_ENDPOINT" ] && missing_outputs+=("projectsEndpoint")
[ -z "$RESOURCE_GROUP_NAME" ] && missing_outputs+=("resourceGroupName")
[ -z "$SUBSCRIPTION_ID" ] && missing_outputs+=("subscriptionId")
[ -z "$AI_SERVICE_NAME" ] && missing_outputs+=("aiAccountName")
[ -z "$AI_PROJECT_NAME" ] && missing_outputs+=("aiProjectName")

if [ ${#missing_outputs[@]} -ne 0 ]; then
  echo "Error: Missing required deployment outputs: ${missing_outputs[*]}"
  echo "This indicates the Azure deployment did not complete successfully."
  echo ""
  echo "Available outputs in the deployment:"
  jq -r '.properties.outputs // {} | keys[]' output.json 2>/dev/null || echo "No outputs found"
  echo ""
  echo "To resolve this issue:"
  echo "1. Check if all required Azure resources were created"
  echo "2. Verify your Azure subscription has sufficient permissions"
  echo "3. Check for any quota limitations in your subscription"
  echo "4. Review the deployment template (main.bicep) for any issues"
  exit -1
fi

BING_CONNECTION_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.CognitiveServices/accounts/$AI_SERVICE_NAME/projects/$AI_PROJECT_NAME/connections/$BING_RESOURCE_NAME"

echo "✓ Successfully extracted deployment outputs:"
echo "  - Projects Endpoint: $PROJECTS_ENDPOINT"
echo "  - Resource Group: $RESOURCE_GROUP_NAME"
echo "  - Subscription ID: $SUBSCRIPTION_ID"
echo "  - AI Service Name: $AI_SERVICE_NAME"
echo "  - AI Project Name: $AI_PROJECT_NAME"

ENV_FILE_PATH="../src/python/workshop/.env"

# Delete the file if it exists
[ -f "$ENV_FILE_PATH" ] && rm "$ENV_FILE_PATH"


# Write to the .env file
{
  echo "PROJECT_ENDPOINT=$PROJECTS_ENDPOINT"
  echo "AZURE_BING_CONNECTION_ID=$BING_CONNECTION_ID"
  echo "MODEL_DEPLOYMENT_NAME=\"$MODEL_NAME\""
} > "$ENV_FILE_PATH"

CSHARP_PROJECT_PATH="../src/csharp/workshop/AgentWorkshop.Client/AgentWorkshop.Client.csproj"

# Set the user secrets for the C# project
dotnet user-secrets set "ConnectionStrings:AiAgentService" "$PROJECTS_ENDPOINT" --project "$CSHARP_PROJECT_PATH"
dotnet user-secrets set "Azure:ModelName" "$MODEL_NAME" --project "$CSHARP_PROJECT_PATH"
dotnet user-secrets set "Azure:BingConnectionId" "$BING_CONNECTION_ID" --project "$CSHARP_PROJECT_PATH"

# Delete the output.json file
rm -f output.json

# Register the Bing Search resource provider
echo "Attempting to register the Bing Search provider..."

# Function to check provider registration status
check_bing_registration() {
    local provider_state
    provider_state=$(az provider show --namespace 'Microsoft.Bing' --query "registrationState" -o tsv 2>/dev/null)
    echo "$provider_state"
}

# Check if already registered
current_state=$(check_bing_registration)
if [ "$current_state" = "Registered" ]; then
    echo "Bing Search provider is already registered."
else
    echo "Current Bing Search provider state: $current_state"
    echo "Registering Bing Search provider..."
    
    # Attempt to register the provider
    if az provider register --namespace 'Microsoft.Bing' --wait; then
        echo "Bing Search provider registration command completed successfully."
    else
        echo "WARNING: Bing Search provider registration command failed."
        echo "This might be due to insufficient permissions or subscription limitations."
    fi
    
    # Wait and check registration status with retry logic
    echo "Waiting for registration to complete..."
    max_attempts=12
    attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        echo "Checking registration status (attempt $attempt/$max_attempts)..."
        current_state=$(check_bing_registration)
        
        if [ "$current_state" = "Registered" ]; then
            echo "✓ Bing Search provider successfully registered!"
            break
        elif [ "$current_state" = "Registering" ]; then
            echo "Still registering... waiting 15 seconds"
            sleep 15
        else
            echo "Current state: $current_state"
            sleep 10
        fi
        
        attempt=$((attempt + 1))
    done
    
    # Final check
    final_state=$(check_bing_registration)
    if [ "$final_state" != "Registered" ]; then
        echo "⚠️  WARNING: Bing Search provider registration was not successful."
        echo "Final state: $final_state"
        echo ""
        echo "This means you may not be able to complete the Grounding with Bing Search lab."
        echo "Possible reasons:"
        echo "1. Insufficient permissions to register resource providers"
        echo "2. Subscription limitations"
        echo "3. Azure service temporary issues"
        echo ""
        echo "You can try to register it manually later with:"
        echo "az provider register --namespace 'Microsoft.Bing'"
        echo ""
        echo "Or contact your Azure administrator for assistance."
        echo ""
        echo "The deployment will continue, but Bing Search functionality may not work."
    fi
fi

echo "✓ Bing Search provider registration completed successfully!"

echo "Adding Azure AI Developer user role"

# Set Variables
subId=$(az account show --query id --output tsv)
objectId=$(az ad signed-in-user show --query id -o tsv)

az role assignment create --role "f6c7c914-8db3-469d-8ca1-694a8f32e121" \
                          --assignee-object-id "$objectId" \
                          --scope "subscriptions/$subId/resourceGroups/$RESOURCE_GROUP_NAME" \
                          --assignee-principal-type 'User'

# Check if the command failed
if [ $? -ne 0 ]; then
    echo "User role assignment failed."
    exit 1
fi

echo "User role assignment succeeded."
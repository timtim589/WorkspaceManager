################################################################################################################
### Creator: Tim Groothuis
### Date: 2023/06/12
### Version: 0.1
### Description: This script is used to deploy infrastructure to play around with Sentinel's Workspace Manager
###
################################################################################################################

Write-Host "--------------- Starting Script ---------------"

######################### Installing required modules ##################################

Write-Host "This script requires one module: The AZ module."
Write-Host "This script will now check if the required module is installed and if not, install it for you."
$Modules = Get-InstalledModule

if ("Az" -in $Modules.Name){
    Write-Host "Az module is already installed, moving on..."
} else {
    Write-Host "Az module is missing..."
    Write-Host "Attempting to install the Az module..."
    Install-Module Az -Scope CurrentUser
}
Write-Host "Modules installed, moving on!"

###################### Connecting to Azure and the Graph ###############################

if(-not(get-azcontext)){
    Write-Host "No connection to Azure found. The script will now prompt you to connect to Azure."
    Connect-AzAccount
}

###################### Starting the actual deployment ###############################

# Declaring all variables we're going to need during this demo
$TenantID = (Get-AzContext).Tenant.Id
$SubscriptionID = (Get-AzContext).Subscription.Id
$ResourceGroupName = "RSG-WorkSpaceManager-Demo"
$Location = "West Europe"
$MasterSentinelName = "LAW-Sentinel-Master"
$ChildSentinelName = "LAW-Sentinel-Child"
$AnalyticRuleName = "WorkspaceManagerRule"
$WorkspaceConfigurationName = "TurningOn"
$WorkspaceManagerGroupName = "WorkspaceManagerDemo"
$WorkspaceManagerAssignmentName = "WorkspaceManagerDemoAssignment"

### Creating the Resource Group
Write-Host "--- Creating the ResourceGroup ---"
New-AzResourceGroup -Name $ResourceGroupName -Location $Location
Write-Host "--- Finished creating the ResourceGroup ---"

### Creating Master Sentinel
Write-Host "--- Creating the Master Sentinel ---"
$MasterSentinelParameters = @{WorkspaceName=$MasterSentinelName;}
New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile "./Sentinel.template.json" -TemplateParameterObject $MasterSentinelParameters | Out-Null
Write-Host "--- Finished creating the Master Sentinel ---"

### Deploying an Analytic rule to the Sentinel Master
Write-Host "--- Deploying an Analytic rule to the Sentinel Master ---"
$AnalyticRuleParameters = @{WorkspaceName=$MasterSentinelName; AnalyticRuleName=$AnalyticRuleName;}
New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile "./AnalyticRule.template.json" -TemplateParameterObject $AnalyticRuleParameters | Out-Null
Write-Host "--- Finished Deploying an Analytic rule to the Sentinel Master ---"

### Creating Child Sentinel
Write-Host "--- Creating the Child Sentinel ---"
$ChildSentinelParameters = @{WorkspaceName=$ChildSentinelName;}
New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile "./Sentinel.template.json" -TemplateParameterObject $ChildSentinelParameters | Out-Null
Write-Host "--- Finished creating the Child Sentinel ---"

##### Enabling workspace manager via API calls #####

### Checking if the workspace manager setting is enabled
$response = Invoke-AzRest -Method GET -Uri "https://management.azure.com/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$MasterSentinelName/providers/Microsoft.SecurityInsights/workspaceManagerConfigurations?api-version=2023-05-01-preview"
$response = $response.content | ConvertFrom-Json
if($response.value[0].properties.mode -eq "Enabled"){
    Write-host "Enabled"
} else {
    Write-host "EXPECTED: Workspace Manager is not Enabled"
}

### Enabling Workspace Manager
$Body = @"
{
  "properties": {
    "mode": "Enabled"
  }
}
"@
$response = Invoke-AzRest -Method PUT -Payload $Body -Uri "https://management.azure.com/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$MasterSentinelName/providers/Microsoft.SecurityInsights/workspaceManagerConfigurations/$WorkspaceConfigurationName`?api-version=2023-05-01-preview"
$response = $response.content | ConvertFrom-Json
if($response.properties.mode -eq "Enabled"){
    Write-host "Workspace Manager has been Enabled"
} else {
    Write-host "ERROR: Workspace Manager has not been Enabled"
}

##### Joining another workspace as a member workspace #####
### Listing current members, outcome should be empty
$response = Invoke-AzRest -Method GET -Uri "https://management.azure.com/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$MasterSentinelName/providers/Microsoft.SecurityInsights/workspaceManagerMembers/?api-version=2023-05-01-preview" 
$response = $response.content | ConvertFrom-Json
$response.value[0]

### Adding the childworkspace as a member to the master workspace. Note that the documentation mentions the property targetWorkspaceId, but in actuallity the expected property for the API is targetWorkspaceResourceId
$Body = @"
{
  "properties": {
    "targetWorkspaceResourceId": "/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$ChildSentinelName",
    "targetWorkspaceTenantId": "$TenantID"
  }
}
"@
$response = Invoke-AzRest -Method PUT -Payload $Body -Uri "https://management.azure.com/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$MasterSentinelName/providers/Microsoft.SecurityInsights/workspaceManagerMembers/$ChildSentinelName`?api-version=2023-05-01-preview"
$response = $response.content | ConvertFrom-Json
$response.value[0]

##### Creating a Workspace Manager Group #####
### Listing the current groups, outcome should be empty
Invoke-AzRest -Method GET -Uri "https://management.azure.com/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$MasterSentinelName/providers/Microsoft.SecurityInsights/workspaceManagerGroups?api-version=2023-05-01-preview"

### Creating a Workspace Manager Group
$Body = @"
{
  "properties": {
    "description": "A Workspace Manager group created via API",
    "displayName": "$WorkspaceManagerGroupName",
    "memberResourceNames": [
      "$ChildSentinelName"
    ]
  }
}
"@
Invoke-AzRest -Method PUT -Payload $Body -Uri "https://management.azure.com/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$MasterSentinelName/providers/Microsoft.SecurityInsights/workspaceManagerGroups/$WorkspaceManagerGroupName`?api-version=2023-05-01-preview"

##### Assigning the content that needs to be pushed to child workspaces #####
### Listing current assignments, outcome should be empty
Invoke-AzRest -Method GET -Uri "https://management.azure.com/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$MasterSentinelName/providers/Microsoft.SecurityInsights/workspaceManagerAssignments?api-version=2023-05-01-preview"

### Getting the previously deployed Alert rule, because we'll need to supply the ID in the assignment:
# Getting all alert rules inside our master Sentinel
$alertRules = Get-AzSentinelAlertRule -ResourceGroupName $ResourceGroupName -WorkspaceName $MasterSentinelName
# Getting only the Analytic Rule we deployed at the start of this script, and getting the Id of that rule
$ruleId = ($alertRules | where {$_.Name -eq $AnalyticRuleName}).Id

### Creating an assignment
$Body = @"
{
  "properties": {
    "items": [
      {
        "resourceId": "$ruleId"
      }
    ],
    "targetResourceName": "$WorkspaceManagerGroupName"
  }
}
"@
Invoke-AzRest -Method PUT -Payload $Body -Uri "https://management.azure.com/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$MasterSentinelName/providers/Microsoft.SecurityInsights/workspaceManagerAssignments/$WorkspaceManagerAssignmentName`?api-version=2023-05-01-preview"

##### Publishing the content to child workspaces #####
### Getting all assignment jobs (publication pushes), should be empty
Invoke-AzRest -Method GET -Uri "https://management.azure.com/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$MasterSentinelName/providers/Microsoft.SecurityInsights/workspaceManagerAssignments/$WorkspaceManagerAssignmentName/jobs?api-version=2023-05-01-preview"

### Creating an assignment job (AKA, publishing the content)
$AssignmentJob = Invoke-AzRest -Method POST -Uri "https://management.azure.com/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$MasterSentinelName/providers/Microsoft.SecurityInsights/workspaceManagerAssignments/$WorkspaceManagerAssignmentName/jobs?api-version=2023-05-01-preview"
$AssignmentJob = $AssignmentJob.Content | ConvertFrom-Json
$AssignmentJobName = $AssignmentJob.Name # We want to save the name of our job, because we need to reference the name to check the status

# Waiting for 10 seconds before checking if our Assignment job has finished running
Sleep 10

### Checking our Assignment Job Name
$response = Invoke-AzRest -Method GET -Uri "https://management.azure.com/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$MasterSentinelName/providers/Microsoft.SecurityInsights/workspaceManagerAssignments/$WorkspaceManagerAssignmentName/jobs/$AssignmentJobName`?api-version=2023-05-01-preview"
$response = $response.content | ConvertFrom-Json
$response[0].properties.provisioningState

<#
.SYNOPSIS
    Sync-Secrets-MyApp.ps1

.DESCRIPTION
    This script fetches secrets for MyApp from Google Cloud Secret Manager
    and stores them in the .NET User Secrets for the specified project.
    It handles both simple string secrets and JSON-based secrets by 
    recursively setting nested properties.

.NOTES
    Author: [Your Name]
    Date: [Date]
    Version: 1.0

    Dependencies:
    - gcloud CLI installed and authorized (google cloud sdk)
    - dotnet CLI
    - PowerShell (tested with 5.1+ or PowerShell Core 7+)
#>

# ------------------------------
# 1) CONFIGURABLE PARAMETERS
# ------------------------------

# The GCP Project ID that contains the secrets for this app
$ProjectId = "my-gcp-project-id"

# Prefix used in secret names for this app.
# For example, if your secrets are named "MyApp--Logging--LogLevel--Default",
# then $AppPrefix = "MyApp--"
$AppPrefix = "MyApp--"

# Full path to the .csproj of your .NET project.
# The user-secrets set command will target this project specifically.
$ProjectCsprojPath = "C:\Path\To\MyApp\MyApp.csproj"

# ------------------------------
# 2) SET GCLOUD PROJECT
# ------------------------------

Write-Host "Setting gcloud project to $ProjectId..."
gcloud config set project $ProjectId | Out-Null

# ------------------------------
# 3) RETRIEVE SECRET NAMES
# ------------------------------

Write-Host "Retrieving secret names from GCP..."
try {
    # Retrieve all secrets whose names contain $AppPrefix
    $secretNames = gcloud secrets list `
        --format="value(name)" `
        --filter="name:$AppPrefix" `
        --project $ProjectId
    
    # Split the output into an array of lines
    $secretNameList = $secretNames -split "`r`n" | Where-Object { $_ -ne "" }
}
catch {
    Write-Host "ERROR: Failed to list secrets from GCP. Exiting script."
    exit 1
}

if (-not $secretNameList) {
    Write-Host "No secrets found with prefix '$AppPrefix' in project '$ProjectId'."
    Read-Host -Prompt "Press Enter to exit script"
    exit 0
}

Write-Host "Found $($secretNameList.Count) secrets with prefix '$AppPrefix'."

# ------------------------------
# 4) PROCESS EACH SECRET
# ------------------------------

foreach ($secretName in $secretNameList) {
    Write-Host "`nProcessing secret: $secretName"
    
    # ------------------------------
    # a) FETCH SECRET VALUE
    # ------------------------------

    try {
        # Get the latest version of this secret
        $secretValue = gcloud secrets versions access latest `
            --secret=$secretName `
            --project $ProjectId
    }
    catch {
        Write-Host "ERROR: Could not retrieve secret value for '$secretName'. Skipping..."
        continue
    }

    if (-not $secretValue) {
        Write-Host "WARNING: Secret '$secretName' has an empty value. Proceeding..."
    }

    # ------------------------------
    # b) DERIVE .NET CONFIG KEY
    # ------------------------------

    # Remove the app prefix from the secret name (if present) 
    # so that e.g. "MyApp--Logging--LogLevel--Default" -> "Logging--LogLevel--Default"
    $configKey = $secretName
    if ($AppPrefix -and $configKey.StartsWith($AppPrefix)) {
        $configKey = $configKey.Substring($AppPrefix.Length)
    }

    # Replace "--" with ":" so that e.g. "Logging--LogLevel--Default" -> "Logging:LogLevel:Default"
    $configKey = $configKey -replace '--', ':'
    Write-Host "Mapping secret name '$secretName' to .NET config key '$configKey'"

    # ------------------------------
    # c) DETECT IF VALUE IS JSON & HANDLE ACCORDINGLY
    # ------------------------------

    # Trim leading/trailing whitespace
    $trimmedValue = $secretValue.Trim()

    # Check if it's JSON by heuristics: starts with { and ends with }
    if ($trimmedValue.StartsWith('{') -and $trimmedValue.EndsWith('}')) {
        $jsonObject = $null
        try {
            $jsonObject = $trimmedValue | ConvertFrom-Json
        }
        catch {
            Write-Host "WARNING: Secret value for '$secretName' looked like JSON but failed to parse. Treating as a normal string."
        }

        if ($jsonObject -ne $null) {
            # It's valid JSON. Let's store each nested property in user secrets.
            
            # A recursive function to flatten the JSON object into user secrets
            function Set-UserSecretRecursively($obj, $parentKey) {
                foreach ($prop in $obj.PSObject.Properties) {
                    $childKey = if ($parentKey) { "$parentKey:$($prop.Name)" } else { $prop.Name }
                    $val = $prop.Value

                    if ($val -is [PSObject] -or $val -is [hashtable]) {
                        # If the property is another object, recurse deeper
                        Set-UserSecretRecursively $val $childKey
                    }
                    else {
                        # Otherwise, set the property value as a user secret
                        Write-Host "Setting user secret: $childKey = $val"
                        dotnet user-secrets set $childKey "`"$val`"" --project $ProjectCsprojPath
                    }
                }
            }

            Write-Host "Secret value is valid JSON. Parsing and storing each nested field..."
            Set-UserSecretRecursively $jsonObject $configKey

            # Proceed to next secret after handling JSON
            continue
        }
    }

    # ------------------------------
    # d) HANDLE PLAIN STRING SECRETS
    # ------------------------------

    Write-Host "Storing plain text secret for key '$configKey'..."
    dotnet user-secrets set $configKey "`"$secretValue`"" --project $ProjectCsprojPath
}

Write-Host "`nAll secrets processed."

# ------------------------------
# 5) FINAL PROMPT (Prevents auto-close if run by clicking .ps1)
# ------------------------------
Read-Host -Prompt "Press Enter to close this window"

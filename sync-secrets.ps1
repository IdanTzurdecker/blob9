# Configurable parameters
$ProjectId = "my-gcp-project-id"        # GCP Project ID for the application
$AppPrefix = "MyApp--"                 # Prefix used in secret names for this app (including the delimiter)

# Ensure gcloud is authenticated and correct project is set
# (This assumes you've already run gcloud auth login and have access)
gcloud config set project $ProjectId | Out-Null

# Retrieve all secret names for this app
$secretNames = gcloud secrets list --format="value(name)" --filter="name:$AppPrefix" --project $ProjectId
$secretNameList = $secretNames -split "`r`n" | Where-Object { $_ -ne "" }

foreach ($secretName in $secretNameList) {
    # Access the latest version of the secret
    $secretValue = gcloud secrets versions access latest --secret=$secretName --project $ProjectId
    
    # Derive the .NET config key by removing prefix and replacing delimiters with colon
    $configKey = $secretName
    if ($AppPrefix -and $configKey.StartsWith($AppPrefix)) {
        $configKey = $configKey.Substring($AppPrefix.Length)  # drop the "MyApp--" prefix
    }
    $configKey = $configKey -replace '--', ':'  # replace all double-hyphens with colon
    
    # If the value looks like JSON, parse and recurse to set nested keys
    if ($secretValue.Trim().StartsWith('{') -and $secretValue.Trim().EndsWith('}')) {
        Try {
            $jsonObject = $secretValue | ConvertFrom-Json
        } Catch {
            $jsonObject = $null
        }
        if ($jsonObject -ne $null) {
            # Flatten JSON object to user secrets
            function Set-UserSecretRecursively ($obj, $parentKey) {
                foreach ($prop in $obj.PSObject.Properties) {
                    $keyName = if ($parentKey) { "$parentKey:$($prop.Name)" } else { $prop.Name }
                    $val = $prop.Value
                    if ($val -is [PSObject] -or $val -is [hashtable]) {
                        Set-UserSecretRecursively $val $keyName  # recurse nested object
                    }
                    else {
                        # Set the key:value in user secrets
                        dotnet user-secrets set $keyName "`"$val`"" --project "C:\Path\To\MyApp.csproj"
                    }
                }
            }
            Set-UserSecretRecursively $jsonObject $configKey
            continue  # move to next secret after processing JSON
        }
    }
    
    # For non-JSON (plain) secret values, set directly
    dotnet user-secrets set $configKey "`"$secretValue`"" --project "C:\Path\To\MyApp.csproj"
}

# Name: DellWarrantyCheck.ps1
# Description: Will check against Dell's API and present Warranty information on your Dell devices
# Copyright (C) 2024 Action1 Corporation
# Documentation: https://www.action1.com/documentation/data-sources/
# Use Action1 Roadmap system (https://roadmap.action1.com/) to submit feedback or enhancement requests.

# WARNING: Carefully study the provided scripts and components before using them. Test in your non-production lab first.

# LIMITATION OF LIABILITY. IN NO EVENT SHALL ACTION1 OR ITS SUPPLIERS, OR THEIR RESPECTIVE 
# OFFICERS, DIRECTORS, EMPLOYEES, OR AGENTS BE LIABLE WITH RESPECT TO THE WEBSITE OR
# THE COMPONENTS OR THE SERVICES UNDER ANY CONTRACT, NEGLIGENCE, TORT, STRICT 
# LIABILITY OR OTHER LEGAL OR EQUITABLE THEORY (I)FOR ANY AMOUNT IN THE AGGREGATE IN
# EXCESS OF THE GREATER OF FEES PAID BY YOU THEREFOR OR $100; (II) FOR ANY INDIRECT,
# INCIDENTAL, PUNITIVE, OR CONSEQUENTIAL DAMAGES OF ANY KIND WHATSOEVER; (III) FOR
# DATA LOSS OR COST OF PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; OR (IV) FOR ANY
# MATTER BEYOND ACTION1’S REASONABLE CONTROL. SOME STATES DO NOT ALLOW THE
# EXCLUSION OR LIMITATION OF INCIDENTAL OR CONSEQUENTIAL DAMAGES, SO THE ABOVE
# LIMITATIONS AND EXCLUSIONS MAY NOT APPLY TO YOU.

# MAKE SURE TO INSERT DELL API AND SECRET BELOW

# 1/10/2026 - Carter Fifield
# Added Snipe-IT API integration to update purchase date and EOL date from Dell warranty information.
# This script assumes you are using the Dell service tag as the serial in Snipe-IT.
# This script assumes you have made the following custom attributes in your Action1 Dashboard:
# "Warranty Type"
# "Warranty Start Date"
# "Warranty End Date"

# Define the Snipe-IT Bearer token
$SnipeApiToken = "SNIPEAPIKEY"

# Define Snipe-IT API URL
$BaseApiURL = "https://yoursnipeitdomain.com/api/v1/hardware/"

# Create the headers with Authorization
$SnipeHeaders = @{
    Authorization = "Bearer $SnipeApiToken"
    Accept        = "application/json"
}

# Obtain system details
$manufacturer = (Get-CimInstance Win32_ComputerSystem).Manufacturer
$serviceTag = (Get-CimInstance Win32_BIOS).SerialNumber

if ($manufacturer -notlike "*Dell*") {
    Write-Host "This system is not a Dell machine. No warranty data retrieved."
    return
}

# Replace with valid credentials and endpoints as needed
$ClientID = "InsertID"
$ClientSecret = "InsertSecret"
$AuthUrl = "https://apigtwb2c.us.dell.com/auth/oauth/v2/token"
$WarrantyUrl = "https://apigtwb2c.us.dell.com/PROD/sbil/eapi/v5/asset-entitlements?servicetags=$serviceTag"

$result = New-Object System.Collections.ArrayList

try {
    # Obtain OAuth token
    $Body = "client_id=$ClientID&client_secret=$ClientSecret&grant_type=client_credentials"
    $TokenResponse = Invoke-RestMethod -Method POST -Uri $AuthUrl -Body $Body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    $AccessToken = $TokenResponse.access_token
} catch {
    Write-Host "Failed to retrieve OAuth token."
    return
}

$Headers = @{
    Authorization = "Bearer $AccessToken"
    Accept        = "application/json"
}

try {
    # Retrieve warranty data
    $WarrantyResponse = Invoke-RestMethod -Method GET -Uri $WarrantyUrl -Headers $Headers -ErrorAction Stop
} catch {
    Write-Host "Failed to retrieve warranty information."
    return
}

# Ensure the response is an array
if ($WarrantyResponse -isnot [System.Collections.IEnumerable]) {
    $WarrantyResponse = @($WarrantyResponse)
}

# Snipe-IT Asset Lookup
$AssetID = -1

# Get Snipe-IT asset ID from system servicetag
try {
    $LookupApiURL = $BaseApiURL + "byserial/" + $serviceTag
    $IDResponse = Invoke-RestMethod -Method Get -Uri $LookupApiURL -Headers $SnipeHeaders -ContentType "application/json" -ErrorAction Stop
    
} catch {
    Write-Host "Failed to retrieve Snipe-IT API."
    return
}

# Ensure the response is an array
if ($IDResponse -isnot [System.Collections.IEnumerable]) {
    $IDResponse= @($IDResponse)
}

foreach ($Asset in $IDResponse) {
    if ($Asset.invalid -eq $true) {
        # If invalid, we skip this asset
        continue
    }

    $Prop = $Asset.rows
    if ($Prop) {
        foreach ($AssetRow in $Prop) {
            $AssetID = $AssetRow.id
        }
    } else {
        Write-Host "Failed to retrieve Snipe-IT asset ID."
        return
    }
}

# Check if the asset has been found in Snipe-IT
if ($number -eq -1) {
    Write-Host "Failed to find asset in Snipe-IT."
    return
} 

# Dates for Snipe-IT update
$PurchaseDate = ""
$EOLDate = ""

foreach ($Asset in $WarrantyResponse) {
    if ($Asset.invalid -eq $true) {
        # If invalid, we skip this asset
        continue
    }

    $Entitlements = $Asset.entitlements
    if ($Entitlements) {
        foreach ($E in $Entitlements) {
            # Include A1_Key field in the output
            $currentOutput = "" | Select-Object "Service Tag", "Warranty Description", "Start Date", "End Date", "Entitlement Type", A1_Key
            $currentOutput."Service Tag" = $Asset.serviceTag
            $currentOutput."Warranty Description" = $E.serviceLevelDescription
            Action1-Set-CustomAttribute "Warranty Type" $E.serviceLevelDescription;
            
            # Convert to DateTime object
            $StartDateObject = [datetime]::Parse($E.startDate)

            # Format as MM/DD/YYYY
            $StartDateFormatted = $StartDateObject.ToString("MM/dd/yyyy")

            $currentOutput."Start Date" = $StartDateFormatted
            Action1-Set-CustomAttribute "Warranty Start Date" $StartDateFormatted;

            # Convert to DateTime object
            $EndDateObject = [datetime]::Parse($E.endDate)

            # Format as MM/DD/YYYY
            $EndDateFormatted = $EndDateObject.ToString("MM/dd/yyyy")

            $currentOutput."End Date" = $EndDateFormatted
            Action1-Set-CustomAttribute "Warranty End Date" $EndDateFormatted;
            $currentOutput."Entitlement Type" = $E.entitlementType
            # Match A1_Key to the service tag
            $currentOutput.A1_Key = $Asset.serviceTag
            
            $result.Add($currentOutput) | Out-Null

            # Reformat dates for Snipe-IT as YYYY-MM-DD
            $PurchaseDate = $StartDateObject.ToString("yyyy-MM-dd")
            $EOLDate = $EndDateObject.ToString("yyyy-MM-dd")

        }
    } else {
        # If no entitlements, still output a line with A1_Key
        $currentOutput = "" | Select-Object "Service Tag", "Warranty Description", "Start Date", "End Date", "Entitlement Type", A1_Key
        $currentOutput."Service Tag" = $serviceTag
        $currentOutput."Warranty Description" = "No entitlements found"
        $currentOutput."Start Date" = ""
        $currentOutput."End Date" = ""
        $currentOutput."Entitlement Type" = ""
        $currentOutput.A1_Key = $serviceTag
        
        $result.Add($currentOutput) | Out-Null
    }
}

# Check if the dates were updated, if not, don't contact Snipe-IT API
if ([string]::IsNullOrEmpty($PurchaseDate) -or [string]::IsNullOrEmpty($EOLDate)) {
    Write-Host "Unable to determine purchase or EOL date."
} else {
    # Patch Snipe-IT asset by id, add purchase date and eol date
    try {
        $Body = '{"purchase_date": "' + $PurchaseDate + '", "asset_eol_date": "' + $EOLDate + '"}'
        $PatchApiURL = $BaseApiURL + $AssetID
        $UpdateResponse = Invoke-RestMethod -Method Patch -Uri $PatchApiURL -Headers $SnipeHeaders -Body $Body -ContentType "application/json" -ErrorAction Stop
        
    } catch {
        Write-Host "Failed to update Snipe-IT asset."
        return
    }
}

$result
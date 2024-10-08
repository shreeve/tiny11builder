# Enable debugging
#Set-PSDebug -Trace 1

# Check if PowerShell execution is restricted
if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Host "Your current PowerShell Execution Policy is set to Restricted, which prevents scripts from running. Do you want to change it to RemoteSigned? (yes/no)"
    $response = Read-Host
    if ($response -eq 'yes') {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
    } else {
        Write-Host "The script cannot be run without changing the execution policy. Exiting..."
        exit
    }
}

# Check and run the script as admin if required

$adminSID           = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup         = $adminSID.Translate([System.Security.Principal.NTAccount])
$adminRole          = [System.Security.Principal.WindowsBuiltInRole]::Administrator
$myWindowsID        = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = new-object System.Security.Principal.WindowsPrincipal($myWindowsID)

if (!$myWindowsPrincipal.IsInRole($adminRole)) {
    Write-Host "Restarting Tiny11 image creator as admin in a new window, you can close this one."
    $newProcess = new-object System.Diagnostics.ProcessStartInfo "PowerShell";
    $newProcess.Verb = "runas";
    $newProcess.Arguments = $myInvocation.MyCommand.Definition;
    [System.Diagnostics.Process]::Start($newProcess);
    exit
}

# Prepare the window and start logging
$Host.UI.RawUI.WindowTitle = "Tiny11 image creator"
try { Start-Transcript -Path "$PSScriptRoot\tiny11.log" } catch { }

# Let's go...
Clear-Host
Write-Host "`n==[ Tiny11 Image Creator: Release 2024-09-02 ]==================================`n"

# Determine the source
$source = Read-Host "Enter the drive letter for the Windows 11 image"
$source = $source + ":"
Write-Host

# Perform eager download of ISO creation utility, so we don't fail at nearly the last step
$osc = "$PSScriptRoot\oscdimg.exe"
$url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"
if (-not (Test-Path -Path $osc)) {
    Write-Host "Downloading oscdimg.exe"
    Invoke-WebRequest -Uri $url -OutFile $osc
    if (!Test-Path $osc) {
        Write-Error "Failed to download oscdimg.exe."
        exit 1
    }
}

# Determine the target and the WIM file path
$target = $env:SystemDrive
New-Item -ItemType Directory -Force -Path "$target\tiny11\sources" > $null
$wimFilePath = "$target\tiny11\sources\install.wim"

# If needed, extract the WIM file from the highly compressed ESD file
if ((Test-Path "$source\sources\boot.wim") -eq $false -or (Test-Path "$source\sources\install.wim") -eq $false) {
    if ((Test-Path "$source\sources\install.esd") -eq $true) {
        Write-Host "Found install.esd, converting to install.wim"
        dism /English /Get-WimInfo "/wimfile:$source\sources\install.esd"
        $index = Read-Host "Enter the image index"
        Write-Host '`nConverting install.esd to install.wim. This may take a while.'
        dism /Export-Image /SourceImageFile:"$source\sources\install.esd" /SourceIndex:$index /DestinationImageFile:"$wimFilePath" /Compress:max /CheckIntegrity

        # Remove the install.esd file
        Set-ItemProperty -Path "$target\tiny11\sources\install.esd" -Name IsReadOnly -Value $false > $null 2>&1
        Remove-Item "$target\tiny11\sources\install.esd" > $null 2>&1
    } else {
        Write-Host "Can't find Windows installation files at that drive letter"
        Write-Host "Enter the correct CD-ROM drive letter (only the letter)"
        exit
    }
}

# Copy all source files to the target, set the WIM file path
Write-Host "Copying Windows image"
Copy-Item -Path "$source\*" -Destination "$target\tiny11" -Recurse -Force > $null
Start-Sleep -Seconds 2

# Show the image info and ask the user to pick the desired index
Write-Host "`nGetting image information"
dism /English /Get-WimInfo "/wimfile:$wimFilePath"
$index = Read-Host "`nEnter the image index"

# Mount the desired image and index
Write-Host "`nMounting Windows image. This may take a while."
takeown /F "$wimFilePath" > $null
icacls "$wimFilePath" /grant "$($adminGroup.Value):(F)" > $null
try { Set-ItemProperty -Path "$wimFilePath" -Name IsReadOnly -Value $false -ErrorAction Stop } catch { }

# Actually make the files available in the scratch directory
New-Item -ItemType Directory -Force -Path "$target\scratchdir" > $null
dism /English /mount-image "/imagefile:$wimFilePath" "/index:$index" "/mountdir:$target\scratchdir"

# Adjust permissions of RtBackup and WebThreatDefSvc
takeown /f "$target\scratchdir\Windows\System32\LogFiles\WMI\RtBackup" /R /D Y > $null
takeown /f "$target\scratchdir\Windows\System32\WebThreatDefSvc"       /R /D Y > $null
icacls     "$target\scratchdir\Windows\System32\LogFiles\WMI\RtBackup" /grant "$($adminGroup.Value):(F)" /T > $null
icacls     "$target\scratchdir\Windows\System32\WebThreatDefSvc"       /grant "$($adminGroup.Value):(F)" /T > $null

# Determine the architecture
$imageInfo = dism /English /Get-WimInfo "/wimFile:$wimFilePath" "/index:$index"
$lines = $imageInfo -split '\r?\n'
foreach ($line in $lines) {
    if ($line -like '*Architecture : *') {
        $architecture = $line -replace 'Architecture : ',''
        # If the architecture is x64, replace it with amd64
        if ($architecture -eq 'x64') {
            $architecture = 'amd64'
        }
        Write-Host "`nArchitecture: $architecture"
        break
    }
}
if (-not $architecture) {
    Write-Host "`nArchitecture information not found."
}

# Remove applications
Write-Host "`n==[ Removing applications ]=====================================================`n"
$packages = & dism /English "/image:$target\scratchdir" '/Get-ProvisionedAppxPackages' |
    ForEach-Object { if ($_ -match 'PackageName : (.*)') { $matches[1] } }
$packagePrefixes =
    'Clipchamp.Clipchamp_',
    'Microsoft.549981C3F5F10_',
    'Microsoft.BingNews_',
    'Microsoft.BingWeather_',
    'Microsoft.GamingApp_',
    'Microsoft.GetHelp_',
    'Microsoft.Getstarted_',
    'Microsoft.MicrosoftOfficeHub_',
    'Microsoft.MicrosoftSolitaireCollection_',
    'Microsoft.People_',
    'Microsoft.PowerAutomateDesktop_',
    'Microsoft.Todos_',
    'Microsoft.WindowsAlarms_',
    'microsoft.windowscommunicationsapps_',
    'Microsoft.WindowsFeedbackHub_',
    'Microsoft.WindowsMaps_',
    'Microsoft.WindowsSoundRecorder_',
    'Microsoft.Xbox.TCUI_',
    'Microsoft.XboxGameOverlay_',
    'Microsoft.XboxGamingOverlay_',
    'Microsoft.XboxSpeechToTextOverlay_',
    'Microsoft.YourPhone_',
    'Microsoft.ZuneMusic_',
    'Microsoft.ZuneVideo_',
    'MicrosoftCorporationII.MicrosoftFamily_',
    'MicrosoftCorporationII.QuickAssist_',
    'MicrosoftTeams_'
$packagesToRemove = $packages | Where-Object {
    $packageName = $_
    $packagePrefixes -contains ($packagePrefixes | Where-Object { $packageName -like "$_*" })
}
foreach ($package in $packagesToRemove) {
    Write-Host "- $package"
    dism /English "/image:$target\scratchdir" /Remove-ProvisionedAppxPackage "/PackageName:$package" /Quiet
}

Write-Host "`n==[ Loading registry ]==========================================================`n"

reg load "HKLM\zCOMPONENTS" "$target\scratchdir\Windows\System32\config\COMPONENTS" > $null
reg load "HKLM\zDEFAULT"    "$target\scratchdir\Windows\System32\config\default"    > $null
reg load "HKLM\zNTUSER"     "$target\scratchdir\Users\Default\ntuser.dat"           > $null
reg load "HKLM\zSOFTWARE"   "$target\scratchdir\Windows\System32\config\SOFTWARE"   > $null
reg load "HKLM\zSYSTEM"     "$target\scratchdir\Windows\System32\config\SYSTEM"     > $null

Write-Host "`n==[ Removing Edge ]=============================================================`n"

Remove-Item -Path "$target\scratchdir\Program Files (x86)\Microsoft\Edge"       -Recurse -Force > $null
Remove-Item -Path "$target\scratchdir\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse -Force > $null
Remove-Item -Path "$target\scratchdir\Program Files (x86)\Microsoft\EdgeCore"   -Recurse -Force > $null

if ($architecture -eq 'amd64') {
    $folderPath = Get-ChildItem -Path "$target\scratchdir\Windows\WinSxS" -Filter "amd64_microsoft-edge-webview_31bf3856ad364e35*" -Directory | Select-Object -ExpandProperty FullName
    if ($folderPath) {
        & takeown /f "$folderPath" /r > $null
        & icacls "$folderPath" /grant "$($adminGroup.Value):(F)" /T /C > $null
        Remove-Item -Path "$folderPath" -Recurse -Force > $null
    } else {
        Write-Host "Folder not found."
    }
} elseif ($architecture -eq 'arm64') {
    $folderPath = Get-ChildItem -Path "$target\scratchdir\Windows\WinSxS" -Filter "arm64_microsoft-edge-webview_31bf3856ad364e35*" -Directory | Select-Object -ExpandProperty FullName > $null
    if ($folderPath) {
        & takeown /f "$folderPath" /r > $null
        & icacls "$folderPath" /grant "$($adminGroup.Value):(F)" /T /C > $null
        Remove-Item -Path "$folderPath" -Recurse -Force > $null
    } else {
        Write-Host "Folder not found."
    }
} else {
    Write-Host "Unknown architecture: $architecture"
}
takeown /f "$target\scratchdir\Windows\System32\Microsoft-Edge-Webview" /r > $null
icacls "$target\scratchdir\Windows\System32\Microsoft-Edge-Webview" /grant "$($adminGroup.Value):(F)" /T /C > $null
Remove-Item -Path "$target\scratchdir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force > $null

reg delete "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"        /f > $null
reg delete "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" /f > $null

Write-Host "`n==[ Removing OneDrive ]=========================================================`n"

takeown /f "$target\scratchdir\Windows\System32\OneDriveSetup.exe" > $null
icacls     "$target\scratchdir\Windows\System32\OneDriveSetup.exe" /grant "$($adminGroup.Value):(F)" /T /C > $null

Remove-Item -Path "$target\scratchdir\Windows\System32\OneDriveSetup.exe" -Force > $null

reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 1 /f > $null

Write-Host "`n==[ Bypassing system requirements (in the system image) ]=======================`n"

reg add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v SV1                                  /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v SV2                                  /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache"  /v SV1                                  /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache"  /v SV2                                  /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zSYSTEM\Setup\LabConfig"                                     /v BypassCPUCheck                       /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zSYSTEM\Setup\LabConfig"                                     /v BypassRAMCheck                       /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zSYSTEM\Setup\LabConfig"                                     /v BypassSecureBootCheck                /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zSYSTEM\Setup\LabConfig"                                     /v BypassStorageCheck                   /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zSYSTEM\Setup\LabConfig"                                     /v BypassTPMCheck                       /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zSYSTEM\Setup\MoSetup"                                       /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f > $null

Write-Host "`n==[ Disabling sponsored applications ]==========================================`n"

reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v ContentDeliveryAllowed             /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v FeatureManagementEnabled           /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v OemPreInstalledAppsEnabled         /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v PreInstalledAppsEnabled            /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v PreInstalledAppsEverEnabled        /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SilentInstalledAppsEnabled         /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SoftLandingEnabled                 /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-310093Enabled    /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338388Enabled    /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338389Enabled    /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338393Enabled    /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-353694Enabled    /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-353696Enabled    /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContentEnabled           /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SystemPaneSuggestionsEnabled       /t REG_DWORD /d 0 /f > $null
reg add    "HKLM\zSOFTWARE\Policies\Microsoft\MRT"                                         /v DontOfferThroughWUAU               /t REG_DWORD /d 1 /f > $null
reg add    "HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall"                               /v DisablePushToInstall               /t REG_DWORD /d 1 /f > $null
reg add    "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent"                        /v DisableCloudOptimizedContent       /t REG_DWORD /d 1 /f > $null
reg add    "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent"                        /v DisableConsumerAccountStateContent /t REG_DWORD /d 1 /f > $null
reg add    "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent"                        /v DisableWindowsConsumerFeatures     /t REG_DWORD /d 1 /f > $null
reg add    "HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start"                   /v ConfigureStartPins                 /t REG_SZ    /d '{"pinnedList": [{}]}' /f > $null
reg delete "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions" /f > $null
reg delete "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps" /f > $null # TODO: Why is this one missing?

Write-Host "`n==[ Enabling local accounts on OOBE (out of box experience) ]===================`n"

reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f > $null

Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$target\scratchdir\Windows\System32\Sysprep\autounattend.xml" -Force > $null

Write-Host "`n==[ Disabling reserved storage ]================================================`n"

reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v ShippedWithReserves /t REG_DWORD /d 0 /f > $null

Write-Host "`n==[ Disabling chat icon ]=======================================================`n"

#reg add "HKCU\Software\Policies\Microsoft\Windows\Explorer" /v DisableSearchBoxSuggestions /t REG_DWORD /d 1 /f

reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer"                       /v DisableSearchBoxSuggestions /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat"                   /v ChatIcon                    /t REG_DWORD /d 3 /f > $null
reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarMn                   /t REG_DWORD /d 0 /f > $null

Write-Host "`n==[ Disabling telemetry ]=====================================================`n"

reg add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"      /v Enabled                                      /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy"              /v TailoredExperiencesWithDiagnosticDataEnabled /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" /v HasAccepted                                  /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zNTUSER\Software\Microsoft\Input\TIPC"                                  /v Enabled                                      /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization"                        /v RestrictImplicitInkCollection                /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization"                        /v RestrictImplicitTextCollection               /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore"       /v HarvestContacts                              /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zNTUSER\Software\Microsoft\Personalization\Settings"                    /v AcceptedPrivacyPolicy                        /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection"                    /v AllowTelemetry                               /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice"                        /v Start                                        /t REG_DWORD /d 4 /f > $null

# Take ownership of the Scheduled Task's registry keys from TrustedInstaller (Based on Jose Espitia's script)
function Enable-Privilege {
    param([ValidateSet(
        "SeAssignPrimaryTokenPrivilege",
        "SeAuditPrivilege",
        "SeBackupPrivilege",
        "SeChangeNotifyPrivilege",
        "SeCreateGlobalPrivilege",
        "SeCreatePagefilePrivilege",
        "SeCreatePermanentPrivilege",
        "SeCreateSymbolicLinkPrivilege",
        "SeCreateTokenPrivilege",
        "SeDebugPrivilege",
        "SeEnableDelegationPrivilege",
        "SeImpersonatePrivilege",
        "SeIncreaseBasePriorityPrivilege",
        "SeIncreaseQuotaPrivilege",
        "SeIncreaseWorkingSetPrivilege",
        "SeLoadDriverPrivilege",
        "SeLockMemoryPrivilege",
        "SeMachineAccountPrivilege",
        "SeManageVolumePrivilege",
        "SeProfileSingleProcessPrivilege",
        "SeRelabelPrivilege",
        "SeRemoteShutdownPrivilege",
        "SeRestorePrivilege",
        "SeSecurityPrivilege",
        "SeShutdownPrivilege",
        "SeSyncAgentPrivilege",
        "SeSystemEnvironmentPrivilege",
        "SeSystemProfilePrivilege",
        "SeSystemtimePrivilege",
        "SeTakeOwnershipPrivilege",
        "SeTcbPrivilege",
        "SeTimeZonePrivilege",
        "SeTrustedCredManAccessPrivilege",
        "SeUndockPrivilege",
        "SeUnsolicitedInputPrivilege"
    )]  $Privilege, # Which privilege to adjust
        $ProcessId = $pid, # Which process to adjust, defaults to current
        [Switch] $Disable # Switch to disable (rather than enable) the privilege
    )
    $definition = @'
        using System;
        using System.Runtime.InteropServices;

        public class AdjPriv {
            [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
            internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);

            [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
            internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);

            [DllImport("advapi32.dll", SetLastError = true)]
            internal static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);

            [StructLayout(LayoutKind.Sequential, Pack = 1)]

            internal struct TokPriv1Luid {
                public int Count;
                public long Luid;
                public int Attr;
            }

            internal const int SE_PRIVILEGE_ENABLED = 0x00000002;
            internal const int SE_PRIVILEGE_DISABLED = 0x00000000;
            internal const int TOKEN_QUERY = 0x00000008;
            internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;

            public static bool EnablePrivilege(long processHandle, string privilege, bool disable) {
                bool retVal;
                TokPriv1Luid tp;
                IntPtr hproc = new IntPtr(processHandle);
                IntPtr htok = IntPtr.Zero;
                retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
                tp.Count = 1;
                tp.Luid = 0;
                if(disable) {
                    tp.Attr = SE_PRIVILEGE_DISABLED;
                } else {
                    tp.Attr = SE_PRIVILEGE_ENABLED;
                }
                retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
                retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
                return retVal;
            }
        }
'@

    $processHandle = (Get-Process -id $ProcessId).Handle
    $type = Add-Type $definition -PassThru
    $type[0]::EnablePrivilege($processHandle, $Privilege, $Disable)
}

Enable-Privilege SeTakeOwnershipPrivilege > $null

Write-Host "`n==[ Updating registry key permissions ]=========================================`n"

$regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks",[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[System.Security.AccessControl.RegistryRights]::TakeOwnership)
$regACL = $regKey.GetAccessControl()
$regACL.SetOwner($adminGroup)
$regKey.SetAccessControl($regACL)
$regKey.Close()
Write-Host "Owner changed to Administrators"

$regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks",[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[System.Security.AccessControl.RegistryRights]::ChangePermissions)
$regACL = $regKey.GetAccessControl()
$regRule = New-Object System.Security.AccessControl.RegistryAccessRule ($adminGroup,"FullControl","ContainerInherit","None","Allow")
$regACL.SetAccessRule($regRule)
$regKey.SetAccessControl($regACL)
$regKey.Close()
Write-Host "Permissions modified for Administrators group"

Write-Host "`n==[ Deleting Application Compatibility Appraiser ]==============================`n"

reg delete "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\{0600DD45-FAF2-4131-A006-0B17509B9F78}" /f > $null

Write-Host "`n==[ Deleting Customer Experience Improvement Program ]==========================`n"

reg delete "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\{4738DE7A-BCC1-4E2D-B1B0-CADB044BFA81}" /f > $null
reg delete "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\{6FAC31FA-4A85-4E64-BFD5-2154FF4594B3}" /f > $null
reg delete "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\{FC931F16-B50A-472E-B061-B6F79A71EF59}" /f > $null

Write-Host "`n==[ Deleting Program Data Updater ]=============================================`n"

reg delete "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\{0671EB05-7D95-4153-A32B-1426B9FE61DB}" /f > $null

Write-Host "`n==[ Deleting autochk proxy ]====================================================`n"

reg delete "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\{87BF85F4-2CE1-4160-96EA-52F554AA28A2}" /f > $null
reg delete "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\{8A9C643C-3D74-4099-B6BD-9C6D170898B1}" /f > $null

Write-Host "`n==[ Deleting QueueReporting ]===================================================`n"

reg delete "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\{E3176A65-4E44-4ED3-AA73-3283660ACB9C}" /f > $null

Write-Host "`n==[ Done tweaking! ]============================================================`n"

Write-Host "`n==[ Unloading registry ]========================================================`n"

  reg unload "HKLM\zCOMPONENTS" > $null
  reg unload "HKLM\zDEFAULT"    > $null
# reg unload "HKLM\zDRIVERS"    > $null
  reg unload "HKLM\zNTUSER"     > $null
# reg unload "HKLM\zSCHEMA"     > $null
  reg unload "HKLM\zSOFTWARE"   > $null
  reg unload "HKLM\zSYSTEM"     > $null

Write-Host "`n==[ Exporting install image, this will take a long time ]=======================`n"

dism /English "/image:$target\scratchdir" /Cleanup-Image /StartComponentCleanup /ResetBase > $null
dism /English /Unmount-Image "/mountdir:$target\scratchdir" /commit > $null
dism /English /Export-Image "/SourceImageFile:$wimFilePath" "/SourceIndex:$index" "/DestinationImageFile:$target\tiny11\sources\install2.wim" /compress:recovery # (max=.wim file, recovery=.esd)

Remove-Item -Path "$wimFilePath" -Force > $null
Rename-Item -Path "$target\tiny11\sources\install2.wim" -NewName "install.wim" > $null
Start-Sleep -Seconds 2

Write-Host "`n==[ Processing boot image ]=====================================================`n"

$wimFilePath = "$target\tiny11\sources\boot.wim"

takeown /F "$wimFilePath" > $null
icacls "$wimFilePath" /grant "$($adminGroup.Value):(F)"

Set-ItemProperty -Path "$wimFilePath" -Name IsReadOnly -Value $false

Write-Host "Mounting boot image"

dism /English /Mount-Image "/imagefile:$target\tiny11\sources\boot.wim" /index:2 "/mountdir:$target\scratchdir"

Write-Host "Loading boot image registry"

reg load "HKLM\zCOMPONENTS" "$target\scratchdir\Windows\System32\config\COMPONENTS"
reg load "HKLM\zDEFAULT"    "$target\scratchdir\Windows\System32\config\default"
reg load "HKLM\zNTUSER"     "$target\scratchdir\Users\Default\ntuser.dat"
reg load "HKLM\zSOFTWARE"   "$target\scratchdir\Windows\System32\config\SOFTWARE"
reg load "HKLM\zSYSTEM"     "$target\scratchdir\Windows\System32\config\SYSTEM"

Write-Host "Bypassing boot image requirements"

reg add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v SV1                                  /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v SV2                                  /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache"  /v SV1                                  /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache"  /v SV2                                  /t REG_DWORD /d 0 /f > $null
reg add "HKLM\zSYSTEM\Setup\LabConfig"                                     /v BypassCPUCheck                       /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zSYSTEM\Setup\LabConfig"                                     /v BypassRAMCheck                       /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zSYSTEM\Setup\LabConfig"                                     /v BypassSecureBootCheck                /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zSYSTEM\Setup\LabConfig"                                     /v BypassStorageCheck                   /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zSYSTEM\Setup\LabConfig"                                     /v BypassTPMCheck                       /t REG_DWORD /d 1 /f > $null
reg add "HKLM\zSYSTEM\Setup\MoSetup"                                       /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f > $null

Write-Host "Unloading boot image registry"

reg unload "HKLM\zCOMPONENTS" > $null
reg unload "HKLM\zDRIVERS"    > $null
reg unload "HKLM\zDEFAULT"    > $null
reg unload "HKLM\zNTUSER"     > $null
reg unload "HKLM\zSCHEMA"     > $null
reg unload "HKLM\zSOFTWARE"   > $null
reg unload "HKLM\zSYSTEM"     > $null

Write-Host "Unmounting boot image"

dism /English /Unmount-Image "/mountdir:$target\scratchdir" /commit

Write-Host "`n==[ Tiny11 image creation is now complete, will now generate an ISO ]===========`n"

Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$target\tiny11\autounattend.xml" -Force > $null

& "$osc" -m -o -u2 -udfver102 "-bootdata:2#p0,e,b$target\tiny11\boot\etfsboot.com#pEF,e,b$target\tiny11\efi\microsoft\boot\efisys.bin" "$target\tiny11" "$PSScriptRoot\tiny11.iso"

Write-Host "`n==[ Tiny11 is now complete ]====================================================`n"

Read-Host "`nPress Enter to clean up temporary files and exit"

Remove-Item -Path "$target\scratchdir" -Recurse -Force > $null
Remove-Item -Path "$target\tiny11"     -Recurse -Force > $null

try { Stop-Transcript } catch { }

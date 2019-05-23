﻿#Requires -Version 5.1 -RunAsAdministrator
<#
    .NAME
        PowerShellModulesUpdater.ps1

    .SYNAPSIS
        Updates, installs and removes PowerShell modules on your system based on settings in the "Settings & Variables" region.

    .DESCRIPTION
        Updates, installs and removes PowerShell modules on your system based on settings in the "Settings & Variables" region.

        How to use:
            1. Remember to allow script execution!
                Set-ExecutionPolicy -ExecutionPolicy 'Unrestricted' -Scope 'CurrentUser' -Force -Confirm:$false
            2. Remember to enable "$InstallPrerequirements" for your first run
                $InstallPrerequirements = [bool]$($true)

    .NOTES
        Author:         Olav Rønnestad Birkeland
        Version:        1.3.2.0
        Creation Date:  190310
        Last Edit Date: 190503
#>



# Only continue if running as Admin, and if 64 bit OS => Running 64 bit PowerShell
$IsAdmin = [bool]$([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ((-not($IsAdmin)) -or ([System.Environment]::Is64BitOperatingSystem -and (-not([System.Environment]::Is64BitProcess)))) {
    Write-Output -InputObject ('Run this script with 64 bit PowerShell as Admin!')
}


else {
    #region    Settings & Variables
    # Action - What Options Would You Like To Perform
    $InstallPrerequirements = [bool] $false
    $InstallMissingModules = [bool] $true
    $InstallMissingSubModules = [bool] $true
    $InstallUpdatedModules = [bool] $true
    $UninstallOutdatedModules = [bool] $true
    $UninstallUnwantedModules = [bool] $true

    # Settings - PowerShell Output Streams
    $VerbosePreference = 'SilentlyContinue'
    $ProgressPreference = 'SilentlyContinue'

    # List of wanted modules
    $ModulesWanted = [string[]]@(
        'Az', # Microsoft. Used for Azure Resources. Combines and extends functionality from AzureRM and AzureRM.Netcore. https://github.com/Azure/azure-powershell
        'Azure', # Microsoft. Used for managing Classic Azure resources/ objects. https://github.com/Azure/azure-powershell
        'AzureAD', # Microsoft. Used for managing Azure Active Directory resources/ objects. https://docs.microsoft.com/en-us/powershell/module/Azuread
        'ImportExcel', # dfinke.    Used for import/export to Excel. https://github.com/dfinke/ImportExcel
        'IntuneBackupAndRestore', # John Seerden. Uses "MSGraphFunctions" module to backup and restore Intune config. https://github.com/jseerden/IntuneBackupAndRestore
        'Microsoft.Graph.Intune', # Microsoft. Used for managing Intune using PowerShell Graph in the backend. https://github.com/Microsoft/Intune-PowerShell-SDK
        'MSGraphFunctions', # John Seerden. Wrapper for Microsoft Graph Rest API. https://github.com/jseerden/MSGraphFunctions
        'PackageManagement', # Microsoft. Used for installing/ uninstalling modules. https://github.com/oneget/oneget
        'Pester', # Pester. Used for test and mock framework for PowerShell. https://github.com/pester/Pester
        'PlatyPS', # Microsoft. Used to generate markdown help for documentation. https://github.com/PowerShell/platyPS
        'PolicyFileEditor', # Microsoft. Used for local group policy / gpedit.msc. https://github.com/dlwyatt/PolicyFileEditor
        'PowerShellGet', # Microsoft. Used for installing updates. https://github.com/PowerShell/PowerShellGet
        'Psake', # Psake. Used for build automation in PowerShell. https://github.com/psake/psake
        'PSScriptAnalyzer', # Microsoft. Used to analyze PowerShell scripts to look for common mistakes + give advice. https://github.com/PowerShell/PSScriptAnalyzer
        'PSWindowsUpdate', # Michal Gajda. Used for updating Windows. https://www.powershellgallery.com/packages/PSWindowsUpdate
        'SHiPS', # Microsoft. Used for exposing any data store like a file system. https://github.com/PowerShell/ShiPS
        'Watch' # Mark Wragg. Used for repeatedly running a command until output has changed. https://github.com/markwragg/Powershell-Watch
    )

    # List of Unwanted Modules - Will Remove Every Related Module, for AzureRM for instance will also search for AzureRM.*
    $ModulesUnwanted = [string[]]@(
        'AzureRM', # (DEPRECATED, "Az" is it's successor)            Used for managing Azure Resource Manager resources/ objects
        'PartnerCenterModule'     # (DEPRECATED, "PartnerCenter" is it's successor) Used for authentication against Azure CSP Subscriptions
    )
    #endregion Settings & Variables




    #region    Functions
    #region    Get-ModulePublishedVersion
    function Get-ModulePublishedVersion {
        <#
                .SYNAPSIS
                    Fetches latest version number of a given module from PowerShellGallery.

                .PARAMETER ModuleName
                    String, name of the module you want to check.
            #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string] $ModuleName
        )


        # Access the main module page, and add a random number to trick proxies
        $Url = [string]('https://www.powershellgallery.com/packages/{0}/?dummy={1}' -f ($ModuleName, [System.Random]::New().Next(9999)))
        Write-Debug -Message ('URL for module "{0}" = "{1}".' -f ($ModuleName, $Url))        

        # Try to get published version number
        Try {
            # Send the request            
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                # Get the web response
                $Response = [System.Net.HttpWebRequest]::Create($url).GetResponse()
                # PowerShell Core work around due to bug https://github.com/dotnet/corefx/issues/23422
                $Version = [System.Version]$Response.ResponseUri.AbsolutePath.Split('/')[-1]
            }
            else {
                # Get back the URL of the true destination page, and split off the version
                # Create Request Url
                $Request = [System.Net.WebRequest]::Create($Url)

                # Do not allow to redirect. The result is a "MovedPermanently"
                $Request.'AllowAutoRedirect' = $false
                $Response = $Request.GetResponse()
                $Version = [System.Version]$($Response.GetResponseHeader('Location').Split('/')[-1])
            }
        }
        Catch {
            # Write warning if it failed & return blank version number.
            Write-Warning -Message ($_.'Exception'.'Message')
            $Version = [System.Version]$('0.0.0.0')
        }
        Finally {
            # Make sure to clean up connection
            if ($Response) {
                $Response.Close()
                $Response.Dispose()
            }
            else {
                Write-Warning -Message ('Reponse has null value')
            }
        }


        # Return Version
        return $Version
    }
    #endregion Get-ModulePublishedVersion



    #region    Get-ModulesInstalled
    function Get-ModulesInstalled {
        <#
                .SYNAPSIS
                    Gets all currentlyy installed modules.
            #>
        [CmdletBinding()]
        Param()


        # Reset Script Scrope Variable "ModulesInstalledNeedsRefresh" to $false
        $null = Set-Variable -Scope 'Script' -Option 'None' -Force -Name 'ModulesInstalledNeedsRefresh' `
            -Value ([bool]$($false))


        # Refresh Script Scope Variable "ModulesInstalledAll" for a list of all currently installed modules
        $null = Set-Variable -Scope 'Script' -Option 'ReadOnly' -Force -Name 'ModulesInstalled' `
            -Value ([PSCustomObject[]]$(Get-InstalledModule | Where-Object -Property 'Repository' -EQ 'PSGallery' | Select-Object -Property 'Name', 'Version' | Sort-Object -Property 'Name'))
    }
    #endregion Get-ModulesInstalled



    #region    Update-ModulesInstalled
    function Update-ModulesInstalled {
        <#
                .SYNAPSIS
                    Fetches latest version number of a given module from PowerShellGallery.
            #>
        [CmdletBinding()]
        Param()


        # Update Installed Modules Variable if needed
        if ((-not([bool]$($null = Get-Variable -Name 'ModulesInstalledNeedsRefresh' -Scope 'Script' -ErrorAction 'SilentlyContinue'; $?))) -or $Script:ModulesInstalledNeedsRefresh) {
            Get-ModulesInstalled
        }


        # Skip if no installed modules was found
        if ($Script:ModulesInstalled.Count -le 0) {
            Write-Output -InputObject ('No installed modules where found, no modules to update.')
            Break
        }


        # Help Variables
        $C = [uint16]$(1)
        $CTotal = [string]$($Script:ModulesInstalled.Count)
        $Digits = [string]$('0' * $CTotal.Length)
        $ModulesInstalledNames = [string[]]$($Script:ModulesInstalled | Select-Object -ExpandProperty 'Name')


        # Update Modules
        :ForEachModule foreach ($Module in [PSCustomObject[]]$($Script:ModulesInstalled | Sort-Object -Property 'Name')) {
            # Get Latest Available Version
            $VersionAvailable = [System.Version]$(Get-ModulePublishedVersion -ModuleName $Module.'Name')

            # Get Version Installed - Get Fresh Version Number if current module is a sub module
            $VersionInstalled = [System.Version]$(if ([System.Version]$($VersionAvailable) -gt [System.Version]$($Module.'Version') -and $Module.'Name' -like '*.*' -and [string[]]$($ModulesInstalledNames) -contains [string]$($Module.'Name'.Replace(('.{0}' -f ($Module.'Name'.Split('.')[-1])), ''))) {
                    [System.Version[]]$(Get-InstalledModule -Name $Module.'Name' -AllVersions | Select-Object -ExpandProperty 'Version') | Sort-Object -Descending | Select-Object -First 1
                }
                else {$Module.'Version'})

            # Present Current Module
            Write-Output -InputObject ('{0}/{1} {2} v{3}' -f (($C++).ToString($Digits), $CTotal, $Module.'Name', $VersionInstalled.ToString()))

            # Compare Version Installed vs Version Available
            if ($VersionInstalled -ge $VersionAvailable) {
                Write-Output -InputObject ('{0}Current version is latest version.' -f ("`t"))
                Continue ForEachModule
            }
            else {
                Write-Output -InputObject ('{0}Newer version available. Installing v{1}.' -f ("`t", $VersionAvailable.ToString()))
                Install-Module -Name $Module.'Name' -Confirm:$false -Scope 'AllUsers' -RequiredVersion $VersionAvailable -AllowClobber -Verbose:$false -Debug:$false -Force
                $Success = [bool]$($?)
                Write-Output -InputObject ('{0}{0}Success? {0}' -f ("`t", $Success.ToString))
                if ($Success) {$Script:ModulesInstalledNeedsRefresh = $true}
            }
        }
    }
    #endregion Update-ModulesInstalled


    #region    Install-ModulesMissing
    function Install-ModulesMissing {
        <#
                .SYNAPSIS
                    Installs missing modules by comparing installed modules vs input parameter $ModulesWanted.

                .PARAMETER ModulesWanted
                    A string array containing names of wanted modules.
            #>
        [CmdletBinding()]
        Param(
            [Parameter(Mandatory = $true)]
            [string[]] $ModulesWanted
        )


        # Update Installed Modules Variable if needed
        if ((-not([bool]$($null = Get-Variable -Name 'ModulesInstalledNeedsRefresh' -Scope 'Script' -ErrorAction 'SilentlyContinue'; $?))) -or $Script:ModulesInstalledNeedsRefresh) {
            Get-ModulesInstalled
        }


        # Help Variables
        $C = [uint16]$(1)
        $CTotal = [string]$($ModulesWanted.Count)
        $Digits = [string]$('0' * $CTotal.Length)
        $ModulesInstalledNames = [string[]]$($Script:ModulesInstalled | Select-Object -ExpandProperty 'Name' | Sort-Object)


        # Loop each wanted module. If not found in installed modules: Install it
        foreach ($ModuleWanted in $ModulesWanted) {
            Write-Output -InputObject ('{0}/{1} {2}' -f (($C++).ToString($Digits), $CTotal, $ModuleWanted))

            # Install if not already installed
            if ([string[]]$([string[]]$($ModulesInstalledNames) | Where-Object -FilterScript {$_ -eq $ModuleWanted}).Count -ge 1) {
                Write-Output -InputObject ('{0}Already Installed. Next!.' -f ("`t"))
            }
            else {
                Write-Output -InputObject ('{0}Not already installed. Installing.' -f ("`t"))
                Install-Module -Name $ModuleWanted -Confirm:$false -Scope 'AllUsers' -AllowClobber -Verbose:$false -Debug:$false -Force
                $Success = [bool]$($?)
                Write-Output -InputObject ('{0}{0}Success? {0}' -f ("`t", $Success.ToString()))
                if ($Success) {$Script:ModulesInstalledNeedsRefresh = $true}
            }
        }
    }
    #endregion Install-ModulesMissing


    #region    Install-SubModulesMissing
    function Install-SubModulesMissing {
        <#
                .SYNAPSIS
                    Installs Eventually Missing Submodules

                .PARAMETER ModulesName
                    String containing the name of the parent module you want to check for missing submodules.
            #>
        [CmdletBinding()]
        Param()


        # Update Installed Modules Variable if needed
        if ((-not([bool]$($null = Get-Variable -Name 'ModulesInstalledNeedsRefresh' -Scope 'Script' -ErrorAction 'SilentlyContinue'; $?))) -or $Script:ModulesInstalledNeedsRefresh) {
            Get-ModulesInstalled
        }


        # Skip if no installed modules was found
        if ($Script:ModulesInstalled.Count -le 0) {
            Write-Output -InputObject ('No installed modules where found, no modules to check against.')
            Break
        }


        # Help Variables - Both Foreach
        $ModulesInstalledNames = [string[]]$($Script:ModulesInstalled | Select-Object -ExpandProperty 'Name' | Sort-Object)
        $ParentModulesInstalledNames = [string[]]$($ModulesInstalledNames | Where-Object -FilterScript {$_ -notlike '*.*' -or ($_ -like '*.*' -and [string[]]$($ModulesInstalledNames) -notcontains [string]$($_.Replace(('.{0}' -f ($_.Split('.')[-1])), '')))})


        # Help Variables - Outer Foreach
        $OC = [uint16]$(1)
        $OCTotal = [string]$($ParentModulesInstalledNames.Count.ToString())
        $ODigits = [string]$('0' * $OCTotal.Length)


        # Loop Through All Installed Modules
        :ForEachModule foreach ($ModuleName in $ParentModulesInstalledNames) {
            # Present Current Module
            Write-Output -InputObject ('{0}/{1} {2}' -f (($OC++).ToString($ODigits), $OCTotal, $ModuleName))


            # Get all installed sub modules
            $SubModulesInstalled = [string[]]$($ModulesInstalledNames | Where-Object -FilterScript {$_ -like ('{0}.*' -f ($ModuleName))} | Sort-Object)


            # Get all available sub modules
            $SubModulesAvailable = [string[]]$(Find-Module -Name ('{0}.*' -f ($ModuleName)) | Select-Object -ExpandProperty 'Name' | Sort-Object)


            # If either $SubModulesAvailable is 0, Continue Outer Foreach
            if ($SubModulesAvailable.Count -eq 0) {
                Write-Output -InputObject ('{0}Found {1} avilable sub module{2}.' -f ("`t", $SubModulesAvailable.Count.ToString(), [string]$(if ($SubModulesAvailable.Count -ne 1) {'s'})))
                Continue ForEachModule
            }


            # Compare objects to see which are missing
            $SubModulesMissing = [string[]]$(if ($SubModulesInstalled.Count -eq 0) {$SubModulesAvailable}else {Compare-Object -ReferenceObject $SubModulesInstalled -DifferenceObject $SubModulesAvailable -PassThru})
            Write-Output -InputObject ('{0}Found {1} missing sub module{2}.' -f ("`t", $SubModulesMissing.Count.ToString(), [string]$(if ($SubModulesMissing.Count -ne 1) {'s'})))


            # Install missing sub modules
            if ($SubModulesMissing.Count -gt 0) {
                # Help Variables - Inner Foreach
                $IC = [uint16]$(1)
                $ICTotal = [string]$($SubModulesMissing.Count.ToSTring())
                $IDigits = [string]$('0' * $ICTotal.Length)

                # Install Modules
                :ForEachSubModule foreach ($SubModuleName in $SubModulesMissing) {
                    # Present Current Sub Module
                    Write-Output -InputObject ('{0}{1}/{2} {3}' -f ([string]$("`t" * 2), ($IC++).ToString($IDigits), $ICTotal, $SubModuleName))

                    # Install The Missing Sub Module
                    Install-Module -Name $SubModuleName -Confirm:$false -Scope 'AllUsers' -AllowClobber -Verbose:$false -Debug:$false -Force
                    $Success = [bool]$($?)
                    Write-Output -InputObject ('{0}Install success? {1}' -f ([string]$("`t" * 3), $Success.ToString()))
                    if ($Success) {$Script:ModulesInstalledNeedsRefresh = $true}
                }
            }
        }
    }
    #endregion Install-SubModulesMissing


    #region    Uninstall-ModulesOutdated
    function Uninstall-ModulesOutdated {
        <#
                .SYNAPSIS
                    Uninstalls outdated modules / currently installed modules with more than one version.
            #>
        [CmdletBinding()]
        Param()


        # Update Installed Modules Variable if needed
        if ((-not([bool]$($null = Get-Variable -Name 'ModulesInstalledNeedsRefresh' -Scope 'Script' -ErrorAction 'SilentlyContinue'; $?))) -or $Script:ModulesInstalledNeedsRefresh) {
            Get-ModulesInstalled
        }


        # Skip if no installed modules was found
        if ($Script:ModulesInstalled.Count -le 0) {
            Write-Output -InputObject ('No installed modules where found, no modules to update.')
            Break
        }


        # Help Variables
        $C = [uint16]$(1)
        $CTotal = [string]$($Script:ModulesInstalled.Count)
        $Digits = [string]$('0' * $CTotal.Length)
        $ModulesInstalledNames = [string[]]$($Script:ModulesInstalled | Select-Object -ExpandProperty 'Name' | Sort-Object)


        # Get Versions of Installed Main Modules
        foreach ($ModuleName in $ModulesInstalledNames) {
            Write-Output -InputObject ('{0}/{1} {2}' -f (($C++).ToString($Digits), $CTotal, $ModuleName))

            # Get all versions installed
            $VersionsAll = [System.Version[]]$([System.Version[]]$(Get-InstalledModule -Name $ModuleName -AllVersions | Select-Object -ExpandProperty 'Version') | Sort-Object)
            Write-Output -InputObject ('{0}{1} got {2} installed version{3} ({4}).' -f ("`t", $ModuleName, $VersionsAll.Count, $(if ($VersionsAll.Count -gt 1) {'s'}), [string]($VersionsAll -join ', ')))

            # Remove old versions if more than 1 versions
            if ($VersionsAll.Count -gt 1) {
                # Find newest version
                $VersionNewest = [System.Version]$($VersionsAll | Select-Object -Last 1)

                # Uninstall all but newest
                foreach ($Version in $VersionsAll) {
                    if ($Version -ne $VersionNewest) {
                        Write-Output -InputObject ('{0}{0}Uninstalling module "{1}" version "{2}".' -f ("`t", $ModuleName, $Version.ToString()))
                        $null = Uninstall-Module -Name $ModuleName -RequiredVersion $Version -Force -ErrorAction 'SilentlyContinue' 2>&1
                        $Success = [bool]$(@(Get-InstalledModule -Name $ModuleName -RequiredVersion $Version -ErrorAction 'SilentlyContinue').Count -eq 0)
                        Write-Output -InputObject ('{0}{0}{0}Success? {1}.' -f ("`t", $Success.ToString()))
                        if ($Success) {$Script:ModulesInstalledNeedsRefresh = $true}
                        else {
                            if ($ModuleName -eq 'PowerShellGet') {
                                Write-Output -InputObject ('{0}PowerShellGet is used during runtime of this script.{1}{0}Close current PowerShell session when script is done, and run the script again.' -f ("`t`t`t`t", "`r`n"))
                            }
                        }
                    }
                }
            }
        }
    }
    #endregion Uninstall-ModulesOutdated


    #region    Uninstall-ModulesUnwanted
    function Uninstall-ModulesUnwanted {
        <#
                .SYNAPSIS
                    Uninstalls installed modules that matches any value in the input parameter $ModulesUnwanted.

                .PARAMETER ModulesUnwanted
                    String Array containig modules you don't want to be installed on your system.
            #>
        [CmdletBinding()]
        Param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string[]] $ModulesUnwanted
        )


        # Update Installed Modules Variable if needed
        if ((-not([bool]$($null = Get-Variable -Name 'ModulesInstalledNeedsRefresh' -Scope 'Script' -ErrorAction 'SilentlyContinue'; $?))) -or $Script:ModulesInstalledNeedsRefresh) {
            Get-ModulesInstalled
        }


        # Skip if no installed modules was found
        if ($Script:ModulesInstalled.Count -le 0) {
            Write-Output -InputObject ('No installed modules where found, no modules to uninstall.')
            Break
        }


        # Find out if we got unwated modules installed based on input parameter $ModulesUnwanted vs $InstalledModulesAll
        $ModulesToRemove = [string[]]$(
            :outer foreach ($ModuleInstalled in $Script:ModulesInstalled) {
                foreach ($ModuleUnwanted in $ModulesUnwanted) {
                    if ($ModuleInstalled -eq $ModuleUnwanted -or $ModuleInstalled -like ('{0}.*' -f ($ModuleUnwanted))) {
                        $ModuleInstalled
                        Continue outer
                    }
                }
            }
        ) | Sort-Object


        # Write Out How Many Unwanted Modules Was Found
        Write-Output -InputObject ('Found {0} unwanted module{1}. {2}' -f ($ModulesToRemove.Count, $(if ($ModulesToRemove.Count -ne 1) {'s'}), $(if ($ModulesToRemove.Count -gt 0) {'Will proceed to uninstall them.'})))


        # Uninstall Unwanted Modules If More Than 0 Was Found
        if ([uint16]$($ModulesToRemove.Count) -gt 0) {
            $C = [uint16]$(1)
            $CTotal = [string]$($ModulesToRemove.Count.ToString())
            $Digits = [string]$('0' * $CTotal.Length)
            $LengthModuleLongestName = [byte]$([byte[]]$(@($ModulesToRemove | ForEach-Object -Process {$_.Length}) | Sort-Object | Select-Object -Last 1))

            foreach ($Module in $ModulesToRemove) {
                Write-Output -InputObject ('{0}{1}/{2}   {3}{4}' -f ("`t", ($C++).ToString($Digits), $CTotal, $Module, (' ' * [byte]$([byte]$($LengthModuleLongestName) - [byte]$($Module.Length)))))

                # Do not uninstall "PowerShellGet"
                if ($Module -eq 'PowerShellGet') {
                    Write-Output -InputObject ('{0}{0}Will not uninstall "PowerShellGet" as it`s a requirement for this script.' -f ("`t"))
                    Continue
                }

                # Remove Current Module
                Uninstall-Module -Name $Module -Confirm:$false -AllVersions -Force -ErrorAction 'SilentlyContinue'
                $Success = [bool]$($?)

                # Write Out Success
                Write-Output -InputObject ('{0}{0}Success? {1}.' -f ("`t", $Success.ToString()))
                if ($Success) {$Script:ModulesInstalledNeedsRefresh = $true}
            }
        }
    }
    #endregion Uninstall-ModulesUnwanted
    #endregion Functions




    #region    Main
    # Start Time
    New-Variable -Scope 'Script' -Option 'ReadOnly' -Force -Name 'TimeTotalStart' -Value ([datetime]$([datetime]::Now))

    # Set Script Scope Variables
    $Script:ModulesInstalledNeedsRefresh = [bool]$($true)

    # Check that same module is not specified in both $ModulesWanted and $ModulesUnwanted
    if (($ModulesWanted | Where-Object -FilterScript {$ModulesUnwanted -contains $_}).'Count' -ge 1) {
        Throw ('ERROR - Same module(s) are specified in both $ModulesWanted and $ModulesUnwanted.')
    }

    # Set ExecutionPolicy if needed
    if ([string[]]$('AllSigned', 'Default', 'Restricted', 'Undefined') -contains [string]$([Microsoft.PowerShell.ExecutionPolicy]$(Get-ExecutionPolicy).ToString())) {
        $null = Set-ExecutionPolicy -Scope 'Process' -ExecutionPolicy 'Unrestricted' -Confirm:$false -Force -ErrorAction 'Stop'
    }



    # Prerequirements
    Write-Output -InputObject ('### Install Prerequirements.')
    if ($InstallPrerequirements) {
        # Prerequirement - NuGet (Package Provider)
        Write-Output -InputObject ('# Prerequirement - "NuGet" (Package Provider)' -f ("`r`n`r`n"))
        $VersionNuGetMinimum = [System.Version]$(Find-PackageProvider -Name 'NuGet' -Force -Verbose:$false -Debug:$false | Select-Object -ExpandProperty 'Version')
        $VersionNuGetInstalled = [System.Version]$([System.Version[]]@(Get-PackageProvider -ListAvailable -Name 'NuGet' -ErrorAction 'SilentlyContinue' | Select-Object -ExpandProperty 'Version') | Sort-Object)[-1]
        if ((-not($VersionNuGetInstalled)) -or $VersionNuGetInstalled -lt $VersionNuGetMinimum) {
            $null = Install-PackageProvider 'NuGet' –Force -Verbose:$false -Debug:$false -ErrorAction 'Stop'
            Write-Output -InputObject ('{0}Not installed, or newer version available. Installing... Success? {1}' -f ("`t", $?.ToString()))
        }
        else {
            Write-Output -InputObject ('{0}NuGet (Package Provider) is already installed.' -f ("`t"))
        }


        # Prerequirement - PowerShellGet (PowerShell Module)
        Write-Output -InputObject ('{0}# Prerequirement - NuGet (Package Provider)' -f ("`r`n"))
        $ModulesRequired = [string[]]@('PowerShellGet')
        foreach ($ModuleName in $ModulesRequired) {
            Write-Output -InputObject ('{0}' -f ($ModuleName))
            $VersionModuleAvailable = [System.Version]$(Get-ModulePublishedVersion -ModuleName $ModuleName)
            $VersionModuleInstalled = [System.Version]$(Get-InstalledModule -Name $ModuleName -ErrorAction 'SilentlyContinue' | Select-Object -ExpandProperty 'Version')
            if ((-not($VersionModuleInstalled)) -or $VersionModuleInstalled -lt $VersionModuleAvailable) {
                Write-Output -InputObject ('{0}Not installed, or newer version available. Installing...' -f ("`t"))
                $null = Install-Module -Name $ModuleName -Scope 'AllUsers' -Verbose:$false -Debug:$false -Confirm:$false -Force -ErrorAction 'Stop'
                $Success = [bool]$($?)
                Write-Output -InputObject ('{0}{0}Success? {1}' -f ("`t", $Success.ToString()))
                if ($Success) {
                    $null = Import-Module -Name $ModuleName -RequiredVersion $VersionModuleAvailable -Force -ErrorAction 'Stop'
                }
            }
            else {
                Write-Output -InputObject ('{0}"{1}" (PowerShell Module) is already installed.' -f ("`t", $ModuleName))
            }
        }
    }
    else {
        Write-Output -InputObject ('{0}Install Prerequirements is set to $false.' -f ("`t"))
    }



    # Only continue if PowerShellGet is installed and can be imported successfully
    if (-not([bool]$($null = Import-Module -Name 'PowerShellGet' -Force -ErrorAction 'SilentlyContinue'; $?))) {
        Throw 'ERROR: PowerShell module "PowerShellGet" is required to continue.'
    }



    # Uninstall Unwanted Modules
    Write-Output -InputObject ('{0}### Uninstall Unwanted Modules' -f ("`r`n`r`n"))
    if ($UninstallUnwantedModules) {
        Uninstall-ModulesUnwanted -ModulesUnwanted $ModulesUnwanted
    }
    else {
        Write-Output -InputObject ('{0}Uninstall Unwanted Modules is set to $false.' -f ("`t"))
    }



    # Update Installed Modules
    Write-Output -InputObject ('{0}### Update Installed Modules' -f ("`r`n`r`n"))
    if ($InstallUpdatedModules) {
        Update-ModulesInstalled
    }
    else {
        Write-Output -InputObject ('{0}Update Installed Modules is set to $false.' -f ("`t"))
    }



    # Install Missing Modules
    Write-Output -InputObject ('{0}### Install Missing Modules' -f ("`r`n`r`n"))
    if ($InstallMissingModules) {
        Install-ModulesMissing -ModulesWanted $ModulesWanted
    }
    else {
        Write-Output -InputObject ('{0}Install Missing Modules is set to $false.' -f ("`t"))
    }



    # Installing Missing Sub Modules
    Write-Output -InputObject ('{0}### Install Missing Sub Modules' -f ("`r`n`r`n"))
    if ($InstallMissingSubModules) {
        Install-SubModulesMissing
    }
    else {
        Write-Output -InputObject ('{0}Install Missing Sub Modules is set to $false.' -f ("`t"))
    }



    # Remove old modules
    Write-Output -InputObject ('{0}### Remove Outdated Modules' -f ("`r`n`r`n"))
    if ($UninstallOutdatedModules) {
        Uninstall-ModulesOutdated
    }
    else {
        Write-Output -InputObject ('{0}Remove Outdated Modules is set to $false.' -f ("`t"))
    }



    # Write Stats
    Write-Output -InputObject ('{0}### Finished.' -f ("`r`n"))
    Write-Output -InputObject ('Start Time:    {0}.' -f ($Script:TimeTotalStart.ToString('o')))
    Write-Output -InputObject ('End Time:      {0}.' -f (($Script:TimeTotalEnd = [datetime]::Now).ToString('o')))
    Write-Output -InputObject ('Total Runtime: {0}.' -f ([string]$([timespan]$($Script:TimeTotalEnd - $Script:TimeTotalStart)).ToString('hh\:mm\:ss')))
    #endregion Main
}
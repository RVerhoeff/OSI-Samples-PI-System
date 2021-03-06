﻿[CmdletBinding()]
param(
    # Name of AF Server for Analysis Server
    [Parameter(Mandatory)]
    [ValidateNotNullorEmpty()]
    [String]$DefaultPIAFServer,

    # Default PI Data Archive
    [Parameter(Mandatory)]
    [ValidateNotNullorEmpty()]
    [String]$DefaultPIDataArchive,

    # Setup Kit PI Installer Product ID
    [Parameter(Mandatory)]
    [ValidateNotNullorEmpty()]
    [String]$SetupKitsS3PIProductID,

    # Test File Name
    [Parameter(Mandatory)]
    [ValidateNotNullorEmpty()]
    [String]$TestFileName,

    # Domain Admin Username
    [Parameter(Mandatory)]
    [ValidateNotNullorEmpty()]
    [String]$DomainAdminUsername,

    # PI Analytics service account name. Also the AWS SSM Parameter Store parameter name. Used to retrieve the account password.
    [Parameter(Mandatory)]
    [ValidateNotNullorEmpty()]
    [String]$PIANServiceAccountName,

    # Domain Net BIOS Name
    [Parameter(Mandatory)]
    [ValidateNotNullorEmpty()]
    [String]$DomainNetBiosName,

    # Domain Controller Name
    [Parameter(Mandatory)]
    [ValidateNotNullorEmpty()] 
    $DomainControllerServerName,

    # Name Prefix for the stack resource tagging.
    [Parameter(Mandatory)]
    [ValidateNotNullorEmpty()]
    [String]$NamePrefix,

    [Parameter(Mandatory)]
    [ValidateNotNullorEmpty()]
    [ValidateSet('true','false')]
    [string]$DeployHA
)

try {

    # Define Event Log source so it's always available
    $CheckSource = Get-EventLog -LogName Application -Source AWSQuickStartStatus -ErrorAction SilentlyContinue
    if (!$CheckSource) {New-EventLog -LogName Application -Source 'AWSQuickStartStatus' -Verbose}  # Check for source to avoid throwing exception if already present.
    
    # Set to enable catch to Write-AWSQuickStartException
    $ErrorActionPreference = "Stop"

    Import-Module $psscriptroot\IPHelper.psm1

    # Set Local Configuration Manager
    Configuration LCMConfig {
        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
            ActionAfterReboot  = 'ContinueConfiguration'
            ConfigurationMode  = 'ApplyOnly'
            CertificateID      = (Get-ChildItem Cert:\LocalMachine\My)[0].Thumbprint
        }
    }

    LCMConfig
    Set-DscLocalConfigurationManager -Path .\LCMConfig


    # Set Configuration Data. Certificate used for credential encryption.
    $ConfigurationData = @{
        AllNodes = @(
            @{
                NodeName             = $env:COMPUTERNAME
                CertificateFile      = 'C:\dsc.cer'
                PSDscAllowDomainUser = $true
            }
        )
    }

    # Get exisitng service account password from AWS System Manager Parameter Store.
    $DomainAdminPassword = (Get-SSMParameterValue -Name "/$NamePrefix/$DomainAdminUserName" -WithDecryption $True).Parameters[0].Value
    $PIANServiceAccountPassword = (Get-SSMParameterValue -Name "/$NamePrefix/$PIANServiceAccountName" -WithDecryption $True).Parameters[0].Value

    # Generate credential for domain security group creation.
    $securePassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
    $domainCredential = New-Object System.Management.Automation.PSCredential -ArgumentList ("$DomainNetBiosName\$DomainAdminUserName", $securePassword)


    # EC2 Configuration 
    Configuration PIAnalysis0Config {

        param(
            # PI Analysis Service Default settings
            [string]$afServer = $DefaultPIAFServer,
            [string]$piServer = $DefaultPIDataArchive,
            [string]$PIHOME = 'F:\Program Files (x86)\PIPC',
            [string]$PIHOME64 = 'F:\Program Files\PIPC',
            [string]$PIANSvcAccountUserName = $PIANServiceAccountName,
            [string]$PIANSvcAccountPassword = $PIANServiceAccountPassword
        )

        Import-DscResource -ModuleName PSDesiredStateConfiguration
        Import-DscResource -ModuleName xPendingReboot -ModuleVersion 0.4.0.0
        Import-DscResource -ModuleName xStorage -ModuleVersion 3.4.0.0
        Import-DscResource -ModuleName xNetworking -ModuleVersion 5.7.0.0
        Import-DscResource -ModuleName XActiveDirectory -ModuleVersion 3.0.0.0
        Import-DscResource -ModuleName cChoco -ModuleVersion 2.4.0.0
        Import-DscResource -ModuleName xWindowsUpdate

        # Generate credential for PI Analysis Service Account
        $securePIANServiceAccountPassword = ConvertTo-SecureString $PIANSvcAccountPassword -AsPlainText -Force
        $domainServiceAccountCredential = New-Object System.Management.Automation.PSCredential -ArgumentList ("$DomainNetBiosName\$PIANSvcAccountUserName", $securePIANServiceAccountPassword) 

        Node $env:COMPUTERNAME {

            #region ### 1. VM PREPARATION ### 
            # 1A. Check for new volumes. The uninitialized disk number may vary depending on EC2 type (i.e. temp disk or no temp disk). This logic will test to find the disk number of an uninitialized disk.
            $disks = Get-Disk | Where-Object {$_.Number -ne 0} | Sort-Object Number
            if ($disks) {
                # Elastic Block Storage for Binary Files
                xWaitforDisk Volume_F {
                    DiskID           = $disks[0].number
                    retryIntervalSec = 30
                    retryCount       = 20
                }
                xDisk Volume_F {
                    DiskID      = $disks[0].number
                    DriveLetter = 'F'
                    FSFormat    = 'NTFS'
                    FSLabel     = 'Apps'
                    DependsOn   = '[xWaitforDisk]Volume_F'
                }
            }

            # 1B. Open PI Analytics Firewall Rules
            xFirewall PIAFAnalysisFirewallRule {
                Direction   = 'Inbound'
                Name        = 'PI-System-PI-AF-Analysis-TCP-In'
                DisplayName = 'PI System PI AF Analysis (TCP-In)'
                Description = 'Inbound rule for PI AF Analysis to allow TCP traffic access to the PI AF Server.'
                Group       = 'PI Systems'
                Enabled     = 'True'
                Action      = 'Allow'
                Protocol    = 'TCP'
                LocalPort   = '5463'
                Ensure      = 'Present'
            }
            #endregion ### 1. VM PREPARATION ###


            #region ### 2. INSTALL AND SETUP ###
            # 2A i. Installing the RSAT tools for AD Cmdlets
            WindowsFeature ADPS {
                Name   = 'RSAT-AD-PowerShell'
                Ensure = 'Present'
            }

            # 2A ii. Create PI Analysis Service Account
            xADUser ServiceAccount_PIAN {
                DomainName                    = $DomainNetBiosName
                UserName                      = $PIANSvcAccountUserName
                CannotChangePassword          = $true
                Description                   = 'PI Analysis Service account.'
                DomainAdministratorCredential = $domainCredential
                Enabled                       = $true
                Ensure                        = 'Present'
                Password                      = $domainServiceAccountCredential
                DomainController              = $DomainControllerServerName
                DependsOn                     = '[WindowsFeature]ADPS'
            }

            # 2A iii. Add PI Analysis Service account to the AD Group mapped to the PI Identity "PIPointsAnalysisGroup"
            xADGroup CreateANServersGroup {
                GroupName        = 'PIPointsAnalysisCreator'
                Description      = 'Identity for PIACEService, PIAFService and users that can create and edit PI Points'
                Category         = 'Security'
                Ensure           = 'Present'
                GroupScope       = 'Global'
                MembersToInclude = $PIANSvcAccountUserName
                Credential       = $domainCredential
                DomainController = $DomainControllerServerName
                DependsOn        = '[WindowsFeature]ADPS'
            }
            
            # 2B a. Install Chocolatey
            cChocoInstaller installChoco {
                InstallDir = 'C:\choco'
            }

            # 2B b. Install .NET Framework Developer Pack for COTS.
            Script InstallDevPack {
                GetScript = {
                    return @{
                        Value = 'InstallDevPack'
                    }
                }

                # Forces SetScript execution everytime
                TestScript = {
                    return $false
                }

                SetScript = {
                    Try {
                        choco install netfx-4.8-devpack --pre -Y
                    }
                    Catch {
                        Write-EventLog -LogName Application -Source 'AWSQuickStartStatus' -EntryType Information -EventId 0 -Message  $_
                    }
                }
                DependsOn  = '[cChocoInstaller]installChoco'
                PsDscRunAsCredential = $domainCredential
            }

            # 2B c. Install visual studio 2017 build tools for COTS.
            cChocoPackageInstaller 'visualstudio2017buildtools' {
                Name = 'visualstudio2017buildtools'
                DependsOn = '[cChocoInstaller]installChoco'
            }

            # 2C. Installl .NET Framwork 4.8
            xHotFix NETFramework {
                Path = 'C:\media\NETFramework\windows10.0-kb4486129.msu'
                Id = 'KB4486129'
                Ensure = 'Present'
            }

            # 2D. Initiate any outstanding reboots.
            xPendingReboot RebootNETFramework {
                Name      = 'PostNETFrameworkInstall'
                DependsOn = '[xHotFix]NETFramework'
            }

            # 2E. Install PI System Client Tools
            Package PISystem {
                Name                 = 'PI Server 2018 Installer'
                Path                 = 'C:\media\PIServer\PIServerInstaller.exe'
                ProductId            = $SetupKitsS3PIProductID
                Arguments            = "/silent ADDLOCAL=PIAnalysisService,FD_AFExplorer,FD_AFAnalysisMgmt,PiPowerShell PIHOME=""$PIHOME"" PIHOME64=""$PIHOME64"" AFSERVER=""$afServer"" PISERVER=""$piServer"" PI_ARCHIVESIZE=""1024"" SENDTELEMETRY=""0"" AFACKNOWLEDGEBACKUP=""1"" PIANALYSIS_SERVICEACCOUNT=""$DomainNetBiosName\$PIANSvcAccountUserName"" PIANALYSIS_SERVICEPASSWORD=""$PIANSvcAccountPassword"""
                Ensure               = 'Present'
                LogPath              = "$env:ProgramData\PIServer_install.log"
                PsDscRunAsCredential = $domainCredential  # Admin creds due to limitations extracting install under SYSTEM account.
                ReturnCode           = 0, 3010
                DependsOn            = '[xDisk]Volume_F', '[cChocoPackageInstaller]visualstudio2017buildtools', '[xHotFix]NETFramework', '[xPendingReboot]RebootNETFramework'
            }

            # 2F. Initiate any outstanding reboots.
            xPendingReboot RebootPISystem { 
                Name      = 'RebootServer'
                DependsOn = '[Package]PISystem'
            }
            #endregion ### 2. INSTALL AND SETUP ###

            #region ### 3. COTS ###
			Script ConfigurePIVisionAccess {
                GetScript = {
                    return @{
                        Value = 'ConfigurePIVisionAccess'
                    }
                }

				TestScript = {
					$FileName = $Using:TestFileName
					$TestFileNameArray = $FileName.Split('.')
					$TestDir = $TestFileNameArray[0]

					return (Test-Path -LiteralPath C:\$TestDir\testResults)
                }

				SetScript = {
                    Try {
						$DeployHA = $Using:DeployHA
						[Uri]$Uri  = "https://PIVS0" 
						[string]$PIVSServer = "PIVS0.com"
						if($DeployHA -eq 'true')	{
							$Uri = "https://PIVS1" 
							$PIVSServer = "PIVS1.com"
						}
						$request = [System.Net.HttpWebRequest]::Create($uri)

						#Get PIVision certificate
						try
						{
							#Make the request but ignore (dispose it) the response, since we only care about the service point
							$request.GetResponse().Dispose()
						}
						catch [System.Net.WebException]
						{
							if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::TrustFailure)
							{
								#Ignore trust failures, since we only want the certificate, and the service point is still populated at this point
							}
							else
							{								
                                Write-EventLog -LogName Application -Source 'AWSQuickStartStatus' -EntryType Information -EventId 0 -Message  $_
							}
						}

						#Install PIVision certificate
						try {
							#The ServicePoint object should now contain the Certificate for the site.
							$servicePoint = $request.ServicePoint

							$bytes = $servicePoint.Certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
							set-content -value $bytes -encoding byte -path "c:\media\pivs.cer"
							Import-Certificate -FilePath c:\media\pivs.cer -CertStoreLocation Cert:\LocalMachine\Root
						}
						catch {
							Write-EventLog -LogName Application -Source 'AWSQuickStartStatus' -EntryType Information -EventId 0 -Message  $_
						}

						#Add PIVision to trusted sites
						try {
							Set-Location "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
							Set-Location ZoneMap\Domains
							New-Item $PIVSServer
							Set-Location $PIVSServer
							New-Item www
							Set-Location www
							New-ItemProperty . -Name https -Value 2 -Type DWORD

							#Let machine trust UNC paths
							Set-Location "HKCU:\Software\Microsoft\Windows\"
							Set-Location "CurrentVersion"
							Set-Location "Internet Settings"
							Set-ItemProperty ZoneMap UNCAsIntranet -Type DWORD 1
							Set-ItemProperty ZoneMap IntranetName -Type DWORD 1
						}
						catch {
        
							Write-EventLog -LogName Application -Source 'AWSQuickStartStatus' -EntryType Information -EventId 0 -Message  $_
						}
					}
					Catch {
						Write-EventLog -LogName Application -Source 'AWSQuickStartStatus' -EntryType Information -EventId 0 -Message  $_
                    }
				}
				DependsOn  = '[Package]PISystem', '[xPendingReboot]RebootPISystem'
                PsDscRunAsCredential = $domainCredential
			}

            Script CreateCots {
                GetScript = {
                    return @{
                        Value = 'CreateCots'
                    }
                }

                TestScript = {
					$FileName = $Using:TestFileName
					$TestFileNameArray = $FileName.Split('.')
					$TestDir = $TestFileNameArray[0]

					return (Test-Path -LiteralPath C:\$TestDir\testResults)
                }

                SetScript = {
                    Try {
						$FileName = $Using:TestFileName
						$TestFileNameArray = $FileName.Split('.')
						$TestDir = $TestFileNameArray[0]

						Write-EventLog -LogName Application -Source 'AWSQuickStartStatus' -EntryType Information -EventId 0 -Message "COTS start. DomainName: $Using:DomainNetBiosName UserName: $Using:DomainAdminUserName NamePrefix: $Using:NamePrefix TestFileName $Using:TestFileName TestDir $TestDir DefaultPIDataArchive $Using:DefaultPIDataArchive DefaultPIAFServer $Using:DefaultPIAFServer"

						#Expand test zip file
						Expand-Archive -LiteralPath C:\media\TestFile.zip -DestinationPath c:\

						#Update config with EC2 machine names
						(Get-Content C:\$TestDir\source\App.config).replace('Enter_Your_PIDataArchive_Name_Here', $Using:DefaultPIDataArchive) | Set-Content C:\$TestDir\source\App.config
						(Get-Content C:\$TestDir\source\App.config).replace('Enter_Your_AFServer_Name_Here', $Using:DefaultPIAFServer) | Set-Content C:\$TestDir\source\App.config
						(Get-Content C:\$TestDir\source\App.config).replace('Enter_Analysis_Service_Machine_Name_Here', 'PIAN0') | Set-Content C:\$TestDir\source\App.config

						$DeployHA = $Using:DeployHA
						if($DeployHA -eq 'false')	{
							(Get-Content C:\$TestDir\source\App.config).replace('key="PIWebAPI" value=""', 'key="PIWebAPI" value="PIVS0"') | Set-Content C:\$TestDir\source\App.config
							(Get-Content C:\$TestDir\source\App.config).replace('key="PIVisionServer" value=""', 'key="PIVisionServer" value="https://PIVS0/PIVision"') | Set-Content C:\$TestDir\source\App.config
						}

						(Get-Content C:\$TestDir\source\App.config).replace('key="SkipCertificateValidation" value=""', 'key="SkipCertificateValidation" value="True"') | Set-Content C:\$TestDir\source\App.config

						#Add user to AF security group
						try {
							$Recal = Get-AFSecurityIdentity -Name "Asset Analytics Recalculation" -Refresh -AFServer (Get-AFServer -Name $Using:DefaultPIAFServer);
							$User = $Using:DomainNetBiosName + '\' + $Using:DomainAdminUserName ;
							Write-EventLog -LogName Application -Source 'AWSQuickStartStatus' -EntryType Information -EventId 0 -Message "COTS User: $User"
							Add-AFSecurityMapping -Name PIAdmin -WindowsAccount $User -AFSecurityIdentity $Recal -CheckIn -AFServer (Get-AFServer -Name $Using:DefaultPIAFServer);
						}
						Catch {
							#Continue user was previously added to group
							Write-EventLog -LogName Application -Source 'AWSQuickStartStatus' -EntryType Information -EventId 0 -Message  $_
						}

						#Run tests
						Start-Process -FilePath powershell.exe -Wait -PassThru -WorkingDirectory C:\$TestDir\scripts\ -ArgumentList ".\run.ps1 -f"

						#Copy test result to remote desktop gateway server
						New-Item -ItemType directory -Path "\\RDGW0.osideploysample.int\\C$\TestResults\" -Force
						Copy-Item -Path "C:\$TestDir\testResults\*.html" -Destination "\\RDGW0.osideploysample.int\\C$\TestResults\"

						Write-EventLog -LogName Application -Source 'AWSQuickStartStatus' -EntryType Information -EventId 0 -Message "COTS end."
                    }
                    Catch {
                        Write-EventLog -LogName Application -Source 'AWSQuickStartStatus' -EntryType Information -EventId 0 -Message  $_
                    }
                }
                DependsOn  = '[Package]PISystem', '[xPendingReboot]RebootPISystem'
                PsDscRunAsCredential = $domainCredential
            }
            #endregion ### 3. COTS ###            

            #region ### 4. SIGNAL WAITCONDITION ###
            # Writes output to the AWS CloudFormation Init Wait Handle (Indicating script completed)
            # To ensure it triggers only at the end of the script, set DependsOn to include all resources.
            Script Write-AWSQuickStartStatus {
                GetScript  = {@( Value = 'WriteAWSQuickStartStatus' )}
                TestScript = {$false}
                SetScript  = {
                    Write-Verbose "Getting Handle" -Verbose
                    $handle = Get-AWSQuickStartWaitHandle -ErrorAction SilentlyContinue
                    Invoke-Expression "cfn-signal.exe -e 0 -i 'pianalysis0config' '$handle'" 

                    # Write to Application Log to record status update.
                    $CheckSource = Get-EventLog -LogName Application -Source AWSQuickStartStatus -ErrorAction SilentlyContinue
                    if (!$CheckSource) {New-EventLog -LogName Application -Source 'AWSQuickStartStatus' -Verbose}  # Check for source to avoid throwing exception if already present.
                    Write-EventLog -LogName Application -Source 'AWSQuickStartStatus' -EntryType Information -EventId 0 -Message "Write-AWSQuickStartStatus function was triggered."
                }
                DependsOn  = '[Package]PISystem', '[xPendingReboot]RebootPISystem'
            }
            #endregion ### 4. SIGNAL WAITCONDITION ###
        }
    }

    # Compile and Execute Configuration
    PIAnalysis0Config -ConfigurationData $ConfigurationData
    Start-DscConfiguration -Path .\PIAnalysis0Config -Wait -Verbose -Force -ErrorVariable ev
}

catch {
    # If any expectations are thrown, output to CloudFormation Init.
    $_ | Write-AWSQuickStartException
}
# SIG # Begin signature block
# MIIbzAYJKoZIhvcNAQcCoIIbvTCCG7kCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDBleuhqIWP6quJ
# GXoe+rpG/X6CJOtndxXwo7fviNL/xaCCCo4wggUwMIIEGKADAgECAhAECRgbX9W7
# ZnVTQ7VvlVAIMA0GCSqGSIb3DQEBCwUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0xMzEwMjIxMjAwMDBa
# Fw0yODEwMjIxMjAwMDBaMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lD
# ZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQD407Mcfw4Rr2d3B9MLMUkZz9D7RZmxOttE9X/l
# qJ3bMtdx6nadBS63j/qSQ8Cl+YnUNxnXtqrwnIal2CWsDnkoOn7p0WfTxvspJ8fT
# eyOU5JEjlpB3gvmhhCNmElQzUHSxKCa7JGnCwlLyFGeKiUXULaGj6YgsIJWuHEqH
# CN8M9eJNYBi+qsSyrnAxZjNxPqxwoqvOf+l8y5Kh5TsxHM/q8grkV7tKtel05iv+
# bMt+dDk2DZDv5LVOpKnqagqrhPOsZ061xPeM0SAlI+sIZD5SlsHyDxL0xY4PwaLo
# LFH3c7y9hbFig3NBggfkOItqcyDQD2RzPJ6fpjOp/RnfJZPRAgMBAAGjggHNMIIB
# yTASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAK
# BggrBgEFBQcDAzB5BggrBgEFBQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9v
# Y3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNydDCBgQYDVR0fBHow
# eDA6oDigNoY0aHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJl
# ZElEUm9vdENBLmNybDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDBPBgNVHSAESDBGMDgGCmCGSAGG/WwA
# AgQwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAK
# BghghkgBhv1sAzAdBgNVHQ4EFgQUWsS5eyoKo6XqcQPAYPkt9mV1DlgwHwYDVR0j
# BBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDQYJKoZIhvcNAQELBQADggEBAD7s
# DVoks/Mi0RXILHwlKXaoHV0cLToaxO8wYdd+C2D9wz0PxK+L/e8q3yBVN7Dh9tGS
# dQ9RtG6ljlriXiSBThCk7j9xjmMOE0ut119EefM2FAaK95xGTlz/kLEbBw6RFfu6
# r7VRwo0kriTGxycqoSkoGjpxKAI8LpGjwCUR4pwUR6F6aGivm6dcIFzZcbEMj7uo
# +MUSaJ/PQMtARKUT8OZkDCUIQjKyNookAv4vcn4c10lFluhZHen6dGRrsutmQ9qz
# sIzV6Q3d9gEgzpkxYz0IGhizgZtPxpMQBvwHgfqL2vmCSfdibqFT+hKUGIUukpHq
# aGxEMrJmoecYpJpkUe8wggVWMIIEPqADAgECAhAFTTVZN0yftPMcszD508Q/MA0G
# CSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0
# IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwHhcNMTkwNjE3MDAwMDAw
# WhcNMjAwNzAxMTIwMDAwWjCBkjELMAkGA1UEBhMCVVMxCzAJBgNVBAgTAkNBMRQw
# EgYDVQQHEwtTYW4gTGVhbmRybzEVMBMGA1UEChMMT1NJc29mdCwgTExDMQwwCgYD
# VQQLEwNEZXYxFTATBgNVBAMTDE9TSXNvZnQsIExMQzEkMCIGCSqGSIb3DQEJARYV
# c21hbmFnZXJzQG9zaXNvZnQuY29tMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB
# CgKCAQEAqbP+VTz8qtsq4SWhF7LsXqeDGyUwtDpf0vlSg+aQh2fOqJhW2uiPa1GO
# M5+xbr+RhTTWzJX2vEwqSIzN43ktTdgcVT9Bf5W2md+RCYE1D17jGlj5sCFTS4eX
# Htm+lFoQF0donavbA+7+ggd577FdgOnjuYxEpZe2lbUyWcKOHrLQr6Mk/bKjcYSY
# B/ipNK4hvXKTLEsN7k5kyzRkq77PaqbVAQRgnQiv/Lav5xWXuOn7M94TNX4+1Mk8
# 74nuny62KLcMRtjPCc2aWBpHmhD3wPcUVvTW+lGwEaT0DrCwcZDuG/Igkhqj/8Rf
# HYfnZQtWMnBFAHcuA4jJgmZ7xYMPoQIDAQABo4IBxTCCAcEwHwYDVR0jBBgwFoAU
# WsS5eyoKo6XqcQPAYPkt9mV1DlgwHQYDVR0OBBYEFNcTKM3o/Fjj9J3iOakcmKx6
# CPetMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAzB3BgNVHR8E
# cDBuMDWgM6Axhi9odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vc2hhMi1hc3N1cmVk
# LWNzLWcxLmNybDA1oDOgMYYvaHR0cDovL2NybDQuZGlnaWNlcnQuY29tL3NoYTIt
# YXNzdXJlZC1jcy1nMS5jcmwwTAYDVR0gBEUwQzA3BglghkgBhv1sAwEwKjAoBggr
# BgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAIBgZngQwBBAEw
# gYQGCCsGAQUFBwEBBHgwdjAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNl
# cnQuY29tME4GCCsGAQUFBzAChkJodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20v
# RGlnaUNlcnRTSEEyQXNzdXJlZElEQ29kZVNpZ25pbmdDQS5jcnQwDAYDVR0TAQH/
# BAIwADANBgkqhkiG9w0BAQsFAAOCAQEAigLIcsGUWzXlZuVQY8s1UOxYgch5qO1Y
# YEDFF8abzJQ4RiB8rcdoRWjsfpWxtGOS0wkA2CfyuWhjO/XqgmYJ8AUHIKKCy6QE
# 31/I6izI6iDCg8X5lSR6nKsB2BCZCOnGJOEi3r+WDS18PMuW24kaBo1ezx6KQOx4
# N0qSrMJqJRXfPHpl3WpcLs3VA1Gew9ATOQ9IXbt8QCvyMICRJxq4heHXPLE3EpK8
# 2wlBKwX3P4phapmEUOWxB45QOcRJqgahe9qIALbLS+i5lxV+eX/87YuEiyDtGfH+
# dAbq5BqlYz1Fr8UrWeR3KIONPNtkm2IFHNMdpsgmKwC/Xh3nC3b27DGCEJQwghCQ
# AgEBMIGGMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAX
# BgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0IFNIQTIg
# QXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0ECEAVNNVk3TJ+08xyzMPnTxD8wDQYJ
# YIZIAWUDBAIBBQCggZ4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYB
# BAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIObGqATwhc1/
# JrQ2Q5aZKAj3BJHc2KI5JXEAiPVARCZoMDIGCisGAQQBgjcCAQwxJDAioSCAHmh0
# dHA6Ly90ZWNoc3VwcG9ydC5vc2lzb2Z0LmNvbTANBgkqhkiG9w0BAQEFAASCAQCm
# ceuWJnXhyqNMIR5unAm6640rLUIwu9PIaFKrCZ9y0mMWF5gs1jSu57RkoQM9Solx
# PyHov307G2Dp2KpfIo0mLCKxlDqiRGC8m/jbKb0y3aGIHm9PCE+7cefFnGoU1kQe
# tcIEFFb22/+P/SC4AFKif5aeluE86Z6cUAXj2eAma39u7oT7s7XpbvKaxAwnfFXS
# yU4WIOVdvy/+GbFsnkPQVtRyjAAyuPXUaZBnhRUJSIBU1hMOh1R18sBJoPaCzCtV
# BHCKUsF8XEcDzdxozGTcsASayg8oE7EsJ+z1PH420QRDOGb6mngfKIEKw9fPnK6C
# F75QIDGJWLlHyzAInh8WoYIOPTCCDjkGCisGAQQBgjcDAwExgg4pMIIOJQYJKoZI
# hvcNAQcCoIIOFjCCDhICAQMxDTALBglghkgBZQMEAgEwggEPBgsqhkiG9w0BCRAB
# BKCB/wSB/DCB+QIBAQYLYIZIAYb4RQEHFwMwMTANBglghkgBZQMEAgEFAAQgGtgE
# Z5I7srKVgrcW+2wRWwqypLKYWjPe0P3J/mpYlsUCFQCLV33UkFX6VB2Rv2B8aGq3
# GpXmvxgPMjAyMDAzMzAxNTQxNTRaMAMCAR6ggYakgYMwgYAxCzAJBgNVBAYTAlVT
# MR0wGwYDVQQKExRTeW1hbnRlYyBDb3Jwb3JhdGlvbjEfMB0GA1UECxMWU3ltYW50
# ZWMgVHJ1c3QgTmV0d29yazExMC8GA1UEAxMoU3ltYW50ZWMgU0hBMjU2IFRpbWVT
# dGFtcGluZyBTaWduZXIgLSBHM6CCCoswggU4MIIEIKADAgECAhB7BbHUSWhRRPfJ
# idKcGZ0SMA0GCSqGSIb3DQEBCwUAMIG9MQswCQYDVQQGEwJVUzEXMBUGA1UEChMO
# VmVyaVNpZ24sIEluYy4xHzAdBgNVBAsTFlZlcmlTaWduIFRydXN0IE5ldHdvcmsx
# OjA4BgNVBAsTMShjKSAyMDA4IFZlcmlTaWduLCBJbmMuIC0gRm9yIGF1dGhvcml6
# ZWQgdXNlIG9ubHkxODA2BgNVBAMTL1ZlcmlTaWduIFVuaXZlcnNhbCBSb290IENl
# cnRpZmljYXRpb24gQXV0aG9yaXR5MB4XDTE2MDExMjAwMDAwMFoXDTMxMDExMTIz
# NTk1OVowdzELMAkGA1UEBhMCVVMxHTAbBgNVBAoTFFN5bWFudGVjIENvcnBvcmF0
# aW9uMR8wHQYDVQQLExZTeW1hbnRlYyBUcnVzdCBOZXR3b3JrMSgwJgYDVQQDEx9T
# eW1hbnRlYyBTSEEyNTYgVGltZVN0YW1waW5nIENBMIIBIjANBgkqhkiG9w0BAQEF
# AAOCAQ8AMIIBCgKCAQEAu1mdWVVPnYxyXRqBoutV87ABrTxxrDKPBWuGmicAMpdq
# TclkFEspu8LZKbku7GOz4c8/C1aQ+GIbfuumB+Lef15tQDjUkQbnQXx5HMvLrRu/
# 2JWR8/DubPitljkuf8EnuHg5xYSl7e2vh47Ojcdt6tKYtTofHjmdw/SaqPSE4cTR
# fHHGBim0P+SDDSbDewg+TfkKtzNJ/8o71PWym0vhiJka9cDpMxTW38eA25Hu/ryS
# V3J39M2ozP4J9ZM3vpWIasXc9LFL1M7oCZFftYR5NYp4rBkyjyPBMkEbWQ6pPrHM
# +dYr77fY5NUdbRE6kvaTyZzjSO67Uw7UNpeGeMWhNwIDAQABo4IBdzCCAXMwDgYD
# VR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQAwZgYDVR0gBF8wXTBbBgtg
# hkgBhvhFAQcXAzBMMCMGCCsGAQUFBwIBFhdodHRwczovL2Quc3ltY2IuY29tL2Nw
# czAlBggrBgEFBQcCAjAZGhdodHRwczovL2Quc3ltY2IuY29tL3JwYTAuBggrBgEF
# BQcBAQQiMCAwHgYIKwYBBQUHMAGGEmh0dHA6Ly9zLnN5bWNkLmNvbTA2BgNVHR8E
# LzAtMCugKaAnhiVodHRwOi8vcy5zeW1jYi5jb20vdW5pdmVyc2FsLXJvb3QuY3Js
# MBMGA1UdJQQMMAoGCCsGAQUFBwMIMCgGA1UdEQQhMB+kHTAbMRkwFwYDVQQDExBU
# aW1lU3RhbXAtMjA0OC0zMB0GA1UdDgQWBBSvY9bKo06FcuCnvEHzKaI4f4B1YjAf
# BgNVHSMEGDAWgBS2d/ppSEefUxLVwuoHMnYH0ZcHGTANBgkqhkiG9w0BAQsFAAOC
# AQEAdeqwLdU0GVwyRf4O4dRPpnjBb9fq3dxP86HIgYj3p48V5kApreZd9KLZVmSE
# cTAq3R5hF2YgVgaYGY1dcfL4l7wJ/RyRR8ni6I0D+8yQL9YKbE4z7Na0k8hMkGNI
# OUAhxN3WbomYPLWYl+ipBrcJyY9TV0GQL+EeTU7cyhB4bEJu8LbF+GFcUvVO9muN
# 90p6vvPN/QPX2fYDqA/jU/cKdezGdS6qZoUEmbf4Blfhxg726K/a7JsYH6q54zoA
# v86KlMsB257HOLsPUqvR45QDYApNoP4nbRQy/D+XQOG/mYnb5DkUvdrk08PqK1qz
# lVhVBH3HmuwjA42FKtL/rqlhgTCCBUswggQzoAMCAQICEHvU5a+6zAc/oQEjBCJB
# TRIwDQYJKoZIhvcNAQELBQAwdzELMAkGA1UEBhMCVVMxHTAbBgNVBAoTFFN5bWFu
# dGVjIENvcnBvcmF0aW9uMR8wHQYDVQQLExZTeW1hbnRlYyBUcnVzdCBOZXR3b3Jr
# MSgwJgYDVQQDEx9TeW1hbnRlYyBTSEEyNTYgVGltZVN0YW1waW5nIENBMB4XDTE3
# MTIyMzAwMDAwMFoXDTI5MDMyMjIzNTk1OVowgYAxCzAJBgNVBAYTAlVTMR0wGwYD
# VQQKExRTeW1hbnRlYyBDb3Jwb3JhdGlvbjEfMB0GA1UECxMWU3ltYW50ZWMgVHJ1
# c3QgTmV0d29yazExMC8GA1UEAxMoU3ltYW50ZWMgU0hBMjU2IFRpbWVTdGFtcGlu
# ZyBTaWduZXIgLSBHMzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAK8O
# iqr43L9pe1QXcUcJvY08gfh0FXdnkJz93k4Cnkt29uU2PmXVJCBtMPndHYPpPydK
# M05tForkjUCNIqq+pwsb0ge2PLUaJCj4G3JRPcgJiCYIOvn6QyN1R3AMs19bjwgd
# ckhXZU2vAjxA9/TdMjiTP+UspvNZI8uA3hNN+RDJqgoYbFVhV9HxAizEtavybCPS
# nw0PGWythWJp/U6FwYpSMatb2Ml0UuNXbCK/VX9vygarP0q3InZl7Ow28paVgSYs
# /buYqgE4068lQJsJU/ApV4VYXuqFSEEhh+XetNMmsntAU1h5jlIxBk2UA0XEzjwD
# 7LcA8joixbRv5e+wipsCAwEAAaOCAccwggHDMAwGA1UdEwEB/wQCMAAwZgYDVR0g
# BF8wXTBbBgtghkgBhvhFAQcXAzBMMCMGCCsGAQUFBwIBFhdodHRwczovL2Quc3lt
# Y2IuY29tL2NwczAlBggrBgEFBQcCAjAZGhdodHRwczovL2Quc3ltY2IuY29tL3Jw
# YTBABgNVHR8EOTA3MDWgM6Axhi9odHRwOi8vdHMtY3JsLndzLnN5bWFudGVjLmNv
# bS9zaGEyNTYtdHNzLWNhLmNybDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAOBgNV
# HQ8BAf8EBAMCB4AwdwYIKwYBBQUHAQEEazBpMCoGCCsGAQUFBzABhh5odHRwOi8v
# dHMtb2NzcC53cy5zeW1hbnRlYy5jb20wOwYIKwYBBQUHMAKGL2h0dHA6Ly90cy1h
# aWEud3Muc3ltYW50ZWMuY29tL3NoYTI1Ni10c3MtY2EuY2VyMCgGA1UdEQQhMB+k
# HTAbMRkwFwYDVQQDExBUaW1lU3RhbXAtMjA0OC02MB0GA1UdDgQWBBSlEwGpn4XM
# G24WHl87Map5NgB7HTAfBgNVHSMEGDAWgBSvY9bKo06FcuCnvEHzKaI4f4B1YjAN
# BgkqhkiG9w0BAQsFAAOCAQEARp6v8LiiX6KZSM+oJ0shzbK5pnJwYy/jVSl7OUZO
# 535lBliLvFeKkg0I2BC6NiT6Cnv7O9Niv0qUFeaC24pUbf8o/mfPcT/mMwnZolkQ
# 9B5K/mXM3tRr41IpdQBKK6XMy5voqU33tBdZkkHDtz+G5vbAf0Q8RlwXWuOkO9Vp
# JtUhfeGAZ35irLdOLhWa5Zwjr1sR6nGpQfkNeTipoQ3PtLHaPpp6xyLFdM3fRwmG
# xPyRJbIblumFCOjd6nRgbmClVnoNyERY3Ob5SBSe5b/eAL13sZgUchQk38cRLB8A
# P8NLFMZnHMweBqOQX1xUiz7jM1uCD8W3hgJOcZ/pZkU/djGCAlowggJWAgEBMIGL
# MHcxCzAJBgNVBAYTAlVTMR0wGwYDVQQKExRTeW1hbnRlYyBDb3Jwb3JhdGlvbjEf
# MB0GA1UECxMWU3ltYW50ZWMgVHJ1c3QgTmV0d29yazEoMCYGA1UEAxMfU3ltYW50
# ZWMgU0hBMjU2IFRpbWVTdGFtcGluZyBDQQIQe9Tlr7rMBz+hASMEIkFNEjALBglg
# hkgBZQMEAgGggaQwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwGCSqGSIb3
# DQEJBTEPFw0yMDAzMzAxNTQxNTRaMC8GCSqGSIb3DQEJBDEiBCD6AcQsJ+wbtf8Y
# kTm4964CYvR8eHIYYG7dJAGRGpQRCzA3BgsqhkiG9w0BCRACLzEoMCYwJDAiBCDE
# dM52AH0COU4NpeTefBTGgPniggE8/vZT7123H99h+DALBgkqhkiG9w0BAQEEggEA
# JE30FeRF1D8oF0pidx/0t0F17SYD9+yuDpE2xp37xYS0RGdEqtppTADW6y+sQXeq
# coHHesSRY7+jZBlnOfxzmdPNDObtt/SXbZp8tN18G1+uAwlvA9yZyrcEzGjZoKFw
# m6gPvBZTnPaN7luGaI7NKcHJCRq7wl/jYHzvytuvftw6/9uAtalhWU3xCXJAPJAJ
# CMzhjL8gcz4eEjIeaJo3QExj+YXmSE1o6idEZuhpXfE0tuQWOC35dszi8vxEzQ73
# //RQf91F+Jw9qlShhfEVNpTQHg8dvZdlRa7+AXi/ZiRr/9rco++AVwEiRrVCXaOv
# uTO9g7YfkqdJAUxu4loujQ==
# SIG # End signature block

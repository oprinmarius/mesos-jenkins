Param(
    [Parameter(Mandatory=$false)]
    [string]$GitURL="https://github.com/dcos/dcos-net",
    [Parameter(Mandatory=$false)]
    [string]$Branch="master",
    [Parameter(Mandatory=$false)]
    [string]$CommitID,
    [Parameter(Mandatory=$false)]
    [string]$ParametersFile="${env:WORKSPACE}\build-parameters.json"
)

$ErrorActionPreference = "Stop"

$globalVariables = (Resolve-Path "$PSScriptRoot\..\global-variables.ps1").Path
$ciUtils = (Resolve-Path "$PSScriptRoot\..\Modules\CIUtils").Path

Import-Module $ciUtils
. $globalVariables

$global:PARAMETERS = @{
    "BUILD_STATUS" = $null
    "LOGS_URLS" = @()
    "FAILED_COMMAND" = $null
}


function Start-DCOSNetCIProcess {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$ProcessPath,
        [Parameter(Mandatory=$false)]
        [string[]]$ArgumentList,
        [Parameter(Mandatory=$true)]
        [string]$LogFileName,
        [Parameter(Mandatory=$true)]
        [string]$BuildErrorMessage
    )
    $logFile = Join-Path $DCOS_NET_BUILD_LOGS_DIR $LogFileName
    $logsUrl = Get-BuildLogsUrl
    $logFileUrl = "${logsUrl}/${LogFileName}"
    $command = $ProcessPath -replace '\\', '\\'
    if($ArgumentList.Count) {
        $ArgumentList | Foreach-Object { $command += " $($_ -replace '\\', '\\')" }
    }
    try {
        cmd.exe /C "$ProcessPath $($ArgumentList -join ' ') 2>&1" | Out-File $logFile
        if($LASTEXITCODE) {
            Throw "Failed to execute: $command"
        }
        $msg = "Successfully executed: $command"
    } catch {
        $msg = "Failed command: $command"
        $global:PARAMETERS["BUILD_STATUS"] = 'FAIL'
        $global:PARAMETERS["LOGS_URLS"] += $($logFileUrl)
        $global:PARAMETERS["FAILED_COMMAND"] = $command

        Write-Output "Exception: $($_.ToString())"
        Throw $BuildErrorMessage
    } finally {
        Write-Output $msg
        Write-Output "Log available at: $logFileUrl"
    }
}

function Get-LatestCommitID {
    if(!$global:LATEST_COMMIT_ID) {
        Throw "Failed to get the latest dcos-net commit ID. Perhaps it was not yet saved."
    }
    return $global:LATEST_COMMIT_ID
}

function Get-DCOSNetBuildRelativePath {
    $repositoryName = $GitURL.Split("/")[-1]
    $dcosNetCommitID = Get-LatestCommitID
    return "${repositoryName}"
}

function Get-BuildOutputsUrl {
    $relativePath = Get-DCOSNetBuildRelativePath
    return "$ARTIFACTS_BASE_URL/${env:JOB_NAME}/${env:BUILD_ID}/$relativePath"
}

function Get-BuildLogsUrl {
    $buildOutUrl = Get-BuildOutputsUrl
    return "$buildOutUrl/logs"
}

function Get-RemoteBuildDirectoryPath {
    $relativePath = Get-DCOSNetBuildRelativePath
    return "$ARTIFACTS_DIRECTORY/${env:JOB_NAME}/${env:BUILD_ID}/$relativePath"
}

function Set-LatestDCOSNetCommit {
    Push-Location $DCOS_NET_GIT_REPO_DIR
    try {
        if($CommitID) {
            Start-ExternalCommand { git.exe reset --hard $CommitID } -ErrorMessage "Failed to set the dcos-net git repository last commit to: $CommitID."
        }
        Start-ExternalCommand { git.exe log -n 1 } -ErrorMessage "Failed to get the latest commit message for the dcos-net git repository" | Out-File "$DCOS_NET_BUILD_LOGS_DIR\latest-commit.log"
        $dcosNetCommitId = Start-ExternalCommand { git.exe log --format="%H" -n 1 } -ErrorMessage "Failed to get the latest commit id for the dcos-net git repository"
        Set-Variable -Name "LATEST_COMMIT_ID" -Value $dcosNetCommitId -Scope Global -Option ReadOnly
    } finally {
        Pop-Location
    }
}

function New-Environment {
    Start-EnvironmentCleanup # Do an environment cleanup to make sure everything is fresh
    New-Directory $DCOS_NET_DIR
    New-Directory $DCOS_NET_BUILD_OUT_DIR
    New-Directory $DCOS_NET_BUILD_LOGS_DIR
    New-Directory $DCOS_NET_BUILD_RELEASE_DIR
    Start-GitClone -URL $GitURL -Branch $Branch -Path $DCOS_NET_GIT_REPO_DIR
    Start-GitClone -URL $LIBSODIUM_GIT_URL -Path $DCOS_NET_LIBSODIUM_GIT_DIR
    $global:PARAMETERS["BRANCH"] = $Branch
    Set-LatestDCOSNetCommit
}

function Set-WindowsSDK {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$VCXProjFile,
        [Parameter(Mandatory=$true)]
        [string]$Version
    )

    [xml]$settings = Get-Content $VCXProjFile
    $target = $settings.Project.PropertyGroup | ? { $_.Label -eq "Globals" }
    if($target.WindowsTargetPlatformVersion) {
        $target.WindowsTargetPlatformVersion = $Version
    } else {
        $element = $settings.CreateElement('WindowsTargetPlatformVersion', $settings.DocumentElement.NamespaceURI)
        $element.InnerText = $Version
        $target.AppendChild($element) | Out-Null
    }
    $settings.Save($VCXProjFile)
}

function Start-LibsodiumBuild {
    Set-VCVariables "15.0"
    Push-Location $DCOS_NET_LIBSODIUM_GIT_DIR
    Set-WindowsSDK -VCXProjFile "$DCOS_NET_LIBSODIUM_GIT_DIR\builds\msvc\vs2017\libsodium\libsodium.vcxproj" -Version "10.0.17134.0"
    Write-Output "Starting the libsodium build"
    try {
        Start-DCOSNetCIProcess -ProcessPath "MSBuild.exe" -LogFileName "libsodium-build.log" `
                               -ArgumentList @('builds\msvc\vs2017\libsodium.sln', '/nologo', '/target:Build', '/p:Platform=x64', '/p:Configuration="DynRelease"') `
                               -BuildErrorMessage "Failed to build libsodium dependency"
    } finally {
        Pop-Location
    }
    $dynamicDir = Join-Path $DCOS_NET_LIBSODIUM_GIT_DIR "bin\x64\Release\v141\dynamic"
    $env:LDFLAGS=" /LIBPATH:$($dynamicDir -replace '\\', '/') libsodium.lib "
    $includeDir = Join-Path $DCOS_NET_LIBSODIUM_GIT_DIR "src/libsodium/include"
    $env:CFLAGS=" -I$($includeDir -replace '\\', '/') "
    $env:PATH = "$DCOS_NET_LIBSODIUM_GIT_DIR\bin\x64\Release\v141\dynamic;" + $env:PATH
    Write-Output "Successfully built libsodium"
}

function Start-DCOSNetBuild {
    Push-Location $DCOS_NET_GIT_REPO_DIR
    Write-Output "Starting the dcos-net build"
    try {
        Start-DCOSNetCIProcess -ProcessPath "escript.exe" -ArgumentList @(".\rebar3", "as", "windows", "release") `
                               -LogFileName "dcos-net-make.log" -BuildErrorMessage "dcos-net failed to build."
    } finally {
        Pop-Location
    }
    Write-Output "Successfully built dcos-net"
}

function Start-CommonTests {
    Push-Location $DCOS_NET_GIT_REPO_DIR
    Write-Output "Starting the dcos-net common tests"
    try {
        Start-DCOSNetCIProcess -ProcessPath "escript.exe" -LogFileName "dcos-net-common-tests.log" `
                               -ArgumentList @(".\rebar3", "as", "test,windows", "ct", "--suite=apps/dcos_dns/test/dcos_dns_SUITE") `
                               -BuildErrorMessage "dcos-net common tests run was not successful"
    } finally {
        Pop-Location
    }
    Write-Output "Successfully finished dcos-net common tests run"
}

function Start-EUnitTests {
    Push-Location $DCOS_NET_GIT_REPO_DIR
    Write-Output "Starting the dcos-net eunit tests"
    try {
        Start-DCOSNetCIProcess -ProcessPath "escript.exe" -ArgumentList @(".\rebar3", "as", "test", "eunit") `
                               -LogFileName "dcos-net-eunit-tests.log" `
                               -BuildErrorMessage "dcos-net eunit tests run was not successful"
    } finally {
        Pop-Location
    }
    Write-Output "Successfully finished dcos-net eunit tests run"
}

function Start-XrefTests {
    Push-Location $DCOS_NET_GIT_REPO_DIR
    Write-Output "Starting the dcos-net xref tests"
    try {
        Start-DCOSNetCIProcess -ProcessPath "escript.exe" -ArgumentList @(".\rebar3", "as", "test", "xref") `
                               -LogFileName "dcos-net-xref-tests.log" `
                               -BuildErrorMessage "dcos-net xref tests run was not successful"
    } finally {
        Pop-Location
    }
    Write-Output "Successfully finished dcos-net xref tests run"
}

function Start-CoverTests {
    Push-Location $DCOS_NET_GIT_REPO_DIR
    Write-Output "Starting the dcos-net coverage tests"
    try {
        Start-DCOSNetCIProcess -ProcessPath "escript.exe" -ArgumentList @(".\rebar3", "as", "test", "cover") `
                               -LogFileName "dcos-net-cover-tests.log" `
                               -BuildErrorMessage "dcos-net coverage tests run was not successful"
    } finally {
        Pop-Location
    }
    Write-Output "Successfully finished dcos-net coverage tests run"
}

function Start-DialyzerTests {
    Push-Location $DCOS_NET_GIT_REPO_DIR
    Write-Output "Starting the dcos-net dialyzer tests"
    try {
        Start-DCOSNetCIProcess -ProcessPath "escript.exe" -ArgumentList @(".\rebar3", "dialyzer") `
                               -LogFileName "dcos-net-dialyzer-tests.log" `
                               -BuildErrorMessage "dcos-net dialyzer tests run was not successful"
    } finally {
        Pop-Location
    }
    Write-Output "Successfully finished dcos-net dialyzer tests run"
}

function Start-EdocTests {
    Push-Location $DCOS_NET_GIT_REPO_DIR
    Write-Output "Starting the dcos-net edoc tests"
    try {
        Start-DCOSNetCIProcess -ProcessPath "escript.exe" -ArgumentList @(".\rebar3", "edoc") `
                               -LogFileName "dcos-net-edoc-tests.log" `
                               -BuildErrorMessage "dcos-net edoc tests run was not successful"
    } finally {
        Pop-Location
    }
    Write-Output "Successfully finished dcos-net edoc tests run"
}

function New-DCOSNetPackage {
    Copy-Item -Recurse "$DCOS_NET_GIT_REPO_DIR\_build\windows\rel\dcos-net\*" "${DCOS_NET_BUILD_RELEASE_DIR}\"
    Copy-Item "$DCOS_NET_LIBSODIUM_GIT_DIR\bin\x64\Release\v141\dynamic\libsodium.dll" "${DCOS_NET_BUILD_RELEASE_DIR}\bin\"
    New-Item -ItemType "Directory" -Path "${DCOS_NET_BUILD_RELEASE_DIR}\config.d"
    New-Item -ItemType "Directory" -Path "${DCOS_NET_BUILD_RELEASE_DIR}\lashup"
    New-Item -ItemType "Directory" -Path "${DCOS_NET_BUILD_RELEASE_DIR}\mnesia"
    $archivePath = Join-Path $DCOS_NET_BUILD_OUT_DIR "release.zip"
    Start-ExternalCommand  {& 7z.exe a -tzip $archivePath "$DCOS_NET_BUILD_RELEASE_DIR\*" -sdel } -ErrorMessage "Failed to compress the dcos-net build directory"
    Remove-Item $DCOS_NET_BUILD_RELEASE_DIR
}

function Copy-FilesToRemoteServer {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$LocalFilesPath,
        [Parameter(Mandatory=$true)]
        [string]$RemoteFilesPath
    )
    Write-Output "Started copying files from $LocalFilesPath to remote location at ${server}:${RemoteFilesPath}"
    Start-SCPCommand -Server $STORAGE_SERVER_ADDRESS -User $STORAGE_SERVER_USER -Key $env:SSH_KEY `
                     -LocalPath $LocalFilesPath -RemotePath $RemoteFilesPath
}

function New-RemoteDirectory {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$RemoteDirectoryPath
    )
    $remoteCMD = "if [[ -d $RemoteDirectoryPath ]]; then rm -rf $RemoteDirectoryPath; fi; mkdir -p $RemoteDirectoryPath"
    Start-SSHCommand -Server $STORAGE_SERVER_ADDRESS -User $STORAGE_SERVER_USER -Key $env:SSH_KEY -Command $remoteCMD
}

function New-RemoteSymlink {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$RemotePath,
        [Parameter(Mandatory=$false)]
        [string]$RemoteSymlinkPath
    )
    $remoteCMD = "if [[ -h $RemoteSymlinkPath ]]; then unlink $RemoteSymlinkPath; fi; ln -s $RemotePath $RemoteSymlinkPath"
    Start-SSHCommand -Server $STORAGE_SERVER_ADDRESS -User $STORAGE_SERVER_USER -Key $env:SSH_KEY -Command $remoteCMD
}

function New-RemoteLatestSymlinks {
    $remoteDirPath = Get-RemoteBuildDirectoryPath
    $latestPath = "${ARTIFACTS_DIRECTORY}/${env:JOB_NAME}/latest-net-build"
    New-RemoteSymlink -RemotePath $remoteDirPath -RemoteSymlinkPath $latestPath
}

function Start-LogServerFilesUpload {
    $consoleUrl = "${env:JENKINS_URL}/job/${env:JOB_NAME}/${env:BUILD_NUMBER}/consoleText"
    Start-FileDownload -User ${env:JENKINS_USER} -Password ${env:JENKINS_PASSWORD} `
                       -URL $consoleUrl -Destination "$DCOS_NET_BUILD_LOGS_DIR\console-jenkins.log"
    $remoteDirPath = Get-RemoteBuildDirectoryPath
    New-RemoteDirectory -RemoteDirectoryPath $remoteDirPath
    Copy-FilesToRemoteServer "$DCOS_NET_BUILD_OUT_DIR\*" $remoteDirPath
    $buildOutputsUrl = Get-BuildOutputsUrl
    $global:PARAMETERS["BUILD_OUTPUTS_URL"] = $buildOutputsUrl
    Write-Output "Build artifacts can be found at: $buildOutputsUrl"
    if($global:PARAMETERS["BUILD_STATUS"] -eq 'PASS') {
        New-RemoteLatestSymlinks
    }
}

function Start-EnvironmentCleanup {
    # Stop any potential hanging process
    $processNames = @('make', 'erl', 'escript')
    $processNames | Foreach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
    cmd.exe /C "rmdir /s /q $DCOS_NET_DIR > nul 2>&1"
}

function New-ParametersFile {
    if(Test-Path $ParametersFile) {
        Remove-Item -Force $ParametersFile
    }
    New-Item -ItemType File -Path $ParametersFile | Out-Null
}

function Write-ParametersFile {
    if($global:PARAMETERS["LOGS_URLS"]) {
        $global:PARAMETERS["LOGS_URLS"] = $global:PARAMETERS["LOGS_URLS"] -join '|'
    }
    $json = ConvertTo-Json -InputObject $global:PARAMETERS
    Set-Content -Path $ParametersFile -Value $json
}


try {
    New-ParametersFile
    New-Environment
    Start-LibsodiumBuild
    Start-DCOSNetBuild
    Start-EUnitTests
    Start-CommonTests
    Start-XrefTests
    Start-CoverTests
    Start-DialyzerTests
    Start-EdocTests
    New-DCOSNetPackage
    $global:PARAMETERS["BUILD_STATUS"] = 'PASS'
    $global:PARAMETERS["MESSAGE"] = "dcos-net build and testing were successful."
} catch {
    Write-Output $_.ToString()
    Write-Output $_.ScriptStackTrace
    $global:PARAMETERS["BUILD_STATUS"] = 'FAIL'
    $global:PARAMETERS["MESSAGE"] = $_.ToString()
    exit 1
} finally {
    Start-LogServerFilesUpload
    Write-ParametersFile
    Start-EnvironmentCleanup
}
exit 0

using module .\AppProjectInfo.class.psm1
using module .\ALGoProjectInfo.class.psm1

<#
Creates a new dev env.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'local build')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'local build')]
[CmdletBinding(DefaultParameterSetName = 'ProjectPaths')]
param(
    [Parameter(Mandatory = $false)]
    [string] $containerName = "BC-$(Get-Date -Format 'yyyyMMdd')",

    [Parameter(Mandatory = $false)]
    [string] $userName = 'admin',

    [Parameter(Mandatory = $false)]
    [string] $password = 'P@ssword1',

    [Parameter(Mandatory = $true, ParameterSetName = 'ProjectPaths')]
    [string[]] $projectPaths,

    [Parameter(Mandatory = $true, ParameterSetName = 'WorkspacePath')]
    [string] $workspacePath,

    [Parameter(Mandatory = $true, ParameterSetName = 'ALGoProject')]
    [string] $alGoProject,

    [Parameter(Mandatory = $false)]
    [string] $packageCacheFolder = ".artifactsCache"
)

function InstallBCContainerHelper {
    if (-not (Get-Module -ListAvailable -Name "BCContainerHelper")) {
        Write-Host "BCContainerHelper module not found. Installing..."
        Install-Module -Name "BCContainerHelper" -Scope CurrentUser -AllowPrerelease -Force
    }

    Import-Module "BCContainerHelper" -DisableNameChecking
}

function CreateBCContainer {
    $containerExist = $null -ne $(docker ps -q -f name="$script:containerName")

    if ($containerExist) {
        Write-Host "Container $script:containerName already exists."
        return
    }

    Write-Host "Creating container $script:containerName"

    $bcArtifactUrl = Get-ConfigValue -Key "artifact" -ConfigType AL-Go

    $newContainerParams = @{
        "accept_eula" = $true
        "accept_insiderEula" = $true
        "containerName" = "$script:containerName"
        "artifactUrl" = $bcArtifactUrl
        "Credential" = $script:credential
        "auth" = "UserPassword"
        "additionalParameters" = @("--volume ""$($script:baseFolder):c:\sources""")
    }

    $newBCContainerScript = Join-Path $script:baseFolder "build\scripts\NewBcContainer.ps1" -Resolve
    . $newBCContainerScript -parameters $newContainerParams
}

function CreateCompilerFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string] $packageCacheFolder
    )
    $bcArtifactUrl = Get-ConfigValue -Key "artifact" -ConfigType AL-Go

    if(-not (Test-Path -Path $packageCacheFolder)) {
        Write-Host "Creating package cache folder $packageCacheFolder"
        New-Item -Path $packageCacheFolder -ItemType Directory | Out-Null
    }

    return New-BcCompilerFolder -artifactUrl $bcArtifactUrl -cacheFolder $packageCacheFolder
}

function GetAllApps {
    if($script:allApps) {
        return $script:allApps
    }

    # Get all AL-Go projects
    $alGoProjects = [ALGoProjectInfo]::FindAll($script:baseFolder)

    $appInfos = @()

    # Collect all apps from AL-Go projects
    foreach($alGoProject in $alGoProjects) {
        $appFolders = $alGoProject.GetAppFolders($true)

        foreach($appFolder in $appFolders) {
            $appInfo = [AppProjectInfo]::Get($appFolder, 'app')
            $appInfos += $appInfo
        }

        $testAppFolders = $alGoProject.GetAppFolders($true)

        foreach($testAppFolder in $testAppFolders) {
            $testAppInfo = [AppProjectInfo]::Get($testAppFolder, 'test')
            $appInfos += $testAppInfo
        }
    }

    $script:allApps = $appInfos
    return $script:allApps
}

function ResolveFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string] $folder
    )

    if([System.IO.Path]::IsPathRooted($folder)) {
        return $folder
    }

    return Join-Path $script:baseFolder $folder
}

function ResolveProjectPaths {
    param(
        [Parameter(Mandatory = $false)]
        [string[]] $projectPaths,

        [Parameter(Mandatory = $false)]
        [string] $workspacePath,

        [Parameter(Mandatory = $false)]
        [string] $alGoProject
    )

    if($projectPaths) {
        return $projectPaths
    }

    if($workspacePath) {
        $workspacePath = ResolveFolder -folder $workspacePath

        $workspace = Get-Content -Path $workspacePath -Raw | ConvertFrom-Json
        $projectPaths = $workspace.folders | ForEach-Object { Join-Path $workspacePath $($_.path) } | Where-Object { Test-Path -Path $_ -PathType Container } | Where-Object { Test-Path -Path (Join-Path $_ "app.json") -PathType Leaf }

        return $projectPaths
    }

    if($alGoProject) {
        $alGoProject = ResolveFolder -folder $alGoProject
        $alGoProjectInfo = [ALGoProjectInfo]::Get($alGoProject)

        return $alGoProjectInfo.GetAppFolders($true)
    }

    throw "Either projectPaths, workspacePath or alGoProject must be specified"
}

function BuildApp {
    param(
        [Parameter(Mandatory = $true)]
        [string] $appProjectFolder,

        [Parameter(Mandatory = $true)]
        [string] $packageCacheFolder
    )

    $appProjectFolder = ResolveFolder -folder $appProjectFolder

    $appInfo = [AppProjectInfo]::Get($appProjectFolder)
    $appFile = $appInfo.GetAppFileName()

    if(Test-Path (Join-Path $packageCacheFolder $appFile)) {
        Write-Host "App $appFile already exists in $packageCacheFolder. Skipping..."
        return (Join-Path $packageCacheFolder $appFile -Resolve)
    }

    $allAppInfos = GetAllApps

    # Build dependencies
    foreach($dependency in $appInfo.AppJson.dependencies) {
        $dependencyAppInfo = $allAppInfos | Where-Object { $_.Id -eq $dependency.id }
        $dependencyAppFile = BuildApp -appProjectFolder $dependencyAppInfo.AppProjectFolder -packageCacheFolder $packageCacheFolder
        PublishApp -appFile $dependencyAppFile
    }

    $compilerFolder = CreateCompilerFolder -packageCacheFolder $packageCacheFolder

    try {
        $appFile = Compile-AppWithBcCompilerFolder -compilerFolder $compilerFolder -appProjectFolder "$($appInfo.AppProjectFolder)" -appOutputFolder $packageCacheFolder -CopyAppToSymbolsFolder -appSymbolsFolder $packageCacheFolder
    }
    finally {
        Remove-Item -Path $compilerFolder -Recurse -Force | Out-Null
    }

    return $appFile
}

function PublishApp {
    param(
        [Parameter(Mandatory = $true)]
        [string] $appFile
    )

    Publish-BcContainerApp -containerName $script:containerName -appFile $appFile -syncMode ForceSync -sync -credential $script:credential -skipVerification -install -ignoreIfAppExists
}

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0
Import-Module "$PSScriptRoot\..\EnlistmentHelperFunctions.psm1"

$script:allApps = @()
[pscredential] $script:credential = New-Object System.Management.Automation.PSCredential ($userName, $(ConvertTo-SecureString $password -AsPlainText -Force))
$script:baseFolder = Get-BaseFolder
$script:packageCacheFolder = ResolveFolder -folder $packageCacheFolder
$script:containerName = $containerName

$projectPaths = ResolveProjectPaths -projectPaths $projectPaths -workspacePath $workspacePath -alGoProject $alGoProject

Write-Host "Loading BCContainerHelper module" -ForegroundColor Yellow
InstallBCContainerHelper

Write-Host "Creating container $script:containerName" -ForegroundColor Yellow
CreateBCContainer

foreach($currentProjectPath in $projectPaths) {
    Write-Host "Building app in $currentProjectPath" -ForegroundColor Yellow
    $appFile = BuildApp -appProjectFolder $currentProjectPath -packageCacheFolder $script:packageCacheFolder

    Write-Host "Publishing app $appFile to $script:containerName" -ForegroundColor Yellow
    PublishApp -appFile $appFile
}
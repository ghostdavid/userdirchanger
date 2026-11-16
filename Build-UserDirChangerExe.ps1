#Requires -Version 5.1
<#
.SYNOPSIS
    将中文启动脚本和迁移引擎编译为单个 UserDirChanger.exe。
.DESCRIPTION
    使用 Windows 自带的 .NET Framework C# 编译器，不下载第三方打包工具。
    EXE 运行时仍调用 Windows 11 自带的 Windows PowerShell 5.1。
#>
[CmdletBinding()]
param(
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $Root 'release\UserDirChanger.exe'
}
$LauncherSource = Join-Path $Root 'tools\UserDirChangerLauncher.cs'
$StartScript = Join-Path $Root 'Start-UserFolderMigration.ps1'
$EngineScript = Join-Path $Root 'Move-UserFolders.ps1'

foreach ($Path in @($LauncherSource, $StartScript, $EngineScript)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "构建所需文件不存在：$Path"
    }
}

$CompilerCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$Compiler = $CompilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $Compiler) {
    throw '未找到 Windows 自带的 .NET Framework C# 编译器，无法构建 EXE。'
}

$OutputFullPath = [IO.Path]::GetFullPath($OutputPath)
$OutputDirectory = Split-Path -Parent $OutputFullPath
if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$CompilerArguments = @(
    '/nologo',
    '/target:exe',
    '/platform:anycpu',
    '/optimize+',
    "/out:$OutputFullPath",
    "/resource:$StartScript,UserDirChanger.Start.ps1",
    "/resource:$EngineScript,UserDirChanger.Move.ps1",
    $LauncherSource
)

& $Compiler @CompilerArguments
if ($LASTEXITCODE -ne 0) {
    throw "C# 编译失败，退出码：$LASTEXITCODE"
}

Write-Host "已生成单文件程序：$OutputFullPath" -ForegroundColor Green
Write-Host '用户只需复制此 EXE；运行时需要 Windows 11 自带的 PowerShell 5.1。'

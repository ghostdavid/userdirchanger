#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 用户文件夹迁移工具的中文交互入口。
.NOTES
    版本：v1.0.2
#>
[CmdletBinding()]
param(
    [switch]$Preview,

    [ValidateNotNullOrEmpty()]
    [string]$DestinationRoot = "D:\Users\$env:USERNAME",

    [string[]]$Folders = @('Desktop', 'Documents', 'Downloads', 'Music', 'Pictures', 'Videos')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Version = '1.0.2'
$ExitCode = 0
$EnginePath = Join-Path $PSScriptRoot 'Move-UserFolders.ps1'

try {
    # powershell.exe -File 会把 Documents,Downloads 作为单个字符串传入。
    $ValidFolders = @('Desktop', 'Documents', 'Downloads', 'Music', 'Pictures', 'Videos')
    $Folders = @(
        $Folders |
            ForEach-Object { $_ -split ',' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    $InvalidFolders = @($Folders | Where-Object { $_ -notin $ValidFolders })
    if ($InvalidFolders.Count -gt 0) {
        throw "不支持的文件夹：$($InvalidFolders -join ', ')。可选值：$($ValidFolders -join ', ')"
    }
    if ($Folders.Count -eq 0) {
        throw '至少需要选择一个文件夹。'
    }

    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host "            Windows 用户文件夹迁移工具 v$Version" -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "当前账户：$env:USERNAME"
    Write-Host "目标根目录：$DestinationRoot"
    if ($Preview) {
        Write-Host '当前模式：预览（不会复制文件或更改文件夹位置）' -ForegroundColor Yellow
    }
    else {
        Write-Host '当前模式：实际迁移（确认后执行）' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '请阅读以下提示：'
    Write-Host '  1. 非空的目标目录将与源目录合并，不会先被清空。'
    Write-Host '  2. 同名文件可能需要你选择替换、跳过或保留两个文件。'
    Write-Host '  3. 替换同名文件前，请备份目标磁盘中的重要数据。'
    Write-Host '  4. 源文件会保留，脚本不会自动删除旧副本。'
    Write-Host '  5. 仔细核对迁移计划，确认前不会执行实际迁移。'
    Write-Host ''

    if (-not (Test-Path -LiteralPath $EnginePath -PathType Leaf)) {
        throw "未找到主脚本：$EnginePath。请将两个 PS1 文件放在同一目录。"
    }

    $Parameters = @{
        AllowTargetMerge = $true
        WhatIf           = $Preview.IsPresent
        DestinationRoot  = $DestinationRoot
        Folders          = $Folders
    }
    & $EnginePath @Parameters
}
catch {
    $ExitCode = 1
    Write-Host ''
    Write-Host "运行失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "可查看日志目录：$env:LOCALAPPDATA\KnownFolderMigration" -ForegroundColor Yellow
}
finally {
    Write-Host ''
    if ($ExitCode -eq 0) {
        Write-Host '脚本已结束，请查看上方结果。' -ForegroundColor Cyan
    }
    else {
        Write-Host "脚本未正常完成，退出码：$ExitCode" -ForegroundColor Red
    }
    Read-Host '按 Enter 键关闭窗口' | Out-Null
}

exit $ExitCode

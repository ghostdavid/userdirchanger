#Requires -Version 5.1
<#
.SYNOPSIS
    将当前用户的 Windows 已知文件夹复制并重定向到另一个本地 NTFS 磁盘。

.DESCRIPTION
    使用 Windows IKnownFolderManager::Redirect，而不是直接修改注册表。
    默认迁移：桌面、文档、下载、音乐、图片、视频。
    源文件会保留；脚本不会删除源文件，也不会迁移整个用户配置文件或 AppData。
    每个目标文件夹必须不存在或为空，除非显式指定 -AllowTargetMerge。

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Move-UserFolders.ps1 -WhatIf

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Move-UserFolders.ps1

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Move-UserFolders.ps1 -Folders Documents,Downloads,Music,Pictures,Videos
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateNotNullOrEmpty()]
    [string]$DestinationRoot = "D:\Users\$env:USERNAME",

    [string[]]$Folders = @('Desktop', 'Documents', 'Downloads', 'Music', 'Pictures', 'Videos'),

    [switch]$AllowTargetMerge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:LogFile = $null

$KnownFolderIds = @{
    Desktop   = [Guid]'B4BFCC3A-DB2C-424C-B029-7FE99A87C641'
    Documents = [Guid]'FDD39AD0-238F-46AF-ADB4-6C85480369C7'
    Downloads = [Guid]'374DE290-123F-4565-9164-39C4925E467B'
    Music     = [Guid]'4BD8D571-6D19-48D3-BE97-422220080E43'
    Pictures  = [Guid]'33E28130-4E1E-4676-835A-98395C3BC3BB'
    Videos    = [Guid]'18989B1D-99B5-455B-841C-AB7C74E4DDFC'
}

$FolderDisplayNames = @{
    Desktop   = '桌面'
    Documents = '文档'
    Downloads = '下载'
    Music     = '音乐'
    Pictures  = '图片'
    Videos    = '视频'
}

function Write-RunLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error'   { Write-Host $Message -ForegroundColor Red }
        default   { Write-Host $Message }
    }

    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
}

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $fullPath = [IO.Path]::GetFullPath($expanded)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $root.Length) {
        $fullPath = $fullPath.TrimEnd('\')
    }
    return $fullPath
}

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path1,
        [Parameter(Mandatory = $true)][string]$Path2
    )
    return [string]::Equals(
        (Get-NormalizedPath $Path1),
        (Get-NormalizedPath $Path2),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Child
    )

    $normalizedParent = Get-NormalizedPath $Parent
    $normalizedChild = Get-NormalizedPath $Child
    if (Test-SamePath $normalizedParent $normalizedChild) {
        return $true
    }

    $prefix = $normalizedParent.TrimEnd('\') + '\'
    return $normalizedChild.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-TreeSize {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        return [long]0
    }

    $rootItem = Get-Item -LiteralPath $Root -Force
    if (-not $rootItem.PSIsContainer) {
        throw "已知文件夹路径不是目录：$Root"
    }

    $total = [long]0
    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pending.Push([System.IO.DirectoryInfo]$rootItem)

    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($file in $directory.EnumerateFiles()) {
            $total += [long]$file.Length
        }
        foreach ($subdirectory in $directory.EnumerateDirectories()) {
            # 不穿越交接点或符号链接，避免递归及重复计算。
            if (($subdirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                $pending.Push($subdirectory)
            }
        }
    }
    return $total
}

$NativeSource = @'
using System;
using System.Runtime.InteropServices;

namespace UserFolderMigration
{
    [ComImport]
    [Guid("8BE2D872-86AA-4D47-B776-32CCA40C7018")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IKnownFolderManager
    {
        void FolderIdFromCsidl(int nCsidl, out Guid pfid);
        void FolderIdToCsidl(ref Guid rfid, out int pnCsidl);
        void GetFolderIds(out IntPtr ppKFId, ref uint pCount);
        void GetFolder(ref Guid rfid, out IntPtr ppkf);
        void GetFolderByName([MarshalAs(UnmanagedType.LPWStr)] string pszCanonicalName, out IntPtr ppkf);
        void RegisterFolder(ref Guid rfid, IntPtr pKFD);
        void UnregisterFolder(ref Guid rfid);
        void FindFolderFromPath([MarshalAs(UnmanagedType.LPWStr)] string pszPath, int mode, out IntPtr ppkf);
        void FindFolderFromIDList(IntPtr pidl, out IntPtr ppkf);

        [PreserveSig]
        int Redirect(
            ref Guid rfid,
            IntPtr hwnd,
            uint flags,
            [MarshalAs(UnmanagedType.LPWStr)] string pszTargetPath,
            uint cFolders,
            IntPtr pExclusion,
            out IntPtr ppszError);
    }

    [ComImport]
    [Guid("4DF0C730-DF9D-4AE3-9153-AA6B82E9795A")]
    internal class KnownFolderManager
    {
    }

    public static class KnownFolderNative
    {
        private const uint KF_REDIRECT_WITH_UI = 0x20;
        private const uint KF_REDIRECT_COPY_CONTENTS = 0x200;

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHGetKnownFolderPath(
            ref Guid rfid,
            uint dwFlags,
            IntPtr hToken,
            out IntPtr ppszPath);

        [DllImport("ole32.dll")]
        private static extern void CoTaskMemFree(IntPtr pv);

        public static string GetPath(Guid folderId)
        {
            IntPtr pathPointer = IntPtr.Zero;
            int hr = SHGetKnownFolderPath(ref folderId, 0, IntPtr.Zero, out pathPointer);
            try
            {
                if (hr != 0)
                {
                    Marshal.ThrowExceptionForHR(hr);
                }
                string path = Marshal.PtrToStringUni(pathPointer);
                if (string.IsNullOrEmpty(path))
                {
                    throw new InvalidOperationException("Windows returned an empty known-folder path.");
                }
                return path;
            }
            finally
            {
                if (pathPointer != IntPtr.Zero)
                {
                    CoTaskMemFree(pathPointer);
                }
            }
        }

        public static void CopyAndRedirect(Guid folderId, string targetPath)
        {
            IKnownFolderManager manager = null;
            IntPtr errorPointer = IntPtr.Zero;
            try
            {
                manager = (IKnownFolderManager)new KnownFolderManager();
                int hr = manager.Redirect(
                    ref folderId,
                    IntPtr.Zero,
                    KF_REDIRECT_COPY_CONTENTS | KF_REDIRECT_WITH_UI,
                    targetPath,
                    0,
                    IntPtr.Zero,
                    out errorPointer);

                string nativeError = errorPointer == IntPtr.Zero
                    ? null
                    : Marshal.PtrToStringUni(errorPointer);

                if (hr != 0)
                {
                    string message = string.Format(
                        "Known-folder redirection failed (HRESULT 0x{0:X8}). {1}",
                        hr,
                        nativeError);
                    throw new COMException(message.Trim(), hr);
                }
            }
            finally
            {
                if (errorPointer != IntPtr.Zero)
                {
                    CoTaskMemFree(errorPointer);
                }
                if (manager != null)
                {
                    Marshal.FinalReleaseComObject(manager);
                }
            }
        }
    }
}
'@

try {
    if (-not ('UserFolderMigration.KnownFolderNative' -as [type])) {
        Add-Type -TypeDefinition $NativeSource -Language CSharp
    }

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw '此脚本只能在 Windows 上运行。'
    }

    # 兼容 powershell.exe -File 传入的逗号分隔文件夹列表。
    $Folders = @(
        $Folders |
            ForEach-Object { $_ -split ',' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    $InvalidFolders = @($Folders | Where-Object { -not $KnownFolderIds.ContainsKey($_) })
    if ($InvalidFolders.Count -gt 0) {
        throw "不支持的文件夹：$($InvalidFolders -join ', ')"
    }
    if ($Folders.Count -eq 0) {
        throw '至少需要选择一个文件夹。'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warning "当前处于管理员提升上下文。请确认这是要迁移的账户：$($identity.Name)。不要以另一个管理员账户的凭据运行。"
    }

    $DestinationRoot = Get-NormalizedPath $DestinationRoot
    if ($DestinationRoot.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw '目标必须是本地固定磁盘，不能使用 UNC 网络路径。'
    }

    $destinationDriveRoot = [IO.Path]::GetPathRoot($DestinationRoot)
    $drive = [System.IO.DriveInfo]::new($destinationDriveRoot)
    if (-not $drive.IsReady) {
        throw "目标磁盘未就绪：$destinationDriveRoot"
    }
    if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
        throw "目标必须是本地固定磁盘；当前类型为 $($drive.DriveType)：$destinationDriveRoot"
    }
    if (-not [string]::Equals($drive.DriveFormat, 'NTFS', [StringComparison]::OrdinalIgnoreCase)) {
        throw "目标磁盘必须为 NTFS；当前文件系统为 $($drive.DriveFormat)：$destinationDriveRoot"
    }

    $criticalTargets = @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($criticalTarget in $criticalTargets) {
        if (Test-PathWithin $criticalTarget $DestinationRoot) {
            throw "目标根目录不能位于系统或程序目录内：$DestinationRoot"
        }
    }

    $cloudRoots = New-Object 'System.Collections.Generic.List[string]'
    $cloudVariableNames = @('OneDrive', 'OneDriveCommercial', 'OneDriveConsumer')
    foreach ($name in $cloudVariableNames) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $cloudRoots.Add((Get-NormalizedPath $value))
        }
        $userValue = [Environment]::GetEnvironmentVariable($name, 'User')
        if (-not [string]::IsNullOrWhiteSpace($userValue)) {
            $cloudRoots.Add((Get-NormalizedPath $userValue))
        }
    }
    foreach ($cloudRoot in @($cloudRoots | Select-Object -Unique)) {
        if (Test-PathWithin $cloudRoot $DestinationRoot) {
            throw "目标不能位于 OneDrive 同步目录内：$cloudRoot"
        }
    }

    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $Folders) {
        $source = Get-NormalizedPath ([UserFolderMigration.KnownFolderNative]::GetPath($KnownFolderIds[$name]))
        $target = Get-NormalizedPath (Join-Path $DestinationRoot $name)

        $criticalSources = @(
            $env:USERPROFILE,
            $env:APPDATA,
            $env:LOCALAPPDATA,
            $env:WINDIR,
            [IO.Path]::GetPathRoot($source)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        foreach ($criticalSource in $criticalSources) {
            if (Test-SamePath $source $criticalSource) {
                throw "$($FolderDisplayNames[$name]) 的当前路径异常，可能指向整个配置文件或磁盘根目录，已停止：$source"
            }
        }

        if (Test-PathWithin $source $DestinationRoot) {
            throw "目标根目录不能位于待迁移源目录内：$source"
        }

        $alreadyRedirected = Test-SamePath $source $target
        $targetState = $(if ($alreadyRedirected) { 'AlreadyRedirected' } else { 'Missing' })
        if (-not $alreadyRedirected) {
            foreach ($cloudRoot in @($cloudRoots | Select-Object -Unique)) {
                if (Test-PathWithin $cloudRoot $source) {
                    throw "$($FolderDisplayNames[$name]) 当前由 OneDrive 接管（$source）。请先在 OneDrive 设置中停止该文件夹备份，确认路径已恢复且文件完整，再运行本脚本。"
                }
            }

            if (Test-Path -LiteralPath $target) {
                $targetItem = Get-Item -LiteralPath $target -Force
                if (-not $targetItem.PSIsContainer) {
                    throw "目标路径已被同名文件占用：$target"
                }
                $targetState = 'Empty'
                $hasContent = [bool](Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1)
                if ($hasContent) {
                    if (-not $AllowTargetMerge) {
                        throw "目标目录非空，为避免合并或覆盖已停止：$target。请改用空目录，或在确认风险后显式使用 -AllowTargetMerge。"
                    }
                    $targetState = 'NonEmptyMerge'
                }
            }
        }

        $plan.Add([pscustomobject]@{
            Name          = $name
            DisplayName   = $FolderDisplayNames[$name]
            Source        = $source
            Target        = $target
            TargetState   = $targetState
            SourceBytes   = [long]0
            Status        = $(if ($alreadyRedirected) { 'AlreadyRedirected' } else { 'Ready' })
            Message       = ''
        })
    }

    # 嵌套的源已知文件夹会造成重复复制和语义冲突，拒绝自动处理。
    for ($i = 0; $i -lt $plan.Count; $i++) {
        for ($j = $i + 1; $j -lt $plan.Count; $j++) {
            if ((Test-PathWithin $plan[$i].Source $plan[$j].Source) -or
                (Test-PathWithin $plan[$j].Source $plan[$i].Source)) {
                throw "所选已知文件夹的当前源路径存在嵌套，已停止：$($plan[$i].Source) 与 $($plan[$j].Source)"
            }
        }
    }

    $readyItems = @($plan | Where-Object { $_.Status -eq 'Ready' })
    if ($readyItems.Count -gt 0) {
        [long]$requiredBytes = 0
        foreach ($item in $readyItems) {
            try {
                $item.SourceBytes = Get-TreeSize $item.Source
                $requiredBytes += $item.SourceBytes
            }
            catch {
                throw "无法完整读取源目录：$($item.Source)。请检查该目录及子目录的读取权限，或先只选择其他文件夹。详细信息：$($_.Exception.Message)"
            }
        }
        $requiredBytes += [long][Math]::Max([long]256MB, [long][Math]::Ceiling($requiredBytes * 0.05))
        if ($drive.AvailableFreeSpace -lt $requiredBytes) {
            throw "目标磁盘可用空间不足。估算至少需要 $([Math]::Ceiling($requiredBytes / 1MB)) MiB，当前可用 $([Math]::Floor($drive.AvailableFreeSpace / 1MB)) MiB。"
        }
    }

    Write-Host ''
    $plan |
        Select-Object `
            @{ Name = '文件夹'; Expression = { $_.DisplayName } },
            @{ Name = '当前位置'; Expression = { $_.Source } },
            @{ Name = '目标位置'; Expression = { $_.Target } },
            @{ Name = '目标状态'; Expression = {
                switch ($_.TargetState) {
                    'Missing'           { '目标不存在，将新建' }
                    'Empty'             { '目标为空' }
                    'NonEmptyMerge'     { '目标非空，将合并' }
                    'AlreadyRedirected' { '已在目标位置' }
                }
            } },
            @{ Name = '处理状态'; Expression = {
                if ($_.Status -eq 'AlreadyRedirected') { '无需处理' } else { '等待确认' }
            } } |
        Format-Table -AutoSize | Out-Host

    if ($readyItems.Count -eq 0) {
        Write-Host '所选文件夹已经位于目标路径，无需更改。'
        return
    }

    $mergeItems = @($readyItems | Where-Object { $_.TargetState -eq 'NonEmptyMerge' })
    if ($mergeItems.Count -gt 0) {
        Write-Warning "有 $($mergeItems.Count) 个目标目录非空，将与源目录合并，不会先清空目标目录。"
        foreach ($item in $mergeItems) {
            Write-Host "  - $($item.DisplayName)：$($item.Target)"
        }
        Write-Warning '如出现同名文件冲突，请在 Windows 复制对话框中逐项核对；选择替换前请确认已有 D 盘数据备份。'
    }

    $operation = "复制内容并重定向 $($readyItems.Count) 个已知文件夹到 $DestinationRoot（保留源文件）"
    if (-not $PSCmdlet.ShouldProcess("$($identity.Name)", $operation)) {
        if ($WhatIfPreference) {
            Write-Host '预览完成，未复制文件或更改文件夹位置。去掉 -WhatIf 后才会实际迁移。'
        }
        else {
            Write-Host '已取消操作，未复制文件或更改文件夹位置。'
        }
        return
    }

    $runId = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logDirectory = Join-Path $env:LOCALAPPDATA "KnownFolderMigration\$runId"
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $script:LogFile = Join-Path $logDirectory 'migration.log'
    $manifestPath = Join-Path $logDirectory 'migration-plan.json'
    $registryBackup = Join-Path $logDirectory 'User-Shell-Folders-before.reg'

    Write-RunLog "当前账户：$($identity.Name)"
    Write-RunLog "目标根目录：$DestinationRoot"
    Write-RunLog '在更改前备份当前用户文件夹配置和路径清单。'

    & reg.exe export 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' $registryBackup /y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "无法备份用户文件夹配置，尚未执行迁移。reg.exe 退出码：$LASTEXITCODE"
    }
    $plan | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    if (-not (Test-Path -LiteralPath $DestinationRoot)) {
        New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    }

    try {
        foreach ($item in $readyItems) {
            try {
                Write-RunLog "开始迁移 $($item.DisplayName)：$($item.Source) -> $($item.Target)"
                [UserFolderMigration.KnownFolderNative]::CopyAndRedirect($KnownFolderIds[$item.Name], $item.Target)

                $actualPath = Get-NormalizedPath ([UserFolderMigration.KnownFolderNative]::GetPath($KnownFolderIds[$item.Name]))
                if (-not (Test-SamePath $actualPath $item.Target)) {
                    throw "系统返回的新路径与目标不一致：$actualPath"
                }
                if (-not (Test-Path -LiteralPath $item.Target -PathType Container)) {
                    throw "重定向后目标目录不存在：$($item.Target)"
                }

                $item.Status = 'RedirectedSourceRetained'
                Write-RunLog "完成 $($item.DisplayName)。源内容保留在：$($item.Source)"
            }
            catch {
                $item.Status = 'Failed'
                $item.Message = $_.Exception.Message
                Write-RunLog "$($item.DisplayName) 迁移失败：$($item.Message)" -Level Error
                throw "迁移已停止。已完成的重定向不会自动回滚，源文件未删除。详情及原始路径清单：$logDirectory"
            }
        }
    }
    finally {
        $plan | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    }

    Write-RunLog '所有所选文件夹均已重定向。'
    Write-RunLog "源文件未删除。请注销并重新登录，验证应用及文件完整后，再自行清理旧的 C 盘副本。"
    Write-RunLog "日志和原始路径清单保存在：$logDirectory"
}
catch {
    Write-Host ''
    Write-Host "操作未完成：$($_.Exception.Message)" -ForegroundColor Red
    throw
}

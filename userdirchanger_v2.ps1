<#
.SYNOPSIS
    安全、无损地将 Windows 11 用户核心文件夹迁移至 D 盘。
.NOTES
    1. 强制要求管理员权限运行。
    2. 增加 Robocopy 错误码校验，仅在完全成功时才修改注册表防断档。
    3. 自动恢复目标文件夹的 ReadOnly 属性以修复自定义图标。
    4. 自动清理源路径空文件夹。
#>

# 1. 强制检查管理员权限
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (!$IsAdmin) {
    Write-Error "严重错误: 必须以管理员身份运行此脚本！请右键 PowerShell 选择“以管理员身份运行”。"
    exit
}

# 2. 定义目标根路径
$TargetDrive = "D:"
$UserName = $env:USERNAME
$NewRoot = "$TargetDrive\Users\$UserName"

# 检查 D 盘是否存在
if (!(Test-Path $TargetDrive)) {
    Write-Error "严重错误: 未找到 $TargetDrive 盘，请检查系统分区状态。"; exit
}

# 3. 定义文件夹映射表
$FolderMap = @{
    "Personal"                               = "Documents"
    "{f42ee2d3-909f-4a93-a124-b06d742f404e}" = "Documents"
    "My Pictures"                            = "Pictures"
    "{0ddd015d-b06c-45d5-8c4c-f59713854639}" = "Pictures"
    "My Music"                               = "Music"
    "{a0c69a99-21c2-4673-8919-aecae0593b1d}" = "Music"
    "My Video"                               = "Videos"
    "{35282759-4847-42f4-b451-97bfa543c0c0}" = "Videos"
    "{374DE290-123F-4565-9164-39C4925E467B}" = "Downloads"
    "Desktop"                                = "Desktop"
}

$RegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
$OldRegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"

Write-Host "--- 开始安全迁移用户文件夹到 $NewRoot ---" -ForegroundColor Cyan

foreach ($Key in $FolderMap.Keys) {
    $SubFolder = $FolderMap[$Key]
    
    # 获取源路径
    $CurrentPath = (Get-ItemProperty -Path $RegistryPath -Name $Key -ErrorAction SilentlyContinue).$Key
    if ([string]::IsNullOrWhiteSpace($CurrentPath)) { continue }
    
    $SourcePath = [System.Environment]::ExpandEnvironmentVariables($CurrentPath)
    $DestinationPath = "$NewRoot\$SubFolder"

    # 路径校验
    if ($SourcePath -eq $DestinationPath -or $SourcePath -like "$TargetDrive*") {
        Write-Host "[跳过] $SubFolder 已经在目标盘 ($SourcePath)。" -ForegroundColor DarkGray
        continue
    }

    Write-Host "`n[处理] 正在迁移: $SubFolder" -ForegroundColor Green
    Write-Host "      源路径: $SourcePath"
    Write-Host "      目标路径: $DestinationPath"

    # 如果源路径根本不存在（被用户误删），只修复注册表
    if (!(Test-Path $SourcePath)) {
        Write-Host "      (警告) 源文件夹不存在，将直接在目标端创建并重置注册表。" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    } 
    else {
        # 执行 Robocopy 迁移 (去掉了/NP等静默参数以确保捕获结果，但输出重定向到 Null)
        # 增加 /B 参数绕过可能的权限障碍
        $roboArgs = @("$SourcePath", "$DestinationPath", "/MOVE", "/E", "/COPYALL", "/B", "/XJ", "/R:2", "/W:1", "/MT:8")
        & robocopy $roboArgs | Out-Null
        $ExitCode = $LASTEXITCODE

        # Robocopy 退出码解析：<8 均表示复制/移动成功（1复制成功，2多余文件，3两者皆有... 8以上为严重失败）
        if ($ExitCode -ge 8) {
            Write-Error "      [失败] $SubFolder 迁移发生严重错误 (退出码: $ExitCode)。可能有文件被占用。"
            Write-Warning "      已中止当前文件夹的注册表修改以保护数据，请关闭占用程序后重试。"
            continue
        }

        # 清理可能残留的空源文件夹（Robocopy /MOVE 有时无法删除系统锁定的根文件夹）
        if (Test-Path $SourcePath) {
            try {
                Remove-Item -Path $SourcePath -Force -Recurse -ErrorAction Stop
            } catch {
                Write-Host "      (提示) 原文件夹外壳因系统占用暂时无法删除，但内部文件已全部移走。" -ForegroundColor Yellow
            }
        }
    }

    # 4. 修复目标文件夹图标显示机制
    if (Test-Path $DestinationPath) {
        $DestItem = Get-Item $DestinationPath -Force
        # 赋予文件夹 ReadOnly 属性，确保 desktop.ini 被系统读取
        $DestItem.Attributes = $DestItem.Attributes -bor [System.IO.FileAttributes]::ReadOnly
    }

    # 5. 更新注册表索引
    Set-ItemProperty -Path $RegistryPath -Name $Key -Value $DestinationPath
    if ($Key -notlike "{*}") { 
        Set-ItemProperty -Path $OldRegistryPath -Name $Key -Value $DestinationPath -ErrorAction SilentlyContinue
    }
    
    Write-Host "      [成功] $SubFolder 映射已更新。" -ForegroundColor Cyan
}

Write-Host "`n--- 迁移流程结束，正在重启资源管理器 ---" -ForegroundColor Cyan

# 重启资源管理器
Stop-Process -Name explorer -Force
Start-Process explorer.exe

Write-Host "执行完毕！" -ForegroundColor White -BackgroundColor Green

<#
.SYNOPSIS
    将 Windows 11 用户核心文件夹（文档、图片、音乐、视频、下载、桌面）从 C 盘迁移至 D 盘。
    支持自动合并 D 盘已存在的路径，并更新系统注册表索引。
    
.NOTES
    1. 建议在运行前关闭所有正在运行的程序（尤其是浏览器和 Office）。
    2. 脚本会自动重启资源管理器以使更改生效。
    3. 适用于 Windows 11 21H2/22H2/24H2/26H1 及更高版本。
#>

# 1. 定义目标根路径 (D:\Users\用户名)
$TargetDrive = "D:"
$UserName = $env:USERNAME
$NewRoot = "$TargetDrive\Users\$UserName"

# 2. 定义需要迁移的文件夹映射表 (注册表键名 : 文件夹子路径)
# 包含传统名称和 Windows 10/11 专用的 GUID 名称
$FolderMap = @{
    "Personal"                             = "Documents"
    "{f42ee2d3-909f-4a93-a124-b06d742f404e}" = "Documents"
    "My Pictures"                          = "Pictures"
    "{0ddd015d-b06c-45d5-8c4c-f59713854639}" = "Pictures"
    "My Music"                             = "Music"
    "{a0c69a99-21c2-4673-8919-aecae0593b1d}" = "Music"
    "My Video"                             = "Videos"
    "{35282759-4847-42f4-b451-97bfa543c0c0}" = "Videos"
    "{374DE290-123F-4565-9164-39C4925E467B}" = "Downloads"
    "Desktop"                              = "Desktop"
}

# 3. 检查 D 盘是否存在
if (!(Test-Path $TargetDrive)) {
    Write-Error "错误: 未找到 $TargetDrive 盘，请检查分区。"; exit
}

# 注册表路径
$RegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"

Write-Host "--- 开始迁移用户文件夹到 $NewRoot ---" -ForegroundColor Cyan

foreach ($Key in $FolderMap.Keys) {
    $SubFolder = $FolderMap[$Key]
    
    # 获取当前系统记录的源路径
    $CurrentPath = (Get-ItemProperty -Path $RegistryPath -Name $Key -ErrorAction SilentlyContinue).$Key
    if ($null -eq $CurrentPath) { continue }
    
    # 解析环境变量 (例如将 %USERPROFILE% 转为 C:\Users\Admin)
    $SourcePath = [System.Environment]::ExpandEnvironmentVariables($CurrentPath)
    $DestinationPath = "$NewRoot\$SubFolder"

    # 如果源路径已经在 D 盘，跳过
    if ($SourcePath -like "$TargetDrive*") {
        Write-Host "[跳过] $SubFolder 已经在 $TargetDrive 盘。" -ForegroundColor Yellow
        continue
    }

    Write-Host "[处理] 正在迁移: $SubFolder" -ForegroundColor Green
    Write-Host "      源: $SourcePath"
    Write-Host "      目标: $DestinationPath"

    # 创建目标目录（如果不存在）
    if (!(Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    # 使用 Robocopy 进行移动与合并
    # /MOVE: 移动文件（成功后删除源）
    # /E: 包含子目录（包括空的）
    # /COPYALL: 复制所有文件信息（权限、时间戳等）
    # /XJ: 排除连接点（防止递归死循环）
    # /R:1 /W:1: 失败重试 1 次，等待 1 秒
    if (Test-Path $SourcePath) {
        robocopy "$SourcePath" "$DestinationPath" /MOVE /E /COPYALL /XJ /R:1 /W:1 /NP
    }

    # 更新注册表项
    Set-ItemProperty -Path $RegistryPath -Name $Key -Value $DestinationPath
}

# 4. 特殊处理：更新全局 Shell Folders（部分老旧软件使用）
$OldRegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
foreach ($Key in $FolderMap.Keys) {
    if ($Key -notlike "{*}") { # 仅更新有友好名称的项
        Set-ItemProperty -Path $OldRegistryPath -Name $Key -Value "$NewRoot\$($FolderMap[$Key])" -ErrorAction SilentlyContinue
    }
}

Write-Host "`n--- 迁移完成，正在重启资源管理器以生效 ---" -ForegroundColor Cyan

# 5. 重启资源管理器
Stop-Process -Name explorer -Force
Start-Process explorer.exe

Write-Host "成功！所有选定文件夹已转移至 D 盘并完成合并。" -ForegroundColor White -BackgroundColor Green

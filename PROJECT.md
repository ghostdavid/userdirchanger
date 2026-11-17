# 项目记忆

## 项目概况与现状

- **项目目标与版本**：UserDirChanger 是中文 Windows 用户文件夹迁移工具，当前版本为 v2026.11.16。默认处理当前账户的 Desktop、Documents、Downloads、Music、Pictures、Videos，目标根目录为 `D:\Users\$env:USERNAME`，各目标子目录使用对应英文名。
- **迁移语义**：当前实现是“复制内容并重定向”，不是移动后清理源目录。源文件保留，需由用户验证新位置和备份后自行清理；这一行为避免脚本自动删除旧副本，但会暂时占用双份空间。
- **系统接口**：`Move-UserFolders.ps1` 通过内嵌 C# 调用 `IKnownFolderManager::Redirect`，使用 `KF_REDIRECT_COPY_CONTENTS | KF_REDIRECT_WITH_UI`；获取路径使用 `SHGetKnownFolderPath`。注册表只通过 `reg.exe export` 备份，不作为重定向手段，由 Windows 接口负责已知文件夹变更。
- **处理边界**：仅处理六类已知文件夹，不迁移整个用户配置文件、AppData 或其他账户。管理员提升上下文只触发账户核对警告，并不要求使用其他账户凭据运行。
- **交付形态**：普通用户使用单个 `release/UserDirChanger.exe`；也可将 CMD 与两个 PS1 放在同一目录直接运行。EXE 内嵌启动脚本和迁移引擎，释放到当前用户临时目录中的随机子目录，调用系统 Windows PowerShell 5.1，返回子进程退出码并尽力清理临时目录。
- **构建方式**：`Build-UserDirChangerExe.ps1` 使用 Windows 自带的 .NET Framework v4 C# 编译器，生成 AnyCPU EXE，不依赖第三方打包工具。EXE 不是脱离 Windows 组件的独立运行时，仍依赖系统 PowerShell。
- **版本同步**：界面和文档使用带 `v` 的版本显示，C# 程序集版本字段使用不带 `v` 的数值形式。修改版本时须同步 `Start-UserFolderMigration.ps1`、`tools/UserDirChangerLauncher.cs`、`README.md` 和 `PROJECT.md`，并重建 EXE，否则内嵌脚本和程序集元数据仍是旧版本。

## 资料与文件地图

- `Move-UserFolders.ps1`：迁移引擎；包含参数校验、路径与磁盘预检、空间估算、Known Folder API、复制重定向、日志、清单和错误处理。
- `Start-UserFolderMigration.ps1`：中文交互入口；显示版本、账户、目标和风险提示，规范文件夹参数，调用迁移引擎，结束时暂停并返回退出码。
- `Run-UserFolderMigration.cmd`：三文件源码运行方式的基本入口；支持首个参数 `--preview`，高级参数应通过 PowerShell 入口传入。
- `tools/UserDirChangerLauncher.cs`：单文件 EXE 启动器；包含程序集版本、控制台标题、内嵌资源释放、PowerShell 查找、参数引用与转发、临时目录清理。
- `Build-UserDirChangerExe.ps1`：正式构建脚本；将两个 PS1 作为资源嵌入 EXE，默认输出到 `release/UserDirChanger.exe`。
- `README.md`：面向用户的介绍、准备、源码运行、预览、迁移、合并、日志恢复和限制说明。
- `docs/images/userdirchanger-preview.png`：README 的预览模式界面截图；本地界面示例及一次性采集工具使用已忽略的 `__ui_demo__/`。原始截图可能包含账户名、真实路径或文件名，公开图片仅使用脱敏示例，原始截图及采集工具不纳入版本控制。
- `release/UserDirChanger.exe`：本地手动发布的单文件 EXE，位于已忽略的 `release/`；内嵌资源 `UserDirChanger.Start.ps1` 和 `UserDirChanger.Move.ps1` 分别对应 `Start-UserFolderMigration.ps1` 和 `Move-UserFolders.ps1`。当前文件的版本元数据为 `2026.11.16`，两个内嵌脚本与对应源文件的 SHA-256 已静态核对一致；未启动 EXE 或验证真实迁移，源码变化后须重新核对。
- `.gitignore`：忽略 `__ui_demo__/`、本地测试与比较产物、运行日志、本地 `AGENTS.md` 和 `release/`；具体资料与产物见相关条目。
- `.gitattributes`：规定文本换行及 PNG、EXE 的二进制处理方式，其中 CMD 使用 CRLF。

## 规则与限制

- **目标安全边界**：目标必须位于已就绪的本地固定 NTFS 磁盘，拒绝 UNC 路径、系统或程序目录、OneDrive 同步目录及待迁移源目录内部。目标磁盘可用空间按所选源文件逻辑大小总和再加 `max(256 MiB, 5%)` 估算；计算目录大小时不进入目录交接点或符号链接。
- **源路径安全边界**：拒绝指向整个用户配置文件、AppData、系统目录或磁盘根目录的异常已知文件夹，也拒绝所选源目录相互嵌套，避免重复复制和语义冲突。OneDrive 检查基于相关环境变量；企业组策略和第三方同步软件仍可能改变结果。
- **合并策略差异**：EXE 和 `Start-UserFolderMigration.ps1` 固定传入 `AllowTargetMerge = $true`，允许非空目标在警告后合并；直接调用迁移引擎时默认拒绝非空目标，必须显式指定 `-AllowTargetMerge`。任何方式都不会预先清空目标。
- **同名文件与完整性**：复制界面由 Windows 提供，替换、跳过或保留两个文件由用户处理；总确认不等于同意覆盖所有文件。当前实现只验证重定向后的系统路径及目标目录存在，不做逐文件哈希或复制完整性证明，跳过文件需自行核对。
- **预览边界**：EXE 的 `--preview` 转为 PowerShell 的 `-Preview`，中文入口再向引擎传入 `WhatIf`；直接调用引擎可使用 `-WhatIf`。预览执行读取和安全检查，但在复制、注册表备份和日志创建之前返回，不能证明实际复制或重定向成功。
- **日志与失败恢复**：有待处理项目且确认实际迁移后，在 `%LOCALAPPDATA%\KnownFolderMigration\<时间戳>\` 写入 `migration.log`、`migration-plan.json` 和 `User-Shell-Folders-before.reg`。日志和路径清单可能包含账户名、真实路径或文件名。单项失败会停止后续处理，已完成的重定向不自动回滚；备份和清单仅供排查恢复，不是一键回滚机制。
- **运行时限制**：项目文档以 Windows 11 和 Windows PowerShell 5.1 为运行环境。EXE 不修改系统全局执行策略，而是对子进程使用 `-ExecutionPolicy Bypass`；不得将此描述为永久更改系统策略。
- **脚本编码**：含中文的 PS1 文件必须保留 UTF-8 BOM。已确认 Windows PowerShell 5.1 会将无 BOM 的 UTF-8 启动脚本按本地 ANSI 读取，造成乱码和解析失败；文本编辑后应核对 BOM，并通过最终 EXE 预览验证实际释放的脚本。
- **构建与验证限制**：源码修改后需通过正式构建脚本同步 EXE；构建成功不等于迁移功能验证。项目没有自动化测试，真实复制、同名冲突、部分失败及恢复不能由编译或预览代替验证，交付时须明确当次实际覆盖范围。

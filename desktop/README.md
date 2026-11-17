# Desktop 悬浮栏工具

Windows 桌面常驻悬浮栏，包含 C、AS、T 和工具（扳手图标）四个按钮。所有客户端、后台、服务端和测试源码均在本目录，不依赖原电脑的固定盘符。

## 四个按钮

| 按钮 | 功能 |
| --- | --- |
| C | 经确认和管理员授权后，关闭 Codex、ChatGPT、Claude 及确认归属它们的后台进程；多轮重新扫描，报告残留；保留悬浮栏、T 工具和无关系统进程。 |
| AS | 经确认后关闭 Android Studio、Gradle、ADB、模拟器及相关子进程。未保存的 IDE 内容可能丢失。 |
| T | 备忘录、AI 提示词、账号密码资料库。默认快速复制列表，支持搜索、分类、置顶、查看/编辑、三栏管理、加密备份及多电脑同步。记录里的网址可以点击，用默认浏览器打开。 |
| 工具 | 安卓开发小工具窗口：查看当前 Activity、查看任务栈、手机截图、截长图、导出蓝牙日志、显示蓝牙日志、停止 Gradle。连了多台手机时在顶部选择要用的那台。 |

### 工具按钮

- 和 T 一样只开一个窗口，显示在按钮正上方；窗口在最前时再点一次收起。
- **查看当前 Activity**：Activity 名称用粗体蓝字突出显示，下面是完整类名和包名；读不到 Activity 时改看焦点窗口，并附上 `dumpsys` 的原始行。
- **查看任务栈**：在单独的窗口里把手机上的每个任务栈画成一张卡片（最近使用的在前）。卡片标题是任务 ID、Activity 数量、应用包名，以及“前台 / 桌面 / 最近任务”标记；下面是一个开口朝上的“栈”，Activity 一块一块叠在里面，上面标“栈顶”、下面标“栈底”，正在显示的那块是蓝色。类名太长会截断，鼠标悬停在卡片上可看完整类名；“刷新”或 F5 重新读取。没有 Activity 的空容器（分屏、自由窗口）不画。
- **手机截图**：截取所选手机的屏幕，保存为桌面上的 `phone_screenshot_年月日_时分秒.png`，同时复制到剪贴板，并打开预览窗口。预览窗口里的“复制图片”随时可以再复制一次（例如中间复制过别的东西），也能打开图片或所在文件夹。
- **截长图**：先在手机上打开要截的页面并停在开头，再点按钮。工具会自动向下滑动、每屏截一张，按重叠的内容对齐后拼成一张长图（保存为 `phone_long_screenshot_*.png`，复制到剪贴板并预览）。滑到底部、达到 12 屏或点“停止截图”时结束；每屏大约 3.5 秒（要等滚动条消失，否则它会出现在长图里）。顶部标题栏只保留第一屏的，底部导航栏只保留一次；Samsung 列表在屏幕边缘画的圆角不会混进拼接处。页面里随滚动变化的内容（动画、视频、浮动按钮）可能在拼接处不完全一致。
- **停止 Gradle**：结束所有 Gradle 守护进程、Wrapper、工作进程和 Kotlin 编译守护进程，列出每个进程是否已结束。Android Studio 本身和其他 Java 程序不受影响。不需要先确认，正在进行的编译会中断。
- **导出蓝牙日志**：把手机上的日志目录复制到电脑。每台手机一个子文件夹，例如 `E:\BLELogs\Mi_10_a1b2c3d4\BLEBluetoothLog`，两台手机的日志不会混在一起；完成后打开该文件夹。
- **显示蓝牙日志**：打开一个占大半屏幕的窗口，像资源管理器一样浏览手机文件。顶部地址栏可以直接输入手机路径（例如 `/sdcard/Download`）后按 Enter，旁边是后退、前进、上一级和刷新按钮（快捷键 Alt+←、Alt+→、Backspace、F5）。双击文件夹打开，单击文件在右侧查看内容；刷新会重新读取当前文件，方便看不断增长的日志。打开时自动进入日志目录里最新的文件夹并显示最新的日志、滚到末尾；可以按文字筛选行。`[CONNECT]`、`[DISCONNECT]` 等标签补齐到同样宽度，后面的框线左边对齐。非文本文件和超过 64 MB 的文件不在这里显示。地址栏右边的“保存到电脑”（也可以右键或 Ctrl+S）把左边选中的文件或整个文件夹从手机复制到电脑：文件会弹出“另存为”可以改名，文件夹选一个目标位置；保存的是手机上的原文件，不受筛选影响，完成后在资源管理器里选中它。下次保存默认打开上次保存的文件夹。
- 手机上的日志目录和电脑上的导出位置可在窗口里修改，自动保存到 `%LOCALAPPDATA%\TNotes\dev-tools.json`；“默认”恢复为 `/sdcard/Android/data/com.enplus.caro_sdk/files/BLEBluetoothLog`。
- 需要 adb：先找 PATH，再找 `ANDROID_HOME`、`ANDROID_SDK_ROOT` 和 `%LOCALAPPDATA%\Android\Sdk`。

- 悬浮栏可拖动，保持置顶，并记住拖动后的位置（原来的屏幕拔掉后回到主屏右下角）；每分钟检查并恢复悬浮栏和本地笔记后台。
- 右键“退出悬浮按钮”是真正退出：守护任务不会再把它拉回来，下次登录或双击桌面 `Desktop Tools` 才恢复。悬浮栏意外崩溃仍会在一分钟内自动恢复。
- T 是开关：一次只开一个笔记窗口，窗口已在最前时再点一次收起，否则把它唤到最前。每次点 T，笔记窗口都显示在 T 按钮正上方（靠近屏幕边缘时贴边，上方放不下时显示在下方）；点窗口里的布局按钮切换到资料库大窗口时，窗口保持底边和中心位置放大，再点一次缩回原处，始终停在按钮上方。
- 笔记里的网址会自动变成蓝色链接：查看记录时，内容和标题里以 `http://`、`https://` 或 `www.` 开头的地址、以及账号密码的“网站”栏（写成 `github.com` 也行）都可以点击；速记列表里带网址的记录多一个“打开链接”按钮。链接由本地后台交给 Windows，用你的默认浏览器打开并切到前面，而不是在 T 窗口里打开。只接受 http / https 网页地址，不会打开本机文件或程序。
- 悬浮栏按钮统一使用蓝色系，不使用绿色。
- 悬浮栏的画面如果没画出来或意外丢失（例如登录时桌面还没准备好），会在几秒内自动重画；重画失败的记录写在 `%LOCALAPPDATA%\TNotes\toolbar-diagnostic.log`，只记时间和原因，不含笔记内容。
- 通过无窗口启动器运行，避免定时弹出黑色命令窗口。
- 笔记后台独立运行，不依赖 Codex 或 Claude 的存活。
- 点击 C 不会修改代理、系统安全设置或删除笔记文件，也不会把所有同名 Java / Runtime Broker 一概结束。

## 目录

```text
desktop/
  Install.ps1 / Uninstall.ps1       安装、启动项和任务管理
  Start-Desktop.vbs                 无控制台窗口启动整套悬浮栏
  Configure-Notes.ps1               当前电脑的私人同步配置
  codex-floating-button*.ps1        三按钮窗口、拖动和 Android 进程选择
  ai-process-cleanup*.ps1           AI 进程识别、权限处理和多轮清理
  codex-floating-watchdog.*         每分钟检查
  codex-network-check.ps1           保留的可选网络诊断辅助函数
  dev-tools/                        工具按钮的窗口（Activity / Gradle / 蓝牙日志），界面文字在 text.json
  config/                          不含真实地址的配置示例
  icons/                           悬浮栏图标和生成工具
  t-notes/
    Launch.ps1 / backend.vbs        笔记窗口与独立后台启动
    window.ps1                     识别并唤起已有笔记窗口，保证只开一个
    client/                        本地 HTTP 后台、Windows 登录保护和界面
    server/                        Linux HTTPS API、SQLite 数据库和每日备份
    tests/                         同步、离线冲突、恢复、加密和网络测试
  tools/deploy_server.py            首次服务器部署，强制核对 SSH 指纹
  tests/                           悬浮栏、工具窗口和进程清理测试
  licenses/                        第三方运行时许可
```

## 在另一台 Windows 电脑安装

要求 Windows 10/11、Windows PowerShell 5.1、Node.js 22 以上，以及 Edge 或 Chrome。安装 Node.js 后，打开新的 PowerShell 终端。

```powershell
git clone https://github.com/4563599/software.git
cd software\desktop
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Install.ps1 -DryRun
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Install.ps1
```

安装后创建桌面 `Desktop Tools` 快捷方式及当前用户启动项，代码仍在克隆下来的 `desktop` 文件夹。不要随意移动该目录；移动后重新安装即可更新路径。

已有旧版运行时，先保存草稿，按下一节把原服务器地址和公开证书配置到私人数据目录，再明确使用 `Install.ps1 -ReplaceExisting` 迁移本工具的任务和启动项。安装不会删除用户数据，也不会修改无关任务。`-NoStart` 只配置、不立即启动。也可以直接双击 `Start-Desktop.vbs` 临时启动悬浮栏。

安装管理的本地任务：

- `TNotesFloatingToolbarWatchdog`：登录后和每分钟检查；静默运行。
- `TNotesLocalBackend`：独立运行笔记后台，无运行时长上限。

## 配置已有同步服务器

仓库不包含真实服务器地址、证书、初始化令牌或密码。每台电脑分别取得服务器的公开证书，并执行：

```powershell
.\Configure-Notes.ps1 -ServerUrl https://notes.example.com:18443/ -ServerCertificate E:\private\server-ca.pem
```

配置写到当前用户的 `%LOCALAPPDATA%\TNotes`，不会写到仓库。配置后关闭并重新打开 T；如果旧后台仍在运行，可先保存草稿，再重启 `TNotesLocalBackend` 任务。

- 第一次部署的所有者可使用 `-Enrollment`，在隐藏提示中输入一次性初始化令牌。不要把令牌放进命令行、聊天或 Git。
- 其他电脑不需要初始化令牌，直接登录同一资料库名称和主密码。
- 不要复制其他电脑的 `remembered-session.dpapi`；每台电脑独立记住登录。
- 只更换服务器连接配置，不自动把现有资料迁移到另一个服务器。换服务器前请保留加密备份。
- 无服务器配置时可以本机加密使用；不要把本机离线资料库和另一台电脑的不同资料库当成同一库覆盖。

## 首次部署 Linux 服务器

需要 Python 3.10+、OpenSSL、systemd 和具有安装权限的 SSH 用户。仅适用于新的 `/opt/tnotes`、`/var/lib/tnotes`，不会覆盖已有安装或改动现有网站。

```powershell
python -m pip install -r requirements-dev.txt
python tools\deploy_server.py --host notes.example.com --fingerprint SHA256:填写你核对过的SSH指纹
```

部署时会隐藏输入 SSH 密码，并强制比对事先核对的主机指纹。连接文件和一次性初始化令牌默认保存到当前用户的私人数据目录，不回显令牌。若该目录已有服务器配置，部署工具拒绝覆盖，可用 `--output-dir` 指向仓库外的另一个私人目录。

默认 HTTPS 端口为 `18443/TCP`；按需配置云安全组。SQLite 仅在服务器本机使用，不对外开放数据库端口。服务使用独立的低权限 `tnotes` 用户，定时做一致性备份，保留最近七份。

## 数据与安全

| 内容 | 位置 / 处理 |
| --- | --- |
| 本机加密缓存、登录记忆、私人连接配置 | `%LOCALAPPDATA%\TNotes`，不属于源码 |
| 每日自动备份（密文） | `文档\TNotes-Backups`，可在笔记的“同步与备份”里改到其他文件夹；保留最近 30 份 |
| 悬浮栏位置 | `%LOCALAPPDATA%\TNotes\toolbar.json` |
| 工具窗口的日志路径、上次选的手机和上次保存的文件夹 | `%LOCALAPPDATA%\TNotes\dev-tools.json` |
| 服务端加密数据库 | `/var/lib/tnotes/vault.sqlite3` |
| 每日服务端备份 | `/var/lib/tnotes/backups` |
| 源码、图标、模板和测试 | 本目录，可提交 Git |
| Node.js 二进制、浏览器缓存、安装包、真实笔记和凭据 | 不提交 Git |

笔记标题、正文、账户、密码、标签采用客户端 AES-256-GCM 加密。主密码不落盘；记住登录仅保存 Windows DPAPI 当前用户加密保护的派生密钥。HTTPS 校验专用证书及主机名，不跳过验证；短暂断连采用有限的安全重试。

记住登录后，同一 Windows 用户可以直接查看资料，离开电脑请锁屏；退出登录会清除本机登录记忆。主密码无法找回。此自用工具尚未经过独立安全审计，重要密码请保留可靠备份。

`.gitignore` 是防误提交的辅助措施，不是脱敏器。提交前仍需检查暂存区，不能直接复制整个用户数据目录或本机程序目录。

## 开发与测试

```powershell
npm ci
python -m pip install -r requirements-dev.txt
npm test
npm run test:integration
git add -- .
python tools\verify_source.py
```

集成测试在独立临时目录、随机端口和测试证书下运行，使用虚构账号数据，覆盖两客户端同步、离线冲突、密码遮挡、登录记忆、分类联动、一键复制、后台恢复、TLS 校验及网络重试。需要 Chrome。不会对真实资料库进行登录、清理或写入。

界面功能测试只需要 Node.js 和 Chrome，不需要同步服务器：在临时目录里用虚构记录检查布局、提示、快捷键、搜索、回收站、提示词变量、每日备份、导入和恢复。

```powershell
npm run test:ui
```

单窗口测试需要 Edge 或 Chrome，会在临时数据目录和随机端口下短暂弹出登录小窗，验证同时启动、连续点击和最小化后唤起都只有一个窗口：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File t-notes\tests\single_window_test.ps1
```

AI 清理测试只使用进程快照夹具以及测试自己启动的短期子进程，不会点击 C 或关闭正在使用的 AI 应用。`ai-process-cleanup-worker.ps1` 默认是只读 `Audit` 模式；不要在开发时随意传入 `-Mode Clean`。

## 停用

```powershell
.\Uninstall.ps1 -ConfirmUninstall
```

仅移除指向本目录的任务、启动项和快捷方式，不删除笔记、主密码或服务器数据。先保存草稿后再停用。

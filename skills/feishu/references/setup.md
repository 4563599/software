# 飞书 API 首次配置

## 1. 开放平台配置

在飞书开放平台创建或选择企业自建应用，并至少开通能够创建、读取和编辑新版文档的权限。发布应用版本并完成管理员审批后，在“安全设置”中配置 OAuth 重定向 URL。

个人云盘中的私人文档应使用用户身份凭证 `user_access_token`。应用身份凭证 `tenant_access_token` 不能天然访问用户私人文件夹。

## 2. 设置本机环境变量

不要把 App Secret 提交到 Git。每台电脑分别配置。

在飞书开放平台获取本机应用的 App ID 和 App Secret。OAuth 回调地址默认是 `http://localhost:53682/callback`；必需的用户权限为 `docx:document`、`docs:document.media:upload`。

Windows 推荐运行以下命令，然后按照提示输入 App ID 和 App Secret：

```powershell
python scripts/feishu_docs.py configure
```

App ID 正常显示，App Secret 输入不会回显。命令会为当前 Windows 用户保存 App ID、App Secret、回调地址和 OAuth 权限。

Windows PowerShell（保存到当前 Windows 用户；新终端会自动生效）：

```powershell
[Environment]::SetEnvironmentVariable("FEISHU_APP_ID", "cli_xxxxxxxxxxxxx", "User")
[Environment]::SetEnvironmentVariable("FEISHU_APP_SECRET", "xxxxxxxxxxxxxxxx", "User")
[Environment]::SetEnvironmentVariable("FEISHU_REDIRECT_URI", "http://localhost:53682/callback", "User")
[Environment]::SetEnvironmentVariable("FEISHU_OAUTH_SCOPES", "docx:document docs:document.media:upload", "User")
```

当前终端无需重启也可以临时设置同名 `$env:` 变量。脚本在 Windows 上还会读取当前用户环境变量注册表，因此刚保存后即可使用。

macOS / Linux：

```bash
export FEISHU_APP_ID="cli_xxxxxxxxxxxxx"
export FEISHU_APP_SECRET="xxxxxxxxxxxxxxxx"
export FEISHU_REDIRECT_URI="http://localhost:53682/callback"
export FEISHU_OAUTH_SCOPES="docx:document docs:document.media:upload"
```

飞书开放平台“安全设置”中的重定向 URL 必须与这里完全一致，包括协议、端口和路径。该本地地址只在授权期间临时监听，不会常驻运行。

不要设置或复制 `FEISHU_USER_ACCESS_TOKEN`。本 Skill 要求每台电脑走一次独立 OAuth，并把令牌绑定当前电脑。

## 3. Mermaid 流程图依赖

文档包含语言标记为 `mermaid` 的围栏代码块时，脚本会在本机渲染 PNG，并依次写入“图片块 + Mermaid 源码代码块”。这需要：

- Node.js（包含 `npx`），或者已全局安装的 `mmdc`；
- Chrome、Edge 或 Chromium；
- 飞书用户权限 `docs:document.media:upload`。

脚本优先使用全局 `mmdc`，否则通过 `npx` 运行 `@mermaid-js/mermaid-cli`。浏览器未安装在常见位置时，通过 `MERMAID_BROWSER_PATH` 指定可执行文件。脚本只在本地渲染，不把 Mermaid 源码提交给在线渲染网站。

图片上传完成后，脚本会调用 `replace_image` 设置媒体 token 和真实尺寸，再通过 API 回读校验。任一步失败都会报错并尝试删除空图片占位块，不会把一直加载的占位图当作成功。

## 4. 把真实凭证写入指定私人文档

只有用户明确授权并给出准确文档 URL/ID 时才使用该模式：

```bash
python scripts/feishu_docs.py write-credentials \
  --document "https://example.feishu.cn/docx/文档ID" \
  --confirm-sensitive-upload
```

脚本会分别安全提示输入 App Secret 和 Token，输入内容不会回显，也不会出现在命令行历史或脚本输出中。自动化环境可以使用专用变量 `FEISHU_CREDENTIAL_APP_SECRET` 和 `FEISHU_CREDENTIAL_TOKEN`；不要复用或提交包含这些变量的配置文件。

在线文档可能受分享设置、管理员策略和历史版本影响。写入后应立即确认目标文档仅对预期人员可见；若不再需要，及时撤销或轮换对应凭证。

## 5. 首次用户授权

推荐使用一次式授权：

```bash
python scripts/feishu_docs.py authorize --open-browser
```

该命令会：

1. 在配置的 `localhost` 端口临时启动回调服务器；
2. 生成带随机 `state` 的飞书授权链接；
3. 打开浏览器并等待用户点击授权；
4. 校验回调路径和 `state`；
5. 使用一次性 `code` 换取用户访问令牌与刷新令牌；
6. 原子写入当前用户的私有令牌缓存，然后关闭回调服务器。

检查保存结果（不会显示令牌内容）：

```bash
python scripts/feishu_docs.py status
```

正常结果中应看到 `token_bound_to_current_device`、`required_oauth_scopes_satisfied`、`access_token_saved`、`refresh_token_saved`、`access_token_valid` 和 `refresh_token_valid` 均为 `true`。否则禁止执行创建、追加或读取文档操作。

如果本机无法监听回调端口，可以使用手工备用流程。先生成授权链接：

```bash
python scripts/feishu_docs.py auth-url
```

在浏览器打开输出链接并同意授权。飞书跳转到重定向 URL 后，从地址栏复制 `code` 参数，然后执行：

```bash
python scripts/feishu_docs.py exchange-code
```

脚本会在终端中提示粘贴一次性 code，不回显任何长期密钥。令牌缓存位置：

- Windows：`%USERPROFILE%\.codex\feishu\token.json`
- macOS / Linux：`~/.codex/feishu/token.json`

缓存会保存 `access_token`、`refresh_token` 及有效期。脚本不会把这些值打印到标准输出；请勿上传、分享或提交此文件。
缓存文件不包含 App Secret。访问令牌过期后，脚本会使用刷新令牌自动刷新；刷新时仍需本机环境变量中的 App ID 和 App Secret。

## 6. 跨电脑安装

把整个 `feishu` 文件夹复制到：

- Windows：`%USERPROFILE%\.codex\skills\feishu`
- macOS / Linux：`~/.codex/skills/feishu`

新电脑必须按以下顺序执行：

1. 安装完整 Skill；
2. 从飞书开放平台安全获取当前应用的 App ID 和 App Secret；
3. 运行 `configure`，安全输入 App Secret；
4. 运行 `authorize --open-browser`，由当前用户明确同意授权；
5. 运行 `status`，确认设备绑定、必需权限和两种令牌全部有效；
6. 验证通过后才允许操作个人云盘文档。

严禁复制其他电脑的 `%USERPROFILE%\.codex\feishu\token.json`。令牌已绑定电脑，复制后也会被脚本拒绝。Skill 安装包不携带 App Secret 或任何用户令牌。

## 7. 常见错误

- `99991663` 或权限不足：检查应用 API 权限、应用版本是否发布、管理员是否审批。
- `1770032 forbidden`：当前用户对目标文档没有编辑权限，或应用缺少新版文档编辑权限。
- `1770040 no folder permission`：当前身份无权在该文件夹创建文档；确认使用用户令牌，并确认该用户拥有目标文件夹。
- 图片上传权限不足：确认应用已开通 `docs:document.media:upload`，重新发布应用版本并再次运行 `authorize --open-browser`。
- Mermaid 渲染器不可用：安装 Node.js 和 Chrome/Edge/Chromium，或设置 `MERMAID_BROWSER_PATH`；不要改用第三方在线渲染服务处理私人文档内容。
- 授权码无效：授权码只能使用一次，重新运行 `auth-url` 获取新的 code。
- 刷新失败：重新执行 OAuth 授权，或确认 App ID / App Secret 与签发令牌的应用一致。

官方参考：

- 云文档常见问题：https://open.feishu.cn/document/server-docs/docs/faq
- 新版文档 API：https://open.feishu.cn/document/server-docs/docs/docs/docx-v1/docx-overview

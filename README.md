# silver-parakeet

DeepSeek Harness（DSH）的个人配置包：把 `ponytail` 系列 skill 与用户级全局指令同步到任意一台机器的 DSH 环境。

来源：[DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail)（MIT）。本仓库只做安装布局与全局指令的适配，skill 正文保持上游原文。

## 目录结构

```
.
├── agents/AGENTS.md          用户级全局指令模板
├── skills/
│   ├── ponytail/SKILL.md
│   ├── ponytail-audit/SKILL.md
│   ├── ponytail-debt/SKILL.md
│   ├── ponytail-gain/SKILL.md
│   ├── ponytail-help/SKILL.md
│   └── ponytail-review/SKILL.md
├── upstream/                 上游原文快照，不做修改，供版本比对与留档
│   ├── VERSION.txt           版本标记：记录上游 commit
│   └── skills/               与 skills/ 应逐字节一致
├── install.ps1               Windows 安装
├── install.sh                Linux / macOS 安装
├── update.ps1                Windows 更新
├── update.sh                 Linux / macOS 更新
└── push-to-github.ps1        无 git 环境下的推送工具（可选）
```

`skills/` 与 `upstream/skills/` 的区别：前者是实际安装到 DSH 的版本，后者是上游原文。正常情况下两者逐字节一致；若出现差异，说明本仓库对 skill 做过本地修改。

## 安装

**Windows**

```powershell
.\install.ps1              # 已存在的 AGENTS.md 会被保留
.\install.ps1 -Force       # 强制覆盖
.\install.ps1 -DshHome "D:\my-dsh-data"
```

**Linux / macOS**

```bash
chmod +x install.sh
./install.sh               # 已存在的 AGENTS.md 会被保留
./install.sh --force
./install.sh --dsh-home /path/to/dsh-data
```

## DSH_HOME 的解析顺序

脚本与 `@deepseek-ai/dsh-home-paths` 的 `resolveDshHome()` 保持一致，从高到低：

1. `-DshHome` / `--dsh-home` 显式指定
2. `$DSH_HOME` 环境变量
3. `%APPDATA%\ds-xzt\dsh` —— DSH 桌面版的实际数据目录（Windows 上优先于第 4 项）
4. `~/.dsh` —— 上游默认目录名

第 3 项是本仓库针对桌面版加的探测。上游默认只认前两项和 `~/.dsh`，而 DSH 桌面版通过环境变量把 home 指向 AppData，所以脚本需要多探一层。

安装后的布局：

```
<DSH_HOME>/
├── AGENTS.md
└── skills/
    └── ponytail/
        └── SKILL.md
```

## 生效机制

DSH 的 skill 采用**目录摘要常驻 + 正文按需加载**两段式：

- **常驻**：`<DSH_HOME>/skills/*/SKILL.md` 的 frontmatter（`name` + `description`）会渲染成目录，在会话首个 step 注入模型上下文，并附上「先加载再遵循」的规则。
- **按需**：skill 正文只在显式触发时注入 —— 模型调用 `skill` 工具，或用户输入 `/<name>`。

**没有自动加载正文的配置项。** `dsh-skill-filesystem` 支持的 frontmatter 字段只有 `name`、`description`、`whenToUse`、`metadata`、`disable-model-invocation`、`user-invocable`，全是调用策略开关，没有「默认激活」。

因此本仓库让 ponytail 默认生效的方式，是复用上游 `cordis` 预设验证过的模式：**在 `AGENTS.md` 里放一段始终在线的短指令**，指示模型在编码任务上先加载 `ponytail` 再动手。全文常驻会污染每个请求的 prompt 前缀，也会破坏跨会话的 prompt 缓存复用。

`agents/AGENTS.md` 由 `dsh-agent-instructions` 插件在每个会话的首个 step 注入（在 `$DSH_HOME/AGENTS.md` 之后，项目级 `AGENTS.md` 之前——更具体的文件优先）。

## 更新

版本真相在 `upstream/VERSION.txt`，它记录本包构建自上游哪个 commit。更新脚本把远程该文件与本地标记比对，一致就什么都不做。

**手动更新**

```powershell
# Windows
.\update.ps1              # 有新版才下载
.\update.ps1 -CheckOnly   # 只检查，不修改；有更新时退出码 10
.\update.ps1 -Force       # 忽略版本，强制重装
```

```bash
# Linux / macOS
./update.sh
./update.sh --check
./update.sh --force
```

脚本会跳过内容逐字节相同的文件，所以重复运行的开销很小。

**自动更新**

`update.ps1` 支持 `-Quiet`，只在必要时输出一行，适合挂到计划任务：

```powershell
# 注册一个每天 10:00 检查更新的计划任务
$repo = "C:\path\to\silver-parakeet"
schtasks /Create /TN "ponytail-config-update" /SC DAILY /ST 10:00 ^
  /TR "powershell -NoProfile -ExecutionPolicy Bypass -File \"$repo\update.ps1\" -Quiet"
```

检查已注册的任务：

```powershell
schtasks /Query /TN "ponytail-config-update"
```

撤销：

```powershell
schtasks /Delete /TN "ponytail-config-update" /F
```

几点需要知道：

- **本仓库不会自动跟踪上游。** `upstream/VERSION.txt` 只在有人手动同步本仓库时才更新。所以「自动更新」实际是「本仓库发布新版后自动跟进」，不是「上游一改就自动跟上」。要缩短这个延迟，需要有人（或一个定时任务）定期比对上游 commit 并更新本仓库。
- **更新是文件覆盖。** 若你改过本地 skill 或 `AGENTS.md`，`-Force` 会覆盖掉。脚本默认不覆盖与仓库版本不同的 `AGENTS.md`，会告警并跳过。
- **无需重启。** `dsh-skill-filesystem` 默认 `watch: true`，会监视 skill 根目录；改完文件新建会话即可生效。skill 正文每次加载都重新读盘，连缓存失效都不需要。

## 验证安装

技能目录能被发现：

```powershell
$home_ = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:APPDATA 'ds-xzt\dsh' }
Get-ChildItem "$home_\skills" -Directory | Select-Object Name
```

新开一个 DSH 会话，输入 `/ponytail-help`。若能返回 ponytail 的级别与命令速查，说明 skill 已被发现并可调用。

## 卸载

```powershell
# Windows
Remove-Item -Recurse "$env:DSH_HOME\skills\ponytail*"
Remove-Item "$env:DSH_HOME\AGENTS.md"
```

```bash
# Linux / macOS
rm -rf "${DSH_HOME:-$HOME/.dsh}"/skills/ponytail*
rm -f  "${DSH_HOME:-$HOME/.dsh}"/AGENTS.md
```

## 注意

- `install.ps1` 默认**不覆盖**已存在的 `AGENTS.md`。若你已有全局指令文件，加 `-Force` 前请先自行备份或合并。
- skill 文件名必须保持 `kebab-case`，否则会被 `dsh-skill-filesystem` 整体丢弃并告警。
- 上游 skill 更新后，本仓库不会自动同步，需要手动替换 `skills/` 下的文件。

## 许可

skill 正文版权归上游项目，MIT。见 [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail)。

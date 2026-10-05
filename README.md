# dotfile — 声明式多发行版软件安装脚本生成器

用一份声明式的模块定义, 生成**自包含的 bash 安装脚本**。目标机零依赖 (只需 bash),
不部署配置文件、不做软链接 —— 只管装软件。

## 设计理念

1. **分叉发生在生成阶段**: `gen --target rocky@8` 产出 rocky 8 专用脚本,
   脚本内部没有任何发行版判断逻辑。
2. **一个模块一张 OS 对照表**: 想知道某系统上装什么, 看 module.toml 里对应的段就完了,
   无覆盖级联、无叠加语义。
3. **职责单一**: 只管软件安装。.zshrc 等配置文件的同步、镜像源这类机器相关设定,
   都不属于本项目。

## 快速上手

```bash
uv sync                                          # 准备 Python 3.11+ 环境 (uv 管理, 零第三方依赖)
uv run python dotfile.py validate                # 校验所有模块定义
uv run python dotfile.py list                    # 查看模块与分组
uv run python dotfile.py plan --target ubuntu@24.04   # 预览将执行什么 (不生成)
uv run python dotfile.py gen --target ubuntu@24.04 -o install-ubuntu.sh

# 把 install-ubuntu.sh 拷到目标机执行 (也可 curl | bash):
bash install-ubuntu.sh [--dry-run] [--force]
```

在 linux 本机直接执行 (自动检测发行版):

```bash
uv run python dotfile.py install                 # 等价于 gen + bash, 免落盘
uv run python dotfile.py install --dry-run
```

## TUI 交互 (gum)

生成的脚本带终端交互界面, 依赖 [gum](https://github.com/charmbracelet/gum)
(charmbracelet 出品的单文件静态二进制)。**gum 是必须依赖, 脚本自动安装**:
`PATH` 里没有就从 GitHub release 下载到 `~/.local/bin` (免 root, 全发行版通吃;
缺 curl 时按目标 family 先装 curl); 可用 `GUM_VERSION=v2.0.2` 环境变量固定版本。

有终端时 (直接 `bash install-xxx.sh`):

1. **模块复选清单** — ↑↓ 移动、空格勾选、回车确认 (默认全选; gen 时的组选择决定清单内容)
2. **安装确认** — 显示将安装的模块数
3. **逐步进度** — 每步 spinner + 完成 ✓; 命令原始输出收进日志文件, 失败自动展示尾部
4. 结束汇总样式框, 附日志路径

**选择的最小单位是模块 (软件包)**: 模块内的软件不可拆分勾选 — 例如 essentials
里的 htop/tree/curl/jq 是同一条配方命令, 要么全装要么全不装。模块声明了 `content`
时, 选择清单里会在模块下方以树状展示其内容 (子项纯展示, 勾选作用于整个模块):

```
[✅] essentials — 常用 CLI 工具
     ├─ htop
     ├─ tree
     ├─ curl
     └─ jq
[✅] git — Git 版本控制
     └─ git
```

想要更细的可选粒度, 在仓库里把模块拆开 (各自独立目录), 而不是在选择界面做子项展开。

无终端 (CI、`curl | bash` 管道) 自动降级为逐行日志模式并安装全部模块;
`--yes` 跳过选择直接装全部, `--no-tui` 强制日志模式, `--dry-run` 只打印动作。

## 选择装什么: 软件包组

模块用 `groups` 标签声明归属, 缺省组为 `base` (不传参只装 base):

```bash
uv run python dotfile.py gen --target ubuntu@24.04 --groups base,dev   # 选择组
uv run python dotfile.py gen --target ubuntu@24.04 --groups all        # 全部
uv run python dotfile.py gen --target ubuntu@24.04 --without-groups games
uv run python dotfile.py gen --target ubuntu@24.04 --modules docker    # 追加单个模块
uv run python dotfile.py gen --target ubuntu@24.04 --without-modules starship   # 排除, 优先级最高
```

规则: `--modules` 显式追加的模块不受 `--without-groups` 影响;
`--without-modules` 是最高优先级的排除。

## module.toml 规范

```toml
[module]
name = "docker"                # 必须与目录名一致, 且只允许 [a-z0-9-]
description = "Docker 容器引擎"
groups = ["dev"]               # 缺省 ["base"]
order = 20                     # 越小越先执行, 缺省 100
requires = []                  # 依赖的其他模块名 (生成时校验已选中, 并约束执行顺序)
content = ["docker-ce", "containerd"]   # 可选: 软件包内容, 选择界面/plan 中树状展示 (纯展示)

[debian]                       # family 段: ubuntu/debian 命中
install = "sudo apt-get install -y docker.io"

[fedora]                       # distro 段
install = "sudo dnf install -y docker-ce"

["rocky@8"]                    # 版本段: 点分前缀匹配 VERSION_ID (8 命中 8.7)
install = [
  "sudo dnf install -y dnf-utils",
  "sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo",
  "sudo dnf install -y docker-ce",
  "./scripts/post-install.sh", # 模块内脚本: 生成时整个嵌入产物, 目标机不需要本仓库
]

[arch]
install = "sudo pacman -S --needed --noconfirm docker"
```

### 段键与查找链

段键三种形态: family (`debian`/`redhat`/`arch`)、distro (`ubuntu`/`rocky`/`fedora`/...)、
`distro@版本`。生成时按 **目标全版本 → 各级版本前缀 → distro → family** 查找,
第一个存在的段即为唯一配方 (命中即止, 不叠加), 整条链无命中则报错。

例如目标 `ubuntu@22.04` 的查找链:
`ubuntu@22.04 → ubuntu@22 → ubuntu → debian`。

当前已注册 family: `debian`(ubuntu/debian/linuxmint/pop), `redhat`(fedora/rocky/almalinux/rhel/centos/amzn),
`arch`(arch/manjaro/endeavouros)。新增发行版在 `lib/distro.py` 的 `FAMILIES` 里登记。

### install 值

- **单条命令**: 字符串, 原样嵌入逐条执行 (sudo 由配方作者自己写, 生成器不加不减)
- **命令数组**: 按顺序执行, 可混用命令与 `./` 开头的脚本路径
- **脚本路径**: `./xxx.sh` 且存在于模块目录 → 内容嵌入生成物,
  执行时注入 `DOTFILES_DISTRO` / `DOTFILES_FAMILY` / `DOTFILES_MODULE` 环境变量

## 如何新增一个模块

1. `mkdir modules/<name> && $EDITOR modules/<name>/module.toml`
2. 写 `[module]` 元数据 + 至少一个 OS 段 (当前仓库的示例模块只配了 `[debian]`,
   需要其他发行版时按同样格式补段即可)
3. 有自定义安装逻辑就放 `modules/<name>/scripts/`, 在 install 数组里以 `./scripts/xxx.sh` 引用
4. `uv run python dotfile.py validate` 校验, `plan --target ...` 预览

### 软件添加约定

- **Upstream First**: 安装通道选上游推荐的方式 — 先查官方文档列出的通道;
  多通道时选与布局目标一致的那条; 发行版档案库优先于厂商第三方源
  (写脚本前先 `apt-cache policy`)。详见 `~/.agents/skills/install-script/SKILL.md`
- **第三方仓库软件离线优先**: 需要加第三方源才能装的, 优先改为直接下载产物
  一次性安装 (.deb + `apt-get install ./pkg.deb`、tarball、独立安装器), 不给
  系统长期注册厂商源; 仅当上游离线形式不可行才退回仓库形式并注明
- **一个软件包一个模块一个路径**: 功能内聚的一组软件就写成一个 module.toml
  (如 agentharness: 六个 agent CLI 一个文件、几行 npm), 统一收纳在一个根
  路径下 (`~/.agentharness/<工具名>/`)。优先用上游环境变量或 npm `--prefix`
  原生实现; 结尾以绝对路径逐个验证 (防 PATH 未生效)
- **拆分粒度由部署复杂度决定**: 几行命令装完的不拆 (单 toml 即可); 只有
  部署复杂的软件栈才拆成多个模块, 用 `requires` 表达依赖、各自独立演进 —
  典型如 ML 环境: cuda-toolkit (版本矩阵、硬件分叉) / pytorch (源码或 wheel
  渠道、XPU/CUDA 变体) 各自一个模块, 组合即环境

## 目录结构

```
dotfile/
├── dotfile.py        # CLI: gen / install / plan / validate / list
├── lib/
│   ├── distro.py     # family 注册表, os-release 检测, 版本匹配, 段查找链
│   ├── manifest.py   # module.toml 加载与校验
│   ├── plan.py       # 组过滤, 配方解析, order/requires 排序
│   └── render.py     # 计划 → 自包含 bash 脚本
├── modules/          # 每个软件一个模块 (git/essentials/neovim/starship)
└── tests/            # 单元测试 + 远程 docker 集成测试脚本
```

## 测试

```bash
uv run python -m unittest discover -s tests   # 本地单元测试 (含生成物 bash -n 断言)
tests/integration_remote.sh                   # 远程 docker 集成测试 (默认 ubuntu:24.04)
```

## CI: 自动生成安装脚本

`targets.toml` 声明构建目标清单, 每次 push 由 GitHub Actions
(`.github/workflows/gen-scripts.yml`) 逐个执行 `gen --all` (自动含全部模块,
供目标机 TUI 勾选), 产物落在 `script/`, 有变更则自动提交回仓库:

```bash
uv run python dotfile.py gen --all            # 本地等价操作, 输出到 script/
```

目标机上可以不 clone 本仓库, 直接取用 raw 链接 (管道方式无 TUI, 装全部模块;
想要交互选择, 先下载成文件再执行):

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/ca1ic0/dotfile/main/script/install-ubuntu-24.04.sh
bash install.sh        # TUI 勾选模块
```

给模块补了新发行版的 OS 段后, 把目标加进 `targets.toml` 即可纳入批量生成;
清单里的目标无法被现有模块解析时, 生成会直接失败 (CI 变红即信号)。

集成测试会把生成的脚本通过 ssh 管道送进远程服务器的全新容器真实执行一遍,
并验证 `git`/`jq`/`nvim`/`starship` 装好。可用环境变量换目标:
`REMOTE_HOST=... IMAGE=ubuntu:22.04 TARGET=ubuntu@22.04 tests/integration_remote.sh`。

## 边界与约定

- 生成的脚本启动时会复核 `/etc/os-release` 的 ID/VERSION_ID 与生成目标一致,
  不符默认拒绝执行 (`--force` 跳过)
- 生成物支持 `--dry-run` (只打印动作) 与 `--force`
- Arch 滚动发行, 无版本段; `rocky@8` 与 `rocky@8.0` 数值等价
- 后续可选扩展: 包名别名表 (OS 段间包名重复变多时)、macOS/brew family、
  CI 批量生成多目标产物、shellcheck 集成

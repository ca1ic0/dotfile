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
name = "docker"                # 必须与目录名一致
description = "Docker 容器引擎"
groups = ["dev"]               # 缺省 ["base"]
order = 20                     # 越小越先执行, 缺省 100
requires = []                  # 依赖的其他模块名 (生成时校验已选中, 并约束执行顺序)

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

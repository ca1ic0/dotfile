---
name: install-script
description: 编写非包管理器的自定义安装脚本: curl|sh 官方安装器包装、二进制下载、厂商 apt/yum 源配置、编译安装、dotfile 仓库模块内嵌的 scripts/*.sh、独立 setup/install.sh。凡是「写一个安装脚本 / 安装器 / 配置软件源 / 部署脚本」的请求都使用本技能 — 即使没有明说 install script。
---

# 软件包添加与安装脚本规范

适用一切软件包的选型、添加与不走系统包管理器的安装逻辑。选型决策流 + 脚本
结构固定三段, 外加三条硬性风格规则。

## 选型决策流 (按顺序执行, 逐步降级)

动手前先确定「用什么通道装」; 同时确定「拆不拆模块」— 粒度由部署复杂度
决定: 几行命令装完的写成一个模块 (一个 toml); 只有部署复杂的软件栈 (如 ML
环境: CUDA toolkit 的版本矩阵、PyTorch 的渠道/硬件变体) 才拆成多个模块,
用 requires 表达依赖。

1. **第一步永远查系统包管理器** — `apt-cache policy <pkg>` / `dnf repoquery
   <pkg>` 实证目标发行版档案库是否收录。存在则直接用系统包, 到此为止
   (真实教训: cuda-toolkit/rocm 在 Ubuntu 26.04 已进官方库, 一条 apt 命令
   优于 90 行厂商源脚本; uv 类工具除非刻意追新, 否则档案库版本优先)。
2. **档案库没有 → 去官网 / GitHub 对应 repo 调研官方安装方式** — 不自创
   安装路径 (下载 URL、目录布局以上游为准)。
3. **官方通道里 npm 优先于一句话命令** — 上游同时提供 npm 包和
   `curl ... | sh` 安装器时, 选 npm: 好歹有包管理器语义 (版本、依赖、卸载、
   升级), 且装进统一的 node bin 路径。一句话安装器 (curl|sh) 是次选,
   官方 tarball/二进制直下再次。
4. **需要第三方仓库的软件, 离线安装方式优先** — 能直接下载产物一次性安装的
   (`.deb` 用 `apt-get install ./pkg.deb` 解依赖、rpm 系用 `dnf
   --repofrompath` 临时仓库、官方 tarball、npm), 就不给系统长期注册第三方源:
   源状态干净、版本可控、离线可复现。仅当上游离线形式不可行 (如依赖闭过大
   的元包子集) 才退回仓库形式, 并在模块里注明取舍。
5. 只有上游环境变量/参数支持的路径定制才做路径定制 (如 HERMES_HOME、
   PI_CODING_AGENT_DIR); 安装器硬编码且无开关的落点, 评估装后移动的代价
   (自更新行为) 再决定。

**避免重复与冗余** (贯穿以上各步):
- 一个软件只用一条通道, 不混用 (已走 npm 就不再 curl 安装器; 已系统包就不
  再叠加官方源)
- install 命令、验证命令、content 列表三者不重复表达同一信息
- 已被某模块覆盖的软件不再另立模块 (如进了 base 就不单独成模块)

## 何时才写脚本

安装的核心命令只有一两行时, **直接内联进 install 数组, 不为它包一层脚本**:
`curl ... | sh` 官方安装器、`npm install -g <pkg>`、`dnf/apt-get install <pkgs>`
都该是一行内联命令, 验证用数组尾部的追加命令表达 (如绝对路径 `--version`)。

`scripts/*.sh` 只留给真正的多步骤安装逻辑: 需要 source/加载环境 (nvm 链)、
解析索引再下载 (docker .deb 直取)、配置源并导入 GPG key、需要函数/循环/
root-无-sudo 垫片。判断标准: 把脚本内容拍平后若只剩两三行线性命令, 它就
不配是脚本。真实反例: uv 的安装曾被包成脚本, 内容核心就一行
`curl -LsSf https://astral.sh/uv/install.sh | sh`。

## 结构 — 固定三段

### 1. 环境变量配置 (开头集中)

`set -euo pipefail` 打头。允许使用者调整的参数 (版本号、安装目录、跳过开关)
集中提为脚本开头带缺省值的环境变量; 其余值一律内联, 不设变量。

```bash
#!/usr/bin/env bash
set -euo pipefail

NVIM_VERSION="${NVIM_VERSION:-0.10.4}"    # 版本 pin, 调用方可覆盖
DEST="$HOME/.local/nvim-v${NVIM_VERSION}" # 安装目的地, 后文多处引用
```

### 2. Step-by-step 安装 (线性展开)

每步一个动作, 按执行顺序平铺; 步骤间用 `echo "==> ..."` 标明进展。
不做条件体操, 不把三步塞进一行。临时文件用 `mktemp -d` + `trap 'rm -rf' EXIT`。

### 3. Verification (结尾必做)

装完必须验证可用性, 验证失败让脚本失败 (set -e 兜底), 成功则打印落点:

```bash
"$DEST/bin/nvim" --version | head -1
echo "已安装: $DEST/bin/nvim (v${NVIM_VERSION})"
```

验证方式: 版本输出、`command -v`、最小可用性检查 (能编译/能 --help)。
无 GPU/外设环境下验证二进制与版本即可, 运行时缺硬件属预期, 注明即可。

## 硬性规则

### 不允许掩盖日志

禁止用 `2>/dev/null`、`|| true`、管道丢错来吞命令输出或退出码。静默失败无法
排查 — 真实教训: 一个 `2>/dev/null` 曾把 TUI 界面整个吞掉, 排查一小时。

- stderr 是诊断信息, 不是噪音; 要留档就显式 `>>"$LOG" 2>&1` 落盘
- 想安静用工具自己的 `-q` / `-s` / `-qq` 标志, 不用重定向堵嘴
- 唯一可接受的丢弃: 无害探测, 如 `command -v gum >/dev/null 2>&1`

### 变量克制

一个值只用一次或两三次, 就不配做变量 — 直接内联。读代码的人不应该为看一个
值跳到脚本开头。变量只用于:

- 被多处引用的值 (如上例 `DEST`)
- 真正的旋钮: 想让使用者覆盖的版本号、目录、开关

反例: `URL="https://x"; curl "$URL"` — URL 只用一次, 直接写
`curl -fsSL https://x`。

### 循环克制

迭代次数是写死的小数字 (≤4) 时禁止循环, 硬编码逐步展开 — 可读性优先。
循环把「实际执行什么」藏进控制流, 读者要在脑内展开; 硬编码的每一行
失败时也自带明确上下文。

```bash
# 反例 — 3 次迭代也要循环:
for b in nvcc ncu nvdisasm; do ln -sf "/usr/local/cuda/bin/$b" /usr/local/bin/; done

# 正例 — 逐步硬编码:
ln -sf /usr/local/cuda/bin/nvcc /usr/local/bin/nvcc
ln -sf /usr/local/cuda/bin/ncu /usr/local/bin/ncu
ln -sf /usr/local/cuda/bin/nvdisasm /usr/local/bin/nvdisasm
```

循环仅当: 迭代对象由数据决定 (遍历目录、参数列表、探测多个候选), 或同构
步骤 ≥5 个。

## 交付前自检

- [ ] 三段齐全: 开头环境变量 → 线性安装步骤 → 结尾验证
- [ ] 全文搜 `/dev/null`: 只允许无害探测
- [ ] 每个 `X=...` 变量至少被引用两次, 或本身是用户旋钮
- [ ] 每个 `for`/`while`: 迭代次数是数据驱动或 ≥5 步同构
- [ ] root-无-sudo 的容器环境可用 (需要提权处自带 `sudo() { "$@"; }` 垫片)

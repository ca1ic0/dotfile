---
name: subagent-parallel
description: 多软件包安装/配置/调研任务的 subagent 并行编排策略: 便宜模型跑 subagent、按软件包/按 OS/按任务类型拆分、安装验证只在容器中进行。凡是「批量添加软件包、并行调研多个 OS、多个安装配置任务、subagent/workflow 编排」的请求都使用本技能 — 即使没明说并行。
---

# Subagent 并行策略

多任务交给多个 subagent 并行, 主模型只做编排、审查与提交。

## 模型选择: subagent 用便宜模型

编排者 (主会话模型) 负责拆任务、写清楚边界、最终验收; subagent 用同生态的
便宜/快速档模型。按主模型生态查表:

| 主模型生态 | Subagent 模型 |
| --- | --- |
| GLM | GLM-5.3-Flash |
| Kimi | Kimi 2.8 |
| Claude | Haiku |
| 其他 | 该家族最便宜的一档 |

在 ZCode 中: Agent 工具的 subagent 跟随会话模型, 无法指定; 需要钉模型时用
CreateWorkflow 的 `subagent_model` (如 `account:.../GLM-5.3-Flash`)。

## 拆分维度

1. **按软件包拆** — N 个软件包 → N 个 subagent, 各自完成「调研 + 配置 +
   验证」全链路, 互不依赖的包并行跑。
2. **按 OS 拆** — 单个软件要支持多个操作系统时, 每个 OS 一个调研 subagent
   (容器里 `apt-cache policy` / `dnf repoquery` 实证包名与版本), 汇总后再
   写配方。
3. **按任务类型拆** — 调研 / 编写 / 验证 / 验收 交给不同 subagent, 前者
   产出作为后者输入 (新鲜上下文互相审视); 确定性检查 (语法、单测) 不派
   subagent, 直接命令门禁。

## 硬规矩

- **安装与验证行为只能在容器中进行** — subagent 的一切安装/运行/验证命令
  跑在 docker 容器里 (远程测试机 `docker run`), 绝不碰宿主机。容器即用即毁
  (`--rm`) 或命名后必须清理; 管道灌脚本先 `cat > /tmp/x.sh` 物化再执行
  (防交互提示吃掉 stdin)。
- **文件写不交叉** — 每个 subagent 只写自己负责的文件 (一个模块一个 agent),
  避免并发写竞态; 共享文件 (README/tests) 留给编排者或串行阶段。
- **ask 自包含** — 每个 subagent 的任务书包含: 仓库位置、规范文件路径、
  远程测试机与容器协议、只许改哪些文件、禁止 git 操作。
- **产出可检验** — subagent 返回结构化结果 (typed), 关键发现须附证据
  (命令与输出), 高危结论由另一个 subagent 独立复核后才采信。

## 典型编排形态

```
调研 (5 agent: 每目标 OS 一个, 容器 repoquery 实证)
  → 编写 (agent: 拿调研结果写配方/模块)
  → 门禁 (命令: validate + 单测 + bash -n, 失败派修复 agent, 有界轮次)
  → 验证 (命令/agent: 容器端到端安装)
  → 汇总报告 (主模型审查 diff、提交)
```

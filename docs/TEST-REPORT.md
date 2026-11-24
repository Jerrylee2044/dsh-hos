# DSH HOS 0.2.3 真机测试报告

## 环境

| 项 | 值 |
|---|---|
| 日期 | 2026-11-24 |
| 设备 | HUAWEI 畅享 90 / JUY-AL80 |
| 系统 | HarmonyOS 7 |
| 应用 | v364 / 0.2.3-alpha.2-matexts.294 |
| 引擎 | @deepseek-ai/dsh 0.2.3-alpha.2 |
| Node | 24.22.1 / dsh_node_main |
| 网络 | 移动数据 |

## 结果汇总

| 模块 | 结果 | 说明 |
|---|---|---|
| 启动 | 通过 | 冷启动显示 splash，随后进入 DSH Web；约 20-25 秒 |
| 安全区 | 通过 | 内容未被状态栏/导航条遮挡 |
| 版本 | 通过 | 设置与关于均显示 0.2.3-alpha.2 |
| 登录 | 通过 | 登录跳系统浏览器，返回后账号/余额正常 |
| 模型 | 通过 | 模型列表加载，DeepSeek 账号已登录 |
| 对话 | 通过 | `hello` 正常流式回复 |
| 工具调用 | 通过 | Agent 创建并编辑 `test.txt`，文件浏览可见 |
| 会话持久化 | 通过 | 强杀重启后 Greeting/问候会话仍在 |
| 工作区 | 通过 | home 工作区选择、目录显示正常 |
| 设置 | 通过 | 账号/通用/模型/插件/关于等标签可切换 |
| 关于 | 通过 | 独立标签页，透明 logo，版本/链接正常 |
| 终端启动 | 通过 | 原生终端进入 bash-5.3 |
| 终端命令 | 部分通过 | `pwd`、`ls` 正常；`git`/`python` 尚无启动器 |
| 前后台 | 通过 | 切后台后重新打开保持状态 |
| 终端输入法 | 通过 | v365 打开终端自动聚焦，键盘自动弹出 |
| 崩溃 | 通过 | 当前日志未见 SIGSEGV/SIGSYS；仅有 SIGCHLD 链 |

## 问题清单

### P1 终端外部工具不完整

v365 已把 `/system/bin`、`/system/xbin` 加入终端 PATH，`ls`、`cat`、`sh`、`toybox` 等系统工具可用。

仍缺：

```text
bash-5.3$ git --version
bash: git: command not found
bash-5.3$ python3 --version
bash: python3: command not found
```

原因：HAP 内的 `libgit.so`、`libpython.so` 是宿主 `.so` 入口，没有生成 `git`/`python` 可执行启动器。

建议：增加自研多调用启动器（`dsh_tool_main` 或独立 PIE 启动器）把命令映射到对应 `.so` 入口。

### P2 关于标签位置偏右

设置标签较多，关于位于最右侧，需要横向滑动才看到；功能正常但发现性一般。

### P3 冷启动较慢

释放/重启后需要重新启动本地运行时，约 20-25 秒；首次解包更慢。属预期但可优化启动提示。

### P4 非阻塞告警

```text
internal/bootstrap/realm: Cannot find module
```

不影响 Web/登录/对话，后续可清理。

## 结论

核心功能可用：启动、登录、模型、对话、工具调用、会话持久化、工作区、设置、关于、终端 bash、前后台恢复均通过真机验证。

终端外部命令为已知限制，不影响 DSH Web 与 Agent 使用；如需完整 shell 工具链，应作为下一项修复。

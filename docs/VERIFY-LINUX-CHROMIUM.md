# 本地 Linux 终端与浏览器验证方案

## 目标

验证 DSH HOS 在 HarmonyOS 沙箱内提供：

1. Agent 可调用的本地终端；
2. Linux 风格工具安装与运行能力；
3. 内置 Chromium 及插件能力。

## 设备

- Mate XTs（GRL-AL20）
- HarmonyOS 7
- 手机保持前台/定时唤醒

## 测试项

### A. 终端基础

| ID | 操作 | 预期 |
|---|---|---|
| A1 | 原生终端执行 `pwd` | 输出工作区路径 |
| A2 | `python3 --version` | Python 3.12.14 |
| A3 | 创建并运行 `.py` 脚本 | 输出脚本结果 |
| A4 | Agent bash 工具执行 `echo ok` | 返回真实 stdout |
| A5 | Agent 执行 `python3 -c 'print(42)'` | 返回 42 |

### B. Linux 工具安装

| ID | 操作 | 预期 |
|---|---|---|
| B1 | 启动 QEMU guest | guest 可用 |
| B2 | `qemu-bash -c 'uname -m'` | x86_64 |
| B3 | `apk add curl` | 安装成功 |
| B4 | `curl --version` | 可用 |
| B5 | 安装一个非预置工具 | 可运行 |

### C. Chromium / 浏览器

| ID | 操作 | 预期 |
|---|---|---|
| C1 | Agent 打开网页 | 页面加载 |
| C2 | 读取 DOM/截图 | 返回内容 |
| C3 | 安装 Chrome 扩展 | 当前架构不支持 |

## 当前结果

### 已验证

- 终端 `pwd`、Python 版本、Python REPL 可用；
- `qemu` host 命令可用，`qemu -version` 返回 `qemu-x86_64 version 10.1.5`；
- Alpine rootfs 已打入 HAP 并解出；
- `qemu -L qemu-root qemu-root/bin/sh -c 'echo ALPINE_SH_OK'` 返回成功；
- 自研 `apk` 安装器已验证：`apk add curl` 自动安装 curl/libcurl 及其 12 个依赖；
- 安装后 `curl 8.14.1` 可执行，动态库符号链接正常；
- ArkWeb 调试端口 `127.0.0.1:9222` 已启用；
- `browser open https://example.com` 成功，返回标题 `Example Domain`；
- `browser text`、`browser dom`、`browser screenshot`、`browser click`、`browser type`、`browser eval`、`browser userscript` 均已验证；
- `browser close` 可关闭覆盖层；
- 截图输出到工作区 `dsh-browser.png`。

### 阻塞

- 旧 `libprobe` QEMU host 不适合作为执行入口，已改为自研 host 的 `qemu` 命令；
- ArkWeb 浏览器通过 iframe 承载，目标站点若设置 `X-Frame-Options`/CSP `frame-ancestors`，可能拒绝加载；
- 不支持 Chrome 扩展。
- HarmonyOS 沙箱不提供真实 Linux 内核，无法实现任意 `apt`/systemd/docker；
- ArkWeb 是 Chromium 内核，但没有 Chrome 扩展运行时，无法安装 Chrome Web Store 插件。

## 结论

原目标“完整 Linux 终端 + 任意工具安装 + Chromium 插件”在当前 HarmonyOS 沙箱架构下不可完整达成。

可交付的降级范围：

- 受限 QEMU Linux 用户态环境（需修 guest 启动链）；
- ArkWeb Agent 浏览器工具，支持导航、DOM、截图、输入和 userscript；
- 不支持 Chrome 扩展。

## 唤醒

验证期间每 5 分钟执行一次手机输入，避免 10 分钟休眠。

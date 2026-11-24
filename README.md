# DSH HOS

> 在 HarmonyOS 手机上运行完整的 DeepSeek Harness，不依赖 PC、Termux 或远程服务器。
>
> **非官方社区项目。** 与 DeepSeek 没有隶属、赞助或背书关系。"DeepSeek"、"DeepSeek Harness"、"DSH" 名称及鲸鱼标识归 DeepSeek 所有。

![DSH HOS 主界面](docs/images/home.jpeg)

## 这是什么

DSH HOS 是面向 HarmonyOS 的 **原生运行时 + 原生壳层**，把上游 DeepSeek Harness Web GUI 完整跑在手机本地：

- 上游 DSH 负责 Agent、模型、会话、插件和 Web UI；
- DSH HOS 负责鸿蒙窗口、ArkWeb、Node 运行时、Bash、终端、工具进程、文件系统和兼容层；
- 运行时完全在应用沙箱内启动，不需要电脑辅助。

当前基线：

```text
DSH engine   @deepseek-ai/dsh 0.2.3-alpha.2
Node         24.22.x（OHOS 自研入口 dsh_node_main）
Bash         GNU Bash 5.3（OHOS 自研入口 dsh_bash_main）
设备         Mate XTs (GRL-AL20) / HUAWEI 畅享 90 (JUY-AL80)，HarmonyOS 7
应用         v425
```

> **Mate XTs 已完成完整回归测试。** 当前版本在 Mate XTs 上覆盖启动、登录、模型、对话、会话持久化、工作区、右侧栏文件、新建终端、git/rg/python REPL、设置与关于页、系统浏览器链接、全屏沉浸式以及侧栏滑动返回。JUY-AL80 也已完成对应验证。

## 功能

| 模块 | 状态 |
|---|---|
| 本地运行时启动 / 解包 / ArkWeb 加载 | 已真机验证 |
| DeepSeek 账号登录（系统浏览器 OAuth） | 已真机验证 |
| 模型列表、账号、余额 | 已真机验证 |
| 流式对话、工具调用 | 已真机验证 |
| 会话保存 / 强杀重启恢复 | 已真机验证 |
| 工作区选择、工作区文件 | 已真机验证 |
| 右侧栏原生终端（bash） | 已真机验证 |
| 终端外部工具：git / rg / python3 | 已真机验证 |
| Python REPL 交互输入 | 已真机验证 |
| 设置 + 独立“关于”页 | 已真机验证 |
| 关于页链接调用系统浏览器 | 已真机验证 |
| 全屏沉浸式，上下无安全区留白 | 已真机验证 |
| 首页左滑开图3、右滑开图2 | 已真机验证 |
| 图2/图3/设置页任意方向滑回首页 | 已真机验证 |
| 设置页顶部菜单横滑不误触返回 | 已真机验证 |
| 系统返回键 / 手势关闭浮层，不退出应用 | 已真机验证 |

## 为什么做这个项目

现有 DSH 主要运行在桌面环境，手机上通常需要 Termux、Linux 沙箱或远程服务器。HarmonyOS 的应用沙箱又限制 `execve`、部分 native addon 和文件系统语义，直接搬 Linux 二进制并不可行。

DSH HOS 做的是：

1. 在应用进程内实现一个 **可 fork / dlopen / 管道通信的 native host**；
2. 为 Node 和 Bash 提供 OHOS 专用入口，不经过 `execve`；
3. 用兼容层绕开 HarmonyOS 对 `require_builtin.node`、`system.node`、`link(2)` 等能力的限制；
4. 用 ArkTS 重写终端 UI，让终端在 ArkWeb 之外由系统原生绘制和输入；
5. 在不修改上游 Web 业务逻辑的前提下，补上设置“关于”、返回手势等移动端体验。

## 整体架构

```text
┌──────────────────────────────────────────────────────────┐
│                    HarmonyOS Application                  │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ ArkTS Shell                                        │  │
│  │  EntryAbility  沉浸式窗口 / 生命周期                │  │
│  │  Index         启动页 / ArkWeb / 返回手势            │  │
│  │  NativeRuntime 运行时解包 / 环境 / 插件安装          │  │
│  │  TerminalView  原生终端 UI / 输入 / 键盘避让         │  │
│  └───────────────┬────────────────────────────────────┘  │
│                  │ NAPI                                  │
│  ┌───────────────▼────────────────────────────────────┐  │
│  │ libdsh_host.so（自研）                              │  │
│  │  probe / spawn / poll / write / terminate / release  │  │
│  │  tar.gz 解包 / symlink / chmod / 工具 IPC server     │  │
│  └───────┬───────────────────┬─────────────────────────┘  │
│          │ fork + dlopen     │ fork + dlopen               │
│  ┌───────▼────────┐  ┌───────▼────────┐  ┌──────────────┐  │
│  │ libnode.so     │  │ libbash.so     │  │ libgit/python │  │
│  │ dsh_node_main  │  │ dsh_bash_main  │  │ .so 工具入口  │  │
│  └───────┬────────┘  └───────┬────────┘  └──────┬───────┘  │
│          │                   │                  │          │
│  ┌───────▼───────────────────▼──────────────────▼───────┐  │
│  │ DSH engine / DSH Web（上游第三方）                    │  │
│  │ 本地 HTTP server → ArkWeb 加载                         │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### 启动链路

```text
EntryAbility
  → Index.start()
  → NativeRuntime.ensure()
      → 检查 runtime manifest
      → libdsh_host 解包 official-engine / npm / python / vim
      → 安装兼容 shim 和 DSH HOS 插件
      → 写入 bin 启动器、bash rc、工具环境
  → spawn(libnode.so, dsh_node_main, dsh web)
  → 获取本地 Web 地址
  → ArkWeb 加载 DSH Web
  → 登录 / 对话 / 会话 / 终端
```

终端链路：

```text
TerminalView
  → libdsh_host.spawn(libbash.so, dsh_bash_main)
  → pipe 轮询输出
  → TextInput 写入 stdin
  → bash rc 将 git/python/rg 等命令通过 TCP 127.0.0.1:47654 转给 host
  → host fork + dlopen 对应 .so 入口并回传输出
```

## 自研部分

| 组件 | 位置 | 作用 |
|---|---|---|
| `libdsh_host.so` | `app/native/host/src/main/cpp/napi_init.cpp` | 自研 NAPI host：fork/dlopen、子进程管道、tar.gz 解包、symlink、工具 IPC |
| Node 入口 | `native/node-entry/dsh_node_entry.cc` | `dsh_node_main`，为 OHOS 提供不经过 execve 的 Node 启动入口 |
| Bash 集成 | `app/entry/libs/arm64-v8a/libbash.so` | `dsh_bash_main` 入口，由 host dlopen 启动 |
| 原生终端 | `app/entry/src/main/ets/pages/Terminal.ets` | ArkTS 终端 UI、ANSI 清理、键盘、输入、HostShell |
| 壳层 | `app/entry/src/main/ets/pages/Index.ets` | 启动页、ArkWeb、窗口/安全区、外部链接、返回手势 |
| 运行时管理 | `app/entry/src/main/ets/platform/NativeRuntime.ets` | 资产解包、环境变量、启动器、插件安装、端口和进程管理 |
| require 兼容 | `app/entry/src/main/resources/rawfile/tools/require-builtin-shim.js` | 替代 `require_builtin.node` native addon |
| flock 兼容 | `app/entry/src/main/resources/rawfile/tools/flock-shim.js` | 替代 dlopen 被拒绝的 `system.node` |
| fs.link 兼容 | `app/entry/src/main/resources/rawfile/harmony/runtime-preload.cjs` | 用 copyFile + unlink 模拟被禁止的 `link(2)`，保证会话原子保存 |
| 工具 IPC | `libdsh_host` + `harmony/dsh-tools.sh` | 终端内 git/python/rg 等命令转发到 host 执行 |
| 设置关于页 | `tools/settings-general-about.js` | 在上游设置 UI 中增加独立“关于”标签 |
| 右栏终端 | `app/plugins/dsh-harmony-terminal/` | 自研右侧栏终端入口与 ArkTS 终端桥 |
| 返回手势 | `Index.onBackPress()` | Web history → 关闭可见浮层 → 消费返回，避免直接退出 |

## 仓库结构

```text
app/                    HarmonyOS 应用源码
  entry/src/main/ets/   ArkTS 壳层、终端、运行时管理
  native/host/          自研 libdsh_host
  entry/libs/           随包原生库（部分大资产不入 Git）
  plugins/              自研 DSH 客户端/宿主插件
native/node-entry/      自研 Node 入口
scripts/                构建、签名、安装脚本
docs/                   架构、构建、签名、返回手势、测试文档
docs/images/            README 截图
LICENSES/               第三方许可证
THIRD_PARTY_NOTICES.md
```

## 部署安装

### 方式 A：Release HAP（推荐给普通用户）

> Release 中的 HAP 为 **unsigned HAP**，不能直接安装，必须用你自己的 HarmonyOS 调试证书和 Profile 签名。

1. 从 [Releases](https://github.com/Jerrylee2044/dsh-hos/releases) 下载对应版本的 unsigned HAP；
2. 准备 HarmonyOS Command Line Tools、JDK 21；
3. 按 [docs/SIGN-INSTALL.md](docs/SIGN-INSTALL.md) 创建/使用自己的调试证书、注册手机 UDID、申请调试 Profile；
4. 签名并安装：

```bash
HAP_SIGN_TOOL=$TOOL_HOME/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar \
KEY_ALIAS=dsh-debug \
APP_CERT=signing/dsh-debug.cer \
PROFILE=signing/your-profile.p7b \
KEYSTORE=signing/dsh-debug.p12 \
bash scripts/sign-hap.sh \
  DSH-HOS-unsigned.hap \
  out/DSH-HOS-signed.hap

$TOOL_HOME/sdk/default/openharmony/toolchains/hdc install -r out/DSH-HOS-signed.hap
$TOOL_HOME/sdk/default/openharmony/toolchains/hdc shell aa start -a EntryAbility -b com.yourname.dshhos
```

> 包名必须与你的 APP ID、Profile、HAP 完全一致。第一次启动会解包运行时，约 1–2 分钟，请保持前台。

### 方式 B：从源码构建

前置：

- Linux 或 WSL（x86_64）
- HarmonyOS Command Line Tools（含 hvigor / SDK / hap-sign-tool）
- JDK 21
- 运行时大资产：Node/Bash/Python/DSH engine（不在 Git，见下文）

```bash
git clone https://github.com/Jerrylee2044/dsh-hos.git
cd dsh-hos
cp -r app build
cd build

export TOOL_HOME=/path/to/command-line-tools
export PATH="$TOOL_HOME/bin:$TOOL_HOME/tool/node/bin:$TOOL_HOME/sdk/default/openharmony/toolchains:$PATH"
export DEVECO_SDK_HOME="$TOOL_HOME/sdk"
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon
```

构建前需要把这些运行时资产放进 `build/entry`：

```text
entry/libs/arm64-v8a/
  libnode.so
  libbash.so
  libpython.so
  libgit.so / libgit-remote-http.so / librg.so ...
entry/src/main/resources/rawfile/tools/
  official-engine.tar.gz
  npm.tar.gz
  python-stdlib.tar
  vim-runtime.tar.gz
  runtime-manifest.json
```

这些文件较大（引擎约 100 MB、Node 库约 130 MB），不纳入 Git。可以直接从本项目的 unsigned HAP 中取出：

```bash
unzip -q DSH-HOS-0.2.3-alpha.2-hos.425-unsigned.hap \
  'libs/arm64-v8a/*' 'resources/rawfile/*' -d /tmp/dsh-runtime
cp -r /tmp/dsh-runtime/libs/arm64-v8a/* build/entry/libs/arm64-v8a/
cp -r /tmp/dsh-runtime/resources/rawfile/* build/entry/src/main/resources/rawfile/
```

然后按上面的构建命令编译。

### 首次使用

1. 启动后等待“正在启动本地运行时”完成；
2. 登录 DeepSeek 账号（会打开系统浏览器）；
3. 在输入框下方把访问模式切到 **完全权限**（HarmonyOS 无 Linux 沙箱后端时必需）；
4. 右侧栏可打开工作区文件、新建原生终端、更多工具。

## 已知限制

- Mate XTs (GRL-AL20) 与 JUY-AL80 已验证；其他机型仍需自行测试；
- 上游 `node-pty` 终端不可用，已统一到自研原生终端；
- 运行时大资产不入 Git，源码构建需要额外资产包；
- 非官方项目，不要用 DeepSeek 官方名义分发。

## 测试与文档

- [详细测试方案](docs/TEST-PLAN.md)
- [真机测试报告](docs/TEST-REPORT.md)
- [返回手势实现](docs/BACK-NAVIGATION.md)
- [构建说明](docs/BUILD.md)
- [签名与安装](docs/SIGN-INSTALL.md)

## 许可证

本项目源码见 [LICENSE](LICENSE)。上游 DSH、Node、Bash、Git、Python 等第三方组件版权与许可证见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与 [LICENSES](LICENSES/)。

# DSH HOS

> 非官方社区项目，与 DeepSeek 没有隶属、赞助或背书关系。
> "DeepSeek"、"DeepSeek Harness"、"DSH" 名称及鲸鱼标识归 DeepSeek 所有。

DSH HOS 是面向 HarmonyOS 的 **自研原生运行时**，运行上游 DeepSeek Harness Web GUI。
当前版本基于 `@deepseek-ai/dsh@0.2.3-alpha.2`，不再包含 Pocket/IEC 运行时、Pocket 终端或 Pocket
native 加载器。

## 当前状态

- 上游：`@deepseek-ai/dsh@0.2.3-alpha.2`
- Node：24.22.x，OHOS 自研入口 `dsh_node_main`
- 真机验证：HUAWEI 畅享 90 / JUY-AL80（HarmonyOS 7）
- 登录、模型对话、会话保存、设置关于页已真机验证
- Mate XTs 尚未在本次运行时上完成回归验收

## 架构

```text
ArkTS 壳层 (Index / NativeRuntime / Terminal / PluginGuard / EntryAbility)
        │
        ├─ libdsh_host.so    自研 fork + dlopen + pipe host + tar.gz 解包
        ├─ libnode.so        自研 Node 入口 dsh_node_main
        ├─ libbash.so        自研 Bash 入口 dsh_bash_main
        ├─ libpython.so      Python
        └─ DSH Web / DSH engine (上游第三方)
```

关键兼容层（HarmonyOS 沙箱限制）：

- `require-builtin-shim.js`：替代 `require_builtin.node` native addon
- `flock-shim.js`：替代被 dlopen 拒绝的 `system.node`
- `runtime-preload.cjs`：用 copyFile + unlink 模拟被禁止的 `link(2)` 原子提交
- `settings-general-about.js`：在 DSH 0.2.3 设置页增加独立“关于”标签

## 仓库内容

```text
app/                 HarmonyOS 应用源码（ArkTS + native host + 资源）
native/node-entry/   自研 Node 入口
scripts/             构建、签名、安装辅助脚本
docs/                架构、构建与验收文档
LICENSES/            第三方许可证
THIRD_PARTY_NOTICES.md
```

运行时大资产（Node/引擎 tar、OHOS SDK 构建产物）不放入 Git；由构建流程或 Release 资产提供。

## 构建

构建需要：

- HarmonyOS Command Line Tools（含 hvigor / SDK / hap-sign-tool）
- JDK 21
- Linux（或 WSL）
- 已构建的 OHOS Node 运行时资产与 DSH engine tarball

```bash
cp -r app build
cd build
TOOL_HOME=/path/to/command-line-tools \
JAVA_HOME=/path/to/jdk21 \
hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon
```

签名与安装见 `docs/SIGN-INSTALL.md`；运行时资产说明见 `docs/BUILD.md`。

## 许可证

本项目源码见 [LICENSE](LICENSE)。第三方组件与许可证见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 [LICENSES](LICENSES/)。

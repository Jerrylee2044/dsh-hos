# 构建 DSH HOS

## 1. 环境

| 项 | 版本/说明 |
|---|---|
| 主机 | Linux 或 WSL（x86_64） |
| HarmonyOS Command Line Tools | 5.1.0.840（API 18）或更新 |
| JDK | 21（工具版本 26 必需；5.1 可用 17/21） |
| Node | 工具链自带 `tool/node` |
| 磁盘 | 至少 5 GB（解包 + 构建缓存） |

Command Line Tools 从华为开发者下载中心获取（需要登录）：解压后目录里应有 `bin/`、`hvigor/`、`ohpm/`、`sdk/`、`tool/node/`。

```bash
export TOOL_HOME=/path/to/command-line-tools
export PATH="$TOOL_HOME/bin:$TOOL_HOME/tool/node/bin:$TOOL_HOME/sdk/default/openharmony/toolchains:$PATH"
export DEVECO_SDK_HOME="$TOOL_HOME/sdk"
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
```

## 2. Bootstrap

```bash
cd dsh-hos
BUNDLE_NAME=com.yourname.dshhos APP_NAME='DSH HOS' bash scripts/bootstrap.sh
```

它会把仓库内 `app/` 的完整源码复制到 `build/`，并从本仓库的 `v0.1.0-assets` release 下载运行时资产（约 400 MB），解出后应用补丁。

离线/已有资产：

```bash
BUNDLE_NAME=com.yourname.dshhos \
APP_SRC=/path/to/existing/app-source \
RUNTIME_HAP=/path/to/DSH-HOS-0.2.2-rc.5-unsigned.hap \
bash scripts/bootstrap.sh
```

## 3. 构建

```bash
PROJECT="$PWD/build" bash scripts/build-hap.sh
```

关键行为：

- `ohpm install --all`；
- `hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`；

产物：

```text
build/entry/build/default/outputs/default/entry-default-unsigned.hap
```

## 4. 项目补丁做了什么

`scripts/patch-project.sh`：

1. **启动门控**：`data-conversation-session` 在 DSH 0.2.2 系列里是空属性，原逻辑要求非空，导致启动页永远不撤；改成 `!!s`。
2. `bundleName` / `versionName` / `versionCode`。
3. `app_name` 与启动页标题。
4. `targetSdkVersion` / `compatibleSdkVersion` 改成 `5.1.0(18)`。
5. `hvigor-config.json5` / `oh-package.json5` 的 `modelVersion` 改成 `5.1.0`。

## 5. 为什么 target 是 API 18

上游运行时的最低兼容版本是 API 18，Linux 版 CLI Tools 5.1 自带 API 18 SDK；先以 18 构建，HAP 在 HarmonyOS 7 上以兼容模式运行。

如果你有 API 26 SDK：

- 把 `targetSdkVersion` / `compatibleSdkVersion` 改成 `"26.0.0"` 或 `"6.1.1(24)"`（按 SDK 支持的格式）；
- 用 API 26 SDK 重编；
- 在 7.0 真机上重新跑一遍验收。

## 6. 资产来源

`bootstrap.sh` 从本仓库的 `v0.1.0-assets` release 下载运行时资产（国内可设 `ASSET_BASE=https://ghfast.top/https://github.com/Jerrylee2044/dsh-hos/releases/download/v0.1.0-assets` 走镜像）：

```text
https://github.com/Jerrylee2044/dsh-hos/releases/tag/v0.1.0-assets
```

这个运行时 HAP 包含引擎/npm/Python/Vim 归档与原生库；版权与许可见 [NOTICE.md](../NOTICE.md) 与 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。

## 6.1 更新 DSH 引擎

从 0.2.2-rc.5 起，引擎直接从 npm 的 `@deepseek-ai/dsh` 更新，不再依赖旧上游 release：

```bash
PROJECT="$PWD/build" bash scripts/update-engine.sh 0.2.2-rc.5
```

详见 [UPDATE-DSH.md](UPDATE-DSH.md)。

## 7. 常见构建问题

| 问题 | 处理 |
|---|---|
| `Duplicated files found in module entry` | `build-hap.sh` 已自动删除三个重复库；手动构建也要删 |
| `modelVersion` 不匹配 | 改成 `5.1.0`（或你的 SDK 对应版本） |
| `targetSdkVersion` 格式错误 | 按 IDE/hvigor 提示改成字符串 |
| `hap-sign-tool.jar` 找不到 | 在 `$TOOL_HOME/sdk/default/openharmony/toolchains/lib/` |
| `ohpm install` 失败 | 检查 `ohpm` 在 PATH、`TOOL_HOME` 正确 |

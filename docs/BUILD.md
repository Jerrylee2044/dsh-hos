# 构建 DSH HOS

> 普通安装请优先使用 Release 中的 unsigned HAP，并按 [SIGN-INSTALL.md](SIGN-INSTALL.md) 用你自己的证书签名。本文是源码构建说明。

## 环境

| 项 | 说明 |
|---|---|
| 主机 | Linux / WSL x86_64 |
| HarmonyOS Command Line Tools | 含 hvigor、SDK、ohpm、hap-sign-tool |
| JDK | 21 |
| 磁盘 | 至少 5 GB |

```bash
export TOOL_HOME=/path/to/command-line-tools
export PATH="$TOOL_HOME/bin:$TOOL_HOME/tool/node/bin:$TOOL_HOME/sdk/default/openharmony/toolchains:$PATH"
export DEVECO_SDK_HOME="$TOOL_HOME/sdk"
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
```

## 1. 准备源码

```bash
git clone https://github.com/Jerrylee2044/dsh-hos.git
cd dsh-hos
cp -r app build
```

## 2. 准备运行时资产

运行时大文件不纳入 Git，可从本项目的 unsigned HAP 中提取：

```bash
unzip -q DSH-HOS-0.2.3-alpha.2-hos.388-unsigned.hap \
  'libs/arm64-v8a/*' 'resources/rawfile/*' -d /tmp/dsh-runtime
cp -r /tmp/dsh-runtime/libs/arm64-v8a/* build/entry/libs/arm64-v8a/
cp -r /tmp/dsh-runtime/resources/rawfile/* build/entry/src/main/resources/rawfile/
```

必须存在：

```text
build/entry/libs/arm64-v8a/libnode.so
build/entry/libs/arm64-v8a/libbash.so
build/entry/libs/arm64-v8a/libpython.so
build/entry/libs/arm64-v8a/libgit.so ...
build/entry/src/main/resources/rawfile/tools/official-engine.tar.gz
build/entry/src/main/resources/rawfile/tools/npm.tar.gz
build/entry/src/main/resources/rawfile/tools/python-stdlib.tar
build/entry/src/main/resources/rawfile/tools/vim-runtime.tar.gz
build/entry/src/main/resources/rawfile/tools/runtime-manifest.json
```

## 3. 构建

```bash
cd build
hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon
```

产物：

```text
entry/build/default/outputs/default/entry-default-unsigned.hap
```

## 4. 签名安装

见 [SIGN-INSTALL.md](SIGN-INSTALL.md)。

## 常见问题

| 问题 | 处理 |
|---|---|
| 缺 `libnode.so` / `libbash.so` | 没有放入运行时资产，见第 2 步 |
| `Duplicated files found` | 清理 `entry/libs/arm64-v8a` 中重复库后重试 |
| `hvigorw` 找不到 | 检查 `TOOL_HOME`、`PATH` |
| `hap-sign-tool.jar` 找不到 | 位于 SDK `toolchains/lib/` |
| HAP 装不上 | 包名/证书/Profile/UDID 必须一致 |

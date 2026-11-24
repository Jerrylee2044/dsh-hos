# DSH HOS 终端工具清单

面向开发、运维和日常排障，终端工具分为四层。

## 1. 自研 host 工具（29 个）

由 `__dsh_tool` 通过 `127.0.0.1:47654` 调起 HAP 内对应的 `.so` 入口：

| 类别 | 命令 |
|---|---|
| 版本管理 | `git`、`gh`、`diff` |
| 语言/包管理 | `python`、`python3`、`pip`、`node` |
| 文本/数据 | `rg`、`jq`、`less`、`bc`、`hexdump`、`vim` |
| 归档/同步 | `tar`、`cpio`、`unzip`、`zip`、`xz`、`zstd`、`rsync` |
| 网络 | `curl`、`nc`、`ssh`、`scp`、`sftp` |
| 加密/数据库 | `openssl`、`sqlite3` |
| 通用 | `tree`、`toybox` |

## 2. 经 Node 启动的包管理命令（2 个）

```text
npm
npx
```

实际执行：

```text
dsh_node_main $IEC_SYSROOT/npm/bin/npm-cli.js
dsh_node_main $IEC_SYSROOT/npm/bin/npx-cli.js
```

## 3. Git 内部辅助命令（3 个）

由 `command_not_found_handle` 转发：

```text
git-remote-http
git-remote-https
git-lfs
```

## 4. 系统 PATH / Bash 内建

系统 PATH 包含：

```text
<runtime>/bin:/system/bin:/system/xbin
```

可用系统 toybox/applet，例如：

```text
ls cat cp mv rm mkdir rmdir touch ln
find grep sed awk head tail wc sort uniq cut tr xargs tee
ps top kill df du free date uname whoami id env
sh sleep timeout nohup ping
```

Bash 内建（61 个）：

```text
: . [ alias bg bind break builtin caller cd command
compgen complete compopt continue declare dirs disown
echo enable eval exec exit export false fc fg getopts
hash help history jobs kill let local logout mapfile
popd printf pushd pwd read readarray readonly return
set shift shopt source suspend test times trap true
type typeset ulimit umask unalias unset wait
```

## 统计口径

- 自研 host 工具：**29 个**
- npm/npx：**2 个**
- Git 辅助入口：**3 个**
- Bash 内建：**61 个**
- 合计显式命令入口：**95 个**
- 系统 toybox/applet 未计入，实际可用命令更多。

## 当前未包含

由于没有随包二进制，且 HarmonyOS 应用不能随意 `exec` 新程序，当前不提供：

- `gcc` / `clang` / `make` / `cmake`
- `docker` / `kubectl` / `systemctl`
- `apt` / `opkg`
- 完整 Linux 用户态工具链

这些需要额外构建静态二进制并通过自研 host 入口启动，不能直接从 PC Linux 拷贝。

## 已知验证状态

已重点验证：

```text
git --version
rg --version
python3 --version
python3（REPL）
ls
```

其余工具已完成宿主映射、库打包和 HAP 安装，但尚未逐个做完整功能验收。

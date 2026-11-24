# 第三方软件声明

本应用 **DSH HOS** 是第三方（非官方）项目，基于 MIT 许可上游运行时的 HarmonyOS 原生实现，与 DeepSeek 没有隶属、
赞助或背书关系。"DeepSeek"、"DeepSeek Harness" 名称及鲸鱼标识归 DeepSeek 所有，本项目仅在
描述所兼容的上游软件时使用它们。

本文件汇总随应用分发的第三方组件及其许可证。许可证全文见 `LICENSES/` 目录，同一份文件也随
HAP 分发（应用内路径 `resources/rawfile/notices/`，首次启动后解出到应用沙箱的 `files/notices/`）。

## 组件清单

| 组件 | 版本 / 来源 | 许可证 | 提示文本 |
| --- | --- | --- | --- |
| DeepSeek Harness（`@deepseek-ai/dsh` 及官方包） | 0.2.2-rc.1，npm 官方发布物 | MIT | `LICENSES/DSH-MIT.txt`；引擎归档内每个 npm 包另带自己的 `LICENSE`（735 份） |
| 本工程原创代码（ArkTS 壳、libdsh_host、终端插件、鸿蒙适配插件、QEMU 移植） | 本仓库 | MIT | `LICENSE` |
| `@local/dsh-harmony-terminal`（原生终端 tab） | `plugins/dsh-harmony-terminal` | MIT | `LICENSE` |
| `@deepseek-ai/dsh-harmony-compat`（鸿蒙适配：返回手势状态、引用浮层） | `plugins/harmony-compat` | MIT | `LICENSE` |
| GNU Bash | 5.3，<https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz>，未打补丁 | GPL-3.0 | `LICENSES/GPL-3.0.txt` |
| GNU Git（`libgit.so`、`libgit-remote-http.so`） | 2.56.0，<https://github.com/git/git>，未打补丁 | GPL-2.0 | `LICENSES/GPL-2.0.txt` |
| OpenSSL（静态链接进 `libgit-remote-http.so`） | 3.0.22，<https://github.com/openssl/openssl> | Apache-2.0 | `LICENSES/Apache-2.0-OpenSSL.txt` |
| libcurl（静态链接进 `libgit-remote-http.so`） | 8.22.0，<https://curl.se/download/curl-8.22.0.tar.gz> | curl | `LICENSES/curl.txt` |
| PCRE2（静态链接进 `libgit.so`） | 10.49，<https://github.com/PCRE2Project/pcre2> | BSD-3-Clause | `LICENSES/pcre2.txt` |
| zlib（静态链接进两个 git 库） | 1.3.1，<https://zlib.net> | zlib | `LICENSES/zlib.txt` |
| Node.js | v24.22.1，<https://nodejs.org>（源码包） | MIT | `LICENSES/Node-MIT.txt` |
| npm | 11.19.1（Node.js 源码树 `deps/npm`） | Artistic-2.0 | `LICENSES/Artistic-2.0.txt` |
| toybox | 0.8.14 | 0BSD | `LICENSES/toybox.txt` |
| libarchive（bsdtar / bsdcpio / unzip / zipcmd） | 3.7.7 | BSD-2-Clause | `LICENSES/libarchive.txt` |
| bzip2 / libbz2（静态链接进 libarchive 前端与 CPython） | 1.0.8，<https://sourceware.org/pub/bzip2/> | bzip2-1.0.8（BSD 风格） | `LICENSES/bzip2.txt` |
| ripgrep | 14.1.1 | Unlicense OR MIT | `LICENSES/ripgrep-UNLICENSE.txt`、`LICENSES/ripgrep-MIT.txt` |
| libc++（`libc++_shared.so`） | DevEco Studio SDK 自带 | Apache-2.0 WITH LLVM-exception | `LICENSES/Apache-2.0-LLVM.txt` |
| `@deepseek-ai/node-addon-system`（`system.node`） | 官方源码 | BSD-3-Clause | 见上游 `LICENSE` |
| `@deepseek-ai/dsh-node-addon-require-builtin` | 官方源码 | MIT | 见上游 `LICENSE` |
| `@vscode/ripgrep` 兼容包 | 本工程重写 | MIT | `LICENSE` |
| Dropbear SSH | 上游源码 | MIT | `LICENSES/dropbear.txt` |
| OpenSSH（ssh/sftp 客户端） | 上游源码 | SSH / BSD | `LICENSES/openssh.txt` |
| GitHub CLI（gh） | 上游源码 | MIT | `LICENSES/gh.txt` |
| jq | 1.7 上游源码 | MIT | `LICENSES/jq.txt` |
| less | 上游源码 | GPL-3.0 / less | `LICENSES/less.txt` |
| Python | 3.12 标准库 | PSF | `LICENSES/Python-PSF.txt` |
| rsync | 上游源码 | GPL-3.0 | `LICENSES/rsync.txt` |
| SQLite | 上游源码 | Public Domain | `LICENSES/sqlite.txt` |
| tree | 上游源码 | GPL-2.0 | `LICENSES/tree.txt` |
| Vim | 上游源码 | Vim License | `LICENSES/vim.txt` |
| xz / liblzma | 上游源码 | Public Domain | `LICENSES/xz.txt` |
| zstd | 上游源码 | BSD-3-Clause | `LICENSES/zstd.txt` |
| libtomcrypt / libtommath | 上游源码 | Public Domain | `LICENSES/libtomcrypt.txt`、`LICENSES/libtommath.txt` |
| oniguruma | 上游源码 | BSD-2-Clause | `LICENSES/oniguruma.txt` |
| ncurses | 上游源码 | MIT | `LICENSES/ncurses.txt` |
| popt | 上游源码 | MIT | `LICENSES/popt.txt` |
| setuptools / pip / wheel | 上游源码 | MIT | `LICENSES/setuptools.txt`、`LICENSES/pip.txt`、`LICENSES/wheel.txt` |
| Go runtime（随 QEMU 工具构建） | 上游源码 | BSD-3-Clause | `LICENSES/Go-BSD.txt` |
| QEMU linux-user | 上游源码 + 本项目鸿蒙移植 | GPL-2.0 | `LICENSES/GPL-2.0.txt`；对应源码索取见 Issue |
| Mozilla CA 根证书集（`cacert.pem`） | Mozilla，纯数据 | MPL-2.0（数据本身为公开证书） | <https://www.mozilla.org/MPL/2.0/> |
| 可选附加 CA（`extra-ca.pem`） | 用户自行提供（不随仓库分发） | 由提供者负责 | 用于会拦截 HTTPS 的开发环境 |

## GNU Bash 的对应源码

分发的 `libbash.so` 由 GNU Bash 5.3 的**原样源码**交叉编译得到，没有修改上游源码：

- 源码包：<https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz>，构建脚本会记录其 SHA-256；
- 由本项目工具链交叉编译；进程/终端由自研 `libdsh_host` 托管。
- 如果上述地址不可用，可通过本仓库的 Issue 向维护者索取对应源码。

GPL-3.0 全文见 `LICENSES/GPL-3.0.txt`。

## GNU Git 的对应源码

分发的 `libgit.so` 与 `libgit-remote-http.so` 由 GNU Git 2.56.0 的**原样源码**交叉编译得到，
没有修改上游源码：

- 源码包：<https://github.com/git/git/archive/refs/tags/v2.56.0.tar.gz>；
- 由本项目工具链交叉编译为共享库；
- 同时静态链接的依赖源码：OpenSSL 3.0.22、libcurl 8.22.0、PCRE2 10.49、zlib 1.3.1，
  下载地址见上表；许可证原文在 `LICENSES/`；
- 如果上述地址不可用，可通过本仓库的 Issue 向维护者索取对应源码。

GPL-2.0 全文见 `LICENSES/GPL-2.0.txt`。

## 对上游 DSH 的修改

本应用没有修改 `@deepseek-ai/dsh` 的源码，只做了三件事：

1. 在 profile 里新增客户端插件 `@local/dsh-harmony-terminal`，把右侧栏终端交给 ArkTS 壳层；
2. 在 profile 里新增客户端插件 `@deepseek-ai/dsh-harmony-compat`，提供返回手势所需的浮层状态上报与引用浮层定位；
3. 在 profile 补丁里禁用自带 Web 终端插件（`ui-sidebar-terminal`），因为它依赖的 PTY 在鸿蒙沙箱内不可用。

DSH 采用 MIT 许可，上述修改与再分发均在许可范围内。

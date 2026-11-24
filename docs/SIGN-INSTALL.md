# 自签证书并安装到自己的鸿蒙手机

> 目标：用自己的华为开发者账号，生成调试证书 + 绑定自己手机 UDID 的调试 Profile，把一个 **自己构建的** DSH HOS HAP 装到手机上。
>
> 关键点：**bundle name、证书、Profile、设备 UDID 四者必须完全对应**。

---

## 0. 前置

| 项 | 要求 |
|---|---|
| 华为开发者账号 | 已注册；建议实名（未实名调试证书只有 14 天） |
| 手机 | 已开启开发者模式 + USB 调试；电脑能 `hdc list targets` |
| Command Line Tools | 含 `hdc`、`hap-sign-tool.jar`、`hvigorw`、`ohpm` |
| JDK | 21（工具版本 26 需要；5.1 工具 17/21 均可） |
| 已构建 HAP | 按 [BUILD.md](BUILD.md) 构建出的 unsigned HAP |

下文用：

```text
BUNDLE=com.yourname.dshhos
TOOL_HOME=/path/to/command-line-tools
```

把 `BUNDLE` 换成你自己的包名。**包名一旦在 AGC 创建就不能改**。

---

## 1. 创建 APP ID（即“创建应用”）

1. 登录 [HarmonyOS 开发者中心](https://developer.huawei.com/consumer/cn/hdc-console)。
2. 进入 **“开发者管理”**。
3. 左侧 **“ID、证书和Profile” → “APP ID”**。
4. 左上角选 **HarmonyOS**，右上角 **“创建”**。
5. 填写：

| 字段 | 值 |
|---|---|
| 应用类型 | HarmonyOS 应用 |
| 应用名称 | 自定义（不要用 DeepSeek 官方名义） |
| 应用包名 | **`BUNDLE`**，必须和 HAP 完全一致 |
| 应用分类 | 工具/效率 |
| 支持设备 | 手机 |
| 默认语言 | 简体中文 |
| 项目 | 新建一个 |

6. 确认。

> 如果包名已被占用，换一个包名，并用新包名重新跑 `bootstrap.sh` / 构建 HAP。

---

## 2. 生成 keystore + CSR

```bash
TOOL_HOME=$TOOL_HOME bash scripts/make-csr.sh
```

脚本会提示输入 keystore 密码（至少 6 位），生成：

```text
signing/dsh-debug.p12    # 私钥，务必保管好
signing/dsh-debug.csr    # 上传到 AGC
```

> 换电脑/丢 `.p12` 后证书就废了，只能重新申请。

---

## 3. 申请调试证书

1. 左侧 **“ID、证书和Profile” → “证书” → “新增证书”**。
2. 证书名称：`dsh-debug`；类型：**调试证书**。
3. 选取证书请求文件（CSR）：上传 `signing/dsh-debug.csr`。
4. 提交并下载 `.cer`，放到 `signing/dsh-debug.cer`。

> 每个账号最多 3 个调试证书。

---

## 4. 注册调试设备（UDID）

1. 手机：设置 → 关于手机 → 连点“版本号”7 次 → 开发者模式。
2. 设置 → 系统和更新 → 开发人员选项 → 打开 **USB 调试**。
3. 插拔数据线，手机弹窗选 **允许**；USB 用途选“传输文件”。
4. 电脑：

```bash
HDC=$TOOL_HOME/sdk/default/openharmony/toolchains/hdc
$HDC list targets
$HDC shell bm get --udid
```

5. 复制 64 位 UDID。
6. 开发者中心 → **“ID、证书和Profile” → “设备” → “添加设备”**：名称、类型手机、粘贴 UDID。

> `hdc list targets` 为 `[Empty]`：检查 USB 调试、授权弹窗、数据线；必要时“撤销 USB 调试授权”再插。

---

## 5. 申请调试 Profile

1. **“ID、证书和Profile” → “Profile” → “添加”**。
2. 应用：选第 1 步的 APP ID。
3. 类型：**调试**。
4. 证书：选第 3 步的 `dsh-debug`。
5. 设备：选第 4 步注册的手机。
6. 提交并下载 `.p7b`，放到 `signing/<name>.p7b`。

---

## 6. 签名 HAP

```bash
HAP_SIGN_TOOL=$TOOL_HOME/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar \
KEY_ALIAS=dsh-debug \
APP_CERT=signing/dsh-debug.cer \
PROFILE=signing/<你的profile>.p7b \
KEYSTORE=signing/dsh-debug.p12 \
bash scripts/sign-hap.sh \
  build/entry/build/default/outputs/default/entry-default-unsigned.hap \
  out/DSH-HOS-signed.hap
```

脚本会提示输入 key/keystore 密码（同一个密码），成功后打印 `verify-app success`。

> 如果 Profile/证书/包名/UDID 任一不匹配，后面安装会报 `9568322` 或 `parse profile prop check error`。

---

## 7. 安装与启动

```bash
HDC=$TOOL_HOME/sdk/default/openharmony/toolchains/hdc
$HDC install -r out/DSH-HOS-signed.hap
$HDC shell aa start -a EntryAbility -b BUNDLE
$HDC hilog | grep -iE 'DSH|THREAD_BLOCK|APP_FREEZE'
```

首启会解包约 46 MB 引擎 + npm + Python/Vim，约 1–2 分钟，保持前台。

---

## 8. 安装后第一件事：切“完全权限”

设备上没有可用的 Linux 沙箱后端，默认 **“工作区内修改”** 模式下 bash 会被拒绝。使用前在输入框下方把访问模式切到 **“完全权限”**。

这是 DSH 应用沙箱内的权限，不是手机系统权限。

---

## 9. 常见错误

| 错误 | 原因 | 处理 |
|---|---|---|
| `9568322 not trusted app source` | 证书/Profile/包名/UDID 不匹配，或用了 release 证书 | 用调试证书 + 调试 Profile；核对四者 |
| `parse profile prop check error` | Profile 的 bundleName 与 HAP 不一致 | 重新建 Profile 或改 HAP 包名 |
| `9568257 fail to verify pkcs7 file` | Profile 不是华为信任链（例如 OpenHarmony 测试证书） | 必须用 AGC 签发的调试证书/Profile |
| `hdc list targets` 为 `[Empty]` | USB 调试没开 / 未授权 / 仅充电 | 开 USB 调试、允许弹窗、换数据线 |
| 启动页一直转 | 旧版本启动门控 bug | 用本仓库 `bootstrap.sh` 的补丁重建 |
| bash 报 sandbox backend | 默认 workspace-write | 切“完全权限” |

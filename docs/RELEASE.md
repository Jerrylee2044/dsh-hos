# 发布与包名

## 当前包名

```text
com.dsh.hos
```

发布构建：

```text
DSH-HOS-0.2.3-alpha.2-hos.454-unsigned.hap
versionName: 0.2.3-alpha.2-hos.454
versionCode: 454
```

## 改名影响

- 新包名是一个全新的 HarmonyOS 应用；
- 旧包 `com.matexts.harness` 不能直接升级到 `com.dsh.hos`；
- 用户需要卸载旧应用后安装新包，旧应用数据不会自动迁移；
- 原有调试签名 Profile 不能用于新包名。

## AppGallery Connect 步骤

1. 在 AGC 创建新应用，包名填写：

   ```text
   com.dsh.hos
   ```

2. 为该应用创建 release 证书和 release Profile；
3. 下载 `.cer`、`.p7b`、`.p12`；
4. 使用新 Profile 签名 unsigned HAP：

   ```bash
   HAP_SIGN_TOOL=$TOOL_HOME/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar \
   KEY_ALIAS=release \
   APP_CERT=signing/release.cer \
   PROFILE=signing/com.dsh.hos-release.p7b \
   KEYSTORE=signing/release.p12 \
   bash scripts/sign-hap.sh \
     DSH-HOS-0.2.3-alpha.2-hos.454-unsigned.hap \
     out/DSH-HOS-0.2.3-alpha.2-hos.454-signed.hap
   ```

5. 在 AppGallery Connect 上传已签名 HAP；
6. 上传桌面上的 1024×1024 图标：

   ```text
   /home/jerrylee/Desktop/DSH-HOS-图标-1024.png
   ```

## 本机构建

```bash
cd dsh-harmonyos-analysis/mate-xts
export TOOL_HOME=/var/tmp/hmos-clt26
export PATH="$TOOL_HOME/bin:$TOOL_HOME/tool/node/bin:$TOOL_HOME/sdk/default/openharmony/toolchains:$PATH"
export DEVECO_SDK_HOME="$TOOL_HOME/sdk"
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
cd /var/tmp/dsh-alpha2/build
hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon
```

产物：

```text
/var/tmp/dsh-alpha2/build/entry/build/default/outputs/default/entry-default-unsigned.hap
```

## 注意

- 应用图标必须与包内 `app_icon.png` 一致；
- 发布签名不能使用 `signing/matexts-debug.p12`；
- 包名创建后在 AGC 中不可随意更改，请确认后再创建。

import { UIAbility, ConfigurationConstant, common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { fileIo as fs } from '@kit.CoreFileKit';
import BuildProfile from 'BuildProfile';
import probe from 'libprobe.so';

const LIGHT_BG = '#F7F7F0';
const DARK_BG = '#101113';

/**
 * DSH HOS 的应用入口。
 *
 * 职责只有三件事：
 *  1. 建立沉浸式窗口（无系统栏，页面自行避让挖孔/手势条）；
 *  2. 加载自研 Shell 页面；
 *  3. 把随包的 x86_64 工具解到 filesDir，并启动 QEMU 命令宿主。
 *
 * DSH Web、Node 运行时与终端都在 Shell/NativeRuntime 层启动，本 Ability 不碰业务。
 */
export default class EntryAbility extends UIAbility {
  private win?: window.Window;

  private makeImmersive(win: window.Window): void {
    try { win.setWindowLayoutFullScreen(true); } catch (error) { /* 老版本忽略 */ }
    try { win.setWindowSystemBarEnable([]); } catch (error) { /* 老版本忽略 */ }
    // 关闭系统侧滑返回热区，改为应用内左右滑手势：
    // 首页左滑开右栏、右滑开左栏，其他页面左滑返回。
    try {
      win.setGestureBackEnabled(false).catch(() => {});
    } catch (error) { /* 版本不支持 */ }
  }

  private paintWindow(win: window.Window): void {
    const dark = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    try { win.setWindowBackgroundColor(dark ? DARK_BG : LIGHT_BG); } catch (error) { /* 忽略 */ }
  }

  private unpackQemuTools(): string {
    const target = this.context.filesDir + '/qemu-tools';
    try { if (!fs.accessSync(target)) { fs.mkdirSync(target, true); } } catch (error) { /* 已存在 */ }
    for (const name of ['bash', 'git', 'rg', 'busybox']) {
      const bytes = this.context.resourceManager.getRawFileContentSync('qemu/' + name);
      const path = target + '/' + name;
      let write = true;
      try { write = fs.statSync(path).size !== bytes.byteLength; } catch (error) { write = true; }
      if (write) {
        const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
        } finally {
          fs.closeSync(file);
        }
      }
      probe.chmodPath(path);
    }
    return target;
  }

  private startCommandHost(): void {
    try {
      probe.startHttp(this.unpackQemuTools());
    } catch (error) { /* QEMU 可选，失败不影响主界面 */ }
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    try { webview.WebviewController.setWebDebuggingAccess(BuildProfile.DEBUG); } catch (error) { /* 调试开关 */ }
    try {
      const context = this.context as common.UIAbilityContext;
      context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (error) { /* 忽略 */ }

    try {
      this.win = stage.getMainWindowSync();
      this.makeImmersive(this.win);
    } catch (error) { /* 窗口未就绪 */ }

    stage.loadContent('pages/Index').then(() => {
      if (this.win) { this.paintWindow(this.win); }
      // QEMU is served by the self-developed host; the old probe HTTP host is intentionally not started.
    }).catch(() => {});
  }

  onConfigurationUpdate(): void {
    if (!this.win) { return; }
    this.makeImmersive(this.win);
    this.paintWindow(this.win);
  }
}

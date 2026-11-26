import { common, Want } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { window, mediaquery } from '@kit.ArkUI';
import { util, url } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeRuntime } from '../platform/NativeRuntime';
import { TerminalView } from './Terminal';

const LOG = '[DSH-HOS-Shell]';
const LIGHT_BG = '#F7F7F0';
const DARK_BG = '#101113';

interface BridgeMessage {
  op?: string;
  owner?: string;
  cwd?: string;
  left?: number;
  top?: number;
  width?: number;
  height?: number;
  visible?: boolean;
  url?: string;
}

/**
 * DSH HOS 自研壳层页面（阶段 A）。
 *
 * 只负责四件事：
 *  1. 启动 NativeRuntime 并加载 DSH Web；
 *  2. 保持沉浸式/主题/安全区；
 *  3. 接收终端插件通过 console 上报的 tab 几何；
 *  4. 把站外链接交给系统浏览器。
 */
@Entry
@Component
struct Index {
  @State private url: string = '';
  @State private status: string = '正在启动本地运行时';
  @State private failed: string = '';
  @State private ready: boolean = false;
  @State private booting: boolean = false;
  @State private dark: boolean = false;
  @State private bg: string = LIGHT_BG;
  @State private insetTop: number = 0;
  @State private insetBottom: number = 0;
  @State private termShown: boolean = false;
  @State private termVisible: boolean = false;
  @State private termLeft: number = 0;
  @State private termTop: number = 0;
  @State private termWidth: number = 0;
  @State private termHeight: number = 0;
  @State private termCwd: string = '';
  private runtime?: NativeRuntime;
  private controller: webview.WebviewController = new webview.WebviewController();
  private nonce: string = util.generateRandomUUID(true);
  private termOwner: string = '';
  private themeListener?: mediaquery.MediaQueryListener;
  private started: boolean = false;
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private touchStartAt: number = 0;

  aboutToAppear(): void {
    this.watchTheme();
    this.watchInsets();
    // Render the lightweight loading shell first. Runtime unpacking is synchronous
    // on the host bridge, so starting it inside aboutToAppear delays the first frame.
    setTimeout(() => { this.start(); }, 120);
  }

  aboutToDisappear(): void {
    this.themeListener?.off('change');
    this.runtime?.stopWebUI();
  }

  private watchTheme(): void {
    try {
      this.themeListener = mediaquery.matchMediaSync('(prefers-color-scheme: dark)');
      this.applyTheme(this.themeListener.matches);
      this.themeListener.on('change', (event: mediaquery.MediaQueryResult) => this.applyTheme(event.matches));
    } catch (error) { /* 忽略 */ }
  }

  private applyTheme(dark: boolean): void {
    this.dark = dark;
    this.bg = dark ? DARK_BG : LIGHT_BG;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(context).then((win: window.Window) => {
        win.setWindowBackgroundColor(this.bg);
      }).catch(() => {});
    } catch (error) { /* 未就绪 */ }
  }

  private watchInsets(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(context).then((win: window.Window) => {
        const top = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
        const bottom = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
        this.insetTop = Math.round(this.getUIContext().px2vp(top));
        this.insetBottom = Math.round(this.getUIContext().px2vp(bottom));
      }).catch(() => {});
    } catch (error) { /* 忽略 */ }
  }

  private async start(): Promise<void> {
    if (this.booting) { return; }
    this.booting = true;
    this.started = true;
    this.failed = '';
    this.status = '正在启动本地运行时';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!this.runtime) { this.runtime = new NativeRuntime(context); }
      const target = await this.runtime.startWebUI((text: string) => {
        if (text.indexOf('dsh web:') >= 0) { this.status = '本地服务已启动'; }
      }, (active: boolean) => {
        this.status = active ? '首次启动，正在解包运行时' : '正在启动本地运行时';
      });
      this.url = target;
      this.status = '正在加载 DSH 界面';
    } catch (error) {
      this.failed = (error as Error).message;
      this.status = '启动失败';
      hilog.error(0, LOG, 'start failed: %{public}s', this.failed);
    } finally {
      this.booting = false;
    }
  }

  private localOrigin(): string {
    try { return new url.URL(this.url).origin; } catch (error) { return ''; }
  }

  private isLocal(target: string): boolean {
    const origin = this.localOrigin();
    if (origin === '') { return false; }
    try {
      const parsed = new url.URL(target);
      return (parsed.protocol === 'http:' || parsed.protocol === 'https:') && parsed.origin === origin;
    } catch (error) { return false; }
  }

  private openExternal(target: string): void {
    if (!/^https?:\/\//i.test(target)) { return; }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: target,
        entities: ['entity.system.browsable'],
        flags: 0x10000000
      };
      context.startAbility(want).catch(() => {
        context.openLink(target).catch(() => {});
      });
    } catch (error) { /* 没有浏览器 */ }
  }

  private sameOwner(owner: string): boolean {
    return owner === '' || this.termOwner === '' || owner === this.termOwner;
  }

  private onBridge(text: string): void {
    const prefix = 'DSH_TERM:' + this.nonce + ':';
    if (text.indexOf(prefix) !== 0) { return; }
    let message: BridgeMessage;
    try { message = JSON.parse(text.slice(prefix.length)) as BridgeMessage; } catch (error) { return; }
    const op = typeof message.op === 'string' ? message.op : '';
    const owner = typeof message.owner === 'string' ? message.owner : '';
    if (op === 'open') {
      if (!this.sameOwner(owner)) { return; }
      if (owner !== '') { this.termOwner = owner; }
      this.termShown = true;
      this.termVisible = false;
      if (typeof message.cwd === 'string' && message.cwd !== '') { this.termCwd = message.cwd; }
    } else if (op === 'bounds') {
      if (!this.sameOwner(owner)) { return; }
      this.termLeft = Number(message.left) || 0;
      this.termTop = Number(message.top) || 0;
      this.termWidth = Math.max(1, Number(message.width) || 0);
      this.termHeight = Math.max(1, Number(message.height) || 0);
      this.termShown = true;
      this.termVisible = message.visible === true && this.termWidth > 1 && this.termHeight > 1;
      if (owner !== '' && this.termOwner === '') { this.termOwner = owner; }
    } else if (op === 'visible') {
      if (this.sameOwner(owner)) { this.termVisible = message.visible === true; }
    } else if (op === 'cwd') {
      if (typeof message.cwd === 'string' && message.cwd !== '') { this.termCwd = message.cwd; }
    } else if (op === 'close') {
      if (!this.sameOwner(owner)) { return; }
      this.termShown = false;
      this.termVisible = false;
      this.termOwner = '';
    } else if (op === 'openExternal') {
      if (typeof message.url === 'string') { this.openExternal(message.url); }
    } else if (op === 'focus') {
      try { this.getUIContext().getFocusController().requestFocus('term-input'); } catch (error) { /* 未挂载 */ }
    }
  }

  private hookWindowOpen(): void {
    const script = '(function(){if(window.__dshOpenHooked)return;window.__dshOpenHooked=true;' +
      'var report=function(v){try{if(v&&v!=="about:blank")console.log("DSH_OPEN:"+v)}catch(e){}};try{console.log("DSH_HOOK:"+typeof window.open+":"+String(window.open).slice(0,60))}catch(e){};' +
      'var __open=function(u){var w={closed:false,focus:function(){},close:function(){}};report(u);' +
      'var loc={assign:function(v){report(v);window.location.href=v},replace:function(v){report(v);window.location.href=v}};' +
      'Object.defineProperty(loc,"href",{get:function(){return u||""},set:function(v){report(v)}});' +
      'Object.defineProperty(w,"location",{get:function(){return loc},set:function(v){report(v)}});' +
      'return w;};try{Object.defineProperty(window,"open",{configurable:true,writable:true,value:__open});}catch(e){window.open=__open;}})();';
    this.controller.runJavaScript(script).then(() => { hilog.info(0, 'DSH-WEB', 'window hook installed'); }).catch((error: Error) => { hilog.warn(0, 'DSH-WEB', 'window hook failed %{public}s', error.message); });
  }

  private bridgeScript(): string {
    return 'window.__dshNonce=' + JSON.stringify(this.nonce) + ';' +
      'window.open=function(u){var w={closed:false,focus:function(){},close:function(){}};' +
      'var report=function(v){try{if(v)console.log("DSH_OPEN:"+v)}catch(e){}};' +
      'if(u&&u!=="about:blank")report(u);' +
      'w.location={assign:function(v){report(v)},replace:function(v){report(v)}};' +
      'Object.defineProperty(w.location,"href",{get:function(){return u||""},set:function(v){report(v)}});' +
      'try{Object.defineProperty(w,"location",{get:function(){return w.location},set:function(v){report(v)}})}catch(e){};' +
      'return w};' +
      'document.addEventListener("click",function(e){try{var a=e.target&&e.target.closest?e.target.closest("a"):null;if(a&&a.target==="_blank"&&a.href){console.log("DSH_OPEN:"+a.href);e.preventDefault();}}catch(x){}},true);' +
      '(function(){' +
      'var s=document.createElement("style");s.textContent="[class*=yHnPSG_root],[class*=yHnPSG_trigger]{display:none!important}";' +
      '(document.head||document.documentElement).appendChild(s);' +
      'var labels=["打开配置文件","插件","插件管理","意见反馈","账号与余额","查询用量","充值","更多账号信息","实验性插件","开发者工具","Codex子智能","Claude Codex子智能"];' +
      'var last=0;function hide(){var now=Date.now();if(now-last<120)return;last=now;' +
      'var ns=document.querySelectorAll("button,a,[role=button]");for(var i=0;i<ns.length;i++){var el=ns[i];var t=((el.getAttribute("aria-label")||"")+" "+(el.textContent||"")).trim();' +
      'for(var j=0;j<labels.length;j++){if(t.indexOf(labels[j])>=0){el.style.setProperty("display","none","important");break;}}}}' +
      'try{hide();new MutationObserver(function(){requestAnimationFrame(hide)}).observe(document.documentElement,{subtree:true,childList:true,characterData:true});}catch(x){}' +
      '})();' +
      '(function(){var sx=0,sy=0,st=0,active=false;' +
      'document.addEventListener("touchstart",function(e){if(e.touches.length!==1){active=false;return;}var t=e.touches[0];sx=t.clientX;sy=t.clientY;st=Date.now();active=true;},true);' +
      'document.addEventListener("touchend",function(e){if(!active){return;}active=false;var t=e.changedTouches&&e.changedTouches[0];if(!t){return;}var dx=t.clientX-sx,dy=t.clientY-sy;if(Date.now()-st>700){return;}if(Math.abs(dx)<80||Math.abs(dx)<Math.abs(dy)*1.6){return;}if(document.body.innerText.indexOf("打开配置文件")>=0&&sy<window.innerHeight*0.2){return;}try{console.log("DSH_SWIPE:"+(dx>0?"left":"right"));}catch(x){}},true);})();'
  }

  private onWebSwipe(direction: string): void {
    const script = '(() => {' +
      'const dir=' + JSON.stringify(direction) + ';' +
      'try {' +
      '  const inView = n => {' +
      '    const r = n.getBoundingClientRect();' +
      '    return r.width > 0 && r.height > 0 && r.left >= -1 && r.top >= -1 &&' +
      '      r.right <= window.innerWidth + 1 && r.bottom <= window.innerHeight + 1;' +
      '  };' +
      '  const nodes = Array.from(document.querySelectorAll("button,[role=button]")).filter(inView);' +
      '  const label = n => ((n.getAttribute("aria-label") || "") + " " + (n.textContent || "")).trim();' +
      '  const pick = k => nodes.find(n => label(n).includes(k));' +
      '  const body = document.body.innerText || "";' +
      '  const click = k => { const n = pick(k); if (n) { n.click(); return true; } return false; };' +
      // 设置页
      '  const hasSettings = Array.from(document.querySelectorAll("button,[role=button]")).some(n => label(n).indexOf("打开配置文件") >= 0);' +
      '  if (hasSettings) {' +
      '    if (click("关闭")) return "close-settings";' +
      '    return "settings-no-close";' +
      '  }' +
      // 图2 左侧栏
      '  if (pick("收起侧边栏")) {' +
      '    if (click("收起侧边栏")) return "close-left";' +
      '    return "left-no-close";' +
      '  }' +
      // 图3 右侧栏
      '  if (pick("收起右侧边栏") || pick("退出全屏")) {' +
      '    if (click("收起右侧边栏")) return "close-right";' +
      '    if (click("退出全屏")) return "close-right-fullscreen";' +
      '    return "right-no-close";' +
      '  }' +
      // 图1 首页
      '  const openLeft = pick("打开侧边栏");' +
      '  const openRight = pick("打开右侧边栏");' +
      '  if (openLeft && openRight) {' +
      '    if (dir === "right") { openRight.click(); return "right-sidebar"; }' +
      '    openLeft.click(); return "left-sidebar";' +
      '  }' +
      '  return "none";' +
      '} catch (e) { return "error:" + String(e); }' +
      '})()';
    this.controller.runJavaScript(script).then((result: string) => {
      hilog.info(0, 'DSH-WEB', 'swipe %{public}s -> %{public}s', direction, result);
    }).catch(() => {
    });
  }

  onBackPress(): boolean {
    // 先关闭右侧原生终端，再把返回手势交给 DSH Web 的历史栈。
    if (this.termShown) {
      this.termShown = false;
      this.termVisible = false;
      return true;
    }
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        hilog.info(0, 'DSH-WEB', 'back: web history backward');
        return true;
      }
    } catch (error) {
      hilog.warn(0, 'DSH-WEB', 'back: accessBackward failed');
    }
    // DSH 是 SPA，设置/侧栏等浮层不会进入浏览器 history。
    // 没有 history 时优先让页面关闭浮层（关闭按钮/Escape），并吞掉返回手势，避免直接退出应用。
    const script = '(() => {' +
      'try {' +
      '  const nodes = Array.from(document.querySelectorAll("button,[role=button]")).filter(n => n.getClientRects().length > 0);' +
      '  const textOf = n => ((n.getAttribute("aria-label") || "") + " " + (n.textContent || "")).trim();' +
      '  const home = (document.body.innerText || "").includes("探索未至之境");' +
      '  if (home) {' +
      '    const openLeft = nodes.find(n => textOf(n).includes("打开侧边栏"));' +
      '    if (openLeft) { openLeft.click(); return "left-sidebar"; }' +
      '  }' +
      '  const priorities = ["关闭右侧边栏", "收起右侧边栏", "关闭", "Close", "退出全屏", "收起", "返回", "Back"];' +
      '  for (const key of priorities) {' +
      '    const hit = nodes.find(n => textOf(n).includes(key));' +
      '    if (hit) { hit.click(); return "close:" + key; }' +
      '  }' +
      '  const esc = new KeyboardEvent("keydown", { key: "Escape", code: "Escape", bubbles: true, cancelable: true });' +
      '  document.dispatchEvent(esc); window.dispatchEvent(esc); return "escape";' +
      '} catch (e) { return "none"; }' +
      '})()';
    this.controller.runJavaScript(script).then((result: string) => {
      hilog.info(0, 'DSH-WEB', 'back overlay result %{public}s', result);
    }).catch(() => {
      hilog.warn(0, 'DSH-WEB', 'back overlay script failed');
    });
    hilog.info(0, 'DSH-WEB', 'back: handled by overlay fallback');
    return true;
  }

  @Builder
  private splash() {
    Column({ space: 14 }) {
      Image($r('app.media.app_logo')).width(88).height(88).borderRadius(0)
      Text('DSH HOS').fontSize(28).fontWeight(FontWeight.Medium).fontColor(this.dark ? '#DCEDE0' : '#1F3D2E')
      Text('DeepSeek Harness · 鸿蒙原生').fontSize(13).fontColor(this.dark ? '#8FA396' : '#6B8474')
      Text(this.status).fontSize(14).fontColor(this.dark ? '#DCEDE0' : '#1F3D2E').margin({ top: 10 })
      if (this.failed === '') {
        LoadingProgress().width(34).height(34).color(this.dark ? '#9BE28F' : '#2E6B50')
      } else {
        Text(this.failed).fontSize(12).fontColor('#C05A5A').maxLines(4).textAlign(TextAlign.Center).padding({ left: 28, right: 28 })
        Button('重试').onClick(() => { this.start(); })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.bg)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.url !== '') {
        Column() {
          Web({ src: this.url, controller: this.controller })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .databaseAccess(false)
            .fileAccess(false)
            .imageAccess(true)
            .onlineImageAccess(true)
            .zoomAccess(false)
            .darkMode(WebDarkMode.Auto)
            .forceDarkAccess(false)
            .width('100%')
            .height('100%')
            .backgroundColor(this.bg)
            .javaScriptOnDocumentStart([{ script: this.bridgeScript(), scriptRules: [this.localOrigin() === '' ? '*' : this.localOrigin()] }])
            .onConsole((event: OnConsoleEvent) => {
              const message = event.message.getMessage();
              hilog.info(0, 'DSH-CONSOLE', '%{public}s', message.length > 220 ? message.slice(0, 220) : message);
              if (message.indexOf('DSH_OPEN:') === 0) {
                hilog.info(0, 'DSH-WEB', 'open external %{public}s', message.slice(8));
                this.openExternal(message.slice(8));
                return true;
              }
              if (message.indexOf('DSH_SWIPE:') === 0) {
                this.onWebSwipe(message.slice(10));
                return true;
              }
              try { this.onBridge(message); } catch (error) { /* 非桥消息 */ }
              return false;
            })
            .multiWindowAccess(true)
            .onWindowNew((event: OnWindowNewEvent) => {
              hilog.info(0, 'DSH-WEB', 'window new %{public}s', event.targetUrl);
              if (event.targetUrl !== '') { this.openExternal(event.targetUrl); }
              event.handler.setWebController(null);
            })
            .onLoadIntercept((event: OnLoadInterceptEvent) => {
              try {
                const request = event.data;
                if (!request.isMainFrame()) { return false; }
                const target = request.getRequestUrl();
                hilog.info(0, 'DSH-WEB', 'load %{public}s', target);
                if (target === '') { return true; }
                let protocol = '';
                try { protocol = new url.URL(target).protocol; } catch (error) { return true; }
                if (protocol !== 'http:' && protocol !== 'https:') { return true; }
                if (this.isLocal(target)) { return false; }
                this.openExternal(target);
                return true;
              } catch (error) { return true; }
            })
            .onPageEnd(() => {
              hilog.info(0, 'DSH-WEB', 'page end');
              this.hookWindowOpen();
              this.ready = true;
              this.status = '';
            })
            .onErrorReceive((event: OnErrorReceiveEvent) => {
              if (event && event.error && event.error.getErrorInfo()) { this.failed = event.error.getErrorInfo(); }
            })
          if (!this.ready) {
            Row({ space: 8 }) {
              LoadingProgress().width(20).height(20).color('#2E6B50')
              Text(this.status).fontSize(12).fontColor('#6B8474')
            }
            .padding({ top: 6, bottom: 6 })
          }
        }
        .width('100%')
        .height('100%')
      }
      if (this.url === '' || !this.ready) { this.splash() }

      if (this.termShown && this.termWidth > 0 && this.termHeight > 0) {
        TerminalView({
          runtime: this.runtime,
          stageLeft: this.termLeft,
          stageTop: this.termTop,
          stageWidth: this.termWidth,
          stageHeight: this.termHeight,
          visible: this.termVisible,
          workspaceCwd: this.termCwd,
          onClose: () => { this.termShown = false; this.termVisible = false; this.termOwner = ''; }
        })
      }



    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.bg)
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.KEYBOARD], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

  }
}

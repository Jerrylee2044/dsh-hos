import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { window } from '@kit.ArkUI';
import { KeyboardAvoidMode as UIKeyboardAvoidMode } from '@ohos.arkui.UIContext';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { spawn as spawnHost, poll as pollHost, write as writeHost, terminate as terminateHost, release as releaseHost, HostChunk } from 'host';

interface TerminalHost {
  ensure(): Promise<void>;
  readonly rootDir: string;
  readonly environment: Record<string, string>;
  workspaceDirectory(): string;
  nativeLibrary(name: string): string;
}

const FONT_SIZE = 13;
const BG = '#101113';
const FG = '#D8DEE9';
const MAX_TEXT = 120000;

/** 自研 host 托管的 bash 会话（pipe 模式）。 */
class HostShell {
  private id: number = -1;
  private timer: number = -1;
  private closed: boolean = false;
  private encoder = new util.TextEncoder();
  private onText: (text: string) => void;
  private onExit: (code: number) => void;

  constructor(library: string, command: string, cwd: string, env: Record<string, string>,
    onText: (text: string) => void, onExit: (code: number) => void) {
    this.onText = onText;
    this.onExit = onExit;
    const envList: string[] = [];
    for (const key of Object.keys(env)) { envList.push(key + '=' + env[key]); }
    this.id = spawnHost({
      library: library, entry: 'dsh_bash_main',
      argv: [command, '--noprofile', '--norc', '-i'], env: envList, cwd: cwd
    });
    this.timer = setInterval(() => this.tick(), 30);
  }

  private tick(): void {
    if (this.closed) { return; }
    try {
      const chunk: HostChunk = pollHost(this.id);
      if (chunk.out.length > 0) { this.onText(chunk.out); }
      if (chunk.err.length > 0) { this.onText(chunk.err); }
      if (!chunk.running && chunk.outEof && chunk.errEof) {
        this.closed = true;
        clearInterval(this.timer);
        releaseHost(this.id);
        this.onExit(chunk.code);
      }
    } catch (error) {
      this.closed = true;
      clearInterval(this.timer);
      this.onExit(-1);
    }
  }

  write(text: string): void {
    if (!this.closed && text.length > 0) { writeHost(this.id, text); }
  }

  close(): void {
    if (this.closed) { return; }
    this.closed = true;
    clearInterval(this.timer);
    try { terminateHost(this.id); } catch (error) { /* 已退出 */ }
  }
}

/**
 * 自研终端视图（阶段 B）。
 *
 * 不再依赖 libdsh_terminal.so：输出经 ANSI 清理后以滚动文本显示；
 * 输入通过自研 host 写入 bash。pipe 模式没有 job control，但对
 * DSH 的常用 shell 场景足够，且完全由 ArkTS 实现。
 */
@Component
export struct TerminalView {
  runtime?: TerminalHost;
  onClose: () => void = () => {};
  @Prop stageLeft: number = 0;
  @Prop stageTop: number = 0;
  @Prop stageWidth: number = 0;
  @Prop stageHeight: number = 0;
  @Prop visible: boolean = true;
  @Prop @Watch('onCwdChanged') workspaceCwd: string = '';
  @State private statusText: string = '正在启动终端';
  @State private output: string = '';
  @State private inputText: string = '';
  @State private keyboardHeight: number = 0;
  @State private ready: boolean = false;
  private session?: HostShell;
  private pending: string = '';
  private flushTimer: number = -1;
  private active: boolean = false;
  private cwdApplied: string = '';
  private context?: common.UIAbilityContext;
  private win?: window.Window;
  private previousKeyboardMode: UIKeyboardAvoidMode = UIKeyboardAvoidMode.OFFSET;
  private decoder = util.TextDecoder.create('utf-8');
  private keyboardChanged = (height: number): void => {
    this.keyboardHeight = this.getUIContext().px2vp(height);
  };

  aboutToAppear(): void {
    this.active = true;
    try { this.context = this.getUIContext().getHostContext() as common.UIAbilityContext; } catch (error) { /* 无上下文 */ }
    this.previousKeyboardMode = this.getUIContext().getKeyboardAvoidMode();
    this.getUIContext().setKeyboardAvoidMode(UIKeyboardAvoidMode.NONE);
    const context = this.context;
    if (context) {
      window.getLastWindow(context).then((win: window.Window) => {
        if (!this.active) { return; }
        this.win = win;
        win.on('keyboardHeightChange', this.keyboardChanged);
      }).catch(() => {});
    }
    this.flushTimer = setInterval(() => this.flush(), 80);
    this.start();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.win?.off('keyboardHeightChange', this.keyboardChanged);
    this.getUIContext().setKeyboardAvoidMode(this.previousKeyboardMode);
    if (this.flushTimer >= 0) { clearInterval(this.flushTimer); this.flushTimer = -1; }
    this.session?.close();
  }

  private async start(): Promise<void> {
    const runtime = this.runtime;
    if (!runtime || !this.context) { this.statusText = '运行时未就绪'; return; }
    try {
      await runtime.ensure();
      if (!this.active) { return; }
      const root = runtime.rootDir;
      const env = runtime.environment;
      env['TERM'] = 'dumb';
      env['SHELL'] = root + '/bin/bash';
      const cwd = this.workspaceCwd !== '' ? this.workspaceCwd : runtime.workspaceDirectory();
      env['PWD'] = cwd;
      this.cwdApplied = cwd;
      this.session = new HostShell(runtime.nativeLibrary('libbash.so'), root + '/bin/bash', cwd, env,
        (text: string) => this.feed(text),
        (code: number) => { this.statusText = 'shell exited (' + code.toString() + ')'; });
      this.ready = true;
      this.statusText = '';
    } catch (error) {
      this.statusText = '终端启动失败：' + (error as Error).message;
      hilog.warn(0, 'DSH-TERM', 'start failed: %{public}s', (error as Error).message);
    }
  }

  onCwdChanged(): void {
    if (!this.session || this.workspaceCwd === '' || this.workspaceCwd === this.cwdApplied) { return; }
    this.cwdApplied = this.workspaceCwd;
    this.session.write("cd '" + this.workspaceCwd.replace(/'/g, "'\\''") + "'\n");
  }

  private plain(text: string): string {
    let value = text;
    // OSC: ESC ] ... BEL
    value = value.replace(/\u001b\][^\u0007]*\u0007/g, '');
    // CSI: ESC [ ... final byte
    value = value.replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, '');
    // 其它 ESC 两字节序列
    value = value.replace(/\u001b[@-_]/g, '');
    value = value.replace(/\r\n/g, '\n');
    value = value.replace(/\r/g, '\n');
    value = value.replace(/\u0000/g, '');
    return value;
  }

  private feed(text: string): void {
    this.pending += this.plain(text);
    if (this.pending.length > MAX_TEXT) { this.pending = this.pending.slice(-MAX_TEXT); }
  }

  private flush(): void {
    if (this.pending.length === 0) { return; }
    let next = this.output + this.pending;
    this.pending = '';
    if (next.length > MAX_TEXT) { next = next.slice(-MAX_TEXT); }
    this.output = next;
  }

  private send(text: string): void {
    this.session?.write(text);
  }

  private submit(): void {
    const command = this.inputText;
    this.inputText = '';
    this.pending += 'bash-5.3$ ' + command + '\n';
    this.send(command + '\n');
    this.flush();
    try { this.getUIContext().getFocusController().requestFocus('term-input'); } catch (error) { /* 未挂载 */ }
  }

  @Builder
  private termKey(label: string, sequence: string) {
    Button(label)
      .height(30)
      .fontSize(12)
      .fontColor(FG)
      .backgroundColor('#26282C')
      .onClick(() => this.send(sequence))
  }

  build() {
    Column() {
      Scroll() {
        Text(this.output.length === 0 ? this.statusText : this.output)
          .width('100%')
          .fontSize(FONT_SIZE)
          .fontFamily('monospace')
          .fontColor(FG)
          .textAlign(TextAlign.Start)
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(BG)
      .scrollable(ScrollDirection.Vertical)
      Scroll() {
        Row({ space: 6 }) {
          this.termKey('Esc', '\u001b')
          this.termKey('Tab', '\t')
          this.termKey('Ctrl-C', '\u0003')
          this.termKey('Ctrl-D', '\u0004')
          this.termKey('←', '\u001b[D')
          this.termKey('↑', '\u001b[A')
          this.termKey('↓', '\u001b[B')
          this.termKey('→', '\u001b[C')
        }.padding({ left: 8, right: 8, top: 6, bottom: 6 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .width('100%')
      .backgroundColor('#17181B')
      TextInput({ text: this.inputText, placeholder: '输入命令，回车执行' })
        .id('term-input')
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor(FG)
        .backgroundColor('#17181B')
        .enterKeyType(EnterKeyType.Send)
        .onChange((value: string) => { this.inputText = value; })
        .onSubmit(() => this.submit())
    }
    .width(this.stageWidth)
    .height(this.stageHeight)
    .position({ x: this.stageLeft, y: this.stageTop })
    .visibility(this.visible ? Visibility.Visible : Visibility.Hidden)
    .padding({ bottom: this.keyboardHeight })
    .backgroundColor(BG)
  }
}

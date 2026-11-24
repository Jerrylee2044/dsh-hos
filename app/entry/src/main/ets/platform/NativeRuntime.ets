import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import fileIO from '@ohos.fileio';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { probe as probeHost, spawn as spawnHost, poll as pollHost, write as writeHost, terminate as terminateHost, release as releaseHost, unpack as unpackHost, symlink as symlinkHost, HostChunk } from 'host';


interface RuntimeCommand {
  name: string;
  library: string;
  entry: string;
  arity?: number;
}

interface RuntimeManifest {
  version: string;
  engineVersion: string;
  nodeVersion: string;
  commands: RuntimeCommand[];
}

/** 由自研 libdsh_host.so 托管的 Node 进程，不经过旧 IEC 运行时。 */
class HostNodeProcess {
  private id: number = -1;
  private timer: number = -1;
  private closed: boolean = false;
  private onText: (text: string) => void;
  private onExit: (code: number, error: string) => void;

  constructor(library: string, argv: string[], env: Record<string, string>, cwd: string,
    onText: (text: string) => void, onExit: (code: number, error: string) => void) {
    this.onText = onText;
    this.onExit = onExit;
    const envList: string[] = [];
    for (const key of Object.keys(env)) { envList.push(key + '=' + env[key]); }
    this.id = spawnHost({ library: library, entry: 'dsh_node_main', argv: argv, env: envList, cwd: cwd });
    this.timer = setInterval(() => this.tick(), 30);
  }

  private tick(): void {
    if (this.closed) { return; }
    try {
      const chunk: HostChunk = pollHost(this.id);
      if (chunk.out.length > 0) { hilog.info(0, 'DSH-NODE', 'out=%{public}s', chunk.out.slice(-800)); this.onText(chunk.out); }
      if (chunk.err.length > 0) { hilog.warn(0, 'DSH-NODE', 'err=%{public}s', chunk.err.slice(-2000)); this.onText(chunk.err); }
      if (!chunk.running && chunk.outEof && chunk.errEof) {
        this.closed = true;
        clearInterval(this.timer);
        releaseHost(this.id);
        this.onExit(chunk.code, '');
      }
    } catch (error) {
      this.closed = true;
      clearInterval(this.timer);
      this.onExit(-1, (error as Error).message);
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
 * DSH HOS 自研运行时宿主（阶段 A）。
 *
 * 只负责：定位/安装 DSH 引擎运行时、写启动器、准备插件、启动 Node Web 进程。
 * 不包含旧 IEC 运行时的 RPC、终端、自动审查等业务。
 */
export class NativeRuntime {
  private context: common.UIAbilityContext;
  private root: string = '';
  private libs: string = '';
  private env: Record<string, string> = {};
  private ready: boolean = false;
  private installing: boolean = false;
  private web?: HostNodeProcess;
  private webUrl: string = '';
  private manifest?: RuntimeManifest;
  engineVersion: string = '';

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  get rootDir(): string { return this.root; }
  get environment(): Record<string, string> { return this.env; }
  get isInstalling(): boolean { return this.installing; }

  private ensureDir(path: string): void {
    if (!fs.accessSync(path)) { fs.mkdirSync(path, true); }
  }

  private removeTree(path: string): void {
    if (!fs.accessSync(path)) { return; }
    if (!fs.lstatSync(path).isDirectory()) { fs.unlinkSync(path); return; }
    for (const name of fs.listFileSync(path)) { this.removeTree(path + '/' + name); }
    fs.rmdirSync(path);
  }

  private writeText(path: string, text: string): void {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, text); } finally { fs.closeSync(file); }
  }

  private copyRawfile(source: string, target: string): void {
    const bytes = this.context.resourceManager.getRawFileContentSync(source);
    this.ensureDir(target.substring(0, target.lastIndexOf('/')));
    const file = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    } finally { fs.closeSync(file); }
  }

  private nativeLibraryDirectory(): string {
    const reported = this.context.applicationInfo.nativeLibraryPath;
    const candidates: string[] = [];
    if (reported) { candidates.push(reported.endsWith('/') ? reported : reported + '/'); }
    candidates.push('/data/storage/el1/bundle/libs/arm64/');
    candidates.push('/data/storage/el1/bundle/libs/x86_64/');
    for (const candidate of candidates) {
      try { if (fs.accessSync(candidate + 'libnode.so')) { return candidate; } } catch (error) { /* next */ }
    }
    throw new Error('未找到 libnode.so');
  }

  private async unpackRaw(name: string, destination: string): Promise<void> {
    const archive = this.context.cacheDir + '/dsh-unpack.tar.gz';
    const bytes = this.context.resourceManager.getRawFileContentSync(name);
    const file = fs.openSync(archive, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    } finally { fs.closeSync(file); }
    try {
      const code = unpackHost(archive, destination);
      if (code !== 0) { throw new Error('解包失败（' + code.toString() + '）：' + name); }
    } finally {
      try { fs.unlinkSync(archive); } catch (error) { /* 已删除 */ }
    }
  }

  private async installEngine(): Promise<void> {
    this.ensureDir(this.root);
    this.ensureDir(this.root + '/bin');
    this.ensureDir(this.root + '/engine');
    await this.unpackRaw('tools/official-engine.tar.gz', this.root + '/engine');
    this.copyRawfile('tools/require-builtin-shim.js', this.root + '/engine/node_modules/node-addon-require-builtin/lib/index.js');
    this.copyRawfile('tools/flock-shim.js', this.root + '/engine/node_modules/@deepseek-ai/node-addon-system/lib/flock.js');
    await this.unpackRaw('tools/npm.tar.gz', this.root);
    await this.unpackRaw('tools/python-stdlib.tar', this.root);
    this.ensureDir(this.root + '/vim');
    await this.unpackRaw('tools/vim-runtime.tar.gz', this.root + '/vim');
    this.ensureDir(this.root + '/git-templates/hooks');
    this.ensureDir(this.root + '/git-templates/info');
    this.ensureDir(this.root + '/git-templates/branches');
  }

  private async ensureQemuRoot(): Promise<void> {
    const dest = this.context.filesDir + '/qemu-root';
    const marker = dest + '/.dsh-rootfs-v3';
    try { if (fs.accessSync(marker)) { return; } } catch (error) { /* 未安装或需升级 */ }
    this.removeTree(dest);
    await this.unpackRaw('qemu/rootfs.tar.gz', dest);
    try { const f = fs.openSync(marker, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC); fs.writeSync(f.fd, '3'); fs.closeSync(f); } catch (error) { /* 标记失败 */ }
  }

  private writeLaunchers(): void {
    // 自研 host 直接 dlopen .so，不再需要 IECSO 启动器；只保留 argv0 路径。
    const bash = this.root + '/bin/bash';
    try { fs.unlinkSync(bash); } catch (error) { /* 不存在 */ }
    let linked = false;
    try { linked = symlinkHost('/system/bin/sh', bash); } catch (error) { linked = false; }
    if (!linked) {
      try {
        fs.copyFileSync('/system/bin/sh', bash);
        fileIO.chmodSync(bash, 0o755);
      } catch (error) { /* 保留空 */ }
    }
    const node = this.root + '/bin/node';
    if (!fs.accessSync(node)) { this.writeText(node, ''); }
  }

  private installToolLaunchers(): void {
    const rc = this.root + '/harmony/dsh-tools.sh';
    this.ensureDir(this.root + '/harmony');
    let text = '__dsh_tool() {\n' +
      '  local cmd="$1"; shift\n' +
      '  local port="${DSH_TOOL_PORT:-47654}"\n' +
      '  if ! exec 3<>/dev/tcp/127.0.0.1/$port 2>/dev/null; then\n' +
      '    echo "dsh-tool: server unavailable" >&2; return 127;\n' +
      '  fi\n' +
      '  { printf "%s\\n" "$PWD" "$cmd" "DSH_ENV=PYTHONHOME=$IEC_SYSROOT/python" "DSH_ENV=PYTHONPATH=$IEC_SYSROOT/python/lib/python3.12"; for arg in "$@"; do printf "%s\\n" "$arg"; done; printf "\\n"; } >&3\n' +
      '  IFS= read -r status <&3\n' +
      '  IFS= read -r len <&3\n' +
      '  if [ -n "$len" ] && [ "$len" -gt 0 ]; then\n' +
      '    IFS= read -r -N "$len" out <&3; printf "%s" "$out";\n' +
      '  fi\n' +
      '  exec 3>&-\n' +
      '  return ${status:-1}\n' +
      '}\n';
    text += '__dsh_interactive() {\n' +
      '  local cmd="$1"; shift\n' +
      '  local port="${DSH_TOOL_PORT:-47654}"\n' +
      '  if ! exec 3<>/dev/tcp/127.0.0.1/$port 2>/dev/null; then\n' +
      '    echo "dsh-tool: server unavailable" >&2; return 127;\n' +
      '  fi\n' +
      '  { printf "%s\\nINTERACTIVE\\n%s\\n" "$PWD" "$cmd"; printf "DSH_ENV=PYTHONHOME=%s\\n" "$IEC_SYSROOT/python"; printf "DSH_ENV=PYTHONPATH=%s\\n" "$IEC_SYSROOT/python/lib/python3.12"; for arg in "$@"; do printf "%s\\n" "$arg"; done; printf "\\n"; } >&3\n' +
      '  local catpid inpid\n' +
      '  cat <&3 &\n' +
      '  catpid=$!\n' +
      '  while :; do\n' +
      '    if IFS= read -r -t 0.2 line; then\n' +
      '      printf "%s\\n" "$line" >&3\n' +
      '      if [ "$line" = "exit()" ]; then break; fi\n' +
      '    fi\n' +
      '  done\n' +
      '  kill "$catpid" 2>/dev/null\n' +
      '  exec 3>&-\n' +
      '}\n';
    const tools = ['git', 'gh', 'python', 'python3', 'pip', 'node', 'rg', 'tar', 'cpio', 'unzip', 'zip',
      'diff', 'curl', 'jq', 'bc', 'less', 'nc', 'ssh', 'scp', 'sftp', 'openssl', 'tree', 'sqlite3',
      'rsync', 'xz', 'zstd', 'hexdump', 'vim', 'toybox', 'qemu'];
    for (const name of tools) {
      if (name === 'python' || name === 'python3') {
        text += name + '() { if [ "$#" -eq 0 ]; then __dsh_interactive ' + name + ' -i -u; else __dsh_tool ' + name + ' "$@"; fi; }\n';
      } else {
        text += name + '() { __dsh_tool ' + name + ' "$@"; }\n';
      }
    }
    text += 'npm() { __dsh_tool node "$IEC_SYSROOT/npm/bin/npm-cli.js" "$@"; }\n';
    text += 'npx() { __dsh_tool node "$IEC_SYSROOT/npm/bin/npx-cli.js" "$@"; }\n';
    text += 'qemu-bash() { __dsh_tool qemu -L "$IEC_SYSROOT/qemu-root" "$IEC_SYSROOT/qemu-tools/bash" "$@"; }\n';
    text += 'qemu-git() { __dsh_tool qemu -L "$IEC_SYSROOT/qemu-root" "$IEC_SYSROOT/qemu-tools/git" "$@"; }\n';
    text += 'qemu-run() { __dsh_tool qemu -L "$IEC_SYSROOT/qemu-root" "$@"; }\n';
    text += 'apk-real() { qemu-run "$IEC_SYSROOT/qemu-root/sbin/apk" "$@"; }\n';
    text += 'apk() { __dsh_tool node "$IEC_SYSROOT/tools/apk-install.mjs" "$@"; }\n';
    text += 'apk() { qemu-run "$IEC_SYSROOT/qemu-root/sbin/apk" "$@"; }\n';
    text += 'command_not_found_handle() {\n' +
      '  case "$1" in\n' +
      '    git-remote-http|git-remote-https|git-lfs) __dsh_tool "$1" "${@:2}";;\n' +
      '    *) echo "$1: command not found" >&2; return 127;;\n' +
      '  esac\n' +
      '}\n';
    this.writeText(rc, text);
  }

  private installPreloads(): void {
    this.ensureDir(this.root + '/harmony');
    for (const name of ['runtime-preload.cjs', 'fetch-polyfill.cjs', 'openssl.cnf']) {
      this.copyRawfile('harmony/' + name, this.root + '/harmony/' + name);
    }
    this.ensureDir(this.root + '/certs');
    this.copyRawfile('harmony/cacert.pem', this.root + '/certs/cacert.pem');
  }

  private installPlugin(name: string, rawDir: string): void {
    hilog.info(0, 'DSH-RT', 'plugin start %{public}s', name);
    const profile = this.context.filesDir + '/harness-home/profiles/web';
    const dest = profile + '/node_modules/' + name;
    hilog.info(0, 'DSH-RT', 'plugin dest %{public}s', dest);
    this.removeTree(dest);
    this.ensureDir(dest + '/lib');
    hilog.info(0, 'DSH-RT', 'plugin dir ok');
    const files = name.indexOf('terminal') >= 0
      ? ['package.json', 'index.js', 'client.js', 'cordis.patch.yml']
      : ['package.json', 'lib/index.js', 'lib/client.js', 'cordis.patch.yml'];
    for (const file of files) {
      hilog.info(0, 'DSH-RT', 'plugin file %{public}s', file);
      this.copyRawfile(rawDir + '/' + file, dest + '/' + file);
    }
    hilog.info(0, 'DSH-RT', 'plugin copied');
    hilog.info(0, 'DSH-RT', 'plugin patch');
    const patchFile = profile + '/cordis.patch.yml';
    const marker = name;
    let text = '';
    try { text = fs.accessSync(patchFile) ? fs.readTextSync(patchFile) : ''; } catch (error) { text = ''; }
    if (text.trim() === '[]') { text = ''; }
    if (text.indexOf(marker) < 0) {
      if (text.length > 0 && !text.endsWith('\n')) { text += '\n'; }
      text += "- insert:\n    - id: " + (name.indexOf('terminal') >= 0 ? 'harmony-native-terminal' : 'harmony-native') +
        "\n      name: '" + name + "'\n";
      this.writeText(patchFile, text);
    }
  }

  private installNotices(): void {
    const dest = this.context.filesDir + '/notices';
    this.ensureDir(dest);
    this.ensureDir(dest + '/LICENSES');
    const files: string[] = [
      'THIRD_PARTY_NOTICES.md',
      'LICENSES/Apache-2.0-LLVM.txt',
      'LICENSES/Apache-2.0-OpenSSL.txt',
      'LICENSES/Artistic-2.0.txt',
      'LICENSES/DSH-MIT.txt',
      'LICENSES/GPL-2.0.txt',
      'LICENSES/GPL-3.0.txt',
      'LICENSES/Go-BSD.txt',
      'LICENSES/Node-MIT.txt',
      'LICENSES/Python-PSF.txt',
      'LICENSES/bzip2.txt',
      'LICENSES/curl.txt',
      'LICENSES/dropbear.txt',
      'LICENSES/gh.txt',
      'LICENSES/git-lfs.txt',
      'LICENSES/jq.txt',
      'LICENSES/less.txt',
      'LICENSES/libarchive.txt',
      'LICENSES/libtomcrypt.txt',
      'LICENSES/libtommath.txt',
      'LICENSES/libvterm.txt',
      'LICENSES/ncurses.txt',
      'LICENSES/oniguruma.txt',
      'LICENSES/openssh.txt',
      'LICENSES/pcre2.txt',
      'LICENSES/pip.txt',
      'LICENSES/popt.txt',
      'LICENSES/ripgrep-MIT.txt',
      'LICENSES/ripgrep-UNLICENSE.txt',
      'LICENSES/rsync.txt',
      'LICENSES/setuptools.txt',
      'LICENSES/sqlite.txt',
      'LICENSES/toybox.txt',
      'LICENSES/tree.txt',
      'LICENSES/vim.txt',
      'LICENSES/wheel.txt',
      'LICENSES/xz.txt',
      'LICENSES/zlib.txt',
      'LICENSES/zstd.txt'
    ];
    for (const name of files) {
      try { this.copyRawfile('notices/' + name, dest + '/' + name); } catch (error) { /* 缺文件不阻断 */ }
    }
  }

  private buildEnv(): Record<string, string> {
    const home = this.context.filesDir + '/home';
    const temp = this.context.filesDir + '/tmp';
    const ca = this.root + '/certs/cacert.pem';
    return {
      'PATH': this.root + '/bin:/system/bin:/system/xbin',
      'DSH_LIBS': this.libs,
      'DSH_RC': this.root + '/harmony/dsh-tools.sh',
      'DSH_TOOL_PORT': '47654',
      'HOME': home,
      'TMPDIR': temp,
      'SHELL': '/system/bin/sh',
      'TERM': 'dumb',
      'LANG': 'C.UTF-8',
      'LC_ALL': 'C.UTF-8',
      'IEC_SYSROOT': this.root,
      'IEC_NODE_JITLESS': 'on',
      'UV_USE_IO_URING': '0',
      'LD_LIBRARY_PATH': this.libs + ':' + this.context.filesDir + '/tmp',
      'NARB_DISABLE_NATIVE_CACHE': '1',
      'NODE_EXTRA_CA_CERTS': ca,
      'SSL_CERT_FILE': ca,
      'GIT_SSL_CAINFO': ca,
      'CURL_CA_BUNDLE': ca,
      'GIT_EXEC_PATH': this.root + '/bin',
      'GIT_TEMPLATE_DIR': this.root + '/git-templates',
      'PYTHONHOME': this.root + '/python',
      'VIMRUNTIME': this.root + '/vim/runtime',
      'OPENSSL_CONF': this.root + '/harmony/openssl.cnf',
      'DSH_HOME': this.context.filesDir + '/harness-home',
      'DSH_TELEMETRY_DISABLED': '1',
      'NODE_OPTIONS': '--require ' + this.root + '/harmony/runtime-preload.cjs' +
        ' --require ' + this.root + '/harmony/fetch-polyfill.cjs'
    };
  }

  async ensure(onInstalling?: (active: boolean) => void): Promise<void> {
    if (this.ready) { return; }
    const manifest = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(
      this.context.resourceManager.getRawFileContentSync('tools/runtime-manifest.json'))) as RuntimeManifest;
    this.manifest = manifest;
    try { const host = probeHost(); hilog.info(0, 'DSH-RT', 'host api=%{public}d abi=%{public}d', host.api, host.abi); } catch (error) { hilog.warn(0, 'DSH-RT', 'host probe failed'); }
    hilog.info(0, 'DSH-RT', 'manifest %{public}s', manifest.version);
    this.root = this.context.filesDir + '/runtime-' + manifest.version;
    this.libs = this.nativeLibraryDirectory();
    hilog.info(0, 'DSH-RT', 'libs ok');
    for (const command of manifest.commands) {
      if (!fs.accessSync(this.libs + command.library)) { throw new Error('缺少 ' + command.name + ' 原生库'); }
    }
    this.ensureDir(this.context.filesDir + '/harness-home');
    this.ensureDir(this.context.filesDir + '/home');
    this.ensureDir(this.context.filesDir + '/tmp');
    try { const src = this.libs + 'libc++_shared.so'; const dst = this.context.filesDir + '/tmp/libc++_shared.so'; if (!fs.accessSync(dst)) { fs.copyFileSync(src, dst); } } catch (error) { /* 可选 */ }
    const complete = fs.accessSync(this.root + '/bin/node') &&
      fs.accessSync(this.root + '/engine/node_modules/@deepseek-ai/dsh/lib/bin.js');
    this.installing = !complete;
    hilog.info(0, 'DSH-RT', 'complete=%{public}s', complete.toString());
    if (!complete) {
      if (onInstalling) { onInstalling(true); await new Promise<void>((resolve) => setTimeout(resolve, 300)); }
      this.removeTree(this.root);
      await this.installEngine();
    }
    try {
      this.copyRawfile('tools/require-builtin-shim.js', this.root + '/engine/node_modules/node-addon-require-builtin/lib/index.js');
      this.copyRawfile('tools/flock-shim.js', this.root + '/engine/node_modules/@deepseek-ai/node-addon-system/lib/flock.js');
      this.copyRawfile('tools/settings-general-about.js', this.root + '/engine/node_modules/@deepseek-ai/dsh-client-ui-settings-general/lib/client.js');
      this.copyRawfile('tools/subprocess-local-patched.js', this.root + '/engine/node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js');
      this.copyRawfile('tools/sidebar-terminal-no-guide.js', this.root + '/engine/node_modules/@deepseek-ai/dsh-client-ui-sidebar-terminal/lib/client.js');
      this.ensureDir(this.root + '/tools');
      this.copyRawfile('tools/apk-install.mjs', this.root + '/tools/apk-install.mjs');
    } catch (error) {
      hilog.warn(0, 'DSH-RT', 'runtime shims unavailable');
    }
    if (false) {
    }
    this.installing = false;
    if (onInstalling) { onInstalling(false); }
    hilog.info(0, 'DSH-RT', 'launchers');
    await this.ensureQemuRoot();
    this.writeLaunchers();
    this.installToolLaunchers();
    hilog.info(0, 'DSH-RT', 'launchers ok');
    this.installPreloads();
    this.installNotices();
    hilog.info(0, 'DSH-RT', 'preloads ok');
    hilog.info(0, 'DSH-RT', 'plugins');
    this.installPlugin('@deepseek-ai/dsh-harmony-compat', 'tools/harmony-compat');
    this.installPlugin('@local/dsh-harmony-terminal', 'tools/harmony-terminal');
    hilog.info(0, 'DSH-RT', 'env');
    this.env = this.buildEnv();
    this.engineVersion = manifest.engineVersion;
    this.ready = true;
    hilog.info(0, 'DSH-RT', 'ready');
  }

  async repair(onInstalling?: (active: boolean) => void): Promise<void> {
    this.stopWebUI();
    this.ready = false;
    if (this.root !== '') { this.removeTree(this.root); }
    this.root = '';
    this.webUrl = '';
    await this.ensure(onInstalling);
  }

  async startWebUI(onLog: (text: string) => void,
    onInstalling?: (active: boolean) => void): Promise<string> {
    await this.ensure(onInstalling);
    if (this.webUrl !== '') { return this.webUrl; }
    return new Promise<string>((resolve, reject) => {
      let seen = '';
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) { return; }
        settled = true;
        this.web?.close(); this.web = undefined;
        reject(new Error('DSH Web 180 秒未就绪'));
      }, 180000);
      const binary = this.root + '/engine/node_modules/@deepseek-ai/dsh/lib/bin.js';
      hilog.info(0, 'DSH-RT', 'spawn web');
    const args = [this.root + '/bin/node', binary, '--profile', 'web', '--port', '0', '--no-open'];
    const onText = (text: string) => {
      seen = (seen + text).slice(-16000);
      onLog(text);
      const match = /dsh web: (\S+)/.exec(seen);
      if (match && !settled) {
        settled = true; clearTimeout(timer); this.webUrl = match[1]; resolve(this.webUrl);
      }
    };
    const onExit = (code: number, error: string) => {
      if (settled) { return; }
      settled = true; clearTimeout(timer);
      reject(new Error('DSH Web 已退出（' + code.toString() + '）：' + error.slice(0, 600)));
    };
    try {
      this.web = new HostNodeProcess(this.libs + 'libnode.so', args, this.env, this.context.filesDir, onText, onExit);
    } catch (hostError) {
      settled = true;
      clearTimeout(timer);
      reject(hostError);
    }
    });
  }

  stopWebUI(): void {
    this.web?.close();
    this.web = undefined;
    this.webUrl = '';
  }

  nativeLibrary(name: string): string {
    return this.libs + name;
  }

  workspaceDirectory(): string {
    const home = this.context.filesDir + '/home';
    try { if (fs.accessSync(home)) { return home; } } catch (error) { /* 未创建 */ }
    return this.context.filesDir;
  }

  readKeepAlive(): boolean {
    try {
      const file = this.context.filesDir + '/harness-home/harmony-native.json';
      if (!fs.accessSync(file)) { return false; }
      const parsed = JSON.parse(fs.readTextSync(file)) as Record<string, Object>;
      return parsed['keepAlive'] === true;
    } catch (error) { return false; }
  }
}

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

interface ProfileBundles {
  bundles?: string[];
}

interface ProfileDsh {
  profile?: ProfileBundles;
}

interface ProfileManifest {
  dependencies?: Record<string, string>;
  dsh?: ProfileDsh;
}

interface QuarantineRecord {
  time: string;
  reason: string;
  bundles: string[];
  originalBundles: string[];
  dir: string;
  failed: string[];
  autoRestored?: boolean;
}

interface QuarantineState {
  version: number;
  records: QuarantineRecord[];
}

interface QuarantineResult {
  moved: string[];
  error: string;
}

/**
 * 用户插件守门人（DSH HOS 自研壳层）。
 *
 * profile 位于 harness-home/profiles/web，跨升级保留。用户插件不兼容时，
 * 引擎可能启动失败；本类负责：
 *   - 启动标记：上次没走完时，下一次先进入安全模式；
 *   - 隔离：把第三方 bundle 移到 plugin-quarantine，并改写 profile bundles；
 *   - 恢复：把包移回并还原原始 bundles；
 *   - 体检：目录、patch、.node 架构。
 */
export class PluginGuard {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  private get home(): string { return this.context.filesDir + '/harness-home'; }
  private get profile(): string { return this.home + '/profiles/web'; }
  private get marker(): string { return this.home + '/.boot-in-progress'; }
  private get stateFile(): string { return this.home + '/plugin-quarantine.json'; }
  private get quarantineRoot(): string { return this.home + '/plugin-quarantine'; }
  private get autoMarker(): string { return this.home + '/.auto-restore-attempted'; }

  private builtin(): string[] {
    return ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app'];
  }

  private ensureDir(path: string): void {
    if (!fs.accessSync(path)) { fs.mkdirSync(path, true); }
  }

  private removeTree(path: string): void {
    if (!fs.accessSync(path)) { return; }
    if (!fs.lstatSync(path).isDirectory()) { fs.unlinkSync(path); return; }
    for (const name of fs.listFileSync(path)) { this.removeTree(path + '/' + name); }
    fs.rmdirSync(path);
  }

  private copyTree(from: string, to: string): void {
    this.ensureDir(to);
    for (const name of fs.listFileSync(from)) {
      const source = from + '/' + name;
      const target = to + '/' + name;
      if (fs.lstatSync(source).isDirectory()) { this.copyTree(source, target); }
      else { fs.copyFileSync(source, target); }
    }
  }

  private readObject(path: string): Record<string, Object> | undefined {
    try {
      if (!fs.accessSync(path)) { return undefined; }
      return JSON.parse(fs.readTextSync(path)) as Record<string, Object>;
    } catch (error) { return undefined; }
  }

  private writeText(path: string, text: string): void {
    const temporary = path + '.tmp';
    const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, text); } finally { fs.closeSync(file); }
    fs.renameSync(temporary, path);
  }

  private bundles(): string[] {
    const manifest = this.readObject(this.profile + '/package.json') as ProfileManifest | undefined;
    return manifest?.dsh?.profile?.bundles ?? [];
  }

  private writeBundles(names: string[]): void {
    const path = this.profile + '/package.json';
    const manifest = this.readObject(path) as ProfileManifest | undefined;
    if (!manifest) { throw new Error('profile package.json 无法解析'); }
    if (!manifest.dsh) { manifest.dsh = {}; }
    if (!manifest.dsh.profile) { manifest.dsh.profile = {}; }
    manifest.dsh.profile.bundles = names;
    this.writeText(path, JSON.stringify(manifest, null, 2) + '\n');
  }

  private thirdParty(): string[] {
    const builtin = this.builtin();
    return this.bundles().filter((name: string) => builtin.indexOf(name) < 0);
  }

  markBootStarted(): void {
    try { this.writeText(this.marker, Date.now().toString()); } catch (error) { /* 不阻断启动 */ }
  }

  markBootSucceeded(): void {
    try { if (fs.accessSync(this.marker)) { fs.unlinkSync(this.marker); } } catch (error) { /* 忽略 */ }
  }

  lastBootFailed(): boolean {
    try { return fs.accessSync(this.marker); } catch (error) { return false; }
  }

  private records(): QuarantineRecord[] {
    const state = this.readObject(this.stateFile);
    if (!state) { return []; }
    const list = state['records'];
    if (!Array.isArray(list)) { return []; }
    const out: QuarantineRecord[] = [];
    for (const item of list as QuarantineRecord[]) {
      if (!item || typeof item.dir !== 'string') { continue; }
      out.push({
        time: typeof item.time === 'string' ? item.time : '',
        reason: typeof item.reason === 'string' ? item.reason : '',
        bundles: Array.isArray(item.bundles) ? item.bundles : [],
        originalBundles: Array.isArray(item.originalBundles) ? item.originalBundles : [],
        dir: item.dir,
        failed: Array.isArray(item.failed) ? item.failed : [],
        autoRestored: item.autoRestored === true
      });
    }
    return out;
  }

  private saveRecords(records: QuarantineRecord[]): void {
    const state: QuarantineState = { version: 2, records: records };
    this.writeText(this.stateFile, JSON.stringify(state, null, 2) + '\n');
  }

  private segment(name: string): string {
    return name.replace(/\//g, '+');
  }

  quarantine(reason: string): QuarantineResult {
    const original = this.bundles();
    const names = this.thirdParty();
    if (names.length === 0) { return { moved: [], error: '' }; }
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const dir = this.quarantineRoot + '/' + stamp;
    try { this.ensureDir(dir); } catch (error) {
      return { moved: [], error: '创建隔离目录失败：' + (error as Error).message };
    }
    const moved: string[] = [];
    const failed: string[] = [];
    for (const name of names) {
      const from = this.profile + '/node_modules/' + name;
      if (!fs.accessSync(from)) { failed.push(name + '：目录不存在'); continue; }
      try {
        fs.renameSync(from, dir + '/' + this.segment(name));
        moved.push(name);
      } catch (error) {
        failed.push(name + '：移动失败（' + (error as Error).message + '）');
      }
    }
    if (moved.length === 0) {
      try { this.removeTree(dir); } catch (error) { /* 空目录 */ }
      return { moved: [], error: failed.join('；') };
    }
    const kept = names.filter((name: string) => moved.indexOf(name) < 0);
    try {
      this.writeBundles(this.builtin().concat(kept));
      this.saveRecords(this.records().concat([{
        time: stamp, reason: reason, bundles: moved, originalBundles: original,
        dir: dir, failed: failed
      }]));
    } catch (error) {
      try { this.writeBundles(original); } catch (restoreError) { /* 保留原始错误 */ }
      for (const name of moved) {
        try {
          fs.renameSync(dir + '/' + this.segment(name), this.profile + '/node_modules/' + name);
        } catch (rollbackError) { /* 尽力而为 */ }
      }
      return { moved: [], error: '隔离状态写入失败，已回滚：' + (error as Error).message };
    }
    return { moved: moved, error: failed.join('；') };
  }

  restoreLastQuarantine(): string {
    const records = this.records();
    if (records.length === 0) { return '没有可恢复的隔离记录'; }
    const failed: string[] = [];
    for (const record of records) {
      for (const name of record.bundles) {
        const from = record.dir + '/' + this.segment(name);
        const to = this.profile + '/node_modules/' + name;
        if (!fs.accessSync(from)) {
          if (!fs.accessSync(to)) { failed.push(name + '：隔离目录中缺失'); }
          continue;
        }
        try {
          this.ensureDir(to.substring(0, to.lastIndexOf('/')));
          fs.renameSync(from, to);
        } catch (error) {
          failed.push(name + '：移回失败（' + (error as Error).message + '）');
        }
      }
    }
    if (failed.length > 0) { return '恢复未完成，隔离记录已保留：' + failed.join('；'); }
    try {
      this.writeBundles(records[0].originalBundles);
      this.saveRecords([]);
      try { this.removeTree(this.quarantineRoot); } catch (error) { /* 清理失败无影响 */ }
      return '';
    } catch (error) {
      return '恢复配置失败：' + (error as Error).message;
    }
  }

  hasQuarantine(): boolean {
    try { return this.records().length > 0; } catch (error) { return false; }
  }

  quarantineCount(): number {
    let total = 0;
    for (const record of this.records()) { total += record.bundles.length; }
    return total;
  }

  canAutoRestore(): boolean {
    try { if (fs.accessSync(this.autoMarker)) { return false; } } catch (error) { /* 首次 */ }
    const records = this.records();
    if (records.length === 0) { return false; }
    for (const record of records) {
      if (record.reason.indexOf('上次启动未完成') < 0 || record.autoRestored === true) { return false; }
    }
    return true;
  }

  markAutoRestoreAttempted(): void {
    try { this.writeText(this.autoMarker, Date.now().toString()); } catch (error) { /* 最多多试一次 */ }
    const records = this.records();
    for (const record of records) { record.autoRestored = true; }
    try { this.saveRecords(records); } catch (error) { /* 尽力而为 */ }
  }

  inspect(): string[] {
    const problems: string[] = [];
    for (const name of this.thirdParty()) {
      const dir = this.profile + '/node_modules/' + name;
      if (!fs.accessSync(dir)) { problems.push(name + '：目录不存在'); continue; }
      const manifest = this.readObject(dir + '/package.json');
      if (!manifest) { problems.push(name + '：package.json 无法解析'); continue; }
      const dsh = manifest['dsh'] as Record<string, Object> | undefined;
      const bundle = dsh ? dsh['bundle'] as Record<string, Object> | undefined : undefined;
      const patches = bundle ? bundle['patch'] as string[] : undefined;
      if (patches) {
        for (const patch of patches) {
          if (!fs.accessSync(dir + '/' + patch.replace(/^\.\//, ''))) {
            problems.push(name + '：缺少 ' + patch);
          }
        }
      }
      this.inspectNodeFiles(dir, name, problems);
    }
    return problems;
  }

  private inspectNodeFiles(dir: string, name: string, problems: string[]): void {
    try {
      for (const entry of fs.listFileSync(dir)) {
        const path = dir + '/' + entry;
        if (fs.lstatSync(path).isDirectory()) { this.inspectNodeFiles(path, name, problems); continue; }
        if (!entry.endsWith('.node')) { continue; }
        const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
        const head = new Uint8Array(20);
        fs.readSync(file.fd, head);
        fs.closeSync(file);
        if (head[0] !== 0x7f || head[1] !== 0x45 || head[2] !== 0x4c || head[3] !== 0x46) {
          problems.push(name + '：' + entry + ' 不是 ELF');
          continue;
        }
        const machine = head[18] | (head[19] << 8);
        if (machine !== 0xb7) { problems.push(name + '：' + entry + ' 不是 arm64'); }
      }
    } catch (error) { /* 跳过不可读目录 */ }
  }

  backup(): void {
    try {
      const root = this.home + '/backups';
      this.ensureDir(root);
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      this.copyTree(this.profile, root + '/web-' + stamp);
      const names = fs.listFileSync(root).filter((name: string) => name.indexOf('web-') === 0).sort();
      while (names.length > 3) {
        this.removeTree(root + '/' + (names.shift() as string));
      }
    } catch (error) { /* 备份失败不阻断启动 */ }
  }
}

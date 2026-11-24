import host from 'libdsh_host.so';

export interface HostProbe {
  api: number;
  abi: number;
  pid: number;
}

export interface SpawnSpec {
  library: string;
  entry: string;
  argv: string[];
  env: string[];
  cwd: string;
}

export interface HostChunk {
  out: string;
  err: string;
  running: boolean;
  outEof: boolean;
  errEof: boolean;
  code: number;
}

export function probe(): HostProbe { return host.probe() as HostProbe; }
export function spawn(spec: SpawnSpec): number { return host.spawn(spec) as number; }
export function poll(id: number): HostChunk { return host.poll(id) as HostChunk; }
export function write(id: number, data: string): number { return host.write(id, data) as number; }
export function terminate(id: number): boolean { return host.terminate(id) as boolean; }
export function release(id: number): void { host.release(id); }
export function unpack(archive: string, destination: string): number { return host.unpack(archive, destination) as number; }
export function testAddon(libnode: string, addon: string): string { return host.testAddon(libnode, addon) as string; }
export function symlink(target: string, link: string): boolean { return host.symlink(target, link) as boolean; }
export function copyTree(src: string, dest: string): boolean { return host.copyTree(src, dest) as boolean; }

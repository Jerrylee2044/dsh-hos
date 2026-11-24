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

export const probe: () => HostProbe;
export const spawn: (spec: SpawnSpec) => number;
export const poll: (id: number) => HostChunk;
export const write: (id: number, data: string) => number;
export const terminate: (id: number) => boolean;
export const release: (id: number) => void;
export const unpack: (archive: string, destination: string) => number;
export const testAddon: (libnode: string, addon: string) => string;
export const symlink: (target: string, link: string) => boolean;
export const copyTree: (src: string, dest: string) => boolean;

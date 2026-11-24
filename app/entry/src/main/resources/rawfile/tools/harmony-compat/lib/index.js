import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { dshHomePath } from "@deepseek-ai/dsh-home-paths";
import z from "@deepseek-ai/schemastery";

const MIRROR_FILE = "harmony-native.json";

/**
 * DSH HOS host half of the HarmonyOS settings bridge.
 *
 * The browser settings form is generated from this plugin's exported Config,
 * so the profile entry id must stay `harmony-native`. Every accepted value is
 * mirrored atomically to `$DSH_HOME/harmony-native.json`; the native shell
 * polls that file and applies the switches.
 */
export const name = "harmony-compat";
export const inject = [];

export const Config = z.object({
  keepAlive: z.boolean().default(false).volatile()
});

function valueOf(config, key) {
  const value = config?.[key];
  if (value && typeof value.get === "function") return value.get() === true;
  return value === true;
}

export function apply(ctx, config) {
  const target = dshHomePath(MIRROR_FILE);
  let writes = Promise.resolve();

  const persist = () => {
    const next = { keepAlive: valueOf(config, "keepAlive") };
    writes = writes.then(async () => {
      let existing = {};
      try {
        const parsed = JSON.parse(await readFile(target, "utf8"));
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) existing = parsed;
      } catch (error) {
        // First write, or a damaged file: start from an empty object.
      }
      await mkdir(dirname(target), { recursive: true });
      const temporary = target + "." + process.pid + ".tmp";
      await writeFile(temporary, JSON.stringify(Object.assign({}, existing, next), null, 2) + "\n", "utf8");
      await rename(temporary, target);
    }).catch((error) => {
      ctx.logger?.warn?.("harmony-native.json write failed", error);
    });
    return writes;
  };

  // Write once at startup so the shell has a concrete state, then react to
  // each live settings edit.
  void persist();
  ctx.on("loader/volatile-update", (paths) => {
    if (!Array.isArray(paths)) return;
    const changed = paths.some((path) => Array.isArray(path) && path[0] === "keepAlive");
    if (changed) void persist();
  });
}

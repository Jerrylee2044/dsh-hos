/** DSH HOS: HarmonyOS blocks dlopen of the musl system.node addon; DSH only
 * needs its advisory flock for local coordination, so use a no-op lock. */
export async function tryLockExclusive(fd) {
  return;
}

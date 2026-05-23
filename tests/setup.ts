import * as fsPromises from "node:fs/promises";

// 1. Force a deterministic default branch name for any `git init` performed by
// production code or test fixtures. Without this, Windows machines whose
// `init.defaultBranch` is unset fall back to `master`, breaking tests that
// push to `main`. Using GIT_CONFIG_* keeps the change scoped to the test
// process — no global git config mutation.
process.env.GIT_CONFIG_COUNT = "1";
process.env.GIT_CONFIG_KEY_0 = "init.defaultBranch";
process.env.GIT_CONFIG_VALUE_0 = "main";

// 2. Windows holds file handles open longer than POSIX after a process exits;
// `fs.rm` racing with git's lingering handles produces EBUSY in afterEach
// cleanup. Inject default retry options via Object.defineProperty (plain
// assignment fails on the frozen fs/promises module).
if (process.platform === "win32") {
	const originalRm = fsPromises.rm.bind(fsPromises);
	const wrappedRm: typeof fsPromises.rm = (target, options) =>
		originalRm(target, {
			maxRetries: 5,
			retryDelay: 100,
			...options,
		});
	try {
		Object.defineProperty(fsPromises, "rm", {
			value: wrappedRm,
			writable: true,
			configurable: true,
		});
	} catch {
		// On Node versions where the descriptor is non-configurable, leave it
		// alone — tests on Windows may see occasional EBUSY in cleanup.
	}
}

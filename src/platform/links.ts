import * as fs from "node:fs/promises";
import * as path from "node:path";

const isWindows = process.platform === "win32";

/**
 * Creates a link from `linkPath` pointing at `targetPath` in a way that works
 * on Windows without requiring administrator privileges or Developer Mode.
 *
 * On POSIX systems this is a regular `fs.symlink`. On Windows:
 *   - directory targets use a "junction" reparse point (works without admin)
 *   - file targets use a hard link via `fs.link` (also works without admin)
 *
 * Hard links share inodes rather than pointing at a path, but for ai-sync's
 * use case — making edits in either location propagate to the other — the
 * semantics are equivalent. Hard links require both paths to live on the same
 * volume; if that fails (e.g. EXDEV), the caller can fall back to copying.
 */
export async function createLink(targetPath: string, linkPath: string): Promise<void> {
	if (!isWindows) {
		await fs.symlink(targetPath, linkPath);
		return;
	}

	let isDir = false;
	try {
		const stat = await fs.stat(targetPath);
		isDir = stat.isDirectory();
	} catch {
		// Target doesn't exist or isn't reachable; fall through to symlink which
		// will produce a clear ENOENT/EPERM error.
	}

	if (isDir) {
		await fs.symlink(path.resolve(targetPath), linkPath, "junction");
		return;
	}

	await fs.link(targetPath, linkPath);
}

/**
 * Returns the absolute path a link resolves to, for both POSIX symlinks and
 * Windows junctions. For Windows hard links this returns the link path itself
 * (hard links have no separate target). Callers that need to compare against
 * an expected destination should normalize both sides with `path.resolve`.
 */
export async function readLinkTarget(linkPath: string): Promise<string> {
	const target = await fs.readlink(linkPath);
	return path.resolve(path.dirname(linkPath), target);
}

/**
 * Reports whether `linkPath` is a symbolic link or junction. Hard links on
 * Windows appear as regular files to `lstat`, so this returns false for them
 * — there is no portable way to detect a hard link short of comparing inodes
 * with another known path, which callers can do explicitly when needed.
 */
export async function isLink(linkPath: string): Promise<boolean> {
	try {
		const stat = await fs.lstat(linkPath);
		return stat.isSymbolicLink();
	} catch {
		return false;
	}
}

/**
 * Reports whether `linkPath` already refers to the same on-disk content as
 * `targetPath`, by either kind of link. On POSIX, symlinks are resolved via
 * `readlink`. On Windows we additionally compare inode + device numbers so
 * hard links register as "already linked", keeping the linker idempotent.
 */
export async function isLinkedTo(linkPath: string, targetPath: string): Promise<boolean> {
	try {
		const lstat = await fs.lstat(linkPath);
		if (lstat.isSymbolicLink()) {
			const resolved = await readLinkTarget(linkPath);
			return path.resolve(resolved) === path.resolve(targetPath);
		}
		if (isWindows) {
			const targetStat = await fs.stat(targetPath);
			return lstat.ino !== 0 && lstat.ino === targetStat.ino && lstat.dev === targetStat.dev;
		}
		return false;
	} catch {
		return false;
	}
}

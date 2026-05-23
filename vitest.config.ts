import { defineConfig } from "vitest/config";

export default defineConfig({
	test: {
		globals: true,
		environment: "node",
		include: ["tests/**/*.test.ts"],
		// Windows spawns git child processes substantially slower than POSIX —
		// the 5s default times out routine network ops. 30s gives headroom
		// without masking genuine hangs.
		testTimeout: 30_000,
		hookTimeout: 30_000,
		setupFiles: ["./tests/setup.ts"],
		coverage: {
			provider: "v8",
			include: ["src/**/*.ts"],
		},
	},
});

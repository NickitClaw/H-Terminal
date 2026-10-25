import { copyFile, mkdir, readFile, rm } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const terminalDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const projectDir = resolve(terminalDir, "..");
const vendorDir = resolve(
  projectDir,
  "entry/src/main/resources/rawfile/terminal/vendor",
);
const manifest = JSON.parse(
  await readFile(resolve(terminalDir, "package.json"), "utf8"),
);

const packages = [
  {
    name: "@xterm/xterm",
    assets: [
      ["lib/xterm.js", "xterm.js"],
      ["lib/xterm.mjs", "xterm.mjs"],
      ["css/xterm.css", "xterm.css"],
      ["LICENSE", "LICENSE.xterm"],
    ],
  },
  {
    name: "@xterm/addon-fit",
    assets: [
      ["lib/addon-fit.js", "addon-fit.js"],
      ["lib/addon-fit.mjs", "addon-fit.mjs"],
      ["LICENSE", "LICENSE.addon-fit"],
    ],
  },
];

await rm(vendorDir, { recursive: true, force: true });
await mkdir(vendorDir, { recursive: true });

for (const pkg of packages) {
  const packageDir = resolve(terminalDir, "node_modules", ...pkg.name.split("/"));
  const installed = JSON.parse(
    await readFile(resolve(packageDir, "package.json"), "utf8"),
  );
  const expected = manifest.devDependencies[pkg.name];

  if (installed.version !== expected) {
    throw new Error(
      `${pkg.name}: expected ${expected}, installed ${installed.version}; run npm ci`,
    );
  }

  await Promise.all(
    pkg.assets.map(([source, destination]) =>
      copyFile(resolve(packageDir, source), resolve(vendorDir, destination))
    ),
  );
}

console.log(`Synced ${packages.length} pinned packages to ${vendorDir}`);

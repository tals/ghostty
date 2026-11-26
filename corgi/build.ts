/**
 * Builds ghostty-host for each release target from this tree (Ghostty with
 * the headless apprt in src/apprt/headless), packs each with Ghostty's
 * resources, and with --publish uploads them to Corgi's release bucket:
 *
 *   bun corgi/build.ts                      every target this machine can build
 *   bun corgi/build.ts linux-x86_64         one target
 *   bun corgi/build.ts --publish            build, then upload to ghostty-host/VERSION/
 *   bun corgi/build.ts --upload             upload what --publish built, after a failed upload
 *
 * macOS arm64 builds on a Mac (Xcode for the Metal shaders); Linux x86_64 and
 * arm64 cross-compile anywhere with Zig. Output goes to corgi/out/:
 * ghostty-host-VERSION-TARGET.tar.gz and SHA256SUMS.
 *
 * VERSION follows Corgi's releases: the UTC datetime of the publish and the
 * commit's first 12 hex digits (20261126T031500Z-638b2c112abc). Publishing
 * needs a clean tree whose commit is on this fork's corgi branch on GitHub.
 * Then, in Corgi, `bun scripts/pin_ghostty_host.ts VERSION` points
 * scripts/ghostty-host at it.
 *
 * Needs Bun and Zig 0.17.0 ($ZIG or zig on PATH). Publishing reads Corgi's
 * release config (~/.config/corgi/release.json or $CORGI_RELEASE_CONFIG) for
 * the bucket, and its credentialsFile or AWS_ACCESS_KEY_ID and
 * AWS_SECRET_ACCESS_KEY.
 */
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

type Target = "macos-aarch64" | "linux-x86_64" | "linux-aarch64";
const targets: Target[] = ["macos-aarch64", "linux-x86_64", "linux-aarch64"];
// The oldest glibc the Linux builds run on: Debian 10, Ubuntu 20.04, RHEL 8.
const GLIBC = "2.28";

const root = resolve(import.meta.dir, "..");
const out = join(root, "corgi/out");

function run(argv: string[], cwd = root, env: Record<string, string | undefined> = process.env): string {
  const p = Bun.spawnSync(argv, { cwd, env, stdout: "pipe", stderr: "inherit" });
  if (p.exitCode !== 0) throw Error(`${argv.join(" ")} exited with ${p.exitCode}`);
  return p.stdout.toString().trim();
}

function zig(): string {
  const path = process.env.ZIG ?? Bun.which("zig");
  if (!path) throw Error("no Zig 0.17.0: set ZIG or put zig on PATH");
  const version = run([path, "version"]);
  if (version !== "0.17.0") throw Error(`Ghostty 1.4.0 needs Zig 0.17.0; ${path} is ${version}`);
  return path;
}

const FORK = "https://github.com/tals/ghostty.git";
const BRANCH = "corgi";

/** Corgi's release version: the UTC datetime and the commit's first 12 hex digits. */
function timestampVersion(commit: string, date = new Date()): string {
  return `${date.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z")}-${commit.slice(0, 12)}`;
}

/** Ghostty's own version for the build: build.zig.zon's, marked as this commit. */
function ghosttyVersion(commit: string): string {
  const zon = /\.version = "([^"]+)"/.exec(readFileSync(join(root, "build.zig.zon"), "utf8"))![1];
  return `${zon}+corgi.${commit.slice(0, 12)}`;
}

/** Zig's target for each release target; the Mac builds for itself. */
function zigTarget(target: Target): string[] {
  switch (target) {
    case "macos-aarch64":
      if (process.platform !== "darwin") throw Error("macos-aarch64 builds on a Mac");
      return [];
    case "linux-x86_64":
      return [`-Dtarget=x86_64-linux-gnu.${GLIBC}`];
    case "linux-aarch64":
      return [`-Dtarget=aarch64-linux-gnu.${GLIBC}`];
  }
}

/** Builds one target into its package folder and packs it; returns the archive. */
function build(compiler: string, target: Target, name: string, options: string[]): string {
  const work = join(out, target);
  const pkg = join(work, name);
  const prefix = join(work, "prefix");
  rmSync(pkg, { recursive: true, force: true });
  mkdirSync(pkg, { recursive: true });
  console.log(`==> ${target}`);
  // The headless apprt builds ghostty-host itself, with Ghostty's resources.
  run([
    compiler,
    "build",
    "-Doptimize=ReleaseFast",
    "-Dapp-runtime=headless",
    "-Demit-macos-app=false",
    ...zigTarget(target),
    ...options,
    "-p",
    prefix,
  ]);
  cpSync(join(prefix, "bin/ghostty-host"), join(pkg, "ghostty-host"));
  // Ghostty finds terminfo beside its resources folder.
  for (const dir of ["ghostty", "terminfo"]) cpSync(join(prefix, "share", dir), join(pkg, "share", dir), { recursive: true });
  cpSync(join(root, "LICENSE"), join(pkg, "LICENSE"));
  // Lists a process's windows from outside it, for tools/prove.py: the host has none.
  if (target === "macos-aarch64")
    run(["clang", "-O2", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics", join(root, "corgi/tools/winlist.m"), "-o", join(work, "winlist")]);
  const archive = join(out, `${name}.tar.gz`);
  // No macOS metadata or owner names: GNU tar warns about each, and they leak the builder's.
  const plain =
    process.platform === "darwin"
      ? ["--no-xattrs", "--no-mac-metadata", "--uid", "0", "--gid", "0"]
      : ["--no-xattrs", "--owner=0", "--group=0", "--numeric-owner"];
  run(["tar", ...plain, "-czf", archive, "-C", work, name], root, { ...process.env, COPYFILE_DISABLE: "1" });
  return archive;
}

const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");

async function publish(version: string, files: string[]) {
  const configPath = process.env.CORGI_RELEASE_CONFIG || join(homedir(), ".config/corgi/release.json");
  const config = JSON.parse(readFileSync(configPath, "utf8")) as {
    publicBaseUrl: string;
    endpoint: string;
    region: string;
    bucket: string;
    credentialsFile?: string;
  };
  let { AWS_ACCESS_KEY_ID: accessKeyId, AWS_SECRET_ACCESS_KEY: secretAccessKey } = process.env;
  if (!accessKeyId && !secretAccessKey && config.credentialsFile) {
    if (statSync(config.credentialsFile).mode & 0o077) throw Error(`${config.credentialsFile} must be chmod 600`);
    ({ accessKeyId, secretAccessKey } = JSON.parse(readFileSync(config.credentialsFile, "utf8")));
  }
  if (!accessKeyId || !secretAccessKey) throw Error("no bucket credentials: see the comment at the top");
  const s3 = new Bun.S3Client({ endpoint: config.endpoint, region: config.region, bucket: config.bucket, accessKeyId, secretAccessKey });
  const keys = files.map(file => [file, `ghostty-host/${version}/${file.split("/").at(-1)}`] as const);
  for (const [file, key] of keys) {
    const bytes = readFileSync(file);
    const object = s3.file(key);
    // A published version never changes: the same bytes are skipped, others refused.
    if (await object.exists()) {
      if (sha256(new Uint8Array(await object.arrayBuffer())) !== sha256(bytes))
        throw Error(`${key} is already published with other contents`);
      console.log(`    ${key} is already uploaded`);
      continue;
    }
    console.log(`    uploading ${key} (${(bytes.length / 1e6).toFixed(1)} MB)`);
    await object.write(bytes, { type: file.endsWith(".gz") ? "application/gzip" : "text/plain" });
  }
  // What a download gets: corgi.computer serves the bucket only on the paths
  // routed to it (Corgi's site/bucket_routes.ts), and a new route takes a few
  // seconds to reach the edge.
  for (const [file, key] of keys) {
    const url = `${config.publicBaseUrl}/${key}`;
    for (let attempt = 1; ; attempt++) {
      const served = await fetch(url, { cache: "no-store" });
      if (served.ok && sha256(new Uint8Array(await served.arrayBuffer())) === sha256(readFileSync(file))) break;
      if (attempt === 8)
        throw Error(
          `${url} answers HTTP ${served.status} without the upload; is ${new URL(url).host}/ghostty-host/* routed to the bucket?`,
        );
      await Bun.sleep(4000);
    }
  }
  console.log(`published to ${config.publicBaseUrl}/ghostty-host/${version}/`);
}

const args = process.argv.slice(2);
const publishing = args.includes("--publish");
const uploading = args.includes("--upload");
const asked = args.filter(a => a !== "--publish" && a !== "--upload");
for (const a of asked) if (!targets.includes(a as Target)) throw Error(`unknown target ${a}; one of ${targets.join(", ")}`);
const chosen = (asked.length ? asked : targets).filter(t => t !== "macos-aarch64" || process.platform === "darwin") as Target[];
const commit = run(["git", "rev-parse", "HEAD"]);
// The version a publish chose, so an interrupted upload resumes it.
const published = join(out, "VERSION");
if (publishing) {
  if (run(["git", "status", "--porcelain", "--untracked-files=no"])) throw Error("--publish needs a clean tree");
  const pushed = run(["git", "ls-remote", FORK, `refs/heads/${BRANCH}`]).split(/\s/)[0];
  if (pushed !== commit) throw Error(`--publish needs HEAD pushed as ${FORK} ${BRANCH}; it has ${pushed || "nothing"}`);
  if (chosen.length !== targets.length) throw Error(`--publish builds every target; this machine builds ${chosen.join(", ")}`);
}
let v = publishing ? timestampVersion(commit) : `dev-${commit.slice(0, 12)}`;
if (uploading) {
  const saved = existsSync(published) ? readFileSync(published, "utf8").trim() : "";
  if (!saved.endsWith(`-${commit.slice(0, 12)}`)) throw Error("--upload resumes a --publish of HEAD; there's none in corgi/out");
  v = saved;
  const built = targets.map(target => join(out, `ghostty-host-${v}-${target}.tar.gz`));
  const sums = join(out, "SHA256SUMS");
  for (const file of [...built, sums]) if (!existsSync(file)) throw Error(`no ${file}; run --publish`);
  await publish(v, [...built, sums]);
  process.exit(0);
}
const compiler = zig();
mkdirSync(out, { recursive: true });
// An explicit version also keeps Ghostty's build from checking git tags on HEAD.
const options = [`-Dversion-string=${ghosttyVersion(commit)}`];
const archives = chosen.map(target => build(compiler, target, `ghostty-host-${v}-${target}`, options));
const sums = join(out, "SHA256SUMS");
writeFileSync(
  sums,
  archives.map(file => `${sha256(readFileSync(file))}  ${file.split("/").at(-1)}\n`).join(""),
);
console.log(readFileSync(sums, "utf8").trimEnd());
if (publishing) {
  writeFileSync(published, `${v}\n`);
  await publish(v, [...archives, sums]);
  console.log(`In Corgi: bun scripts/pin_ghostty_host.ts ${v}`);
}

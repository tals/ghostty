/**
 * Builds ghostty-host for each release target from this tree (Ghostty with
 * the headless patch), packs each with libghostty's resources, and with
 * --publish uploads them to Corgi's release bucket:
 *
 *   bun corgi/build.ts                      every target this machine can build
 *   bun corgi/build.ts linux-x86_64         one target
 *   bun corgi/build.ts --publish            build, then upload to ghostty-host/VERSION/
 *   bun corgi/build.ts --upload             upload what --publish built, after a failed upload
 *
 * macOS arm64 builds on a Mac (Xcode for the Metal shaders); Linux x86_64 and
 * arm64 cross-compile anywhere with Zig. VERSION is the tag on HEAD without
 * its v (v1.4.0-corgi.1 is 1.4.0-corgi.1); publishing needs that tag and a
 * clean tree. Output goes to corgi/out/: ghostty-host-VERSION-TARGET.tar.gz
 * and SHA256SUMS.
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
const MACOS_MIN = "13.0";

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

function version(): { name: string; tagged: boolean } {
  const tag = Bun.spawnSync(["git", "describe", "--tags", "--exact-match", "HEAD"], { cwd: root, stderr: "ignore" });
  const name = tag.stdout.toString().trim();
  if (tag.exitCode === 0 && /^v\d+\.\d+\.\d+-corgi\.\d+$/.test(name)) return { name: name.slice(1), tagged: true };
  return { name: `dev-${run(["git", "rev-parse", "--short", "HEAD"])}`, tagged: false };
}

/** The zlib that Ghostty builds in, for its header: the Linux host calls libghostty's zlib. */
function zlibSource(): string {
  const hash = /\.hash = "([^"]+)"/.exec(readFileSync(join(root, "pkg/zlib/build.zig.zon"), "utf8"))![1];
  // Zig 0.17 fetches a project's packages into its zig-pkg folder.
  const dir = join(root, "zig-pkg", hash);
  if (!existsSync(join(dir, "zlib.h"))) throw Error(`no zlib.h in ${dir}; the library build fetches it`);
  return dir;
}

const shared = ["main", "frames", "input", "http", "json", "image"];
const warnings = ["-Wall", "-Wextra", "-Wno-unused-parameter"];

function buildMacos(compiler: string, work: string, pkg: string, options: string[]) {
  if (process.platform !== "darwin") throw Error("macos-aarch64 builds on a Mac");
  const prefix = join(work, "prefix");
  run([
    compiler,
    "build",
    "-Doptimize=ReleaseFast",
    "-Demit-macos-app=false",
    "-Dxcframework-target=native",
    ...options,
    "-p",
    prefix,
  ]);
  const kit = join(root, "macos/GhosttyKit.xcframework/macos-arm64");
  const flags = ["-O2", "-g", ...warnings, `-I${kit}/Headers`, `-mmacosx-version-min=${MACOS_MIN}`, "-arch", "arm64"];
  const objects: string[] = [];
  const compile = (source: string, extra: string[] = []) => {
    const object = join(work, `${source.replace(/\W/g, "_")}.o`);
    run(["clang", ...flags, ...extra, "-c", join(root, "corgi/src", source), "-o", object]);
    objects.push(object);
  };
  for (const name of shared) compile(`${name}.c`, ["-std=c11"]);
  compile("pacer_macos.c", ["-std=c11"]);
  compile("platform_macos.m", ["-fobjc-arc"]);
  run([
    "clang",
    `-mmacosx-version-min=${MACOS_MIN}`,
    "-arch",
    "arm64",
    "-o",
    join(pkg, "ghostty-host"),
    ...objects,
    join(kit, "libghostty-internal.a"),
    ...["AppKit", "Metal", "QuartzCore", "IOSurface", "CoreText", "CoreVideo", "CoreGraphics", "Carbon"].flatMap(f => [
      "-framework",
      f,
    ]),
    "-lc++",
    "-lz",
  ]);
  // Lists a process's windows from outside it, for tools/prove.py: the host has none.
  run(["clang", "-O2", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics", join(root, "corgi/tools/winlist.m"), "-o", join(work, "winlist")]);
  return prefix;
}

function buildLinux(compiler: string, work: string, pkg: string, arch: "x86_64" | "aarch64", options: string[]) {
  const target = `${arch}-linux-gnu.${GLIBC}`;
  const prefix = join(work, "prefix");
  run([compiler, "build", "-Doptimize=ReleaseFast", "-Dapp-runtime=none", `-Dtarget=${target}`, ...options, "-p", prefix]);
  // The library's soname is libghostty.so; the host finds it beside itself.
  cpSync(join(prefix, "lib/ghostty-internal.so"), join(pkg, "libghostty.so"));
  const cc = [compiler, "cc", "-target", target];
  const glad = join(root, "vendor/glad");
  const zlib = zlibSource();
  const flags = ["-O2", ...warnings, "-std=c11", "-D_GNU_SOURCE", `-I${prefix}/include`, `-I${zlib}`];
  const objects: string[] = [];
  const compile = (source: string, extra: string[]) => {
    const object = join(work, `${source.replace(/\W/g, "_")}.o`);
    run([...cc, ...extra, "-c", source, "-o", object]);
    objects.push(object);
  };
  for (const name of [...shared, "platform_linux"]) compile(join(root, "corgi/src", `${name}.c`), flags);
  // The library leaves glad (the GL and EGL loaders) and EGL to the program,
  // as Ghostty's own executable compiles and links them.
  compile(join(glad, "src/gl.c"), ["-O2", `-I${glad}/include`]);
  compile(join(glad, "src/glad_egl.c"), ["-O2", `-I${glad}/include`]);
  // EGL comes from the machine it runs on. A stub with libEGL.so.1's name and
  // the functions used stands in for it here, so this links on any OS.
  const used = [join(pkg, "libghostty.so"), ...objects].flatMap(file =>
    run(["nm", "-u", ...(file.endsWith(".so") ? ["-D"] : []), file])
      .split("\n")
      .map(line => line.trim().split(/\s+/).at(-1)!)
      .filter(name => /^egl[A-Z]/.test(name)),
  );
  const stubs = join(work, "egl");
  mkdirSync(stubs, { recursive: true });
  writeFileSync(
    join(stubs, "egl.c"),
    [...new Set(used)]
      .sort()
      .map(name => `void ${name}(void) {}\n`)
      .join(""),
  );
  run([...cc, "-shared", "-Wl,-soname,libEGL.so.1", "-o", join(stubs, "libEGL.so"), join(stubs, "egl.c")]);
  run([
    ...cc,
    "-o",
    join(pkg, "ghostty-host"),
    ...objects,
    `-L${pkg}`,
    "-lghostty",
    `-L${stubs}`,
    "-lEGL",
    "-lm",
    "-lpthread",
    "-Wl,-rpath,$ORIGIN",
  ]);
  return prefix;
}

/** Builds one target into its package folder and packs it; returns the archive. */
function build(compiler: string, target: Target, name: string, options: string[]): string {
  const work = join(out, target);
  const pkg = join(work, name);
  rmSync(pkg, { recursive: true, force: true });
  mkdirSync(pkg, { recursive: true });
  console.log(`==> ${target}`);
  const prefix =
    target === "macos-aarch64"
      ? buildMacos(compiler, work, pkg, options)
      : buildLinux(compiler, work, pkg, target === "linux-x86_64" ? "x86_64" : "aarch64", options);
  // Ghostty finds terminfo beside its resources folder.
  for (const dir of ["ghostty", "terminfo"]) cpSync(join(prefix, "share", dir), join(pkg, "share", dir), { recursive: true });
  cpSync(join(root, "LICENSE"), join(pkg, "LICENSE"));
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
        throw Error(`${key} is already published with other contents; tag a new version`);
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
const { name: v, tagged } = version();
if (publishing) {
  if (!tagged) throw Error("--publish needs a vX.Y.Z-corgi.N tag on HEAD");
  if (run(["git", "status", "--porcelain", "--untracked-files=no"])) throw Error("--publish needs a clean tree");
  if (chosen.length !== targets.length) throw Error(`--publish builds every target; this machine builds ${chosen.join(", ")}`);
}
if (uploading) {
  if (!tagged) throw Error("--upload needs the vX.Y.Z-corgi.N tag on HEAD that --publish built");
  const built = targets.map(target => join(out, `ghostty-host-${v}-${target}.tar.gz`));
  const sums = join(out, "SHA256SUMS");
  for (const file of [...built, sums]) if (!existsSync(file)) throw Error(`no ${file}; run --publish`);
  await publish(v, [...built, sums]);
  process.exit(0);
}
const compiler = zig();
mkdirSync(out, { recursive: true });
// Ghostty's build takes a tag on HEAD for its own version and accepts only
// vX.Y.Z; an explicit version skips that check.
const options = tagged ? [`-Dversion-string=${v}`] : [];
const archives = chosen.map(target => build(compiler, target, `ghostty-host-${v}-${target}`, options));
const sums = join(out, "SHA256SUMS");
writeFileSync(
  sums,
  archives.map(file => `${sha256(readFileSync(file))}  ${file.split("/").at(-1)}\n`).join(""),
);
console.log(readFileSync(sums, "utf8").trimEnd());
if (publishing) await publish(v, [...archives, sums]);

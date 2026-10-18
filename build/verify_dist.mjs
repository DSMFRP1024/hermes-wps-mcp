/**
 * 产物校验 —— 编译结果完整性 + 可加载性。
 *
 * 在 CI 里紧跟 tsc 之后跑。它拦的是「编译绿了但产物不可用」这一类问题：
 *   · 入口文件缺失 / 空文件
 *   · 关键模块没被编译出来（tsconfig include 漏配）
 *   · 产物 require 时抛错（依赖没装、循环引用）
 *   · 误把 .ts 源码混进 dist
 *
 * 用法：node build/verify_dist.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const MC = path.join(ROOT, 'wps-office-mcp');
const DIST = path.join(MC, 'dist');

let pass = 0;
let fail = 0;
const problems = [];

function ok(name, extra = '') {
  pass++;
  console.log(`  \u2713 ${name}${extra ? '  ' + extra : ''}`);
}
function bad(name, detail) {
  fail++;
  problems.push(`${name}: ${detail}`);
  console.log(`  \u2717 ${name}  ${detail}`);
}

/** 必须存在的产物（相对 dist） */
const REQUIRED = [
  'index.js',
  'client/wps-client.js',
  'client/mac-poll-server.js',
  'server/mcp-server.js',
  'server/tool-registry.js',
  'tools/index.js',
  'utils/logger.js',
  'utils/error.js',
  'types/wps.js',
];

/** 必须能 require 的模块（入口 + 两个客户端 + MCP 服务） */
const LOADABLE = [
  'index.js',
  'client/mac-poll-server.js',
  'client/wps-client.js',
  'server/mcp-server.js',
];

console.log('== 产物校验 ==');
console.log(`   dist: ${DIST}\n`);

if (!fs.existsSync(DIST)) {
  console.error('✗ dist 不存在，请先执行 npx tsc');
  process.exit(1);
}

// ---------- 1. 必需文件 ----------
console.log('[1] 必需产物');
for (const rel of REQUIRED) {
  const p = path.join(DIST, rel);
  if (!fs.existsSync(p)) {
    bad(rel, '缺失');
    continue;
  }
  const size = fs.statSync(p).size;
  if (size < 32) bad(rel, `体积异常 ${size} B`);
  else ok(rel, `${size} B`);
}

// ---------- 2. 可加载性 ----------
console.log('\n[2] 可加载性（require）');
const require = createRequire(path.join(MC, 'package.json'));
for (const rel of LOADABLE) {
  const p = path.join(DIST, rel);
  if (!fs.existsSync(p)) { bad(rel, '不存在，跳过'); continue; }
  try {
    require(p);
    ok(rel, 'require 成功');
  } catch (e) {
    bad(rel, `require 抛错: ${e && e.message}`);
  }
}

// ---------- 3. 入口不自动启动 ----------
// 被 require 时不应执行 main()，否则 CI 会挂住（stdio server 会一直等输入）
console.log('\n[3] 入口副作用');
try {
  const entry = require(path.join(DIST, 'index.js'));
  const keys = Object.keys(entry);
  if (keys.length >= 3) ok('入口导出模块', `${keys.length} 个导出`);
  else bad('入口导出模块', `仅 ${keys.length} 个导出: ${keys.join(',')}`);
  if (typeof entry.createMcpServer === 'function') ok('导出 createMcpServer');
  else bad('导出 createMcpServer', '不是函数');
  if (typeof entry.wpsClient === 'object') ok('导出 wpsClient 单例');
  else bad('导出 wpsClient 单例', typeof entry.wpsClient);
} catch (e) {
  bad('入口导出检查', String(e && e.message));
}

// ---------- 4. dist 里不该有源码 ----------
console.log('\n[4] 源码泄漏');
const stray = [];
function walk(dir) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p);
    else if (/\.(ts|tsx)$/.test(ent.name) && !ent.name.endsWith('.d.ts')) stray.push(p);
  }
}
walk(DIST);
if (stray.length === 0) ok('dist 无 .ts 源码');
else bad('dist 无 .ts 源码', `发现 ${stray.length} 个: ${stray.slice(0, 3).join(', ')}`);

// ---------- 5. 规模统计 ----------
console.log('\n[5] 规模');
let jsCount = 0;
let jsBytes = 0;
let mapBytes = 0;
function walk2(dir) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) { walk2(p); continue; }
    const s = fs.statSync(p).size;
    if (ent.name.endsWith('.js')) { jsCount++; jsBytes += s; }
    else if (ent.name.endsWith('.map')) mapBytes += s;
  }
}
walk2(DIST);
ok('统计', `${jsCount} 个 .js, ${(jsBytes / 1024).toFixed(1)} KB（sourcemap ${(mapBytes / 1024).toFixed(1)} KB）`);
if (jsCount < 20) bad('模块数量', `仅 ${jsCount} 个，tsconfig include 可能漏配`);

// ---------- 6. 生产依赖可解析 ----------
// 不按 package.json 的 dependencies 逐条 require.resolve —— 那样会误报：
// @modelcontextprotocol/sdk@1.29.0 的 exports["."] 指向 dist/cjs/index.js，
// 而该文件根本没打进包里（上游打包瑕疵），只能走子路径 /server/stdio.js。
// 正确做法：扫描 dist 里真实出现的 require("...") 说明符，逐个解析。
// 这才是运行时真正需要的东西。
console.log('\n[6] 生产依赖（按实际 require 扫描）');
const external = new Set();
const REQ_RE = /\brequire\(\s*["']([^"']+)["']\s*\)/g;
function scanRequires(dir) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) { scanRequires(p); continue; }
    if (!ent.name.endsWith('.js')) continue;
    const src = fs.readFileSync(p, 'utf8');
    let m;
    while ((m = REQ_RE.exec(src)) !== null) {
      const spec = m[1];
      if (spec.startsWith('.') || spec.startsWith('node:')) continue;
      external.add(spec);
    }
  }
}
scanRequires(DIST);

// 内置模块名单（不需要解析，只确认不是漏装的第三方包）
const BUILTINS = new Set(['fs', 'path', 'os', 'http', 'https', 'url', 'util', 'crypto',
  'events', 'stream', 'child_process', 'assert', 'net', 'tls', 'zlib', 'buffer',
  'string_decoder', 'querystring', 'readline', 'process', 'timers', 'dns']);

const unresolved = [];
let resolvedCount = 0;
for (const spec of [...external].sort()) {
  if (BUILTINS.has(spec)) continue;
  try {
    require.resolve(spec, { paths: [MC] });
    resolvedCount++;
  } catch {
    unresolved.push(spec);
  }
}
if (unresolved.length === 0) {
  ok('全部外部依赖可解析', `${resolvedCount} 个说明符`);
} else {
  bad('存在无法解析的依赖', `${unresolved.length} 个: ${unresolved.join(', ')}`);
}

// 顶层包清单（便于回看装了什么）
const topDeps = [...new Set([...external].filter((s) => !BUILTINS.has(s))
  .map((s) => (s.startsWith('@') ? s.split('/').slice(0, 2).join('/') : s.split('/')[0])))].sort();
ok('实际引用的顶层包', topDeps.join(', '));

// ---------- 汇总 ----------
console.log(`\n== 结果: ${pass} 通过 / ${fail} 失败 ==`);
if (fail) {
  console.log('\n问题项：');
  problems.forEach((p) => console.log('  - ' + p));
  process.exit(1);
}
process.exit(0);

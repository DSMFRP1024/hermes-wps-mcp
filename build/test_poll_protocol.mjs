/**
 * 协议联动测试 —— 伪造 WPS 加载项，验证 Linux 分支的完整收发链路。
 *
 * 为什么需要它：
 *   Linux/macOS 走的是「反向轮询」（wps-client.ts 的 USE_POLL 分支），
 *   真正的收发方是 WPS 里的加载项。CI 里没有 WPS、没有图形会话，
 *   但**协议层是可以完整验证的** —— 只要按加载项的契约发请求即可：
 *
 *     GET  /poll   -> {"command":{action,params,requestId}}  或  {}
 *     POST /result -> 回传 {requestId,result}，服务端应答 {"ok":true}
 *     GET  /status -> {status,currentApp,hasPendingCommand}
 *
 *   所以这个脚本代替真加载项，断言：投递、取走、requestId 匹配、
 *   回执解析、不重复投递、超时、CORS 预检、404。
 *
 * 用法：node build/test_poll_protocol.mjs
 * 前置：在 wps-office-mcp 下已执行 npx tsc（dist/ 存在）
 */
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SERVER_JS = path.join(ROOT, 'wps-office-mcp', 'dist', 'client', 'mac-poll-server.js');

const PORT = Number(process.env.TEST_POLL_PORT || 58999);
const BASE = `http://127.0.0.1:${PORT}`;

let pass = 0;
let fail = 0;
const failures = [];

function ok(name, extra = '') {
  pass++;
  console.log(`  \u2713 ${name}${extra ? '  ' + extra : ''}`);
}
function bad(name, detail) {
  fail++;
  failures.push(`${name}: ${detail}`);
  console.log(`  \u2717 ${name}\n      ${detail}`);
}
function eq(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) ok(name, a);
  else bad(name, `期望 ${e}，实际 ${a}`);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function request(method, urlPath, body) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? null : JSON.stringify(body);
    const req = http.request(
      { host: '127.0.0.1', port: PORT, path: urlPath, method,
        headers: payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {} },
      (res) => {
        let data = '';
        res.on('data', (c) => { data += c; });
        res.on('end', () => {
          let json = null;
          try { json = JSON.parse(data); } catch { /* 非 JSON 保持 null */ }
          resolve({ status: res.statusCode, headers: res.headers, raw: data, json });
        });
      }
    );
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function main() {
  console.log('== 协议联动测试（伪造 WPS 加载项）==');
  console.log(`   服务端模块: ${SERVER_JS}`);

  if (!fs.existsSync(SERVER_JS)) {
    console.error('\n✗ 找不到编译产物，请先在 wps-office-mcp 下执行 npx tsc');
    process.exit(1);
  }

  const mod = await import('file://' + SERVER_JS.replace(/\\/g, '/'));
  const server = mod.macPollServer;
  if (!server) {
    console.error('✗ 模块未导出 macPollServer');
    process.exit(1);
  }

  await server.start(PORT);
  console.log(`   已监听 127.0.0.1:${PORT}\n`);

  // ---------- 1. 空队列轮询 ----------
  console.log('[1] 空队列');
  let r = await request('GET', '/poll');
  eq('GET /poll 无命令时返回 {}', r.json, {});

  // ---------- 2. 状态接口 ----------
  console.log('\n[2] /status');
  r = await request('GET', '/status');
  if (r.status === 200 && r.json && r.json.status === 'running') ok('GET /status 返回 running');
  else bad('GET /status', `status=${r.status} body=${r.raw}`);
  eq('/status 初始无挂起命令', r.json && r.json.hasPendingCommand, false);

  // ---------- 3. 投递 -> 取走 -> 回执 ----------
  console.log('\n[3] 完整往返');
  // 用不在 COMMAND_APP_MAP 里的 action，避免触发 switchApp（那会去跑 wps-auto.sh）
  const pending = server.executeCommand('ping', { hello: 'hermes' }, 5000);

  await sleep(50);
  r = await request('GET', '/poll');
  const cmd = r.json && r.json.command;
  if (cmd && cmd.action === 'ping' && typeof cmd.requestId === 'string') {
    ok('GET /poll 取到命令', `action=${cmd.action} requestId=${cmd.requestId}`);
  } else {
    bad('GET /poll 取到命令', `body=${r.raw}`);
  }
  eq('params 原样透传', cmd && cmd.params, { hello: 'hermes' });

  // 同一时刻再取一次：命令已投递，但未回执前允许重复取（加载项可能丢包重试）
  // 这里只断言不崩、且 requestId 稳定
  const r2 = await request('GET', '/poll');
  const cmd2 = r2.json && r2.json.command;
  eq('重复 poll 的 requestId 稳定', cmd2 && cmd2.requestId, cmd && cmd.requestId);

  r = await request('POST', '/result', {
    requestId: cmd.requestId,
    result: { success: true, data: { pong: 1 } },
  });
  eq('POST /result 应答 ok', r.json, { ok: true });

  const got = await pending;
  eq('executeCommand 拿到结果', got, { success: true, data: { pong: 1 } });

  // ---------- 4. 回执后队列清空 ----------
  console.log('\n[4] 回执后清空');
  r = await request('GET', '/poll');
  eq('回执后 /poll 返回 {}', r.json, {});
  r = await request('GET', '/status');
  eq('回执后 hasPendingCommand=false', r.json && r.json.hasPendingCommand, false);

  // ---------- 5. 错误 requestId 被忽略 ----------
  console.log('\n[5] 错误回执');
  const p2 = server.executeCommand('ping', {}, 3000);
  await sleep(50);
  const r3 = await request('GET', '/poll');
  const id2 = r3.json.command.requestId;
  r = await request('POST', '/result', { requestId: 'not-exist', result: { success: true } });
  eq('未知 requestId 仍应答 ok', r.json, { ok: true });
  // 正确的回执照常生效
  r = await request('POST', '/result', { requestId: id2, result: { success: true, data: 2 } });
  eq('随后正确回执生效', await p2, { success: true, data: 2 });

  // ---------- 6. 超时 ----------
  console.log('\n[6] 超时');
  let timedOut = false;
  try {
    await server.executeCommand('ping', {}, 250);
  } catch (e) {
    timedOut = /timeout/i.test(String(e && e.message));
  }
  if (timedOut) ok('无回执时按超时拒绝');
  else bad('无回执时按超时拒绝', '未抛出 timeout 错误');
  r = await request('GET', '/status');
  eq('超时后挂起命令被清理', r.json && r.json.hasPendingCommand, false);

  // ---------- 7. CORS 预检 ----------
  console.log('\n[7] CORS');
  r = await request('OPTIONS', '/poll');
  if (r.status === 200 && r.headers['access-control-allow-origin'] === '*') {
    ok('OPTIONS 预检通过', `allow-origin=${r.headers['access-control-allow-origin']}`);
  } else {
    bad('OPTIONS 预检', `status=${r.status} allow-origin=${r.headers['access-control-allow-origin']}`);
  }

  // ---------- 8. 未知路由 ----------
  console.log('\n[8] 404');
  r = await request('GET', '/nope');
  eq('未知路由 404', r.status, 404);

  // ---------- 汇总 ----------
  console.log(`\n== 结果: ${pass} 通过 / ${fail} 失败 ==`);
  if (fail) {
    console.log('\n失败项：');
    failures.forEach((f) => console.log('  - ' + f));
    process.exit(1);
  }
  process.exit(0);
}

main().catch((e) => {
  console.error('\n✗ 测试异常:', e);
  process.exit(1);
});

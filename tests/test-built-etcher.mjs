// Exercise the packaged native helper with image bytes, without opening devices.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { gzipSync } from 'node:zlib';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const [build, manifest] = process.argv.slice(2);
assert.ok(build && manifest, 'usage: node tests/test-built-etcher.mjs <build> <manifest>');
// Exercise the real runtime command with Node's socket-backed subprocess I/O.
// Listing column names does not probe or open block devices.
const helperEnv = { PATH: process.env.PATH, HOME: os.homedir(), LANG: 'C.UTF-8',
  ...(process.env.FLATPAK_USER_DIR ? { FLATPAK_USER_DIR: process.env.FLATPAK_USER_DIR } : {}) };
const checkScanner = `
const assert = require('node:assert/strict');
const run = require('node:util').promisify(require('node:child_process').execFile);
(async () => {
  const { stdout, stderr } = await run('/app/bin/lsblk', ['--list-columns', '--json']);
  assert.ok(JSON.parse(stdout)['lsblk-columns'].some(column => column.holder === 'NAME'));
  assert.equal(stderr, '');
  await assert.rejects(run('/app/bin/lsblk', ['--etcher-invalid-option']), error => {
    assert.equal(error.code, 1);
    assert.match(error.stderr, /unrecognized option/);
    return true;
  });
})().catch(error => { console.error(error); process.exitCode = 1; });
`;
await promisify(execFile)('flatpak-builder', ['--run', '--env=PKG_EXECPATH=PKG_INVOKE_NODEJS',
  build, manifest, '/app/etcher/resources/etcher-util', '-e', checkScanner], { env: helperEnv });
console.log('Packaged scanner command captures JSON and preserves invalid-option errors');
const work = await mkdtemp(path.join(os.tmpdir(), 'etcher-metadata-'));
const listener = net.createServer();
listener.listen(0, '127.0.0.1');
await once(listener, 'listening');
const port = listener.address().port;
await new Promise(resolve => listener.close(resolve));
const image = Buffer.alloc(16 * 1024 * 1024);
image[510] = 0x55;
image[511] = 0xaa;
await writeFile(path.join(work, 'image with spaces.img'), image);
await writeFile(path.join(work, 'image with spaces.img.gz'), gzipSync(image));
await writeFile(path.join(work, 'broken.img.gz'), gzipSync(image).subarray(0, 12));
const child = spawn('flatpak-builder', ['--run', `--filesystem=${work}:ro`, '--share=network', build, manifest,
  '/app/etcher/resources/etcher-util', `--ETCHER_SERVER_PORT=${port}`, '--ETCHER_SERVER_ADDRESS=127.0.0.1', '--ETCHER_TERMINATE_TIMEOUT=30000'], {
  stdio: 'ignore',
  // The upstream helper prints its environment; avoid passing CI credentials.
  env: helperEnv,
});
let socket;
try {
  for (let attempt = 0; attempt < 100; attempt++) {
    const candidate = new WebSocket(`ws://127.0.0.1:${port}`);
    const connected = await new Promise(resolve => {
      candidate.onopen = () => resolve(true);
      candidate.onerror = () => resolve(false);
    });
    if (connected) { socket = candidate; break; }
    assert.equal(child.exitCode, null, 'packaged helper exited before accepting requests');
    await delay(100);
  }
  assert.ok(socket, 'packaged helper did not start');
  socket.send(JSON.stringify({ type: 'ready', payload: {} }));
  for (const name of ['image with spaces.img', 'image with spaces.img.gz', 'broken.img.gz', 'missing.img']) {
    const response = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('metadata request timed out')), 10000);
      socket.onmessage = event => {
        const message = JSON.parse(event.data);
        if (message.type === 'sourceMetadata') { clearTimeout(timer); resolve(JSON.parse(message.payload)); }
      };
    });
    const selected = path.join(work, name);
    socket.send(JSON.stringify({ type: 'sourceMetadata', payload: JSON.stringify({ selected, SourceType: 'File' }) }));
    const metadata = await response;
    if (name.startsWith('image')) {
      assert.equal(metadata.path, selected);
      assert.equal(metadata.extension, name.endsWith('gz') ? 'gz' : 'img');
      assert.equal(metadata.size, image.length);
      assert.equal(metadata.hasMBR, true);
    } else {
      assert.deepEqual(metadata, {}, 'unreadable files must exercise the renderer rejection path');
    }
  }
  console.log('Packaged Etcher reads raw/gzip images and rejects corrupt/missing images');
} finally {
  const exited = once(child, 'exit');
  if (socket?.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({ type: 'terminate', payload: {} }));
  }
  await Promise.race([exited, delay(2000)]);
  socket?.close();
  if (child.exitCode === null) {
    child.kill('SIGTERM');
    await Promise.race([exited, delay(2000)]);
  }
  if (child.exitCode === null) child.kill('SIGKILL');
  await rm(work, { recursive: true, force: true });
}

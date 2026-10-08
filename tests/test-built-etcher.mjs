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

const [build, manifest] = process.argv.slice(2);
assert.ok(build && manifest, 'usage: node tests/test-built-etcher.mjs <build> <manifest>');
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
  env: { PATH: process.env.PATH, HOME: os.homedir(), LANG: 'C.UTF-8',
    ...(process.env.FLATPAK_USER_DIR ? { FLATPAK_USER_DIR: process.env.FLATPAK_USER_DIR } : {}) },
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
  socket?.close();
  child.kill('SIGTERM');
  await Promise.race([once(child, 'exit'), delay(2000)]);
  if (child.exitCode === null) child.kill('SIGKILL');
  await rm(work, { recursive: true, force: true });
}

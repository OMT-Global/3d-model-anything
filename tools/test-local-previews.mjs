import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, cp, symlink, readdir, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build, createServer } from 'vite';
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const fixture = await mkdtemp(join(tmpdir(), 'local-preview-test-'));
const marker = 'SYNTHETIC_PRIVATE_PREVIEW_CANARY_73e6';
const privateName = 'synthetic-private-asset-73e6.glb';
let server;
const originalFetch = globalThis.fetch;
const originalLoad = GLTFLoader.prototype.loadAsync;
try {
  // Copy only Git-visible source/public files. Ignored real captures never enter the fixture.
  const files = execFileSync('git', ['ls-files', '-z'], { cwd: root }).toString().split('\0').filter(Boolean);
  for (const file of files) {
    try { await cp(join(root, file), join(fixture, file), { recursive: true }); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  await symlink(join(root, 'node_modules'), join(fixture, 'node_modules'), 'dir');
  const manifest = join(fixture, 'data/scans/local-preview/manifest.json');
  await mkdir(dirname(manifest), { recursive: true });
  await writeFile(manifest, JSON.stringify([{ id: marker, label: marker, mesh: '/local-scans/' + privateName, measurements: '/synthetic-room.json', note: marker }]));
  const asset = join(fixture, 'data/web-assets/local-scans', privateName);
  await mkdir(dirname(asset), { recursive: true }); await writeFile(asset, marker);
  // Unreviewed files outside the reserved directory must also stay out of production.
  await writeFile(join(fixture, 'data/web-assets/synthetic-private-sidecar.txt'), marker);
  const configFile = join(fixture, 'apps/room-viewer/vite.config.ts');
  server = await createServer({ configFile, server: { middlewareMode: true }, logLevel: 'error' });
  const policy = await server.ssrLoadModule('/src/preview-policy.ts');
  for (const mode of ['walk', 'knolling']) assert.equal(policy.viewerModeForRoom(true, mode), 'orbit');
  for (const mode of ['orbit', 'layout']) assert.equal(policy.viewerModeForRoom(true, mode), mode);
  const rooms = [{ id: 'office' }, { id: 'raw', previewOnly: true }];
  for (const id of ['raw', null, 'unknown']) assert.equal(policy.playgroundRoom(rooms, id).id, 'office');
  assert.equal(policy.viewerModeForRoom(false, 'knolling'), 'knolling');
  const texture = new THREE.Texture();
  GLTFLoader.prototype.loadAsync = async () => {
    const scene = new THREE.Group(), parent = new THREE.Group(); parent.position.x = 3;
    const geometry = new THREE.BoxGeometry(1, 2, 1);
    parent.add(new THREE.Mesh(geometry, new THREE.MeshStandardMaterial({ color: '#aa8844', map: texture })));
    scene.add(parent); return { scene };
  };
  let measurements = { walls: [], polygon: [], objects: [] };
  globalThis.fetch = async () => ({ ok: true, json: async () => measurements });
  const { localScans } = await server.ssrLoadModule('/src/local-scans.ts');
  assert.equal(localScans[0].id, marker, 'dev manifest remains available');
  const scan = await localScans[0].build();
  assert.ok(Number.isFinite(scan.wallTop));
  assert.ok(scan.camera.orbit.every(Number.isFinite));
  assert.equal(scan.ceiling.length, 0, 'no guessed ceiling for empty walls');
  const mesh = scan.group.children[0];
  assert.equal(mesh.material[0].vertexColors, false);
  assert.equal(mesh.material[0].map, texture);
  assert.ok(mesh.geometry.groups.every(draw => draw.materialIndex === 0), 'single-material mesh groups remain valid');
  assert.ok(new THREE.Box3().setFromObject(scan.group).min.x > 2, 'nested node transform retained');
  measurements = { walls: [{ height: 1 }], polygon: [], objects: [] };
  const cutaway = await localScans[0].build();
  assert.equal(cutaway.ceiling.length, 1);
  assert.equal(cutaway.group.children[0].geometry.getAttribute('position'),
    cutaway.group.children[1].geometry.getAttribute('position'), 'cutaway shares transformed attributes');
  await server.close(); server = undefined;
  globalThis.fetch = originalFetch; GLTFLoader.prototype.loadAsync = originalLoad;
  // Malformed private metadata proves production never reads/parses it.
  await writeFile(manifest, marker + '{invalid json');
  await build({ configFile, logLevel: 'error' });
  const dist = join(fixture, 'apps/room-viewer/dist');
  let outputFiles = 0;
  async function inspect(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      assert.ok(!entry.name.includes('synthetic-private') && entry.name !== 'local-scans', 'private output filename');
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await inspect(path);
      else { outputFiles++; assert.ok(!(await readFile(path)).includes(Buffer.from(marker)), 'private output content'); }
    }
  }
  await inspect(dist);
  await readFile(join(dist, 'index.html'));
  const publicAssets = JSON.parse(await readFile(join(root, 'docs/public-assets.json'), 'utf8'));
  const publicFile = Object.keys(publicAssets).find(name => name.startsWith('data/web-assets/'));
  await readFile(join(dist, publicFile.slice('data/web-assets/'.length)));
  console.log(`PASS: dev scan, URL/mode policy, empty-wall bounds, texture fallback, nested transforms; ${outputFiles} production files contain no private canary filenames/content.`);
} finally {
  globalThis.fetch = originalFetch; GLTFLoader.prototype.loadAsync = originalLoad;
  if (server) await server.close();
  // This directory contains only the disposable synthetic fixture, never real captures.
  await rm(fixture, { recursive: true, force: true });
}

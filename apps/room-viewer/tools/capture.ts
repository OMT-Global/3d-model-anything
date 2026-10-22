import '../src/asset-base';
// Measuring / comparison renders of a room's reference (scan) and the rebuilt model.
// /tools/capture.html?room=<id>&src=scan|model&...
//   view=top|up|n|s|e|w&ppm=200&cut=<m>   orthographic plan/elevation with a meter grid
//   cam=x,y,z&look=x,y,z&fov=50&size=WxH   perspective
//   photo=N&size=W                          the exact camera of posed photo N (House Capture rooms)
import * as THREE from 'three';
import { roomById } from '../../../demos/index';
import { configureRenderer } from '../../../packages/room-runtime/lighting';
import { applyRoomRendering, createPipeline } from '../../../packages/room-runtime/render';

// A comparison is a snapshot. Room edits must not reset its canvas while the
// capture script is measuring/screenshotting it; the next navigation builds afresh.
if (import.meta.hot) import.meta.hot.accept('../../../demos/index', () => {});

const params = new URLSearchParams(location.search);
const view = params.get('view') ?? 'top';
let src = params.get('src') ?? 'scan';
const ppm = Number(params.get('ppm') ?? 200);
const pad = 0.25;

const room = await roomById(params.get('room')).build();
if (room.referenceAvailable === false && src === 'scan') src = 'model';

// room bounds from its walls
const bb = new THREE.Box2();
for (const { def } of room.walls) {
  bb.expandByPoint(new THREE.Vector2(def.origin.x, def.origin.z));
  const end = def.origin.clone().addScaledVector(def.u, def.length);
  bb.expandByPoint(new THREE.Vector2(end.x, end.z));
}

type Axis = 'x' | 'y' | 'z';
interface ViewDef {
  dir: THREE.Vector3; // camera look direction
  up: THREE.Vector3;
  h: [Axis, number, number, number]; // axis, min, max, sign (screen right = +sign)
  v: [Axis, number, number, number]; // axis, min, max, sign (screen up = +sign)
  cut: number;
}
if (bb.isEmpty()) {
  const bounds = new THREE.Box3().setFromObject(room.group);
  if (!bounds.isEmpty()) {
    bb.expandByPoint(new THREE.Vector2(bounds.min.x, bounds.min.z));
    bb.expandByPoint(new THREE.Vector2(bounds.max.x, bounds.max.z));
  } else { bb.expandByPoint(new THREE.Vector2(-1, -1)); bb.expandByPoint(new THREE.Vector2(1, 1)); }
}
const X: [number, number] = [bb.min.x - pad, bb.max.x + pad];
const Z: [number, number] = [bb.min.y - pad, bb.max.y + pad];
const Y: [number, number] = [-0.1, room.wallTop + 0.45];
const views: Record<string, ViewDef> = {
  top: { dir: new THREE.Vector3(0, -1, 0), up: new THREE.Vector3(0, 0, -1), h: ['x', ...X, 1], v: ['z', ...Z, -1], cut: room.wallTop - 0.05 },
  n: { dir: new THREE.Vector3(0, 0, -1), up: new THREE.Vector3(0, 1, 0), h: ['x', ...X, 1], v: ['y', ...Y, 1], cut: bb.max.y - 0.1 },
  s: { dir: new THREE.Vector3(0, 0, 1), up: new THREE.Vector3(0, 1, 0), h: ['x', ...X, -1], v: ['y', ...Y, 1], cut: bb.min.y + 0.1 },
  e: { dir: new THREE.Vector3(1, 0, 0), up: new THREE.Vector3(0, 1, 0), h: ['z', ...Z, 1], v: ['y', ...Y, 1], cut: bb.min.x + 0.1 },
  w: { dir: new THREE.Vector3(-1, 0, 0), up: new THREE.Vector3(0, 1, 0), h: ['z', ...Z, -1], v: ['y', ...Y, 1], cut: bb.max.x - 0.1 },
  up: { dir: new THREE.Vector3(0, 1, 0), up: new THREE.Vector3(0, 0, 1), h: ['x', ...X, 1], v: ['z', ...Z, 1], cut: 1.0 },
};
const def = views[view];
const cut = params.has('cut') ? Number(params.get('cut')) : def.cut;
const [hAxis, hMin, hMax, hSign] = def.h;
const [vAxis, vMin, vMax, vSign] = def.v;

const photo = params.has('photo') ? room.photos?.[Number(params.get('photo'))] : undefined;
const persp = params.get('cam');
let W: number, H: number;
if (photo) {
  W = Number(params.get('size') ?? 720);
  H = Math.round(W / photo.aspect);
} else if (persp) {
  [W, H] = (params.get('size') ?? '1200x800').split('x').map(Number);
} else {
  [W, H] = [Math.round((hMax - hMin) * ppm), Math.round((vMax - vMin) * ppm)];
}

const canvas = document.querySelector<HTMLCanvasElement>('#scene')!;
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(1);
renderer.setSize(W, H);

const scene = new THREE.Scene();
scene.background = new THREE.Color('#000');

let camera: THREE.Camera;
if (photo) {
  const cam = new THREE.PerspectiveCamera(photo.fovY, photo.aspect, 0.02, 50);
  const pos = new THREE.Vector3(...photo.position);
  cam.position.copy(pos);
  cam.up.set(photo.up[0], photo.up[1], photo.up[2]);
  cam.lookAt(pos.clone().add(new THREE.Vector3(...photo.forward)));
  camera = cam;
} else if (persp) {
  const vec = (s: string) => new THREE.Vector3(...s.split(',').map(Number));
  const cam = new THREE.PerspectiveCamera(Number(params.get('fov') ?? 50), W / H, 0.02, 50);
  cam.position.copy(vec(persp));
  cam.lookAt(vec(params.get('look') ?? '0,1,0'));
  camera = cam;
} else {
  const cam = new THREE.OrthographicCamera(-W / ppm / 2, W / ppm / 2, H / ppm / 2, -H / ppm / 2, 0, 20);
  const center = new THREE.Vector3();
  center[hAxis] = (hMin + hMax) / 2;
  center[vAxis] = (vMin + vMax) / 2;
  const viewAxis: Axis = def.dir.x ? 'x' : def.dir.y ? 'y' : 'z';
  center[viewAxis] = cut;
  cam.position.copy(center);
  cam.up.copy(def.up);
  cam.lookAt(center.clone().add(def.dir));
  camera = cam;
}

let drawFrame: () => void;
if (src === 'scan') {
  drawFrame = () => renderer.render(scene, camera);
  scene.add(await room.loadReference());
  renderer.render(scene, camera);
} else {
  configureRenderer(renderer, scene);
  scene.add(room.group, room.lights);
  const pipe = createPipeline(renderer, scene, camera);
  room.optimize?.({ static: true });
  applyRoomRendering(renderer, scene, room, pipe, { bloom: !params.has('nobloom') });
  const draw = () => (params.has('noao') ? renderer.render(scene, camera) : pipe.render());
  drawFrame = draw;
  draw();
  // The first frame after a (re)load is sometimes all black (shader compiles racing a busy GPU,
  // or a context hiccup): check a grid of pixels and redraw until something is lit.
  const gl = renderer.getContext();
  const px = new Uint8Array(4);
  const lit = () => {
    for (let i = 1; i < 6; i++) for (let j = 1; j < 6; j++) {
      gl.readPixels(Math.floor((W * i) / 6), Math.floor((H * j) / 6), 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
      if (px[0] + px[1] + px[2] > 12) return true;
    }
    return false;
  };
  for (let k = 0; k < 6 && !lit(); k++) {
    await new Promise((r) => setTimeout(r, 250));
    renderer.shadowMap.needsUpdate = true;
    draw();
  }
  if (params.has('stats')) {
    // steady-state frame cost (shadow maps are static, so they're not part of it)
    renderer.info.autoReset = false;
    renderer.info.reset();
    draw();
    gl.finish();
    const calls = renderer.info.render.calls, triangles = renderer.info.render.triangles;
    const times: number[] = [];
    for (let k = 0; k < 15; k++) {
      const t = performance.now();
      draw();
      gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
      times.push(performance.now() - t);
    }
    times.sort((a, b) => a - b);
    let meshes = 0;
    scene.traverseVisible((o) => { if ((o as THREE.Mesh).isMesh) meshes++; });
    document.body.dataset.stats = JSON.stringify({ calls, triangles, meshes, programs: renderer.info.programs?.length, msMin: +times[0].toFixed(1), msMedian: +times[7].toFixed(1) });
    renderer.info.autoReset = true;
  }
}

// --- grid overlay (orthographic views only) ---------------------------------------
const grid = document.querySelector<HTMLCanvasElement>('#grid')!;
grid.width = W;
grid.height = H;
const ctx = grid.getContext('2d')!;
const toPxH = (c: number) => (hSign > 0 ? c - hMin : hMax - c) * ppm;
const toPxV = (c: number) => (vSign > 0 ? vMax - c : c - vMin) * ppm;
ctx.font = '12px monospace';
for (let c = Math.ceil(hMin * 4) / 4; c <= hMax; c += 0.25) {
  const major = Math.abs(c - Math.round(c)) < 1e-6;
  const half = Math.abs(c * 2 - Math.round(c * 2)) < 1e-6;
  ctx.strokeStyle = major ? 'rgba(0,200,255,0.8)' : half ? 'rgba(0,200,255,0.45)' : 'rgba(0,200,255,0.2)';
  const x = toPxH(c);
  ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, H); ctx.stroke();
  if (half) { ctx.fillStyle = '#0ff'; ctx.fillText(`${hAxis}${c.toFixed(1)}`, x + 2, 12); }
}
for (let c = Math.ceil(vMin * 4) / 4; c <= vMax; c += 0.25) {
  const major = Math.abs(c - Math.round(c)) < 1e-6;
  const half = Math.abs(c * 2 - Math.round(c * 2)) < 1e-6;
  ctx.strokeStyle = major ? 'rgba(255,200,0,0.8)' : half ? 'rgba(255,200,0,0.45)' : 'rgba(255,200,0,0.2)';
  const y = toPxV(c);
  ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke();
  if (half) { ctx.fillStyle = '#ff0'; ctx.fillText(`${vAxis}${c.toFixed(1)}`, 2, y - 2); }
}
if (params.has('nogrid') || persp || photo) grid.style.display = 'none';
if (import.meta.env.DEV) Object.assign(window, { __cap: { renderer, scene, room, camera,
  renderPhoto(index: number) {
    const p = room.photos?.[index];
    if (!p || !(camera instanceof THREE.PerspectiveCamera)) throw new Error('Photo camera unavailable');
    camera.position.fromArray(p.position); camera.up.fromArray(p.up);
    camera.lookAt(camera.position.clone().add(new THREE.Vector3(...p.forward)));
    camera.fov = p.fovY; camera.aspect = p.aspect; camera.updateProjectionMatrix();
    for (const wall of room.walls) wall.group.visible = true;
    for (const ceiling of room.ceiling) ceiling.visible = true;
    drawFrame();
    return canvas.toDataURL('image/jpeg', .97).split(',')[1];
  }
} });
document.body.dataset.ready = '1';

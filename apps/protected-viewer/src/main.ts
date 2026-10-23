import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import './style.css';

interface RoomObject { id: string; label: string; kind: 'box'; position: [number, number, number]; size: [number, number, number]; color: string }
interface Revision { id: string; origin: string; document: { format: 'editable-room/1'; label: string; objects: RoomObject[] } }
const status = document.querySelector<HTMLElement>('#status')!;
const container = document.querySelector<HTMLElement>('#scene')!;
async function load() {
  const room = new URL(location.href).searchParams.get('room') ?? '';
  if (!/^[A-Za-z0-9_-]{1,100}$/.test(room)) throw new Error('Open a room link from your private Site.');
  const response = await fetch(`/v1/rooms/${encodeURIComponent(room)}/published`, { credentials: 'same-origin', cache: 'no-store' });
  if (!response.ok) throw new Error(response.status === 401 ? 'Sign in to view this room.' : 'No approved room is available for this account.');
  const revision: Revision = await response.json();
  if (revision.document.format !== 'editable-room/1') throw new Error('This room format is not supported.');
  document.querySelector('#title')!.textContent = revision.document.label;
  status.textContent = revision.origin === 'synthetic' ? 'SYNTHETIC DEMO · local publication only' : 'Private · approved model';
  document.querySelector('#revision')!.textContent = `Revision ${revision.id.slice(0, 8)}`;
  const scene = new THREE.Scene(); scene.background = new THREE.Color('#f3eee5');
  scene.add(new THREE.HemisphereLight(0xffffff, 0x988775, 3));
  const light = new THREE.DirectionalLight(0xffffff, 3); light.position.set(4, 8, 5); scene.add(light);
  for (const object of revision.document.objects) {
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(...object.size), new THREE.MeshStandardMaterial({ color: object.color, roughness: .75 }));
    mesh.position.set(...object.position); scene.add(mesh);
    const item = document.createElement('li'); item.textContent = object.label; document.querySelector('#objects')!.append(item);
  }
  const camera = new THREE.PerspectiveCamera(40, 1, .01, 500);
  const box = new THREE.Box3().setFromObject(scene); const center = box.getCenter(new THREE.Vector3());
  const extent = Math.max(...box.getSize(new THREE.Vector3()).toArray(), 1);
  camera.position.copy(center).add(new THREE.Vector3(extent * 1.4, extent * 1.1, extent * 1.6));
  const renderer = new THREE.WebGLRenderer({ antialias: true }); renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  container.append(renderer.domElement);
  const controls = new OrbitControls(camera, renderer.domElement); controls.target.copy(center); controls.update();
  const render = () => renderer.render(scene, camera);
  controls.addEventListener('change', render);
  new ResizeObserver(() => { camera.aspect = container.clientWidth / container.clientHeight; camera.updateProjectionMatrix(); renderer.setSize(container.clientWidth, container.clientHeight); render(); }).observe(container);
  render();
}
load().catch(error => { status.textContent = error.message; });

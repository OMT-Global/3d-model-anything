import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import type { BuiltRoom, RoomLayout, RoomModule } from '../packages/room-runtime/types';

type Entry = { id: string; label: string; mesh: string; measurements: string; note: string };
// Personal room names and asset paths live only in an ignored local manifest.
const manifests = import.meta.glob('../data/scans/local-preview/manifest.json', { eager: true, import: 'default' });
const entries = Object.values(manifests).flatMap(value => value as Entry[]);
export const localScans: RoomModule[] = entries.map(entry => ({
  id: entry.id, label: entry.label,
  async build(): Promise<BuiltRoom> {
    const response = await fetch(entry.measurements);
    if (!response.ok) throw new Error(`Scan measurements: HTTP ${response.status}`);
    const data = await response.json();
    const gltf = await new GLTFLoader().loadAsync(entry.mesh);
    const group = new THREE.Group(), ceiling: THREE.Object3D[] = [];
    const wallTop = Math.max(...data.walls.map((wall: { height?: number; h?: number }) => wall.height ?? wall.h ?? 2.5));
    gltf.scene.updateMatrixWorld(true);
    gltf.scene.traverse(object => {
      if (!(object instanceof THREE.Mesh)) return;
      const geometry = object.geometry.clone();
      geometry.applyMatrix4(object.matrixWorld);
      const position = geometry.getAttribute('position');
      const index = geometry.index;
      const body: number[] = [], roof: number[] = [];
      for (let i = 0; i < (index?.count ?? position.count); i += 3) {
        const ids = [0, 1, 2].map(j => index ? index.getX(i + j) : i + j);
        const target = ids.every(j => position.getY(j) > wallTop - .18) ? roof : body;
        target.push(...ids);
      }
      const material = new THREE.MeshBasicMaterial({ vertexColors: true, side: THREE.FrontSide, toneMapped: false });
      for (const [indices, isRoof] of [[body, false], [roof, true]] as const) {
        const part = geometry.clone(); part.setIndex(indices);
        const mesh = new THREE.Mesh(part, material); group.add(mesh);
        if (isRoof) ceiling.push(mesh);
      }
    });
    const xs = data.polygon.map((p: number[]) => p[0]), zs = data.polygon.map((p: number[]) => p[1]);
    const span = Math.max(Math.max(...xs) - Math.min(...xs), Math.max(...zs) - Math.min(...zs), 2);
    const layout: RoomLayout = { polygon: data.polygon, walls: data.walls, objects: data.objects, note: entry.note };
    return {
      group, lights: new THREE.Group(), walls: [], ceiling, wallTop,
      layout, previewNote: 'Raw LiDAR + photo colors · work in progress. Holes and gray areas are incomplete capture coverage. Rooms are shown separately, without house placement.',
      render: { toneMapping: THREE.NoToneMapping, ao: { intensity: 0 }, envSize: 16, envBounces: 0 },
      environment: { center: [0, 1.4, 0], intensity: 0 },
      camera: { orbit: [span * 1.1, Math.max(wallTop + 1, span * 1.2), span * 1.1], target: [0, .8, 0], walk: [0, 1.6, 0], walkLook: [0, 1.6, -1] },
      walkable: () => false,
      referenceAvailable: false, referenceKind: 'scan',
      loadReference: async () => new THREE.Group(),
    };
  },
}));

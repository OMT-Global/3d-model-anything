import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import type { BuiltRoom, RoomLayout, RoomModule } from '../../../packages/room-runtime/types';

type Entry = { id: string; label: string; mesh: string; measurements: string; note: string; module?: string };
// The Vite plugin exposes private metadata only to the localhost dev server.
import entries from 'virtual:local-scans';
export const localScans: RoomModule[] = (entries as Entry[]).map(entry => ({
  id: entry.id, label: entry.label, previewOnly: true,
  async build(): Promise<BuiltRoom> {
    if (entry.module) {
      if (!import.meta.env.DEV) throw new Error('Local scene modules are development-only');
      if (!entry.module.startsWith('/@fs/')) throw new Error('Local scene modules require an absolute local file URL');
      return (await import(/* @vite-ignore */ entry.module)).build();
    }
    const response = await fetch(entry.measurements);
    if (!response.ok) throw new Error(`Scan measurements: HTTP ${response.status}`);
    const data = await response.json();
    const gltf = await new GLTFLoader().loadAsync(entry.mesh);
    const group = new THREE.Group(), ceiling: THREE.Object3D[] = [];
    const heights = data.walls.map((wall: { height?: number; h?: number }) => wall.height ?? wall.h).filter((height: number) => Number.isFinite(height) && height > 0);
    let wallTop = heights.length ? Math.max(...heights) : 2.5;
    gltf.scene.updateMatrixWorld(true);
    gltf.scene.traverse(object => {
      if (!(object instanceof THREE.Mesh)) return;
      const geometry = object.geometry.clone();
      geometry.applyMatrix4(object.matrixWorld);
      const position = geometry.getAttribute('position');
      const index = geometry.index;
      // Share transformed attributes between cutaway parts; only indices differ.
      const parts = [new THREE.BufferGeometry(), new THREE.BufferGeometry()];
      for (const part of parts) {
        for (const name of Object.keys(geometry.attributes)) part.setAttribute(name, geometry.getAttribute(name));
      }
      const originals = Array.isArray(object.material) ? object.material : [object.material];
      const materials = originals.map(original => {
        const source = original as THREE.MeshStandardMaterial;
        return new THREE.MeshBasicMaterial({ color: source.color ?? 0xcccccc, map: source.map ?? null,
          vertexColors: geometry.hasAttribute('color'), side: THREE.FrontSide, toneMapped: false,
          transparent: original.transparent, opacity: original.opacity, alphaTest: original.alphaTest });
      });
      const indices: number[][] = [[], []];
      const groups = geometry.groups.length ? geometry.groups : [{ start: 0, count: index?.count ?? position.count, materialIndex: 0 }];
      for (const draw of groups) {
        const starts = indices.map(part => part.length);
        for (let i = draw.start; i < draw.start + draw.count; i += 3) {
          const ids = [0, 1, 2].map(j => index ? index.getX(i + j) : i + j);
          const roof = heights.length > 0 && ids.every(j => position.getY(j) > wallTop - .18);
          indices[roof ? 1 : 0].push(...ids);
        }
        parts.forEach((part, i) => part.addGroup(starts[i], indices[i].length - starts[i], Array.isArray(object.material) ? draw.materialIndex ?? 0 : 0));
      }
      parts.forEach((part, i) => {
        if (!indices[i].length) return;
        part.setIndex(indices[i]);
        const mesh = new THREE.Mesh(part, materials); group.add(mesh);
        if (i === 1) ceiling.push(mesh);
      });
    });
    const xs = data.polygon.map((p: number[]) => p[0]), zs = data.polygon.map((p: number[]) => p[1]);
    const bounds = new THREE.Box3().setFromObject(group);
    const size = bounds.isEmpty() ? new THREE.Vector3(2, 2.5, 2) : bounds.getSize(new THREE.Vector3());
    if (!heights.length && Number.isFinite(size.y) && size.y > 0) wallTop = Math.max(size.y, 1);
    const span = Math.max(xs.length ? Math.max(...xs) - Math.min(...xs) : size.x,
      zs.length ? Math.max(...zs) - Math.min(...zs) : size.z, 2);
    const layout: RoomLayout | undefined = data.polygon.length >= 3 ? { polygon: data.polygon, walls: data.walls, objects: data.objects, note: entry.note } : undefined;
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

import { resolve, relative } from 'node:path';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { defineConfig } from 'vite';

const app = import.meta.dirname;
const repository = resolve(app, '../..');

export default defineConfig(({ command }) => ({
  plugins: [{
    name: 'local-scan-boundary',
    resolveId(id) { if (id === 'virtual:local-scans') return '\0virtual:local-scans'; },
    load(id) {
      if (id !== '\0virtual:local-scans') return;
      // Never read or transform private metadata during a production build.
      if (command === 'build') return 'export default []';
      const manifest = resolve(repository, 'data/scans/local-preview/manifest.json');
      this.addWatchFile(manifest);
      return `export default ${existsSync(manifest) ? JSON.stringify(JSON.parse(readFileSync(manifest, 'utf8'))) : '[]'}`;
    },
    generateBundle() {
      if (command !== 'build') return;
      // Only explicitly reviewed public assets may enter production output.
      const manifest = JSON.parse(readFileSync(resolve(repository, 'docs/public-assets.json'), 'utf8')) as Record<string, string>;
      const publicRoot = resolve(repository, 'data/web-assets');
      for (const [name, digest] of Object.entries(manifest)) {
        if (!name.startsWith('data/web-assets/')) continue;
        const path = resolve(repository, name);
        const fileName = relative(publicRoot, path).replaceAll('\\', '/');
        if (fileName.startsWith('../') || fileName === '..') throw new Error('Invalid public asset path');
        const source = readFileSync(path);
        if (createHash('sha256').update(source).digest('hex') !== digest) throw new Error(`Public asset changed: ${name}`);
        this.emitFile({ type: 'asset', fileName, source });
      }
    },
  }],
  root: app,
  base: process.env.VIEWER_BASE || '/',
  optimizeDeps: { include: ['three/addons/objects/Reflector.js'] },
  publicDir: command === 'serve' ? resolve(repository, 'data/web-assets') : false,
  server: {
    host: '127.0.0.1', port: 5188, strictPort: true, fs: { allow: [repository] },
    // Render evidence is output, not application source. Publishing a preview
    // image must not reload every viewer/capture in the middle of a build.
    watch: { ignored: ['**/data/captures/**', '**/data/recordings/**', '**/data/web-assets/office-v4/live/**'] },
  },
  build: {
    outDir: resolve(app, 'dist'),
    rolldownOptions: {
      input: {
        main: resolve(app, 'index.html'),
        play: resolve(app, 'play.html'),
        capture: resolve(app, 'tools/capture.html'),
      },
    },
  },
}));

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const VIDEO_PATH = '/Users/deveshpatel/Downloads/The new Mac mini with M6 - Apple (1080p, h264).mp4';
const OUT_DIR = path.resolve('ad/m6-mini/ref');
const FFMPEG = '/Users/deveshpatel/.local/bin/ffmpeg';

fs.mkdirSync(OUT_DIR, { recursive: true });

console.log('Detecting scene changes...');
const args = [
  '-i', VIDEO_PATH,
  '-filter_complex', `select='gt(scene,0.15)',metadata=print:file=${path.join(OUT_DIR, 'scenes.txt')}`,
  '-fps_mode', 'vfr',
  path.join(OUT_DIR, 'scene_%03d.jpg'),
  '-y'
];

const res = spawnSync(FFMPEG, args, { stdio: 'inherit' });
console.log('Scene detection finished with exit code:', res.status);


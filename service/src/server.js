import http from 'node:http';
import { spawn } from 'node:child_process';
import { createReadStream, createWriteStream, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const varDir = join(root, 'var');
const logDir = join(varDir, 'logs');
const stateFile = join(varDir, 'state.json');
const port = Number(process.env.PORT || 8787);
const running = new Map();

mkdirSync(logDir, { recursive: true });

function now() {
  return new Date().toISOString();
}

function loadState() {
  if (!existsSync(stateFile)) return { builds: [] };
  return JSON.parse(readFileSync(stateFile, 'utf8'));
}

function saveState(state) {
  mkdirSync(varDir, { recursive: true });
  writeFileSync(stateFile, JSON.stringify(state, null, 2));
}

function updateBuild(id, patch) {
  const state = loadState();
  const build = state.builds.find((item) => item.id === id);
  if (!build) return null;
  Object.assign(build, patch, { updatedAt: now() });
  saveState(state);
  return build;
}

function json(res, status, payload) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(payload, null, 2));
}

async function body(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function startPlatformBuild(build, platform) {
  const logPath = join(logDir, `${build.id}-${platform}.service.log`);
  const child = spawn(join(root, 'scripts', 'run-build.sh'), [platform, build.id], {
    cwd: root,
    env: { ...process.env, NG_SERVICE_BUILD_ID: build.id },
    stdio: ['ignore', 'pipe', 'pipe']
  });

  const logStream = createWriteStream(logPath, { flags: 'a' });
  child.stdout.pipe(logStream, { end: false });
  child.stderr.pipe(logStream, { end: false });

  running.set(`${build.id}:${platform}`, child);
  child.on('exit', (code, signal) => {
    running.delete(`${build.id}:${platform}`);
    logStream.end();
    const current = loadState();
    const stored = current.builds.find((item) => item.id === build.id);
    if (!stored) return;
    const target = stored.platforms.find((item) => item.name === platform);
    if (!target) return;
    target.status = code === 0 ? 'succeeded' : 'failed';
    target.exitCode = code;
    target.signal = signal;
    target.finishedAt = now();
    stored.status = stored.platforms.some((item) => item.status === 'running') ? 'running'
      : stored.platforms.every((item) => item.status === 'succeeded') ? 'succeeded'
      : 'failed';
    stored.updatedAt = now();
    saveState(current);
  });
}

function createBuild(platforms, meta = {}) {
  const id = `${new Date().toISOString().replace(/[-:.]/g, '').slice(0, 15)}-${Math.floor(Math.random() * 100000)}`;
  const build = {
    id,
    status: 'running',
    reason: meta.reason || '',
    createdAt: now(),
    updatedAt: now(),
    platforms: platforms.map((name) => ({
      name,
      status: 'running',
      log: join(logDir, `${id}-${name}.service.log`)
    })),
    request: meta
  };
  const state = loadState();
  state.builds.unshift(build);
  saveState(state);
  for (const platform of platforms) startPlatformBuild(build, platform);
  return build;
}

function getBuild(id) {
  return loadState().builds.find((build) => build.id === id);
}

function routeParts(url) {
  return new URL(url, `http://127.0.0.1:${port}`).pathname.split('/').filter(Boolean);
}

const server = http.createServer(async (req, res) => {
  try {
    const parts = routeParts(req.url);

    if (req.method === 'GET' && parts.length === 0) {
      return json(res, 200, {
        name: 'ng-webkit build service',
        endpoints: ['GET /builds', 'POST /builds', 'GET /builds/:id', 'POST /builds/:id/restart', 'POST /builds/:id/checkpoint', 'POST /builds/:id/cancel']
      });
    }

    if (req.method === 'GET' && parts[0] === 'builds' && parts.length === 1) {
      return json(res, 200, loadState().builds);
    }

    if (req.method === 'POST' && parts[0] === 'builds' && parts.length === 1) {
      const payload = await body(req);
      const platforms = payload.platforms || ['android', 'windows'];
      return json(res, 202, createBuild(platforms, payload));
    }

    if (parts[0] === 'builds' && parts[1]) {
      const build = getBuild(parts[1]);
      if (!build) return json(res, 404, { error: 'build not found' });

      if (req.method === 'GET' && parts.length === 2) return json(res, 200, build);

      if (req.method === 'GET' && parts[2] === 'logs' && parts[3]) {
        const platform = parts[3];
        const logPath = join(logDir, `${build.id}-${platform}.service.log`);
        if (!existsSync(logPath)) return json(res, 404, { error: 'log not found' });
        res.writeHead(200, { 'content-type': 'text/plain' });
        return createReadStream(logPath).pipe(res);
      }

      if (req.method === 'POST' && parts[2] === 'checkpoint') {
        const payload = await body(req);
        const checkpoint = { time: now(), message: payload.message || 'manual checkpoint' };
        const updated = updateBuild(build.id, { checkpoints: [...(build.checkpoints || []), checkpoint] });
        return json(res, 200, updated);
      }

      if (req.method === 'POST' && parts[2] === 'cancel') {
        for (const platform of build.platforms) {
          const child = running.get(`${build.id}:${platform.name}`);
          if (child) child.kill('SIGTERM');
          platform.status = platform.status === 'running' ? 'cancelled' : platform.status;
        }
        return json(res, 200, updateBuild(build.id, { status: 'cancelled', platforms: build.platforms }));
      }

      if (req.method === 'POST' && parts[2] === 'restart') {
        const payload = await body(req);
        const platforms = payload.platforms || build.platforms.map((platform) => platform.name);
        return json(res, 202, createBuild(platforms, { reason: `restart of ${build.id}`, restartedFrom: build.id, ...payload }));
      }
    }

    return json(res, 404, { error: 'not found' });
  } catch (error) {
    return json(res, 500, { error: error.message, stack: process.env.NODE_ENV === 'production' ? undefined : error.stack });
  }
});

server.listen(port, '0.0.0.0', () => {
  console.log(`ng-webkit build service listening on http://127.0.0.1:${port}`);
});

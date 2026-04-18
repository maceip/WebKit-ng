import http from 'node:http';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { closeSync, createReadStream, createWriteStream, existsSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const serviceDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dashboardPath = join(serviceDir, 'public', 'index.html');
const varDir = join(root, 'var');
const logDir = join(varDir, 'logs');
const stateFile = join(varDir, 'state.json');
const port = Number(process.env.PORT || 8787);
const running = new Map();
const execFileAsync = promisify(execFile);

mkdirSync(logDir, { recursive: true });

function loadDashboardHtml() {
  if (!existsSync(dashboardPath)) {
    return `<!DOCTYPE html><html><head><meta charset="utf-8"/><title>ng-webkit</title></head><body>
<p>Dashboard missing. Add <code>service/public/index.html</code> (see repo).</p>
<p><a href="/meta">API meta</a></p></body></html>`;
  }
  return readFileSync(dashboardPath, 'utf8');
}

const dashboardHtml = loadDashboardHtml();

function html(res, status, body) {
  res.writeHead(status, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store'
  });
  res.end(body);
}

class HttpError extends Error {
  constructor(statusCode, message) {
    super(message);
    this.statusCode = statusCode;
  }
}

function badRequest(message) {
  throw new HttpError(400, message);
}

function now() {
  return new Date().toISOString();
}

function loadState() {
  if (!existsSync(stateFile)) return { builds: [] };
  return JSON.parse(readFileSync(stateFile, 'utf8'));
}

function parseEnvFile(path) {
  if (!existsSync(path)) return {};
  const result = {};
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const match = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line);
    if (match) result[match[1]] = match[2];
  }
  return result;
}

function activeBuildsFromMarkerFiles() {
  const markers = [
    { platform: 'windows', path: join(varDir, 'WINDOWS_ACTIVE_BUILD.env'), idKey: 'WINDOWS_BUILD_ID' },
    { platform: 'macos', path: join(varDir, 'MACOS_ACTIVE_BUILD.env'), idKey: 'MACOS_BUILD_ID' }
  ];

  return markers.flatMap(({ platform, path, idKey }) => {
    const env = parseEnvFile(path);
    const id = env[idKey];
    if (!id) return [];
    const request = { env, platformEnv: { [platform]: env }, external: true };
    const inferred = inferExternalBuildStatusFromLog(id, platform);
    const logFile = existsSync(join(logDir, `${id}-${platform}.service.log`))
      ? join(logDir, `${id}-${platform}.service.log`)
      : join(logDir, `${id}-${platform}.log`);
    return [{
      id,
      status: inferred.status,
      reason: `external ${platform} build (marker file; ${inferred.detail})`,
      createdAt: null,
      updatedAt: now(),
      external: true,
      externalMarker: true,
      externalInference: inferred.detail,
      platforms: [{
        name: platform,
        status: inferred.status,
        external: true,
        externalInference: inferred.detail,
        log: logFile,
        artifactPrefix: artifactPrefixForPlatform(id, platform, request),
        workdir: env[`${platform.toUpperCase()}_BUILD_POLL_WORKDIR`],
        ssmCommandId: env[`${platform.toUpperCase()}_SSM_COMMAND_ID`]
      }],
      request
    }];
  });
}

function mergeMarkerBuildsById(markerBuilds) {
  const rank = (s) => ({ failed: 4, cancelled: 4, running: 3, unknown: 2, succeeded: 1 }[s] ?? 0);
  const pick = (a, b) => (rank(a) >= rank(b) ? a : b);
  const byId = new Map();
  for (const build of markerBuilds) {
    const prev = byId.get(build.id);
    if (!prev) {
      byId.set(build.id, { ...build, platforms: [...(build.platforms || [])] });
      continue;
    }
    prev.platforms = [...(prev.platforms || []), ...(build.platforms || [])];
    prev.status = pick(prev.status, build.status);
    prev.reason = [prev.reason, build.reason].filter(Boolean).join(' · ');
    prev.updatedAt = now();
  }
  return [...byId.values()];
}

function loadBuilds() {
  const state = loadState();
  const builds = [...(state.builds || [])];
  const known = new Set(builds.map((build) => build.id));
  for (const build of mergeMarkerBuildsById(activeBuildsFromMarkerFiles())) {
    if (!known.has(build.id)) builds.unshift(build);
  }
  return builds;
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
  res.writeHead(status, {
    'content-type': 'application/json',
    'cache-control': 'no-store',
    'access-control-allow-origin': '*'
  });
  res.end(JSON.stringify(payload, null, 2));
}

async function body(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    badRequest('request body must be valid JSON');
  }
}

function normalizeStringRecord(value, label) {
  if (value === undefined || value === null) return {};
  if (typeof value !== 'object' || Array.isArray(value)) {
    badRequest(`${label} must be an object of string keys and string/number/boolean values`);
  }

  const result = {};
  for (const [key, raw] of Object.entries(value)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      badRequest(`${label}.${key} is not a valid environment variable name`);
    }
    if (raw === undefined || raw === null) continue;
    if (!['string', 'number', 'boolean'].includes(typeof raw)) {
      badRequest(`${label}.${key} must be a string, number, or boolean`);
    }
    result[key] = String(raw);
  }
  return result;
}

function validateBuildEnvPayload(payload) {
  normalizeStringRecord(payload.env, 'env');
  const platformEnv = payload.platformEnv || {};
  if (typeof platformEnv !== 'object' || Array.isArray(platformEnv)) {
    badRequest('platformEnv must be an object keyed by platform');
  }
  for (const [platform, env] of Object.entries(platformEnv)) {
    normalizeStringRecord(env, `platformEnv.${platform}`);
  }
}

function platformConfig() {
  return readJsonFile(join(root, 'config', 'platforms.json')).platforms || {};
}

function normalizePlatforms(value) {
  const platforms = value || ['android', 'windows', 'macos'];
  if (!Array.isArray(platforms) || platforms.length === 0) {
    badRequest('platforms must be a non-empty array');
  }

  const configs = platformConfig();
  const seen = new Set();
  const result = [];
  for (const platform of platforms) {
    if (typeof platform !== 'string' || !platform) {
      badRequest('platforms entries must be non-empty strings');
    }
    const config = configs[platform];
    if (!config) {
      badRequest(`Unknown platform: ${platform}`);
    }
    if (config.status === 'empty') {
      badRequest(`Platform is not wired yet: ${platform}`);
    }
    if (!seen.has(platform)) {
      seen.add(platform);
      result.push(platform);
    }
  }
  return result;
}

function normalizePresetPayload(value) {
  if (value === undefined || value === null) return {};
  if (typeof value !== 'object' || Array.isArray(value)) {
    badRequest('presets must be an object keyed by platform');
  }

  const result = {};
  for (const [platform, raw] of Object.entries(value)) {
    if (typeof raw !== 'string') {
      badRequest(`presets.${platform} must be a string`);
    }
    result[platform] = raw;
  }
  return result;
}

function expandBuildRequest(payload, platforms) {
  const presets = normalizePresetPayload(payload.presets || payload.platformPresets);
  const phase = normalizeBuildPhase(payload.phase);
  const configs = platformConfig();
  const platformEnv = {};

  for (const platform of platforms) {
    const presetName = presets[platform];
    const configuredPreset = presetName ? configs[platform]?.presets?.[presetName] : null;
    if (presetName && !configuredPreset) {
      badRequest(`Unknown preset for ${platform}: ${presetName}`);
    }
    platformEnv[platform] = {
      ...normalizeStringRecord(configuredPreset?.env, `presets.${platform}.${presetName}.env`),
      ...normalizeStringRecord(payload.platformEnv?.[platform], `platformEnv.${platform}`)
    };
    if (platform === 'windows') {
      if (platformEnv[platform].NG_WINDOWS_ENABLE_SCCACHE && platformEnv[platform].NG_WINDOWS_ENABLE_SCCACHE !== '1') {
        badRequest('Windows builds require NG_WINDOWS_ENABLE_SCCACHE=1');
      }
      platformEnv[platform].NG_WINDOWS_ENABLE_SCCACHE = '1';
    }
  }

  return {
    ...payload,
    phase,
    reason: normalizeBuildReason(payload.reason, platforms, presets, phase),
    presets,
    platformEnv
  };
}

function normalizeBuildPhase(value) {
  if (value === undefined || value === null || value === '') return null;
  const phase = Number(value);
  if (!Number.isInteger(phase) || phase < 1 || phase > 6)
    badRequest('phase must be an integer from 1 to 6');
  return phase;
}

function normalizeBuildReason(reason, platforms, presets, phase) {
  const raw = String(reason || '').trim();
  const isWindowsWebGPU = platforms.includes('windows') && ['webgpu-dawn', 'webgpu-dawn-fast'].includes(presets.windows);
  if (!isWindowsWebGPU) return raw;
  if (/^webgpu phase \d+:/i.test(raw)) return raw;
  if (phase) return `webgpu phase ${phase}: ${raw || defaultWebGPUPhaseReason(phase)}`;
  if (!raw) return 'webgpu: windows dawn build';
  if (/^webgpu\b/i.test(raw)) return raw;
  return `webgpu: ${raw}`;
}

function defaultWebGPUPhaseReason(phase) {
  switch (phase) {
  case 1:
    return 'foundations reproducible build';
  case 2:
    return 'in-process compute readback';
  case 3:
    return 'canvas present and animation';
  case 4:
    return 'multi-process evaluation';
  case 5:
    return 'conformance subset';
  case 6:
    return 'hardening sustainment';
  default:
    return 'windows dawn build';
  }
}

function artifactPrefixForPlatform(id, platform, request) {
  const env = {
    ...process.env,
    ...normalizeStringRecord(request.env, 'env'),
    ...normalizeStringRecord(request.platformEnv?.[platform], `platformEnv.${platform}`)
  };
  const bucket = env.NG_ARTIFACT_BUCKET || 's3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit';
  if (platform === 'windows') return env.NG_WINDOWS_ARTIFACT_S3 || `${bucket}/windows/${id}`;
  if (platform === 'macos') return env.NG_MACOS_ARTIFACT_S3 || `${bucket}/macos/${id}`;
  if (platform === 'android') return env.NG_ANDROID_ARTIFACT_S3 || `${bucket}/android/${id}`;
  return `${bucket}/${platform}/${id}`;
}

function artifactLinksForPlatform(id, platform, request) {
  const artifactPrefix = artifactPrefixForPlatform(id, platform, request);
  const links = { artifactPrefix };
  if (platform === 'windows') {
    links.validationReport = `${artifactPrefix}/validation-report.json`;
    links.validationRecovered = `${artifactPrefix}/validation-recovered.json`;
    links.sccacheReport = `${artifactPrefix}/sccache-report.json`;
    links.patchManifest = `${artifactPrefix}/patch-manifest.json`;
    links.manifestPre = `${artifactPrefix}/manifest-pre.json`;
    links.manifestPost = `${artifactPrefix}/manifest-post.json`;
    links.buildProgress = `${artifactPrefix}/build-progress.json`;
  }
  return links;
}

function defaultCheckpointMessage(build, payload) {
  const phase = normalizeBuildPhase(payload.phase ?? build.request?.phase);
  const windows = (build.platforms || []).find((platform) => platform.name === 'windows');
  if (phase === 1 && windows) {
    const artifacts = windows.artifacts || artifactLinksForPlatform(build.id, 'windows', build.request || {});
    return `Phase 1 gate met: preset=${build.request?.presets?.windows || 'default'} artifact=${artifacts.artifactPrefix} validation=${artifacts.validationReport}`;
  }
  if (phase === 2 && windows) {
    const artifacts = windows.artifacts || artifactLinksForPlatform(build.id, 'windows', build.request || {});
    return `Phase 2 checkpoint: compute smoke target; artifact=${artifacts.artifactPrefix} validation=${artifacts.validationReport}`;
  }
  return 'manual checkpoint';
}

function buildEnvForPlatform(build, platform) {
  const request = build.request || {};
  return {
    ...process.env,
    ...normalizeStringRecord(request.env, 'env'),
    ...normalizeStringRecord(request.platformEnv?.[platform], `platformEnv.${platform}`),
    NG_SERVICE_BUILD_ID: build.id,
    NG_SERVICE_PLATFORM: platform
  };
}

function startPlatformBuild(build, platform) {
  const logPath = join(logDir, `${build.id}-${platform}.service.log`);
  writeFileSync(logPath, `[${now()}] starting ${platform} build ${build.id}\n`, { flag: 'a' });
  const child = spawn(join(root, 'scripts', 'run-build.sh'), [platform, build.id], {
    cwd: root,
    env: buildEnvForPlatform(build, platform),
    stdio: ['ignore', 'pipe', 'pipe']
  });

  const logStream = createWriteStream(logPath, { flags: 'a' });
  child.stdout.pipe(logStream, { end: false });
  child.stderr.pipe(logStream, { end: false });

  running.set(`${build.id}:${platform}`, child);
  const started = loadState();
  const storedBuild = started.builds.find((item) => item.id === build.id);
  const storedPlatform = storedBuild?.platforms.find((item) => item.name === platform);
  if (storedPlatform) {
    storedPlatform.pid = child.pid;
    storedPlatform.startedAt = now();
    saveState(started);
  }

  child.on('error', (error) => {
    running.delete(`${build.id}:${platform}`);
    logStream.end(`[${now()}] spawn failed: ${error.message}\n`);
    const current = loadState();
    const stored = current.builds.find((item) => item.id === build.id);
    const target = stored?.platforms.find((item) => item.name === platform);
    if (target) {
      target.status = 'failed';
      target.error = error.message;
      target.finishedAt = now();
    }
    if (stored) {
      stored.status = stored.platforms.some((item) => item.status === 'running') ? 'running' : 'failed';
      stored.updatedAt = now();
      saveState(current);
    }
  });

  child.on('exit', (code, signal) => {
    running.delete(`${build.id}:${platform}`);
    logStream.end();
    const current = loadState();
    const stored = current.builds.find((item) => item.id === build.id);
    if (!stored) return;
    const target = stored.platforms.find((item) => item.name === platform);
    if (!target) return;
    const inferred = code === 0 ? null : inferExternalBuildStatusFromLog(build.id, platform);
    target.status = code === 0 || inferred.status === 'succeeded' ? 'succeeded' : 'failed';
    target.exitCode = code;
    target.signal = signal;
    if (code !== 0 && inferred.status === 'succeeded') {
      target.warning = `runner exited ${code} after remote success marker: ${inferred.detail}`;
    }
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
      log: join(logDir, `${id}-${name}.service.log`),
      artifactPrefix: artifactPrefixForPlatform(id, name, meta),
      artifacts: artifactLinksForPlatform(id, name, meta)
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
  return loadBuilds().find((build) => build.id === id);
}

function readJsonFile(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

async function runCaptured(command, args, options = {}) {
  const startedAt = now();
  try {
    const result = await execFileAsync(command, args, {
      cwd: options.cwd || root,
      env: { ...process.env, ...(options.env || {}) },
      timeout: options.timeout || 120000,
      maxBuffer: options.maxBuffer || 2 * 1024 * 1024,
      windowsHide: true
    });
    return {
      ok: true,
      command,
      args,
      cwd: options.cwd || root,
      startedAt,
      finishedAt: now(),
      stdout: result.stdout,
      stderr: result.stderr
    };
  } catch (error) {
    return {
      ok: false,
      command,
      args,
      cwd: options.cwd || root,
      startedAt,
      finishedAt: now(),
      exitCode: error.code,
      signal: error.signal,
      stdout: error.stdout || '',
      stderr: error.stderr || error.message
    };
  }
}

async function gitStatus() {
  const [head, branch, status, remote, recent] = await Promise.all([
    runCaptured('git', ['rev-parse', 'HEAD']),
    runCaptured('git', ['branch', '--show-current']),
    runCaptured('git', ['status', '--short']),
    runCaptured('git', ['remote', '-v']),
    runCaptured('git', ['log', '--oneline', '-8'])
  ]);
  return {
    head: head.stdout.trim(),
    branch: branch.stdout.trim(),
    dirty: status.stdout.trim().split(/\r?\n/).filter(Boolean),
    remotes: remote.stdout.trim().split(/\r?\n/).filter(Boolean),
    recent: recent.stdout.trim().split(/\r?\n/).filter(Boolean),
    commands: { head, branch, status, remote, recent }
  };
}

function commandExists(command) {
  const check = process.platform === 'win32'
    ? spawn('where.exe', [command], { stdio: 'ignore' })
    : spawn('bash', ['-lc', `command -v ${JSON.stringify(command)} >/dev/null 2>&1`], { stdio: 'ignore' });
  return new Promise((resolve) => {
    check.on('exit', (code) => resolve(code === 0));
    check.on('error', () => resolve(false));
  });
}

async function dependencyStatus() {
  const requiredCommands = ['git', 'python3', 'node', 'npm', 'aws', 'tar'];
  const optionalCommands = ['ruby', 'perl', 'cmake', 'ninja', 'gperf'];
  const checks = {};
  await Promise.all([...requiredCommands, ...optionalCommands].map(async (command) => {
    checks[command] = await commandExists(command);
  }));
  const missingRequired = requiredCommands.filter((command) => !checks[command]);
  const config = readJsonFile(join(root, 'config', 'dependencies.json'));
  return {
    ok: missingRequired.length === 0,
    missingRequired,
    requiredCommands,
    optionalCommands,
    commands: checks,
    config
  };
}

function logFiles() {
  if (!existsSync(logDir)) return [];
  return readdirSync(logDir)
    .filter((name) => /^[A-Za-z0-9._-]+$/.test(name))
    .map((name) => {
      const path = join(logDir, name);
      const stats = statSync(path);
      return { name, size: stats.size, modifiedAt: stats.mtime.toISOString() };
    })
    .sort((a, b) => b.modifiedAt.localeCompare(a.modifiedAt));
}

function requestUrl(url) {
  return new URL(url, `http://127.0.0.1:${port}`);
}

function tailTextFile(path, lineCount) {
  const lines = Math.max(1, Math.min(Number(lineCount) || 200, 15000));
  const stats = statSync(path);
  const bytesToRead = Math.min(stats.size, Math.max(64 * 1024, lines * 300));
  const buffer = Buffer.alloc(bytesToRead);
  const fd = openSync(path, 'r');
  try {
    readSync(fd, buffer, 0, bytesToRead, stats.size - bytesToRead);
  } finally {
    closeSync(fd);
  }
  return buffer.toString('utf8').split(/\r?\n/).slice(-lines).join('\n');
}

/**
 * Marker-file builds (remote SSM) are injected even after completion because
 * WINDOWS_ACTIVE_BUILD.env / MACOS_ACTIVE_BUILD.env may linger. Infer terminal
 * status from the orchestrator tee log on this host (no build-script changes).
 */
function inferExternalBuildStatusFromLog(id, platform) {
  const serviceLogPath = join(logDir, `${id}-${platform}.service.log`);
  const directLogPath = join(logDir, `${id}-${platform}.log`);
  const logPath = existsSync(serviceLogPath) ? serviceLogPath : directLogPath;
  if (!existsSync(logPath)) {
    return { status: 'unknown', detail: 'no orchestrator log file yet', logPath: null };
  }
  let text;
  try {
    const stats = statSync(logPath);
    const n = Math.min(stats.size, 384 * 1024);
    const buf = Buffer.alloc(n);
    const fd = openSync(logPath, 'r');
    try {
      readSync(fd, buf, 0, n, stats.size - n);
    } finally {
      closeSync(fd);
    }
    text = buf.toString('utf8');
  } catch (e) {
    return { status: 'unknown', detail: `log read failed: ${e.message}`, logPath };
  }

  const failed = /remote build FAILED|BUILD_FAILED\.txt|Timed out waiting for BUILD_DONE|ninja: build stopped: subcommand failed|marker poll unexpected|bootstrap SSM failure/i.test(
    text
  );
  const ok =
    /marker poll OK|remote build completed|checkpoint\.sh.*completed|windows remote build completed|macos remote build completed/i.test(text) ||
    /BUILD_DONE\.txt/i.test(text);

  if (failed && ok) return { status: 'failed', detail: 'log contains both success and failure markers; treating as failed', logPath };
  if (failed) return { status: 'failed', detail: 'inferred from orchestrator log', logPath };
  if (ok) return { status: 'succeeded', detail: 'inferred from orchestrator log', logPath };

  try {
    const ageMs = Date.now() - statSync(logPath).mtimeMs;
    if (ageMs > 48 * 60 * 60 * 1000) {
      return { status: 'unknown', detail: 'log idle >48h with no terminal pattern; refresh markers or open log', logPath };
    }
  } catch {
    // ignore
  }

  return { status: 'running', detail: 'no terminal pattern in log tail yet', logPath };
}

const server = http.createServer(async (req, res) => {
  try {
    const url = requestUrl(req.url);
    const parts = url.pathname.split('/').filter(Boolean);

    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'access-control-allow-origin': '*',
        'access-control-allow-methods': 'GET,POST,OPTIONS',
        'access-control-allow-headers': 'content-type'
      });
      return res.end();
    }

    if (req.method === 'GET' && parts.length === 0) {
      return html(res, 200, dashboardHtml);
    }

    if (req.method === 'GET' && parts[0] === 'meta' && parts.length === 1) {
      return json(res, 200, {
        name: 'ng-webkit build service',
        dashboard: 'GET /',
        endpoints: [
          'GET /health',
          'GET /git',
          'POST /git/pull',
          'GET /platforms',
          'GET /dependencies',
          'GET /dependencies/status',
          'GET /logs',
          'GET /logs/:name?tail=200',
          'GET /builds',
          'POST /builds',
          'POST /builds?dryRun=1',
          'GET /builds/:id',
          'GET /builds/:id/artifacts',
          'GET /builds/:id/logs/:platform?tail=200',
          'POST /builds/:id/restart',
          'POST /builds/:id/checkpoint',
          'POST /builds/:id/cancel'
        ]
      });
    }

    if (req.method === 'GET' && parts[0] === 'git' && parts.length === 1) {
      return json(res, 200, await gitStatus());
    }

    if (req.method === 'POST' && parts[0] === 'git' && parts[1] === 'pull' && parts.length === 2) {
      const payload = await body(req);
      const args = payload?.rebase ? ['pull', '--ff-only', '--rebase'] : ['pull', '--ff-only'];
      const result = await runCaptured('git', args, { timeout: 5 * 60 * 1000 });
      writeFileSync(join(logDir, 'api-git-pull.log'), `[${now()}] git ${args.join(' ')}\n${result.stdout}\n${result.stderr}\n`, { flag: 'a' });
      return json(res, result.ok ? 200 : 500, result);
    }

    if (req.method === 'GET' && parts[0] === 'health' && parts.length === 1) {
      return json(res, 200, {
        ok: true,
        time: now(),
        root,
        port,
        running: [...running.keys()]
      });
    }

    if (req.method === 'GET' && parts[0] === 'platforms' && parts.length === 1) {
      return json(res, 200, readJsonFile(join(root, 'config', 'platforms.json')));
    }

    if (req.method === 'GET' && parts[0] === 'builds' && parts.length === 1) {
      return json(res, 200, loadBuilds());
    }

    if (req.method === 'GET' && parts[0] === 'changes' && parts.length === 1) {
      return json(res, 200, {
        config: readJsonFile(join(root, 'config', 'changes.json')),
        note: 'Enable changes in config/changes.json; patches live under changes/<id>.'
      });
    }

    if (req.method === 'GET' && parts[0] === 'dependencies' && parts.length === 1) {
      const catalogPath = join(varDir, 'dependency-catalog.json');
      return json(res, 200, {
        config: readJsonFile(join(root, 'config', 'dependencies.json')),
        catalog: existsSync(catalogPath) ? readJsonFile(catalogPath) : null
      });
    }

    if (req.method === 'GET' && parts[0] === 'dependencies' && parts[1] === 'status' && parts.length === 2) {
      return json(res, 200, await dependencyStatus());
    }

    if (req.method === 'GET' && parts[0] === 'logs' && parts.length === 1) {
      return json(res, 200, { logDir, logs: logFiles() });
    }

    if (req.method === 'GET' && parts[0] === 'logs' && parts[1] && parts.length === 2) {
      const name = parts[1];
      if (!/^[A-Za-z0-9._-]+$/.test(name)) return json(res, 400, { error: 'invalid log name' });
      const logPath = join(logDir, name);
      if (!existsSync(logPath)) return json(res, 404, { error: 'log not found' });
      if (url.searchParams.has('tail')) {
        res.writeHead(200, { 'content-type': 'text/plain' });
        return res.end(tailTextFile(logPath, url.searchParams.get('tail')));
      }
      res.writeHead(200, { 'content-type': 'text/plain' });
      return createReadStream(logPath).pipe(res);
    }

    if (req.method === 'POST' && parts[0] === 'builds' && parts.length === 1) {
      const payload = await body(req);
      const platforms = normalizePlatforms(payload.platforms);
      validateBuildEnvPayload(payload);
      const request = expandBuildRequest(payload, platforms);
      if (url.searchParams.get('dryRun') === '1' || url.searchParams.get('dryRun') === 'true') {
        return json(res, 200, {
          ok: true,
          dryRun: true,
          platforms,
          request,
          artifactPrefixes: Object.fromEntries(platforms.map((platform) => [platform, artifactPrefixForPlatform('dry-run', platform, request)]))
        });
      }
      return json(res, 202, createBuild(platforms, request));
    }

    if (parts[0] === 'builds' && parts[1]) {
      const build = getBuild(parts[1]);
      if (!build) return json(res, 404, { error: 'build not found' });

      if (req.method === 'GET' && parts.length === 2) return json(res, 200, build);

      if (req.method === 'GET' && parts[2] === 'artifacts' && parts.length === 3) {
        return json(res, 200, {
          buildId: build.id,
          platforms: build.platforms.map((platform) => ({
            name: platform.name,
            status: platform.status,
            artifactPrefix: platform.artifactPrefix,
            artifacts: platform.artifacts || artifactLinksForPlatform(build.id, platform.name, build.request || {})
          }))
        });
      }

      if (req.method === 'GET' && parts[2] === 'logs' && parts[3]) {
        const platform = parts[3];
        const serviceLogPath = join(logDir, `${build.id}-${platform}.service.log`);
        const directLogPath = join(logDir, `${build.id}-${platform}.log`);
        const logPath = existsSync(serviceLogPath) ? serviceLogPath : directLogPath;
        if (!existsSync(logPath)) return json(res, 404, { error: 'log not found' });
        if (url.searchParams.has('tail')) {
          res.writeHead(200, { 'content-type': 'text/plain' });
          return res.end(tailTextFile(logPath, url.searchParams.get('tail')));
        }
        res.writeHead(200, { 'content-type': 'text/plain' });
        return createReadStream(logPath).pipe(res);
      }

      if (req.method === 'POST' && parts[2] === 'checkpoint') {
        const payload = await body(req);
        const checkpoint = {
          time: now(),
          phase: normalizeBuildPhase(payload.phase ?? build.request?.phase),
          message: payload.message || defaultCheckpointMessage(build, payload)
        };
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
        const platforms = normalizePlatforms(payload.platforms || build.platforms.map((platform) => platform.name));
        validateBuildEnvPayload(payload);
        const request = expandBuildRequest({ reason: `restart of ${build.id}`, restartedFrom: build.id, ...payload }, platforms);
        return json(res, 202, createBuild(platforms, request));
      }
    }

    return json(res, 404, { error: 'not found' });
  } catch (error) {
    const status = error.statusCode || (error instanceof SyntaxError ? 400 : 500);
    return json(res, status, { error: error.message, stack: process.env.NODE_ENV === 'production' ? undefined : error.stack });
  }
});

server.listen(port, '0.0.0.0', () => {
  console.log(`ng-webkit build service listening on http://127.0.0.1:${port}/ (dashboard + API)`);
});

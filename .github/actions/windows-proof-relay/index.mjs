import {existsSync, readFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {spawn} from 'node:child_process';

const uploaderPin = 'cf430e030ddbb5b0abf93d22962f4752f3646cd9';
const uploader = join(dirname(process.env.RUNNER_TEMP), '_actions', 'actions', 'upload-artifact', uploaderPin, 'dist', 'upload', 'index.js');
if (!existsSync(uploader)) throw new Error('The pinned official artifact action must be prepared before starting the relay');
if (!process.env.ACTIONS_RUNTIME_TOKEN || !process.env.ACTIONS_RESULTS_URL) throw new Error('The JavaScript action artifact runtime is unavailable');
const workspace = process.env.GITHUB_WORKSPACE;
const readyPath = join(workspace, 'evidence', 'windows-relay', 'public.json');
let ended = false;
let exitCode;
const powershell = spawn('pwsh', ['-NoProfile', '-Command',
  '& ./scripts/proof-lab/windows-relay-start.ps1; if (!$?) { exit 1 }; & ./scripts/proof-lab/windows-relay-hold.ps1; if (!$?) { exit 1 }'],
  {cwd:workspace, env:process.env, stdio:['ignore','pipe','pipe']});
powershell.stdout.on('data', chunk => process.stdout.write(chunk));
powershell.stderr.on('data', chunk => process.stderr.write(chunk));
const completion = new Promise((resolve, reject) => {
  powershell.on('error', reject);
  powershell.on('close', code => { ended = true; exitCode = code; resolve(code); });
});
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
try {
  const deadline = Date.now() + 10 * 60_000;
  let ready = false;
  while (Date.now() < deadline && !ended) {
    if (existsSync(readyPath)) {
      const metadata = JSON.parse(readFileSync(readyPath, 'utf8'));
      if (metadata.sourceHead === process.env.RIGHTCLICK_RELAY_SOURCE_HEAD && Date.parse(metadata.expiresAt) > Date.now()) {
        ready = true;
        break;
      }
    }
    await delay(1000);
  }
  if (!ready) throw new Error(ended ? 'Native Windows relay setup exited before readiness' : 'Native Windows relay setup deadline exceeded');
  const upload = spawn(process.execPath, [uploader], {cwd:workspace,
    env:{...process.env, INPUT_NAME:'live-windows-proof-connection', INPUT_PATH:'evidence/windows-relay/*.json',
      'INPUT_RETENTION-DAYS':'1', 'INPUT_IF-NO-FILES-FOUND':'error', 'INPUT_COMPRESSION-LEVEL':'6',
      INPUT_OVERWRITE:'false', 'INPUT_INCLUDE-HIDDEN-FILES':'false', INPUT_ARCHIVE:'true'}, stdio:'inherit'});
  const uploaded = await new Promise((resolve, reject) => { upload.on('error', reject); upload.on('close', resolve); });
  if (uploaded !== 0) throw new Error('Pinned official uploader could not publish the encrypted connection');
  console.log('Live native Windows TLS connection artifact uploaded. The hosting session remains open until scoped operator withdrawal or expiry.');
  const result = await completion;
  if (result !== 0) throw new Error('Native Windows relay lifecycle supervisor failed');
} catch (error) {
  if (!ended) powershell.kill();
  console.error('::error::' + error.message);
  process.exitCode = 1;
}

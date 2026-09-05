import { randomBytes } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = fileURLToPath(new URL('../', import.meta.url));
try {
  await writeFile(path.join(root, '.env'), `LOVE2D_MCP_TOKEN=${randomBytes(32).toString('hex')}\nLOVE2D_MCP_HOST=127.0.0.1\nLOVE2D_MCP_PORT=12345\nLOVE2D_MCP_ALLOW_RUN_LUA=false\n`, { flag: 'wx', mode: 0o600 });
  console.log('Created .env with a random token. The token is not printed. Do not share or commit this file.');
} catch (error) {
  if (error.code !== 'EEXIST') throw error;
  console.log('Existing .env preserved.');
}
console.log('\nCodex configuration (no token embedded):\n');
console.log('[mcp_servers.love2d]\ncommand = "node"\nargs = ' + JSON.stringify(['--env-file=' + path.join(root, '.env'), path.join(root, 'build/index.js')]) + '\ntool_timeout_sec = 30');
console.log('\nNext: npm run build, then npm run game in a separate terminal.');

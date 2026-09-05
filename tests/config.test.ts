import assert from 'node:assert/strict';
import test from 'node:test';
import { loadConfig } from '../src/config.ts';
const base = { LOVE2D_MCP_TOKEN: 'x'.repeat(64) };
test('secure defaults and hostname normalization',()=>{const c=loadConfig({...base,LOVE2D_MCP_HOST:'localhost'});assert.equal(c.host,'127.0.0.1');assert.equal(c.allowRunLua,false);assert.equal(c.maxResponseBytes,4194304);});
test('requires non-placeholder printable token',()=>{for(const token of ['', 'x'.repeat(31), 'x'.repeat(257),'replace-with-at-least-32-random-characters','가'.repeat(32),' '.repeat(64)])assert.throws(()=>loadConfig({LOVE2D_MCP_TOKEN:token}));});
test('rejects non-loopback hosts',()=>assert.throws(()=>loadConfig({...base,LOVE2D_MCP_HOST:'0.0.0.0'})));
for(const raw of ['12345junk','1.5','-1','','65536','1e3'])test('strict port parsing: '+JSON.stringify(raw),()=>assert.throws(()=>loadConfig({...base,LOVE2D_MCP_PORT:raw})));
test('Lua requires literal boolean opt-in',()=>{assert.equal(loadConfig({...base,LOVE2D_MCP_ALLOW_RUN_LUA:'true'}).allowRunLua,true);assert.throws(()=>loadConfig({...base,LOVE2D_MCP_ALLOW_RUN_LUA:'1'}));});

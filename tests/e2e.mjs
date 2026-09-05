// Runs only in the Linux LÖVE CI job. Tests real rendering, not a mocked image.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { setTimeout as sleep } from 'node:timers/promises';
import net from 'node:net';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
const listener=net.createServer();await new Promise(r=>listener.listen(0,'127.0.0.1',r));const port=listener.address().port;await new Promise(r=>listener.close(r));
const token=randomBytes(32).toString('hex');
const env=Object.fromEntries(Object.entries({...process.env,LOVE2D_MCP_TOKEN:token,LOVE2D_MCP_HOST:'127.0.0.1',LOVE2D_MCP_PORT:String(port),LOVE2D_MCP_ALLOW_RUN_LUA:'false',LOVE2D_MCP_TEST_MODE:'true',LIBGL_ALWAYS_SOFTWARE:'1',SDL_VIDEODRIVER:'x11'}).filter(([,v])=>v!==undefined));
const game=spawn('xvfb-run',['-a','love','game'],{env,detached:true,stdio:['ignore','pipe','pipe']});
let gameLog='';game.on('error',error=>{gameLog+=error.message;});game.stdout.on('data',b=>gameLog+=b);game.stderr.on('data',b=>gameLog+=b);
const transport=new StdioClientTransport({command:process.execPath,args:['build/index.js'],env,stderr:'pipe'});
const client=new Client({name:'love2d-e2e',version:'1'});
let passed=0;const ok=(name)=>{passed++;console.log('PASS E2E: '+name);};
async function call(name,args={}){return client.callTool({name,arguments:args});}
async function result(name,args={}){const r=await call(name,args);assert.notEqual(r.isError,true,JSON.stringify(r));return r.structuredContent;}
try{
  await client.connect(transport);
  const {tools}=await client.listTools();assert.equal(tools.length,16);assert(!tools.some(t=>t.name==='run_lua'));ok('MCP initializes over stdio without requiring the game to be ready');
  let ready=false;let lastPing;
  for(let i=0;i<100;i++){const r=await call('ping');lastPing=r;if(!r.isError){ready=true;break;}if(game.exitCode!==null)break;await sleep(100);}
  assert(ready,gameLog+'\nLast ping: '+JSON.stringify(lastPing));ok('real LÖVE TCP bridge authenticates');
  const status=await result('get_status');assert.equal(status.bridge_version,'2.1.0');assert.equal(status.run_lua_enabled,false);ok('live capabilities and version');
  const actions=await result('list_actions');assert(actions.actions.some(a=>a.name==='damage_player'));ok('registered action discovery');
  assert.equal((await call('invoke_action',{action:'damage_player',params:{amount:-10}})).isError,true);ok('out-of-range action rejected');
  await result('control_game',{operation:'pause'});await result('save_snapshot',{name:'baseline'});
  const before=(await result('get_object',{id:'player'})).object;
  await result('send_input',{event:'key_down',key:'right'});
  const step=await result('control_game',{operation:'step',frames:6,dt:0.02});assert.equal(step.steps_remaining,0);
  await result('send_input',{event:'reset'});
  const after=(await result('get_object',{id:'player'})).object;assert(Math.abs(after.x-before.x-21.6)<0.001);ok('virtual polling input and six fixed simulation steps');
  await result('set_object_property',{id:'player',property:'health',value:75});
  const differences=await result('diff_snapshot',{name:'baseline'});assert(differences.changes.some(d=>d.path==='/player/health'));ok('snapshot diff detects real mutations');
  await result('restore_snapshot',{name:'baseline'});const restored=(await result('get_object',{id:'player'})).object;assert.equal(restored.x,before.x);assert.equal(restored.health,before.health);ok('explicit game snapshot restoration');
  const batch=await result('batch',{commands:[{command:'get_object',args:{id:'player'}},{command:'get_metrics'}]});assert.equal(batch.completed,2);assert.equal(batch.atomic,false);ok('batched structured results');
  const image=await call('capture_screenshot');assert.notEqual(image.isError,true,JSON.stringify(image));const content=image.content.find(c=>c.type==='image');assert(content);const png=Buffer.from(content.data,'base64');assert.equal(png.subarray(0,8).toString('hex'),'89504e470d0a1a0a');assert.equal(png.readUInt32BE(16),960);assert.equal(png.readUInt32BE(20),540);assert(png.length>1000);
  await mkdir('test-results',{recursive:true});await writeFile('test-results/demo.png',png);ok('real rendered 960x540 PNG travels through MCP image content');
  const logs=await result('get_logs');assert(logs.entries.length>0);assert(!JSON.stringify(logs).includes(token));ok('bounded logs with token redaction');
  const resource=await client.readResource({uri:'love2d://status'});assert.equal(JSON.parse(resource.contents[0].text).bridge_version,'2.1.0');ok('MCP status resource');
  await writeFile('test-results/e2e.json',JSON.stringify({passed,renderer:'real LÖVE under Xvfb',width:960,height:540},null,2));
  console.log(`${passed} E2E assertions passed`);
}catch(error){console.error(gameLog.split(token).join('[redacted]'));throw error;}
finally{await client.close().catch(()=>{});if(game.pid){try{process.kill(-game.pid,'SIGTERM');}catch{}}}

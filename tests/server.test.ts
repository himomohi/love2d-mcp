import assert from 'node:assert/strict';
import test from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createServer, specs } from '../build/server.js';
import { Love2DClient } from '../build/love2d-client.js';
const config={host:'127.0.0.1',port:12345,token:'x'.repeat(64),timeoutMs:500,maxResponseBytes:4194304};
async function fixture(run:(client:Client,calls:any[])=>Promise<void>,allow=false) {
  const calls:any[]=[];
  const bridge=new Love2DClient(config);
  bridge.sendCommand=async(command,payload)=>{calls.push({command,payload});return {request_id:'test',ok:true,result:command==='batch'?{results:[{ok:false}],completed:1,atomic:false}:{received:command,...payload}};};
  const {server}=createServer({...config,allowRunLua:allow},bridge);
  const client=new Client({name:'unit-test',version:'1'});
  const [a,b]=InMemoryTransport.createLinkedPair();
  await server.connect(a);await client.connect(b);
  try{await run(client,calls);}finally{await client.close();await server.close();}
}
test('MCP exposes 16 tools by default and two resources without a running game',async()=>fixture(async(client)=>{const {tools}=await client.listTools();assert.equal(tools.length,16);assert(!tools.some(t=>t.name==='run_lua'));assert(tools.every(t=>t.inputSchema.type==='object'));assert.equal((await client.listResources()).resources.length,2);}));
test('Lua tool is advertised only with explicit server opt-in',async()=>fixture(async client=>assert.equal((await client.listTools()).tools.length,17),true));
test('schema errors do not reach the game and are MCP errors',async()=>fixture(async(client,calls)=>{const result=await client.callTool({name:'get_object',arguments:{id:1}});assert.equal(result.isError,true);assert.equal(calls.length,0);}));
test('read-only tools reject unexpected fields',async()=>fixture(async(client,calls)=>{assert.equal((await client.callTool({name:'ping',arguments:{token:'not-allowed'}})).isError,true);assert.equal(calls.length,0);}));
test('hidden Lua cannot be invoked by name',async()=>fixture(async(client,calls)=>{assert.equal((await client.callTool({name:'run_lua',arguments:{code:'return 1'}})).isError,true);assert.equal(calls.length,0);}));
test('batch validates every item before any game mutation',async()=>fixture(async(client,calls)=>{const result=await client.callTool({name:'batch',arguments:{commands:[{command:'ping'},{command:'get_object',args:{id:5}}]}});assert.equal(result.isError,true);assert.equal(calls.length,0);}));
test('batch partial failures are surfaced and not called atomic',async()=>fixture(async(client,calls)=>{const result=await client.callTool({name:'batch',arguments:{commands:[{command:'get_object',args:{id:'missing'}}]}});assert.equal(result.isError,true);assert.deepEqual(calls[0].payload.commands,[{id:'missing',command:'get_object'}]);}));
test('resource reads route only known read-only commands',async()=>fixture(async(client,calls)=>{await client.readResource({uri:'love2d://status'});assert.equal(calls[0].command,'get_status');await assert.rejects(client.readResource({uri:'love2d://no-such-resource'}));assert.equal(calls.length,1);}));
test('tool result includes structured data and matching text',async()=>fixture(async client=>{const r=await client.callTool({name:'ping'});assert.deepEqual(r.structuredContent,JSON.parse((r.content as any[])[0].text));}));
test('tool schemas enforce input event shape',()=>{assert.throws(()=>specs.send_input.schema.parse({event:'key_down'}));assert.throws(()=>specs.control_game.schema.parse({operation:'step',frames:121}));});

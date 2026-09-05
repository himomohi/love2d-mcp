import assert from 'node:assert/strict';
import net from 'node:net';
import test from 'node:test';
import { Love2DClient } from '../src/love2d-client.ts';
const token = 'test-token-' + 'x'.repeat(40);
async function fixture(handler: (socket: net.Socket, r: any) => void, run: (c: Love2DClient, count: () => number) => Promise<void>, options: Record<string, unknown> = {}) {
  const sockets = new Set<net.Socket>(); let count = 0;
  const server = net.createServer(socket => {
    count++; sockets.add(socket); socket.on('close', () => sockets.delete(socket)); socket.on('error', () => {});
    let buffer = '';
    socket.on('data', chunk => { buffer += chunk; let end: number; while ((end = buffer.indexOf('\n')) >= 0) { const line = buffer.slice(0, end); buffer = buffer.slice(end + 1); handler(socket, JSON.parse(line)); } });
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as net.AddressInfo).port;
  const client = new Love2DClient({ host: '127.0.0.1', port, token, timeoutMs: 1000, maxResponseBytes: 4096, ...options });
  try { await run(client, () => count); } finally { client.close(); for (const s of sockets) s.destroy(); await new Promise<void>(resolve => server.close(() => resolve())); }
}
const reply = (r: any, result: unknown) => JSON.stringify({request_id:r.request_id,ok:true,result})+'\n';
test('reassembles UTF8 split inside a Korean character', async () => {
  await fixture((s,r) => { const b=Buffer.from(reply(r,{text:'한글 😺'}));const cut=b.indexOf(Buffer.from('한'))+1;s.write(b.subarray(0,cut));setTimeout(()=>s.write(b.subarray(cut)),5); },async c=>assert.deepEqual((await c.sendCommand('ping')).result,{text:'한글 😺'}));
});
test('multiplexes concurrent requests on one connection and accepts out-of-order coalesced replies', async () => {
  const waiting: any[]=[];
  await fixture((s,r)=>{waiting.push(r);if(waiting.length===2)s.write(reply(waiting[1],2)+reply(waiting[0],1));},async(c,count)=>{const results=await Promise.all([c.sendCommand('one'),c.sendCommand('two')]);assert.deepEqual(results.map(r=>r.result),[1,2]);assert.equal(count(),1);});
});
test('rejects unmatched request IDs',async()=>fixture(s=>s.write('{"request_id":"wrong","ok":true,"result":{}}\n'),async c=>{await assert.rejects(c.sendCommand('ping'),/request_id/);}));
test('requires a boolean success flag',async()=>fixture((s,r)=>s.write(JSON.stringify({request_id:r.request_id,result:{}})+'\n'),async c=>{await assert.rejects(c.sendCommand('ping'),/envelope/);}));
test('bounds each response frame',async()=>fixture((s,r)=>s.write(reply(r,'x'.repeat(5000))),async c=>{await assert.rejects(c.sendCommand('ping'),/exceeded/);}));
test('bounds request bytes before connecting',async()=>fixture(()=>assert.fail('Should not connect'),async(c,count)=>{await assert.rejects(c.sendCommand('ping',{x:'a'.repeat(2048)}),/exceeded/);assert.equal(count(),0);},{maxRequestBytes:1024}));
test('payload cannot replace token, command or request ID',async()=>fixture(()=>assert.fail('Should not connect'),async c=>{for(const field of ['token','command','request_id'])await assert.rejects(c.sendCommand('ping',{[field]:'oops'}),/Reserved/);}));
test('surfaces game errors and keeps the connection usable',async()=>fixture((s,r)=>s.write(r.command==='bad'?JSON.stringify({request_id:r.request_id,ok:false,error:'Denied',code:'DENIED'})+'\n':reply(r,true)),async(c,count)=>{await assert.rejects(c.sendCommand('bad'),/Denied/);assert.equal((await c.sendCommand('ping')).result,true);assert.equal(count(),1);}));
test('reconnects only on next call; never replays a failed mutation',async()=>{let calls=0;await fixture((s,r)=>{calls++;if(calls===1)s.destroy();else s.write(reply(r,calls));},async(c,count)=>{await assert.rejects(c.sendCommand('mutate'),/disconnected/);assert.equal((await c.sendCommand('ping')).result,2);assert.equal(count(),2);assert.equal(calls,2);});});
test('timeout is bounded and is not retried',async()=>{let calls=0;await fixture(()=>{calls++;},async c=>{await assert.rejects(c.sendCommand('mutate'),/timed out/);assert.equal(calls,1);},{timeoutMs:50});});
test('pre-cancelled commands do not connect',async()=>fixture(()=>assert.fail('Should not connect'),async c=>{const controller=new AbortController();controller.abort();await assert.rejects(c.sendCommand('ping',{},controller.signal),/cancelled/);}));
test('malformed UTF8 is not silently replaced',async()=>fixture((s,r)=>{s.write(Buffer.concat([Buffer.from('{"request_id":"'+r.request_id+'","ok":true,"result":"'),Buffer.from([255]),Buffer.from('"}\n')]));},async c=>{await assert.rejects(c.sendCommand('ping'),/UTF-8/);}));

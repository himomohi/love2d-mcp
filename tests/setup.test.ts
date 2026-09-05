import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, mkdir, copyFile, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
test('setup creates a random secret without printing it and never overwrites it',async()=>{
  const dir=await mkdtemp(path.join(tmpdir(),'love2d-setup-'));
  try{await mkdir(path.join(dir,'scripts'));await copyFile('scripts/setup.mjs',path.join(dir,'scripts/setup.mjs'));
    const out=execFileSync(process.execPath,[path.join(dir,'scripts/setup.mjs')],{encoding:'utf8'});
    const before=await readFile(path.join(dir,'.env'),'utf8');const token=before.match(/TOKEN=([a-f0-9]{64})/)?.[1];assert(token);assert(!out.includes(token));assert(out.includes('[mcp_servers.love2d]'));
    execFileSync(process.execPath,[path.join(dir,'scripts/setup.mjs')]);assert.equal(await readFile(path.join(dir,'.env'),'utf8'),before);
    if(process.platform!=='win32')assert.equal((await stat(path.join(dir,'.env'))).mode & 0o777,0o600);
  }finally{await rm(dir,{recursive:true,force:true});}
});

import fs from 'node:fs';
const files = fs.readdirSync('.').filter(f=>f.endsWith('.swift'));
const src = files.map(f=>fs.readFileSync(f,'utf8')).join('\n');
const problems = [];

// 收集所有 struct/class/enum 的成员
function typeMembers(name){
  const set=new Set();
  const re=new RegExp(`(?:struct|final class|class|enum|extension) ${name}\\b[\\s\\S]*?(?=\\n(?:struct |final class |class |enum |extension |@main|private struct |public )|$)`,'g');
  for(const b of src.match(re)||[]){
    for(const m of b.matchAll(/\b(?:var|let) (\w+)/g)) set.add(m[1]);
    for(const m of b.matchAll(/\bfunc (\w+)/g)) set.add(m[1]);
    for(const m of b.matchAll(/\bcase (\w+)/g)) set.add(m[1]);
  }
  return set;
}

const account = typeMembers('Account');
const settings = typeMembers('Settings');
const remote = typeMembers('RemoteModel');
const keep = typeMembers('KeepAlive');
const mode = typeMembers('KeepAliveMode');
const reqlog = typeMembers('RequestLog');

function checkMembers(memberSet, name, usages){
  for(const [pattern, field] of usages){
    if(!memberSet.has(field)) problems.push(`${name} 缺少成员: ${field}  (用于 ${pattern})`);
  }
}
checkMembers(account,'Account',[
  ['account.nickname','nickname'],['account.uid','uid'],['account.realm','realm'],
  ['account.disabled','disabled'],['account.credits','credits'],
  ['account.lastRun','lastRun'],['account.lastCheckin','lastCheckin'],
  ['account.accessToken','accessToken'],['account.refreshToken','refreshToken'],
  ['account.expiresAt','expiresAt'],['account.displayName','displayName'],
]);
checkMembers(remote,'RemoteModel',[
  ['m.id','id'],['m.name','name'],['m.contextWindow','contextWindow'],
  ['m.maxTokens','maxTokens'],['m.supportsImages','supportsImages'],['m.credits','credits'],
]);
checkMembers(keep,'KeepAlive',[
  ['k.active','active'],['k.detail','detail'],['k.degraded','degraded'],
  ['k.audioOn','audioOn'],['k.uptime','uptime'],['k.renewCount','renewCount'],
  ['bootstrap','bootstrap'],['enterForeground','enterForeground'],
  ['enterBackground','enterBackground'],['reassert','reassert'],['sync','sync'],
]);
checkMembers(mode,'KeepAliveMode',[
  ['label','label'],['detail','detail'],['cost','cost'],['usesAudio','usesAudio'],['sampleRate','sampleRate'],
]);
checkMembers(reqlog,'RequestLog',[
  ['model','model'],['upstreamURL','upstreamURL'],['account','account'],['dialect','dialect'],
  ['streamed','streamed'],['status','status'],['promptTokens','promptTokens'],
  ['completionTokens','completionTokens'],['reasoningTokens','reasoningTokens'],
  ['totalTokens','totalTokens'],['elapsedMs','elapsedMs'],['error','error'],
  ['ok','ok'],['stamp','stamp'],['tokenSummary','tokenSummary'],['elapsedText','elapsedText'],
]);

// 检查实际用到的但可能不存在的成员（从调用点提取）
const dynamic = [
  ['account.needsRefresh', src.includes('.needsRefresh')],
  ['account.phone', /\.phone\b/.test(src)],
  ['UIDevice.isLowPowerMode', src.includes('UIDevice.current.isLowPowerModeEnabled')],
  ['sync(enabled:) 单参', /KeepAlive\.shared\.sync\(enabled: [^,)]+\)/.test(src)],
];
for(const [label, hit] of dynamic) if(hit) problems.push('不应存在: '+label);

if(problems.length===0) console.log('LOCAL LINT OK');
else problems.forEach(p=>console.log('✘',p));
typeof account;

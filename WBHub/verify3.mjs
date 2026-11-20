import fs from 'node:fs';
import zlib from 'node:zlib';

// 从 cwd 逐级向上找 DSH-Go/WBHub-final/WBHub.ipa
function locate() {
  let dir = process.cwd();
  for (let i = 0; i < 5; i++) {
    const p = `${dir}/DSH-Go/WBHub-final/WBHub.ipa`;
    if (fs.existsSync(p)) return p;
    dir = dir.split('/').slice(0, -1).join('/');
    if (!dir) break;
  }
  return null;
}

const IPA = process.env.IPA || locate();
if (!IPA) { console.error('找不到 IPA'); process.exit(1); }
const b = fs.readFileSync(IPA);

function unzip(buf) {
  const eocd = buf.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  const total = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  const out = [];
  for (let i = 0; i < total; i++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) break;
    const m = buf.readUInt16LE(p + 10), c = buf.readUInt32LE(p + 20);
    const nl = buf.readUInt16LE(p + 28), el = buf.readUInt16LE(p + 30), cl = buf.readUInt16LE(p + 32);
    const lho = buf.readUInt32LE(p + 42);
    const name = buf.slice(p + 46, p + 46 + nl).toString();
    const lnl = buf.readUInt16LE(lho + 26), lel = buf.readUInt16LE(lho + 28);
    const st = lho + 30 + lnl + lel;
    out.push({ name, data: m === 0 ? buf.slice(st, st + c) : zlib.inflateRawSync(buf.slice(st, st + c)) });
    p += 46 + nl + el + cl;
  }
  return out;
}

const entries = unzip(b);
const bin = entries.find(x => x.name.endsWith('/WBHub'));
const u8 = bin.data.toString('utf8');

console.log('IPA:', b.length, 'bytes |', entries.length, 'entries');
console.log('二进制度:', bin.data.length);

const checks = [
  ['KeepAlive', '保活类'], ['LanIP', '局域网'], ['RequestLog', '请求日志'],
  ['bootstrap', '方法'], ['enterForeground', '方法'], ['enterBackground', '方法'],
  ['reassert', '方法'], ['silentWAV', '静音音频'],
  ['isBatteryMonitoringEnabled', '电池监测'], ['isLowPowerModeEnabled', '低电量'],
  ['thermalState', '温度'], ['refreshLanIP', 'IP刷新'],
  ['addRequestLog', '写日志'], ['clearRequestLogs', '清日志'], ['requestSummary', '汇总'],
  ['onlyCheckin', '仅签到'], ['creditDelta', '积分差值'], ['creditBefore', '积分基线'],
  ['creditAfter', '积分后值'], ['declaredCredit', '声明额度'],
  ['ModelsView', '模型页'], ['RequestLogView', '请求日志页'], ['Screen', '页面骨架'],
  ['TapRow', '可点击行'], ['PrimaryButton', '主按钮'], ['Num', '数值工具'],
];
let hit = 0;
for (const [k, t] of checks) {
  const ok = u8.includes(k);
  if (ok) hit++;
  console.log((ok ? '✔' : '✘'), k.padEnd(28), t);
}
console.log(`\n命中 ${hit}/${checks.length}`);

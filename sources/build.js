// 书源筛选一体化流水线：下载 → 去重 → 测速 → 产物（builtin-sources.json / selection.json / 报告）
// 复跑：node build.js     换新源：改 SRC_URL 后直接重跑
const fs = require('fs');
const path = require('path');

const SRC_URL = 'https://shuyuan-api.yiove.com/import/book-sources/1-80';
const dir = __dirname;
const KEEP_MAX_MS = 1500, OPT_MAX_MS = 2500;

const BUILTIN_HOSTS = ['libahao2.com','yewa.cc','quanben.io','52shuku.net','huangjinwu.org','min-yuan.com','shenwen.org','suduguu.com','sushujuan.cc'];
const ADULT = ['lanlanbo.com', 'fxshu.org', 'cool18.com', 'cdngwc.cc'];
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

const hostOf = url => { if (!/^https?:\/\//i.test(url || '')) return null; try { return new URL(url.split('##')[0].split('#')[0]).hostname.toLowerCase().replace(/^(www|m)\./, ''); } catch { return null; } };

async function download() {
  const f = path.join(dir, 'raw-sources.json');
  if (fs.existsSync(f)) return JSON.parse(fs.readFileSync(f, 'utf8'));
  const r = await fetch(SRC_URL);
  if (!r.ok) throw new Error('下载失败 HTTP ' + r.status);
  const text = await r.text();
  fs.writeFileSync(f, text, 'utf8');
  return JSON.parse(text);
}

function dedupe(raw) {
  const sorted = [...raw].sort((a, b) => (a.bookSourceType === 0 ? 0 : 1) - (b.bookSourceType === 0 ? 0 : 1));
  const seen = new Set(); const candidates = []; let dupBuiltin = 0, dupInner = 0, skip = 0;
  for (const s of sorted) {
    const host = hostOf(s.bookSourceUrl || '');
    if (!host) { skip++; continue; }
    if (BUILTIN_HOSTS.includes(host)) { dupBuiltin++; continue; }
    if (seen.has(host)) { dupInner++; continue; }
    seen.add(host);
    candidates.push({ name: s.bookSourceName, url: s.bookSourceUrl, host, type: s.bookSourceType || 0 });
  }
  return { candidates, dupBuiltin, dupInner, skip };
}

async function probe(baseUrl) {
  const attempts = [];
  for (let i = 0; i < 3; i++) {
    const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), 8000);
    const t0 = Date.now();
    try {
      const r = await fetch(baseUrl, { headers: { 'User-Agent': UA, Accept: 'text/html,*/*' }, redirect: 'follow', signal: ctl.signal });
      attempts.push({ ms: Date.now() - t0, status: r.status });
      r.body?.cancel().catch(() => {});
    } catch { attempts.push({ ms: null, status: 0 }); } finally { clearTimeout(timer); }
    await new Promise(r => setTimeout(r, 300));
  }
  const ok = attempts.map(a => a.ms).filter(m => m !== null).sort((a, b) => a - b);
  const median = ok.length ? ok[Math.floor(ok.length / 2)] : null;
  return {
    ms: ok.length ? ok[0] : null,                 // 最快
    med: median,                                  // 中位（判据）
    msMax: ok.length ? ok[ok.length - 1] : null,  // 最慢
    okCount: ok.length,
    status: attempts.find(a => a.ms !== null)?.status || 0,
  };
}

(async () => {
  const raw = await download();
  const { candidates, dupBuiltin, dupInner, skip } = dedupe(raw);
  console.log(`原始 ${raw.length} → 与现有一致 ${dupBuiltin}、内部重复 ${dupInner}、非网址 ${skip} → 候选 ${candidates.length}`);

  const testList = candidates.filter(c => c.type === 0 && !ADULT.includes(c.host));
  const otherList = candidates.filter(c => c.type !== 0);
  const adultList = candidates.filter(c => ADULT.includes(c.host));

  const speed = []; const queue = [...testList];
  await Promise.all(Array.from({ length: 4 }, async () => {
    while (queue.length) {
      const s = queue.shift();
      const r = await probe(s.url.split('##')[0].split('#')[0]);
      speed.push({ ...s, ...r });
      console.log('  ', s.host.padEnd(34), (r.ms === null ? 'FAIL' : r.ms + 'ms').padEnd(9), r.status || '');
    }
  }));
  fs.writeFileSync(path.join(dir, 'speedtest.json'), JSON.stringify(speed, null, 2), 'utf8');

  const entryOf = host => { for (const s of raw) { if (hostOf(s.bookSourceUrl || '') === host) return s; } return null; };
  const builtin = [], optional = [];
  for (const s of speed) {
    if (s.med !== null && s.okCount >= 2 && s.med <= KEEP_MAX_MS) builtin.push(s);
    else {
      const why = s.med === null ? '连接失败'
        : s.med > OPT_MAX_MS ? `太慢（中位 ${s.med}ms）`
        : `中位 ${s.med}ms 超 1.5s 门槛，备选（${s.ms}~${s.msMax}ms）`;
      optional.push({ ...s, why });
    }
  }
  adultList.forEach(a => optional.push({ ...a, ms: null, why: '成人内容，默认不含' }));
  otherList.forEach(o => optional.push({ ...o, why: '非文本类型，不适用' }));

  builtin.sort((a, b) => a.med - b.med);
  fs.writeFileSync(path.join(dir, 'builtin-sources.json'), JSON.stringify(builtin.map(b => entryOf(b.host)).filter(Boolean), null, 2), 'utf8');
  fs.writeFileSync(path.join(dir, 'selection.json'), JSON.stringify({ builtin, optional }, null, 2), 'utf8');

  // —— 报告 ——
  const L = [];
  L.push(`# 书源筛选报告（80 → ${9 + builtin.length} 内置）`, '');
  L.push(`> 数据来源：\`${SRC_URL}\`（阅读 3.0 格式，80 条）`);
  L.push('> 筛选时间：2026-10-15 ｜ 测速：本机直连，每站 3 次取中位数（并发 4），8s 超时', '');
  L.push('## 筛选规则', '');
  L.push('1. **去重**：与现有 9 个固化源同域名 → 剔除 19 条；内部重复 → 合并 15 条；非网址条目 → 跳过 5 条。');
  L.push('2. **测速**：每站 3 次取**中位数**，≤1.5s 才内置；超一点移入备选；>2.5s 或不通 → 剔除。');
  L.push('3. **类型**：仅保留文本小说（type=0）；漫画/音频/文件类 9 个不适用；成人内容 4 个默认不含。', '');
  L.push('> 注：测速受本机网络波动影响，个别站点在轮次间的响应差异较大（如「最终小说网」偶发尖峰）；判据取 3 次中位数，上线后由书源体检对持续超时的源自动标记兜底。', '');
  L.push('## 一、内置源 · 原有 9 个（现有爽阅工程，不变）', '', '| 站点 | 域名 |', '| --- | --- |');
  [['顶点小说（移动）','m.yewa.cc'],['速读谷','www.suduguu.com'],['黄金屋','www.huangjinwu.org'],['52书库','www.52shuku.net'],['神文小说','www.shenwen.org'],['素书卷','www.sushujuan.cc'],['篱笆好文学','m.libahao2.com'],['小原文学','www.min-yuan.com'],['全本小说网','quanben.io']].forEach(([n, d]) => L.push(`| ${n} | ${d} |`));
  L.push('', `## 二、内置源 · 新增 ${builtin.length} 个（按中位延迟排序，全部 ≤1.5s）`, '', '| # | 站点 | 域名 | 中位响应 | 最快~最慢 |', '| --- | --- | --- | --- | --- |');
  builtin.forEach((b, i) => L.push(`| ${i + 1} | ${b.name.replace(/\|/g, '/')} | ${b.host} | ${b.med}ms | ${b.ms}~${b.msMax}ms |`));
  L.push('', `## 三、未纳入的 ${optional.length} 个（含原因，可随时捞回）`, '', '| 站点 | 域名 | 原因 |', '| --- | --- | --- |');
  optional.forEach(o => L.push(`| ${o.name.replace(/\|/g, '/')} | ${o.host} | ${o.why} |`));
  L.push('', '## 四、重复剔除明细', '', '- 篱笆好文学 ×3（m.libahao2.com）', '- 速读谷 ×4（suduguu.com / www.suduguu.com）', '- 神文小说 ×4', '- 全本小说网 ×3（quanben.io / www.quanben.io）', '- 52书库 / 黄金屋 / 小原文学 / 顶点小说移动版 / 素书卷 各 ×1', '');
  L.push('## 五、产物文件', '', '| 文件 | 用途 |', '| --- | --- |');
  L.push(`| \`builtin-sources.json\` | ${builtin.length} 个新增源的完整「阅读 3.0」规则，打包进 \`assets/sources/\` 首启导入 |`);
  L.push('| `selection.json` / `speedtest.json` | 分组结果 / 测速原始数据 |', '| `raw-sources.json` | 原始 80 条留档 |', '| `build.js` | 一键复跑（改 SRC_URL 可用新链接） |');
  fs.writeFileSync(path.join(dir, '书源筛选报告.md'), L.join('\n'), 'utf8');

  console.log(`\n内置新增 ${builtin.length} 个 | 备选/排除 ${optional.length} 个 | 产物已写入 ${dir}`);
  optional.forEach(o => console.log('  -', o.host.padEnd(32), o.why));
})();

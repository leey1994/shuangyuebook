// 站点探针：不看「阅读」规则，只看 26 个站点现在真实返回什么。
// 目标：分类 可用 / JS锁 / 已死，为「原生固化实现」确定可抓清单。
// 运行：node tool/site_probe.js
const fs = require('fs');
const path = require('path');

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const KW = '斗破苍穹';
const KW_ENC = encodeURIComponent(KW);

const root = path.join(__dirname, '..');
const srcs = JSON.parse(fs.readFileSync(path.join(root, 'assets/sources/builtin_sources.json'), 'utf8')).sources;

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function grab(url, init = {}) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), 15000);
  try {
    const r = await fetch(url, {
      redirect: 'follow',
      signal: ctl.signal,
      headers: {
        'User-Agent': UA,
        Accept: 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        ...(init.headers || {}),
      },
      ...init,
    });
    const buf = Buffer.from(await r.arrayBuffer());
    let text = buf.toString('utf8');
    if ((text.match(/\uFFFD/g) || []).length > text.length / 50) {
      try { text = new TextDecoder('gbk').decode(buf); } catch {}
    }
    return { status: r.status, url: r.url, text };
  } catch (e) {
    return { status: 0, url, text: '', err: String(e && e.message || e) };
  } finally { clearTimeout(t); }
}

// 从书源规则里尽量还原搜索地址（GET/POST/常见模式兜底）
function candidates(s) {
  const out = [];
  const raw = String(s.searchUrl || '').trim();
  const base = String(s.bookSourceUrl || '').split('#')[0].split('##')[0].replace(/\/+$/, '');
  const fill = t => t.replace(/\{\{\s*key\s*\}\}/gi, KW_ENC).replace(/\{key\}/gi, KW_ENC)
      .replace(/\{\{\s*page\s*\}\}/gi, '1').replace(/\{page\}/gi, '1')
      .replace(/searchKey|searchKey/g, KW_ENC);
  // checkKeyWord / 直接 GET 模板
  if (raw && !/^@js:|^<js>/i.test(raw)) {
    const m = raw.match(/^([^,]+?),\s*(\{.*\})$/s);
    const urlPart = m ? m[1] : raw;
    let u = fill(urlPart.trim());
    if (!/^https?:/i.test(u)) u = base + (u.startsWith('/') ? '' : '/') + u;
    if (m) {
      let cfg = {};
      try { cfg = JSON.parse(fill(m[2])); } catch {}
      if (cfg.method === 'POST' || cfg.body) {
        out.push({ tag: '规则POST', url: u, method: 'POST', body: cfg.body || '', headers: cfg.headers || {} });
      } else out.push({ tag: '规则GET', url: u });
    } else out.push({ tag: '规则GET', url: u });
  } else {
    // JS 规则：抠出其中拼的静态地址或路径
    const seg = raw.replace(/^@js:?|^<js>|<\/js>$/gi, '');
    const m = seg.match(/(['"`])(\/[A-Za-z0-9_\-./]*(?:search|so|soso)[A-Za-z0-9_\-./]*)\1/i);
    if (m) out.push({ tag: 'JS-PATH', url: base + m[2] });
    out.push({ tag: 'JS-未知', url: '' });
  }
  // 通用模式兜底
  const pats = ['/search.php?keyword=', '/search.php?q=', '/s?q=', '/search?q=', '/search/?q=', '/search.html?q=', '/so.php?q=', '/search/?keyword=', '/index.php/search?keyword=', '/?s=', '/search/'];
  for (const p of pats) out.push({ tag: '通用' + p, url: base + p + encodeURIComponent(KW) });
  return out;
}

(async () => {
  for (let i = 0; i < srcs.length; i++) {
    const s = srcs[i];
    const name = String(s.bookSourceName || '?').slice(0, 30);
    const base = String(s.bookSourceUrl || '').split('#')[0].split('##')[0].replace(/\/+$/, '');
    // 1) 首页存活
    const home = await grab(base + '/');
    const homeFlag = home.err ? '网络X ' + home.err : `${home.status} ${home.text.length}B`;
    console.log(`\n== [${i}] ${name}  ${base}`);
    console.log(`   首页: ${homeFlag}`);
    if (home.err) continue;
    // 2) 依次试候选搜索
    const cands = candidates(s);
    for (const c of cands.slice(0, 6)) {
      if (!c.url) continue;
      const r = await grab(c.url, c.method === 'POST' ? {
        method: 'POST',
        body: c.body,
        headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8', Referer: base + '/', ...(c.headers || {}) },
      } : { headers: { Referer: base + '/' } });
      const hit = r.text.split(KW).length - 1;
      const flag = r.err ? '网络X ' + r.err : `${r.status} ${r.text.length}B 含词x${hit}`;
      console.log(`   ${c.tag}: ${flag}  ${r.url !== c.url ? '→ ' + r.url : ''}`);
      if (!r.err && r.status === 200 && hit > 0) {
        console.log(`   >>> 命中搜索: ${c.method || 'GET'} ${c.url}`);
        break;
      }
      await sleep(300);
    }
  }
})();

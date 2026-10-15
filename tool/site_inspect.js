// 站点结构取样：抓候选站点的搜索页存盘（tool/.probe/*.html），供写原生适配器时读结构。
// 运行：node tool/site_inspect.js [keywords...]
const fs = require('fs');
const path = require('path');

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const KW = process.argv[2] || '斗破苍穹';
const KWU = encodeURIComponent(KW);
const outDir = path.join(__dirname, '.probe');
fs.mkdirSync(outDir, { recursive: true });

async function grab(url, init = {}) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), 20000);
  try {
    const r = await fetch(url, {
      redirect: 'follow', signal: ctl.signal,
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
    let enc = 'utf8';
    if ((text.match(/\uFFFD/g) || []).length > text.length / 100) {
      try { text = new TextDecoder('gbk').decode(buf); enc = 'gbk'; } catch {}
    }
    return { status: r.status, url: r.url, text, enc };
  } catch (e) {
    return { status: 0, url, text: '', enc: '-', err: String((e && e.message) || e) };
  } finally { clearTimeout(t); }
}

const sites = [
  { key: 'sudugu', tag: '伪速读谷-搜索POST', url: 'https://www.sudugu.cc/modules/article/search.php', method: 'POST', body: `searchkey=${KWU}&searchtype=articlename&action=login` },
  { key: 'sudugu-get', tag: '伪速读谷-搜索GET', url: `https://www.sudugu.cc/modules/article/search.php?searchkey=${KW}&searchtype=articlename` },
  { key: 'deqixss', tag: '得奇-搜索POST', url: 'https://www.deqixss.com/modules/article/search.php', method: 'POST', body: `searchkey=${KWU}&searchtype=all` },
  { key: 'deqixss-get', tag: '得奇-搜索GET', url: `https://www.deqixss.com/modules/article/search.php?searchkey=${KW}&searchtype=all` },
  { key: 'gdbzkz', tag: '鬼吹灯-搜索', url: `http://www.gdbzkz.la/s.php?ie=utf-8&q=${KWU}` },
  { key: 'douyinxs', tag: '抖音小说-搜索POST', url: 'https://www.douyinxs.com/search/', method: 'POST', body: `searchkey=${KWU}&submit=` },
  { key: 'sanyt', tag: '若雨中文-搜索', url: `http://www.3yt.info/book/search.aspx?searchkey=${KWU}&SeaButton=` },
  { key: 'gushizu', tag: '故事族-搜索', url: `https://www.gushizu.com/novel/search/result?searchkey=${KWU}` },
  { key: 'longshuwu', tag: '新龙-搜索', url: `https://wap.longshuwu.com/search/?q=${KWU}` },
  { key: 'zuizhong', tag: '最终小说网-搜索POST', url: 'https://www.zuizhong.net/search.html', method: 'POST', body: `s=${KWU}` },
  { key: 'washai', tag: '书海阁-首页', url: 'https://book.washai.net/' },
];

(async () => {
  for (const s of sites) {
    const r = await grab(s.url, s.method === 'POST' ? {
      method: 'POST', body: s.body,
      headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8', Referer: new URL(s.url).origin + '/' },
    } : {});
    const hit = (r.text.split(KW).length - 1);
    console.log(`${s.key.padEnd(12)} ${String(r.status).padEnd(5)} ${String(r.text.length).padEnd(8)}B 编码:${r.enc} 含词x${hit} ${r.err || ''} ${r.url !== s.url ? '→ ' + r.url : ''}`);
    if (r.text) fs.writeFileSync(path.join(outDir, s.key + '.html'), r.text, 'utf8');
  }
})();

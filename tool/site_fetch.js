// 指定 URL 取样存盘：node tool/site_fetch.js 名字=URL [名字=URL ...]
// 存到 tool/.probe/名字.html
const fs = require('fs');
const path = require('path');
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const outDir = path.join(__dirname, '.probe');
fs.mkdirSync(outDir, { recursive: true });

(async () => {
  for (const arg of process.argv.slice(2)) {
    const eq = arg.indexOf('=');
    const name = arg.slice(0, eq);
    const url = arg.slice(eq + 1);
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 30000);
    try {
      const r = await fetch(url, {
        redirect: 'follow', signal: ctl.signal,
        headers: { 'User-Agent': UA, Accept: 'text/html,application/xhtml+xml,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9' },
      });
      const buf = Buffer.from(await r.arrayBuffer());
      let text = buf.toString('utf8'), enc = 'utf8';
      if ((text.match(/\uFFFD/g) || []).length > text.length / 100) {
        try { text = new TextDecoder('gbk').decode(buf); enc = 'gbk'; } catch {}
      }
      fs.writeFileSync(path.join(outDir, name + '.html'), text, 'utf8');
      console.log(`${name.padEnd(16)} ${r.status} ${text.length}B 编码:${enc} → ${r.url}`);
    } catch (e) {
      console.log(`${name.padEnd(16)} 失败: ${(e && e.message) || e}`);
    } finally { clearTimeout(t); }
  }
})();

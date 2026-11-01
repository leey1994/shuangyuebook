# 书源生成原型（AI 生成「阅读 3.0」书源）

**结论：可行，且已用真实站点跑通「生成 → 校验 → 实测」闭环。**
本目录是独立验证环境，不影响 App 主代码。

## 已跑通的证据

对 `https://book.sfacg.com`（SF轻小说桌面站）生成的候选书源
（`candidates/sfacg_desktop.json`），用**本仓库自己的解析引擎**实测：

```
搜索      OK  342ms  拿到 30 条
详情/目录 OK  648ms  书名=卷刃长剑和某失恋村民…，目录 2162 章
正文      OK  229ms  403 字：为了免得天天被人说抄袭之类的…
```

搜索页是 `http://s.sfacg.com/?Key={{key}}&S=1&SS=0`（GBK），
详情/目录/正文走 `book.sfacg.com` 静态页；规则全部由模型侧生成，
没有复用仓库内置的 SF 源。

## 书源格式要点（模型需要知道的）

一个书源 = 顶层元信息 + 4 个规则对象：

| 对象 | 作用 | 关键字段 |
| --- | --- | --- |
| `ruleSearch` | 搜索结果列表 | `bookList` `name` `author` `bookUrl` `coverUrl` |
| `ruleBookInfo` | 书页详情 | `name` `author` `coverUrl` `intro` `tocUrl` `lastChapter` |
| `ruleToc` | 章节目录 | `chapterList` `chapterName` `chapterUrl` |
| `ruleContent` | 正文 | `content`（常用 `#id@html`） |

规则语法（本仓库 `analyze_css.dart` 支持）：

- `选择器@属性`，属性可为 `text` / `html` / `href` / `src` / 任意属性名；
- `class.xxx` / `id.xxx` / `tag.li` / 原生 CSS；`a.0`、`:eq(n)`、`:first`、`:has(x)`、`:contains(文字)`；
- 清洗 `规则##正则##替换`（可多段，替换为空只写 `规则##正则`）；
- 拼接 `规则1&&规则2`；搜索关键词固定用 `{{key}}`。

## 生成流水线（`generator.dart`）

```
1. 抓页面 → 去 script/style/注释压缩（slimHtml）
2. 拼 prompt（格式 + 语法 + 页面片段）→ OpenAI 兼容 /chat/completions
3. 容错解析模型输出（允许 ```json 包裹 / 前后废话）→ BookSource
4. 用本仓库引擎实测：搜索 → 详情/目录 → 正文
5. 失败项作为 feedback 回灌，最多重试 N 轮
```

第 4 步是可行性关键：模型输出不可信，必须落到真实引擎上跑一遍才算生成成功。
正文步骤会试前 8 章（卷首/作者删章/VIP 章很常见）。

## 验证命令

```bash
# 与真实站点跑闭环（会联网）
flutter test tool/source_gen_probe/probe_test.dart

# 接真实模型（OpenAI 兼容接口；不填则跳过该用例）
flutter test tool/source_gen_probe/probe_test.dart \
  --dart-define=LLM_BASE_URL=https://api.openai.com/v1 \
  --dart-define=LLM_API_KEY=sk-... \
  --dart-define=LLM_MODEL=gpt-4o-mini
```

## 已集成进 App

- 实现：`lib/legado/source_generator.dart`（生成器 + 实测探针，本目录的
  `probe_test.dart` 也直接引用它）。
- 入口：书源管理 →「+」→ **用 AI 生成书源**。
- 模型配置页：接口地址 / API Key / 型号；型号走 `GET /models` 自动获取，
  拉不到自动切手填；Key 存 SharedPreferences，随备份导出。
- 生成页：站点地址 + 关键词示例 + 可选搜索地址模板（给了模板模型能直接看到
  搜索结果页结构），生成过程逐步上屏，实测通过才入库。

## 风险与限制（决定这个功能能覆盖多少站）

1. **纯 JS 渲染 / 令牌墙站点**：静态 HTTP 拿不到正文，需要先用隐藏 WebView
   （Android 已有 `WebViewEngine`）渲染再喂模型；桌面端只能跳过或提示。
2. **搜索是 POST / 需要签名的站**：模型看不到请求参数，需要让用户补一个
   「搜索页 URL 示例」，或直接把 `searchUrl` 模板喂给它。
3. **成本与延迟**：每轮几万 token、1~3 轮，生成一个源约 10~60 秒；必须有进度与超时。
4. **模型质量**：建议用结构化输出能力强的模型；本仓库的容错解析 + 实测重试是兜底。
5. **站点改版即失效**：AI 生成的是「此刻的结构」，改版后要重新生成（这也是阅读类工具的常态）。
6. **合规**：只生成抓取规则，不把正文入库；仍由用户决定抓哪些站。

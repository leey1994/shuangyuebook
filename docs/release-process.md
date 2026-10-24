# 发版流程（GitHub Actions 自动化）

正式安装包由 `.github/workflows/release.yml` 自动产出，不再手动 `flutter build`
→ 改版本号 → 拖文件上传。本文记录工作流的行为与约定，改动工作流前先读一遍。

## 触发

| 方式 | 说明 |
| --- | --- |
| push 到 `main` | 正常发版路径。`.github/**`、`**/*.md`、`docs/**` 的改动**不触发**——文档、公告、官网更新不该发行 |
| Actions 页手动 `workflow_dispatch` | 立刻按当前最新 tag 的下一版再发一次 |

同一仓库同一时间只跑一个发版任务（`concurrency: release`），不会并发出两版。

## 版本号

* `X.Y.Z` 来自**最新 git tag**（`git describe --tags --match 'v*' --abbrev=0`），
  没有 tag 时退回读 `pubspec.yaml`；默认 **patch +1**。
* commit message 控制档位：

  | 写法 | 效果 |
  | --- | --- |
  | 无 | `v1.0.4` → `v1.0.5` |
  | `#minor` | `v1.0.4` → `v1.1.0` |
  | `#major` | `v1.0.4` → `v2.0.0` |
  | `#norelease` | 跳过本次发版 |

* 构建号 `B = git rev-list --count HEAD`（仓库提交总数，单调递增），
  最终写入 `pubspec.yaml` 的 `version: X.Y.Z+B`。
  App 内 `compareVersion` 只比 `X.Y.Z`，`+B` 仅供「我的 → 关于」展示。
* 注意：`workflow_dispatch` 重跑时版本按**当前最新 tag**重算，不是读 `pubspec.yaml`。
  如果上一次发版在建好 tag 之后、回写提交之前失败，重跑会跳一个版本号
  （tag 已推进而 pubspec 没跟上）——此时手动改 `pubspec.yaml` 对齐或删掉多余 tag 再重跑。

## 产物

| 资产 | 产出 |
| --- | --- |
| `ShuangYue-vX.Y.Z+B-arm64-v8a.apk` | `flutter build apk --release --split-per-abi`，64 位机型首选 |
| `ShuangYue-vX.Y.Z+B-armeabi-v7a.apk` | 同上，32 位老机型 |
| `ShuangYue-vX.Y.Z+B-windows-x64.zip` | `flutter build windows --release` 整目录打包，**先编译 `updater.exe` 放进 `Release/`**，exe 在压缩包根目录 |
| `SHA256SUMS.txt` | 以上三个产物的 SHA-256 |

命名里的 `arm64-v8a` / `armeabi-v7a` / `windows-x64` 是 App 内「检查更新」按架构挑包的
依据（见 `lib/update_check.dart` 的 `assetAbiTag` / `pickApkUrl`），**不要改**。
x86_64 包按惯例不发布（模拟器用户自行源码构建，见 README「从源码构建」）。

## 构建环境

* Flutter 固定 `3.47.1`（与本地开发版、`.metadata` 一致）；项目升级 Flutter 时
  同步改工作流里的 `flutter-version`（两处：Android / Windows job）。
* Android release 签名用 `android/app/build.gradle.kts` 里既有的 debug signingConfig，
  CI 无需任何 secret。**若要换正式签名，把密钥做成 Repository Secrets 并改 build.gradle.kts，
  工作流不用动。**
* 工作流只加了 `contents: write` 权限，用于推 tag、建 Release、回写提交。

## 工作流末尾自动完成的同步

发版成功后 release job 会把这些文件改到新版本号并提交
（`chore(release): vX.Y.Z+B [skip ci]`，用 GITHUB_TOKEN 推送不会再次触发工作流）：

* `pubspec.yaml` —— `version: X.Y.Z+B`（权威版本号）
* `README.md` —— 当前版本行、下载表文件名、`--dart-define=APP_VERSION=` 示例
* `docs/index.html` —— 页内 `FALLBACK` 默认版本号、release-notes 链接
  （页面运行时仍以 GitHub Release tag 与 `announcement.json` 的更高者为准）
* `docs/release-notes-vX.Y.Z.md` —— 自动生成的提交清单，**人工补充用户向说明后自行提交**

`docs/announcement.json` **不自动改**：公告 id / 文案 / 生效开关是编辑内容，发版后按需手改
（官网页首与 App 内公告会读它）。

## 常见问题

* **只想推文档/改配置，不想发版**：commit message 加 `#norelease`；
  或者只动 `docs/**`、`**/*.md`、`.github/**`（这些路径本来就不触发）。
* **构建失败**：workflow 在建 Release 之前失败，tag 不会创建，修复后重跑即可；
  失败发生在建 tag 之后时会跳过版本号，见上文「版本号」末尾。
* **发版想带一段用户向的更新说明**：改 `docs/release-notes-vX.Y.Z.md` 提交即可，
  官网 `index.html` 的链接指向它。

// 桌宠的全局动作总线。
//
// 软件里每一次「用户做了什么」都在这里登记一条 [PetAction]，由 [reactionFor]
// 翻译成宠物的反应：给多少成长值、什么情绪、说什么话。
//
// 加一个新动作只要在 [PetAction] 里加一项、在下面的表里加一行；
// 动作点那边调用 [PetStore.emit] 一行即可，不用碰任何 UI。
import 'pet_painter.dart';

enum PetAction {
  // 阅读
  openBook('打开书'),
  exitBook('合上书'),
  nextChapter('下一章'),
  prevChapter('上一章'),
  finishBook('读完一本'),
  addBookmark('加书签'),
  removeBookmark('删书签'),

  // 书架
  shelfSort('换排序'),
  shelfView('换视图'),
  shelfRemove('移出书架'),
  shelfClear('清空书架'),
  importLocal('导入本地书'),

  // 找书
  search('搜索'),
  searchClear('清空搜索'),
  searchOpen('找到一本书'),
  discoverOpen('随便逛逛'),
  downloadBook('下载整本'),

  // 书源
  sourceImport('导入书源'),
  sourceHealthy('书源体检'),
  sourceFailed('书源失效'),
  sourceRemove('删除书源'),

  // 外观 / 设置
  themeChange('换主题'),
  fontChange('换字体'),
  fontSizeChange('改字号'),
  pageModeChange('换翻页'),
  backgroundChange('换背景'),
  settingChange('改设置'),
  petToggle('开关桌宠'),

  // 阅读辅助
  ttsPlay('朗读'),
  ttsStop('停朗读'),

  // 系统
  checkUpdate('检查更新'),
  foundUpdate('有新版'),
  notice('公告'),
  openExternal('外部打开'),
  clearCache('清缓存'),
  exportData('导出'),

  // 直接摸
  petTap('摸一下');

  const PetAction(this.label);

  final String label;
}

/// 一个动作对应的宠物反应。
class PetReaction {
  const PetReaction({this.exp = 0, this.mood, this.lines = const []});

  /// 额外成长值（阅读时长那份不在这儿，见 PetStore.exp）。
  final int exp;

  /// 触发的情绪；null 表示沿用当前情绪。
  final PetMood? mood;

  /// 候选台词。为空 = 只长数值/变情绪，不说话（免得刷屏）。
  final List<String> lines;
}

/// 动作 → 反应。台词写短一点：气泡只有 230px 宽，还要半透明浮在正文上。
///
/// 返回值一定非空：没打算说话的动作给一个 [PetReaction]（`lines` 为空）就行 ——
/// switch 表达式对枚举是穷尽的，以后新增动作忘了配会**编译期**报错，
/// 不至于漏到运行时才发现「这个动作点了没反应」。
PetReaction reactionFor(PetAction a, PetStage stage) => switch (a) {
      PetAction.openBook =>
        const PetReaction(mood: PetMood.focus, lines: ['翻开了一页。', '开始读了。']),
      PetAction.exitBook =>
        const PetReaction(mood: PetMood.calm, lines: ['合上了。歇会儿。', '随时可以接着看。']),
      PetAction.nextChapter => const PetReaction(lines: ['下一章。', '接着走。']),
      PetAction.prevChapter => const PetReaction(lines: ['往回翻。', '再看看前面。']),
      PetAction.finishBook =>
        const PetReaction(exp: 20, mood: PetMood.cheer, lines: [
          '这本书读完了。',
          '又一本。你读得真稳。',
        ]),
      PetAction.addBookmark => const PetReaction(
          exp: 1, mood: PetMood.cheer, lines: ['标好了，不会丢。', '记下来了。']),
      PetAction.removeBookmark =>
        const PetReaction(mood: PetMood.sad, lines: ['删掉了。确定不要了？']),
      PetAction.shelfSort =>
        const PetReaction(exp: 1, lines: ['换个看法。', '这样找书快一点。']),
      PetAction.shelfView =>
        const PetReaction(exp: 1, lines: ['排成你顺手的样子。', '换了个样子看你。']),
      PetAction.shelfRemove =>
        const PetReaction(mood: PetMood.sad, lines: ['从书架上拿走了。', '这一本先收起来了。']),
      PetAction.shelfClear =>
        const PetReaction(mood: PetMood.sad, lines: ['都清空了。', '书架空了也别急。']),
      PetAction.importLocal => const PetReaction(
          exp: 8, mood: PetMood.cheer, lines: ['捡到一本新书。', '本地书收好了。']),
      PetAction.search => const PetReaction(
          exp: 2, mood: PetMood.focus, lines: ['找找看。', '我帮你一起找。']),
      PetAction.searchClear => const PetReaction(lines: ['不找了？', '清干净了。']),
      PetAction.searchOpen => const PetReaction(
          exp: 15, mood: PetMood.cheer, lines: ['这本看着像。', '找到了就去读吧。']),
      PetAction.discoverOpen =>
        const PetReaction(exp: 1, lines: ['随便翻翻也好。', '不一定看，但看看不亏。']),
      PetAction.downloadBook => const PetReaction(
          exp: 12, mood: PetMood.cheer, lines: ['整本存好了，没网也能看。', '下载完了。']),
      PetAction.sourceImport => const PetReaction(
          exp: 5, mood: PetMood.cheer, lines: ['多了一个能用的书源。', '书源收下了。']),
      PetAction.sourceHealthy =>
        const PetReaction(mood: PetMood.cheer, lines: ['书源都还活着。', '今天体检全过。']),
      PetAction.sourceFailed => const PetReaction(
          mood: PetMood.sad, lines: ['有几个书源失效了，去「阅读记录」看看。', '有源坏了，别急，换一个就行。']),
      PetAction.sourceRemove =>
        const PetReaction(mood: PetMood.sad, lines: ['这个源不用了。']),
      PetAction.themeChange =>
        const PetReaction(exp: 1, lines: ['换个颜色，眼睛舒服点。', '这样看着不累。']),
      PetAction.fontChange =>
        const PetReaction(exp: 1, lines: ['字换了。', '这个字顺眼吗？']),
      PetAction.fontSizeChange =>
        const PetReaction(exp: 1, lines: ['字号调好了。', '这个大小看得清吗？']),
      PetAction.pageModeChange =>
        const PetReaction(exp: 1, lines: ['换个翻法。', '这样翻更顺手。']),
      PetAction.backgroundChange =>
        const PetReaction(exp: 1, lines: ['背景换了。', '这个色护眼。']),
      PetAction.settingChange => const PetReaction(lines: ['调好了。', '记住了。']),
      // 开关桌宠本身是个哑动作：正关着的时候没气泡可言，所以只记情绪不说话
      PetAction.petToggle => const PetReaction(mood: PetMood.calm),
      PetAction.ttsPlay =>
        const PetReaction(mood: PetMood.focus, lines: ['我念给你听。', '闭上眼睛也行。']),
      PetAction.ttsStop => const PetReaction(lines: ['不念了。', '自己看也挺好。']),
      PetAction.checkUpdate => const PetReaction(lines: ['看看有没有新的。']),
      PetAction.foundUpdate =>
        const PetReaction(mood: PetMood.cheer, lines: ['有新版了。', '可以更新了。']),
      PetAction.notice => const PetReaction(lines: ['刚发了公告。', '你看看。']),
      PetAction.openExternal => const PetReaction(
          exp: 3, mood: PetMood.focus, lines: ['从外面带进来一本。', '接着上次的地方。']),
      PetAction.clearCache =>
        const PetReaction(mood: PetMood.sad, lines: ['缓存清了，会重新下载。']),
      PetAction.exportData => const PetReaction(exp: 2, lines: ['数据留了份备份。']),

      // 摸它：台词随形态变，从怯生生到从容
      PetAction.petTap => switch (stage) {
          PetStage.drop =>
            const PetReaction(exp: 1, mood: PetMood.cheer, lines: [
              '…（蹭了蹭你的手指）',
              '嗯？我在。',
            ]),
          PetStage.paper =>
            const PetReaction(exp: 1, mood: PetMood.cheer, lines: [
              '嗯？我在。',
              '再摸一下，就一下。',
            ]),
          PetStage.fox =>
            const PetReaction(exp: 1, mood: PetMood.cheer, lines: [
              '再摸一下，就一下。',
              '（墨尾巴摇了摇）',
            ]),
          PetStage.spirit =>
            const PetReaction(exp: 1, mood: PetMood.cheer, lines: [
              '你的心事，可以先放这儿。',
              '我在。不着急说。',
            ]),
        },
    };

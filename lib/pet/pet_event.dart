// 桌宠的全局动作总线。
//
// 软件里每一次「用户做了什么」都在这里登记一条 [PetAction]，由 [reactionFor]
// 翻译成宠物的反应：给多少成长值、什么情绪、说什么话。
//
// 加一个新动作只要在 [PetAction] 里加一项、在下面的表里加一行；
// 动作点那边调用 [PetStore.emit] 一行即可，不用碰任何 UI。
//
// 规矩：每个动作至少 5 条台词（不然反复用同一句太假），全部合计远多于 60 条。
// test/pet_test.dart 会对这个下限做回归校验。
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
  /// 气泡只显示一行，所以每条都控制在十几个字以内。
  final List<String> lines;
}

/// 动作 → 反应。
///
/// 返回值一定非空：没打算说话的动作给一个 [PetReaction]（`lines` 为空）就行 ——
/// switch 表达式对枚举是穷尽的，以后新增动作忘了配会**编译期**报错，
/// 不至于漏到运行时才发现「这个动作点了没反应」。
PetReaction reactionFor(PetAction a, PetStage stage) => switch (a) {
      PetAction.openBook => const PetReaction(mood: PetMood.focus, lines: [
          '翻开了一页。',
          '开始读了。',
          '进来坐。',
          '今天从这儿开始。',
          '读到哪页我记着。',
          '好，开始。',
        ]),
      PetAction.exitBook => const PetReaction(mood: PetMood.calm, lines: [
          '合上了。',
          '歇会儿。',
          '随时接着看。',
          '读到这儿。',
          '位置记住了。',
          '下次见。',
        ]),
      PetAction.nextChapter => const PetReaction(lines: [
          '下一章。',
          '接着走。',
          '翻过去。',
          '新的。',
          '往前走。',
          '后面还有。',
        ]),
      PetAction.prevChapter => const PetReaction(lines: [
          '往回翻。',
          '再看看前面。',
          '回去一点。',
          '这里看过了。',
          '翻回去。',
        ]),
      PetAction.finishBook =>
        const PetReaction(exp: 20, mood: PetMood.cheer, lines: [
          '这本书读完了。',
          '又一本。',
          '你读得真稳。',
          '读完啦。',
          '一本收进书架。',
        ]),
      PetAction.addBookmark =>
        const PetReaction(exp: 1, mood: PetMood.cheer, lines: [
          '标好了，不会丢。',
          '记下来了。',
          '加个书签。',
          '存住了。',
          '回头找得到。',
        ]),
      PetAction.removeBookmark => const PetReaction(mood: PetMood.sad, lines: [
          '删掉了。',
          '确定不要了？',
          '拿掉了。',
          '好吧。',
          '清掉一个。',
        ]),
      PetAction.shelfSort => const PetReaction(exp: 1, lines: [
          '换个看法。',
          '这样找书快一点。',
          '排一排。',
          '顺序换了。',
          '按你的习惯来。',
        ]),
      PetAction.shelfView => const PetReaction(exp: 1, lines: [
          '排成你顺手的样子。',
          '换了个样子看你。',
          '布局换了。',
          '这样清爽点。',
          '变了个排法。',
        ]),
      PetAction.shelfRemove => const PetReaction(mood: PetMood.sad, lines: [
          '从书架上拿走了。',
          '这本先收起来。',
          '嗯，移走了。',
          '书架少了一本。',
          '放回来看吗？',
        ]),
      PetAction.shelfClear => const PetReaction(mood: PetMood.sad, lines: [
          '都清空了。',
          '空了也别急。',
          '清干净了。',
          '重新来过。',
          '空的也清爽。',
        ]),
      PetAction.importLocal =>
        const PetReaction(exp: 8, mood: PetMood.cheer, lines: [
          '捡到一本新书。',
          '本地书收好了。',
          '加进来了。',
          '又多一本。',
          '存好了。',
        ]),
      PetAction.search =>
        const PetReaction(exp: 2, mood: PetMood.focus, lines: [
          '找找看。',
          '我帮你一起找。',
          '搜一下。',
          '翻翻看有没有。',
          '在找了。',
          '关键词对不对？',
        ]),
      PetAction.searchClear => const PetReaction(lines: [
          '不找了？',
          '清干净了。',
          '重来。',
          '擦干净。',
          '搜索框空了。',
        ]),
      PetAction.searchOpen =>
        const PetReaction(exp: 15, mood: PetMood.cheer, lines: [
          '这本看着像。',
          '找到了就去读吧。',
          '就这本。',
          '点开了。',
          '嗯，这本不错。',
        ]),
      PetAction.discoverOpen => const PetReaction(exp: 1, lines: [
          '随便翻翻也好。',
          '看看不亏。',
          '逛逛。',
          '说不定有惊喜。',
          '看看有什么。',
        ]),
      PetAction.downloadBook =>
        const PetReaction(exp: 12, mood: PetMood.cheer, lines: [
          '整本存好了。',
          '没网也能看了。',
          '下载完了。',
          '存本地了。',
          '随时能开。',
        ]),
      PetAction.sourceImport =>
        const PetReaction(exp: 5, mood: PetMood.cheer, lines: [
          '多了一个能用的书源。',
          '书源收下了。',
          '新书源加入。',
          '又多一个能找的。',
          '装好了。',
        ]),
      PetAction.sourceHealthy => const PetReaction(mood: PetMood.cheer, lines: [
          '书源都还活着。',
          '今天体检全过。',
          '都没问题。',
          '还能用。',
          '检查完了，挺好。',
        ]),
      PetAction.sourceFailed => const PetReaction(mood: PetMood.sad, lines: [
          '有几个书源失效了。',
          '去阅读记录看看。',
          '换一个就行。',
          '别急，能补。',
          '有的源坏了。',
        ]),
      PetAction.sourceRemove => const PetReaction(mood: PetMood.sad, lines: [
          '这个源不用了。',
          '移除了。',
          '删掉了。',
          '拿掉了。',
          '少一个。',
        ]),
      PetAction.themeChange => const PetReaction(exp: 1, lines: [
          '换个颜色，眼睛舒服点。',
          '这样看着不累。',
          '主题换了。',
          '顺眼多了。',
          '换个色调。',
        ]),
      PetAction.fontChange => const PetReaction(exp: 1, lines: [
          '字换了。',
          '这个字顺眼吗？',
          '换字体了。',
          '看着舒服点。',
          '字不一样了。',
        ]),
      PetAction.fontSizeChange => const PetReaction(exp: 1, lines: [
          '字号调好了。',
          '这个大小看得清吗？',
          '大了点。',
          '舒服些了吗？',
          '大小合适吗？',
        ]),
      PetAction.pageModeChange => const PetReaction(exp: 1, lines: [
          '换个翻法。',
          '这样翻更顺手。',
          '翻页方式换了。',
          '试试这个。',
          '手感不一样。',
        ]),
      PetAction.backgroundChange => const PetReaction(exp: 1, lines: [
          '背景换了。',
          '这个色护眼。',
          '换个底色。',
          '看着柔和些。',
          '颜色换了。',
        ]),
      PetAction.settingChange => const PetReaction(lines: [
          '调好了。',
          '记住了。',
          '嗯，这样。',
          '收到。',
          '照你说的。',
        ]),
      // 开关桌宠本身是个哑动作：正关着的时候没气泡可言，所以只记情绪不说话
      PetAction.petToggle => const PetReaction(mood: PetMood.calm),
      PetAction.ttsPlay => const PetReaction(mood: PetMood.focus, lines: [
          '我念给你听。',
          '闭上眼睛也行。',
          '我读，你听。',
          '慢慢听。',
          '开始念了。',
        ]),
      PetAction.ttsStop => const PetReaction(lines: [
          '不念了。',
          '自己看也挺好。',
          '停了。',
          '安静点了。',
          '不听了。',
        ]),
      PetAction.checkUpdate => const PetReaction(lines: [
          '看看有没有新的。',
          '检查一下版本。',
          '查查更新。',
          '看看有没有好事。',
          '在查了。',
        ]),
      PetAction.foundUpdate => const PetReaction(mood: PetMood.cheer, lines: [
          '有新版了。',
          '可以更新了。',
          '新版本来了。',
          '去看看。',
          '该更新啦。',
        ]),
      PetAction.notice => const PetReaction(lines: [
          '刚发了公告。',
          '你看看。',
          '有新通知。',
          '公告来了。',
          '看一眼。',
        ]),
      PetAction.openExternal =>
        const PetReaction(exp: 3, mood: PetMood.focus, lines: [
          '从外面带进来一本。',
          '接着上次的地方。',
          '外面打开的。',
          '接着读。',
          '接上了。',
        ]),
      PetAction.clearCache => const PetReaction(mood: PetMood.sad, lines: [
          '缓存清了，会重新下载。',
          '清干净了。',
          '腾出空间了。',
          '要重新下一遍。',
          '清掉了。',
        ]),
      PetAction.exportData => const PetReaction(exp: 2, lines: [
          '数据留了份备份。',
          '导出好了。',
          '存了一份。',
          '备份完成。',
          '拿走了。',
        ]),

      // 摸它：台词随形态变，从怯生生到从容
      PetAction.petTap => switch (stage) {
          PetStage.drop =>
            const PetReaction(exp: 1, mood: PetMood.cheer, lines: [
              '…（蹭了蹭手指）',
              '嗯？我在。',
              '（安静地看着你）',
              '（往手上贴了贴）',
              '在呢。',
            ]),
          PetStage.paper =>
            const PetReaction(exp: 1, mood: PetMood.cheer, lines: [
              '嗯？我在。',
              '再摸一下。',
              '（靠过来一点）',
              '手别停。',
              '舒服。',
            ]),
          PetStage.fox =>
            const PetReaction(exp: 1, mood: PetMood.cheer, lines: [
              '再摸一下，就一下。',
              '（墨尾巴摇了摇）',
              '手别停。',
              '继续啊。',
              '嘿嘿。',
            ]),
          PetStage.spirit =>
            const PetReaction(exp: 1, mood: PetMood.cheer, lines: [
              '你的心事，可以先放这儿。',
              '我在，不着急说。',
              '（书页转了一圈）',
              '说吧，我听着。',
              '不着急。',
            ]),
        },
    };

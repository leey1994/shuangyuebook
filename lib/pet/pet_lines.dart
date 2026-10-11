// 桌宠的「按场景」台词：问候、久别、连续天数、护眼、摸鱼、升阶。
//
// 原则仍然是**先关心人，再谈养成**：不催更、不施压、不拿「你今天还没读」
// 当开场白。优先级：深夜劝睡 > 久坐护眼 > 久别问候 > 日常闲聊 > 成长播报。
//
// 每个场景至少 5 条，随机取一条；全部场景合计远多于 60 条。
// test/pet_test.dart 会对这两个下限做回归校验，别随手删到不够数。
import 'pet_painter.dart';

/// 一个场景 = 一组候选台词。
class PetScene {
  const PetScene(this.id, this.lines);

  final String id;
  final List<String> lines;
}

/// 按场景取一句。同一天同一场景内轮换，不会连着重复。
String petLine(PetScene scene, {int day = -1, int turn = 0}) {
  if (scene.lines.isEmpty) return '';
  final d = day >= 0 ? day : DateTime.now().day;
  // 用「天 + 轮次」散列，保证同一轮里顺序稳定、跨轮才换
  final i = (scene.id.hashCode + d * 31 + turn * 17).abs() % scene.lines.length;
  return scene.lines[i];
}

/// 按时段问候。[now] 决定语气，深夜（23:00–05:00）自动切到劝睡语气。
PetScene greetingScene(DateTime now) {
  final h = now.hour;
  if (h >= 23 || h < 5) {
    return const PetScene('night', [
      '很晚了。',
      '困了就先睡吧。',
      '明天还有明天的事。',
      '我陪你到你放下书。',
      '别熬了，书不会跑。',
      '夜深了，慢慢看也行。',
    ]);
  }
  if (h < 8) {
    return const PetScene('dawn', [
      '这个点醒着的，有理由吧。',
      '天还没亮透，不着急。',
      '先喝口水。',
      '这么早，我陪你。',
      '慢慢来，不赶。',
      '醒了就好，不急着看。',
    ]);
  }
  if (h < 11) {
    return const PetScene('morning', [
      '早上好。',
      '记得吃早饭。',
      '精神不错，看看几章？',
      '早，这个点记得最牢。',
      '新的一天，翻一页。',
      '今天想读哪本？',
    ]);
  }
  if (h < 14) {
    return const PetScene('noon', [
      '中午了，先吃饭。',
      '书不会跑，胃会。',
      '午休一会儿吧。',
      '眼睛也要歇。',
      '吃完再回来。',
      '别空着肚子看书。',
    ]);
  }
  if (h < 18) {
    return const PetScene('afternoon', [
      '下午容易困。',
      '泡杯茶再继续。',
      '困了就歇，不催你。',
      '走神也没关系。',
      '慢一点反而读得进。',
      '这个点最容易困。',
    ]);
  }
  return const PetScene('evening', [
    '傍晚了。',
    '一天读了不少。',
    '够了，歇会儿。',
    '晚上适合读慢书。',
    '今天到这儿也行。',
    '再翻两页就收？',
  ]);
}

/// 久别重逢。[days] 是距上次打开的天数。
PetScene absenceScene(int days) {
  if (days >= 30) {
    return const PetScene('away30', [
      '你终于回来了。',
      '没关系，随时重新开始。',
      '我一直在。',
      '书也还在原地。',
      '不急，先坐会儿。',
      '回来就好，别自责。',
    ]);
  }
  if (days >= 7) {
    return const PetScene('away7', [
      '一周没见了。',
      '不用解释，我懂。',
      '还以为你把我忘了。',
      '回来就好。',
      '最近忙什么呢。',
      '书给你留着呢。',
    ]);
  }
  if (days >= 2) {
    return const PetScene('away2', [
      '两天没见了。',
      '书夹在你上次那页。',
      '回来啦。',
      '接着看？',
      '我一直在。',
      '不怪你，忙嘛。',
    ]);
  }
  return const PetScene('away0', [
    '今天也来了。',
    '刚坐下就打开。',
    '挺好。',
    '今天读点什么。',
    '嗯，你来了。',
    '开门就来，够勤快。',
  ]);
}

/// 连续阅读天数。话是关心的，不是炫耀的。
PetScene streakScene(int days) {
  if (days >= 100) {
    return const PetScene('streak100', [
      '一百天了。',
      '你跟这本书已经是老朋友。',
      '稳得不像话。',
      '一百天，值得记一笔。',
      '继续保持，但别太拼。',
    ]);
  }
  if (days >= 30) {
    return const PetScene('streak30', [
      '一个月。',
      '这已经不是三分钟热度了。',
      '三十天，稳。',
      '记下来了。',
      '你做到了。',
    ]);
  }
  if (days >= 7) {
    return const PetScene('streak7', [
      '一周了。',
      '书里的世界你走得很稳。',
      '连着七天。',
      '记得看看窗外。',
      '状态不错。',
    ]);
  }
  if (days >= 3) {
    return const PetScene('streak3', [
      '连着三天了。',
      '别太拼。',
      '第三天，还行。',
      '节奏刚好。',
      '悠着点。',
    ]);
  }
  return const PetScene('streak0', [
    '慢慢读，不赶。',
    '一天也算数。',
    '不急。',
    '读多少都算数。',
    '有就行。',
  ]);
}

/// 久坐护眼。
const PetScene restScene = PetScene('rest', [
  '看了挺久了，闭眼二十秒。',
  '脖子动一动。',
  '喝口水，我等你。',
  '眼睛比书重要。',
  '歇一下再看。',
  '别一直低着头。',
]);

/// 长时间没翻页。
const PetScene idleScene = PetScene('idle', [
  '页面停了好久。',
  '在发呆吗？',
  '我不催你。',
  '卡住了？跳过去也行。',
  '只是想让你知道我在。',
  '发呆也算休息。',
]);

/// 升阶播报。
PetScene stageUpScene(PetStage s) => switch (s) {
      PetStage.paper => const PetScene('up1', [
          '我好像长出身体了。',
          '看，我不再是墨点了。',
          '有身体了。',
          '这是……身体？',
          '感觉不一样了。',
        ]),
      PetStage.fox => const PetScene('up2', [
          '尾巴！原来我有尾巴。',
          '墨自己卷起来了。',
          '看，我有尾巴了。',
          '原来是这么卷的。',
          '尾巴能卷了。',
        ]),
      PetStage.spirit => const PetScene('up3', [
          '我变成书灵了。',
          '是你把我养大的。',
          '谢谢你陪我读到这。',
          '书页在我身边转。',
          '我长成了。',
        ]),
      PetStage.drop => const PetScene('up0', [
          '……',
          '嗯？',
          '我在这儿。',
          '还没成形。',
          '慢慢来。',
        ]),
    };

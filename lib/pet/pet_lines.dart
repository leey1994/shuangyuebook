// 桌宠台词。
//
// 原则：**先关心人，再谈养成**。
// 不催更、不施压、不拿「你今天还没读」当开场白 —— 那种东西放两天就变成噪音。
// 优先级：深夜劝睡 > 久坐护眼 > 久别问候 > 日常闲聊 > 成长播报。
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
      '你要是还不困，我陪你；困了就先睡吧。',
      '明天还有明天的事，今晚就到这儿。',
      '睡吧，书又不会跑。',
    ]);
  }
  if (h < 8) {
    return const PetScene('dawn', [
      '这个点醒着的，应该有理由吧。我陪你。',
      '还早，慢慢来，不着急。',
      '天还没亮透呢。别忘了先喝口水。',
    ]);
  }
  if (h < 11) {
    return const PetScene('morning', [
      '早上好。今天也别忘了吃早饭。',
      '精神不错呀，那就看几章吧。',
      '早。这个点读书记得最牢。',
    ]);
  }
  if (h < 14) {
    return const PetScene('noon', [
      '中午了，先吃饭。书不会跑。',
      '午休一会儿吧，眼睛也要歇。',
      '吃完饭再回来，我不催你。',
    ]);
  }
  if (h < 18) {
    return const PetScene('afternoon', [
      '下午容易困，泡杯茶再继续。',
      '困了就歇会儿，真不急。',
      '这个点最容易走神，慢一点没关系。',
    ]);
  }
  return const PetScene('evening', [
    '傍晚了，歇会儿吧。',
    '一天读了不少，够了。',
    '晚上安静，适合读慢一点的书。',
  ]);
}

/// 久别重逢。[days] 是距上次打开的天数。
PetScene absenceScene(int days) {
  if (days >= 30) {
    return const PetScene('away30', [
      '你终于回来了。没关系，随时都可以重新开始。',
      '好久不见。我一直在，书也一直在。',
    ]);
  }
  if (days >= 7) {
    return const PetScene('away7', [
      '一周没见了。不用解释，我懂。',
      '好久不见…我还以为你把我忘了。',
    ]);
  }
  if (days >= 2) {
    return const PetScene('away2', [
      '两天没见了。书还夹在你上次那一页。',
      '回来啦。我一直在。',
    ]);
  }
  return const PetScene('away0', [
    '今天也来了。',
    '刚坐下就打开，挺好。',
  ]);
}

/// 连续阅读天数。话是关心的，不是炫耀的。
PetScene streakScene(int days) {
  if (days >= 100) {
    return const PetScene('streak100', ['一百天了。你和这本书，已经算老朋友了。']);
  }
  if (days >= 30) {
    return const PetScene('streak30', [
      '一个月。这已经不是三分钟热度了。',
      '三十天。稳得不像话。',
    ]);
  }
  if (days >= 7) {
    return const PetScene('streak7', [
      '一周了。书里的世界你走得很稳。',
      '连着七天，记得偶尔也看看窗外。',
    ]);
  }
  if (days >= 3) {
    return const PetScene('streak3', [
      '连着三天了。别太拼。',
      '第三天。状态不错，但还是悠着点。',
    ]);
  }
  return const PetScene('streak0', ['慢慢读，不赶。']);
}

/// 久坐护眼。
const PetScene restScene = PetScene('rest', [
  '看了挺久了，闭眼歇二十秒。',
  '脖子该动一动了，你一直低着头。',
  '喝口水吧。我等你，不催。',
  '眼睛比书重要。歇一下再看。',
]);

/// 摸一下。语气随形态变，从怯生生到从容。
PetScene petScene(PetStage stage) => switch (stage) {
      PetStage.drop => const PetScene('pet0', [
          '…（蹭了蹭你的手指）',
          '嗯？我在。',
          '（尾巴还没有的它，只是安静地待着）',
        ]),
      PetStage.paper => const PetScene('pet1', [
          '嗯？我在。',
          '再摸一下，就一下。',
          '（它把身体靠过来了一点）',
        ]),
      PetStage.fox => const PetScene('pet2', [
          '再摸一下，就一下。',
          '（墨尾巴摇了摇）',
          '手别停。',
        ]),
      PetStage.spirit => const PetScene('pet3', [
          '你的心事，可以先放这儿。',
          '（书页绕着它转了一圈）',
          '我在。不着急说。',
        ]),
    };

/// 升阶播报。
PetScene stageUpScene(PetStage s) => switch (s) {
      PetStage.paper => const PetScene('up1', [
          '我好像……长出身体了。',
          '看，我不再是墨点了。',
        ]),
      PetStage.fox => const PetScene('up2', [
          '尾巴！原来我有尾巴。',
          '（墨迹自己卷了起来）',
        ]),
      PetStage.spirit => const PetScene('up3', [
          '我变成书灵了。是你把我养大的。',
          '谢谢你陪我读到现在。',
        ]),
      PetStage.drop => const PetScene('up0', ['……'])
    };

/// 长时间没翻页。
const PetScene idleScene = PetScene('idle', [
  '页面停了好久。在发呆吗？',
  '我不催你，就是想让你知道我在。',
  '卡住了？跳过去也行。',
]);

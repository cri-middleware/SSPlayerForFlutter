# ▶️ 再生とイベント

`SpriteStudioPlayer` は直感的なトランスポートとイベントコールバックを備え、アプリのロジックにそのまま組み込めます。ここでは `SpriteStudioAnimation` ウィジェットの引数・再生制御・アニメ切り替え・イベント処理を扱います。

以下のコードの `_player` は `SpriteStudioPlayer` です。自分で持つもの（[下記](#プレイヤーを自分で持つ場合)）か、`SpriteStudioAnimation` が `onLoaded` で渡すものを使います。

## ウィジェットの引数

| 引数 | 役割 |
|---|---|
| `animation` | 選択するアニメ名。省略するとパックの最初。未選択のパックは空の箱を描き、それはロード失敗と見分けが付きません。変えると同じプレイヤーのまま切り替わり、`playing` の間は新しいアニメが先頭から再生されます。 |
| `transition` | `animation` を変えたときにクロスフェードする長さ。`Duration.zero`（既定）なら即座に切り替えます。→ [モーションブレンド](motion-blending.md#crossfade) |
| `width` / `height` | 描画する箱。省略すると作者のキャンバスの大きさになり、制約に収まるよう縦横比を保って縮みます（`Image` が画像の大きさを使うのと同じ）。 |
| `fit` / `alignment` | キャンバスを箱にどう収めるかと、どの点をどこに寄せるか。`BoxFit.contain`（既定）・`cover`・`none` と `Alignment` です。`none` は等倍で、原点を箱の中央に置きます。 |
| `frame` | 作者のキャンバスの代わりに収める箱（プレイヤーローカルのピクセル）。キャンバスの外へはみ出すアニメーション向けです。 |
| `loopCount` | `-1` で無限ループ、`n > 0` で n 回。→ [再生制御](#再生制御) |
| `playing` | 既定でオン。起動時だけのフラグではなく状態です。オフにするとその場で止まり、オンに戻すとそこから続きを再生します。最初のビルドからオフなら 1 フレーム目のポーズで止まります（`autoplay` の無い `<video>` がポスターを出すのと同じ）。 |
| `speedScale` | 再生速度。オーサリング時のレートに対する倍率です。 |
| `flipX` / `flipY` | 描画を左右／上下に反転します。 |
| `offset` / `scale` | フィットの後に描画をずらす量と、フィットの倍率に掛ける倍率。 |
| `placeholder` | 最初のフレームが描けるまでの表示。設定する価値があります —— それまで描くものは無く、空の箱は壊れたパックと同じ見た目だからです。 |
| `onLoaded` | 最初のフレームが描けるようになったとき（パックを読み込み、アニメを選び、`playing` なら再生を始めた後）に、プレイヤーを渡して呼ばれます。`onError` と対です。引数でカバーしていない API はここで呼びます。パーツオーバーライド、トラック、テクスチャ差し替えはパックが要ります。 |
| `onError` | ロード失敗時に呼ばれます。設定しないと未処理の非同期エラーとしてゾーンへ流れます。 |
| `onAnimationStarted` / `onAnimationFinished` / `onAnimationLooped` | 再生の開始／全ループの終了／ループの境目の通過。ロード後にウィジェットが始める再生も開始に数え、`onLoaded` より先に届きます。 |
| `onUserData` / `onSignal` / `onAudio` | ユーザーデータ・シグナル・サウンドのキーの通過。音を鳴らすのはアプリの仕事です。→ [イベント](#イベント) |
| `children` | アニメーションの上に重ねるウィジェット。それぞれアニメーションと同じ箱を覆います。ここに置いた `SpriteStudioPartAnchor` は `player` なしでパーツに追従し、どのウィジェットも `SpriteStudioAnimation.playerOf(context)` でプレイヤーを取れます。→ [パーツトラッキング](part-following.md) |
| `onPlayerCreated` | プレイヤーができた時点で、パックを読み込む前に渡します。読み込みより先に済ませられる設定に使います。破棄はウィジェットがやるので、呼び出し側でしないでください。 |
| `bundle` / `backend` | 読み込む `AssetBundle` と、描画バックエンド。`SpriteStudioBackend.auto`（既定）と `.gpu` は、flutter_gpu が使える実行（Impeller で `--enable-flutter-gpu` 付き）では flutter_gpu で、それ以外では Canvas で描きます。`.canvas` は常に Canvas です。→ [制約と適用範囲](../limitations.md#描画) |

`assetKey`・`bundle`・`backend` を変えるとプレイヤーを作り直します。それ以外の引数は、値が変わったときだけプレイヤーに届きます。なので `onPlayerCreated` でプレイヤーに設定したものは、対応する引数が変わるまでそのまま残ります。イベントの引数はそれぞれコールバックを 1 つだけ取り、渡すと `onPlayerCreated` がそのイベントに設定したものと置き換わります。

これだけで、アニメを自分の状態から動かせます。1 回だけ再生してループに戻す演出なら、引数 2 つとコールバック 1 つです。

```dart
SpriteStudioAnimation.asset(
  'assets/hero/Hero.ssab',
  animation: _attacking ? 'attack' : 'idle',
  loopCount: _attacking ? 1 : -1,
  onAnimationFinished: () => setState(() => _attacking = false),
)
```

## プレイヤーを自分で持つ場合

`SpriteStudioAnimation` がプレイヤーを作るのは、たいていの画面がそれを欲しがらないからです。欲しい場合 —— クロックを別から駆動する —— は
[`SpriteStudioPlayer`](#再生制御) を自分で作って `SpriteStudioView` に渡してください。

```dart
class _MyState extends State<MyWidget> with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player = SpriteStudioPlayer(vsync: this);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _player.loadAsset('assets/spritestudio/Ringo/Ringo.ssab');
    if (!mounted) return;
    _player
      ..setAnimation(_player.animationNames.first)
      ..loopCount = -1
      ..play();
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) =>
      SpriteStudioView(player: _player, width: 400, height: 400);
}
```

たまに props の外へ手を伸ばしたいだけなら、`SpriteStudioAnimation` が
`onLoaded:` で自分のプレイヤーを渡します。生成と破棄のタイミングまで握りたくなったら、そこからは `SpriteStudioView` の仕事です。

## 再生制御

```dart
_player.setAnimation('attack'); // アニメを選択（先頭フレームで待機）
_player.play();                    // 先頭から再生
```

| メンバー | 種別 | 説明 |
|---|---|---|
| `play()` | メソッド | 設定済みアニメを先頭から再生 |
| `pause()` / `resume()` | メソッド | 一時停止（現在フレームを保持。独立再生のインスタンスとエフェクトは動き続けます）/ 保持を解除してその場から続行。どちらも冪等で、`resume()` は**停止中・完了後には何もしません** —— 開始するのは `play()` の役目で、そちらは先頭へ巻き戻します |
| `togglePlayPause()` | メソッド | 再生/一時停止ボタン 1 つ分。進行中なら一時停止、保持中なら再開、停止中・完了後なら `play()` で先頭から |
| `stop()` | メソッド | 再生を停止。再生ヘッドは **その場に留まり**、巻き戻りません（停止したフレームを描画し続けます）。先頭に戻すのは `play()` です |
| `seek(double frame)` | メソッド | 任意フレームへジャンプ（小数可）。独立再生のインスタンス / エフェクトは追従しません |
| `loopCount` | `int` | ループ回数 —— `-1`（または `0`）で無限、`n` で n 回 |
| `speedScale` | `double` | 再生速度倍率。`0` と負値は逆再生ではなく**再生ヘッドの停止**です —— 向きを変えるのは `setPlaybackDirection` の役目 |
| `frameRate` | `int` | 進行レート（fps）。上書きしなければパックに設定された値 |
| `setPlaybackDirection(dir, style)` | メソッド | 再生方向（`SsPlaybackDirection.forward` / `.backward`）と終端での挙動（`SsPlaybackStyle.normal` / `.pingPong`） |
| `playbackDirection` / `playbackStyle` | 読取 | 上記 2 つの現在値 |
| `setAnimationSection(start, end)` | メソッド | **現在の**アニメの再生範囲をフレーム区間で限定する。終わりが始まりより前なら `false` を返し、何も変えない |
| `setAnimationSectionByLabel(start, end, {startOffset, endOffset})` | メソッド | 同じことを、現在のアニメのラベルで両端を指定して行う |
| `frameSkipEnabled` | `bool` | ON（既定）はフレームを落として実時間に追従、OFF は 1 ティックにつき厳密に 1 フレーム進む |
| `subFrameEnabled` | `bool` | サブフレーム補間（既定オン） |
| `isPlaying` / `isPausing` | `bool`（読取） | `isPlaying` は `play()` から停止・完了までが `true` で、**一時停止中も `true`** です。`isPausing` は保持中だけ `true`。「いま進んでいる」は `isPlaying && !isPausing` です |
| `isFinished` / `justLooped` | `bool`（読取） | 全ループを再生し終えた（sticky）/ 直前の進行でループ境界を跨いだ（エッジ） |
| `isPlayingForward` | `bool`（読取） | 再生ヘッドが**実際に**どちら向きに進んでいるか。設定値である `playbackDirection` とは別物で、ピンポンの戻りでは `playbackDirection` が `forward` のままこちらは `false` になります。**音声はこれで抑止してください** |
| `frameNo` / `currentAnimation` | 読取 | 現在フレーム / track 0 が再生しているアニメ名。[クロスフェード](motion-blending.md)では呼んだ時点で入ってくる側の名前になります |
| `startFrame` / `endFrame` / `totalFrames` | `int`（読取） | 再生対象のフレーム区間とその長さ。`totalFrames` はスクラバに渡す用 |

### `setAnimation` をまたいで残るもの

アニメをセットアップすると、ランタイムでリセットされるのは再生区間とループ回数の 2 つです。速度・フレームレートの上書き・フレームスキップ・再生方向とスタイルはランタイムで保たれ、ループ回数はプレイヤーが戻します。そのため**あなたが決めた設定**は残り、**アニメ自身を表す設定**だけがリセットされます。

| 残る | リセットされる |
|---|---|
| `loopCount` / `speedScale` / `frameSkipEnabled` / `frameRate` / `playbackDirection`・`playbackStyle` / `subFrameEnabled` | 再生区間 |

再生区間は別のアニメでは意味を持たないフレーム番号の範囲です。持ち越すと、いま選んだアニメの設定を黙って上書きしてしまいます。必要ならセットアップのたびに設定し直してください。特に区間を
`setAnimation` の**前**に設定しても消えてしまう点に注意してください。

`frameRate` の上書きも遷移を跨いで残るので、各アニメの authored 値に戻したいときは `0` を渡してクリアしてください。authored 値そのものを置き換えずに再生を伸縮させたいだけなら、`frameRate` ではなく `speedScale` を使います。

### 逆再生と往復再生

```dart
_player.setPlaybackDirection(SsPlaybackDirection.backward, SsPlaybackStyle.pingPong);
```

`pingPong` では 1 ループが**往復 1 回**なので、`loopCount = 1` で行って戻って終わりです。`speedScale` に負の値を渡しても逆再生にはならず（再生ヘッドが停止します）、向きを変えるのは `playbackDirection` です。こちらはセットアップをまたいで残ります。

### アニメの一部だけ再生する

```dart
_player.setAnimation('attack');
_player.setAnimationSection(10, 24);   // setup の後で。前だと消える
_player..loopCount = -1..play();            // 10〜24 の範囲でループ
```

`startFrame` / `endFrame` / `totalFrames` は区間を反映するので、それらに紐づけたスクラバもそのまま追従します。

範囲外の値（`-1` など）を渡すと、その側はアニメの端になります。両端ともアニメの範囲内で終わりが始まりより前なら受け付けません。`setAnimationSection` は `false` を返してログに 1 度だけ書き、区間も再生ヘッドも変えません。

両端はラベルでも指定できます。それぞれにフレーム単位のオフセットを足せます。

```dart
_player.setAnimation('attack');
_player.setAnimationSectionByLabel('windup', 'hit', endOffset: -1); // `hit` の 1 フレーム手前まで
```

`_start` と `_end` は SpriteStudio と同じくアニメの先頭と最後のフレームを指します。アニメに無いラベルを渡したときと、ラベルとオフセットから出たフレームが `setAnimationSection` の受け付けない区間になったときは、`false` を返してログに 1 度だけ書き、区間は変えません。

## 反転・オフセット・スケール

プレイヤーが**描くもの**だけを反転・移動・拡大縮小できます。ウィジェットツリーには一切触れません。

| プロパティ | 型 | 説明 |
|---|---|---|
| `flipX` | `bool` | 描画を左右反転（Flutter 自身の `Transform.flip(flipX: …)` と同じ考え方） |
| `flipY` | `bool` | 描画を上下反転 |
| `offset` | `Offset` | 描画を論理ピクセル単位でずらす。反転の**後**に適用されるため、オフセット自身は反転しません |
| `scale` | `double` | 描画を原点まわりに拡大縮小。フィット付きのビューでは、フィットの倍率を置き換えず掛け合わせます |
| `rootTransform` | `SsRootTransform` | 上記 4 つをまとめた値。複数を同時に変えるときはこちらへ代入すれば再描画は 1 回で済みます |

```dart
// 進行方向を向く
_player.flipX = velocity.dx < 0;
```

インスタンスパーツの子アニメーションを含むツリー全体に適用され、`reload()` をまたいでも保持されます。変更するとリスナーへ通知されるため、ビューは自動で再描画されます。

> [!QUESTION] `Transform.flip` でビューを包むのとの違い
> 包む方法は、包んだサブツリー**全体**を反転します。[パーツトラッキング](part-following.md) を併用していると、これが問題になります。
>
> | やり方 | 結果 |
> |---|---|
> | `Stack` 全体を `Transform.flip` で包む | アンカーした子ウィジェット（アイコンや文字）まで鏡像になる |
> | `SpriteStudioView` だけを包む | アンカーが反転前の位置に取り残される |
> | **`player.flipX`** | アニメーションが反転し、アンカーも一緒に移動する。子ウィジェット自身は正立させたままにもできる |
>
> パーツトラッキングを使っていないなら `Transform.flip` で包む方法で十分です。
>
> 反転したプレイヤーにウィジェットを追従させるときの詳細は
> [パーツトラッキング](part-following.md) を参照してください。

> [!NOTE] Flame アダプタでは
> `SpriteStudioComponent` は Flame の `PositionComponent` として `flipHorizontally()` などを既に持つため、反転用の引数は持ちません。

## アニメを切り替える

`setAnimation(name)` はアニメを選択して**先頭フレームで待機**します —— 再生は開始しません。

ランタイムのトランスポートはリセットされますが、`SpriteStudioPlayer` は**あなたが設定した `loopCount` / `speedScale` を覚えていて再適用**するので、アニメを切り替えるたびに設定し直す必要はありません（「`setAnimation` をまたいで残るもの」の表のとおり）。

```dart
_player.setAnimation('walk');
_player..loopCount = 3..speedScale = 1.5..play();
```

すでに選択中のアニメを指定しても何も起きません —— 再生ヘッド・区間・パーツオーバーライドはそのままなので、ステートマシンが毎フレーム現在のクリップを指定しても安全です。最初からやり直すなら `play()` を呼びます。パックに無い名前を渡すと `setAnimation` は `false` を返し、ログに 1 度だけ書きます。

利用可能なアニメ名は `animationNames`（または `SsAnimeInfo(bytes).animationNames`）で取得します。

切り替えずにフェードでつなぐ、あるアニメの上に別のアニメを重ねる、といったことは[モーションブレンド](motion-blending.md)を参照してください。`setAnimation` はその重ねたトラックを track 0 だけに戻します。

## クロックの駆動

- **vsync モード** —— `SpriteStudioPlayer(vsync: this)` で生成すると、プレイヤーが自前の `Ticker`
  を回します。これがウィジェット経路です（[クイックスタート](quickstart.md)）。
- **外部クロック** —— `vsync` を省き、毎ティック `advance(delta)` を自分で呼びます。
  [Flame](flame.md) アダプタはこの方式で駆動します。

## イベント

プレイヤーにコールバックを設定します。再生の進行に応じて発火します。

| コールバック | シグネチャ | 発火タイミング |
|---|---|---|
| `onUserData` | `void Function(SsUserData)` | タイムラインの**ユーザーデータ**を通過したとき。1 件につき 1 回 |
| `onSignal` | `void Function(SsSignal)` | 有効な**シグナル**キーフレームを通過したとき。無効なシグナルは通知されない |
| `onAudio` | `void Function(SsAudioEvent)` | **オーディオ**トリガを通過したとき。プレイヤー自身は音を鳴らさない（下記参照） |
| `onAnimationStarted` | `VoidCallback` | 再生が**始まった**とき。自分のコードからの `play()` に限らず、autoplay ラッパーやホストのステートマシンが呼んだものも含みます。`resume()` では発火しません（一時停止の解除は続行であって開始ではないため） |
| `onAnimationFinished` | `VoidCallback` | 設定したループを全て再生し終えたとき。`loopCount` が無限のときは**発火せず**、`stop()` でも発火しない |
| `onAnimationLooped` | `VoidCallback` | ループ境界を跨いだとき（最終周は代わりに `onAnimationFinished` が発火） |
| `onEvents` | `void Function(List<int> passedEventIndices)` | 低レベルの逃げ道。デコード前の生の index がそのフレーム分だけ渡される |

通常はデコード済みの `onUserData` / `onSignal` / `onAudio` を使ってください。`onEvents` が渡すのは index だけで、デコードは呼び出し側の仕事になります。index は**それを発火したアニメ**のイベントテーブルを指し、track 0 を[クロスフェード](motion-blending.md)した後は `setAnimation` で選んだアニメとは限りません。デコード済みのコールバックは、イベントごとに正しいテーブルで引きます。デコードは 3 つのデコード済みコールバックがどれも未設定なら丸ごとスキップされるので、`onEvents` だけを登録しても余計なコストはかかりません。

デコード済みの 3 つはいずれも `partIndex` / `partName` / `frameNo` / `source` を持ちます。`frameNo` はキーが**置かれている** フレームであって、検出されたフレームとは限りません。1 回の `advance` で複数フレームをまたぐことがあり、その間のキーはすべてそこで発火するため、プレイヤーの現在フレームとは一致しません。`source` は発火した[ソース](motion-blending.md#sources)のハンドルです。既定では track 0 のアニメだけが発火するので、オーバーレイやクロスフェードの出ていく側にも発火させない限り `trackMainSource(0)` になります。

### 例: ユーザーデータを受け取る

```dart
_player.onUserData = (userData) {
  // SpriteStudio で設定した項目（integer / rect / point / string）だけが非 null になります。
  if (userData.string == 'footstep') _audio.play();
};
```

### 例: シグナルを受け取る

```dart
_player.onSignal = (signal) {
  if (signal.commandId != 'spawn') return;
  for (final p in signal.params) {           // 作者が置いた順
    if (p.paramId == 'count' && p.value is int) _spawn(p.value as int);
  }
};
```

### 例: オーディオトリガを鳴らす

SpriteStudio のオーディオはトリガのみです。プレイヤーは「鳴らすべき音」を渡すだけで、オーディオスタックには関与しません。ハッシュをパック相対パスに解決して、お使いの再生手段に渡してください。

**`isPlayingForward` で抑止してください。** SpriteStudio に逆再生の音声は無いので、逆向きに進んでいる最中に通過したキーは鳴らすべきものではありません。自前のオーディオバックエンドを持つプレイヤーはこの判定を自分で行いますが、こちらは再生せず通知するだけなので `onAudio` はどちらでも発火します。判定はあなたの側の仕事です。

```dart
_player.onAudio = (audio) {
  if (!_player.isPlayingForward) return; // 逆再生の音声は無い
  final path = _player.soundFilePath(audio.soundNameHash); // 例: "sound/foo.mp3"
  if (path != null) _audio.play(path, times: audio.loopNum);
};
```

`isPlayingForward` は*瞬間の*向きです。`playbackDirection` ではなくこちらで判定するのはそのためで、
`SsPlaybackStyle.pingPong` の戻りでは `playbackDirection` が `forward` のまま実際には逆向きに進んでいます。再生前は `true` なので、このゲートが初回フレームを取りこぼすことはありません。

**seek の移動先でも鳴らさない。** `seek` すると、次の更新が移動先のフレームのオーディオキーを報告します。再生中ならすぐ、一時停止中の seek なら `resume()` の後の最初の tick です。再生ヘッドはそのキーを通過していないので、seek で音を出したくなければ、seek の後の最初の更新が報告する移動先のフレームのキーを飛ばしてください。`play()` の直後の開始フレームの音は鳴らすものです。

### 例: アニメを連結する

```dart
_player.onAnimationFinished = () {
  if (_player.currentAnimation == 'attack') {
    _player.setAnimation('idle');
    _player..loopCount = -1..play();
  }
};
```

## パーツへのウィジェット追従

指定パーツの位置・回転・スケールにウィジェットを毎フレーム追従させる、あるいはその瞬間の姿勢だけを読み取るには、[パーツトラッキング](part-following.md) を参照してください。

## パーツ単位の上書き

特定のパーツだけを、キーフレームより優先して別の色 / セル / 非表示にするには、
[パーツオーバーライド](part-overrides.md) を参照してください。

## 開発中のライブ更新

再エクスポートした `.ssab` をトランスポート状態を保ったまま差し替えるには、
[ライブリロード](live-reload.md) を参照してください。

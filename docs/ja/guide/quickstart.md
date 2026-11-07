# ⚡ クイックスタート

`.ssab` ファイルからウィジェットでアニメを再生するまでの最短手順です。

!!! note "このページは `.ssab` が手元にある前提です"
    SpriteStudio プロジェクト（`.sspj`）しか無い場合は、まず
    [アセットの準備（`.sspj` → `.ssab`）](conversion.md) で `.ssab` を生成してください。

## 1. アセットを追加する

`.ssab`（参照テクスチャ形式なら同じフォルダの PNG / WebP も）をアプリのアセットに置き、`pubspec.yaml` にフォルダを宣言します。

```yaml
flutter:
  assets:
    - assets/spritestudio/Ringo/
```

## 2. 読み込んで再生する

```dart
SpriteStudioAnimation.asset(
  'assets/spritestudio/Ringo/Ringo.ssab',
  width: 400,
  height: 400,
)
```

これで全部です。このウィジェットがプレイヤーを作り、アセットバンドルからバイト列を読み（reference テクスチャはキー自身のフォルダから解決。embedded も同じ）、パックの最初のアニメを選んでループ再生を始め、ウィジェットと一緒に破棄します。別のアニメを選ぶなら
`animation:`、1 フレーム目で止めておくなら `playing: false`、最初のフレームが描けるまでの表示は `placeholder:`、ロード失敗を受け取るなら `onError:` です。

## 渡せるもの

| 引数 | 役割 |
|---|---|
| `animation` | 選択するアニメ名。省略するとパックの最初。未選択のパックは空の箱を描き、それはロード失敗と見分けが付きません。変えると同じプレイヤーのまま切り替わり、`playing` の間は新しいアニメが先頭から再生されます。 |
| `transition` | `animation` を変えたときにクロスフェードする長さ。`Duration.zero`（既定）なら即座に切り替えます。→ [モーションブレンド](motion-blending.md#crossfade) |
| `width` / `height` | 描画する箱。省略すると作者のキャンバスの大きさになり、制約に収まるよう縦横比を保って縮みます（`Image` が画像の大きさを使うのと同じ）。 |
| `fit` / `alignment` | キャンバスを箱にどう収めるかと、どの点をどこに寄せるか。`BoxFit.contain`（既定）・`cover`・`none` と `Alignment` です。`none` は等倍で、原点を箱の中央に置きます。 |
| `frame` | 作者のキャンバスの代わりに収める箱（プレイヤーローカルのピクセル）。キャンバスの外へはみ出すアニメーション向けです。 |
| `loopCount` | `-1` で無限ループ、`n > 0` で n 回。→ [再生とイベント](playback.md) |
| `playing` | 既定でオン。起動時だけのフラグではなく状態です。オフにするとその場で止まり、オンに戻すとそこから続きを再生します。最初のビルドからオフなら 1 フレーム目のポーズで止まります（`autoplay` の無い `<video>` がポスターを出すのと同じ）。 |
| `speedScale` | 再生速度。オーサリング時のレートに対する倍率です。 |
| `flipX` / `flipY` | 描画を左右／上下に反転します。 |
| `offset` / `scale` | フィットの後に描画をずらす量と、フィットの倍率に掛ける倍率。 |
| `placeholder` | 最初のフレームが描けるまでの表示。設定する価値があります —— それまで描くものは無く、空の箱は壊れたパックと同じ見た目だからです。 |
| `onLoaded` | 最初のフレームが描けるようになったとき（パックを読み込み、アニメを選び、`playing` なら再生を始めた後）に、プレイヤーを渡して呼ばれます。`onError` と対です。引数でカバーしていない API はここで呼びます。パーツオーバーライド、トラック、テクスチャ差し替えはパックが要ります。 |
| `onError` | ロード失敗時に呼ばれます。設定しないと未処理の非同期エラーとしてゾーンへ流れます。 |
| `onAnimationStarted` / `onAnimationFinished` / `onAnimationLooped` | 再生の開始／全ループの終了／ループの境目の通過。ロード後にウィジェットが始める再生も開始に数え、`onLoaded` より先に届きます。 |
| `onUserData` / `onSignal` / `onAudio` | ユーザーデータ・シグナル・サウンドのキーの通過。音を鳴らすのはアプリの仕事です。→ [再生とイベント](playback.md) |
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
[`SpriteStudioPlayer`](playback.md) を自分で作って `SpriteStudioView` に渡してください。

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

!!! tip "テクスチャ: embedded と reference"
    どちらのモードも追加引数なしで解決します。**embedded** な `.ssab`（`ssconvert -e` で生成）は画像を内包し、**reference** な `.ssab` は同じフォルダの画像ファイルを参照して `loadAsset` がキー自身のフォルダから解決します。→ [アセットの準備](conversion.md)。

サブフレーム補間は**既定でオン**なので、フレームレートに関係なく滑らかに動きます。

## 次のステップ

- 再生制御・アニメ切り替え・イベント → [再生とイベント](playback.md)
- [Flame](https://flame-engine.org/) ゲームエンジン → [Flame 連携](flame.md)

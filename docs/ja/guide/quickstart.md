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
    - assets/overall/
```

## 2. 読み込んで再生する

```dart
SpriteStudioAnimation.asset(
  'assets/overall/Basic.ssab',
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
| `width` / `height` | 描画する箱。省略すると親の制約に従います。 |
| `loopCount` | `-1` で無限ループ、`n > 0` で n 回。→ [再生とイベント](playback.md) |
| `playing` | 既定でオン。起動時だけのフラグではなく状態です。オフにするとその場で止まり、オンに戻すとそこから続きを再生します。最初のビルドからオフなら 1 フレーム目のポーズで止まります（`autoplay` の無い `<video>` がポスターを出すのと同じ）。 |
| `speedScale` | 再生速度。オーサリング時のレートに対する倍率です。 |
| `flipX` / `flipY` | 描画を左右／上下に反転します。 |
| `placeholder` | 最初のフレームが描けるまでの表示。設定する価値があります —— それまで描くものは無く、空の箱は壊れたパックと同じ見た目だからです。 |
| `onError` | ロード失敗時に呼ばれます。設定しないと未処理の非同期エラーとしてゾーンへ流れます。 |
| `onPlayerCreated` | 引数でカバーしていない API に手を伸ばすためにプレイヤーを渡します。破棄はウィジェットがやるので、呼び出し側でしないでください。 |
| `bundle` / `backend` | 読み込む `AssetBundle` と、描画バックエンド。 |

`assetKey`・`bundle`・`backend` を変えるとプレイヤーを作り直します。それ以外の引数は、値が変わったときだけプレイヤーに届きます。なので `onPlayerCreated` でプレイヤーに設定したものは、対応する引数が変わるまでそのまま残ります。

## プレイヤーを自分で持つ場合

`SpriteStudioAnimation` がプレイヤーを作るのは、たいていの画面がそれを欲しがらないからです。欲しい場合 —— ステートマシンからアニメを差し替える、イベントを購読する、ウィジェットをパーツに貼り付ける、クロックを別から駆動する —— は
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
    await _player.loadAsset('assets/overall/Basic.ssab');
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
`onPlayerCreated:` で自分のプレイヤーを渡します。生成と破棄のタイミングまで握りたくなったら、そこからは `SpriteStudioView` の仕事です。

!!! tip "テクスチャ: embedded と reference"
    どちらのモードも追加引数なしで解決します。**embedded** な `.ssab`（`ssconvert -e` で生成）は画像を内包し、**reference** な `.ssab` は同じフォルダの画像ファイルを参照して `loadAsset` がキー自身のフォルダから解決します。→ [アセットの準備](conversion.md)。

サブフレーム補間は**既定でオン**なので、フレームレートに関係なく滑らかに動きます。

## 次のステップ

- 再生制御・アニメ切り替え・イベント → [再生とイベント](playback.md)
- [Flame](https://flame-engine.org/) ゲームエンジン → [Flame 連携](flame.md)

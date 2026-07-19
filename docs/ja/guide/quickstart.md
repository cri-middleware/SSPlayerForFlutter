# クイックスタート

`.ssab` ファイルからウィジェットでアニメを再生するまでの最短手順です。

!!! note "このページは `.ssab` が手元にある前提です"
    SpriteStudio プロジェクト（`.sspj`）しか無い場合は、まず
    [CLI 変換（`.sspj` → `.ssab`）](conversion.md) で `.ssab` を生成してください。

## 1. アセットを追加する

`.ssab`（参照テクスチャ形式なら同じフォルダの PNG / WebP も）をアプリのアセットに置き、`pubspec.yaml` に
フォルダを宣言します。

```yaml
flutter:
  assets:
    - assets/overall/
```

## 2. 読み込んで再生する

```dart
class _MyState extends State<MyWidget> with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player = SpriteStudioPlayer(vsync: this);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final bytes = (await rootBundle.load('assets/overall/Basic.ssab'))
        .buffer.asUint8List();
    final animName = SsAnimeInfo(bytes).animationNames.first;
    // reference テクスチャ（同じフォルダの PNG）は baseAssetDir を渡す。embedded は自動解決。
    await _player.load(bytes, animationName: animName, baseAssetDir: 'assets/overall');
    _player..loop = -1..play();
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) =>
      SpriteStudioView(player: _player, width: 400, height: 400);
}
```

## 各ステップの意味

| ステップ | 役割 |
|---|---|
| `SpriteStudioPlayer(vsync: this)` | 自前の `Ticker` を持つプレイヤーを生成。`vsync` を省くとクロックを自分で駆動できます（[再生とイベント](playback.md)）。 |
| `SsAnimeInfo(bytes).animationNames` | `.ssab` 内のアニメ名を列挙して選べます。 |
| `load(bytes, animationName:, baseAssetDir:)` | バイト列をネイティブランタイムに渡し、アニメを選択してテクスチャを解決します。 |
| `loop = -1` | 無限ループ（`n > 0` は n 回。[再生とイベント](playback.md)）。 |
| `play()` | トランスポートを開始します。 |
| `SpriteStudioView(player:, width:, height:)` | 普通の `RenderBox` ウィジェット。他のウィジェットと同じく配置・変形・クリップできます。 |

!!! tip "テクスチャ: embedded と reference"
    **embedded** な `.ssab`（`ssconvert -e` で生成）はテクスチャを内包するので `baseAssetDir` は
    任意です。**reference** な `.ssab` は同じフォルダの画像ファイルを参照するので、`baseAssetDir` を渡して
    解決させます。→ [CLI 変換](conversion.md)。

サブフレーム補間は**既定でオン**なので、フレームレートに関係なく滑らかに動きます。

## 次のステップ

- 再生制御・アニメ切り替え・イベント → [再生とイベント](playback.md)
- [Flame](https://flame-engine.org/) ゲームエンジン → [Flame 連携](flame.md)

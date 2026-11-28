# ⚡ クイックスタート

SpriteStudio のプロジェクトからウィジェットでアニメを再生するまでの最短手順です。

## 1. プロジェクトを変換する

SpriteStudio のプロジェクトをフォルダごとアプリの `SpriteStudio_Source/` に置き、[インストール](install.md) で dev dependency に入れた `ssconverter_dart` の `ssconvert` で `assets/spritestudio/` へ変換します。

```bash
dart run ssconverter_dart:ssconvert -o assets/spritestudio/Ringo/ SpriteStudio_Source/Ringo/Ringo.sspj
```

```
my_app/
├── SpriteStudio_Source/
│   └── Ringo/                 ← SpriteStudio のプロジェクト（フォルダごと）
│       ├── Ringo.sspj
│       ├── Ringo.png
│       └── …
├── assets/spritestudio/
│   └── Ringo/                 ← ssconvert が書き出す
│       ├── Ringo.ssab
│       ├── Ringo.png
│       └── …
├── lib/main.dart
└── pubspec.yaml
```

ほかの変換方法は [アセットの準備（`.sspj` → `.ssab`）](conversion.md) にあります。

> [!TIP] SpriteStudio のデータが手元に無くても始められます
> [公式のサンプルデータ](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/)がそのまま使えます。
> キャラクターなら [Ringo](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/#ringo) が手頃です。

## 2. アセットを登録する

`ssconvert` が書き出したフォルダを `pubspec.yaml` に宣言します。
```yaml
flutter:
  assets:
    - assets/spritestudio/Ringo/
```

## 3. 読み込んで再生する

```dart
SpriteStudioAnimation.asset(
  'assets/spritestudio/Ringo/Ringo.ssab',
  width: 400,
  height: 400,
)
```

これで全部です。このウィジェットがプレイヤーを作り、アセットバンドルからバイト列を読み（reference テクスチャはキー自身のフォルダから解決。embedded も同じ）、パックの最初のアニメを選んでループ再生を始め、ウィジェットと一緒に破棄します。別のアニメを選ぶなら
`animation:`、1 フレーム目で止めておくなら `playing: false`、最初のフレームが描けるまでの表示は `placeholder:`、ロード失敗を受け取るなら `onError:` です。

web では、`runApp` の前に `await loadSsRuntime()` を 1 回呼びます。ほかのプラットフォームでは何もしません。

```dart
Future<void> main() async {
  await loadSsRuntime();
  runApp(const MyApp());
}
```

## 渡せるもの

| 引数 | 役割 |
|---|---|
| `animation` | 選択するアニメ名。省略するとパックの最初。未選択のパックは空の箱を描き、それはロード失敗と見分けが付きません。変えると同じプレイヤーのまま切り替わり、`playing` の間は新しいアニメが先頭から再生されます。 |
| `width` / `height` | 描画する箱。省略すると作者のキャンバスの大きさになり、制約に収まるよう縦横比を保って縮みます（`Image` が画像の大きさを使うのと同じ）。 |
| `loopCount` | `-1` で無限ループ、`n > 0` で n 回。→ [再生とイベント](playback.md) |
| `playing` | 既定でオン。起動時だけのフラグではなく状態です。オフにするとその場で止まり、オンに戻すとそこから続きを再生します。最初のビルドからオフなら 1 フレーム目のポーズで止まります（`autoplay` の無い `<video>` がポスターを出すのと同じ）。 |

すべての引数と、変更がプレイヤーに届く仕組みは [再生とイベント](playback.md#ウィジェットの引数) にあります。

> [!TIP] テクスチャ: embedded と reference
> どちらのモードも追加引数なしで解決します。**embedded** な `.ssab`（`ssconvert -e` で生成）は画像を内包し、**reference** な `.ssab` は同じフォルダの画像ファイルを参照して `loadAsset` がキー自身のフォルダから解決します。→ [アセットの準備](conversion.md)。

サブフレーム補間は**既定でオン**なので、フレームレートに関係なく滑らかに動きます。

## 次のステップ

- 再生制御・アニメ切り替え・イベント → [再生とイベント](playback.md)
- [Flame](https://flame-engine.org/) ゲームエンジン → [Flame 連携](flame.md)

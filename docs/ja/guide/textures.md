# 🧥 テクスチャ差し替え

ランタイムのテクスチャ差し替えは、**セルマップ**単位で参照しているビットマップを、コードから実行時に丸ごと入れ替える機能です。アニメーションデータには手を触れずに、衣装替え・カラーバリエーション・表情差分などを実現できます。描画ループはテクスチャをセルマップのハッシュでバインドするため、差し替えはそのテクスチャを参照する全パーツへ即座に反映されます。

これは [パーツオーバーライド](part-overrides.md) とは別の機能です。あちらはランタイムを通してパーツ 1 つの色 / セル / 表示を変えるもの、こちらはプレイヤーのテクスチャレジストリ内で**テクスチャ画像そのもの**を差し替えるものです。

## 例: 衣装の着せ替え

差し替え用テクスチャはデコード済みの `ui.Image` です。アセット（などどこからでも）読み込み、
`setCellmapTexture()` に渡します。

```dart
import 'dart:ui' as ui;
import 'package:flutter/services.dart' show rootBundle;

Future<ui.Image> _loadImage(String assetKey) async {
  final data = await rootBundle.load(assetKey);
  final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
  return (await codec.getNextFrame()).image;
}

// "Clothes" セルマップを、同じサイズ・同じレイアウトの別アトラスに差し替える
final sailor = await _loadImage('assets/sailor_uniform.png');
_player.setCellmapTexture('Clothes', sailor);

// 元のビットマップに戻す。渡した画像はこれ以降は呼び出し側が解放する
_player.setCellmapTexture('Clothes', null);
sailor.dispose();
```

これにより、組み合わせごとにアニメーションを用意しなくても、効率的なアバター / 着せ替えシステムを組めます —— リグは 1 つ、テクスチャは何通りでも。

!!! tip "動かして確認"
    `examples/overall` の [Web デモ](../../demo/) はこの機能をパネルから操作できます。セルマップを差し替えると、再生中のアニメーションがその場で着せ替わります。

## 名前を調べる

差し替えられる名前は、読み込んだ `.ssab` から取得できます。

```dart
final names = _player.replaceableTextureNames; // セルマップ ＋ TextureChange の差し先
```

- **セルマップ名** は拡張子を含みません（`Clothes`）。差し替えると、そのセルマップを参照する全パーツが着せ替わります。
- **TextureChange のファイル名** は拡張子を含みます（`clothes.png`）。オーサリングされた
  *TextureChange* が効いているフレームでパーツが表示する絵を変えたい場合は、こちらを差し替えます（下記の注記を参照）。

`cellmapNames` / `cellNames(cellmap)` —— [セルオーバーライド](part-overrides.md) が使うのと同じ
2 つ —— でセルマップと、その中のセルを列挙できます。

## メソッド

`SpriteStudioPlayer` のメソッドです。

| メソッド | 説明 |
|---|---|
| `setCellmapTexture(name, image)` | セルマップ（または TextureChange のファイル）`name` が参照するテクスチャを差し替える。`image: null` で元に**復元** |
| `setCellmapTextureByHash(hash, image)` | 同じ処理を、`cellmapTextureHash` から得たレジストリのハッシュ指定で行う（名前解決を省略） |
| `cellmapTextureOverride(name)` | `name` に現在設定されている差し替え画像（差し替え値のみ。元画像は返さない）。未設定なら `null` |
| `replaceableTextureNames` | 差し替え対象になり得る全名称 —— セルマップ、続いて TextureChange のファイル |
| `cellmapTextureHash(name)` | セルマップ名に対応するレジストリのキー（`...ByHash` や低レベルの `TextureRegistry` 用） |
| `cellmapNames` / `cellNames(name)` | セルマップと、その中のセルを列挙 |

`setCellmapTexture` は、`load()` 前・不明な名前・差し替えが無い名前を復元しようとした場合に `false`、差し替えを設定した / 実際に解除した場合に `true` を返します。

!!! note "低レベル API からも同じように使えます"
    `setCellmapTexture(hash, image)` と `cellmapTextureOverride(hash)` は、ハッシュ指定で
    `SpriteStudioInternalPlayer`（L2）にも用意されています。パーツオーバーライドと同様、違いは
    `SpriteStudioPlayer`（L3）が成功時に再描画するのに対し、L2 は再描画を呼び出し側に委ねる点だけです（レイヤーについては[プレイヤーの構成](../development/architecture.md)を参照）。

## 注意点

- **差し替え画像は呼び出し側の所有です。** プレイヤーは*借用*するだけで、解放は行いません。設定している間は生かしておき、オーバーライドを解除した後（または別の画像に差し替えた後）に自分で
  `dispose()` してください。復元は即時です —— プレイヤーが元のデコード済み画像を保持しているため、
  `null` は何も読み直さず、失敗もしません。
- **元アトラスと同じサイズ・同じレイアウトを使ってください。** セル矩形と UV は*元*セルマップのピクセル空間のままなので、解像度の違う画像に差し替えると同じ矩形が別の領域をサンプリングします。テクスチャ差し替えは、同サイズ・同レイアウトのアトラス（レイアウト変更ではなく着せ替え）を前提とします。
- **ツリー全体に効きます。** インスタンス子の内部パーツも含め、アニメーション全体が 1 つのテクスチャレジストリを共有するため、差し替えはそのテクスチャを参照する全パーツ（ルートでも子でも）に届きます。
- **一時停止中でも反映されます。** 差し替えはフレーム番号を変えずにピクセルだけを変えます。
  `SpriteStudioPlayer` は成功時にリスナーへ通知するので、一時停止中のプレイヤーもすぐ再描画されます。
- **別の `.ssab` を読み込むと差し替えはすべてクリアされます** —— テクスチャレジストリが新しいパックで再構築されるためです。

## TextureChange とランタイム差し替え

SpriteStudio には**オーサリング**の TextureChange 属性もあります —— タイムライン上で設定し、キーのあるフレームでパーツが参照するテクスチャを切り替えるものです。こちらは自動で描画され、コードは不要です。両者は 1 点で交わります。

- オーサリングされた TextureChange が効いているフレームでは、パーツはセルマップ名（`Clothes`）ではなく**ファイル名**のテクスチャ（`clothes.png`）をバインドします。そのフレームで表示される絵を差し替えたい場合は、**TextureChange のファイル名**（拡張子付き）を対象にしてください —— これは
  `replaceableTextureNames` に列挙されます。

## セルオーバーライドとの使い分け

- **`setCellmapTexture()`** は、**セルマップ（テクスチャ）まるごと**を一度に差し替え、それを使う全パーツにまとめて効きます —— 着せ替えです。
- **[`setPartCellOverride()`](part-overrides.md)** は、**パーツ 1 つが描画するセルそのもの**を差し替えます —— 1 パーツ単位で、セルマップ内の別の絵に。

目的に応じて使い分けてください。両者は独立していて、併用もできます。

## Flame から使う

`ssplayer_flame` は独自 API を追加しません —— コンポーネントが公開するプレイヤーに対して
`setCellmapTexture` を呼びます。

```dart
final player = component.player!;
player.setCellmapTexture('Clothes', await _loadImage('assets/sailor_uniform.png'));
```

## 関連

- [パーツオーバーライド](part-overrides.md) —— パーツ単位の色 / セル / 表示
- [アセットの準備](conversion.md) —— セルマップとその画像が `.ssab` に入るまで
- [API リファレンス](../api.md) —— 自分で描画を駆動する場合の低レベル `TextureRegistry`

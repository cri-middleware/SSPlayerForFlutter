# ssplayer_flame_example

`ssplayer_flame` の検証用サンプル。`FlameGame` に `SpriteStudioComponent` を1つ
載せ、SpriteStudio の **Ringo** アニメーションを再生する最小構成です。画面を
**タップすると再生 / 一時停止** が切り替わります。

これは Layer‑4 の描画アダプタとして Flame を使う例です。ゲームループ（`update(dt)`）が
プレイヤーの時計を回し、`render` が Widget 版（`SpriteStudioView`）と同じ Layer‑2 の
描画パスに委譲します。

## 前提

- **Flutter 3.47+ / Dart 3.13+**（Native Assets 標準対応。下限 3.47 は flutter_gpu バックエンドの要件）。CI は 3.47.1 / 3.13.1 で検証。
- ネイティブ Brain（`libssruntime`）。`hook/build.dart` がピン留めした SDK リリースから
  プリビルドを自動DL・同梱するので、通常は事前配置不要（Rust 不要）。
  - ソースからビルドする場合: `bash scripts/build-runtime.sh`（Rust 必要）
- 例アセット（Ringo の `.ssab` + `Ringo.png`）を生成済みであること:

  ```sh
  bash scripts/deploy-examples.sh   # → examples/flame/assets/spritestudio/Ringo/ に Ringo をコピー
  ```

  > overall 例の変換出力（`examples/overall/assets/.../Ringo`）を **コピー** して配置します
  > （二重変換しません）。`examples/flame/assets/` は生成物なので `.gitignore` 済みです。

> `libssruntime` は **Native Assets** で自動同梱されます。`SSRUNTIME_LIBRARY_PATH` の設定や
> framework の手動配置は不要です（`flutter run`/`flutter build` が `hook/build.dart` を自動実行）。

## 実行 / ビルド（`examples/flame/` で）

> ⚠️ **プラットフォーム runner はコミットされていません。** `examples/flame/{android,ios,macos,linux,windows,web}/`
> はリポジトリの `.gitignore` 済みで、クローン毎に再生成する方針です（ルート `.gitignore` 参照）。
> **初回、または `git clean` の後は必ず再生成**してください（これをしないと
> `No macOS desktop project configured.` になります）:
>
> ```sh
> # macOS: 共通スクリプトのラッパ（flame は flutter create のみ・特別な entitlement 不要）
> bash examples/flame/scripts/setup-macos.sh
> # 他プラットフォームは flutter create で:
> #   cd examples/flame && flutter create --platforms=ios,android,linux,windows,web .
> ```
>
> 共通ロジックは `examples/scripts/setup-macos.sh`（overall はここに `--drag-drop --dev-unsandbox`
> を渡すラッパ）。

```sh
flutter pub get
flutter run -d macos     # 実行（macOS ウィンドウが開き、Ringo が中央で再生される）
# または
flutter build macos      # .app をビルド
```

macOS ビルドでは overall 例と同様、`libssruntime` が
`*.app/Contents/Frameworks/ssruntime.framework` に埋め込まれます。

## ヘッドレス検証（アプリを起動せずに）

Flame アダプタの実描画は、`ssplayer_flame` パッケージのテストが CI で検証します
（実 `.ssab` をロード → ホストクロックで前進 → テクスチャ付き非空フレームを描画）:

```sh
cd packages/ssplayer_flame && flutter test
```

## コード

再生の要点は [`lib/main.dart`](./lib/main.dart) の十数行です:

```dart
class SpriteStudioGame extends FlameGame {
  @override
  Future<void> onLoad() async {
    add(SpriteStudioComponent.asset(
      // 参照テクスチャ（隣接する Ringo.png）はキー自身のフォルダから解決されるので
      // baseAssetDir は不要です。
      'assets/spritestudio/Ringo/Ringo.ssab',
      anchor: Anchor.center,
      position: size / 2,
    ));
  }
}
```

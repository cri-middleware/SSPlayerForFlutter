# ssplayer_flutter_example

`tests/overall/overall.ssab` を再生する検証用 Flutter アプリ。上部のドロップダウンで
アニメ（`Basic` ほか）を切り替えられる。

## 前提

- **Flutter 3.47+ / Dart 3.13+**（Native Assets 標準対応。下限 3.47 は flutter_gpu バックエンドの要件）。CI は 3.47.1 / 3.13.1 で検証。
- ネイティブ Brain（`libssruntime`）。`hook/build.dart` がピン留めした SDK リリースから
  プリビルドを自動DL・同梱するので、通常は事前配置不要（Rust 不要）。
  - ソースからビルドする場合: `bash scripts/build-runtime.sh`（Rust 必要）
- 例アセット（`.ssab`）を生成済みであること:

  ```sh
  bash scripts/deploy-examples.sh   # → examples/overall/assets/spritestudio/overall/ に出力
  ```

> `libssruntime` は **Native Assets** で自動同梱されます。`SSRUNTIME_LIBRARY_PATH` の設定や
> framework の手動配置は不要です（`flutter run`/`flutter build` が `hook/build.dart` を自動実行）。

## 実行 / ビルド（`examples/overall/` で）

> ⚠️ **プラットフォーム runner はコミットされていません。** `examples/overall/{android,ios,macos,linux,windows,web}/`
> はリポジトリの `.gitignore` 済みで、クローン毎に再生成する方針です（ルート `.gitignore` 参照）。
> （旧 `example/` から `examples/overall/` へ移設済み）
> **初回、または `git clean` の後は必ず再生成**してください（これをしないと
> `No macOS desktop project configured.` になります）:
>
> ```sh
> cd examples/overall
> flutter create --platforms=macos .        # 必要なら ios,android,linux,windows,web も同様
> ```

```sh
flutter pub get
flutter run -d macos     # 実行（macOS ウィンドウが開く）
# または
flutter build macos      # .app をビルド
```

成功するとコンソールに `[ssplayer] OK — playing "…" (frame=…)` が出ます。macOS ビルドでは
`libssruntime` が `*.app/Contents/Frameworks/ssruntime.framework` に埋め込まれ、
`flutter_assets/NativeAssetsManifest.json` に写像が記録されます（`package:ssruntime_dart/ssruntime`
→ `ssruntime.framework/ssruntime`）。

## トラブルシュート

- **CocoaPods は使いません。** プラグイン無し＋ネイティブは Native Assets 同梱なので、新規生成した
  `macos/` に `Podfile` は作られず、ビルドは pod なしで通ります（`.app` には
  `App` / `FlutterMacOS` / `ssruntime` framework のみ）。もし旧チェックアウトに移行前の
  `macos/Podfile` が残って `The sandbox is not in sync with the Podfile.lock` が出たら、runner を
  作り直してください: `rm -rf macos && flutter create --platforms=macos .`。
- **`Could not find bin/ssconvert.dart`**（`deploy-examples.sh`）: `ssconverter_dart` の
  CLI 未取得。リポジトリを最新化（`git pull`）してください。
- アセット未生成でウィンドウが `loading…` のまま: 先に `bash scripts/deploy-examples.sh` を実行。

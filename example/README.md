# ssplayer_flutter_example

`tests/overall/overall.ssab` を再生する検証用 Flutter アプリ。上部のドロップダウンで
アニメ（`Basic` ほか）を切り替えられる。

## 前提

- **Flutter 3.44.6+ / Dart 3.12.2+**（Native Assets 標準対応）。
- ネイティブ Brain（`libssruntime`）が `packages/ssruntime_dart/native/libs/` に配置済みであること。
  - Rust あり: `bash scripts/build-runtime.sh`
  - Rust なし: `bash scripts/download-sdk.sh`（プリビルド SDK を取得）
- 例アセット（`.ssab`）を生成済みであること:

  ```sh
  bash scripts/prepare-example-assets.sh   # → example/assets/overall/ に出力
  ```

> `libssruntime` は **Native Assets** で自動同梱されます。`SSRUNTIME_LIBRARY_PATH` の設定や
> framework の手動配置は不要です（`flutter run`/`flutter build` が `hook/build.dart` を自動実行）。

## 実行 / ビルド（`example/` で）

> ⚠️ **プラットフォーム runner はコミットされていません。** `example/{android,ios,macos,linux,windows,web}/`
> はリポジトリの `.gitignore` 済みで、クローン毎に再生成する方針です（ルート `.gitignore` 参照）。
> **初回、または `git clean` の後は必ず再生成**してください（これをしないと
> `No macOS desktop project configured.` になります）:
>
> ```sh
> cd example
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

- **`The sandbox is not in sync with the Podfile.lock`**（`flutter build macos`）:
  macOS プロジェクトに旧プラグイン時代の CocoaPods 統合が残っているだけです。一度
  `cd macos && pod install` で再同期すれば解消します（プラグイン Pod は 0 個で綺麗に通ります）。
- **`Could not find bin/ssconvert.dart`**（`prepare-example-assets.sh`）: `ssconverter_dart` の
  CLI 未取得。リポジトリを最新化（`git pull`）してください。
- アセット未生成でウィンドウが `loading…` のまま: 先に `bash scripts/prepare-example-assets.sh` を実行。

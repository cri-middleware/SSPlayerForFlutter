# ssplayer_flutter_example

`tests/overall/overall.ssab` を再生する検証用 Flutter アプリ。上部のドロップダウンでアニメ（`Basic` ほか）を切り替えられる。

## 前提

- **Flutter / Dart** —— 下限は[インストール](../../docs/ja/guide/install.md)にあります（古いと `flutter pub get` が落ちます）。
- ネイティブ Brain（`libssruntime`）。`hook/build.dart` がピン留めした SDK リリースからプリビルドを自動DL・同梱するので、通常は事前配置不要（Rust 不要）。
  - ソースからビルドする場合: `bash scripts/build-runtime.sh`（Rust 必要）
- 例アセット（`.ssab`）を生成済みであること:

  ```sh
  bash scripts/deploy-examples.sh   # → examples/overall/assets/spritestudio/overall/ に出力
  ```

> `libssruntime` は **Native Assets** で自動同梱されます。`SSRUNTIME_LIBRARY_PATH` の設定や
> framework の手動配置は不要です（`flutter run`/`flutter build` が `hook/build.dart` を自動実行）。

## 実行 / ビルド（`examples/overall/` で）

> ⚠️ **プラットフォーム runner はコミットされていません。** `examples/overall/{android,ios,macos,linux,windows,web}/`
> はリポジトリの `.gitignore` 済みで、クローン毎に再生成する方針です（ルート `.gitignore` 参照）。（旧 `example/` から `examples/overall/` へ移設済み）**初回、または `git clean` の後は必ず再生成**してください（これをしないと
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

### iOS / Android

`macos/` と同じく runner は未コミットなので、まず生成します。

```sh
bash scripts/setup-mobile.sh              # ios + android（macOS 以外では android のみ）
bash scripts/setup-mobile.sh --android    # android だけ
pwsh scripts/setup-mobile.ps1             # Windows（android のみ。iOS は Xcode が要る）
```

ネイティブ Brain は `hook/build.dart` がピン留めした SDK リリースから落としますが、**そのリリースはまだ公開されていません**。初回リリースまでは、この 2 つのプラットフォームはローカルのクロスビルドだけが経路です（Rust と各ターゲット、Android は実在する NDK が要る）。

```sh
bash scripts/build-runtime.sh platform=android   # リポジトリルートで
bash scripts/build-runtime.sh platform=ios
```

生成していないと、Gradle の中で HTTP 404 として 90 秒後に落ちます。`setup-mobile` はその場で気づけるよう、ライブラリが無ければ上のコマンドを表示します。

### flutter_gpu（Impeller）で動かす

バックエンド切り替えに要るスイッチは 3 つあり、毎回打つには長いのでラッパにまとめてあります。

```sh
bash scripts/run.sh -d macos                # Canvas（既定）
bash scripts/run.sh --gpu -d macos          # flutter_gpu
bash scripts/run.sh --gpu --watch -d macos  # flutter_gpu + ライブリロード
pwsh scripts/run.ps1 -Gpu -d windows        # Windows
```

`--gpu` は `--dart-define=SS_BACKEND=gpu --enable-impeller --enable-flutter-gpu` に展開されます。このうち `--enable-impeller` が効くのは **Android だけ**で（Impeller が既定でない唯一のターゲット）、
macOS / iOS では `flutter run` が無視します —— macOS では残り 2 つだけでも
`running on gpu` になることを確認済みです。1 つのフラグがどのターゲットでも正しくなるよう、常に 3 つとも渡しています。`--gpu` 以外の引数はそのまま `flutter run` へ流れます。

起動時のコンソール行が唯一の判定材料です。`gpu` は*要求*でしかなく、flutter_gpu が使えなければ**何も言わずに** Canvas へ落ちます。

```
[ssplayer] backend: requested gpu -> running on gpu (flutter_gpu available: true)
```

成功するとコンソールに `[ssplayer] OK — playing "…" (frame=…)` が出ます。macOS ビルドでは
`libssruntime` が `*.app/Contents/Frameworks/ssruntime.framework` に埋め込まれ、
`flutter_assets/NativeAssetsManifest.json` に写像が記録されます（`package:ssruntime_dart/ssruntime`
→ `ssruntime.framework/ssruntime`）。

## トラブルシュート

- **CocoaPods は使いません。** プラグイン無し＋ネイティブは Native Assets 同梱なので、新規生成した
  `macos/` に `Podfile` は作られず、ビルドは pod なしで通ります（`.app` には
  `App` / `FlutterMacOS` / `ssruntime` framework のみ）。もし旧チェックアウトに移行前の
  `macos/Podfile` が残って `The sandbox is not in sync with the Podfile.lock` が出たら、runner を作り直してください: `rm -rf macos && flutter create --platforms=macos .`。
- **`Could not find bin/ssconvert.dart`**（`deploy-examples.sh`）: `ssconverter_dart` の
  CLI 未取得。リポジトリを最新化（`git pull`）してください。
- アセット未生成でウィンドウが `loading…` のまま: 先に `bash scripts/deploy-examples.sh` を実行。

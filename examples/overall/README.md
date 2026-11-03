# ssplayer_flutter_example

A Flutter app for verification that plays the SDK's `tests/overall` project, and `Ringo`, `Doll` and
`ParticleEffect` beside it. The three dropdowns at the top pick the project (`sspj`), the pack (`ssab`:
`Basic`, `Shape`, …) and the animation (`anime`); on desktop, dropping a folder or an `.ssab` on the
window plays that instead.

## Prerequisites

- **Flutter / Dart** — the minimum is on [Installation](../../docs/en/guide/install.md) (an older
  one fails `flutter pub get`).
- The native runtime (`libssruntime`). `ssruntime_dart`'s `hook/build.dart` downloads the prebuilt from the pinned SDK
  release and bundles it, so normally nothing needs placing first (no Rust needed).
  - To build it from source instead: `bash scripts/build-runtime.sh` (needs Rust)
- The example assets (`.ssab`), generated:

  ```sh
  bash scripts/deploy-examples.sh   # → writes to examples/overall/assets/spritestudio/overall/
  ```

> `libssruntime` is bundled automatically through **Native Assets**. No framework needs placing by
> hand (`flutter run` / `flutter build` run `hook/build.dart` automatically).

## Run / build (in `examples/overall/`)

> From the repository root, `bash scripts/run-<platform>.sh` does the steps below (assets,
> regenerating the runner, picking a device, launching) in one go.

> ⚠️ **The platform runners are not committed.** `examples/overall/{android,ios,macos,linux,windows,web}/`
> is in the repository's `.gitignore`, and is regenerated in each clone (see the root `.gitignore`).
> **Regenerate it the first time, and after a `git clean`** (otherwise you get
> `No macOS desktop project configured.`):
>
> ```sh
> bash examples/overall/scripts/setup-macos.sh   # macOS: flutter create plus the drag-and-drop and debug-sandbox entitlements
> cd examples/overall && flutter create --platforms=ios,android,linux,windows,web .   # the other platforms, as needed
> ```

```sh
flutter pub get
flutter run -d macos     # run (a macOS window opens)
# or
flutter build macos      # build the .app
```

### iOS / Android

As with `macos/`, the runners are not committed, so generate them first.

```sh
bash scripts/setup-mobile.sh              # ios + android (android only, off macOS)
bash scripts/setup-mobile.sh --android    # android only
pwsh scripts/setup-mobile.ps1             # Windows (android only; iOS needs Xcode)
```

The native Brain is fetched automatically from the SDK release `hook/build.dart` pins. To use a
local cross build instead, run the following at the repository root (it needs Rust and each target,
and for Android an NDK that is actually installed). `setup-mobile` prints this command when there is
no local library.

```sh
bash scripts/build-runtime.sh platform=android   # at the repository root
bash scripts/build-runtime.sh platform=ios
```

### Running on flutter_gpu (Impeller)

Switching the backend takes three switches, too long to type every time, so a wrapper bundles them.

```sh
bash scripts/run.sh -d macos                # Canvas (the default)
bash scripts/run.sh --gpu -d macos          # flutter_gpu
bash scripts/run.sh --gpu --watch -d macos  # flutter_gpu + live reload
pwsh scripts/run.ps1 -Gpu -d windows        # Windows
```

`--gpu` expands to `--dart-define=SS_BACKEND=gpu --enable-impeller --enable-flutter-gpu`. Of these,
`--enable-impeller` takes effect **only on Android** (the one target where Impeller is not the
default), and `flutter run` ignores it on macOS / iOS — on macOS the other two alone are confirmed
to reach `running on gpu`. All three are always passed, so that one flag is right on every target.
Arguments other than `--gpu` pass straight through to `flutter run`.

The console line at startup is the only evidence. `gpu` is only a *request*: when flutter_gpu is not
available, it falls back to Canvas **without a word**.

```
[ssplayer] backend: requested gpu -> running on gpu (flutter_gpu available: true)
```

On success the console prints `[ssplayer] OK — playing "…" (frame=…)`. In a macOS build,
`libssruntime` is embedded at `*.app/Contents/Frameworks/ssruntime.framework`, and the mapping is
recorded in `flutter_assets/NativeAssetsManifest.json` (`package:ssruntime_dart/ssruntime`
→ `ssruntime.framework/ssruntime`).

## Troubleshooting

- **CocoaPods is not used.** There are no plugins and the native library ships through Native
  Assets, so a newly generated `macos/` has no `Podfile`, and the build goes through without pods
  (the `.app` holds only the `App` / `FlutterMacOS` / `ssruntime` frameworks). If a `macos/Podfile`
  is left over and you get `The sandbox is not in sync with the Podfile.lock`, recreate the runner:
  `rm -rf macos && bash examples/overall/scripts/setup-macos.sh`.
- The window stays on `loading…` because the assets were never generated: run
  `bash scripts/deploy-examples.sh` first.

---

# ssplayer_flutter_example（日本語）

SDK の `tests/overall` プロジェクトと、並んで `Ringo`・`Doll`・`ParticleEffect` を再生する検証用 Flutter アプリ。上部の 3 つのドロップダウンで、プロジェクト（`sspj`）、パック（`ssab`: `Basic`、`Shape` ほか）、アニメ（`anime`）を切り替えられる。デスクトップではフォルダや `.ssab` をウィンドウにドロップしても再生できる。

## 前提

- **Flutter / Dart** —— 下限は[インストール](../../docs/ja/guide/install.md)にあります（古いと `flutter pub get` が落ちます）。
- ネイティブランタイム（`libssruntime`）。`ssruntime_dart` の `hook/build.dart` がピン留めした SDK リリースからプリビルドを自動 DL・同梱するので、通常は事前配置不要（Rust 不要）。
  - ソースからビルドする場合: `bash scripts/build-runtime.sh`（Rust 必要）
- 例アセット（`.ssab`）を生成済みであること:

  ```sh
  bash scripts/deploy-examples.sh   # → examples/overall/assets/spritestudio/overall/ に出力
  ```

> `libssruntime` は **Native Assets** で自動同梱されます。framework の手動配置は不要です（`flutter run`/`flutter build` が `hook/build.dart` を自動実行）。

## 実行 / ビルド（`examples/overall/` で）

> リポジトリのルートで `bash scripts/run-<platform>.sh` を実行すれば、以下の手順（アセット生成・runner の再生成・端末の選択・起動）を 1 回で済ませられます。

> ⚠️ **プラットフォーム runner はコミットされていません。** `examples/overall/{android,ios,macos,linux,windows,web}/`
> はリポジトリの `.gitignore` 済みで、クローン毎に再生成する方針です（ルート `.gitignore` 参照）。**初回、または `git clean` の後は必ず再生成**してください（これをしないと
> `No macOS desktop project configured.` になります）:
>
> ```sh
> bash examples/overall/scripts/setup-macos.sh   # macOS: flutter create に、ドラッグ&ドロップと debug のサンドボックス解除の entitlement を足す
> cd examples/overall && flutter create --platforms=ios,android,linux,windows,web .   # ほかのプラットフォームは必要に応じて
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

ネイティブ Brain は `hook/build.dart` がピン留めした SDK リリースから自動で取得します。手元のクロスビルドを使う場合は、リポジトリルートで次を実行します（Rust と各ターゲット、Android は実在する NDK が要る）。`setup-mobile` は、手元のライブラリが無いときにこのコマンドを表示します。

```sh
bash scripts/build-runtime.sh platform=android   # リポジトリルートで
bash scripts/build-runtime.sh platform=ios
```

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
  `App` / `FlutterMacOS` / `ssruntime` framework のみ）。`macos/Podfile` が残っていて
  `The sandbox is not in sync with the Podfile.lock` が出たら、runner を作り直してください: `rm -rf macos && bash examples/overall/scripts/setup-macos.sh`。
- アセット未生成でウィンドウが `loading…` のまま: 先に `bash scripts/deploy-examples.sh` を実行。

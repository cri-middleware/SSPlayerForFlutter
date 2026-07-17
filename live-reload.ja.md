# SpriteStudio ライブリロード — 統合設計・引き継ぎ（cold start）

> **これは何**: 「SpriteStudio でアートを保存 → Flutter のプレビューが即更新」を Flutter の
> hot reload に相乗りさせる機能の設計・実装状況・残タスクを、新規セッションが**これ1枚で再開**
> できるようにまとめたもの。詳細背景は auto-memory `ssplayer-live-reload-architecture` にもある。

## 0. 目的（達成済みの体験）

- **アニメ編集が Flutter の看板 DX（hot reload）に乗る**。コードの `r` と同じ手数でアートが反映。
- Rive/Lottie/Spine の mobile ワークフロー（host で再export→hot reload）と同等以上。
- ランタイム（`ssplayer_flutter`）は **converter を一切積まない**まま、これを実現。

## 1. 現状（2コミット・全プラットフォーム動作確認済み）

| commit | 内容 |
|---|---|
| `ade19a5` | `SpriteStudioPlayer.reload()` ＋ `ssgen_dart` ＋ `ssconverter_dart` mobile-inert 化 ＋ example ＋ `examples/overall/scripts/setup-macos.sh` |
| `9268c24` | `ssgen_flutter` dev ヘルパ（`SsLiveReload` mixin ＋ `dart run ssgen_flutter:ssreconvert`） |

- **NEW（未コミットの作業中変更）**: `ssgen_flutter:ssdev` — `flutter run --machine` を内包する live-reload dev runner（source watch → stale reconvert → daemon `app.restart{fullRestart:false}`）。signal 不使用で **Windows 対応設計**。live-reload は **`SS_LIVE_RELOAD` define で opt-in**（ssdev が自動注入、mixin/example が gate）。**Android emulator で end-to-end 検証済み**（`dart run ssgen_flutter:ssdev -d emulator-5554`）。詳細は §7(b)。
- 実機確認：**macOS desktop / iOS simulator / Android emulator** で、実際に SpriteStudio 編集→反映を確認済み（Android は ssdev 経路でも）。
- **未検証**：Windows / Linux desktop（設計上は動くはず。ssdev は daemon プロトコルのみで signal 非依存なので Windows も同一経路の見込み、実機未確認）。
- main 直コミット運用（並行プロセスが同 checkout で作業するので branch を切らず、**自分の変更のみ明示パスで commit**）。

## 2. アーキテクチャ = **B（アプリ converter-free）**

```
ssruntime_dart (L1 runtime, 全PF)
      ▲
ssplayer_flutter (L2-4 player; reload() を持つ; ★converter-FREE; 全PF)
      ▲   ← 出荷アプリの regular dependency はここまで（再生だけなら）
      │
     app ──(regular)── ssplayer_flutter        … 再生
        └──(regular)── ssgen_flutter            … dev live-reload を入れたいアプリだけ
                          ▼
                     ssgen_dart (SsProjectSync: dir走査+mtime+reconvert, pure lib)
                          ▼
                     ssconverter_dart (純 SsConverter, 1 .sspj→N .ssab, desktop-only)
```

**鉄則**: `ssplayer_flutter` に converter を**絶対混ぜない**。混ぜると `ssconverter_dart` の build hook が
全アプリ・全ターゲットで走り、iOS/Android で throw して**全 mobile アプリのビルドが壊れる**。

### パッケージの役割

| pkg | 役割 | 依存 | PF |
|---|---|---|---|
| `ssruntime_dart` | L1 FFI ランタイム bindings | — | 全PF |
| `ssplayer_flutter` | L2-4 プレイヤ。`reload()`（transport 保存の差し替え） | ssruntime_dart | 全PF |
| `ssconverter_dart` | 純 `SsConverter`（1 .sspj → N .ssab）。**hook は mobile で no-op（inert）**、runtime は desktop-only ガード | — | host(desktop) |
| `ssgen_dart` | `SsProjectSync`（`SpriteStudio_Source/` 走査＋mtime 差分＋stale だけ convert）。CLI/watch/状態なしの pure lib | ssconverter_dart | host(desktop) |
| `ssgen_flutter` | `SsLiveReload` mixin ＋ `bin/ssreconvert.dart` ＋ **`bin/ssdev.dart`**（`flutter run` 置き換えの live-reload runner）＋ 共有 const `ssLiveReloadDefine` | ssgen_dart, ssplayer_flutter, watcher, flutter | 全PF（実行時 converter-free） |

## 3. 動作フロー（reassemble に相乗り）

契機は **Flutter の hot reload**（`r` / IDE の Dart 保存）＝`State.reassemble()`。`SsLiveReload` mixin が分岐：

- **desktop**（アプリ＝host）: `SsProjectSync().reconvert(projectRoot)` を **in-process 実行**（stale だけ）→
  出力から現パックを読み `player.reload()`。→ **`r` 一発で完結**。
- **device (iOS/Android)**（アプリ＝端末、変換不可）: `player.reload()` のみ（reconvert しない）。
  新 `.ssab` は **host が別途生成** ＋ **`r` が Flutter の DevFS 同期＋`ext.flutter.evict`** で端末へ届ける。

### 変換の規約（`SsProjectSyncConfig`）
- source: `<projectRoot>/SpriteStudio_Source/`（各プロジェクトは 1 ディレクトリ = `.sspj`＋`.ssae`＋`.ssce`＋テクスチャ）
- output: `<projectRoot>/assets/spritestudio/<sspj stem>/`
- 上書き: `<projectRoot>/spritestudio.yaml`（`source:` / `output:` / `embedded:`）
- **stale 判定 = プロジェクト部分木の最新 mtime > 出力 `.ssab` の最古 mtime**（`.ssae`/`.png` 編集も拾う）
- `projectRoot` = `--dart-define=SS_PROJECT_ROOT` else `Platform.resolvedExecutable` から親を辿って `SpriteStudio_Source/` を持つ階層（macOS の `Directory.current` はサンドボックスコンテナなので使えない）

## 4. 消費アプリの統合手順（recipe）

1. `pubspec.yaml` に `ssgen_flutter`（regular dependency。reassemble が lib/ から import するため dev 不可）。
2. State に mixin ＋ getter 3つ：
   ```dart
   class _MyPageState extends State<MyPage>
       with SingleTickerProviderStateMixin, SsLiveReload<MyPage> {
     @override SpriteStudioPlayer get ssPlayer => _player;
     @override String get ssAssetDir => 'assets/spritestudio/overall'; // 現パックの出力dir(相対)
     @override String get ssPack => _pack;                              // 現パック(.ssab stem)
     @override void ssOnLiveReloaded() => setState(() {});              // 任意（UI更新）
     // 任意: ssLiveReloadEnabled(既定 kDebugMode && SS_LIVE_RELOAD define), ssProjectRoot, ssOnLiveReloadError
   }
   ```
3. **起動＝live-reload の opt-in**: `dart run ssgen_flutter:ssdev -d <device>`（推奨。`flutter run` を置き換え、`SS_LIVE_RELOAD` define を注入、保存で reconvert＋hot reload を1コマンド自動化）。手動なら `flutter run --dart-define=SS_LIVE_RELOAD=true` ＋ device では host で `dart run ssgen_flutter:ssreconvert` ＋ `r`。**define 無しの素の `flutter run` は art を reload しない**（通常の Dart hot reload のみ）。
4. **macOS**: `bash examples/overall/scripts/setup-macos.sh`（Debug の App Sandbox を false に。理由は §5）。
5. source を `SpriteStudio_Source/<project>/` に置く（`scripts/deploy-examples.sh` が overall を stage＋変換して雛形を作る）。

## 5. 既知の gotcha（ハマりどころ）

- **macOS App Sandbox**: 既定 ON だと `Directory.current`＝コンテナ、かつプロジェクト実体の読み書き/変換が不可。
  → **Debug のみ sandbox=false**（`examples/overall/scripts/setup-macos.sh`、`examples/overall/macos/` は gitignore/再生成なので
  スクリプトで冪等適用。Release は ON 維持）。
- **`examples/overall/macos/` は gitignore** → entitlements 変更は commit されない。必ず setup スクリプト経由。
- **新規 `.ssae`/パック追加**: Flutter は「新規 asset 追加を hot reload しない」。desktop は `_scanPacks`(dir走査)で
  ドロップダウンに出るが、**device は新 `.ssab` が manifest 変化＝再起動が必要**。
- **`touch` は同一バイト**: 再変換は決定的なので `touch` では出力が変わらず「見た目不変」。実変化は**本物のアート編集**で。
- **`reload()` は transport 保存**（現アニメ/frame/再生, loop/speed）。`load()` は frame0 に巻き戻す（対比）。
- **SIGUSR1=hot reload / SIGUSR2=hot restart**（`flutter run` を stdin なしで駆動可。テスト/ssdev で使用。Windows は不可）。
- **`bin/` は root .gitignore の `**/[Bb]in/*` で ignore される** → 各 pkg に `!bin/` 再包含の `.gitignore`（ssconverter_dart / ssgen_flutter が対応済み）。
- **Android AVD**: 非標準 `~/.config/.android/avd/` にあると tooling が見つけない → `~/.android/avd/` へ移動済み（`.ini` の `path=` 書換）。`flutter emulators --launch <avd>`。
- **DevFS 同期**: `r` で変更 asset を端末へ送り、`ext.flutter.evict` でキャッシュ evict。実バイト差分で確認済み（PartsColor.ssab 5760→6896 が `r` 後に反映）。ただし PLAYER は FFI Resource を旧バイトで保持するので `reassemble→player.reload()` は必須（Flutter はバイトを届けるだけ）。
- **reload トリガはツール経由必須（ssdev の肝）**: DevFS の asset 同期はツールの仕事なので、**生の VM Service `reloadSources` はコードは reload しても新 `.ssab` を運ばない**。`ssdev` は daemon プロトコルの `app.restart{fullRestart:false}`（＝`r` と同一コードパス）を使うので asset 同期込み。SIGUSR1 も可（ツールへの signal）だが Windows 不可なので daemon を採用。
- **live-reload は `SS_LIVE_RELOAD` define で opt-in**: mixin 既定 gate は `kDebugMode && bool.fromEnvironment('SS_LIVE_RELOAD')`。`ssdev` が注入、example も gate 済み。**define 無しの素の `flutter run` では reconvert が走らない**（「動かない」の一因はこれ＋実編集なしの up-to-date）。

## 6. 主要な設計判断と却下案（再litigate しないため）

- **B（アプリ converter-free）採用**: ランタイムに converter を混ぜない。dev 機能は `ssgen_flutter` に隔離。
- **`ssconverter_dart` を mobile-inert 化**（`hook/build.dart`: 非desktop OS で早期 return＝アセット出さない）:
  これで live-reload 対応アプリでも **iOS/Android がビルド可**（converter は端末に載らない）。runtime は `SsConverter.convert()` に desktop-only ガード。
- **asset transformer 案は却下**（＝Flutter の Metro/Vite ポジション）:
  - spike で**機構は成立確認**：(1)ビルド時に走る (2)**hot reload で変更入力を再変換し端末へ届く** (3)transformer pkg は **dev_dependency 可**（アプリ実行時 converter-free）。
  - **却下理由（本質的）**: transformer の入力は**宣言 asset 必須** ＝ source `.ssae` を `pubspec assets:` に列挙する必要。「sspj を assets に入れる」構造が受け入れ不可。加えて 新規`.ssae`=pubspec編集/再起動、**共有テクスチャ/.ssce 編集を追えない**（Flutter は宣言入力しか無効化しない）、変則 asset キー。
  - SDK に per-`.ssae` 1:1 変換 API があれば transformer の**冗長変換は解消**するが、**source-in-assets の壁は残る**ので却下は変わらない。
- **daemon/watcher は避ける**: 受容性の知見＝「**自動起動＋不可視**（Metro/Vite）は受容、**手動常駐**（build_runner watch）は Windows/IDE-only 層に嫌われる」。裸の常駐コマンドにはしない。
- **ssdev = daemon(machine) ラッパ採用**（§7(b) で実装）: reload トリガは **`app.restart`（ツール経由）一択**。VM Service `reloadSources`（asset 運ばない）／SIGUSR1（Windows 不可）を却下。live-reload は `SS_LIVE_RELOAD` define で **opt-in**（素の `flutter run` は通常 hot reload のみ＝毎回の再変換オーバーヘッド/不意の挙動を回避）。
- **IDE 統合 = reconvert/reload の分解**（§7(b′) で実装）: ラッパ ssdev は `flutter run` を所有するので IDE の Run/Debug と両立しない → **`ssreconvert --watch`**（flutter/daemon 非所有の reconvert-only watch）で分解。IDE で run（+define）＋保存で自動再変換＋**IDE の hot reload ボタン**（＝ツールが DevFS 同期）。トレードオフ: ssdev=ゼロキー/端末専用 ⇔ watch+IDE=1キー/デバッガ維持（full-auto＋IDE は IDE が外部 reload API を出さないので不可）。

## 7. 残タスク / 次の一手

- **(b) ssdev — ✅ 実装済み・Android emulator で検証済み（未コミット）**: `dart run ssgen_flutter:ssdev -d <device>` が `flutter run` を置き換える live-reload runner。`flutter run --machine` を内包し、`SpriteStudio_Source/` を watch → 保存で stale reconvert → daemon **`app.restart{fullRestart:false}`** で hot reload（＝`r` と同一のツール経路なので DevFS asset 同期込み）。**signal 不使用で Windows 対応設計**。`SS_LIVE_RELOAD` define を注入し opt-in を成立。`r`/`R`/`q`/Ctrl-C 操作、debounce＋single-flight、exit 時 stdin 復元。純ロジックは unit test 済み（`test/ssdev_test.dart`）。
  - 設計判断（再litigate 防止）: **VM Service `reloadSources` は却下**（asset を運ばない、§5）。SIGUSR1 も却下（Windows 不可）。→ daemon プロトコル（`app.restart`）一択。
  - **残**: 実 Windows / Linux desktop での確認（同一 daemon 経路なので有望、未実測）。手動2手（`ssreconvert`＋`r`）は ssdev の部分集合として機構的にカバー済み。
- **(b′) IDE 統合 — ✅ 実装済み（`ssreconvert --watch`）**: ラッパ ssdev は `flutter run` を所有するので **IDE の Run/Debug と両立しない**。**reconvert-only watch**（`dart run ssgen_flutter:ssreconvert --watch`、flutter/daemon 非所有、`ChangeRunner` 再利用）で分解: IDE で run（+`--dart-define=SS_LIVE_RELOAD=true`）＋本コマンドが保存で `.ssab` 再生成＋**IDE の hot reload ボタン**（＝ツールが DevFS 同期）。desktop は mixin が reassemble で再変換するので watch 不要。トレードオフ: ssdev=ゼロキー/端末専用 ⇔ watch+IDE=1キー/デバッガ維持（full-auto＋IDE は IDE が外部 reload API を出さないので不可）。VS Code=`launch.json` の `toolArgs`／IntelliJ=run config の Additional args に define。
- **(c) Windows/Linux desktop 検証**: 機構は OS 非依存のはず。Linux は bash＋no-sandbox で macOS 同様の見込み。
  Windows は `scripts/deploy-examples.ps1` が無い（.sh のみ）＋SIGUSR1 不可（ssdev は VM Service 側で回避）。native libs は release zip download or `build-runtime.{sh,ps1}`。
- **(d) `ssgen_flutter` の widget test**: mixin の reassemble を WidgetTester で回す軽いテスト（現状は example がドッグフーディングでカバー）。
- **(e) manifest（逆引き ssab→sspj）**: Unity/Godot の「エディタから元 sspj を開く」相当。`SsProjectSync` に薄く足せる（今は mtime 走査のみ）。

## 8. 主要ファイル

| path | 役割 |
|---|---|
| `packages/ssplayer_flutter/lib/src/player.dart` | `SpriteStudioPlayer.reload()`（transport 保存） |
| `packages/ssgen_dart/lib/src/project_sync.dart` | `SsProjectSync` / `SsProjectSyncConfig` / `SsReconvertReport` |
| `packages/ssconverter_dart/hook/build.dart` | mobile-inert 化した native-assets hook（非desktop 早期 return） |
| `packages/ssconverter_dart/lib/src/converter.dart` | `SsConverter.convert()`（desktop-only runtime ガード） |
| `packages/ssgen_flutter/lib/src/live_reload.dart` | `SsLiveReload` mixin（reassemble→desktop 再変換+reload / device reload-only） |
| `packages/ssgen_flutter/bin/ssreconvert.dart` | host reconvert runner。`--watch` で reconvert-only watch（IDE フレンドリー：flutter/daemon 非所有、`ChangeRunner` 再利用） |
| `packages/ssgen_flutter/bin/ssdev.dart` | `dart run ssgen_flutter:ssdev` の薄い main（→ `runSsDev`） |
| `packages/ssgen_flutter/lib/src/ssdev.dart` | ssdev 本体: `FlutterDaemon`(machine プロトコル)/`ChangeRunner`(debounce)/`SsDevOptions`/`withLiveReloadDefine`/`runSsDev` |
| `packages/ssgen_flutter/lib/src/ss_defines.dart` | 共有 const `ssLiveReloadDefine`（`'SS_LIVE_RELOAD'`）。`ssgen_flutter.dart` から公開 export |
| `examples/overall/lib/main.dart` | mixin 利用のドッグフーディング |
| `examples/overall/scripts/setup-macos.sh` | Debug sandbox off（＋drag&drop entitlement） |
| `scripts/deploy-examples.sh` | overall を `SpriteStudio_Source/` に stage＋`assets/spritestudio/overall/` へ変換 |

## 9. 動作確認レシピ（手元で再現）

```bash
bash scripts/deploy-examples.sh          # source を stage＋変換
bash examples/overall/scripts/setup-macos.sh             # macOS のみ: Debug sandbox off
cd examples/overall

# desktop（r 一発）
flutter run -d macos
#  SpriteStudio_Source/overall/PartsColor.ssae を本当に編集して保存 → r
#  → [ssplayer] live-reloaded "PartsColor"

# device（host 再変換 → r の2手。ssdev(b) で1手に畳む予定）
flutter emulators --launch ssplayer_test        # or apple_ios_simulator
flutter run -d emulator-5554
#  別ターミナル(examples/overall/): 編集して保存 → dart run ssgen_flutter:ssreconvert
#  flutter run 側で r → 端末に反映
```

> 注意: `touch` だけだと出力バイトが同一で見た目は変わらない（正常）。実際の編集で確認すること。

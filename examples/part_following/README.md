# part_following — attach a widget to a live part

A runnable Flutter app that demonstrates **part following**: sticking an ordinary
Flutter widget to a SpriteStudio part so it tracks that part's **position,
rotation and scale** every frame. It runs the **Ringo** character and pins a
marker to a part with `SpriteStudioPartAnchor`.

This is the Flutter take on the same feature as
[SSPlayerForUnity](https://github.com/cri-middleware/SSPlayerForUnity)'s part
tracker (`SpriteStudioPartTracker`) and
[SSPlayerForGodot](https://github.com/cri-middleware/SSPlayerForGodot)'s part
attachment (`SpriteStudioPartAttachment2D`), and a direct port of
[SSPlayerForWeb](https://github.com/cri-middleware/SSPlayerForWeb)'s
`examples/part-follow`. Each engine delivers the same capability its own
idiomatic way; Flutter's is a Widget you drop into the tree.

## Run it

From the repo root, `bash scripts/run-<platform>.sh example=part_following` does all of the
below — assets, the platform runner, a device — in one step. By hand:

```sh
# First time / after a pull: stage the Ringo assets (see "The assets" below).
bash scripts/deploy-examples.sh          # from the repo root

cd examples/part_following
flutter run -d windows          # or -d macos, -d chrome, -d <device>
```

The character loops while a star marker rides the followed part. Use the
**Follow target** picker (top-right) to point the marker at any part, the buttons
(bottom) to switch **motion** and toggle **Attach**, **Scale follow** and
**onHide: hide**.

## The teaching point — skinned mesh parts are poor follow targets

Ringo is a rig with **skinned (bone-bound) mesh** parts: its hands, legs, ears
and tail. A skinned part's vertices are drawn by bone skinning, but the part's
*own* transform stays near the character root — so following one snaps the marker
to the root instead of onto the visible art. Only skinned parts do this; a
*rigid* (deform-only) mesh, and every bone / joint / NULL part, follows correctly.

The follow-target picker mirrors the Unity and Godot inspectors:

- Skinned parts are **listed but disabled (dimmed)** so they can't be picked by
  accident — the dropdown is built from `player.partNames.names` and each entry
  is dimmed when `player.isPartSkinnedMesh(name)` is true.
- The **text box** beside it still accepts any name (including a skinned one),
  matching those editors' "type it to override" escape hatch — and a
  **non-blocking warning** appears, because `isPartSkinnedMesh` is a *hint*, not a
  gate. Type `hand_r` to see it.
- The default target, `bone_14`, is a bone in the right-hand chain — the
  recommended kind of follow target.

See the [Part Following guide](../../docs/en/guide/part-following.md) for the full
API and the caveat.

## What to read

`lib/main.dart` is the whole demo. The one rule that makes it line up: the
follower must share the **same coordinate space** as the animation. Here the
`SpriteStudioView` and the `SpriteStudioPartAnchor` are both children of one
transformed `Stack`, so any nudge or scale moves them together:

```dart
FractionalTranslation(
  translation: const Offset(0, 0.25),
  child: Stack(
    fit: StackFit.expand,
    children: [
      SpriteStudioView(player: player),
      Positioned.fill(
        child: SpriteStudioPartAnchor(
          player: player,
          partName: 'bone_14',
          child: myMarker,           // any widget; its top-left pins to the part
        ),
      ),
    ],
  ),
)
```

The read API the anchor drives (`partTransform` / `isPartHidden` /
`isPartSkinnedMesh` / `findPartIndex` / `partNames`) lives on
`SpriteStudioPlayer`, so you can also follow a part by hand — e.g. from a Flame
component — without the widget. The status readout shows the pull side directly:
`partTransform(name)` re-read each frame via a `ListenableBuilder` on the player.

## The assets

`assets/spritestudio/Ringo/` is **generated, not committed** (git-ignored). It is
the same self-contained Ringo pack the `flame` example uses,
staged by `scripts/deploy-examples.sh`, which converts the SDK's `tests/Ringo`
project with the `ssconvert` CLI (`ssconverter_dart`) — no Rust toolchain needed:
its build hook downloads the converter's native library.

## Limits

Tracks top-level parts only (a part nested inside an Instance part lives in a
child player and cannot be followed), and transfers only the spatial transform —
not draw order, so the marker paints on top rather than being interleaved between
the character's own parts.

---

# part_following — 動いているパーツにウィジェットを貼り付ける

**パーツトラッキング**を見せる、実行できる Flutter アプリです。通常の Flutter ウィジェットを SpriteStudio のパーツに貼り付け、そのパーツの**位置・回転・スケール**に毎フレーム追従させます。**Ringo** キャラクターを再生し、`SpriteStudioPartAnchor` でマーカーをパーツに固定します。

[SSPlayerForUnity](https://github.com/cri-middleware/SSPlayerForUnity) のパーツトラッカー（`SpriteStudioPartTracker`）や [SSPlayerForGodot](https://github.com/cri-middleware/SSPlayerForGodot) のパーツアタッチメント（`SpriteStudioPartAttachment2D`）と同じ機能の Flutter 版で、[SSPlayerForWeb](https://github.com/cri-middleware/SSPlayerForWeb) の `examples/part-follow` をそのまま移植したものです。各エンジンは同じ機能をそれぞれの流儀で提供しており、Flutter ではツリーに置く Widget です。

## 実行する

リポジトリのルートで `bash scripts/run-<platform>.sh example=part_following` を実行すれば、以下の手順（アセット、プラットフォーム runner、端末）を 1 回で済ませられます。手で行う場合は次のとおりです。

```sh
# 初回 / pull の後: Ringo のアセットを配置します（下の「アセット」を参照）。
bash scripts/deploy-examples.sh          # リポジトリのルートで

cd examples/part_following
flutter run -d windows          # または -d macos、-d chrome、-d <device>
```

キャラクターがループ再生し、星のマーカーが追従先のパーツに乗って動きます。右上の **Follow target** ピッカーでマーカーの追従先を任意のパーツに変え、下のボタンで **motion** を切り替えたり、**Attach**・**Scale follow**・**onHide: hide** をオン / オフしたりできます。

## 要点 —— スキンメッシュのパーツは追従先に向きません

Ringo は**スキン（ボーンにバインドされた）メッシュ**のパーツを持つリグです。手・脚・耳・しっぽがそれにあたります。スキンパーツの頂点はボーンのスキニングで描かれますが、パーツ*自身*のトランスフォームはキャラクターのルート付近に留まります。そのため、それを追従するとマーカーは見えている絵ではなくルートに飛びます。こうなるのはスキンパーツだけで、*リジッド*（変形のみ）のメッシュや、ボーン / ジョイント / NULL パーツはすべて正しく追従します。

追従先ピッカーは Unity と Godot のインスペクターに倣っています。

- スキンパーツは**一覧に出ますが無効（薄い表示）**なので、誤って選ぶことはありません。ドロップダウンは `player.partNames.names` から作られ、`player.isPartSkinnedMesh(name)` が true の項目は薄く表示されます。
- 横の**テキストボックス**には、スキンパーツを含む任意の名前を入力できます。これらのエディターにある「入力すれば上書きできる」逃げ道と同じです。入力すると**操作を妨げない警告**が出ます。`isPartSkinnedMesh` は*ヒント*であって、関門ではないためです。`hand_r` と入力すると確かめられます。
- 既定の追従先 `bone_14` は右手のチェーンにあるボーンで、推奨される種類の追従先です。

API の全体と注意点は[パーツトラッキングのガイド](../../docs/ja/guide/part-following.md)を参照してください。

## 読むところ

デモの全体は `lib/main.dart` です。位置を揃えるためのルールは 1 つで、追従する側はアニメーションと**同じ座標空間**を共有している必要があります。ここでは `SpriteStudioView` と `SpriteStudioPartAnchor` がどちらも、変換を掛けた 1 つの `Stack` の子なので、ずらしてもスケールしても一緒に動きます。

```dart
FractionalTranslation(
  translation: const Offset(0, 0.25),
  child: Stack(
    fit: StackFit.expand,
    children: [
      SpriteStudioView(player: player),
      Positioned.fill(
        child: SpriteStudioPartAnchor(
          player: player,
          partName: 'bone_14',
          child: myMarker,           // 任意のウィジェット。左上がパーツに固定されます
        ),
      ),
    ],
  ),
)
```

アンカーが使う読み取り API（`partTransform` / `isPartHidden` / `isPartSkinnedMesh` / `findPartIndex` / `partNames`）は `SpriteStudioPlayer` にあるので、ウィジェットを使わずに手でパーツを追従することもできます（たとえば Flame のコンポーネントから）。ステータス表示は取得する側をそのまま見せています。プレイヤーに対する `ListenableBuilder` で、`partTransform(name)` を毎フレーム読み直しています。

## アセット

`assets/spritestudio/Ringo/` は**生成物で、コミットされていません**（git-ignore 済み）。`flame` サンプルが使うのと同じ自己完結した Ringo のパックで、`scripts/deploy-examples.sh` が配置します。このスクリプトは SDK の `tests/Ringo` プロジェクトを `ssconvert` CLI（`ssconverter_dart`）で変換します。Rust ツールチェーンは不要で、ビルドフックがコンバーターのネイティブライブラリをダウンロードします。

## 制限

追従できるのはトップレベルのパーツだけです（Instance パーツの中にあるパーツは子プレイヤーに属するため、追従できません）。また、伝えるのは空間的なトランスフォームだけで、描画順は伝えません。そのため、マーカーはキャラクター自身のパーツの間には挟まらず、その上に描かれます。

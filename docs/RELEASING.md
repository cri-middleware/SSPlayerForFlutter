# Releasing — monorepo, independent versioning, main-only

This repo publishes several packages from a single `main` branch with
**independent** SemVer per package. Three layers, each with one job:

| Concern | Tool |
|---|---|
| Resolve the workspace (shared lockfile) | **pub workspaces** (`resolution: workspace`) |
| Decide the bump per package + CHANGELOG + git tag | **Melos** (`melos version`, Conventional Commits) |
| Publish each package on its tag | **pub.dev automated publishing** (GitHub Actions OIDC) |

The release trigger is **on-demand**: merge PRs to `main` normally, then run the
**Release** workflow by hand when you want to cut versions. No release branches.

## Conventional Commits drive the bump

Melos reads commit messages since each package's last `<package>-v<version>` tag:

| Commit | Bump |
|---|---|
| `fix: …` / `fix(<pkg>): …` | **patch** |
| `feat: …` / `feat(<pkg>): …` | **minor** |
| `feat!: …` or a `BREAKING CHANGE:` footer | **major** |
| `chore/docs/refactor/test/ci: …` | none on their own |

Use the package name as the scope (`feat(ssruntime_dart): …`) so the CHANGELOG
attributes it correctly. Because versioning is **fully independent**, a `feat!`
in `ssruntime_dart` majors only `ssruntime_dart`; its dependents
(`ssplayer_flutter`, then `ssgen_flutter`) get an automatic patch + a "Updated a
dependency" changelog entry and their constraint is bumped — Melos does this via
`--dependent-versions` / `--dependent-constraints`, both on by default.

## One-time setup (per package, before its first automated publish)

1. **Claim the name.** Remove `publish_to: none` from the package's
   `pubspec.yaml`, then publish once **manually** (`dart pub publish` /
   `flutter pub publish`). Do the first-ever publishes in dependency order —
   `ssruntime_dart`, `ssconverter_dart` → `ssgen_dart`, `ssplayer_flutter` →
   `ssgen_flutter` — because a dependent can't resolve on pub.dev until its deps
   already exist there.
2. **Enable automated publishing.** pub.dev → the package → **Admin** →
   *Automated publishing* → enable **GitHub Actions**, set repository to
   `cri-middleware/SSPlayerForFlutter`, and set the **tag pattern** to
   `<package>-v{{version}}` (e.g. `ssruntime_dart-v{{version}}`). This must match
   the tags Melos produces. Optionally require an environment (then add
   `with: { environment: <name> }` to that job in `publish.yml` and create the
   matching GitHub environment).
3. **Release token.** Add a repo secret **`RELEASE_PAT`** — a fine-grained PAT
   (or GitHub App token) with `contents: write` on this repo. `release.yml`
   pushes tags with it. The default `GITHUB_TOKEN` is deliberately avoided:
   tags it pushes do **not** trigger `publish.yml`.

## Cutting a release (steady state)

1. Land PRs on `main` with Conventional Commit messages.
2. **Actions → Release → Run workflow** (tick *dry-run* first to preview the
   computed versions in the logs without pushing).
3. Melos bumps each changed **public** package independently, writes CHANGELOGs,
   commits `chore(release): version packages`, and pushes `<package>-v<version>`
   tags.
4. Each tag triggers `publish.yml`, which publishes just that package to pub.dev
   over OIDC.

## Notes / gotchas

- **`publish_to: none` is the on/off switch.** `release.yml` runs
  `melos version --no-private`, so a package keeps out of releases entirely while
  that line is present. Remove it (step 1) only when the package is ready to go
  public.
- **Native assets:** publishing ships source only. The prebuilt `libssruntime` /
  `libssconverter` are fetched by each package's `hook/build.dart` at the
  consumer's build time (pinned `_sdkVersion`); `native/` is gitignored and not in
  the published archive — nothing to do at release time.
- **Melos is a pinned workspace dev-dependency (`>=7.0.0 <7.8.2`).** It must be a
  dependency — its `cli_launcher` finds the workspace only via a pubspec that
  depends on melos, so a global `pub global activate` install can't detect it.
  It is pinned below 7.8.2 because 7.8.2 bumped its transitive `cli_util` to
  `^0.5.0`, which conflicts with `ffigen`'s `^0.4.2` pin in the shared workspace
  resolution; 7.8.1 is the newest compatible melos. Invoke it via `dart run
  melos …` (uses the exact version from `pubspec.lock`).
- **Local preview without CI:** `dart run melos version --yes --no-private
  --no-git-tag-version` edits versions/CHANGELOGs but makes no commit or tag —
  inspect, then `git restore .`.
- **Toolchain is pinned** to Flutter 3.44.6 / Dart 3.12.2 (see `release.yml` and
  the root `environment:`); bump both together when the local toolchain moves.

# 🚢 Releasing

The monorepo publishes several packages from a single `main` branch with **independent** SemVer per
package. Three layers, each with one job:

| Concern | Tool |
|---|---|
| Resolve the workspace (shared lockfile) | **pub workspaces** (`resolution: workspace`) |
| Decide each package's bump + CHANGELOG + git tag | **[Melos](https://melos.invertase.dev/)** (Conventional Commits) |
| Publish each package on its tag | **pub.dev automated publishing** (GitHub Actions OIDC) |

The release trigger is **on-demand**: merge PRs to `main` normally, then run the **Release** workflow
by hand when you want to cut versions. No release branches.

## Conventional Commits drive the bump

Melos reads commit messages since each package's last `<package>-v<version>` tag:

| Commit | Bump |
|---|---|
| `fix: …` / `fix(<pkg>): …` | patch |
| `feat: …` / `feat(<pkg>): …` | minor |
| `feat!: …` or a `BREAKING CHANGE:` footer | major |
| `chore` / `docs` / `refactor` / `test` / `ci` | none on their own |

Use the package name as the scope (`feat(ssruntime_dart): …`). Versioning is **fully independent**: a
`feat!` in `ssruntime_dart` majors only `ssruntime_dart`; dependents get an automatic patch + a
constraint bump.

## Cutting a release (steady state)

1. Land PRs on `main` with Conventional Commit messages.
2. **Actions → Release → Run workflow** (tick *dry-run* first to preview the computed versions).
3. Melos bumps each changed public package, writes CHANGELOGs, commits `chore(release): …`, and pushes
   `<package>-v<version>` tags.
4. Each tag triggers `publish.yml`, which publishes just that package to pub.dev over OIDC.

## Gotchas

- **`publish_to: none` is the on/off switch.** `release.yml` runs `melos version --no-private`, so a
  package stays out of releases entirely while that line is present. Remove it (and do the first
  publish manually, in dependency order) only when the package is ready to go public.
- **Native assets ship source only.** The prebuilt `libssruntime` / `libssconverter` are fetched by
  each package's `hook/build.dart` at the *consumer's* build time; `native/` is gitignored and not in
  the published archive — nothing to do at release time.
- **Melos is a pinned workspace dev-dependency** (`>=7.0.0 <7.8.2`; 7.8.2 pulls a `cli_util` that
  conflicts with ffigen's pin). Invoke via `dart run melos …`.
- **CI toolchain is pinned** in `release.yml` (Flutter 3.44.6 / Dart 3.12.2). The package
  `environment:` declares only the support *floor* (`sdk: >=3.10.0`, Flutter `>=3.38.0`) — deliberately
  lower, so consumers aren't forced onto the exact CI version. Bump the `release.yml` pin as your local
  toolchain moves.

/// Host-side "reconvert only the stale SpriteStudio projects in a directory"
/// library — the orchestration layer over `ssconverter_dart` behind a
/// consumer-owned reconvert trigger (typically `ssgen_flutter`'s `sswatch`
/// runner, which watches the source tree and pushes the result). No CLI, no
/// watcher, no daemon state. **Desktop only** — it drives the host `libssconverter`.
library;

export 'src/project_sync.dart'
    show SsProjectSync, SsProjectSyncConfig, SsReconvertReport;

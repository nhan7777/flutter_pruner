# Flutter Pruner

<p align="center">
  <img
    src="doc/images/flutter_pruner_banner.png"
    alt="Flutter Pruner — semantic cleanup for Flutter and Dart projects"
    width="100%"
  >
</p>

<p align="center">
  <a href="https://pub.dev/packages/flutter_pruner"><img src="https://img.shields.io/pub/v/flutter_pruner.svg?logo=dart&amp;logoColor=white" alt="pub package"></a>
  <a href="https://github.com/nhan7777/flutter_pruner/actions/workflows/ci.yml"><img src="https://github.com/nhan7777/flutter_pruner/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/nhan7777/flutter_pruner" alt="License"></a>
</p>

<p align="center">
  <strong>Safety-first semantic cleanup for Dart and Flutter.</strong><br>
  Find unreachable declarations and assets, review the evidence, then apply only
  changes allowed by the configured safety policy.
</p>

## Install

Requires Dart SDK 3.9 or newer.

```bash
dart pub global activate flutter_pruner
```

## Four commands

```bash
flutter_pruner init            # declare project boundary and targets
flutter_pruner scan            # analyze, save report, change nothing
flutter_pruner apply --dry-run # preview the plan, change nothing
flutter_pruner apply           # quarantine originals, mutate, verify
```

To undo: `flutter_pruner rollback <run-id>`.

See the [5-minute quickstart](doc/quickstart.md) for a complete walkthrough.

## Safety in one box

- **Start from a clean Git worktree.** Rollback is a recovery layer, not a
  replacement for version control.
- **Review `.flutter_pruner/config.yaml`.** Coverage is declared by you, never
  inferred.
- **Scan exits 0 even with findings.** Inspect the report, not the exit code.
- **Stop on `recoveryRequired`.** Inspect quarantine before running anything
  else.

Read [how the workflow works](doc/workflow.md) before applying to an
important project.

## Documentation

- [5-minute quickstart](doc/quickstart.md)
- [Workflow and safety model](doc/workflow.md)
- [CLI and CI reference](doc/reference.md)
- [Project configuration](doc/flutter_pruner.yaml.md)

Found a false `SAFE` finding, data loss, or broken rollback? Open an
[issue](https://github.com/nhan7777/flutter_pruner/issues) — these are
release-blocking defects.

## License

MIT — see [LICENSE](LICENSE).

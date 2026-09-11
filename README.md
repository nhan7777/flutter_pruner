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
  Find unreachable Dart declarations, assets, and other supported resources;
  review the evidence, then apply only changes allowed by the configured safety
  policy.
</p>

## 📦 Install

Requires Dart SDK 3.9 or newer.

```bash
dart pub global activate flutter_pruner
```

## ✨ What it finds

Six built-in analyzers share one reachability graph, so cross-domain chains
(e.g. a route referencing an asset referenced from Dart) are resolved together:

| Analyzer | Finds |
|---|---|
| 📝 Dart declarations | Unreachable libraries, declarations, unused imports |
| 🖼️ Assets | Declared asset families with no resolved reference |
| 📑 Duplicates | Byte-identical files that could be unified |
| 🧭 GoRouter routes | Routes unreachable from any entry point |
| 💉 GetIt registrations | DI registrations never resolved |
| 🌍 Localization | Unused ARB keys and generated l10n dead code |

Every finding carries a confidence tier and the evidence behind it — the
explanation is the product, not a score.

## 🛡️ Confidence tiers

| Tier | Meaning | Can apply? |
|---|---|---|
| `SAFE` | Every safety predicate holds | ✅ Yes |
| `HIGH` | All hard gates hold, one known manual risk | ⚠️ Package-internal only, with confirmation |
| `REVIEW` | Evidence incomplete or ambiguous | ❌ Never |
| `PROTECTED` | Must be kept (framework wiring, entry points) | ❌ Never |

`PROTECTED` always wins. Most findings on a mature codebase land in `HIGH` or
`REVIEW` — that is the intended outcome, not a limitation.

## 🚀 Four commands

```bash
flutter_pruner init            # declare project boundary and targets
flutter_pruner scan            # analyze, save report, change nothing
flutter_pruner apply --dry-run # preview the plan, change nothing
flutter_pruner apply           # quarantine originals, mutate, verify
```

To undo: `flutter_pruner rollback <run-id>`.

See the [5-minute quickstart](doc/quickstart.md) for a complete walkthrough.

## 🔄 Apply and recover

A mutating run is all-or-nothing: originals are quarantined before editing,
the project is rescanned and verified after mutation, and everything is
restored if any step fails.

```bash
flutter_pruner quarantine list
flutter_pruner quarantine inspect <run-id>
flutter_pruner rollback <run-id>
```

Read [how the workflow works](doc/workflow.md) before applying to an
important project.

## ⚠️ Safety in one box

- **Start from a clean Git worktree.** Rollback is a recovery layer, not a
  replacement for version control.
- **Review `.flutter_pruner/config.yaml`.** Coverage is declared by you, never
  inferred.
- **Scan exits 0 even with findings.** Inspect the report, not the exit code.
- **Stop on `recoveryRequired`.** Inspect quarantine before running anything
  else.

## 📊 Reports

Every completed scan saves one immutable report under
`.flutter_pruner/reports/`. HTML is the default and works offline — open the
path printed at the end of the run.

For CI, save JSON and inspect tiers — never parse human stdout:

```bash
flutter_pruner scan --format json --output scan.json
jq -e '
  .run.status == "completed" and
  .statistics.findings.byTier.SAFE == 0 and
  .statistics.findings.byTier.HIGH == 0
' .flutter_pruner/reports/scan.json
```

## ⚙️ Configuration

`flutter_pruner init` writes `.flutter_pruner/config.yaml` — the declared
analysis boundary:

```yaml
version: 1
analysis:
  mode: application   # application | package | package-internal
target_matrix:
  complete: true
  targets:
    - name: android-prod
      platform: android
      entrypoint: lib/main.dart
```

Three modes: `application` (closed app, `SAFE` may apply), `package`
(external consumers unknown, audit-only), `package-internal` (local package
evaluation, `SAFE` plus one allowlisted `HIGH` with confirmation).

See [every config field](doc/flutter_pruner.yaml.md).

## 📚 Documentation

- [5-minute quickstart](doc/quickstart.md)
- [Workflow and safety model](doc/workflow.md)
- [CLI and CI reference](doc/reference.md)
- [Project configuration](doc/flutter_pruner.yaml.md)

Technical architecture, report storage, performance, and release-validation
notes remain repository-only deep dives.

Found a false `SAFE` finding, data loss, or broken rollback? Open an
[issue](https://github.com/nhan7777/flutter_pruner/issues) — these are
release-blocking defects.

## 🤝 Contributing

New domains land as adapters in `lib/src/adapters/` — see
[how to add an adapter](doc/contributing/how-to-add-adapter.md).
Core reachability and confidence logic stays domain-agnostic.

## 📄 License

MIT — see [LICENSE](LICENSE).

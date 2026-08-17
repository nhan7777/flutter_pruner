# Flutter Pruner CLI example

This walkthrough scans a disposable Dart project before previewing any cleanup.
Run it from a clean Git worktree so every proposed change is easy to review.

## Install the CLI

```bash
dart pub global activate flutter_pruner
```

## Create a project to inspect

```bash
dart create -t console flutter_pruner_example
cd flutter_pruner_example
git init
git add .
git commit -m "chore: capture clean baseline"
```

## Configure the analysis boundary

```bash
flutter_pruner init
```

Review `.flutter_pruner/config.yaml`, especially the detected project type,
targets, public entrypoints, and verification commands. Flutter Pruner does not
infer that target coverage is complete on your behalf.

## Scan without changing the project

```bash
flutter_pruner scan
```

The scan is read-only for project source files and assets. Findings remain
non-actionable when coverage or semantic evidence is incomplete.

## Preview and apply eligible findings

```bash
flutter_pruner apply --dry-run
flutter_pruner apply
```

Review the dry-run before applying. Package mode is intentionally review-only;
only configurations whose declared boundary and safety gates permit mutation
can apply findings.

## Roll back an applied run

```bash
flutter_pruner quarantine list
flutter_pruner rollback <run-id>
```

Each mutating run records its recovery data under
`.flutter_pruner/quarantine/<run-id>`. Keep the quarantine until the resulting
project has been reviewed and verified.

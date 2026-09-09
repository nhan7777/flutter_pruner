# Quickstart (5 minutes)

> **Goal:** run your first safe cleanup on a disposable copy.
> **Requires:** Dart SDK 3.9+, a Flutter or Dart project with Git.

## 1. Copy your project

Never run your first apply on the real project.

```bash
cp -r ~/my_app /tmp/my_app_trial
cd /tmp/my_app_trial
git status   # must be clean
```

## 2. Declare the boundary

```bash
flutter_pruner init
```

Review `.flutter_pruner/config.yaml`. Confirm the analysis mode matches what
you own (`application` for a complete app, `package` for a reusable library).

## 3. Scan

```bash
flutter_pruner scan
```

This changes nothing. Open the HTML report path printed at the end and review
the findings table. Each finding has a tier:

| Tier | Meaning | Can apply? |
|---|---|---|
| `SAFE` | All gates passed | Yes |
| `HIGH` | One known manual risk | Package-internal only |
| `REVIEW` | Evidence incomplete | Never |
| `PROTECTED` | Must be kept | Never |

## 4. Preview

```bash
flutter_pruner apply --dry-run
```

This validates the plan and shows every file that would change. It still
changes nothing.

## 5. Apply and verify

```bash
flutter_pruner apply
```

Originals are quarantined before editing. The project is rescanned and
verified after mutation.

## 6. Undo if needed

```bash
flutter_pruner quarantine list
flutter_pruner rollback <run-id>
```

## Next steps

- [Workflow and safety model](workflow.md) — tiers, modes, and recovery states.
- [CLI and CI reference](reference.md) — flags, exit codes, and JSON reports.
- [Project configuration](flutter_pruner.yaml.md) — every config field.

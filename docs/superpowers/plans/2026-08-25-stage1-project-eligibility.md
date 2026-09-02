# Stage 1 Project Eligibility Implementation Plan

**Goal:** Make production Stage 1 fail fast per corpus project, bind Smooth to an exact compatible SDK, and prevent external Dart closure issues from masquerading as project-owned l10n blockers.

**Architecture:** Add a project eligibility gate ahead of individual and family mutation attempts. The gate provisions one disposable view, runs the production scan and family evidence pipeline, and records a redaction-safe terminal eligibility record. Rejected projects receive deterministic skipped attempt records without repeating the same expensive rejection. Smooth uses a hashed `3.44.9` selector fixture plus exact machine identity; GitJournal and GSY remain fail-closed for project-owned blockers.

**Tech Stack:** Dart, package:test, existing production readiness composition, l10n evidence pipeline, frozen manifest builder.

---

## Task 1: Freeze the new authority contract

- Add failing parser/manifest tests for the SDK set `3.41.5`, `3.44.1`, `3.44.9`.
- Add a hashed Smooth `.fvmrc` fixture and exact Flutter 3.44.9 machine evidence.
- Update the independent manifest builder and frozen manifest expectations.

## Task 2: Add project eligibility orchestration

- Add failing contract tests proving one eligibility run per project.
- Record eligibility before mutation attempts and synthesize deterministic failed attempts when a project is rejected.
- Preserve all Stage 1 denominators and resume validation; do not reinterpret skipped work as passed.

## Task 3: Scope external closure blockers

- Add failing resolver tests for conditional/analyzer issues owned by external SDK or pub-cache packages.
- Exclude external issues that cannot name a configured project l10n member.
- Preserve project-owned dynamic localization and unclassified-entrypoint blockers.

## Task 4: Verify production behavior

- Regenerate the manifest byte-for-byte from the independent builder.
- Run focused tests, analyzer, format check, and `git diff --check`.
- Run one production family smoke per project, then the full Stage 1 corpus only if eligibility allows useful progress.
- Confirm retained corpus repositories remain at their exact SHAs and clean.

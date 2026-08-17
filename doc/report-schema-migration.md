# Report schema migration policy

Flutter Pruner treats JSON reports as a supported integration surface. Schema
changes must preserve auditability and cannot silently change the meaning of a
safety or recovery field.

## Compatibility rules

- Consumers must select a schema explicitly when reproducibility matters.
  Schema v3 is the default; `--json-version 2` is compatibility-only.
- Adding an optional field, enum value, adapter catalog entry, measurement kind,
  or diagnostic code is additive. Consumers must ignore unknown fields and
  handle unknown enum-like strings conservatively.
- Removing or renaming a field, changing its type, moving it to another counter
  domain, or changing its safety semantics requires a new schema version.
- Existing fields never change from `unknown` to zero by omission. A missing or
  unknown measurement remains unavailable evidence.
- Adapter presentation metadata can add labels and detail definitions, but it
  cannot grant confidence or mutation authority.

## Version lifecycle

When schema `N` becomes the default, schema `N-1` remains selectable for at
least one published minor release and until the next major release boundary.
Deprecation and the earliest removal release must be announced in the changelog
before removal. A compatibility formatter preserves the old wire contract; it
does not backport new safety evidence into fields whose old semantics cannot
represent it.

Schema v2 is therefore retained while v3 is the default. New integrations must
use v3 typed measurements and coverage fields.

## Reader and writer behavior

Writers emit deterministic key meanings, stable raw IDs, sorted identifier
collections where order has no semantic meaning, and a top-level schema
version. Readers should:

1. reject unsupported major schema versions;
2. ignore unknown additive fields;
3. treat unknown statuses, confidence tiers, or recovery states as
   non-actionable;
4. use raw IDs for automation and presentation labels only for display;
5. never reconstruct rollback state from a run report.

The quarantine manifest is a separate recovery protocol. New apply runs write
manifest V3, while V1 and V2 manifests remain readable and restorable. The
manifest remains authoritative for bytes, transaction state, verification
evidence, and rollback; report migrations cannot weaken that contract.

## Change checklist

Before merging a report change:

- classify it as additive or schema-breaking;
- update v3 serialization and its contract tests;
- update the v2 compatibility formatter when the old schema can represent the
  change without changing meaning;
- test CI selectors and unknown-field tolerance;
- update `doc/run-report.md`, the changelog, and adapter presentation metadata;
- verify JSON, human, and HTML output still describe the same run state.

V2 adapters may add rule IDs, node kinds, typed details, and measurements under
these additive rules. They must not repurpose an existing raw ID or field.

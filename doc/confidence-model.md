# The confidence model

Flutter Pruner sorts every finding into one of four tiers. This document
explains what the tiers mean and why they are predicates rather than a numeric
score.

---

## The tiers

| Tier | Meaning | Apply behaviour |
|---|---|---|
| `SAFE` | every safety predicate holds | applied by default |
| `HIGH` | all hard gates hold, with exactly one allowlisted manual risk | package-internal only, with confirmation |
| `REVIEW` | a human must decide | reported, never applied |
| `PROTECTED` | unreferenced but must not be removed | reported as information |

`PROTECTED` is not a weaker `REVIEW`. It says: this really does appear unused,
and removing it is still wrong. Framework entry points and explicit keep rules
are typical examples. External-consumer risk is intentionally modelled as
`HIGH` in `package-internal`: it remains eligible only after interactive
confirmation or `--yes`.

---

## Why not a score

The obvious design is a float and a threshold: `confidence > 0.95 → delete`.
It is the wrong shape for this problem, for three reasons.

**A score cannot be explained.** "0.93" tells a user nothing about what to check.
"Unreachable in all 4 targets, but a dart-define branch could not be evaluated"
tells them exactly where to look. For an operation that deletes their code, the
explanation *is* the product.

**Scores invite arithmetic that is not meaningful.** Once confidence is a
number, someone averages it, or multiplies two 0.9s into 0.81. But "unreachable
from all roots" and "no dynamic blocker" are not independent probabilities to
combine. They are conditions that either hold or do not.

**Thresholds drift.** A test fails, someone nudges 0.95 to 0.93, and the safety
guarantee silently weakens with no reviewable diff. With predicates, weakening
safety means deleting a named predicate — visible in review, and hard to justify
in a PR description.

---

## Hard gates and explicit HIGH risks

`SAFE` requires all eight predicates below: complete selected-boundary and target
coverage, complete incoming graph evidence, and an action the core owns. A
blocker, protection, unsupported action, missing inverse, incomplete scope or a
dangling incoming edge on the candidate always produces `REVIEW`/`PROTECTED`;
none can fall through to `HIGH`.

**`ruleAllowsAutoFix`** — the rule itself has a mechanical fix. Some findings are
informational by nature; a rule that cannot express its own fix never produces
`SAFE`.

**`unreachableAcrossAllTargets`** — dead in *every* configured build target, not
just the default one. See [`graph-model.md`](graph-model.md) for the formula.
Code live only under `--dart-define=ENABLE_BETA=true` is still live. Exact
auxiliary test, runtime, and external contexts also contribute to the global
retained union; an incomplete auxiliary context retains with a blocker rather
than proving absence.

**`noDynamicBlockers`** — no unresolved dynamic construct could reach this node.
This is the predicate that fails most often on real projects, and that is the
system working as intended.

**`notProtected`** — no protection rule covers it. Protection rules prevent
deletion of code that appears unused but is actually wired by frameworks at
runtime. See [Framework Protection Rules](#framework-protection-rules) below.

**`noPublicApiRisk`** — removing it cannot break an external consumer. Matters
for published packages, where an unreferenced public symbol is API surface
rather than dead code.

**`hasDeterministicInverse`** — the change can be undone exactly. If the tool
cannot describe how to reverse an edit, it does not get to apply it
automatically.

**`analysisCoverageComplete`** — every selected target and internal root
boundary was explicitly declared and is complete. A partial target matrix or
inferred roots cannot authorize a `SAFE` finding.

**`notRetained`** — the candidate is absent from every retained context, not
only every proven configured target. The evidence records both
`configuredProvenUnitPaths`/`configuredRetainedUnitPaths` per target and
`auxiliaryProvenUnitPaths`/`auxiliaryRetainedUnitPaths` per auxiliary context.
`globalUsageUnitPaths` is the configured-plus-auxiliary retained union. A
retained-only context, unknown condition, unresolved endpoint, or incomplete
environment makes `notRetained` false and hard-gates `SAFE`, `HIGH`, and any
apply action.

The public finding/report fields are intentionally narrower and distinct:
`retainedIn` lists the configured target names retaining the candidate, while
`auxiliaryRetainedIn` lists the exact `aux:*` context IDs retaining it.
`notRetained` is true only when both lists are empty. The `*UnitPaths` maps and
`globalUsageUnitPaths` above are internal pass-snapshot path evidence, not
aliases for the public finding fields; consumers must not collapse configured
and auxiliary retention or infer absence from a compatibility path projection.

**`actionSupported`** — the core has a specific, reversible implementation for
this adapter and node kind. Report metadata alone never grants mutation
authority.

`HIGH` is positive eligibility, not a fallback: all hard gates still hold and
exactly one allowlisted risk exists. The risks are
`external-consumers-not-scanned` and `broad-removal-scope`. Two risks produce
`REVIEW`. Package-internal apply accepts only the exact set
`{external-consumers-not-scanned}`.

Mode policy remains independent of classification: `application` applies only
SAFE, `package` applies nothing, and `package-internal` applies SAFE plus that
exact HIGH set. `PROTECTED` always wins.

An exact asset reference is an edge from its Dart caller, not an unconditional
root. The asset remains reachable only when that caller is reachable. Selected
analyzer/linter unused diagnostics are emitted as `PRN-DART-003`; because no
deterministic inverse editor exists yet, they carry unsupported-action risk and
remain `REVIEW` in every mode.

Duplicate groups are explicitly `REVIEW`, or `PROTECTED` when dependency-owned.
Choosing a canonical copy and rewriting every reference is not implemented, so
duplicates have no proposed action and cannot enter a transaction.

---

## Source bytes are not binary bytes

Findings report `sourceBytes`, the size of the source on disk. That number is
**not** the size change in the shipped app, and the tool never presents it as
one.

Deleting a 40 KB Dart file that was already tree-shaken out of the release build
saves zero shipped bytes. Deleting a 200 KB PNG saves close to 200 KB, minus
whatever the platform's own compression was doing. Assets and code behave
completely differently here.

Real binary impact requires building the release artifact and measuring it, with
all the constraints in [`flutter-facts.md`](flutter-facts.md) — release-only,
single ABI on Android, and builds that are not byte-reproducible, so a small
measured delta may be noise.

Conflating the two is the most common way cleanup tools overstate their value.
This one reports source bytes, labelled as source bytes.

---

## Framework Protection Rules

Flutter Pruner protects classes that appear unused in static analysis but are
actually instantiated or registered by frameworks at runtime. These classes
have no direct Dart references, so without protection they would incorrectly
appear as `SAFE` to delete.

### Built-in Protection Patterns

The Dart adapter protects common framework-wired patterns automatically:

**Dependency Injection:**
- `*Module` — GetIt/injectable modules registered via `@module` annotation
- `*Binding` — GetX dependency binding classes

**State Management:**
- `*Bloc`, `*bloc`, `*Cubit`, `*cubit` — BLoC pattern state managers (case-insensitive)
- `*Event` — BLoC pattern event classes
- `*State` (non-private) — BLoC/Cubit state classes
- `*Controller` — GetX/MVC controllers
- `*Provider` — Riverpod providers
- `*Notifier` — Riverpod StateNotifier classes
- `*ViewModel` — MVVM pattern view models
- `*Action` — Redux action classes
- `*Reducer` — Redux reducer functions
- `*Middleware` — Redux middleware

**Routing:**
- `*Route` — AutoRoute/GoRouter declarations
- `*Screen`, `*Page` — routing destination classes

**Clean Architecture:**
- `*UseCase` — use case implementations
- `*Repository`, `*RepositoryImpl` — repository pattern
- `*DataSource`, `*Datasource` — data layer boundaries

### When Protection Rules Fail

These patterns are **heuristics based on common naming conventions**. They will
not protect your code if you:

- Use different naming (e.g., `CartBlok` instead of `CartBloc`)
- Use synonyms (e.g., `*Status` instead of `*State`)
- Use non-English names (e.g., `*Servicio` instead of `*Service`)
- Follow different architectural patterns

**Always review findings before applying changes.** The `SAFE` tier means every
hard predicate passed within the declared analysis boundary; it is not a claim
that unmodeled runtime behavior cannot exist. Protection rules cover known
framework-wired patterns, while unknown wiring must remain a blocker or an
explicit project risk.

### References

- [BLoC Naming Conventions](https://bloclibrary.dev/naming-conventions/)
- [Flutter Simple State Management](https://docs.flutter.dev/data-and-backend/state-mgmt/simple)
- [Flutter MVVM Architecture Guide](https://docs.flutter.dev/app-architecture/guide)
- [GetIt Injectable](https://pub.dev/packages/injectable)
- [Riverpod Documentation](https://riverpod.dev/)
- [Flutter Redux package](https://pub.dev/packages/flutter_redux)

---

## Absence of evidence

One asymmetry deserves its own statement, because it is easy to get backwards
when a runtime-trace feature is added later:

> A runtime observation can prove that something **is** used.
> It can never prove that something **is not** used.

A trace showing `checkout_screen.dart` loading is proof of life. A trace *not*
showing it means the tester did not reach checkout. Runtime data may only ever
promote a finding to protected, never demote one to safe.

---

## In practice

Most findings on a mature codebase land in `HIGH` or `REVIEW`, not `SAFE`. That
is the intended outcome, not a limitation to engineer away.

`SAFE` means the tool found no failed hard predicate within the declared scope.
Keeping that set small makes it useful, but users should still review the plan
and keep version-control or filesystem recovery available for boundaries the
tool does not model.

The rule that follows, and the one reviewers enforce most strictly: **never
widen `SAFE` to make a test pass.** If a finding is genuinely safe, some
predicate is being computed wrongly — fix the computation. If it is not, it
belongs in a lower tier.

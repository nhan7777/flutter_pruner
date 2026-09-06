# V3 Roadmap — Root Document

**Trạng thái:** Draft — chưa được phê duyệt, chưa implement.
**Ngày:** 2026-09-05
**Phạm vi:** Safe l10n Removal V3.1 (Stage 1–5) + benchmark shared-view optimization.
**Nguyên tắc:** Fail closed, reversible, evidence-backed. Không over-engineering, không over-thinking.

---

## 1. Bối cảnh và phạm vi

Repo có hai cách đánh số khác nhau. Tài liệu này phân biệt rõ:

| Nhóm | Đánh số | Nội dung |
|---|---|---|
| Safe l10n Removal V3.1 | Stage 1–5 | Mutation readiness → promotion → API → generated families → concurrency |
| Benchmark optimization | Phase 1–5 | Shared-view cache cho l10n mutation-readiness benchmark |

**Roadmap chính là l10n Stage 1–5.** Shared-view chỉ là infrastructure phục vụ benchmark/validation, không phải product milestone.

---

## 2. Review Phase 1 (Stage 1 — internal mutation evidence)

### Điểm tốt
- Giữ Stage 1 internal-only, không mở public CLI/API sớm.
- Có manifest/oracle độc lập, candidate-level + family-level evidence.
- Kiểm tra generated output, restoration, unexpected writes, no-resolution verification.
- Fail-closed khi gặp malformed input, blocker, ambiguity, toolchain/config drift.

### Điểm cần lưu ý
- Exit gate rất nặng (367/367 keys, 3/3 family batches, 2,235 negatives, 370/370 restorations).
- Đây là evidence gate cho cohort hiện tại, **không** nên biến toàn bộ thành prerequisite cho mọi thay đổi l10n sau này.
- Evidence cũ: Smooth smoke từng dừng ở `inProgress`, zero completed results → không thể claim full natural-project success.

---

## 3. Review Phase 2 (Stage 2 — promotion/actionability)

### Điểm tốt
- `ActionReadinessIndex`, `MutationFootprint`, `ActionRiskScope`.
- Static readiness resolver, l10n action capability, family grouping.
- Apply integration, quarantine transaction primitives, test coverage.

### Vấn đề cần xử lý trước khi đi tiếp

**1. Working tree chưa compile/analyze sạch**
- `dart analyze` báo 22 issues, có lỗi compile thực sự:
  - `lib/src/analysis/analysis_snapshot.dart:26` — default value không constant.
  - `test/adapters/dart/analyzer_diagnostic_collector_test.dart:171` — contract cũ.
  - `test/cli/apply_command_test.dart:6350` — fake runner chưa cập nhật signature.
- Focused test run không load được nhiều test do lỗi compile.
- **Không bắt đầu Stage 3 trên branch chưa compile được.**

**2. Resolver quá đơn giản so với design contract**
- `L10nStaticReadinessResolver` chủ yếu group theo family + check blockers + lấy path từ node origin.
- Design yêu cầu: config ownership, template/locale ARB ownership, generated output ownership, stale output, config fingerprint, complete mutation footprint.
- `physicalPaths` từ `node.origin` không đủ để đảm bảo locale ARB + generated outputs vào atomic unit.

**3. Executor chạy generator trực tiếp trên project thật**
- `L10nMutationExecutor` gọi `Process.run('flutter', ['gen-l10n'], workingDirectory: project.root.path)`.
- Lệch với design promotion:
  - preflight phải chạy fresh trước live mutation;
  - candidate bytes phải generate ở staging;
  - transaction phải journal toàn bộ write set trước mutation;
  - live project chỉ install candidate bytes đã witness;
  - rollback không chạy `gen-l10n`;
  - verification kiểm tra complete write set.
- **Rủi ro lớn nhất của Phase 2: unjournaled generated write.**

**4. Quarantine entries chưa gắn vào transaction đầy đủ**
- `createCaseQuarantine()` đang gọi với `entries: const []`.
- Cần xác minh transaction biết chính xác bytes/mode của ARB + generated files cần restore.

**5. Verification bị mô phỏng như bước bên ngoài**
- `MutationApplied` trả về transaction ID, quarantine dir, affected files.
- Chưa thể hiện candidate hash, expected absent/present state, generated output set, policy/toolchain fingerprint.
- Khó phân biệt "đúng file sai nội dung", "file phát sinh ngoài danh sách", "generated output stale".

**6. Action capability có nguy cơ báo action quá sớm**
- Descriptor chọn `selectedKeys: {node.id}` nhưng mutation group theo family.
- Cần thống nhất mô hình: per-key selection + deterministic family expansion, hoặc family-level ngay từ đầu.
- Khuyến nghị: per-key selection, ghi rõ expansion + exact selected finding IDs trong transaction.

---

## 4. Review shared-view optimization

### Kết luận
- **Giữ** `SharedViewManager` ở individual-case benchmark path.
- **Không** mở rộng sang family batch (đã chứng minh 32.4% regression).
- **Không** thêm disk cache, incremental analysis, analyzer session pool ở thời điểm này.
- **Không** đưa shared-view option vào user-facing product config.
- Chỉ giữ validation harness nếu tạo evidence lặp lại được.

### Lý do loại disk cache / generic optimization
- Chưa có benchmark ổn định chứng minh cần nó.
- Analyzer state không có serialization contract ổn định.
- Corpus view path thay đổi mỗi lần.
- Cache invalidation theo repo/config/toolchain rất phức tạp.
- Không trực tiếp cải thiện safety của sản phẩm.

---

## 5. Điều chỉnh Stage 3–5

### Stage 3: Public adapter API — **Defer / thu hẹp**
- **Không** expose `ActionReadinessIndex` nguyên bản.
- **Không** expose `L10nMutationExecutor`, quarantine internals, mutation footprint implementation.
- Nếu có consumer cụ thể (IDE/CI/programmatic scan), tạo read-only typed result:
  - action support, reason/blocker, family identity, affected logical findings, bounded physical footprint summary, verification status.
- Public API chỉ phục vụ inspection/reporting trước, chưa cho phép arbitrary mutation.
- **Giá trị:** vừa phải. **Rủi ro:** lộ internal contracts, compatibility burden.

### Stage 4: Generated-code families khác — **Defer**
- Không mở rộng ngay sang JSON/GraphQL/codegen tổng quát.
- L10n có đặc tính riêng (ARB structured input, `gen-l10n` convention, family mapping kiểm soát được).
- Mỗi family mới cần evidence model riêng, không tạo "GenericGeneratedCodeMutationAdapter".
- Chọn tối đa một family thứ hai chỉ khi có workload thật + false-positive problem rõ ràng.
- Bắt buộc: independent oracle, exact mutation footprint, staging generator, generated output inspector, no-resolution verification, restoration tests, negative fixtures.
- Nếu chưa có nhu cầu thực tế → research spike ngắn, không productionize.

### Stage 5: Concurrent family execution — **Defer**
- L10n family có thể chia sẻ ARB dir, generated output dir, `.dart_tool`, analyzer caches, project mutation lock, Flutter resources.
- Chạy đồng thời gây lock contention, file collision, generator race, tăng peak RSS, khó deterministic, khó rollback.
- Giữ sequential là mặc định.
- Chỉ benchmark concurrency ở disposable corpus.
- Chỉ cho phép parallel khi physical footprints disjoint, generator state không shared, memory budget có margin.
- Dùng bounded worker count, không `Future.wait` toàn bộ.
- Nếu không chứng minh speedup sau khi tính lock/serialization cost → bỏ.

---

## 6. Roadmap đã điều chỉnh

1. **Stabilize Stage 2** — compile sạch, transaction ownership, fresh preflight, staging generation, install candidate bytes, complete write-set verification, rollback/recovery tests, natural-project evidence.
2. **Stage 2 acceptance review** — đối chiếu exit gate, tách rõ "focused tests passed" vs "natural-project corpus passed", không claim promotion-ready nếu thiếu smoke final status.
3. **Read-only API/reporting decision** — chỉ làm nếu có consumer, không expose internal index nguyên bản.
4. **L10n hardening & operational usability** — diagnostics, stable reason codes, dry-run/report clarity, runbook, release evidence.
5. **Generated family pilot** — chỉ một family cụ thể, independent design + evidence gate.
6. **Concurrency experiment** — cuối cùng, opt-in benchmark-only trước, production chỉ sau khi có evidence.

---

## 7. Plan chi tiết (chưa implement)

### Phase A: Establish baseline
1. Ghi nhận `git status`, HEAD, diff stat, phân loại file modified (production / tests / benchmark / unrelated).
2. Chạy `dart analyze`, focused l10n tests, apply/quarantine regression, full suite sau khi compile baseline phục hồi.
3. Lập bảng lỗi theo nhóm: API drift, compile error, assertion failure, environment skip, smoke incomplete.
4. Không chạy mutation trên project thật.

### Phase B: Restore compile & contract consistency
1. Sửa `AnalysisSnapshot` constructor/default contract.
2. Cập nhật fake process runners theo signature mới.
3. Cập nhật test fixtures diagnostic payload.
4. Chạy analyzer sau từng nhóm thay đổi.
5. Chạy lại l10n/apply/quarantine tests.
6. Xác nhận không thay đổi hành vi V2 review-only.

**Acceptance:** `dart analyze` không error; focused tests pass; warning còn lại phân loại pre-existing hoặc xử lý riêng.

### Phase C: Audit readiness boundary
1. Xác định nơi `L10nStaticReadinessResolver` inject vào `ProjectAnalyzer`.
2. Kiểm tra default resolver vẫn no-op với caller cũ.
3. Kiểm tra l10n readiness không tạo SAFE/HIGH ngoài policy.
4. Bổ sung kiểm tra: package mode, package-internal mode, unresolved/dynamic/generated blockers, malformed ARB, missing template, family mismatch, stale output, output path ambiguity.
5. Sửa footprint lấy path từ inventory/config ownership, không chỉ node origin.
6. Xác nhận một family tạo đúng một logical mutation unit; exact finding IDs xuất hiện đúng một lần.

**Acceptance:** readiness index chỉ chứa family pass toàn bộ static preconditions; mọi failure trả reason code ổn định; không có action descriptor mâu thuẫn family expansion.

### Phase D: Correct mutation architecture
1. Tách rõ: capture live baseline → preflight → materialize staging → mutate staging ARB → run canonical `gen-l10n` trong staging → inspect generated outputs → compute candidate hashes → create quarantine transaction → revalidate live hashes → install candidate bytes → rescan/verify → commit/rollback.
2. Không chạy `gen-l10n` trong project thật.
3. Journal tất cả: existing ARB, generated files, absent output paths (nếu contract yêu cầu), bytes, modes, finding IDs, policy/toolchain fingerprints.
4. Đảm bảo `createCaseQuarantine` nhận write entries thực tế, không `const []`.
5. Kiểm tra TOCTOU: live source thay đổi sau analysis, output thay đổi trước install, collision ở path coi là absent.
6. Rollback không chạy generator.
7. Xử lý failure ở từng transition: journal, install, verify, commit, recovery.

**Acceptance:** không unjournaled write; fail ở bất kỳ bước nào cũng restore byte/mode/status; candidate output chỉ commit khi complete family verification pass.

### Phase E: Focused verification
1. Unit tests: resolver, footprint.
2. Mutation tests: một key, nhiều key cùng family, nhiều locale, metadata companion, generated output replacement, generated output absent.
3. Failure injection trước/sau mỗi quarantine transition.
4. Apply tests: exact selection, stale snapshot, concurrent modification, generator failure trong staging, verifier rejection, commit failure.
5. Regression: V2 adapters vẫn REVIEW-only, scan không mutate, package mode không action, report schema không đổi ngoài field đã phê duyệt.

### Phase F: Natural-project evidence
1. Dùng SHA + manifest đã freeze.
2. Chạy focused production readiness trước.
3. Chạy từng candidate độc lập.
4. Chạy family batch riêng.
5. Theo dõi process liveness + output JSON đến trạng thái final, không coi file `inProgress` là success.
6. Ghi nhận: candidate/family counts, negative counts, blocker counts, mutation status, restoration status, toolchain identities, memory/time metrics.
7. Chạy lại subset để kiểm tra reproducibility.
8. Chỉ sau khi complete evidence đủ mới review promotion.

### Phase G: Shared-view benchmark validation
1. Giữ shared view chỉ cho individual-case mode.
2. So sánh baseline vs optimized trên cùng repo SHA, Flutter SDK, manifest, corpus root, environment.
3. So sánh semantic result, không diff raw JSON có timing fields.
4. Đo: cold load, warm case, total wall time, peak RSS, cleanup, lock wait.
5. Kiểm tra lifecycle khi provision fail, case fail, process cancel, dispose fail.
6. Không triển khai disk cache.
7. Không bật family-batch shared views.

**Acceptance:** correctness không đổi; có speedup thực tế ở individual mode; không tăng memory ngoài budget; cleanup deterministic; family mode không regression.

### Phase H: Quyết định Stage 3–5
- Stage 3: chỉ làm read-only API nếu có consumer đã xác định.
- Stage 4: chỉ chọn một generated family có demand + oracle.
- Stage 5: chỉ benchmark concurrency sau khi footprint disjoint + memory margin.
- Mỗi stage có go/no-go review riêng.
- Không gộp public API, generic abstraction, concurrency trong một release.

---

## 8. Khuyến nghị cuối

Ưu tiên đúng hiện tại **không phải Stage 3**. Ưu tiên là:

> **Đóng các khoảng cách giữa Phase 2 implementation và Stage 2 safety contract, sau đó chứng minh lại bằng compile-clean, focused tests và natural-project evidence.**

- Stage 3 → thu hẹp thành read-only API có điều kiện.
- Stage 4, Stage 5 → defer.
- Disk cache, generic generated-code framework → loại khỏi roadmap hiện tại vì chưa có evidence giải quyết bottleneck hoặc nhu cầu sản phẩm.

---

## 9. Trạng thái và quyết định cần phê duyệt

- [ ] Xác nhận roadmap này là root document cho V3.
- [ ] Xác nhận thứ tự: Stabilize Stage 2 → acceptance review → read-only API decision → hardening → generated pilot → concurrency experiment.
- [ ] Xác nhận Stage 3–5 defer/điều chỉnh như trên.
- [ ] Xác nhận không implement cho đến khi có lệnh rõ ràng.

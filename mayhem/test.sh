#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN htslib's own `make check` suite (built by build.sh's `make all`). Each step below is one line of
# the Makefile's `check` rule; every one compares outputs / asserts values (known-answer unit tests,
# golden-output diffs in the tst scripts, test.pl's per-case comparisons). Stdout of a step is kept
# so a failure is diagnosable; test.pl contributes its own per-case counts.
export REF_PATH=:
passed=0; failed=0
step() {
  local name="$1"; shift
  if "$@" >"/tmp/htslib-test.$$.log" 2>&1; then
    passed=$((passed+1)); echo "ok   $name"
  else
    failed=$((failed+1)); echo "FAIL $name"; tail -n 15 "/tmp/htslib-test.$$.log"
  fi
}
for t in test/hts_endian test/test_alloc test/test_expr test/test_kfunc test/test_khash test/test_ksort \
         test/test_kstring test/test_str2int test/test_time_funcs test/hfile test/test-regidx \
         test/test_hfile_libcurl; do
  [ -x "$t" ] || { echo "missing test runner $t (build.sh bug)" >&2; emit_ctrf "htslib-make-check" 0 1 0; exit 1; }
done
step test_nibbles       test/test_nibbles -v
step test_hts_endian    test/hts_endian
step test_alloc         test/test_alloc
step test_expr          test/test_expr
step test_kfunc         test/test_kfunc
step test_khash         test/test_khash
step test_ksort         test/test_ksort
step test_kstring       test/test_kstring
step test_str2int       test/test_str2int
step test_time_funcs    test/test_time_funcs
step fieldarith         test/fieldarith test/fieldarith.sam
step hfile              test/hfile
step test_bgzf          test/test_bgzf test/bgziptest.txt
step test-parse-reg     test/test-parse-reg -t test/colons.bam
step faidx              bash -c 'cd test/faidx && bash ./test-faidx.sh faidx.tst'
step sam_filter         bash -c 'cd test/sam_filter && bash ./filter.sh filter.tst'
step tabix              bash -c 'cd test/tabix && bash ./test-tabix.sh tabix.tst'
step mpileup            bash -c 'cd test/mpileup && bash ./test-pileup.sh mpileup.tst'
step fastq              bash -c 'cd test/fastq && bash ./test-fastq.sh'
step base_mods          bash -c 'cd test/base_mods && bash ./base-mods.sh base-mods.tst'
step tlen               bash -c 'cd test/tlen && bash ./tlen.sh tlen.tst'
step sam                test/sam test/ce.fa test/faidx/faidx.fa test/faidx/fastqs.fq
step test-regidx        test/test-regidx
step hfile_libcurl      test/test_hfile_libcurl

# test.pl: ~hundreds of golden-output comparisons; parse its own summary for the counts.
if (cd test && ./test.pl) >/tmp/htslib-testpl.$$.log 2>&1; then plrc=0; else plrc=$?; fi
pl_total=$(sed -n 's/^ *total *\.\. *//p' /tmp/htslib-testpl.$$.log | tail -n1)
pl_passed=$(sed -n 's/^ *passed *\.\. *//p' /tmp/htslib-testpl.$$.log | tail -n1)
pl_failed=$(sed -n 's/^ *failed *\.\. *//p' /tmp/htslib-testpl.$$.log | tail -n1)
if [ -n "$pl_total" ] && [ "$pl_total" -gt 0 ] 2>/dev/null; then
  passed=$((passed+pl_passed)); failed=$((failed+pl_failed))
  [ "$plrc" -eq 0 ] || [ "$pl_failed" -gt 0 ] || failed=$((failed+1))
  echo "test.pl: total=$pl_total passed=$pl_passed failed=$pl_failed"
else
  failed=$((failed+1)); echo "FAIL test.pl produced no summary"; tail -n 15 /tmp/htslib-testpl.$$.log
fi
[ "$failed" -eq 0 ] || grep -E "^(not ok|FAIL|# ?Failed)" /tmp/htslib-testpl.$$.log | head -n 20 || true

emit_ctrf "htslib-make-check" "$passed" "$failed" 0

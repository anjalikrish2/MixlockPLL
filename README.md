# MixLock-ADPLL

An ADPLL (All-Digital Phase-Locked Loop) whose output division ratio is gated by
a device-unique key derived from a Ring-Oscillator PUF, with TRLL-style logic
locking on the key path and a DisORC-style fault-detection layer added on top.
Three security mechanisms are combined:

- **RO-PUF identity** — an unclonable per-chip key derived from ring-oscillator
  timing variation, reconstructed through a fuzzy extractor with BCH-style
  error correction.
- **TRLL (Truth-table Rewriting Logic Locking) on the division ratio** — the
  ADPLL's feedback divider ratio `M` is XOR-gated by whether the reconstructed
  key matches an "active key," so a wrong key corrupts the output frequency
  instead of just failing a comparison.
- **DisORC-style fault detection** — a small bounds-checker (added this
  session) that flags tamper conditions on two independent signal domains:
  the digital divider path and the analog DCO frequency.

This is a simulation project (Verilog behavioral models, Vivado `xsim`), not a
taped-out or synthesized design. Claims below are scoped to what was actually
simulated.

## Canonical design file

**`design_fixed2.v`** is the single canonical source for this project (stated
in its own header comment). All modules — PUF, fuzzy extractor, TRLL, ADPLL,
DCO, and DisORC checker — live in this one file, in per-module sections
(`//==================== ModuleName.v ====================`).

Two earlier iteration snapshots existed and were retired when the project was
cleaned up to have a single unambiguous source of truth:

- `mixlockadpll_topdesign_.v` — the pre-fix original. **Deleted.** It was
  strictly superseded with no unique content once `design_fixed2.v` existed.
- `mixlockadpll_topdesign_fixed.v` — an intermediate working snapshot.
  **Kept as a backup** in `archive/`, not deleted, but not to be edited —
  `design_fixed2.v` carries every fix that snapshot had, plus more.

`design_fixed2.v` specifically carries two fixes/changes the snapshots don't:
1. A `puf_top` race-condition fix — `enrol_pulse`/`reco_pulse` are driven
   combinationally off `puf_valid` instead of a registered pulse one cycle
   later, which used to miss `fuzzy_extractor`'s `IDLE` transition.
2. A structural Ring-Oscillator PUF (`ro_puf`) replacing an earlier
   behavioral `sram_puf` that derived its "randomness" from a hashed
   `DEVICE_ID` parameter — a design smell, since `DEVICE_ID` is meant to be
   a per-chip identity value, not a source of cryptographic entropy.

There is no `.xpr`/project file anywhere in this directory tree, so file
identity is settled by convention (this header) and by testbenches
instantiating modules by name, not by file path.

## Module roles

| Module | Role |
|---|---|
| **`ro_puf`** | Structural Ring-Oscillator PUF: 128 matched oscillator pairs, each built from two structurally identical NAND-start/inverter rings. Per-cell NAND delay skew (the manufacturing-variation proxy) is drawn from `$random(SIM_SEED)` — explicitly *not* from `DEVICE_ID`, so two instances with different `SIM_SEED` are guaranteed independent simulated "chips," and two with the same `SIM_SEED` are guaranteed identical. Response bit = which ring in a pair counted more toggles in a fixed window. A few bit positions get flipped per sample via an internal LFSR to model near-tied-pair read noise. |
| **`fuzzy_extractor`** | Turns the PUF's noisy 128-bit reading into a stable 16-bit key (`K_puf`) plus public `helper_data`/`mask_data`. Enrollment (`S_ENROL`) stores the reference reading and a stability mask; reconstruction (`RECO`) applies a single-bit-correcting parity scheme (`bch_syndrome`) and a bit-stability mask (`STABLE_MASK`) before hashing to `K_puf`. |
| **`trll_locked_M`** | The TRLL key gate. `key_diff = active_key ^ K_puf` (zero only on a correct key); if nonzero, `M_locked` is forced to `(scramble % 6) + 2` — a value structurally guaranteed to land in `[2,7]` — instead of the programmed `M_prog`. A wrong key doesn't fail visibly; it makes the ADPLL lock to the wrong output frequency. |
| **`mixlock_adpll_top`** | Top-level integration: `puf_top` (PUF+extractor) → `disorc_key_manager` (sticky corruption latch on any `scan_enable` assertion, replacing the key with a dummy) → `trll_locked_M` → `ADPLL` (pfd + CONTROLLER + DCO + FREQ_DIV). Exposes `key_diff_obs`, `M_locked_obs`, `helper_data`, `corrupt_flag`, `OUT_CLK`, `LOCK` for testbench visibility. |
| **`disorc_checker`** *(added this session)* | Real-RTL tamper bounds checker, two independent sticky flags, deliberately not OR'd together: **`digital_fault`** — divider-side, flags `M_locked ∈ {0,1}` while `wrong_key` is asserted (structurally impossible through normal `trll_locked_M` logic, so it can only mean the divider input was tampered with directly). **`analog_fault`** — DCO-side, a real edge-counting frequency-window checker (`OUT_CLK`-domain free-running counter, toggle-synchronized into the `REF_CLK` domain) that flags `OUT_CLK` running outside `[171 MHz, 1550 MHz]`, i.e. somewhere none of the DCO's 129 valid control codes can legitimately produce. |

Supporting modules not itemized above: `puf_top` (wraps `ro_puf` + `fuzzy_extractor` with a settle/sample sequencer), `disorc_key_manager` (the sticky corrupt latch), `ADPLL`/`pfd`/`CONTROLLER`/`FREQ_DIV` (Anjali's original PLL, unchanged), `DCO` (jitter-enhanced behavioral oscillator model — explicitly documented in-file as simulation-only, not synthesizable), `JITTER_MEASURE` (cycle/period/accumulated jitter reporting).

## Parameters that matter

- **`SIM_SEED`** (`ro_puf`, `puf_top`, `mixlock_adpll_top`) — seeds `$random` for that instance's per-cell NAND delay skew. Two instances with different `SIM_SEED` are guaranteed distinct simulated "chips"; same `SIM_SEED` reproduces the same chip deterministically. Default `32'hC001_C0DE`.
- **`STABLE_MASK`** (`fuzzy_extractor`, localparam) — a fixed 128-bit constant clearing exactly the 18 bit positions found unstable in a 30-read stability analysis at `SIM_SEED=C001_C0DE` (positions 0, 8, 16, 24, 32, 40, 48, 56, 64, 68, 72, 80, 88, 96, 104, 112, 120, 126). `mask_data` is stored alongside `helper_data` at enrollment and applied to both operands of `bch_syndrome` during reconstruction, so `K_puf` derives only from the remaining 110 positions.
- **DisORC bounds** (`disorc_checker` parameters):
  - `M_locked` legal range: `M_prog` on a correct key, or `[2,7]` on a wrong key (from `trll_locked_M`'s `(scramble%6)+2`). `0` or `1` while `wrong_key` is asserted is the fault condition.
  - DCO frequency: `MIN_FREQ_HZ = 171_000_000`, `MAX_FREQ_HZ = 1_550_000_000` — taken directly from the measured tuning-range sweep (below), not a datasheet or invented spec.

## Test results actually obtained (this session)

All results below come from Verilog testbenches compiled/elaborated/run with
Xilinx `xvlog`/`xelab`/`xsim` (Vivado 2025.2) against `design_fixed2.v`. No
hardware, no synthesis, no timing closure — behavioral RTL simulation only.

### Reliability (bit error rate)

- `fuzzy_extractor`'s `RECO` state had a bug: it overwrote `helper_data` with
  the current noisy read and computed `bch_syndrome(noisy_word, noisy_word)`
  instead of referencing the real enrollment-time `helper_data` — a self-
  comparison that trivially "succeeded" every time. This was found unfixed
  (session had been lost mid-fix), confirmed against the file, and fixed:
  `RECO` now computes `bch_syndrome(noisy_word, helper_data)`.
- **After that fix, before bit-masking:** 30-read BER test (`tb_ber30.v`,
  `SIM_SEED=C001_C0DE`) — **30/30 reads mismatched**, **120/480 `K_puf` bits
  wrong = 25.0% BER**. Root cause: `bch_syndrome` can only correct a single
  bit error, but the noise model (`NOISE_BITS=3` flipped independently at
  both enrollment and each reconstruction) typically produces 4–6
  simultaneous differing bits per read — beyond the corrector's capacity.
- Per-bit stability analysis (`tb_bitstability.v`, same seed, 30 reads):
  **110/128 bit positions never flipped once**; 18 positions were noisy (15
  flipped 3–6/30 times from ordinary per-read noise landing there by chance;
  3 positions flipped ~25–30/30 times — these are the positions the
  *enrollment* sample itself happened to have noise on, so they mismatch
  almost every subsequent read).
- Masking those 18 positions out (`STABLE_MASK`) and **re-running the same
  30-read BER test: 0/30 mismatched, 0/480 bits wrong = 0.0% BER.**

### Uniqueness

- `tb_tc5_masked.v`: two independent `ro_puf`+`fuzzy_extractor` pairs
  (`SIM_SEED=1`, `SIM_SEED=2`), each enrolled once, masking in place.
  - `K_puf` (16-bit) inter-device Hamming distance: **8/16 bits = 50%**
    (PASS against the 37.5%/6-bit threshold used elsewhere in this project's
    testbenches).
  - Masked-stable 110-bit underlying value Hamming distance: **53/110 bits ≈
    48%.**
  - This is a purpose-built test, not `tbmixlock_vivado_.v`'s own TC5 — see
    Limitations below for why.

### Uniformity

- Not a dedicated test suite — computed from the three independent enrolled
  `helper_data` values captured incidentally across this session's runs
  (`SIM_SEED=C001_C0DE`, `SIM_SEED=1`, `SIM_SEED=2`): **196/384 bits set =
  51.04%** (individually 47.7%, 55.5%, 50.0%). **N=3 chips — far too small a
  sample to be a real uniformity characterization**; reported here only
  because it's real data already collected, not because it's statistically
  meaningful. A proper uniformity study needs on the order of 100s of
  independent enrollments.

### DCO characterization (`tb_dco_characterize.v`)

- Tuning range: **~170.9 MHz (code 0) to ~1550.4 MHz (code 128)** nominal,
  across all 129 valid thermometer control codes. This is the source of
  `disorc_checker`'s `[171 MHz, 1550 MHz]` bound.
- No inherent slew-rate limiting: a code change takes effect at the very
  next oscillator half-edge (no gradual ramp in this behavioral model), so
  arbitrary code jumps can shift frequency by >1 GHz within one sub-
  nanosecond half-period.
- Settling: near-instant (1–2 cycles) at low/mid-range codes; at high-speed
  codes a strict single-cycle 1%-tolerance check never sustains, because 1%
  of the period there (a few ps) is smaller than the modeled jitter floor
  (20 ps rms). This is why `disorc_checker`'s `analog_fault` measures over a
  multi-cycle window rather than a single sample.

### DisORC checker validation (`tb_disorc_checker.v`)

| Scenario | digital_fault | analog_fault | Result |
|---|---|---|---|
| 1. Correct key, real `mixlock_adpll_top` | 0 | 0 | PASS |
| 2. Wrong key (`scan_enable` tripped `disorc_key_manager`'s sticky latch; `M_locked` observed = 3, within `[2,7]`) | 0 | 0 | PASS — in-range `M_locked` correctly not flagged |
| 3. Forced `wrong_key=1` + `M_locked=0`, then `M_locked=1` (bypassing `trll_locked_M` entirely) | 1 | 0 | PASS — fires, `analog_fault` stays independent |
| 4a. Forced `OUT_CLK=50 MHz` (below floor) | 0 | 1 | PASS — fires, `digital_fault` stays independent |
| 4b. Forced `OUT_CLK≈3.33 GHz` (above ceiling) | 0 | 1 | PASS — fires, `digital_fault` stays independent |

## Scope and limitations (explicit)

- **DisORC here detects physical/fault-injection-style tampering, not
  brute-force key guessing.** `digital_fault` fires on an `M_locked` value
  that's structurally impossible through legitimate TRLL logic, and
  `analog_fault` fires on a DCO frequency outside its physically achievable
  range. Neither flag reacts to an attacker simply trying wrong keys through
  the normal `scan_enable`/key path — that's a correctness property of TRLL
  ("wrong key → wrong frequency," verified in Scenario 2 above), not
  something DisORC needs to additionally detect.
- **`STABLE_MASK` is a fixed constant derived from one 30-read simulation at
  one `SIM_SEED`, not a per-chip characterization.** In a real design, each
  physical chip's stable-bit positions would need to be determined per-chip
  (e.g. at manufacturing test) and stored per-chip, not hardcoded as a
  single mask shared by every simulated "device." Using one simulation's
  mask for all chips is a simplification specific to this project's
  simulation scope.
- **`K_puf` is 16 bits.** That's a small key for any production security
  use — it was sized for observability/simplicity in a teaching/capstone
  simulation (easy to print and compare in testbenches), not as a
  production key length recommendation.
- **`tbmixlock_vivado_.v`'s own TC5 test has a known, separately-flagged,
  unresolved gap**: it instantiates two `puf_top`s with different
  `DEVICE_ID`s expecting different `K_puf`s, but `DEVICE_ID` no longer
  drives PUF randomness (by design — see `ro_puf` above) and `SIM_SEED`
  isn't threaded through that testbench's two instances, so both currently
  default to the same seed. This was flagged to the project owner and
  deferred, not fixed. The uniqueness numbers reported above come from
  `tb_tc5_masked.v`, a testbench built this session that instantiates
  `ro_puf`/`fuzzy_extractor` directly with explicit distinct `SIM_SEED`
  values, sidestepping that gap — it does not fix or supersede
  `tbmixlock_vivado_.v`'s TC5.
- **Everything here is behavioral RTL simulation.** `DCO` is explicitly
  documented in-file as non-synthesizable (uses `$random`, real-number
  arithmetic, `$time`). No synthesis, timing closure, or hardware
  measurement has been done on any of this.
- **`disorc_checker`'s CDC (clock-domain-crossing) handling is a standard
  toggle-synchronizer pattern, not formally verified.** It's reasonable
  RTL style, but hasn't been run through a CDC linter or gate-level timing
  analysis.

## How to reproduce

Tooling used: Xilinx Vivado 2025.2 simulator (`xvlog`/`xelab`/`xsim`); no
`iverilog` was available in this environment. Adjust the tool path for your
install.

```powershell
$VIVADO = "C:\AMDDesignTools\2025.2\Vivado\bin"

# 1. Compile design + one testbench
& "$VIVADO\xvlog.bat" design_fixed2.v <testbench>.v --work work

# 2. Elaborate a simulation snapshot
& "$VIVADO\xelab.bat" <testbench_module_name> -s <snapshot_name>

# 3. Run it to completion
& "$VIVADO\xsim.bat" <snapshot_name> -runall
```

Per-testbench commands (each testbench's top module name matches its file
name minus `.v`):

| Testbench | What it checks | Command (steps 1–3 above, in order) |
|---|---|---|
| `tb_ber30.v` | 30-read bit error rate after enrollment | `xvlog design_fixed2.v tb_ber30.v --work work` → `xelab tb_ber30 -s ber30_sim` → `xsim ber30_sim -runall` |
| `tb_bitstability.v` | Per-bit flip-count stability analysis over 30 reads | `xvlog design_fixed2.v tb_bitstability.v --work work` → `xelab tb_bitstability -s bitstab_sim` → `xsim bitstab_sim -runall` |
| `tb_tc5_masked.v` | Inter-device uniqueness (`K_puf` and masked-stable Hamming distance) | `xvlog design_fixed2.v tb_tc5_masked.v --work work` → `xelab tb_tc5_masked -s tc5_sim` → `xsim tc5_sim -runall` |
| `tb_dco_characterize.v` | DCO tuning range, slew rate, settling time | `xvlog design_fixed2.v tb_dco_characterize.v --work work` → `xelab tb_dco_characterize -s dco_sim` → `xsim dco_sim -runall` |
| `tb_disorc_checker.v` | The four DisORC fault-detection scenarios above | `xvlog design_fixed2.v tb_disorc_checker.v --work work` → `xelab tb_disorc_checker -s chk_sim` → `xsim chk_sim -runall` |

Each run prints its results to stdout (`$display`) — no waveform viewing is
required to get the pass/fail numbers above, though `xsim` will also produce
a `.wdb` if you want to inspect waveforms interactively.

Pre-existing testbenches also in this directory (`tb_5cases.v`,
`tb_disorc_demo.v`, `tb_trll_demo.v`, `tbmixlock_scan_attack.v`,
`tbmixlock_vivado_.v`, `tbmixlock_wrongkey_attack_.v`) were not re-run this
session; no results for them are claimed here.

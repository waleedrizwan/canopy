# Light Meter for Dad: Tasks, Acceptance Criteria & Tests (v3)

**Goal:** a private iOS app, installed on Dad's iPhone only, that does everything he can do in Photone today, so he no longer needs to pay for it.

**What "done" means:** every item in the Photone inventory (T-1) has an equivalent, and readings agree with Photone on his phone within the agreement target (T7.1).

**Not goals:** App Store release, other phones, other users, other languages.

Conventions:
- **AC** = acceptance criteria. Every AC must be testable.
- **Test types**: `Unit` (pure logic), `Corpus` (replays recorded real frames, T7.1), `E2E` (XCUITest smoke), `Device` (Dad's phone), `Manual`.
- **(P)** = provisional number. It is a guess until the spike (T0.0) confirms or replaces it.
- **Reference** = Photone running on Dad's phone, unless a real PAR/lux meter is available.

## Fill in before starting

| Item | Value |
|---|---|
| Dad's iPhone model and iOS version | `____` |
| Camera he uses in Photone (front/back) | `____` |
| Diffuser he uses | `____` |
| Lights he actually owns | `____` |
| His Photone purchase (subscription or lifetime; which unlocks) | `____` |
| Does he keep a reef tank? | `____` |

If his purchase is a **subscription**, all reference captures (T-1, T7.1) must be finished before it lapses. If it is a **lifetime** unlock, Photone stays available as a permanent reference.

## Measurement pipeline (single source of truth)

| Step | Formula | Notes |
|---|---|---|
| 1. Sensor signal | `S` = exposure-normalised whole-frame signal | Exact definition (channels, weights, linearisation) is fixed by T0.0 and never changed afterwards without redoing calibration. |
| 2. Lux | `lux = S × kBase(camera, diffuser)` | `kBase` is fitted so lux matches the reference. One value per camera + diffuser combination. |
| 3. PPFD | `ppfd = lux × fLight(lightType) × kUser(camera, diffuser, lightType)` | `fLight` in µmol·m⁻²·s⁻¹ per lux. `kUser` is the user's own calibration, 1.0 if none. |
| 4. DLI | `dli = ppfd × hours × 0.0036` | mol·m⁻²·d⁻¹ |

- `kBase` absorbs phone and diffuser error, so it carries across every light type.
- `kUser` changes PPFD and DLI, not lux. The lux↔PPFD converter (T5.1) uses `fLight × kUser` for the selected light type, so the converter and the measure screen always agree.

---

## -1. Reference capture

### T-1 Photone inventory
The feature list in sections 1–5 was written from the outside. "Everything" has to be checked against the real app on his account.

**AC**
- [ ] Screenshot every Photone screen, setting and menu on Dad's phone; store in `docs/photone-inventory/`.
- [ ] Checklist of every feature, light type, diffuser option, unit and setting, each mapped to a task in this spec or marked "add" / "skip (Dad doesn't want it)".
- [ ] Dad reviews the checklist and marks what he actually uses; those items are built first.
- [ ] Reef/underwater behaviour recorded exactly: what modes exist, what the app tells the user to do, what changes on screen.
- [ ] Nothing is copied from Photone except observed behaviour and readings: no icons, images, text or artwork.

**Tests**
- Manual: checklist has no unmapped rows.

---

## 0. Foundations

### T0.0 Feasibility spike (throwaway code, do first)
Decide how to get a trustworthy signal from the camera on Dad's phone model.

**AC**
- [ ] Two methods prototyped and compared:
  - **A. Locked exposure + pixels:** fixed exposure steps, signal from pixel values normalised by exposure time and ISO.
  - **B. Auto-exposure as the meter:** let the system expose, derive the signal from the reported exposure time, ISO and exposure offset.
- [ ] For each: readings at 5 light levels from dim indoor to full sun, with Dad's diffuser, compared with Photone's lux. Record error and repeatability.
- [ ] Linearity checked: halving the light (e.g., doubling distance from a point-like lamp, or a neutral-density filter) roughly halves the signal.
- [ ] Flicker checked under a mains-powered lamp (see T0.1).
- [ ] Written decision: chosen method, exact definition of `S`, and replacement values for every **(P)** number in this spec.
- [ ] No-go outcome is allowed: if neither method tracks Photone within 15% (P), stop and reassess.

### T0.1 Camera capture pipeline
Produces `S` using the method chosen in T0.0.

**AC**
- [ ] Single physical lens (`builtInWideAngleCamera`); never a virtual multi-lens device.
- [ ] Front or back camera selectable; default is the one Dad uses.
- [ ] HDR, low-light boost and video stabilisation disabled.
- [ ] White balance set to **fixed gains** (constant values in config), not "locked at whatever auto chose".
- [ ] Signal uses the whole frame minus a 10% border (P), not a small centre region. Different rows are exposed at different moments, which averages out flicker.
- [ ] Frame rate is not a divisor of 100 or 120 (e.g., 27 fps (P)), so successive frames don't all land on the same phase of mains flicker.
- [ ] Each reading averages ≥ 10 frames (P).
- [ ] If method A: exposure steps have a stated spacing (1 stop (P)) and hysteresis so the app doesn't flip between two steps; frames whose metadata doesn't match the requested exposure are discarded; the last good value is shown (marked "adjusting") while switching.
- [ ] "Too bright" / "too dark" are reported only at the ends of the exposure range, with thresholds from T0.0.
- [ ] Interruptions (backgrounding, calls, camera taken by another app) pause measuring and resume cleanly; a stale value is never shown as live.
- [ ] Capture session stops when the measure screen is not visible.
- [ ] Camera permission denial shows an explanation screen with a Settings link.

**Tests**
- Unit: frame averaging, border cropping, exposure normalisation match hand-calculated values.
- Unit: step selection with hysteresis — a signal sitting on a boundary doesn't oscillate.
- Unit: frames with mismatched exposure metadata are dropped.
- Integration: constant mocked frames → variance < 0.5%.
- Device: steady DC-powered light (or daylight on a clear day) for 60 s; drift < 2% (P).
- Device: under a mains lamp, reading is the same within 2% (P) at two different frame rates.
- Device: same light at two adjacent exposure steps; `S` differs < 2% (P).
- Manual: deny camera permission → explanation screen, Settings link works.

### T0.2 Base constants
One phone, so no model lookup.

**AC**
- [ ] `kBase` stored per (camera, diffuser) in a versioned config file, each with the capture date and how it was fitted.
- [ ] Phone case and screen protector state at capture time recorded; onboarding tells Dad to measure the same way (a protector over the front camera changes the reading).
- [ ] If the app ever runs on a different phone model it shows "not calibrated for this phone".

**Tests**
- Unit: config loads; every (camera, diffuser) pair offered in the UI has a `kBase`.

---

## 1. Light Measurement

### T1.1 Lux reading
**AC**
- [ ] Lux shown in real time, updating at ≥ 2 Hz.
- [ ] Range covers dim indoor light to full sun with the diffuser on; exact limits from T0.0.
- [ ] Integer lux with thousands separators.
- [ ] Hold/freeze button captures the current value.
- [ ] **Level indicator:** uses the motion sensor; shows a warning when the phone is tilted more than 10° (P) from the measuring orientation.
- [ ] Without a diffuser, an "estimate only" label is shown (if Photone offers a no-diffuser mode; otherwise omit the mode).

**Tests**
- Unit: `S` → lux with known `kBase`.
- Unit: formatting, 12345.6 → "12,346 lx" (locale pinned in the test).
- Unit: tilt 5° → no warning; tilt 15° → warning.
- Corpus: recorded captures reproduce the reference lux within the agreement target.
- Manual: freeze stops updates; unfreeze resumes.

### T1.2 PPFD reading
**AC**
- [ ] `ppfd` per pipeline step 3. Integer display (one decimal below 10).
- [ ] If no light type is selected, the same default as Photone is used and labelled as default.

**Tests**
- Unit: table-driven conversion for every light type.
- Corpus: recorded captures reproduce reference PPFD for each light Dad owns.

### T1.3 DLI reading
**AC**
- [ ] Photoperiod 0–24 h in 0.5 h steps; default 12 h (or Photone's default per inventory).
- [ ] DLI to one decimal; updates live with PPFD or photoperiod.
- [ ] Out-of-range input rejected with an inline error.
- [ ] Under Sunlight, a note explains the DLI assumes this intensity all day.

**Tests**
- Unit: PPFD 500, 12 h → 21.6. PPFD 0 → 0. PPFD 500, 24 h → 43.2.
- Unit: −1 or 25 h → validation error.

### T1.4 Diffuser support
**AC**
- [ ] Diffuser options match the Photone inventory (none / recommended types / custom).
- [ ] Each option selects its own `kBase`.
- [ ] Custom diffuser: derived by measuring the same steady light with a known diffuser and then the new one; ratio stored as a new `kBase`.
- [ ] Measure screen shows the active diffuser.
- [ ] Short guide on placing the diffuser.

**Tests**
- Unit: switching diffuser switches `kBase`.
- Unit: custom diffuser ratio maths; zero or non-finite ratio rejected.
- Device: with Dad's diffuser, lux agrees with the reference within the agreement target.

---

## 2. Accuracy & Correction

### T2.1 Light types
**AC**
- [ ] Light-type list matches the Photone inventory exactly (names and grouping).
- [ ] Each `fLight` has a recorded origin, one of:
  - **Measured:** fitted from a capture under a real lamp of that type that Dad owns (`fLight = reference PPFD / lux`).
  - **Ratio-derived:** under one steady light, switch the reference app between light types and record how its PPFD changes; apply the same ratio. Valid only if the ratio is the same under two different test lights (if it isn't, the reference isn't using a simple factor and this method is dropped for that type).
  - **Published:** from a cited conversion table.
- [ ] Types that are not **Measured** show a small "unverified" tag in the picker.
- [ ] Selected light type persists between sessions; measure screen always shows it.

**Tests**
- Unit: every type has a factor > 0 and an origin field.
- Unit: unverified tag appears for non-measured types.
- Integration: select HPS, reload store from disk, HPS still selected.
- Regression: factor table snapshot test.

### T2.2 User calibration
**AC**
- [ ] User enters a reference PPFD while measuring the same light; app stores `kUser = reference / uncalibrated ppfd`, keyed by camera + diffuser + light type.
- [ ] Capture allowed only when the reading is stable (< 2% variation over 2 s (P)) and non-zero.
- [ ] View, reset and delete calibrations.
- [ ] Multiplier outside 0.5–2.0: warning with the option to re-measure or confirm. Outside 0.1–10: rejected.

**Tests**
- Unit: reads 400, reference 440 → `kUser` 1.10; next 400 shows 440; lux unchanged.
- Unit: 2.5 → warning, saved only on confirm; 12 → rejected; reading 0 → refused.
- Unit: keying — HPS calibration doesn't affect LED; front doesn't affect back.
- Unit: converter (T5.1) uses the calibrated factor for the calibrated light type.
- Integration: calibrate → reload store → still applied.

### T2.3 Aquarium / reef mode
Built to match the inventory (T-1). If Dad has no tank, build it last.

**AC**
- [ ] Modes, light types and on-screen guidance match what Photone offers.
- [ ] If Photone has an underwater mode: its correction is captured by ratio (same light, mode on vs off in the reference) and applied the same way; the app shows the same handling instructions (waterproof housing, etc.).
- [ ] Reef mode keeps its own light-type selection, separate from plant mode.
- [ ] Coral PAR guidance ranges (low/medium/high), each with a cited source.
- [ ] Marked "unverified" in the UI until checked against the reference on a real tank.

**Tests**
- Unit: reef mode lists reef light types only; toggling back restores the plant light type.
- Unit: underwater correction applied only when that mode is on.
- Manual (if a tank is available): compare with the reference in each mode.

---

## 3. Mapping & Visualization

### T3.1 Heatmap
**AC**
- [ ] Grid rows and columns set independently, 2–10 each.
- [ ] App guides cell by cell; each cell can be measured, re-measured or skipped.
- [ ] A cell can't be recorded while the reading is "too bright", "too dark", "adjusting" or the tilt warning is showing.
- [ ] In-progress heatmap survives backgrounding and relaunch.
- [ ] Colour map with legend (PPFD or DLI) and min / max / average / uniformity (min ÷ average, as %).
- [ ] Average 0 or no data → stats show "—". All cells equal → single colour, uniformity 100%.
- [ ] Heatmaps saved to the log and shareable as an image.

**Tests**
- Unit: [100, 200, 300] → min 100, avg 200, max 300, uniformity 50%.
- Unit: all zero, all skipped, all equal cases.
- Unit: skipped cells excluded from stats.
- Unit: recording refused in each blocked state.
- E2E: 3×3 walkthrough with fixture readings, one cell skipped → 8 cells + 1 "no data".
- Manual: exported image opens in Photos.

---

## 4. Data & Tracking

### T4.1 Logging
**AC**
- [ ] Each entry stores: timestamp, lux, PPFD, DLI, photoperiod, light type, diffuser, camera, `kBase`, `fLight`, `kUser`, raw `S`, optional label and note.
- [ ] Entries are snapshots; later calibration changes don't rewrite them.
- [ ] List newest first; tap for details; swipe to delete with undo.
- [ ] Filter by label or light type.
- [ ] Data survives app updates and reinstalls over the top.

**Tests**
- Unit: entry has all fields; changing calibration leaves saved entries unchanged.
- Integration: 100 entries listed in date-descending order; delete and undo.
- Migration: store from the previous schema version loads intact.

### T4.2 CSV export
**AC**
- [ ] Export all or filtered logs.
- [ ] Header: `timestamp,lux,ppfd_umol_m2_s,dli_mol_m2_d,photoperiod_h,light_type,diffuser,camera,calibration_multiplier,label,note`.
- [ ] ISO 8601 timestamps with offset; `.` decimals, no grouping, 2 decimal places.
- [ ] RFC 4180 quoting; CRLF line endings; UTF-8.
- [ ] Opens in the share sheet.
- [ ] Doubles as the backup: Dad's data can always be taken out of the app.

**Tests**
- Unit: output matches a golden file.
- Unit: note with commas, quotes and a line break is one correctly quoted field.
- Manual: file opens in Numbers and Excel.

---

## 5. Planning Tools

### T5.1 Calculators
**AC**
- [ ] Required hours = `dli / (ppfd × 0.0036)`.
- [ ] Required PPFD = `dli / (hours × 0.0036)`.
- [ ] Lux ↔ PPFD for a chosen light type, using `fLight × kUser`.
- [ ] Negative, empty, zero-divisor or > 24 h input → inline error, never NaN/infinity.
- [ ] Results over 24 h → "not reachable with this light".
- [ ] Any other calculators found in the inventory are added here.

**Tests**
- Unit: DLI 20, PPFD 400 → 13.9 h. DLI 20, 16 h → 347.2. DLI 40, PPFD 200 → "not reachable".
- Unit: PPFD 0 or hours 0 → validation error.

### T5.2 Guides
**AC**
- [ ] Measuring guide (position, diffuser, level, distance, shadows), written in our own words.
- [ ] Target PPFD/DLI table by plant category, each range with a cited source.
- [ ] Bundled in the app; no network calls.

**Tests**
- E2E: each guide opens and is not empty.
- Content review: every range has a source in repo docs.

---

## 6. Out of Scope

Only things Photone doesn't have either (confirm each against the inventory; anything Photone does have moves in scope):
- Plant database
- Multiple grow rooms/spaces
- Home-screen widgets
- Notifications/reminders
- Cloud sync

Also out: App Store submission, other phone models, localisation, in-app purchases, analytics.

---

## 7. Cross-Cutting

### T7.1 Reference capture session and agreement target
Replaces the benchmark suite. The two apps can't use the camera at once, so readings are taken one after the other from a fixed position.

**AC**
- [ ] Phone on a stand or tripod, steady artificial light, order Photone → our app → Photone again; discard the set if the two Photone readings differ by more than 2%.
- [ ] Covered: each light Dad owns × 3 distances × the camera and diffuser he uses. Other diffusers and the other camera: one distance each.
- [ ] Our app saves the raw frames and exposure metadata for every capture, alongside the Photone lux and PPFD. This is the **corpus**, committed to the repo (or stored with Git LFS).
- [ ] Corpus tests replay every capture through the pipeline and compare with the recorded reference.
- [ ] **Agreement target:** median absolute difference ≤ 5% (P), no single capture over 10% (P), for the lights Dad owns.
- [ ] Session finished before any Photone subscription lapses.
- [ ] If a real PAR meter can be borrowed, add its readings as a second reference column; not required.

**Tests**
- Corpus: all captures within target; runs in `make check` without a device or simulator.
- Manual: Dad uses both apps side by side for a week and reports any reading that looks off.

### T7.2 Performance
**AC**
- [ ] First reading within 2 s (P) of opening the measure screen.
- [ ] 10 minutes of measuring under his actual grow light: no thermal shutdown warning; if `thermalState` reaches `.serious`, the app shows "phone is hot, reading paused" instead of continuing.
- [ ] Battery drop for that 10 minutes recorded; no fixed limit.

**Tests**
- Device: 10-minute run under the grow light with thermal and battery log.
- Unit: thermal state `.serious` → paused state.

### T7.3 Usability
**AC**
- [ ] Reading values stay fully visible at the text size Dad uses on his phone, and at the two sizes above it.
- [ ] States are shown in words, not colour alone.
- [ ] Heatmap uses a perceptually uniform palette (e.g., viridis) with values in cells.

**Tests**
- E2E: measure screen at a large text size, reading not clipped.
- Manual: Dad can read every screen without help.

### T7.4 Install and upkeep
**AC**
- [ ] Installed through the paid developer account (direct install or TestFlight).
- [ ] The expiry date of the install (provisioning profile or TestFlight build) is written in the README, with a calendar reminder two weeks before.
- [ ] Updating the app keeps logs, calibrations and settings.

**Tests**
- Manual: install build N, add data, install build N+1 over it, data intact.

---

## 8. Code Quality (sized for one developer, one user)

**AC**
- [ ] Measurement maths (pipeline, calculators, heatmap stats, CSV) in a pure Swift package with no SwiftUI or AVFoundation imports; tested with `swift test`, no simulator needed.
- [ ] Typed units (`Lux`, `PPFD`, `DLI`), not raw `Double`.
- [ ] Warnings as errors; Swift 6 language mode.
- [ ] swift-format and SwiftLint (default rules plus `force_unwrapping`), both in a pre-commit hook.
- [ ] `CameraSource` protocol with real and fixture implementations; fixture replays corpus frames plus exposure metadata.
- [ ] `make check` runs: format check, lint, build, unit tests, corpus tests.
- [ ] E2E smoke suite, run on demand on one small simulator before giving Dad a new build:

| ID | Flow | Expected |
|---|---|---|
| S-01 | Launch → measure screen | Lux/PPFD/DLI shown from fixture |
| S-02 | Select light type → relaunch | Selection kept; PPFD reflects it |
| S-03 | Saturated and dark fixtures | "Too bright" / "too dark", no number |
| S-04 | Calibrate 400 → 440 | PPFD 440, lux unchanged |
| S-05 | Heatmap 3×3, skip one | 8 cells + "no data"; stats exclude it |
| S-06 | Save 3 readings → log → delete one → relaunch | 2 entries, newest first |
| S-07 | Export CSV | File produced, share sheet presented |
| S-08 | Calculator DLI 20, PPFD 400 | 13.9 h |

- [ ] Optional: GitHub Actions running `make check` on push. Not required.

Deliberately dropped from v2: dead-code scan, coverage gates, `swiftlint analyze`, String Catalog check, privacy manifest, secrets scan, commit-message rules, two-simulator CI, PR review rules.

---

## Build Order

1. **Fill in the table** at the top (phone, lights, diffuser, purchase type).
2. **T-1 inventory** on Dad's phone.
3. **T0.0 spike** — two methods, pick one. Go/no-go.
4. T0.1 capture, `make check` skeleton (section 8).
5. **T7.1 capture session** — build the corpus and fit `kBase` and `fLight`. Do this before anything else if the subscription is about to renew.
6. T1.1 → T1.2 → T2.1 → T1.3 (lux, PPFD, DLI) with corpus tests passing.
7. T1.4, T2.2 (diffusers, user calibration).
8. **First install on Dad's phone**; side-by-side week (T7.1 manual test).
9. Features Dad marked as used in the inventory, in his priority order, from: T4.1/T4.2 logging and export, T3.1 heatmap, T5.1 calculators.
10. The rest of the inventory: T5.2 guides, T2.3 reef, anything added by T-1.
11. T7.2–T7.4 polish; he cancels Photone only after this.

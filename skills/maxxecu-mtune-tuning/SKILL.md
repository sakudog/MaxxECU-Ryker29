---
name: maxxecu-mtune-tuning
description: >-
  Analyze MaxxECU MTune datalogs (.MaxxECU-Zip-log, .MaxxECU-log, .maxxlog, .csv)
  and calibration files (.MaxxECU-save) to generate steady-state VE table error
  histograms, damped MTune copy-paste VE corrections, WOT pull diagnostics,
  dual-bank wideband balance, Flex Fuel checks, knock/ignition analysis, boost
  control review, accel enrichment evaluation, idle stability, and safety cut audits.
  Use whenever the user uploads or references a MaxxECU / MTune log or tune file
  or asks for MaxxECU tuning recommendations.
---

# MaxxECU MTune Log & Calibration Tuning Skill

This skill parses MaxxECU MTune datalogs (`.MaxxECU-Zip-log`, `.MaxxECU-log`, `.maxxlog`, `.csv`) and XML tune files (`.MaxxECU-save`) directly using the bundled PowerShell/C# analyzer—no Python install or manual `.zip` renaming required.

For detailed MaxxECU fuel model formulas, MTune axis IDs, channel mappings, and tuning targets, read [mtune_tuning_reference.md](./references/mtune_tuning_reference.md) as needed.

## Workspace Directory Convention (ALWAYS USE FOR EVERY BUILD)
Keep every vehicle's project folder clean and inspectable by organizing files into three subfolders under the build's project directory (e.g., `<project>\`):
- **`\LOGS`** — All incoming and archived MTune datalogs (`.MaxxECU-Zip-log`, `.MaxxECU-log`, `.maxxlog`, `.csv`).
- **`\TUNES`** — All `.MaxxECU-save` calibration files (baseline deposits, generated revisions, and final/Golden tunes).
- **`\ARTIFACTS`** — Any requested outputs that are not an MTune tune file (telemetry graphs `.png`, TSV/CSV table exports, Google Sheets batch `.json`, and markdown/HTML reports).

When creating a new vehicle workspace (or mirroring a build folder to Google Drive), always initialize `LOGS`, `TUNES`, and `ARTIFACTS` and save outputs into their matching subfolder.

## Workflow

### Step 0: Vehicle Configuration Intake & MTune Cross-Check (ALWAYS DO FIRST ON A NEW BUILD)
This skill is **platform-agnostic** (works equally well for a single-turbo 2JZ-GTE Supra, an LS-swapped OBS truck, a K24, a BMW S54/N54, etc.). Before giving tuning recommendations on a new build, gather (or confirm) the 6 physical configuration blocks from [VEHICLE_PROFILE.md](../../../VEHICLE_PROFILE.md) and **cross-check every detectable item directly against the user's `.MaxxECU-save`**:

1. **Engine Configuration:** Cylinders, displacement, NA vs. turbo/supercharged (target boost & WG spring), bore/stroke, compression ratio, cam specs, DBW E-Throttle vs. cable TB + IACV, redline.
   - *Cross-check in `.MaxxECU-save`:* `Engine Cylcount`, `Engine Volume`, `KnockCtrl Diameter` (bore in mm), `RevLimit`, VE/Ign Load axis ceiling (`~101 kPa` NA vs. `200–400 kPa` boosted), `DBW` vs. stepper/PWM IAC settings.
2. **Fuel System Configuration:** Pump gas octane vs. E85 / Flex Fuel, injector model & rated flow @ 3 bar, fuel pump(s), base rail pressure & 1:1 manifold-referenced FPR vs. fixed returnless, fuel pressure sensor installed?, single vs. dual wideband.
   - *Cross-check in `.MaxxECU-save`:* `Fuel Injflow`, `Fuel Injdeadtime`, `Fuel pressureadj`, `Multiply Lambda = 1`, `DualBankO2`, Flex Fuel / Ethanol sensor & blend tables.
3. **Exhaust System Configuration:** Turbo manifold/downpipe vs. headers, **catalytic converters vs. catless**, wideband sensor placement (pre-cat collector / post-turbo downpipe / post-cat).
   - *Why it matters:* Cat-equipped builds MUST avoid aggressive ignition-only misfire cuts (shiftcut, rev limiter, overrun pops) that dump raw unburned fuel into hot cats — favor **ignition retard** or clean **fuel+ign cuts** instead!
4. **Transmission Configuration:** Manual (clutch type) vs. CAN Automatic (Dodge/BMW ZF 8HP70/8HP90, DCT, DSG) vs. hydraulic auto (4L80E, TH400) + torque converter stall RPM if automatic.
   - *Cross-check in `.MaxxECU-save`:* `Dodge 8HP TCU type`, `DCT`/`DSG`, or `TransCtrl` settings. **Adapt the audit to the actual transmission:** run 8HP shift/torque/TCC checks ONLY on 8HP builds; on manual turbo cars, focus on clutch-in anti-stall/coasting, flat-foot/shift-cut, and boost-by-gear!
5. **Rear Gear Ratio, Tire Diameter & Vehicle Weight:** Informs gear-drop WOT shift RPM math, low-RPM lugging zones, and traction / boost-by-gear limits.
6. **Cooling Fan Control Type (`PWM Soft-Start` vs. `On/Off Relay`) & Electrical Loads:**
   - *Cross-check in `.MaxxECU-save`:* `Radiatorfan PWM` vs. GPO on/off fan outputs, `Fan Ctrl Temp / Temp2`, `RadiatorFan Delay`, `Idle RadFan Duty Up`, `Idle AC Duty Up`.
   - *Adapt strategy immediately:*
     - **Relay-switched high-draw fans:** Expect transient voltage dip on relay close; protect `0 mph` idle with empirically sized `Idle RadFan Duty Up` (~2.5–3× steady-state Fan ON delta), keep `RadiatorFan Delay` at `0.5 s` (NOT `10 s` — `RadiatorFan Delay` delays only the relay, NOT `Idle RadFan Duty Up`!), and scale rolling fan duty down via a smooth 10-pt `IdleCtrl User Duty Adjust` curve (`VSS × Fan`). Once the rolling fan cancel curve is active, lowering `Idle closedloop Disable Spd` to `~4.8 km/h (3 mph)` eliminates coasting/braking near-stalls without rolling self-drive.
     - **PWM soft-start fans:** No relay inrush surge — `Idle RadFan Duty Up` only needs a modest steady-state bump (`~10–15%`) and rarely causes hot-start flares or rolling self-drive.

If the user hasn't provided all 6 blocks yet, auto-extract everything visible from their `.MaxxECU-save` first, flag any detected mismatches, and ask concisely for only the missing physical details (e.g., cats vs. catless, PWM vs. relay fans, cam/octane/rear gear).

### Step 1: Parse the Log and/or Calibration File
Run the bundled analyzer on the uploaded or referenced file:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.gemini\config\plugins\maxxecu-tuning\skills\maxxecu-mtune-tuning\scripts\parse_maxxecu.ps1" -Path "<absolute-path-to-file>"
```

If the user provides a standalone log (`.MaxxECU-log`, `.maxxlog`, `.csv`) **and** a separate `.MaxxECU-save` tune file, pass both so the VE error histogram aligns to the tune's exact RPM × Load breakpoints:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.gemini\config\plugins\maxxecu-tuning\skills\maxxecu-mtune-tuning\scripts\parse_maxxecu.ps1" -Path "<path-to-log>" -TunePath "<path-to-tune.MaxxECU-save>"
```

**Key options:**
- `-Path "<file>"` — Supports `.MaxxECU-Zip-log` / `.MaxxECU-Zip.log` (auto-extracts both log & `.MaxxECU-save`), `.MaxxECU-log` / `.maxxlog`, `.csv`, or standalone `.MaxxECU-save`.
- `-TunePath "<file.MaxxECU-save>"` — Optional companion calibration file when `-Path` is a standalone log.
- `-MinClt 70` — Minimum coolant temperature (°C) for steady-state VE error binning (default `70`; auto-converts if logged in °F).
- `-MaxDTps 3.0` — Max throttle change per sample (`%`) to exclude tip-in/tip-out transients (default `3.0`).
- `-MaxDMap 8.0` — Max MAP change per sample (`kPa`) to exclude rapid spool/load transients (default `8.0`).
- `-MinHits 5` — Minimum steady-state samples per VE cell before recommending an adjustment (default `5`).
- `-ApplyFactor 0.65` — Damping factor applied to VE corrections where `|error| > 5%` to avoid overshoot (default `0.65`; full correction or damped as appropriate).
- `-LambdaOffsetMs 0` — Optional exhaust wideband transport-delay shift in ms (e.g., `150`–`250` at low RPM/idle, `80`–`120` during pulls).
- `-DumpTables` — Print full `VE Table 1`, `Lambda Table 1`, and `IgnAdv Table 1` from the `.MaxxECU-save`.
- `-ExportVeTable "<path.tsv>"` — Write a tab-delimited updated VE table ready to paste into MTune (check Y-axis orientation note before pasting).
- `-ExportCsv "<path.csv>"` — Export normalized log channels + computed `TotalVeErrorPct` and `IDC_Pct` for charting or revision diffs.

### Step 2: Verify File Type, Channel Mapping & Units
1. Confirm whether the input included a **calibration (`.MaxxECU-save`)**, a **datalog**, or **both** (e.g., `.MaxxECU-Zip-log`).
   - If the user only uploaded a `.MaxxECU-save` calibration file, perform a thorough **Calibration Audit** (hardware/engine/injector config, VE/Lambda/Ign table shape & clipping, IAT/CLT/Accel/Idle/Closed-Loop Lambda settings, safety protections) and explain what log file (`.MaxxECU-Zip-log` or MTune CSV export) to capture next so you can generate log-verified VE/spark/boost adjustments.
   - If a native `.MaxxECU-log` file reports binary/unrecognized encoding, instruct the user to either save as **`.MaxxECU-Zip-log`** or use MTune's **Log Viewer → Export → CSV** and re-upload.
2. Inspect the **Channel Inventory** and verify auto-mapped semantic roles:
   - `RPM`, `Load` (`MAP` kPa or `TPS` % if Alpha-N), `TPS`
   - `Lambda` (`Lambda A`, `Lambda B` if dual-bank), `Lambda Target`, `Lambda Corr` (closed-loop % trim), `Long-Term Trim / Fuel Adaptation`, `Total Fueling Target Error`
   - `Ignition Angle`, `Knock Level` / `Knock Retard`, `Injector PW` / `Duty Cycle`
   - `CLT`, `IAT`, `Battery Voltage`, `Fuel Pressure` (and differential fuel pressure `FuelP - MAP`), `Oil Pressure`, `Ethanol %` (if Flex Fuel), `Boost Target` / `Boost Duty` (if forced induction), `Fuel Cut` / `Ign Cut` / `Rev Limiter` flags.
3. Verify unit normalization: MaxxECU logs may be exported in metric (`kPa`, `°C`, `Lambda`) or imperial (`psi`, `°F`, `AFR`). Always confirm Lambda math uses true Lambda (never gas-scale AFR on ethanol blends!).

### Step 3: Apply MaxxECU Fuel Model & VE Error Math (CRITICAL)
MaxxECU uses a **VE + Target Lambda** fuel model (verify `Multiply Lambda = 1` in `.MaxxECU-save`):
- **Never compute VE error from raw `Lambda / Target` alone when closed-loop Lambda control is active** — you MUST include the active closed-loop trim (`Lambda corr %`) and any active `Long-Term Fuel Trim / Adaptation %`:
  $$\text{Total VE Error \%} = \left[\left(1 + \frac{\text{LambdaCorr \%} + \text{LTFT \%}}{100}\right) \times \left(\frac{\lambda_{\text{meas}}}{\lambda_{\text{target}}}\right) - 1\right] \times 100$$
- Sign convention:
  - **Positive % = Lean** → **ADD % to VE table** (`VE_new = VE_old * (1 + err/100)`)
  - **Negative % = Rich** → **SUBTRACT % from VE table**
- **Steady-state gating**: Exclude cold engine (`CLT < MinClt` AND full transmission/oil warmup if available, e.g. `Trans Oil Temp [1004] >= 48.9°C / 120°F`), cranking/afterstart, overrun fuel cut (plus **`0.8 s` post-FuelCut** exhaust-clearing settling guard!), active accel enrichment (plus **`0.5 s` post-AE** settling guard!), rev/boost/launch/traction cuts, invalid wideband readings (`< 0.65` or `> 1.35` $\lambda$), and rapid TPS/MAP transients.
- **Flex Fuel / Ethanol**: Work strictly in Lambda ($\lambda$). Confirm ethanol % stability during pulls and check `Fuel Primary Density`, `Extra Fuel` / `Extra Ign` blend tables, and injector duty cycle headroom (E85 demands ~30–35% more fuel volume than E0/E10).
- **Fuel Pressure Check**: Before blaming VE for high-load lean drift, ALWAYS check `Differential Fuel Pressure = Fuel Pressure - MAP` (for 1:1 manifold-referenced FPR) or check that `Fuel pressureadj` / differential pressure compensation is enabled and fuel pressure holds steady at WOT.

### Step 4: Analyze & Present Actionable Tuning Recommendations
Organize your report clearly by priority (**Safety / Critical First**, then **Fueling/VE**, **Ignition/Knock**, **Boost/Drivability**, **Next-Step Table Edits**):

1. **Session & ECU Profile:** ECU model/firmware, engine specs (cyl/cc/injectors/dual-bank/Flex Fuel), log duration & sample rate, drive profile (idle/cruise/decel/WOT), temp/voltage/pressure envelopes.
2. **Critical Safety & Mechanical Flags (Lead with these!):**
   - Lean WOT excursions (`λ_meas > λ_target + 0.03` under high load/boost), fuel pressure drop, low oil pressure, high **Injector Duty Cycle (`>80%` warn, `>90%` critical)**, knock retard / knock spikes, excessive IAT (`>55–65°C` boosted), battery charging sag (`<13.0V` running), or misconfigured protection cuts (`BoostCut`, `LeanPowerCut`, `OilPressureCut`, `RevLimit`, `Lambdareg MinCLT`).
3. **VE Table Calibration & Dual-Bank Balance:**
   - Summarize steady-state RPM × Load VE error map, highlight regions outside **±3%**, flag low-hit cells (`< MinHits`), and check **Bank A vs Bank B** wideband splits (`>3–4%` split points to exhaust leak, mismatched injector flow, or individual cylinder trim need).
   - Recommend **50%–75% damped corrections** for errors `>5%` and smooth transitions between adjacent RPM/Load cells.
   - Note any VE table anomalies from `.MaxxECU-save` (e.g., cells flat-topped/clipped at `100%`, sharp discontinuities, or IAT correction spikes).
4. **WOT / High-Load Pull & Ignition / Knock Review:**
   - RPM-binned WOT trace: MAP/Boost, target vs measured $\lambda$ (B1/B2), closed-loop trim, ignition advance, **true `Knock correction [479]` / `Knock Count [488]` / `Last knock cylinder [655]`** (never rely solely on blank legacy `Knock retard` aliases!), IDC %, fuel pressure, IAT, and `Fuel Flow Engine Power (hp) [1614]` / `Torque (Nm) [1615]`.
   - Separate **real high-load knock** (`MAP ≥ 80 kPa`) from harmless low-MAP decel valvetrain noise (`13–25 kPa`) and repeatable single-cylinder high-RPM valve-spring noise near redline. Flag abrupt timing jumps or aggressive advance at peak torque / high IAT.
5. **Boost Control (if forced induction), Accel Enrichment & Idle / Drivability:**
   - **Boost**: Target vs actual MAP, spool RPM, overshoot/oscillation, solenoid duty saturation (`>85–90%`).
   - **Accel Enrichment**: Tip-in lean spikes vs rich bog after rapid TPS steps; recommend `MinTpsDot`, `AccEnrichment Table`, `HoldTime`, or `DecayTime` adjustments.
   - **Idle & Overrun**: Closed-throttle RPM stability/hunting, MAP, idle spark lock (`Ign Idlelock`), IAC/stepper/E-throttle duty, overrun fuel cut entry/exit smoothness.
6. **DBW Idle, Electric-Fan Inrush, Hot-Start & Cruise Control Review (if E-Throttle equipped):**
   - **Alternator / Dual-Fan Inrush Safety (CRITICAL):** Never blindly slash `Idle AC Duty Up` or `Idle RadFan Duty Up` down to low numbers without checking battery voltage dip on fan/A/C engagement (`< 12.5V` transient dip under heavy electrical load can immediately stall the engine at idle!). Measure the steady-state `Idle ctrl duty Air [563]` delta (`Fan ON - Fan OFF` at `0 mph`), size `Idle RadFan Duty Up` to **`~2.5–3×`** that steady-state delta for reliable inrush catch, and mirror that exact negative value in `IdleCtrl User Duty Adjust`.
   - **`RadiatorFan Delay` Firmware Behavior (CRITICAL):** `RadiatorFan Delay` ONLY delays closing the physical fan relay (`GPO out 3 [411]`) — **`Idle RadFan Duty Up` still fires IMMEDIATELY** when `CLT >= Fan Ctrl Temp`! Setting `RadiatorFan Delay = 10 s` creates a 10-second blind window where `+Idle RadFan Duty Up` dumps air with zero alternator load on hot restarts AND prevents `IdleCtrl User Duty Adjust` (`Y = GPO out 3 [411]`) from cancelling rolling fan air until the relay closes. **Keep `RadiatorFan Delay = 0.5 s`**! To eliminate hot-restart fan flares cleanly, trim hot-cell `Afterstart IdleDutyTable` or gate Fan 1 via a custom `GPO` (`Engine runtime > 10 s`) with fan air supplied directly by `IdleCtrl User Duty Adjust`.
   - **Rolling Fan Idle-Up + `3 mph` Idle Disable Synergy:** Never lower `Idle closedloop Disable Spd` to `< 15 km/h` *without* a rolling fan cancel curve, or `Idle RadFan Duty Up` will drive the vehicle off-throttle. **WITH** a smooth 10-point **`IdleCtrl User Duty Adjust Table`** (`X = VSS Speed [89]`, `Y = Radiator Fan [411]`, `0%` at `0 mph` ramping to `-IdleRadFanDutyUp` by `~20 mph / 32 km/h`), lowering **`Idle closedloop Disable Spd` to `~4.8 km/h (3 mph)`** is a major upgrade: it stops CL idle from winding down to `Min Pos` during braking decel (eliminating `550–600 RPM` stop dips) while keeping rolling fan air cancelled.
   - **Pedal-Brush Stall Protection (`Idle closedloop disable TPS`):** Default `0.5%` is hair-trigger sensitive — brushing the pedal (`0.6–1.0% TPS`) while CL idle is rescuing a Park→Drive dip instantly aborts CL idle (dropping ignition rescue and air duty together → instant stall). Raise **`Idle closedloop disable TPS` to `1.5%`** and verify `Idle closedloop P Gain` (`~14–16`) catches Park→Drive drops quickly.
   - **Cold-Start & Warmup Sweep:** Below `Lambdareg MinCLT` (recommend `50°C`), use wideband Lambda vs. Target to dial `Fuel Warmup Table`, and verify the closed-loop handoff right at `MinCLT`. **CRITICAL:** Always keep the rightmost warm breakpoint of `Fuel Warmup Table` at `0%` so hot fueling is never shifted.
   - **Cruise Control PID:** MaxxECU uses pure PID starting at `0%` (no bumpless throttle feedforward). On DBW setups with a `~10–12%` closed-idle floor, soft `P`/`I` gains cause a multi-second speed sag until `CruiseCtrl Target Pos [598]` clears the idle floor, and `D = 0` causes recovery overshoot. Verify `CruiseCtrl P/I/D` (typical well-damped DBW range: `P = 45–55`, `I = 16–20`, `D = 5–6`) and `Cruise MaxTPS` against actual `SET` engagements in logs.
7. **ZF 8HP70 / 8HP90 (Dodge / BMW) CAN Transmission Audit (if `Dodge 8HP TCU type > 0`):**
   - **Torque Model vs. Real Output:** Compare `Dodge 8HP Engine Torque [901]` against `Fuel Flow Engine Torque (Nm) [1615]` at WOT. Under-reporting light-load torque gives smooth street shifts, but severe under-reporting in `Dodge 8HP Torque Adjust` Column `0` (in-gear holding) at high load (`75–101 kPa`) reduces clutch clamping line pressure during WOT pulls.
   - **`Shiftcut Retard Angle` vs. `ShiftCut Drop Ign/Fuel` Mid-Throttle Breakup Trap (CRITICAL!):** On large-bore NA DBW throttle bodies (e.g., 90mm LS3 TB), **50–60% mid-throttle pedal ALREADY produces `95–97 kPa` MAP**! Because `Shiftcut Retard Angle` uses **MAP (`[20]`)** on its Y-axis (not TPS), adding `10°–20°` retard at `63–101 kPa` triggers on *every* mid-throttle shift — and stacking `-15° to -18°` spark retard ON TOP of active `ShiftCut Drop Ign Table` + `ShiftCut Drop Fuel Table` (`Shiftcut Output = 3`) for `400–550 ms` makes mid-throttle shifts sound and feel like a violent breakup/misfire! Always inspect `Shiftcut Output`, `ShiftCut Drop Ign`, and `ShiftCut Drop Fuel` first; if those cuts are already active and shifts feel clean, **keep `Shiftcut Retard Angle = 0°`** (only use retard *instead of* Ign/Fuel cut, or on boosted MAP rows strictly above atmospheric baro `> 110 kPa`!).
   - **MaxxECU MAPS TCU Shift Target Lead Calibration (CRITICAL!):**
     - `Dodge 8HP Shift Strategy = 0` IS active **MaxxECU TCU MAPS (`1500–9000 rpm`)** on MAPS-flashed Gen1 TCUs — never blindly flip it!
     - `Dodge 8HP Automatic Upshift Offset` applies **ONLY to Manual Mode rev-limit auto-upshift protection** (`Revlimit RPM - Offset`), NOT Auto Drive Mode!
     - Because MaxxECU triggers Auto shifts by modulating reported load to the TCU, Gen1 MAPS TCUs consistently complete Auto WOT shifts **`~250–385 RPM` BELOW the `Dodge 8HP Shift Target Table` value** (tracking table edits 1-to-1). Always log an Auto WOT pull first, measure `Empirical_Lead = Table_Target - Actual_Peak_RPM`, and set the `90%` row to `Desired_Tach_RPM + Empirical_Lead` — while ALWAYS keeping the highest shift target **strictly below `Revlimit RPM`** and keeping rows strictly monotonic (`81.8% < 85% < 90%`) with no duplicate values!
   - **Takeoff Softening & TCC Lockup:** Preserve any intentional low-speed (`0–8 km/h`) torque reduction in `Dodge 8HP Torque Table` that prevents Park→Drive clunk, and check `Dodge 8HP Converter Lockup [906]` (`2 → 3`) when diagnosing light-throttle power-loss feel on high-stall converters.
8. **Direct `.MaxxECU-save` Revision Editing & Verification Rules:**
   - **XML Encoding Quirk:** `.MaxxECU-save` files declare `encoding="utf-16"` on line 1 even though the bytes are UTF-8 (no BOM, CRLF). Preserve the exact `<?xml version="1.0" encoding="utf-16"?>` declaration and write back UTF-8 **without BOM** (`UTF8Encoding($false)`).
   - **Mandatory Exact XML Diff:** Before presenting any generated `.MaxxECU-save` file to the user, parse it back as valid XML and run a node-by-node XML diff against the parent revision confirming **only** the intended settings/tables changed. Always instruct the user to verify in MTune via **File → Compare File** before flashing.
   - Provide specific table edits (exact RPM × Load coordinates or clipboard-ready TSV block with explicit Y-axis orientation reminder—MTune's 2D visual grid displays **highest Load/MAP at top** or **bottom** depending on user's MTune view setting; always verify top-left corner cell before pasting!).
   - Give concrete next-log instructions (what operating cells still lack hits, or what single change to verify next) and compare against prior revisions if available to confirm convergence toward **±2%**.

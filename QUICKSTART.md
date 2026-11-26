# Quick Start Guide — Universal MaxxECU Tuning Co-Pilot

This guide walks you step-by-step through installing the plugin, using every included tool, supplying your vehicle configuration profile (whether you're tuning a **single-turbo 2JZ-GTE Toyota Supra**, an **LS-swapped OBS truck**, a **K-series**, or a **BMW**), and tuning safely one step at a time.

---

## 1. Install in Antigravity (Windows — No Python Required)

### Option A — Clone From GitHub (Recommended)
Open PowerShell and run:
```powershell
git clone https://github.com/sakudog/MaxxECU-Ryker29.git "$env:USERPROFILE\.gemini\config\plugins\maxxecu-tuning"
```
To pull updates later:
```powershell
git -C "$env:USERPROFILE\.gemini\config\plugins\maxxecu-tuning" pull
```

### Option B — Download ZIP (No Git Needed)
1. Click **Code → Download ZIP** on [github.com/sakudog/MaxxECU-Ryker29](https://github.com/sakudog/MaxxECU-Ryker29).
2. Extract the contents directly into:
   ```text
   C:\Users\<YourUsername>\.gemini\config\plugins\maxxecu-tuning\
   ```
3. **Verify the folder layout** (avoid double-nesting `maxxecu-tuning\maxxecu-tuning\`!):
   ```text
   C:\Users\<YourUsername>\.gemini\config\plugins\maxxecu-tuning\
   ├── plugin.json          <-- MUST sit directly in this folder
   ├── README.md
   ├── QUICKSTART.md
   ├── assets\logo.svg
   └── skills\maxxecu-mtune-tuning\
       ├── SKILL.md
       ├── references\mtune_tuning_reference.md
       └── scripts\parse_maxxecu.ps1
   ```

### Enable Plugins in Antigravity
1. Open **Antigravity → Customizations / Plugins** and confirm **`maxxecu-tuning`** is toggled **ON**.
2. *(Optional — Recommended)* Install the **Google Sheets** plugin from the Antigravity Marketplace if you want the agent to maintain a live spreadsheet tracking every revision, VE table, and cell change automatically.

---

## 2. How to Use the Tools Included

### Tool 1: AI Tuning Co-Pilot (Antigravity Chat — Primary Workflow)
You do **not** have to run scripts manually. Once the plugin is enabled:
1. In MTune, save your current ECU calibration (**File → Save As** → `.MaxxECU-save`) and save your datalog as a **`.MaxxECU-Zip-log`** (best format — bundles both the log, sample rate metadata, and exact embedded tune breakpoints!).
2. Start a new Antigravity chat, drag-and-drop your `.MaxxECU-save` and `.MaxxECU-Zip-log` into the chat, and paste the **Starter Prompt** from Section 3 below.
3. For each revision, the agent will:
   - Parse your log and tune automatically using `parse_maxxecu.ps1`
   - Report safety flags first (lean WOT, knock, fuel pressure, IDC, dual-bank split, battery sag)
   - Generate an uploadable `.MaxxECU-save` revision (or MTune copy-paste table) with a **verified node-by-node XML diff**
   - Optionally sync every revision and cell delta into your Google Sheet

### Tool 2: Standalone PowerShell Log & Tune Analyzer (`parse_maxxecu.ps1`)
You can also run the native Windows C#/PowerShell parser directly from PowerShell anytime (handles 100 MB+, 1,800-column `.MaxxECU-Zip-log` files in ~3 seconds):

```powershell
# Analyze a .MaxxECU-Zip-log (auto-unpacks embedded tune + datalog)
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.gemini\config\plugins\maxxecu-tuning\skills\maxxecu-mtune-tuning\scripts\parse_maxxecu.ps1" `
  -Path "C:\path\to\your_log.MaxxECU-Zip-log"

# Analyze a standalone .MaxxECU-log / .csv paired with a separate .MaxxECU-save
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.gemini\config\plugins\maxxecu-tuning\skills\maxxecu-mtune-tuning\scripts\parse_maxxecu.ps1" `
  -Path "C:\path\to\your_log.csv" `
  -TunePath "C:\path\to\your_tune.MaxxECU-save" `
  -MinClt 80 -MinHits 5 -ApplyFactor 0.65

# Standalone calibration-only audit (dump VE, Lambda, and Ignition tables)
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.gemini\config\plugins\maxxecu-tuning\skills\maxxecu-mtune-tuning\scripts\parse_maxxecu.ps1" `
  -Path "C:\path\to\your_tune.MaxxECU-save" -DumpTables

# Export MTune clipboard-ready updated VE table (.tsv) and normalized CSV
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.gemini\config\plugins\maxxecu-tuning\skills\maxxecu-mtune-tuning\scripts\parse_maxxecu.ps1" `
  -Path "C:\path\to\your_log.MaxxECU-Zip-log" `
  -ExportVeTable "C:\path\to\updated_ve.tsv" `
  -ExportCsv "C:\path\to\normalized_log.csv"
```

**Useful CLI Flags:**
| Flag | Default | Purpose |
| :--- | :--- | :--- |
| `-Path` | *(required)* | `.MaxxECU-Zip-log`, `.MaxxECU-log`, `.maxxlog`, `.csv`, or standalone `.MaxxECU-save` |
| `-TunePath` | `""` | Companion `.MaxxECU-save` when `-Path` is a standalone log or CSV |
| `-MinClt` | `70` | Minimum coolant temp (°C) for steady-state VE error binning |
| `-MaxDTps` / `-MaxDMap` | `3.0` / `8.0` | Transient filters excluding tip-in/spool spikes |
| `-MinHits` | `5` | Minimum steady-state samples required before adjusting a VE cell |
| `-ApplyFactor` | `0.65` | Damping factor applied to VE errors `> 5%` to prevent overshoot |
| `-DumpTables` | off | Prints full `VE Table 1`, `Lambda Table 1`, and `IgnAdv Table 1` |
| `-ExportVeTable` | `""` | Writes a tab-delimited VE table ready for MTune clipboard paste |
| `-ExportCsv` | `""` | Exports normalized channels + `TotalVeErrorPct` and `IDC_Pct` |

### Tool 3: MTune `Compare File` Safety Workflow (Use Before Every Flash!)
Whenever the agent builds a new `.MaxxECU-save` revision (e.g., `V1` → `V2`):
1. Open your **current** `.MaxxECU-save` in MTune.
2. Click **File → Compare File** and select the **new** `.MaxxECU-save`.
3. Visually verify that **only** the expected tables/settings show differences before flashing to the ECU.

---

## 3. Copy-Paste Starter Prompt (Your First Session)

Start a new Antigravity chat, attach your current `.MaxxECU-save` and baseline `.MaxxECU-Zip-log`, and paste the filled-in configuration blocks below (see **[VEHICLE_PROFILE.md](./VEHICLE_PROFILE.md)** for complete filled-in **Toyota Supra 2JZ-GTE** and **LS-Swapped OBS Truck** examples):

> Use the `maxxecu-mtune-tuning` skill to audit my attached `.MaxxECU-save` calibration and `.MaxxECU-Zip-log` datalog, cross-checking my physical build against my MTune settings first.
>
> **My Build Profile:**
> - **Vehicle & Weight:** [e.g., 1994 Toyota Supra MK4 (3,550 lbs) / 1997 LS-Swapped OBS Truck (3,900 lbs)]
> - **Engine Configuration:** [displacement, cyl count, NA vs. turbo/SC & target psi, bore/stroke, CR, cams, heads, intake, DBW vs. cable TB + IACV, redline]
> - **Fuel System Configuration:** [fuel octane / E85 / Flex Fuel sensor?, injector model & cc/min @ 3 bar, pump(s), base pressure & 1:1 referenced vs. fixed returnless, fuel pressure sensor?, single vs. dual wideband]
> - **Exhaust System Configuration:** [turbo manifold/downpipe vs. headers, high-flow/OEM cats vs. catless, wideband sensor placement]
> - **Transmission:** [Manual + clutch type OR Dodge/BMW 8HP / 4L80E / DCT / DSG + converter stall RPM]
> - **Rear Gear & Tire Size:** [e.g., 3.13 / 3.23 / 3.73 rear gear, rear tire diameter]
> - **Fan Type & Electrical Loads:** [**PWM soft-start** vs. **On/Off Relay-switched** (single/dual), A/C active?, alternator amps, thermostat temp, full-warmup rule (e.g., `CLT >= 80°C` + `Oil/Trans >= 120°F`)]
>
> **Goals:**
> 1. Cross-check my physical profile against `.MaxxECU-save` and flag any mismatches or safety issues first.
> 2. Build a step-by-step street/dyno tuning roadmap tailored to my exact hardware.
> 3. Generate uploadable `.MaxxECU-save` revisions one clean step at a time, with a verified exact XML diff before I flash.
> 4. *(Optional)* Create a Google Sheet workbook and log every revision and cell change as we go.

---

## 4. Recommended 6-Step Tuning Order (Adapts to NA, Turbo, Manual, or Auto)

Follow this order — changing **1–2 related areas per log** keeps every test clean and reversible:

1. **Step 1 — Profile Validation & Baseline Safety:** Cross-check `Engine Cylcount`/`Volume`, `KnockCtrl Diameter` (bore mm), injector deadtimes, `Multiply Lambda = 1`, `Fuel pressureadj`, `Lambdareg MinCLT` (`50°C` recommended), IAT correction smoothness, Flex Fuel config, and protection cuts (`LeanPowerCut`, `BoostCut`, `RevLimit`, `OilPressureCut`).
2. **Step 2 — Steady-State `VE Table 1` (Full Warmup Only):** Drive normal street, highway, and steady load once fully warmed up (`CLT >= 80°C` plus oil/trans warmup). Apply damped corrections (`50–75%`) until driven cells converge inside **±2–3%** with closed-loop trims near `0%` and dual-bank split `< 2%`. Blend unvisited perimeter cells smoothly.
3. **Step 3 — WOT Fueling, Boost Control (if Forced Induction), Spark/Knock & Accel Enrichment:**
   - **NA or Boosted:** Verify fuel pressure tracks `1:1` (or flat differential), IDC stays `< 80%`, and zero knock across part-load and WOT pulls.
   - **Turbo / Supercharged:** Dial closed-loop boost target vs. actual MAP, WGDC headroom (`< 85–90%`), IAT timing retard, and E85 Flex Fuel blend tables.
   - **Transients:** Dial `AccEnrichment Table` & `MinTpsDot` so quick throttle stabs have crisp response without lean stumbles or rich bog.
4. **Step 4 — Idle, Fan Control (PWM vs. Relay) & Cold-Start Warmup:**
   - Dial hot idle (`Idle OpenloopDutyTable`, `Idle closedloop Min Pos`, `deadband`, DBW or cable IACV) so hot idle spark sits comfortably around `12–18°`.
   - **Relay-Switched High-Draw Fans:** Protect `0 mph` idle against voltage inrush dips (`Idle RadFan Duty Up`), set `RadiatorFan Delay` (`8–10 s`) to prevent hot-restart flares, and scale rolling fan duty down via `IdleCtrl User Duty Adjust` (`VSS × Fan`) so closed-loop `I` doesn't wind deeply negative while moving.
   - **PWM Soft-Start Fans:** Verify smooth `Radiatorfan PWM` ramp and keep `Idle RadFan Duty Up` modest (`~10–15%`).
   - Capture an overnight **cold-start log** (checklist below) to dial `Fuel Warmup Table` (**always keeping the rightmost warm cell at `0%`**!).
5. **Step 5 — Transmission-Specific Optimization:**
   - **Dodge / BMW 8HP (or CAN Auto):** Cross-check `Dodge 8HP Engine Torque [901]` vs. `Fuel Flow Engine Torque [1615]`, configure cat-safe **positive** `Shiftcut Retard Angle` at high load (`≥ 63 kPa`), verify high-load clamping in `Dodge 8HP Torque Adjust`, and align WOT `Dodge 8HP Shift Target Table` RPMs to your powerband and gear-ratio drops.
   - **Manual Transmissions (e.g., V160 / T56 / CD009):** Verify clutch-in coasting / overrun fuel-cut exit smoothness (`Disable Spd` & `Ramp Time`), shift-cut / flat-foot shifting (cat-safe if catted!), and boost-by-gear traction limits.
6. **Step 6 — Final Failsafes & Cruise Control PID:** Once VE is dialed, tighten `Lambda min/max corr` (especially under high load/boost so a failed wideband can never pull fuel at WOT), and tune `Cruise PID P / I / D` + `Cruise MaxTPS` (if equipped) against logged `SET` engagements.

---

## 5. How to Capture a Quality Cold-Start Log

1. Start from a true overnight cold soak (`CLT` near ambient, **A/C OFF**).
2. **Key ON, Engine OFF:** Connect MTune and **start recording ~5 seconds before cranking** (captures ambient temps, battery voltage, and fuel prime).
3. **Crank & Fire — Foot Completely OFF the Pedal:** Don't blip the gas for 30+ seconds so the log captures clean cranking, afterstart bark, and cold idle settling.
4. **Warmup in Park past `Lambdareg MinCLT` (~`55°C / 131°F`):** Captures pure open-loop `Fuel Warmup Table` Lambda below `50°C` and the exact closed-loop O2 handoff at `50°C`.
5. **Cold Gear Check (`~50–55°C`):** Hold brake firmly, shift **Park → Drive (~10 s) → Reverse (~10 s)**, then drive normally to full operating temperature (`CLT >= 80°C`, `Trans >= 120°F`). Include a few normal & firm stops, 1–2 Cruise `SET` engagements, and (if testing fan delay) a 5-second hot restart above fan-on temp.

---

## 6. Golden Safety Rules
- **Always verify in MTune (`File → Compare File`) before flashing any generated `.MaxxECU-save`.**
- **Never flash someone else's `.MaxxECU-save`** onto a different engine/injector/transmission combination.
- **Never slash `Idle AC Duty Up` or `Idle RadFan Duty Up` blindly** — heavy electric fan / A/C alternator inrush can stall an idling engine immediately. Test fan-duty changes stationary in your driveway with MTune live.
- **Always keep the rightmost warm cell of `Fuel Warmup Table` at `0%`** so warm fueling is never shifted.
- **Keep `.gitignore` intact** if you fork this repo — never commit personal `.MaxxECU-save` or `.MaxxECU-Zip-log` files to a public repository.

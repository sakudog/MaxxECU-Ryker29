# Quick Start Guide — MaxxECU + LS / Dodge 8HP Tuning Co-Pilot

This guide walks you step-by-step through installing the plugin, using every included tool, capturing clean logs in MTune, and iteratively tuning your MaxxECU + LS / 8HP build safely.

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

Start a new Antigravity chat, attach your current `.MaxxECU-save` and baseline `.MaxxECU-Zip-log`, and paste this filled-in prompt:

> Use the `maxxecu-mtune-tuning` skill to audit my attached `.MaxxECU-save` calibration and `.MaxxECU-Zip-log` datalog.
>
> **My Build Profile:**
> - **Vehicle & Weight:** [e.g., '99 Silverado / C10 / Camaro, 3,900 lbs w/ driver]
> - **Engine:** [e.g., 6.0L / 6.2L LS, bore/stroke, compression ratio, heads, intake, TB size (DBW or cable)]
> - **Camshaft:** [e.g., specs @ .050", lift, LSA]
> - **Fuel System:** [e.g., injector model & cc/min @ 3 bar, fuel pump, fuel grade / E85, dual or single wideband]
> - **Exhaust:** [e.g., 1-7/8" long-tube headers, catalytic converters or catless]
> - **Transmission & Driveline:** [e.g., Dodge 8HP70 / 8HP90, converter stall RPM, rear gear ratio]
> - **Thermostat & Full-Warmup Rule:** [e.g., 190°F thermostat; treat vehicle as fully warmed up once `CLT >= 80°C` AND `Transmission Oil Temp >= 120°F`]
>
> **Goals:**
> 1. Run a safety & calibration audit first (flag any typos, protection gaps, knock, lean WOT, fuel pressure, or dual-bank imbalance).
> 2. Build a step-by-step street tuning roadmap (VE → Spark/Knock → Accel Enrichment → DBW Idle & Fan Control → Cold-Start Warmup → Dodge 8HP70/8HP90 → Cruise Control PID).
> 3. Generate uploadable `.MaxxECU-save` revisions one clean step at a time, with a verified exact XML diff before I flash.
> 4. *(Optional)* Create a Google Sheet workbook and log every revision and cell change as we go.

---

## 4. Recommended 6-Step Street Tuning Order

Follow this order — changing **1–2 related areas per log** keeps every test clean and reversible:

1. **Step 1 — Safety & Baseline Glitches:** Verify injector deadtimes, `Multiply Lambda = 1`, `Lambdareg MinCLT` (`50°C` recommended so O2 doesn't fight cold warmup), IAT correction smoothness, knock bore size, fuel pressure stability, and safety cuts (`LeanPowerCut`, `RevLimit`, `OilPressureCut`).
2. **Step 2 — Steady-State `VE Table 1` (Full Warmup Only):** Drive normal street, highway, and light/medium hills once fully warmed up (`CLT >= 80°C` and `Trans/Oil Temp >= 120°F`). Apply damped corrections (`50–75%`) until driven cells converge inside **±2–3%** with closed-loop trims near `0%` and dual-bank split `< 2%`. Blend unvisited perimeter cells smoothly.
3. **Step 3 — Spark/Knock & Accel Enrichment:** Eliminate any part-load or lugging knock first, verify WOT knock = `0°`, then dial tip-in `AccEnrichment Table` & `MinTpsDot` so quick throttle stabs don't lean-stumble or bog overly rich.
4. **Step 4 — DBW Idle, Electric Fans & Cold-Start Warmup:**
   - Dial hot Park & Drive idle (`Idle OpenloopDutyTable`, `Idle closedloop Min Pos`, `deadband`) so hot spark sits comfortably around `14–18°` with smooth stops.
   - If hot restarts flare `> 1,800 RPM` when cooling fans kick on immediately, check **`RadiatorFan Delay`** (`8–10 s` lets the engine settle before fans engage).
   - If high `Idle RadFan Duty Up` is needed at `0 mph` to catch fan/alternator inrush without stalling, use **`IdleCtrl User Duty Adjust`** (`VSS × Fan 1`) to smoothly scale that fan duty down to `0%` by `15–20 mph` while keeping `Idle closedloop Disable Spd` safely enabled.
   - Capture a true overnight **cold-start log** (checklist below) to polish `Fuel Warmup Table` (`15–60°C`, **always keeping the rightmost warm breakpoint at `0%`**!).
5. **Step 5 — Dodge 8HP70 / 8HP90 Audit:** Review `Dodge 8HP Engine Torque [901]` vs. `Fuel Flow Engine Torque [1615]`, add cat-safe **positive** ignition retard in `Shiftcut Retard Angle` at high load (`≥ 63 kPa`) so WOT upshifts honor TCU torque cuts, verify high-load holding torque in `Dodge 8HP Torque Adjust`, and align WOT `Dodge 8HP Shift Target Table` RPMs to your cam's powerband and 8HP gear ratio drops.
6. **Step 6 — Final Failsafes & Cruise Control PID:** Once VE is locked in, tighten `Lambda min/max corr` (especially under high load/WOT so a failed wideband can never lean out the motor), and tune `Cruise PID P / I / D` + `Cruise MaxTPS` against logged `SET` engagements.

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

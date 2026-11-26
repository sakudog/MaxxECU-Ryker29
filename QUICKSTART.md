# Quick Start Guide — Tuning Your MaxxECU + LS / 8HP Build

## 1. Copy-Paste Starter Prompt (First Chat)
Start a new Antigravity conversation, attach your current **`.MaxxECU-save`** and a baseline **`.MaxxECU-Zip-log`** (saved from MTune), and paste this prompt filled in with your specs:

> Use the `maxxecu-mtune-tuning` skill to review my attached `.MaxxECU-save` tune and `.MaxxECU-Zip-log` datalog.
>
> **My Build Profile:**
> - **Engine:** [e.g., 6.0L / 6.2L LS, cam specs, heads, intake, TB size (DBW or cable)]
> - **Fuel System:** [e.g., injector model & flow, fuel pump, fuel grade / E85, dual or single wideband]
> - **Exhaust:** [e.g., long-tube headers, cats or catless]
> - **Transmission & Driveline:** [e.g., Dodge 8HP70 / 8HP90, stall RPM, rear gear ratio, vehicle weight]
> - **Thermostat / Warmup Rule:** [e.g., 190°F thermostat; consider fully warmed up when CLT ≥ 80°C and Trans/Oil Temp ≥ 120°F]
>
> Please:
> 1. Run a full calibration & datalog safety audit first.
> 2. Build a step-by-step street tuning plan (VE, Accel Enrichment, Cold-Start Warmup, DBW Idle, Dodge 8HP, Cruise Control).
> 3. Generate uploadable `.MaxxECU-save` revisions one clean step at a time with an exact XML diff before I flash.
> 4. *(Optional)* Track every revision and table change in a Google Sheet workbook.

---

## 2. Best Practices for Clean, Fast Results
- **Always upload `.MaxxECU-Zip-log`** (not bare `.csv`) whenever possible — it bundles both your exact embedded `.MaxxECU-save` breakpoints and `LogRate` metadata.
- **Change 1–2 related things per revision** so every log cleanly proves what helped and what didn't.
- **Always run `File → Compare File` in MTune** comparing your previous tune to each new generated `.MaxxECU-save` before flashing.
- **Gate VE tuning to full operating temperature** (coolant AND transmission/oil temp warm) so warmup enrichment doesn't skew steady-state VE cells.

---

## 3. Cold-Start Logging Checklist
1. Overnight cold soak (`CLT` near ambient, A/C OFF).
2. Key ON, Engine OFF → connect MTune → **start logging ~5 seconds before cranking**.
3. Crank and fire with **foot completely OFF the pedal**; let idle untouched for 30+ seconds.
4. Let it warm up in Park past `Lambdareg MinCLT` (e.g., `50–55°C / 122–131°F`) to capture open-loop `Fuel Warmup Table` accuracy and the closed-loop handoff.
5. Hold brake firmly, shift Park → Drive (~10 s) → Reverse (~10 s), then drive normally to full operating temp (including a few normal/firm stops, Cruise `SET` engagements if equipped, and a brief hot restart if testing fan startup delay).

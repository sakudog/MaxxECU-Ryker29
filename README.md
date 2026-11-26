# MaxxECU MTune Log, Calibration & 8HP Analyzer (Antigravity Plugin)

An AI-assisted street and dyno tuning plugin for **MaxxECU MTune** (`.MaxxECU-Zip-log`, `.MaxxECU-log`, `.maxxlog`, `.csv`, and `.MaxxECU-save`), built for native Windows execution with **zero Python dependencies**.

## What It Does
- **Native `.MaxxECU-Zip-log` & `.MaxxECU-save` Parsing:** Automatically unpacks the embedded tune, `LogMetaData` sample rate, and 1,800+ `[ID]`-tagged RT-Data channels (including custom blended VE Load axes such as `User table 2`).
- **Closed-Loop + Open-Loop VE Table Calibration:** Computes true combined VE error (measured Lambda + active closed-loop `Lambda corr` + `LTFT`), applies post-FuelCut and post-Accel-Enrichment settling guards, checks dual-bank wideband balance, and outputs damped MTune-ready corrections or directly patched, XML-diff-verified `.MaxxECU-save` revisions.
- **Cold-Start & Warmup Auditing:** Sweeps `Fuel Warmup Table` below and across `Lambdareg MinCLT`, verifies cranking/afterstart decay, and keeps the rightmost warm cell locked at `0%`.
- **DBW Idle, Fan-by-VSS & Hot-Start Diagnostics:** Audits E-Throttle idle floors, alternator/dual-fan electrical inrush safety, `RadiatorFan Delay` hot-restart flares, and `IdleCtrl User Duty Adjust` (`Fan × VSS`) scaling curves.
- **Cruise Control PID Review:** Diagnoses slow `SET` engagement, negative integral windup, and DBW idle-floor deadzone lag.
- **Dodge 8HP70 / 8HP90 CAN Audit:** Inspects `Dodge 8HP Shift Target Table` gear-ratio drops, `Dodge 8HP Torque Adjust` WOT clamping vs. part-throttle smoothness, `Shiftcut Retard Angle` (positive-degree convention, cat-safe), and TCC lockup telemetry.

---

## Install in Antigravity (Windows)

### Option A — Clone Directly From GitHub (Recommended for Easy Updates)
```powershell
git clone https://github.com/sakudog/MaxxECU-Ryker29.git "$env:USERPROFILE\.gemini\config\plugins\maxxecu-tuning"
```
To pull future updates later:
```powershell
git -C "$env:USERPROFILE\.gemini\config\plugins\maxxecu-tuning" pull
```

### Option B — Download & Unzip
1. Download the repository ZIP (or `maxxecu-tuning-plugin.zip`).
2. Extract the `maxxecu-tuning` folder into:
   ```
   C:\Users\<YourUsername>\.gemini\config\plugins\maxxecu-tuning\
   ```
   *(Make sure `plugin.json` sits directly inside that `maxxecu-tuning\` folder.)*
3. Open Antigravity → **Customizations / Plugins** and confirm **`maxxecu-tuning`** is enabled.
4. *(Optional)* Install the **Google Sheets** plugin from the Antigravity Marketplace if you want the agent to maintain a live revision-tracking workbook alongside your tune files.

---

## Quick Start
See **[QUICKSTART.md](./QUICKSTART.md)** for a copy-paste **Starter Prompt**, cold-start logging checklist, and MTune `Compare File` safety workflow.

> **Safety Disclaimer:** Always inspect every generated `.MaxxECU-save` revision in MTune using **File → Compare File** before flashing to your ECU. Never flash someone else's tune file onto a different engine/injector/transmission combination.

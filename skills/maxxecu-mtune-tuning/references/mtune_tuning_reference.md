# MaxxECU MTune Reference Guide

## 1. Supported File Formats

| Extension | Format | Contents | Notes |
| :--- | :--- | :--- | :--- |
| `.MaxxECU-Zip-log` / `.MaxxECU-Zip.log` | Standard ZIP archive | `.MaxxECU-log` (1,800+ RT-Data columns with `[ID]` tags) + `Embedded Tune *.MaxxECU-save` + `fileinfo01.LogMetaData` (`LogRate` = sample period in seconds) + `Readme.txt` | **Best format to request from users**—gives exact VE/Lambda/Ign breakpoints, `LogRate` timing, and `[ID]`-tagged channels. |
| `.MaxxECU-log` / `.maxxlog` | Tab-delimited text (usually) | Timestamped RT-Data channels | Extension `.maxxlog` is identical to `.MaxxECU-log` (renamed for email filters). |
| `.csv` | Comma- or semicolon-delimited text | MTune `Log Viewer -> Export -> CSV` | Available in MTune 1.122+. May use localized units (`°F`, `psi`, `AFR`). |
| `.MaxxECU-save` | XML (`<MaxxECUSettingsFile>`) | All `ECUSettingsItem`, `DynamicTable`, `Fileinfo`, `MiniScript` | **XML Quirk:** Header often declares `encoding="utf-16"` even though file bytes are UTF-8/ASCII. Always strip/override the declaration when loading via `XmlDocument`. |

---

## 2. Verified MaxxECU RT-Data & `AxisDataSource` IDs (MTune 1.162)

| Channel / Axis ID | MTune Name | Typical Units |
| :--- | :--- | :--- |
| `5` | Lambda (Average) | $\lambda$ |
| `17` | Intake air temp (IAT) | °C |
| `18` | Coolant temp (CLT) | °C |
| `19` | Throttle position (TPS) | % |
| `20` | MAP (Manifold Absolute Pressure) | kPa |
| `21` | Battery voltage | V |
| `60` | Ignition angle | ° BTDC |
| `61` | RPM (Engine speed) | RPM |
| `63` / `64` | Fuel pulse primary / Fuel duty primary | ms / % |
| `69` | Engine runtime | s |
| `70` | VE table 1 (active) | % |
| `81` | Lambda target | $\lambda$ |
| `89` / `90` | VSS Speed / VSS Gear | km/h / # |
| `95` | Baro pressure | kPa |
| `100` / `584` | Fuel cut / Fuel cut reason | % / bitmask |
| `101` / `585` | Ignition cut / Ignition cut reason | % / bitmask |
| `102` / `112` | Lambda corr A / Lambda corr B | % |
| `103` / `106` | TPS Rate / Acc enrichment | %/s / % |
| `110` / `111` | Lambda A / Lambda B | $\lambda$ |
| `119` / `280` | Boost solenoid duty / Boost Target MAP | % / kPa |
| `123` | Long term trim 1 (Fuel Adaptation) | % |
| `136` | EGT Highest | °C |
| `204` | Main throttle 1 position | % |
| `246` / `813` | Ethanol concentration / Ethanol used | % |
| `247` | Fuel temperature | °C |
| `273` | Fuel load primary | % |
| `311` | User table 2 (commonly custom TPS×MAP blended Load) | Load units |
| `479` / `488` | Knock correction / Knock Count | ° / # |
| `499` | Primary fuel pressure | kPa |
| `562` / `563` / `818` | Idle RPM error / Idle ctrl duty Air / Idle Target RPM | RPM / % / RPM |
| `664` / `665` / `806` | Fueling Target Error Bank A / Bank B / Total Fueling Target Error | % |
| `804` | Engine Oil Pressure | kPa |

*Note: Always verify axis meaning against the actual breakpoint values (`0..101.3` = NA MAP kPa; `0..300+` = boosted MAP kPa; `0..100` with tight low-end spacing like `0,2,5,10` = Alpha-N TPS %).*

---

## 3. MaxxECU Fuel Model & Math

When `Multiply Lambda = 1` (standard modern MaxxECU VE fuel model):
$$\text{Fuel Mass} \propto \text{Displacement} \times \text{MAP} \times \frac{\text{VE \%}}{100} \times \frac{1}{\lambda_{\text{target}}} \times \prod \text{Corrections}$$

### Total VE Error (Closed-Loop + Open-Loop Combined)
Because closed-loop Lambda Control (`Lambda corr %`) and Fuel Adaptation (`LTFT %`) actively mask VE error in measured Lambda:
$$\text{Total VE Error \%} = \left[\left(1 + \frac{\text{LambdaCorr \%} + \text{LTFT \%}}{100}\right) \times \left(\frac{\lambda_{\text{meas}}}{\lambda_{\text{target}}}\right) - 1\right] \times 100$$

- **Positive %** = Engine needed more fuel (Lean) → **Increase VE cell**: `VE_new = VE_old * (1 + err / 100)`
- **Negative %** = Engine needed less fuel (Rich) → **Decrease VE cell**: `VE_new = VE_old * (1 + err / 100)`
- **Damping**: For `|err| > 5%`, apply `50%–75%` of the error per revision to prevent oscillation, especially if deadtime or fuel pressure hasn't been verified yet.

### Injector Duty Cycle (IDC)
$$\text{IDC \%} = \frac{\text{IPW}_{\text{ms}} \times \text{RPM}}{1200} \quad (\text{4-stroke sequential, 1 injection per 720°})$$
- **Healthy**: `< 80%` at peak power RPM
- **Warning**: `80% – 88%` (limited headroom for cold air or higher ethanol %)
- **Critical**: `> 90%` (risk of static/lean-out at high RPM)

### Typical Target Lambda Guidelines (Verify per build!)
| Operating Region | Pump Gas (91–93 oct) | E85 / High Ethanol |
| :--- | :--- | :--- |
| Idle | `0.97 – 1.02` (`0.95–0.98` for big cams) | `0.98 – 1.02` |
| Light Cruise (30–70 kPa) | `0.98 – 1.04` | `0.98 – 1.03` |
| NA WOT (90–102 kPa) | `0.85 – 0.88` | `0.82 – 0.86` |
| Low Boost (115–160 kPa) | `0.80 – 0.84` | `0.78 – 0.83` |
| High Boost (170–250+ kPa) | `0.75 – 0.80` | `0.74 – 0.80` |

---

## 4. Key Calibration Audit Checks (`.MaxxECU-save`)

1. **Fueling Setup**:
   - `Multiply Lambda = 1` (if `0`, changing Lambda table does NOT automatically rescale fuel!).
   - `Fuel pressureadj`: Verify whether a fuel pressure sensor is active (`Primary Injectors FuelPressure Source`) and matches the hardware (1:1 manifold-referenced vs fixed returnless).
   - `Fuel Injdeadtime TimePt` vs `BattVPt`: Must decrease smoothly as voltage rises (`8V -> 18V`).
2. **VE Table (`VE Table 1 data`)**:
   - Watch for **ceiling clipping** (multiple cells stuck at `100.0` at high RPM/load — indicates either injector flow/scaling is slightly off or VE table needs values `>100%` on a high-VE engine).
   - Watch for abrupt cell-to-cell jumps (`>12–15%`) that cause drivability surges or closed-loop oscillation.
3. **Temperature Corrections**:
   - `Fuel IATCorr Table data`: Should smoothly decrease fuel (or stay near `0%` if ideal-gas density is already modeled internally) as IAT rises—flag sign inversions or jagged spikes (e.g., `0, 0, +3, -6`).
   - `Fuel Warmup Table data`: Should decay smoothly to `0%` by operating temp (`70–80°C`).
4. **Closed-Loop Lambda Control (`Lambdareg *`)**:
   - `Lambdareg MinCLT`: Recommend `45–60°C` minimum! Setting `15°C` lets closed-loop fight cold warmup enrichment and poison fuel trims while the wideband/engine is still warming up.
   - `Lambdareg Max TPS Delta` / `Rate Type`: Ensure transient pause is active so closed-loop doesn't fight Accel Enrichment.
   - `Lambda min/max corr Table`: Typically `±10%` to `±15%` at cruise, tighter (`-5%` to `+10%`) or `+only` (`0%` to `+15%`) under heavy boost so a failed O2 sensor cannot pull fuel at WOT!
5. **Safety Protections**:
   - `LeanPowerCut`: Verify `Enable = 1`, `Use LambdaTable = 1`, reasonable `Deviation` (`0.08–0.15` $\lambda$), `Min MAP`, `Min RPM`, `Time` (`0.3–0.8s`).
   - `BoostCut`: Verify `Enable = 1` and `MAP level` is safely above target boost (`+15–25 kPa` margin) — note on NA cars `200 kPa` is harmless, on boosted cars it must match hardware limits.
   - `OilPressureCut`: Check `OilPressureCut MinPressure Table` vs RPM and `Enable` flag.
   - `KnockCtrl`: Confirm bore diameter (`KnockCtrl Diameter` in mm — e.g. `101` mm for 4.000" 6.0L LS), per-bank cylinder mapping, and safe `MaxRet` (`6–12°`).

---

## 5. Common MTune Log Column Name Aliases

MTune channel names vary slightly across firmware versions and CSV export locales. The parser normalizes common aliases automatically:
- **Time**: `Time`, `Time (s)`, `TimeStamp`, `Log time`
- **RPM**: `RPM`, `Engine speed`, `Engine Speed (RPM)`
- **MAP / Load**: `MAP`, `Manifold absolute pressure`, `Fuel load`, `Load`
- **TPS**: `TPS`, `Throttle position`, `E-Throttle position`
- **Lambda**: `Lambda`, `Lambda avg`, `Lambda A`, `Lambda 1`, `Lambda B`, `Lambda 2`, `AFR`
- **Lambda Target**: `Lambda target`, `Target lambda`, `AFR target`
- **Lambda Correction**: `Lambda corr`, `Lambda corr A`, `Lambda corr B`, `Lambda correction`, `Closed loop lambda`
- **Long-Term Trim**: `Long term trim`, `Fuel adaptation`, `LTFT`
- **Total Fueling Error**: `Total fueling target error`, `Lambda target error`
- **Ignition**: `Ignition angle`, `Ign angle`, `Spark advance`, `Ignition timing`
- **Knock**: `Knock retard`, `Knock level`, `Knock count`, `Knock cyl`
- **Fuel / Injectors**: `Injection time`, `Injector pulse width`, `Inj PW`, `Injector duty`, `Fuel duty`, `Fuel VE`, `Fuel pressure`, `Fuel diff pressure`, `Accel enrich`
- **Temps & Aux**: `CLT`, `Coolant temp`, `IAT`, `Intake air temp`, `Battery voltage`, `Batt V`, `Oil pressure`, `Ethanol`, `Ethanol content`, `Boost target`, `Boost duty`, `EGT`, `VSS`, `Vehicle speed`, `Gear`, `Fuel cut`, `Ign cut`

---

## 6. Dodge 8HP70 / 8HP90 RT-Data IDs & Calibration Notes (MTune 1.162)

| Channel ID | MTune Name | Tuning Significance |
| :--- | :--- | :--- |
| `901` | `Dodge 8HP Engine Torque` | Actual Nm reported over CAN to ZF TCU (controls clutch line pressure) |
| `903` / `911` | `Torque Reduction Target` / `Request` | TCU shift torque-cut request (`1` = active, target Nm) |
| `904` / `985` | `Dodge 8HP Target Gear` / `Delayed Gear` | Active commanded & actual gear (`-3`=Park, `-1`=Rev, `1..8`=Fwd) |
| `905` | `Dodge 8HP Last Shift Time` | Shift duration in ms (`~300–500 ms` crisp under load; `>700–900 ms` at WOT suggests weak torque cut or low clamping pressure) |
| `906` | `Dodge 8HP Converter Lockup` | `0/1`=Open, `2`=Slipping, `3`=Full TCC Lockup |
| `912` / `920` | `Drive Mode` / `Shift Status` | Active Z-slice & X-column of `Dodge 8HP Torque Adjust` (`920`: `0`=In-gear, `1`=Downshift, `2`=Upshift) |
| `1004` | `Transmission Oil Temp` | Useful full-warmup gate (`>= 48.9°C / 120°F`) when engine oil temp is absent |
| `1615` | `Fuel Flow Engine Torque (Nm)` | Independent fuel-flow engine torque cross-check vs. CAN `901` |

### Dodge 8HP70 Gear Ratios & Shift-Drop Reference
| Gear | Ratio | Upshift Ratio Drop | Notes |
| :--- | :---: | :---: | :--- |
| `1` | `4.714` | `1 -> 2`: **`33.3%`** | Large drop — benefits from shifting slightly past peak HP |
| `2` | `3.143` | `2 -> 3`: **`33.0%`** | Large drop — benefits from shifting slightly past peak HP |
| `3` | `2.106` | `3 -> 4`: `20.8%` | Tight drop — shift closer to peak HP |
| `4` | `1.667` | `4 -> 5`: `22.9%` | Tight drop |
| `5` | `1.285` | `5 -> 6`: `22.2%` | Tight drop — avoid creeping close to rev limiter |
| `6` | `1.000` | `6 -> 7`: `16.1%` | Very tight — keep safely below rev limiter / valve spring float |
| `7` / `8` | `0.839` / `0.667` | — | Highway overdrive gears |

- **`Shiftcut Retard Angle` Sign Convention:** Enter **positive** degrees (`10`, `15`, `20`). MaxxECU subtracts positive values from base ignition timing during active shiftcut and ramps back cleanly via `Shiftcut Retard BackTime`.

---

## 7. DBW Idle, Fan-by-VSS & Cruise Control RT-Data IDs

| Channel ID | MTune Name | Notes |
| :--- | :--- | :--- |
| `151` / `152` / `153` | `Idle PID P` / `I` / `D` | Watch `I` burying at `-350..-500` when `RadFan`/`AC` open-loop adders are active while rolling |
| `204` / `206` | `Main throttle 1 position` / `Main pedal position` | DBW idle blade maps linearly: `DBW_Min + (AirDuty/100) * (DBW_Max - DBW_Min)` |
| `411` / `702` | `GPO out 3 (Radiator Fan 1)` / `AC Active` | Common auxiliary load triggers; `411` can drive `IdleCtrl User Duty Adjust` Y-axis |
| `524` | `Internal out 1 (Gear Idle)` | `0`=Park/Neutral, `1`=In-Gear row selector for `Idle OpenloopDutyTable` |
| `570` / `571` | `CruiseCtrl Locked Speed` / `Filtered Speed` | `571` quantizes in `~1 km/h` steps — keep Cruise `D Gain` moderate to prevent twitchiness |
| `595`–`599` | `CruiseCtrl P/I/D Term`, `Target Pos`, `State` | `Target Pos [598]` drives DBW blade `1:1`; must exceed DBW idle floor before blade opens |

- **Legacy `Idle AntiStall Enable`:** Deprecated in MTune `1.116+`; idle dip spark rescue is handled natively by `IdleLockAngle Table` (`IdleLockAngle Table Enable = 1`).

---

## 8. Safe `.MaxxECU-save` XML Editing Rules

1. Always replace `encoding="utf-16"` with `encoding="utf-8"` only in memory when parsing via `[xml]`; write the output file back with the original `<?xml version="1.0" encoding="utf-16"?>` header using **UTF-8 without BOM** (`New-Object System.Text.UTF8Encoding($false)`) and original CRLF line endings.
2. In 2D `<DynamicTableData XSize="Nx" YSize="Ny">`, rows are separated by newlines (`Ny` lines, top = `Y[0]`) with `Nx` comma-separated values per line.
3. In .NET regex replacements, always use `${1}` / `${2}` (never `$1` before digits, which parses as group `$10`!).
4. Always re-parse the saved `.MaxxECU-save` as XML and print a complete node-by-node XML diff vs. the previous revision to verify zero unintended edits before handing it to the user.

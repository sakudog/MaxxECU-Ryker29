# Vehicle Configuration Profile (Universal MaxxECU Intake)

Fill out the template below and paste it into your first Antigravity chat alongside your **`.MaxxECU-save`** and baseline **`.MaxxECU-Zip-log`**.

> **How Auto-Validation Works:** The `maxxecu-mtune-tuning` skill automatically cross-checks your profile against your live `.MaxxECU-save` file (cylinders, displacement, NA vs. boosted load axis, injector flow & deadtimes, fuel-pressure compensation mode, single vs. dual O2, DBW vs. IACV, knock bore size, fan output mode, and CAN transmission mode) and flags any mismatches **before** making tuning recommendations.

---

## Copy-Paste Blank Template

```markdown
### Vehicle Profile
- **Chassis & Weight (w/ driver):** [e.g., 1994 Toyota Supra MK4 (3,550 lbs) / 1997 OBS Chevy C1500 (3,950 lbs)]
- **Primary Use:** [Street / Track / Drag / Towing / Drift]

### 1. Engine Configuration
- **Engine & Displacement:** [e.g., 2JZ-GTE 3.0L I6 / LS 6.0L V8 / K24 2.4L I4]
- **Aspiration:** [NA / Single Turbo (model & wastegate spring) / Twin Turbo / Supercharger (type & target psi)]
- **Internal Specs:** [Bore × Stroke, Compression Ratio, Stock vs. Forged internals]
- **Valvetrain & Breathing:** [Camshaft specs @ .050" / lift / LSA, Heads, Intake Manifold, Throttle Body (DBW or Cable + IACV)]
- **Target Redline / Rev Limit:** [e.g., 7,500 RPM / 6,500 RPM]

### 2. Fuel System Configuration
- **Fuel Grade / Flex Fuel:** [91 oct / 93 oct / E85 / Flex Fuel sensor installed?]
- **Injectors:** [Brand, model, rated flow cc/min @ 3 bar]
- **Fuel Pump(s) & Regulator:** [Pump model(s), base pressure (e.g., 43.5 or 58 psi), 1:1 manifold-referenced FPR vs. fixed returnless, fuel pressure sensor installed?]
- **Wideband O2 Setup:** [Single or Dual-bank wideband, sensor model(s)]

### 3. Exhaust System Configuration
- **Manifold / Headers:** [Turbo manifold & downpipe size / Long-tube header primary size]
- **Catalytic Converters:** [High-flow cats (brand) / OEM cats / Catless] *(Critical for shift-cut, rev-limiter, and overrun safety!)*
- **Wideband Location:** [Pre-cat collector / Downpipe ~18" post-turbo / Post-cat]

### 4. Transmission Configuration
- **Transmission Type:** [Manual (e.g., V160 / T56 / CD009) / Dodge or BMW ZF 8HP70-8HP90 CAN / GM 4L80E / DCT / DSG / TH400]
- **Clutch / Torque Converter:** [Clutch type OR converter stall RPM & lockup type]
- **Shift Control:** [Full manual / OEM CAN TCU / MaxxECU-controlled solenoids / Paddles]

### 5. Rear Gear & Driveline
- **Final Drive / Rear Gear Ratio:** [e.g., 3.13 / 3.23 / 3.73 / 4.10]
- **Rear Tire Size / Diameter:** [e.g., 285/35R18 (~25.9") / 275/55R20 (~31.9")]

### 6. Cooling Fans, A/C & Warmup Rules
- **Fan Control Type:** [PWM Solid-State Soft-Start (e.g., OEM brushless/Volvo/C6 module) **OR** On/Off Relay-Switched (Single or Dual)]
- **Fan On/Off Temps & Thermostat:** [e.g., 180°F or 190°F thermostat; Fan 1 @ 195°F, Fan 2 @ 205°F]
- **A/C & Alternator:** [A/C connected to ECU? Alternator amperage / known voltage drop on fan engagement?]
- **Full-Warmup Rule for VE Tuning:** [e.g., CLT >= 80°C AND Oil/Trans Temp >= 120°F (or 15 min drive if no oil/trans sensor)]
```

---

## Filled-In Reference Examples

### Example A — Turbo Toyota Supra (2JZ-GTE, Manual, PWM Fan, Flex Fuel)
- **Chassis & Weight:** 1994 Toyota Supra MK4, ~3,550 lbs w/ driver (Street / Roll Racing)
- **Engine:** 2JZ-GTE 3.0L I6, Single BorgWarner S366SX-E (14 psi gate spring, targeting 22 psi pump / 30 psi E85), 8.5:1 stock bottom end, GSC S1 cams (`269/269`), stock intake, cable 80mm TB + OEM ISCV, 7,500 RPM redline
- **Fuel:** Flex Fuel (93 oct / E85, Continental ethanol sensor), ID1300X2 (`1340 cc/min` @ 3 bar), dual Walbro 450s, Aeromotive 1:1 boost-referenced FPR @ 43.5 psi base + fuel pressure sensor, single LSU 4.9 wideband
- **Exhaust:** T4 divided manifold, 3.5" catless downpipe, wideband 20" post-turbine
- **Transmission:** Getrag V160 6-speed manual, twin-disc organic clutch
- **Rear Gear / Tires:** 3.13 rear gear, 295/35R18 (~26.1")
- **Fans / Electrical:** Dual brushless **PWM soft-start** fans driven by MaxxECU `Radiatorfan PWM`, A/C active, 130A alternator, 180°F thermostat; warm gate `CLT >= 80°C` & `Oil Temp >= 75°C`

### Example B — LS-Swapped OBS Truck (6.0L NA, Dodge 8HP70, Relay Fans, DBW)
- **Chassis & Weight:** 1997 OBS GMC/Chevy Truck, ~3,900 lbs w/ driver (Street Cruiser)
- **Engine:** 6.0L LS iron block (4.000" bore × 3.622" stroke), NA, 10.5:1 CR, rectangular-port heads, ported truck intake, 90mm DBW E-Throttle, `212/22X` 107° LSA cam, 6,800 RPM rev limit
- **Fuel:** 93 octane pump gas, ID1050XD (`1077 cc/min` @ 3 bar), Walbro 340 LPH, 58 psi base w/ fuel pressure sensor, dual pre-cat widebands
- **Exhaust:** 1-7/8" long-tube headers + high-flow GESI catalytic converters, dual O2 in pre-cat collectors
- **Transmission:** Dodge ZF 8HP70 8-speed automatic (OEM ZF TCU over CAN), 2,800 RPM stall converter
- **Rear Gear / Tires:** 3.23 rear gear, 28" rear tire
- **Fans / Electrical:** Dual **on/off relay-switched** electric fans (heavy startup inrush — drops battery to ~12.2V on relay close), A/C active, 190°F thermostat; warm gate `CLT >= 80°C` & `Trans Oil Temp >= 120°F`

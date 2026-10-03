# AtlasOS Ship

Ship-control edition of AtlasOS for CC:Tweaked.

**Current stable release:** `0.5.5 — Constellation Navigation`

AtlasOS Ship is a server + Pocket Computer flight-control system for Minecraft vessels. It provides manual control, assisted flight, autopilot/navigation, safety interlocks, external telemetry, pairing, radio integration, and a guided hardware commissioning flow.

The software runs on Advanced Computers.

## Quick install

On the onboard Advanced Computer:

```text
pastebin run vzfpu2uf
```

Choose the `server` role during first-run setup.

The installer will ask for:

- vessel name;
- server computer label;
- temporary six-digit pairing PIN.

Write down the onboard server **computer ID** and pairing PIN.

Install the same release on the Pocket Computer:

```text
pastebin run vzfpu2uf
```

Choose the `pocket` role, then enter:

- onboard server computer ID;
- six-digit pairing PIN;
- optional operator PIN.

The Pocket Computer needs working wireless networking.

After the onboard server reboots, stop AtlasOS with `Ctrl+T` before doing maintenance or hardware setup.

Then run:

```text
atlasctl ship setup
```

If you only remember one setup command, remember that one.

---

## What `atlasctl ship setup` does

The guided ship setup walks through the complete commissioning path:

1. onboard computer + Redstone Relays;
2. Redstone Links + propulsion fail-safe;
3. sensors + rudder;
4. navigation + GPS;
5. flight assist;
6. final readiness checks.

You can rerun it at any time:

```text
atlasctl ship setup
```

To see the current state without reopening the guide:

```text
atlasctl ship status
```

---

# Hardware setup

## 1. Onboard computer and Redstone Relays

The recommended layout uses two CC:Tweaked Redstone Relays:

```text
             Wireless Modem
                  [M]
                   |
  POWER Relay [P]-[SERVER]-[S] STEERING Relay
```

Direct attachment is simplest, but a wired modem network also works.

Before mapping the relays, **disconnect transmitting Redstone Links**. The mapper pulses relay faces so that each physical output can be identified without assuming relay orientation.

Start the mapper directly with:

```text
atlasctl io setup
```

The normal output map contains:

### Power relay

- `propulsionPermit` — digital
- `lift` — analogue
- `thrust` — analogue
- `reverse` — digital
- `gyro` — digital

### Steering relay

- `steeringEnable` — digital
- `rudderLeft` — digital
- `rudderRight` — digital

After mapping, AtlasOS stores the actual relay peripheral and side used for every output.

View the current map with:

```text
atlasctl io map
```

---

## 2. Redstone Links and propulsion fail-safe

Once the relay map exists, place transmitting Redstone Links against the mapped relay faces and give them the same frequency pairs as the matching receivers on the vessel mechanisms.

The **propulsion permit must be fail-safe**.

Required behavior:

```text
No permit  -> clutch powered/locked -> propulsion CUT
Permit     -> clutch released       -> propulsion READY
```

A dead computer, dead relay, disconnected control link, or crashed program must therefore remove propulsion rather than leave stale thrust active.

Test outputs individually before commissioning:

```text
atlasctl io test propulsionPermit
atlasctl io test lift 7
atlasctl io test thrust 7
atlasctl io test reverse
atlasctl io test gyro
atlasctl io test steeringEnable
atlasctl io test rudderLeft
atlasctl io test rudderRight
```

Then verify the map:

```text
atlasctl io check
```

When every mapped output is correct and returns to SAFE:

```text
atlasctl io commission
```

Commissioning unlocks arming, but does **not** arm the vessel immediately.

---

## 3. Sensors and steering hardware

Connect the flight instrumentation to the onboard server's peripheral network.

The current setup expects:

- Navigation Table
- Gimbal Sensor
- Altitude Sensor
- Velocity Sensor X
- Velocity Sensor Y
- Velocity Sensor Z
- Physical Steering Wheel
- Rudder Mechanical or Swivel Bearing
- Steering Rotation Speed Controller
- Physics Assembler — optional

Run:

```text
atlasctl sensors setup
```

The setup process records the relevant peripherals and vessel body/nose orientation.

The currently validated and recommended steering-actuator baseline is:

```text
16 RPM
```

After mapping:

```text
atlasctl sensors check
atlasctl sensors calibrate
atlasctl sensors commission
```

For live sensor output:

```text
atlasctl sensors monitor
```

---

# Navigation

AtlasOS Ship supports two navigation-position backends.

## Atlas Navigation Compatibility + Navigation Table

When Atlas Navigation Compatibility is available, AtlasOS can use the vessel's Navigation Table directly for navigation target and position integration.

With navigation source set to `AUTO`, this provider is preferred when available.

Atlas Navigation Compatibility is a server-side mod that may not work on versions beside NeoForge 1.21.1

If it doesn't work, you can modify the source of it in any way, so feel free to fix, port, or otherwise change it.

The mod jar and source can be found in:

```text
nav-compat/
```

## CC:Tweaked GPS fallback

If Navigation Table integration is unavailable, AtlasOS can use standard CC:Tweaked GPS.

A recommended constellation is four stationary wireless-modem computers at separated, known world coordinates.

On each GPS host:

```text
gps host <x> <y> <z>
```

On the vessel, verify that a fix can be obtained:

```text
gps locate
```

`AUTO` navigation behavior is:

```text
Navigation Table integration available -> use Navigation Table
otherwise GPS fix available            -> use GPS
otherwise                               -> no navigation provider
```

The selected provider is not switched underneath an armed vessel.

Manual flight can still be used without a navigation-position provider, but navigation and FULL AUTO must not be commissioned until Navigation Table integration or GPS is working.

The guided setup checks both providers automatically:

```text
atlasctl ship setup
```

---

# Flight assist

Flight assist closes the loop around:

- rudder control;
- heading hold;
- navigation steering;
- altitude control;
- physical wheel override.

Only configure flight assist after I/O and sensors are mapped and the rudder has been calibrated.

Run:

```text
atlasctl assist setup
atlasctl assist check
atlasctl assist commission
```

Flight-assist commissioning is a ground test. Propulsion remains locked during commissioning.

Current tuning values can be inspected with:

```text
atlasctl assist tune show
```

Individual tuning values can be changed while SAFE with:

```text
atlasctl assist tune set <key> <value>
```

Restart AtlasOS before the next flight test after changing flight-assist tuning.

---

# Pocket Computer

AtlasOS Ship uses a paired Pocket Computer as the normal flight-control interface.

The Pocket provides:

- manual flight control;
- assisted-flight controls;
- navigation and FULL AUTO controls;
- radio;
- system/configuration access;
- server telemetry and SAFE state.

The onboard server remains authoritative over flight hardware and safety state.

To reopen pairing on the onboard server:

```text
atlasctl pair on
```

Or provide a specific six-digit PIN:

```text
atlasctl pair on 123456
```

To close pairing:

```text
atlasctl pair off
```

---

# External telemetry

AtlasOS can render live ship telemetry to an attached compatible monitor/display.

The current telemetry renderer supports:

- standard CC:Tweaked monitors;
- adaptive monitor sizing;
- incremental framebuffer updates to avoid visible full-screen rebuilds.

Telemetry is read-only. Normal vessel control remains on the Pocket Computer.

---

# First-flight checklist

Before the first real flight, verify all of the following:

1. SAFE physically removes propulsion.
2. The physical steering wheel has authority while SAFE.
3. Every mapped I/O channel was tested individually.
4. Sensors report healthy values.
5. Rudder calibration is correct.
6. Flight assist passes `atlasctl assist check`.
7. Pocket pairing is stable.
8. Loss of Pocket heartbeat causes the expected safe behavior.
9. The selected navigation source reports READY.
10. Assisted steering is tested before FULL AUTO.

Useful status commands:

```text
atlasctl status
atlasctl ship status
atlasctl diagnostics
atlasctl io check
atlasctl sensors check
atlasctl assist check
```

---

# Updating AtlasOS

Run the same bootstrap again:

```text
pastebin run vzfpu2uf
```

The GitHub-backed installer resolves the current stable channel, downloads the release manifest and package, verifies managed files with SHA-256, stages the update, and applies it transactionally.

Machine-owned persistent state is preserved across normal updates, including AtlasOS configuration and pairing state.

The repository is the authoritative release source, Pastebin is only the small easy installation.

---

# Useful `atlasctl` commands

```text
atlasctl status
atlasctl diagnostics
atlasctl logs
atlasctl setup

atlasctl ship setup
atlasctl ship status

atlasctl pair on [six-digit-pin]
atlasctl pair off

atlasctl safe

atlasctl io setup
atlasctl io map
atlasctl io check
atlasctl io test
atlasctl io commission
atlasctl io uncommission

atlasctl sensors setup
atlasctl sensors map
atlasctl sensors check
atlasctl sensors monitor
atlasctl sensors calibrate
atlasctl sensors commission
atlasctl sensors uncommission

atlasctl assist setup
atlasctl assist map
atlasctl assist check
atlasctl assist commission
atlasctl assist uncommission
atlasctl assist tune show
atlasctl assist tune set <key> <value>

atlasctl reboot
```

Stop AtlasOS with `Ctrl+T` before server maintenance.

---

# Installation architecture

The public install path is:

```text
Pastebin bootstrap
        |
        v
GitHub stable/dev channel
        |
        v
release manifest
        |
        v
download + SHA-256 verification
        |
        v
staging
        |
        v
transactional install/update
        |
        v
AtlasOS
```

Release payloads, manifests, hashes, channels, and installer logic live in this repository.

The Pastebin code is:

```text
vzfpu2uf
```

---

# FlightOS relationship

AtlasOS Ship is an independent project and is **not a FlightOS fork**.

The original AtlasOS flight-control system predates its use of FlightOS as a reference. Later UI and architecture work used FlightOS as design inspiration in some areas, including parts of the monitor telemetry presentation.

AtlasOS retains its own runtime, Pocket Computer control model, safety/session architecture, hardware commissioning flow, navigation stack, and release/update infrastructure.

---

# Current release

## AtlasOS Ship 0.5.5 — Constellation Navigation

0.5.5 is the current stable release.

Major capabilities include:

- manual vessel control;
- SAFE/ARM authority and fail-safe output handling;
- paired Pocket Computer control;
- heading and altitude assistance;
- destination navigation;
- FULL AUTO steering and thrust control;
- reverse-braking arrival behavior;
- CC:Tweaked GPS fallback;
- adaptive external telemetry;
- guided ship hardware commissioning;
- GitHub-backed verified installation and updates.

Stable channel metadata is stored under:

```text
channels/stable.json
```

Development channel metadata is stored under:

```text
channels/dev.json
```

Published release packages live under:

```text
releases/
```

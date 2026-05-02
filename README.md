<p align="center">
  <img src="priv/static/images/logo.svg" alt="packheavy logo" width="128" />
</p>

# packheavy

> ⚠️ **Single-user only.** Sign-up is disabled in the router and the
> AshAuthentication password flows are stubbed. The deployed instance
> uses Auth0 with a hardcoded email allowlist. Don't open this to
> anyone but yourself.

A personal hiking gear inventory and trip planner. Catalogue every item
you own, bundle items into reusable **kits**, then plan **trips** that
pull from kits and individual items, upload GPX files per leg, and
produce a printable hike handout (with sunrise/sunset, calorie targets,
emergency contacts and PLB IDs) to email to your emergency contact
before you set off.

Built with [Phoenix LiveView][lv] and the [Ash framework][ash].

[lv]: https://hexdocs.pm/phoenix_live_view
[ash]: https://hexdocs.pm/ash

## Features

### Inventory
- Items grouped by category (Packs, Shelter, Sleep, Clothing, Cooking,
  Water, Food, Electronics, Camera lenses, Powerbanks, Batteries,
  Cables, First aid, Hygiene, Containers, Tools, Other).
- Each item has a brand (autocompleted from prior entries), title,
  weight, on-hand qty, and free-form notes.
- Category-specific data captured via an Ash union + embedded
  resources stored as `jsonb` (so adding a new category needs no DB
  migration):
  - **Packs**: volume in litres
  - **Water containers**: capacity in ml
  - **Food**: kcal per serving + serving label (kcal/g surfaces in lists)
  - **Electronics**: power source — built-in rechargeable (with charger
    cable type) **or** replaceable batteries (with battery type)
  - **Powerbanks**: capacity (mAh) + USB ports
  - **Batteries**: a battery-type FK (the type's `rechargeable` flag
    drives the pre-departure charged checklist)
  - **Camera lenses**: prime/zoom, focal range, max aperture range
  - **Cables**: cable-type FK
  - "Simple" categories (Shelter, Sleep, …) carry only the discriminator
- User-editable `CableType` and `BatteryType` lookup tables, seeded
  with common values.

### Kits
- Named, reusable bundles of items + qty per item.
- Picker is the same modal LiveComponent the trip planner uses —
  category-grouped, searchable, multi-select with per-item qty.

### Trips
A trip has a name, start/end dates, area, park / route URLs, a state
machine (`draft → packing → complete`), an opaque share token, and
free-form Markdown notes.

The trip workspace is split across two routes:

- **`/trips/:id` — Details.** The trip's metadata: dates, area, park &
  route URLs, departure & return ISO timestamps, escalation criteria,
  Markdown notes, the hiking group (one leader + 0..N members with
  phones, satellite SMS, location-tracker URL/password, **PLB Hex ID +
  serial**, weight, age/training notes), and the emergency / daily
  check-in contacts. Public share toggle lives here.

- **`/trips/:id/pack` — Route / Plan / Pack / Complete tabs.**

  - **Route.** GPX-driven multi-leg planner. Drag-and-drop a `.gpx`
    file per leg, give it a name, day-of-trip, walking pace (km/h),
    sidequest flag, and Markdown notes. Legs are grouped by day and
    each day shows its distance, walking time, and sunrise/sunset/
    daylight (computed from the leg's start lat/lon and date via the
    `astro` library). Side-by-side Komoot-style layout: a Leaflet
    +OpenTopoMap on the left with all legs as coloured polylines, the
    per-day leg cards on the right with a per-leg gradient-shaded SVG
    elevation chart. Hover the chart and the corresponding point
    pulses on the map (and vice versa).

    - **Walking time** is Naismith with load: `distance/pace +
      elevation/600`.
    - **Calories** use the **Pandolf load-carriage equation** (1977),
      with terrain factor η=1.2 (trail), so we get a metabolic rate in
      watts → kcal that includes baseline + load-carry + speed + grade
      effects rather than a flat MET × hours estimate.
    - **Carry modes per item**: each TripItem rides as `worn`,
      `day_pack`, or `main_pack`, and a single inventory item can be
      split across modes (e.g. 2 water bottles in main pack + 1 in day
      pack). **Sidequest** legs only count `worn + day_pack` items
      toward their calorie estimate, so summit out-and-backs from a
      base camp don't get punished by your full pack weight.

  - **Plan.** Items grouped by category with section weight subtotals.
    Add/edit items via the picker (caps each item's qty at `Item.qty −
    sum already on this trip`); add a kit which expands into TripItems
    with a `TripKit` breadcrumb. Top of the tab: distance, elevation
    gain, walking time, pack weight (full + sidequest split), calories
    carried, **active calorie burn (Pandolf walking)**, **resting
    calorie burn (BMR × non-walking trip hours)**, surplus/deficit vs
    food carried, plus power and validation errors/warnings (missing
    chargers, missing spare batteries).

  - **Pack.** Category-grouped checklist with `packed`, `charged`
    (rechargeable items only) and `tested` checkboxes per item, and a
    per-section progress count.

  - **Complete.** State transition that decrements `Item.qty` on each
    Food item by the trip qty (consumables come off the inventory).

### Public share + private handout
- **Public share** (`/share/trip/:token`): read-only view, no contacts,
  no PLB info. Same map + per-leg cards + Pack list. Token is enabled/
  rotated/disabled from the Details page.
- **Private handout** (`/trips/:id/handout`): the same content **plus**
  hiker phones, satellite SMS, tracker URL+password, PLB IDs, emergency
  contacts, daily check-in contacts. The page is tuned for **Cmd/Ctrl+P
  → Save as PDF**: `@media print` overrides force light theme, hide
  navigation/buttons, force fresh pages around the headline-numbers
  tile + map combo, glue day headings to their first leg via
  `break-after: avoid`, keep leg cards together via `break-inside:
  avoid`, and render real `<a href>` (and `tel:`) links so the saved
  PDF has clickable hyperlinks for park/route URLs and phone numbers.
  Markdown notes ship through Earmark which already produces real
  anchors.

### Backup / restore
`/backup` exports the full user state (items, kits, trips, hikers,
contacts, legs with parsed track jsonb) as a single JSON file, and
imports the same shape back. Useful before risky migrations.

### Profile
`/profile` carries the user's defaults — name, phone, satellite SMS,
location-tracker URL/password, **PLB Hex ID + serial**, default hiker
weight, default hiker notes. These are copied into the leader
TripHiker record when a new trip is created (independently editable
afterwards so a profile change doesn't retroactively rewrite past
trips).

## Architecture

```
Packheavy.Accounts             AshAuthentication users + tokens
Packheavy.Inventory            CableType, BatteryType, Item (union),
                                 Kit, KitItem
Packheavy.Trips                Trip (state machine), TripItem, TripKit
                                 (breadcrumb), TripHiker, TripContact,
                                 TripLeg
```

### Polymorphic Item

`Inventory.Item` has an `Ash.Type.Union` `category_data` with a tagged
variant per category. Each variant is a `data_layer: :embedded` Ash
resource (`Item.Electronic`, `Item.Pack`, `Item.Food`, …). Simple
categories (Shelter, Sleep, …) share an `Item.Simple` macro to cut
boilerplate. `category_data` is stored as `jsonb` so adding a new
category requires no DB migration — just a new embedded module + an
entry in the union constraints + a `+` button label.

### Kit expansion is at add-time

When a kit is added to a trip, each `KitItem` is copied into a fresh
`TripItem` with `source: :kit, source_kit_id: kit.id` and a `TripKit`
breadcrumb row. After that, the trip owns its copies — later edits to
the kit don't propagate. Deliberate trade-off: lets you tweak in-flight
trips without mutating the kit template.

### Per-trip qty enforcement

`Packheavy.Trips.Changes.EnforceItemQtyAvailable` runs on TripItem
create/update and errors when `requested + sum(other TripItems for the
same item) > Item.qty`. Cross-trip reservation is not enforced — that's
a deferred warn-only follow-up.

### TripLeg is the GPX unit

`Packheavy.Trips.TripLeg` stores `name, position, day, sidequest,
pace_kmh, distance_m, elevation_gain_m, point_count, track` (a parsed
canonical track `[%{lat, lon, ele, d}]` jsonb), and Markdown notes.
`Packheavy.Gpx` parses uploaded `.gpx` files (regex-based for the
prototype — extracts `<trkpt>` lat/lon and `<ele>`, computes Haversine
distance and positive-delta elevation gain). The original GPX file is
not stored; the parsed track is the source of truth.

### Validation report

`Packheavy.Trips.Calculations.ValidationReport` is a custom Ash
calculation on `Trip` that loads `trip_items: [item: …]`, `trip_legs`,
and `trip_hikers` once and produces:

```elixir
%{
  totals: %{
    weight_g, food_weight_g, water_weight_g,
    calories, calories_burned_active, calories_burned_resting,
    calories_burned_total,
    water_ml, pack_volume_l, power_mah, usb_ports, electronics,
    time_h, loads
  },
  errors:   [%{kind: :missing_charger, ...}],
  warnings: [%{kind: :no_spare_battery, ...}]
}
```

Loaded only on the trip pages. Component re-use (`weight_breakdown`,
`day_summary`) keeps planner / public / handout in lockstep.

### Trip completion decrements food

`Trip.complete` is an `update` action wired through `AshStateMachine`'s
`transition_state(:complete)`. An `after_action` reloads `trip_items:
[item: …]`, filters Food union variants, and calls `Item.decrement_qty`
clamped at 0.

### Calorie estimates

- **Active (walking)**: Pandolf (1977). Metabolic rate in watts =
  `1.5W + 2.0(W+L)(L/W)² + η(W+L)(1.5V² + 0.35VG)`. η = 1.2 (trail).
  Computed per leg using the leg's average grade and the actual walking
  speed implied by Naismith time. Watts × hours × 0.8604 → kcal.
- **Resting**: BMR (~1 kcal/kg/h × leader weight × non-walking trip
  hours, derived from `start_date`/`end_date` and the sum of leg
  walking times).
- **Total** is active + resting and drives the food carried vs burn
  surplus/deficit on the Plan tab.

### Sunrise / sunset

`Packheavy.Trips.Helpers.day_sun/2` uses the [`astro`][astro] library
with [`tzdata`][tzdata] as the time-zone database. Picks a
representative lat/lon from the day's first leg's first trackpoint,
computes sunrise/sunset for that date, returns daylight hours. Timezone
is hardcoded to `Australia/Hobart` for now (single-user app, all
current trips are in Tassie); easy to swap to a per-trip attr if that
ever changes.

[astro]: https://hex.pm/packages/astro
[tzdata]: https://hex.pm/packages/tzdata

## Stack

- **Elixir 1.19** / **Erlang/OTP 28**
- **Phoenix 1.8** + **Phoenix LiveView 1.1** (no JSON API)
- **Ash 3.x**, **AshPostgres**, **AshPhoenix**, **AshAuthentication**,
  **AshStateMachine**
- **Postgres 16**
- **Tailwind 4** + **daisyUI 5**
- **Leaflet 1.9** + **OpenTopoMap** tiles (CDN-loaded on demand)
- **Earmark** (Markdown rendering for trip + leg notes)
- **astro** + **tzdata** (sunrise/sunset)

## Routes

| URL | LiveView | Purpose |
|---|---|---|
| `/dashboard` | `DashboardLive` | landing |
| `/items` | `ItemLive.Index` | inventory by category |
| `/kits`, `/kits/:id` | `KitLive.Index` / `Show` | reusable bundles |
| `/cable-types`, `/battery-types` | lookup table editors | |
| `/trips`, `/trips/:id` | `TripLive.Index` / `TripDetailsLive` | list + details |
| `/trips/:id/pack` | `TripLive.Show` | Route / Plan / Pack / Complete |
| `/trips/:id/handout` | `HandoutLive` | private printable handout |
| `/share/trip/:token` | `PublicTripLive` | public read-only share |
| `/gpx` | `GpxLive` | scratchpad GPX viewer |
| `/backup` | `BackupLive` | export / import JSON |
| `/profile` | `ProfileLive` | user defaults |

## Getting started

Prerequisites: Elixir 1.19+, Erlang/OTP 28+, Postgres 16 running locally.

```bash
mix setup                              # deps.get + ash.setup + assets + seeds
mix run priv/scripts/create_user.exs   # seeds ben@local / password123
mix phx.server                         # http://localhost:4000
```

Sign in, then walk through:

1. Profile (`/profile`): set your phone, satellite SMS, tracker URL,
   PLB Hex ID + serial, default hiker weight.
2. Cable & battery types (`/cable-types`, `/battery-types`).
3. Inventory (`/items`).
4. Kits (`/kits`).
5. New trip (`/trips`): set dates and area on Details, drop in
   members + emergency / daily check-in contacts. Move to `/pack`,
   upload a GPX file per leg on **Route**, dial in pace per leg, add
   items via the picker on **Plan**, validate (carried calories vs
   burn, missing chargers, missing spare batteries), pack, complete.
6. Open `/trips/:id/handout` and `Cmd+P → Save as PDF` for the offline
   contact-rich handout. Or enable sharing on Details and send the
   `/share/trip/:token` URL.

## Operations

```sh
# After any Ash resource change:
mix ash.codegen <name> --auto-name && mix ecto.migrate

# Reset DB (drop + create + migrate + seeds):
mix ecto.reset

# Smoke-test the create / validate / complete flow without the dev server:
mix run priv/scripts/smoke.exs
```

Release migrate (`Packheavy.Release.migrate`) runs Ecto migrations
and a small data fixup that recomputes `TripLeg.elevation_gain_m`
from the stored track when the value drifts (idempotent — no-ops on
subsequent boots).

## Deploy

The app deploys to AWS ECS Fargate behind an ALB with managed Postgres
on RDS, all orchestrated by Pulumi (TypeScript). Auth0 fronts login —
a post-login Action gates access to a hardcoded email allowlist. Pulumi
state lives in S3 with KMS encryption. See
[`infra/README.md`](infra/README.md) for the runbook (first-time
setup, image build/push, hibernation).

## Repo layout

```
lib/packheavy/
  accounts.ex                          Ash domain
  accounts/user.ex                     AshAuthentication user + profile
  inventory.ex                         Ash domain
  inventory/item.ex                    union over inventory/item/*.ex
  inventory/item/{electronic,pack,food,water,power,battery,cable,
                  camera_lens,simple,other}.ex
  inventory/{cable_type,battery_type,kit,kit_item}.ex
  trips.ex                             Ash domain
  trips/trip.ex                        state machine + food decrement
  trips/{trip_item,trip_kit,trip_hiker,trip_contact,trip_leg}.ex
  trips/calculations/validation_report.ex
  trips/changes/enforce_item_qty_available.ex
  trips/helpers.ex                     pace / time / Pandolf / sun
  gpx.ex                               GPX parser + distance/gain
  backup.ex                            export / import JSON
  release.ex                           release-time migrate hook

lib/packheavy_web/live/
  dashboard_live.ex
  item_live/index.ex                   category-grouped inventory
  kit_live/{index,show}.ex
  trip_live/index.ex                   list, create
  trip_details_live.ex                 /trips/:id details + sharing
  trip_live/show.ex                    Route / Plan / Pack / Complete
  public_trip_live.ex                  /share/trip/:token
  handout_live.ex                      /trips/:id/handout (printable)
  cable_type_live/index.ex
  battery_type_live/index.ex
  profile_live.ex
  backup_live.ex
  gpx_live.ex                          scratchpad GPX viewer
  components/item_picker.ex            shared modal picker

assets/js/hooks/
  route_map.js                         Leaflet multi-leg map + hover
  leg_chart.js                         per-leg elevation crosshair

infra/                                 Pulumi (TypeScript) for AWS
priv/repo/migrations/                  Ash-codegen migrations
priv/resource_snapshots/               Ash codegen snapshots
priv/scripts/                          smoke / seed / fixup scripts
```

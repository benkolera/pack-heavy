# packheavy

> ⚠️ **Local-only — do not deploy this anywhere public.**
> The bootstrap script (`priv/scripts/create_user.exs`) seeds a hardcoded
> account (`ben@local` / `password123`), the password-reset / magic-link
> auth flows are stubbed out, secrets in `config/runtime.exs` aren't
> production-ready, and there's no rate limiting, email delivery, HTTPS
> enforcement, or any of the other hardening you'd want for a multi-user
> deployment. Run on `localhost` only until that gets sorted.

A personal hiking gear inventory and trip planner. Catalogue every item you
own (with weight, brand, category-specific data), bundle them into reusable
**kits**, and compose **trips** that pull from kits and individual items.
The trip planner gives you a weight breakdown (base / +food / +food+water),
food density (kcal/g and kcal/day), validation against missing chargers,
and a per-departure packed/charged checklist.

Built with [Phoenix LiveView][lv] and the [Ash framework][ash].

[lv]: https://hexdocs.pm/phoenix_live_view
[ash]: https://hexdocs.pm/ash

## Screenshots

### Desktop

| | |
|---|---|
| **Dashboard** | **Trips list** |
| ![Dashboard](docs/screenshots/desktop-dashboard.png) | ![Trips list](docs/screenshots/desktop-trips.png) |
| **Inventory** | **Kits list** |
| ![Inventory](docs/screenshots/desktop-items.png) | ![Kits](docs/screenshots/desktop-kits.png) |
| **Kit detail** | **Cable types** |
| ![Kit detail](docs/screenshots/desktop-kit-show.png) | ![Cable types](docs/screenshots/desktop-cable-types.png) |
| **Trip — plan** | **Trip — pack** |
| ![Trip plan](docs/screenshots/desktop-trip-plan.png) | ![Trip pack](docs/screenshots/desktop-trip-pack.png) |
| **Food (kcal/serve, kcal/g)** | **Pack — charged + packed** |
| ![Food category](docs/screenshots/desktop-items-food.png) | ![Pack electronics](docs/screenshots/desktop-trip-pack-electronics.png) |
| **Item picker (full-state editor)** | **Battery types** |
| ![Item picker](docs/screenshots/desktop-item-picker.png) | ![Battery types](docs/screenshots/desktop-battery-types.png) |

### Mobile

| | | |
|---|---|---|
| **Dashboard** | **Inventory** | **Trips** |
| ![Dashboard mobile](docs/screenshots/mobile-dashboard.png) | ![Inventory mobile](docs/screenshots/mobile-items.png) | ![Trips mobile](docs/screenshots/mobile-trips.png) |
| **Kits** | **Kit detail** | **Trip — plan** |
| ![Kits mobile](docs/screenshots/mobile-kits.png) | ![Kit detail mobile](docs/screenshots/mobile-kit-show.png) | ![Trip plan mobile](docs/screenshots/mobile-trip-plan.png) |
| **Trip — pack** | **Cable types** | **Battery types** |
| ![Trip pack mobile](docs/screenshots/mobile-trip-pack.png) | ![Cable types mobile](docs/screenshots/mobile-cable-types.png) | ![Battery types mobile](docs/screenshots/mobile-battery-types.png) |
| **Food (kcal/serve, kcal/g)** | **Pack — charged + packed** | **Item picker** |
| ![Food mobile](docs/screenshots/mobile-items-food.png) | ![Pack electronics mobile](docs/screenshots/mobile-trip-pack-electronics.png) | ![Item picker mobile](docs/screenshots/mobile-item-picker.png) |

## Features

### Inventory
- Items grouped by category (Packs, Shelter, Sleep, Clothing, Cooking, Water,
  Food, Electronics, Camera lenses, Powerbanks, Batteries, Cables, First aid,
  Hygiene, Containers, Tools, Other).
- Each item has a brand (with autocomplete from prior entries), title, weight
  in grams, an on-hand qty, and free-form notes.
- Category-specific data captured via an Ash `:union` attribute:
  - **Packs**: volume in litres
  - **Water containers**: capacity in ml
  - **Food**: kcal per serving + serving label (kcal/g surfaces in lists)
  - **Electronics**: power source — built-in rechargeable (with charger cable
    type) **or** replaceable batteries (with battery type and how many it takes)
  - **Powerbanks**: capacity (mAh) + USB ports
  - **Batteries**: a battery type FK (the type's `rechargeable` flag drives
    the pre-departure charged checklist)
  - **Camera lenses**: prime/zoom kind, focal length range, max aperture
    range (constant or variable)
  - **Cables**: cable type FK
  - The "simple" categories (Shelter, Sleep, etc.) only carry the discriminator
- User-editable **CableType** and **BatteryType** lookup tables, seeded with
  common values (USB-C, Micro-USB, Lightning, USB-A, Proprietary; AA, AAA,
  CR123A, CR2032, CR2016, 18650).

### Kits
- Named, reusable bundles of items + qty per item.
- Items are added/edited via the same modal picker the trip planner uses —
  category-grouped, searchable, multi-select with per-item qty.

### Trips
- A trip has a name, optional start/end dates, and an `AshStateMachine` state
  (`draft → packing → complete`).
- **Plan tab**: items grouped by category with section weight subtotals;
  add/edit items via the picker (caps each item's qty at `Item.qty − sum
  already on this trip`); also add a kit which expands into TripItems.
- **Validate tab**: weight breakdown (base / +food / +food+water with food
  weight per day), calorie totals (per trip, per day, average kcal/g across
  the food carried), water capacity, power; hard error if a built-in
  rechargeable electronic is missing its matching cable on the trip; soft
  warning if an electronic with replaceable batteries has no spare Battery
  item of the right type packed.
- **Pack tab**: category-grouped checklist with `packed` checkbox per item
  and `charged` checkbox for items that need it (built-in rechargeable
  electronics, powerbanks, and Battery items whose type is rechargeable);
  per-section progress count.
- **Complete tab**: marks the trip complete and decrements `Item.qty` on each
  Food item by the trip qty (consumables come off the inventory).

### Misc
- `@media print` styles tuned for **Cmd+P → Save as PDF** of the items page
  on a Mac browser — light background, no chrome, sections kept together.
- AshAuthentication password strategy is wired in but the app is single-user
  in practice (every resource is `change relate_actor(:user)` on create).

## Architecture

```
Packheavy.Accounts             AshAuthentication users + tokens
Packheavy.Inventory            CableType, BatteryType, Item (union), Kit, KitItem
Packheavy.Trips                Trip (state machine), TripItem, TripKit (breadcrumb)
```

### Polymorphic Item

`Inventory.Item` has an `Ash.Type.Union` attribute `category_data` with a
tagged variant per category. Each variant is a `data_layer: :embedded` Ash
resource (`Item.Electronic`, `Item.Pack`, `Item.Food`, …). The simple
categories that carry only a discriminator (`Shelter`, `Sleep`, etc.) share a
`Item.Simple` macro to cut boilerplate. The whole `category_data` is stored
as `jsonb` so adding a new category requires no DB migration — just a new
embedded module + a new entry in the union constraints + a `+` button label.

Embedded resources can't have Ash `belongs_to`, so foreign keys to
`CableType` and `BatteryType` live on the embedded structs as plain `:uuid`
attributes, resolved by the LiveView when it needs the names.

### Kit expansion at add-time

When a kit is added to a trip, each `KitItem` is copied into a fresh
`TripItem` row with `source: :kit, source_kit_id: kit.id`. After that, the
trip owns its copies — later edits to the kit don't propagate. A `TripKit`
row is also written as a breadcrumb. This is the deliberate trade — it lets
you tweak the trip without mutating the kit template, and avoids ambiguous
"shared state" between a planning trip and the kit it came from.

### Per-trip qty enforcement

`TripItem` create and update run a `Packheavy.Trips.Changes.EnforceItemQtyAvailable`
change that errors when `requested_qty + sum(other TripItems for the same item
on this trip) > Item.qty`. Cross-trip reservation is **not** enforced — two
draft trips can each claim the same item independently. That's a deferred
"warn-only" follow-up.

### Validation report

`Packheavy.Trips.Calculations.ValidationReport` is a custom Ash calculation
on `Trip` that loads `trip_items: [item: ...]` once and walks them in a
single reduce, producing:

```elixir
%{
  totals: %{weight_g, food_weight_g, water_weight_g, calories, water_ml,
            power_mah, usb_ports, electronics},
  errors:   [%{kind: :missing_charger, item_id, item_title, cable_type_id}, ...],
  warnings: [%{kind: :no_spare_battery, item_id, item_title, battery_type_id}, ...]
}
```

Loaded only on the trip detail page (Plan + Validate tabs). The breakdown
component (`weight_breakdown/1`) is shared between both tabs so the totals
stay in sync.

### Trip completion decrements food

`Trip.complete` is an `update` action wired through `AshStateMachine`'s
`transition_state(:complete)`. An `after_action` reloads the trip's items,
filters for Food union variants, and calls `Item.decrement_qty` for each —
a custom `update` action that clamps `Item.qty` at 0.

### `Item.qty` instead of per-variant counts

Stock-on-hand is a top-level `Item.qty` attribute (default 1) used by every
category, not just food. A "Battery" item with `qty: 8` represents eight AA
cells. Trip planner caps additions against this and the trip-completion
hook decrements it on Food.

## Stack

- **Elixir 1.19**, **Erlang/OTP 28**
- **Phoenix 1.8** + **Phoenix LiveView 1.1** (full UI, no JSON API)
- **Ash 3.x**, **AshPostgres**, **AshPhoenix**, **AshAuthentication**,
  **AshStateMachine**
- **Postgres 16** (homebrew default)
- **Tailwind 4** + **daisyUI 5** for styling

## Getting started

Prerequisites: Elixir 1.19+, Erlang/OTP 28+, Postgres 16 running locally.

```bash
mix setup                         # deps.get + ash.setup + assets + seeds
mix run priv/scripts/create_user.exs   # creates ben@local / password123
mix phx.server                    # http://localhost:4000
```

Sign in, then walk through:

1. Add cable types & battery types you care about (`/cable-types`, `/battery-types`).
2. Build out your inventory at `/items` — `+` button per category section.
3. Create kits at `/kits` and pick items into them.
4. Create a trip at `/trips`, set start/end dates, add kits + individual items
   on the Plan tab. Validate. Move into packing. Tick everything packed and
   charged. Mark complete.

## Repo layout

```
lib/packheavy/
  accounts.ex            # Ash domain
  accounts/user.ex       # AshAuthentication user
  inventory.ex           # Ash domain
  inventory/item.ex      # union over the variants in inventory/item/*.ex
  inventory/cable_type.ex
  inventory/battery_type.ex
  inventory/kit.ex
  inventory/kit_item.ex
  trips.ex               # Ash domain
  trips/trip.ex          # state machine + after_action food decrement
  trips/trip_item.ex
  trips/trip_kit.ex
  trips/calculations/validation_report.ex
  trips/changes/enforce_item_qty_available.ex

lib/packheavy_web/live/
  dashboard_live.ex
  item_live/index.ex            # category-grouped inventory + modal form
  kit_live/index.ex
  kit_live/show.ex
  trip_live/index.ex
  trip_live/show.ex             # plan / validate / pack / complete tabs
  cable_type_live/index.ex
  battery_type_live/index.ex
  components/item_picker.ex     # shared modal picker, used by Kit + Trip

priv/repo/migrations/            # AshPostgres-generated, committed
priv/resource_snapshots/         # Ash codegen snapshots, committed
priv/scripts/                    # smoke.exs, create_user.exs, etc.
```

## Operations

- `mix ash.codegen <name> --auto-name` after a resource change — generates a
  migration and a new resource snapshot. Run `mix ecto.migrate` after.
- `mix ecto.reset` rebuilds the database and runs seeds.
- `priv/scripts/smoke.exs` exercises the create/validate/complete paths
  end-to-end (handy when the dev server isn't usable for the test).

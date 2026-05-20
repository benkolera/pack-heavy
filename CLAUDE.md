# Claude Code project context

> See **AGENTS.md** for the general Phoenix 1.8 / LiveView / Tailwind 4 / Ash
> conventions inherited from `phx.new`. Everything below is packheavy-specific
> and assumes the AGENTS.md guidance is already in effect.

## Status / scope

- **Single-user, deployed but locked-down.** Live at
  packheavy.benkolera.com, bundled into the [benkolera-poncho] release
  alongside electric-brain — one Fargate task, one ALB, one RDS. Auth0
  fronts sign-in with a hardcoded email allowlist in a post-login Action.
  Don't widen the allowlist; many design assumptions are single-user.
- `priv/scripts/create_user.exs` seeds the local-dev account (password
  strategy is dev-only; prod is Auth0).
- See README for the user-facing feature list.

[benkolera-poncho]: https://github.com/benkolera/benkolera-poncho

## Always keep these in sync with code changes

Treat these as part of the change, not follow-up work:

1. **`README.md`** — if you add, remove, or meaningfully change a
   user-visible feature in the "Features" list, update the README in
   the same commit. If you change the resource graph (new Ash
   domain, new cross-domain reference, new state-machine transition),
   update the Mermaid architecture diagram.
2. **Tests** — every change to an Ash resource, action, policy, or
   live view event should land with a matching test edit. The test
   suite is the only check that trip validation, kit expansion,
   per-trip qty, and food decrement stay correct as we iterate.
   Don't ship a schema change with no test movement; either update
   an existing test or add one.
3. **Ash snapshots** — `mix ash.codegen --name <descriptive>` after
   any resource/attribute/action edit. Never hand-edit migration
   files (this project has had zero one-shot data moves; if you need
   one, follow the convention from the poncho's TimeBlocks split).

If you're unsure whether something needs README or test movement,
err on the side of yes.

## Domain layout

```
Packheavy.Accounts   — AshAuthentication User + Token
Packheavy.Inventory  — CableType, BatteryType, Item (union), Kit, KitItem
Packheavy.Trips      — Trip (state machine), TripItem, TripKit (breadcrumb)
```

Cross-domain reads are fine. Code interfaces (`define :create_item, …`) live
on the domain modules; **always use the `!` versions in handlers** so errors
raise rather than silently returning `{:error, _}`.

## Items: polymorphic via union+embedded

`Inventory.Item` has an `Ash.Type.Union` attribute `category_data`, with one
embedded resource per variant under `lib/packheavy/inventory/item/*.ex`.
Storage is `jsonb` — **adding a new category needs no DB migration**.

### Recipe: add a new Item category

1. Either:
   - For a "simple" category (no extra fields): add a line to
     `lib/packheavy/inventory/item/simple.ex` invoking the `use Item.Simple,
     type: :the_atom` macro.
   - For a category with fields: write a new module under
     `lib/packheavy/inventory/item/<name>.ex` with `use Ash.Resource,
     data_layer: :embedded` and a `:type` discriminator constrained to one
     atom matching its `tag_value`. JSON-encodable types only — don't use
     `Decimal` (it doesn't auto-encode; use `:float`).
2. Add an entry to the `category_data` union constraints in
   `lib/packheavy/inventory/item.ex`.
3. Add `{:atom, "Label"}` to the `@categories` list in
   `lib/packheavy_web/live/item_live/index.ex` (also `category_order/0` in
   `trip_live/show.ex` and `@categories` in `components/item_picker.ex` —
   they're duplicated for now).
4. Add a `variant_module(:atom)` clause and (if there are extra fields) a
   `category_fields(%{category: :atom})` clause in the LiveView.
5. Optionally an `extra_for/3` clause for the right-aligned info column on
   the items list.
6. No migration. The first save of an item with the new variant just lands
   in `category_data` jsonb.

## Kit expansion is at add-time, not by reference

When a kit is added to a trip we copy each `KitItem` into a fresh `TripItem`
with `source: :kit, source_kit_id: kit.id` and write a `TripKit` breadcrumb
row. After that the trip owns its copies and edits to the kit don't
propagate. **Don't** add kit→trip live-sync without a deliberate "re-sync"
button — silent mutation of in-flight trips is what we set out to avoid.

## Per-trip qty enforcement

`Packheavy.Trips.Changes.EnforceItemQtyAvailable` runs `before_action` on
TripItem create/update and errors when `requested + sum(other TripItems for
the same item on this trip) > Item.qty`. Cross-trip reservation is **not**
enforced — that's a deferred warn-only feature.

The user-facing way to edit a trip's items is the `ItemPicker` LiveComponent
in "full state editor" mode: existing TripItems start checked at their
current qty, the user dials up/down (capped at `Item.qty`), unchecking or
qty=0 removes. The parent `handle_info({:item_picker_confirm, …})` computes
the diff and delete/replace TripItems accordingly. **Don't reintroduce an
inline qty edit on the row** — it's been tried, the no-op-update path
through `EnforceItemQtyAvailable` was confusing and triggered false
positives.

## `relate_actor(:user)` instead of form params for user_id

Every user-scoped resource's `:create` action does `change relate_actor(:user)`
and accepts `[:title, …]` *without* `:user_id`. **Don't** add a `user_id`
form field or a `transform_params` injecting it — past attempts caused
silent failures in nested AshPhoenix.Form contexts.

## Trip completion decrements food

`Trip.complete` is an `update` action with `transition_state(:complete)` and
an `after_action` that loads `trip_items: [item: …]`, filters Food union
variants, and calls `Item.decrement_qty` (clamped at 0) for each. The
relevant gotcha: pattern-match against `%Ash.Union{value: %Food{}}` —
`category_data` is wrapped in an `Ash.Union` struct, **not** the raw
embedded struct. The validation report calc has the same wrap concern.

## Validation report

`Packheavy.Trips.Calculations.ValidationReport` is a custom Ash calculation
on Trip, loaded only on the trip detail page. It returns
`%{totals: %{...}, errors: […], warnings: […]}`. The `weight_breakdown/1`
component on `trip_live/show.ex` is shared between Plan and Validate tabs —
keep it that way so totals don't drift.

## Useful commands

```sh
# After any Ash resource change:
mix ash.codegen <name> --auto-name && mix ecto.migrate

# Reset DB (drop + create + migrate + seeds):
mix ecto.reset

# Smoke-test the create / validate / complete flow without the dev server:
mix run priv/scripts/smoke.exs
```

## Conventions / gotchas

- **Don't `rmdir` the Bash cwd.** If a generator (`mix igniter.new`,
  `mix phx.new packheavy`) wants the dir to not exist, run from inside
  with `.` as the path or coordinate a session restart. Deleting the cwd
  bricks the Bash tool until the directory exists again.
- **`Ash.get!(Resource, id, load: […])`** — do not pipe a query into
  `Ash.get!` (`Resource |> Ash.Query.load(…) |> Ash.get!(id)` is wrong;
  the query gets passed as the resource arg).
- **`phx-keyup` / `phx-blur` events** put the input's current value at
  `params["value"]`, not under the input's `name` key.
- **Print CSS** lives in `assets/css/app.css` under `@media print` —
  Cmd+P → Save as PDF on Mac is the supported "export" path.
- **Memory** under
  `~/.claude/projects/-Users-ben-src-gh-benkolera-packheavy/memory/`
  has cross-session preferences and incident notes; check it before
  proposing approaches that have been weighed before.

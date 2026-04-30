defmodule Packheavy.Trips.Calculations.ValidationReport do
  @moduledoc """
  Calculates a validation report for a Trip:
    %{
      totals: %{weight_g, calories, water_ml, power_mah, usb_ports},
      errors:   [%{kind: :missing_charger, item_id, item_title, cable_type_id}, ...],
      warnings: [%{kind: :no_spare_battery, item_id, item_title, battery_type_id}, ...]
    }

  The rules: every rechargeable Electronic with a charger_cable_type_id must
  have at least one Cable trip_item whose cable_type_id matches. Every
  consumable Electronic with a battery_type_id soft-warns if no Item with a
  matching battery_type_id is present (v1: rough heuristic — checks if any
  item's category_data carries that battery_type_id).
  """
  use Ash.Resource.Calculation

  alias Packheavy.Inventory.Item.{Battery, Cable, Electronic, Food, Pack, Power, Water}

  @impl true
  def load(_query, _opts, _ctx) do
    [
      trip_items: [
        :qty,
        :packed,
        :charged,
        item: [:id, :title, :weight_g, :category_data]
      ]
    ]
  end

  @impl true
  def calculate(trips, _opts, _ctx) do
    Enum.map(trips, fn trip -> build_report(trip) end)
  end

  defp build_report(trip) do
    trip_items = trip.trip_items || []

    cable_type_ids =
      trip_items
      |> Enum.flat_map(fn ti ->
        case unwrap(ti.item && ti.item.category_data) do
          %Cable{cable_type_id: id} when not is_nil(id) -> [id]
          _ -> []
        end
      end)
      |> MapSet.new()

    # Spare batteries actually packed on the trip (Battery items only).
    spare_battery_type_ids =
      trip_items
      |> Enum.flat_map(fn ti ->
        case unwrap(ti.item && ti.item.category_data) do
          %Battery{battery_type_id: id} when not is_nil(id) -> [id]
          _ -> []
        end
      end)
      |> MapSet.new()

    {totals, errors, warnings} =
      Enum.reduce(trip_items, {empty_totals(), [], []}, fn ti, {tot, errs, warns} ->
        item = ti.item
        cd = unwrap(item && item.category_data)
        weight = (item && item.weight_g) || 0
        qty = ti.qty || 1
        tot = Map.update!(tot, :weight_g, &(&1 + weight * qty))

        case cd do
          %Electronic{power_source: ps} = e ->
            tot = Map.update!(tot, :electronics, &(&1 + qty))

            errs =
              if ps == :built_in and not is_nil(e.charger_cable_type_id) and
                   not MapSet.member?(cable_type_ids, e.charger_cable_type_id) do
                [
                  %{
                    kind: :missing_charger,
                    item_id: item.id,
                    item_title: item.title,
                    cable_type_id: e.charger_cable_type_id
                  }
                  | errs
                ]
              else
                errs
              end

            warns =
              if ps == :batteries and not is_nil(e.battery_type_id) and
                   not MapSet.member?(spare_battery_type_ids, e.battery_type_id) do
                [
                  %{
                    kind: :no_spare_battery,
                    item_id: item.id,
                    item_title: item.title,
                    battery_type_id: e.battery_type_id
                  }
                  | warns
                ]
              else
                warns
              end

            {tot, errs, warns}

          %Water{capacity_ml: ml} ->
            # Container weight stays in base; water_weight_g is the water itself
            # when the container is full (1 ml ≈ 1 g).
            tot =
              tot
              |> Map.update!(:water_ml, &(&1 + (ml || 0) * qty))
              |> Map.update!(:water_weight_g, &(&1 + (ml || 0) * qty))

            {tot, errs, warns}

          %Food{calories: cals} ->
            tot =
              tot
              |> Map.update!(:calories, &(&1 + (cals || 0) * qty))
              |> Map.update!(:food_weight_g, &(&1 + weight * qty))

            {tot, errs, warns}

          %Pack{volume_l: v} ->
            tot = Map.update!(tot, :pack_volume_l, &(&1 + (v || 0) * qty))
            {tot, errs, warns}

          %Power{capacity_mah: mah, usb_ports: ports} ->
            tot =
              tot
              |> Map.update!(:power_mah, &(&1 + (mah || 0) * qty))
              |> Map.update!(:usb_ports, &(&1 + (ports || 0) * qty))

            {tot, errs, warns}

          %Cable{} ->
            {tot, errs, warns}

          %Battery{} ->
            {tot, errs, warns}

          _ ->
            {tot, errs, warns}
        end
      end)

    %{totals: totals, errors: Enum.reverse(errors), warnings: Enum.reverse(warnings)}
  end

  defp unwrap(%Ash.Union{value: value}), do: value
  defp unwrap(other), do: other

  defp empty_totals do
    %{
      weight_g: 0,
      food_weight_g: 0,
      water_weight_g: 0,
      calories: 0,
      water_ml: 0,
      pack_volume_l: 0,
      power_mah: 0,
      usb_ports: 0,
      electronics: 0
    }
  end
end

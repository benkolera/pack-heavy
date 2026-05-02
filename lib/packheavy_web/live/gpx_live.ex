defmodule PackheavyWeb.GpxLive do
  use PackheavyWeb, :live_view

  alias Packheavy.Gpx

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Packheavy: GPX viewer")
     |> assign(:parsed, nil)
     |> assign(:filename, nil)
     |> assign(:error, nil)
     |> allow_upload(:gpx,
       accept: ~w(.gpx application/gpx+xml),
       max_entries: 1,
       max_file_size: 50_000_000
     )}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :gpx, ref)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, parsed: nil, filename: nil, error: nil)}
  end

  def handle_event("parse", _params, socket) do
    case consume_uploaded_entries(socket, :gpx, fn %{path: path}, entry ->
           {:ok, {entry.client_name, File.read!(path) |> Gpx.parse()}}
         end) do
      [{name, {:ok, parsed}}] ->
        track = canonical_track(parsed.points)

        {:noreply,
         socket
         |> assign(parsed: parsed, filename: name, error: nil)
         |> assign(track: track, track_json: Jason.encode!(track))}

      [{name, {:error, reason}}] ->
        {:noreply,
         assign(socket, parsed: nil, filename: name, error: "Could not parse GPX: #{reason}")}

      [] ->
        {:noreply, assign(socket, error: "No file uploaded")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-2xl font-bold">GPX viewer</h1>
      <p class="text-sm opacity-70">
        Upload a GPX export from Komoot or Garmin Connect to see distance,
        elevation gain, an elevation profile, and the route on OpenTopoMap.
      </p>

      <div class="card bg-base-200 p-4 space-y-3 mt-4">
        <form phx-change="validate" phx-submit="parse">
          <.live_file_input upload={@uploads.gpx} class="file-input file-input-bordered w-full" />
          <div :for={entry <- @uploads.gpx.entries} class="text-sm mt-2 flex items-center gap-2">
            <span>{entry.client_name}</span>
            <button
              type="button"
              phx-click="cancel-upload"
              phx-value-ref={entry.ref}
              class="btn btn-ghost btn-xs"
            >
              Remove
            </button>
          </div>
          <div :for={err <- upload_errors(@uploads.gpx)} class="text-error text-sm mt-1">
            {Phoenix.Naming.humanize(err)}
          </div>
          <button type="submit" class="btn btn-primary mt-3" disabled={@uploads.gpx.entries == []}>
            Parse
          </button>
          <button :if={@parsed} type="button" phx-click="clear" class="btn btn-ghost mt-3">
            Clear
          </button>
        </form>

        <div :if={@error} class="alert alert-error text-sm">{@error}</div>
      </div>

      <div :if={@parsed} class="space-y-4 mt-6">
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div class="card bg-base-200 p-4">
            <div class="text-sm opacity-70">Distance</div>
            <div class="text-3xl font-bold">{format_km(@parsed.stats.distance_m)} km</div>
          </div>
          <div class="card bg-base-200 p-4">
            <div class="text-sm opacity-70">Elevation gain</div>
            <div class="text-3xl font-bold">{round(@parsed.stats.elevation_gain_m)} m</div>
          </div>
          <div class="card bg-base-200 p-4">
            <div class="text-sm opacity-70">Track points</div>
            <div class="text-3xl font-bold">{@parsed.stats.point_count}</div>
            <div :if={@filename} class="text-xs opacity-60 truncate">{@filename}</div>
          </div>
        </div>

        <div class="card bg-base-200 p-4">
          <h2 class="font-semibold mb-2">Elevation profile</h2>
          <%= if has_elevation?(@track) do %>
            <div
              id="gpx-chart"
              phx-hook=".GpxChart"
              phx-update="ignore"
              data-track={@track_json}
              class="text-primary"
            >
              {Phoenix.HTML.raw(elevation_svg(@track))}
            </div>
          <% else %>
            <p class="text-sm opacity-70">No elevation data in this GPX.</p>
          <% end %>
        </div>

        <div class="card bg-base-200 p-4">
          <h2 class="font-semibold mb-2">Route</h2>
          <div
            id="gpx-map"
            phx-hook=".OpenTopoMap"
            phx-update="ignore"
            data-track={@track_json}
            class="w-full h-[500px] rounded"
          >
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".OpenTopoMap">
        // Lazy-load Leaflet from CDN on first mount; subsequent mounts
        // reuse the cached promise. OpenTopoMap is the public tile
        // server (CC-BY-SA, fair-use only — fine for personal use).
        let leafletReady = null
        function loadLeaflet() {
          if (window.L) return Promise.resolve()
          if (leafletReady) return leafletReady
          leafletReady = new Promise((resolve, reject) => {
            const link = document.createElement("link")
            link.rel = "stylesheet"
            link.href = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
            link.integrity = "sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY="
            link.crossOrigin = ""
            document.head.appendChild(link)

            const script = document.createElement("script")
            script.src = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"
            script.integrity = "sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo="
            script.crossOrigin = ""
            script.onload = resolve
            script.onerror = reject
            document.head.appendChild(script)
          })
          return leafletReady
        }

        export default {
          async mounted() {
            await loadLeaflet()
            const track = JSON.parse(this.el.dataset.track)
            if (!track.length) return

            const latlngs = track.map(p => [p.lat, p.lon])
            const map = L.map(this.el).setView(latlngs[0], 13)
            L.tileLayer("https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png", {
              maxZoom: 17,
              attribution:
                'Map data: © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors, SRTM | ' +
                'Map style: © <a href="https://opentopomap.org">OpenTopoMap</a> ' +
                '(<a href="https://creativecommons.org/licenses/by-sa/3.0/">CC-BY-SA</a>)',
            }).addTo(map)

            const polyline = L.polyline(latlngs, { color: "#dc2626", weight: 4 }).addTo(map)
            map.fitBounds(polyline.getBounds(), { padding: [20, 20] })

            // Reusable hover marker — added/removed on incoming hover
            // events. Kept as a CircleMarker so the radius is in pixels
            // regardless of zoom.
            const marker = L.circleMarker([0, 0], {
              radius: 7,
              color: "#000",
              weight: 2,
              fillColor: "#facc15",
              fillOpacity: 1,
            })

            // Map → chart: when the user moves over the polyline,
            // find the closest track point and broadcast its index.
            polyline.on("mousemove", (e) => {
              const ll = e.latlng
              let bestI = 0,
                bestD = Infinity
              for (let i = 0; i < track.length; i++) {
                const dx = track[i].lat - ll.lat,
                  dy = track[i].lon - ll.lng
                const d = dx * dx + dy * dy
                if (d < bestD) {
                  bestD = d
                  bestI = i
                }
              }
              window.dispatchEvent(
                new CustomEvent("gpx:hover", { detail: { index: bestI, source: "map" } }),
              )
            })
            polyline.on("mouseout", () => {
              window.dispatchEvent(
                new CustomEvent("gpx:hover", { detail: { index: null, source: "map" } }),
              )
            })

            // Chart → map: incoming events move the marker.
            this._handleHover = (e) => {
              const i = e.detail.index
              if (i === null || i === undefined) {
                marker.remove()
                return
              }
              const p = track[i]
              if (!p) return
              marker.setLatLng([p.lat, p.lon]).addTo(map)
            }
            window.addEventListener("gpx:hover", this._handleHover)

            this._map = map
          },
          destroyed() {
            if (this._handleHover) window.removeEventListener("gpx:hover", this._handleHover)
            if (this._map) this._map.remove()
          },
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".GpxChart">
        // Mousemove on the chart → broadcast the index of the nearest
        // sample by cumulative distance. Listens for the same event so
        // the map can drive the chart's crosshair too.
        const SVG_W = 800
        const SVG_H = 200

        export default {
          mounted() {
            const track = JSON.parse(this.el.dataset.track)
            const eles = track.map((p) => p.ele).filter((e) => e !== null && e !== undefined)
            if (!eles.length || track.length < 2) return

            const totalD = track[track.length - 1].d || 1
            const minE = Math.min(...eles)
            const spanE = Math.max(Math.max(...eles) - minE, 1)

            const svg = this.el.querySelector("svg")
            if (!svg) return

            const ns = "http://www.w3.org/2000/svg"
            const indicator = document.createElementNS(ns, "g")
            indicator.style.display = "none"
            indicator.style.pointerEvents = "none"
            const line = document.createElementNS(ns, "line")
            line.setAttribute("y1", "10")
            line.setAttribute("y2", String(SVG_H))
            line.setAttribute("stroke", "currentColor")
            line.setAttribute("stroke-width", "1")
            line.setAttribute("opacity", "0.5")
            indicator.appendChild(line)
            const dot = document.createElementNS(ns, "circle")
            dot.setAttribute("r", "4")
            dot.setAttribute("fill", "currentColor")
            indicator.appendChild(dot)
            const label = document.createElementNS(ns, "text")
            label.setAttribute("y", "26")
            label.setAttribute("text-anchor", "middle")
            label.setAttribute("class", "fill-base-content text-xs")
            indicator.appendChild(label)
            svg.appendChild(indicator)

            const showAt = (i) => {
              const p = track[i]
              if (!p || p.ele === null || p.ele === undefined) {
                indicator.style.display = "none"
                return
              }
              const x = (p.d / totalD) * SVG_W
              const y = SVG_H - ((p.ele - minE) / spanE) * 180 - 10
              line.setAttribute("x1", String(x))
              line.setAttribute("x2", String(x))
              dot.setAttribute("cx", String(x))
              dot.setAttribute("cy", String(y))
              // Keep the label inside the chart even at the edges.
              const labelX = Math.min(Math.max(x, 40), SVG_W - 40)
              label.setAttribute("x", String(labelX))
              label.textContent = `${(p.d / 1000).toFixed(2)} km · ${Math.round(p.ele)} m`
              indicator.style.display = ""
            }

            // Chart → map: mousemove on the SVG.
            this.el.addEventListener("mousemove", (ev) => {
              const rect = svg.getBoundingClientRect()
              if (rect.width === 0) return
              const xSvg = ((ev.clientX - rect.left) / rect.width) * SVG_W
              const targetD = (xSvg / SVG_W) * totalD

              // Linear scan — fine for typical GPX (<10k points).
              let bestI = 0,
                bestDiff = Infinity
              for (let i = 0; i < track.length; i++) {
                const diff = Math.abs(track[i].d - targetD)
                if (diff < bestDiff) {
                  bestDiff = diff
                  bestI = i
                }
              }
              window.dispatchEvent(
                new CustomEvent("gpx:hover", { detail: { index: bestI, source: "chart" } }),
              )
            })
            this.el.addEventListener("mouseleave", () => {
              window.dispatchEvent(
                new CustomEvent("gpx:hover", { detail: { index: null, source: "chart" } }),
              )
            })

            // Map → chart: incoming events move the crosshair.
            this._handleHover = (e) => {
              const i = e.detail.index
              if (i === null || i === undefined) {
                indicator.style.display = "none"
                return
              }
              showAt(i)
            }
            window.addEventListener("gpx:hover", this._handleHover)
          },
          destroyed() {
            if (this._handleHover) window.removeEventListener("gpx:hover", this._handleHover)
          },
        }
      </script>
    </Layouts.app>
    """
  end

  # ---- view helpers --------------------------------------------------

  defp format_km(metres), do: :erlang.float_to_binary(metres / 1000, decimals: 2)

  # Build one indexed track that both the map polyline and the chart
  # consume. Cumulative distance is computed over every point (not just
  # those with elevation) so chart x-coords stay aligned with map
  # marker positions when some points lack <ele>.
  defp canonical_track(points) do
    {acc, _, _} =
      Enum.reduce(points, {[], nil, 0.0}, fn pt, {acc, prev, total} ->
        d =
          case prev do
            nil -> 0.0
            _ -> total + haversine_pt(prev, pt)
          end

        {[%{lat: pt.lat, lon: pt.lon, ele: pt.ele, d: d} | acc], pt, d}
      end)

    Enum.reverse(acc)
  end

  defp has_elevation?(track), do: Enum.any?(track, &(&1.ele != nil))

  # SVG line chart of elevation vs distance. ViewBox 800x200 — must
  # match SVG_W/SVG_H in the .GpxChart hook so the crosshair lines up.
  defp elevation_svg(track) do
    eles = track |> Enum.map(& &1.ele) |> Enum.reject(&is_nil/1)
    {min_e, max_e} = Enum.min_max(eles)
    total_d = track |> List.last() |> Map.get(:d) |> max(1.0)
    e_span = max(max_e - min_e, 1.0)

    coords =
      track
      |> Enum.filter(&(&1.ele != nil))
      |> Enum.map_join(" ", fn %{d: d, ele: e} ->
        x = d / total_d * 800
        y = 200 - (e - min_e) / e_span * 180 - 10
        "#{:erlang.float_to_binary(x, decimals: 1)},#{:erlang.float_to_binary(y, decimals: 1)}"
      end)

    """
    <svg viewBox="0 0 800 200" class="w-full h-48 select-none">
      <polyline points="#{coords}" fill="none" stroke="currentColor" stroke-width="1.5" />
      <text x="4" y="14" class="fill-base-content text-xs opacity-70">#{round(max_e)} m</text>
      <text x="4" y="196" class="fill-base-content text-xs opacity-70">#{round(min_e)} m</text>
      <text x="796" y="196" text-anchor="end" class="fill-base-content text-xs opacity-70">#{:erlang.float_to_binary(total_d / 1000, decimals: 1)} km</text>
    </svg>
    """
  end

  defp haversine_pt(%{lat: lat1, lon: lon1}, %{lat: lat2, lon: lon2}) do
    r = 6_371_000.0
    rlat1 = :math.pi() * lat1 / 180
    rlat2 = :math.pi() * lat2 / 180
    dlat = :math.pi() * (lat2 - lat1) / 180
    dlon = :math.pi() * (lon2 - lon1) / 180
    a = :math.sin(dlat / 2) ** 2 + :math.cos(rlat1) * :math.cos(rlat2) * :math.sin(dlon / 2) ** 2
    r * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end
end

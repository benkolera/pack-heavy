// Multi-leg OpenTopoMap renderer. Each leg is one Leaflet polyline in
// its own colour, hover-linked to the per-leg elevation chart via
// window-level `gpx:hover` events. Server pushes `route:legs-updated`
// when the leg list mutates so the polylines refresh in place — the
// map div has phx-update="ignore" so attribute diffs would otherwise
// never reach us.

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
    this._polylines = []

    await loadLeaflet()

    // Initialise the map with a placeholder centre. The actual leg
    // tracks arrive via the `route:legs-updated` push_event after
    // mount, which keeps the (potentially hundreds of KB) GPX
    // payload out of the initial LiveView phx_reply.
    const map = L.map(this.el).setView([0, 0], 2)
    L.tileLayer("https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png", {
      maxZoom: 17,
      attribution:
        'Map data: © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors, SRTM | ' +
        'Map style: © <a href="https://opentopomap.org">OpenTopoMap</a> ' +
        '(<a href="https://creativecommons.org/licenses/by-sa/3.0/">CC-BY-SA</a>)',
    }).addTo(map)
    this._map = map

    // `interactive: false` keeps pointer events flowing to the
    // polyline underneath. Without it the cursor sits on the marker
    // after the first move, the polyline fires `mouseout`, and the
    // chart hides its indicator — the bug where the highlight
    // disappears the moment you stop moving.
    this._marker = L.circleMarker([0, 0], {
      radius: 7,
      color: "#000",
      weight: 2,
      fillColor: "#facc15",
      fillOpacity: 1,
      interactive: false,
    })

    this._handleHover = (e) => {
      const { legId, index } = e.detail
      if (!legId || index === null || index === undefined) {
        this._marker.remove()
        return
      }
      const entry = this._polylines.find((p) => p.leg.id === legId)
      if (!entry) return
      const p = entry.leg.track[index]
      if (!p) return
      this._marker.setLatLng([p.lat, p.lon]).addTo(this._map)
    }
    window.addEventListener("gpx:hover", this._handleHover)

    this.handleEvent("gpx:fly", ({ leg_id }) => {
      const entry = this._polylines.find((p) => p.leg.id === leg_id)
      if (!entry) return
      // Compute fresh bounds from the source track. Reusing
      // `polyline.getBounds()` was returning the full-route bounds for
      // the first leg because drawLegs aliases its bounds object into
      // `combinedBounds` and then mutates it via `.extend()`.
      const latlngs = entry.leg.track.map((p) => [p.lat, p.lon])
      this._map.flyToBounds(L.latLngBounds(latlngs), { padding: [20, 20] })

      // On narrow viewports the map sits above the legs list, so a Fly
      // click leaves the user staring at the leg row they just tapped.
      // Scroll the map into view so the result of the click is visible.
      // Skipped on viewports wide enough for the side-by-side layout
      // (lg = 1024 px) where the map is already on screen.
      if (window.innerWidth < 1024) {
        this.el.scrollIntoView({ behavior: "smooth", block: "start" })
      }
    })

    this.handleEvent("route:legs-updated", ({ legs }) => {
      this.drawLegs(legs)
    })
  },
  drawLegs(legs) {
    if (!this._map) return

    this._polylines.forEach(({ polyline }) => polyline.remove())
    this._polylines = []

    let combinedBounds = null
    legs.forEach((leg) => {
      const latlngs = leg.track.map((p) => [p.lat, p.lon])
      const pl = L.polyline(latlngs, { color: leg.color, weight: 4 }).addTo(this._map)
      pl._legId = leg.id

      pl.on("mousemove", (e) => {
        const ll = e.latlng
        let bestI = 0,
          bestD = Infinity
        for (let i = 0; i < leg.track.length; i++) {
          const dx = leg.track[i].lat - ll.lat,
            dy = leg.track[i].lon - ll.lng
          const d = dx * dx + dy * dy
          if (d < bestD) {
            bestD = d
            bestI = i
          }
        }
        window.dispatchEvent(
          new CustomEvent("gpx:hover", { detail: { legId: leg.id, index: bestI } }),
        )
      })
      pl.on("mouseout", () => {
        window.dispatchEvent(
          new CustomEvent("gpx:hover", { detail: { legId: null, index: null } }),
        )
      })

      this._polylines.push({ leg, polyline: pl })
      // Always allocate a fresh bounds for combinedBounds rather than
      // aliasing leg 0's polyline-bounds object. Without this, later
      // `.extend(...)` calls mutate the leg 0 bounds we'd reuse on fly.
      const b = L.latLngBounds(latlngs)
      combinedBounds = combinedBounds ? combinedBounds.extend(b) : b
    })

    if (combinedBounds) {
      this._map.fitBounds(combinedBounds, { padding: [20, 20] })
    }
  },
  destroyed() {
    if (this._handleHover) window.removeEventListener("gpx:hover", this._handleHover)
    if (this._map) this._map.remove()
  },
}

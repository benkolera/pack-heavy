// SVG elevation profile crosshair. The track data arrives via the
// `chart:tracks` push_event from the LiveView (so it stays out of
// the initial render diff); each chart hook listens for the same
// event and picks its own leg's track by id.

const SVG_W = 800
const SVG_H = 200

export default {
  mounted() {
    this._initialised = false

    this.handleEvent("chart:tracks", ({ tracks }) => {
      const legId = this.el.dataset.legId
      const track = tracks && tracks[legId]
      if (!this._initialised && track) this._init(track, legId)
    })
  },
  _init(track, legId) {
    this._initialised = true

    const eles = track.map((p) => p.ele).filter((e) => e !== null && e !== undefined)
    if (!eles.length || track.length < 2) return

    const totalD = track[track.length - 1].d || 1
    const minE = Math.min(...eles)
    const spanE = Math.max(Math.max(...eles) - minE, 1)

    // Precompute the slope to the NEXT point at each index. Last
    // point falls back to the slope coming in from the previous one
    // so the indicator still shows a value at the end of the track.
    const slopes = track.map((p, i) => {
      const ref =
        i < track.length - 1 ? { from: p, to: track[i + 1] } : { from: track[i - 1], to: p }
      if (!ref.from || !ref.to) return null
      if (ref.from.ele === null || ref.from.ele === undefined) return null
      if (ref.to.ele === null || ref.to.ele === undefined) return null
      const dh = ref.to.d - ref.from.d
      if (dh <= 0) return null
      return ((ref.to.ele - ref.from.ele) / dh) * 100
    })

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

    // Popover: a translucent rounded rect behind a single text node
    // so the readout is legible against the gradient-shaded background.
    const popoverBg = document.createElementNS(ns, "rect")
    popoverBg.setAttribute("rx", "4")
    popoverBg.setAttribute("ry", "4")
    popoverBg.setAttribute("fill", "rgba(0,0,0,0.7)")
    indicator.appendChild(popoverBg)

    const label = document.createElementNS(ns, "text")
    label.setAttribute("y", "32")
    label.setAttribute("text-anchor", "middle")
    label.setAttribute("font-size", "22")
    label.setAttribute("font-weight", "600")
    label.setAttribute("fill", "white")
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

      const labelX = Math.min(Math.max(x, 100), SVG_W - 100)
      label.setAttribute("x", String(labelX))

      const slope = slopes[i]
      const slopeStr =
        slope !== null && slope !== undefined
          ? ` · ${slope >= 0 ? "+" : ""}${slope.toFixed(1)}%`
          : ""
      label.textContent = `${(p.d / 1000).toFixed(2)} km · ${Math.round(p.ele)} m${slopeStr}`

      // Size the popover background to wrap the text after we've set it.
      const bbox = label.getBBox()
      const padX = 10
      const padY = 5
      popoverBg.setAttribute("x", String(bbox.x - padX))
      popoverBg.setAttribute("y", String(bbox.y - padY))
      popoverBg.setAttribute("width", String(bbox.width + padX * 2))
      popoverBg.setAttribute("height", String(bbox.height + padY * 2))

      indicator.style.display = ""
    }

    this.el.addEventListener("mousemove", (ev) => {
      const rect = svg.getBoundingClientRect()
      if (rect.width === 0) return
      const xSvg = ((ev.clientX - rect.left) / rect.width) * SVG_W
      const targetD = (xSvg / SVG_W) * totalD

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
        new CustomEvent("gpx:hover", { detail: { legId, index: bestI } }),
      )
    })
    this.el.addEventListener("mouseleave", () => {
      window.dispatchEvent(
        new CustomEvent("gpx:hover", { detail: { legId: null, index: null } }),
      )
    })

    this._handleHover = (e) => {
      const { legId: hoveredLegId, index } = e.detail
      if (hoveredLegId !== legId || index === null || index === undefined) {
        indicator.style.display = "none"
        return
      }
      showAt(index)
    }
    window.addEventListener("gpx:hover", this._handleHover)
  },
  destroyed() {
    if (this._handleHover) window.removeEventListener("gpx:hover", this._handleHover)
  },
}

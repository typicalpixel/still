// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/still"
import topbar from "../vendor/topbar"
import {Terminal} from "../vendor/xterm"
import {FitAddon} from "../vendor/xterm-addon-fit"

// Remote console terminal. Keeps the terminal-facing surface to
// write/onData/resize so the underlying library stays swappable.
const Console = {
  mounted() {
    this.term = new Terminal({
      scrollback: 5000,
      fontFamily: "JetBrains Mono, ui-monospace, SF Mono, Menlo, monospace",
      fontSize: 13,
      theme: {
        background: "#24283b",
        foreground: "#c0caf5",
        cursor: "#c0caf5",
        selectionBackground: "#3d59a1",
        black: "#1d202f",
        red: "#f7768e",
        green: "#9ece6a",
        yellow: "#e0af68",
        blue: "#7aa2f7",
        magenta: "#bb9af7",
        cyan: "#7dcfff",
        white: "#a9b1d6",
        brightBlack: "#414868",
        brightRed: "#f7768e",
        brightGreen: "#9ece6a",
        brightYellow: "#e0af68",
        brightBlue: "#7aa2f7",
        brightMagenta: "#bb9af7",
        brightCyan: "#7dcfff",
        brightWhite: "#c0caf5",
      },
    })
    this.fit = new FitAddon()
    this.term.loadAddon(this.fit)
    this.term.open(this.el)
    this.fit.fit()
    // Emitting the clear/home escape ourselves: IEx won't, because ANSI is off
    // on the deployed node and enabling it node-wide would also color the app's
    // logs. This is what a real `clear` sends, so scrollback is preserved.
    const clearScreen = () => this.term.write("\x1b[2J\x1b[H")
    this.term.onData((data) => this.pushEvent("input", {data}))
    this.term.onResize(({cols, rows}) => this.pushEvent("resize", {cols, rows}))
    this.outTail = ""
    this.handleEvent("output", ({d}) => {
      const bytes = Uint8Array.from(atob(d), (c) => c.charCodeAt(0))
      this.term.write(bytes)
      // Make a typed `clear` work: IEx prints a refusal instead of clearing, so
      // clear for it when we see that refusal (robust to line-editing/history).
      this.outTail = (this.outTail + new TextDecoder().decode(bytes)).slice(-256)
      if (this.outTail.includes("escape codes are not enabled")) {
        this.outTail = ""
        clearScreen()
      }
    })
    this.handleEvent("exit", () => this.term.blur())
    this.handleEvent("focus", () => this.term.focus())
    this.handleEvent("reset", () => this.term.reset())
    this.resizeObserver = new ResizeObserver(() => this.fit.fit())
    this.resizeObserver.observe(this.el)
    this.pushEvent("resize", {cols: this.term.cols, rows: this.term.rows})
    this.term.focus()
  },
  destroyed() {
    this.resizeObserver?.disconnect()
    this.term?.dispose()
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, Console},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

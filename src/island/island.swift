import Cocoa
import SwiftUI
import CoreText

// ─────────────────────────────────────────────────────────────────────────
// ClaudeIsland — a persistent notch "live activity" for Claude Code.
//
// Runs as a background LSUIElement agent. Owns a borderless, non-activating
// NSPanel pinned at the top-center of the notch screen. State is pushed in
// from Claude Code hooks: the `island-send` helper writes a normalized
// payload to ~/.claude-island/event.json and posts a Darwin notification,
// which wakes this process to reload and animate.
// ─────────────────────────────────────────────────────────────────────────

// MARK: - Paths

let kEventDir = NSString("~/.claude-island").expandingTildeInPath
let kEventFile = kEventDir + "/event.json"
let kSessionsDir = kEventDir + "/sessions"     // one <tabUUID>.json per live session
// Claude Code's own per-session state files (one <pid>.json each, keyed by sessionId).
// CC updates `status` (busy/idle) live, independent of our hooks — the freshest signal
// for whether a session is actually computing right now. Reverse-engineered, no API.
let kCCSessionsDir = NSString("~/.claude/sessions").expandingTildeInPath
let kProjectOrderFile = kEventDir + "/project-order"   // persisted dropdown group order (first-seen)
let kGifPath = kEventDir + "/claude.gif"               // working
let kThinkingGifPath = kEventDir + "/claude-thinking.gif"  // thinking
let kCompactingGifPath = kEventDir + "/claude-compacting.gif"  // compacting
let kDoneImagePath = kEventDir + "/claude-done.tiff"       // success
let kDarwinName = "com.claude-island.event"

// Custom fonts (registered at launch). Verb uses the serif, project uses the sans.
let kSerifFontPath = NSString("~/Library/Fonts/AnthropicSerif_Roman_Web-s.p.0974051x8mlf0.otf").expandingTildeInPath
let kSansFontPath  = NSString("~/Library/Fonts/AnthropicSans_Roman_Web-s.p.0g0iw7wqvowb5.otf").expandingTildeInPath
let kSerifFontName = "AnthropicSerifWebWeb-TextLight"
let kSansFontName  = "AnthropicSansWebWeb-TextRegular"

func registerFonts() {
    for path in [kSerifFontPath, kSansFontPath] where FileManager.default.fileExists(atPath: path) {
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, nil)
    }
}

/// Bring Warp to the front (or launch it) when the island is clicked.
func activateWarp() {
    let apps = NSWorkspace.shared.runningApplications
    if let warp = apps.first(where: { ($0.bundleIdentifier ?? "").lowercased().contains("warp") }) {
        warp.activate(options: [.activateAllWindows])
    } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable") {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

/// Jump to the exact Warp tab/pane that owns this session via its deep link
/// (warp://session/<uuid>). Falls back to just fronting Warp if we have no link.
func focusSession() {
    let f = IslandState.shared.focusURL
    if !f.isEmpty, let url = URL(string: f) {
        NSWorkspace.shared.open(url)
    } else {
        activateWarp()
    }
}

// Text measurement. SwiftUI GeometryReader/PreferenceKey reads come back 0 inside
// this non-activating NSPanel hosting context (verified: L/R/Pill all measured 0),
// so we can't measure laid-out views. Instead we size everything deterministically
// from CoreText: measure each label with its real font and reconstruct the cluster
// widths in code. The pill lays out from the same strings, so the pill geometry and
// the back-card widths/offsets stay perfectly in sync.
func textWidth(_ s: String, _ font: NSFont, tracking: CGFloat = 0) -> CGFloat {
    guard !s.isEmpty else { return 0 }
    var attrs: [NSAttributedString.Key: Any] = [.font: font]
    if tracking != 0 { attrs[.kern] = tracking }
    return ceil((s as NSString).size(withAttributes: attrs).width)
}

// Back-card layout constants. Shared between the SwiftUI view (which draws the cards)
// and AppController (which hit-tests them against the mouse), so the geometry the user
// sees and the geometry the hover logic uses can never drift apart.
let kCardPeek: CGFloat = 22       // how far each stacked card peeks past the one in front
let kCardTuck: CGFloat = 56       // how far a hovered card's right edge tucks under the pill
let kCardTextPad: CGFloat = 22    // title leading inset (clears the concave shoulder)
let kCardTextGap: CGFloat = 8     // gap after the title before the tuck
let kCardSansFont = NSFont(name: kSansFontName, size: 13) ?? .systemFont(ofSize: 13)
let kTimerFont = NSFont(name: kSansFontName, size: 12) ?? .systemFont(ofSize: 12)  // dropdown row timer

// Dropdown ("{n} ⌄") UI geometry, shared by the view and the controller's hit-testing.
let kAgentsPeek: CGFloat = 32     // how far the "{n} ⌄" back pill peeks past the pill's right edge
let kSheetSide: CGFloat = 40      // how much wider (each side) the expanded sheet is than the pill
let kRowHeight: CGFloat = 32      // dropdown row height
let kHeaderHeight: CGFloat = 22   // dropdown section-header (project label) height
let kDropdownVPad: CGFloat = 6    // vertical padding below the pill row, inside the sheet
let kDropdownBottomPad: CGFloat = 6   // padding below the last row, inside the rounded bottom
let kRowInset: CGFloat = 14       // row horizontal inset from the sheet edge
let kFrontPeek: CGFloat = 22      // how far the front pill grows DOWN on hover to show its title
let kFrontExpandRadius: CGFloat = 28  // bottom corner radius while the front pill is expanded

/// One entry in the dropdown: either a project section header or a session row. Headers
/// appear only when the roster spans more than one project; a single-project list is flat.
struct DropdownItem: Identifiable {
    let id: String
    let header: String?     // non-nil → section header label
    let card: SessionCard?  // non-nil → session row
    var isHeader: Bool { header != nil }
}

/// Total pixel height of the dropdown's item stack (headers are shorter than rows).
func dropdownContentHeight(_ items: [DropdownItem]) -> CGFloat {
    items.reduce(0) { $0 + ($1.isHeader ? kHeaderHeight : kRowHeight) }
}

/// Whether a row draws a context ring (shared by the view and the controller's hit-test):
/// only once the window is ≥25% full, and never on the grey idle/stale rows.
func ringVisible(_ card: SessionCard) -> Bool {
    card.context >= 0.25 && card.status != "idle" && card.status != "stale"
}

/// Truncated card label (title or, if empty, project), matching what the view draws.
func cardLabel(_ card: SessionCard) -> String {
    let raw = card.title.isEmpty ? card.project : card.title
    return raw.count > 24 ? String(raw.prefix(24)) + "…" : raw
}

/// Constant on-screen width of a back card — never resizes, only slides. Wide enough to
/// fit its title, but never less than what's needed to still cover the sliver the cursor
/// grabbed (so a hover can't slide the card out from under the pointer).
func cardWidth(_ card: SessionCard, idx: Int) -> CGFloat {
    let titleW = textWidth(cardLabel(card), kCardSansFont)
    return max(titleW + kCardTextPad + kCardTextGap + kCardTuck,
               kCardTuck + CGFloat(idx + 1) * kCardPeek + 30)
}

// MARK: - State

final class IslandState: ObservableObject {
    enum Mode: String { case thinking, working, attention, error, done, compacting, compacted }

    @Published var mode: Mode = .thinking
    @Published var title: String = "Claude Code"
    @Published var detail: String = ""       // left label: verb while working
    @Published var preview: String = ""      // (currently unused for display)
    @Published var elapsed: String = ""      // right label: live turn timer
    @Published var project: String = ""
    @Published var contextPct: Double = 0    // 0…1 fill of the context window
    @Published var focusURL: String = ""     // warp://session/<uuid> for this tab

    // ── Multi-session aggregate (≥2 sessions that have actually run) ─────────────
    // Past one session the front pill stops narrating a single tab and shows fleet
    // counts: a left headline (most important live signal) + grey trailing counts.
    // Computed by the controller's rebuild() from the roster; the single-session
    // fields above still mirror the front tab (harmless — the view ignores them while
    // `aggregate` is true).
    @Published var aggregate = false   // render the count pill, not the single-session one
    @Published var runningCount = 0    // working / thinking / compacting / compacted
    @Published var needYouCount = 0    // attention + error, merged ("go look")
    @Published var doneCount = 0       // done within 15m (stale ones drop out)

    // Notch geometry, set by the controller so the island can match it.
    @Published var notchHeight: CGFloat = 32
    @Published var notchWidth: CGFloat = 200

    // Corner radii (tunable live via the event payload during calibration).
    @Published var topRadius: CGFloat = 12     // re-entrant shoulder fillet
    @Published var bottomRadius: CGFloat = 16  // bottom convex corner

    // Other live sessions, rendered as muted cards stacked behind the front pill,
    // peeking out to the left. Keyed by Warp tab UUID in the real pipeline.
    @Published var cards: [SessionCard] = []

    // Which back card is hovered, driven by AppController's global mouse monitor
    // (SwiftUI's own onHover never fires inside this non-key panel). The view observes
    // this to slide the card out and reveal its title.
    @Published var hoveredCard: String? = nil

    // ── Alternate "dropdown" UI (config: ~/.claude-island/ui-mode = peek | dropdown) ──
    // peek    : back cards stack/peek to the LEFT, hover reveals each title.
    // dropdown: a single "{n} ⌄" back pill peeks to the RIGHT; clicking it drops down a
    //           menu listing every tracked session (dot + name), click a row to focus.
    @Published var uiMode: String = "dropdown"
    @Published var roster: [SessionCard] = []   // every tracked session, for the dropdown
    @Published var dropdownItems: [DropdownItem] = []   // roster grouped by project (+ headers)
    @Published var dropdownOpen = false
    @Published var hoveredRow: String? = nil    // dropdown row under the cursor
    @Published var hoveredRing: String? = nil   // dropdown row whose context ring is hovered

    // Front-pill hover: while true the primary island grows DOWN by kFrontPeek and shows
    // the front session's title at the bottom-center — a quick "which session is this?"
    // peek. Driven by the controller's mouse monitor (onHover never fires in this panel).
    @Published var frontHovered = false

    static let shared = IslandState()
}

/// A background session in the stack (one per other active Warp tab).
struct SessionCard: Identifiable {
    let id: String          // Warp tab UUID
    var project: String = ""
    var title: String = ""  // ai-title, shown on hover
    var status: String = "" // mode string, drives the dot/bg color
    var focus: String = ""  // warp://session/<uuid>
    var isSelected: Bool = false  // highlighted row: the Warp-active tab, else the front session
    var elapsed: String = "" // turn timer text; live while active, frozen when done
    var context: Double = 0  // 0…1 context-window fill, for the per-row ring
    var preview: String = "" // latest action / message, shown grey after the title
}

struct EventPayload: Decodable {
    let mode: String?
    let title: String?
    let detail: String?
    let preview: String?
    let project: String?
    let context: Double?
    let focus: String?
    let topRadius: Double?
    let bottomRadius: Double?
    let cards: [CardPayload]?
}

struct CardPayload: Decodable {
    let id: String?
    let project: String?
    let title: String?
    let status: String?
    let focus: String?
}

/// One session's latest event, written by the hook to sessions/<tabUUID>.json.
struct SessionFile: Decodable {
    let mode: String?
    let detail: String?
    let preview: String?
    let project: String?
    let context: Double?
    let focus: String?
    let id: String?
    let aiTitle: String?
    let cwd: String?
    let ts: Double?
    let kind: String?   // hook event type: prompt | tool | post | attention | stop
    let transcript: String?
}

/// Drives the spinner from a real run-loop timer. SwiftUI's `repeatForever`
/// animations don't reliably run inside a non-activating background panel, so
/// we step the angle ourselves and only run while there's something to spin.
final class Ticker: ObservableObject {
    @Published var angle: Double = 0
    private var timer: Timer?
    static let shared = Ticker()

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.angle = (self.angle + 4).truncatingRemainder(dividingBy: 360)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Geometry

func notchScreen() -> NSScreen {
    if let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return s }
    return NSScreen.main ?? NSScreen.screens[0]
}

/// Physical notch width in points, or a sensible fallback on notch-less Macs.
func notchWidth(_ screen: NSScreen) -> CGFloat {
    if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
        let w = screen.frame.width - left.width - right.width
        if w > 0 { return w }
    }
    return 180
}

// MARK: - Darwin notification bridge

private func darwinCallback(_ center: CFNotificationCenter?,
                            _ observer: UnsafeMutableRawPointer?,
                            _ name: CFNotificationName?,
                            _ object: UnsafeRawPointer?,
                            _ userInfo: CFDictionary?) {
    DispatchQueue.main.async { AppController.shared?.reload() }
}

// MARK: - SwiftUI

/// Embeds an animated GIF via AppKit's NSImageView, which animates GIFs on the
/// main run loop (works inside a background panel where SwiftUI animation won't).
struct GIFView: NSViewRepresentable {
    let path: String
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        v.image = NSImage(contentsOfFile: path)
        // Don't let the image's intrinsic 128px size override the SwiftUI .frame.
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {
        if v.image == nil { v.image = NSImage(contentsOfFile: path) }
    }
}

/// Dynamic-Island silhouette. The top edge spans the full width ("ears"); the
/// body walls are inset by the shoulder radius. Each top shoulder is a concave,
/// re-entrant fillet — a quad whose control point sits at the intersection of the
/// horizontal (top edge) and vertical (wall) tangents, giving a tangent-continuous
/// inward-and-down sweep like the shoulders around an iPhone notch. The bottom
/// corners are ordinary convex rounds.
struct IslandShape: Shape {
    var topRadius: CGFloat = 16     // shoulder (re-entrant) fillet radius
    var bottomRadius: CGFloat = 16  // bottom convex corner radius

    // Let the corner radii interpolate frame-by-frame so the bottom corners round out
    // smoothly as the pill expands (otherwise the radius would snap to its new value).
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = max(0, min(topRadius, w / 2, h))
        let br = max(0, min(bottomRadius, (w - 2 * r) / 2, h - r))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))                                                  // top-left ear
        p.addLine(to: CGPoint(x: w, y: 0))                                               // top edge (full width)
        p.addQuadCurve(to: CGPoint(x: w - r, y: r), control: CGPoint(x: w - r, y: 0))    // right shoulder (concave)
        p.addLine(to: CGPoint(x: w - r, y: h - br))                                      // right wall (inset)
        p.addQuadCurve(to: CGPoint(x: w - r - br, y: h), control: CGPoint(x: w - r, y: h)) // bottom-right convex
        p.addLine(to: CGPoint(x: r + br, y: h))                                          // bottom edge
        p.addQuadCurve(to: CGPoint(x: r, y: h - br), control: CGPoint(x: r, y: h))       // bottom-left convex
        p.addLine(to: CGPoint(x: r, y: r))                                               // left wall (inset)
        p.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: r, y: 0))            // left shoulder (concave)
        p.closeSubpath()
        return p
    }
}

// Real macOS "glass": an NSVisualEffectView with .behindWindow blending, which
// samples and blurs whatever is physically behind the panel (desktop + other app
// windows). SwiftUI's own Material only blurs within-window content, so in this
// transparent borderless panel it can't produce the frosted-glass look — this can.
// Forced dark so the vibrancy reads against the island's dark chrome.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

struct IslandView: View {
    @ObservedObject var state = IslandState.shared

    private static let coral = Color(red: 232 / 255, green: 112 / 255, blue: 78 / 255) // #E8704E

    private static let amber = Color(red: 1.0, green: 0.745, blue: 0.0) // #FFBE00 (reserved: thinking)

    private static let orange = Color(red: 1.0, green: 0.584, blue: 0.0) // #FF9500 (attention: input needed)

    private static let red = Color(red: 0.898, green: 0.282, blue: 0.302) // #E5484D

    private static let compact = Color(red: 142 / 255, green: 165 / 255, blue: 255 / 255) // #8EA5FF

    private var accent: Color {
        switch state.mode {
        case .thinking:  return IslandView.amber
        case .working:   return IslandView.coral
        case .attention: return IslandView.coral
        case .error:     return IslandView.red
        case .done:      return IslandView.green
        case .compacting, .compacted: return IslandView.compact
        }
    }

    // The island matches the notch's height and hangs from the very top edge,
    // wider than the notch, with content wrapping around the camera.
    private var islandHeight: CGFloat { max(state.notchHeight, 30) }

    // Clearance added to the notch gap so text never touches the camera.
    private let notchClearance: CGFloat = 80

    // Real fonts, used to measure label widths deterministically (see textWidth).
    private static let serifFont = NSFont(name: kSerifFontName, size: 13) ?? .systemFont(ofSize: 13)
    private static let sansFont  = NSFont(name: kSansFontName, size: 13) ?? .systemFont(ofSize: 13)

    // Front-pill width, computed deterministically from the parts the pill lays out from
    // (the pill is rendered at EXACTLY this width). Back cards anchor to it, and the
    // controller's hover hit-test reads the same value — so view, cards, and hit-testing
    // never drift. (GeometryReader returns 0 in this panel, so we can't measure instead.)
    private var pillWidth: CGFloat {
        leftW + state.notchWidth + notchClearance + rightW + 36
    }

    // How far the centered island is shifted to keep the notch gap on the camera.
    private var islandOffset: CGFloat { (rightW - leftW) / 2 }

    var body: some View {
        ZStack(alignment: .top) {
            if state.uiMode == "dropdown" {
                // Closed: a "{n} ⌄" back pill peeks RIGHT of the front pill. Open: the
                // island grows into an expanded sheet (wider + taller) holding the list.
                if state.dropdownOpen { expandedSheet }
                if state.roster.count > 1 { agentsBackPill }
                island
                if state.dropdownOpen { dropdownList }
                if state.roster.count > 1 { agentsLabel }
            } else {
                // Back cards are SIBLINGS of the island (not its background) so each
                // card's full frame is hit-testable.
                ForEach(Array(state.cards.enumerated()), id: \.element.id) { idx, card in
                    backCard(idx: idx, card: card)
                }
                island
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.mode)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.hoveredCard)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: state.dropdownOpen)
        .animation(.spring(response: 0.5, dampingFraction: 0.64), value: state.frontHovered)
        .animation(.easeOut(duration: 0.12), value: state.hoveredRow)
        // Grow/shrink the bar smoothly when its width changes (verb/preview text updates)
        // instead of snapping to the new size.
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: pillWidth)
        // Report the live geometry to the controller, which hit-tests the mouse against
        // it (SwiftUI's onHover/GeometryReader don't work in this non-key panel).
        .onChange(of: pillWidth) { AppController.shared?.updateGeom(pillWidth: $0, islandOffset: islandOffset) }
        .onChange(of: islandOffset) { AppController.shared?.updateGeom(pillWidth: pillWidth, islandOffset: $0) }
        .onAppear { AppController.shared?.updateGeom(pillWidth: pillWidth, islandOffset: islandOffset) }
    }

    // A row is "inactive" when its dot is grey — idle tabs and stale (long-finished)
    // sessions, plus any unrecognized status. Mirror this in dotColor's grey cases.
    private func isInactiveStatus(_ status: String) -> Bool {
        !["thinking", "working", "attention", "error", "done", "compacting", "compacted"].contains(status)
    }

    // Status-dot color for a background session.
    private func dotColor(_ status: String) -> Color {
        switch status {
        case "thinking":          return IslandView.amber
        case "working":           return IslandView.coral
        case "attention", "error": return IslandView.red
        case "done":              return IslandView.green
        case "compacting", "compacted": return IslandView.compact
        case "stale":             return Color(white: 0.5)   // done, unattended >15 min
        default:                  return Color(white: 0.55)
        }
    }

    // Other sessions: dark-glass cards tinted by their status color, anchored to the
    // pill's leading edge and nudged left so each peeks a thin sliver. The controller's
    // mouse monitor sets state.hoveredCard; the hovered card slides left to reveal its
    // title (constant width — it only translates, never resizes). Clicking focuses it.
    @ViewBuilder
    private func backCard(idx: Int, card: SessionCard) -> some View {
        let hovered = state.hoveredCard == card.id
        let label = cardLabel(card)
        let w = cardWidth(card, idx: idx)
        let pillLeft = islandOffset - pillWidth / 2
        // Collapsed: left edge a sliver-stack left of the pill (right part tucked under
        // it). Hovered: slide left so the right edge tucks `kCardTuck` under the pill and
        // the title is revealed to the left. Only `off` changes — w is constant.
        let off: CGFloat = hovered
            ? pillLeft + kCardTuck - w / 2
            : pillLeft - CGFloat(idx + 1) * kCardPeek + w / 2

        let shape = IslandShape(topRadius: state.topRadius, bottomRadius: state.bottomRadius)
        let tint = dotColor(card.status)
        ZStack {
            // Frosted glass, solid black for the top half fading to translucent toward
            // the bottom, with a uniform status tint over the whole card.
            shape.fill(.ultraThinMaterial)                       // frosted glass
            shape.fill(LinearGradient(                           // solid-black top → translucent bottom
                stops: [
                    .init(color: Color.black, location: 0.0),
                    .init(color: Color.black, location: 0.5),
                    .init(color: Color.black.opacity(0.5), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom))
            shape.fill(tint.opacity(0.26))                       // status tint
        }
        .environment(\.colorScheme, .dark)                       // dark frost, not washed-out
        .frame(width: w, height: islandHeight)
        .overlay(alignment: .leading) {
            Text(label)
                .font(.custom(kSansFontName, size: 13))
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, kCardTextPad)
                .opacity(hovered ? 1 : 0)
        }
        .opacity(hovered ? 1 : 0.97 - Double(idx) * 0.06)
        .offset(x: off)
        // Collapsed cards stack under the pill (negative z, nearer = higher). A hovered
        // card rises above the other cards but stays BELOW the pill, so its tuck hides
        // under the pill while its revealed title (left of the pill) shows.
        .zIndex(hovered ? -0.5 : Double(-(idx + 1)))
        .contentShape(Rectangle())
        .onTapGesture { AppController.shared?.focusCardTab(card.id) }
    }

    // MARK: - Dropdown mode ("{n} ⌄" back pill + menu)

    // A single dark-glass pill behind the front pill, shifted RIGHT so it peeks a
    // sliver past the pill's right edge, showing the agent count + a chevron. Clicking
    // it toggles the dropdown menu. (Mirror of the left peek cards, but one, on the right.)
    private var agentsBackPill: some View {
        let open = state.dropdownOpen
        let shape = IslandShape(topRadius: state.topRadius, bottomRadius: state.bottomRadius)
        return ZStack {
            // Closed: a soft, mostly-transparent glass card peeks right. Open: NO
            // background — the expanded sheet is the backdrop, and a translucent card
            // here would wash out the (solid-black) notch ticker it overlaps.
            if !open {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.28))
            }
        }
        .environment(\.colorScheme, .dark)
        .frame(width: pillWidth, height: islandHeight)
        // Same width as the pill, shifted right so it peeks `kAgentsPeek` on the right.
        .offset(x: islandOffset + kAgentsPeek)
        .zIndex(-1)
        .contentShape(Rectangle())
        .onTapGesture { AppController.shared?.openDropdown() }
    }

    // The "{n} ⌄" label, rendered as a direct ZStack child positioned at the peek
    // centre (verified against a marker — placing it inside the back card's overlay
    // composed the offset wrong). Purely an indicator; the whole pill is the button.
    private var agentsLabel: some View {
        HStack(spacing: 4) {
            Text("\(state.roster.count)")
                .font(.custom(kSansFontName, size: 13))
                .foregroundColor(.white)
            Image(systemName: state.dropdownOpen ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color(white: 0.7))
        }
        .fixedSize()
        // Box is islandHeight tall so the label centres VERTICALLY with the verb (the
        // ZStack is .top-aligned, which was pinning it to the top). Nudged left of the
        // geometric peek centre so it sits in the solid peek, clear of the right shoulder.
        // The box is the click target too — tapping the indicator opens/closes the menu.
        .frame(width: kAgentsPeek + 14, height: islandHeight)
        .contentShape(Rectangle())
        .offset(x: islandOffset + pillWidth / 2 + kAgentsPeek / 2 - 11)
        .zIndex(1)
        .onTapGesture { AppController.shared?.openDropdown() }
    }

    // Sheet width / total height when expanded (shared with the controller hit-test).
    // The sheet's LEFT edge stays flush with the pill (aligned with the verb); it only
    // grows to the RIGHT (by kSheetSide, to encompass the "{n}" back card) and downward.
    private var sheetWidth: CGFloat { pillWidth + kSheetSide }
    private var sheetOffset: CGFloat { islandOffset + kSheetSide / 2 }  // keeps left edge at pillLeft
    private var sheetListHeight: CGFloat { dropdownContentHeight(state.dropdownItems) + kDropdownVPad + kDropdownBottomPad }

    // The expanded "Dynamic Island" sheet: the SAME silhouette as the pill, grown to the
    // right + downward, hanging from the notch. The notch row stays solid black (it
    // overlaps the physical notch / ticker), and the body below is real macOS glass —
    // a behind-window blur of the desktop, with a light dark tint for legibility — so it
    // no longer just composites the raw desktop text through it. Pill content sits on the
    // top row; the session list fills the body below.
    private var expandedSheet: some View {
        let shape = IslandShape(topRadius: state.topRadius, bottomRadius: 22)
        let total = islandHeight + sheetListHeight
        let notchFrac = min(0.92, islandHeight / total)   // the whole notch row stays solid black
        return ZStack {
            // Frosted glass backdrop: blurs whatever is behind the panel. `.hudWindow` is
            // the only DARK material — the lighter ones (.popover/.sidebar) add a grey-white
            // haze that reads as "milky frost"; this keeps a clean dark vibrant blur.
            VisualEffectBlur(material: .hudWindow)
                .clipShape(shape)
            // Solid black across the notch row, then a light dark tint over the glass for
            // the body — enough contrast for white text without hiding the blur.
            shape.fill(LinearGradient(
                stops: [
                    .init(color: Color.black, location: 0.0),
                    // Hold solid black a bit past the notch row, then fade slowly all the
                    // way to the bottom so the glass eases in (no hard band).
                    .init(color: Color.black, location: min(0.92, notchFrac + 0.16)),
                    .init(color: Color.black.opacity(0.1), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom))
        }
        .frame(width: sheetWidth, height: total)
        .offset(x: sheetOffset)
        .zIndex(-2)
    }

    // The session rows (grouped by project, with headers when >1 project), stacked in the
    // sheet body just below the pill row.
    private var dropdownList: some View {
        VStack(spacing: 0) {
            ForEach(state.dropdownItems) { item in
                if let h = item.header { dropdownHeader(h) }
                else if let c = item.card { dropdownRow(c) }
            }
        }
        .frame(width: sheetWidth - 2 * kRowInset)
        .offset(x: sheetOffset, y: islandHeight + kDropdownVPad)
        .zIndex(-1)
    }

    // A project section header — a small, dim label above its group of rows.
    private func dropdownHeader(_ title: String) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.custom(kSansFontName, size: 11))
                .foregroundColor(Color(white: 0.45))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 2)   // a little breathing room between the label and its first row
        .frame(width: sheetWidth - 2 * kRowInset, height: kHeaderHeight, alignment: .bottomLeading)
    }

    // Leading marker for a row: an attention session (permission / waiting on the user)
    // shows a red exclamation to flag it needs action; everything else is a status dot.
    // Both occupy the same 8-pt slot so the title stays aligned across rows.
    @ViewBuilder
    private func rowMarker(_ status: String) -> some View {
        if status == "attention" {
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(IslandView.orange)
                .frame(width: 8)
        } else if status == "compacted" {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(IslandView.compact)
                .frame(width: 8)
        } else {
            Circle().fill(dotColor(status)).frame(width: 8, height: 8)
        }
    }

    private func dropdownRow(_ card: SessionCard) -> some View {
        let hl = state.hoveredRow == card.id
        // The selected session (Warp-active tab, else front) reads as "selected": a soft
        // persistent tint, lighter than the hover highlight. Hovering bumps to full alpha.
        let rowBG: Color = hl ? Color.white.opacity(0.13)
            : (card.isSelected ? Color.white.opacity(0.10) : Color.clear)
        // Inactive rows (grey dot — idle / stale) get a grey title too, so the whole row
        // recedes and the active sessions read first.
        let titleColor: Color = isInactiveStatus(card.status)
            ? Color(white: 0.5)
            : (card.isSelected ? .white : Color(white: 0.9))
        return HStack(spacing: 10) {
            rowMarker(card.status)
            Group {
                // A just-compacted session flags itself with a blue "Compacted" prefix, and
                // a session waiting on the user with an orange "Input Needed" one, so the state
                // is legible in the list ahead of the tab's own title.
                if card.status == "compacted" {
                    Text("Compacted ").foregroundColor(IslandView.compact)
                        + Text(card.title.isEmpty ? card.project : card.title).foregroundColor(titleColor)
                } else if card.status == "attention" {
                    Text("Input Needed ").foregroundColor(IslandView.orange)
                        + Text(card.title.isEmpty ? card.project : card.title).foregroundColor(titleColor)
                } else {
                    Text(card.title.isEmpty ? card.project : card.title).foregroundColor(titleColor)
                }
            }
            .font(.custom(kSansFontName, size: 13))
            .lineLimit(1)
            .layoutPriority(1)            // title keeps its width; preview yields first
            // Latest action / message in grey, filling the gap and truncating with an
            // ellipsis. Its expanding frame also right-pins the ring + timer.
            if !card.preview.isEmpty {
                Text(card.preview)
                    .font(.custom(kSansFontName, size: 12))
                    .foregroundColor(Color(white: 0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 8)
            }
            // Per-session context-window fill, mirroring the front pill's ring — only for
            // active/done rows, not the grey ones (idle / stale). Sits LEFT of the timer.
            // Hovering it floats a small label above (SwiftUI hover can't fire in this panel,
            // so the controller's mouse hit-test drives `hoveredRing`).
            if ringVisible(card) {
                ContextRing(pct: card.context)
                    .overlay(alignment: .top) {
                        if state.hoveredRing == card.id {
                            Text("\(Int((card.context * 100).rounded()))% context used")
                                .font(.custom(kSansFontName, size: 11))
                                .foregroundColor(.white)
                                .fixedSize()
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Capsule(style: .continuous).fill(Color.black.opacity(0.92)))
                                .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
                                .offset(y: -20)
                                .zIndex(100)
                                .allowsHitTesting(false)
                        }
                    }
            }
            if !card.elapsed.isEmpty {
                Text(card.elapsed)
                    .font(.custom(kSansFontName, size: 12))
                    .monospacedDigit()
                    .foregroundColor(card.status == "done" ? IslandView.green : Color(white: 0.5))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(width: sheetWidth - 2 * kRowInset, height: kRowHeight)
        // Highlight sits inside the row with a sliver of padding all round, fully rounded
        // (capsule) so it never pokes past the sheet's rounded bottom corners.
        .background(
            RoundedRectangle(cornerRadius: (kRowHeight - 4) / 2)
                .fill(rowBG)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { AppController.shared?.focusCardTab(card.id) }
    }

    // Width reserved for the leading icon (gif / image / glyph) + spacing.
    private var leadingSlot: CGFloat {
        let iconW: CGFloat
        if state.aggregate {
            iconW = aggKind == .needYou ? 14 : 18   // "!" is 14; gif / "✓" are 18
        } else {
            iconW = state.mode == .attention ? 14 : (state.mode == .error ? 16 : 18)
        }
        return iconW + (primary.isEmpty ? 0 : 8)
    }

    // ── Fleet aggregate (≥2 sessions) ───────────────────────────────────────────
    // The left headline is the single most important live signal; need-you always
    // wins it (red), then running, then done. Whatever isn't the headline trails on
    // the right in grey — need-you never appears there.
    private enum AggKind { case needYou, running, done }
    private var aggKind: AggKind {
        if state.needYouCount > 0 { return .needYou }
        if state.runningCount > 0 { return .running }
        return .done
    }
    private var aggHeadline: String {
        switch aggKind {
        case .needYou: return "\(state.needYouCount) need you"
        case .running: return "\(state.runningCount) running…"
        case .done:    return "\(state.doneCount) done"
        }
    }
    private var aggRight: String {
        var parts: [String] = []
        if aggKind != .running, state.runningCount > 0 { parts.append("\(state.runningCount) running") }
        if aggKind != .done,    state.doneCount    > 0 { parts.append("\(state.doneCount) done") }
        return parts.joined(separator: " · ")
    }
    private var leftW: CGFloat {
        leadingSlot + textWidth(primary, IslandView.serifFont, tracking: 0.5)
    }
    // Right cluster: leading pad (3) + message text. The context ring now lives per-row in
    // the dropdown, so the front pill no longer draws it (would be redundant).
    private var rightW: CGFloat {
        3 + textWidth(rightText, IslandView.sansFont)
    }

    private static let green = Color(red: 0.45, green: 0.82, blue: 0.52)

    // Verb/label color matches the state.
    private var primaryColor: Color {
        if state.aggregate {
            switch aggKind {
            case .needYou: return IslandView.red
            case .running: return IslandView.coral
            case .done:    return IslandView.green
            }
        }
        switch state.mode {
        case .thinking: return IslandView.amber
        case .done:     return IslandView.green
        case .error:    return IslandView.red
        case .compacting, .compacted: return IslandView.compact
        default:        return IslandView.coral
        }
    }

    private static let clipLen = 18
    private func clip(_ s: String) -> String {
        let m = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return "" }
        guard m.count > IslandView.clipLen else { return m }
        return String(m.prefix(IslandView.clipLen)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // Right side: live timer while thinking; a clip of Claude's message/action
    // while working, on done, and for permission prompts.
    private var rightText: String {
        if state.aggregate { return aggRight }
        switch state.mode {
        case .thinking:                  return state.elapsed
        // When a working event has no verb, the preview is promoted to the left as the
        // verb — so suppress it here to avoid showing the same text on both sides.
        case .working:                   return state.detail.isEmpty ? "" : clip(state.preview)
        case .done, .attention, .error:  return clip(state.preview)
        case .compacting, .compacted:    return ""
        }
    }

    private var island: some View {
        // Each cluster is laid out at EXACTLY its CoreText-measured width, so the pill's
        // total rendered width is deterministically `pillWidth` (left + gap + right +
        // padding). That's what lets the back cards anchor to the real pill edge — they
        // peek off the same `pillWidth` the pill is actually drawn at, never an estimate
        // that drifts. (`fixedSize` on the text means a sub-pixel measurement difference
        // overflows invisibly into the gap rather than clipping the text.)
        HStack(spacing: 0) {
            // Left: gif/icon + verb.
            HStack(spacing: 8) {
                leading
                if !primary.isEmpty {
                    Text(primary)
                        .font(.custom(kSerifFontName, size: 13))
                        .tracking(0.5)
                        .foregroundColor(primaryColor)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(width: leftW, alignment: .leading)

            // Centered notch gap (+ clearance so text never touches the camera).
            Color.clear.frame(width: state.notchWidth + notchClearance)

            // Right: message/timer (context ring moved to the dropdown rows).
            HStack(spacing: 7) {
                if !rightText.isEmpty {
                    Text(rightText)
                        .font(.custom(kSansFontName, size: 13))
                        .fontWeight(.regular)
                        .monospacedDigit()                  // tabular-nums: stable digit width
                        .foregroundColor(Color(white: 0.62))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.leading, 3)
            .frame(width: rightW, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(width: pillWidth, height: islandHeight)   // top row stays pinned to the notch
        // Background grows DOWN by the peek on hover; the row above stays put, and the
        // session title fades in at the bottom-center of the revealed strip.
        .frame(width: pillWidth, height: islandHeight + frontPeekH, alignment: .top)
        .background(
            // When the dropdown is open, the expanded sheet draws the background; the
            // pill's own shape would otherwise leave a seam mid-sheet. While expanded the
            // bottom corners round out more (animated via IslandShape.animatableData) so
            // the grown pill reads as a soft lozenge rather than a stretched rectangle.
            IslandShape(topRadius: state.topRadius,
                        bottomRadius: frontPeekH > 0 ? kFrontExpandRadius : state.bottomRadius)
                .fill(state.dropdownOpen ? Color.clear : Color.black)
        )
        .overlay(alignment: .bottom) {
            if frontPeekH > 0 && !state.title.isEmpty {
                Text(state.title)
                    .font(.custom(kSansFontName, size: 11))
                    .foregroundColor(Color(white: 0.66))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: pillWidth - 28)
                    .padding(.bottom, 5)
                    // Fade + rise into place so it doesn't just blink on.
                    .opacity(state.frontHovered ? 1 : 0)
                    .offset(y: state.frontHovered ? 0 : 5)
                    .environment(\.colorScheme, .dark)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { AppController.shared?.handleIslandClick() }
        // Shift so the notch gap stays centered on the camera even when the two
        // sides differ in width — neither side can slide behind the notch.
        .offset(x: islandOffset)
    }

    // Extra height the front pill takes on hover (0 normally). Suppressed while the
    // dropdown is open — the expanded sheet already names every session there.
    private var frontPeekH: CGFloat { (state.frontHovered && !state.dropdownOpen) ? kFrontPeek : 0 }

    private var primary: String {
        if state.aggregate { return aggHeadline }
        switch state.mode {
        case .error: return "Error"
        case .compacting: return "Compacting…"
        case .compacted:  return "Compacted"
        case .done:  return state.elapsed.isEmpty ? "Finished" : "Finished " + state.elapsed
        // working: verb; thinking: "Thinking…"; attention: label. A malformed/partial
        // working event can carry a preview but no verb — fall back to the preview so the
        // left side is never a bare gif (the right side drops it to avoid duplication).
        case .working: return state.detail.isEmpty ? state.preview : state.detail
        default:     return state.detail
        }
    }

    @ViewBuilder private func icon(_ path: String, fallback: AnyView) -> some View {
        if FileManager.default.fileExists(atPath: path) {
            GIFView(path: path).frame(width: 18, height: 18).clipped()
        } else {
            fallback
        }
    }

    @ViewBuilder private var leading: some View {
        if state.aggregate {
            switch aggKind {
            case .needYou:
                Image(systemName: "exclamationmark").font(.system(size: 13, weight: .bold)).foregroundColor(IslandView.red).frame(width: 14)
            case .running:
                icon(kGifPath, fallback: AnyView(Spinner(accent: IslandView.coral, mode: .working)))
            case .done:
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(IslandView.green).frame(width: 18)
            }
        } else {
            leadingSingle
        }
    }

    @ViewBuilder private var leadingSingle: some View {
        switch state.mode {
        case .thinking:
            icon(kThinkingGifPath, fallback: AnyView(Spinner(accent: accent, mode: .working)))
        case .working:
            icon(kGifPath, fallback: AnyView(Spinner(accent: accent, mode: .working)))
        case .attention:
            Image(systemName: "exclamationmark").font(.system(size: 13, weight: .bold)).foregroundColor(accent).frame(width: 14)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold)).foregroundColor(accent).frame(width: 16)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(accent).frame(width: 18)
        case .compacting:
            icon(kCompactingGifPath, fallback: AnyView(Circle().fill(accent).frame(width: 9, height: 9).frame(width: 18)))
        case .compacted:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(accent).frame(width: 18)
        }
    }
}

struct Spinner: View {
    let accent: Color
    let mode: IslandState.Mode
    @ObservedObject private var ticker = Ticker.shared

    var body: some View {
        Group {
            switch mode {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(accent)
            case .attention:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(accent)
            default:
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(ticker.angle))
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// Context-window fill gauge. Grey track (matching the preview text), with the filled
/// arc swept clockwise from 12 o'clock — white when low, amber past a third, red past half.
struct ContextRing: View {
    let pct: Double
    // Warn as the window fills: white < 30%, amber 30–50%, red > 50%.
    private var fillColor: Color {
        if pct > 0.5  { return Color(red: 0.898, green: 0.282, blue: 0.302) }  // red
        if pct > 0.30 { return Color(red: 1.0, green: 0.745, blue: 0.0) }      // amber
        return .white
    }
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(white: 0.62).opacity(0.55), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, pct)))
                .stroke(fillColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .animation(.easeOut(duration: 0.3), value: pct)
    }
}

// MARK: - Panel

/// Hosting view that accepts clicks even though the panel is non-activating and never
/// becomes key — otherwise the first click on the island/chevron is swallowed by the
/// window server instead of reaching SwiftUI's tap gestures.
final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Start transparent to clicks; the controller flips this to false (per mouse-move)
        // only while the cursor is actually over the island, so the rest of this wide panel
        // never steals clicks from the menu bar / status items beneath it. (Returning nil
        // from the view's hitTest does NOT forward clicks to other apps' windows — verified
        // — so ignoresMouseEvents is the only reliable passthrough.)
        ignoresMouseEvents = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// Resolved, in-memory state for one Warp-tab session, merged across its events.
/// A session exists only once it has fired at least one hook (i.e. actually run);
/// open-but-never-run tabs are intentionally NOT shown.
final class LiveSession {
    var mode = "thinking"
    var detail = ""
    var preview = ""
    var project = ""
    var aiTitle = ""
    var context = 0.0
    var focus = ""
    var cwd = ""
    var ts = 0.0          // last event time (epoch)
    var promptTs = 0.0    // last UserPromptSubmit — the "you're focused here" signal
    var turnStartTs = 0.0 // start of the current turn, for the elapsed timer
    var transcript = ""   // transcript path, polled to detect user-cancel (Esc)
}

final class AppController: NSObject, NSApplicationDelegate {
    static var shared: AppController?

    private var panel: NotchPanel!
    private var clockTimer: Timer?
    private var gcTimer: Timer?
    private var liveTimer: Timer?   // fast poll of CC's live status + transcript tail

    private var sessions: [String: LiveSession] = [:]
    private var liveTabs: Set<String> = []      // interactive (non-forked) tab UUIDs
    private var lastSeenLive: [String: Double] = [:]   // uuid → last scan that saw it (debounce)
    private var liveTabCwd: [String: String] = [:]     // uuid → cwd, for idle (no-file) tab labels
    private var liveTabTitle: [String: String] = [:]   // uuid → last-known label, kept after a file is gone
    private var liveTabContext: [String: Double] = [:]  // uuid → last-known context fill, for idle rings
    private var projectOrder: [String] = []             // dropdown group order, by first-seen (never reshuffled)
    private var activeWarpTab: String?                  // uuid of the tab focused in Warp (drives row highlight)
    private var lastDbActiveTab: String?                // last active tab Warp's DB reported (to detect real switches)
    private var clickFocus: String?             // a tab the user clicked → pin to front
    private var clickFocusTs: Double = 0        // newest activity ts at click time; the pin
                                                // releases once any tab posts something newer
    private var dropdownFrozenOrder: [String]?  // row id order locked while the menu is open,
                                                // so rows don't reshuffle under the cursor
    private var frontUUID: String?              // current front-pill session

    // Live pill geometry, reported by the view (which computes it deterministically).
    // The mouse monitor hit-tests the cursor against this — both use the same numbers,
    // so what's drawn and what's hoverable can't drift. Set/read on the main thread.
    private var curPillWidth: CGFloat = 0
    private var curIslandOffset: CGFloat = 0
    private var mouseMonitors: [Any] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        AppController.shared = self
        registerFonts()

        // UI mode: "peek" (left peek cards) or "dropdown" ({n}⌄ back pill → menu).
        if let m = try? String(contentsOfFile: kEventDir + "/ui-mode", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            IslandState.shared.uiMode = m
        }

        // Persisted dropdown group order (first-seen project names, one per line) so the
        // dir headers keep their "when first opened" order across daemon restarts.
        if let raw = try? String(contentsOfFile: kProjectOrderFile, encoding: .utf8) {
            projectOrder = raw.split(separator: "\n").map(String.init)
        }

        let hosting = ClickableHostingView(rootView: IslandView())
        hosting.frame = NSRect(x: 0, y: 0, width: 1100, height: 160)
        hosting.autoresizingMask = [.width, .height]

        panel = NotchPanel()
        panel.contentView = hosting
        position()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center,
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        darwinCallback,
                                        kDarwinName as CFString,
                                        nil,
                                        .deliverImmediately)

        // Reposition if displays change (external monitor, resolution).
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(position),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        // Periodic liveness scan: prune sessions whose tab closed or whose turn the
        // user canceled (Esc), then refresh the deck. The process/transcript IO runs
        // off the main thread so it never freezes the bar.
        let g = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            self?.refreshLiveness()
        }
        RunLoop.main.add(g, forMode: .common)
        gcTimer = g

        // Fast live poll: reads CC's own busy/idle status files and tails each transcript so
        // the verb/preview/active-state track real activity at sub-second latency instead of
        // only updating when a hook fires (the "always one transcript behind" problem). All
        // IO runs off the main thread; it no-ops when there are no sessions.
        let lt = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.pollLiveStatus()
        }
        lt.tolerance = 0.2
        RunLoop.main.add(lt, forMode: .common)
        liveTimer = lt

        // Drive back-card hover ourselves. SwiftUI's onHover relies on a tracking area
        // that only fires in the key window, and this non-activating panel can never
        // become key — so onHover never fires (verified). Instead we watch mouse moves
        // globally (when another app is active, the normal case for us) and locally, and
        // hit-test the cursor against the deterministic pill geometry.
        panel.acceptsMouseMovedEvents = true
        let gm = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            self?.updateHover()
        })
        let lm = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in
            self?.updateHover(); return e
        })
        // Click-outside dismiss: while the dropdown is open, a mouse-down anywhere outside
        // the expanded sheet closes it. Global catches clicks in other apps; local catches
        // clicks on our own panel's transparent areas. Neither consumes the event.
        let gd = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.dismissDropdownIfOutside(NSEvent.mouseLocation)
        })
        let ld = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            self?.dismissDropdownIfOutside(NSEvent.mouseLocation); return e
        })
        mouseMonitors = [gm, lm, gd, ld].compactMap { $0 }

        refreshLiveness()
        reload()
    }

    /// Called by the view whenever the pill's drawn geometry changes, so the hover
    /// hit-test below stays in lockstep with what's on screen.
    func updateGeom(pillWidth: CGFloat, islandOffset: CGFloat) {
        curPillWidth = pillWidth
        curIslandOffset = islandOffset
        // Re-hit-test against the cursor's current spot: the front pill shifting (its
        // own text changing) moves the cards, so a card shouldn't stay revealed under a
        // cursor it's no longer beneath, even if the mouse itself hasn't moved.
        updateHover()
    }

    /// Hit-test the mouse against the back-card slivers and update the hovered card.
    /// Runs on the main thread (NSEvent monitors fire there).
    private func updateHover() {
        let p = NSEvent.mouseLocation                 // screen coords, origin bottom-left
        let f = panel.frame
        let s = IslandState.shared

        // Capture clicks only while the cursor is over the island; otherwise stay
        // transparent so the menu bar / status items underneath remain clickable.
        let overIsland = pointInIslandHitArea(p)
        panel.ignoresMouseEvents = !overIsland

        // Front-pill peek: hovering the primary pill grows it down to show the session
        // title. Suppressed while the dropdown is open (the sheet names everything there).
        let front = !s.dropdownOpen && pointInFrontPill(p)
        if s.frontHovered != front { setFrontHover(front) }

        // Dropdown mode: hover-driven open/close. Hovering the "{n} ⌄" peek drops the
        // menu down; moving the cursor off the expanded sheet closes it. (SwiftUI's
        // onHover never fires in this non-key panel, so we drive it from the monitor.)
        // The trigger is the peek only — never the front pill — so the front ticker's
        // own hover/click-to-focus is unaffected. Once open, `overIsland` covers the
        // whole sheet, so the larger sheet region holds it open until the cursor leaves.
        if s.uiMode == "dropdown" {
            if s.roster.count > 1 {
                if !s.dropdownOpen {
                    if pointInBackPillPeek(p) { openDropdown() }
                } else if !overIsland {
                    closeDropdown()
                }
            }
            updateRowHover(p: p, f: f)
            return
        }

        let cards = s.cards
        let cur = s.hoveredCard
        // Only when the cursor is within the island's strip; otherwise no hover.
        guard p.x >= f.minX, p.x <= f.maxX, p.y >= f.minY, p.y <= f.maxY, !cards.isEmpty else {
            if cur != nil { setHover(nil) }
            return
        }
        // The hosting view fills the panel and the ZStack is centered, so the pill's
        // center sits at the panel's horizontal center + islandOffset.
        let pillLeft = f.midX + curIslandOffset - curPillWidth / 2
        // Keep the current card hovered while the cursor is within its EXPANDED rect, so
        // moving onto the revealed title doesn't drop the hover.
        if let cur, let i = cards.firstIndex(where: { $0.id == cur }) {
            let w = cardWidth(cards[i], idx: i)
            if p.x >= pillLeft + kCardTuck - w, p.x <= pillLeft + kCardTuck { return }
        }
        // Otherwise pick the collapsed sliver the cursor is over (each is kCardPeek wide
        // and they abut, so there's no overlap to flicker between).
        for (idx, card) in cards.enumerated() {
            let sLeft = pillLeft - CGFloat(idx + 1) * kCardPeek
            let sRight = pillLeft - CGFloat(idx) * kCardPeek
            if p.x >= sLeft, p.x < sRight {
                if cur != card.id { setHover(card.id) }
                return
            }
        }
        if cur != nil { setHover(nil) }
    }

    /// True if a screen point falls within the island's clickable region (the pill, its
    /// "{n} ⌄" right peek, and the expanded sheet when open). Used by the hosting view to
    /// pass every other click through to the menu bar. A few px of margin so edge taps land.
    func pointInIslandHitArea(_ p: NSPoint) -> Bool {
        let s = IslandState.shared
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        let center = f.midX + curIslandOffset          // pill center on screen
        let m: CGFloat = 4
        let left = center - curPillWidth / 2
        var right = center + curPillWidth / 2
        var bottom = f.maxY - islandH
        let top = f.maxY
        if s.roster.count > 1 { right += kAgentsPeek }  // "{n} ⌄" back pill peeks right
        if s.frontHovered && !s.dropdownOpen { bottom -= kFrontPeek }  // title-peek strip stays clickable
        if s.dropdownOpen {
            right = left + curPillWidth + kSheetSide     // sheet grows right…
            bottom = f.maxY - (islandH + dropdownContentHeight(s.dropdownItems) + kDropdownVPad + kDropdownBottomPad)  // …and down
        }
        return p.x >= left - m && p.x <= right + m && p.y >= bottom - m && p.y <= top
    }

    /// True if a screen point falls within the "{n} ⌄" peek band — the strip just right
    /// of the front pill where the back-pill indicator sits. This is the hover-open
    /// trigger (deliberately the peek only, so hovering the front ticker never opens the
    /// menu). Geometry mirrors the right edge used by `pointInIslandHitArea`.
    private func pointInBackPillPeek(_ p: NSPoint) -> Bool {
        let s = IslandState.shared
        guard s.roster.count > 1 else { return false }
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        let pillRight = f.midX + curIslandOffset + curPillWidth / 2
        let m: CGFloat = 4
        return p.x >= pillRight - m && p.x <= pillRight + kAgentsPeek + m
            && p.y >= f.maxY - islandH && p.y <= f.maxY
    }

    /// True if a screen point falls within the front pill — the trigger for the title
    /// peek. Once the peek is showing, the live region extends down by kFrontPeek so the
    /// cursor moving onto the revealed title strip holds it open (hysteresis, no flicker).
    private func pointInFrontPill(_ p: NSPoint) -> Bool {
        let s = IslandState.shared
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        let center = f.midX + curIslandOffset
        let left = center - curPillWidth / 2
        let right = center + curPillWidth / 2
        let bottom = f.maxY - islandH - (s.frontHovered ? kFrontPeek : 0)
        return p.x >= left && p.x <= right && p.y >= bottom && p.y <= f.maxY
    }

    /// Close the open dropdown when a click lands outside the expanded sheet's bounds.
    private func dismissDropdownIfOutside(_ p: NSPoint) {
        let s = IslandState.shared
        guard s.dropdownOpen else { return }
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        // Same silhouette the sheet is drawn at: flush-left with the pill, extending
        // kSheetSide right and the row stack + paddings down from the notch top.
        let leftEdge = f.midX + curIslandOffset - curPillWidth / 2
        let rightEdge = leftEdge + curPillWidth + kSheetSide
        let sheetH = islandH + dropdownContentHeight(s.dropdownItems) + kDropdownVPad + kDropdownBottomPad
        let inside = p.x >= leftEdge && p.x <= rightEdge && p.y <= f.maxY && p.y >= f.maxY - sheetH
        if !inside { closeDropdown() }
    }

    /// Hit-test the cursor against the open dropdown's rows (walking the item stack, since
    /// project headers are shorter than rows and only a row should register a hover).
    private func updateRowHover(p: NSPoint, f: NSRect) {
        let s = IslandState.shared
        let items = s.dropdownItems
        guard s.dropdownOpen, !items.isEmpty else {
            if s.hoveredRow != nil { s.hoveredRow = nil }
            if s.hoveredRing != nil { s.hoveredRing = nil }
            return
        }
        let islandH = max(s.notchHeight, 30)
        // Rows fill the sheet, whose left edge is flush with the pill and which extends
        // kSheetSide to the right. Screen coords have origin bottom-left, so items go DOWN.
        let leftEdge = f.midX + curIslandOffset - curPillWidth / 2
        let rightEdge = leftEdge + curPillWidth + kSheetSide
        let listRight = rightEdge - kRowInset       // rows are inset kRowInset inside the sheet
        let contentTop = f.maxY - islandH - kDropdownVPad
        guard p.x >= leftEdge, p.x <= rightEdge, p.y <= contentTop, p.y >= contentTop - dropdownContentHeight(items) else {
            if s.hoveredRow != nil { setRow(nil) }
            if s.hoveredRing != nil { s.hoveredRing = nil }
            return
        }
        var y = contentTop
        for item in items {
            let h = item.isHeader ? kHeaderHeight : kRowHeight
            if p.y <= y, p.y > y - h {
                let id = item.card?.id            // nil over a header → clears hover
                if s.hoveredRow != id { setRow(id) }
                // The ring sits LEFT of the (variable-width) timer: trailing pad (12), then
                // the timer, then a 10px gap, then the 12px ring. Locate that band.
                let overRing: Bool = item.card.map { card in
                    guard ringVisible(card) else { return false }
                    let timerW = card.elapsed.isEmpty ? 0 : textWidth(card.elapsed, kTimerFont)
                    let ringRight = listRight - 12 - (timerW > 0 ? timerW + 10 : 0)
                    return p.x >= ringRight - 12 - 6 && p.x <= ringRight + 6
                } ?? false
                let ringID = overRing ? id : nil
                if s.hoveredRing != ringID { s.hoveredRing = ringID }
                return
            }
            y -= h
        }
        if s.hoveredRow != nil { setRow(nil) }
        if s.hoveredRing != nil { s.hoveredRing = nil }
    }

    private func setRow(_ id: String?) {
        withAnimation(.easeOut(duration: 0.1)) { IslandState.shared.hoveredRow = id }
    }

    private func setHover(_ id: String?) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            IslandState.shared.hoveredCard = id
        }
    }

    private func setFrontHover(_ on: Bool) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.64)) {
            IslandState.shared.frontHovered = on
        }
    }

    /// Run the expensive process scan + transcript checks on a background queue,
    /// then apply the results (prune dead/canceled sessions, rebuild) on main.
    private func refreshLiveness() {
        let active = sessions
            .filter { $0.value.mode == "thinking" || $0.value.mode == "working" }
            .map { ($0.key, $0.value.transcript) }
        // Every session's transcript, so a /rename (which fires no hook) is picked up here
        // within a scan cycle instead of waiting for that tab's next activity.
        let titleScan = sessions.compactMap { $0.value.transcript.isEmpty ? nil : ($0.key, $0.value.transcript) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let live = self.computeLiveTabs()
            let warpTab = self.warpActiveTab()
            var interrupted = Set<String>()
            for (uuid, tx) in active where !tx.isEmpty {
                if self.transcriptInterrupted(tx) { interrupted.insert(uuid) }
            }
            var titles: [String: String] = [:]
            for (uuid, tx) in titleScan {
                if let t = self.transcriptTitle(tx), !t.isEmpty { titles[uuid] = t }
            }
            DispatchQueue.main.async {
                let now = Date().timeIntervalSince1970
                self.applyDBActiveTab(warpTab)
                // Apply any renamed titles (manual /rename wins over the auto ai-title).
                for (u, t) in titles where self.sessions[u]?.aiTitle != t {
                    self.sessions[u]?.aiTitle = t
                    self.liveTabTitle[u] = t
                }
                for (u, c) in live {
                    self.lastSeenLive[u] = now
                    if !c.isEmpty { self.liveTabCwd[u] = c }
                }
                // A tab counts as live if a scan saw it in the last 8s — smooths a single
                // transient `ps` miss (scans are every 4s) so a live tab never flickers
                // out, while a genuinely-closed tab clears in ~8-12s.
                self.liveTabs = Set(self.lastSeenLive.filter { now - $0.value < 8 }.keys)
                self.liveTabs.insert("local")
                // Only canceled turns delete a file; dead tabs are just hidden by the
                // liveTabs filter (their file lingers harmlessly until they reappear).
                let fm = FileManager.default
                for k in interrupted {
                    self.sessions.removeValue(forKey: k)
                    self.lastSeenLive.removeValue(forKey: k)
                    try? fm.removeItem(atPath: kSessionsDir + "/" + k + ".json")
                }
                self.rebuild()
            }
        }
    }

    /// Size and pin the panel to the top-center of the notch screen.
    @objc func position() {
        let screen = notchScreen()
        let nh = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top
                                               : (NSApp.mainMenu?.menuBarHeight ?? 32)
        IslandState.shared.notchHeight = nh
        IslandState.shared.notchWidth = notchWidth(screen)

        // Only as tall as the menu-bar strip (never blocks clicks below it), and
        // wide enough that an expanded card never hits the panel bound and clips,
        // but not so wide it covers the app menus / status items. When the dropdown is
        // open the panel grows down to make room for the menu (transparent elsewhere, so
        // clicks outside the menu still pass through to the apps below).
        let w: CGFloat = 1100
        let s = IslandState.shared
        let dropH = s.dropdownOpen ? dropdownContentHeight(s.dropdownItems) + kDropdownVPad + kDropdownBottomPad : 0
        // Always reserve room for the front-pill hover peek so its expand/collapse animates
        // smoothly inside a transparent panel (no resize-on-hover that would clip the spring).
        let h: CGFloat = max(nh, 30) + 2 + max(dropH, kFrontPeek)
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - h
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    /// Open the dropdown menu (idempotent) and resize the panel to fit it. Driven by
    /// hovering the "{n} ⌄" peek; a tap on the peek also calls this as a fallback. It
    /// never closes — closing is purely hover-leave (or a click outside the sheet) — so a
    /// tap while the cursor still rests on the peek can't toggle it shut and reopen.
    func openDropdown() {
        let s = IslandState.shared
        guard !s.dropdownOpen else { return }
        s.dropdownOpen = true
        refreshActiveTab()   // freshest active-tab highlight on open
        // Lock the current row order on open so timers/activity can't reshuffle rows under
        // the cursor; release it on close so the list re-sorts by recency again.
        dropdownFrozenOrder = s.roster.map { $0.id }
        position()
    }
    func closeDropdown() {
        guard IslandState.shared.dropdownOpen else { return }
        IslandState.shared.dropdownOpen = false
        dropdownFrozenOrder = nil
        position()
    }

    // MARK: - Session ingest

    /// Re-read every session file (a Darwin ping means one just changed) and rebuild.
    /// The files are the source of truth: a session whose file is gone is dropped,
    /// even if its tab is still live.
    func reload() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: kSessionsDir)) ?? []).filter { $0.hasSuffix(".json") }
        let existing = Set(files.map { ($0 as NSString).deletingPathExtension })
        for k in sessions.keys where !existing.contains(k) { sessions.removeValue(forKey: k) }
        for f in files {
            guard let data = fm.contents(atPath: kSessionsDir + "/" + f),
                  let sf = try? JSONDecoder().decode(SessionFile.self, from: data) else { continue }
            merge(sf, fallbackID: (f as NSString).deletingPathExtension)
        }
        rebuild()
    }

    /// Merge one event into a session, retaining fields the event omitted.
    private func merge(_ sf: SessionFile, fallbackID: String) {
        let id = sf.id ?? fallbackID
        let s = sessions[id] ?? LiveSession()
        sessions[id] = s
        if let v = sf.mode { s.mode = v }
        if let v = sf.detail { s.detail = v }
        if let v = sf.preview { s.preview = v }   // omitted by emit_keep → retained
        if let v = sf.project { s.project = v }
        if let v = sf.aiTitle, !v.isEmpty { s.aiTitle = v }
        // Remember the label (title, else project) so a later idle entry for this tab —
        // after its file is deleted/interrupted — shows the title, not just the dir.
        let label = s.aiTitle.isEmpty ? s.project : s.aiTitle
        if !label.isEmpty { liveTabTitle[id] = label }
        if let v = sf.context { s.context = v; if v > 0 { liveTabContext[id] = v } }
        // Compaction shrank the window: drop the remembered fill so a later idle entry
        // for this tab doesn't resurrect the stale pre-compaction ring.
        if s.mode == "compacted" { liveTabContext[id] = 0 }
        if let v = sf.focus { s.focus = v }
        if let v = sf.cwd { s.cwd = v }
        if let v = sf.transcript { s.transcript = v }
        if let v = sf.ts { s.ts = v }
        if sf.kind == "prompt" {                  // a new turn the user just started
            s.promptTs = sf.ts ?? s.promptTs
            s.turnStartTs = sf.ts ?? s.turnStartTs
            clickFocus = nil                      // a fresh prompt takes focus
        }
    }

    // MARK: - Rebuild the deck

    // Visible = sessions that have actually run (have a file) and whose tab is still
    // live. Open-but-never-run tabs have no session here, so they never appear.
    private func visibleSessions() -> [String: LiveSession] {
        sessions.filter { (k, _) in liveTabs.contains(k) || k == "local" }
    }

    private func rebuild() {
        let vis = visibleSessions()
        guard !vis.isEmpty else {
            frontUUID = nil
            Ticker.shared.stop(); stopClock()
            panel.orderOut(nil)
            return
        }

        // Front pill: a clicked tab wins (pinned until the next prompt), else the most
        // recently prompted, else the most recent activity. All candidates have really
        // run, so the front pill is always a genuine activity state — never a bare tab.
        // A click pins the front, but only until a DIFFERENT tab posts newer activity than
        // existed at click time — then the genuinely-live tab reclaims the front (otherwise
        // a stale pinned session, e.g. one stuck "Waiting for input", hides the active one).
        let newestTs = vis.values.map { $0.ts }.max() ?? 0
        if let c = clickFocus, vis[c] == nil || newestTs > clickFocusTs {
            clickFocus = nil
        }
        let front: String
        if let c = clickFocus, vis[c] != nil {
            front = c
        } else if let p = vis.max(by: { ($0.value.promptTs, $0.value.ts) < ($1.value.promptTs, $1.value.ts) })?.key {
            front = p
        } else {
            front = vis.keys.sorted().first!
        }
        frontUUID = front
        let f = vis[front]!

        let state = IslandState.shared
        state.mode = IslandState.Mode(rawValue: f.mode) ?? .working
        state.detail = f.detail
        state.preview = f.preview
        state.project = f.project
        // The front session's AI title (its directory name if it hasn't earned one yet),
        // surfaced by the on-hover front-pill peek.
        state.title = f.aiTitle.isEmpty ? f.project : f.aiTitle
        state.contextPct = f.context
        state.focusURL = f.focus

        // Back cards: the other live sessions, most-recent first. The uuid breaks ties
        // deterministically so equal-timestamp cards keep a STABLE order — otherwise the
        // dictionary's random iteration order reshuffles them every rebuild (the
        // "carousel" rotation). A done card stays green for 15 min, then greys (stale).
        let now = Date().timeIntervalSince1970
        // Highlighted dropdown row = the tab currently focused in Warp (from Warp's DB),
        // falling back to the front session when unknown. Highlight only — never re-fronts.
        let selected = (activeWarpTab.flatMap { liveTabs.contains($0) ? $0 : nil }) ?? front
        func makeCard(_ k: String, _ v: LiveSession) -> SessionCard {
            let status = (v.mode == "done" && now - v.ts > 900) ? "stale" : v.mode
            // Show a turn timer for active (working/thinking) and finished (done/stale)
            // sessions; formatElapsed ticks live for active and freezes at ts for done.
            let showTimer = ["working", "thinking", "done"].contains(v.mode) || status == "stale"
            return SessionCard(id: k, project: v.project,
                               title: v.aiTitle.isEmpty ? v.project : v.aiTitle,
                               status: status, focus: v.focus, isSelected: k == selected,
                               elapsed: showTimer ? formatElapsed(v) : "",
                               context: v.context, preview: v.preview)
        }
        // Idle live tabs: a Warp tab running claude that hasn't written a state file
        // (never emitted, or its file was cleared). Surface a neutral entry so the deck
        // and the "{n} ⌄" counter reflect ALL live tabs — but never the front pill
        // (front is chosen from `vis` only). ts stays 0 so they sort to the bottom.
        var idle: [String: LiveSession] = [:]
        for u in liveTabs where u != "local" && vis[u] == nil {
            let s = LiveSession()
            s.mode = "idle"
            s.focus = "warp://session/\(u)"
            let cwd = liveTabCwd[u] ?? ""
            s.project = cwd.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent
            // Prefer the tab's last-known session title over its directory name.
            s.aiTitle = liveTabTitle[u] ?? ""
            s.context = liveTabContext[u] ?? 0   // last-known fill, so the ring persists
            idle[u] = s
        }
        let all = vis.merging(idle) { a, _ in a }

        var ordered = all.sorted { ($0.value.ts, $0.key) > ($1.value.ts, $1.key) }
        // While the dropdown is open, hold the row order it had on open (new sessions append
        // by recency) so ticking timers / new activity never slide a row under the cursor.
        if state.dropdownOpen, let frozen = dropdownFrozenOrder {
            let rank = Dictionary(frozen.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            ordered.sort { a, b in
                let ra = rank[a.key] ?? Int.max, rb = rank[b.key] ?? Int.max
                return ra != rb ? ra < rb : (a.value.ts, a.key) > (b.value.ts, b.key)
            }
        }
        state.cards = ordered.filter { $0.key != front }.prefix(5).map { makeCard($0.key, $0.value) }
        // dropdown roster: every live tab (front + others + idle), most-recent first.
        state.roster = ordered.map { makeCard($0.key, $0.value) }

        // Dropdown group order = the order projects were FIRST SEEN by the daemon, persisted
        // to disk so it reflects when each tab was first opened and survives restarts. A new
        // project is appended (oldest stays on top, new tabs land at the bottom) and never
        // reshuffles afterward. A batch first seen together is tie-broken by ascending ts.
        let projFirstTs = Dictionary(grouping: all.values, by: { $0.project.isEmpty ? "Claude Code" : $0.project })
            .mapValues { $0.map(\.ts).min() ?? 0 }
        var orderGrew = false
        for proj in projFirstTs.keys.sorted(by: { (projFirstTs[$0]!, $0) < (projFirstTs[$1]!, $1) })
        where !projectOrder.contains(proj) { projectOrder.append(proj); orderGrew = true }
        if orderGrew { try? projectOrder.joined(separator: "\n").write(toFile: kProjectOrderFile, atomically: true, encoding: .utf8) }
        state.dropdownItems = Self.groupRoster(state.roster, order: projectOrder)

        // Spinner follows the front session.
        switch state.mode {
        case .thinking, .working: Ticker.shared.start()
        case .done:
            Ticker.shared.stop()
            state.elapsed = formatElapsed(f)        // frozen total
        case .attention, .error, .compacting, .compacted: Ticker.shared.stop()
        }
        // The 1s clock runs while ANY visible session is mid-turn, so every active row's
        // timer in the dropdown ticks live — not just the front pill's.
        let anyActive = vis.values.contains { $0.mode == "working" || $0.mode == "thinking" }
        if anyActive { startClock() } else { stopClock() }

        // Fleet reducer: tally the roster into the three buckets the front pill and (later)
        // the dropdown headers both read. The roster's `status` already bakes in the 15-min
        // done→stale rule, so `done` here is "finished within 15 min"; stale/idle count
        // toward nothing. Aggregate kicks in once ≥2 sessions have actually run.
        let running = state.roster.filter { ["working", "thinking", "compacting", "compacted"].contains($0.status) }.count
        let needYou = state.roster.filter { ["attention", "error"].contains($0.status) }.count
        let done = state.roster.filter { $0.status == "done" }.count
        state.runningCount = running
        state.needYouCount = needYou
        state.doneCount = done
        state.aggregate = (running + needYou + done) >= 2

        // Nothing live and nothing waiting on you (all stale / idle) → hide the island
        // entirely, unless the dropdown is open showing the earlier sessions.
        if running + needYou + done == 0 && !state.dropdownOpen {
            Ticker.shared.stop()
            panel.orderOut(nil)
            return
        }

        position()
        panel.orderFrontRegardless()
    }

    // MARK: - Process scan (liveness + forked filter) — runs on a background queue

    /// Which Warp tabs still have a live, interactive (non-forked) CC process. Used only
    /// to GC sessions whose tab closed. Pure IO, safe off the main thread.
    /// Live (non-forked) Warp tabs running claude, mapped to each tab's working
    /// directory (from the env dump) so a tab with no state file can still be
    /// labelled by its project name.
    private func computeLiveTabs() -> [String: String] {
        let pids = shell("/usr/bin/pgrep", ["-U", "\(getuid())", "-f", "claude"])
            .split(separator: "\n").map(String.init)
        var cwds = [String: String](), excluded = Set<String>()
        for pid in pids {
            // `ps eww` dumps the full command + env after it; the env survives here
            // where `ps -axeww` would truncate the long claude arg list and lose it.
            let line = shell("/bin/ps", ["eww", "-o", "command=", "-p", pid])
            guard let u = uuidIn(line) else { continue }
            if cwds[u] == nil { cwds[u] = cwdIn(line) }
            if line.contains("--fork-session") || line.contains("mcp__computer-use") {
                excluded.insert(u)   // forked / computer-use session — hide it
            }
        }
        for u in excluded { cwds.removeValue(forKey: u) }
        return cwds
    }

    // Pull " PWD=…" out of the env dump (leading space avoids matching OLDPWD=).
    // Stops at the next space, so a path with spaces would clip — acceptable.
    private func cwdIn(_ s: String) -> String {
        guard let r = s.range(of: " PWD=") else { return "" }
        return String(s[r.upperBound...].prefix { $0 != " " })
    }

    /// A canceled turn (Esc) fires no Stop hook, so an active session can get stuck
    /// showing thinking/working. Claude Code writes "Request interrupted by user" as
    /// the latest transcript entry — detect that. File IO, safe off the main thread.
    private func transcriptInterrupted(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let size = fh.seekToEndOfFile()
        fh.seek(toFileOffset: size > 4096 ? size - 4096 : 0)
        guard let s = String(data: fh.readDataToEndOfFile(), encoding: .utf8) else { return false }
        // The interrupt marker is the latest entry until the next prompt.
        for line in s.split(separator: "\n").reversed().prefix(5) {
            if line.contains("Request interrupted by user") { return true }
        }
        return false
    }

    // MARK: - Live status poll (freshest activity, between hook events)

    /// Map sessionId → CC's live status ("busy"/"idle"), read from Claude Code's own
    /// per-session state files. CC rewrites these continuously, so this leads our hooks.
    /// Safe off the main thread (small files, plain reads).
    private func ccSessionStatuses() -> [String: String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: kCCSessionsDir) else { return [:] }
        var out: [String: String] = [:]
        for f in files where f.hasSuffix(".json") {
            guard let data = fm.contents(atPath: kCCSessionsDir + "/" + f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  let st = obj["status"] as? String else { continue }
            out[sid] = st
        }
        return out
    }

    private func verbForTool(_ name: String) -> String {
        switch name {
        case "Read":                              return "Reading"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing"
        case "Grep", "Glob":                      return "Searching"
        case "Bash", "BashOutput", "KillShell":   return "Running"
        case "WebFetch":                          return "Fetching"
        case "WebSearch":                         return "Searching the web"
        case "Task", "Agent":                     return "Delegating"
        case "TodoWrite":                         return "Planning"
        default:                                  return "Working"   // incl. mcp__* tools
        }
    }

    /// Concrete object a tool is acting on (file basename / command / pattern), mirroring
    /// the hook so the pill's right side stays specific ("Reading | island.swift").
    private func toolTarget(_ tool: String, _ input: [String: Any]) -> String {
        func base(_ p: String) -> String { (p as NSString).lastPathComponent }
        switch tool {
        case "Read", "Edit", "MultiEdit", "Write": return base(input["file_path"] as? String ?? "")
        case "NotebookEdit":                       return base(input["notebook_path"] as? String ?? "")
        case "Bash": return (input["command"] as? String ?? "").split(separator: " ").first.map(String.init) ?? ""
        case "Grep", "Glob":                       return input["pattern"] as? String ?? ""
        default:                                   return ""
        }
    }

    /// Tail the transcript for the *live* activity: the latest assistant entry's final block
    /// gives the real verb ("Thinking" during an extended-thinking block, else the running
    /// tool), and the most recent non-empty assistant text is the freshest preview. File IO,
    /// run off the main thread. Returns nil if nothing usable was found.
    private func transcriptActivity(_ path: String) -> (preview: String, verb: String, thinking: Bool)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = fh.seekToEndOfFile()
        fh.seek(toFileOffset: size > 16_384 ? size - 16_384 : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        var textPreview = "", action = "", verb = "", thinking = false
        var classified = false
        for line in s.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            // The very latest assistant entry decides the verb (what it's doing right now);
            // a running tool also yields a concrete object for the preview.
            if !classified, let last = content.last(where: { ($0["type"] as? String) != nil }) {
                switch last["type"] as? String {
                case "thinking": thinking = true; verb = "Thinking"
                case "tool_use":
                    verb = verbForTool(last["name"] as? String ?? "")
                    let tgt = toolTarget(last["name"] as? String ?? "", last["input"] as? [String: Any] ?? [:])
                    action = (verb + " " + tgt).trimmingCharacters(in: .whitespaces)   // "Reading island.swift"
                case "text":     verb = "Responding"
                default:         break
                }
                classified = true
            }
            // Fallback preview = first line of the most recent non-empty text block (may be an
            // earlier entry than the one that set the verb, e.g. when it's now running a tool).
            if textPreview.isEmpty {
                let texts = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                if let t = texts.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    let first = t.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? ""
                    textPreview = String(first.prefix(120))
                }
            }
            if classified && !textPreview.isEmpty { break }
        }
        if !classified && textPreview.isEmpty { return nil }
        // Tool action (concrete object) wins for the preview; otherwise the latest text.
        return (action.isEmpty ? textPreview : action, verb, thinking)
    }

    /// Fires ~2×/sec. Reconciles each known session against CC's live busy/idle status and
    /// the transcript tail, so the pill reflects real activity without waiting for a hook.
    /// Deliberately conservative: attention/error/compacting/compacted are hook-owned and
    /// never overridden here (avoids re-introducing false "waiting for input").
    @objc private func pollLiveStatus() {
        guard !sessions.isEmpty else { return }
        // Snapshot (tabUUID, sessionId, transcript) for sessions that have a transcript.
        let snap: [(String, String, String)] = sessions.compactMap { (k, v) in
            guard !v.transcript.isEmpty else { return nil }
            let sessionId = ((v.transcript as NSString).lastPathComponent as NSString).deletingPathExtension
            return (k, sessionId, v.transcript)
        }
        guard !snap.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let statuses = self.ccSessionStatuses()
            var acts: [String: (preview: String, verb: String, thinking: Bool)] = [:]
            for (uuid, _, tx) in snap {
                if let a = self.transcriptActivity(tx) { acts[uuid] = a }
            }
            DispatchQueue.main.async {
                var changed = false
                let now = Date().timeIntervalSince1970
                for (uuid, sessionId, _) in snap {
                    guard let s = self.sessions[uuid] else { continue }
                    let protected = (s.mode == "compacting" || s.mode == "compacted"
                                     || s.mode == "attention" || s.mode == "error")
                    if !protected, let st = statuses[sessionId] {
                        if st == "busy" {
                            // Actively computing. Only un-stick a stale terminal state (resumed
                            // turn) — leave thinking/working and the verb to the hooks, which own
                            // the playful gerund vocabulary.
                            if s.mode != "working" && s.mode != "thinking" {
                                s.mode = "working"; s.turnStartTs = now; changed = true
                            }
                        } else if s.mode == "working" || s.mode == "thinking" {
                            // CC went idle but we're still showing active → the turn ended and
                            // we haven't seen the Stop hook yet. Settle to "done" immediately.
                            s.mode = "done"; s.ts = now; changed = true
                        }
                    }
                    // Freshest preview in every state (cheap; no-op when unchanged).
                    if let p = acts[uuid]?.preview, !p.isEmpty, s.preview != p { s.preview = p; changed = true }
                }
                if changed { self.rebuild() }
            }
        }
    }

    /// Latest session title from the transcript: a manual /rename (`custom-title`) wins over
    /// Claude's auto `ai-title`. Reads a tail (a just-made rename is near the end) so the
    /// periodic scan stays cheap. File IO, safe off the main thread.
    private func transcriptTitle(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = fh.seekToEndOfFile()
        let span: UInt64 = 262_144
        fh.seek(toFileOffset: size > span ? size - span : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        var ai: String? = nil
        for line in s.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "custom-title":
                if let c = obj["customTitle"] as? String, !c.isEmpty { return c }  // rename wins outright
            case "ai-title":
                if ai == nil, let a = obj["aiTitle"] as? String, !a.isEmpty { ai = a }
            default: break
            }
        }
        return ai
    }

    private func uuidIn(_ s: String) -> String? {
        guard let r = s.range(of: "WARP_TERMINAL_SESSION_UUID=") else { return nil }
        let u = s[r.upperBound...].prefix { $0.isHexDigit }
        return u.isEmpty ? nil : String(u)
    }

    private func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.launchPath = path; p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    // MARK: - Warp active tab (read from Warp's own SQLite — no Accessibility prompt)

    /// Path to Warp's SQLite store, in our own Group Container (readable without any TCC
    /// grant). Channel dir varies (Warp-Stable / -Preview), so glob for dev.warp.Warp*.
    private func warpDBPath() -> String? {
        let base = NSString("~/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support")
            .expandingTildeInPath
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        for d in dirs where d.hasPrefix("dev.warp.Warp") {
            let p = base + "/" + d + "/warp.sqlite"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// UUID of the tab currently focused in Warp. Resolves app.active_window_id →
    /// windows.active_tab_index (0-based, tabs in id order) → the tab's focused leaf →
    /// terminal_panes.uuid. Read-only over a `mode=ro` URI so it sees Warp's live WAL
    /// writes. Returns nil if Warp/db is absent or the row is ambiguous. Safe off-main.
    private func warpActiveTab() -> String? {
        guard let db = warpDBPath() else { return nil }
        // Percent-encode the path (it has spaces) for the file: URI; keep slashes.
        let enc = db.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db
        let q = """
        WITH aw AS (SELECT active_window_id AS wid FROM app LIMIT 1),
        atab AS (SELECT id AS tab_id FROM tabs WHERE window_id=(SELECT wid FROM aw)
                 ORDER BY id LIMIT 1 OFFSET (SELECT active_tab_index FROM windows WHERE id=(SELECT wid FROM aw)))
        SELECT lower(hex(tp.uuid)) FROM pane_nodes pn JOIN terminal_panes tp ON tp.id=pn.id
        LEFT JOIN pane_leaves pl ON pl.pane_node_id=pn.id
        WHERE pn.tab_id=(SELECT tab_id FROM atab) AND pn.is_leaf=1
        ORDER BY (CASE WHEN pl.is_focused=1 THEN 0 ELSE 1 END), pn.id LIMIT 1;
        """
        let out = shell("/usr/bin/sqlite3", ["file:\(enc)?mode=ro", q])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.count == 32 ? out : nil
    }

    /// Apply a DB-reported active tab. Warp only updates active_tab_index on *manual* tab
    /// switches — a deep-link focus (our row click) doesn't persist there. So we adopt the
    /// DB value only when it actually CHANGES (a real switch); otherwise we keep whatever
    /// activeWarpTab a click set optimistically. A nil read (Warp closed / transient) is
    /// ignored so the highlight doesn't flicker.
    private func applyDBActiveTab(_ dbTab: String?) {
        guard let dbTab else { return }
        if dbTab != lastDbActiveTab { activeWarpTab = dbTab }
        lastDbActiveTab = dbTab
    }

    /// Re-read the Warp-active tab off-main and rebuild (called when the dropdown opens, so
    /// the highlight is fresh even between 4s scans).
    func refreshActiveTab() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let tab = self.warpActiveTab()
            DispatchQueue.main.async { self.applyDBActiveTab(tab); self.rebuild() }
        }
    }

    // MARK: - Clicks

    /// Front-pill click: focus its Warp tab; if it's done, dismiss that card.
    func handleIslandClick() {
        // The front ticker focuses its own tab. The dropdown is opened ONLY by the
        // "{n} ⌄" back-pill peek (which has its own tap target) — never by the front pill.
        closeDropdown()
        guard let front = frontUUID, let f = sessions[front] else { activateWarp(); return }
        openFocus(f.focus)
        // A finished or just-compacted session is a terminal "you can dismiss me" state —
        // clicking takes the user there and clears the card.
        if f.mode == "done" || f.mode == "compacted" {
            sessions.removeValue(forKey: front)
            try? FileManager.default.removeItem(atPath: kSessionsDir + "/" + front + ".json")
            clickFocus = nil
            rebuild()
        }
    }

    /// Back-card / dropdown-row click: focus that tab and promote it to the front pill.
    func focusCardTab(_ id: String) {
        // Idle tabs have no state file; reconstruct the focus URL from the uuid so the
        // click still jumps to the tab. They can't be pinned (never front), so don't.
        openFocus(sessions[id]?.focus ?? "warp://session/\(id)")
        // The click focuses this tab in Warp, but a deep-link focus doesn't update Warp's
        // active_tab_index — so highlight it optimistically; the DB will only override this
        // once the user manually switches tabs (applyDBActiveTab detects the change).
        activeWarpTab = id
        if sessions[id] != nil {
            clickFocus = id
            // Remember how recent activity was when pinned; any newer event releases it.
            clickFocusTs = sessions.values.map { $0.ts }.max() ?? 0
        } else {
            clickFocus = nil
        }
        closeDropdown()
        IslandState.shared.hoveredRow = nil
        rebuild()
    }

    private func openFocus(_ url: String) {
        if !url.isEmpty, let u = URL(string: url) { NSWorkspace.shared.open(u) }
        else { activateWarp() }
    }

    // MARK: - Elapsed timer (front session)

    private func startClock() {
        refreshElapsed()
        guard clockTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshElapsed() }
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
    }

    /// Re-tick the front pill's timer and every live row timer in the dropdown roster.
    private func refreshElapsed() {
        let s = IslandState.shared
        if let f = frontUUID.flatMap({ sessions[$0] }) { s.elapsed = formatElapsed(f) }
        guard !s.roster.isEmpty else { return }
        s.roster = s.roster.map { card in
            guard let v = sessions[card.id] else { return card }
            var c = card
            let show = ["working", "thinking", "done"].contains(v.mode) || card.status == "stale"
            c.elapsed = show ? formatElapsed(v) : ""
            return c
        }
        s.dropdownItems = Self.groupRoster(s.roster, order: projectOrder)   // keep grouped view's timers in sync
    }

    /// Group the roster by project for the dropdown. Group order follows the caller's
    /// persistent first-seen order (oldest-opened dir on top); rows keep ts order within a
    /// group. Headers are emitted only when more than one project is present.
    static func groupRoster(_ roster: [SessionCard], order persistentOrder: [String]) -> [DropdownItem] {
        var groups: [String: [SessionCard]] = [:]
        for c in roster {
            let key = c.project.isEmpty ? "Claude Code" : c.project
            groups[key, default: []].append(c)
        }
        // Group (dir) order follows the persistent first-seen order so headers never
        // reshuffle when a session becomes active. Any project not yet recorded (shouldn't
        // happen, but be safe) is appended at the end. Rows within a group keep ts order.
        var order = persistentOrder.filter { groups[$0] != nil }
        for key in groups.keys where !order.contains(key) { order.append(key) }
        let showHeaders = order.count > 1
        var items: [DropdownItem] = []
        for key in order {
            if showHeaders { items.append(DropdownItem(id: "hdr:\(key)", header: key, card: nil)) }
            for c in groups[key]! { items.append(DropdownItem(id: c.id, header: nil, card: c)) }
        }
        return items
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func formatElapsed(_ s: LiveSession) -> String {
        guard s.turnStartTs > 0 else { return "" }
        let end = s.mode == "done" ? s.ts : Date().timeIntervalSince1970
        let sec = max(0, Int(end - s.turnStartTs))
        return sec < 60 ? "\(sec)s" : "\(sec / 60)m \(sec % 60)s"
    }
}

// MARK: - Boot

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()

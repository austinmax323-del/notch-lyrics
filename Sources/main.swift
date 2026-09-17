// notch-lyrics — an always-visible synced lyric line under the MacBook notch.
//
// Vorssaint (and Sapphire before it) only render lyrics inside the *expanded*
// notch, behind a hover and a tab: `NotchIdleContent` is `none | battery |
// music`, with no lyrics case. This draws its own strip instead, so the current
// line is simply always on screen.
//
// Position comes from Spotify over AppleScript and lyrics from LRCLIB. The
// window is click-through and joins all Spaces, so it never takes focus or
// blocks what is underneath.

import AppKit
import Foundation

// MARK: - Spotify

struct Playback: Equatable {
	var track: String
	var artist: String
	var album: String
	var durationMs: Int
	var position: Double
	var isPlaying: Bool

	/// Identity for lyric lookups — position deliberately excluded.
	var identity: String { "\(artist)|\(track)|\(durationMs)" }
}

enum Spotify {
	/// One round trip for everything; querying fields separately lets the track
	/// change mid-read and yields a mismatched artist/title pair.
	private static let script = """
	tell application "Spotify"
		if it is not running then return "stopped"
		set s to player state as string
		set t to name of current track
		set a to artist of current track
		set al to album of current track
		set d to duration of current track
		set p to player position
		return s & "\\n" & t & "\\n" & a & "\\n" & al & "\\n" & (d as string) & "\\n" & (p as string)
	end tell
	"""

	static func poll() -> Playback? {
		var error: NSDictionary?
		guard let apple = NSAppleScript(source: script) else { return nil }
		let out = apple.executeAndReturnError(&error)
		if let error {
			FileHandle.standardError.write("[notch-lyrics] AppleScript error: \(error)\n".data(using: .utf8)!)
			return nil
		}
		guard let raw = out.stringValue else { return nil }
		let parts = raw.components(separatedBy: "\n")
		guard parts.count >= 6 else { return nil }

		return Playback(
			track: parts[1],
			artist: parts[2],
			album: parts[3],
			durationMs: Int(Double(parts[4]) ?? 0),
			position: Double(parts[5]) ?? 0,
			isPlaying: parts[0] == "playing"
		)
	}
}

// MARK: - Lyrics

struct LyricLine {
	let time: Double
	let text: String
}

enum Lyrics {
	/// Parses LRC. A single line can carry several timestamps ("[00:12.00][01:04.00]text"),
	/// which is how repeated choruses are usually encoded.
	static func parseLRC(_ source: String) -> [LyricLine] {
		var out: [LyricLine] = []
		let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#)

		for raw in source.components(separatedBy: .newlines) {
			let ns = raw as NSString
			let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
			guard !matches.isEmpty, let last = matches.last else { continue }

			let text = ns.substring(from: last.range.upperBound).trimmingCharacters(in: .whitespaces)

			for m in matches {
				let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
				let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
				var frac = 0.0
				if m.range(at: 3).location != NSNotFound {
					let digits = ns.substring(with: m.range(at: 3))
					frac = (Double(digits) ?? 0) / pow(10, Double(digits.count))
				}
				out.append(LyricLine(time: min * 60 + sec + frac, text: text))
			}
		}
		return out.sorted { $0.time < $1.time }
	}

	static func fetch(_ playback: Playback, completion: @escaping ([LyricLine]?) -> Void) {
		var components = URLComponents(string: "https://lrclib.net/api/get")!
		components.queryItems = [
			URLQueryItem(name: "artist_name", value: playback.artist),
			URLQueryItem(name: "track_name", value: playback.track),
			URLQueryItem(name: "album_name", value: playback.album),
			URLQueryItem(name: "duration", value: String(playback.durationMs / 1000)),
		]
		guard let url = components.url else { return completion(nil) }

		var request = URLRequest(url: url)
		request.setValue("notch-lyrics (https://github.com/austinmax323-del)", forHTTPHeaderField: "User-Agent")
		request.timeoutInterval = 8

		URLSession.shared.dataTask(with: request) { data, _, _ in
			guard
				let data,
				let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				let synced = json["syncedLyrics"] as? String, !synced.isEmpty
			else { return completion(nil) }
			completion(parseLRC(synced))
		}.resume()
	}
}

// MARK: - Overlay

final class LyricWindow: NSWindow {
	// Borderless windows refuse key status anyway; being explicit keeps focus
	// with whatever the user is actually doing.
	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }
}

/// Near-black plate whose top corners are square and bottom corners round, so
/// the strip reads as an extrusion of the notch rather than a floating widget.
final class PlateView: NSView {
	override var wantsUpdateLayer: Bool { true }

	override func updateLayer() {
		guard let layer else { return }
		layer.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
		layer.mask = maskLayer()
	}

	private func maskLayer() -> CAShapeLayer {
		let r = min(bounds.height / 2, 14)
		let path = CGMutablePath()
		path.move(to: CGPoint(x: 0, y: bounds.maxY))
		path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
		path.addLine(to: CGPoint(x: bounds.maxX, y: r))
		path.addArc(tangent1End: CGPoint(x: bounds.maxX, y: 0), tangent2End: CGPoint(x: bounds.maxX - r, y: 0), radius: r)
		path.addLine(to: CGPoint(x: r, y: 0))
		path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: 0, y: r), radius: r)
		path.closeSubpath()

		let mask = CAShapeLayer()
		mask.path = path
		return mask
	}
}

final class Controller: NSObject {
	private let window: LyricWindow
	private let plate = PlateView()
	private let label = NSTextField(labelWithString: "")

	private var lines: [LyricLine] = []
	private var identity: String?
	private var shownText: String?
	private var offset: Double

	private let font = NSFont.systemFont(ofSize: 13, weight: .medium)
	private let hPadding: CGFloat = 18
	private let height: CGFloat = 28

	private var reduceMotion: Bool {
		NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
	}

	init(offset: Double) {
		self.offset = offset

		window = LyricWindow(
			contentRect: NSRect(x: 0, y: 0, width: 200, height: height),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isOpaque = false
		window.backgroundColor = .clear
		window.hasShadow = false          // hardware does not cast one
		window.ignoresMouseEvents = true  // click-through: never in the way
		window.level = .statusBar
		window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
		window.alphaValue = 0

		plate.wantsLayer = true
		plate.autoresizingMask = [.width, .height]

		label.font = font
		label.textColor = NSColor.white.withAlphaComponent(0.92)
		label.alignment = .center
		label.lineBreakMode = .byTruncatingTail
		label.maximumNumberOfLines = 1
		// No autoresizing: the plate resizes on every line change, and letting it
		// stretch the label re-derives a width that truncates the text.
		label.autoresizingMask = []

		window.contentView = plate
		plate.addSubview(label)

		super.init()
		window.orderFrontRegardless()
	}

	// MARK: Geometry

	/// Width of the notch on this screen, or 0 when there is none. Used as the
	/// minimum width so a short line still looks anchored to the cutout.
	private func notchWidth(_ screen: NSScreen) -> CGFloat {
		guard screen.safeAreaInsets.top > 0 else { return 0 }
		if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
			return screen.frame.width - left.width - right.width
		}
		return 0
	}

	private func layout(for text: String) {
		guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
		else { return }

		// Measure the field, not the string: NSTextField draws inside cell insets
		// that NSString.size(withAttributes:) knows nothing about, so a
		// string-derived width is a few points short and truncates the last word.
		label.stringValue = text
		let measured = ceil(label.fittingSize.width) + 1
		let maxWidth = screen.frame.width * 0.52
		let width = min(max(measured + hPadding * 2, max(notchWidth(screen), 160)), maxWidth)

		let inset = screen.safeAreaInsets.top
		let top = screen.frame.maxY - max(inset, NSStatusBar.system.thickness)

		window.setFrame(
			NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height),
			display: true
		)
		label.frame = NSRect(x: hPadding, y: 0, width: width - hPadding * 2, height: height)
		plate.needsDisplay = true

		if ProcessInfo.processInfo.environment["NOTCH_LYRICS_DEBUG"] != nil {
			print("[layout] measured=\(measured) width=\(width) cap=\(maxWidth) screen=\(screen.frame.width) label=\(label.frame.width) text=\(text.prefix(28))")
			fflush(stdout)
		}
	}

	// MARK: Display

	private func show(_ text: String) {
		guard text != shownText else { return }
		shownText = text

		let apply = { self.layout(for: text) }

		guard !reduceMotion, window.alphaValue > 0 else {
			apply()
			window.animator().alphaValue = 1
			return
		}

		// One motion moment: the outgoing line fades as the incoming one rises.
		NSAnimationContext.runAnimationGroup { ctx in
			ctx.duration = 0.12
			label.animator().alphaValue = 0
		} completionHandler: {
			apply()
			self.label.frame.origin.y -= 3
			NSAnimationContext.runAnimationGroup { ctx in
				ctx.duration = 0.18
				self.label.animator().alphaValue = 1
				self.label.animator().frame.origin.y += 3
				self.window.animator().alphaValue = 1
			}
		}
	}

	private func hide() {
		guard shownText != nil || window.alphaValue > 0 else { return }
		shownText = nil
		NSAnimationContext.runAnimationGroup { ctx in
			ctx.duration = reduceMotion ? 0 : 0.2
			window.animator().alphaValue = 0
		}
	}

	// MARK: Tick

	func tick() {
		guard let playback = Spotify.poll(), playback.isPlaying else { return hide() }

		if playback.identity != identity {
			identity = playback.identity
			lines = []
			Lyrics.fetch(playback) { [weak self] parsed in
				DispatchQueue.main.async {
					guard let self, self.identity == playback.identity else { return }
					self.lines = parsed ?? []
				}
			}
		}

		guard !lines.isEmpty else { return hide() }

		let t = playback.position + offset
		guard let current = lines.last(where: { $0.time <= t }), !current.text.isEmpty else { return hide() }

		show(current.text)
	}
}

// MARK: - Main

let args = CommandLine.arguments
let offset = args.firstIndex(of: "--offset").flatMap { i -> Double? in
	i + 1 < args.count ? Double(args[i + 1]) : nil
} ?? 0

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar entry

let controller = Controller(offset: offset)
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in controller.tick() }

print("[notch-lyrics] running (offset \(offset)s) — Ctrl-C to stop")
app.run()

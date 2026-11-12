//
//  EdgeDragWatcher.swift
//  DropPortal
//
//  Notices a file drag anywhere on the Mac, so the right-edge drop zone shows
//  only while one is on. No event monitor and no tap: a low-rate timer reads
//  whether the left button is down (5 Hz while it is up), then whether the
//  drag pasteboard changed since the press and holds files (URLs,
//  file names or file promises) (10 Hz while
//  it is down). Only during a file drag does it follow the pointer at 60 Hz.
//  Reading two counters is all it costs while nothing is dragged.
//

import AppKit

@MainActor
final class EdgeDragWatcher {
    /// A drag of files began: the drag pasteboard's types.
    var onBegin: (([String]) -> Void)?
    /// The pointer during that drag, in screen coordinates.
    var onMove: ((NSPoint) -> Void)?
    /// The button came up: the drag is over, dropped or not.
    var onEnd: (() -> Void)?

    private enum Rate: Double {
        case idle = 0.2, pressed = 0.1, dragging = 0.0166
    }

    private let board = NSPasteboard(name: .drag)
    private var baseline = 0
    private var timer: Timer?
    private var rate: Rate?
    private(set) var dragging = false

    func start() {
        guard timer == nil else { return }
        baseline = board.changeCount
        schedule(.idle)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        rate = nil
        if dragging {
            dragging = false
            onEnd?()
        }
    }

    private func schedule(_ new: Rate) {
        guard rate != new else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: new.rawValue, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = new == .dragging ? 0.004 : new.rawValue / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        rate = new
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            baseline = board.changeCount
            if dragging {
                dragging = false
                onEnd?()
            }
            return schedule(.idle)
        }
        if dragging {
            onMove?(NSEvent.mouseLocation)
            return
        }
        let count = board.changeCount
        guard count != baseline else { return schedule(.pressed) }
        // Something is dragged; only files count. Any other drag is ignored until the button comes up.
        baseline = count
        let types = board.types ?? []
        guard types.contains(where: EdgePortal.dropTypes.contains) else { return schedule(.pressed) }
        dragging = true
        schedule(.dragging)
        onBegin?(types.map(\.rawValue))
        onMove?(NSEvent.mouseLocation)
    }
}

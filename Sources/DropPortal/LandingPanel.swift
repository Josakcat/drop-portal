//
//  LandingPanel.swift
//  DropPortal
//
//  Where a file from the phone lands. While a card is dragged on the phone, a
//  peek card comes through the right edge of the screen with the pointer and
//  follows the drag; on a flick it becomes the "Receiving" card and then, in
//  place, the landed card: click opens the file, drag takes the file out.
//  A file that comes without a peek (a retry, a phone without the live
//  channel) and the settings' Preview play the same crossing, driven here.
//
//  How it crosses is the chosen `PortalEffect`: `CardLook` shapes the card and
//  `SeamView` lights the edge (PortalEffects.swift); this file owns the panels.
//  Reduce motion: the card fades in and the edge light only fades.
//
// droppykit-lint: allow-file own-window: Drop Portal makes short-lived borderless, non-activating panels (LandingPanel, level .floating, [.canJoinAllSpaces, .stationary, .ignoresCycle], never over a full-screen app) that no DroppyKit surface can place, because each sits at a point on the screen with the pointer or follows one up to 120 times a second (the display's rate): (1) the landing/peek card, which slides in at the right screen edge while the phone drags, follows the finger, shows "Receiving" and lands mid-screen (click opens the file, drag exports its URL), ordered out a few seconds after landing (longer under the pointer) or when it slides back out on a cancel; (2) the edge seam, a click-through light on that right edge, closed when the card has crossed or on cancel; (3) the stage, a click-through panel the size of the screen just under the card for the crossing effect, closed 0.9 s after the impact, on the next crossing and on a cancel once the card is gone (at most 0.45 s), never made under Reduce motion; (4) the right-edge drop zone, an 8 pt (150 pt while its light is open) panel on each outer right screen edge that exists only while a file drag is on, closed on the drop, on button-up, after 0.6 s without a drop or by a 0.25 s watchdog, with the dropped files' icon falling into the edge (click-through, under a second). All are closed in deactivate() (tearDown). The developer asks the Store maintainer for this exception in the merge request.
//

import AppKit
import SwiftUI
import CoreImage
import ImageIO
import DropPortalCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

@MainActor
final class LandingPresenter {
    private var current: NSPanel?
    private var holdTask: Task<Void, Never>?
    /// Seconds the card waits before it leaves, unless the pointer is on it.
    var holdSeconds: Double = 3.5
    /// How cards cross; read when a crossing starts.
    var effect: PortalEffect = .default
    /// Each effect's colour; an effect missing here draws in its default.
    var tints: [PortalEffect: PortalTint] = [:]
    private var peek: PeekCard?
    /// The display's frame clock (PortalFeel.swift): 120 Hz on ProMotion.
    private var springTimer: FrameClock?
    private var lastTick: CFTimeInterval = 0
    /// A crossing with no finger behind it (a plain arrival or the Preview).
    private var driveTimer: FrameClock?
    private var driveTasks: [Task<Void, Never>] = []
    /// The light on the screen edge for the current crossing, in front of the card.
    private var seam: PortalSeam?
    /// The whole screen behind the card: vignette, rays, the send and the impact.
    private var stage: PortalStage?
    /// A file landed (not a cancel): the droplet plays Droppy's drop sound.
    var onLanded: ((PortalEffect) -> Void)?
    /// A trackpad tap: as the card comes out of the edge, and at its landing.
    var onFeel: ((PortalHaptics.Beat) -> Void)?
    /// The landing touches' switches (LandingCelebration.swift), read at each landing.
    var wantsCelebration: () -> Bool = { true }
    var wantsKineticName: () -> Bool = { true }
    /// Several cards flicked together: the landed card counts the files after the first, which do not cross again.
    private var batch: (id: String, total: Int, got: Int, card: LandingView)?

    static let fileCardSize = NSSize(width: 240, height: 268)

    // MARK: Arrivals

    /// A file arrived with no peek: it crosses the same way, driven from 0 to 1.
    func show(file: URL, onOpen: @escaping (URL) -> Void) {
        Task { @MainActor [weak self] in
            let image = await Self.thumbnail(for: file)
            guard let self else { return }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let info = PeekInfo(id: "arrival-\(UUID().uuidString.prefix(8))", name: file.lastPathComponent,
                                kind: .file, size: size)
            guard let card = self.startPeek(info, image: image) else { return }
            // A short peek, then the flick: the same crossing a finger makes.
            self.drive(card, to: 0.4, seconds: 0.4) { [weak self] in
                guard let self, self.peek === card else { return }
                self.commit(card)
                self.settle(card, image: image, title: file.lastPathComponent, url: file, onOpen: onOpen)
            }
        }
    }

    /// The settings' Preview: a made-up photo is dragged half way out of the
    /// edge, flicked, flies in, lands with the full impact and is received.
    func preview(effect: PortalEffect? = nil) {
        let info = PortalPreview.samplePhoto
        let image = PeekThumbnail.decode(info.thumb).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        guard let card = startPeek(info, image: image, effect: effect) else { return }
        drive(card, to: 0.5, seconds: 1.0) { [weak self] in
            guard let self, self.peek === card else { return }
            self.after(0.18) { [weak self] in
                guard let self, self.peek === card else { return }
                // A brisk flick a little upward, as a finger makes it.
                self.commit(card, release: PeekRelease(vx: -1700, vy: -220, exitY: 0.42, angle: -5))
                for step in 1...5 {
                    self.after(0.09 * Double(step)) { [weak self] in
                        guard self?.peek === card else { return }
                        card.view.showReceiving(progress: Double(step) / 5)
                    }
                }
                self.after(0.5) { [weak self] in
                    self?.settle(card, image: image ?? NSImage(), title: info.name, url: nil, onOpen: { _ in })
                }
            }
        }
    }

    /// A file arrived. When it is the one the peek card is showing, that card
    /// turns into the landed card where it is; otherwise it crosses on its own.
    func land(file: URL, peekID: String?, onOpen: @escaping (URL) -> Void) {
        if let peekID, var group = batch, group.id == peekID {
            group.got += 1
            batch = group
            group.card.setTitle(group.got >= group.total ? "\(group.total) files received"
                                : "\(group.got) of \(group.total) received")
            if group.got >= group.total {
                batch = nil
                onLanded?(effect)
                if current != nil { scheduleDismiss() }
            } else if current != nil {
                scheduleDismiss(after: 30)
            }
            return
        }
        guard let peekID, let card = peek, card.id == peekID, !card.leaving else {
            return show(file: file, onOpen: onOpen)
        }
        Task { @MainActor [weak self] in
            let image = await Self.thumbnail(for: file)
            guard let self else { return }
            // Replaced or cancelled while the thumbnail was made.
            guard self.peek === card, !card.leaving else {
                return self.show(file: file, onOpen: onOpen)
            }
            self.settle(card, image: image, title: file.lastPathComponent, url: file, onOpen: onOpen)
        }
    }

    /// The peek card becomes the landed card in place, and takes clicks.
    private func settle(_ card: PeekCard, image: NSImage, title: String, url: URL?, onOpen: @escaping (URL) -> Void) {
        guard peek === card, !card.leaving else { return }
        if !card.committed { commit(card) }
        // Stardust: from 0.4 s after the release the landed card takes clicks and
        // drags in place, under grains still flying; it shows at the impact.
        let early = !card.impacted && card.takesHitsEarly
        // The file can be here before the card is: it turns into the landed card just after the impact.
        guard card.impacted || early else {
            card.pendingSettle = { [weak self, weak card] in
                guard let self, let card else { return }
                self.settle(card, image: image, title: title, url: url, onOpen: onOpen)
            }
            runSpring()
            return
        }
        if !early {
            onLanded?(card.look.effect)
            peek = nil
            stopSpringIfIdle()
        }
        let landed = LandingView(image: image, title: title, url: url)
        if card.count > 1 {
            batch = (card.id, card.count, 1, landed)
            landed.setTitle("1 of \(card.count) received")
        } else {
            batch = nil
        }
        landed.onClick = { [weak self] in
            if let url { onOpen(url) }
            self?.dismiss()
        }
        landed.frame = card.view.frame
        landed.autoresizingMask = PeekCard.scales
        landed.alphaValue = 0
        card.container.addSubview(landed)
        wire(landed)
        if current !== card.panel { dismiss() }
        current = card.panel
        card.panel.ignoresMouseEvents = false
        if early {
            // Hit-testable but not drawn: the grains are still forming the card.
            card.earlyLanded = landed
            card.reveal = { [weak self, weak card] in
                guard let self, let card else { return }
                self.reveal(card, landed: landed, title: title)
            }
            return
        }
        reveal(card, landed: landed, title: title)
    }

    /// The landed card shows: depth, the kinetic name, the fade in place.
    private func reveal(_ card: PeekCard, landed: LandingView, title: String) {
        if card.earlyLanded != nil {
            // Stardust's early card: the crossing ends here, at the impact.
            card.earlyLanded = nil
            card.reveal = nil
            onLanded?(card.look.effect)
            if peek === card { peek = nil }
            stopSpringIfIdle()
        }
        // Landed: no edge clip, and a re-form or unfold still playing finishes.
        card.look.unclip()
        // A contact shadow and the lean toward the pointer (PortalFeel.swift) instead of the window's shadow.
        card.panel.hasShadow = false
        let celebrate = wantsCelebration()
        LandingDepth.attach(under: landed, calm: card.look.calm, glass: celebrate, arm: LandingCelebration.tiltArm)
        if wantsKineticName(), batch == nil, let label = landed.titleField {
            KineticTitleView.play(on: label, name: title, calm: card.look.calm)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            landed.animator().alphaValue = 1
            card.view.animator().alphaValue = 0
            card.panel.animator().alphaValue = 1
            card.panel.animator().setFrameOrigin(card.panelOrigin(x: card.onX))
        }, completionHandler: nil)
        // A batch stays while its files come in; one that stops arriving still goes.
        scheduleDismiss(after: batch == nil ? nil : 30)
    }

    /// Moves a crossing from progress 0 to `end` over `seconds`, slowing toward
    /// it like a hand, through the same spring a finger drives; then `done`.
    private func drive(_ card: PeekCard, to end: CGFloat, seconds: Double, done: @escaping () -> Void) {
        driveTimer?.invalidate()
        let start = CACurrentMediaTime()
        driveTimer = FrameClock(screen: FrameRate.screen(for: card.screen)) { [weak self] timer in
            guard let self, self.peek === card, !card.leaving else { return timer.invalidate() }
            let t = min(1, (CACurrentMediaTime() - start) / seconds)
            let eased = CGFloat(1 - pow(1 - t, 3)) * end
            card.target = card.offX + (card.onX - card.offX) * eased
            self.runSpring()
            if t >= 1 {
                timer.invalidate()
                if self.driveTimer === timer { self.driveTimer = nil }
                done()
            }
        }
    }

    private func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            body()
        }
        driveTasks.append(task)
    }

    private func cancelDrives() {
        driveTimer?.invalidate()
        driveTimer = nil
        driveTasks.forEach { $0.cancel() }
        driveTasks = []
    }

    // MARK: Peek

    /// Draws a peek event from the phone.
    func peek(_ event: PeekEvent) {
        switch event {
        case .start(let info):
            startPeek(info, image: nil)
        case .move(let id, let progress, let y):
            guard let card = peek, card.id == id, !card.leaving, !card.committed else { return }
            card.target = card.offX + (card.onX - card.offX) * CGFloat(progress)
            if let y { card.follow(phoneY: y, progress: progress) }
            runSpring()
        case .commit(let id, let release):
            guard let card = peek, card.id == id, !card.leaving else { return }
            commit(card, release: release)
        case .progress(let id, let progress):
            guard let card = peek, card.id == id, card.committed, !card.leaving else { return }
            card.view.showReceiving(progress: progress)
        case .cancel(let id):
            guard let card = peek, card.id == id else { return }
            card.leaving = true
            card.target = card.offX
            seam?.retire(bloom: false)
            stage?.retire()
            runSpring()
        }
    }

    /// The flick: the card flies from where the finger left it to its spot
    /// and lands exactly `look.flight` later: carrying the phone's throw on
    /// when the page sent one (`ThrowFlight`), else on the travel curve.
    private func commit(_ card: PeekCard, release: PeekRelease? = nil) {
        guard !card.committed else { return }
        card.committed = true
        card.flightStart = CACurrentMediaTime()
        card.flightFrom = card.x
        card.target = card.onX
        // Stardust and Lightning keep their own flight (the grains' and the strike's timeline).
        if let release, !card.look.calm, !card.look.effect.isSky, !card.look.effect.isCourier { card.throwOn(release) }
        card.yTarget = card.landY
        card.view.showReceiving(progress: 0)
        card.look.commit()
        seam?.retire(bloom: true)
        stage?.send(flight: card.look.flight)
        runSpring()
    }

    /// The card reaches its spot: it squashes and settles, the stage plays the
    /// impact and clears 0.9 s later, and a file already here lands.
    private func impact(_ card: PeekCard) {
        guard !card.impacted else { return }
        card.impacted = true
        card.look.settles = wantsCelebration()
        card.look.land()
        if card.look.settles, !card.look.calm {
            SparkView.play(in: card.container, below: card.view, card: card.view.frame,
                           tones: card.tones ?? PhotoTones.fallback(card.look.palette))
        }
        onFeel?(.land)
        if let stage {
            stage.impact()
            after(stage.afterImpactSeconds + 0.05) { [weak self] in
                stage.close()
                if self?.stage === stage { self?.stage = nil }
            }
        }
        if let pending = card.pendingSettle {
            card.pendingSettle = nil
            after(0.16, pending)
        }
        if let reveal = card.reveal {
            card.reveal = nil
            after(0.16, reveal)
        }
    }

    /// Stardust's early card was clicked or dragged away before the impact:
    /// the crossing stops here and its stage finishes on its own clock.
    private func endEarly(_ card: PeekCard) {
        guard card.earlyLanded != nil else { return }
        card.earlyLanded = nil
        card.reveal = nil
        onLanded?(card.look.effect)
        card.look.stop()
        if peek === card { peek = nil }
        stopSpringIfIdle()
        if let stage {
            let left = max(0, card.look.flight - (CACurrentMediaTime() - card.flightStart))
            self.stage = nil
            after(left + StageView.Look.impactSeconds + 0.05) { stage.close() }
        }
    }

    @discardableResult
    private func startPeek(_ info: PeekInfo, image: NSImage?, effect chosen: PortalEffect? = nil) -> PeekCard? {
        let effect = chosen ?? self.effect
        // A landed card still on screen goes first; the peek takes its place.
        dismiss()
        cancelDrives()
        if let old = peek {
            // One crossing at a time: the old card fades where it is.
            peek = nil
            old.look.stop()
            Self.fadeAndClose(old.panel)
        }
        seam?.close()
        seam = nil
        stage?.close()
        stage = nil
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return nil }
        let size = Self.fileCardSize
        let final = Self.landingRect(on: screen, size: size)
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // One palette for the whole crossing: Rainbow's hue is taken once, here.
        let palette = palette(for: effect)
        let card = PeekCard(id: info.id, view: PeekView(info: info, image: image), effect: effect, palette: palette, calm: calm,
                            offX: screen.frame.maxX + 12, onX: final.minX, y: final.minY, screen: screen.frame)
        card.count = info.count
        // Looking only: a peek never takes a click or the focus.
        card.panel.ignoresMouseEvents = true
        // It waits at the screen edge: invisible there, fading in over the first 40 pt of travel.
        card.panel.alphaValue = 0
        card.place()
        card.panel.orderFrontRegardless()
        peek = card
        // The stage goes behind the card; Reduce motion keeps only the edge light.
        if !calm {
            let origin = screen.frame.origin
            let stage = PortalStage(screen: screen, effect: effect, palette: palette,
                                    seam: CGPoint(x: screen.frame.width, y: final.midY - origin.y),
                                    landing: CGPoint(x: final.midX - origin.x, y: final.midY - origin.y))
            stage.show(below: card.panel)
            self.stage = stage
            // A courier: this crossing's variant from the phone's seed, and a click on it lands the card now.
            if let courier = effect.courier {
                stage.startCourier(CourierPlan(courier: courier, seed: info.seed ?? CourierPlan.randomSeed(), short: info.short, files: info.count),
                                   screen: screen, image: card.view.snapshot()) { [weak self, weak card] in
                    guard let self, let card, self.peek === card, card.committed, !card.impacted else { return }
                    card.flightStart = CACurrentMediaTime() - card.look.flight
                }
            }
        }
        // The seam goes in front of the card, so the card comes out of the light.
        let light = PortalSeam(screen: screen, centerY: final.midY, effect: effect, palette: palette, calm: calm)
        light.show()
        seam = light
        if card.look.wantsSnapshot { card.look.setSnapshot(card.view.snapshot()) }
        if wantsCelebration() {
            SparkGPU.warm()
            PhotoTones.sample(image) { [weak card] in card?.tones = $0 }
        }
        if image == nil, !info.thumb.isEmpty {
            let data = info.thumb, id = info.id
            Task { @MainActor [weak self] in
                let decoded = await Self.decodeThumbnail(data)
                guard let decoded, let card = self?.peek, card.id == id else { return }
                let picture = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                card.view.setThumbnail(picture)
                PhotoTones.sample(picture) { [weak card] in card?.tones = $0 }
                if card.look.wantsSnapshot { card.look.setSnapshot(card.view.snapshot()) }
                if card.look.effect.isCourier { self?.stage?.setCardImage(card.view.snapshot()) }
            }
        }
        return card
    }

    /// The phone's JPEG, decoded off the main thread and capped at 440 px.
    nonisolated static func decodeThumbnail(_ data: Data) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { PeekThumbnail.decode(data) }.value
    }

    private func runSpring() {
        guard springTimer == nil else { return }
        lastTick = CACurrentMediaTime()
        springTimer = FrameClock(screen: FrameRate.screen(for: peek?.screen)) { [weak self] _ in self?.tick() }
    }

    private func stopSpringIfIdle() {
        // A sent card keeps the clock running until it has landed.
        if let card = peek, !card.settled || (card.committed && !card.impacted && !card.leaving) { return }
        springTimer?.invalidate()
        springTimer = nil
    }

    /// One step toward the target: a critically damped spring while a finger
    /// drives it (60 Hz input reads as one smooth motion) and on a cancel or
    /// under Reduce motion; after the flick, the timed flight.
    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1.0 / 30, max(1.0 / 240, now - lastTick)))
        lastTick = now
        guard let card = peek else { return stopSpringIfIdle() }
        let flying = card.committed && !card.leaving && !card.look.calm
        if flying, let path = card.path {
            // The phone's throw carried on: its velocity decelerating into the spot.
            let t = now - card.flightStart, at = path.position(at: t)
            card.velocity = (CGFloat(at.x) - card.x) / dt
            card.x = CGFloat(at.x)
            card.y = CGFloat(at.y)
            if t >= path.duration { card.x = card.onX; card.y = card.landY; card.velocity = 0 }
        } else if flying {
            // After the release: from where the finger left it to the spot on
            // the travel curve, landing exactly `flight` seconds later.
            let u = CGFloat((now - card.flightStart) / max(0.01, card.look.flight))
            let x = card.flightFrom + (card.onX - card.flightFrom) * Ease.travel(u)
            card.velocity = (x - card.x) / dt
            card.x = x
            if u >= 1 { card.x = card.onX; card.velocity = 0 }
        } else {
            // The finger: a critically damped spring toward its target.
            let stiffness: CGFloat = 420, damping = 2 * stiffness.squareRoot()
            let accel = stiffness * (card.target - card.x) - damping * card.velocity
            card.velocity += accel * dt
            card.x += card.velocity * dt
            card.springY(dt: dt, stiffness: stiffness, damping: damping)
        }
        if abs(card.target - card.x) < 0.5, abs(card.velocity) < 8, card.yAtRest {
            card.x = card.target
            card.velocity = 0
            card.settled = true
        } else {
            card.settled = false
        }
        card.place()
        if !card.felt, !card.leaving, card.offX - card.x > 40 { card.felt = true; onFeel?(.appear) }
        if !card.committed {
            let intensity = min(1, max(0, (card.offX - card.x) / max(1, card.offX - card.onX)))
            if !card.leaving { seam?.setIntensity(intensity) }
            // A cancel plays the stage's drag backwards while the card goes back into the edge.
            stage?.setIntensity(intensity)
        }
        if !card.committed, !card.leaving {
            // The edge's light stays at the card's exit height (flow's phone y), not the landing's.
            let exitY = card.center.y
            seam?.moveCenter(toY: exitY)
            stage?.moveSeam(toY: exitY)
        }
        if !card.impacted { stage?.follow(card: card.center) }
        if card.committed, !card.leaving, !card.impacted, flying ? now - card.flightStart >= card.look.flight : card.x - card.onX < 6 {
            impact(card)
        }
        if !card.impacted, card.takesHitsEarly, let pending = card.pendingSettle {
            card.pendingSettle = nil
            pending()
        }
        if card.settled, card.leaving {
            peek = nil
            if !card.committed {
                stage?.close()
                stage = nil
            }
            card.look.stop()
            card.panel.orderOut(nil)
            card.panel.close()
        }
        stopSpringIfIdle()
    }

    private static func fadeAndClose(_ panel: NSPanel) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.close()
        })
    }

    /// Text, when the notification could not be posted: a small card that fades up.
    func show(text: String) {
        let card = LandingView(text: text)
        card.onClick = { [weak self] in self?.dismiss() }
        present(card, size: NSSize(width: 320, height: 132))
    }

    /// Takes the card away now, without waiting.
    func dismiss() {
        holdTask?.cancel()
        holdTask = nil
        guard let panel = current else { return }
        if let card = peek, card.panel === panel { endEarly(card) }
        current = nil
        let end = Self.scaled(panel.frame, by: 0.25)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.close()
        })
    }

    /// Closes everything immediately, for deactivate().
    func tearDown() {
        PortalLightTexture.clear()
        SparkGPU.reset()
        holdTask?.cancel()
        holdTask = nil
        cancelDrives()
        springTimer?.invalidate()
        springTimer = nil
        seam?.close()
        seam = nil
        stage?.close()
        stage = nil
        peek?.look.stop()
        peek?.panel.orderOut(nil)
        peek?.panel.close()
        peek = nil
        current?.orderOut(nil)
        current?.close()
        current = nil
        batch = nil
    }

    // MARK: Presenting

    private func present(_ card: LandingView, size: NSSize) {
        dismiss()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let final = Self.landingRect(on: screen, size: size)

        let panel = LandingPanel(contentRect: final)
        card.frame = NSRect(origin: .zero, size: size)
        card.autoresizingMask = [.width, .height]
        panel.contentView = card
        wire(card)
        current = panel

        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(calm ? final : final.offsetBy(dx: 0, dy: -16), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }
        scheduleDismiss()
    }

    private func wire(_ card: LandingView) {
        card.onHover = { [weak self] inside in
            if inside { self?.holdTask?.cancel() } else { self?.scheduleDismiss() }
        }
        card.onDragEnded = { [weak self] in self?.dismiss() }
    }

    func palette(for effect: PortalEffect) -> PortalPalette {
        PortalPalette(tint: tints[effect] ?? .defaultTint(for: effect))
    }

    /// Warm an effect in its colour before a crossing, on a private paint queue:
    /// called whenever the effect or its colour changes, so a new colour never paints on the crossing's frame.
    func prepareLight(_ effect: PortalEffect) {
        let palette = palette(for: effect)
        for screen in NSScreen.screens {
            let rect = Self.landingRect(on: screen, size: Self.fileCardSize)
            let landing = CGPoint(x: rect.midX - screen.frame.minX, y: rect.midY - screen.frame.minY)
            let layout = PortalLightTexture.layout(effect: effect, screen: screen.frame.size, landing: landing,
                                                   k: StageView.scale(for: screen.frame.size))
            PortalLightTexture.prepare(effect: effect, palette: palette, layout: layout, scale: screen.backingScaleFactor)
        }
    }

    /// Where a card comes to rest: a little above the middle of the screen.
    private static func landingRect(on screen: NSScreen, size: NSSize) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.minX + visible.width * 0.64 - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08,
            width: size.width, height: size.height
        ).integral
    }

    private func scheduleDismiss(after delay: Double? = nil) {
        holdTask?.cancel()
        let seconds = delay ?? holdSeconds
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private static func scaled(_ rect: NSRect, by factor: CGFloat) -> NSRect {
        let w = rect.width * factor, h = rect.height * factor
        return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    static func thumbnail(for url: URL) async -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 220, height: 220), scale: scale, representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return rep.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Panel

/// The one panel type behind everything in the own-window waiver at the top of
/// this file: the landing/peek card, the edge seam, the stage, the right-edge
/// drop zone and the falling icon. No `.fullScreenAuxiliary`: none of them is
/// drawn over a full-screen app (a file still lands in Downloads › Drop Portal
/// and the File Tray, and plays its sound; see .droppykit/docs/store-plan.md).
private final class LandingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Card

final class LandingView: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragEnded: (() -> Void)?

    private let url: URL?
    private let dragImage: NSImage?
    private var downPoint: NSPoint?
    private var dragging = false
    private var titleLabel: NSTextField?

    init(image: NSImage, title: String, url: URL?) {
        self.url = url
        self.dragImage = image
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 268)) // subviews below are laid out for this size; .zero made autoresizing stretch them
        setUp()
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 10, y: 38, width: 220, height: 220)
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        addSubview(imageView)
        let label = Self.label(title, size: 12, weight: .medium, color: .white)
        label.frame = NSRect(x: 12, y: 10, width: 216, height: 18)
        label.autoresizingMask = [.width, .maxYMargin]
        addSubview(label)
        titleLabel = label
    }

    func setTitle(_ text: String) {
        if let titleLabel { KineticTitleView.stop(on: titleLabel) }
        titleLabel?.stringValue = text
    }

    /// The name's label, for the kinetic filename (LandingCelebration.swift).
    var titleField: NSTextField? { titleLabel }

    init(text: String) {
        self.url = nil
        self.dragImage = nil
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 132))
        setUp()
        let title = Self.label("Clipboard received", size: 13, weight: .semibold, color: .white)
        title.frame = NSRect(x: 16, y: 98, width: 288, height: 20)
        title.autoresizingMask = [.width, .minYMargin]
        addSubview(title)
        let body = Self.label(String(text.prefix(300)), size: 12, weight: .regular,
                              color: NSColor.white.withAlphaComponent(0.75))
        body.maximumNumberOfLines = 4
        body.lineBreakMode = .byTruncatingTail
        body.frame = NSRect(x: 16, y: 12, width: 288, height: 80)
        body.autoresizingMask = [.width, .height]
        addSubview(body)
    }

    required init?(coder: NSCoder) { nil }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.94).cgColor
        layer?.cornerRadius = 18
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { if !dragging { onHover?(false) } }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let url, let start = downPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let side: CGFloat = 96
        item.setDraggingFrame(NSRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side),
                              contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        if !dragging, downPoint != nil { onClick?() }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        onDragEnded?()
    }
}

// MARK: - Peek card

/// The peek on screen: its panel, where the spring has it and how it looks.
/// The panel is `CardLook.margin` larger than the card on every side, so the
/// effect has room; the card sits in the middle.
@MainActor
private final class PeekCard {
    /// Card and landed view keep their margins when the panel shrinks away.
    static let scales: NSView.AutoresizingMask = [.width, .height, .minXMargin, .maxXMargin, .minYMargin, .maxYMargin]

    let id: String
    let panel: LandingPanel
    let container = NSView()
    let view: PeekView
    let look: CardLook
    /// Card x fully off the right edge, and at the landing spot; the screen's right edge.
    let offX: CGFloat, onX: CGFloat, screenMaxX: CGFloat
    /// The card's bottom edge: the landing spot's, unless the phone's height moves it (`follow(phoneY:)`).
    var y: CGFloat
    let landY: CGFloat
    var yTarget: CGFloat
    var yVelocity: CGFloat = 0
    /// The phone's throw after the flick, from where the card was; nil flies the travel curve.
    var path: ThrowFlight?
    /// The screen it crosses onto, for the stage's coordinates.
    let screen: CGRect
    var x: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat
    /// Cards flicked together; more than one draws the stack.
    var count = 1
    var committed = false
    var leaving = false
    var settled = true
    /// Landed at its spot (the impact played); not before this time.
    var impacted = false
    /// The trackpad tapped as it came out of the edge.
    var felt = false
    /// The release: when, and from where.
    var flightStart: CFTimeInterval = 0
    var flightFrom: CGFloat = 0
    /// The landed card, when the file was here before the card.
    var pendingSettle: (@MainActor () -> Void)?
    /// Stardust: the landed card already takes hits but is not drawn yet; `reveal` shows it at the impact.
    var earlyLanded: LandingView?
    var reveal: (@MainActor () -> Void)?
    /// Stardust's card takes clicks and drags from `Stardust.interactiveAt` after the release.
    var takesHitsEarly: Bool {
        look.effect == .stardust && !look.calm && committed && !leaving
            && CACurrentMediaTime() - flightStart >= Stardust.interactiveAt
    }
    /// The picture's two colours for the celebration's sparks; nil uses the effect's.
    var tones: [NSColor]?

    init(id: String, view: PeekView, effect: PortalEffect, palette: PortalPalette, calm: Bool,
         offX: CGFloat, onX: CGFloat, y: CGFloat, screen: CGRect) {
        let screenMaxX = screen.maxX
        self.screen = screen
        let m = CardLook.margin, size = LandingPresenter.fileCardSize
        self.id = id
        self.view = view
        self.offX = offX
        self.onX = onX
        self.y = y
        self.landY = y
        self.yTarget = y
        self.screenMaxX = screenMaxX
        self.x = offX
        self.target = offX
        panel = LandingPanel(contentRect: NSRect(x: offX - m, y: y - m, width: size.width + 2 * m, height: size.height + 2 * m))
        // The window shadow cannot follow a changing shape at 120 Hz: on once landed.
        panel.hasShadow = false
        container.frame = NSRect(x: 0, y: 0, width: size.width + 2 * m, height: size.height + 2 * m)
        container.wantsLayer = true
        view.frame = NSRect(x: m, y: m, width: size.width, height: size.height)
        view.autoresizingMask = Self.scales
        container.addSubview(view)
        panel.contentView = container
        look = CardLook(effect: effect, palette: palette, calm: calm, host: container.layer!, card: view.layer!, cardFrame: view.frame)
    }

    /// Where the card's bottom edge may go: the visible frame, a little inside.
    lazy var yRange: ClosedRange<CGFloat> = {
        let visible = (NSScreen.screens.first { $0.frame == screen } ?? NSScreen.main)?.visibleFrame ?? screen
        let inset = visible.height * 0.06, low = visible.minY + inset
        return low...max(low, visible.maxY - inset - LandingPresenter.fileCardSize.height)
    }()

    /// The phone card's height (0 top to 1 bottom): the card comes out of
    /// the edge at that height and drifts half way to its spot with the drag.
    /// Reduce motion keeps it at its spot.
    func follow(phoneY: Double, progress: Double) {
        guard !look.calm else { return }
        let range = yRange, h = LandingPresenter.fileCardSize.height
        let mids = Double(range.lowerBound + h / 2)...Double(range.upperBound + h / 2)
        let entry = CGFloat(ThrowFlight.entryY(exitY: phoneY, in: mids)) - h / 2
        yTarget = entry + (landY - entry) * 0.5 * CGFloat(min(1, max(0, progress)))
    }

    /// The same critically damped spring as x, on y.
    func springY(dt: CGFloat, stiffness: CGFloat, damping: CGFloat) {
        let accel = stiffness * (yTarget - y) - damping * yVelocity
        yVelocity += accel * dt
        y += yVelocity * dt
        if abs(yTarget - y) < 0.5, abs(yVelocity) < 8 { y = yTarget; yVelocity = 0 }
    }

    var yAtRest: Bool { y == yTarget && yVelocity == 0 }

    /// The flick carried on: the path from here to the spot with the phone's
    /// velocity, its time handed to the card's look (and from there the
    /// stage), so the impact lands when the card does.
    func throwOn(_ release: PeekRelease) {
        let k = Double(screen.width / 1280), range = yRange
        let flight = ThrowFlight(from: .init(Double(x), Double(y)), to: .init(Double(onX), Double(landY)),
                                 release: .init(release.vx, release.vy), base: look.effect.flight, scale: k,
                                 yRange: Double(range.lowerBound)...Double(range.upperBound))
        path = flight
        yVelocity = 0
        // Wormhole turns of its own; CSS turns clockwise, layers counter-clockwise.
        let turn = look.effect == .wormhole ? 0 : -CGFloat(min(30, max(-30, release.angle)))
        look.thrown = (flight.duration, turn)
    }

    /// The card's middle in the stage's coordinates (the screen's, from its corner).
    var center: CGPoint {
        let size = LandingPresenter.fileCardSize
        return CGPoint(x: x + size.width / 2 - screen.minX, y: y + size.height / 2 - screen.minY)
    }

    func panelOrigin(x: CGFloat) -> NSPoint {
        NSPoint(x: x.rounded() - CardLook.margin, y: y.rounded() - CardLook.margin)
    }

    /// The panel where the spring has the card: invisible at the edge (a
    /// screen may sit to the right) and fully there after 40 pt, never drawn
    /// past this screen's edge, shaped by the effect.
    func place() {
        let origin = panelOrigin(x: x)
        panel.setFrameOrigin(origin)
        panel.alphaValue = min(1, max(0, (offX - x) / 40))
        look.clip(toMaxX: screenMaxX - origin.x)
        look.update(progress: (offX - x) / max(1, offX - onX), velocity: velocity, leaving: leaving)
    }
}

/// What is coming: the phone's thumbnail (or the file type's icon), the name
/// cut in the middle, the size, and once sent a ring for the upload.
final class PeekView: NSView {
    /// The dim and the ring over the picture, a view so it stays above it.
    private let overlayView = NSView()
    private var overlay: CALayer { overlayView.layer! }
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let status: NSTextField
    private var receiving = false

    private let picture = NSView(frame: NSRect(x: 10, y: 38, width: 220, height: 220))
    private var content: NSView?

    init(info: PeekInfo, image: NSImage?) {
        status = LandingView.label("Receiving…", size: 12, weight: .medium, color: .white)
        super.init(frame: NSRect(origin: .zero, size: LandingPresenter.fileCardSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.94).cgColor
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        picture.wantsLayer = true
        picture.layer?.cornerRadius = 12
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        picture.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        if info.count > 1 {
            // The cards under the top one, showing above it; drawn before the picture so they sit behind.
            for (inset, rise, alpha) in [(16.0, 8.0, 0.10), (8.0, 4.0, 0.18)] {
                let sheet = NSView(frame: picture.frame.insetBy(dx: inset, dy: 0).offsetBy(dx: 0, dy: rise))
                sheet.wantsLayer = true
                sheet.layer?.cornerRadius = 12
                sheet.layer?.cornerCurve = .continuous
                sheet.layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
                addSubview(sheet)
            }
        }
        if let image {
            setThumbnail(image)
        } else {
            let type = UTType(filenameExtension: (info.name as NSString).pathExtension)
                ?? (info.kind == .image ? .image : info.kind == .video ? .movie : .data)
            let icon = PictureView(image: NSWorkspace.shared.icon(for: type), fill: false)
            icon.frame = picture.bounds.insetBy(dx: 50, dy: 50)
            picture.addSubview(icon)
            content = icon
        }

        overlayView.frame = picture.bounds
        overlayView.wantsLayer = true
        overlay.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        overlay.opacity = 0
        let diameter: CGFloat = 46
        // From twelve o'clock, clockwise (layer space has y up).
        let circle = CGMutablePath()
        circle.addArc(center: CGPoint(x: 110, y: 122), radius: diameter / 2,
                      startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for (shape, alpha) in [(track, 0.25), (ring, 1.0)] {
            shape.path = circle
            shape.fillColor = nil
            shape.strokeColor = NSColor.white.withAlphaComponent(alpha).cgColor
            shape.lineWidth = 4
            shape.lineCap = .round
            overlay.addSublayer(shape)
        }
        ring.frame = overlay.bounds
        track.frame = overlay.bounds
        ring.strokeEnd = 0
        picture.addSubview(overlayView)
        addSubview(picture)

        status.alignment = .center
        status.frame = NSRect(x: 10, y: 38 + 62, width: 220, height: 18)
        status.alphaValue = 0
        addSubview(status)

        let sizeText = ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file)
        let sizeLabel = LandingView.label(sizeText, size: 12, weight: .regular,
                                          color: NSColor.white.withAlphaComponent(0.55))
        sizeLabel.alignment = .right
        sizeLabel.sizeToFit()
        let sizeWidth = ceil(sizeLabel.frame.width)
        sizeLabel.frame = NSRect(x: 228 - sizeWidth, y: 10, width: sizeWidth, height: 18)
        addSubview(sizeLabel)
        let name = LandingView.label(info.count > 1 ? "\(info.count) files" : info.name,
                                     size: 12, weight: .medium, color: .white)
        name.frame = NSRect(x: 12, y: 10, width: 216 - sizeWidth - 8, height: 18)
        addSubview(name)

        layerUsesCoreImageFilters = true
    }

    /// The card as it is now, for Beam's slices, Liquid's rounded copy and Paper plane's wings.
    func snapshot() -> CGImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    required init?(coder: NSCoder) { nil }

    /// The dim, the ring and "Receiving…", with `progress` of the ring drawn.
    /// Swaps the file-type icon for the decoded thumbnail, under the ring's dim.
    func setThumbnail(_ image: NSImage) {
        content?.removeFromSuperview()
        let view = PictureView(image: image, fill: true)
        view.frame = picture.bounds
        picture.addSubview(view, positioned: .below, relativeTo: nil)
        content = view
    }

    func showReceiving(progress: Double) {
        if !receiving {
            receiving = true
            overlay.opacity = 1
            status.alphaValue = 1
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        ring.strokeEnd = CGFloat(min(1, max(0, progress)))
        CATransaction.commit()
    }
}

/// An image drawn to fill (cropped) or to fit its bounds.
private final class PictureView: NSView {
    private let image: NSImage
    private let fill: Bool

    init(image: NSImage, fill: Bool) {
        self.image = image
        self.fill = fill
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = fill ? max(bounds.width / size.width, bounds.height / size.height)
                         : min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        image.draw(in: NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
}

// MARK: - Portal seam

/// The light on the screen's right edge where a card crosses from the phone:
/// a panel of its own that never takes a click or the focus, on the card's
/// screen and centred on the card. Its look is the effect's `SeamView`.
@MainActor
private final class PortalSeam {
    private let panel: LandingPanel
    private let view: SeamView
    private var retiring = false
    private var closeTask: Task<Void, Never>?

    init(screen: NSScreen, centerY: CGFloat, effect: PortalEffect, palette: PortalPalette, calm: Bool) {
        let size = SeamView.size(screenHeight: screen.frame.height)
        let frame = NSRect(x: screen.frame.maxX - size.width, y: screen.frame.minY,
                           width: size.width, height: size.height)
        panel = LandingPanel(contentRect: frame)
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        view = SeamView(frame: NSRect(origin: .zero, size: size), effect: effect, palette: palette, calm: calm,
                        centerY: centerY - screen.frame.minY)
        panel.contentView = view
    }

    func show() {
        view.setIntensity(0)
        panel.orderFrontRegardless()
    }

    /// The panel, for ordering the stage under it (the right-edge send).
    var window: NSWindow { panel }

    /// 0 dark, 1 full light; follows the drag.
    func setIntensity(_ value: CGFloat) {
        guard !retiring else { return }
        view.setIntensity(value)
    }

    /// The light's height in the screen's coordinates from its bottom edge.
    func moveCenter(toY y: CGFloat) {
        guard !retiring else { return }
        view.moveCenter(toY: y)
    }

    /// A send plays the effect's send and fades (about 0.65 s); a cancel holds
    /// the light while the card goes back into it, then fades. The panel closes after.
    func retire(bloom: Bool) {
        guard !retiring else { return }
        retiring = true
        let seconds = view.retire(bloom: bloom)
        // Holds self: the right-edge portal lets go of a retiring seam at once,
        // and a weak self here left its panel on screen for good.
        closeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.close()
        }
    }

    func close() {
        closeTask?.cancel()
        closeTask = nil
        retiring = true
        view.stop()
        panel.orderOut(nil)
        panel.close()
    }
}

// MARK: - Portal stage

/// The whole screen behind the peek card, a panel of its own that never
/// takes a click or the focus and is ordered just under the card. Its look is
/// the effect's `StageView`; it closes after the impact, on a cancel, on the
/// next crossing and in deactivate().
@MainActor
private final class PortalStage {
    private let panel: LandingPanel
    private let view: StageView
    private var closeTask: Task<Void, Never>?

    init(screen: NSScreen, effect: PortalEffect, palette: PortalPalette, seam: CGPoint, landing: CGPoint) {
        panel = LandingPanel(contentRect: screen.frame)
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        view = StageView(frame: NSRect(origin: .zero, size: screen.frame.size), effect: effect, palette: palette,
                         seam: seam, landing: landing, backingScale: screen.backingScaleFactor)
        panel.contentView = view
    }

    func show(below window: NSWindow) {
        view.setIntensity(0)
        panel.orderFrontRegardless()
        panel.order(.below, relativeTo: window.windowNumber)
    }

    func setIntensity(_ value: CGFloat) { view.setIntensity(value) }
    func follow(card center: CGPoint) { view.follow(card: center) }
    func moveSeam(toY y: CGFloat) { view.moveSeam(toY: y) }
    func send(flight: Double? = nil) {
        if let flight, flight > 0 { view.flight = flight }
        view.send()
    }
    func impact() { view.impact() }
    var afterImpactSeconds: Double { view.afterImpactSeconds }

    /// A courier crossing goes live: its plan, the card copy's picture, its frame clock, the click that skips.
    func startCourier(_ plan: CourierPlan, screen: NSScreen, image: CGImage?, onSkip: @escaping () -> Void) {
        guard let courier = view.courier else { return }
        courier.plan = plan
        courier.setCardImage(image)
        courier.onSkip = onSkip
        courier.pointer = { [weak panel] in
            guard let panel else { return nil }
            let point = NSEvent.mouseLocation
            return (CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY), NSEvent.pressedMouseButtons & 1 != 0)
        }
        courier.start(screen: screen)
    }

    func setCardImage(_ image: CGImage?) { view.courier?.setCardImage(image) }

    /// A cancel: the drag runs backwards as the card goes back (the
    /// presenter keeps feeding p and closes the panel when the card is gone);
    /// if that takes longer than 0.45 s the light fades and the panel closes.
    func retire() {
        closeTask?.cancel()
        // Holds self until the panel is closed (see `PortalSeam.retire`).
        closeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            let seconds = self.view.fadeOut()
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.05) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.close()
        }
    }

    func close() {
        closeTask?.cancel()
        closeTask = nil
        view.stop()
        panel.orderOut(nil)
        panel.close()
    }
}

// MARK: - Thumbnail decoding

/// The phone's JPEG as a bitmap of at most 440 px a side (twice the 220 pt
/// picture), decoded by ImageIO without loading the full size. Safe off the main thread.
enum PeekThumbnail {
    static func decode(_ data: Data) -> CGImage? {
        guard PeekMessage.isJPEG(data),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 440,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}


// MARK: - Harness preview

/// The settings' colour row on its own, as the pane lays it out, for the harness.
private struct ColorRowPreview: View {
    @State var tint: PortalTint

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "paintpalette").foregroundStyle(.secondary)
            Text("Color").font(.system(size: 13))
            Spacer(minLength: 12)
            TintPicker(tint: $tint)
        }
        .padding(.horizontal, 14)
        .frame(width: 560, height: 64)
        .background(Color(white: 0.16))
    }
}

/// Pictures for the harness (`--peek-shots <dir>`): a thumbnail mid-drag, the
/// same card receiving at 42%, a file with no thumbnail, and one picture per
/// crossing effect half way through (`effect-<name>.png`: the edge light at
/// 0.5 and the card half formed). No server, no panel: views and layers drawn to PNG.
public enum PortalPreview {
    @MainActor
    static var samplePhoto: PeekInfo {
        PeekInfo(id: "preview", name: "IMG_4821 holiday at the beach with friends.HEIC",
                 kind: .image, size: 3_481_000, thumb: sampleThumb())
    }

    @MainActor
    public static func writePeekShots(to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = samplePhoto
        let doc = PeekInfo(id: "preview-doc", name: "Quarterly report final v3.pdf", kind: .file, size: 812_000)
        var stack = photo
        stack.count = 4
        var urls: [URL] = []
        for (name, info, progress) in [("peek-drag", photo, nil), ("peek-receiving", photo, 0.42),
                                       ("peek-file", doc, nil), ("peek-stack", stack, nil)] as [(String, PeekInfo, Double?)] {
            let view = PeekView(info: info, image: image(of: info))
            if let progress { view.showReceiving(progress: progress) }
            let url = folder.appendingPathComponent("\(name).png")
            try render(view, to: url)
            urls.append(url)
        }
        // The settings' colour row: an effect's default, Rainbow, and a custom colour.
        for (name, tint) in [("default", PortalTint.defaultTint(for: .portal)), ("rainbow", .rainbow),
                             ("custom", .color(PortalRGB(hex: "#12C8A0")!))] as [(String, PortalTint)] {
            let row = NSHostingView(rootView: ColorRowPreview(tint: tint))
            row.frame = NSRect(x: 0, y: 0, width: 560, height: 64)
            row.appearance = NSAppearance(named: .darkAqua)
            let url = folder.appendingPathComponent("settings-color-\(name).png")
            try render(row, to: url)
            urls.append(url)
        }
        // Each effect in its default colour, in Lime, in Rainbow, and in its default on a light wallpaper.
        let variants: [(suffix: String, tint: PortalTint?, light: Bool)] = [("", nil, false), ("-lime", .lime, false),
                                                                             ("-rainbow", .rainbow, false), ("-light", nil, true)]
        for effect in PortalEffect.allCases {
            for variant in variants {
                for impact in [false, true] {
                    let url = folder.appendingPathComponent("effect-\(effect.rawValue)\(impact ? "-impact" : "")\(variant.suffix).png")
                    let palette = PortalPalette(tint: variant.tint ?? .defaultTint(for: effect), at: Date(timeIntervalSince1970: 0))
                    try writeEffectShot(effect, palette: palette, light: variant.light, photo: photo, impact: impact, to: url)
                    urls.append(url)
                }
            }
            // Rainbow's hue sweeping through the impact, 0.2 s after the landing; and a drag at p = 0.85.
            let rainbow = PortalPalette(tint: .rainbow, at: Date(timeIntervalSince1970: 0))
            let mid = folder.appendingPathComponent("effect-\(effect.rawValue)-impact-mid-rainbow.png")
            try writeEffectShot(effect, palette: rainbow, light: false, photo: photo, impact: true, impactAt: 0.2, to: mid)
            let late = folder.appendingPathComponent("effect-\(effect.rawValue)-p85.png")
            try writeEffectShot(effect, palette: .of(effect), light: false, photo: photo, impact: false, progress: 0.85, to: late)
            urls += [mid, late]
        }
        #if DEBUG
        // The landing touches, Core Animation path (LandingCelebration.swift).
        urls += try LandingTouchesProbe.writeShots(to: folder, gpu: false)
        #endif
        return urls
    }

    @MainActor
    private static func image(of info: PeekInfo) -> NSImage? {
        PeekThumbnail.decode(info.thumb).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    /// A whole 1440 × 900 dark desktop, drawn at full size, to set beside the
    /// motion spec's hero frames. Peek: the drag at p = 0.5, the stage and the
    /// edge light at 0.5 and the card half way. Impact: sampled at each effect's brightest readable beat after the
    /// landing (the spec's L), released at p = 0.45.
    @MainActor
    private static func writeEffectShot(_ effect: PortalEffect, palette: PortalPalette, light: Bool, photo: PeekInfo,
                                        impact: Bool, impactAt: Double? = nil, progress: CGFloat = 0.5, to url: URL) throws {
        let image = try effectImage(effect, palette: palette, light: light, photo: photo, impact: impact,
                                    impactAt: impactAt, progress: progress)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    @MainActor private static var thumbnails: [String: NSImage] = [:]

    /// The settings' mini preview: the right part of `effectImage` at p = 0.7,
    /// the light open and the card on its way, in the effect's own colour.
    /// Made on the main actor the first time each effect and colour is shown, then kept.
    @MainActor
    static func thumbnail(_ effect: PortalEffect, tint: PortalTint) -> NSImage? {
        let key = "\(effect.rawValue) \(tint.stored)"
        if let hit = thumbnails[key] { return hit }
        let palette = PortalPalette(tint: tint, at: Date(timeIntervalSince1970: 0))
        guard let full = try? effectImage(effect, palette: palette, light: false, photo: samplePhoto, impact: false, progress: 0.7),
              let crop = full.cropping(to: CGRect(x: 560, y: 0, width: 880, height: 550).offsetBy(dx: 0, dy: 175)) else { return nil }
        let image = NSImage(cgImage: crop, size: NSSize(width: 224, height: 140))
        if thumbnails.count > 24 { thumbnails.removeAll() }
        thumbnails[key] = image
        return image
    }

    @MainActor
    static func effectImage(_ effect: PortalEffect, palette: PortalPalette, light: Bool, photo: PeekInfo,
                            impact: Bool, impactAt: Double? = nil, progress: CGFloat = 0.5) throws -> CGImage {
        let size = CGSize(width: 1440, height: 900)
        let root = effectScene(effect, palette: palette, light: light, photo: photo, impact: impact,
                               impactAt: impactAt, progress: progress, size: size)
        let scale: CGFloat = 1
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.scaleBy(x: scale, y: scale)
        root.render(in: ctx)
        guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }

    /// The desktop, the stage, the card and the edge light of one instant, as layers.
    @MainActor
    static func effectScene(_ effect: PortalEffect, palette: PortalPalette, light: Bool, photo: PeekInfo,
                            impact: Bool, impactAt: Double? = nil, progress: CGFloat = 0.5,
                            size: CGSize = CGSize(width: 1440, height: 900), sentAt: Double? = nil) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        let desk = CAGradientLayer()
        desk.frame = root.bounds
        desk.colors = (light ? [NSColor(srgbRed: 0.86, green: 0.89, blue: 0.94, alpha: 1), NSColor(srgbRed: 0.93, green: 0.9, blue: 0.86, alpha: 1)]
                             : [NSColor(srgbRed: 0.07, green: 0.07, blue: 0.1, alpha: 1), NSColor(srgbRed: 0.043, green: 0.043, blue: 0.06, alpha: 1)]).map(\.cgColor)
        root.addSublayer(desk)
        // A window on the desktop, so the vignette has something to dim.
        let window = CALayer()
        window.frame = CGRect(x: 120, y: 200, width: 640, height: 440)
        window.backgroundColor = (light ? NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1) : NSColor(srgbRed: 0.12, green: 0.12, blue: 0.15, alpha: 1)).cgColor
        window.cornerRadius = 12
        root.addSublayer(window)

        let peekView = PeekView(info: photo, image: image(of: photo))
        let snapshot = peekView.snapshot()
        if impact { peekView.showReceiving(progress: 0.2) }
        let m = CardLook.margin, card = LandingPresenter.fileCardSize
        let landing = CGPoint(x: size.width * 0.64, y: size.height / 2 + size.height * 0.04)
        let seam = CGPoint(x: size.width, y: landing.y)
        let stage = StageView(frame: NSRect(origin: .zero, size: size), effect: effect, palette: palette, seam: seam, landing: landing)
        if let layer = stage.layer {
            layer.frame = root.bounds
            root.addSublayer(layer)
        }

        let offX = size.width + 12, onX = landing.x - card.width / 2
        let p: CGFloat = impact ? 0.45 : progress
        let x = impact ? onX : offX - (offX - onX) * p
        let host = CALayer()
        host.frame = CGRect(x: x - m, y: landing.y - card.height / 2 - m, width: card.width + 2 * m, height: card.height + 2 * m)
        let cardLayer = CALayer()
        cardLayer.frame = CGRect(x: m, y: m, width: card.width, height: card.height)
        cardLayer.contents = impact ? peekView.snapshot() : snapshot
        cardLayer.cornerRadius = 18
        host.addSublayer(cardLayer)
        root.addSublayer(host)
        let look = CardLook(effect: effect, palette: palette, calm: false, host: host, card: cardLayer, cardFrame: cardLayer.frame)
        look.setSnapshot(snapshot)
        stage.courier?.setCardImage(snapshot)
        look.clip(toMaxX: size.width - host.frame.minX)
        let center = CGPoint(x: host.frame.midX, y: host.frame.midY)
        stage.paintNow()
        stage.setIntensity(p)
        stage.follow(card: center)
        look.update(progress: p, velocity: -700, leaving: false)
        if let sentAt {
            // In flight: the release `sentAt` s ago, not landed yet.
            look.commit(still: sentAt)
            stage.send(still: sentAt)
        } else if impact {
            let t = impactAt ?? (effect == .plane ? 0.085 : effect == .beam ? 0.048 : 0.055), L = effect.flight
            look.commit(still: L + t)
            look.land(still: t)
            stage.send(still: L + t)
            stage.impact(still: t)
        } else {
            let seamSize = SeamView.size(screenHeight: size.height)
            let seamView = SeamView(frame: NSRect(x: size.width - seamSize.width, y: 0, width: seamSize.width, height: seamSize.height),
                                    effect: effect, palette: palette, calm: false, centerY: seam.y)
            seamView.setIntensity(p)
            if let seamLayer = seamView.layer {
                seamLayer.frame = seamView.frame
                root.addSublayer(seamLayer)
            }
        }
        return root
    }

    @MainActor
    private static func render(_ view: NSView, to url: URL) throws {
        let pad: CGFloat = 24
        let size = NSSize(width: view.frame.width + pad * 2, height: view.frame.height + pad * 2)
        let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(calibratedRed: 0.32, green: 0.36, blue: 0.42, alpha: 1).cgColor
        view.setFrameOrigin(NSPoint(x: pad, y: pad))
        backdrop.addSubview(view)
        backdrop.layoutSubtreeIfNeeded()
        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    /// A made-up photo: sky, sun, sea and sand, as a JPEG like the phone's.
    @MainActor
    private static func sampleThumb() -> Data {
        let image = NSImage(size: NSSize(width: 160, height: 120), flipped: false) { rect in
            NSColor(calibratedRed: 0.45, green: 0.68, blue: 0.92, alpha: 1).setFill(); rect.fill()
            NSColor(calibratedRed: 1, green: 0.84, blue: 0.4, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 104, y: 74, width: 30, height: 30)).fill()
            NSColor(calibratedRed: 0.13, green: 0.42, blue: 0.62, alpha: 1).setFill()
            NSRect(x: 0, y: 30, width: 160, height: 34).fill()
            NSColor(calibratedRed: 0.93, green: 0.84, blue: 0.66, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 160, height: 32).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return Data() }
        return jpeg
    }
}


// MARK: - To the phone: the right edge

/// The mirror of a flick off the phone's left edge: while files are dragged
/// anywhere on the Mac (`EdgeDragWatcher` says when), a thin drop zone waits
/// on the right edge of every screen whose right edge is the desktop's. It is
/// all but invisible and takes only file drops; anything else passes. As the
/// pointer nears the edge the portal opens in the chosen effect and colour
/// (the same `SeamView` and `StageView` as a crossing, the ribbon reaching
/// the pointer); a drop plays the send, the file's icon falls through the
/// edge and the stage plays a short impact there. Under Reduce motion only the
/// edge light shows and the icon fades. When the zone and the light go is
/// `EdgeDropState`'s call: on the drop, on a button-up away from the zone, 0.6 s
/// after a button-up on it without a drop, and, from a watchdog of its own,
/// 1.5 s after the last drag activity once the button is up. Every step is a
/// line in `DropPortal.log` (`edge:`). Everything is closed in `tearDown()`.
@MainActor
final class EdgePortal {
    /// Files dropped on the edge, for the droplet to offer to the phone.
    var onDrop: (([URL]) -> Void)?
    /// A send played (a drop, the shortcut, the Quick Action): its sound.
    var onSent: ((PortalEffect) -> Void)?
    /// Where dropped file promises (Photos, Mail) are written before they are offered.
    var promiseFolder: URL?
    /// The rectangles whose right edge takes drops, in screen coordinates:
    /// the outer screens. The harness's drop test points it at a strip of its own.
    var edges: () -> [NSRect] = { EdgePortal.edgeScreens().map(\.frame) }

    /// Points from the edge where the light starts.
    static let reach: CGFloat = 220
    /// The zone at rest: a sliver on the edge, so drags elsewhere pass.
    static let zoneWidth: CGFloat = 8
    /// The zone while the light is open: the lit band takes the drop. An 8 pt
    /// zone under a light 220 pt wide missed every drop let go on the light.
    static let openZoneWidth: CGFloat = 150
    /// The types the zone (and the drag watcher) take: file URLs, the legacy
    /// file-name list and file promises.
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static var dropTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, filenamesType] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    private let presenter: LandingPresenter
    private var state = EdgeDropState()
    private var zones: [EdgeZonePanel] = []
    private var seam: PortalSeam?
    private var stage: PortalStage?
    private var screenFrame: NSRect?
    private var lastPoint: NSPoint?
    /// The light went out because the pointer rested; it comes back when it moves.
    private var rested = false
    private var watchdog: Timer?
    private var closeTasks: [Task<Void, Never>] = []

    init(presenter: LandingPresenter) {
        self.presenter = presenter
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: The drag

    func dragBegan(types: [String] = []) {
        let action = state.begin(at: now)
        lastPoint = nil
        rested = false
        guard action == .showZones else { return }
        PortalLog.write("edge: drag detected types=\(Self.shortTypes(types))")
        for edge in edges() {
            let zone = EdgeZonePanel(frame: NSRect(x: edge.maxX - Self.zoneWidth, y: edge.minY,
                                                   width: Self.zoneWidth, height: edge.height),
                                     edge: edge)
            zone.zone.owner = self
            zone.orderFrontRegardless()
            zones.append(zone)
            PortalLog.write("edge: zone shown frame=\(Self.describe(zone.frame)) visible=\(zone.isVisible) level=\(zone.level)")
        }
        if zones.isEmpty { PortalLog.write("edge: no screen edge to show a zone on") }
        startWatchdog()
    }

    func dragMoved(_ point: NSPoint) {
        guard !zones.isEmpty else { return }
        if point != lastPoint {
            lastPoint = point
            state.moved(at: now)
            rested = false
        }
        guard !rested else { return }
        guard let edge = zones.first(where: { NSMouseInRect(point, $0.edge, false) })?.edge else {
            return dim()
        }
        let p = min(1, max(0, 1 - (edge.maxX - point.x) / Self.reach))
        guard p > 0 || seam != nil else { return }
        if screenFrame != edge { open(on: edge, y: point.y) }
        widenZones(p > 0)
        seam?.setIntensity(p)
        stage?.setIntensity(p * 0.8)
        if let display = screenFrame.flatMap(Self.display(for:)) {
            stage?.follow(card: CGPoint(x: point.x - display.frame.minX, y: point.y - display.frame.minY))
        }
    }

    /// The button came up. A drop on the zone lands a moment later, so the zone
    /// waits for it while the pointer is on it; anywhere else it goes at once.
    func dragEnded() {
        guard state.visible else { return }
        PortalLog.write("edge: button up hovering=\(state.hovering)")
        handle(state.buttonUp(at: now))
    }

    // MARK: Zone callbacks

    fileprivate func zoneEntered(files: Int, promises: Int, types: [String]) {
        PortalLog.write("edge: draggingEntered files=\(files) promises=\(promises) types=\(Self.shortTypes(types))")
        if files + promises > 0 { state.entered(at: now) }
    }

    fileprivate func zoneUpdated() {
        state.moved(at: now)
        rested = false
    }

    fileprivate func zoneExited() {
        PortalLog.write("edge: draggingExited")
        handle(state.exited(at: now))
    }

    /// `performDragOperation`: true when the zone took the drop.
    fileprivate func zoneDrop(_ info: NSDraggingInfo, in window: NSWindow) -> Bool {
        let board = info.draggingPasteboard
        let point = window.convertPoint(toScreen: info.draggingLocation)
        let urls = Self.files(on: board)
        if !urls.isEmpty {
            PortalLog.write("edge: performDragOperation took \(urls.count) file(s): \(urls.map(\.lastPathComponent).joined(separator: ", "))")
            handle(state.dropped())
            fallThrough(icon: NSWorkspace.shared.icon(forFiles: urls.map(\.path)) ?? NSWorkspace.shared.icon(for: .data), at: point)
            onDrop?(urls)
            return true
        }
        let promises = Self.promises(on: board)
        guard !promises.isEmpty, let folder = promiseFolder?.appendingPathComponent(UUID().uuidString, isDirectory: true),
              (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            PortalLog.write("edge: performDragOperation refused: no regular files (types=\(Self.shortTypes(board.types?.map(\.rawValue) ?? [])))")
            handle(state.refused())
            return false
        }
        PortalLog.write("edge: performDragOperation took \(promises.count) file promise(s)")
        handle(state.dropped())
        fallThrough(icon: NSWorkspace.shared.icon(for: .data), at: point)
        Self.receive(promises, into: folder) { [weak self] urls in
            PortalLog.write("edge: promises written \(urls.count)")
            if !urls.isEmpty { self?.onDrop?(urls) }
        }
        return true
    }

    // MARK: Without a drag

    /// The shortcut and the Quick Action: the portal opens on the screen with
    /// the pointer, at its height, and the files' icon falls through.
    func play(files: [URL]) {
        guard !files.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = Self.edgeScreens().first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? Self.edgeScreens().first else { return }
        let f = screen.frame
        let y = min(f.maxY - 120, max(f.minY + 120, mouse.y))
        let point = NSPoint(x: f.maxX - 40, y: y)
        open(on: f, y: y)
        seam?.setIntensity(0.85)
        stage?.setIntensity(0.7)
        stage?.follow(card: CGPoint(x: point.x - 80 - f.minX, y: y - f.minY))
        let icon = NSWorkspace.shared.icon(forFiles: files.map(\.path)) ?? NSWorkspace.shared.icon(for: .data)
        after(0.16) { [weak self] in self?.fallThrough(icon: icon, at: point) }
    }

    // MARK: State

    private func handle(_ action: EdgeDropState.Action) {
        switch action {
        case .none, .showZones:
            break
        case .dimLight:
            PortalLog.write("edge: light dimmed, the pointer rests")
            rested = true
            dim()
        case .hide(let reason):
            let had = !zones.isEmpty
            hideZones()
            dim()
            stopWatchdog()
            if had { PortalLog.write("edge: zone hidden (\(reason.rawValue))") }
        }
    }

    /// Hides everything even when the drag watcher misses the end of the drag.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handle(self.state.tick(at: self.now, buttonDown: NSEvent.pressedMouseButtons & 1 != 0))
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    // MARK: Light

    private func open(on edge: NSRect, y: CGFloat) {
        closeVisuals()
        guard let display = Self.display(for: edge) else { return }
        screenFrame = edge
        let effect = presenter.effect
        let palette = presenter.palette(for: effect)
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let screen = display.frame
        let light = PortalSeam(screen: display, centerY: y, effect: effect, palette: palette, calm: calm)
        light.show()
        seam = light
        if !calm {
            let local = CGPoint(x: screen.width, y: y - screen.minY)
            let stage = PortalStage(screen: display, effect: effect, palette: palette, seam: local,
                                    landing: CGPoint(x: screen.width - 70, y: local.y))
            stage.show(below: light.window)
            self.stage = stage
        }
        // The zone stays on top of the light, or the light would catch the drop.
        zones.forEach { $0.orderFrontRegardless() }
    }

    /// The drop: the send, the icon through the edge, a short impact at the edge.
    private func fallThrough(icon: NSImage, at point: NSPoint) {
        let effect = presenter.effect
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if seam == nil, let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            open(on: screen.frame, y: point.y)
            seam?.setIntensity(1)
        }
        let seam = self.seam, stage = self.stage
        self.seam = nil
        self.stage = nil
        screenFrame = nil
        seam?.retire(bloom: true)
        if let stage {
            stage.setIntensity(1)
            stage.send()
            after(0.2) { stage.impact() }
            after(0.2 + StageView.Look.impactSeconds + 0.1) { stage.close() }
        }
        FallingIcon.play(icon: icon, from: point, calm: calm)
        onSent?(effect)
    }

    /// The pointer left the edge, or the drag ended: the light goes out. The
    /// seam and the stage close themselves once faded (`retire` holds them).
    private func dim() {
        widenZones(false)
        guard seam != nil || stage != nil else { return }
        seam?.retire(bloom: false)
        stage?.retire()
        seam = nil
        stage = nil
        screenFrame = nil
    }

    private func closeVisuals() {
        seam?.close()
        stage?.close()
        seam = nil
        stage = nil
        screenFrame = nil
    }

    /// The zone covers the lit band while the light is open, the sliver otherwise.
    private func widenZones(_ open: Bool) {
        let width = open ? Self.openZoneWidth : Self.zoneWidth
        for zone in zones where zone.width != width {
            zone.setWidth(width)
            PortalLog.write("edge: zone \(open ? "widened" : "narrowed") to \(Int(width)) pt")
        }
    }

    private func hideZones() {
        zones.forEach { $0.close() }
        zones = []
    }

    private func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        closeTasks.removeAll { $0.isCancelled }
        closeTasks.append(Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            body()
        })
    }

    func tearDown() {
        handle(state.tearDown())
        stopWatchdog()
        closeTasks.forEach { $0.cancel() }
        closeTasks = []
        hideZones()
        closeVisuals()
        FallingIcon.closeAll()
    }

    /// The zones on screen, for `EdgeDropProbe`.
    fileprivate var zonesForTest: [EdgeZonePanel] { zones }
    /// The light is up, for `EdgeDropProbe`.
    var lightOn: Bool { seam != nil || stage != nil }

    // MARK: Helpers

    /// Screens whose right edge is the desktop's: no other screen continues past it.
    static func edgeScreens() -> [NSScreen] {
        let all = NSScreen.screens
        let outer = all.filter { screen in
            !all.contains { other in
                other != screen && abs(other.frame.minX - screen.frame.maxX) < 2
                    && other.frame.maxY > screen.frame.minY && other.frame.minY < screen.frame.maxY
            }
        }
        return outer.isEmpty ? Array(all.max { $0.frame.maxX < $1.frame.maxX }.map { [$0] } ?? []) : outer
    }

    /// The screen an edge rectangle is on (the one holding its centre).
    static func display(for edge: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame == edge }
            ?? NSScreen.screens.first { NSMouseInRect(NSPoint(x: edge.midX, y: edge.midY), $0.frame, false) }
    }

    /// Regular files on a drag pasteboard, from file URLs or the legacy
    /// file-name list, folders included (they go as a .zip); anything else is left out.
    static func files(on board: NSPasteboard) -> [URL] {
        var urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let paths = board.propertyList(forType: filenamesType) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        return urls.filter {
            let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            return values?.isRegularFile == true || values?.isDirectory == true
        }
    }

    static func promises(on board: NSPasteboard) -> [NSFilePromiseReceiver] {
        board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    /// Writes each promise into `folder` off the main thread; `done` on the main actor with the regular files.
    private static func receive(_ promises: [NSFilePromiseReceiver], into folder: URL,
                                done: @escaping @MainActor ([URL]) -> Void) {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for promise in promises {
            group.enter()
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                if error == nil, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { done(urls) }
        }
    }

    private static func shortTypes(_ types: [String]) -> String {
        let shown = types.prefix(6).joined(separator: ",")
        return types.count > 6 ? "\(shown),+\(types.count - 6)" : (shown.isEmpty ? "-" : shown)
    }

    fileprivate static func describe(_ r: NSRect) -> String {
        "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
    }
}

/// The thin drop target on one screen's right edge. Nearly clear (a fully
/// clear window lets drags through), never key, never a click target: it is
/// ordered in only while a file drag is on.
@MainActor
private final class EdgeZonePanel {
    let zone: EdgeZoneView
    /// The rectangle whose right edge this zone sits on (a screen's frame).
    let edge: NSRect
    private let panel: LandingPanel

    init(frame: NSRect, edge: NSRect) {
        zone = EdgeZoneView(frame: NSRect(origin: .zero, size: frame.size))
        zone.autoresizingMask = [.width, .height]
        self.edge = edge
        panel = LandingPanel(contentRect: frame)
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.backgroundColor = NSColor(white: 0, alpha: 0.02)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.contentView = zone
        panel.setFrame(frame, display: false)
    }

    var frame: NSRect { panel.frame }
    var width: CGFloat { panel.frame.width }

    /// Grows or shrinks leftwards from the edge.
    func setWidth(_ width: CGFloat) {
        panel.setFrame(NSRect(x: edge.maxX - width, y: edge.minY, width: width, height: edge.height), display: false)
    }
    var isVisible: Bool { panel.isVisible }
    var level: Int { panel.level.rawValue }
    var window: NSWindow { panel }

    func orderFrontRegardless() { panel.orderFrontRegardless() }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

private final class EdgeZoneView: NSView {
    weak var owner: EdgePortal?
    private var updates = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(EdgePortal.dropTypes)
    }

    required init?(coder: NSCoder) { nil }

    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        guard !EdgePortal.files(on: board).isEmpty || !EdgePortal.promises(on: board).isEmpty else { return [] }
        // Copy whatever the source allows; Finder allows copy, some sources only generic or move.
        let mask = sender.draggingSourceOperationMask
        for op in [NSDragOperation.copy, .generic, .move] where mask.contains(op) { return op }
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        updates = 0
        MainActor.assumeIsolated {
            owner?.zoneEntered(files: EdgePortal.files(on: board).count, promises: EdgePortal.promises(on: board).count,
                               types: board.types?.map(\.rawValue) ?? [])
        }
        let op = operation(sender)
        PortalLog.write("edge: draggingEntered -> operation \(op.rawValue) (source mask \(sender.draggingSourceOperationMask.rawValue))")
        return op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updates += 1
        if updates == 1 { PortalLog.write("edge: draggingUpdated") }
        MainActor.assumeIsolated { owner?.zoneUpdated() }
        return operation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { owner?.zoneExited() }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let window else {
            PortalLog.write("edge: performDragOperation without a window")
            return false
        }
        return MainActor.assumeIsolated { owner?.zoneDrop(sender, in: window) ?? false }
    }
}

/// The dropped files' icon, sliding into the edge as it shrinks and fades
/// (a 160 ms fade where it is under Reduce motion).
@MainActor
private enum FallingIcon {
    private static var open: [NSPanel] = []

    static func play(icon: NSImage, from point: NSPoint, calm: Bool) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return }
        let side: CGFloat = 72
        let x = min(point.x, screen.frame.maxX - 30) - side / 2 - 40
        let start = NSRect(x: x, y: point.y - side / 2, width: side, height: side)
        let panel = LandingPanel(contentRect: start)
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        let image = NSImageView(frame: NSRect(origin: .zero, size: start.size))
        image.image = icon
        image.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView = image
        panel.orderFrontRegardless()
        open.append(panel)
        let end = calm ? start : NSRect(x: screen.frame.maxX - 6, y: point.y - 8, width: 16, height: 16)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = calm ? 0.16 : 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.6)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = calm ? 0 : 0.15
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.close()
                open.removeAll { $0 === panel }
            }
        })
    }

    static func closeAll() {
        open.forEach { $0.orderOut(nil); $0.close() }
        open = []
    }
}

// MARK: - Edge shots

extension PortalPreview {
    /// The right-edge send for the harness (`--edge-shots <dir>`), at half size:
    /// `edge-<effect>.png` a file dragged 70 pt from the edge (p 0.7), and
    /// `edge-<effect>-drop.png` 0.2 s after the drop, the impact at the edge.
    @MainActor
    public static func writeEdgeShots(to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for effect in PortalEffect.allCases {
            for drop in [false, true] {
                let url = folder.appendingPathComponent("edge-\(effect.rawValue)\(drop ? "-drop" : "").png")
                try writeEdgeShot(effect, drop: drop, to: url)
                urls.append(url)
            }
        }
        return urls
    }

    @MainActor
    private static func writeEdgeShot(_ effect: PortalEffect, drop: Bool, to url: URL) throws {
        let size = CGSize(width: 1440, height: 900)
        let palette = PortalPalette(tint: .defaultTint(for: effect), at: Date(timeIntervalSince1970: 0))
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        let desk = CAGradientLayer()
        desk.frame = root.bounds
        desk.colors = [NSColor(srgbRed: 0.07, green: 0.07, blue: 0.1, alpha: 1),
                       NSColor(srgbRed: 0.043, green: 0.043, blue: 0.06, alpha: 1)].map(\.cgColor)
        root.addSublayer(desk)
        let window = CALayer()
        window.frame = CGRect(x: 520, y: 220, width: 640, height: 440)
        window.backgroundColor = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.15, alpha: 1).cgColor
        window.cornerRadius = 12
        root.addSublayer(window)

        let y = size.height * 0.52
        let p: CGFloat = 0.7
        let pointer = CGPoint(x: size.width - EdgePortal.reach * (1 - p), y: y)
        let stage = StageView(frame: NSRect(origin: .zero, size: size), effect: effect, palette: palette,
                              seam: CGPoint(x: size.width, y: y), landing: CGPoint(x: size.width - 70, y: y))
        if let layer = stage.layer {
            layer.frame = root.bounds
            root.addSublayer(layer)
        }
        stage.setIntensity(drop ? 1 : p * 0.8)
        stage.follow(card: pointer)
        if drop {
            stage.send(still: 0.2)
            stage.impact(still: 0.06)
        } else {
            let seamSize = SeamView.size(screenHeight: size.height)
            let seamView = SeamView(frame: NSRect(x: size.width - seamSize.width, y: 0, width: seamSize.width, height: seamSize.height),
                                    effect: effect, palette: palette, calm: false, centerY: y)
            seamView.setIntensity(p)
            if let seamLayer = seamView.layer {
                seamLayer.frame = seamView.frame
                root.addSublayer(seamLayer)
            }
        }
        // The dragged file's icon under the pointer, or half way through the edge after the drop.
        let icon = NSWorkspace.shared.icon(for: .pdf)
        let side: CGFloat = drop ? 28 : 72
        let iconLayer = CALayer()
        iconLayer.frame = drop ? CGRect(x: size.width - 24, y: y - side / 2, width: side, height: side)
                               : CGRect(x: pointer.x - side / 2, y: pointer.y - side / 2, width: side, height: side)
        var iconRect = NSRect(x: 0, y: 0, width: 144, height: 144)
        iconLayer.contents = icon.cgImage(forProposedRect: &iconRect, context: nil, hints: nil)
        iconLayer.opacity = drop ? 0.5 : 0.9
        root.addSublayer(iconLayer)

        let scale: CGFloat = 0.5
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.scaleBy(x: scale, y: scale)
        root.render(in: ctx)
        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}

// MARK: - Edge drop test

/// The right-edge drop end to end without a person, for the harness
/// (`--edge-drop-test`): the real `EdgePortal`, zone window and zone view,
/// fed a drag through `NSDraggingInfo` with a pasteboard holding a temp file,
/// the drop offered by a real `DropPortalServer` and queued in a real
/// `OutgoingQueue` as no phone is paired. `live` runs the real drag watcher
/// against a strip ending at `edgeX`, for a drag made by another process.
public enum EdgeDropProbe {
    public struct Report: Sendable {
        public var passed: Bool
        public var lines: [String]
    }

    @MainActor
    public static func simulate() -> Report {
        PortalLog.mirrorToStandardError = true
        var lines: [String] = []
        var ok = true
        func check(_ condition: Bool, _ what: String) {
            lines.append("\(condition ? "PASS" : "FAIL") \(what)")
            ok = ok && condition
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("edge-drop-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("hello.txt")
        try? Data("hello".utf8).write(to: file)
        let server = DropPortalServer(port: 0, destination: temp)
        let queue = OutgoingQueue(manifest: temp.appendingPathComponent("queue.json"))
        var offered: [DropPortalServer.Offer] = []

        guard let screen = NSScreen.screens.first else { return Report(passed: false, lines: ["FAIL no screen"]) }
        let edge = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width * 0.6, height: screen.frame.height)
        let portal = EdgePortal(presenter: LandingPresenter())
        portal.edges = { [edge] }
        portal.onDrop = { urls in
            offered = urls.compactMap { server.offer($0) }
            queue.add(offered.map(\.url))     // no page paired: the droplet queues
        }

        // 1. A drop on the zone.
        portal.dragBegan(types: [NSPasteboard.PasteboardType.fileURL.rawValue])
        check(portal.zoneCount == 1, "zone shown on drag begin")
        let zone = portal.testZone
        check(zone?.window.isVisible == true, "zone window ordered in")
        check(zone?.window.ignoresMouseEvents == false, "zone window takes mouse events")
        check(zone?.view.registeredDraggedTypes.contains(.fileURL) == true, "zone view registered for public.file-url")
        // Let go on the light, 100 pt from the edge: the old 8 pt zone missed exactly this.
        let at = NSPoint(x: edge.maxX - 100, y: edge.midY)
        portal.dragMoved(NSPoint(x: edge.maxX - 160, y: edge.midY))
        check(portal.lightOn, "light opens near the edge")
        portal.dragMoved(at)
        check(zone.map { NSMouseInRect(at, $0.window.frame, false) } == true, "zone covers the lit band (drop 100 pt from the edge)")
        if let zone {
            let board = NSPasteboard(name: NSPasteboard.Name("DropPortalEdgeTest-\(UUID().uuidString)"))
            board.clearContents()
            board.writeObjects([file as NSURL])
            let info = FakeDraggingInfo(board: board, window: zone.window, at: zone.window.convertPoint(fromScreen: at))
            let entered = zone.view.draggingEntered(info)
            check(entered == .copy, "draggingEntered returns .copy")
            check(zone.view.draggingUpdated(info) == .copy, "draggingUpdated returns .copy")
            // The poll sees the button up before the drop lands: the zone must wait.
            portal.dragEnded()
            check(portal.zoneCount == 1, "zone waits for the drop after button up")
            check(zone.view.prepareForDragOperation(info), "prepareForDragOperation true")
            check(zone.view.performDragOperation(info), "performDragOperation true")
            board.releaseGlobally()
        }
        check(offered.map(\.url.lastPathComponent) == ["hello.txt"], "server offered the dropped file")
        check(queue.count == 1, "queue holds it (no phone paired)")
        check(portal.zoneCount == 0, "zone hidden after the drop")
        spin(1.6)
        check(!portal.lightOn && visibleEdgePanels() == 0, "no edge light left on screen 1.6 s after the drop")

        // 2. A drag that ends away from the edge, after the light opened.
        portal.dragBegan(types: [NSPasteboard.PasteboardType.fileURL.rawValue])
        portal.dragMoved(NSPoint(x: edge.maxX - 40, y: edge.midY))
        check(portal.lightOn, "light opens again on the next drag")
        portal.dragMoved(NSPoint(x: edge.midX, y: edge.midY))
        portal.dragEnded()
        check(portal.zoneCount == 0, "zone hidden at once on a button up away from it")
        spin(1.0)
        check(visibleEdgePanels() == 0, "no edge light left 1 s after a drag that ended away")

        // 3. The watcher never reports the end: the watchdog hides it (the button is up here).
        portal.dragBegan(types: [NSPasteboard.PasteboardType.fileURL.rawValue])
        portal.dragMoved(NSPoint(x: edge.maxX - 30, y: edge.midY))
        spin(0.6)
        check(portal.zoneCount == 0, "watchdog hides the zone without a drag end")
        spin(1.0)
        check(visibleEdgePanels() == 0, "and its light")
        portal.tearDown()
        return Report(passed: ok, lines: lines)
    }

    /// The real watcher and zone on a strip ending at `edgeX`, for `seconds`.
    @MainActor
    public static func live(edgeX: CGFloat, seconds: Double) -> Int {
        PortalLog.mirrorToStandardError = true
        guard let screen = NSScreen.screens.first else { return 0 }
        let edge = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: edgeX - screen.frame.minX, height: screen.frame.height)
        let portal = EdgePortal(presenter: LandingPresenter())
        portal.edges = { [edge] }
        var dropped = 0
        portal.onDrop = { urls in
            dropped += urls.count
            PortalLog.write("live: onDrop \(urls.map(\.lastPathComponent))")
        }
        let watcher = EdgeDragWatcher()
        watcher.onBegin = { portal.dragBegan(types: $0) }
        watcher.onMove = { portal.dragMoved($0) }
        watcher.onEnd = { portal.dragEnded() }
        watcher.start()
        spin(seconds)
        PortalLog.write("live: edge panels still visible: \(visibleEdgePanels())")
        watcher.stop()
        portal.tearDown()
        return dropped
    }

    @MainActor
    private static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.02))) }
    }

    @MainActor
    private static func visibleEdgePanels() -> Int {
        NSApp?.windows.filter { $0 is LandingPanel && $0.isVisible }.count ?? 0
    }
}

extension EdgePortal {
    fileprivate var zoneCount: Int { zonesForTest.count }
    fileprivate var testZone: (window: NSWindow, view: EdgeZoneView)? {
        zonesForTest.first.map { ($0.window, $0.zone) }
    }
}

private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let board: NSPasteboard
    let window: NSWindow
    let at: NSPoint

    init(board: NSPasteboard, window: NSWindow, at: NSPoint) {
        self.board = board
        self.window = window
        self.at = at
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .move] }
    var draggingLocation: NSPoint { at }
    var draggedImageLocation: NSPoint { at }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { board }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

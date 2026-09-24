import Foundation
import Observation
import UIKit

/// Advances presentation only. It has no network, source-sync, or generation dependencies.
@MainActor @Observable
final class AmbientController {
    private(set) var isActive = false
    private(set) var view = BookwormsView.shelf
    private(set) var contentIndex = 0
    private(set) var layoutVariant = 0
    @ObservationIgnored private var started = Date.distantPast
    @ObservationIgnored private var nextContent = Date.distantPast
    @ObservationIgnored private var nextView = Date.distantPast
    @ObservationIgnored private var viewInterval: TimeInterval = 600
    @ObservationIgnored private var sessionInterval: TimeInterval = 0
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let idleTimer: (Bool) -> Void

    init(
        now: @escaping () -> Date = Date.init,
        idleTimer: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }
    ) {
        self.now = now
        self.idleTimer = idleTimer
    }

    @discardableResult
    func start(views: [BookwormsView], preferences: ViewPreferences, voiceOver: Bool) -> Bool {
        guard !voiceOver, let first = views.first else { return false }
        var preferences = preferences
        preferences.validate()
        started = now()
        viewInterval = Double(preferences.ambientMinutes * 60)
        sessionInterval = Double(preferences.sessionMinutes * 60)
        nextContent = started.addingTimeInterval(60)
        nextView = started.addingTimeInterval(viewInterval)
        view = first
        contentIndex = 0
        layoutVariant = 0
        isActive = true
        idleTimer(true)
        return true
    }

    func tick(views: [BookwormsView], voiceOver: Bool = false, sceneActive: Bool = true) {
        guard isActive else { return }
        let date = now()
        guard !voiceOver, sceneActive, !views.isEmpty,
            sessionInterval == 0 || date.timeIntervalSince(started) < sessionInterval
        else {
            stop()
            return
        }
        if !views.contains(view) {
            view = views[0]
            contentIndex = 0
        }
        if date >= nextView {
            let index = views.firstIndex(of: view) ?? 0
            view = views[(index + 1) % views.count]
            contentIndex = 0
            nextView = date.addingTimeInterval(viewInterval)
            nextContent = date.addingTimeInterval(60)
            layoutVariant = (layoutVariant + 1) % 4
        }
        if date >= nextContent {
            contentIndex += 1
            layoutVariant = (layoutVariant + 1) % 4
            nextContent = date.addingTimeInterval(60)
        }
    }

    func stop() {
        isActive = false
        idleTimer(false)
    }
}

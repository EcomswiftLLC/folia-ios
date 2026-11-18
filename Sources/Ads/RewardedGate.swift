import SwiftUI
import UIKit
import GoogleMobileAds

/// Pure rules for the rewarded export gate, so they can be unit tested.
struct RewardedPolicy: Equatable {
    /// One watched ad covers every export for this long, so saving and then sharing the same result asks only once.
    static let graceInterval: TimeInterval = 120

    /// How long after closing an ad early the next export request waits for the replacement ad that is loading.
    static let earlyCloseWindow: TimeInterval = 120
    /// The longest a request waits for that replacement ad. After this the export simply runs.
    static let reloadWait: TimeInterval = 6

    private(set) var lastReward: Date?
    private(set) var lastEarlyClose: Date?

    /// True when the person should be offered an ad before this export. Never when no ad is ready.
    func shouldOffer(adReady: Bool, now: Date = Date()) -> Bool {
        guard adReady else { return false }
        if let lastReward, now.timeIntervalSince(lastReward) < Self.graceInterval { return false }
        return true
    }

    /// True when an ad was just closed before the reward was earned and its replacement is still loading, so a
    /// retry should wait a moment for it instead of exporting for free.
    func shouldWaitForReload(adReady: Bool, reloading: Bool, now: Date = Date()) -> Bool {
        guard !adReady, reloading, let lastEarlyClose else { return false }
        if let lastReward, lastReward > lastEarlyClose { return false }
        return now.timeIntervalSince(lastEarlyClose) < Self.earlyCloseWindow
    }

    mutating func didEarnReward(now: Date = Date()) {
        lastReward = now
        lastEarlyClose = nil
    }

    mutating func didCloseEarly(now: Date = Date()) {
        lastEarlyClose = now
    }
}

/// Why an export did not go ahead after the ad was offered.
enum RewardedCancelReason: Equatable {
    /// The person chose "Not now".
    case declined
    /// The ad was closed before the reward was earned.
    case closedEarly

    var message: String {
        switch self {
        case .declined: return "Export cancelled. Watch the short ad to export."
        case .closedEarly: return "Watch the whole ad to export."
        }
    }
}

/// Folia is free. Saving, sharing or printing a finished document asks the person to watch one short rewarded ad.
/// When no ad is ready (offline, no fill, consent still pending) the export simply goes ahead for free.
@MainActor
final class RewardedGate: NSObject, FullScreenContentDelegate {
    static let shared = RewardedGate()

    private var ad: RewardedAd?
    private var loadedAt: Date?
    private var loading = false
    private var policy = RewardedPolicy()
    private let maxAge: TimeInterval = 55 * 60

    private var failedLoads = 0
    private let retryDelays: [UInt64] = [5, 15, 45]

    private var earned = false
    private var proceed: (() -> Void)?
    private var cancelled: ((RewardedCancelReason) -> Void)?
    /// A request that is waiting for the replacement ad after an ad was closed early.
    private var waitTask: Task<Void, Never>?

    private override init() { super.init() }

    private var hasUsableAd: Bool {
        guard ad != nil, let loadedAt else { return false }
        return Date().timeIntervalSince(loadedAt) < maxAge
    }

    /// Call when the app may request ads (after consent and SDK start), and again after each ad.
    func preloadIfPossible() {
        guard AdsManager.shared.adsReady, !loading, !hasUsableAd else { return }
        guard let unitID = AdsConfiguration.rewardedUnitID else { return }
        loading = true
        Task { [weak self] in
            do {
                let loaded = try await RewardedAd.load(with: unitID, request: Request())
                guard let self else { return }
                loaded.fullScreenContentDelegate = self
                self.ad = loaded
                self.loadedAt = Date()
                self.loading = false
                self.failedLoads = 0
            } catch {
                AdsLog.logger.info("Rewarded ad failed to load: \(error.localizedDescription, privacy: .public)")
                guard let self else { return }
                self.loading = false
                // One no-fill or network hiccup must not leave the session without an ad: try again a few times.
                if self.failedLoads < self.retryDelays.count {
                    let delay = self.retryDelays[self.failedLoads]
                    self.failedLoads += 1
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    self.preloadIfPossible()
                }
            }
        }
    }

    /// Runs `action` right away when no ad is needed, otherwise asks first. The action runs only after the ad was
    /// watched to the end, or when the ad could not be shown. "Not now", or closing the ad early, runs `onCancel` instead.
    /// When an ad was just closed early and its replacement is still loading, the request waits a few seconds for it
    /// (`onWaiting(true)` ... `onWaiting(false)`) rather than letting the export through for free. If no ad arrives
    /// in time, the export runs: it is never blocked for good.
    func requestExport(
        _ action: @escaping () -> Void,
        onCancel: ((RewardedCancelReason) -> Void)? = nil,
        onWaiting: ((Bool) -> Void)? = nil
    ) {
        request(action, onCancel: onCancel, onWaiting: onWaiting, mayWait: true)
    }

    private func request(
        _ action: @escaping () -> Void,
        onCancel: ((RewardedCancelReason) -> Void)?,
        onWaiting: ((Bool) -> Void)?,
        mayWait: Bool
    ) {
        if mayWait, AdsManager.shared.adsReady,
           policy.shouldWaitForReload(adReady: hasUsableAd, reloading: loading) {
            // A second tap while waiting is ignored: the first request is still pending.
            guard waitTask == nil else { return }
            onWaiting?(true)
            waitTask = Task { [self] in
                let deadline = Date().addingTimeInterval(RewardedPolicy.reloadWait)
                while !hasUsableAd, loading, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                waitTask = nil
                onWaiting?(false)
                request(action, onCancel: onCancel, onWaiting: onWaiting, mayWait: false)
            }
            return
        }
        guard AdsManager.shared.adsReady,
              policy.shouldOffer(adReady: hasUsableAd),
              let presenter = AdsPresenter.topViewController() else {
            action()
            preloadIfPossible()
            return
        }
        let alert = UIAlertController(
            title: "Watch a short ad to export",
            message: "Folia is free because of ads. Saving, sharing or printing asks you to watch one short ad.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not now", style: .cancel) { _ in
            onCancel?(.declined)
        })
        alert.addAction(UIAlertAction(title: "Watch ad", style: .default) { [weak self] _ in
            self?.show(then: action, onCancel: onCancel)
        })
        presenter.present(alert, animated: true)
    }

    private func show(then action: @escaping () -> Void, onCancel: ((RewardedCancelReason) -> Void)?) {
        guard let ad, let presenter = AdsPresenter.topViewController() else {
            action()
            return
        }
        self.ad = nil
        earned = false
        proceed = action
        cancelled = onCancel
        ad.present(from: presenter) { [weak self] in
            self?.earned = true
        }
    }

    // MARK: FullScreenContentDelegate

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        let action = proceed
        let cancel = cancelled
        proceed = nil
        cancelled = nil
        if earned {
            policy.didEarnReward()
            earned = false
            action?()
        } else {
            // Closed before the reward: the next tap must not slip through while the replacement ad loads.
            policy.didCloseEarly()
            cancel?(.closedEarly)
        }
        preloadIfPossible()
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        AdsLog.logger.info("Rewarded ad failed to present: \(error.localizedDescription, privacy: .public)")
        // The ad is what failed, not the person: let the export through.
        let action = proceed
        proceed = nil
        cancelled = nil
        earned = false
        action?()
        preloadIfPossible()
    }
}

import SwiftUI
import UIKit
import GoogleMobileAds

/// Pure rules for the rewarded export gate, so they can be unit tested.
struct RewardedPolicy: Equatable {
    /// One watched ad covers every export for this long, so saving and then sharing the same result asks only once.
    static let graceInterval: TimeInterval = 120

    private(set) var lastReward: Date?

    /// True when the person should be offered an ad before this export. Never when no ad is ready.
    func shouldOffer(adReady: Bool, now: Date = Date()) -> Bool {
        guard adReady else { return false }
        if let lastReward, now.timeIntervalSince(lastReward) < Self.graceInterval { return false }
        return true
    }

    mutating func didEarnReward(now: Date = Date()) {
        lastReward = now
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
    private var cancelled: (() -> Void)?

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
    func requestExport(_ action: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
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
            onCancel?()
        })
        alert.addAction(UIAlertAction(title: "Watch ad", style: .default) { [weak self] _ in
            self?.show(then: action, onCancel: onCancel)
        })
        presenter.present(alert, animated: true)
    }

    private func show(then action: @escaping () -> Void, onCancel: (() -> Void)?) {
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
            cancel?()
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

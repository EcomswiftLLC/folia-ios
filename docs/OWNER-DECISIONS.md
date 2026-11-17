# Owner decisions for Folia (read before changing monetisation)

**2026-11-17, from the owner in chat: Folia is FREE. No in-app purchases, no export packs, no Premium, no StoreKit.**
Every export (Share, Save to Files, Save to Photos, Print) is paid for with one opt-in AdMob rewarded ad ("Watch a short ad to export").
**If no ad is available, the export is simply free.** Implemented in `Sources/Ads/RewardedGate.swift` and used by `FoliaExportBar` in `Sources/Features/Common.swift`.

Same model as Aperta and CareerKit. Do not add `Sources/Purchases`, `ExportStore`, paywall sheets or restore-purchases rows.
Ads: banner on the Documents screen only. No interstitials.

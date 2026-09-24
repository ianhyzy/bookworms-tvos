# Privacy implementation

The app and Top Shelf extension each include a `PrivacyInfo.xcprivacy` resource. Both declare no tracking and no tracking domains.

## Required-reason APIs

| Target | API category | Reason | Use |
| --- | --- | --- | --- |
| App | User defaults | `CA92.1` | Store and read this app's settings, sync schedules, and saved designs. |
| App | File timestamps | `C617.1` | Read modification dates of files in the app's cache for font-catalog freshness and image eviction. |
| Top Shelf | None | None | Read a JSON snapshot in the App Group container and publish public cover URLs. |

The extension does not call `UserDefaults` or read file timestamps. Do not copy the app's declarations into it without corresponding API use. Update these manifests whenever a target starts using another required-reason API. Reason definitions come from [Apple's API category reference](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

## Data flows

| Destination | Data sent | Purpose |
| --- | --- | --- |
| Hardcover | PAT in the authorization header; fixed read queries, book IDs, and selected reader IDs | Fetch account, library, edition, followed-reader, activity, rating, and review data. |
| Configured CWA server | Local username/password through HTTPS Basic authentication; catalog and cover requests | Fetch owned books and protected covers. Hidden in Settings while `BookPresentation.offersCWA` is false. |
| AI providers | No requests while generation is disabled | Retained implementation only; saved keys and designs remain stored. |
| Google Fonts and font hosting | No requests while generated spines are disabled | Retained implementation for spine fonts only. |
| Artwork hosts | Cover and avatar URL requests | Display and analyze cover artwork. |
| Private CloudKit database | Source snapshots and saved design records, only when the user turns on iCloud storage (off by default) | Restore and merge the user's library and designs. |

Network recipients can observe connection metadata such as an IP address. The app has no advertising or analytics SDK. The local request ledger does not upload diagnostics. Cloud archives exclude credentials but include source identities and reading metadata. Turning off iCloud does not delete its archive.

## Collection disclosures

The manifests declare required-reason API use; they do not yet declare collected-data categories. This is not a claim that no data leaves the device. The developer receives no user data, so **Data Not Collected** is the expected App Store privacy answer for the current build; confirm it against Apple's definitions when answering. Keep the manifest, the [published privacy policy](https://ian.gay/bookworms-privacy-policy/), and App Store privacy answers consistent.

Apple distinguishes real-time request processing from retained collection. Generation is currently disabled. Reassess disclosure before enabling any automatic provider requests. See [Apple's privacy questionnaire guidance](https://developer.apple.com/app-store/app-privacy-details/).

## Local verification

Regenerate the project with `xcodegen generate`, then archive the Release scheme. Run:

```sh
python3 scripts/verify-release-archive.py PATH_TO_ARCHIVE
```

The script checks embedded manifests, signature validity, entitlements, versions, deployment target, assets, and extension packaging. It does not contact App Store Connect or validate provider retention policies.

Social snapshots contain reader profiles, activities, ratings, and reviews in the local cache only. They are not included in the private CloudKit archive. Ambient playback uses saved metadata and does not initiate source sync or AI generation.

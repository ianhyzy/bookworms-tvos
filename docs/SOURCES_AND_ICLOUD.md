# Sources, shelf choices, and iCloud

See [tvOS views](../VIEWS.md) for shelf options and [tvOS data sources](../DATASOURCES.md) for providers, merge rules, sync schedules, and limits.

CWA redirects and catalog paging stay within the configured HTTPS origin. The app uses HTTP Basic authentication with credentials from Keychain. See [storage and performance](STORAGE_AND_PERFORMANCE.md) for cache behavior.

## iCloud

**Settings → General → iCloud storage** enables private CloudKit storage. It is off by default until the production CloudKit schema is deployed. The archive contains source snapshots and saved AI design records. Credentials are excluded. Covers and downloadable fonts stay in local caches. The cloud archive uses a file asset so it can exceed the local preferences budget.

Cloud sync merges sources by identity and sync date, and designs by book ID and generation date. Conditional saves retry concurrent updates instead of overwriting another device's newer data. Unchanged archives are not uploaded again. A source sync queues a cloud update, and paid designs are saved to iCloud before relying on cloud storage beyond the local preferences budget.

Small design collections retain a durable local preferences copy. Larger collections can exceed that budget after a successful cloud save, with a local disk copy for fast access. If iCloud is unavailable, existing local data stays usable. Account changes stop cloud syncing until the user enables storage for the new account. Turning the setting off does not delete cloud records.

The current implementation transfers one archive asset when the archive changes. The entire asset is transferred when any archived data changes. CloudKit development and production environments are separate: deploy the schema before TestFlight or App Store distribution.

## Verification

Unit tests cover OPDS parsing and invalid feeds, credential-origin restrictions, stable source IDs, merging, shelf selection and ordering, per-source daily scheduling, cloud merges, and persistent design recovery. UI tests cover Shelf, Sources, and Storage settings. Follow the [device testing procedure](TESTING.md) to verify live services and production CloudKit.

## References

- [CWA OPDS implementation](https://github.com/crocodilestick/Calibre-Web-Automated/blob/master/cps/opds.py)
- [CWA feed fields](https://github.com/crocodilestick/Calibre-Web-Automated/blob/master/cps/templates/feed.xml)
- [CloudKit private database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase)

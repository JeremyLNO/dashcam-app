# App Store submission

App Store Connect record: **6811080566** (`Dashcam Pocket`).

## External steps that cannot live in the repository

### 1. Subscriptions — DONE (2026-09-11, via the API)

Group **Dashcam Pocket Premium** (`22377613`) with three auto-renewable subscriptions, all
at group level 1 so switching duration is a crossgrade rather than an upgrade. Each one
carries: 175 territories, a base price, five localizations (en/fr/es/de/pt) and a **3-day
free trial introductory offer in every territory** (175 offers each).

Two API details that cost time and are not in the docs:
- a brand-new subscription has **no `subscriptionAvailability`**, and setting a price before
  creating one fails with a misleading `ENTITY_ERROR.RELATIONSHIP.INVALID` pointing at the
  price point;
- `subscriptionIntroductoryOffers` requires a **`territory` relationship** — there is no
  "all territories" form, so it is one POST per territory per plan.

All three reached **`READY_TO_SUBMIT`** on 2026-09-12. Two things were missing, not one:

- the **App Store review screenshot** (`appStoreReviewScreenshot`), now `screenshots/08-paywall.png`
  on all three. It does *not* need a real device: `./tools/capture-paywall.sh` takes it in the
  Simulator through a UI test, because `xcodebuild test` applies the scheme's StoreKit
  configuration while `simctl launch` starts the app without it;
- **the prices of the other 174 territories.** App Store Connect's web UI derives them from a
  base country on its own; the API sets exactly the one you post. Until every available
  territory has a price the subscription stays `MISSING_METADATA`, and the state never says
  which field is at fault — easy to blame the screenshot you just uploaded. The equalized
  points come from `GET /v1/subscriptionPricePoints/{id}/equalizations`.

Prices confirmed by Jeremy on 2026-09-12: 4.99 / 11.99 / 34.99 USD, i.e. 5.99 / 12.99 /
39.99 EUR in the euro zone.

The product identifiers match `Config/Base.xcconfig`:

| Plan      | Product ID                          | Duration  |
|-----------|-------------------------------------|-----------|
| Monthly   | `dashcam.lno.company.monthly`       | 1 month   |
| Quarterly | `dashcam.lno.company.quarterly`     | 3 months  |
| Yearly    | `dashcam.lno.company.yearly`        | 1 year    |

Add an **introductory offer** of **3 days free** to each, in every territory. The app reads
eligibility from StoreKit (`Product.SubscriptionInfo.isEligibleForIntroOffer`) and never
simulates a trial locally.

Prices are set in App Store Connect only. Nothing in the app hardcodes an amount.

After the group exists, copy its numeric id into `SUBSCRIPTION_GROUP_ID`. It is only a
fallback — at runtime the app reads the authoritative id back off a loaded product.

### 2. CarPlay entitlement

**Requested on 2026-09-12**, awaiting Apple's answer.

CarPlay Driving Task is granted per app by request:
<https://developer.apple.com/contact/carplay/>. The form asks nothing beyond the category
for this branch — the description fields and screenshot uploads only appear for
*Navigation* — so the whole request is: pick **Driving Task**, accept the CarPlay
Entitlement Addendum, submit. The text to send if Apple asks for details is in
`docs/CARPLAY-ENTITLEMENT.md`.

Once granted, uncomment the key in `App/Dashcam.entitlements`:

```xml
<key>com.apple.developer.carplay-driving-task</key>
<true/>
```

The entitlement must be enabled on the App ID before the build will sign. Nothing else in
the app depends on it.

### 3. Privacy answers

`Resources/PrivacyInfo.xcprivacy` declares **no data collected** and no tracking, with
required-reason declarations for `UserDefaults`, disk space and file timestamps. The App
Store privacy questionnaire must match: *Data Not Collected*.

If a build ever ships with `ONESIGNAL_APP_ID` filled in, add a **Device ID → App
Functionality → not linked to the user → not used for tracking** entry to both the manifest
and the questionnaire.

### 4. App Review notes

> Dashcam Pocket turns the iPhone into a dashcam.
>
> **What it does.** Tapping Start records two simultaneous video streams: the road through
> the rear ultra-wide camera, and the cabin through the front camera. Both streams are cut
> into short segments (1, 3 or 5 minutes) so a crash or a power loss costs at most one
> segment.
>
> **Where the files go.** Everything stays in the app's private container on the device.
> No video, image or location ever reaches a server — ours or anyone's. There is no
> account and none is offered. Writing to Photos happens only when the user explicitly
> exports a specific recording.
>
> **CarPlay.** The CarPlay interface is a remote control with three actions: Start, Stop
> and Protect. It contains no navigation, no map and no route guidance; the driver keeps
> using Apple Maps, Waze or Google Maps. All configuration is done on the iPhone.
>
> **Location.** CoreLocation is used only to attach position and speed to a recording as
> metadata, and optionally to stamp them onto a file the user exports. The app provides no
> navigation of any kind. Recording works normally if location is denied.
>
> **Background.** The app does not claim to record in the background. iOS suspends camera
> capture when the app leaves the foreground, and the app stops the recording cleanly at
> that point. The "discreet screen" keeps the app in the foreground and only hides the
> camera previews.
>
> **Subscription.** One group, three durations, with a 3-day free trial configured as an
> introductory offer. During the free trial the user can record, review and delete;
> **exporting a file requires a paid subscription**, which is stated on the paywall before
> purchase.
>
> **To test:** the recording screen needs a physical device with two cameras; the Simulator
> reports "Camera capture is not available in the Simulator".

### 5. Screenshots

English by default. 6.9" (1290 × 2796) is accepted. Capture on an iPhone 16 Plus or newer
simulator for the library, settings and paywall; the recording screen needs a real device.

## Checklist before submitting

- [ ] Three subscriptions live in App Store Connect with a 3-day introductory offer
- [ ] `SUBSCRIPTION_GROUP_ID` matches the group's numeric id
- [ ] Privacy questionnaire says *Data Not Collected*
- [ ] Review notes pasted (above)
- [ ] CarPlay entitlement granted, or the key left commented out
- [ ] `ONESIGNAL_APP_ID` either empty, or the privacy answers updated
- [ ] Device pass over `docs/DEVICE-TESTING.md`

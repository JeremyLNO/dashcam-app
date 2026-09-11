# App Store submission

App Store Connect record: **6811080566** (`Dashcam Pocket`).

## External steps that cannot live in the repository

### 1. Subscriptions

Create one subscription group containing three auto-renewable subscriptions. The product
identifiers must match `Config/Base.xcconfig`:

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

CarPlay Driving Task is granted per app by request:
<https://developer.apple.com/contact/carplay/>. Ask for the **Driving Task** category and
explain that the app is a dashcam whose CarPlay surface is Start / Stop / Protect only.

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

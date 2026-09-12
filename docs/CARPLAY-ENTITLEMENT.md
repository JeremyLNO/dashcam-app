# CarPlay Driving Task — entitlement request

Apple grants `com.apple.developer.carplay-driving-task` per app, by hand, through
<https://developer.apple.com/contact/carplay/>. There is no API: the form sits behind an
Apple Developer sign-in and has to be submitted by someone holding the account.

**Demandée le 2026-09-12** — Apple a répondu « Thank you for your submission. We'll review
your request and contact you soon with a status update. » En attente de leur réponse.

⚠️ **Le volet Driving Task ne demande aucune description.** Les champs « Tell us about your
app » et « What specific CarPlay features do you plan to implement ? », ainsi que les trois
téléversements de captures, n'existent que pour la catégorie **Navigation** : ils sont dans
le DOM mais en `display:none` pour toutes les autres. La demande s'est donc résumée à
choisir la catégorie et à accepter le **CarPlay Entitlement Addendum** (un avenant à l'Apple
Developer Program License Agreement, qui engage le compte).

Le dossier ci-dessous n'a donc pas servi au formulaire, mais il reste ce qu'il faut dire si
Apple demande des précisions par mail.

## Identity

| Field | Value |
|---|---|
| App name | Dashcam Pocket |
| Bundle ID | `dashcam.lno.company` |
| App Store ID | 6811080566 (not released yet — TestFlight only) |
| Team ID | 2E6D4Q69QB |
| CarPlay app category | **Driving Task** |

## What to write

> Dashcam Pocket turns an iPhone into a dashcam. It records the road through the rear
> camera and the cabin through the front camera at the same time, entirely on device. It
> has no navigation, no map and no route guidance, and it never takes over the screen the
> driver uses to navigate.
>
> The CarPlay interface is a remote control for the recording running on the iPhone. It is
> a single `CPInformationTemplate` showing recording status, elapsed time and whether the
> current footage is protected, with at most three `CPTextButton`s: Start, Stop and
> Protect. Protect marks the footage around this moment so the retention sweep cannot
> overwrite it — the one thing a driver genuinely needs to do from the wheel, right after
> an incident, and the reason the app asks for this entitlement rather than leaving the
> feature on the phone.
>
> There is nothing else in the CarPlay interface: no list to browse, no video playback, no
> media, no map, no settings. Every control is a single tap from the root template.
> Reviewing, exporting and configuring recordings happen on the iPhone only.

## Once granted

1. Enable the entitlement on the App ID in the developer portal.
2. Uncomment the key in `App/Dashcam.entitlements`:
   ```xml
   <key>com.apple.developer.carplay-driving-task</key>
   <true/>
   ```
3. Rebuild. The CarPlay scene is already declared in `Info.plist`; without the entitlement
   iOS simply never creates it, which is why the app ships fine while the request is
   pending.

Code: `CarPlay/CarPlayManager.swift`, `CarPlay/CarPlaySceneDelegate.swift`.

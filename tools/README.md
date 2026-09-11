# tools/

## flatten-icon.swift

Turns Crazy Bee Labs icon artwork into an App Store icon.

```bash
swiftc -O tools/flatten-icon.swift -o /tmp/flatten-icon
/tmp/flatten-icon ~/Desktop/crazybee-icons/"Dashcam Pocket.png" \
    Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
```

The artwork is delivered with a transparent margin around a rounded square. Two things
have to be true before App Store Connect will take it: **no alpha channel** (otherwise
ITMS-90717 rejects the build) and 1024×1024.

Flattening naively is not enough. It leaves the transparent margin as a coloured border
around the artwork's own rounded corners, and iOS then applies its own mask on top — the
icon ends up visibly inset, with a rim. So the script crops to the artwork's opaque bounds
first, squares that crop around its centre, scales it to fill 1024×1024, and only then
flattens onto a background colour sampled from inside the artwork.

Reusable as-is for any other app in the same icon set.

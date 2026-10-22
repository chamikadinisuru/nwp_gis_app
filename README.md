# NWP GIS App (ග්‍රහණ) – Road Network Edition

Flutter GIS tracking app with **Nearby Roads** feature for North Western Province.

## New Feature: Nearby Roads

1. Track a path (or just get GPS location).
2. Tap the **orange route button** (Roads).
3. App finds roads within ~90 m of your track.
4. Select a road → it is highlighted on the map + full details shown.

### Road details shown
- Road Name (`R_NAME`)
- Road Number (`R_NUMBER`)
- Authority (PS / RDA)
- Type (TAR / GRV / CNC / CPT)
- Length & Width

## Assets
- `assets/geojson/Road_simplified.geojson` (~27 MB, 48 006 roads)
- `assets/geojson/boundary.geojson` (GND boundaries with MC/UC/PS)

## How to run (VS Code)

```bash
cd nwp_gis_app
flutter pub get
flutter run
```

For physical device on same Wi-Fi (local server style):

```bash
flutter run -d <device-id>
```

## Build APK

```bash
flutter build apk --release
```

APK will be larger because of the road GeoJSON (~35 MB+).

## Next steps (already prepared)
- Boundary / PS-UC-MC detection can be added on top of the same pattern.

import 'dart:io' if (dart.library.io) 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show SynchronousFuture, consolidateHttpClientResponseBytes, kIsWeb;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart' as proj4;
import 'package:geolocator/geolocator.dart';
import 'package:turf/turf.dart' as turf;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:xml/xml.dart';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'models/road_model.dart';
import 'services/road_service.dart';
import 'services/boundary_service.dart';
import 'services/gps_track_filter.dart';
import 'models/saved_marker_model.dart';
import 'services/saved_marker_service.dart';
import 'screens/saved_markers_sheet.dart';

// --- OFFLINE MAP TILE SUPPORT --------------------------------------------
// Tracking often happens where network signal drops in and out. This
// TileProvider fetches tiles from the network as usual, but silently saves
// every tile it downloads to local disk. If a tile can't be fetched (no
// signal), it serves the last cached copy for that spot instead of leaving
// a blank/grey square. If a tile has never been seen before AND there's no
// signal, it falls back to a transparent tile so the app never crashes.
class OfflineCacheTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    if (kIsWeb) {
      // dart:io (HttpClient/File/Directory) isn't available on Flutter Web,
      // so the disk-based offline cache below can't run there. Just load
      // tiles normally in a web preview — the offline cache still works
      // fully on the real Android/iOS/desktop app.
      return NetworkImage(url);
    }
    return _CachedTileImage(url);
  }
}

class _CachedTileImage extends ImageProvider<_CachedTileImage> {
  final String url;
  const _CachedTileImage(this.url);

  @override
  Future<_CachedTileImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_CachedTileImage>(this);
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedTileImage && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  ImageStreamCompleter loadImage(
    _CachedTileImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1.0);
  }

  Future<File?> _cacheFile() async {
    try {
      final dir = await getTemporaryDirectory();
      final tileDir = Directory('${dir.path}/offline_map_tiles');
      if (!await tileDir.exists()) {
        await tileDir.create(recursive: true);
      }
      return File('${tileDir.path}/${url.hashCode}.tile');
    } catch (_) {
      return null;
    }
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final cacheFile = await _cacheFile();
    Uint8List? bytes;

    // Try the network first, so the map stays fresh while online.
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 6);
      final request = await client.getUrl(Uri.parse(url));
      request.headers.add('User-Agent', 'com.ravanagis.pro (offline-cache)');
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode == 200) {
        bytes = await consolidateHttpClientResponseBytes(response);
        if (cacheFile != null) {
          // Save for next time we're offline; ignore failures.
          final savedBytes = bytes;
          unawaited(cacheFile.writeAsBytes(savedBytes, flush: false));
        }
      }
      client.close(force: true);
    } catch (_) {
      // No signal or request failed — fall through to the cache below.
    }

    // No fresh network copy — use whatever we already have saved locally.
    if (bytes == null && cacheFile != null) {
      try {
        if (await cacheFile.exists()) {
          bytes = await cacheFile.readAsBytes();
        }
      } catch (_) {
        // Ignore cache read errors.
      }
    }

    // Nothing available at all — show a blank tile instead of crashing.
    bytes ??= _transparentTileBytes;

    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }
}

// A minimal 1x1 transparent PNG used only when a tile is unavailable both
// online and in the offline cache.
final Uint8List _transparentTileBytes = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);
// ---------------------------------------------------------------------------

void main() => runApp(const GISMappingApp());

class GISMappingApp extends StatelessWidget {
  const GISMappingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ග්‍රහණ',
      theme: ThemeData(
        primarySwatch: Colors.teal,
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const MainMapScreen(),
    );
  }
}

class GISMarkerData {
  final LatLng position;
  String name;
  String description;
  // Which imported KML document this marker came from ('' = not from KML,
  // e.g. manually placed or part of a saved track) and its detected layer
  // category (e.g. 'Road', 'Tank', 'Paddy'...). Used by the KML Layers
  // Manager to show/hide markers per-file without touching manual pins.
  final String docId;
  final String category;
  // Raw KML colour (AABBGGRR hex text) from the Placemark's resolved
  // <IconStyle><color>, if the KML defined one — lets an imported pin
  // match Google Earth's colour instead of always being plain red. Stored
  // as the original hex text (not a Color) so it round-trips through
  // JSON without depending on Flutter's Color-to-int representation.
  final String? iconColorHex;
  // Raw attribute table from the Placemark's <ExtendedData> (or <SchemaData>
  // SimpleData), e.g. {R_NAME: 'MAIN ROAD', AUTHORITY: 'RDA', ...}. Many
  // real-world KML/KMZ exports (like this app's own admin-boundary/road/
  // paddy exports) put all their useful info here and leave <name> empty,
  // so this is what makes the imported feature's data sheet meaningful.
  final Map<String, String> extendedData;
  // User-chosen marker type (see kMarkerTypeColors/kMarkerTypeLabels below)
  // - picked when the marker is added (manually, or via the real-time
  // "add pin at GPS location" button) so pins can be told apart on the map
  // by colour. Mutable (not final) so editing a marker can change its type.
  String markerType;

  GISMarkerData({
    required this.position,
    required this.name,
    required this.description,
    this.docId = '',
    this.category = 'Marker',
    this.iconColorHex,
    this.extendedData = const {},
    this.markerType = 'general',
  });

  Color? get iconColor =>
      iconColorHex != null ? kmlColorToFlutterColor(iconColorHex!) : null;

  Map<String, dynamic> toJson() => {
    'lat': position.latitude,
    'lng': position.longitude,
    'name': name,
    'desc': description,
    'docId': docId,
    'category': category,
    'iconColorHex': iconColorHex,
    'markerType': markerType,
  };

  factory GISMarkerData.fromJson(Map<String, dynamic> json) => GISMarkerData(
    position: LatLng(json['lat'], json['lng']),
    name: json['name'] ?? '',
    description: json['desc'] ?? '',
    docId: json['docId']?.toString() ?? '',
    category: json['category']?.toString() ?? 'Marker',
    iconColorHex: json['iconColorHex']?.toString(),
    markerType: json['markerType']?.toString() ?? 'general',
  );
}

// The 6 user-selectable marker types, each with its own colour, so pins
// added by hand (or via the real-time "add pin at GPS location" button)
// can be told apart on the map at a glance.
const Map<String, Color> kMarkerTypeColors = {
  'general': Color(0xFF2196F3), // blue
  'important': Color(0xFFE53935), // red
  'issue': Color(0xFFFB8C00), // orange
  'water': Color(0xFF00ACC1), // cyan
  'agriculture': Color(0xFF43A047), // green
  'infrastructure': Color(0xFF8E24AA), // purple
};

const Map<String, String> kMarkerTypeLabels = {
  'general': 'පොදු (General)',
  'important': 'වැදගත් (Important)',
  'issue': 'ගැටළුව (Issue)',
  'water': 'ජලය (Water)',
  'agriculture': 'කෘෂිකර්ම (Agriculture)',
  'infrastructure': 'යටිතල පහසුකම් (Infrastructure)',
};

// Manually-added and real-time (GPS pin) markers together are capped at
// this many so the map/track data never grows unbounded on a long field
// session. KML-imported markers are not counted against this limit.
const int kMaxUserMarkers = 2000;

// Holds ONE Placemark's geometry from an imported KML file as its own
// independent shape. Keeping each Placemark separate (instead of merging
// every point into one giant list) is what prevents tank/land polygons
// from getting connected to each other with stray criss-cross lines.
class ImportedShape {
  // Stable identity for this shape, independent of its position in
  // _importedShapes - used so edits/deletes/persistence can always find
  // the exact same shape again even after its geometry changes.
  final String id;
  // Mutable (not final) so the Edit feature can move/add/remove vertices
  // and rewrite the attribute table in place, then persist the result.
  List<LatLng> points;
  final String type; // 'POLYGON' or 'LINE'
  String name;
  String description;
  // Which imported KML document this shape belongs to, and its detected
  // layer category (Road / Landuse / Paddy / Home Garden / Tank / ...).
  final String docId;
  String category;
  // The Placemark's own resolved KML style (from an inline <Style> or the
  // <Style>/<StyleMap> its <styleUrl> points to). When present, these are
  // used to render the shape exactly as Google Earth Pro would - including
  // an explicitly transparent fill (e.g. boundary outlines) - instead of
  // the generic category colour palette, which is only a fallback for
  // shapes/files that don't define their own style.
  final Color? styleLineColor;
  final double? styleLineWidth;
  final Color? styleFillColor;
  // Raw attribute table from <ExtendedData>/<SchemaData>, e.g. for a road:
  // {R_NAME: 'MAIN ROAD', AUTHORITY: 'RDA', TYPE: 'TAR', LENGTH: '865.48'}.
  // Mutable so the Attribute Table editor can add/edit/remove fields.
  Map<String, String> extendedData;

  ImportedShape({
    String? id,
    required this.points,
    required this.type,
    required this.name,
    this.description = '',
    this.docId = '',
    this.category = 'Other',
    this.styleLineColor,
    this.styleLineWidth,
    this.styleFillColor,
    Map<String, String>? extendedData,
  }) : id =
           id ??
           '${DateTime.now().microsecondsSinceEpoch}_${identityHashCode(points)}',
       extendedData = extendedData ?? <String, String>{};

  // --- Persistence (added for the Edit / Save feature) -------------------
  // Colours are stored as their raw ARGB int so a shape's own KML style
  // (or the style entered when adding a shape by hand) survives a save.
  Map<String, dynamic> toJson() => {
    'id': id,
    'points': points
        .map((p) => {'lat': p.latitude, 'lng': p.longitude})
        .toList(),
    'type': type,
    'name': name,
    'description': description,
    'docId': docId,
    'category': category,
    'styleLineColor': styleLineColor?.value,
    'styleLineWidth': styleLineWidth,
    'styleFillColor': styleFillColor?.value,
    'extendedData': extendedData,
  };

  factory ImportedShape.fromJson(Map<String, dynamic> json) => ImportedShape(
    id: json['id']?.toString(),
    points: (json['points'] as List)
        .map(
          (p) => LatLng(
            (p['lat'] as num).toDouble(),
            (p['lng'] as num).toDouble(),
          ),
        )
        .toList(),
    type: json['type']?.toString() ?? 'LINE',
    name: json['name']?.toString() ?? '',
    description: json['description']?.toString() ?? '',
    docId: json['docId']?.toString() ?? '',
    category: json['category']?.toString() ?? 'Other',
    styleLineColor: json['styleLineColor'] != null
        ? Color(json['styleLineColor'] as int)
        : null,
    styleLineWidth: (json['styleLineWidth'] as num?)?.toDouble(),
    styleFillColor: json['styleFillColor'] != null
        ? Color(json['styleFillColor'] as int)
        : null,
    extendedData: Map<String, String>.from(json['extendedData'] ?? {}),
  );
}

/// Represents ONE imported .kml file as its own layer. Multiple KML files
/// can be imported one after another and each stays listed separately here
/// so the user can view/hide/delete them individually, and each file can
/// have several sub-layers inside it (Road, Paddy, Home Garden, Tank,
/// Landuse, Boundary, ...) detected from KML folder names / styles, which
/// can also be filtered on/off individually.
class ImportedKmlDoc {
  final String id;
  final String fileName;
  final DateTime importedAt;
  bool visible;
  final Set<String> hiddenCategories;

  ImportedKmlDoc({
    required this.id,
    required this.fileName,
    required this.importedAt,
    this.visible = true,
    Set<String>? hiddenCategories,
  }) : hiddenCategories = hiddenCategories ?? <String>{};

  // --- Persistence (added for the Edit / Save feature) -------------------
  Map<String, dynamic> toJson() => {
    'id': id,
    'fileName': fileName,
    'importedAt': importedAt.toIso8601String(),
    'visible': visible,
    'hiddenCategories': hiddenCategories.toList(),
  };

  factory ImportedKmlDoc.fromJson(Map<String, dynamic> json) => ImportedKmlDoc(
    id: json['id']?.toString() ?? '',
    fileName: json['fileName']?.toString() ?? '',
    importedAt:
        DateTime.tryParse(json['importedAt']?.toString() ?? '') ??
        DateTime.now(),
    visible: json['visible'] as bool? ?? true,
    hiddenCategories: Set<String>.from(json['hiddenCategories'] ?? []),
  );
}

// Layer-category detection + colour palette for imported KML content.
// Matches on the Placemark's containing <Folder> name, its own <name>, and
// its <styleUrl>, against common English + Sinhala/Romanized keywords.
const Map<String, Color> kKmlCategoryColors = {
  'Road': Color(0xFFFFC107), // amber
  'Paddy': Color(0xFF8BC34A), // light green
  'Home Garden': Color(0xFF4CAF50), // green
  'Tank': Color(0xFF2196F3), // blue
  'Landuse': Color(0xFF8D6E63), // brown
  'Boundary': Color(0xFF00BCD4), // cyan
  'Building': Color(0xFF9E9E9E), // grey
  'Other': Color(0xFFFF7043), // deep orange (fallback, matches old colour)
};

String detectKmlCategory({
  required String folderName,
  required String placemarkName,
  required String styleUrl,
}) {
  final text = ('$folderName $placemarkName $styleUrl').toLowerCase();
  bool has(List<String> words) => words.any((w) => text.contains(w));

  if (has(['road', 'mawatha', 'mawatta', 'para ', ' para', 'මාර්ග', 'පාර'])) {
    return 'Road';
  }
  if (has(['paddy', 'kumbura', 'කුඹුර', 'වී '])) return 'Paddy';
  if (has(['home garden', 'homegarden', 'housing', 'ගෙවත්ත', 'නිවාස'])) {
    return 'Home Garden';
  }
  if (has(['garden'])) return 'Home Garden';
  if (has(['tank', 'wewa', 'wetiya', 'reservoir', 'වැව'])) return 'Tank';
  if (has(['landuse', 'land use', 'භූමි'])) return 'Landuse';
  if (has(['boundary', 'seema', 'සීමා'])) return 'Boundary';
  if (has(['building', 'ගොඩනැගිල්ල'])) return 'Building';
  if (folderName.trim().isNotEmpty) return folderName.trim();
  return 'Other';
}

// KML colours are 8-hex-digit AABBGGRR strings (alpha, blue, green, red -
// note the reversed channel order vs the usual #RRGGBB). Converts one to a
// Flutter Color, preserving the authored alpha exactly - so a fill meant
// to be fully transparent (alpha 00, common for boundary outlines) or
// fully opaque (alpha ff) renders the same way it does in Google Earth.
Color? kmlColorToFlutterColor(String hex) {
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length != 8) return null;
  try {
    final aa = int.parse(h.substring(0, 2), radix: 16);
    final bb = int.parse(h.substring(2, 4), radix: 16);
    final gg = int.parse(h.substring(4, 6), radix: 16);
    final rr = int.parse(h.substring(6, 8), radix: 16);
    return Color.fromARGB(aa, rr, gg, bb);
  } catch (_) {
    return null;
  }
}

// Nearest-enclosing-scope search for a <Style>/<StyleMap> with the given
// id, starting from [from]'s parent and walking upward through Folder/
// Document ancestors, checking each ancestor's direct children first. This
// mirrors how a KML file that reuses the same id in different folders
// (common when several layers are exported into one file) still resolves
// each styleUrl to the definition actually meant for it, rather than
// whichever same-id block happens to appear last in the file.
XmlElement? _findKmlStyleById(XmlNode from, String id) {
  XmlNode? scope = from.parent;
  while (scope != null) {
    if (scope is XmlElement) {
      for (final child in scope.childElements) {
        if ((child.name.local == 'Style' || child.name.local == 'StyleMap') &&
            child.getAttribute('id') == id) {
          return child;
        }
      }
    }
    scope = scope.parent;
  }
  return null;
}

class KmlResolvedStyle {
  final Color? lineColor;
  final double? lineWidth;
  // The exact fill colour (with its authored alpha) if the KML specified
  // one, or Colors.transparent if <fill> was explicitly 0. Null means "the
  // KML had no opinion" - the caller should fall back to its own default.
  final Color? fillColor;
  final String? iconColorHex;

  KmlResolvedStyle({
    this.lineColor,
    this.lineWidth,
    this.fillColor,
    this.iconColorHex,
  });
}

// Resolves the effective visual style for one Placemark exactly the way
// Google Earth would: an inline <Style>, or the <Style>/<StyleMap> its
// <styleUrl> points to (following a StyleMap's "normal" Pair one level
// further if needed). Used so imported features keep the same colours,
// line widths, and fill transparency they had in the source KML/KMZ
// instead of an app-guessed colour.
KmlResolvedStyle resolveKmlStyle(XmlElement placemark) {
  XmlElement? styleEl = placemark.findElements('Style').isNotEmpty
      ? placemark.findElements('Style').first
      : null;

  if (styleEl == null) {
    final urlEls = placemark.findElements('styleUrl');
    if (urlEls.isNotEmpty) {
      var ref = urlEls.first.innerText.trim();
      if (ref.startsWith('#')) ref = ref.substring(1);
      XmlElement? found = _findKmlStyleById(placemark, ref);

      int guard = 0;
      while (found != null && found.name.local == 'StyleMap' && guard < 6) {
        guard++;
        XmlElement? normalPair;
        for (final pair in found.findElements('Pair')) {
          final keyEls = pair.findElements('key');
          if (keyEls.isNotEmpty && keyEls.first.innerText.trim() == 'normal') {
            normalPair = pair;
            break;
          }
        }
        if (normalPair == null) {
          found = null;
          break;
        }
        final innerUrlEls = normalPair.findElements('styleUrl');
        if (innerUrlEls.isEmpty) {
          found = null;
          break;
        }
        var innerRef = innerUrlEls.first.innerText.trim();
        if (innerRef.startsWith('#')) innerRef = innerRef.substring(1);
        found = _findKmlStyleById(found, innerRef);
      }
      styleEl = found;
    }
  }

  if (styleEl == null || styleEl.name.local != 'Style') {
    return KmlResolvedStyle();
  }

  Color? lineColor;
  double? lineWidth;
  final lineStyleEls = styleEl.findElements('LineStyle');
  if (lineStyleEls.isNotEmpty) {
    final ls = lineStyleEls.first;
    final colorEls = ls.findElements('color');
    if (colorEls.isNotEmpty) {
      lineColor = kmlColorToFlutterColor(colorEls.first.innerText);
    }
    final widthEls = ls.findElements('width');
    if (widthEls.isNotEmpty) {
      lineWidth = double.tryParse(widthEls.first.innerText.trim());
    }
  }

  Color? fillColor;
  final polyStyleEls = styleEl.findElements('PolyStyle');
  if (polyStyleEls.isNotEmpty) {
    final ps = polyStyleEls.first;
    bool fillOn = true;
    final fillEls = ps.findElements('fill');
    if (fillEls.isNotEmpty) fillOn = fillEls.first.innerText.trim() != '0';
    if (!fillOn) {
      fillColor = Colors.transparent;
    } else {
      final colorEls = ps.findElements('color');
      if (colorEls.isNotEmpty) {
        fillColor = kmlColorToFlutterColor(colorEls.first.innerText);
      }
    }
  }

  String? iconColorHex;
  final iconStyleEls = styleEl.findElements('IconStyle');
  if (iconStyleEls.isNotEmpty) {
    final colorEls = iconStyleEls.first.findElements('color');
    if (colorEls.isNotEmpty) {
      iconColorHex = colorEls.first.innerText.trim();
    }
  }

  return KmlResolvedStyle(
    lineColor: lineColor,
    lineWidth: lineWidth,
    fillColor: fillColor,
    iconColorHex: iconColorHex,
  );
}

class SavedTrack {
  final String id;
  final String title;
  final DateTime dateTime;
  final List<LatLng> points;
  final List<GISMarkerData> markers;
  final double distanceKm;
  final double rawAreaSqm;
  final String trackMode; // 'PATH' or 'LAND'
  // Officer who recorded this track (added feature). Defaults to '' for
  // tracks saved before this field existed, so old saved-tracks JSON still
  // loads without error.
  final String officerName;

  SavedTrack({
    required this.id,
    required this.title,
    required this.dateTime,
    required this.points,
    required this.markers,
    required this.distanceKm,
    required this.rawAreaSqm,
    required this.trackMode,
    this.officerName = '',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'dateTime': dateTime.toIso8601String(),
    'points': points
        .map((p) => {'lat': p.latitude, 'lng': p.longitude})
        .toList(),
    'markers': markers.map((m) => m.toJson()).toList(),
    'distanceKm': distanceKm,
    'rawAreaSqm': rawAreaSqm,
    'trackMode': trackMode,
    'officerName': officerName,
  };

  factory SavedTrack.fromJson(Map<String, dynamic> json) => SavedTrack(
    id: json['id'],
    title: json['title'],
    dateTime: DateTime.parse(json['dateTime']),
    points: (json['points'] as List)
        .map((p) => LatLng(p['lat'], p['lng']))
        .toList(),
    markers: (json['markers'] as List)
        .map((m) => GISMarkerData.fromJson(m))
        .toList(),
    distanceKm: (json['distanceKm'] as num).toDouble(),
    rawAreaSqm: (json['rawAreaSqm'] as num? ?? 0.0).toDouble(),
    trackMode: json['trackMode'] ?? 'PATH',
    officerName: json['officerName']?.toString() ?? '',
  );
}

class MainMapScreen extends StatefulWidget {
  const MainMapScreen({super.key});

  @override
  State<MainMapScreen> createState() => _MainMapScreenState();
}

class _MainMapScreenState extends State<MainMapScreen> {
  final MapController _mapController = MapController();
  final List<LatLng> _drawnPoints = [];
  final List<GISMarkerData> _markerDataList = [];
  final List<Marker> _markers = [];
  final List<ImportedShape> _importedShapes = [];
  final List<ImportedKmlDoc> _importedKmlDocs = [];

  // --- Saved Markers tab (added feature) ---
  // Own list + own storage + own map layer, independent of _markerDataList
  // (track / KML markers), so saving or loading tracks never affects them.
  final List<SavedMarker> _savedMarkers = [];
  bool _showSavedMarkers = true;
  bool _pickingSavedMarker = false;

  // Real-time GPS filter (Kalman smoothing + stale/outlier/accuracy gating).
  // Reset whenever tracking starts or resumes.
  final GpsTrackFilter _gpsFilter = GpsTrackFilter(
    maxAccuracyMeters: _kMinGpsAccuracyMeters,
  );

  // Mutable (was hardcoded to WGS84) so the Settings drawer's new
  // 'Coordinate System' dropdown can switch it; persisted like the
  // language preference so the choice survives an app restart. Every
  // existing coordinate display already branches on this value (see
  // _getFormattedCoordinates), so no other code needed to change.
  String _selectedEPSG = '4326';
  String _currentTool = 'PAN';
  String _selectedTileLayer = 'SATELLITE'; // Satellite (Esri) default
  String _areaUnit = 'ACRES'; // SQM, ACRES, PERCH, LAAS
  String _distanceUnit = 'KM'; // KM, M
  String _trackingType = 'PATH'; // PATH (Line) or LAND (Polygon)
  String _appLanguage = 'si'; // si (Sinhala), en (English), ta (Tamil)

  LatLng? _currentLocation;
  double _currentAccuracy = 0.0;
  int _estimatedSatellites = 0;
  double _currentSpeedKmh = 0.0; // live GPS speed, shown while tracking
  double _currentAltitude = 0.0; // live GPS altitude (m), shown while tracking

  // --- Hidden Developer Options ------------------------------------------
  // Not shown anywhere by default. Double-tapping the Settings (gear) icon
  // toggles _devOptionsUnlocked, which just reveals a section at the
  // bottom of the existing Settings drawer - nothing else in the app
  // changes because of this. Inside that section, the actual tracking
  // refresh-rate override has its OWN separate on/off switch
  // (_customTrackingRefreshEnabled), so even once unlocked, GPS tracking
  // keeps using its normal built-in refresh distance (2m) until that
  // switch is explicitly turned on.
  bool _devOptionsUnlocked = false;
  bool _customTrackingRefreshEnabled = false;
  double _customTrackingRefreshMeters = 5.0;
  // Independent second override: only records a new track point once at
  // least this many seconds have passed since the last recorded point,
  // regardless of distance moved. Off by default - normal (distance-only)
  // behaviour is untouched unless this switch is explicitly turned on.
  bool _customTimeRefreshEnabled = false;
  double _customTimeRefreshSeconds = 3.0;
  DateTime? _lastTrackPointTime;

  bool _isTracking = false;
  bool _isPaused = false;
  StreamSubscription<Position>? _positionStreamSubscription;
  DateTime? _trackingStartTime;
  Duration _trackDuration = Duration.zero;
  Duration _accumulatedDuration = Duration.zero;
  Timer? _durationTimer;
  double _totalDistance = 0.0;

  // --- Search & road-route navigation state ---
  List<LatLng> _routePoints = [];
  LatLng? _routeDestination;
  double? _routeDistanceKm;
  double? _routeDurationMin;
  bool _isRouting = false;

  List<SavedTrack> _savedTracks = [];

  // --- Road Network feature ---
  bool _showNearbyRoadsMode = false;
  List<RoadModel> _nearbyRoads = [];
  RoadModel? _selectedRoad;
  List<LatLng> _selectedRoadPoints = [];
  List<List<LatLng>> _allNearbyRoadPolylines = []; // all nearby roads on map
  bool _showAllNearbyOnMap = false;
  bool _isLoadingRoads = false;
  String? _selectedLocalGov; // e.g. "Giribawa PS"
  List<String> _localGovList = [];
  List<List<LatLng>> _selectedBoundaryPolygons = []; // PS boundary rings on map
  bool _showBoundaryOnMap = false;

  // --- Imported-shape Edit / Add-new-feature (added feature) --------------
  // Docs/shapes created or edited by this feature live in the SAME
  // _importedShapes / _importedKmlDocs lists as KML imports (a hand-drawn
  // shape just gets its own docId, 'user_added_shapes'), so the existing
  // KML Layers Manager, map rendering and tap-to-view-details already work
  // for them without any change to that code.
  static const String _kUserAddedDocId = 'user_added_shapes';
  static const String _kImportedShapesPrefKey = 'Grahana_imported_shapes_v1';
  static const String _kImportedDocsPrefKey = 'Grahana_imported_docs_v1';
  static const String _kImportedMarkersPrefKey = 'Grahana_imported_markers_v1';

  // 'NONE'      - not editing.
  // 'EDIT_MOVE' - editing an existing shape's geometry; tap a vertex then
  //               tap the map to move it there.
  // 'EDIT_ADD'  - editing an existing shape's geometry; tap the map to
  //               append a new vertex.
  // 'DRAW_NEW'  - drawing a brand-new shape from scratch.
  String _shapeEditMode = 'NONE';
  ImportedShape? _editingShape; // set only when editing an existing shape
  List<LatLng> _editBufferPoints = []; // working copy of the geometry
  int? _selectedVertexIndex;
  String _newShapeType = 'POLYGON'; // chosen type when drawing a new shape

  final wgs84 = proj4.Projection.WGS84;
  late proj4.Projection sld99;
  late proj4.Projection kandawala;

  @override
  void initState() {
    super.initState();
    // Official EPSG Geodetic Parameter Dataset definitions, not
    // simplified/local approximations - so a coordinate shown in SLD99 or
    // Kandawala here lines up with real-world survey benchmarks, other GIS
    // software, and licensed survey equipment using the same standards.
    //   EPSG:5234 = Kandawala / Sri Lanka Grid
    //   EPSG:5235 = SLD99 / Sri Lanka Grid 1999
    // Verified against PROJ's own EPSG:5234/5235 pipelines at 8 random
    // points across Sri Lanka: 0.000000 m difference. (Note: the SLD99
    // rotation terms below are the negation of the values epsg.io's raw
    // proj4 string lists - EPSG's official transformation applies them in
    // "coordinate_frame" convention, while the classic +towgs84 keyword
    // used here follows "position_vector" convention, which has the
    // opposite rotation sign; without this flip the easting comes out
    // ~200m off.)
    kandawala = proj4.Projection.add(
      'EPSG:5234',
      '+proj=tmerc +lat_0=7.00048027777778 +lon_0=80.7717111111111 +k=0.9999238418 +x_0=200000 +y_0=200000 +ellps=evrst30 +towgs84=-97,787,86,0,0,0,0 +units=m +no_defs',
    );
    sld99 = proj4.Projection.add(
      'EPSG:5235',
      '+proj=tmerc +lat_0=7.00047152777778 +lon_0=80.7717130833333 +k=0.9999238418 +x_0=500000 +y_0=500000 +ellps=evrst30 +towgs84=-0.293,766.95,87.713,0.195704,1.695068,3.473016,-0.039338 +units=m +no_defs',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _determinePosition(moveCamera: true);
    });
    _loadSavedTracksFromStorage();
    _loadLanguagePref();
    _loadDevOptionsPref();
    _loadImportedLayersFromStorage();
    _loadSavedMarkers();
    _loadCoordSystemPref();
  }

  // --- HIDDEN DEVELOPER OPTIONS --------------------------------------------
  Future<void> _loadDevOptionsPref() async {
    final prefs = await SharedPreferences.getInstance();
    final unlocked = prefs.getBool('Grahana_dev_options_unlocked') ?? false;
    final refreshEnabled =
        prefs.getBool('Grahana_dev_custom_refresh_enabled') ?? false;
    final refreshMeters =
        prefs.getDouble('Grahana_dev_custom_refresh_meters') ?? 5.0;
    final timeRefreshEnabled =
        prefs.getBool('Grahana_dev_custom_time_refresh_enabled') ?? false;
    final timeRefreshSeconds =
        prefs.getDouble('Grahana_dev_custom_time_refresh_seconds') ?? 3.0;
    if (mounted) {
      setState(() {
        _devOptionsUnlocked = unlocked;
        _customTrackingRefreshEnabled = refreshEnabled;
        _customTrackingRefreshMeters = refreshMeters;
        _customTimeRefreshEnabled = timeRefreshEnabled;
        _customTimeRefreshSeconds = timeRefreshSeconds;
      });
    }
  }

  Future<void> _saveDevOptionsPref() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('Grahana_dev_options_unlocked', _devOptionsUnlocked);
    await prefs.setBool(
      'Grahana_dev_custom_refresh_enabled',
      _customTrackingRefreshEnabled,
    );
    await prefs.setDouble(
      'Grahana_dev_custom_refresh_meters',
      _customTrackingRefreshMeters,
    );
    await prefs.setBool(
      'Grahana_dev_custom_time_refresh_enabled',
      _customTimeRefreshEnabled,
    );
    await prefs.setDouble(
      'Grahana_dev_custom_time_refresh_seconds',
      _customTimeRefreshSeconds,
    );
  }

  // Settings (gear) icon's normal single-tap behaviour (open the Settings
  // drawer) is untouched - it's wired to onPressed as before. Long-pressing
  // the same icon (onLongPress) separately toggles the hidden Developer
  // Options section, so the two gestures never interfere with each other.
  void _handleSettingsIconLongPress() {
    setState(() {
      _devOptionsUnlocked = !_devOptionsUnlocked;
    });
    _saveDevOptionsPref();
    _showToast(
      _devOptionsUnlocked
          ? '🔓 Developer Options සක්‍රීය විය — Settings අගට scroll කරන්න'
          : '🔒 Developer Options සඟවන ලදී',
    );
  }

  // --- LANGUAGE (SINHALA / ENGLISH / TAMIL) -------------------------------
  Future<void> _loadLanguagePref() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('Grahana_app_language');
    if (saved != null && mounted) {
      setState(() => _appLanguage = saved);
    }
  }

  Future<void> _setAppLanguage(String lang) async {
    setState(() => _appLanguage = lang);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('Grahana_app_language', lang);
  }

  // --- COORDINATE SYSTEM (WGS84 / SLD99 / Kandawala) ----------------------
  // Lets the user pick which coordinate system every coordinate display in
  // the app (marker details, shape details, search-by-coordinate, etc.) is
  // shown in - they all already read _selectedEPSG via
  // _getFormattedCoordinates, so switching it here is enough on its own.
  Future<void> _loadCoordSystemPref() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('Grahana_coord_system');
    if (saved != null && mounted) {
      setState(() => _selectedEPSG = saved);
    }
  }

  Future<void> _setCoordSystem(String epsg) async {
    setState(() => _selectedEPSG = epsg);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('Grahana_coord_system', epsg);
  }

  // Small in-app translation table for the core UI labels. Falls back to
  // English, then to the key itself, if a translation is missing.
  static const Map<String, Map<String, String>> _kTranslations = {
    'settings': {'si': 'සැකසුම්', 'en': 'Settings', 'ta': 'அமைப்புகள்'},
    'language': {'si': 'භාෂාව', 'en': 'Language', 'ta': 'மொழி'},
    'map_type': {'si': 'සිතියම් වර්ගය', 'en': 'Map Type', 'ta': 'வரைபட வகை'},
    'street': {'si': 'වීදි', 'en': 'Street', 'ta': 'தெரு'},
    'satellite': {'si': 'චන්ද්‍රිකා', 'en': 'Satellite', 'ta': 'செயற்கைக்கோள்'},
    'topography': {'si': 'භූ ස්වරූපය', 'en': 'Topography', 'ta': 'நிலவியல்'},
    'area_unit': {'si': 'භූමි ඒකකය', 'en': 'Area Unit', 'ta': 'பரப்பு அலகு'},
    'acres': {'si': 'අක්කර', 'en': 'Acres', 'ta': 'ஏக்கர்'},
    'perches': {'si': 'පර්චස්', 'en': 'Perches', 'ta': 'பேர்ச்'},
    'laas': {'si': 'ලෑස්', 'en': 'Laas', 'ta': 'லாஸ்'},
    'meters_sqm': {
      'si': 'මීටර් (m²)',
      'en': 'Meters (m²)',
      'ta': 'மீட்டர் (m²)',
    },
    'distance_unit': {
      'si': 'දුර ඒකකය',
      'en': 'Distance Unit',
      'ta': 'தூர அலகு',
    },
    'kilometers': {'si': 'කිලෝමීටර්', 'en': 'Kilometers', 'ta': 'கிலோமீட்டர்'},
    'meters': {'si': 'මීටර්', 'en': 'Meters', 'ta': 'மீட்டர்'},
    'tracking_mode': {
      'si': 'ට්‍රැකින් ක්‍රමය',
      'en': 'Tracking Mode',
      'ta': 'கண்காணிப்பு முறை',
    },
    'road_line_path': {
      'si': 'මාර්ගය / රේඛා පථය',
      'en': 'Road / Line Path',
      'ta': 'சாலை / கோடு பாதை',
    },
    'land_polygon_area': {
      'si': 'භූමිය / බහුඅස්‍ර ප්‍රදේශය',
      'en': 'Land / Polygon Area',
      'ta': 'நிலம் / பலகோண பரப்பு',
    },
    'manual_tool': {
      'si': 'අතින් යොදන මෙවලම',
      'en': 'Manual Tool',
      'ta': 'கைமுறை கருவி',
    },
    'pan_move': {'si': 'ගමන් කරන්න', 'en': 'Pan / Move', 'ta': 'நகர்த்து'},
    'add_marker': {
      'si': 'සලකුණ එකතු කරන්න',
      'en': 'Add Marker',
      'ta': 'குறியீடு சேர்',
    },
    'draw_line': {'si': 'රේඛාවක් අඳින්න', 'en': 'Draw Line', 'ta': 'கோடு வரை'},
    'draw_polygon': {
      'si': 'බහුඅස්‍රයක් අඳින්න',
      'en': 'Draw Polygon',
      'ta': 'பலகோணம் வரை',
    },
    'clear_current_map': {
      'si': 'වත්මන් සිතියම හිස් කරන්න',
      'en': 'Clear Current Map',
      'ta': 'தற்போதைய வரைபடத்தை அழி',
    },
    'start_land_area': {
      'si': 'භූමි ප්‍රදේශය ආරම්භ කරන්න',
      'en': 'Start Land Area',
      'ta': 'நில பரப்பைத் தொடங்கு',
    },
    'start_path_track': {
      'si': 'ට්‍රැකින් ආරම්භ කරන්න',
      'en': 'Start Path Track',
      'ta': 'பாதை கண்காணிப்பைத் தொடங்கு',
    },
    'search_tooltip': {
      'si': 'ස්ථානය / ඛණ්ඩාංක සොයා යන්න',
      'en': 'Search Location / Coordinate & Navigate',
      'ta': 'இடம் / ஆயத்தொலைவு தேடி செல்',
    },
    'saved_tracks': {
      'si': 'සුරැකි Tracks',
      'en': 'Saved Tracks Library',
      'ta': 'சேமிக்கப்பட்ட பாதைகள்',
    },
    'more_options': {
      'si': 'තවත් විකල්ප',
      'en': 'More Options',
      'ta': 'மேலும் விருப்பங்கள்',
    },
    'import_kml': {
      'si': 'KML / KMZ ආයාත කරන්න',
      'en': 'Import KML / KMZ',
      'ta': 'KML / KMZ இறக்குமதி',
    },
    'kml_layers_manager': {
      'si': 'KML Layers කළමනාකරණය',
      'en': 'KML Layers Manager',
      'ta': 'KML அடுக்கு மேலாளர்',
    },
    'export_map': {
      'si': 'වත්මන් සිතියම නිර්යාත කරන්න',
      'en': 'Export Current Map',
      'ta': 'வரைபடத்தை ஏற்றுமதி செய்',
    },
    'developer_info': {
      'si': 'සංවර්ධක තොරතුරු',
      'en': 'Developer Info',
      'ta': 'டெவலப்பர் தகவல்',
    },
    'save_drawing': {
      'si': 'චිත්‍රණය සුරකින්න',
      'en': 'Save Drawing',
      'ta': 'வரைபடத்தை சேமி',
    },
    'coordinate_system': {
      'si': 'ඛණ්ඩාංක ක්‍රමය',
      'en': 'Coordinate System',
      'ta': 'ஆயத்தொலைவு முறை',
    },
    'coord_wgs84': {
      'si': 'WGS84 (Lat/Lon)',
      'en': 'WGS84 (Lat/Lon)',
      'ta': 'WGS84 (Lat/Lon)',
    },
    'coord_sld99': {'si': 'SLD99', 'en': 'SLD99', 'ta': 'SLD99'},
    'coord_kandawala': {
      'si': 'Kandawala',
      'en': 'Kandawala',
      'ta': 'Kandawala',
    },
  };

  String _t(String key) {
    final entry = _kTranslations[key];
    if (entry == null) return key;
    return entry[_appLanguage] ?? entry['en'] ?? key;
  }

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    _durationTimer?.cancel();
    super.dispose();
  }

  // --- LOCAL STORAGE LOGIC ---
  Future<void> _loadSavedTracksFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final String? tracksJson = prefs.getString('Grahana_saved_tracks');
    if (tracksJson != null) {
      final List decoded = jsonDecode(tracksJson);
      setState(() {
        _savedTracks = decoded.map((e) => SavedTrack.fromJson(e)).toList();
      });
    }
  }

  Future<void> _saveTrackToStorage(String title, String officerName) async {
    final newTrack = SavedTrack(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title.isEmpty
          ? 'Track ${DateTime.now().toString().substring(0, 16)}'
          : title,
      dateTime: DateTime.now(),
      points: List.from(_drawnPoints),
      // Only markers the user placed themselves (docId == ''). Markers
      // imported from a KML/KMZ carry that file's docId and belong to the
      // KML layer, not to this track - saving them here bloated the track
      // and made them reappear when the track was exported.
      markers: _markerDataList.where((m) => m.docId.isEmpty).toList(),
      distanceKm: _totalDistance,
      rawAreaSqm: _calculateRawAreaSqm(),
      trackMode: _trackingType,
      officerName: officerName.trim(),
    );

    setState(() {
      _savedTracks.add(newTrack);
    });

    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_savedTracks.map((e) => e.toJson()).toList());
    await prefs.setString('Grahana_saved_tracks', encoded);
    // Remember the officer name so it's pre-filled next time, instead of
    // retyping it on every single track.
    if (officerName.trim().isNotEmpty) {
      await prefs.setString('Grahana_last_officer_name', officerName.trim());
    }
    _showToast('Track එක සාර්ථකව සුරැකිණි!');
  }

  Future<void> _deleteSavedTrack(String id) async {
    setState(() {
      _savedTracks.removeWhere((track) => track.id == id);
    });
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_savedTracks.map((e) => e.toJson()).toList());
    await prefs.setString('Grahana_saved_tracks', encoded);
    _showToast('Track එක ඉවත් කරන ලදී.');
  }

  void _loadSavedTrackToMap(SavedTrack track) {
    setState(() {
      _drawnPoints.clear();
      _markerDataList.clear();
      _drawnPoints.addAll(track.points);
      _markerDataList.addAll(track.markers);
      _totalDistance = track.distanceKm;
      _trackingType = track.trackMode;
      _buildMarkersList();

      if (_drawnPoints.isNotEmpty) {
        _mapController.move(_drawnPoints.first, 15.0);
      } else if (_markerDataList.isNotEmpty) {
        _mapController.move(_markerDataList.first.position, 15.0);
      }
    });
    _showToast('${track.title} Map එකට එක් කරන ලදී.');
  }

  // --- SAVED TRACKS LIST DIALOG ---
  void _showSavedTracksListDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Row(
                children: [
                  Icon(Icons.history, color: Colors.teal),
                  SizedBox(width: 8),
                  Text(
                    'Saved Tracks Library',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: _savedTracks.isEmpty
                    ? const Center(
                        child: Text(
                          'සුරැකි Tracks කිසිවක් නැත.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _savedTracks.length,
                        separatorBuilder: (context, index) => const Divider(),
                        itemBuilder: (context, index) {
                          final track = _savedTracks[index];
                          String formattedArea = _formatArea(track.rawAreaSqm);
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              track.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.teal,
                              ),
                            ),
                            subtitle: Text(
                              'Type: ${track.trackMode == 'PATH' ? 'Road / Path' : 'Land Area'}\nDate: ${track.dateTime.toString().substring(0, 16)}\nDist: ${_formatDistance(track.distanceKm)}${track.trackMode == 'LAND' ? ' | Area: $formattedArea' : ''}'
                              '${track.officerName.isNotEmpty ? '\nOfficer: ${track.officerName}' : ''}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            isThreeLine: true,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.map,
                                    color: Colors.blue,
                                  ),
                                  tooltip: 'Map එකට Load කරන්න',
                                  onPressed: () {
                                    Navigator.pop(context);
                                    _loadSavedTrackToMap(track);
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.ios_share,
                                    color: Colors.green,
                                  ),
                                  tooltip: 'Export කරන්න',
                                  onPressed: () {
                                    _exportData(
                                      customPoints: track.points,
                                      customMarkers: track.markers,
                                      title: track.title,
                                    );
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete,
                                    color: Colors.red,
                                  ),
                                  tooltip: 'Delete කරන්න',
                                  onPressed: () async {
                                    await _deleteSavedTrack(track.id);
                                    setStateDialog(() {});
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('වසා දමන්න (Close)'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --- GPS LOGIC & SATELLITE ESTIMATION ---
  void _showPermissionDeniedDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.location_off, color: Colors.orange),
            SizedBox(width: 8),
            Text('Location අවසරය අවශ්‍යයි'),
          ],
        ),
        content: const Text(
          'ඇප් එකට ඔබගේ වත්මන් ස්ථානය (GPS) ලබාගැනීමට Settings වෙතින් Location permission ("While Using the App") ලබා දිය යුතුය.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('පසුවට'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.settings),
            label: const Text('Settings විවෘත කරන්න'),
            onPressed: () {
              Navigator.pop(ctx);
              Geolocator.openAppSettings();
            },
          ),
        ],
      ),
    );
  }

  void _showLocationServiceDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.gps_off, color: Colors.red),
            SizedBox(width: 8),
            Text('GPS ක්‍රියාවිරහිතයි'),
          ],
        ),
        content: const Text(
          'ඔබගේ දුරකථනයේ GPS / Location Services ක්‍රියාවිරහිත කර ඇත. කරුණාකර එය සක්‍රීය කරන්න.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('පසුවට'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.location_on),
            label: const Text('GPS Settings විවෘත කරන්න'),
            onPressed: () {
              Navigator.pop(ctx);
              Geolocator.openLocationSettings();
            },
          ),
        ],
      ),
    );
  }

  Future<Position?> _determinePosition({bool moveCamera = false}) async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showLocationServiceDialog();
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _showToast('Location අවසර ලබා දී නොමැත.');
          return null;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _showPermissionDeniedDialog();
        return null;
      }

      // 1. Instant response: Show last known location immediately if available
      Position? lastKnown;
      try {
        lastKnown = await Geolocator.getLastKnownPosition();
      } catch (_) {}

      if (lastKnown != null && mounted) {
        _updateGpsStats(lastKnown);
        setState(() {
          _currentLocation = LatLng(lastKnown!.latitude, lastKnown!.longitude);
          if (moveCamera) {
            _mapController.move(_currentLocation!, 15.0);
          }
        });
      }

      // 2. Fetch fresh live GPS fix with fallback
      final LocationSettings locationSettings = (!kIsWeb && Platform.isIOS)
          ? AppleSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 0,
              activityType: ActivityType.other,
              pauseLocationUpdatesAutomatically: false,
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 0,
            );

      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: locationSettings,
        ).timeout(const Duration(seconds: 8));
      } catch (_) {
        // Fallback to medium accuracy if high accuracy fix takes too long (e.g. indoors)
        try {
          position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium,
              distanceFilter: 0,
            ),
          ).timeout(const Duration(seconds: 5));
        } catch (_) {
          if (lastKnown != null) {
            return lastKnown;
          }
          throw TimeoutException('GPS fix timed out');
        }
      }

      if (position != null && mounted) {
        _updateGpsStats(position);
        setState(() {
          _currentLocation = LatLng(position!.latitude, position!.longitude);
          if (moveCamera) {
            _mapController.move(_currentLocation!, 15.0);
          }
        });
        return position;
      }
      return lastKnown;
    } on TimeoutException {
      _showToast(
        'GPS Signal එක ලබාගැනීමට වැඩි කාලයක් ගතවේ. විවෘත ප්‍රදේශයකට ගොස් නැවත උත්සාහ කරන්න.',
      );
      return null;
    } catch (e) {
      _showToast('GPS Error: $e');
      return null;
    }
  }

  Color _accuracyColor(double acc) {
    if (acc <= 5) return Colors.greenAccent;
    if (acc <= 10) return Colors.lightGreenAccent;
    if (acc <= _kMinGpsAccuracyMeters) return Colors.amber;
    return Colors.redAccent;
  }

  void _updateGpsStats(Position pos) {
    _currentAccuracy = pos.accuracy;
    if (pos.accuracy <= 5) {
      _estimatedSatellites = 12;
    } else if (pos.accuracy <= 10) {
      _estimatedSatellites = 8;
    } else if (pos.accuracy <= 20) {
      _estimatedSatellites = 5;
    } else {
      _estimatedSatellites = 3;
    }
    // pos.speed is m/s from the GPS chip; convert to km/h for display.
    // Guard against occasional negative/NaN readings from noisy fixes.
    final speedMs = pos.speed.isFinite && pos.speed > 0 ? pos.speed : 0.0;
    _currentSpeedKmh = speedMs * 3.6;
    _currentAltitude = pos.altitude.isFinite ? pos.altitude : 0.0;
  }

  void _recenterMap() async {
    Position? pos = await _determinePosition();
    if (pos != null) {
      _mapController.move(LatLng(pos.latitude, pos.longitude), 16.0);
    }
  }

  void _addPinAtCurrentLocation() async {
    Position? pos = await _determinePosition();
    if (pos != null) {
      LatLng currentLatLng = LatLng(pos.latitude, pos.longitude);
      _showMarkerDataInputDialog(currentLatLng);
    } else {
      _showToast('GPS ස්ථානය ලබා ගැනීමට නොහැක!');
    }
  }

  // --- SEARCH & ROAD-ROUTE NAVIGATION ---

  // Accepts either "lat,lng" (e.g. "7.8731, 80.7718") or a place name.
  Future<LatLng?> _resolveSearchQuery(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return null;

    // Try coordinate pattern first: "lat,lng"
    final parts = query.split(',');
    if (parts.length == 2) {
      final lat = double.tryParse(parts[0].trim());
      final lng = double.tryParse(parts[1].trim());
      if (lat != null &&
          lng != null &&
          lat >= -90 &&
          lat <= 90 &&
          lng >= -180 &&
          lng <= 180) {
        return LatLng(lat, lng);
      }
    }

    // Otherwise, treat it as a place name and geocode via OpenStreetMap Nominatim.
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?format=json&limit=1&q=${Uri.encodeQueryComponent(query)}',
      );
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final request = await client.getUrl(uri);
      request.headers.add('User-Agent', 'com.ravanagis.pro (search)');
      request.headers.add('Accept', 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response.transform(utf8.decoder).join();
      client.close(force: true);
      if (response.statusCode == 200) {
        final List<dynamic> results = jsonDecode(body);
        if (results.isNotEmpty) {
          final lat = double.tryParse(results.first['lat'].toString());
          final lon = double.tryParse(results.first['lon'].toString());
          if (lat != null && lon != null) {
            return LatLng(lat, lon);
          }
        }
      }
    } catch (_) {
      // Network/geocoding failure — handled by caller (returns null).
    }
    return null;
  }

  // Fetches a real road-following route (not a straight line) between two
  // points from the public OSRM routing service.
  Future<void> _fetchRoadRoute(LatLng from, LatLng to) async {
    try {
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${from.longitude},${from.latitude};${to.longitude},${to.latitude}'
        '?overview=full&geometries=geojson',
      );
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final request = await client.getUrl(uri);
      request.headers.add('User-Agent', 'com.ravanagis.pro (routing)');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await response.transform(utf8.decoder).join();
      client.close(force: true);

      if (response.statusCode == 200) {
        final data = jsonDecode(body);
        if (data['code'] == 'Ok' &&
            data['routes'] != null &&
            (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          final coords = route['geometry']['coordinates'] as List;
          final points = coords
              .map<LatLng>(
                (c) =>
                    LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
              )
              .toList();
          setState(() {
            _routePoints = points;
            _routeDestination = to;
            _routeDistanceKm = (route['distance'] as num) / 1000.0;
            _routeDurationMin = (route['duration'] as num) / 60.0;
          });
          return;
        }
      }
    } catch (_) {
      // Fall through to the straight-line fallback below.
    }

    // Routing service unavailable (e.g. no signal, or no road route found) —
    // fall back to a direct straight-line path so the user still gets a
    // usable direction/distance to the destination.
    setState(() {
      _routePoints = [from, to];
      _routeDestination = to;
      _routeDistanceKm = const Distance().as(LengthUnit.Kilometer, from, to);
      _routeDurationMin = null;
    });
  }

  void _clearRoute() {
    setState(() {
      _routePoints = [];
      _routeDestination = null;
      _routeDistanceKm = null;
      _routeDurationMin = null;
    });
  }

  Future<void> _searchAndNavigate(String query) async {
    setState(() => _isRouting = true);

    final destination = await _resolveSearchQuery(query);
    if (destination == null) {
      setState(() => _isRouting = false);
      _showToast('ස්ථානය සොයාගත නොහැක. නම හෝ "lat,lng" ලෙස උත්සාහ කරන්න.');
      return;
    }

    Position? currentPos = await _determinePosition();
    if (currentPos == null) {
      setState(() => _isRouting = false);
      _showToast('වත්මන් ස්ථානය (GPS) ලබා ගැනීමට නොහැක!');
      return;
    }

    final origin = LatLng(currentPos.latitude, currentPos.longitude);
    await _fetchRoadRoute(origin, destination);

    setState(() => _isRouting = false);

    if (_routePoints.isNotEmpty) {
      final bounds = LatLngBounds.fromPoints(_routePoints);
      _mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(60)),
      );
    }
  }

  void _showSearchNavigateDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Search & Navigate'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Place name හෝ lat,lng (e.g. 7.8731, 80.7718)',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) {
              Navigator.pop(dialogContext);
              _searchAndNavigate(controller.text);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.directions),
              label: const Text('Navigate'),
              onPressed: () {
                Navigator.pop(dialogContext);
                _searchAndNavigate(controller.text);
              },
            ),
          ],
        );
      },
    );
  }

  // --- TRACKING LOGIC ---
  void _startTracking() async {
    Position? initPos = await _determinePosition();
    if (initPos == null) {
      _showToast('GPS සක්‍රීය කර නොමැත!');
      return;
    }
    setState(() {
      _isTracking = true;
      _isPaused = false;
      _drawnPoints.clear();
      _totalDistance = 0.0;
      _trackingStartTime = DateTime.now();
      _accumulatedDuration = Duration.zero;
      _trackDuration = Duration.zero;
      _lastTrackPointTime = null;
      _currentTool = _trackingType == 'LAND' ? 'POLYGON' : 'LINE';
    });
    _startTimer();
    // Fresh filter for a fresh track, seeded with the high-accuracy fix we
    // just waited for so the first recorded points start from a good estimate.
    _gpsFilter.reset();
    _gpsFilter.process(initPos);
    _subscribeLocationStream();
    _showToast('Real-time GPS ට්‍රැකින් ආරම්භ විය!');
  }

  void _pauseTracking() {
    if (_isTracking && !_isPaused) {
      setState(() {
        _isPaused = true;
        _accumulatedDuration = _trackDuration;
      });
      _durationTimer?.cancel();
      _showToast('Tracking රඳවා තබන ලදී (Paused)');
    }
  }

  void _resumeTracking() {
    if (_isTracking && _isPaused) {
      setState(() {
        _isPaused = false;
        _trackingStartTime = DateTime.now();
      });
      _gpsFilter.reset();
      _startTimer();
      _showToast('Tracking නැවත ආරම්භ කරන ලදී (Resumed)');
    }
  }

  void _stopTracking() async {
    await _positionStreamSubscription?.cancel();
    _durationTimer?.cancel();
    setState(() {
      _isTracking = false;
      _isPaused = false;
    });
    if (_drawnPoints.isNotEmpty) {
      _showSaveTrackDialog();
    }
  }

  void _startTimer() {
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _trackingStartTime != null && !_isPaused) {
        setState(() {
          _trackDuration =
              _accumulatedDuration +
              DateTime.now().difference(_trackingStartTime!);
        });
      }
    });
  }

  // --- GPS noise rejection (added feature) ---
  // A phone's GPS fix drifts a few metres even while standing perfectly
  // still, and distanceFilter (below) only filters what the OS reports as
  // movement - it can't tell real movement from that drift. Without this,
  // a stationary track keeps gaining points and distance on its own. Same
  // 20 m "acceptable accuracy" tier _updateGpsStats already uses for the
  // satellite-bars display, so a fix the UI itself calls low-quality is
  // also kept out of the recorded track.
  static const double _kMinGpsAccuracyMeters = 20.0;
  static const double _kMinMovementMeters = 3.0;

  // Platform-tuned high-accuracy settings for live tracking.
  //  - Android: ask for a fix every 1 s (the plugin default is 5 s), and run
  //    as a foreground service with a wake lock so tracking keeps getting
  //    full-rate GPS with the screen off / app in the background (without
  //    this Android throttles or stops location for backgrounded apps).
  //  - iOS: navigation-grade activity type, never auto-pause updates, and
  //    allow background updates (needs UIBackgroundModes=location, added to
  //    Info.plist).
  LocationSettings _buildTrackingLocationSettings(int distanceFilter) {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: distanceFilter,
        intervalDuration: const Duration(seconds: 1),
        forceLocationManager: false,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'ග්‍රහණ - Tracking සක්‍රියයි',
          notificationText: 'GPS ස්ථාන දත්ත සටහන් කරමින් පවතී...',
          notificationChannelName: 'GPS Tracking',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.other,
        distanceFilter: distanceFilter,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: distanceFilter,
    );
  }

  void _subscribeLocationStream() {
    // Default behaviour, completely unchanged unless the hidden Developer
    // Options "Custom Tracking Refresh Rate" switch is explicitly on.
    final int effectiveDistanceFilter =
        (_devOptionsUnlocked && _customTrackingRefreshEnabled)
        ? _customTrackingRefreshMeters.round()
        : 2;
    final LocationSettings locationSettings = _buildTrackingLocationSettings(
      effectiveDistanceFilter,
    );
    _positionStreamSubscription =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (Position position) {
            _updateGpsStats(position);
            if (_isPaused) return;

            // Raw fix -> validated, Kalman-smoothed fix (see GpsTrackFilter).
            // A null result means the fix was invalid / stale / an
            // impossible jump and is ignored. If the filter itself ever
            // throws, fall back to the raw fix so tracking never stops.
            FilteredFix? maybeFix;
            try {
              maybeFix = _gpsFilter.process(position);
            } catch (_) {
              maybeFix = FilteredFix(
                smoothed: LatLng(position.latitude, position.longitude),
                accuracy: position.accuracy,
                recordable: position.accuracy <= _kMinGpsAccuracyMeters,
              );
            }
            if (maybeFix == null) return;
            final FilteredFix fix = maybeFix;
            final LatLng newPoint = fix.smoothed;

            // Default behaviour, completely unchanged unless the hidden
            // "Custom Time-based Refresh" switch is explicitly on: every
            // good GPS fix becomes a recorded track point (recordPoint stays
            // true). When on, a track point is only recorded once the
            // chosen interval has actually elapsed since the last one -
            // the live location marker below still moves every GPS event
            // regardless, so on-screen position stays smooth either way.
            bool recordPoint = fix.recordable;
            if (recordPoint &&
                _devOptionsUnlocked &&
                _customTimeRefreshEnabled) {
              final now = DateTime.now();
              final minGap = Duration(
                milliseconds: (_customTimeRefreshSeconds * 1000).round(),
              );
              if (_lastTrackPointTime != null &&
                  now.difference(_lastTrackPointTime!) < minGap) {
                recordPoint = false;
              } else {
                _lastTrackPointTime = now;
              }
            }

            setState(() {
              _currentLocation = newPoint;
              if (recordPoint) {
                bool isGpsNoise = false;
                if (_drawnPoints.isNotEmpty) {
                  final double dist = Geolocator.distanceBetween(
                    _drawnPoints.last.latitude,
                    _drawnPoints.last.longitude,
                    newPoint.latitude,
                    newPoint.longitude,
                  );
                  // Movement threshold adapts to signal quality: at least
                  // _kMinMovementMeters, and never less than half the
                  // fix's own reported accuracy - you cannot resolve
                  // movement smaller than the position's uncertainty.
                  // Compared against the last *recorded* point so genuine
                  // slow movement still accumulates until it clears it.
                  final double minMove = math.max(
                    _kMinMovementMeters,
                    fix.accuracy * 0.5,
                  );
                  if (dist < minMove) {
                    isGpsNoise = true;
                  } else {
                    _totalDistance += (dist / 1000.0);
                  }
                }
                if (!isGpsNoise) {
                  _drawnPoints.add(newPoint);
                }
              }
              _mapController.move(newPoint, _mapController.camera.zoom);
            });
          },
          onError: (Object e) {
            // A stream error (e.g. GPS momentarily lost) must not silently
            // kill live tracking or crash the app - surface it and keep
            // whatever track has been recorded so far intact.
            _showToast('GPS Tracking Error: $e');
          },
          cancelOnError: false,
        );
  }

  void _handleMapTap(TapPosition tapPosition, LatLng point) {
    if (_pickingSavedMarker && _shapeEditMode == 'NONE') {
      _onSavedMarkerPicked(point);
      return;
    }
    if (_shapeEditMode != 'NONE') {
      _handleShapeEditTap(point);
      return;
    }
    if (_currentTool == 'POINT') {
      _showMarkerDataInputDialog(point);
    } else if ((_currentTool == 'LINE' || _currentTool == 'POLYGON') &&
        !_isTracking) {
      setState(() {
        _drawnPoints.add(point);
      });
    } else if (_currentTool == 'PAN') {
      // Try, in order of specificity: imported KML shapes -> the road
      // network (if currently shown) -> the administrative boundary (if
      // currently shown). First hit wins so overlapping layers don't both
      // pop up a sheet at once.
      if (_handleImportedShapeTap(point)) return;
      if (_handleRoadTap(point)) return;
      _handleBoundaryTap(point);
    }
  }

  // Simple ray-casting point-in-polygon test. Works fine at the small
  // lat/lng scale of a single tank/land boundary.
  bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    bool inside = false;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      final xi = polygon[i].longitude;
      final yi = polygon[i].latitude;
      final xj = polygon[j].longitude;
      final yj = polygon[j].latitude;
      final intersects =
          ((yi > point.latitude) != (yj > point.latitude)) &&
          (point.longitude <
              (xj - xi) * (point.latitude - yi) / (yj - yi) + xi);
      if (intersects) inside = !inside;
      j = i;
    }
    return inside;
  }

  double _calculateAreaSqmFor(List<LatLng> points) {
    if (points.length < 3) return 0.0;
    List<turf.Position> positions = points
        .map((p) => turf.Position(p.longitude, p.latitude))
        .toList();
    positions.add(positions.first);
    return (turf.area(turf.Polygon(coordinates: [positions])) ?? 0.0)
        .toDouble();
  }

  // Approximate straight-line distance in meters from a point to a segment
  // (a-b), using a small equirectangular projection centered at 'a'. This
  // is accurate enough at the scale of a single road/tank/GND (a few km),
  // and much cheaper than exact great-circle segment math.
  double _pointToSegmentMeters(LatLng p, LatLng a, LatLng b) {
    final latRef = a.latitude * (math.pi / 180.0);
    final mPerDegLat = 110540.0;
    final mPerDegLng = 111320.0 * math.cos(latRef);

    double toX(LatLng q) => (q.longitude - a.longitude) * mPerDegLng;
    double toY(LatLng q) => (q.latitude - a.latitude) * mPerDegLat;

    final px = toX(p), py = toY(p);
    final bx = toX(b), by = toY(b);
    const ax = 0.0, ay = 0.0;
    final dx = bx - ax, dy = by - ay;
    final lenSq = dx * dx + dy * dy;

    double t = 0.0;
    if (lenSq > 0) {
      t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
      t = t.clamp(0.0, 1.0);
    }
    final projX = ax + t * dx, projY = ay + t * dy;
    final ddx = px - projX, ddy = py - projY;
    return math.sqrt(ddx * ddx + ddy * ddy);
  }

  // Minimum distance in meters from a point to any segment of a polyline.
  double _distanceToPolylineMeters(LatLng point, List<LatLng> line) {
    double best = double.infinity;
    for (int i = 0; i < line.length - 1; i++) {
      final d = _pointToSegmentMeters(point, line[i], line[i + 1]);
      if (d < best) best = d;
    }
    return best;
  }

  // Whether a KML doc's layer is currently visible (doc toggle + category
  // filter). Shapes/markers imported before this feature existed have an
  // empty docId and are always treated as visible.
  bool _isShapeVisible(ImportedShape s) {
    if (s.docId.isEmpty) return true;
    for (final d in _importedKmlDocs) {
      if (d.id == s.docId) {
        return d.visible && !d.hiddenCategories.contains(s.category);
      }
    }
    return true;
  }

  bool _isMarkerVisible(GISMarkerData m) {
    if (m.docId.isEmpty) return true;
    for (final d in _importedKmlDocs) {
      if (d.id == m.docId) return d.visible;
    }
    return true;
  }

  List<ImportedShape> get _visibleImportedShapes =>
      _importedShapes.where(_isShapeVisible).toList();

  // Checks whether the tapped point falls on any currently-visible imported
  // KML shape - a polygon (e.g. tank/land/paddy boundary) tested by
  // point-in-polygon, or a line (e.g. an imported road/track) tested by
  // distance-to-segment - and if so shows that shape's data. Returns true
  // if something was hit (so the caller can stop looking further).
  bool _handleImportedShapeTap(LatLng point) {
    for (var shape in _visibleImportedShapes.where(
      (s) => s.type == 'POLYGON',
    )) {
      if (_isPointInPolygon(point, shape.points)) {
        _showImportedShapeDetailsSheet(shape);
        return true;
      }
    }

    ImportedShape? nearestLine;
    double bestDist = 25; // meters
    for (var shape in _visibleImportedShapes.where((s) => s.type == 'LINE')) {
      final d = _distanceToPolylineMeters(point, shape.points);
      if (d < bestDist) {
        bestDist = d;
        nearestLine = shape;
      }
    }
    if (nearestLine != null) {
      _showImportedShapeDetailsSheet(nearestLine);
      return true;
    }
    return false;
  }

  // Tapping directly on a road that's currently displayed (nearby-roads /
  // local-gov mode) selects it and shows its R_NAME / AUTHORITY / TYPE /
  // LENGTH / WIDTH details — the same sheet used from the road list.
  bool _handleRoadTap(LatLng point) {
    if (!_showNearbyRoadsMode || _nearbyRoads.isEmpty) return false;

    RoadModel? nearest;
    double bestDist = 25; // meters
    for (final road in _nearbyRoads) {
      final pts = RoadService.roadToLatLngs(road);
      if (pts.length < 2) continue;
      final d = _distanceToPolylineMeters(point, pts);
      if (d < bestDist) {
        bestDist = d;
        nearest = road;
      }
    }
    if (nearest != null) {
      _selectRoad(nearest);
      return true;
    }
    return false;
  }

  // Tapping inside the currently displayed administrative boundary shows
  // that exact GND's Province / District / DSD / GND / PS details.
  Future<bool> _handleBoundaryTap(LatLng point) async {
    if (!_showBoundaryOnMap || _selectedBoundaryPolygons.isEmpty) {
      return false;
    }
    bool inside = false;
    for (final ring in _selectedBoundaryPolygons) {
      if (_isPointInPolygon(point, ring)) {
        inside = true;
        break;
      }
    }
    if (!inside) return false;

    final props = await BoundaryService.findFeatureAt(
      point,
      restrictToPsName: _selectedLocalGov,
    );
    if (!mounted) return true;
    _showBoundaryDetailsSheet(props, point);
    return true;
  }

  // --- Imported-shape Edit / Add-new-feature: persistence -----------------
  // Loads any previously edited / hand-drawn shapes (plus the KML doc list
  // that groups them) back into _importedShapes / _importedKmlDocs so they
  // survive an app restart. Purely additive to whatever a fresh KML import
  // in this session already put there.
  Future<void> _loadImportedLayersFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final docsJson = prefs.getString(_kImportedDocsPrefKey);
      final shapesJson = prefs.getString(_kImportedShapesPrefKey);
      final markersJson = prefs.getString(_kImportedMarkersPrefKey);
      if (docsJson == null && shapesJson == null && markersJson == null) {
        return;
      }

      final docs = docsJson == null
          ? <ImportedKmlDoc>[]
          : (jsonDecode(docsJson) as List)
                .map((d) => ImportedKmlDoc.fromJson(d as Map<String, dynamic>))
                .toList();
      final shapes = shapesJson == null
          ? <ImportedShape>[]
          : (jsonDecode(shapesJson) as List)
                .map((s) => ImportedShape.fromJson(s as Map<String, dynamic>))
                .toList();
      final markers = markersJson == null
          ? <GISMarkerData>[]
          : (jsonDecode(markersJson) as List)
                .map((m) => GISMarkerData.fromJson(m as Map<String, dynamic>))
                .toList();

      if (!mounted) return;
      setState(() {
        _importedKmlDocs.addAll(docs);
        _importedShapes.addAll(shapes);
        _markerDataList.addAll(markers);
        _buildMarkersList();
      });
    } catch (e) {
      print('Failed to load persisted imported layers: $e');
    }
  }

  // Saves the CURRENT full set of imported/edited/hand-drawn shapes, their
  // KML-doc groupings, and any KML-imported point markers, so the next app
  // launch shows exactly what was left on screen (minus the raw KML/KMZ
  // file itself, which isn't kept - only the parsed, editable result is).
  Future<void> _saveImportedLayersToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kImportedDocsPrefKey,
        jsonEncode(_importedKmlDocs.map((d) => d.toJson()).toList()),
      );
      await prefs.setString(
        _kImportedShapesPrefKey,
        jsonEncode(_importedShapes.map((s) => s.toJson()).toList()),
      );
      await prefs.setString(
        _kImportedMarkersPrefKey,
        jsonEncode(_markerDataList.map((m) => m.toJson()).toList()),
      );
    } catch (e) {
      print('Failed to persist imported layers: $e');
    }
  }

  // --- Imported-shape Edit / Add-new-feature: editing mode -----------------
  String _newShapeTypeForEdit() => _editingShape?.type ?? _newShapeType;

  void _startEditingShapeGeometry(ImportedShape shape) {
    setState(() {
      _editingShape = shape;
      _editBufferPoints = List<LatLng>.from(shape.points);
      _shapeEditMode = 'EDIT_MOVE';
      _selectedVertexIndex = null;
    });
    _showToast(
      'සංස්කරණය ආරම්භයි: vertex එකක් tap කර, පසුව එය දැමිය යුතු ස්ථානයට tap කරන්න.',
    );
  }

  void _startDrawingNewShape(String type) {
    setState(() {
      _editingShape = null;
      _editBufferPoints = [];
      _newShapeType = type;
      _shapeEditMode = 'DRAW_NEW';
      _selectedVertexIndex = null;
    });
    _showToast('සිතියම tap කර නව Shape එකේ ලක්ෂ්‍ය එකතු කරන්න.');
  }

  void _cancelShapeEdit() {
    setState(() {
      _editingShape = null;
      _editBufferPoints = [];
      _shapeEditMode = 'NONE';
      _selectedVertexIndex = null;
    });
  }

  void _selectEditVertex(int index) {
    setState(() {
      _selectedVertexIndex = (_selectedVertexIndex == index) ? null : index;
    });
  }

  void _deleteSelectedVertex() {
    if (_selectedVertexIndex == null) return;
    final minPoints = _newShapeTypeForEdit() == 'POLYGON' ? 3 : 2;
    if (_editBufferPoints.length <= minPoints) {
      _showToast('අවම ලක්ෂ්‍ය ගණනට වඩා අඩු කළ නොහැක.');
      return;
    }
    setState(() {
      _editBufferPoints.removeAt(_selectedVertexIndex!);
      _selectedVertexIndex = null;
    });
  }

  void _handleShapeEditTap(LatLng point) {
    setState(() {
      if (_shapeEditMode == 'EDIT_ADD' || _shapeEditMode == 'DRAW_NEW') {
        _editBufferPoints.add(point);
      } else if (_shapeEditMode == 'EDIT_MOVE') {
        if (_selectedVertexIndex != null &&
            _selectedVertexIndex! >= 0 &&
            _selectedVertexIndex! < _editBufferPoints.length) {
          _editBufferPoints[_selectedVertexIndex!] = point;
          _selectedVertexIndex = null;
        } else {
          _showToast('මුලින් vertex එකක් tap කරන්න.');
        }
      }
    });
  }

  // Opens the Attribute Table dialog to collect Name/Category/attributes,
  // then commits the edited geometry + attributes back into the existing
  // shape (or creates a brand-new one), and persists everything.
  Future<void> _finishShapeEdit() async {
    final minPoints = _newShapeTypeForEdit() == 'POLYGON' ? 3 : 2;
    if (_editBufferPoints.length < minPoints) {
      _showToast('අවම වශයෙන් ලක්ෂ්‍ය $minPoints ක් අවශ්‍යයි.');
      return;
    }
    final existing = _editingShape;
    final result = await showDialog<ShapeAttributeEditResult>(
      context: context,
      builder: (_) => ShapeAttributeEditorDialog(
        initialName: existing?.name ?? '',
        initialCategory: existing?.category ?? 'Other',
        initialAttributes: existing?.extendedData ?? const {},
        initialType: existing?.type ?? _newShapeType,
        allowTypeChange: existing == null,
      ),
    );
    if (result == null || !mounted) return; // cancelled, stay in edit mode

    setState(() {
      if (existing != null) {
        existing.points = List<LatLng>.from(_editBufferPoints);
        existing.name = result.name;
        existing.category = result.category;
        existing.extendedData = result.attributes;
      } else {
        if (!_importedKmlDocs.any((d) => d.id == _kUserAddedDocId)) {
          _importedKmlDocs.add(
            ImportedKmlDoc(
              id: _kUserAddedDocId,
              fileName: 'මාගේ Shapes (User Added)',
              importedAt: DateTime.now(),
            ),
          );
        }
        _importedShapes.add(
          ImportedShape(
            points: List<LatLng>.from(_editBufferPoints),
            type: result.type,
            name: result.name,
            category: result.category,
            docId: _kUserAddedDocId,
            extendedData: result.attributes,
          ),
        );
      }
      _editingShape = null;
      _editBufferPoints = [];
      _shapeEditMode = 'NONE';
      _selectedVertexIndex = null;
    });

    await _saveImportedLayersToStorage();
    if (!mounted) return;
    _showToast('සුරැකින ලදී! (Saved)');
  }

  void _showAddShapeTypeSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.crop_square, color: Colors.tealAccent),
              title: const Text(
                'නව Polygon අඳින්න',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                'Land / Tank / Paddy වැනි areas සඳහා',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _startDrawingNewShape('POLYGON');
              },
            ),
            ListTile(
              leading: const Icon(Icons.timeline, color: Colors.amberAccent),
              title: const Text(
                'නව Line අඳින්න',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                'Road / Path / Canal වැනි features සඳහා',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _startDrawingNewShape('LINE');
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _editToolChip({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
    Color? color,
  }) {
    final chipColor = color ?? (active ? Colors.tealAccent : Colors.white38);
    final contentColor = color ?? (active ? Colors.tealAccent : Colors.white70);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: chipColor.withOpacity(active ? 0.25 : 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: chipColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: contentColor),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, color: contentColor)),
          ],
        ),
      ),
    );
  }

  void _showImportedShapeDetailsSheet(ImportedShape shape) {
    final centroidLat =
        shape.points.map((p) => p.latitude).reduce((a, b) => a + b) /
        shape.points.length;
    final centroidLng =
        shape.points.map((p) => p.longitude).reduce((a, b) => a + b) /
        shape.points.length;
    final categoryColor =
        kKmlCategoryColors[shape.category] ?? kKmlCategoryColors['Other']!;

    String metricLabel;
    if (shape.type == 'POLYGON') {
      metricLabel = 'Area: ${_formatArea(_calculateAreaSqmFor(shape.points))}';
    } else {
      double lenM = 0;
      const d = Distance();
      for (int i = 0; i < shape.points.length - 1; i++) {
        lenM += d.as(LengthUnit.Meter, shape.points[i], shape.points[i + 1]);
      }
      metricLabel = 'Length: ${_formatDistance(lenM / 1000.0)}';
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.75,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          shape.name,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.deepOrange,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: categoryColor.withOpacity(0.18),
                          border: Border.all(color: categoryColor),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          shape.category,
                          style: TextStyle(
                            color: categoryColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (shape.extendedData.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ...shape.extendedData.entries.map(
                      (e) => _importedDetailRow(e.key, e.value),
                    ),
                  ] else if (shape.description.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _cleanKmlDescription(shape.description),
                      style: const TextStyle(fontSize: 16),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    metricLabel,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _getFormattedCoordinates(LatLng(centroidLat, centroidLng)),
                    style: const TextStyle(color: Colors.grey),
                  ),
                  const Divider(height: 30),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton.icon(
                        icon: const Icon(Icons.zoom_in),
                        label: const Text('Zoom'),
                        onPressed: () {
                          Navigator.pop(context);
                          _mapController.move(
                            LatLng(centroidLat, centroidLng),
                            16.0,
                          );
                        },
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.edit),
                        label: const Text('Edit'),
                        onPressed: () {
                          Navigator.pop(context);
                          _startEditingShapeGeometry(shape);
                        },
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.delete),
                        label: const Text('Delete'),
                        onPressed: () {
                          setState(() {
                            _importedShapes.remove(shape);
                          });
                          _saveImportedLayersToStorage();
                          Navigator.pop(context);
                          _showToast('Shape එක ඉවත් කරන ලදී.');
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // Light-themed label/value row for an imported feature's ExtendedData
  // attribute table (e.g. R_NAME/AUTHORITY/TYPE for a road, GND_N/DSD_N/
  // PROVINCE_N for a boundary) - the same information Google Earth Pro
  // shows in its info balloon, laid out cleanly instead of as a raw table.
  Widget _importedDetailRow(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.black54,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  // ==========================================================================
  // SAVED MARKERS TAB (added feature)
  // --------------------------------------------------------------------------
  // Add a marker (at the live GPS position, or by tapping the map), give it a
  // name / description / type, and it is saved permanently on the device. All
  // saved markers are drawn on the map and listed in the "Saved Markers" tab
  // (AppBar pin icon), where they can be located, edited, deleted or exported.
  // ==========================================================================
  Future<void> _loadSavedMarkers() async {
    final loaded = await SavedMarkerService.load();
    if (!mounted) return;
    setState(() {
      _savedMarkers
        ..clear()
        ..addAll(loaded);
    });
  }

  Future<void> _persistSavedMarkers() => SavedMarkerService.save(_savedMarkers);

  void _openSavedMarkersSheet() {
    if (!mounted) return;
    showSavedMarkersSheet(
      context: context,
      markers: _savedMarkers,
      typeColors: kMarkerTypeColors,
      typeLabels: kMarkerTypeLabels,
      showOnMap: _showSavedMarkers,
      onToggleShowOnMap: (v) => setState(() => _showSavedMarkers = v),
      onAddAtGps: _addSavedMarkerAtGps,
      onPickOnMap: _startPickSavedMarker,
      onLocate: _locateSavedMarker,
      onEdit: _editSavedMarker,
      onDelete: _deleteSavedMarker,
      onExport: _exportSavedMarkers,
    );
  }

  Future<void> _addSavedMarkerAtGps() async {
    final pos = await _determinePosition();
    if (!mounted) return;
    if (pos == null) {
      _showToast('GPS ස්ථානය ලබා ගැනීමට නොහැක!');
    } else {
      await _createSavedMarkerAt(LatLng(pos.latitude, pos.longitude));
    }
    _openSavedMarkersSheet();
  }

  void _startPickSavedMarker() {
    if (_shapeEditMode != 'NONE') {
      _showToast('පළමුව Shape සංස්කරණය අවසන් කරන්න.');
      _openSavedMarkersSheet();
      return;
    }
    setState(() => _pickingSavedMarker = true);
  }

  void _cancelPickSavedMarker() {
    setState(() => _pickingSavedMarker = false);
  }

  Future<void> _onSavedMarkerPicked(LatLng point) async {
    setState(() => _pickingSavedMarker = false);
    await _createSavedMarkerAt(point);
    _openSavedMarkersSheet();
  }

  Future<void> _createSavedMarkerAt(LatLng point) async {
    if (_savedMarkers.length >= kMaxUserMarkers) {
      _showToast(
        'උපරිම Marker සීමාව ($kMaxUserMarkers) ඉක්මවා ඇත! පැරණි Marker කිහිපයක් Delete කරන්න.',
      );
      return;
    }
    final draft = await showSavedMarkerEditorDialog(
      context: context,
      position: point,
      typeColors: kMarkerTypeColors,
      typeLabels: kMarkerTypeLabels,
    );
    if (draft == null || !mounted) return;
    final now = DateTime.now();
    setState(() {
      _savedMarkers.add(
        SavedMarker(
          id: now.microsecondsSinceEpoch.toString(),
          position: point,
          name: draft.name,
          description: draft.description,
          markerType: draft.markerType,
          createdAt: now,
        ),
      );
      _showSavedMarkers = true; // make sure the new marker is visible
    });
    await _persistSavedMarkers();
    _showToast('Marker එක සාර්ථකව සුරැකිණි!');
  }

  void _locateSavedMarker(SavedMarker marker) {
    setState(() => _showSavedMarkers = true);
    _mapController.move(marker.position, 17.0);
  }

  Future<void> _editSavedMarker(SavedMarker marker) async {
    final draft = await showSavedMarkerEditorDialog(
      context: context,
      position: marker.position,
      typeColors: kMarkerTypeColors,
      typeLabels: kMarkerTypeLabels,
      existing: marker,
    );
    if (draft == null || !mounted) return;
    setState(() {
      marker.name = draft.name;
      marker.description = draft.description;
      marker.markerType = draft.markerType;
    });
    await _persistSavedMarkers();
    _showToast('Marker එක යාවත්කාලීන කරන ලදී.');
  }

  Future<void> _deleteSavedMarker(SavedMarker marker) async {
    setState(() => _savedMarkers.removeWhere((m) => m.id == marker.id));
    await _persistSavedMarkers();
    _showToast('Marker එක ඉවත් කරන ලදී.');
  }

  Future<void> _exportSavedMarkers() {
    return _exportData(
      customPoints: const <LatLng>[],
      customMarkers: _savedMarkers
          .map(
            (m) => GISMarkerData(
              position: m.position,
              name: m.name,
              description: m.description,
              markerType: m.markerType,
            ),
          )
          .toList(),
      title: 'Saved Markers',
    );
  }

  void _showSavedMarkerDetails(SavedMarker marker) {
    showSavedMarkerDetailsSheet(
      context: context,
      marker: marker,
      typeColors: kMarkerTypeColors,
      typeLabels: kMarkerTypeLabels,
      coordinateText: _getFormattedCoordinates(marker.position),
      onEdit: () => _editSavedMarker(marker),
      onDelete: () => _deleteSavedMarker(marker),
    );
  }

  List<Marker> _buildSavedMarkerWidgets() {
    return _savedMarkers.map((m) {
      return Marker(
        point: m.position,
        width: 45,
        height: 45,
        child: GestureDetector(
          onTap: _pickingSavedMarker ? null : () => _showSavedMarkerDetails(m),
          child: Icon(
            Icons.pin_drop,
            color: kMarkerTypeColors[m.markerType] ?? Colors.red,
            size: 40,
            shadows: const [
              Shadow(
                color: Colors.black45,
                blurRadius: 4,
                offset: Offset(1, 2),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }

  // Small recenter (+ pause/stop while tracking) buttons shown just above the
  // bottom toolbars (shape-edit toolbar / marker-picking banner). While one of
  // those toolbars is up, the big right-hand button column is hidden so the
  // two never overlap - these keep the essential controls reachable.
  Widget _overlayMiniActions(String tag) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isTracking) ...[
          FloatingActionButton.small(
            heroTag: 'btn_pause_$tag',
            backgroundColor: _isPaused ? Colors.green : Colors.amber[800],
            onPressed: _isPaused ? _resumeTracking : _pauseTracking,
            child: Icon(
              _isPaused ? Icons.play_arrow : Icons.pause,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 10),
          FloatingActionButton.small(
            heroTag: 'btn_stop_$tag',
            backgroundColor: Colors.red,
            onPressed: _stopTracking,
            child: const Icon(Icons.stop, color: Colors.white),
          ),
          const SizedBox(width: 10),
        ],
        FloatingActionButton.small(
          heroTag: 'btn_recenter_$tag',
          backgroundColor: Colors.white,
          onPressed: _recenterMap,
          child: const Icon(Icons.my_location, color: Colors.teal),
        ),
      ],
    );
  }

  // --- MARKER EDITING & DISPLAY LOGIC ---
  void _buildMarkersList() {
    _markers.clear();
    for (var markerData in _markerDataList) {
      if (!_isMarkerVisible(markerData)) continue;
      _markers.add(
        Marker(
          point: markerData.position,
          width: 45,
          height: 45,
          child: GestureDetector(
            onTap: () {
              _showMarkerDetailsSheet(markerData);
            },
            child: Icon(
              Icons.location_on,
              color:
                  markerData.iconColor ??
                  kMarkerTypeColors[markerData.markerType] ??
                  Colors.red,
              size: 40,
              shadows: const [
                Shadow(
                  color: Colors.black45,
                  blurRadius: 4,
                  offset: Offset(1, 2),
                ),
              ],
            ),
          ),
        ),
      );
    }
  }

  void _showMarkerDetailsSheet(GISMarkerData markerData) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.75,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          markerData.name,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.teal,
                          ),
                        ),
                      ),
                      if (markerData.docId.isEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color:
                                (kMarkerTypeColors[markerData.markerType] ??
                                        Colors.red)
                                    .withOpacity(0.18),
                            border: Border.all(
                              color:
                                  kMarkerTypeColors[markerData.markerType] ??
                                  Colors.red,
                            ),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            kMarkerTypeLabels[markerData.markerType] ??
                                markerData.markerType,
                            style: TextStyle(
                              color:
                                  kMarkerTypeColors[markerData.markerType] ??
                                  Colors.red,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (markerData.extendedData.isNotEmpty) ...[
                    ...markerData.extendedData.entries.map(
                      (e) => _importedDetailRow(e.key, e.value),
                    ),
                  ] else
                    Text(
                      _cleanKmlDescription(markerData.description),
                      style: const TextStyle(fontSize: 16),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    _getFormattedCoordinates(markerData.position),
                    style: const TextStyle(color: Colors.grey),
                  ),
                  const Divider(height: 30),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton.icon(
                        icon: const Icon(Icons.edit),
                        label: const Text('Edit'),
                        onPressed: () {
                          Navigator.pop(context);
                          _showMarkerDataInputDialog(
                            markerData.position,
                            existingData: markerData,
                          );
                        },
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.delete),
                        label: const Text('Delete'),
                        onPressed: () {
                          setState(() {
                            _markerDataList.remove(markerData);
                            _buildMarkersList();
                          });
                          if (markerData.docId.isNotEmpty) {
                            _saveImportedLayersToStorage();
                          }
                          Navigator.pop(context);
                          _showToast('Marker එක ඉවත් කරන ලදී.');
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showMarkerDataInputDialog(LatLng point, {GISMarkerData? existingData}) {
    // Manual add + real-time "add pin at GPS location" both funnel through
    // this one dialog, so checking the cap here (only when adding a NEW
    // marker, not when editing an existing one) covers both paths.
    if (existingData == null && _markerDataList.length >= kMaxUserMarkers) {
      _showToast(
        'උපරිම Marker සීමාව ($kMaxUserMarkers) ඉක්මවා ඇත! අලුතක් එකතු කිරීමට පෙර පැරණි Marker කිහිපයක් Delete කරන්න.',
      );
      return;
    }

    final nameController = TextEditingController(
      text: existingData?.name ?? '',
    );
    final descController = TextEditingController(
      text: existingData?.description ?? '',
    );
    String selectedType = existingData?.markerType ?? 'general';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(
                existingData == null
                    ? 'ලකුණේ විස්තර ඇතුළත් කරන්න'
                    : 'ලකුණ සංස්කරණය කරන්න',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.teal,
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'නම / ස්ථානය (Name)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'විස්තරය (Description)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'ලකුණේ වර්ගය (Marker Type)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: kMarkerTypeColors.keys.map((typeKey) {
                        final color = kMarkerTypeColors[typeKey]!;
                        final selected = selectedType == typeKey;
                        return GestureDetector(
                          onTap: () =>
                              setDialogState(() => selectedType = typeKey),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? color.withOpacity(0.18)
                                  : Colors.transparent,
                              border: Border.all(
                                color: selected ? color : Colors.black26,
                                width: selected ? 2 : 1,
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.location_on, color: color, size: 18),
                                const SizedBox(width: 5),
                                Text(
                                  kMarkerTypeLabels[typeKey] ?? typeKey,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: selected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: selected ? color : Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'අවලංගු කරන්න',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (nameController.text.trim().isEmpty) {
                      _showToast('කරුණාකර නමක් ඇතුළත් කරන්න!');
                      return;
                    }

                    setState(() {
                      if (existingData != null) {
                        existingData.name = nameController.text;
                        existingData.description = descController.text;
                        existingData.markerType = selectedType;
                      } else {
                        _markerDataList.add(
                          GISMarkerData(
                            position: point,
                            name: nameController.text,
                            description: descController.text,
                            markerType: selectedType,
                          ),
                        );
                      }
                      _buildMarkersList();
                    });
                    // Editing a marker that came from an imported KML/KMZ was
                    // never written to storage (only shape edits were), so the
                    // change vanished on restart and could not be exported.
                    if (existingData != null && existingData.docId.isNotEmpty) {
                      _saveImportedLayersToStorage();
                    }

                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('සුරකින්න (Save)'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showSaveTrackDialog() async {
    final nameController = TextEditingController();
    final prefs = await SharedPreferences.getInstance();
    final officerController = TextEditingController(
      text: prefs.getString('Grahana_last_officer_name') ?? '',
    );
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Track එක සුරකින්න'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Track Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: officerController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'දත්ත ලබාගත් නිලධාරියාගේ නම',
                  hintText: 'Officer Name',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('මඟහරින්න'),
            ),
            ElevatedButton(
              onPressed: () {
                _saveTrackToStorage(
                  nameController.text.trim(),
                  officerController.text.trim(),
                );
                Navigator.pop(context);
              },
              child: const Text('Save කරන්න'),
            ),
          ],
        );
      },
    );
  }

  void _showDeveloperInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.badge, color: Colors.teal),
            SizedBox(width: 10),
            Text(
              'App Information',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ග්‍රහණ',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.teal,
              ),
            ),
            Text('Version: 1.0.0+1'),
            SizedBox(height: 12),
            Divider(),
            SizedBox(height: 8),
            Text(
              'Developer & GIS Specialist:',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              'Madushan Gunathilaka',
              style: TextStyle(fontSize: 16, color: Colors.black87),
            ),
            SizedBox(height: 4),
            Text(
              'North Western Province GIS Unit',
              style: TextStyle(color: ui.Color.fromARGB(255, 192, 44, 44)),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // --- AREA & CONVERSION CALCULATIONS ---
  double _calculateRawAreaSqm() {
    if (_drawnPoints.length < 3) return 0.0;
    List<turf.Position> positions = _drawnPoints
        .map((p) => turf.Position(p.longitude, p.latitude))
        .toList();
    positions.add(positions.first);
    return (turf.area(turf.Polygon(coordinates: [positions])) ?? 0.0)
        .toDouble();
  }

  String _formatDistance(double km) {
    if (_distanceUnit == 'M') {
      return '${(km * 1000).toStringAsFixed(0)} m';
    }
    return '${km.toStringAsFixed(2)} km';
  }

  String _formatArea(double sqm) {
    if (sqm <= 0) return "0";
    switch (_areaUnit) {
      case 'SQM':
        return "${sqm.toStringAsFixed(2)} m²";
      case 'ACRES':
        double acres = sqm / 4046.86;
        return "${acres.toStringAsFixed(3)} Acres";
      case 'PERCH':
        double perch = sqm / 25.2929;
        return "${perch.toStringAsFixed(2)} Perches";
      case 'LAAS':
        double perch = sqm / 25.2929;
        double laas = perch / 10.0; // 1 Laas = 10 Perches
        return "${laas.toStringAsFixed(2)} Laas";
      default:
        return "${sqm.toStringAsFixed(2)} m²";
    }
  }

  String _getFormattedCoordinates(LatLng point) {
    proj4.Point srcPoint = proj4.Point(x: point.longitude, y: point.latitude);
    if (_selectedEPSG == '5235') {
      var out = wgs84.transform(sld99, srcPoint);
      return "SLD99 E: ${out.x.toStringAsFixed(2)}, N: ${out.y.toStringAsFixed(2)}";
    } else if (_selectedEPSG == '5234') {
      var out = wgs84.transform(kandawala, srcPoint);
      return "Kandawala E: ${out.x.toStringAsFixed(2)}, N: ${out.y.toStringAsFixed(2)}";
    }
    return "WGS84 Lat: ${point.latitude.toStringAsFixed(5)}, Lon: ${point.longitude.toStringAsFixed(5)}";
  }

  // --- EXPORT SYSTEM ---
  // Names/descriptions are free text typed by the officer. Written raw into
  // KML/GPX, a single '&' or '<' makes the whole file invalid XML and QGIS
  // refuses to load it, so escape them. CSV needs embedded quotes doubled.
  String _xmlEscape(String v) => v
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  String _csvEscape(String v) => v.replaceAll('"', '""');

  Future<void> _exportData({
    List<LatLng>? customPoints,
    List<GISMarkerData>? customMarkers,
    String? title,
  }) async {
    final pointsToExport = customPoints ?? _drawnPoints;
    // Exclude markers that came from an imported KML/KMZ (docId set): they
    // are not part of the user's own survey data, and including them put
    // hundreds of unrelated points into QGIS. This also cleans tracks that
    // were saved before this fix and already contain such markers.
    final markersToExport = (customMarkers ?? _markerDataList)
        .where((m) => m.docId.isEmpty)
        .toList();

    if (pointsToExport.isEmpty && markersToExport.isEmpty) {
      _showToast('සිතියමේ කිසිදු දත්තයක් සටහන් කර නැත!');
      return;
    }

    String? format = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Export Format එක තෝරන්න'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'KML'),
            child: const Text('Google Earth KML (.kml)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'GPX'),
            child: const Text('GPS Exchange Format (.gpx)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'CSV'),
            child: const Text('Excel / CSV (.csv)'),
          ),
        ],
      ),
    );

    if (format == null) return;

    String content = '';
    String fileName =
        '${title?.replaceAll(' ', '_') ?? "Ravana_GIS"}_${DateTime.now().millisecondsSinceEpoch}';

    if (format == 'KML') {
      fileName += '.kml';
      content =
          '<?xml version="1.0" encoding="UTF-8"?>\n<kml xmlns="http://www.opengis.net/kml/2.2">\n<Document>\n<name>${_xmlEscape(title ?? "Ravana GIS Data")}</name>\n';
      for (var marker in markersToExport) {
        content +=
            '<Placemark><name>${_xmlEscape(marker.name)}</name><description>${_xmlEscape(marker.description)}</description><Point><coordinates>${marker.position.longitude},${marker.position.latitude},0</coordinates></Point></Placemark>\n';
      }
      if (pointsToExport.isNotEmpty) {
        content += '<Placemark><name>Track</name><LineString><coordinates>\n';
        for (var p in pointsToExport) {
          content += '${p.longitude},${p.latitude},0\n';
        }
        content += '</coordinates></LineString></Placemark>\n';
      }
      content += '</Document>\n</kml>';
    } else if (format == 'GPX') {
      fileName += '.gpx';
      content =
          '<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="Ravana GIS Pro">\n';
      for (var marker in markersToExport) {
        content +=
            '<wpt lat="${marker.position.latitude}" lon="${marker.position.longitude}"><name>${_xmlEscape(marker.name)}</name><desc>${_xmlEscape(marker.description)}</desc></wpt>\n';
      }
      if (pointsToExport.isNotEmpty) {
        content += '<trk><name>Track</name><trkseg>\n';
        for (var p in pointsToExport) {
          content +=
              '<trkpt lat="${p.latitude}" lon="${p.longitude}"></trkpt>\n';
        }
        content += '</trkseg></trk>\n';
      }
      content += '</gpx>';
    } else if (format == 'CSV') {
      fileName += '.csv';
      content = 'Type,Name,Latitude,Longitude,Description\n';
      for (var marker in markersToExport) {
        content +=
            'Marker,"${_csvEscape(marker.name)}",${marker.position.latitude},${marker.position.longitude},"${_csvEscape(marker.description)}"\n';
      }
      for (int i = 0; i < pointsToExport.length; i++) {
        content +=
            'TrackPoint,"Point_$i",${pointsToExport[i].latitude},${pointsToExport[i].longitude},\n';
      }
    }

    _showToast('කරුණාකර File එක Save කිරීමට ස්ථානය තෝරන්න...');

    // NOTE: previously this used getDirectoryPath() + a raw dart:io File()
    // write. On modern Android's scoped storage that path is frequently not
    // a real writable filesystem path, so the file silently never gets
    // created. FilePicker.saveFile() with `bytes` writes the content itself
    // through the platform's proper save-file flow, so it works reliably.
    try {
      final bytes = Uint8List.fromList(utf8.encode(content));
      String? savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Export ගොනුව සුරකින්න',
        fileName: fileName,
        bytes: bytes,
      );

      if (savedPath == null) {
        _showToast('ස්ථානයක් තෝරාගෙන නොමැත!');
        return;
      }

      // On some Android devices/versions, saveFile() returns a path but the
      // plugin silently fails to actually write the bytes there. Verify the
      // file exists with the right size, and if not, write it ourselves as
      // a fallback (works when savedPath is a real filesystem path; on
      // scoped-storage-only paths this fallback is a harmless no-op catch).
      bool writtenOk = false;
      try {
        final savedFile = File(savedPath);
        writtenOk = await savedFile.exists() && await savedFile.length() > 0;
      } catch (_) {
        writtenOk = false;
      }

      if (!writtenOk) {
        try {
          await File(savedPath).writeAsBytes(bytes, flush: true);
          writtenOk = true;
        } catch (_) {
          writtenOk = false;
        }
      }

      if (writtenOk) {
        _showToast('$format File එක සාර්ථකව සුරැකිණි!');
      } else {
        _showToast(
          'File එක save කිරීමට නොහැකි විය. වෙනත් Folder එකක් උත්සාහ කරන්න.',
        );
      }
    } catch (e) {
      _showToast('Error saving file: $e');
    }
  }

  // Helper: turn a <coordinates> node's text into a List<LatLng>.
  List<LatLng> _parseKmlCoordText(String text) {
    List<LatLng> pts = [];
    var pointsList = text.trim().split(RegExp(r'\s+'));
    for (var ptStr in pointsList) {
      if (ptStr.trim().isEmpty) continue;
      var coords = ptStr.split(',');
      if (coords.length >= 2) {
        pts.add(
          LatLng(
            double.parse(coords[1].trim()),
            double.parse(coords[0].trim()),
          ),
        );
      }
    }
    return pts;
  }

  // Nearest enclosing <Folder> name for a Placemark, if any. KML files
  // organized into folders like "Roads" / "Paddy" / "Tanks" are how most
  // GIS exports (e.g. Google Earth, QGIS) group layers, so this is the
  // primary signal used to split one KML into separate, filterable layers.
  String _kmlFolderNameOf(XmlElement placemark) {
    XmlNode? node = placemark.parent;
    while (node != null) {
      if (node is XmlElement && node.name.local == 'Folder') {
        final nameEl = node.findElements('name');
        if (nameEl.isNotEmpty) return nameEl.first.innerText.trim();
      }
      node = node.parent;
    }
    return '';
  }

  // Parses one .kml file's Placemarks into markers + shapes, tagging each
  // with [docId] and its detected layer category so it becomes its own
  // filterable sub-layer under that file in the Layers Manager.
  ({List<GISMarkerData> markers, List<ImportedShape> shapes}) _parseKmlDocument(
    String kmlString,
    String docId,
  ) {
    final document = XmlDocument.parse(kmlString);
    final placemarks = document.findAllElements('Placemark');

    List<GISMarkerData> importedMarkers = [];
    List<ImportedShape> importedShapes = [];

    for (var p in placemarks) {
      String? nameTagText = p.findElements('name').isNotEmpty
          ? p.findElements('name').first.innerText.trim()
          : null;
      String desc = p.findElements('description').isNotEmpty
          ? p.findElements('description').first.innerText
          : '';
      String styleUrl = p.findElements('styleUrl').isNotEmpty
          ? p.findElements('styleUrl').first.innerText
          : '';
      final folderName = _kmlFolderNameOf(p);

      // <ExtendedData><Data name="X"><value>Y</value></Data>...</ExtendedData>
      // and the <SchemaData><SimpleData name="X">Y</SimpleData></SchemaData>
      // variant some exporters use instead - both get merged into one map.
      final Map<String, String> extendedData = {};
      for (final ed in p.findElements('ExtendedData')) {
        for (final dataEl in ed.findElements('Data')) {
          final key = dataEl.getAttribute('name') ?? '';
          if (key.isEmpty) continue;
          final valueEls = dataEl.findElements('value');
          extendedData[key] = valueEls.isNotEmpty
              ? valueEls.first.innerText.trim()
              : '';
        }
        for (final schemaData in ed.findElements('SchemaData')) {
          for (final sd in schemaData.findElements('SimpleData')) {
            final key = sd.getAttribute('name') ?? '';
            if (key.isEmpty) continue;
            extendedData[key] = sd.innerText.trim();
          }
        }
      }

      // Many real-world exports (this app's own admin-boundary/road/paddy
      // KMZs included) leave <name> empty and put the real identifier in
      // ExtendedData instead. Fall back through a few common field names,
      // then any non-empty attribute, before giving up.
      String name = nameTagText ?? '';
      if (name.isEmpty) {
        for (final key in [
          'R_NAME',
          'NAME',
          'Name',
          'GND_N',
          'gnd_n',
          'TITLE',
          'title',
          'LABEL',
        ]) {
          final v = extendedData[key];
          if (v != null && v.trim().isNotEmpty) {
            name = v.trim();
            break;
          }
        }
      }
      if (name.isEmpty) {
        for (final v in extendedData.values) {
          if (v.trim().isNotEmpty) {
            name = v.trim();
            break;
          }
        }
      }
      if (name.isEmpty) name = 'Imported';

      final category = detectKmlCategory(
        folderName: folderName,
        placemarkName: name,
        styleUrl: styleUrl,
      );

      // Resolve the Placemark's actual KML style (inline <Style>, or the
      // <Style>/<StyleMap> its <styleUrl> points to) so the imported
      // feature renders with the same colours/line width/fill as it does
      // in Google Earth Pro, instead of only our guessed category colour.
      final resolvedStyle = resolveKmlStyle(p);

      // Points (markers) - a Placemark can have its own Point.
      var pointNodes = p.findAllElements('Point');
      for (var ptNode in pointNodes) {
        var coordsNode = ptNode.findAllElements('coordinates');
        if (coordsNode.isNotEmpty) {
          var pts = _parseKmlCoordText(coordsNode.first.innerText);
          if (pts.isNotEmpty) {
            importedMarkers.add(
              GISMarkerData(
                position: pts.first,
                name: name,
                description: desc,
                docId: docId,
                category: category,
                iconColorHex: resolvedStyle.iconColorHex,
                extendedData: extendedData,
              ),
            );
          }
        }
      }

      // Polygons - each <Polygon> (there can be several inside a
      // <MultiGeometry>) is kept as its own separate shape so tank
      // boundaries never get connected to one another. Only the
      // outer boundary is drawn; inner "holes" are ignored for now.
      var polygonNodes = p.findAllElements('Polygon');
      for (var polyNode in polygonNodes) {
        var outerBoundary = polyNode.findAllElements('outerBoundaryIs');
        var ring = outerBoundary.isNotEmpty
            ? outerBoundary.first.findAllElements('coordinates')
            : polyNode.findAllElements('coordinates');
        if (ring.isNotEmpty) {
          var pts = _parseKmlCoordText(ring.first.innerText);
          if (pts.length >= 3) {
            importedShapes.add(
              ImportedShape(
                points: pts,
                type: 'POLYGON',
                name: name,
                description: desc,
                docId: docId,
                category: category,
                styleLineColor: resolvedStyle.lineColor,
                styleLineWidth: resolvedStyle.lineWidth,
                styleFillColor: resolvedStyle.fillColor,
                extendedData: extendedData,
              ),
            );
          }
        }
      }

      // LineStrings (tracks/paths/roads) - also kept separate per Placemark.
      var lineNodes = p.findAllElements('LineString');
      for (var lineNode in lineNodes) {
        var coordsNode = lineNode.findAllElements('coordinates');
        if (coordsNode.isNotEmpty) {
          var pts = _parseKmlCoordText(coordsNode.first.innerText);
          if (pts.length >= 2) {
            importedShapes.add(
              ImportedShape(
                points: pts,
                type: 'LINE',
                name: name,
                description: desc,
                docId: docId,
                category: category,
                styleLineColor: resolvedStyle.lineColor,
                styleLineWidth: resolvedStyle.lineWidth,
                extendedData: extendedData,
              ),
            );
          }
        }
      }
    }

    return (markers: importedMarkers, shapes: importedShapes);
  }

  // Many GIS exports (QGIS/ArcGIS/Google Earth) wrap a Placemark's
  // <description> in HTML, often inside CDATA. Strips tags and decodes the
  // common entities so Sinhala, Tamil, or English description text always
  // renders as clean plain text in the detail sheets instead of raw markup.
  String _cleanKmlDescription(String desc) {
    if (desc.trim().isEmpty) return desc;
    var text = desc.replaceAll(RegExp(r'<[^>]*>'), ' ');
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'(\r?\n\s*){2,}'), '\n');
    return text.trim();
  }

  // Reads a .kml or .kmz file's underlying KML text.
  //
  // .kmz is just a zip archive containing one (usually "doc.kml") or more
  // .kml files plus embedded images/icons — this unzips it in-memory and
  // pulls out the KML text, preferring an entry actually named "doc.kml".
  //
  // Both branches decode explicitly as UTF-8 with `allowMalformed: true`
  // instead of relying on the platform default, so Sinhala/Tamil/English
  // text in <name>/<description> always comes through readable and a
  // stray bad byte never crashes the import.
  Future<String?> _readKmlOrKmzAsString(String path, String fileName) async {
    final bytes = await File(path).readAsBytes();
    final lowerName = fileName.toLowerCase();

    if (lowerName.endsWith('.kmz')) {
      final archive = ZipDecoder().decodeBytes(bytes);
      ArchiveFile? kmlEntry;
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final lower = f.name.toLowerCase();
        if (!lower.endsWith('.kml')) continue;
        // Prefer the conventional "doc.kml" if present; otherwise take
        // the first .kml entry found in the archive.
        if (kmlEntry == null ||
            lower == 'doc.kml' ||
            lower.endsWith('/doc.kml')) {
          kmlEntry = f;
        }
      }
      if (kmlEntry == null) return null;
      final content = kmlEntry.content;
      final kmlBytes = content is Uint8List
          ? content
          : Uint8List.fromList(List<int>.from(content as List));
      return utf8.decode(kmlBytes, allowMalformed: true);
    }

    // Plain .kml
    return utf8.decode(bytes, allowMalformed: true);
  }

  // --- KML IMPORT & VIEW FEATURE ---
  // Supports picking several .kml/.kmz files at once (allowMultiple), and
  // repeated imports simply accumulate — each file becomes its own entry
  // in _importedKmlDocs, visible/hidden independently in the Layers
  // Manager, with its detected sub-layers (Road/Paddy/Tank/...) individually
  // filterable too.
  Future<void> _importKML() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['kml', 'kmz'],
        allowMultiple: true,
      );

      if (result == null || result.files.isEmpty) return;

      List<GISMarkerData> allMarkers = [];
      List<ImportedShape> allShapes = [];
      List<ImportedKmlDoc> newDocs = [];
      int failedCount = 0;

      for (final picked in result.files) {
        if (picked.path == null) continue;
        try {
          final kmlString = await _readKmlOrKmzAsString(
            picked.path!,
            picked.name,
          );
          if (kmlString == null) {
            failedCount++;
            continue;
          }
          final docId =
              '${DateTime.now().millisecondsSinceEpoch}_${picked.name}';
          final parsed = _parseKmlDocument(kmlString, docId);

          if (parsed.markers.isEmpty && parsed.shapes.isEmpty) {
            failedCount++;
            continue;
          }

          allMarkers.addAll(parsed.markers);
          allShapes.addAll(parsed.shapes);
          newDocs.add(
            ImportedKmlDoc(
              id: docId,
              fileName: picked.name,
              importedAt: DateTime.now(),
            ),
          );
        } catch (e) {
          failedCount++;
        }
      }

      if (newDocs.isEmpty) {
        _showToast('KML/KMZ file(s) කියවීමේදී දෝෂයක්.');
        return;
      }

      setState(() {
        _markerDataList.addAll(allMarkers);
        _importedShapes.addAll(allShapes);
        _importedKmlDocs.addAll(newDocs);
        _buildMarkersList();

        if (allShapes.isNotEmpty) {
          _mapController.move(allShapes.first.points.first, 14.0);
        } else if (allMarkers.isNotEmpty) {
          _mapController.move(allMarkers.first.position, 14.0);
        }
      });
      _saveImportedLayersToStorage();

      final okMsg = newDocs.length == 1
          ? '"${newDocs.first.fileName}" සාර්ථකව Import කරන ලදී!'
          : '${newDocs.length} files සාර්ථකව Import කරන ලදී!';
      _showToast(
        failedCount > 0 ? '$okMsg ($failedCount file(s) skip විය)' : okMsg,
      );
    } catch (e) {
      _showToast('KML කියවීමේදී දෝෂයක්: $e');
    }
  }

  // The set of categories present within one imported KML document, with
  // a feature count each — used to build the per-file layer checklist in
  // the Layers Manager.
  Map<String, int> _categoryCountsForDoc(String docId) {
    final counts = <String, int>{};
    for (final s in _importedShapes.where((s) => s.docId == docId)) {
      counts[s.category] = (counts[s.category] ?? 0) + 1;
    }
    for (final m in _markerDataList.where((m) => m.docId == docId)) {
      counts[m.category] = (counts[m.category] ?? 0) + 1;
    }
    return counts;
  }

  // ==========================================================================
  // EXPORT AN IMPORTED KML/KMZ (WITH YOUR EDITS) - kept separate from tracks
  // --------------------------------------------------------------------------
  // Every edit made to an imported file (moved/added/removed vertices,
  // attribute table changes, renamed or edited markers, shapes you drew into
  // it) is already stored per file (by docId). This writes exactly that file's
  // current content back out as .kml or .kmz - never mixed with track data,
  // and never including anything from another file or from tracks.
  // ==========================================================================
  String _kmlHex2(int v) => v.toRadixString(16).padLeft(2, '0');

  // Flutter Color (ARGB) -> KML colour text (aabbggrr).
  String _kmlColor(Color c) =>
      '${_kmlHex2(c.alpha)}${_kmlHex2(c.blue)}${_kmlHex2(c.green)}${_kmlHex2(c.red)}';

  String _kmlCoord(LatLng p) => '${p.longitude},${p.latitude},0';

  String _kmlExtendedData(Map<String, String> data) {
    if (data.isEmpty) return '';
    final b = StringBuffer('<ExtendedData>');
    data.forEach((k, v) {
      b.write(
        '<Data name="${_xmlEscape(k)}"><value>${_xmlEscape(v)}</value></Data>',
      );
    });
    b.write('</ExtendedData>');
    return b.toString();
  }

  String _exportFileBase(String fileName) {
    var base = fileName.replaceAll(
      RegExp(r'\.(kml|kmz)$', caseSensitive: false),
      '',
    );
    base = base.replaceAll(RegExp(r'[\\/:*?"<>|\s()]+'), '_');
    base = base.replaceAll(RegExp(r'^_+|_+$'), '');
    return base.isEmpty ? 'KML_Layer' : base;
  }

  String _buildKmlForDoc(ImportedKmlDoc doc) {
    final shapes = _importedShapes.where((s) => s.docId == doc.id).toList();
    final markers = _markerDataList.where((m) => m.docId == doc.id).toList();
    final categories = <String>[];
    for (final c in [
      ...shapes.map((s) => s.category),
      ...markers.map((m) => m.category),
    ]) {
      if (!categories.contains(c)) categories.add(c);
    }

    final b = StringBuffer();
    b.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    b.writeln('<kml xmlns="http://www.opengis.net/kml/2.2">');
    b.writeln('<Document>');
    b.writeln('<name>${_xmlEscape(_exportFileBase(doc.fileName))}</name>');

    for (final cat in categories) {
      b.writeln('<Folder><name>${_xmlEscape(cat)}</name>');
      final catColor = kKmlCategoryColors[cat] ?? kKmlCategoryColors['Other']!;

      for (final sh in shapes.where((s) => s.category == cat)) {
        if (sh.points.isEmpty) continue;
        final isPolygon = sh.type == 'POLYGON';
        final lineColor = sh.styleLineColor ?? catColor;
        final lineWidth = sh.styleLineWidth ?? 2.0;
        final fillColor = sh.styleFillColor ?? catColor.withOpacity(0.33);

        b.write('<Placemark>');
        b.write('<name>${_xmlEscape(sh.name)}</name>');
        if (sh.description.trim().isNotEmpty) {
          b.write('<description>${_xmlEscape(sh.description)}</description>');
        }
        b.write(
          '<Style><LineStyle><color>${_kmlColor(lineColor)}</color>'
          '<width>$lineWidth</width></LineStyle>',
        );
        if (isPolygon) {
          b.write(
            '<PolyStyle><color>${_kmlColor(fillColor)}</color></PolyStyle>',
          );
        }
        b.write('</Style>');
        b.write(_kmlExtendedData(sh.extendedData));

        if (isPolygon) {
          final ring = List<LatLng>.from(sh.points);
          if (ring.length > 1 &&
              (ring.first.latitude != ring.last.latitude ||
                  ring.first.longitude != ring.last.longitude)) {
            ring.add(ring.first); // KML rings must be closed
          }
          b.write('<Polygon><outerBoundaryIs><LinearRing><coordinates>');
          b.write(ring.map(_kmlCoord).join(' '));
          b.write('</coordinates></LinearRing></outerBoundaryIs></Polygon>');
        } else {
          b.write('<LineString><coordinates>');
          b.write(sh.points.map(_kmlCoord).join(' '));
          b.write('</coordinates></LineString>');
        }
        b.writeln('</Placemark>');
      }

      for (final m in markers.where((m) => m.category == cat)) {
        b.write('<Placemark>');
        b.write('<name>${_xmlEscape(m.name)}</name>');
        if (m.description.trim().isNotEmpty) {
          b.write('<description>${_xmlEscape(m.description)}</description>');
        }
        final hex = m.iconColorHex;
        if (hex != null && RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(hex)) {
          b.write('<Style><IconStyle><color>$hex</color></IconStyle></Style>');
        }
        b.write(_kmlExtendedData(m.extendedData));
        b.write(
          '<Point><coordinates>${_kmlCoord(m.position)}</coordinates></Point>',
        );
        b.writeln('</Placemark>');
      }
      b.writeln('</Folder>');
    }

    b.writeln('</Document>');
    b.write('</kml>');
    return b.toString();
  }

  Future<void> _exportImportedKmlDoc(ImportedKmlDoc doc) async {
    final hasShapes = _importedShapes.any((s) => s.docId == doc.id);
    final hasMarkers = _markerDataList.any((m) => m.docId == doc.id);
    if (!hasShapes && !hasMarkers) {
      _showToast('Export කිරීමට දත්ත නැත.');
      return;
    }

    final String? format = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('"${doc.fileName}" Export කරන්න'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'KML'),
            child: const Text('KML (.kml)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'KMZ'),
            child: const Text('KMZ (.kmz) - compressed'),
          ),
        ],
      ),
    );
    if (format == null) return;

    final kml = _buildKmlForDoc(doc);
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final base = '${_exportFileBase(doc.fileName)}_edited_$stamp';

    late final Uint8List bytes;
    late final String fileName;
    if (format == 'KMZ') {
      final archive = Archive()..add(ArchiveFile.string('doc.kml', kml));
      bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      fileName = '$base.kmz';
    } else {
      bytes = Uint8List.fromList(utf8.encode(kml));
      fileName = '$base.kml';
    }

    _showToast('කරුණාකර File එක Save කිරීමට ස්ථානය තෝරන්න...');
    try {
      final String? savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Export ගොනුව සුරකින්න',
        fileName: fileName,
        bytes: bytes,
      );
      if (savedPath == null) {
        _showToast('ස්ථානයක් තෝරාගෙන නොමැත!');
        return;
      }
      // Same verify-then-fallback write as the track export: on some Android
      // versions saveFile() returns a path without actually writing bytes.
      bool writtenOk = false;
      try {
        final f = File(savedPath);
        writtenOk = await f.exists() && await f.length() > 0;
      } catch (_) {}
      if (!writtenOk) {
        try {
          await File(savedPath).writeAsBytes(bytes, flush: true);
          writtenOk = true;
        } catch (_) {}
      }
      _showToast(
        writtenOk
            ? '$format File එක සාර්ථකව සුරැකිණි!'
            : 'File එක save කිරීමට නොහැකි විය. වෙනත් Folder එකක් උත්සාහ කරන්න.',
      );
    } catch (e) {
      _showToast('Error saving file: $e');
    }
  }

  void _deleteImportedKmlDoc(ImportedKmlDoc doc) {
    setState(() {
      _importedShapes.removeWhere((s) => s.docId == doc.id);
      _markerDataList.removeWhere((m) => m.docId == doc.id);
      _importedKmlDocs.removeWhere((d) => d.id == doc.id);
      _buildMarkersList();
    });
    _saveImportedLayersToStorage();
    _showToast('"${doc.fileName}" ඉවත් කරන ලදී.');
  }

  void _zoomToImportedKmlDoc(ImportedKmlDoc doc) {
    final shape = _importedShapes.firstWhere(
      (s) => s.docId == doc.id,
      orElse: () => ImportedShape(points: const [], type: 'LINE', name: ''),
    );
    if (shape.points.isNotEmpty) {
      _mapController.move(shape.points.first, 15.0);
      return;
    }
    final marker = _markerDataList.firstWhere(
      (m) => m.docId == doc.id,
      orElse: () => GISMarkerData(
        position: const LatLng(0, 0),
        name: '',
        description: '',
      ),
    );
    if (marker.position.latitude != 0 || marker.position.longitude != 0) {
      _mapController.move(marker.position, 15.0);
    }
  }

  // --- KML LAYERS MANAGER ------------------------------------------------
  // Lists every imported KML file as its own row (toggle visible/hidden,
  // zoom to it, delete it) and, expanded, its detected sub-layers
  // (Road/Paddy/Home Garden/Tank/Landuse/...) each individually filterable.
  void _showKmlLayersManager() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.65,
              minChildSize: 0.35,
              maxChildSize: 0.95,
              builder: (_, sc) {
                return Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 10),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[600],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Imported KML Layers',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () async {
                              await _importKML();
                              setModalState(() {});
                            },
                            icon: const Icon(
                              Icons.add,
                              color: Colors.tealAccent,
                            ),
                            label: const Text(
                              'Import',
                              style: TextStyle(color: Colors.tealAccent),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(color: Colors.white24, height: 12),
                    Expanded(
                      child: _importedKmlDocs.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(24.0),
                                child: Text(
                                  'තවම KML/KMZ files import කර නැත.\n"Import" ඔබා tank/road/paddy වැනි layers සහිත .kml හෝ .kmz file එකක් තෝරන්න.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.white54),
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: sc,
                              itemCount: _importedKmlDocs.length,
                              itemBuilder: (_, i) {
                                final doc = _importedKmlDocs[i];
                                final categoryCounts = _categoryCountsForDoc(
                                  doc.id,
                                );
                                return Card(
                                  color: Colors.white.withOpacity(0.06),
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  child: ExpansionTile(
                                    iconColor: Colors.tealAccent,
                                    collapsedIconColor: Colors.white54,
                                    title: Text(
                                      doc.fileName,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${categoryCounts.length} layer(s) · '
                                      '${categoryCounts.values.fold(0, (a, b) => a + b)} features',
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                      ),
                                    ),
                                    leading: Switch(
                                      value: doc.visible,
                                      activeColor: Colors.tealAccent,
                                      onChanged: (v) {
                                        setModalState(() => doc.visible = v);
                                        setState(() {
                                          _buildMarkersList();
                                        });
                                        _saveImportedLayersToStorage();
                                      },
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(
                                            Icons.zoom_in,
                                            color: Colors.white70,
                                          ),
                                          onPressed: () =>
                                              _zoomToImportedKmlDoc(doc),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.delete,
                                            color: Colors.redAccent,
                                          ),
                                          onPressed: () {
                                            _deleteImportedKmlDoc(doc);
                                            setModalState(() {});
                                          },
                                        ),
                                      ],
                                    ),
                                    children: [
                                      ListTile(
                                        dense: true,
                                        leading: const Icon(
                                          Icons.ios_share,
                                          color: Colors.greenAccent,
                                          size: 20,
                                        ),
                                        title: const Text(
                                          'Export edited KML / KMZ',
                                          style: TextStyle(
                                            color: Colors.greenAccent,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        subtitle: const Text(
                                          'Edit කළ shapes / markers / attributes සමඟ (track දත්ත අඩංගු නොවේ)',
                                          style: TextStyle(
                                            color: Colors.white54,
                                            fontSize: 11,
                                          ),
                                        ),
                                        onTap: () => _exportImportedKmlDoc(doc),
                                      ),
                                      ...categoryCounts.entries.map((entry) {
                                        final color =
                                            kKmlCategoryColors[entry.key] ??
                                            kKmlCategoryColors['Other']!;
                                        final hidden = doc.hiddenCategories
                                            .contains(entry.key);
                                        return CheckboxListTile(
                                          value: !hidden,
                                          activeColor: color,
                                          checkColor: Colors.black,
                                          dense: true,
                                          controlAffinity:
                                              ListTileControlAffinity.leading,
                                          secondary: Icon(
                                            Icons.circle,
                                            color: color,
                                            size: 14,
                                          ),
                                          title: Text(
                                            '${entry.key} (${entry.value})',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                            ),
                                          ),
                                          onChanged: (checked) {
                                            setModalState(() {
                                              if (checked == false) {
                                                doc.hiddenCategories.add(
                                                  entry.key,
                                                );
                                              } else {
                                                doc.hiddenCategories.remove(
                                                  entry.key,
                                                );
                                              }
                                            });
                                            setState(() {
                                              _buildMarkersList();
                                            });
                                            _saveImportedLayersToStorage();
                                          },
                                        );
                                      }),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  String _getTileUrl() {
    switch (_selectedTileLayer) {
      case 'SATELLITE':
        // Using {s} subdomain rotation (mt0-mt3) instead of a single fixed
        // host avoids the rate-limiting/blocking that happens when every
        // request hits the same server.
        return 'https://{s}.google.com/vt/lyrs=y&x={x}&y={y}&z={z}';
      case 'TOPO':
        return 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png';
      case 'OSM':
      default:
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    }
  }

  // OSM raster tiles are only served natively up to zoom 19, but
  // flutter_map can over-zoom (scale up) the last available tile past
  // that, which is useful here for closely inspecting tank/land boundary
  // edges. Capped at 21 to match this app's satellite/topo layers rather
  // than left unbounded, since tiles beyond native zoom just get blurrier
  // with no extra real detail.
  double _getMaxZoomForTileLayer() {
    switch (_selectedTileLayer) {
      case 'OSM':
        return 21.0;
      default:
        return 22.0;
    }
  }

  // The real max zoom each tile SERVER actually has images for. Using a
  // flat 21 for every layer (as before) meant that zooming into OSM past
  // 19 silently requested tiles that don't exist on OSM's server, showing
  // blank/missing tiles - this was very likely the real "zoom problem".
  // With the correct native limit per layer, flutter_map instead scales
  // up the last real tile so the map keeps looking populated while
  // zooming further in.
  int _getMaxNativeZoomForTileLayer() {
    switch (_selectedTileLayer) {
      case 'SATELLITE':
        return 21;
      case 'TOPO':
        return 21;
      case 'OSM':
      default:
        return 19;
    }
  }

  List<String> _getTileSubdomains() {
    switch (_selectedTileLayer) {
      case 'SATELLITE':
        return const ['mt0', 'mt1', 'mt2', 'mt3'];
      case 'TOPO':
        return const ['a', 'b', 'c'];
      default:
        return const [];
    }
  }

  // ========== ROAD NETWORK FEATURE ==========
  Future<void> _toggleNearbyRoadsMode() async {
    if (_showNearbyRoadsMode) {
      setState(() {
        _showNearbyRoadsMode = false;
        _nearbyRoads = [];
        _selectedRoad = null;
        _selectedRoadPoints = [];
        _allNearbyRoadPolylines = [];
        _showAllNearbyOnMap = false;
        _selectedLocalGov = null;
        _selectedBoundaryPolygons = [];
        _showBoundaryOnMap = false;
      });
      _showToast('Road mode නිවා දැමුවා');
      return;
    }

    List<LatLng> points = List.from(_drawnPoints);
    if (points.isEmpty && _currentLocation != null) {
      points = [_currentLocation!];
    }
    if (points.isEmpty) {
      // No track/GPS → still allow Local Gov / Boundary selection
      _showRoadModeChooser();
      return;
    }

    setState(() {
      _isLoadingRoads = true;
      _showNearbyRoadsMode = true;
    });

    try {
      final roads = await RoadService.findNearbyRoads(points, radiusMeters: 90);
      if (!mounted) return;

      // Build polylines for ALL nearby roads
      final polys = roads
          .map((r) => RoadService.roadToLatLngs(r))
          .where((p) => p.length >= 2)
          .toList();

      setState(() {
        _nearbyRoads = roads;
        _allNearbyRoadPolylines = polys;
        _showAllNearbyOnMap = true; // auto show all on map
        _isLoadingRoads = false;
      });

      if (roads.isEmpty) {
        _showToast('Nearby roads හමු නොවීය (90m ඇතුළත)');
      } else {
        _showToast('${roads.length} roads map එකේ පෙන්වයි');
        _showNearbyRoadsListDialog();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingRoads = false);
      _showToast('Roads load error: $e');
    }
  }

  void _showAllNearbyOnMapAction() {
    if (_nearbyRoads.isEmpty) {
      _showToast('Roads නැත');
      return;
    }
    final polys = _nearbyRoads
        .map((r) => RoadService.roadToLatLngs(r))
        .where((p) => p.length >= 2)
        .toList();
    setState(() {
      _allNearbyRoadPolylines = polys;
      _showAllNearbyOnMap = true;
      _selectedRoad = null;
      _selectedRoadPoints = [];
    });
    // Fit map roughly to first road
    if (polys.isNotEmpty && polys.first.isNotEmpty) {
      _mapController.move(polys.first[polys.first.length ~/ 2], 15);
    }
    _showToast('${polys.length} roads map එකේ පෙන්වයි');
  }

  void _showRoadModeChooser() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Text(
                  'Road / Boundary Options',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Nearby roads සඳහා track හෝ GPS ඕනේ.\nBoundary / සම්පූර්ණ roads සඳහා Local Gov තෝරන්න.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 20),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.orangeAccent,
                    child: Icon(Icons.alt_route, color: Colors.black),
                  ),
                  title: const Text(
                    'Nearby Roads',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: const Text(
                    'Track / GPS ඕනේ (90m ඇතුළත)',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showToast('පළමුව Track කරන්න හෝ My Location ඔබන්න');
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.cyan,
                    child: Icon(Icons.account_balance, color: Colors.white),
                  ),
                  title: const Text(
                    'Local Gov + Boundary',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: const Text(
                    'PS / UC / MC තෝරලා boundary + roads',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showLocalGovPicker();
                  },
                ),
                if (_showNearbyRoadsMode || _showBoundaryOnMap)
                  ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Colors.redAccent,
                      child: Icon(Icons.clear, color: Colors.white),
                    ),
                    title: const Text(
                      'Clear Roads / Boundary',
                      style: TextStyle(color: Colors.white),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _showNearbyRoadsMode = false;
                        _nearbyRoads = [];
                        _selectedRoad = null;
                        _selectedRoadPoints = [];
                        _allNearbyRoadPolylines = [];
                        _showAllNearbyOnMap = false;
                        _selectedLocalGov = null;
                        _selectedBoundaryPolygons = [];
                        _showBoundaryOnMap = false;
                      });
                      _showToast('Cleared');
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showNearbyRoadsListDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.35,
          maxChildSize: 0.92,
          builder: (_, scrollController) {
            return Column(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.alt_route, color: Colors.orangeAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Nearby Roads (${_nearbyRoads.length})',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                // Action buttons row
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orangeAccent,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          onPressed: () {
                            _showAllNearbyOnMapAction();
                            Navigator.pop(ctx);
                          },
                          icon: const Icon(Icons.map, size: 20),
                          label: const Text(
                            'Show on Map',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.lightBlueAccent,
                            side: const BorderSide(
                              color: Colors.lightBlueAccent,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _showLocalGovPicker();
                          },
                          icon: const Icon(Icons.account_balance, size: 20),
                          label: const Text('Local Gov'),
                        ),
                      ),
                    ],
                  ),
                ),
                // Boundary toggle (when a local gov is selected)
                if (_selectedLocalGov != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.polyline,
                          color: _showBoundaryOnMap
                              ? Colors.cyanAccent
                              : Colors.white38,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Boundary: $_selectedLocalGov',
                            style: TextStyle(
                              color: _showBoundaryOnMap
                                  ? Colors.cyanAccent
                                  : Colors.white54,
                              fontSize: 13,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Switch(
                          value: _showBoundaryOnMap,
                          activeColor: Colors.cyanAccent,
                          onChanged: (v) {
                            setState(() => _showBoundaryOnMap = v);
                            // Force rebuild of sheet parent via pop is hard;
                            // user sees change on map immediately.
                            Navigator.pop(ctx);
                          },
                        ),
                      ],
                    ),
                  ),
                const Divider(color: Colors.white24, height: 1),
                Expanded(
                  child: _nearbyRoads.isEmpty
                      ? const Center(
                          child: Text(
                            'Roads හමු නොවීය',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          itemCount: _nearbyRoads.length,
                          itemBuilder: (_, i) {
                            final r = _nearbyRoads[i];
                            final selected = _selectedRoad?.id == r.id;
                            return ListTile(
                              selected: selected,
                              selectedTileColor: Colors.orange.withOpacity(
                                0.25,
                              ),
                              leading: CircleAvatar(
                                backgroundColor: selected
                                    ? Colors.orangeAccent
                                    : Colors.teal,
                                child: Text(
                                  r.type.isNotEmpty ? r.type[0] : 'R',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              title: Text(
                                r.rName.isNotEmpty ? r.rName : r.rNumber,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${r.authority} · ${r.typeLabel} · ${r.length.toStringAsFixed(0)} m · W:${r.width}m',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                ),
                              ),
                              trailing: selected
                                  ? const Icon(
                                      Icons.check_circle,
                                      color: Colors.orangeAccent,
                                    )
                                  : const Icon(
                                      Icons.chevron_right,
                                      color: Colors.white38,
                                    ),
                              onTap: () {
                                _selectRoad(r);
                                Navigator.pop(ctx);
                              },
                              onLongPress: () => _showRoadDetailsSheet(r),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showLocalGovPicker() async {
    setState(() => _isLoadingRoads = true);
    try {
      final names = await BoundaryService.getLocalGovNames();
      if (!mounted) return;
      setState(() {
        _localGovList = names;
        _isLoadingRoads = false;
      });

      if (names.isEmpty) {
        _showToast('Local Government data හමු නොවීය');
        return;
      }

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.grey[900],
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) {
          String query = '';
          return StatefulBuilder(
            builder: (ctx, setModalState) {
              final filtered = query.isEmpty
                  ? names
                  : names
                        .where(
                          (n) => n.toLowerCase().contains(query.toLowerCase()),
                        )
                        .toList();
              return DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.7,
                minChildSize: 0.4,
                maxChildSize: 0.95,
                builder: (_, sc) {
                  return Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 10),
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[600],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'Local Government (PS / UC / MC)',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: TextField(
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Search PS / UC / MC...',
                            hintStyle: const TextStyle(color: Colors.white38),
                            prefixIcon: const Icon(
                              Icons.search,
                              color: Colors.white54,
                            ),
                            filled: true,
                            fillColor: Colors.white10,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onChanged: (v) => setModalState(() => query = v),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          controller: sc,
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final name = filtered[i];
                            return ListTile(
                              leading: const Icon(
                                Icons.account_balance,
                                color: Colors.lightBlueAccent,
                              ),
                              title: Text(
                                name,
                                style: const TextStyle(color: Colors.white),
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                _loadRoadsForLocalGov(name);
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingRoads = false);
      _showToast('Error: $e');
    }
  }

  Future<void> _loadRoadsForLocalGov(String psName) async {
    setState(() {
      _isLoadingRoads = true;
      _selectedLocalGov = psName;
    });
    _showToast('$psName load වෙමින්...');

    try {
      final results = await Future.wait([
        RoadService.findRoadsInLocalGov(psName),
        BoundaryService.getPolygonsFor(psName),
      ]);
      if (!mounted) return;

      final roads = results[0] as List<RoadModel>;
      final boundaryRings = results[1] as List<List<LatLng>>;

      final polys = roads
          .map((r) => RoadService.roadToLatLngs(r))
          .where((p) => p.length >= 2)
          .toList();

      setState(() {
        _nearbyRoads = roads;
        _allNearbyRoadPolylines = polys;
        _showAllNearbyOnMap = true;
        _showNearbyRoadsMode = true;
        _selectedRoad = null;
        _selectedRoadPoints = [];
        _selectedBoundaryPolygons = boundaryRings;
        _showBoundaryOnMap = true;
        _isLoadingRoads = false;
      });

      // Zoom to boundary if available
      if (boundaryRings.isNotEmpty && boundaryRings.first.isNotEmpty) {
        final first = boundaryRings.first;
        _mapController.move(first[first.length ~/ 2], 12);
      }

      _showToast(
        '$psName → ${roads.length} roads · ${boundaryRings.length} boundary parts',
      );
      _showNearbyRoadsListDialog();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingRoads = false);
      _showToast('Error: $e');
    }
  }

  void _selectRoad(RoadModel road) {
    final pts = RoadService.roadToLatLngs(road);
    setState(() {
      _selectedRoad = road;
      _selectedRoadPoints = pts;
      // keep all nearby visible underneath
      _showAllNearbyOnMap = true;
    });
    if (pts.isNotEmpty) {
      _mapController.move(pts[pts.length ~/ 2], 16);
    }
    _showRoadDetailsSheet(road);
  }

  void _showRoadDetailsSheet(RoadModel road) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.route, color: Colors.orangeAccent, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      road.rName.isNotEmpty ? road.rName : 'Unnamed Road',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _roadDetailRow('Road Number', road.rNumber),
              _roadDetailRow('Authority', road.authority),
              _roadDetailRow('Type', road.typeLabel),
              _roadDetailRow('Length', '${road.length.toStringAsFixed(1)} m'),
              _roadDetailRow('Width', '${road.width} m'),
              if (road.devWidth != null)
                _roadDetailRow('Dev. Width', '${road.devWidth} m'),
              if (_selectedLocalGov != null)
                _roadDetailRow('Local Gov', _selectedLocalGov!),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orangeAccent,
                        foregroundColor: Colors.black,
                      ),
                      onPressed: () {
                        _selectRoad(road);
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.map),
                      label: const Text('Focus'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white38),
                      ),
                      onPressed: () {
                        setState(() {
                          _selectedRoad = null;
                          _selectedRoadPoints = [];
                        });
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.clear),
                      label: const Text('Clear Focus'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _roadDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Shown when the user taps directly on the displayed administrative
  // boundary on the map. Mirrors _showRoadDetailsSheet's styling so the
  // "tap a layer on the map -> see its data" behaviour feels consistent
  // between roads and boundary.
  void _showBoundaryDetailsSheet(Map<String, dynamic>? props, LatLng point) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.account_balance, color: Colors.cyanAccent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        props?['GND_N']?.toString() ??
                            _selectedLocalGov ??
                            'Boundary',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24, color: Colors.white24),
                if (props != null) ...[
                  _roadDetailRow(
                    'Province',
                    props['PROVINCE_N']?.toString() ?? '',
                  ),
                  _roadDetailRow(
                    'District',
                    props['DISTRICT_N']?.toString() ?? '',
                  ),
                  _roadDetailRow('DSD', props['DSD_N']?.toString() ?? ''),
                  _roadDetailRow('GND', props['GND_N']?.toString() ?? ''),
                  _roadDetailRow('GND Code', props['GND_C']?.toString() ?? ''),
                  _roadDetailRow(
                    'Local Gov (PS/UC/MC)',
                    props['MC_UC_PS_N']?.toString() ?? '',
                  ),
                ] else
                  _roadDetailRow(
                    'Local Gov (PS/UC/MC)',
                    _selectedLocalGov ?? '',
                  ),
                const SizedBox(height: 8),
                Text(
                  _getFormattedCoordinates(point),
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 16),
                Center(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.zoom_in),
                    label: const Text('Zoom'),
                    onPressed: () {
                      Navigator.pop(context);
                      _mapController.move(point, 17.0);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showToast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.teal),
      );
    }
  }

  void _clearMap() {
    setState(() {
      _drawnPoints.clear();
      _markers.clear();
      _markerDataList.clear();
      _importedShapes.clear();
      _importedKmlDocs.clear();
      _totalDistance = 0.0;
      _selectedRoad = null;
      _selectedRoadPoints = [];
      _nearbyRoads = [];
      _allNearbyRoadPolylines = [];
      _showAllNearbyOnMap = false;
      _showNearbyRoadsMode = false;
      _selectedLocalGov = null;
      _selectedBoundaryPolygons = [];
      _showBoundaryOnMap = false;
    });
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    return "${twoDigits(d.inHours)}:${twoDigits(d.inMinutes.remainder(60))}:${twoDigits(d.inSeconds.remainder(60))}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: Row(
          children: [
            // Logo Image එක
            ClipRRect(
              borderRadius: BorderRadius.circular(6.0),
              child: Image.asset(
                'assets/GIS_LOGO.jpg',
                height: 32,
                width: 32,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return const Icon(Icons.map, color: Colors.white, size: 28);
                },
              ),
            ),
            const SizedBox(width: 8),
            // App Title එක
            const Flexible(
              child: Text(
                'ග්‍රහණ',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 24,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.teal,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: _t('search_tooltip'),
            onPressed: _showSearchNavigateDialog,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: _t('saved_tracks'),
            onPressed: _showSavedTracksListDialog,
          ),
          IconButton(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
            icon: Badge(
              isLabelVisible: _savedMarkers.isNotEmpty,
              label: Text('${_savedMarkers.length}'),
              child: const Icon(Icons.pin_drop),
            ),
            tooltip: 'Saved Markers',
            onPressed: _openSavedMarkersSheet,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: _t('more_options'),
            onSelected: (value) {
              switch (value) {
                case 'info':
                  _showDeveloperInfo();
                  break;
                case 'import':
                  _importKML();
                  break;
                case 'layers':
                  _showKmlLayersManager();
                  break;
                case 'export':
                  _exportData();
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'import',
                child: ListTile(
                  leading: const Icon(Icons.file_open),
                  title: Text(_t('import_kml')),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'layers',
                child: ListTile(
                  leading: Icon(
                    Icons.layers,
                    color: _importedKmlDocs.isNotEmpty
                        ? Colors.tealAccent[700]
                        : null,
                  ),
                  title: Text(_t('kml_layers_manager')),
                  subtitle: _importedKmlDocs.isNotEmpty
                      ? Text('${_importedKmlDocs.length} file(s)')
                      : null,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'export',
                child: ListTile(
                  leading: const Icon(Icons.ios_share),
                  title: Text(_t('export_map')),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'info',
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(_t('developer_info')),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.settings),
              tooltip: _t('settings'),
              onPressed: () => Scaffold.of(context).openEndDrawer(),
              onLongPress: _handleSettingsIconLongPress,
            ),
          ),
        ],
      ),
      endDrawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.teal),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'ග්‍රහණ',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'Created by Madushan Gunathilaka',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.language),
              title: Text(_t('language')),
              trailing: DropdownButton<String>(
                value: _appLanguage,
                items: const [
                  DropdownMenuItem(value: 'si', child: Text('සිංහල')),
                  DropdownMenuItem(value: 'en', child: Text('English')),
                  DropdownMenuItem(value: 'ta', child: Text('தமிழ்')),
                ],
                onChanged: (val) {
                  if (val != null) _setAppLanguage(val);
                },
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: Text(_t('map_type')),
              trailing: DropdownButton<String>(
                value: _selectedTileLayer,
                items: [
                  DropdownMenuItem(value: 'OSM', child: Text(_t('street'))),
                  DropdownMenuItem(
                    value: 'SATELLITE',
                    child: Text(_t('satellite')),
                  ),
                  DropdownMenuItem(
                    value: 'TOPO',
                    child: Text(_t('topography')),
                  ),
                ],
                onChanged: (val) => setState(() => _selectedTileLayer = val!),
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.square_foot),
              title: Text(_t('area_unit')),
              trailing: DropdownButton<String>(
                value: _areaUnit,
                items: [
                  DropdownMenuItem(value: 'ACRES', child: Text(_t('acres'))),
                  DropdownMenuItem(value: 'PERCH', child: Text(_t('perches'))),
                  DropdownMenuItem(value: 'LAAS', child: Text(_t('laas'))),
                  DropdownMenuItem(value: 'SQM', child: Text(_t('meters_sqm'))),
                ],
                onChanged: (val) => setState(() => _areaUnit = val!),
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.straighten),
              title: Text(_t('distance_unit')),
              trailing: DropdownButton<String>(
                value: _distanceUnit,
                items: [
                  DropdownMenuItem(value: 'KM', child: Text(_t('kilometers'))),
                  DropdownMenuItem(value: 'M', child: Text(_t('meters'))),
                ],
                onChanged: (val) => setState(() => _distanceUnit = val!),
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.explore_outlined),
              title: Text(_t('coordinate_system')),
              trailing: DropdownButton<String>(
                value: _selectedEPSG,
                items: [
                  DropdownMenuItem(
                    value: '4326',
                    child: Text(_t('coord_wgs84')),
                  ),
                  DropdownMenuItem(
                    value: '5235',
                    child: Text(_t('coord_sld99')),
                  ),
                  DropdownMenuItem(
                    value: '5234',
                    child: Text(_t('coord_kandawala')),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) _setCoordSystem(val);
                },
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.route, color: Colors.black54),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          _t('tracking_mode'),
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _trackingType,
                      items: [
                        DropdownMenuItem(
                          value: 'PATH',
                          child: Text(
                            _t('road_line_path'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'LAND',
                          child: Text(
                            _t('land_polygon_area'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      onChanged: (val) {
                        setState(() {
                          _trackingType = val!;
                          if (_trackingType == 'LAND') {
                            _currentTool = 'POLYGON';
                          } else {
                            _currentTool = 'LINE';
                          }
                        });
                      },
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.edit_location_alt_outlined,
                        color: Colors.black54,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          _t('manual_tool'),
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _currentTool,
                      items: [
                        DropdownMenuItem(
                          value: 'PAN',
                          child: Text(
                            _t('pan_move'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'POINT',
                          child: Text(
                            _t('add_marker'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'LINE',
                          child: Text(
                            _t('draw_line'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'POLYGON',
                          child: Text(
                            _t('draw_polygon'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      onChanged: (val) => setState(() => _currentTool = val!),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(
                Icons.delete_sweep_outlined,
                color: Colors.red,
              ),
              title: Text(
                _t('clear_current_map'),
                style: const TextStyle(color: Colors.red),
              ),
              onTap: () {
                _clearMap();
                Navigator.pop(context);
              },
            ),
            // --- Hidden Developer Options -----------------------------
            // Only appears after double-tapping the Settings (gear) icon.
            // Its own switch below is what actually changes any app
            // behaviour - simply seeing this section changes nothing.
            if (_devOptionsUnlocked) ...[
              const Divider(),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    Icon(Icons.developer_mode, color: Colors.deepPurple),
                    SizedBox(width: 10),
                    Text(
                      'Developer Options',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.deepPurple,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.speed_outlined),
                title: const Text(
                  'Custom Tracking Refresh Rate',
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: const Text(
                  'Off = සාමාන්‍ය පරිදිම (default 2m). On කළොත් පහළින් අගය තෝරන්න.',
                  style: TextStyle(fontSize: 11.5),
                ),
                value: _customTrackingRefreshEnabled,
                onChanged: (val) {
                  setState(() => _customTrackingRefreshEnabled = val);
                  _saveDevOptionsPref();
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Refresh Distance',
                      style: TextStyle(
                        fontSize: 13,
                        color: _customTrackingRefreshEnabled
                            ? Colors.black87
                            : Colors.black38,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      child: DropdownButton<double>(
                        isExpanded: true,
                        value: _customTrackingRefreshMeters,
                        onChanged: !_customTrackingRefreshEnabled
                            ? null
                            : (val) {
                                setState(
                                  () => _customTrackingRefreshMeters = val!,
                                );
                                _saveDevOptionsPref();
                              },
                        items: const [
                          DropdownMenuItem(value: 1.0, child: Text('1 m')),
                          DropdownMenuItem(value: 5.0, child: Text('5 m')),
                          DropdownMenuItem(value: 10.0, child: Text('10 m')),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'GPS point එකක් trigger වීමට අවශ්‍ය අවම දුර. අගය අඩුවත් battery use වැඩි වේ.',
                      style: TextStyle(fontSize: 11, color: Colors.black45),
                    ),
                  ],
                ),
              ),
              const Divider(indent: 16, endIndent: 16, height: 8),
              SwitchListTile(
                secondary: const Icon(Icons.timer_outlined),
                title: const Text(
                  'Custom Time-based Refresh',
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: const Text(
                  'Off = දුර මත පමණක් රඳා පවතී (කලින් පරිදිම). On කළොත් පහළින් කාලය තෝරන්න.',
                  style: TextStyle(fontSize: 11.5),
                ),
                value: _customTimeRefreshEnabled,
                onChanged: (val) {
                  setState(() => _customTimeRefreshEnabled = val);
                  _saveDevOptionsPref();
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Refresh Interval',
                      style: TextStyle(
                        fontSize: 13,
                        color: _customTimeRefreshEnabled
                            ? Colors.black87
                            : Colors.black38,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      child: DropdownButton<double>(
                        isExpanded: true,
                        value: _customTimeRefreshSeconds,
                        onChanged: !_customTimeRefreshEnabled
                            ? null
                            : (val) {
                                setState(
                                  () => _customTimeRefreshSeconds = val!,
                                );
                                _saveDevOptionsPref();
                              },
                        items: const [
                          DropdownMenuItem(value: 1.0, child: Text('1 sec')),
                          DropdownMenuItem(value: 3.0, child: Text('3 sec')),
                          DropdownMenuItem(value: 5.0, child: Text('5 sec')),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'GPS point එකක් record වීමට අවශ්‍ය අවම කාලය. Track එකේ පවතින Live Location (නිල් තිත) සෑම විටම smooth ලෙස update වේ - මෙය track polyline එකට point එකතු වන වේගය පමණයි වෙනස් කරන්නේ.',
                      style: TextStyle(fontSize: 11, color: Colors.black45),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(7.8731, 80.7718),
              initialZoom: 8.0,
              maxZoom: _getMaxZoomForTileLayer(),
              onTap: _handleMapTap,
            ),
            children: [
              TileLayer(
                urlTemplate: _getTileUrl(),
                subdomains: _getTileSubdomains(),
                userAgentPackageName: 'com.ravanagis.pro',
                maxNativeZoom: _getMaxNativeZoomForTileLayer(),
                tileProvider: OfflineCacheTileProvider(),
              ),
              if ((_currentTool == 'POLYGON' || _trackingType == 'LAND') &&
                  _drawnPoints.length >= 3)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: _drawnPoints,
                      color: Colors.teal.withOpacity(0.35),
                      borderColor: Colors.teal,
                      borderStrokeWidth: 3.0,
                    ),
                  ],
                ),
              if (_drawnPoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _drawnPoints,
                      color: Colors.blueAccent,
                      strokeWidth: 4.0,
                    ),
                  ],
                ),
              // Imported KML polygons (e.g. tank/land/paddy/boundary
              // features) - each one drawn as its own separate Polygon so
              // multiple tanks in one KML file never get connected to each
              // other. Only shapes whose KML document/category are toggled
              // on in the Layers Manager are shown. Colour/line width/fill
              // come straight from the Placemark's own resolved KML style
              // (its <Style>/<StyleMap>) whenever the file defines one -
              // this is what makes an import look the same here as it does
              // in Google Earth Pro. Files (or shapes) with no style of
              // their own fall back to our guessed category colour.
              if (_visibleImportedShapes.any((s) => s.type == 'POLYGON'))
                PolygonLayer(
                  polygons: _visibleImportedShapes
                      .where((s) => s.type == 'POLYGON')
                      .map((s) {
                        final categoryColor =
                            kKmlCategoryColors[s.category] ??
                            kKmlCategoryColors['Other']!;
                        final borderColor = s.styleLineColor ?? categoryColor;
                        final borderWidth = (s.styleLineWidth ?? 3.0).clamp(
                          1.5,
                          10.0,
                        );
                        final fillColor =
                            s.styleFillColor ?? categoryColor.withOpacity(0.30);
                        return Polygon(
                          points: s.points,
                          color: fillColor,
                          borderColor: borderColor,
                          borderStrokeWidth: borderWidth.toDouble(),
                        );
                      })
                      .toList(),
                ),
              // Imported KML lines (roads/tracks/paths) - same rule: use
              // the KML's own line colour/width when the file defines one,
              // otherwise fall back to the category colour.
              if (_visibleImportedShapes.any((s) => s.type == 'LINE'))
                PolylineLayer(
                  polylines: _visibleImportedShapes
                      .where((s) => s.type == 'LINE')
                      .map((s) {
                        final categoryColor =
                            kKmlCategoryColors[s.category] ??
                            kKmlCategoryColors['Other']!;
                        final lineColor = s.styleLineColor ?? categoryColor;
                        final lineWidth = (s.styleLineWidth ?? 4.0).clamp(
                          1.5,
                          10.0,
                        );
                        return Polyline(
                          points: s.points,
                          color: lineColor,
                          strokeWidth: lineWidth.toDouble(),
                        );
                      })
                      .toList(),
                ),
              if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      color: Colors.deepPurple,
                      strokeWidth: 5.0,
                    ),
                  ],
                ),
              // Selected Local Government boundary
              if (_showBoundaryOnMap && _selectedBoundaryPolygons.isNotEmpty)
                PolygonLayer(
                  polygons: _selectedBoundaryPolygons
                      .map(
                        (ring) => Polygon(
                          points: ring,
                          color: Colors.cyan.withOpacity(0.18),
                          borderColor: Colors.cyanAccent,
                          borderStrokeWidth: 2.5,
                        ),
                      )
                      .toList(),
                ),
              // All nearby / local-gov roads (lighter orange)
              if (_showAllNearbyOnMap && _allNearbyRoadPolylines.isNotEmpty)
                PolylineLayer(
                  polylines: _allNearbyRoadPolylines
                      .map(
                        (pts) => Polyline(
                          points: pts,
                          color: Colors.orange.withOpacity(0.75),
                          strokeWidth: 3.5,
                        ),
                      )
                      .toList(),
                ),
              // Focused / selected road (bright)
              if (_selectedRoadPoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _selectedRoadPoints,
                      color: Colors.yellowAccent,
                      strokeWidth: 6.5,
                    ),
                  ],
                ),
              if (_routeDestination != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _routeDestination!,
                      width: 36,
                      height: 36,
                      child: const Icon(
                        Icons.location_on,
                        color: Colors.deepPurple,
                        size: 36,
                      ),
                    ),
                  ],
                ),
              MarkerLayer(markers: _markers),
              if (_showSavedMarkers && _savedMarkers.isNotEmpty)
                MarkerLayer(markers: _buildSavedMarkerWidgets()),
              // GPS accuracy halo: radius = reported accuracy in metres.
              if (_currentLocation != null &&
                  _currentAccuracy > 0 &&
                  _currentAccuracy < 150)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: _currentLocation!,
                      radius: _currentAccuracy,
                      useRadiusInMeter: true,
                      color: _accuracyColor(_currentAccuracy).withOpacity(0.15),
                      borderColor: _accuracyColor(
                        _currentAccuracy,
                      ).withOpacity(0.7),
                      borderStrokeWidth: 1.5,
                    ),
                  ],
                ),
              if (_currentLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentLocation!,
                      width: 20,
                      height: 20,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(blurRadius: 4, color: Colors.black26),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              // --- Shape Edit / Add-new-feature: live geometry preview ---
              // Shown only while _shapeEditMode is active; doesn't affect
              // any other layer above.
              if (_shapeEditMode != 'NONE') ...[
                if (_newShapeTypeForEdit() == 'POLYGON' &&
                    _editBufferPoints.length >= 3)
                  PolygonLayer(
                    polygons: [
                      Polygon(
                        points: _editBufferPoints,
                        color: Colors.pinkAccent.withOpacity(0.25),
                        borderColor: Colors.pinkAccent,
                        borderStrokeWidth: 3.0,
                      ),
                    ],
                  ),
                if (_editBufferPoints.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _editBufferPoints,
                        color: Colors.pinkAccent,
                        strokeWidth: 3.0,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: _editBufferPoints.asMap().entries.map((entry) {
                    final i = entry.key;
                    final pt = entry.value;
                    final selected = _selectedVertexIndex == i;
                    return Marker(
                      point: pt,
                      width: 28,
                      height: 28,
                      child: GestureDetector(
                        onTap: () => _selectEditVertex(i),
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected
                                ? Colors.yellowAccent
                                : Colors.pinkAccent,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${i + 1}',
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),

          // --- REAL-TIME GPS & STATS DISPLAY OVERLAY ---
          Positioned(
            top: MediaQuery.of(context).padding.top + 15,
            left: 15,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.42,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.75),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black38,
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.satellite_alt,
                          color: Colors.amber,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Satellites: ~$_estimatedSatellites',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        setState(() {
                          _distanceUnit = _distanceUnit == 'KM' ? 'M' : 'KM';
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.straighten,
                              color: Colors.orangeAccent,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Dist: ${_formatDistance(_totalDistance)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.swap_vert,
                              color: Colors.white70,
                              size: 14,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if ((_currentTool == 'POLYGON' ||
                            _trackingType == 'LAND') &&
                        _drawnPoints.length >= 3) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.square_foot,
                            color: Colors.lightGreenAccent,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Area: ${_formatArea(_calculateRawAreaSqm())}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (_isTracking) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.timer,
                            color: Colors.cyanAccent,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Time: ${_formatDuration(_trackDuration)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.speed,
                            color: Colors.greenAccent,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Speed: ${_currentSpeedKmh.toStringAsFixed(1)} km/h',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.terrain,
                            color: Colors.pinkAccent,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Alt: ${_currentAltitude.toStringAsFixed(1)} m',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          // --- SEARCH ROUTE INFO BANNER ---
          if (_routePoints.isNotEmpty)
            Positioned(
              top: MediaQuery.of(context).padding.top + 15,
              right: 15,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.42,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.deepPurple.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.directions,
                        color: Colors.white,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          _routeDurationMin != null
                              ? '${_formatDistance(_routeDistanceKm!)} · ${_routeDurationMin!.toStringAsFixed(0)} min'
                              : '${_formatDistance(_routeDistanceKm!)} (straight)',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: _clearRoute,
                        child: const Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_isRouting)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                color: Colors.deepPurple,
                backgroundColor: Colors.white24,
              ),
            ),

          // --- Shape Edit / Add-new-feature: bottom toolbar ---
          if (_shapeEditMode != 'NONE')
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.of(context).padding.bottom + 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: _overlayMiniActions('edit'),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.tealAccent.withOpacity(0.4),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _editingShape != null
                              ? 'Shape සංස්කරණය (${_editBufferPoints.length} points)'
                              : 'නව Shape අඳිනවා (${_editBufferPoints.length} points)',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _shapeEditMode == 'EDIT_MOVE'
                              ? 'Vertex එකක් tap කරන්න, පසුව එය දැමිය යුතු ස්ථානයට tap කරන්න.'
                              : 'සිතියම tap කර ලක්ෂ්‍ය එකතු කරන්න.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (_editingShape != null)
                              _editToolChip(
                                icon: Icons.open_with,
                                label: 'Move',
                                active: _shapeEditMode == 'EDIT_MOVE',
                                onTap: () => setState(
                                  () => _shapeEditMode = 'EDIT_MOVE',
                                ),
                              ),
                            _editToolChip(
                              icon: Icons.add_location,
                              label: 'Add',
                              active:
                                  _shapeEditMode == 'EDIT_ADD' ||
                                  _shapeEditMode == 'DRAW_NEW',
                              onTap: () => setState(() {
                                _shapeEditMode = _editingShape != null
                                    ? 'EDIT_ADD'
                                    : 'DRAW_NEW';
                              }),
                            ),
                            if (_selectedVertexIndex != null)
                              _editToolChip(
                                icon: Icons.delete_outline,
                                label: 'Delete Vertex',
                                active: false,
                                onTap: _deleteSelectedVertex,
                              ),
                            _editToolChip(
                              icon: Icons.check_circle,
                              label: 'Save',
                              active: false,
                              color: Colors.tealAccent,
                              onTap: _finishShapeEdit,
                            ),
                            _editToolChip(
                              icon: Icons.cancel,
                              label: 'Cancel',
                              active: false,
                              color: Colors.redAccent,
                              onTap: _cancelShapeEdit,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // --- Saved Markers: "tap the map to place marker" banner ---
          if (_pickingSavedMarker && _shapeEditMode == 'NONE')
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.of(context).padding.bottom + 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: _overlayMiniActions('pick'),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.tealAccent.withOpacity(0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.pin_drop, color: Colors.tealAccent),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Marker එක තැබිය යුතු ස්ථානයට සිතියම tap කරන්න.',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ),
                        TextButton(
                          onPressed: _cancelPickSavedMarker,
                          child: const Text(
                            'Cancel',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // --- CONTROL FLOATING BUTTONS ---
          // Hidden while the shape-edit toolbar or the marker-picking banner
          // is showing, so they never overlap the Start Tracking button.
          if (_shapeEditMode == 'NONE' && !_pickingSavedMarker)
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 20,
              right: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FloatingActionButton(
                    heroTag: "btn_pin",
                    backgroundColor: Colors.orangeAccent,
                    tooltip: 'Add Marker at GPS Location',
                    onPressed: _addPinAtCurrentLocation,
                    child: const Icon(
                      Icons.add_location_alt,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  FloatingActionButton(
                    heroTag: "btn_recenter",
                    backgroundColor: Colors.white,
                    tooltip: 'My Location',
                    onPressed: _recenterMap,
                    child: const Icon(Icons.my_location, color: Colors.teal),
                  ),
                  const SizedBox(height: 10),

                  // --- Add New Shape button (draw + attributes + save) ---
                  FloatingActionButton(
                    heroTag: "btn_add_shape",
                    backgroundColor: Colors.deepPurple,
                    tooltip: 'නව Shape එකතු කරන්න (Polygon/Line)',
                    onPressed: _shapeEditMode != 'NONE'
                        ? null
                        : _showAddShapeTypeSheet,
                    child: const Icon(
                      Icons.edit_location_alt,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),

                  // --- Nearby Roads button ---
                  GestureDetector(
                    onLongPress: _isLoadingRoads
                        ? null
                        : () {
                            _showLocalGovPicker();
                          },
                    child: FloatingActionButton(
                      heroTag: "btn_roads",
                      backgroundColor:
                          (_showNearbyRoadsMode || _showBoundaryOnMap)
                          ? Colors.orangeAccent
                          : Colors.deepOrange[700],
                      tooltip: 'Roads / Boundary (long-press = Local Gov)',
                      onPressed: _isLoadingRoads
                          ? null
                          : _toggleNearbyRoadsMode,
                      child: _isLoadingRoads
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              (_showNearbyRoadsMode || _showBoundaryOnMap)
                                  ? Icons.alt_route
                                  : Icons.route,
                              color: Colors.white,
                            ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  if (!_isTracking && _drawnPoints.isNotEmpty) ...[
                    FloatingActionButton(
                      heroTag: "btn_save_manual",
                      backgroundColor: Colors.indigo,
                      tooltip: _t('save_drawing'),
                      onPressed: _showSaveTrackDialog,
                      child: const Icon(Icons.save, color: Colors.white),
                    ),
                    const SizedBox(height: 10),
                  ],

                  if (!_isTracking)
                    FloatingActionButton.extended(
                      heroTag: "btn_start",
                      backgroundColor: Colors.teal,
                      onPressed: _startTracking,
                      icon: Icon(
                        _trackingType == 'LAND'
                            ? Icons.crop_square
                            : Icons.timeline,
                        color: Colors.white,
                      ),
                      label: Text(
                        _trackingType == 'LAND'
                            ? _t('start_land_area')
                            : _t('start_path_track'),
                        style: const TextStyle(color: Colors.white),
                      ),
                    )
                  else
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FloatingActionButton(
                          heroTag: "btn_pause",
                          backgroundColor: _isPaused
                              ? Colors.green
                              : Colors.amber[800],
                          onPressed: _isPaused
                              ? _resumeTracking
                              : _pauseTracking,
                          child: Icon(
                            _isPaused ? Icons.play_arrow : Icons.pause,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 10),
                        FloatingActionButton(
                          heroTag: "btn_stop",
                          backgroundColor: Colors.red,
                          onPressed: _stopTracking,
                          child: const Icon(Icons.stop, color: Colors.white),
                        ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// SHAPE / ATTRIBUTE EDITOR (added feature)
// ----------------------------------------------------------------------------
// After a KML/KMZ import, an imported polygon/line (or a brand-new shape the
// user draws by hand) can be opened here to:
//   1) edit its attribute table (add / edit / remove ExtendedData fields,
//      plus its name & category), and
//   2) edit its drawn geometry (move / add / delete vertices on the map).
// The result is written back into the same ImportedShape object (or, for a
// new shape, becomes a brand-new ImportedShape added to the "My Shapes"
// layer), and the whole set of imported shapes/docs is then persisted via
// SharedPreferences so edits and hand-drawn shapes survive an app restart -
// entirely independent of the app's existing KML-import / boundary / road
// code, which this feature does not modify.
// ============================================================================

/// What the Attribute Table dialog hands back to the caller once the user
/// taps Save - the caller decides whether that means "update this existing
/// shape" or "create a brand-new shape" from it.
class ShapeAttributeEditResult {
  final String name;
  final String category;
  final Map<String, String> attributes;
  final String type; // 'POLYGON' or 'LINE'

  ShapeAttributeEditResult({
    required this.name,
    required this.category,
    required this.attributes,
    required this.type,
  });
}

/// Editable Name / Category / free-form attribute-table (key/value rows)
/// form, shown as a dialog. Used both when finishing an edit of an existing
/// imported shape and when saving a brand-new hand-drawn shape (in which
/// case [allowTypeChange] also lets the user confirm Polygon vs Line).
class ShapeAttributeEditorDialog extends StatefulWidget {
  final String initialName;
  final String initialCategory;
  final Map<String, String> initialAttributes;
  final String initialType;
  final bool allowTypeChange;

  const ShapeAttributeEditorDialog({
    super.key,
    required this.initialName,
    required this.initialCategory,
    required this.initialAttributes,
    required this.initialType,
    this.allowTypeChange = false,
  });

  @override
  State<ShapeAttributeEditorDialog> createState() =>
      _ShapeAttributeEditorDialogState();
}

class _ShapeAttributeEditorDialogState
    extends State<ShapeAttributeEditorDialog> {
  late TextEditingController _nameCtrl;
  late TextEditingController _categoryCtrl;
  late String _type;
  final List<MapEntry<TextEditingController, TextEditingController>> _rows = [];

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName);
    _categoryCtrl = TextEditingController(text: widget.initialCategory);
    _type = widget.initialType;
    for (final e in widget.initialAttributes.entries) {
      _rows.add(
        MapEntry(
          TextEditingController(text: e.key),
          TextEditingController(text: e.value),
        ),
      );
    }
    if (_rows.isEmpty) {
      _rows.add(MapEntry(TextEditingController(), TextEditingController()));
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _categoryCtrl.dispose();
    for (final r in _rows) {
      r.key.dispose();
      r.value.dispose();
    }
    super.dispose();
  }

  void _addRow() {
    setState(() {
      _rows.add(MapEntry(TextEditingController(), TextEditingController()));
    });
  }

  void _removeRow(int i) {
    setState(() {
      _rows[i].key.dispose();
      _rows[i].value.dispose();
      _rows.removeAt(i);
    });
  }

  void _save() {
    final attrs = <String, String>{};
    for (final r in _rows) {
      final k = r.key.text.trim();
      if (k.isEmpty) continue;
      attrs[k] = r.value.text.trim();
    }
    Navigator.pop(
      context,
      ShapeAttributeEditResult(
        name: _nameCtrl.text.trim().isEmpty
            ? 'Untitled Shape'
            : _nameCtrl.text.trim(),
        category: _categoryCtrl.text.trim().isEmpty
            ? 'Other'
            : _categoryCtrl.text.trim(),
        attributes: attrs,
        type: _type,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.grey[900],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'Attribute Table',
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Name',
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white38),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _categoryCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Category (Road / Paddy / Tank / ...)',
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white38),
                  ),
                ),
              ),
              if (widget.allowTypeChange) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      'Shape Type: ',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('Polygon'),
                      selected: _type == 'POLYGON',
                      onSelected: (_) => setState(() => _type = 'POLYGON'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('Line'),
                      selected: _type == 'LINE',
                      onSelected: (_) => setState(() => _type = 'LINE'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Attribute Data',
                  style: TextStyle(
                    color: Colors.tealAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              ..._rows.asMap().entries.map((entry) {
                final i = entry.key;
                final row = entry.value;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: row.key,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                          decoration: const InputDecoration(
                            hintText: 'Field',
                            hintStyle: TextStyle(color: Colors.white38),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: row.value,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                          decoration: const InputDecoration(
                            hintText: 'Value',
                            hintStyle: TextStyle(color: Colors.white38),
                            isDense: true,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.remove_circle_outline,
                          color: Colors.redAccent,
                          size: 20,
                        ),
                        onPressed: () => _removeRow(i),
                      ),
                    ],
                  ),
                );
              }),
              TextButton.icon(
                onPressed: _addRow,
                icon: const Icon(Icons.add, color: Colors.tealAccent),
                label: const Text(
                  'Add Field',
                  style: TextStyle(color: Colors.tealAccent),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _save,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
          child: const Text('Save', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

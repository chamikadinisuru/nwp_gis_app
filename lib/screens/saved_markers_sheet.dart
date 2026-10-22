import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../models/saved_marker_model.dart';

// ============================================================================
// SAVED MARKERS TAB (added feature)
// ----------------------------------------------------------------------------
// UI for adding, saving, listing, editing, deleting and locating markers.
// It knows nothing about the map screen's internals: everything it needs
// (marker list, type colours, actions) is passed in, so the existing map
// code stays untouched apart from a few small hook-ins.
// ============================================================================

/// Values returned by the add / edit dialog.
class SavedMarkerDraft {
  final String name;
  final String description;
  final String markerType;
  const SavedMarkerDraft({
    required this.name,
    required this.description,
    required this.markerType,
  });
}

String _fmtCoord(LatLng p) =>
    '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';

String _fmtDate(DateTime d) => d.toString().substring(0, 16);

// ---------------------------------------------------------------------------
// Main tab (bottom sheet)
// ---------------------------------------------------------------------------
Future<void> showSavedMarkersSheet({
  required BuildContext context,
  required List<SavedMarker> markers,
  required Map<String, Color> typeColors,
  required Map<String, String> typeLabels,
  required bool showOnMap,
  required ValueChanged<bool> onToggleShowOnMap,
  required Future<void> Function() onAddAtGps,
  required VoidCallback onPickOnMap,
  required ValueChanged<SavedMarker> onLocate,
  required Future<void> Function(SavedMarker) onEdit,
  required Future<void> Function(SavedMarker) onDelete,
  required Future<void> Function() onExport,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _SavedMarkersSheet(
      markers: markers,
      typeColors: typeColors,
      typeLabels: typeLabels,
      showOnMap: showOnMap,
      onToggleShowOnMap: onToggleShowOnMap,
      onAddAtGps: onAddAtGps,
      onPickOnMap: onPickOnMap,
      onLocate: onLocate,
      onEdit: onEdit,
      onDelete: onDelete,
      onExport: onExport,
    ),
  );
}

class _SavedMarkersSheet extends StatefulWidget {
  final List<SavedMarker> markers;
  final Map<String, Color> typeColors;
  final Map<String, String> typeLabels;
  final bool showOnMap;
  final ValueChanged<bool> onToggleShowOnMap;
  final Future<void> Function() onAddAtGps;
  final VoidCallback onPickOnMap;
  final ValueChanged<SavedMarker> onLocate;
  final Future<void> Function(SavedMarker) onEdit;
  final Future<void> Function(SavedMarker) onDelete;
  final Future<void> Function() onExport;

  const _SavedMarkersSheet({
    required this.markers,
    required this.typeColors,
    required this.typeLabels,
    required this.showOnMap,
    required this.onToggleShowOnMap,
    required this.onAddAtGps,
    required this.onPickOnMap,
    required this.onLocate,
    required this.onEdit,
    required this.onDelete,
    required this.onExport,
  });

  @override
  State<_SavedMarkersSheet> createState() => _SavedMarkersSheetState();
}

class _SavedMarkersSheetState extends State<_SavedMarkersSheet> {
  late bool _showOnMap;

  @override
  void initState() {
    super.initState();
    _showOnMap = widget.showOnMap;
  }

  Color _colorOf(SavedMarker m) => widget.typeColors[m.markerType] ?? Colors.red;

  @override
  Widget build(BuildContext context) {
    // Newest first.
    final items = widget.markers.reversed.toList();

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            child: Row(
              children: [
                const Icon(Icons.pin_drop, color: Colors.teal),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'සුරැකි Markers (${widget.markers.length})',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.teal,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.ios_share, color: Colors.green),
                  tooltip: 'Export කරන්න',
                  onPressed: widget.markers.isEmpty
                      ? null
                      : () => widget.onExport(),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'වසන්න',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: const Text('Map එකේ පෙන්වන්න (Show on map)'),
            value: _showOnMap,
            onChanged: (v) {
              setState(() => _showOnMap = v);
              widget.onToggleShowOnMap(v);
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.my_location, size: 18),
                    label: const Text('GPS ස්ථානය'),
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onAddAtGps();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.touch_app, size: 18),
                    label: const Text('Map එකෙන්'),
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onPickOnMap();
                    },
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'සුරැකි Markers කිසිවක් නැත.\nඉහත බොත්තම් වලින් අලුත් Marker එකක් එක් කරන්න.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final m = items[index];
                      final color = _colorOf(m);
                      final lines = <String>[
                        widget.typeLabels[m.markerType] ?? m.markerType,
                        if (m.description.trim().isNotEmpty)
                          m.description.trim(),
                        '${_fmtCoord(m.position)}  ·  ${_fmtDate(m.createdAt)}',
                      ];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: color.withOpacity(0.15),
                          child: Icon(Icons.pin_drop, color: color),
                        ),
                        title: Text(
                          m.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          lines.join('\n'),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        isThreeLine: lines.length > 2,
                        onTap: () {
                          Navigator.pop(context);
                          widget.onLocate(m);
                        },
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) async {
                            if (value == 'locate') {
                              Navigator.pop(context);
                              widget.onLocate(m);
                            } else if (value == 'edit') {
                              await widget.onEdit(m);
                              if (mounted) setState(() {});
                            } else if (value == 'delete') {
                              final ok = await confirmDeleteSavedMarker(
                                context,
                                m,
                              );
                              if (!ok) return;
                              await widget.onDelete(m);
                              if (mounted) setState(() {});
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'locate',
                              child: ListTile(
                                leading: Icon(Icons.map, color: Colors.blue),
                                title: Text('Map එකේ බලන්න'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            PopupMenuItem(
                              value: 'edit',
                              child: ListTile(
                                leading: Icon(Icons.edit),
                                title: Text('Edit'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: ListTile(
                                leading: Icon(Icons.delete, color: Colors.red),
                                title: Text('Delete'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Delete confirmation
// ---------------------------------------------------------------------------
Future<bool> confirmDeleteSavedMarker(
  BuildContext context,
  SavedMarker marker,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Marker එක Delete කරන්නද?'),
      content: Text('"${marker.name}" ස්ථිරවම ඉවත් වේ.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('නැහැ'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return result ?? false;
}

// ---------------------------------------------------------------------------
// Add / edit dialog
// ---------------------------------------------------------------------------
Future<SavedMarkerDraft?> showSavedMarkerEditorDialog({
  required BuildContext context,
  required LatLng position,
  required Map<String, Color> typeColors,
  required Map<String, String> typeLabels,
  SavedMarker? existing,
}) {
  return showDialog<SavedMarkerDraft>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SavedMarkerEditorDialog(
      position: position,
      typeColors: typeColors,
      typeLabels: typeLabels,
      existing: existing,
    ),
  );
}

class _SavedMarkerEditorDialog extends StatefulWidget {
  final LatLng position;
  final Map<String, Color> typeColors;
  final Map<String, String> typeLabels;
  final SavedMarker? existing;

  const _SavedMarkerEditorDialog({
    required this.position,
    required this.typeColors,
    required this.typeLabels,
    this.existing,
  });

  @override
  State<_SavedMarkerEditorDialog> createState() =>
      _SavedMarkerEditorDialogState();
}

class _SavedMarkerEditorDialogState extends State<_SavedMarkerEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late String _type;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
    _descCtrl = TextEditingController(text: widget.existing?.description ?? '');
    _type = widget.existing?.markerType ?? 'general';
    if (!widget.typeColors.containsKey(_type)) _type = 'general';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'කරුණාකර නමක් ඇතුළත් කරන්න!');
      return;
    }
    Navigator.pop(
      context,
      SavedMarkerDraft(
        name: name,
        description: _descCtrl.text.trim(),
        markerType: _type,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'නව Marker එකක්' : 'Marker සංස්කරණය',
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
            Row(
              children: [
                const Icon(Icons.place, size: 16, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  _fmtCoord(widget.position),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
              decoration: InputDecoration(
                labelText: 'නම / ස්ථානය (Name)',
                border: const OutlineInputBorder(),
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descCtrl,
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
              children: widget.typeColors.keys.map((typeKey) {
                final color = widget.typeColors[typeKey]!;
                final selected = _type == typeKey;
                return GestureDetector(
                  onTap: () => setState(() => _type = typeKey),
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
                        Icon(Icons.pin_drop, color: color, size: 18),
                        const SizedBox(width: 5),
                        Text(
                          widget.typeLabels[typeKey] ?? typeKey,
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
          child: const Text('අවලංගු කරන්න', style: TextStyle(color: Colors.red)),
        ),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.teal,
            foregroundColor: Colors.white,
          ),
          child: const Text('සුරකින්න (Save)'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Details sheet shown when a saved marker is tapped on the map
// ---------------------------------------------------------------------------
Future<void> showSavedMarkerDetailsSheet({
  required BuildContext context,
  required SavedMarker marker,
  required Map<String, Color> typeColors,
  required Map<String, String> typeLabels,
  required String coordinateText,
  required VoidCallback onEdit,
  required VoidCallback onDelete,
}) {
  final color = typeColors[marker.markerType] ?? Colors.red;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
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
                    marker.name,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.teal,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.18),
                    border: Border.all(color: color),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    typeLabels[marker.markerType] ?? marker.markerType,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (marker.description.trim().isNotEmpty)
              Text(marker.description, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 12),
            Text(coordinateText, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 2),
            Text(
              'සුරකින ලද්දේ: ${_fmtDate(marker.createdAt)}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const Divider(height: 30),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit'),
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    onEdit();
                  },
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.delete),
                  label: const Text('Delete'),
                  onPressed: () async {
                    final ok = await confirmDeleteSavedMarker(
                      sheetContext,
                      marker,
                    );
                    if (!ok) return;
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                    onDelete();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

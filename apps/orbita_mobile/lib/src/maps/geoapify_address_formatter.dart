/// Короткая подпись из известных частей Geoapify, без региона, страны и индекса.
/// Отсутствующие улица и дом не восстанавливаются из свободного текста.
String? formatGeoapifyAddress(Map<dynamic, dynamic> row) {
  String? locality;
  for (final key in ['city', 'town', 'village', 'hamlet']) {
    locality = _text(row[key]);
    if (locality != null) break;
  }
  final street = _text(row['street']);
  final house = _text(row['housenumber']);
  final parts = <String>[
    ?locality,
    if (street != null) _streetCaption(street),
    // Без улицы номер дома сам по себе неоднозначен.
    if (street != null && house != null) house,
  ];
  if (parts.isNotEmpty) {
    final label = parts.join(', ');
    return label.length <= 500 ? label : null;
  }
  // Старые и неполные ответы могут не содержать структурированных частей.
  // Используем только короткие подписи. Не разбираем их по запятым и не
  // придумываем компоненты адреса из свободного текста.
  return _text(row['address_line1']) ?? _text(row['name']);
}

String? _text(dynamic value) {
  if (value is! String || value.length > 500) return null;
  final text = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  return text.isEmpty ? null : text;
}

String _streetCaption(String street) {
  final type = RegExp(
    r'^(улица|переулок|проспект|проезд|шоссе|набережная|бульвар|площадь|тупик|аллея|тракт|дорога|линия)\s',
    caseSensitive: false,
  ).firstMatch(street);
  if (type == null) return street;
  return '${type.group(1)!.toLowerCase()}${street.substring(type.group(1)!.length)}';
}

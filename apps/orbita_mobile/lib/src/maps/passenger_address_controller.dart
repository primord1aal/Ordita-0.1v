import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'address_models.dart';
import 'geoapify_service.dart';
import 'map_settings.dart';

class AddressDraft {
  String text = '';
  AddressPlace? place;
  List<AddressPlace> suggestions = const [];
  String? message;
  bool busy = false, searched = false;
}

/// Черновик живёт только в текущем пассажирском интерфейсе, не на диске/сервере.
class PassengerAddressController extends ChangeNotifier {
  PassengerAddressController(
    this.settings, {
    AddressService Function(String)? serviceFactory,
    this.debounce = const Duration(milliseconds: 500),
  }) : _factory = serviceFactory ?? ((key) => GeoapifyAddressService(key)) {
    _key = settings.clientKey;
    _service = _factory(_key);
    settings.addListener(_configurationChanged);
  }
  final MapSettings settings;
  final AddressService Function(String) _factory;
  final Duration debounce;
  late AddressService _service;
  late String _key;
  final pickup = AddressDraft(), destination = AddressDraft();
  AddressField activeField = AddressField.pickup;
  bool _enabled = true, _disposed = false;
  bool _foreground = true;
  int _generation = 0;
  Timer? _timer;
  bool get enabled => _enabled && _foreground && !_disposed;
  bool get foreground => _foreground && !_disposed;
  AddressDraft draft(AddressField field) =>
      field == AddressField.pickup ? pickup : destination;
  void setEnabled(bool value, {bool foreground = true}) {
    if ((_enabled == value && _foreground == foreground) || _disposed) return;
    _enabled = value;
    _foreground = foreground;
    if (!enabled) _cancel();
    // Маршрут выбора точки находится вне поддерева AuthScreen. Изменение
    // полномочий действует немедленно; его перерисовка ждёт конца текущего build.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  void focus(AddressField field) {
    if (!enabled) return;
    if (activeField != field) _cancel();
    activeField = field;
    final item = draft(field);
    if (item.place == null &&
        item.text.trim().length >= 3 &&
        item.suggestions.isEmpty) {
      _schedule(field);
    }
    notifyListeners();
  }

  void edit(AddressField field, String value) {
    if (!enabled) return;
    final item = draft(field);
    if (item.text == value) return;
    _cancel();
    activeField = field;
    item
      ..text = value
      ..place = null
      ..suggestions = const []
      ..message = null
      ..searched = false;
    _schedule(field);
    notifyListeners();
  }

  void _schedule(AddressField field) {
    _timer?.cancel();
    final item = draft(field);
    if (enabled && settings.configured && item.text.trim().length >= 3) {
      _timer = Timer(debounce, () => searchNow(field));
    }
  }

  Future<void> searchNow(AddressField field) async {
    if (!enabled) return;
    _cancel();
    activeField = field;
    final item = draft(field), query = draft(field).text.trim();
    if (!settings.configured || query.length < 3 || query.length > 250) {
      notifyListeners();
      return;
    }
    final generation = _generation;
    item
      ..busy = true
      ..message = null
      ..suggestions = const []
      ..searched = false;
    notifyListeners();
    try {
      final results = await _service.search(query);
      if (!_current(generation)) return;
      item
        ..suggestions = results
        ..searched = true;
      if (results.isEmpty) item.message = 'Адрес не найден. Уточните населённый пункт или выберите точку на карте.';
    } on MapFailure catch (failure) {
      if (_current(generation)) item.message = failure.message;
    } catch (_) {
      if (_current(generation)) {
        item.message = const MapFailure(MapFailureKind.unavailable).message;
      }
    } finally {
      if (_current(generation)) {
        item.busy = false;
        notifyListeners();
      }
    }
  }

  void select(AddressField field, AddressPlace place) {
    if (!enabled || !place.point.valid) return;
    _cancel();
    activeField = field;
    draft(field)
      ..text = place.label
      ..place = place
      ..suggestions = const []
      ..message = null
      ..searched = false;
    notifyListeners();
  }

  Future<String?> previewPoint(GeoPoint point) async {
    if (!enabled || !point.valid) {
      throw const MapFailure(MapFailureKind.cancelled);
    }
    _cancel();
    final generation = _generation;
    if (!settings.configured) {
      throw const MapFailure(MapFailureKind.configuration);
    }
    final label = await _service.reverse(point);
    if (!_current(generation)) {
      throw const MapFailure(MapFailureKind.cancelled);
    }
    return label;
  }

  void cancelPointPreview() {
    if (!_disposed) _cancel();
  }

  Future<void> choosePoint(
    AddressField field,
    GeoPoint point, {
    String? address,
  }) async {
    if (!enabled || !point.valid) return;
    select(field, AddressPlace(address ?? 'Точка на карте', point));
    if (address != null) return;
    final item = draft(field), generation = _generation;
    if (!settings.configured) return;
    item.busy = true;
    notifyListeners();
    try {
      final label = await _service.reverse(point);
      if (!_current(generation)) return;
      if (label != null) {
        // Обратный поиск подписывает именно выбранную точку, не переносит её на соседний дом.
        item
          ..text = label
          ..place = AddressPlace(label, point);
      } else {
        item.message = 'Адрес у точки не найден. Точка сохранена в черновике.';
      }
    } on MapFailure catch (failure) {
      if (_current(generation)) {
        item.message = '${failure.message} Выбранная точка сохранена.';
      }
    } catch (_) {
      if (_current(generation)) {
        item.message = 'Не удалось уточнить адрес. Выбранная точка сохранена.';
      }
    } finally {
      if (_current(generation)) {
        item.busy = false;
        notifyListeners();
      }
    }
  }

  bool _current(int generation) => enabled && generation == _generation;
  void _cancel() {
    _generation++;
    _timer?.cancel();
    _service.cancel();
    pickup.busy = destination.busy = false;
  }

  void _configurationChanged() {
    if (_disposed || settings.clientKey == _key) return;
    _cancel();
    _service.close();
    _key = settings.clientKey;
    _service = _factory(_key);
    pickup.suggestions = destination.suggestions = const [];
    pickup.message = destination.message = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    settings.removeListener(_configurationChanged);
    _cancel();
    _service.close();
    super.dispose();
  }
}

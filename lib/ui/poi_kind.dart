import 'package:flutter/material.dart';
import '../models/poi.dart';

/// What sort of place a POI is — drives the map icon and the label on its card.
enum PoiKind {
  church,
  museum,
  castle,
  monument,
  fountain,
  street,
  square,
  park,
  water,
  viewpoint,
  artwork,
  theatre,
  library,
  tower,
  station,
  building,
  other,
}

extension PoiKindInfo on PoiKind {
  IconData get icon {
    switch (this) {
      case PoiKind.church:
        return Icons.church;
      case PoiKind.museum:
        return Icons.museum;
      case PoiKind.castle:
        return Icons.castle;
      case PoiKind.monument:
        return Icons.account_balance;
      case PoiKind.fountain:
        return Icons.water_drop;
      case PoiKind.street:
        return Icons.edit_road;
      case PoiKind.square:
        return Icons.groups;
      case PoiKind.park:
        return Icons.park;
      case PoiKind.water:
        return Icons.waves;
      case PoiKind.viewpoint:
        return Icons.landscape;
      case PoiKind.artwork:
        return Icons.palette;
      case PoiKind.theatre:
        return Icons.theater_comedy;
      case PoiKind.library:
        return Icons.local_library;
      case PoiKind.tower:
        return Icons.fort;
      case PoiKind.station:
        return Icons.train;
      case PoiKind.building:
        return Icons.apartment;
      case PoiKind.other:
        return Icons.place;
    }
  }

  String get label {
    switch (this) {
      case PoiKind.church:
        return 'Храм';
      case PoiKind.museum:
        return 'Музей';
      case PoiKind.castle:
        return 'Замок / палац';
      case PoiKind.monument:
        return 'Пам\'ятник';
      case PoiKind.fountain:
        return 'Фонтан';
      case PoiKind.street:
        return 'Вулиця';
      case PoiKind.square:
        return 'Площа';
      case PoiKind.park:
        return 'Парк';
      case PoiKind.water:
        return 'Водойма';
      case PoiKind.viewpoint:
        return 'Оглядовий майданчик';
      case PoiKind.artwork:
        return 'Мистецтво';
      case PoiKind.theatre:
        return 'Театр';
      case PoiKind.library:
        return 'Бібліотека';
      case PoiKind.tower:
        return 'Вежа';
      case PoiKind.station:
        return 'Вокзал';
      case PoiKind.building:
        return 'Будівля';
      case PoiKind.other:
        return 'Цікаве місце';
    }
  }
}

/// OSM tags are the reliable source; the name is the fallback (static POIs have no tags).
PoiKind poiKindOf(Poi poi) =>
    _fromTags(poi.osmTags ?? const {}) ?? _fromName(poi.name) ?? PoiKind.other;

PoiKind? _fromTags(Map<String, String> t) {
  if (t.isEmpty) return null;
  final amenity = t['amenity'];
  final tourism = t['tourism'];
  final historic = t['historic'];
  final building = t['building'];
  final manMade = t['man_made'];
  final leisure = t['leisure'];
  final natural = t['natural'];
  final highway = t['highway'];

  if (amenity == 'fountain') return PoiKind.fountain;
  if (amenity == 'place_of_worship' ||
      amenity == 'monastery' ||
      const {'church', 'cathedral', 'chapel', 'synagogue', 'mosque', 'bell_tower'}.contains(building) ||
      historic == 'monastery' ||
      manMade == 'cross') {
    return PoiKind.church;
  }
  if (tourism == 'museum' || tourism == 'gallery') return PoiKind.museum;
  if (amenity == 'theatre' || amenity == 'cinema' || amenity == 'arts_centre') return PoiKind.theatre;
  if (amenity == 'library') return PoiKind.library;
  if (const {'castle', 'palace', 'manor', 'fort'}.contains(historic) ||
      const {'castle', 'palace', 'manor'}.contains(building)) {
    return PoiKind.castle;
  }
  if (const {'tower', 'water_tower', 'lighthouse', 'windmill'}.contains(manMade) ||
      historic == 'city_gate' ||
      building == 'tower' ||
      historic == 'tower') {
    return PoiKind.tower;
  }
  if (tourism == 'viewpoint') return PoiKind.viewpoint;
  if (tourism == 'artwork' || amenity == 'public_art') return PoiKind.artwork;
  if (const {'monument', 'memorial', 'statue', 'wayside_cross', 'wayside_shrine', 'obelisk'}.contains(historic) ||
      const {'obelisk', 'monument'}.contains(manMade)) {
    return PoiKind.monument;
  }
  if (const {'park', 'garden', 'nature_reserve'}.contains(leisure) ||
      const {'tree', 'wood'}.contains(natural)) {
    return PoiKind.park;
  }
  if (const {'water', 'spring'}.contains(natural)) return PoiKind.water;
  if (t['railway'] != null) return PoiKind.station;
  if (highway != null && t['name'] != null) return PoiKind.street;
  if (t['place'] == 'square' || t['highway'] == 'pedestrian' && t['area'] == 'yes') {
    return PoiKind.square;
  }
  if (building != null || historic == 'building' || historic == 'ruins' || t['heritage'] != null) {
    return PoiKind.building;
  }
  return null;
}

PoiKind? _fromName(String name) {
  final n = name.toLowerCase();
  bool has(List<String> words) => words.any(n.contains);

  if (has(['фонтан'])) return PoiKind.fountain;
  if (has(['церква', 'собор', 'костел', 'каплиц', 'монастир', 'храм', 'синагог', 'лавра', 'церкв'])) {
    return PoiKind.church;
  }
  if (has(['музей', 'галере'])) return PoiKind.museum;
  if (has(['театр', 'опера', 'філармон'])) return PoiKind.theatre;
  if (has(['бібліотек'])) return PoiKind.library;
  if (has(['замок', 'палац', 'цитадел'])) return PoiKind.castle;
  if (has(['вежа', 'башта', 'брама'])) return PoiKind.tower;
  if (has(['пам\'ятник', 'памʼятник', 'монумент', 'меморіал', 'скульптур', 'обеліск'])) {
    return PoiKind.monument;
  }
  if (has(['вокзал', 'станці'])) return PoiKind.station;
  if (has(['площа', 'пл.', 'ринок'])) return PoiKind.square;
  if (has(['вулиц', 'вул.', 'проспект', 'бульвар', 'провулок', 'алея', 'узвіз'])) return PoiKind.street;
  if (has(['парк', 'сад', 'сквер', 'дерево', 'дуб '])) return PoiKind.park;
  if (has(['озеро', 'став', 'річка', 'джерело'])) return PoiKind.water;
  if (has(['ратуша', 'будинок', 'будівл', 'вілла', 'кам\'яниця', 'готель', 'університет'])) {
    return PoiKind.building;
  }
  return null;
}

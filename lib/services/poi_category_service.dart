import '../models/enriched_poi.dart';

/// Rule-based POI categorization using OSM tags.
///
/// Categories:
/// - historical_building: historic buildings, palaces, gates, ruins
/// - sculpture_memorial: sculptures, monuments, memorials, plaques
/// - nature_park: old trees, gardens, natural features, lakes
/// - fountain_viewpoint_architecture: fountains, viewpoints, gazebos
/// - other: everything else of potential tourist interest
class PoiCategoryService {
  static const historicalBuilding = 'historical_building';
  static const sculptureMemorial = 'sculpture_memorial';
  static const naturePark = 'nature_park';
  static const fountainViewpointArchitecture = 'fountain_viewpoint_architecture';
  static const other = 'other';

  /// Determine the category of a POI based on its OSM tags.
  String categorize(Map<String, String> tags) {
    final historic = tags['historic'];
    final tourism = tags['tourism'];
    final amenity = tags['amenity'];
    final leisure = tags['leisure'];
    final building = tags['building'];
    final manMade = tags['man_made'];
    final natural = tags['natural'];

    // 1. Sculptures & Memorials
    if (_isSculptureMemorial(historic, tourism, amenity, manMade)) {
      return sculptureMemorial;
    }

    // 2. Historical Buildings
    if (_isHistoricalBuilding(historic, building, tourism, amenity)) {
      return historicalBuilding;
    }

    // 3. Nature & Parks
    if (_isNaturePark(leisure, natural, tags)) {
      return naturePark;
    }

    // 4. Fountains, Viewpoints, Architecture
    if (_isFountainViewpoint(amenity, tourism, manMade, tags)) {
      return fountainViewpointArchitecture;
    }

    return other;
  }

  /// Determine research priority based on tags and category.
  ResearchPriority determinePriority(Map<String, String> tags, String category) {
    // HIGH: objects with wikidata ID, historic landmarks, major attractions
    final wikidata = tags['wikidata'];
    if (wikidata != null && wikidata.isNotEmpty) return ResearchPriority.high;
    final wikipedia = tags['wikipedia'];
    if (wikipedia != null && wikipedia.isNotEmpty) return ResearchPriority.high;
    if (category == historicalBuilding) return ResearchPriority.high;
    if (tags['tourism'] == 'attraction') return ResearchPriority.high;
    if (tags['historic'] == 'castle' ||
        tags['historic'] == 'palace' ||
        tags['historic'] == 'monument') return ResearchPriority.high;
    final heritage = tags['heritage'];
    if (heritage != null && heritage.isNotEmpty && heritage != 'no') return ResearchPriority.high;

    // MEDIUM: sculptures, viewpoints, named features
    if (category == sculptureMemorial) return ResearchPriority.medium;
    if (category == fountainViewpointArchitecture) return ResearchPriority.medium;
    if (tags['tourism'] == 'viewpoint') return ResearchPriority.medium;
    if (tags['tourism'] == 'artwork') return ResearchPriority.medium;

    // LOW: unnamed or generic features
    if (tags['name'] == null) return ResearchPriority.low;
    if (category == other) return ResearchPriority.low;

    return ResearchPriority.medium;
  }

  bool _isSculptureMemorial(
      String? historic, String? tourism, String? amenity, String? manMade) {
    const sculptureTags = {
      'memorial', 'monument', 'bust', 'memorial_plaque',
      'memorial_cross', 'memorial_stone', 'memorial_plate',
    };
    if (historic != null && sculptureTags.contains(historic)) return true;
    if (tourism == 'artwork') return true;
    if (amenity == 'public_art') return true;
    if (manMade == 'obelisk') return true;
    return false;
  }

  bool _isHistoricalBuilding(
      String? historic, String? building, String? tourism, String? amenity) {
    const historicBuildings = {
      'castle', 'palace', 'manor', 'fort', 'city_gate',
      'ruins', 'archaeological_site', 'building', 'tower',
      'church', 'monastery', 'convent', 'cathedral', 'yes',
    };
    if (historic != null && historicBuildings.contains(historic)) return true;
    if (tourism == 'museum') return true;
    // place_of_worship can be a node without building tag
    if (amenity == 'place_of_worship') return true;
    const historicBuilding = {
      'church', 'cathedral', 'synagogue', 'mosque', 'castle',
      'palace', 'manor',
    };
    if (building != null && historicBuilding.contains(building)) return true;
    return false;
  }

  bool _isNaturePark(
      String? leisure, String? natural, Map<String, String> tags) {
    const natureLeisure = {'garden', 'park', 'nature_reserve'};
    if (leisure != null && natureLeisure.contains(leisure)) return true;
    const natureTags = {
      'tree', 'wood', 'water', 'spring', 'lake', 'pond',
      'peak', 'rock', 'cliff', 'cave_entrance',
    };
    if (natural != null && natureTags.contains(natural)) return true;
    if (tags['boundary'] == 'protected_area') return true;
    return false;
  }

  bool _isFountainViewpoint(
      String? amenity, String? tourism, String? manMade,
      Map<String, String> tags) {
    if (amenity == 'fountain') return true;
    if (tags['historic'] == 'fountain') return true;
    if (tourism == 'viewpoint') return true;
    if (manMade == 'tower') return true; // observation towers
    if (tags['building'] == 'gazebo') return true;
    if (tags['leisure'] == 'bandstand') return true;
    return false;
  }
}

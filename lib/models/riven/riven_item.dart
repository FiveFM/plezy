import 'package:json_annotation/json_annotation.dart';

import '../../media/media_kind.dart';

part 'riven_item.g.dart';

/// Where Riven is with a title (`program/media/state.py` `States`), in
/// pipeline order: indexed for metadata, scraped for releases, downloaded to
/// the debrid service, symlinked into the library mount.
enum RivenItemState {
  unknown('Unknown'),
  unreleased('Unreleased'),
  ongoing('Ongoing'),
  requested('Requested'),
  indexed('Indexed'),
  scraped('Scraped'),
  downloaded('Downloaded'),
  symlinked('Symlinked'),
  completed('Completed'),
  partiallyCompleted('PartiallyCompleted'),
  failed('Failed'),
  paused('Paused');

  final String wire;
  const RivenItemState(this.wire);

  /// An unrecognized name falls back to [unknown], which offers no actions
  /// and is not polled: nothing is claimed about a state this client does
  /// not understand.
  static RivenItemState fromWire(String? value) => values.where((v) => v.wire == value).firstOrNull ?? unknown;

  /// Riven is still moving the title toward a playable file, so a screen
  /// showing it should keep re-reading. [indexed] can sit for days waiting
  /// on a release date, which costs one cheap read per poll while open.
  bool get isInProgress => switch (this) {
    requested || indexed || scraped || downloaded || symlinked => true,
    _ => false,
  };

  /// The file is in the library mount; the media server only has to scan it.
  bool get isAvailable => this == completed || this == partiallyCompleted || this == ongoing;
}

/// A movie or show Riven tracks, as `GET /api/v1/items` reports it.
///
/// Every id arrives as a string (`"id": "6702"`, `"tmdb_id": "1368337"`).
/// Shows are keyed by TVDB and usually carry no TMDB id at all.
@JsonSerializable(createToJson: false)
class RivenItem {
  @JsonKey(fromJson: _parseId)
  final int id;
  final String? title;
  final String? type;
  @JsonKey(fromJson: RivenItemState.fromWire)
  final RivenItemState state;
  @JsonKey(name: 'imdb_id')
  final String? imdbId;
  @JsonKey(name: 'tmdb_id')
  final String? tmdbId;
  @JsonKey(name: 'tvdb_id')
  final String? tvdbId;

  /// Absolute artwork URL (TMDB for movies, TheTVDB for shows).
  @JsonKey(name: 'poster_path')
  final String? posterUrl;

  @JsonKey(name: 'requested_at', fromJson: _parseTimestamp)
  final DateTime? requestedAt;

  /// Release date for a movie, first air date for a show.
  @JsonKey(name: 'aired_at', fromJson: _parseTimestamp)
  final DateTime? airedAt;

  /// The indexer's genres, lowercased by Riven (`science fiction`).
  final List<String>? genres;

  /// TMDB vote average for movies; null for shows indexed through TVDB.
  final double? rating;
  @JsonKey(name: 'content_rating')
  final String? contentRating;

  const RivenItem({
    required this.id,
    this.title,
    this.type,
    required this.state,
    this.imdbId,
    this.tmdbId,
    this.tvdbId,
    this.posterUrl,
    this.requestedAt,
    this.airedAt,
    this.genres,
    this.rating,
    this.contentRating,
  });

  MediaKind get kind => switch (type) {
    'movie' => MediaKind.movie,
    'show' => MediaKind.show,
    'season' => MediaKind.season,
    'episode' => MediaKind.episode,
    _ => MediaKind.unknown,
  };

  factory RivenItem.fromJson(Map<String, dynamic> json) => _$RivenItemFromJson(json);
}

/// One page of `GET /api/v1/items`, newest request first.
@JsonSerializable(createToJson: false)
class RivenItemPage {
  final List<RivenItem> items;
  final int page;
  @JsonKey(name: 'total_pages')
  final int totalPages;
  @JsonKey(name: 'total_items')
  final int totalItems;

  const RivenItemPage({required this.items, required this.page, required this.totalPages, required this.totalItems});

  bool get hasMore => page < totalPages;

  factory RivenItemPage.fromJson(Map<String, dynamic> json) => _$RivenItemPageFromJson(json);
}

int _parseId(Object? value) => switch (value) {
  final int id => id,
  final String id => int.parse(id),
  _ => throw FormatException('Riven item id is not numeric: $value'),
};

/// Riven serializes naive server-local datetimes with Python's `str()`
/// (`2026-10-17 18:39:38.729835`) and missing ones as the string `None`.
DateTime? _parseTimestamp(Object? value) => value is String ? DateTime.tryParse(value) : null;

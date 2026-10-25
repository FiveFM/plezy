// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'riven_item.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

RivenItem _$RivenItemFromJson(Map<String, dynamic> json) => RivenItem(
  id: _parseId(json['id']),
  title: json['title'] as String?,
  type: json['type'] as String?,
  state: RivenItemState.fromWire(json['state'] as String?),
  imdbId: json['imdb_id'] as String?,
  tmdbId: json['tmdb_id'] as String?,
  tvdbId: json['tvdb_id'] as String?,
  posterUrl: json['poster_path'] as String?,
  requestedAt: _parseTimestamp(json['requested_at']),
);

RivenItemPage _$RivenItemPageFromJson(Map<String, dynamic> json) =>
    RivenItemPage(
      items: (json['items'] as List<dynamic>)
          .map((e) => RivenItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      page: (json['page'] as num).toInt(),
      totalPages: (json['total_pages'] as num).toInt(),
      totalItems: (json['total_items'] as num).toInt(),
    );

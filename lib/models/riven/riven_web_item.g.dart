// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'riven_web_item.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

RivenTmdbItem _$RivenTmdbItemFromJson(Map<String, dynamic> json) =>
    RivenTmdbItem(
      id: (json['id'] as num).toInt(),
      title: json['title'] as String?,
      mediaType: json['media_type'] as String?,
      year: _parseYear(json['year']),
      overview: json['overview'] as String?,
      voteAverage: (json['vote_average'] as num?)?.toDouble(),
      voteCount: (json['vote_count'] as num?)?.toInt(),
      popularity: (json['popularity'] as num?)?.toDouble(),
      posterUrl: json['poster_path'] as String?,
      backdropUrl: json['backdrop_path'] as String?,
      releaseDate: json['release_date'] as String?,
      firstAirDate: json['first_air_date'] as String?,
      originalTitle: json['original_title'] as String?,
      originalLanguage: json['original_language'] as String?,
    );

RivenTmdbPage _$RivenTmdbPageFromJson(Map<String, dynamic> json) =>
    RivenTmdbPage(
      results: (json['results'] as List<dynamic>)
          .map((e) => RivenTmdbItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      page: (json['page'] as num?)?.toInt(),
      totalPages: (json['total_pages'] as num?)?.toInt(),
      totalResults: (json['total_results'] as num?)?.toInt(),
    );

RivenAnimeItem _$RivenAnimeItemFromJson(Map<String, dynamic> json) =>
    RivenAnimeItem(
      id: (json['id'] as num).toInt(),
      title: json['title'] as String?,
      posterUrl: json['poster_path'] as String?,
      format: json['media_type'] as String?,
      year: (json['year'] as num?)?.toInt(),
    );

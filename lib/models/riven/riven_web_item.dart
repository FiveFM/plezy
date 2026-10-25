import 'package:json_annotation/json_annotation.dart';

part 'riven_web_item.g.dart';

/// A title from the Riven web app's TMDB proxy, in the shape its
/// `transformTMDBList` gives every list (trending, discover, search): TMDB's
/// own fields with the artwork paths already made absolute.
@JsonSerializable(createToJson: false)
class RivenTmdbItem {
  final int id;
  final String? title;

  /// `movie` or `tv`; search and discover answers also carry people and
  /// companies, which are not titles.
  @JsonKey(name: 'media_type')
  final String? mediaType;

  /// Release year, or the string `N/A` when TMDB has no date.
  @JsonKey(fromJson: _parseYear)
  final int? year;
  final String? overview;
  @JsonKey(name: 'vote_average')
  final double? voteAverage;
  @JsonKey(name: 'vote_count')
  final int? voteCount;
  final double? popularity;

  /// Absolute TMDB URLs: posters at `w500`, backdrops at `w1280`.
  @JsonKey(name: 'poster_path')
  final String? posterUrl;
  @JsonKey(name: 'backdrop_path')
  final String? backdropUrl;
  @JsonKey(name: 'release_date')
  final String? releaseDate;
  @JsonKey(name: 'first_air_date')
  final String? firstAirDate;
  @JsonKey(name: 'original_title')
  final String? originalTitle;
  @JsonKey(name: 'original_language')
  final String? originalLanguage;

  const RivenTmdbItem({
    required this.id,
    this.title,
    this.mediaType,
    this.year,
    this.overview,
    this.voteAverage,
    this.voteCount,
    this.popularity,
    this.posterUrl,
    this.backdropUrl,
    this.releaseDate,
    this.firstAirDate,
    this.originalTitle,
    this.originalLanguage,
  });

  factory RivenTmdbItem.fromJson(Map<String, dynamic> json) => _$RivenTmdbItemFromJson(json);
}

/// One page of the web app's TMDB proxy. Trending answers carry only
/// [results]; discover and search add TMDB's paging.
@JsonSerializable(createToJson: false)
class RivenTmdbPage {
  final List<RivenTmdbItem> results;
  final int? page;
  @JsonKey(name: 'total_pages')
  final int? totalPages;
  @JsonKey(name: 'total_results')
  final int? totalResults;

  const RivenTmdbPage({required this.results, this.page, this.totalPages, this.totalResults});

  factory RivenTmdbPage.fromJson(Map<String, dynamic> json) => _$RivenTmdbPageFromJson(json);
}

/// An anime from the web app's AniList trending proxy, which keeps only
/// these fields of AniList's media object.
@JsonSerializable(createToJson: false)
class RivenAnimeItem {
  /// AniList id.
  final int id;
  final String? title;
  @JsonKey(name: 'poster_path')
  final String? posterUrl;

  /// AniList `format`: `TV`, `TV_SHORT`, `MOVIE`, `SPECIAL`, `OVA`, `ONA`, `MUSIC`.
  @JsonKey(name: 'media_type')
  final String? format;

  /// AniList `seasonYear`.
  final int? year;

  const RivenAnimeItem({required this.id, this.title, this.posterUrl, this.format, this.year});

  factory RivenAnimeItem.fromJson(Map<String, dynamic> json) => _$RivenAnimeItemFromJson(json);
}

int? _parseYear(Object? value) => switch (value) {
  final int year => year,
  final String year => int.tryParse(year),
  _ => null,
};

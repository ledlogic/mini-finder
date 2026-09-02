# url_helpers.rb
# URL builder helpers — all methods that construct URLs for routes or external sites.
# Loaded by app.rb via: require_relative 'url_helpers'
# All methods are prefixed with url_

helpers do

  # Build a URL query string from a hash, skipping blank values
  # e.g. url_query(folder: 'x', page: 2) -> "folder=x&page=2"
  def url_query(h)
    h.reject { |_, v| v.to_s.empty? }.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join('&')
  end

  # Returns the current filter query string (all active catalog filters)
  # Use this for any prev/next/page link that should preserve filters
  def catalog_filter_qs(extra = {})
    parts = {}
    parts[:show_all]      = '1'                if @show_all
    parts[:folder]        = @folder_filter      unless @folder_filter.to_s.empty?
    parts[:f_untagged]    = '1'                if @f_untagged
    parts[:f_unprinted]   = '1'                if @f_unprinted
    parts[:f_unpainted]   = '1'                if @f_unpainted
    parts[:f_no_size]     = '1'                if @f_no_size
    parts[:f_no_weapons]  = '1'                if @f_no_weapons
    parts[:f_no_stance]   = '1'                if @f_no_stance
    parts[:f_no_species]  = '1'                if @f_no_species
    parts[:f_no_vehicles] = '1'                if @f_no_vehicles
    parts[:f_no_robots]   = '1'                if @f_no_robots
    parts[:f_no_bundles]  = '1'                if @f_no_bundles
    parts[:colorized]     = @colorized_catalog  unless @colorized_catalog.to_s.empty?
    parts.merge!(extra)
    qs = url_query(parts)
    qs.empty? ? '' : '?' + qs
  end

  # App route URL for streaming a collection PDF
  def url_pdf(collection_id)
    "/pdf/#{collection_id}"
  end

  # Build a /random page URL preserving all current filters
  def url_random(colorized: @colorized_filter, no_bundles: @no_bundles, no_vehicles: @no_vehicles, no_robots: @no_robots, no_drones: @no_drones, unprinted: @unprinted_only, printed: @printed_only, n: @random_count)
    qs = { colorized:   colorized,
           no_bundles:  (no_bundles  ? '1' : nil),
           no_vehicles: (no_vehicles ? '1' : nil),
           no_robots:   (no_robots   ? '1' : nil),
           no_drones:   (no_drones   ? '1' : nil),
           unprinted:   (unprinted   ? '1' : nil),
           printed:     (printed     ? '1' : nil),
           n:           (n != 60     ? n   : nil) }
          .reject { |_, v| v.to_s.empty? }.map { |k, v| "#{k}=#{v}" }.join('&')
    qs.empty? ? '/random' : "/random?#{qs}"
  end

  # Build a /collections page URL preserving year, status filter, and sort
  def url_collections(filter: @filter, year: @year_filter, sort: @sort_order)
    parts = []
    parts << "filter=#{filter}" unless filter.to_s.empty?
    parts << "year=#{year}"     unless year.to_s.empty?
    parts << "sort=#{sort}"     if sort.to_s == 'asc'
    parts.empty? ? '/collections' : "/collections?#{parts.join('&')}"
  end

  # Build a MyMiniFactory search URL for a given YYYY-MM release month
  def url_mmf_search(release_month)
    return nil unless release_month && release_month.match(/^\d{4}-\d{2}$/)
    year, month = release_month.split("-").map(&:to_i)
    month_name  = MONTH_NAMES[month - 1]
    short_year  = year.to_s[-2..]
    query       = "unit9 #{month_name}#{short_year}"
    json        = %Q({"searchString":"#{query}","categories":[],"designType":"premium-only","sortingKey":"relevance","tags":[]})
    encoded     = json.gsub('{', '%7B').gsub('}', '%7D')
                      .gsub('"'  , '%22').gsub(' '  , '%20')
                      .gsub('['  , '%5B').gsub(']'  , '%5D')
                      .gsub(':'  , '%3A').gsub(','  , '%2C')
    "https://www.myminifactory.com/search#/?#{encoded}"
  end

end

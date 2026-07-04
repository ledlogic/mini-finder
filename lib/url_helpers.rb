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

  # App route URL for streaming a collection PDF
  def url_pdf(collection_id)
    "/pdf/#{collection_id}"
  end

  # Build a /random page URL preserving all current filters
  def url_random(colorized: @colorized_filter, no_bundles: @no_bundles, no_vehicles: @no_vehicles, unprinted: @unprinted_only, n: @random_count)
    qs = { colorized:   colorized,
           no_bundles:  (no_bundles  ? '1' : nil),
           no_vehicles: (no_vehicles ? '1' : nil),
           unprinted:   (unprinted   ? '1' : nil),
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

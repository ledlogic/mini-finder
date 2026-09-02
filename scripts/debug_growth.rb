#!/usr/bin/env ruby
# Debug script: find images where printed > printable in a given period
# Run from project root: ruby scripts/debug_growth.rb

require 'dotenv/load'
require 'sequel'

DB_PATH = File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db')
DB = Sequel.sqlite(DB_PATH)

all_images = DB[:images]
  .where(primary_image_id: nil)
  .where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
  .exclude(Sequel.ilike(:mini_name, 'bundle'))
  .select(:id, :collection_id, :created_at, :printed, :painted, :colorized, :mini_name)
  .all

collections_map = DB[:collections].select(:id, :release_month, :folder_path)
  .each_with_object({}) { |c, h| h[c[:id]] = c }

release_date_for_col = lambda do |col|
  folder = File.basename(col[:folder_path].to_s)
  if (m = folder.match(/^(\d{4})-(\d{2})/))
    "#{m[1]}-#{m[2]}-02"
  end
end

by_collection = all_images.group_by { |img| img[:collection_id] }

by_period = Hash.new { |h, k| h[k] = { printable: 0, printed: 0, imgs: [] } }

by_collection.each do |col_id, imgs|
  col = collections_map[col_id]
  next unless col
  date_str = release_date_for_col.call(col)
  next unless date_str
  key = date_str[0..6]  # YYYY-MM

  imgs.each do |img|
    if img[:colorized] == false
      by_period[key][:printable] += 1
      if img[:printed].to_i > 0
        by_period[key][:printed] += 1
        by_period[key][:imgs] << { id: img[:id], name: img[:mini_name], printed: img[:printed], col: File.basename(col[:folder_path]) }
      end
    end
  end
end

puts "%-12s %10s %10s %9s" % ['Period', 'Printable', 'Printed', '% Printed']
puts "-" * 90

cum_printable = 0
cum_printed   = 0

by_period.keys.sort.each do |k|
  cum_printable += by_period[k][:printable]
  cum_printed   += by_period[k][:printed]
  pct = cum_printable > 0 ? (cum_printed * 100.0 / cum_printable).round(1) : 0
  flag = pct > 100 ? " ⚠ OVER 100%" : ""
  puts "%-12s %10d %10d %8.1f%%%s" % [k, cum_printable, cum_printed, pct, flag]
end

puts ""
puts "Total printable: #{cum_printable}"
puts "Total printed:   #{cum_printed}"
puts "Overall %:       #{cum_printable > 0 ? (cum_printed * 100.0 / cum_printable).round(1) : 0}%"

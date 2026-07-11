#!/usr/bin/env ruby
# Report field usage % across images and collections tables.
# Highlights fields with low fill rates so you can decide what to prune.
#
# Run from project root:
#   ruby scripts/field_usage_report.rb
#   ruby scripts/field_usage_report.rb --threshold 50   # flag fields below 50%

require 'dotenv/load'
require 'sequel'

DB_PATH  = File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db')
DB       = Sequel.sqlite(DB_PATH)
THRESHOLD = (ARGV.find { |a| a =~ /^\d+$/ } || '25').to_i

def filled?(val)
  return false if val.nil?
  return false if val.is_a?(String) && val.strip.empty?
  true
end

def report_table(table_name, skip_cols: [])
  rows  = DB[table_name].all
  total = rows.size
  return if total == 0

  cols = rows.first.keys - skip_cols
  puts "━━━ #{table_name} (#{total} rows) ━━━"

  results = cols.map do |col|
    filled = rows.count { |r| filled?(r[col]) }
    pct    = (filled.to_f / total * 100).round(1)
    [col, filled, pct]
  end

  results.sort_by { |_, _, pct| pct }.each do |col, filled, pct|
    bar    = ('█' * (pct / 5).round).ljust(20)
    flag   = pct < THRESHOLD ? '  ⚠ LOW' : ''
    puts "  %-22s %6.1f%%  #{bar}  (%d/%d)#{flag}" % [col, pct, filled, total]
  end
  puts ""
end

puts "mini-finder: field usage report"
puts "DB:        #{DB_PATH}"
puts "Threshold: #{THRESHOLD}% (fields below this are flagged ⚠)"
puts "Date:      #{Time.now.strftime('%Y-%m-%d %H:%M')}"
puts ""

report_table(:images, skip_cols: [:id, :collection_id, :source_folder, :filename, :created_at, :updated_at])
report_table(:collections, skip_cols: [:id, :folder_path, :created_at, :updated_at])

puts "Done. Run with a number arg to change threshold, e.g.: ruby scripts/field_usage_report.rb 50"

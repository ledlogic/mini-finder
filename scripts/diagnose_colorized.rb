#!/usr/bin/env ruby
# Diagnose colorized field values for images in a given folder pattern
# Run from project root: ruby scripts/diagnose_colorized.rb [folder_pattern]
# Examples:
#   ruby scripts/diagnose_colorized.rb 2021
#   ruby scripts/diagnose_colorized.rb 2021-01
#   ruby scripts/diagnose_colorized.rb          # shows all

require 'dotenv/load'
require 'sequel'

DB_PATH = File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db')
DB = Sequel.sqlite(DB_PATH)

pattern = ARGV[0] || ''
folder_like = "%#{pattern}%"

puts "mini-finder: colorized diagnostic"
puts "DB:      #{DB_PATH}"
puts "Pattern: #{pattern.empty? ? '(all)' : folder_like}"
puts ""

rows = DB[:images]
  .join(:collections, id: :collection_id)
  .where(Sequel.ilike(Sequel[:collections][:folder_path], folder_like))
  .where(Sequel[:images][:primary_image_id] => nil)
  .exclude(Sequel.ilike(Sequel[:images][:mini_name], 'bundle'))
  .where(Sequel.expr { Sequel[:images][:mini_count] < 4 } | Sequel.expr(Sequel[:images][:mini_count] => nil))
  .select(
    Sequel[:images][:id],
    Sequel[:images][:colorized],
    Sequel[:images][:mini_count],
    Sequel[:images][:mini_name],
    Sequel[:collections][:folder_path]
  )
  .all

puts "Total matching images: #{rows.length}"
puts ""

# Group by colorized value
tally = rows.group_by { |r| r[:colorized].inspect }
tally.each do |val, group|
  puts "colorized = #{val}: #{group.length} images"
end

puts ""
puts "Sample rows (first 15):"
puts "%-6s %-12s %-6s %-30s %s" % ['id', 'colorized', 'count', 'name', 'folder']
puts "-" * 90
rows.first(15).each do |r|
  folder = File.basename(r[:folder_path].to_s)
  puts "%-6s %-12s %-6s %-30s %s" % [
    r[:id],
    r[:colorized].inspect,
    r[:mini_count].to_s,
    r[:mini_name].to_s[0..29],
    folder
  ]
end

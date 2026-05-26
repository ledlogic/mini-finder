require 'sequel'

DB = Sequel.sqlite('db/catalog.db')

ids = DB[:images].limit(3).select_map(:id)
puts "Found ids: #{ids.inspect}"

ids.each_with_index do |id, i|
  name = i == 1 ? 'Kunoichi Sisters' : 'Ash Shepherd'
  rows = DB[:images].where(id: id).update(mini_name: name, tagged: 1)
  puts "Updated id #{id} with '#{name}' — #{rows} row(s) affected"
end

# Verify
DB[:images].where(id: ids).each do |r|
  puts "#{r[:id]}: #{r[:mini_name]} tagged=#{r[:tagged]}"
end
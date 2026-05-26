require 'sequel'

DB = Sequel.sqlite('db/catalog.db')

deleted_images = DB[:images]
  .where(Sequel.~(Sequel.like(:source_folder, '%Cyberdreams%')))
  .delete
puts "Deleted #{deleted_images} stale image records"

puts "Done"
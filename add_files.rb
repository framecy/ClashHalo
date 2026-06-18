require 'xcodeproj'
project_path = 'ClashPow.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'ClashPow' }

sources_group = project.main_group.find_subpath('Sources', true)
model_group = sources_group.find_subpath('Model', true)
ui_group = sources_group.find_subpath('UI', true)
subs_group = ui_group.find_subpath('Subscriptions', true)
# Ensure the Subscriptions group has the correct path
subs_group.set_path('Subscriptions')

eng_file = model_group.new_file('SubStoreEngine.swift')
target.source_build_phase.add_file_reference(eng_file)

page_file = subs_group.new_file('SubStorePage.swift')
target.source_build_phase.add_file_reference(page_file)

panels_substore = project.main_group.new_reference('Resources/Panels/sub-store')
panels_substore.last_known_file_type = 'folder'
target.resources_build_phase.add_file_reference(panels_substore, true)

bin_substore = project.main_group.new_file('Resources/bin/sub-store-backend')
target.resources_build_phase.add_file_reference(bin_substore, true)

project.save
puts "Successfully added files to Xcode project!"

# Copyright (c) 2020 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "xcodeproj"

require_relative "utils"
require_relative "error"
require_relative "settings"
require_relative "xcodeproj_extensions"

class Array
  # Converts an array of arrays of size 2 into a multimap, mapping the first element of each
  # subarray to an array of the last elements it appears with in the same subarray.
  def to_multi_h
    raise ArgumentError, "Not all elements are arrays of size 2" unless all? do |arr|
      arr.is_a?(Array) && arr.count == 2
    end

    group_by(&:first).transform_values { |group| group.map(&:last) }
  end
end

module Kintsugi
  class << self
    # Applies the change specified by `change` to `project`.
    #
    # @param  [Xcodeproj::Project] project
    #         Project to which to apply the change.
    #
    # @param  [Hash] change
    #         Change to apply to `project`. Assumed to be in the format emitted by
    #         Xcodeproj::Differ#project_diff where its `key_1` and `key_2` parameters have values of
    #         `:added` and `:removed` respectively.
    #
    # @return [void]
    def apply_change_to_project(project, change, base_project)
      return unless change&.key?("rootObject")

      # We iterate over the main group and project references first because they might create file
      # or project references that are referenced in other parts.
      unless change["rootObject"]["mainGroup"].nil?
        if project.root_object.main_group.nil?
          puts "Warning: Main group doesn't exist, ignoring changes to it."
        else
          apply_main_group_change(project, change["rootObject"]["mainGroup"])
        end
      end

      unless change["rootObject"]["projectReferences"].nil?
        apply_change_to_component(project.root_object, "projectReferences",
                                  change["rootObject"]["projectReferences"], "rootObject")
      end

      apply_change_to_component(project, "rootObject",
                                change["rootObject"].reject { |key|
                                  %w[mainGroup projectReferences].include?(key)
                                }, "")
    end

    private

    def apply_main_group_change(project, main_group_change)
      additions, removals, diffs = classify_group_and_file_changes(main_group_change, "")
      apply_group_additions(project, additions)
      apply_file_changes(project, additions, removals)
      apply_group_and_file_diffs(project, diffs)
      apply_group_removals(project, removals)
    end

    def classify_group_and_file_changes(change, path)
      children_changes = change["children"] || {}
      removals = flatten_change(children_changes[:removed], path)
      additions = flatten_change(children_changes[:added], path)
      diffs = [[change, path]]
      subchanges_of_change(children_changes).each do |key, subchange|
        sub_additions, sub_removals, sub_diffs =
          classify_group_and_file_changes(subchange, join_path(path, key))
        removals += sub_removals
        additions += sub_additions
        diffs += sub_diffs
      end

      [additions, removals, diffs]
    end

    def flatten_change(change, path)
      entries = (change || []).map do |child|
        [child, path]
      end
      group_entries = entries.map do |group, _|
        next if group["children"].nil?

        flatten_change(group["children"], join_path(path, group["displayName"]))
      end.compact.flatten(1)
      entries + group_entries
    end

    def apply_group_additions(project, additions)
      additions.each do |change, path|
        next unless %w[PBXGroup PBXVariantGroup].include?(change["isa"])

        group_type = Module.const_get("Xcodeproj::Project::#{change["isa"]}")
        containing_group = project.group_from_path(path)

        if containing_group.nil?
          raise MergeError, "Trying to add or move a group with change #{change} to a group that " \
            "no longer exists with path '#{path}'. This is considered a conflict that should be " \
            "resolved manually."
        end

        next if !Settings.allow_duplicates &&
          !find_group_in_group(containing_group, group_type, change).nil?

        new_group = project.new(group_type)
        containing_group.children << new_group
        add_attributes_to_component(new_group, change, path, ignore_keys: ["children"])
      end
    end

    def find_group_in_group(group, instance_type, change)
      group
        .children
        .select { |child| child.instance_of?(instance_type) }
        .find do |child_group|
          child_group.display_name == change["displayName"] && child_group.path == change["path"]
        end
    end

    def apply_file_changes(project, additions, removals)
      def file_reference_key(change)
        [change["name"], change["path"], change["sourceTree"]]
      end

      file_additions = additions.select { |change, _| change["isa"] == "PBXFileReference" }
      file_removals = removals.select { |change, _| change["isa"] == "PBXFileReference" }

      addition_keys_to_paths = file_additions
                               .map { |change, path| [file_reference_key(change), path] }
                               .to_multi_h
      removal_keys_to_references = file_removals.to_multi_h.map do |change, paths|
        references = paths.map do |containing_path|
          project[join_path(containing_path, change["displayName"])]
        end

        [file_reference_key(change), references]
      end.to_h

      file_additions.each do |change, path|
        containing_group = project.group_from_path(path)
        change_key = file_reference_key(change)

        if containing_group.nil?
          raise MergeError, "Trying to add or move a file with change #{change} to a group that " \
            "no longer exists with path '#{path}'. This is considered a conflict that should be " \
            "resolved manually."
        end

        if (removal_keys_to_references[change_key] || []).empty?
          apply_file_addition(containing_group, change, "rootObject/mainGroup/#{path}")
        elsif addition_keys_to_paths[change_key].length == 1 &&
            removal_keys_to_references[change_key].length == 1 &&
            !removal_keys_to_references[change_key].first.nil?
          removal_keys_to_references[change_key].first.move(containing_group)
        else
          file_path = join_path(path, change["displayName"])
          raise MergeError,
                "Cannot deduce whether the file #{file_path} is new, or was moved to its new place"
        end
      end

      file_removals.each do |change, path|
        next unless addition_keys_to_paths[file_reference_key(change)].nil?

        file_reference = project[join_path(path, change["displayName"])]
        remove_component(file_reference, change)
      end
    end

    def apply_file_addition(containing_group, change, path)
      return if !Settings.allow_duplicates &&
        !find_file_in_group(containing_group, Xcodeproj::Project::PBXFileReference,
                            change["path"]).nil?

      file_reference = containing_group.project.new(Xcodeproj::Project::PBXFileReference)
      containing_group.children << file_reference

      # For some reason, `include_in_index` is set to `1` and `source_tree` to `SDKROOT` by
      # default.
      file_reference.include_in_index = nil
      file_reference.source_tree = nil
      add_attributes_to_component(file_reference, change, path)
    end

    def apply_group_and_file_diffs(project, diffs)
      diffs.each do |change, path|
        component = project[path]

        next if component.nil?

        change.each do |subchange_name, subchange|
          next if subchange_name == "children"

          apply_change_to_component(component, subchange_name, subchange, path)
        end
      end
    end

    def apply_group_removals(project, removals)
      removals.sort_by(&:last).reverse.each do |change, path|
        next unless %w[PBXGroup PBXVariantGroup].include?(change["isa"])

        group_path = join_path(path, change["displayName"])

        # by now we've deleted all of this group's children in the project, so we need to adapt the
        # change to the expected current state of the group, that is, without any children.
        change_without_children = change.dup
        change_without_children["children"] = []

        remove_component(project[group_path], change_without_children)
      end
    end

    def apply_change_to_component(parent_component, change_name, change, parent_change_path)
      return if change_name == "displayName"

      change_path = join_path(parent_change_path, change_name)

      attribute_name = attribute_name_from_change_name(change_name)
      if simple_attribute?(parent_component, attribute_name)
        apply_change_to_simple_attribute(parent_component, attribute_name, change)
        return
      end

      if change["isa"]
        component = replace_component_with_new_type(parent_component, attribute_name, change)
        change = change_for_component_of_new_type(component, change)
      else
        component = child_component(parent_component, change, change_name)
      end

      if change[:removed].is_a?(Hash)
        remove_component(component, change[:removed])
      elsif change[:removed].is_a?(Array)
        unless component.nil?
          (change[:removed]).each do |removed_change|
            child = child_component_of_object_list(component, removed_change,
                                                   removed_change["displayName"])
            remove_component(child, removed_change)
          end
        end
      elsif !change[:removed].nil?
        raise MergeError, "Unsupported removed change type for #{change[:removed]}"
      end

      if change[:added].is_a?(Hash)
        add_child_to_component(parent_component, change[:added], change_path)
      elsif change[:added].is_a?(Array)
        (change[:added]).each do |added_change|
          add_child_to_component(parent_component, added_change, change_path)
        end
      elsif !change[:added].nil?
        raise MergeError, "Unsupported added change type for #{change[:added]}"
      end

      subchanges_of_change(change).each do |subchange_name, subchange|
        if component.nil?
          raise MergeError, "Trying to apply changes to a component that doesn't exist at path " \
            "#{change_path}. It was probably removed in a previous commit. This is considered a " \
            "conflict that should be resolved manually."
        end

        apply_change_to_component(component, subchange_name, subchange, change_path)
      end
    end

    def subchanges_of_change(change)
      if change.key?(:diff)
        change[:diff]
      else
        change.reject { |change_name, _| %i[added removed].include?(change_name) }
      end
    end

    def attribute_name_from_change_name(change_name)
      if %w[fileEncoding repositoryURL].include?(change_name)
        change_name.to_sym
      else
        Xcodeproj::Project::Object::CaseConverter.convert_to_ruby(change_name)
      end
    end

    def replace_component_with_new_type(parent_component, name_in_parent_component, change)
      old_component = parent_component.send(name_in_parent_component)
      new_component = component_of_new_type(parent_component, change, old_component)

      copy_attributes_to_new_component(old_component, new_component)

      parent_component.send("#{name_in_parent_component}=", new_component)
      new_component
    end

    def component_of_new_type(parent_component, change, old_component)
      if change["isa"][:added] == "PBXFileReference"
        path = (change["path"] && change["path"][:added]) || old_component.path
        case parent_component
        when Xcodeproj::Project::XCBuildConfiguration
          parent_component.base_configuration_reference = find_file(parent_component.project, path)
          return parent_component.base_configuration_reference
        when Xcodeproj::Project::PBXNativeTarget
          parent_component.product_reference = find_file(parent_component.project, path)
          return parent_component.product_reference
        when Xcodeproj::Project::PBXBuildFile
          parent_component.file_ref = find_file(parent_component.project, path)
          return parent_component.file_ref
        end
      end

      parent_component.project.new(
        Module.const_get("Xcodeproj::Project::#{change["isa"][:added]}")
      )
    end

    def copy_attributes_to_new_component(old_component, new_component)
      # The change won't describe the attributes that haven't changed, therefore the attributes
      # are copied to the new component.
      old_component.attributes.each do |attribute|
        next if %i[isa display_name].include?(attribute.name) ||
          !new_component.respond_to?(attribute.name)

        new_component.send("#{attribute.name}=", old_component.send(attribute.name))
      end
    end

    def change_for_component_of_new_type(new_component, change)
      change.select do |subchange_name, _|
        next false if subchange_name == "isa"

        attribute_name = attribute_name_from_change_name(subchange_name)
        new_component.respond_to?(attribute_name)
      end
    end

    def child_component(component, change, change_name)
      if component.is_a?(Xcodeproj::Project::ObjectList)
        child_component_of_object_list(component, change, change_name)
      else
        attribute_name = attribute_name_from_change_name(change_name)
        component.send(attribute_name)
      end
    end

    def child_component_of_object_list(component, change, change_name)
      if change["isa"] == "PBXReferenceProxy"
        find_reference_proxy_in_component(component, change["remoteRef"])
      else
        component.find { |child| child.display_name == change_name }
      end
    end

    def simple_attribute?(component, attribute_name)
      return false unless component.respond_to?("simple_attributes")

      component.simple_attributes.any? { |attribute| attribute.name == attribute_name }
    end

    def apply_change_to_simple_attribute(component, attribute_name, change)
      new_attribute_value =
        simple_attribute_value_with_change(component.send(attribute_name), change)
      component.send("#{attribute_name}=", new_attribute_value)
    end

    def simple_attribute_value_with_change(old_value, change)
      type = simple_attribute_type(old_value, change[:removed], change[:added])
      new_value = new_simple_attribute_value(type, old_value, change[:removed], change[:added])

      subchanges_of_change(change).each do |subchange_name, subchange_value|
        new_value = new_value || old_value || {}
        new_value[subchange_name] =
          simple_attribute_value_with_change(old_value[subchange_name], subchange_value)
      end

      new_value
    end

    def simple_attribute_type(old_value, removed_change, added_change)
      types = [old_value.class, removed_change.class, added_change.class]

      if types.include?(Hash)
        unless types.to_set.subset?([Hash, NilClass].to_set)
          raise MergeError, "Cannot apply changes because the types are not compatible. Existing " \
            "value: '#{old_value}', removed change: '#{removed_change}', added change: " \
            "'#{added_change}'"
        end
        Hash
      elsif types.include?(Array)
        unless types.to_set.subset?([Array, String, NilClass].to_set)
          raise MergeError, "Cannot apply changes because the types are not compatible. Existing " \
            "value: '#{old_value}', removed change: '#{removed_change}', added change: " \
            "'#{added_change}'"
        end
        Array
      elsif types.include?(String)
        unless types.to_set.subset?([String, NilClass].to_set)
          raise MergeError, "Cannot apply changes because the types are not compatible. Existing " \
            "value: '#{old_value}', removed change: '#{removed_change}', added change: " \
            "'#{added_change}'"
        end
        String
      else
        raise MergeError, "Unsupported types of all of the values. Existing value: " \
          "'#{old_value}', removed change: '#{removed_change}', added change: '#{added_change}'"
      end
    end

    def new_simple_attribute_value(type, old_value, removed_change, added_change)
      if type == Hash
        new_hash_simple_attribute_value(old_value, removed_change, added_change)
      elsif type == Array
        new_array_simple_attribute_value(old_value, removed_change, added_change)
      elsif type == String
        new_string_simple_attribute_value(old_value, removed_change, added_change)
      else
        raise MergeError, "Unsupported types of all of the values. Existing value: " \
          "'#{old_value}', removed change: '#{removed_change}', added change: '#{added_change}'"
      end
    end

    def new_hash_simple_attribute_value(old_value, removed_change, added_change)
      return added_change if ((old_value || {}).to_a - (removed_change || {}).to_a).empty?

      # First apply the added change to see if there are any conflicts with it.
      new_value = (old_value || {}).merge(added_change || {})

      unless (old_value.to_a - new_value.to_a).empty?
        raise MergeError, "New hash #{change} contains values that conflict with old hash " \
          "#{old_value}"
      end

      if removed_change.nil?
        return new_value
      end

      new_value
        .reject do |key, value|
          if value != removed_change[key] && value != (added_change || {})[key]
            raise MergeError, "Trying to remove value '#{removed_change[key]}' of hash with key " \
              "'#{key}' but it changed to #{value}. This is considered a conflict that should be " \
              "resolved manually."
          end

          removed_change.key?(key)
        end
    end

    def new_array_simple_attribute_value(old_value, removed_change, added_change)
      if old_value.is_a?(String)
        old_value = [old_value]
      end
      if removed_change.is_a?(String)
        removed_change = [removed_change]
      end
      if added_change.is_a?(String)
        added_change = [added_change]
      end

      return added_change if ((old_value || []) - (removed_change || [])).empty?

      new_value = (old_value || []) - (removed_change || [])
      filtered_added_change = if Settings.allow_duplicates
                                (added_change || [])
                              else
                                (added_change || []).reject { |added| new_value.include?(added) }
                              end

      new_value + filtered_added_change
    end

    def new_string_simple_attribute_value(old_value, removed_change, added_change)
      if old_value != removed_change && !old_value.nil? && added_change != old_value
        raise MergeError, "Trying to remove value '#{removed_change || "nil"}', but the existing " \
          "value is '#{old_value}'. This is considered a conflict that should be resolved manually."
      end

      added_change
    end

    def remove_component(component, change)
      return if component.nil?

      if component.to_tree_hash != change
        raise MergeError, "Trying to remove an object that changed since then. This is " \
          "considered a conflict that should be resolved manually. Name of the object is: " \
          "'#{component.display_name}'. Existing component: #{component.to_tree_hash}. " \
          "Change: #{change}"
      end

      if change["isa"] == "PBXFileReference"
        remove_build_files_of_file_reference(component, change)
      end

      component.remove_from_project
    end

    def remove_build_files_of_file_reference(file_reference, change)
      # Since the build file's display name depends on the file reference, removing the file
      # reference before removing it will change the build file's display name which will not be
      # detected when trying to remove the build file. Therefore, the build files that depend on
      # the file reference are removed prior to removing the file reference.
      file_reference.build_files.each do |build_file|
        build_file.referrers.each do |referrer|
          referrer.remove_build_file(build_file)
        end
      end
    end

    def add_child_to_component(component, change, component_change_path)
      change_path = join_path(component_change_path, change["displayName"])

      if change["ProjectRef"] && change["ProductGroup"]
        add_subproject_reference(component, change, change_path)
        return
      end

      case change["isa"]
      when "PBXNativeTarget"
        add_target(component, change, change_path)
      when "PBXAggregateTarget"
        add_aggregate_target(component, change, change_path)
      when "PBXFileReference"
        add_file_reference(component, change, change_path)
      when "PBXGroup"
        add_group(component, change, change_path)
      when "PBXContainerItemProxy"
        add_container_item_proxy(component, change, change_path)
      when "PBXTargetDependency"
        add_target_dependency(component, change, change_path)
      when "PBXBuildFile"
        add_build_file(component, change, change_path)
      when "XCConfigurationList"
        add_build_configuration_list(component, change, change_path)
      when "XCBuildConfiguration"
        add_build_configuration(component, change, change_path)
      when "PBXHeadersBuildPhase"
        add_headers_build_phase(component, change, change_path)
      when "PBXSourcesBuildPhase"
        add_sources_build_phase(component, change, change_path)
      when "PBXCopyFilesBuildPhase"
        add_copy_files_build_phase(component, change, change_path)
      when "PBXShellScriptBuildPhase"
        add_shell_script_build_phase(component, change, change_path)
      when "PBXFrameworksBuildPhase"
        add_frameworks_build_phase(component, change, change_path)
      when "PBXResourcesBuildPhase"
        add_resources_build_phase(component, change, change_path)
      when "PBXBuildRule"
        add_build_rule(component, change, change_path)
      when "PBXVariantGroup"
        add_variant_group(component, change, change_path)
      when "PBXReferenceProxy"
        add_reference_proxy(component, change, change_path)
      when "XCSwiftPackageProductDependency"
        add_swift_package_product_dependency(component, change, change_path)
      when "XCRemoteSwiftPackageReference"
        add_remote_swift_package_reference(component, change, change_path)
      else
        raise MergeError, "Trying to add unsupported component type #{change["isa"]}. Full " \
          "component change is: #{change}"
      end
    end

    def add_remote_swift_package_reference(containing_component, change, change_path)
      remote_swift_package_reference =
        containing_component.project.new(Xcodeproj::Project::XCRemoteSwiftPackageReference)
      add_attributes_to_component(remote_swift_package_reference, change, change_path)

      case containing_component
      when Xcodeproj::Project::XCSwiftPackageProductDependency
        containing_component.package = remote_swift_package_reference
      when Xcodeproj::Project::PBXProject
        containing_component.package_references << remote_swift_package_reference
      else
        raise MergeError, "Trying to add remote swift package reference to an unsupported " \
          "component type #{containing_component.isa}. Change is: #{change}"
      end
    end

    def add_swift_package_product_dependency(containing_component, change, change_path)
      swift_package_product_dependency =
        containing_component.project.new(Xcodeproj::Project::XCSwiftPackageProductDependency)
      add_attributes_to_component(swift_package_product_dependency, change, change_path)

      case containing_component
      when Xcodeproj::Project::PBXBuildFile
        containing_component.product_ref = swift_package_product_dependency
      when Xcodeproj::Project::PBXNativeTarget
        containing_component.package_product_dependencies << swift_package_product_dependency
      else
        raise MergeError, "Trying to add swift package product dependency to an unsupported " \
          "component type #{containing_component.isa}. Change is: #{change}"
      end
    end

    def add_reference_proxy(containing_component, change, change_path)
      case containing_component
      when Xcodeproj::Project::PBXBuildFile
        # If there are two file references that refer to the same file, one with a build file and
        # the other one without, this method will prefer to take the one without the build file.
        # This assumes that it's preferred to have a file reference with build file than a file
        # reference without/with two build files.
        filter_references_without_build_files = lambda do |reference|
          reference.referrers.find do |referrer|
            referrer.is_a?(Xcodeproj::Project::PBXBuildFile)
          end.nil?
        end
        file_reference =
          find_reference_proxy(containing_component.project, change["remoteRef"],
                               reference_filter: filter_references_without_build_files)
        if file_reference.nil?
          file_reference = find_reference_proxy(containing_component.project, change["remoteRef"])
        end
        containing_component.file_ref = file_reference
      when Xcodeproj::Project::PBXGroup
        return if !Settings.allow_duplicates &&
          !find_file_in_group(containing_component, Xcodeproj::Project::PBXReferenceProxy,
                              change["path"]).nil?

        reference_proxy = containing_component.project.new(Xcodeproj::Project::PBXReferenceProxy)
        containing_component << reference_proxy
        add_attributes_to_component(reference_proxy, change, change_path)
      else
        raise MergeError, "Trying to add reference proxy to an unsupported component type " \
          "#{containing_component.isa}. Change is: #{change}"
      end
    end

    def add_variant_group(containing_component, change, change_path)
      case containing_component
      when Xcodeproj::Project::PBXBuildFile
        containing_component.file_ref =
          find_variant_group(containing_component.project, change["displayName"])
      when Xcodeproj::Project::PBXGroup, Xcodeproj::Project::PBXVariantGroup
        if find_group_in_group(containing_component, Xcodeproj::Project::PBXVariantGroup,
                               change).nil?
          raise "Group should have been added already, so this is most likely a bug in Kintsugi" \
            "Change is: #{change}. Change path: #{change_path}"
        end
      else
        raise MergeError, "Trying to add variant group to an unsupported component type " \
          "#{containing_component.isa}. Change is: #{change}"
      end
    end

    def add_build_rule(target, change, change_path)
      build_rule = target.project.new(Xcodeproj::Project::PBXBuildRule)
      target.build_rules << build_rule
      add_attributes_to_component(build_rule, change, change_path)
    end

    def add_shell_script_build_phase(target, change, change_path)
      build_phase = target.new_shell_script_build_phase(change["displayName"])
      add_attributes_to_component(build_phase, change, change_path)
    end

    def add_headers_build_phase(target, change, change_path)
      add_attributes_to_component(target.headers_build_phase, change, change_path)
    end

    def add_sources_build_phase(target, change, change_path)
      add_attributes_to_component(target.source_build_phase, change, change_path)
    end

    def add_frameworks_build_phase(target, change, change_path)
      add_attributes_to_component(target.frameworks_build_phase, change, change_path)
    end

    def add_resources_build_phase(target, change, change_path)
      add_attributes_to_component(target.resources_build_phase, change, change_path)
    end

    def add_copy_files_build_phase(target, change, change_path)
      copy_files_phase_name = change["displayName"] == "CopyFiles" ? nil : change["displayName"]
      copy_files_phase = target.new_copy_files_build_phase(copy_files_phase_name)

      add_attributes_to_component(copy_files_phase, change, change_path)
    end

    def add_build_configuration_list(target, change, change_path)
      target.build_configuration_list = target.project.new(Xcodeproj::Project::XCConfigurationList)
      add_attributes_to_component(target.build_configuration_list, change, change_path)
    end

    def add_build_configuration(configuration_list, change, change_path)
      build_configuration = configuration_list.project.new(Xcodeproj::Project::XCBuildConfiguration)
      configuration_list.build_configurations << build_configuration
      add_attributes_to_component(build_configuration, change, change_path)
    end

    def add_build_file(build_phase, change, change_path)
      if change["fileRef"].nil?
        puts "Warning: Trying to add a build file without any file reference to build phase " \
          "'#{build_phase}'"
        return
      end

      existing_build_file = build_phase.files.find do |build_file|
        build_file.file_ref && build_file.file_ref.path == change["fileRef"]["path"]
      end
      return if !Settings.allow_duplicates && !existing_build_file.nil?

      build_file = build_phase.project.new(Xcodeproj::Project::PBXBuildFile)
      build_phase.files << build_file
      add_attributes_to_component(build_file, change, change_path)
    end

    def find_variant_group(project, display_name)
      project.objects.find do |object|
        object.isa == "PBXVariantGroup" && object.display_name == display_name
      end
    end

    def add_target_dependency(target, change, change_path)
      target_dependency = find_target(target.project, change["displayName"])

      if target_dependency
        target.add_dependency(target_dependency)
        return
      end

      target_dependency = target.project.new(Xcodeproj::Project::PBXTargetDependency)

      target.dependencies << target_dependency
      add_attributes_to_component(target_dependency, change, change_path)
    end

    def find_target(project, display_name)
      project.targets.find { |target| target.display_name == display_name }
    end

    def add_container_item_proxy(component, change, change_path)
      container_proxy = component.project.new(Xcodeproj::Project::PBXContainerItemProxy)
      container_proxy.container_portal = find_containing_project_uuid(component.project, change)

      case component.isa
      when "PBXTargetDependency"
        component.target_proxy = container_proxy
      when "PBXReferenceProxy"
        component.remote_ref = container_proxy
      else
        raise MergeError, "Trying to add container item proxy to an unsupported component type " \
          "#{containing_component.isa}. Change is: #{change}"
      end
      add_attributes_to_component(container_proxy, change, change_path,
                                  ignore_keys: ["containerPortal"])
    end

    def find_containing_project_uuid(project, container_item_proxy_change)
      if project.objects_by_uuid[container_item_proxy_change["containerPortal"]]
        return container_item_proxy_change["containerPortal"]
      end

      # The `containerPortal` from `container_item_proxy_change` might not be relevant, since when a
      # project is added its UUID is generated. Instead, existing container item proxies are
      # searched, until one that has the same remote info as the one in
      # `container_item_proxy_change` is found.
      container_item_proxies =
        project.root_object.project_references.map do |project_ref_and_products|
          project_ref_and_products[:project_ref].proxy_containers.find do |container_proxy|
            container_proxy.remote_info == container_item_proxy_change["remoteInfo"]
          end
        end.compact

      if container_item_proxies.length > 1
        puts "Debug: Found more than one potential dependency with name " \
          "'#{container_item_proxy_change["remoteInfo"]}'. Using the first one."
      elsif container_item_proxies.empty?
        puts "Warning: No container portal was found for dependency with name " \
          "'#{container_item_proxy_change["remoteInfo"]}'."
        return
      end

      container_item_proxies.first.container_portal
    end

    def add_subproject_reference(root_object, project_reference_change, change_path)
      existing_subproject =
        root_object.project_references.find do |project_reference|
          project_reference.project_ref.path == project_reference_change["ProjectRef"]["path"]
        end
      return if !Settings.allow_duplicates && !existing_subproject.nil?

      filter_subproject_without_project_references = lambda do |file_reference|
        root_object.project_references.find do |project_reference|
          project_reference.project_ref.uuid == file_reference.uuid
        end.nil?
      end
      subproject_reference =
        find_file(root_object.project, project_reference_change["ProjectRef"]["path"],
                  file_filter: filter_subproject_without_project_references)

      unless subproject_reference
        raise MergeError, "No file reference was found for project reference with change " \
          "#{project_reference_change}. This might mean that the file used to exist in the " \
          "project the but was removed at some point"
      end

      attribute =
        Xcodeproj::Project::PBXProject.references_by_keys_attributes
                                      .find { |attrb| attrb.name == :project_references }
      project_reference = Xcodeproj::Project::ObjectDictionary.new(attribute, root_object)
      project_reference[:project_ref] = subproject_reference
      root_object.project_references << project_reference

      updated_project_reference_change =
        change_with_updated_subproject_uuid(project_reference_change, subproject_reference.uuid)
      add_attributes_to_component(project_reference, updated_project_reference_change,
                                  change_path, ignore_keys: ["ProjectRef"])
    end

    def change_with_updated_subproject_uuid(change, subproject_reference_uuid)
      new_change = change.deep_clone
      new_change["ProductGroup"]["children"].map do |product_reference_change|
        product_reference_change["remoteRef"]["containerPortal"] = subproject_reference_uuid
        product_reference_change
      end
      new_change
    end

    def add_target(root_object, change, change_path)
      target = root_object.project.new(Xcodeproj::Project::PBXNativeTarget)
      root_object.project.targets << target
      add_attributes_to_component(target, change, change_path)
    end

    def add_aggregate_target(root_object, change, change_path)
      target = root_object.project.new(Xcodeproj::Project::PBXAggregateTarget)
      root_object.project.targets << target
      add_attributes_to_component(target, change, change_path)
    end

    def add_file_reference(containing_component, change, change_path)
      # base configuration reference and product reference always reference a file that exists
      # inside a group, therefore in these cases the file is searched for.
      # In the case of group and variant group, the file can't exist in another group, therefore a
      # new file reference is always created.
      case containing_component
      when Xcodeproj::Project::XCBuildConfiguration
        containing_component.base_configuration_reference =
          find_file(containing_component.project, change["path"])
      when Xcodeproj::Project::PBXNativeTarget
        containing_component.product_reference =
          find_file(containing_component.project, change["path"])
      when Xcodeproj::Project::PBXBuildFile
        containing_component.file_ref = find_file(containing_component.project, change["path"])
      when Xcodeproj::Project::PBXGroup, Xcodeproj::Project::PBXVariantGroup
        if find_file_in_group(containing_component, Xcodeproj::Project::PBXFileReference,
                              change["path"]).nil?
          raise "File should have been added already, so this is most likely a bug in Kintsugi" \
            "Change is: #{change}. Change path: #{change_path}"
        end
      else
        raise MergeError, "Trying to add file reference to an unsupported component type " \
          "#{containing_component.isa}. Change is: #{change}"
      end
    end

    def find_file_in_group(group, instance_type, filepath)
      group
        .children
        .select { |child| child.instance_of?(instance_type) }
        .find { |file| file.path == filepath }
    end

    def adding_files_and_groups_allowed?(change_path)
      change_path.start_with?("rootObject/mainGroup") ||
        change_path.start_with?("rootObject/projectReferences")
    end

    def add_group(containing_component, change, change_path)
      case containing_component
      when Xcodeproj::Project::ObjectDictionary
        # It is assumed that an `ObjectDictionary` always represents a project reference.
        new_group = containing_component[:project_ref].project.new(Xcodeproj::Project::PBXGroup)
        containing_component[:product_group] = new_group
        add_attributes_to_component(new_group, change, change_path)
      when Xcodeproj::Project::PBXGroup
        if find_group_in_group(containing_component, Xcodeproj::Project::PBXGroup, change).nil?
          raise "Group should have been added already, so this is most likely a bug in Kintsugi" \
            "Change is: #{change}. Change path: #{change_path}"
        end
      else
        raise MergeError, "Trying to add group to an unsupported component type " \
          "#{containing_component.isa}. Change is: #{change}. Change path: #{change_path}"
      end
    end

    def add_attributes_to_component(component, change, change_path, ignore_keys: [])
      change.each do |change_name, change_value|
        next if (%w[isa displayName] + ignore_keys).include?(change_name)

        attribute_name = attribute_name_from_change_name(change_name)
        if simple_attribute?(component, attribute_name)
          simple_attribute_change = {
            added: change_value,
            removed: simple_attribute_default_value(component, attribute_name)
          }
          apply_change_to_simple_attribute(component, attribute_name, simple_attribute_change)
          next
        end

        case change_value
        when Hash
          add_child_to_component(component, change_value, change_path)
        when Array
          change_value.each do |added_attribute_element|
            add_child_to_component(component, added_attribute_element, change_path)
          end
        else
          raise MergeError, "Trying to add attribute of unsupported type '#{change_value.class}' " \
            "to object #{component}. Attribute name is '#{change_name}'"
        end
      end
    end

    def simple_attribute_default_value(component, attribute_name)
      component.simple_attributes.find do |attribute|
        attribute.name == attribute_name
      end.default_value
    end

    def find_file(project, path, file_filter: ->(_) { true })
      file_references = project.files.select do |file_reference|
        file_reference.path == path && file_filter.call(file_reference)
      end
      if file_references.length > 1
        puts "Debug: Found more than one matching file with path '#{path}'. Using the first one."
      elsif file_references.empty?
        puts "Debug: No file reference found for file with path '#{path}'."
        return
      end

      file_references.first
    end

    def find_reference_proxy(project, container_item_proxy_change, reference_filter: ->(_) { true })
      reference_proxies = project.root_object.project_references.map do |project_ref_and_products|
        find_reference_proxy_in_component(project_ref_and_products[:product_group].children,
                                          container_item_proxy_change,
                                          reference_filter: reference_filter)
      end.compact

      if reference_proxies.length > 1
        puts "Debug: Found more than one matching reference proxy with name " \
          "'#{container_item_proxy_change["remoteInfo"]}'. Using the first one."
      elsif reference_proxies.empty?
        puts "Warning: No reference proxy was found for name " \
          "'#{container_item_proxy_change["remoteInfo"]}'."
        return
      end

      reference_proxies.first
    end

    def find_reference_proxy_in_component(component, container_item_proxy_change,
                                          reference_filter: ->(_) { true })
      component.find do |product|
        product.remote_ref.remote_global_id_string ==
          container_item_proxy_change["remoteGlobalIDString"] &&
          product.remote_ref.remote_info == container_item_proxy_change["remoteInfo"] &&
          reference_filter.call(product)
      end
    end

    def join_path(left, right)
      left.empty? ? right : "#{left}/#{right}"
    end
  end
end

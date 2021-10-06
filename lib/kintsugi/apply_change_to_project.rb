# Copyright (c) 2020 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "xcodeproj"

require_relative "utils"
require_relative "xcodeproj_extensions"

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
    def apply_change_to_project(project, change)
      # We iterate over the main group and project references first because they might create file
      # or project references that are referenced in other parts.
      unless change["rootObject"]["mainGroup"].nil?
        if project.root_object.main_group.nil?
          puts "Warning: Main group doesn't exist, ignoring changes to it."
        else
          apply_change_to_component(project.root_object, "mainGroup",
                                    change["rootObject"]["mainGroup"])
        end
      end

      unless change["rootObject"]["projectReferences"].nil?
        apply_change_to_component(project.root_object, "projectReferences",
                                  change["rootObject"]["projectReferences"])
      end

      apply_change_to_component(project, "rootObject",
                                change["rootObject"].reject { |key|
                                  %w[mainGroup projectReferences].include?(key)
                                })
    end

    private

    def apply_change_to_component(parent_component, change_name, change)
      return if change_name == "displayName"

      attribute_name = attribute_name_from_change_name(change_name)
      if simple_attribute?(parent_component, attribute_name)
        apply_change_to_simple_attribute(parent_component, attribute_name, change)
        return
      end

      if change["isa"]
        component = replace_component_with_new_type(parent_component, attribute_name, change)
        change = change_for_component_of_new_type(component, change)
      else
        component = child_component(parent_component, change_name)

        if component.nil?
          add_missing_component_if_valid(parent_component, change_name, change)
          return
        end
      end

      (change[:removed] || []).each do |removed_change|
        child = child_component(component, removed_change["displayName"])
        next if child.nil?

        remove_component(child, removed_change)
      end

      (change[:added] || []).each do |added_change|
        is_object_list = component.is_a?(Xcodeproj::Project::ObjectList)
        add_child_to_component(is_object_list ? parent_component : component, added_change)
      end

      subchanges_of_change(change).each do |subchange_name, subchange|
        apply_change_to_component(component, subchange_name, subchange)
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
      if change_name == "fileEncoding"
        change_name.to_sym
      else
        Xcodeproj::Project::Object::CaseConverter.convert_to_ruby(change_name)
      end
    end

    def add_missing_component_if_valid(parent_component, change_name, change)
      if change[:added] && change.compact.count == 1
        add_child_to_component(parent_component, change[:added])
        return
      end

      puts "Warning: Detected change of an object named '#{change_name}' contained in " \
        "'#{parent_component}' but the object doesn't exist. Ignoring this change."
    end

    def replace_component_with_new_type(parent_component, name_in_parent_component, change)
      old_component = parent_component.send(name_in_parent_component)

      new_component = parent_component.project.new(
        Module.const_get("Xcodeproj::Project::#{change["isa"][:added]}")
      )

      copy_attributes_to_new_component(old_component, new_component)

      parent_component.send("#{name_in_parent_component}=", new_component)
      new_component
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

    def child_component(component, change_name)
      if component.is_a?(Xcodeproj::Project::ObjectList)
        component.find { |child| child.display_name == change_name }
      else
        attribute_name = attribute_name_from_change_name(change_name)
        component.send(attribute_name)
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
      new_value = nil

      if change.key?(:removed)
        new_value = apply_removal_to_simple_attribute(old_value, change[:removed])
      end

      if change.key?(:added)
        new_value = apply_addition_to_simple_attribute(old_value, change[:added])
      end

      subchanges_of_change(change).each do |subchange_name, subchange_value|
        new_value = new_value || old_value || {}
        new_value[subchange_name] =
          simple_attribute_value_with_change(old_value[subchange_name], subchange_value)
      end

      new_value
    end

    def apply_removal_to_simple_attribute(old_value, change)
      case change
      when Array
        (old_value || []) - change
      when Hash
        (old_value || {}).reject do |key, value|
          if value != change[key]
            raise "Trying to remove value #{change[key]} of hash with key #{key} but it changed " \
              "to #{value}. This is considered a conflict that should be resolved manually."
          end

          change.key?(key)
        end
      when String
        if old_value != change && !old_value.nil?
          raise "Trying to remove value #{change}, but the existing value is #{old_value}. This " \
            "is considered a conflict that should be resolved manually."
        end

        nil
      when nil
        nil
      else
        raise "Unsupported change #{change} of type #{change.class}"
      end
    end

    def apply_addition_to_simple_attribute(old_value, change)
      case change
      when Array
        (old_value || []) + change
      when Hash
        old_value ||= {}
        new_value = old_value.merge(change)

        unless (old_value.to_a - new_value.to_a).empty?
          raise "New hash #{change} contains values that conflict with old hash #{old_value}"
        end

        new_value
      when String
        change
      when nil
        nil
      else
        raise "Unsupported change #{change} of type #{change.class}"
      end
    end

    def remove_component(component, change)
      if component.to_tree_hash != change
        raise "Trying to remove an object that changed since then. This is considered a conflict " \
          "that should be resolved manually. Name of the object is: '#{component.display_name}'"
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

    def add_child_to_component(component, change)
      if change["ProjectRef"] && change["ProductGroup"]
        add_subproject_reference(component, change)
        return
      end

      case change["isa"]
      when "PBXNativeTarget"
        add_target(component, change)
      when "PBXAggregateTarget"
        add_aggregate_target(component, change)
      when "PBXFileReference"
        add_file_reference(component, change)
      when "PBXGroup"
        add_group(component, change)
      when "PBXContainerItemProxy"
        add_container_item_proxy(component, change)
      when "PBXTargetDependency"
        add_target_dependency(component, change)
      when "PBXBuildFile"
        add_build_file(component, change)
      when "XCConfigurationList"
        add_build_configuration_list(component, change)
      when "XCBuildConfiguration"
        add_build_configuration(component, change)
      when "PBXHeadersBuildPhase"
        add_headers_build_phase(component, change)
      when "PBXSourcesBuildPhase"
        add_sources_build_phase(component, change)
      when "PBXCopyFilesBuildPhase"
        add_copy_files_build_phase(component, change)
      when "PBXShellScriptBuildPhase"
        add_shell_script_build_phase(component, change)
      when "PBXFrameworksBuildPhase"
        add_frameworks_build_phase(component, change)
      when "PBXResourcesBuildPhase"
        add_resources_build_phase(component, change)
      when "PBXBuildRule"
        add_build_rule(component, change)
      when "PBXVariantGroup"
        add_variant_group(component, change)
      when "PBXReferenceProxy"
        add_reference_proxy(component, change)
      else
        raise "Trying to add unsupported component type #{change["isa"]}. Full component change " \
          "is: #{change}"
      end
    end

    def add_reference_proxy(containing_component, change)
      case containing_component
      when Xcodeproj::Project::PBXBuildFile
        containing_component.file_ref = find_file(containing_component.project, change)
      when Xcodeproj::Project::PBXGroup
        reference_proxy = containing_component.project.new(Xcodeproj::Project::PBXReferenceProxy)
        containing_component << reference_proxy
        add_attributes_to_component(reference_proxy, change)
      else
        raise "Trying to add reference proxy to an unsupported component type " \
          "#{containing_component.isa}. Change is: #{change}"
      end
    end

    def add_variant_group(containing_component, change)
      case containing_component
      when Xcodeproj::Project::PBXBuildFile
        containing_component.file_ref =
          find_variant_group(containing_component.project, change["displayName"])
      when Xcodeproj::Project::PBXGroup, Xcodeproj::Project::PBXVariantGroup
        variant_group = containing_component.project.new(Xcodeproj::Project::PBXVariantGroup)
        containing_component.children << variant_group
        add_attributes_to_component(variant_group, change)
      else
        raise "Trying to add variant group to an unsupported component type " \
          "#{containing_component.isa}. Change is: #{change}"
      end
    end

    def add_build_rule(target, change)
      build_rule = target.project.new(Xcodeproj::Project::PBXBuildRule)
      target.build_rules << build_rule
      add_attributes_to_component(build_rule, change)
    end

    def add_shell_script_build_phase(target, change)
      build_phase = target.new_shell_script_build_phase(change["displayName"])
      add_attributes_to_component(build_phase, change)
    end

    def add_headers_build_phase(target, change)
      add_attributes_to_component(target.headers_build_phase, change)
    end

    def add_sources_build_phase(target, change)
      add_attributes_to_component(target.source_build_phase, change)
    end

    def add_frameworks_build_phase(target, change)
      add_attributes_to_component(target.frameworks_build_phase, change)
    end

    def add_resources_build_phase(target, change)
      add_attributes_to_component(target.resources_build_phase, change)
    end

    def add_copy_files_build_phase(target, change)
      copy_files_phase_name = change["displayName"] == "CopyFiles" ? nil : change["displayName"]
      copy_files_phase = target.new_copy_files_build_phase(copy_files_phase_name)

      add_attributes_to_component(copy_files_phase, change)
    end

    def add_build_configuration_list(target, change)
      target.build_configuration_list = target.project.new(Xcodeproj::Project::XCConfigurationList)
      add_attributes_to_component(target.build_configuration_list, change)
    end

    def add_build_configuration(configuration_list, change)
      build_configuration = configuration_list.project.new(Xcodeproj::Project::XCBuildConfiguration)
      configuration_list.build_configurations << build_configuration
      add_attributes_to_component(build_configuration, change)
    end

    def add_build_file(build_phase, change)
      if change["fileRef"].nil?
        puts "Warning: Trying to add a build file without any file reference to build phase " \
          "'#{build_phase}'"
        return
      end

      build_file = build_phase.project.new(Xcodeproj::Project::PBXBuildFile)
      build_phase.files << build_file
      add_attributes_to_component(build_file, change)
    end

    def find_variant_group(project, display_name)
      project.objects.find do |object|
        object.isa == "PBXVariantGroup" && object.display_name == display_name
      end
    end

    def add_target_dependency(target, change)
      target_dependency = find_target(target.project, change["displayName"])

      if target_dependency
        target.add_dependency(target_dependency)
        return
      end

      target_dependency = target.project.new(Xcodeproj::Project::PBXTargetDependency)

      target.dependencies << target_dependency
      add_attributes_to_component(target_dependency, change)
    end

    def find_target(project, display_name)
      project.targets.find { |target| target.display_name == display_name }
    end

    def add_container_item_proxy(component, change)
      container_proxy = component.project.new(Xcodeproj::Project::PBXContainerItemProxy)
      container_proxy.container_portal = find_containing_project_uuid(component.project, change)

      case component.isa
      when "PBXTargetDependency"
        component.target_proxy = container_proxy
      when "PBXReferenceProxy"
        component.remote_ref = container_proxy
      else
        raise "Trying to add container item proxy to an unsupported component type " \
          "#{containing_component.isa}. Change is: #{change}"
      end
      add_attributes_to_component(container_proxy, change, ignore_keys: ["containerPortal"])
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

    def add_subproject_reference(root_object, project_reference_change)
      subproject_reference = find_file(root_object.project, project_reference_change["ProjectRef"])

      attribute =
        Xcodeproj::Project::PBXProject.references_by_keys_attributes
                                      .find { |attrb| attrb.name == :project_references }
      project_reference = Xcodeproj::Project::ObjectDictionary.new(attribute, root_object)
      project_reference[:project_ref] = subproject_reference
      root_object.project_references << project_reference

      updated_project_reference_change =
        change_with_updated_subproject_uuid(project_reference_change, subproject_reference.uuid)
      add_attributes_to_component(project_reference, updated_project_reference_change,
                                  ignore_keys: ["ProjectRef"])
    end

    def change_with_updated_subproject_uuid(change, subproject_reference_uuid)
      new_change = change.deep_clone
      new_change["ProductGroup"]["children"].map do |product_reference_change|
        product_reference_change["remoteRef"]["containerPortal"] = subproject_reference_uuid
        product_reference_change
      end
      new_change
    end

    def add_target(root_object, change)
      target = root_object.project.new(Xcodeproj::Project::PBXNativeTarget)
      root_object.project.targets << target
      add_attributes_to_component(target, change)
    end

    def add_aggregate_target(root_object, change)
      target = root_object.project.new(Xcodeproj::Project::PBXAggregateTarget)
      root_object.project.targets << target
      add_attributes_to_component(target, change)
    end

    def add_file_reference(containing_component, change)
      # base configuration reference and product reference always reference a file that exists
      # inside a group, therefore in these cases the file is searched for.
      # In the case of group and variant group, the file can't exist in another group, therefore a
      # new file reference is always created.
      case containing_component
      when Xcodeproj::Project::XCBuildConfiguration
        containing_component.base_configuration_reference =
          find_file(containing_component.project, change)
      when Xcodeproj::Project::PBXNativeTarget
        containing_component.product_reference = find_file(containing_component.project, change)
      when Xcodeproj::Project::PBXBuildFile
        containing_component.file_ref = find_file(containing_component.project, change)
      when Xcodeproj::Project::PBXGroup, Xcodeproj::Project::PBXVariantGroup
        file_reference = containing_component.project.new(Xcodeproj::Project::PBXFileReference)
        containing_component.children << file_reference

        # For some reason, `include_in_index` is set to `1` by default.
        file_reference.include_in_index = nil
        add_attributes_to_component(file_reference, change)
      else
        raise "Trying to add file reference to an unsupported component type " \
          "#{containing_component.isa}. Change is: #{change}"
      end
    end

    def add_group(containing_component, change)
      case containing_component
      when Xcodeproj::Project::ObjectDictionary
        # It is assumed that an `ObjectDictionary` always represents a project reference.
        new_group = containing_component[:project_ref].project.new(Xcodeproj::Project::PBXGroup)
        containing_component[:product_group] = new_group
      when Xcodeproj::Project::PBXGroup
        new_group = containing_component.project.new(Xcodeproj::Project::PBXGroup)
        containing_component.children << new_group
      else
        raise "Trying to add group to an unsupported component type #{containing_component.isa}. " \
          "Change is: #{change}"
      end

      add_attributes_to_component(new_group, change)
    end

    def add_attributes_to_component(component, change, ignore_keys: [])
      change.each do |change_name, change_value|
        next if (%w[isa displayName] + ignore_keys).include?(change_name)

        attribute_name = attribute_name_from_change_name(change_name)
        if simple_attribute?(component, attribute_name)
          apply_change_to_simple_attribute(component, attribute_name, {added: change_value})
          next
        end

        case change_value
        when Hash
          add_child_to_component(component, change_value)
        when Array
          change_value.each do |added_attribute_element|
            add_child_to_component(component, added_attribute_element)
          end
        else
          raise "Trying to add attribute of unsupported type '#{change_value.class}' to " \
            "object #{component}. Attribute name is '#{change_name}'"
        end
      end
    end

    def find_file(project, file_reference_change)
      case file_reference_change["isa"]
      when "PBXFileReference"
        project.files.find do |file_reference|
          next file_reference.path == file_reference_change["path"]
        end
      when "PBXReferenceProxy"
        find_reference_proxy(project, file_reference_change["remoteRef"])
      else
        raise "Unsupported file reference change of type #{file_reference["isa"]}."
      end
    end

    def find_reference_proxy(project, container_item_proxy_change)
      reference_proxies = project.root_object.project_references.map do |project_ref_and_products|
        project_ref_and_products[:product_group].children.find do |product|
          product.remote_ref.remote_global_id_string ==
            container_item_proxy_change["remoteGlobalIDString"] &&
            product.remote_ref.remote_info == container_item_proxy_change["remoteInfo"]
        end
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
  end
end

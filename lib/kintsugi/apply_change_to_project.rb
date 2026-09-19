# Copyright (c) 2020 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "xcodeproj"

require_relative "conflict_resolver"
require_relative "error"
require_relative "settings"
require_relative "xcodeproj_extensions"
require_relative "utils"

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
    # Isas of components whose additions and removals are handled by the main group pipeline
    # (`apply_group_additions`/`apply_group_removals`). `PBXFileSystemSynchronizedRootGroup` is the
    # Xcode 16 "buildable folder" object, which lives in the group tree like a group.
    GROUP_PIPELINE_ISAS =
      %w[PBXGroup PBXVariantGroup PBXFileSystemSynchronizedRootGroup].freeze

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
    # @param  [Xcodeproj::Project] change_source_project
    #         Project from which `change` to apply was created. Used for providing information about
    #         components that are no longer available in `project`.

    # @return [void]
    def apply_change_to_project(project, change, change_source_project)
      return unless change&.key?("rootObject")

      @change_source_project = change_source_project
      @ignored_components_group_paths = []
      @created_components_group_paths = []
      @pending_exception_references = []

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

      # Exception sets reference targets and build phases that may only be created later in the
      # change (and groups are linked to their targets only in the rootObject pass above), so their
      # references are resolved here, once everything exists.
      resolve_pending_exception_references
    end

    private

    def apply_main_group_change(project, main_group_change)
      additions, removals, diffs = classify_group_and_file_changes(main_group_change, "")
      apply_isa_conversions(project, diffs)
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

    def apply_group_additions(project, additions, force_create_containing_group: false)
      additions.each do |change, path|
        next unless GROUP_PIPELINE_ISAS.include?(change["isa"])

        # If the destination path is at or under a buildable folder in this project (e.g. this side
        # converted the group while the other side added a subgroup or nested file under it), the
        # folder includes its descendants implicitly -- there is no explicit child object to add.
        next if path_within_synchronized_root_group?(project, path)

        group_type = Module.const_get("Xcodeproj::Project::#{change["isa"]}")
        containing_group = project.group_or_file_at_path(path)

        if containing_group.nil?
          display_name = change["displayName"]
          if !force_create_containing_group &&
              !ConflictResolver.create_nonexistent_group_when_adding_subgroup?(path, display_name)
            @ignored_components_group_paths.append(join_path(path, display_name))
            next
          end

          @created_components_group_paths.append(join_path(path, display_name))
          containing_group = create_nonexistent_groupable_component(project, path)
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

    def apply_file_changes(project, additions, removals, force_create_containing_group: false)
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
          # Buildable-folder-safe lookup: a removed file whose containing path is now inside a
          # folder converted from a group in the same change resolves to nil rather than raising.
          project.group_or_file_at_path(join_path(containing_path, change["displayName"]))
        end

        [file_reference_key(change), references]
      end.to_h

      file_additions.each do |change, path|
        change_key = file_reference_key(change)

        # If the destination path is at or under a buildable folder in this project (e.g. this side
        # converted the group while the other side added a file into it), the folder includes the
        # file implicitly -- there is no explicit reference to add. Drop any moved source reference
        # so it is not left behind, then skip; otherwise `apply_file_addition` would call `children`
        # on the folder and raise.
        if path_within_synchronized_root_group?(project, path)
          (removal_keys_to_references[change_key] || []).compact.each(&:remove_from_project)
          next
        end

        containing_group = project.group_or_file_at_path(path)

        if containing_group.nil?
          if !force_create_containing_group &&
              !ConflictResolver.create_nonexistent_group_when_adding_file?(path,
                                                                           change["displayName"])
            @ignored_components_group_paths.append(join_path(path, change["displayName"]))
            next
          end

          @created_components_group_paths.append(join_path(path, change["displayName"]))
          containing_group = create_nonexistent_groupable_component(project, path)
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

        file_reference = project.group_or_file_at_path(join_path(path, change["displayName"]))
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
        # A folder->group conversion is handled up front by `apply_isa_conversions` (before files
        # are added), so the recreated group already exists here with nothing left to apply for it.
        next if converts_from_synchronized_root_group?(change)

        component = project.group_or_file_at_path(path)

        if component.nil? && change&.keys != ["children"]
          unless ConflictResolver.create_nonexistent_component_when_changing_it?(path)
            @ignored_components_group_paths.append(path)
            next
          end

          @created_components_group_paths.append(path)
          component = create_nonexistent_groupable_component(project, path)
        end

        # A group->buildable-folder conversion replaces the node's type in place. It is handled
        # here, after `apply_file_changes` has removed the group's explicit children, so that those
        # file removals could still navigate the group. The old group is removed and a folder
        # recreated at the same path. If this project already holds the folder (both sides converted
        # the same group), there is nothing to tear down; the conflict check surfaces any diverging
        # folder attributes rather than silently dropping them.
        if converts_to_synchronized_root_group?(change)
          if component.is_a?(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
            raise_on_diverging_both_sides_conversion(component, path)
          elsif !component.nil?
            remove_groupable_component_for_conversion(component)
            create_nonexistent_groupable_component(project, path)
          end
          next
        end

        change.each do |subchange_name, subchange|
          next if subchange_name == "children"

          apply_change_to_component(component, subchange_name, subchange, path)
        end
      end
    end

    # Xcode 16 can convert a plain group (`PBXGroup`) into a buildable folder
    # (`PBXFileSystemSynchronizedRootGroup`) or back. The two are unrelated classes, so the change
    # is expressed as an in-place `isa` change on a node that keeps its name and location, which
    # can't be applied as an ordinary attribute; the old node is removed and a new one of the
    # target type is created at the same path.
    #
    # Only the folder->group direction is handled here, before files are added or removed, so that
    # the conversion's restored child files land in the newly created group -- a buildable folder
    # has no navigable `children`, so adding them to the not-yet-converted node would raise. The
    # group->folder direction is handled later, in `apply_group_and_file_diffs`, because the group
    # must stay navigable until `apply_file_changes` has removed its explicit children.
    def apply_isa_conversions(project, diffs)
      diffs.each do |change, path|
        next unless converts_from_synchronized_root_group?(change)

        component = project.group_or_file_at_path(path)

        if component.is_a?(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
          # This project still holds the buildable folder: convert it to the plain group. The normal
          # additions/file-changes path then merges the other side's restored children in.
          remove_groupable_component_for_conversion(component)
          create_nonexistent_groupable_component(project, path)
        elsif !component.nil?
          # This project already holds a plain group here -- both sides ran the same folder->group
          # conversion. There is nothing to tear down (ours-only children still merge via the normal
          # path), but surface any diverging attributes rather than silently dropping them.
          raise_on_diverging_both_sides_conversion(component, path)
        end
      end
    end

    # When both sides of a merge independently convert the same node to the same type (group or
    # buildable folder), `change` for that node conflates the structural attributes both sides
    # applied identically with any attribute the other side additionally changed -- so the latter
    # can't be cleanly merged onto the node this project already holds. Rather than silently drop
    # such a change, compare the two converted nodes' own attributes (children merge separately, so
    # they are ignored) and raise a conflict when they diverge, leaving it for the user to resolve.
    def raise_on_diverging_both_sides_conversion(component, path)
      source_component = @change_source_project.group_or_file_at_path(path)
      return if source_component.nil?
      return if own_conversion_attributes(component) == own_conversion_attributes(source_component)

      raise MergeError, "Both sides converted the node at '#{path}' to the same type but with " \
                        "different attributes, which cannot be merged automatically. Resolve the " \
                        "conflict for this file manually."
    end

    def own_conversion_attributes(node)
      canonicalize(node.to_tree_hash.reject { |key, _| %w[children displayName].include?(key) })
    end

    # Canonicalizes a tree-hash value so semantically-equal attributes compare equal regardless of
    # hash key order or the order of set-like arrays. A buildable folder's `exceptions` and
    # `explicitFolders` are order-independent sets, so a pure reordering must not read as a
    # divergence: hashes become key-sorted pair lists and arrays are sorted by their canonical form.
    def canonicalize(value)
      case value
      when Hash
        value.sort_by { |key, _| key.to_s }.map { |key, subvalue| [key, canonicalize(subvalue)] }
      when Array
        value.map { |element| canonicalize(element) }.sort_by(&:inspect)
      else
        value
      end
    end

    # Whether `change` is an in-place `isa` change whose new type is a buildable folder, i.e. a
    # group->folder conversion. Restricting to this exact case (rather than any `isa` change) keeps
    # the remove-and-recreate path away from unrelated in-place `isa` changes (e.g. a
    # `PBXVariantGroup` to `PBXGroup`), whose unchanged children must be preserved rather than
    # dropped.
    def converts_to_synchronized_root_group?(change)
      isa_conversion_added_type(change) == "PBXFileSystemSynchronizedRootGroup"
    end

    # Whether `change` is an in-place `isa` change whose old type was a buildable folder, i.e. a
    # folder->group conversion.
    def converts_from_synchronized_root_group?(change)
      isa_conversion_removed_type(change) == "PBXFileSystemSynchronizedRootGroup"
    end

    def isa_conversion_added_type(change)
      isa_change = change.is_a?(Hash) ? change["isa"] : nil
      isa_change.is_a?(Hash) ? isa_change[:added] || isa_change["added"] : nil
    end

    def isa_conversion_removed_type(change)
      isa_change = change.is_a?(Hash) ? change["isa"] : nil
      isa_change.is_a?(Hash) ? isa_change[:removed] || isa_change["removed"] : nil
    end

    # Whether `path` (a "/"-separated path from the main group) lies at or under a buildable folder
    # (`PBXFileSystemSynchronizedRootGroup`) in `project`. A buildable folder includes its
    # descendants implicitly, so an explicit group/file addition at such a path must be skipped
    # rather than navigated into (a folder has no `children`). Walks the path shallowest-first,
    # returning at the first folder (match) or the first segment that does not resolve (no folder
    # sits above the change -- the path is genuinely absent and handled normally).
    def path_within_synchronized_root_group?(project, path)
      return false if path.nil? || path.empty?

      segments = path.split("/")
      (1..segments.length).each do |depth|
        node = project.group_or_file_at_path(segments.first(depth).join("/"))
        return true if node.is_a?(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
        return false if node.nil?
      end
      false
    end

    # Removes a node that is being converted to or from a buildable folder. The subtree is torn down
    # bottom-up: each file reference's build files are removed first (so none are left dangling once
    # the file references go away), then every descendant object is detached (so none are left
    # orphaned once the node is replaced), then the node itself. A buildable folder includes its
    # files implicitly, so their explicit references and build-phase membership are no longer
    # represented.
    def remove_groupable_component_for_conversion(component)
      if component.respond_to?(:recursive_children)
        component.recursive_children.reverse_each do |child|
          if child.is_a?(Xcodeproj::Project::PBXFileReference)
            remove_build_files_of_file_reference(child)
          end
          child.remove_from_project
        end
      end
      component.remove_from_project
    end

    def create_nonexistent_groupable_component(project, path)
      source_project_component = @change_source_project.group_or_file_at_path(path)
      component_change = source_project_component.to_tree_hash
      containing_group_path = parent_group_path(path)

      case source_project_component
      when Xcodeproj::Project::PBXFileReference
        apply_file_changes(project, [[component_change, containing_group_path]], [],
                           force_create_containing_group: true)
      when Xcodeproj::Project::PBXGroup,
           Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup
        apply_group_additions(project, [[component_change, containing_group_path]],
                              force_create_containing_group: true)
      else
        raise MergeError, "Component should either be a group or a file reference. " \
                          "Instead got: #{source_project_component}"
      end
      project.group_or_file_at_path(path)
    end

    def apply_group_removals(project, removals)
      removals.sort_by(&:last).reverse.each do |change, path|
        next unless GROUP_PIPELINE_ISAS.include?(change["isa"])

        group_path = join_path(path, change["displayName"])

        # by now we've deleted all of this group's children in the project, so we need to adapt the
        # change to the expected current state of the group, that is, without any children.
        # `PBXFileSystemSynchronizedRootGroup` has no `children` attribute, so we must not inject an
        # empty one, otherwise `remove_component`'s tree hash comparison would never match.
        change_without_children = change.dup
        change_without_children["children"] = [] if change.key?("children")

        # Use the buildable-folder-safe lookup: a group nested under a folder that was converted to
        # a buildable folder in the same change no longer exists as a navigable object (it was
        # removed with its parent), so this resolves to nil and the removal becomes a no-op.
        remove_component(project.group_or_file_at_path(group_path), change_without_children)
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
        component = replace_component_with_new_type(parent_component, attribute_name, change,
                                                    change_path)
        change = change_for_component_of_new_type(component, change)
      else
        component = child_component(parent_component, change_name)
      end

      if change[:removed].is_a?(Hash)
        remove_component(component, change[:removed])
      elsif change[:removed].is_a?(Array)
        remove_children_from_object_list(component, change[:removed]) unless component.nil?
      elsif !change[:removed].nil?
        raise MergeError, "Unsupported removed change type for #{change[:removed]}"
      end

      if change[:added].is_a?(Hash)
        add_child_to_component(parent_component, change[:added], change_path)
        component = child_component(parent_component, change_name)
      elsif change[:added].is_a?(Array)
        (change[:added]).each do |added_change|
          add_child_to_component(parent_component, added_change,
                                 join_path(change_path, added_change["displayName"]))
        end
      elsif !change[:added].nil?
        raise MergeError, "Unsupported added change type for #{change[:added]}"
      end

      subchanges_of_change(change).each do |subchange_name, subchange|
        if component.nil?
          component = resolve_nonexistent_component(parent_component, change_path)
          break if component.nil?
        end

        apply_change_to_component(component, subchange_name, subchange, change_path)
      end
    end

    def remove_children_from_object_list(object_list, removed_changes)
      removed_changes.each do |removed_change|
        child = child_component_of_object_list(object_list, removed_change["displayName"])
        if removed_change["isa"] == "PBXFileSystemSynchronizedRootGroup"
          # A target references the buildable folder object; unlinking it must detach the reference,
          # not unconditionally delete the shared object. `ObjectList#delete` is reference-counted:
          # it removes the object only when this was its last referrer, so a folder still referenced
          # by the main group or another target survives. (Full deletion of the folder itself is
          # driven separately by its main group entry, via `apply_group_removals`.)
          object_list.delete(child) unless child.nil?
        else
          remove_component(child, removed_change)
        end
      end
    end

    def resolve_nonexistent_component(parent_component, change_path)
      source_project_component = component_at_path(@change_source_project, change_path)
      group_path = group_path_of_group_based_component(source_project_component)

      if group_path
        should_create_component = @created_components_group_paths.include?(group_path) ||
          (!@ignored_components_group_paths.include?(group_path) &&
          !ConflictResolver.create_nonexistent_component_when_changing_it?(change_path))
        return unless should_create_component
      elsif !ConflictResolver.create_nonexistent_component_when_changing_it?(change_path)
        return
      end

      non_object_list_parent =
        if parent_component.is_a?(Xcodeproj::Project::ObjectList)
          parent_component.owner
        else
          parent_component
        end
      add_child_to_component(non_object_list_parent, source_project_component.to_tree_hash,
                             change_path)
      component_at_path(non_object_list_parent.project, change_path)
    end

    def group_path_of_group_based_component(component)
      if component.is_a?(Xcodeproj::Project::PBXBuildFile) && !component.file_ref.nil?
        component.file_ref.hierarchy_path.delete_prefix("/")
      elsif component.is_a?(Xcodeproj::Project::PBXFileReference) ||
          component.is_a?(Xcodeproj::Project::PBXGroup)
        component.hierarchy_path.delete_prefix("/")
      elsif component.is_a?(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
        # A synchronized root group is not a `PBXGroup`, so it has no `hierarchy_path` instance
        # method; the groupable helper computes the same path from its parent chain.
        Xcodeproj::Project::Object::GroupableHelper.hierarchy_path(component).delete_prefix("/")
      end
    end

    def component_at_path(project, path)
      current_component = project
      until path["/"].nil?
        change_name = path.split("/")[0]
        current_component = child_component(current_component, change_name)
        path = path.delete_prefix("#{change_name}/")
      end

      child_component(current_component, path)
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

    def replace_component_with_new_type(parent_component, name_in_parent_component, change,
                                        change_path)
      old_component = parent_component.send(name_in_parent_component)
      new_component = component_of_new_type(parent_component, change, old_component, change_path)

      copy_attributes_to_new_component(old_component, new_component)

      parent_component.send("#{name_in_parent_component}=", new_component)
      new_component
    end

    def component_of_new_type(parent_component, change, old_component, change_path)
      if change["isa"][:added] == "PBXFileReference"
        source_project_component =
          component_at_path(@change_source_project, change_path.split("/")[0...-1].join("/"))
        if source_project_component.nil?
          raise MergeError, "Couldn't find file reference in the project where the file should " \
                            "reside. The file's change is #{change}. Change path is #{change_path}"
        end

        case parent_component
        when Xcodeproj::Project::XCBuildConfiguration
          parent_component.base_configuration_reference =
            parent_component.project.group_or_file_at_path(
              source_project_component.base_configuration_reference.hierarchy_path
                .delete_prefix("/")
            )
          return parent_component.base_configuration_reference
        when Xcodeproj::Project::PBXNativeTarget
          parent_component.product_reference = parent_component.project.group_or_file_at_path(
            source_project_component.product_reference.hierarchy_path.delete_prefix("/")
          )
          return parent_component.product_reference
        when Xcodeproj::Project::PBXBuildFile
          parent_component.file_ref = parent_component.project.group_or_file_at_path(
            source_project_component.file_ref.hierarchy_path.delete_prefix("/")
          )
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

    def child_component(component, change_name)
      if component.is_a?(Xcodeproj::Project::ObjectList)
        child_component_of_object_list(component, change_name)
      else
        attribute_name = attribute_name_from_change_name(change_name)
        component.send(attribute_name)
      end
    end

    def child_component_of_object_list(component, change_name)
      component.find { |child| child.display_name == change_name }
    end

    def simple_attribute?(component, attribute_name)
      return false unless component.respond_to?("simple_attributes")

      component.simple_attributes.any? { |attribute| attribute.name == attribute_name }
    end

    def apply_change_to_simple_attribute(component, attribute_name, change)
      new_attribute_value =
        simple_attribute_value_with_change(component.send(attribute_name), change, attribute_name)
      component.send("#{attribute_name}=", new_attribute_value)
    end

    def simple_attribute_value_with_change(old_value, change, attribute_name)
      type = simple_attribute_type(old_value, change[:removed], change[:added])
      new_value = new_simple_attribute_value(type, old_value, change[:removed], change[:added],
                                             attribute_name)

      subchanges_of_change(change).each do |subchange_name, subchange_value|
        new_value = new_value || old_value || {}
        new_value[subchange_name] =
          simple_attribute_value_with_change(old_value[subchange_name], subchange_value,
                                             subchange_name)
      end

      new_value
    end

    def simple_attribute_type(old_value, removed_change, added_change)
      types = [old_value.class, removed_change.class, added_change.class]

      if types.include?(Hash)
        unless types.to_set.subset?([Hash, NilClass].to_set)
          raise MergeError, "Cannot apply changes because the types are not compatible. Existing " \
                            "value: '#{old_value}', removed change: '#{removed_change}', added " \
                            "change: '#{added_change}'"
        end
        Hash
      elsif types.include?(Array)
        unless types.to_set.subset?([Array, String, NilClass].to_set)
          raise MergeError, "Cannot apply changes because the types are not compatible. Existing " \
                            "value: '#{old_value}', removed change: '#{removed_change}', added " \
                            "change: '#{added_change}'"
        end
        Array
      elsif types.include?(String)
        unless types.to_set.subset?([String, NilClass].to_set)
          raise MergeError, "Cannot apply changes because the types are not compatible. Existing " \
                            "value: '#{old_value}', removed change: '#{removed_change}', added " \
                            "change: '#{added_change}'"
        end
        String
      else
        raise MergeError, "Unsupported types of all of the values. Existing value: " \
                          "'#{old_value}', removed change: '#{removed_change}', added change: " \
                          "'#{added_change}'"
      end
    end

    def new_simple_attribute_value(type, old_value, removed_change, added_change, attribute_name)
      if type == Hash
        new_hash_simple_attribute_value(old_value, removed_change, added_change, attribute_name)
      elsif type == Array
        new_array_simple_attribute_value(old_value, removed_change, added_change, attribute_name)
      elsif type == String
        new_string_simple_attribute_value(old_value, removed_change, added_change, attribute_name)
      else
        raise MergeError, "Unsupported types of all of the values. Existing value: " \
                          "'#{old_value}', removed change: '#{removed_change}', added change: " \
                          "'#{added_change}'"
      end
    end

    def new_hash_simple_attribute_value(old_value, removed_change, added_change, attribute_name)
      return added_change if ((old_value || {}).to_a - (removed_change || {}).to_a).empty?

      # First apply the added change to see if there are any conflicts with it.
      new_value = (old_value || {}).merge(added_change || {})
      conflicting_added_hash_values = (old_value.to_a - new_value.to_a)

      unless conflicting_added_hash_values.empty?
        override_values = ConflictResolver.override_values_when_keys_already_exist_in_hash?(
          attribute_name, old_value, added_change
        )
        new_value = override_values ? old_value.merge(added_change) : added_change.merge(old_value)
      end

      if removed_change.nil?
        return new_value
      end

      conflicting_removal_hash_values = new_value.select do |key, value|
        value != removed_change[key] && value != (added_change || {})[key]
      end

      unless conflicting_removal_hash_values.empty?
        expected_values =
          removed_change.select { |key, value| conflicting_removal_hash_values.key?(key) }
        should_remove_conflicting_values =
          ConflictResolver.remove_entries_when_unexpected_values_in_hash?(
            attribute_name, expected_values, conflicting_removal_hash_values
          )
      end

      new_value
        .reject do |key, value|
          if conflicting_removal_hash_values.key?(key)
            next should_remove_conflicting_values
          end

          removed_change.key?(key)
        end
    end

    def new_array_simple_attribute_value(old_value, removed_change, added_change, attribute_name)
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

    def new_string_simple_attribute_value(old_value, removed_change, added_change, attribute_name)
      if old_value != removed_change && !old_value.nil? && added_change != old_value
        use_added_change = ConflictResolver.set_value_to_string_when_unxpected_value?(
          attribute_name, added_change, removed_change, old_value
        )
        return use_added_change ? added_change : old_value
      end

      added_change
    end

    def remove_component(component, change)
      return if component.nil?

      if component.to_tree_hash != change &&
          !ConflictResolver.remove_component_when_unexpected_hash?(component, change)
        return
      end

      if change["isa"] == "PBXFileReference" || change["isa"] == "PBXReferenceProxy" ||
          change["isa"] == "PBXGroup" || change["isa"] == "PBXVariantGroup"
        remove_build_files_of_file_reference(component)
      end

      component.remove_from_project
    end

    def remove_build_files_of_file_reference(file_reference)
      # Since the build file's display name depends on the file reference, removing the file
      # reference before removing it will change the build file's display name which will not be
      # detected when trying to remove the build file. Therefore, the build files that depend on
      # the file reference are removed prior to removing the file reference.
      file_reference.referrers.grep(Xcodeproj::Project::PBXBuildFile).each do |build_file|
        build_file.referrers.each do |referrer|
          referrer.remove_build_file(build_file)
        end
      end
    end

    def add_child_to_component(component, change, change_path)
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
      when "PBXFileSystemSynchronizedRootGroup"
        add_file_system_synchronized_root_group(component, change, change_path)
      when "PBXFileSystemSynchronizedBuildFileExceptionSet"
        add_file_system_synchronized_build_file_exception_set(component, change, change_path)
      when "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet"
        add_file_system_synchronized_group_build_phase_membership_exception_set(component, change,
                                                                                change_path)
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
      project = containing_component.project
      # A remote package reference is shared project-wide: `rootObject.packageReferences` and every
      # product dependency's `package` point at the same object. The diff adds it from each place,
      # so reuse an equivalent reference already in the project rather than adding a duplicate.
      remote_swift_package_reference = existing_remote_swift_package_reference(project, change)

      if remote_swift_package_reference.nil?
        remote_swift_package_reference =
          project.new(Xcodeproj::Project::XCRemoteSwiftPackageReference)
        add_attributes_to_component(remote_swift_package_reference, change, change_path)
      end

      case containing_component
      when Xcodeproj::Project::XCSwiftPackageProductDependency
        containing_component.package = remote_swift_package_reference
      when Xcodeproj::Project::PBXProject
        references = containing_component.package_references
        unless references.any? { |reference| reference.equal?(remote_swift_package_reference) }
          references << remote_swift_package_reference
        end
      else
        raise MergeError, "Trying to add remote swift package reference to an unsupported " \
                          "component type #{containing_component.isa}. Change is: #{change}"
      end
    end

    # An existing remote swift package reference in `project` whose tree hash equals `change`, else
    # nil. Package references are shared project-wide, so the lookup is not scoped to a target.
    def existing_remote_swift_package_reference(project, change)
      project.objects.find do |object|
        object.isa == "XCRemoteSwiftPackageReference" && object.to_tree_hash == change
      end
    end

    def add_swift_package_product_dependency(containing_component, change, change_path)
      # Within a single target, the target's `packageProductDependencies` entry and the `productRef`
      # of the build file that links the product are the same object. The diff adds it from both
      # places, so reuse an equivalent dependency already present in the SAME target rather than
      # adding a duplicate. The reuse is scoped to the target because Xcode keeps a separate
      # dependency object per target. Looking up before creating avoids adding a throwaway object.
      target = owning_native_target(containing_component)
      swift_package_product_dependency = existing_package_product_dependency(target, change)

      if swift_package_product_dependency.nil?
        swift_package_product_dependency =
          containing_component.project.new(Xcodeproj::Project::XCSwiftPackageProductDependency)
        add_attributes_to_component(swift_package_product_dependency, change, change_path)
      end

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

    # The native target that owns `component`: the target itself, or -- for a build file -- the
    # target whose build phases contain it. Returns nil if none (e.g. the build phase is not yet
    # linked to a target), in which case the caller adds a fresh dependency.
    def owning_native_target(component)
      return component if component.is_a?(Xcodeproj::Project::PBXNativeTarget)
      return nil unless component.is_a?(Xcodeproj::Project::PBXBuildFile)

      component.project.native_targets.find do |target|
        # Match by object identity, not `include?` (which compares by value): a freshly-created
        # build file is still attribute-less here, and `PBXBuildFile#==` would treat it as equal to
        # any other attribute-less build file, wrongly attributing it to an earlier target.
        target.build_phases.any? do |build_phase|
          build_phase.files.any? { |file| file.equal?(component) }
        end
      end
    end

    # An existing package product dependency of `target` (in its `packageProductDependencies` or
    # referenced by one of its build files) whose tree hash equals `change`, else nil.
    def existing_package_product_dependency(target, change)
      return nil if target.nil?

      candidates = target.package_product_dependencies.to_a +
                   target.build_phases.flat_map(&:files).map(&:product_ref).compact
      candidates.uniq.find { |candidate| candidate.to_tree_hash == change }
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
          find_reference_proxy(containing_component.project, change,
                               reference_filter: filter_references_without_build_files)
        if file_reference.nil?
          file_reference = find_reference_proxy(containing_component.project, change)
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
      when Xcodeproj::Project::PBXGroup
        # Adding variant groups to groups is handled by another part of the code.
      else
        raise MergeError, "Trying to add variant group to an unsupported component type " \
                          "#{containing_component.isa}. Change is: #{change}"
      end
    end

    # Known limitation: buildable folders have no stable identity in a project diff (they're
    # compared by value), so relocating a folder between parent groups while it stays linked to a
    # target reads as remove-from-A + add-to-B. The old object (and its target link) is removed, and
    # the new object is created but not re-linked to the target, since the target's own change is
    # empty. Such a merge can drop the folder's target membership; re-verify after relocating.
    def add_file_system_synchronized_root_group(containing_component, change, change_path)
      case containing_component
      when Xcodeproj::Project::PBXNativeTarget
        # The group was already created in the group tree by the main group pass. Resolve it by its
        # position in the tree so we reuse the exact same object, even when another buildable folder
        # shares its name in a different parent group.
        group = resolve_file_system_synchronized_root_group(containing_component, change)
        if group.nil?
          raise MergeError, "No file system synchronized root group matching #{change} was " \
                            "found in the group tree. Change path: #{change_path}"
        end

        # Dedup by object identity, not display name: one target can legitimately link several
        # same-named folders from different parent groups, each a distinct object.
        already_linked = containing_component.file_system_synchronized_groups.any? do |linked|
          linked.uuid == group.uuid
        end
        return if !Settings.allow_duplicates && already_linked

        containing_component.file_system_synchronized_groups << group
      else
        raise MergeError, "Trying to add file system synchronized root group to an unsupported " \
                          "component type #{containing_component.isa}. Change is: #{change}"
      end
    end

    def resolve_file_system_synchronized_root_group(target, change)
      candidates = target.project.objects.select do |object|
        object.isa == "PBXFileSystemSynchronizedRootGroup" &&
          object.display_name == change["displayName"]
      end
      return candidates.first if candidates.length <= 1

      # More than one buildable folder shares this name (in different parent groups). Match against
      # the folders the change's target links in the source project, comparing hierarchy paths as
      # strings. A folder's own `path`/`display_name` may itself contain "/", so this must not be
      # split into segments, so path-walking helpers like `group_or_file_at_path` can't be used.
      source_hierarchies = source_synchronized_root_group_hierarchies(target, change)
      source_matching = candidates.select do |candidate|
        source_hierarchies.include?(synchronized_root_group_hierarchy_path(candidate))
      end
      return candidates.first if source_matching.empty?

      # Prefer a folder not already linked to this target, so a target linking two same-named
      # folders resolves each addition to a distinct object rather than dropping the second.
      linked_uuids = target.file_system_synchronized_groups.map(&:uuid)
      source_matching.find { |candidate| !linked_uuids.include?(candidate.uuid) } ||
        source_matching.first
    end

    # Hierarchy paths (in source order) of the buildable folders the change's target links that
    # match `change`. A target may link several same-named folders from different parents; their
    # identity lets us map each addition to the right destination object.
    def source_synchronized_root_group_hierarchies(target, change)
      source_target = find_target(@change_source_project, target.display_name)
      (source_target&.file_system_synchronized_groups || [])
        .select { |group| group.to_tree_hash == change }
        .map { |group| synchronized_root_group_hierarchy_path(group) }
        .compact
    end

    # Groupable helper raises a `RuntimeError` consistency error (rather than returning nil) for an
    # object with no parent group; treat that as "no hierarchy" so a stray unparented candidate
    # can't abort the merge. Narrowly rescued so unrelated errors still surface.
    def synchronized_root_group_hierarchy_path(group)
      Xcodeproj::Project::Object::GroupableHelper.hierarchy_path(group)
    rescue RuntimeError
      nil
    end

    def add_file_system_synchronized_build_file_exception_set(containing_component, change,
                                                              change_path)
      unless containing_component.is_a?(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
        raise MergeError, "Trying to add file system synchronized build file exception set to an " \
                          "unsupported component type #{containing_component.isa}. Change is: " \
                          "#{change}"
      end
      return if exception_set_already_exists?(containing_component, change)

      exception_set = containing_component.project.new(
        Xcodeproj::Project::PBXFileSystemSynchronizedBuildFileExceptionSet
      )
      containing_component.exceptions << exception_set
      add_attributes_to_component(exception_set, change, change_path, ignore_keys: ["target"])
      resolve_or_defer_exception_reference(exception_set, :target, change["target"])
    end

    def add_file_system_synchronized_group_build_phase_membership_exception_set(
      containing_component, change, change_path
    )
      unless containing_component.is_a?(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
        raise MergeError, "Trying to add file system synchronized group build phase membership " \
                          "exception set to an unsupported component type " \
                          "#{containing_component.isa}. Change is: #{change}"
      end
      return if exception_set_already_exists?(containing_component, change)

      exception_set = containing_component.project.new(
        Xcodeproj::Project::PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet
      )
      containing_component.exceptions << exception_set
      add_attributes_to_component(exception_set, change, change_path, ignore_keys: ["buildPhase"])
      resolve_or_defer_exception_reference(exception_set, :build_phase, change["buildPhase"])
    end

    # `true` if an equivalent exception set already exists on `group`. This is intentionally NOT
    # gated on `Settings.allow_duplicates`: a synchronized root group is referenced from both the
    # main group and its target(s), so the same exception addition is visited through several graph
    # paths, and two exception sets identical in target/build phase + membership are meaningless.
    def exception_set_already_exists?(group, change)
      group.exceptions.any? { |exception_set| exception_set_matches_change?(exception_set, change) }
    end

    def exception_set_matches_change?(exception_set, change)
      signature = exception_set.to_tree_hash
      pending = @pending_exception_references.find { |set, _, _| set.equal?(exception_set) }
      unless pending.nil?
        _, kind, reference = pending
        signature = signature.merge(exception_reference_key(kind) => reference)
      end
      # `displayName` is derived from the (possibly still-unresolved) reference and the folder name,
      # so it carries no information the reference key and simple attributes don't already carry;
      # excluding it avoids a spurious mismatch when the reference is still pending (nil).
      signature.reject { |key, _| key == "displayName" } ==
        change.reject { |key, _| key == "displayName" }
    end

    def exception_reference_key(kind)
      kind == :target ? "target" : "buildPhase"
    end

    # Resolves the target/build phase an exception set references. The target may be created, and
    # the group linked to its targets, only later, so unresolvable references are recorded and
    # retried by `resolve_pending_exception_references` after the whole change is applied. Build
    # phase resolution always defers: it needs the group already linked to a target.
    def resolve_or_defer_exception_reference(exception_set, kind, reference)
      # Only the target reference is resolved eagerly (it just needs the target to exist). The build
      # phase reference is always deferred, because the phase it points to might itself be created
      # later in the same change (e.g. a target and its build phases added together).
      if kind == :target
        resolved = resolve_exception_reference(exception_set, kind, reference)
        unless resolved.nil?
          assign_exception_reference(exception_set, kind, resolved)
          return
        end
      end

      @pending_exception_references << [exception_set, kind, reference]
    end

    def resolve_pending_exception_references
      @pending_exception_references.each do |exception_set, kind, reference|
        resolved = resolve_exception_reference(exception_set, kind, reference)
        if resolved.nil?
          puts "Warning: Couldn't resolve #{kind} reference #{reference.inspect} for exception " \
               "set '#{exception_set.display_name}'."
          next
        end

        assign_exception_reference(exception_set, kind, resolved)
      end
      @pending_exception_references = []
    end

    def resolve_exception_reference(exception_set, kind, reference)
      case kind
      when :target
        find_target(exception_set.project, reference)
      when :build_phase
        find_synchronized_group_build_phase(exception_set, reference)
      end
    end

    def assign_exception_reference(exception_set, kind, resolved)
      case kind
      when :target then exception_set.target = resolved
      when :build_phase then exception_set.build_phase = resolved
      end
    end

    # Finds the build phase an exception set references. The reference carries its owning target,
    # so we resolve that target by name (unique) then its build phase by name. This disambiguates
    # same-named phases (e.g. "Sources") when the group is shared by several targets. Returns nil
    # when the target isn't created yet, so the caller can defer.
    def find_synchronized_group_build_phase(exception_set, reference)
      project = exception_set.project
      target_name = reference.is_a?(Hash) ? reference["target"] : nil
      phase_name = reference.is_a?(Hash) ? reference["name"] : reference

      candidate_targets =
        if target_name.nil?
          synchronized_group_referencing_targets(exception_set)
        else
          target = find_target(project, target_name)
          return nil if target.nil?

          [target]
        end

      matching_build_phases = candidate_targets.flat_map(&:build_phases).select do |build_phase|
        build_phase.display_name == phase_name
      end
      if matching_build_phases.length > 1
        puts "Debug: Multiple build phases named '#{phase_name}'. Using the first one."
      end
      matching_build_phases.first
    end

    # The targets that reference the exception set's owning synchronized root group. Used as a
    # fallback when a build phase reference doesn't carry its owning target. The groupable helper
    # raises `RuntimeError` for an unparented set (e.g. its group was removed earlier in the same
    # change); fall back to all native targets rather than aborting the merge.
    def synchronized_group_referencing_targets(exception_set)
      project = exception_set.project
      group =
        begin
          Xcodeproj::Project::Object::GroupableHelper.parent(exception_set)
        rescue RuntimeError
          nil
        end
      return project.native_targets if group.nil?

      referencing_targets = project.native_targets.select do |target|
        target.file_system_synchronized_groups.any? { |linked| linked.uuid == group.uuid }
      end
      referencing_targets.empty? ? project.native_targets : referencing_targets
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
      # A build file references either a file (`fileRef`) or a Swift package product (`productRef`).
      if change["fileRef"].nil? && change["productRef"].nil?
        puts "Warning: Trying to add a build file without any file or product reference to build " \
             "phase '#{build_phase}'"
        return
      end

      existing_build_file = build_phase.files.find do |build_file|
        if change["fileRef"]
          build_file.file_ref && build_file.file_ref.path == change["fileRef"]["path"]
        else
          # Compare the whole product reference, not just its name: two different Swift package
          # products (from different packages) may share a product name, so a name-only match would
          # wrongly drop a distinct build file. Comparing the full tree hash also distinguishes
          # nameless products by their package.
          build_file.product_ref &&
            build_file.product_ref.to_tree_hash == change["productRef"]
        end
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

      source_project_subproject_reference = component_at_path(@change_source_project, change_path)
      if source_project_subproject_reference.nil?
        raise MergeError, "Project reference with change #{project_reference_change} doesn't " \
                          "exist in the source project. Change path is #{change_path}"
      end

      subproject_reference = root_object.project.files.find do |file_reference|
        file_reference.hierarchy_path ==
          source_project_subproject_reference.project_ref.hierarchy_path &&
        root_object.project_references.find do |project_reference|
          project_reference.project_ref.uuid == file_reference.uuid
        end.nil?
      end

      unless subproject_reference
        raise MergeError, "No file reference was found for project reference with change " \
                          "#{project_reference_change}. This might mean that the file used to " \
                          "exist in the project the but was removed at some point"
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
      source_project_component =
        component_at_path(@change_source_project, change_path.split("/")[0...-1].join("/"))
      if source_project_component.nil?
        raise MergeError, "Couldn't find file reference in the project where the file should " \
                          "reside. The file's change is #{change}. Change path is #{change_path}"
      end

      case containing_component
      when Xcodeproj::Project::XCBuildConfiguration
        containing_component.base_configuration_reference =
          containing_component.project.group_or_file_at_path(
            source_project_component.base_configuration_reference.hierarchy_path.delete_prefix("/")
          )
      when Xcodeproj::Project::PBXNativeTarget
        containing_component.product_reference =
          containing_component.project.group_or_file_at_path(
            source_project_component.product_reference.hierarchy_path.delete_prefix("/")
          )
      when Xcodeproj::Project::PBXBuildFile
        containing_component.file_ref =
          containing_component.project.group_or_file_at_path(
            source_project_component.file_ref.hierarchy_path.delete_prefix("/")
          )
      when Xcodeproj::Project::PBXGroup
        # Adding files to groups is handled by another part of the code.
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

    def add_group(containing_component, change, change_path)
      case containing_component
      when Xcodeproj::Project::ObjectDictionary
        # It is assumed that an `ObjectDictionary` always represents a project reference.
        new_group = containing_component[:project_ref].project.new(Xcodeproj::Project::PBXGroup)
        containing_component[:product_group] = new_group
        add_attributes_to_component(new_group, change, change_path)
      when Xcodeproj::Project::PBXGroup
        # Adding groups to groups is handled by another part of the code.
      else
        raise MergeError, "Trying to add group to an unsupported component type " \
                          "#{containing_component.isa}. Change is: #{change}. Change path: " \
                          "#{change_path}"
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

        child_path = join_path(change_path, change_name)
        case change_value
        when Hash
          add_child_to_component(component, change_value, child_path)
        when Array
          change_value.each do |added_attribute_element|
            element_path = join_path(child_path, added_attribute_element["displayName"])
            add_child_to_component(component, added_attribute_element, element_path)
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

    def find_reference_proxy(project, change, reference_filter: ->(_) { true })
      reference_proxies = project.root_object.project_references.map do |project_ref_and_products|
        project_ref_and_products[:product_group].children.find do |reference_proxy|
          reference_proxy.display_name == change["displayName"] &&
            reference_filter.call(reference_proxy)
        end
      end.compact

      if reference_proxies.length > 1
        puts "Debug: Found more than one matching reference proxy with name " \
             "'#{change["remoteInfo"]}'. Using the first one."
      elsif reference_proxies.empty?
        puts "Warning: No reference proxy was found for name '#{change["remoteInfo"]}'."
        return
      end

      reference_proxies.first
    end

    def join_path(left, right)
      left.empty? ? right : "#{left}/#{right}"
    end

    def parent_group_path(group_path)
      group_path[/(.*)\//, 1] || ""
    end
  end
end

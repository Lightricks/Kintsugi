# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "json"
require "rspec"
require "tempfile"
require "tmpdir"
require "tty-prompt"

require "kintsugi/apply_change_to_project"
require "kintsugi/error"
require "tty/prompt/test"

require_relative "be_equivalent_to_project"

describe Kintsugi, :apply_change_to_project do
  let(:temporary_directories_paths) { [] }
  let(:base_project_path) { make_temp_directory("base", ".xcodeproj") }
  let(:base_project) { Xcodeproj::Project.new(base_project_path) }

  before do
    Kintsugi::Settings.interactive_resolution = false
  end

  after do
    temporary_directories_paths.each do |directory_path|
      FileUtils.remove_entry(directory_path)
    end
  end

  it "not raises when change is nil or doesn't have root object" do
    expect {
      theirs_project = create_copy_of_project(base_project, "theirs")
      described_class.apply_change_to_project(base_project, nil, theirs_project)
      described_class.apply_change_to_project(base_project, {}, theirs_project)
    }.not_to raise_error
  end

  it "adds new target" do
    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.new_target("com.apple.product-type.library.static", "foo", :ios)

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds new aggregate target" do
    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.new_aggregate_target("foo")

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds package reference" do
    theirs_project = create_copy_of_project(base_project, "theirs")

    theirs_project.root_object.package_references <<
      create_remote_swift_package_reference(theirs_project)

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds new subproject" do
    theirs_project = create_copy_of_project(base_project, "theirs")
    add_new_subproject_to_project(theirs_project, "foo", "foo")

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
  end

  it "removes reference proxy from subproject with the same display name as another reference proxy" do
    framework_filename = "baz"
    subproject = add_new_subproject_to_project(base_project, "subproj", framework_filename)

    subproject.new_target("com.apple.product-type.library.static", framework_filename, :ios)
    base_project.root_object.project_references[0][:product_group] <<
      create_reference_proxy_from_product_reference(base_project,
                                                    base_project.root_object.project_references[0][:project_ref],
                                                    subproject.products_group.files[-1])

    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.root_object.project_references[0][:product_group].children[-1].remove_from_project

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  # Checks that the order the changes are applied in is correct.
  it "adds new subproject and reference to its framework" do
    theirs_project = create_copy_of_project(base_project, "theirs")
    add_new_subproject_to_project(theirs_project, "foo", "foo")

    target = theirs_project.new_target("com.apple.product-type.library.static", "foo", :ios)
    target.frameworks_build_phase.add_file_reference(
      theirs_project.root_object.project_references[0][:product_group].children[0]
    )

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
  end

  it "raises if adding subproject whose file reference isn't found" do
    ours_project = create_copy_of_project(base_project, "ours")

    add_new_subproject_to_project(base_project, "foo", "foo")

    theirs_project = create_copy_of_project(base_project, "theirs")

    base_project.root_object.project_references.pop

    changes_to_apply = get_diff(theirs_project, base_project)

    expect {
      described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)
    }.to raise_error(Kintsugi::MergeError)
  end

  it "ignores removal of a product reference that was already removed" do
    base_project.new_target("com.apple.product-type.library.static", "foo", :ios)

    ours_project = create_copy_of_project(base_project, "ours")
    ours_project.targets[0].product_reference.remove_from_project

    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.targets[0].product_reference.remove_from_project

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

    expect(ours_project).to be_equivalent_to_project(theirs_project)
  end

  describe "file related changes" do
    let(:filepath) { "foo" }

    before do
      base_project.main_group.new_reference(filepath)
    end

    it "moves file to another group" do
      base_project.main_group.find_subpath("new_group", true)

      theirs_project = create_copy_of_project(base_project, "theirs")
      new_group = theirs_project.main_group.find_subpath("new_group")
      file_reference = theirs_project.main_group.find_file_by_path(filepath)
      file_reference.move(new_group)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "raises if trying to move file to another group that no longer exists" do
      base_project.main_group.find_subpath("new_group", true)

      theirs_project = create_copy_of_project(base_project, "theirs")
      new_group = theirs_project.main_group.find_subpath("new_group")
      file_reference = theirs_project.main_group.find_file_by_path(filepath)
      file_reference.move(new_group)

      changes_to_apply = get_diff(theirs_project, base_project)

      base_project.main_group.find_subpath("new_group").remove_from_project

      expect {
        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)
      }.to raise_error(Kintsugi::MergeError)
    end

    it "raises if trying to add file to a group that no longer exists" do
      base_project.main_group.find_subpath("new_group", true)

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.main_group.find_subpath("new_group").new_reference("foo")

      changes_to_apply = get_diff(theirs_project, base_project)

      base_project.main_group.find_subpath("new_group").remove_from_project

      expect {
        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)
      }.to raise_error(Kintsugi::MergeError)
    end

    it "does nothing if trying to remove a file from a group that no longer exists" do
      base_project.main_group.find_subpath("new_group", true).new_reference("foo")

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.main_group.find_subpath("new_group/foo").remove_from_project

      changes_to_apply = get_diff(theirs_project, base_project)

      base_project.main_group.find_subpath("new_group").remove_from_project

      expected_project = create_copy_of_project(base_project, "expected")

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(expected_project)
    end

    it "raises when a file is split into two" do
      base_project.main_group.find_subpath("new_group", true)
      base_project.main_group.find_subpath("new_group2", true)

      theirs_project = create_copy_of_project(base_project, "theirs")
      new_group = theirs_project.main_group.find_subpath("new_group")
      file_reference = theirs_project.main_group.find_file_by_path(filepath)
      file_reference.move(new_group)
      theirs_project.main_group.find_subpath("new_group2").new_reference(filepath)

      changes_to_apply = get_diff(theirs_project, base_project)

      expect {
        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)
      }.to raise_error(Kintsugi::MergeError)
    end

    it "adds file to new group" do
      theirs_project = create_copy_of_project(base_project, "theirs")

      theirs_project.main_group.find_subpath("new_group", true).new_reference(filepath)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "removes group" do
      base_project.main_group.find_subpath("new_group", true)

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project["new_group"].remove_from_project

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "moves a group with files in it" do
      new_group = base_project.main_group.find_subpath("new_group", true)
      new_group.new_reference("new_file")

      theirs_project = create_copy_of_project(base_project, "theirs")
      new_group2 = theirs_project.main_group.find_subpath("new_group2", true)
      theirs_project["new_group"].move(new_group2)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "raises when trying to add a group to a group that no longer exists" do
      base_project.main_group.find_subpath("new_group", true)

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project["new_group"].find_subpath("sub_group", true)

      changes_to_apply = get_diff(theirs_project, base_project)

      base_project.main_group.find_subpath("new_group").remove_from_project

      expect {
        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)
      }.to raise_error(Kintsugi::MergeError)
    end

    it "raises when trying to move a group to a group that no longer exists" do
      base_project.main_group.find_subpath("new_group", true)
      base_project.main_group.find_subpath("other_group", true)

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project["other_group"].move(theirs_project["new_group"])

      changes_to_apply = get_diff(theirs_project, base_project)

      base_project.main_group.find_subpath("new_group").remove_from_project

      expect {
        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)
      }.to raise_error(Kintsugi::MergeError)
    end

    it "moves a group with a group in it" do
      new_group = base_project.main_group.find_subpath("new_group", true)
      new_group.find_subpath("sub_group", true)

      theirs_project = create_copy_of_project(base_project, "theirs")
      new_group2 = theirs_project.main_group.find_subpath("new_group2", true)
      theirs_project["new_group"].move(new_group2)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "moves a group with a group with a file in it" do
      new_group = base_project.main_group.find_subpath("new_group", true)
      sub_group = new_group.find_subpath("sub_group", true)
      sub_group.new_reference("new_file")

      theirs_project = create_copy_of_project(base_project, "theirs")
      new_group2 = theirs_project.main_group.find_subpath("new_group2", true)
      theirs_project["new_group"].move(new_group2)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds file with include in index and last known file type as nil" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      file_reference = theirs_project.main_group.new_reference("#{filepath}.h")
      file_reference.include_in_index = nil
      file_reference.last_known_file_type = nil

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "renames file" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      file_reference = theirs_project.main_group.find_file_by_path(filepath)
      file_reference.path = "newFoo"

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "removes file" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.main_group.find_file_by_path(filepath).remove_from_project

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "changes simple attribute of a file that has a build file" do
      target = base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      file_reference = base_project.main_group.find_file_by_path(filepath)
      target.frameworks_build_phase.add_file_reference(file_reference)

      theirs_project = create_copy_of_project(base_project, "theirs")
      file_reference = theirs_project.main_group.find_file_by_path(filepath)
      file_reference.include_in_index = "4"

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "ignores removal of a non-existent group" do
      base_project.main_group.find_subpath("new_group", true)

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.main_group.children.delete_at(-1)

      changes_to_apply = get_diff(theirs_project, base_project)

      base_project.main_group.children.delete_at(-1)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "removes build files of a removed file" do
      target = base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
      target.source_build_phase.add_file_reference(
        base_project.main_group.find_file_by_path(filepath)
      )

      theirs_project = create_copy_of_project(base_project, "theirs")
      file_reference = theirs_project.main_group.find_file_by_path(filepath)
      file_reference.build_files.each do |build_file|
        build_file.referrers.each do |referrer|
          referrer.remove_build_file(build_file)
        end
      end
      file_reference.remove_from_project

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds file inside a group that has a path on filesystem" do
      theirs_project = create_copy_of_project(base_project, "theirs")

      new_group = theirs_project.main_group.find_subpath("new_group", true)
      new_group.path = "some_path"
      new_group.name = nil
      new_group.new_reference(filepath)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "handles subfile changes" do
      theirs_project = create_copy_of_project(base_project, "theirs")

      theirs_project.main_group.find_file_by_path(filepath).explicit_file_type = "bar"
      theirs_project.main_group.find_file_by_path(filepath).include_in_index = "0"
      theirs_project.main_group.find_file_by_path(filepath).fileEncoding = "4"

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "handles moved file to an existing group with a different path on filesystem" do
      base_project.main_group.find_subpath("new_group", true).path = "some_path"

      theirs_project = create_copy_of_project(base_project, "theirs")
      new_group = theirs_project.main_group.find_subpath("new_group")
      theirs_project.main_group.find_file_by_path(filepath).move(new_group)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    describe "dealing with unexpected change" do
      it "raises if applying change to a file whose containing group doesn't exist" do
        ours_project = create_copy_of_project(base_project, "ours")
        new_group = ours_project.main_group.find_subpath("new_group", true)
        ours_project.main_group.find_file_by_path(filepath).move(new_group)

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.main_group.find_file_by_path(filepath).explicit_file_type = "bar"

        ours_project.main_group.find_subpath("new_group").remove_from_project

        changes_to_apply = get_diff(theirs_project, base_project)

        expect {
          described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)
        }.to raise_error(Kintsugi::MergeError)
      end

      it "raises if applying change to a file that doesn't exist" do
        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.main_group.find_file_by_path(filepath).remove_from_project

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.main_group.find_file_by_path(filepath).explicit_file_type = "bar"

        changes_to_apply = get_diff(theirs_project, base_project)

        expect {
          described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)
        }.to raise_error(Kintsugi::MergeError)
      end

      it "ignores removal of a file whose group doesn't exist" do
        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.main_group.remove_from_project

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.main_group.find_file_by_path(filepath).remove_from_project

        changes_to_apply = get_diff(theirs_project, base_project)

        ours_project_before_applying_changes = create_copy_of_project(ours_project, "ours")

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(ours_project_before_applying_changes)
      end

      it "ignores removal of non-existent file" do
        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.main_group.find_file_by_path(filepath).remove_from_project

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.main_group.find_file_by_path(filepath).remove_from_project

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(theirs_project)
      end
    end
  end

  describe "target related changes" do
    let!(:target) { base_project.new_target("com.apple.product-type.library.static", "foo", :ios) }

    it "moves file that is referenced by a target from main group to a new group" do
      file_reference = base_project.main_group.new_reference("bar")
      base_project.targets[0].source_build_phase.add_file_reference(file_reference)

      theirs_project = create_copy_of_project(base_project, "theirs")
      new_group = theirs_project.main_group.find_subpath("new_group", true)
      file_reference = theirs_project.main_group.find_file_by_path("bar")
      file_reference.move(new_group)
      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "keeps different files with the same name in their respective targets" do
      file_reference = base_project.main_group.new_reference("file1.swift")
      base_project.targets[0].source_build_phase.add_file_reference(file_reference)

      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      base_project.main_group.find_subpath("new_group", true).new_reference("file1.swift")

      theirs_project = create_copy_of_project(base_project, "theirs")
      second_target = theirs_project.targets[1]
      second_file_reference = theirs_project.main_group.find_subpath("new_group/file1.swift")
      second_target.source_build_phase.add_file_reference(second_file_reference)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)
      expect(base_project).to be_equivalent_to_project(theirs_project)
      expect(base_project.main_group.find_subpath("new_group/file1.swift").build_files).not_to be_empty
    end

    it "moves file that is referenced by a target from a group to the main group" do
      file_reference = base_project.main_group.find_subpath("new_group", true).new_reference("bar")
      base_project.targets[0].source_build_phase.add_file_reference(file_reference)

      theirs_project = create_copy_of_project(base_project, "theirs")
      file_reference = theirs_project["new_group/bar"]
      file_reference.move(theirs_project.main_group)
      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "moves file that is referenced by a target and has a different file encoding" do
      file_reference = base_project.main_group.find_subpath("new_group", true).new_reference("bar")
      target.frameworks_build_phase.add_file_reference(file_reference)

      theirs_project = create_copy_of_project(base_project, "theirs")
      file_reference = theirs_project["new_group/bar"]
      file_reference.move(theirs_project.main_group)
      file_reference.fileEncoding = "4"

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "changes framework from file reference to reference proxy" do
      framework_filename = "baz"

      file_reference = base_project.main_group.new_reference(framework_filename)
      base_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)

      add_new_subproject_to_project(base_project, "subproj", framework_filename)

      # Removes the container item proxy to make sure the display name of the reference proxy is the
      # same as the file reference.
      base_project.root_object.project_references[-1][:product_group].children[0].remote_ref.remove_from_project

      theirs_project = create_copy_of_project(base_project, "theirs")

      build_phase = theirs_project.targets[0].frameworks_build_phase
      build_phase.files.find { |build_file| build_file.display_name == "baz" }.remove_from_project
      build_phase.add_file_reference(
        theirs_project.root_object.project_references[0][:product_group].children[0]
      )

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds package product dependency to target" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.targets[0].package_product_dependencies <<
        create_swift_package_product_dependency(theirs_project)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds a build file that references a swift package product" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      build_file = theirs_project.new(Xcodeproj::Project::PBXBuildFile)
      build_file.product_ref = create_swift_package_product_dependency(theirs_project)
      theirs_project.targets[0].frameworks_build_phase.files << build_file

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "links a target and its build file to the same package product dependency" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      dependency = create_swift_package_product_dependency(theirs_project)
      theirs_project.targets[0].package_product_dependencies << dependency
      build_file = theirs_project.new(Xcodeproj::Project::PBXBuildFile)
      build_file.product_ref = dependency
      theirs_project.targets[0].frameworks_build_phase.files << build_file

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)

      # The dependency is shared, as Xcode writes it: the build file's product_ref is the very same
      # object as the target's package product dependency, not a duplicate.
      dependencies = base_project.objects.select { |o| o.isa == "XCSwiftPackageProductDependency" }
      expect(dependencies.count).to eq(1)
      product_build_file =
        base_project.targets[0].frameworks_build_phase.files.find(&:product_ref)
      expect(product_build_file.product_ref)
        .to equal(base_project.targets[0].package_product_dependencies.first)
    end

    it "shares one package reference between packageReferences and the product dependency" do
      # The shape Xcode writes when adding a package: the package reference sits on
      # rootObject.packageReferences, the product dependency's `package` points at that same object,
      # and the build file's product_ref points at the dependency.
      theirs_project = create_copy_of_project(base_project, "theirs")
      package_reference = theirs_project.new(Xcodeproj::Project::XCRemoteSwiftPackageReference)
      package_reference.repositoryURL = "https://github.com/example/pkg"
      package_reference.requirement = {"kind" => "upToNextMajorVersion", "minimumVersion" => "1.0.0"}
      theirs_project.root_object.package_references << package_reference
      dependency = theirs_project.new(Xcodeproj::Project::XCSwiftPackageProductDependency)
      dependency.package = package_reference
      dependency.product_name = "Example"
      theirs_project.targets[0].package_product_dependencies << dependency
      build_file = theirs_project.new(Xcodeproj::Project::PBXBuildFile)
      build_file.product_ref = dependency
      theirs_project.targets[0].frameworks_build_phase.files << build_file

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)

      # A single package reference object, shared by rootObject.packageReferences and the
      # dependency's `package`; a single dependency, linked by the build file.
      package_references = base_project.objects.select { |o| o.isa == "XCRemoteSwiftPackageReference" }
      dependencies = base_project.objects.select { |o| o.isa == "XCSwiftPackageProductDependency" }
      expect(package_references.count).to eq(1)
      expect(dependencies.count).to eq(1)
      expect(base_project.root_object.package_references.first).to equal(package_references.first)
      expect(dependencies.first.package).to equal(package_references.first)
      product_build_file =
        base_project.targets[0].frameworks_build_phase.files.find(&:product_ref)
      expect(product_build_file.product_ref).to equal(dependencies.first)
    end

    it "keeps a separate package product dependency per target for the same product" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.targets.each do |target|
        dependency = create_swift_package_product_dependency(theirs_project)
        target.package_product_dependencies << dependency
        build_file = theirs_project.new(Xcodeproj::Project::PBXBuildFile)
        build_file.product_ref = dependency
        target.frameworks_build_phase.files << build_file
      end

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)

      # Each target keeps its own dependency object -- Xcode does not share one across targets -- but
      # within a target the build file's product_ref is that same object.
      dependencies = base_project.objects.select { |o| o.isa == "XCSwiftPackageProductDependency" }
      expect(dependencies.count).to eq(2)
      base_project.targets.each do |target|
        product_build_file = target.frameworks_build_phase.files.find(&:product_ref)
        expect(product_build_file.product_ref).to equal(target.package_product_dependencies.first)
      end
    end

    it "keeps two products that share a name but come from different packages" do
      base_dependency = create_swift_package_product_dependency(base_project)
      base_project.targets[0].package_product_dependencies << base_dependency
      base_build_file = base_project.new(Xcodeproj::Project::PBXBuildFile)
      base_build_file.product_ref = base_dependency
      base_project.targets[0].frameworks_build_phase.files << base_build_file

      # theirs links a second product with the SAME product name but from a different package.
      theirs_project = create_copy_of_project(base_project, "theirs")
      other_package = theirs_project.new(Xcodeproj::Project::XCRemoteSwiftPackageReference)
      other_package.repositoryURL = "http://other"
      other_dependency = theirs_project.new(Xcodeproj::Project::XCSwiftPackageProductDependency)
      other_dependency.product_name = "foo"
      other_dependency.package = other_package
      theirs_project.targets[0].package_product_dependencies << other_dependency
      other_build_file = theirs_project.new(Xcodeproj::Project::PBXBuildFile)
      other_build_file.product_ref = other_dependency
      theirs_project.targets[0].frameworks_build_phase.files << other_build_file

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)

      # Both same-named products are distinct (different packages), so both survive, each linked by
      # its own build file -- a name-only dedup would have dropped the second build file.
      dependencies = base_project.objects.select { |o| o.isa == "XCSwiftPackageProductDependency" }
      expect(dependencies.count).to eq(2)
      product_build_files =
        base_project.targets[0].frameworks_build_phase.files.select(&:product_ref)
      expect(product_build_files.count).to eq(2)
    end

    it "attributes an added product build file to its own target despite a bare build file elsewhere" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      foo = base_project.targets.find { |target| target.display_name == "foo" }
      # foo already links the product, and also carries a bare (reference-less) build file, which is
      # value-equal to any freshly-created build file.
      foo.package_product_dependencies << create_swift_package_product_dependency(base_project)
      foo_build_file = base_project.new(Xcodeproj::Project::PBXBuildFile)
      foo_build_file.product_ref = foo.package_product_dependencies.first
      foo.frameworks_build_phase.files << foo_build_file
      foo.frameworks_build_phase.files << base_project.new(Xcodeproj::Project::PBXBuildFile)

      # theirs links the same product in bar.
      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_bar = theirs_project.targets.find { |target| target.display_name == "bar" }
      theirs_bar.package_product_dependencies << create_swift_package_product_dependency(theirs_project)
      bar_build_file = theirs_project.new(Xcodeproj::Project::PBXBuildFile)
      bar_build_file.product_ref = theirs_bar.package_product_dependencies.first
      theirs_bar.frameworks_build_phase.files << bar_build_file

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)

      # bar's build file must link bar's own dependency, not foo's (a value-based target lookup would
      # attribute it to foo via foo's bare build file, collapsing the two targets' dependencies).
      merged_bar = base_project.targets.find { |target| target.display_name == "bar" }
      bar_reference = merged_bar.frameworks_build_phase.files.map(&:product_ref).compact.first
      expect(merged_bar.package_product_dependencies).to include(bar_reference)
      expect(base_project.objects.count { |o| o.isa == "XCSwiftPackageProductDependency" }).to eq(2)
    end

    it "changes framework from reference proxy to file reference" do
      framework_filename = "baz"

      add_new_subproject_to_project(base_project, "subproj", framework_filename)
      subproject_reference_proxy =
        base_project.root_object.project_references[0][:product_group].children[0]
      # Removes the container item proxy to make sure the display name of the reference proxy is the
      # same as the file reference.
      subproject_reference_proxy.remote_ref.remove_from_project
      base_project.targets[0].frameworks_build_phase.add_file_reference(subproject_reference_proxy)


      theirs_project = create_copy_of_project(base_project, "theirs")

      file_reference = theirs_project.main_group.new_reference("bar")
      file_reference.name = framework_filename
      build_phase = theirs_project.targets[0].frameworks_build_phase
      build_phase.files[-1].remove_from_project
      theirs_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)
      # This verifies we haven't created a new file reference instead of reusing the one in the
      # hierarchy.
      base_project.files[-1].name = "foo"
      theirs_project.files[-1].name = "foo"

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds remote ref to reference proxy" do
      framework_filename = "baz"

      add_new_subproject_to_project(base_project, "subproj", framework_filename)
      build_file = base_project.targets[0].frameworks_build_phase.add_file_reference(
        base_project.root_object.project_references[0][:product_group].children[0]
      )
      container_proxy = build_file.file_ref.remote_ref
      build_file.file_ref.remote_ref = nil


      theirs_project = create_copy_of_project(base_project, "theirs")

      theirs_project.targets[0].frameworks_build_phase.files[-1].file_ref.remote_ref =
        container_proxy

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds subproject target and adds reference to it" do
      framework_filename = "baz"
      subproject = add_new_subproject_to_project(base_project, "subproj", framework_filename)

      theirs_project = create_copy_of_project(base_project, "theirs")

      subproject.new_target("com.apple.product-type.library.static", "bari", :ios)

      theirs_project.root_object.project_references[0][:product_group] <<
        create_reference_proxy_from_product_reference(theirs_project,
                                                      theirs_project.root_object.project_references[0][:project_ref],
                                                      subproject.products_group.files[-1])

      build_phase = theirs_project.targets[0].frameworks_build_phase
      build_phase.add_file_reference(
        theirs_project.root_object.project_references[0][:product_group].children[-1]
      )

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds new build file" do
      base_project.main_group.new_reference("bar")

      theirs_project = create_copy_of_project(base_project, "theirs")

      file_reference = theirs_project.main_group.files.find { |file| file.display_name == "bar" }
      theirs_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
    end

    it "adds build when there is a build file without file ref" do
      target = base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
      target.frameworks_build_phase.add_file_reference(nil)

      theirs_project = create_copy_of_project(base_project, "theirs")
      file_reference = theirs_project.main_group.new_reference("bar")
      theirs_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)

      changes_to_apply = get_diff(theirs_project, base_project)
      other_project = create_copy_of_project(base_project, "theirs")
      described_class.apply_change_to_project(other_project, changes_to_apply, theirs_project)

      expect(other_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds product ref to build file" do
      base_project.main_group.new_reference("bar")

      theirs_project = create_copy_of_project(base_project, "theirs")

      file_reference = theirs_project.main_group.files.find { |file| file.display_name == "bar" }
      build_file =
        theirs_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)
      build_file.product_ref =
        create_swift_package_product_dependency(theirs_project)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
    end

    it "adds build file to a file reference that already exists" do
      base_project.main_group.new_reference("bar")
      base_project.main_group.new_reference("bar")

      theirs_project = create_copy_of_project(base_project, "theirs")

      theirs_file_reference = theirs_project.main_group.files.find do |file|
        !file.referrers.find { |referrer| referrer.is_a?(Xcodeproj::Project::PBXBuildFile) } &&
          file.display_name == "bar"
      end
      theirs_project.targets[0].frameworks_build_phase.add_file_reference(theirs_file_reference)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds file reference to build file" do
      file_reference = base_project.main_group.new_reference("bar")
      build_file = base_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)
      build_file.file_ref = nil

      theirs_project = create_copy_of_project(base_project, "theirs")

      file_reference = theirs_project.main_group.files.find { |file| file.display_name == "bar" }
      theirs_project.targets[0].frameworks_build_phase.files[-1].file_ref = file_reference

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
    end

    it "ignores build file without file reference" do
      base_project.main_group.new_reference("bar")

      theirs_project = create_copy_of_project(base_project, "theirs")
      file_reference = theirs_project.main_group.files.find { |file| file.display_name == "bar" }
      build_file =
        theirs_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)
      build_file.file_ref = nil

      changes_to_apply = get_diff(theirs_project, base_project)

      other_project = create_copy_of_project(base_project, "other")
      described_class.apply_change_to_project(other_project, changes_to_apply, theirs_project)

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "adds new build rule" do
      theirs_project = create_copy_of_project(base_project, "theirs")

      build_rule = theirs_project.new(Xcodeproj::Project::PBXBuildRule)
      build_rule.compiler_spec = "com.apple.compilers.proxy.script"
      build_rule.file_type = "pattern.proxy"
      build_rule.file_patterns = "*.json"
      build_rule.is_editable = "1"
      build_rule.input_files = [
        "$(DERIVED_FILE_DIR)/$(arch)/${INPUT_FILE_BASE}.json"
      ]
      build_rule.output_files = [
        "$(DERIVED_FILE_DIR)/$(arch)/${INPUT_FILE_BASE}.h",
        "$(DERIVED_FILE_DIR)/$(arch)/${INPUT_FILE_BASE}.mm"
      ]
      build_rule.script = "foo"
      theirs_project.targets[0].build_rules << build_rule

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
    end

    describe "build settings" do
      it "adds new string build setting" do
        theirs_project = create_copy_of_project(base_project, "theirs")

        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "$(SRCROOT)/../Bar"
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "adds new array build setting" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = {}
        end
        theirs_project = create_copy_of_project(base_project, "theirs")

        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = [
            "$(SRCROOT)/../Foo",
            "$(SRCROOT)/../Bar"
          ]
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "adds new hash build setting" do
        theirs_project = create_copy_of_project(base_project, "theirs")

        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = [
            "$(SRCROOT)/../Foo",
            "$(SRCROOT)/../Bar"
          ]
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "adds values to existing array build setting" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = [
            "$(SRCROOT)/../Foo"
          ]
        end

        theirs_project = create_copy_of_project(base_project, "theirs")

        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = [
            "$(SRCROOT)/../Foo",
            "$(SRCROOT)/../Bar"
          ]
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "adds array value to an existing string if no removed value" do
        theirs_project = create_copy_of_project(base_project, "theirs")

        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar foo]
        end
        changes_to_apply = get_diff(theirs_project, base_project)

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "baz"
        end

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expected_project = create_copy_of_project(base_project, "expected")
        expected_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar foo baz]
        end
        expect(ours_project).to be_equivalent_to_project(expected_project)
      end

      it "adds string value to existing array value if no removed value" do
        theirs_project = create_copy_of_project(base_project, "theirs")

        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "baz"
        end
        changes_to_apply = get_diff(theirs_project, base_project)

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar foo]
        end

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expected_project = create_copy_of_project(base_project, "expected")
        expected_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar foo baz]
        end
        expect(ours_project).to be_equivalent_to_project(expected_project)
      end

      it "removes array build setting" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = [
            "$(SRCROOT)/../Foo",
            "$(SRCROOT)/../Bar"
          ]
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = nil
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "removes string build setting" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings =
            configuration.build_settings.reject { |key, _| key == "HEADER_SEARCH_PATHS" }
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "removes hash build setting" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = nil
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "removes hash build setting if removed hash contains the existing hash" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
          configuration.build_settings["foo"] = "baz"
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = nil
        end

        ours_project = create_copy_of_project(base_project, "theirs")
        ours_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["foo"] = nil
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "removes value if existing is string and removed is array that contains it" do
        theirs_project = create_copy_of_project(base_project, "theirs")

        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end

        before_theirs_project = create_copy_of_project(base_project, "before_theirs")
        before_theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = ["bar"]
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "removes value if removed value is string and existing is array that contains it" do
        theirs_project = create_copy_of_project(base_project, "theirs")

        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = ["bar"]
        end

        before_theirs_project = create_copy_of_project(base_project, "before_theirs")
        before_theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "removes value if existing is string and removed is array that contains it among other " \
          "values" do
        theirs_project = create_copy_of_project(base_project, "theirs")

        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end

        before_theirs_project = create_copy_of_project(base_project, "before_theirs")
        before_theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar baz]
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expected_project = create_copy_of_project(base_project, "expected")
        expected_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = nil
        end
        expect(base_project).to be_equivalent_to_project(expected_project)
      end

      it "changes to a single string value if removed is string and existing is array that " \
          "contains it among another value" do
        theirs_project = create_copy_of_project(base_project, "theirs")

        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar baz]
        end

        before_theirs_project = create_copy_of_project(base_project, "before_theirs")
        before_theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expected_project = create_copy_of_project(base_project, "expected")
        expected_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "baz"
        end
        expect(base_project).to be_equivalent_to_project(expected_project)
      end

      it "changes to string value if change contains removal of existing array" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar foo]
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "baz"
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "changes to array value if change contains removal of existing string" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[baz foo]
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "changes to array if added value is string and existing is another string and removal is" \
          "nil for an array build setting" do
        before_theirs_project = create_copy_of_project(base_project, "theirs")

        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end

        theirs_project = create_copy_of_project(base_project, "before_theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "baz"
        end

        expected_project = create_copy_of_project(base_project, "expected")
        expected_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar baz]
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

        expect(base_project).to be_equivalent_to_project(expected_project)
      end

      it "raises if added value is string and existing is another string and removal is nil for a " \
          "string build setting" do
        before_theirs_project = create_copy_of_project(base_project, "theirs")

        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["PRODUCT_NAME"] = "bar"
        end

        theirs_project = create_copy_of_project(base_project, "before_theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["PRODUCT_NAME"] = "baz"
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        expect {
          described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)
        }.to raise_error(Kintsugi::MergeError)
      end

      it "raises if trying to remove hash entry whose value changed" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = nil
        end

        before_theirs_project = create_copy_of_project(base_project, "theirs")
        before_theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "baz"
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        expect {
          described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)
        }.to raise_error(Kintsugi::MergeError)
      end
    end

    it "adds build phases" do
      theirs_project = create_copy_of_project(base_project, "theirs")

      theirs_project.targets[0].new_shell_script_build_phase("bar")
      theirs_project.targets[0].source_build_phase
      theirs_project.targets[0].headers_build_phase
      theirs_project.targets[0].frameworks_build_phase
      theirs_project.targets[0].resources_build_phase
      theirs_project.targets[0].new_copy_files_build_phase("baz")

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds build phase with a simple attribute value that has non nil default" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.targets[0].new_shell_script_build_phase("bar")
      theirs_project.targets[0].build_phases.last.shell_script = "Other value"

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "removes build phase" do
      base_project.targets[0].new_shell_script_build_phase("bar")

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.targets[0].shell_script_build_phases[0].remove_from_project

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "ignores localizations in build settings added to existing localization files" do
      variant_group = base_project.main_group.new_variant_group("foo.strings")
      file = variant_group.new_reference("Base")
      file.last_known_file_type = "text.plist.strings"
      target.resources_build_phase.add_file_reference(variant_group)

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_variant_group = theirs_project.main_group.find_subpath("foo.strings")
      theirs_variant_group.new_reference("en")

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds target dependency" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.targets[1].add_dependency(theirs_project.targets[0])

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "changes value of a string build setting" do
      base_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["GCC_PREFIX_HEADER"] = "foo"
      end

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["GCC_PREFIX_HEADER"] = "bar"
      end

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds build settings to new target" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      theirs_project.targets[1].build_configurations.each do |configuration|
        configuration.build_settings["GCC_PREFIX_HEADER"] = "baz"
      end

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds base configuration reference" do
      base_project.main_group.new_reference("baz")

      theirs_project = create_copy_of_project(base_project, "theirs")
      configuration_reference = theirs_project.main_group.find_subpath("baz")
      theirs_project.targets[0].build_configurations.each do |configuration|
        configuration.base_configuration_reference = configuration_reference
      end

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds base configuration reference to new configuration in a new list" do
      base_project.main_group.new_reference("baz")
      base_project.targets[0].build_configuration_list = nil

      theirs_project = create_copy_of_project(base_project, "theirs")
      configuration_reference = theirs_project.main_group.find_subpath("baz")

      configuration_list = theirs_project.new(Xcodeproj::Project::XCConfigurationList)
      theirs_project.targets[0].build_configuration_list = configuration_list

      build_configuration = theirs_project.new(Xcodeproj::Project::XCBuildConfiguration)
      build_configuration.base_configuration_reference = configuration_reference
      configuration_list.build_configurations << build_configuration

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end
  end

  it "adds known regions" do
    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.root_object.known_regions += ["fr"]

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "removes known regions" do
    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.root_object.known_regions = nil

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds attribute target changes even if target attributes don't exist" do
    theirs_project = create_copy_of_project(base_project, "theirs")

    theirs_project.root_object.attributes["TargetAttributes"] =
      {"foo" => {"LastSwiftMigration" => "1140"}}

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds attribute target changes of new target" do
    base_project.root_object.attributes["TargetAttributes"] = {}

    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.root_object.attributes["TargetAttributes"] =
      {"foo" => {"LastSwiftMigration" => "1140"}}

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds attribute target changes of existing target" do
    base_project.root_object.attributes["TargetAttributes"] = {"foo" => {}}

    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.root_object.attributes["TargetAttributes"] =
      {"foo" => {"LastSwiftMigration" => "1140"}}

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "removes attribute target changes" do
    base_project.root_object.attributes["TargetAttributes"] =
      {"foo" => {"LastSwiftMigration" => "1140"}}

    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.root_object.attributes["TargetAttributes"]["foo"] = {}

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "removes attribute target changes from a project it was removed from already" do
    base_project.root_object.attributes["TargetAttributes"] =
      {"foo" => {"LastSwiftMigration" => "1140"}}

    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.root_object.attributes["TargetAttributes"]["foo"] = {}

    ours_project = create_copy_of_project(base_project, "ours")
    ours_project.root_object.attributes["TargetAttributes"]["foo"] = {}

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

    expect(ours_project).to be_equivalent_to_project(theirs_project)
  end

  it "doesn't throw if existing attribute target change is same as added change" do
    base_project.root_object.attributes["TargetAttributes"] = {"foo" => "1140"}

    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.root_object.attributes["TargetAttributes"]["foo"] = "1111"

    ours_project = create_copy_of_project(base_project, "ours")
    ours_project.root_object.attributes["TargetAttributes"]["foo"] = "1111"

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

    expect(ours_project).to be_equivalent_to_project(theirs_project)
  end

  it "identifies subproject added at separate times when adding a product to the subproject" do
    framework_filename = "baz"

    subproject = new_subproject("subproj", framework_filename)

    add_existing_subproject_to_project(base_project, subproject, framework_filename)

    theirs_project_path = make_temp_directory("theirs", ".xcodeproj")
    theirs_project = Xcodeproj::Project.new(theirs_project_path)
    add_existing_subproject_to_project(theirs_project, subproject, framework_filename)
    ours_project = create_copy_of_project(theirs_project, "other_theirs")

    subproject.new_target("com.apple.product-type.library.static", "bari", :ios)
    ours_project.root_object.project_references[0][:product_group] <<
      create_reference_proxy_from_product_reference(theirs_project,
                                                    theirs_project.root_object.project_references[0][:project_ref],
                                                    subproject.products_group.files[-1])

    changes_to_apply = get_diff(ours_project, theirs_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(ours_project, ignore_keys: ["containerPortal"])
  end

  it "adds localization files" do
    base_project_path = make_temp_directory("base", ".xcodeproj")
    base_project = Xcodeproj::Project.new(base_project_path)
    base_project.new_target("com.apple.product-type.library.static", "foo", :ios)

    theirs_project = create_copy_of_project(base_project, "theirs")

    variant_group = theirs_project.main_group.new_variant_group("foo.strings")
    variant_group.new_reference("Base").last_known_file_type = "text.plist.strings"
    theirs_project.targets[0].resources_build_phase.add_file_reference(variant_group)

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds build configuration list" do
    base_project.root_object.build_configuration_list = nil

    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.root_object.build_configuration_list =
      theirs_project.new(Xcodeproj::Project::XCConfigurationList)

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)
    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "removes build configuration list" do
    theirs_project = create_copy_of_project(base_project, "theirs")
    theirs_project.build_configuration_list.remove_from_project

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)
    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds group to product group" do
    base_project_path = make_temp_directory("base", ".xcodeproj")
    base_project = Xcodeproj::Project.new(base_project_path)
    base_project.new_target("com.apple.product-type.library.static", "foo", :ios)

    theirs_project = create_copy_of_project(base_project, "theirs")

    theirs_project.root_object.product_ref_group.new_group("foo")

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds localization files to product group" do
    base_project_path = make_temp_directory("base", ".xcodeproj")
    base_project = Xcodeproj::Project.new(base_project_path)
    base_project.new_target("com.apple.product-type.library.static", "foo", :ios)

    theirs_project = create_copy_of_project(base_project, "theirs")

    variant_group = theirs_project.root_object.product_ref_group.new_variant_group("foo.strings")
    variant_group.new_reference("Base").last_known_file_type = "text.plist.strings"

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  describe "avoiding duplicate references to the same component" do
    it "avoids adding file reference that already exists" do
      base_project.main_group.new_reference("bar")

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.main_group.new_reference("bar")

      changes_to_apply = get_diff(theirs_project, base_project)
      other_project = create_copy_of_project(base_project, "theirs")
      described_class.apply_change_to_project(other_project, changes_to_apply, theirs_project)

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "avoids adding group that already exists" do
      base_project.main_group.new_group("bar")

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.main_group.new_group("bar")

      changes_to_apply = get_diff(theirs_project, base_project)
      other_project = create_copy_of_project(base_project, "theirs")
      described_class.apply_change_to_project(other_project, changes_to_apply, theirs_project)

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "avoids adding variant group that already exists" do
      base_project.main_group.new_variant_group("bar")

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.main_group.new_variant_group("bar")

      changes_to_apply = get_diff(theirs_project, base_project)
      other_project = create_copy_of_project(base_project, "theirs")
      described_class.apply_change_to_project(other_project, changes_to_apply, theirs_project)

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "avoids adding subproject that already exists" do
      theirs_project = create_copy_of_project(base_project, "theirs")

      subproject = add_new_subproject_to_project(theirs_project, "foo", "foo")

      ours_project = create_copy_of_project(base_project, "ours")
      add_existing_subproject_to_project(ours_project, subproject, "foo")

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

      expect(ours_project.root_object.project_references.count).to equal(1)
    end

    it "avoids adding build file that already exists" do
      file_reference = base_project.main_group.new_reference("bar")
      target = base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
      target.frameworks_build_phase.add_file_reference(file_reference)

      theirs_project = create_copy_of_project(base_project, "theirs")
      file_reference = theirs_project.main_group.new_reference("bar")
      theirs_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)

      changes_to_apply = get_diff(theirs_project, base_project)
      other_project = create_copy_of_project(base_project, "theirs")
      described_class.apply_change_to_project(other_project, changes_to_apply, theirs_project)

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "avoids adding reference proxy that already exists" do
      framework_filename = "baz"
      subproject = add_new_subproject_to_project(base_project, "subproj", framework_filename)

      theirs_project = create_copy_of_project(base_project, "theirs")

      theirs_project.root_object.project_references[0][:product_group] <<
        create_reference_proxy_from_product_reference(theirs_project,
                                                      theirs_project.root_object.project_references[0][:project_ref],
                                                      subproject.products_group.files[-1])


      changes_to_apply = get_diff(theirs_project, base_project)

      other_project = create_copy_of_project(base_project, "theirs")
      described_class.apply_change_to_project(other_project, changes_to_apply, theirs_project)

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "keeps array if adding string value that already exists in array" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
      end
      changes_to_apply = get_diff(theirs_project, base_project)

      ours_project = create_copy_of_project(base_project, "ours")
      ours_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar foo]
      end

      expected_project = create_copy_of_project(ours_project, "expected")

      described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

      expect(ours_project).to be_equivalent_to_project(expected_project)
    end
  end

  describe "allowing adding reference to the same component" do
    before do
      Kintsugi::Settings.allow_duplicates = true
    end

    after do
      Kintsugi::Settings.allow_duplicates = false
    end

    it "adds subproject that already exists" do
      theirs_project = create_copy_of_project(base_project, "theirs")

      subproject = add_new_subproject_to_project(theirs_project, "foo", "foo")

      ours_project = create_copy_of_project(base_project, "ours")
      add_existing_subproject_to_project(ours_project, subproject, "foo")

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

      expect(ours_project.root_object.project_references[0][:project_ref].uuid)
        .not_to equal(ours_project.root_object.project_references[1][:project_ref].uuid)
      expect(ours_project.root_object.project_references[0][:project_ref].proxy_containers).not_to be_empty
      expect(ours_project.root_object.project_references[1][:project_ref].proxy_containers).not_to be_empty
    end
  end

  describe "resolving conflicts interactively" do
    let(:test_prompt) { TTY::Prompt::Test.new }

    before do
      Kintsugi::Settings.interactive_resolution = true
      allow(TTY::Prompt).to receive(:new).and_return(test_prompt)
      test_prompt.setup
    end

    after do
      Kintsugi::Settings.interactive_resolution = false
    end

    describe "adding group to a non existent group" do
      it "creates the non existent group" do
        test_prompt.choose_option(0)

        base_project.main_group.find_subpath("new_group", true)

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project["new_group"].find_subpath("sub_group", true)

        changes_to_apply = get_diff(theirs_project, base_project)

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.main_group.find_subpath("new_group").remove_from_project

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)
        expect(ours_project).to be_equivalent_to_project(theirs_project)
      end

      it "ignores adding the group" do
        test_prompt.choose_option(1)

        base_project.main_group.find_subpath("new_group", true)

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project["new_group"].find_subpath("sub_group", true)

        changes_to_apply = get_diff(theirs_project, base_project)

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.main_group.find_subpath("new_group").remove_from_project
        expected_project = create_copy_of_project(ours_project, "expected")

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)
        expect(ours_project).to be_equivalent_to_project(expected_project)
      end
    end

    describe "adding file to a non existent group" do
      it "creates the non existent group" do
        test_prompt.choose_option(0)

        base_project.main_group.find_subpath("new_group", true)

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project["new_group"].new_reference("foo/bar")

        changes_to_apply = get_diff(theirs_project, base_project)

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.main_group.find_subpath("new_group").remove_from_project

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)
        expect(ours_project).to be_equivalent_to_project(theirs_project)
      end

      it "ignores adding the file" do
        test_prompt.choose_option(1)

        base_project.main_group.find_subpath("new_group", true)

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project["new_group"].new_reference("foo/bar")

        changes_to_apply = get_diff(theirs_project, base_project)

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.main_group.find_subpath("new_group").remove_from_project
        expected_project = create_copy_of_project(ours_project, "expected")

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)
        expect(ours_project).to be_equivalent_to_project(expected_project)
      end
    end

    describe "changing a group that was already removed" do
      it "creates the group and applies changes to it" do
        test_prompt.choose_option(0)

        base_project.main_group.find_subpath("some_group", true)

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.main_group.find_subpath("some_group").remove_from_project

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.main_group.find_subpath("some_group").source_tree = "SDKROOT"

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(theirs_project)
      end

      it "ignores changes to group" do
        test_prompt.choose_option(1)

        base_project.main_group.find_subpath("some_group", true)

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.main_group.find_subpath("some_group").remove_from_project

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.main_group.find_subpath("some_group").source_tree = "SDKROOT"

        changes_to_apply = get_diff(theirs_project, base_project)

        expected_project = create_copy_of_project(ours_project, "expected")

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(expected_project)
      end
    end

    describe "changing a component that was already removed" do
      it "creates the component and applies changes to it" do
        test_prompt.choose_option(0)

        base_project.new_target("com.apple.product-type.library.static", "foo", :ios)

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.targets[0].product_reference.remove_from_project

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].product_reference.source_tree = "SDKROOT"

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(theirs_project)
      end

      it "ignores changes to component" do
        test_prompt.choose_option(1)

        base_project.new_target("com.apple.product-type.library.static", "foo", :ios)

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.targets[0].product_reference.remove_from_project

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].product_reference.source_tree = "SDKROOT"

        changes_to_apply = get_diff(theirs_project, base_project)

        expected_project = create_copy_of_project(ours_project, "expected")

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(expected_project)
      end
    end

    describe "changing a file reference that has a build file and both were already removed" do
      it "creates the component and its build file and applies changes to it" do
        test_prompt.choose_option(0)

        file_reference_name = "bar"

        file_reference = base_project.main_group.new_reference(file_reference_name)
        target = base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
        target.source_build_phase.add_file_reference(file_reference)

        ours_project = create_copy_of_project(base_project, "ours")
        build_file = ours_project.targets[0].source_build_phase.files[-1]
        # Removing the build file first is done because prior to xcodeproj 1.22, the build file was
        # not removed when its file reference was removed.
        build_file.remove_from_project
        ours_project.main_group.find_subpath(file_reference_name).remove_from_project

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.main_group.find_subpath(file_reference_name).source_tree = "SDKROOT"

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(theirs_project)
      end

      it "ignores changes to component and to its build file" do
        test_prompt.choose_option(1)

        file_reference_name = "bar"

        file_reference = base_project.main_group.new_reference(file_reference_name)
        target = base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
        target.source_build_phase.add_file_reference(file_reference)

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.main_group.find_subpath(file_reference_name).remove_from_project

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.main_group.find_subpath(file_reference_name).source_tree = "SDKROOT"

        changes_to_apply = get_diff(theirs_project, base_project)

        expected_project = create_copy_of_project(ours_project, "expected")

        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(expected_project)
      end
    end

    describe "adding entry to a hash that has another value for the same key" do
      it "overrides values from new hash" do
        # There will be two conflicts, one for each configuration.
        test_prompt.choose_option(0, repeating: 2)

        base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = nil
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = {"HEADER_SEARCH_PATHS" => "bar"}
        end

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = {"HEADER_SEARCH_PATHS" => "baz"}
        end

        changes_to_apply = get_diff(theirs_project, base_project)
        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(theirs_project)
      end

      it "keeps values from old hash" do
        # There will be two conflicts, one for each configuration.
        test_prompt.choose_option(1, repeating: 2)

        base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = nil
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = {"HEADER_SEARCH_PATHS" => "bar"}
        end

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = {"HEADER_SEARCH_PATHS" => "baz"}
        end
        expected_project = create_copy_of_project(ours_project, "expected")

        changes_to_apply = get_diff(theirs_project, base_project)
        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(expected_project)
      end
    end

    describe "trying to remove entry from a hash that has another value for the same key" do
      it "removes the key" do
        # There will be two conflicts, one for each configuration.
        test_prompt.choose_option(0, repeating: 2)

        base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = {"HEADER_SEARCH_PATHS" => "bar"}
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = nil
        end

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = {"HEADER_SEARCH_PATHS" => "baz"}
        end

        changes_to_apply = get_diff(theirs_project, base_project)
        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expected_project = create_copy_of_project(base_project, "expected")
        expected_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = {}
        end
        expect(ours_project).to be_equivalent_to_project(expected_project)
      end

      it "keeps the key" do
        # There will be two conflicts, one for each configuration.
        test_prompt.choose_option(1, repeating: 2)

        base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = {"HEADER_SEARCH_PATHS" => "bar"}
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = nil
        end

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = {"HEADER_SEARCH_PATHS" => "baz"}
        end
        expected_project = create_copy_of_project(ours_project, "expected")

        changes_to_apply = get_diff(theirs_project, base_project)
        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(expected_project)
      end
    end

    describe "trying to change string value that has another existing value" do
      it "replaces the string with the new value" do
        # There will be two conflicts, one for each configuration.
        test_prompt.choose_option(0, repeating: 2)

        base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["PRODUCT_NAME"] = "old"
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["PRODUCT_NAME"] = "new"
        end

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["PRODUCT_NAME"] = "existing"
        end

        changes_to_apply = get_diff(theirs_project, base_project)
        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(theirs_project)
      end

      it "keeps the existing value" do
        # There will be two conflicts, one for each configuration.
        test_prompt.choose_option(1, repeating: 2)

        base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["PRODUCT_NAME"] = "old"
        end

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["PRODUCT_NAME"] = "new"
        end

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["PRODUCT_NAME"] = "existing"
        end
        expected_project = create_copy_of_project(ours_project, "expected")

        changes_to_apply = get_diff(theirs_project, base_project)
        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(expected_project)
      end
    end

    describe "trying to remove a component with different attributes" do
      it "removes the component anyway" do
        test_prompt.choose_option(0)

        base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
        base_project.targets[0].new_shell_script_build_phase("bar")

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].shell_script_build_phases[0].remove_from_project

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.targets[0].shell_script_build_phases[0].shell_script = "foo"

        changes_to_apply = get_diff(theirs_project, base_project)
        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(theirs_project)
      end

      it "keeps the component" do
        test_prompt.choose_option(1)

        base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
        base_project.targets[0].new_shell_script_build_phase("bar")

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_project.targets[0].shell_script_build_phases[0].remove_from_project

        ours_project = create_copy_of_project(base_project, "ours")
        ours_project.targets[0].shell_script_build_phases[0].shell_script = "foo"

        expected_project = create_copy_of_project(ours_project, "expected")

        changes_to_apply = get_diff(theirs_project, base_project)
        described_class.apply_change_to_project(ours_project, changes_to_apply, theirs_project)

        expect(ours_project).to be_equivalent_to_project(expected_project)
      end
    end
  end

  describe "file system synchronized groups" do
    before do
      base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
    end

    def add_synchronized_root_group(project, path, source_tree: "<group>")
      group = project.new(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
      group.source_tree = source_tree
      group.path = path
      project.main_group.children << group
      group
    end

    it "adds a file system synchronized root group to the main group" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      add_synchronized_root_group(theirs_project, "SyncedSources")

      changes_to_apply = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds a file system synchronized root group referenced by a target" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      group = add_synchronized_root_group(theirs_project, "SyncedSources")
      theirs_project.targets[0].file_system_synchronized_groups << group

      changes_to_apply = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)

      # `be_equivalent_to_project` compares tree hashes (attributes only), so it can't detect a
      # duplicated object. Assert that the target reuses the exact same object that was created in
      # the group tree, rather than a second root group with the same attributes.
      synchronized_groups = base_project.objects.select do |object|
        object.isa == "PBXFileSystemSynchronizedRootGroup"
      end
      expect(synchronized_groups.count).to eq(1)
      expect(base_project.targets[0].file_system_synchronized_groups.first)
        .to equal(synchronized_groups.first)
    end

    it "adds a synchronized root group with explicit file types and folders" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      group = add_synchronized_root_group(theirs_project, "SyncedSources")
      group.explicit_file_types = {"*.md" => "text"}
      group.explicit_folders = ["Fixtures"]
      theirs_project.targets[0].file_system_synchronized_groups << group

      changes_to_apply = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds a synchronized root group with build file exceptions" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      group = add_synchronized_root_group(theirs_project, "SyncedSources")
      theirs_project.targets[0].file_system_synchronized_groups << group
      exception_set =
        theirs_project.new(Xcodeproj::Project::PBXFileSystemSynchronizedBuildFileExceptionSet)
      exception_set.target = theirs_project.targets[0]
      exception_set.membership_exceptions = ["Excluded.swift"]
      group.exceptions << exception_set

      changes_to_apply = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
      resolved = base_project.objects.find do |object|
        object.isa == "PBXFileSystemSynchronizedBuildFileExceptionSet"
      end
      expect(resolved.target).to equal(base_project.targets[0])
    end

    it "adds a synchronized root group with build phase membership exceptions" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      group = add_synchronized_root_group(theirs_project, "SyncedSources")
      theirs_project.targets[0].file_system_synchronized_groups << group
      klass = Xcodeproj::Project::PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet
      exception_set = theirs_project.new(klass)
      exception_set.build_phase = theirs_project.targets[0].source_build_phase
      exception_set.membership_exceptions = ["OnlyInSources.swift"]
      group.exceptions << exception_set

      changes_to_apply = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "removes a file system synchronized root group" do
      group = add_synchronized_root_group(base_project, "SyncedSources")
      base_project.targets[0].file_system_synchronized_groups << group

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.main_group.children
                    .find { |child| child.display_name == "SyncedSources" }
                    .remove_from_project

      changes_to_apply = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes_to_apply, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
      expect(base_project.objects.count { |o| o.isa == "PBXFileSystemSynchronizedRootGroup" })
        .to eq(0)
    end

    it "unlinks a folder from one target without deleting it for the others" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      group = add_synchronized_root_group(base_project, "Shared")
      base_project.targets.each { |target| target.file_system_synchronized_groups << group }

      theirs_project = create_copy_of_project(base_project, "theirs")
      foo = theirs_project.targets.find { |target| target.display_name == "foo" }
      foo.file_system_synchronized_groups.delete(foo.file_system_synchronized_groups.first)

      changes = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
      # The shared folder must survive: only foo's link is removed; bar keeps it and it stays in
      # the main group (removing a target reference must not delete the shared object).
      expect(base_project.objects.count { |o| o.isa == "PBXFileSystemSynchronizedRootGroup" })
        .to eq(1)
      expect(base_project.targets.find { |t| t.display_name == "foo" }
                          .file_system_synchronized_groups).to be_empty
      expect(base_project.targets.find { |t| t.display_name == "bar" }
                          .file_system_synchronized_groups.count).to eq(1)
    end

    it "keeps a folder shared by three targets when one unlinks it" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      base_project.new_target("com.apple.product-type.library.static", "baz", :ios)
      group = add_synchronized_root_group(base_project, "Shared")
      base_project.targets.each { |target| target.file_system_synchronized_groups << group }

      theirs_project = create_copy_of_project(base_project, "theirs")
      foo = theirs_project.targets.find { |target| target.display_name == "foo" }
      foo.file_system_synchronized_groups.delete(foo.file_system_synchronized_groups.first)

      changes = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
      expect(base_project.objects.count { |o| o.isa == "PBXFileSystemSynchronizedRootGroup" })
        .to eq(1)
      %w[bar baz].each do |name|
        expect(base_project.targets.find { |t| t.display_name == name }
                            .file_system_synchronized_groups.count).to eq(1)
      end
    end

    it "removes a folder shared by two targets and unlinks both in one change" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      group = add_synchronized_root_group(base_project, "Shared")
      base_project.targets.each { |target| target.file_system_synchronized_groups << group }

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.main_group.children
                    .find { |child| child.display_name == "Shared" }
                    .remove_from_project

      changes = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
      expect(base_project.objects.count { |o| o.isa == "PBXFileSystemSynchronizedRootGroup" })
        .to eq(0)
      base_project.targets.each do |target|
        expect(target.file_system_synchronized_groups).to be_empty
      end
    end

    it "resolves a same-named folder when another candidate is not in the group tree" do
      # A buildable folder linked by two targets but absent from the main group has no parent, so
      # its hierarchy_path raises; resolution must tolerate it rather than aborting the merge.
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      groupless = base_project.new(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
      groupless.source_tree = "<group>"
      groupless.path = "Shared"
      base_project.targets.each { |target| target.file_system_synchronized_groups << groupless }

      theirs_project = create_copy_of_project(base_project, "theirs")
      feature = theirs_project.main_group.new_group("FeatureA")
      real_group = theirs_project.new(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
      real_group.source_tree = "<group>"
      real_group.path = "Shared"
      feature << real_group
      theirs_project.targets.find { |t| t.display_name == "foo" }
                    .file_system_synchronized_groups << real_group

      changes = get_diff(theirs_project, base_project)
      expect {
        described_class.apply_change_to_project(base_project, changes, theirs_project)
      }.not_to raise_error

      # The new FeatureA/Shared is linked in addition to the pre-existing group-tree-less folder.
      expect(base_project.targets.find { |t| t.display_name == "foo" }
                          .file_system_synchronized_groups.count).to eq(2)
    end

    it "avoids adding a synchronized root group that already exists" do
      existing_group = add_synchronized_root_group(base_project, "SyncedSources")
      base_project.targets[0].file_system_synchronized_groups << existing_group

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_group = add_synchronized_root_group(theirs_project, "SyncedSources")
      theirs_project.targets[0].file_system_synchronized_groups << theirs_group

      changes_to_apply = get_diff(theirs_project, base_project)
      other_project = create_copy_of_project(base_project, "other")
      described_class.apply_change_to_project(other_project, changes_to_apply, theirs_project)

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "resolves an exception target added in the same change" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      target = theirs_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      group = add_synchronized_root_group(theirs_project, "SyncedSources")
      target.file_system_synchronized_groups << group

      klass = Xcodeproj::Project::PBXFileSystemSynchronizedBuildFileExceptionSet
      exception = theirs_project.new(klass)
      exception.target = target
      exception.membership_exceptions = ["Excluded.swift"]
      group.exceptions << exception

      changes = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      resolved = base_project.objects.find { |object| object.is_a?(klass) }
      expected_target = base_project.targets.find { |item| item.name == "bar" }
      expect(resolved.target&.uuid).to eq(expected_target.uuid)
    end

    it "resolves a build-phase exception against the correct target" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      theirs_project = create_copy_of_project(base_project, "theirs")
      target = theirs_project.targets.find { |item| item.name == "bar" }
      group = add_synchronized_root_group(theirs_project, "SyncedSources")
      target.file_system_synchronized_groups << group

      klass = Xcodeproj::Project::PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet
      exception = theirs_project.new(klass)
      exception.build_phase = target.source_build_phase
      exception.membership_exceptions = ["OnlyInSources.swift"]
      group.exceptions << exception

      changes = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      resolved = base_project.objects.find { |object| object.is_a?(klass) }
      expected_phase = base_project.targets.find { |item| item.name == "bar" }.source_build_phase
      expect(resolved.build_phase.uuid).to eq(expected_phase.uuid)
    end

    it "resolves a build-phase exception when the folder is shared by multiple targets" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      theirs_project = create_copy_of_project(base_project, "theirs")
      group = add_synchronized_root_group(theirs_project, "Shared")
      theirs_project.targets.find { |item| item.display_name == "foo" }
                    .file_system_synchronized_groups << group
      bar = theirs_project.targets.find { |item| item.display_name == "bar" }
      bar.file_system_synchronized_groups << group

      klass = Xcodeproj::Project::PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet
      exception = theirs_project.new(klass)
      # Reference the SECOND target's Sources phase. "foo" (added first) also references the group
      # and has its own "Sources" phase, so a resolver scoped only to the referencing targets would
      # pick foo's phase instead of bar's.
      exception.build_phase = bar.source_build_phase
      exception.membership_exceptions = ["OnlyInBarSources.swift"]
      group.exceptions << exception

      changes = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)
      resolved = base_project.objects.find { |object| object.is_a?(klass) }
      expected_phase = base_project.targets.find { |item| item.name == "bar" }.source_build_phase
      expect(resolved.build_phase.uuid).to eq(expected_phase.uuid)
    end

    it "attaches the correct folder when two buildable folders share a name" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      theirs_project = create_copy_of_project(base_project, "theirs")

      feature_a = theirs_project.main_group.new_group("FeatureA")
      feature_b = theirs_project.main_group.new_group("FeatureB")
      group_a = theirs_project.new(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
      group_a.source_tree = "<group>"
      group_a.path = "Shared"
      feature_a << group_a
      group_b = theirs_project.new(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
      group_b.source_tree = "<group>"
      group_b.path = "Shared"
      feature_b << group_b
      theirs_project.targets.find { |item| item.display_name == "foo" }
                    .file_system_synchronized_groups << group_a
      theirs_project.targets.find { |item| item.display_name == "bar" }
                    .file_system_synchronized_groups << group_b

      changes = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      expect(base_project).to be_equivalent_to_project(theirs_project)

      helper = Xcodeproj::Project::Object::GroupableHelper
      foo_group = base_project.targets.find { |item| item.display_name == "foo" }
                              .file_system_synchronized_groups.first
      bar_group = base_project.targets.find { |item| item.display_name == "bar" }
                              .file_system_synchronized_groups.first
      expect(helper.hierarchy_path(foo_group)).to eq("/FeatureA/Shared")
      expect(helper.hierarchy_path(bar_group)).to eq("/FeatureB/Shared")
    end

    it "does not duplicate an exception set added on both sides" do
      group = add_synchronized_root_group(base_project, "Models")
      base_project.targets[0].file_system_synchronized_groups << group
      common_base = create_copy_of_project(base_project, "base")

      add_build_file_exception = lambda do |project|
        synchronized_group = project.objects.find do |object|
          object.isa == "PBXFileSystemSynchronizedRootGroup"
        end
        exception = project.new(Xcodeproj::Project::PBXFileSystemSynchronizedBuildFileExceptionSet)
        exception.target = project.targets.find { |target| target.display_name == "foo" }
        exception.membership_exceptions = ["Excluded.swift"]
        synchronized_group.exceptions << exception
      end

      theirs_project = create_copy_of_project(base_project, "theirs")
      add_build_file_exception.call(theirs_project)
      add_build_file_exception.call(base_project)

      changes = get_diff(theirs_project, common_base)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      exception_count = base_project.objects.count do |object|
        object.isa == "PBXFileSystemSynchronizedBuildFileExceptionSet"
      end
      expect(exception_count).to eq(1)
    end

    it "does not duplicate a deferred exception added to an existing buildable folder" do
      group = add_synchronized_root_group(base_project, "Models")
      base_project.targets[0].file_system_synchronized_groups << group
      common_base = create_copy_of_project(base_project, "base")

      klass = Xcodeproj::Project::PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet
      theirs_project = create_copy_of_project(base_project, "theirs")
      synchronized_group = theirs_project.objects.find do |object|
        object.isa == "PBXFileSystemSynchronizedRootGroup"
      end
      exception = theirs_project.new(klass)
      exception.build_phase = theirs_project.targets[0].source_build_phase
      exception.membership_exceptions = ["Excluded.swift"]
      synchronized_group.exceptions << exception

      changes = get_diff(theirs_project, common_base)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      # The build-phase reference is resolved lazily, so the exception travels both the main-group
      # and the target graph paths with a still-unresolved reference; dedup must recognize it.
      expect(base_project.objects.count { |object| object.is_a?(klass) }).to eq(1)
      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "attaches the correct slashed-path folder when two share a name" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      theirs_project = create_copy_of_project(base_project, "theirs")

      klass = Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup
      feature_a = theirs_project.main_group.new_group("FeatureA")
      feature_b = theirs_project.main_group.new_group("FeatureB")
      group_a = theirs_project.new(klass)
      group_a.source_tree = "<group>"
      group_a.path = "Sub/Shared"
      feature_a << group_a
      group_b = theirs_project.new(klass)
      group_b.source_tree = "<group>"
      group_b.path = "Sub/Shared"
      feature_b << group_b
      theirs_project.targets.find { |item| item.display_name == "foo" }
                    .file_system_synchronized_groups << group_a
      theirs_project.targets.find { |item| item.display_name == "bar" }
                    .file_system_synchronized_groups << group_b

      changes = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      helper = Xcodeproj::Project::Object::GroupableHelper
      foo_group = base_project.targets.find { |item| item.display_name == "foo" }
                              .file_system_synchronized_groups.first
      bar_group = base_project.targets.find { |item| item.display_name == "bar" }
                              .file_system_synchronized_groups.first
      expect(helper.hierarchy_path(foo_group)).to eq("/FeatureA/Sub/Shared")
      expect(helper.hierarchy_path(bar_group)).to eq("/FeatureB/Sub/Shared")
    end

    it "serializes a build file exception set with an unset target without crashing" do
      group = add_synchronized_root_group(base_project, "Models")
      exception =
        base_project.new(Xcodeproj::Project::PBXFileSystemSynchronizedBuildFileExceptionSet)
      group.exceptions << exception

      expect { exception.to_tree_hash }.not_to raise_error
      expect(exception.to_tree_hash["displayName"])
        .to eq("Exceptions for \"Models\" folder in \"\" target")
    end

    it "serializes an exception set with no parent group without infinite recursion" do
      exception =
        base_project.new(Xcodeproj::Project::PBXFileSystemSynchronizedBuildFileExceptionSet)

      expect { exception.to_tree_hash }.not_to raise_error
    end

    it "serializes a parent-less build-phase exception set without infinite recursion" do
      klass = Xcodeproj::Project::PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet
      exception = base_project.new(klass)

      expect { exception.to_tree_hash }.not_to raise_error
      expect(exception.to_tree_hash["displayName"])
        .to eq("Exceptions for \"\" folder in \"\" build phase")
    end

    it "links both folders when one target references two folders sharing a name" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      target = theirs_project.targets.find { |item| item.display_name == "foo" }

      klass = Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup
      %w[FeatureA FeatureB].each do |feature|
        parent = theirs_project.main_group.new_group(feature)
        group = theirs_project.new(klass)
        group.source_tree = "<group>"
        group.path = "Shared"
        parent << group
        target.file_system_synchronized_groups << group
      end

      changes = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      helper = Xcodeproj::Project::Object::GroupableHelper
      linked = base_project.targets.find { |item| item.display_name == "foo" }
                           .file_system_synchronized_groups
      expect(linked.map { |group| helper.hierarchy_path(group) })
        .to contain_exactly("/FeatureA/Shared", "/FeatureB/Shared")
    end

    it "keeps exception sets that differ only by target" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      theirs_project = create_copy_of_project(base_project, "theirs")
      group = add_synchronized_root_group(theirs_project, "Models")
      theirs_project.targets.each { |target| target.file_system_synchronized_groups << group }

      klass = Xcodeproj::Project::PBXFileSystemSynchronizedBuildFileExceptionSet
      %w[foo bar].each do |target_name|
        exception = theirs_project.new(klass)
        exception.target = theirs_project.targets.find { |t| t.display_name == target_name }
        exception.membership_exceptions = ["Excluded.swift"]
        group.exceptions << exception
      end

      changes = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      expect(base_project.objects.count { |object| object.is_a?(klass) }).to eq(2)
      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "keeps exception sets that differ only by membership" do
      theirs_project = create_copy_of_project(base_project, "theirs")
      group = add_synchronized_root_group(theirs_project, "Models")
      theirs_project.targets[0].file_system_synchronized_groups << group

      klass = Xcodeproj::Project::PBXFileSystemSynchronizedBuildFileExceptionSet
      %w[A B].each do |suffix|
        exception = theirs_project.new(klass)
        exception.target = theirs_project.targets[0]
        exception.membership_exceptions = ["Excluded#{suffix}.swift"]
        group.exceptions << exception
      end

      changes = get_diff(theirs_project, base_project)
      described_class.apply_change_to_project(base_project, changes, theirs_project)

      expect(base_project.objects.count { |object| object.is_a?(klass) }).to eq(2)
      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "recreates a synchronized root group modified on theirs and deleted on ours" do
      allow(Kintsugi::ConflictResolver).to receive(:create_nonexistent_component_when_changing_it?)
        .and_return(true)

      group = add_synchronized_root_group(base_project, "Models")
      base_project.targets[0].file_system_synchronized_groups << group
      common_base = create_copy_of_project(base_project, "base")

      theirs_project = create_copy_of_project(base_project, "theirs")
      theirs_project.objects.find { |object| object.isa == "PBXFileSystemSynchronizedRootGroup" }
                    .explicit_folders = ["Generated"]

      base_project.objects.find { |object| object.isa == "PBXFileSystemSynchronizedRootGroup" }
                  .remove_from_project

      changes = get_diff(theirs_project, common_base)
      expect {
        described_class.apply_change_to_project(base_project, changes, theirs_project)
      }.not_to raise_error

      recreated =
        base_project.objects.find { |object| object.isa == "PBXFileSystemSynchronizedRootGroup" }
      expect(recreated&.explicit_folders).to eq(["Generated"])
    end

    context "when duplicates are allowed" do
      before { Kintsugi::Settings.allow_duplicates = true }

      after { Kintsugi::Settings.allow_duplicates = false }

      it "adds a synchronized root group that already exists" do
        existing_group = add_synchronized_root_group(base_project, "SyncedSources")
        base_project.targets[0].file_system_synchronized_groups << existing_group

        theirs_project = create_copy_of_project(base_project, "theirs")
        theirs_group = add_synchronized_root_group(theirs_project, "SyncedSources")
        theirs_project.targets[0].file_system_synchronized_groups << theirs_group

        changes_to_apply = get_diff(theirs_project, base_project)
        other_project = create_copy_of_project(base_project, "other")
        described_class.apply_change_to_project(other_project, changes_to_apply, theirs_project)

        expect(other_project.targets[0].file_system_synchronized_groups.count).to eq(2)
      end

      it "still does not duplicate an exception on an existing folder" do
        group = add_synchronized_root_group(base_project, "Models")
        base_project.targets[0].file_system_synchronized_groups << group
        common_base = create_copy_of_project(base_project, "base")

        klass = Xcodeproj::Project::PBXFileSystemSynchronizedBuildFileExceptionSet
        theirs_project = create_copy_of_project(base_project, "theirs")
        synchronized_group = theirs_project.objects.find do |object|
          object.isa == "PBXFileSystemSynchronizedRootGroup"
        end
        exception = theirs_project.new(klass)
        exception.target = theirs_project.targets[0]
        exception.membership_exceptions = ["Excluded.swift"]
        synchronized_group.exceptions << exception

        changes = get_diff(theirs_project, common_base)
        described_class.apply_change_to_project(base_project, changes, theirs_project)

        # The two-pass traversal visits the same source exception twice; that artifact must be
        # suppressed even when duplicates are allowed (an identical exception set is meaningless).
        expect(base_project.objects.count { |object| object.is_a?(klass) }).to eq(1)
      end

      it "still does not duplicate a deferred build-phase exception on an existing folder" do
        group = add_synchronized_root_group(base_project, "Models")
        base_project.targets[0].file_system_synchronized_groups << group
        common_base = create_copy_of_project(base_project, "base")

        klass = Xcodeproj::Project::PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet
        theirs_project = create_copy_of_project(base_project, "theirs")
        synchronized_group = theirs_project.objects.find do |object|
          object.isa == "PBXFileSystemSynchronizedRootGroup"
        end
        exception = theirs_project.new(klass)
        exception.build_phase = theirs_project.targets[0].source_build_phase
        exception.membership_exceptions = ["Excluded.swift"]
        synchronized_group.exceptions << exception

        changes = get_diff(theirs_project, common_base)
        described_class.apply_change_to_project(base_project, changes, theirs_project)

        expect(base_project.objects.count { |object| object.is_a?(klass) }).to eq(1)
      end
    end
  end

  def create_copy_of_project(project, new_project_prefix)
    copied_project_path = make_temp_directory(new_project_prefix, ".xcodeproj")
    project.save(copied_project_path)
    Xcodeproj::Project.open(copied_project_path)
  end

  def get_diff(first_project, second_project)
    diff = Xcodeproj::Differ.project_diff(first_project, second_project, :added, :removed)

    diff_without_display_name =
      diff.merge("rootObject" => diff["rootObject"].reject { |key, _| key == "displayName" })
    if diff_without_display_name == {"rootObject" => {}}
      raise "Diff contains no changes. This probably means the test doesn't check anything."
    end

    diff
  end

  def add_new_subproject_to_project(project, subproject_name, subproject_product_name)
    subproject = new_subproject(subproject_name, subproject_product_name)
    add_existing_subproject_to_project(project, subproject, subproject_product_name)
    subproject
  end

  def new_subproject(subproject_name, subproject_product_name)
    subproject_path = make_temp_directory(subproject_name, ".xcodeproj")
    subproject = Xcodeproj::Project.new(subproject_path)
    subproject.new_target("com.apple.product-type.library.static", subproject_product_name, :ios)
    subproject.save

    subproject
  end

  def add_existing_subproject_to_project(project, subproject, subproject_product_name)
    subproject_reference = project.new_file(subproject.path, :built_products)

    # Workaround for a bug in xcodeproj: https://github.com/CocoaPods/Xcodeproj/issues/678
    project.main_group.find_subpath("Products").children.find do |file_reference|
      # The name of the added file reference is equivalent to the name of the product.
      file_reference.path == subproject_product_name
    end.remove_from_project

    project.root_object.project_references[-1][:product_group] =
      project.new(Xcodeproj::Project::PBXGroup)
    project.root_object.project_references[-1][:product_group].name = "Products"
    project.root_object.project_references[-1][:product_group] <<
      create_reference_proxy_from_product_reference(project, subproject_reference,
                                                    subproject.products_group.files[0])
  end

  def create_reference_proxy_from_product_reference(project, subproject_reference,
      product_reference)
    container_proxy = project.new(Xcodeproj::Project::PBXContainerItemProxy)
    container_proxy.container_portal = subproject_reference.uuid
    container_proxy.proxy_type = Xcodeproj::Constants::PROXY_TYPES[:reference]
    container_proxy.remote_global_id_string = product_reference.uuid
    container_proxy.remote_info = subproject_reference.name

    reference_proxy = project.new(Xcodeproj::Project::PBXReferenceProxy)
    extension = File.extname(product_reference.path)[1..-1]
    reference_proxy.file_type = Xcodeproj::Constants::FILE_TYPES_BY_EXTENSION[extension]
    reference_proxy.path = product_reference.path
    reference_proxy.remote_ref = container_proxy
    reference_proxy.source_tree = 'BUILT_PRODUCTS_DIR'

    reference_proxy
  end

  def create_swift_package_product_dependency(project)
    product_dependency = project.new(Xcodeproj::Project::XCSwiftPackageProductDependency)
    product_dependency.product_name = "foo"
    product_dependency.package = create_remote_swift_package_reference(project)

    product_dependency
  end

  def create_remote_swift_package_reference(project)
    package_reference = project.new(Xcodeproj::Project::XCRemoteSwiftPackageReference)
    package_reference.repositoryURL = "http://foo"
    package_reference.requirement = {"foo" => "bar"}

    package_reference
  end

  def make_temp_directory(directory_prefix, directory_extension)
    directory_path = Dir.mktmpdir([directory_prefix, directory_extension])
    temporary_directories_paths << directory_path
    directory_path
  end
end

module TTY
  class Prompt
    class Test
      def choose_option(index, repeating: 1)
        input << "#{"j" * index}\n" * repeating
        input.rewind
      end

      def setup
        on(:keypress) do |event|
          trigger(:keydown) if event.value == "j"
        end
      end
    end
  end
end

# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "git"
require "json"
require "rspec"
require "tempfile"
require "tmpdir"

require "kintsugi"

shared_examples "tests" do |git_command, project_name|
  let(:temporary_directories_paths) { [] }
  let(:git_directory_path) { make_temp_directory }
  let(:git) { Git.init(git_directory_path) }

  before do
    git.config("user.email", "you@example.com")
    git.config("user.name", "Your Name")
  end

  after do
    temporary_directories_paths.each do |directory_path|
      FileUtils.remove_entry(directory_path)
    end
  end

  context "running 'git #{git_command}' with project name '#{project_name}'" do
    it "resolves conflicts with root command" do
      File.write(File.join(git_directory_path, ".gitattributes"), "*.pbxproj merge=Unset")

      project = create_new_project_at_path(File.join(git_directory_path, project_name))

      git.add(File.join(git_directory_path, ".gitattributes"))
      git.add(project.path)
      git.commit("Initial project")

      project.new_target("com.apple.product-type.library.static", "foo", :ios)
      project.save

      git.add(all: true)
      git.commit("Add target foo")
      first_commit_hash = git.revparse("HEAD")

      git.checkout("HEAD^")
      project = Xcodeproj::Project.open(project.path)
      project.new_target("com.apple.product-type.library.static", "bar", :ios)
      project.save
      git.add(all: true)
      git.commit("Add target bar")

      `git -C #{git_directory_path} #{git_command} #{first_commit_hash} &> /dev/null`
      Kintsugi.run([File.join(project.path, "project.pbxproj")])

      project = Xcodeproj::Project.open(project.path)
      expect(project.targets.map(&:display_name)).to contain_exactly("foo", "bar")
    end

    it "resolves conflicts automatically with driver" do
      git.config("merge.kintsugi.name", "Kintsugi driver")
      git.config("merge.kintsugi.driver", "#{__dir__}/../bin/kintsugi driver %O %A %B %P")
      File.write(File.join(git_directory_path, ".gitattributes"), "*.pbxproj merge=kintsugi")

      project = create_new_project_at_path(File.join(git_directory_path, project_name))

      git.add(File.join(git_directory_path, ".gitattributes"))
      git.add(project.path)
      git.commit("Initial project")

      project.new_target("com.apple.product-type.library.static", "foo", :ios)
      project.save

      git.add(all: true)
      git.commit("Add target foo")
      first_commit_hash = git.revparse("HEAD")

      git.checkout("HEAD^")
      project = Xcodeproj::Project.open(project.path)
      project.new_target("com.apple.product-type.library.static", "bar", :ios)
      project.save
      git.add(all: true)
      git.commit("Add target bar")

      `git -C #{git_directory_path} #{git_command} #{first_commit_hash} &> /dev/null`

      project = Xcodeproj::Project.open(project.path)
      expect(project.targets.map(&:display_name)).to contain_exactly("foo", "bar")
    end

    it "keeps conflicts if failed to resolve conflicts" do
      File.write(File.join(git_directory_path, ".gitattributes"), "*.pbxproj merge=Unset")

      project = create_new_project_at_path(File.join(git_directory_path, project_name))
      project.new_target("com.apple.product-type.library.static", "foo", :ios)
      project.save

      git.add(File.join(git_directory_path, ".gitattributes"))
      git.add(project.path)
      git.commit("Initial project")

      project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["PRODUCT_NAME"] = "bar"
      end
      project.save
      git.add(all: true)
      git.commit("Change target product name to bar")
      first_commit_hash = git.revparse("HEAD")

      git.checkout("HEAD^")
      project = Xcodeproj::Project.open(project.path)
      project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["PRODUCT_NAME"] = "baz"
      end
      project.save
      git.add(all: true)
      git.commit("Change target product name to baz")

      `git -C #{git_directory_path} #{git_command} #{first_commit_hash} &> /dev/null`

      arguments = [File.join(project.path, "project.pbxproj"), "--interactive-resolution", "false"]
      expect {
        Kintsugi.run(arguments)
      }.to raise_error(Kintsugi::MergeError)
      expect(`git -C #{git_directory_path} diff --name-only --diff-filter=U`.chomp)
        .to eq("#{project_name}/project.pbxproj")
    end
  end

  def make_temp_directory
    directory_path = Dir.mktmpdir
    temporary_directories_paths << directory_path
    directory_path
  end
end

def create_new_project_at_path(path)
  project = Xcodeproj::Project.new(path)
  project.save
  project
end

describe Kintsugi, :kintsugi do
  %w[rebase cherry-pick merge].each do |git_command|
    ["foo.xcodeproj", "foo with space.xcodeproj"].each do |project_name|
      it_behaves_like("tests", git_command, project_name)
    end
  end
end

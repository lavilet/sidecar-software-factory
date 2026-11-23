require "json"
require "tmpdir"

require_relative "spec_helper"

require "harness/errors"
require "harness/logger"
require "harness/backends/base"
require "harness/epic_splitter"

RSpec.describe Harness::EpicSplitter do
  it "creates pilot and dependent child issues with automatic Parent, Depends on, and Pilot headers" do
    temp_dir = Dir.mktmpdir("harness-split-spec")
    created = []
    next_num = 42

    fake_gh = Object.new
    fake_gh.define_singleton_method(:transition_label) { |_n, **| nil }
    fake_gh.define_singleton_method(:create_issue) do |title:, body:, label:|
      num = next_num
      next_num += 1
      created << { number: num, title: title, body: body, label: label }
      { number: num, url: "https://github.com/example/sample/issues/#{num}" }
    end

    splitter = described_class.new(
      repo_root: temp_dir,
      github: fake_gh,
      backend: nil,
      logger: Harness::Logger.new(File.join(temp_dir, "split.log"))
    )

    plan = {
      "epic_number" => 41,
      "summary" => "2-step split",
      "tasks" => [
        { "key" => "catalog", "title" => "Catalog repo", "pilot" => true, "depends_on_keys" => [], "playbook" => "feature", "body" => "Move catalog SQL.", "done_if" => "Catalog specs pass" },
        { "key" => "accounts", "title" => "Accounts repo", "pilot" => false, "depends_on_keys" => [ "catalog" ], "playbook" => "feature", "body" => "Move accounts SQL.", "done_if" => "Accounts specs pass" }
      ]
    }

    result = splitter.create_children(split_plan: plan, epic_number: 41)

    expect(result.size).to eq(2)
    expect(created[0][:label]).to eq("agent:triage")
    expect(created[0][:body]).to include("Parent: #41\nDepends on: none\nPilot: true")
    expect(created[1][:label]).to eq("agent:waiting-deps")
    expect(created[1][:body]).to include("Parent: #41\nDepends on: #42")
    expect(created[1][:body]).not_to include("Pilot: true")
  ensure
    FileUtils.rm_rf(temp_dir)
  end
end

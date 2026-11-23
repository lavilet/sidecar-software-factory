require "fileutils"
require "optparse"
require "rbconfig"
require_relative "paths"

abort "Sidecar requires Ruby 3.2+. Set FACTORY_RUBY to the absolute path of a supported Ruby." unless defined?(Data) && Data.respond_to?(:define)

commands = %w[init profile verify run qa attach dashboard setup-labels bot split-epic retro scout eval]
project = ENV["FACTORY_PROJECT"]
parser = OptionParser.new do |o|
  o.banner = "Usage: factory --project PATH COMMAND [options]\nCommands: #{commands.join(" ")}"
  o.on("--project PATH", "Target Git checkout (or set FACTORY_PROJECT)") { |arg| project = arg }
  o.on("-h", "--help") { puts o; exit }
end
parser.order!
command = ARGV.shift
abort parser.to_s unless commands.include?(command) && project
out, ok = Open3.capture2e("git", "-C", project, "rev-parse", "--show-toplevel")
abort "Expected a Git checkout at #{project}: #{out}" unless ok.success?
target = File.realpath(out.strip)
root = Harness::Paths::ROOT
if target == root || target.start_with?(root + "/") || root.start_with?(target + "/")
  abort "Choose a target checkout outside the factory installation"
end
profile = Harness::Paths.profile(target)
case command
when "profile"
  puts profile
when "init"
  FileUtils.mkdir_p(profile)
  source = File.join(root, "templates", "profile")
  Dir.glob("**/*", base: source).each do |entry|
    src = File.join(source, entry)
    dest = File.join(profile, entry)
    if File.directory?(src)
      FileUtils.mkdir_p(dest)
    elsif !File.exist?(dest)
      FileUtils.cp(src, dest, preserve: true)
    end
  end
  puts "Project: #{target}\nProfile: #{profile}\nVerify hook: #{profile}/hooks/verify"
else
  abort "Initialize the project profile with factory --project PATH init" unless File.directory?(profile)
  ENV["FACTORY_STATE_DIR"] = File.expand_path(ENV["FACTORY_STATE_DIR"]) if ENV["FACTORY_STATE_DIR"]
  Dir.chdir(target)
  ENV["FACTORY_PROJECT"] = target
  ENV.delete("GH_REPO")
  if command == "verify"
    hook = File.join(profile, "hooks", "verify")
    exec([hook, hook], *ARGV)
  elsif command == "setup-labels"
    if ARGV.any?
      puts "Usage: factory setup-labels"
      exit(ARGV == ["--help"] ? 0 : 1)
    end
    exec("bash", File.join(root, "commands", command))
  else
    exec(RbConfig.ruby, "-r", File.join(root, "lib/harness/paths"), File.join(root, "commands", command), *ARGV)
  end
end

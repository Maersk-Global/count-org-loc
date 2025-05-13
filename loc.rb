# frozen_string_literal: true

require 'octokit'
require 'open3'
require 'cliver'
require 'fileutils'
require 'dotenv'

if ARGV.count != 1
  puts 'Usage: script/count [ORG NAME]'
  exit 1
end

Dotenv.load

def cloc(*args)
  cloc_path = Cliver.detect! 'cloc'
  Open3.capture2e(cloc_path, *args)
end

# Check rate limit and wait if necessary
def check_rate_limit(client)
  rate_limit = client.rate_limit
  remaining = rate_limit.remaining
  reset_time = rate_limit.resets_at
  
  if remaining <= 10
    wait_time = [reset_time - Time.now, 0].max
    puts "Rate limit nearly exceeded! Remaining: #{remaining}"
    puts "Waiting for #{wait_time.round} seconds until rate limit resets at #{reset_time}"
    sleep(wait_time + 1) # Add 1 second buffer
    
    # Recheck rate limit after waiting
    new_rate_limit = client.rate_limit
    puts "Rate limit reset. New remaining requests: #{new_rate_limit.remaining}"
  end
end

tmp_dir = File.expand_path './tmp', File.dirname(__FILE__)
FileUtils.rm_rf tmp_dir
FileUtils.mkdir_p tmp_dir

# Enabling support for GitHub Enterprise
unless ENV['GITHUB_ENTERPRISE_URL'].nil?
  Octokit.configure do |c|
    c.api_endpoint = ENV['GITHUB_ENTERPRISE_URL']
  end
end

client = Octokit::Client.new access_token: ENV['GITHUB_TOKEN']
client.auto_paginate = true

begin
  check_rate_limit(client) # Check rate limit before fetching repos
  repos = client.organization_repositories(ARGV[0].strip, type: 'sources')
rescue StandardError => e
  if e.message.include?('rate limit')
    # Handle specific rate limit error
    check_rate_limit(client)
    # Try again after waiting
    repos = client.organization_repositories(ARGV[0].strip, type: 'sources')
  else
    repos = client.repositories(ARGV[0].strip, type: 'sources')
  end
end
puts "Found #{repos.count} repos. Counting..."

reports = []
repos.each do |repo|
  puts "Counting #{repo.name}..."
  
  # Check rate limit before cloning
  check_rate_limit(client)

  destination = File.expand_path repo.name, tmp_dir
  report_file = File.expand_path "#{repo.name}.txt", tmp_dir

  clone_url = repo.clone_url
  clone_url = clone_url.sub '//', "//#{ENV['GITHUB_TOKEN']}:x-oauth-basic@" if ENV['GITHUB_TOKEN']
  _output, status = Open3.capture2e 'git', 'clone', '--depth', '1', '--quiet', clone_url, destination
  next unless status.exitstatus.zero?

  _output, _status = cloc destination, '--quiet', "--report-file=#{report_file}"
  if File.exist?(report_file) && status.exitstatus.zero?
    reports.push(report_file)
    # Delete the repository directory after report is generated successfully
    FileUtils.rm_rf(destination)
    puts "  Repository cleaned up: #{repo.name}"
  end
end

puts 'Done. Summing...'

output, _status = cloc '--sum-reports', *reports
puts output.gsub(%r{^#{Regexp.escape tmp_dir}/(.*)\.txt}) { Regexp.last_match(1) + ' ' * (tmp_dir.length + 5) }

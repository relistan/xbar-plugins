#!/usr/bin/ruby
# frozen_string_literal: true

# <xbar.title>GitHub review and open PR counts</xbar.title>
# <xbar.desc>Shows PRs waiting on your review and PRs you opened</xbar.desc>
# <xbar.version>v0.2</xbar.version>
# <xbar.dependencies>ruby,gh</xbar.dependencies>

require "cgi"
require "base64"
require "json"
require "open3"
require "time"

ORG = "hydrolix"

# Optional: narrow scope, e.g. "draft:false org:hydrolix"
FILTERS = "draft:false org:#{ORG}"

# Optional: PRs with this label render with subdued color
WIP_LABEL = "WIP"
ICON_SET_DIR_CANDIDATES = [
  File.expand_path("001-github-review-requests.assets/number-circle-icons-din-alternate", __dir__),
  File.expand_path("assets/number-circle-icons-din-alternate", __dir__)
].freeze

def dark_mode?
  %w[1 true yes on].include?(ENV.fetch("BitBarDarkMode", "").downcase)
end

DARK_MODE = dark_mode?
COLORS = {
  inactive: "#b4b4b4",
  title: DARK_MODE ? "#f7f7f7" : "#111111",
  subtitle: "#586069",
  section: DARK_MODE ? "#f7f7f7" : "#111111"
}.freeze

def gh_path
  candidates = [
    ENV["XBAR_GH_BIN"],
    "/opt/homebrew/bin/gh",
    "/usr/local/bin/gh",
    `command -v gh`.strip
  ].compact.uniq

  candidates.find { |path| !path.empty? && File.executable?(path) }
end

def magick_path
  candidates = [
    ENV["XBAR_MAGICK_BIN"],
    "/opt/homebrew/bin/magick",
    "/usr/local/bin/magick",
    `command -v magick`.strip
  ].compact.uniq

  candidates.find { |path| !path.empty? && File.executable?(path) }
end

def xbar_line(text, params = {})
  if params.empty?
    puts text
  else
    suffix = params.map { |k, v| "#{k}=#{v}" }.join(" ")
    puts "#{text} | #{suffix}"
  end
end

def search_url(query)
  "https://github.com/pulls?q=#{CGI.escape(query)}"
end

def format_date(iso8601)
  Time.parse(iso8601).strftime("%B %-d, %Y")
end

def count_icon_path(count)
  icon_dir = ICON_SET_DIR_CANDIDATES.find { |dir| Dir.exist?(dir) }
  raise "Icon directory not found" unless icon_dir

  normalized = count.to_i
  normalized = 0 if normalized.negative?
  normalized = 99 if normalized > 99
  File.join(icon_dir, "#{normalized}.png")
end

def title_image_base64(magick_bin, review_count, open_count)
  review_icon = count_icon_path(review_count)
  open_icon = count_icon_path(open_count)
  raise "Missing icon: #{review_icon}" unless File.exist?(review_icon)
  raise "Missing icon: #{open_icon}" unless File.exist?(open_icon)

  out, err, status = Open3.capture3(
    magick_bin,
    "(",
    review_icon, "-resize", "18x18",
    ")",
    "(",
    "-size", "6x18", "xc:none",
    ")",
    "(",
    open_icon, "-resize", "18x18",
    ")",
    "+append",
    "png:-"
  )

  raise(err.empty? ? "Failed to render title image" : err) unless status.success?

  Base64.strict_encode64(out)
end

def query_github(gh_bin, review_query, open_query)
  gql = <<~GRAPHQL
    query($reviewQ: String!, $openQ: String!) {
      viewer { login }
      review: search(query: $reviewQ, type: ISSUE, first: 30) {
        issueCount
        edges {
          node {
            ... on PullRequest {
              repository { nameWithOwner }
              author { login }
              createdAt
              number
              url
              title
              labels(first: 100) { nodes { name } }
              reviewDecision
              latestReviews(first: 20) { nodes { author { login } state } }
            }
          }
        }
      }
      open: search(query: $openQ, type: ISSUE, first: 30) {
        issueCount
        edges {
          node {
            ... on PullRequest {
              repository { nameWithOwner }
              author { login }
              createdAt
              number
              url
              title
              labels(first: 100) { nodes { name } }
            }
          }
        }
      }
    }
  GRAPHQL

  out, err, status = Open3.capture3(
    gh_bin,
    "api",
    "graphql",
    "-f", "query=#{gql}",
    "-f", "reviewQ=#{review_query}",
    "-f", "openQ=#{open_query}"
  )

  raise(err.empty? ? "gh api graphql failed" : err) unless status.success?

  parsed = JSON.parse(out)
  if parsed["errors"] && !parsed["errors"].empty?
    raise parsed["errors"].map { |e| e["message"] }.join("; ")
  end
  parsed
end

def print_pr_list(prs)
  prs.each do |pr|
    labels = pr.dig("labels", "nodes")&.map { |l| l["name"] } || []
    inactive = labels.include?(WIP_LABEL)

    title = "#{pr.dig("repository", "nameWithOwner")} - #{pr["title"].to_s.tr("|", "-")}"
    subtitle = "##{pr["number"]} opened on #{format_date(pr["createdAt"])} by @#{pr.dig("author", "login")}"

    xbar_line(title, size: 17, color: COLORS[inactive ? :inactive : :title], href: pr["url"])
    xbar_line(subtitle, size: 12, color: COLORS[inactive ? :inactive : :subtitle])
  end
end

begin
  gh_bin = gh_path
  raise "gh CLI not found. Set XBAR_GH_BIN or install gh." unless gh_bin

  review_query = ["is:pr", "is:open", "review-requested:@me", FILTERS].reject(&:empty?).join(" ")
  open_query = ["is:pr", "is:open", "author:@me", FILTERS].reject(&:empty?).join(" ")

  data = query_github(gh_bin, review_query, open_query).fetch("data")
  viewer_login = data.dig("viewer", "login")
  review_data = data.fetch("review")
  open_data = data.fetch("open")

  review_prs = review_data.fetch("edges", []).map { |edge| edge["node"] }.compact.reject do |pr|
    next false unless pr["reviewDecision"] == "CHANGES_REQUESTED"

    reviewed_by_me = pr.dig("latestReviews", "nodes")&.any? { |r| r.dig("author", "login") == viewer_login }
    !reviewed_by_me
  end
  open_prs = open_data.fetch("edges", []).map { |edge| edge["node"] }.compact

  review_count = review_prs.size
  open_count = open_data.fetch("issueCount", 0)

  magick_bin = magick_path
  if magick_bin
    begin
      image_b64 = title_image_base64(magick_bin, review_count, open_count)
      xbar_line(" ", image: image_b64)
    rescue StandardError
      xbar_line("#{review_count} #{open_count}")
    end
  else
    xbar_line("#{review_count} #{open_count}")
  end

  if review_prs.any? || open_prs.any?
    xbar_line("---")
  end

  if review_prs.any?
    xbar_line("Review requests", size: 16, color: COLORS[:section], font: "Menlo-Bold")
    print_pr_list(review_prs)
  end

  if review_prs.any? && open_prs.any?
    xbar_line("---")
  end

  if open_prs.any?
    xbar_line("My open PRs", size: 16, color: COLORS[:section], font: "Menlo-Bold")
    print_pr_list(open_prs)
  end
rescue StandardError => e
  xbar_line("❓ ❓")
  xbar_line("---")
  xbar_line("Error: #{e.message.lines.first.to_s.strip}", color: "red")
  xbar_line("Run: #{gh_path || 'gh'} auth login")
end

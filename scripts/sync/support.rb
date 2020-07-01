class MarkdownFileContents
  attr_accessor :lines, :fields, :comments

  def initialize(lines, fields = {}, comments = [])
    @lines = lines
    @fields = fields
    @comments = comments
  end

  def extract_title
    heading_underline_index = lines.find_index{ |line| line.start_with?("======") }

    if heading_underline_index && heading_underline_index > 0
      lines.delete_at(heading_underline_index)
      title = lines.delete_at(heading_underline_index - 1).strip
      self.fields[:title] = title
    else
      heading_index = lines.find_index { | line | line.start_with?('#') }
      if heading_index
        title = lines.delete_at(heading_index).gsub(/^#+/, '').strip
        self.fields[:title] = title
      else
        raise "Could not find a heading for page with head lines #{lines[0..5].join}"
      end
    end
  end

  def to_s
    comments_maybe_newlines = comments.dup
    if lines.first && lines.first.strip != ''
      comments_maybe_newlines << ""
    end
    ["---", header_lines, "---", comments_maybe_newlines, lines].flatten.join("\n") + "\n"
  end

  def find_and_replace(find, replace)
    @lines = lines.collect{ |line| line.gsub(find, replace) }
  end

  def remove_lines_including(substring)
    @lines = lines.select{ |line| !line.include?(substring) }
  end

  def add_lines_at_start(*new_lines)
    @lines = new_lines + lines
  end

  def clean_up_changelog
    @lines = lines.collect do | line |
      if line.start_with?('#')
        line
      elsif line.strip.size.zero?
        line
      elsif line.include?('feat:') || line.include?('fix:') || line.include?('Merge pull request')
        line
      end
    end.compact
  end

  private

  def header_lines
    [:title, :custom_edit_url, :description].collect do | key |
      if fields[key]
        "#{key}: #{fields[key]}"
      end
    end.compact
  end
end

PROJECT_ROOT = File.expand_path(File.join(__FILE__, '..', '..', '..'))

def relative_path_to path
  Pathname.new(File.join(PROJECT_ROOT, path)).relative_path_from(Pathname.pwd)
end

def edit_comment_for slug
  "<!-- This file has been synced from the #{slug} repository. Please do not edit it directly. The URL of the source file can be found in the custom_edit_url value above -->"
end

def get_file_list(repository_slug, include_conditions, exclude_conditions = [])
  client = Octokit::Client.new(:access_token => ENV['GITHUB_ACCESS_TOKEN'])
  client.auto_paginate = true
  tree = client.tree(repository_slug, 'master',  recursive: true).tree
  if include_conditions.any? || exclude_conditions.any?
    filter_file_list(tree, include_conditions, exclude_conditions)
  else
    tree
  end
end

def filter_file_list(file_list, include_conditions, exclude_conditions = [])
  file_list.select do | file |
    include_conditions.any?{ |lambda| lambda.call(file.path) } && !exclude_conditions.any? { |lambda| lambda.call(file.path) }
  end
end

def each_file(files)
  files.each do | file |
    file_resource = file.rels[:self].get
    yield file.path, Base64.decode64(file_resource.data.content)
  end
end

def select_actions(custom_actions, path)
  custom_actions
    .select{ | selector , _ | selector == :all || selector == path || (selector.respond_to?(:call) && selector.call(path))  }
    .collect(&:last)
end

def process_file(path, content, path_transformer, custom_actions, comment)
  destination = path_transformer.call(path)
  fields = { custom_edit_url: "https://github.com/#{SOURCE_REPO}/edit/master/#{path}" }
  md_file_contents = MarkdownFileContents.new(content.split("\n"), fields, [comment])
  select_actions(custom_actions, path).each { |action| action.call(md_file_contents) }

  puts "Writing file #{destination}"
  FileUtils.mkdir_p(File.dirname(destination))
  File.open(destination, "w") { |file| file << md_file_contents.to_s }
end

# potential race condition



module UrlAbsolutizer
  extend self

  def absolutize_links(contents, repository_file_paths, repository_slug, path_transformer)
    contents.gsub(/\]\(([^)]+)\)/) { | match |
      url = match[2..-2]
      if url.start_with?('http')
        match
      elsif url_for_page_synced_to_docs?(url, path_transformer)
        transformed_path = path_transformer.call(url)
        "](#{transformed_path})"
      elsif url_for_page_in_github_repository?(url.gsub(/^\//, ''), repository_file_paths)
        "](https://github.com/#{repository_slug}/blob/master/#{url.gsub(/^\//, '')})"
      else
        match
      end
    }
  end

  def url_for_page_synced_to_docs?(url, path_transformer)
    File.exist?(path_transformer.call(url))
  end

  def url_for_page_in_github_repository?(url, repository_file_paths)
    repository_file_paths.include?(url)
  end
end

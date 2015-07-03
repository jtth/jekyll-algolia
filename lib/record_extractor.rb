require 'algoliasearch'
require 'nokogiri'
require 'json'

# Given an HTML file as input, will return an array of records to index
class AlgoliaSearchRecordExtractor
  def initialize(file)
    @file = file
  end

  # Returns metadata from the current file
  def metadata
    return metadata_page if @file.is_a?(Jekyll::Page)
    return metadata_post if @file.is_a?(Jekyll::Post)
    {}
  end

  # Extract a list of tags
  def tags
    return nil unless @file.respond_to? :tags
    # Some plugins will extend the tags from simple strings to full featured
    # objects. We'll simply call .to_s to always have a string
    @file.tags.map(&:to_s)
  end

  # Extract metadata from a post
  def metadata_post
    {
      type: 'post',
      url: @file.url,
      title: @file.title,
      slug: @file.slug,
      posted_at: @file.date.to_time.to_i,
      tags: tags
    }
  end

  # Extract metadata from a page
  def metadata_page
    {
      type: 'page',
      url: @file.url,
      title: @file['title'],
      slug: @file.basename
    }
  end

  # Get the list of all HTML nodes to index
  def html_nodes
    document = Nokogiri::HTML(@file.content)
    selector = 'p'
    if @file.site.config['algolia']['css_selector']
      selector = @file.site.config['algolia']['css_selector']
    end
    document.css(selector)
  end

  # Get all the parent headings of the specified node
  def node_hierarchy(node, memo = { level: 7 })
    # This will actually create a hash with all the h1, h2, etc to find the
    # specified node
    previous = node.previous_element

    # No previous element, we go up to the parent
    unless previous
      parent = node.parent
      # No more parent, ending recursion
      if parent.name == 'body'
        memo.delete(:level)
        return memo
      end
      # We start from the previous sibling of the parent
      return node_hierarchy(parent, memo)
    end

    # Skip non-title elements
    tag_name = previous.name
    unless %w(h1 h2 h3 h4 h5 h6).include?(tag_name)
      return node_hierarchy(previous, memo)
    end

    # Skip if item already as title of a higher level
    title_level = tag_name.gsub('h', '').to_i
    return node_hierarchy(previous, memo) if title_level >= memo[:level]
    memo[:level] = title_level

    # Add to the memo and continue
    memo[tag_name.to_sym] = previous.content
    node_hierarchy(previous, memo)
  end

  # Return the raw HTML of the element to index
  def node_raw_html(node)
    node.to_s
  end

  # Return the text of the element, sanitized to be displayed
  def node_text(node)
    node.content.gsub('<', '&lt;').gsub('>', '&gt;')
  end

  # Returns a unique string of hierarchy from title to h6, used for distinct
  def unique_hierarchy(data)
    headings = %w(title h1 h2 h3 h4 h5 h6)
    headings.map { |heading| data[heading.to_sym] }.compact.join(' > ')
  end

  # Returns a unique css selector to scroll to this result
  # TODO: Find a better way to handle selection.
  # TODO: Maybe looping through parents to find the closest anchor
  def node_css_selector(node)
    node.css_path.gsub('html > body > ', '')
  end

  # Returns a custom numeric value representing how relevant to its hierarchy
  # this record is. This value can be used in the custom ranking to display more
  # relevant records first.
  def weight(data)
    # Get list of unique words in headings
    title_words = %i(title h1 h2 h3 h4 h5 h6)
                  .select { |title| data.key?(title) }
                  .map { |title| data[title].split(/\W+/) }
                  .flatten
                  .compact
                  .map(&:downcase)
                  .uniq
    # Intersect words in headings with words in test
    text_words = data[:text].downcase.split(/\W+/)
    (title_words & text_words).size
  end

  def extract
    items = []
    html_nodes.each_with_index do |node, index|
      next unless node.text.size > 0

      item = metadata.clone
      item[:objectID] = "#{item[:slug]}_#{index}"
      item.merge!(node_hierarchy(node))
      item[:raw_html] = node_raw_html(node)
      item[:text] = node_text(node)
      item[:unique_hierarchy] = unique_hierarchy(item)
      item[:css_selector] = node_css_selector(node)
      item[:weight] = weight(item)

      items << item
    end
    items
  end
end

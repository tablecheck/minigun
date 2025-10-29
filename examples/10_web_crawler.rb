#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Web Crawler Example
# Demonstrates recursive web crawling with URL deduplication and depth tracking
class WebCrawler
  include Minigun::DSL

  max_threads 20 # High concurrency for I/O-bound web fetching

  attr_reader :visited_urls, :pages_fetched, :links_extracted, :pages_processed, :start_url

  def initialize(seed_urls = nil, start_url: 'http://example.com', max_pages: 20, max_depth: 3)
    # Support both old API (array of seed URLs) and new API (single start URL)
    if seed_urls.is_a?(Array)
      @seed_urls = seed_urls
      @start_url = seed_urls.first
    else
      @start_url = start_url
      @seed_urls = [start_url]
    end

    @max_pages = max_pages
    @max_depth = max_depth
    @visited_urls = Set.new
    @pages_fetched = []
    @links_extracted = []
    @pages_processed = []
    @pages_crawled = 0
    @links_found = 0
    @mutex = Mutex.new
    @domain = extract_domain(@start_url)
  end

  # Simulate fetching a web page
  def fetch_page(url)
    # In a real crawler, this would use Net::HTTP or similar
    sleep 0.01 # Simulate network delay

    # Simulate realistic page content
    paragraphs = rand(2..5)
    content = []
    paragraphs.times do |i|
      content << ("This is paragraph #{i + 1} of content from #{url}. " * rand(3..8))
    end

    {
      url: url,
      title: "Page: #{url.split('/').last || 'Home'}",
      content: content.join("\n\n"),
      status: 200,
      word_count: content.join(' ').split.size
    }
  end

  # Extract links from page content
  def extract_links_from_page(_source_url, _content)
    # In a real crawler, this would parse HTML with Nokogiri
    # For demo, generate plausible links based on the source URL
    num_links = rand(2..5)

    links = []
    num_links.times do |_i|
      path = %w[article page blog post category product].sample
      links << "http://#{@domain}/#{path}/#{rand(1..100)}"
    end

    # Add some cross-domain links occasionally
    links << "http://external-site.com/page/#{rand(1..10)}" if rand < 0.3

    links
  end

  # Check if URL should be crawled
  def should_crawl?(url)
    # Filtering rules
    return false if url.include?('login') || url.include?('logout')
    return false if url.include?('admin') || url.include?('cart')
    return false unless url.start_with?("http://#{@domain}", "https://#{@domain}")

    # Stop if we've reached the limit
    return false if @pages_crawled >= @max_pages

    true
  end

  # Save page data
  def save_page_data(page)
    # In a real crawler, this would save to database or file
    # For now, just track it
  end

  pipeline do
    # Stage 1: Seed with initial URLs
    producer :seed_urls do |output|
      puts "\n#{'=' * 60}"
      puts "WEB CRAWLER: Starting from #{@start_url}"
      puts "Max pages: #{@max_pages}, Max depth: #{@max_depth}"
      puts '=' * 60

      @seed_urls.each do |url|
        output << { url: url, depth: 0 }
      end
      puts "[Seed] Emitted #{@seed_urls.size} seed URL(s)"
    end

    # Stage 2: Fetch pages (with deduplication)
    threads(20) do
      processor :fetch_pages do |page_info, output|
        url = page_info[:url]
        depth = page_info[:depth]

        # Check if already visited (deduplication)
        already_visited = @mutex.synchronize do
          if @visited_urls.include?(url)
            true
          else
            @visited_urls.add(url)
            false
          end
        end

        if already_visited
          puts "⊘ Skipping already visited: #{url}"
          next
        end

        # Check depth limit
        if depth > @max_depth
          puts "⊘ Max depth (#{@max_depth}) reached: #{url}"
          next
        end

        # Check page limit
        if @pages_crawled >= @max_pages
          puts "⊘ Max pages (#{@max_pages}) reached"
          next
        end

        # Fetch the page
        puts "↓ [depth #{depth}] Fetching: #{url}"
        page = fetch_page(url)
        page[:depth] = depth

        @mutex.synchronize do
          @pages_fetched << page
          @pages_crawled += 1
        end

        output << page
      end
    end

    # Stage 3: Extract links from fetched pages
    processor :extract_links do |page, output|
      links = extract_links_from_page(page[:url], page[:content])

      @mutex.synchronize do
        @links_extracted.concat(links)
        @links_found += links.size
      end

      puts "  📄 #{page[:title]} (#{page[:word_count]} words)"
      puts "     Found #{links.size} links on #{page[:url]}"

      # Emit the page for storage
      output << page

      # NOTE: In a real recursive crawler, we would emit links back to fetch_pages
      # For this demo, we just extract and track them to avoid complexity
      # To enable recursive crawling:
      # links.each do |link|
      #   next unless should_crawl?(link)
      #   output << { url: link, depth: page[:depth] + 1 }
      # end
    end

    # Stage 4: Process and store pages
    consumer :process_pages do |page|
      @mutex.synchronize { @pages_processed << page }
      save_page_data(page)
      puts "✓ Stored: #{page[:url]} (depth: #{page[:depth]})"
    end

    after_run do
      puts "\n#{'=' * 60}"
      puts 'WEB CRAWLER STATISTICS'
      puts '=' * 60
      puts "Start URL: #{@start_url}"
      puts "Pages crawled: #{@pages_crawled}"
      puts "Links found: #{@links_found}"
      puts "Unique URLs visited: #{@visited_urls.size}"
      puts "Pages processed: #{@pages_processed.size}"

      puts "Average links per page: #{(@links_found.to_f / @pages_crawled).round(1)}" if @pages_crawled > 0

      puts "\nCrawling complete!"
      puts '=' * 60
    end
  end

  private

  def extract_domain(url)
    # Extract domain from URL
    url.split('/')[2] || 'example.com'
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Web Crawler Example ===\n\n"

  # Example 1: Simple crawl with default settings
  puts "Example 1: Single start URL with deduplication\n"
  crawler = WebCrawler.new(start_url: 'http://example.com', max_pages: 15, max_depth: 3)
  crawler.run

  # Example 2: Multiple seed URLs (backward compatible)
  puts "\n\nExample 2: Multiple seed URLs\n"
  seed_urls = [
    'http://test.com',
    'http://test.com/products',
    'http://test.com/services'
  ]
  crawler2 = WebCrawler.new(seed_urls)
  crawler2.run
end

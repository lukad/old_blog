# frozen_string_literal: true

require 'nokogiri'
require 'tempfile'
require 'shellwords'

Jekyll::Hooks.register(:site, :post_write) do |site|
  config = site.config['uncss']

  files = config['files'].flat_map do |file_glob|
    Dir.glob(File.join(site.dest, file_glob))
  end

  stylesheet_hrefs = files.map do |path|
    doc = File.open(path) { |file| Nokogiri::HTML(file) }
    links = doc.css('link[rel="stylesheet"]')
    hrefs = links.map { |link| link.attr('href') }
    hrefs
  end.flatten.uniq

  uncss_stylesheets = stylesheet_hrefs.map do |href|
    if File.file?(File.join(site.dest, href))
      File.join('/', href)
    else
      href
    end
  end

  uncssrc = {
    htmlroot: site.dest,
    stylesheets: uncss_stylesheets,
    media: config['media'],
    timeout: config['timeout']
  }.compact

  uncss_files = files.map { |f| Shellwords.shellescape(f) }.join(' ')

  tempfile = Tempfile.new('uncssrc')
  tempfile.write(uncssrc.to_json)
  tempfile.flush

  begin
    css = `uncss --uncssrc '#{tempfile.path}' #{uncss_files}`
  rescue StandardError => e
    raise Error, "uncss failed: #{e} :: #{result}"
  end

  result_path = config['destination'] || '/assets/styles.css'
  result_path = File.join('/', result_path)

  File.open(File.join(site.dest, result_path), 'w') do |f|
    f.write(css)
  end

  files.each do |path|
    doc = File.open(path) { |file| Nokogiri::HTML(file) }
    links = doc.css('link[rel="stylesheet"]')
    next if links.empty?

    link = Nokogiri::XML::Node.new('link', doc)
    link['rel'] = 'stylesheet'
    link['href'] = result_path

    links.last.add_next_sibling(link)
    links.remove

    File.open(path, 'w') do |file|
      file.write(doc.to_html)
    end
  end
end

namespace :db do
  desc "Update database with yesterday's papers"
  task arxiv_update: :environment do

    print "Fetching arXiv RSS feed ... "

    #fetch the latest RSS feed and add it to the DB
    feed_day = fetch_arxiv_rss

    puts "Done!"

    if feed_day.pubdate == Date.today
      #create Paper stubs (date and identifier)
      papers = parse_arxiv feed_day 

      puts "Updating papers for #{feed_day.pubdate} - #{papers[:all].count - papers[:updates].count} new, #{papers[:updates].count} updates"

      print "Fetching metadata ... "

      #fetch metadata from arXiv OAI interface      
      update_metadata papers

      puts "Done!"
    end
  end
end

namespace :db do
  desc "Completely rebuild metadata database from cache of feed"
  task rebuild_metadata: :environment do

    #ensure we have the latest RSS feed
    fetch_arxiv_rss

    puts "Deleting papers from DB"
    Paper.delete_all

    #get FeedDay objects in ascending order of pubday
    FeedDay.find(:all, order: 'pubdate').each do |feed|
      #create stubs
      papers = parse_arxiv feed

      print "Reloading papers for #{feed.pubdate} ... "
      update_metadata papers
      puts "Done!"
    end
  end
end

def fetch_arxiv_rss
  url = URI.parse('http://export.arxiv.org/rss/quant-ph')
  rss = Net::HTTP.get_response(url).body

  xml = REXML::Document.new(rss)

  date = xml.elements["rdf:RDF/channel/dc:date"].text.to_date

  date += 1 #arxiv mailing for day n happens on day n-1

  feed_day = FeedDay.new(pubdate: date, content: rss)
  feed_day.save

  return feed_day
end

def parse_arxiv feed_day
  papers = []
  updates = Set.new

  xml = REXML::Document.new(feed_day.content)
  date = feed_day.pubdate

  xml.elements.each('rdf:RDF/item') do |item|
    id = item.attributes["about"][-9,9]

    if item.elements["title"].text =~ /\[quant-ph\]/      
      stub =  Paper.new(identifier: id, pubdate: date)
      papers << stub
    
      if item.elements["title"].text =~ /\[quant-ph\] UPDATED\)/
        updates << stub
      end
    end
  end
    
  return {all: papers, updates: updates}
end

def update_metadata papers
  oai_client = OAI::Client.new 'http://export.arxiv.org/oai2'

  papers[:all].each do |paper|
    
    #get the updated date from the stub (in case we fetch an existing record)
    updated_date = paper.pubdate

    #is this an update?
    if papers[:updates].include? paper

      #fetch paper to update
      paper = Paper.find_by_identifier(paper.identifier)

      #if we don't have this paper, skip updating so we don't add it
      next if paper.nil?
    end

    #fetch the record from the arXiv
    response = oai_client.get_record(
                        identifier: "oai:arXiv.org:#{paper.identifier}",
                        metadataPrefix: "arXiv")
    item = response.record.metadata.elements["arXiv"]

    paper.title = item.elements["title"].text
    paper.abstract = item.elements["abstract"].text
    paper.url = "http://arxiv.org/abs/#{paper.identifier}"
    paper.updated_date = updated_date

    paper.authors = []
    item.elements.each('authors/author') do |author|
      name = "#{author.elements['forenames'].text} #{author.elements['keyname'].text}"
      paper.authors << name
    end

    paper.save(validate: false)
  end
end
require "json"
require "logger"
require "net/http"
require "socket"
require "thread"
require "uri"
require "yaml"

class Result
  def self.ready(value)
    new(ready: true, value: value)
  end

  def self.pending
    new(ready: false)
  end

  def self.error(err)
    new(ready: false, error: err)
  end

  def initialize(ready: false, value: nil, error: nil, &blk)
    if block_given?
      @ready = true
      begin
        @value = yield
      rescue => err
        @ready = false
        @error = err
      end
    else
      @ready = ready
      @value = value
      @error = error
    end
  end

  def ready?
    @ready
  end

  def ok?
    !@error
  end

  def value
    @value
  end

  def error
    @error
  end
end

class GraphQLProcessor

  ENDPOINT = URI("https://api.github.com/graphql")

  REPO_DESCRIPTION = <<~GRAPHQL
    query RepoDescription($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        description
      }
    }
  GRAPHQL

  ISSUE_TITLE = <<~GRAPHQL
    query IssueTitle($owner: String!, $name: String!, $number:Int!) {
      repository(owner: $owner, name: $name) {
        issueish(number:$number) {
          title
        }
      }
    }
  GRAPHQL

  ISSUE_SEARCH = <<~GRAPHQL
    query IssueSearch($query:String!) {
      search(query:$query, type:ISSUE, first:10) {
        nodes {
          __typename
          ...on Issueish {
            repository {
              name
              owner {
                login
              }
            }
            number
            title
          }
        }
      }
    }
  GRAPHQL

  def initialize(api_token, logger: nil)
    @api_token = api_token
    @results = {}
    @pending = {}
    @logger = logger
  end

  def process(query)
    if result = @results[query]
      log "#{query.inspect}: cached"
      result
    elsif thread = @pending[query]
      if thread.alive?
        log "#{query.inspect}: pending"
        Result.pending
      else
        @pending.delete(query)
        result = Result.new { thread.value }
        result = result.value if result.ok? # unwrap the result
        @results[query] = result
        log "#{query.inspect}: finished"
        result
      end
    else
      request_type, params = query.split(":", 2)
      case request_type
      when "repo"
        owner, name = params.split("/", 2)
        if owner && name
          log "#{query.inspect}: starting new thread"
          @pending[query] = Thread.new { repo_description owner, name }
          Result.pending
        else
          Result.error "owner/name not found in #{query}"
        end
      when "issue"
        owner, name = params.split("/", 2)
        if owner && name
          name, number = name.split("#", 2)
          if name && number
            log "#{query.inspect}: starting new thread"
            @pending[query] = Thread.new { issue_title(owner, name, number) }
            Result.pending
          else
            Result.error "issue number not specified in #{query}"
          end
        else
          Result.error "owner/name not found in #{query}"
        end
      when "issuesearch"
        log "#{query.inspect}: starting new thread"
        @pending[query] = Thread.new { issue_search(params) }
        Result.pending
      else
        Result.error "unknown RPC query: #{request_type}"
      end
    end
  end

  def repo_description(owner, name)
    result = graphql_request(REPO_DESCRIPTION, :owner => owner, :name => name)
    if result.ok?
      data = result.value
      if data["errors"]
        Result.error data["errors"].first["message"]
      elsif data["repository"]
        Result.ready data["repository"]["description"]
      else
        Result.error "Repository not found"
      end
    else
      result
    end
  end

  def issue_title(owner, name, number)
    result = graphql_request(
      ISSUE_TITLE, :owner => owner, :name => name, :number => number.to_i)
    if result.ok?
      data = result.value
      if data["errors"]
        Result.error data["errors"].first["message"]
      elsif data["repository"]
        if data["repository"]["issueish"]
          Result.ready data["repository"]["issueish"]["title"]
        else
          Result.error "Issue or PR not found"
        end
      else
        Result.error "Repository not found"
      end
    end
  end

  def issue_search(query)
    result = graphql_request(
      ISSUE_SEARCH, :query => query)
    if result.ok?
      data = result.value
      if data["errors"]
        Result.error data["errors"].first["message"]
      elsif data["search"]
        results = data["search"]["nodes"].map do |node|
          owner = node["repository"]["owner"]["login"]
          name = node["repository"]["name"]
          number = node["number"]
          type = node["__typename"]
          title = node["title"]
          "#{owner}/#{name}:#{number}:#{type}:#{title}"
        end
        Result.ready results.join("\n")
      else
        Result.error "No search results"
      end
    end
  end

  def graphql_request(query, variables)
    headers = {"Authorization" => "bearer #{@api_token}"}
    body = {"query" => query, "variables" => variables}.to_json
    res = Net::HTTP.post(ENDPOINT, body, headers)
    if res.code == "200"
      data = JSON.parse(res.body)["data"]
      Result.ready data
    else
      Result.error [res.code, res.body]
    end
  end

  def log(msg)
    if @logger
      @logger.debug("GraphQLProcessor: " + msg)
    end
  end
end

class RPCServer
  def initialize(socket_path, backend, logger: nil)
    @socket_path = socket_path
    cleanup
    @socket = UNIXServer.new(socket_path)
    @backend = backend
    @logger = logger
  end

  # Public: start the RPC server and listen for new requests.
  def run
    while s = @socket.accept do
      Thread.new do
        begin
          input = s.gets.strip
          result = @backend.process(input)
          if result.ready?
            log "OK: #{input}"
            s.puts "OK"
            s.puts result.value
          elsif result.error
            log "ERROR: #{input}: #{result.error}"
            s.puts "ERROR"
            s.puts result.error.to_s
          else
            log "PENDING: #{input}"
            s.puts "PENDING"
          end
        rescue Errno::EPIPE
          log "pipe closed"
          # client closed the socket early
        rescue => e
          puts e
        ensure
          s.close
        end
      end
    end
  rescue Errno::EBADF
    # socket got cleaned up, but we're done anyway
  end

  # Public: stop the RPC server.
  def stop
    @socket.close
  ensure
    cleanup
  end

  def cleanup
    if File.exist?(@socket_path)
      File.unlink @socket_path
    end
  end

  def log(msg)
    if @logger
      @logger.info("RPCServer: " + msg)
    end
  end
end

if __FILE__ == $0

  config_file = File.expand_path("~/.gh-shorthand.yml")
  if !File.exist?(config_file)
    abort "config file #{config_file} not found"
  end
  config = YAML.load(File.read(config_file))
  unless socket_path = config["socket_path"]
    abort "no socket_path defined in #{config_file}"
  end
  unless api_token = config["api_token"]
    abort "no api_token defined in #{config_file}"
  end

  logger = Logger.new(STDERR)
  if ARGV.include?("--verbose") || ARGV.include?("-v")
    logger.level = Logger::DEBUG
  else
    logger.level = Logger::INFO
  end
  store = GraphQLProcessor.new(api_token, logger: logger)
  server = RPCServer.new(socket_path, store, logger: logger)

  trap("INT") { server.stop }
  trap("TERM") { server.stop }

  logger.info "started gh-shorthand RPC server at #{socket_path}"
  server.run

end

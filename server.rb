require "socket"
require "thread"
require "json"
require "yaml"
require "net/http"
require "uri"

class MemoryStore
  def initialize
    @data = {}
    @mutex = Thread::Mutex.new
  end

  def [](key)
    @data[key]
  end

  def []=(key, value)
    @mutex.synchronize do
      @data[key] = value
    end
  end
end

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

  REPO_DESCRIPTION = <<-GRAPHQL
    query RepoDescription($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        description
      }
    }
  GRAPHQL

  def initialize(api_token)
    @api_token = api_token
    @results = {}
    @pending = {}
  end

  def process(query)
    if result = @results[query]
      puts "query #{query.inspect}: cached results found"
      result
    elsif thread = @pending[query]
      if thread.alive?
        puts "query #{query.inspect}: thread still pending"
        Result.pending
      else
        @pending.delete(query)
        result = Result.new { thread.value }
        result = result.value if result.ok? # unwrap the result
        @results[query] = result
        puts "query #{query.inspect}: thread finished: #{result.inspect}"
        result
      end
    else
      request_type, params = query.split(":", 2)
      case request_type
      when "repo"
        owner, name = params.split("/", 2)
        if owner && name
          puts "query #{query.inspect}: starting new thread"
          @pending[query] = Thread.new { repo_description owner, name }
          Result.pending
        else
          Result.error "owner/name not found in #{query}"
        end
      else
        Result.error "unknown RPC query: #{request_type}"
      end
    end
  end

  def repo_description(owner, name)
    result = graphql_request(REPO_DESCRIPTION, :owner => owner, :name => name)
    if result.ok?
      data = result.value
      if data["repository"]
        output = {:description => data["repository"]["description"]}
        Result.ready output.to_json
      else
        Result.error "Repository not found"
      end
    else
      result
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
end

# for testing
class UpcaseStore
  DELAY = 2 # wait this long for results

  def initialize
    @store = MemoryStore.new
  end

  def process(input)
    state, value = @store[input]
    case state
    when nil
      now = Time.now.to_f
      @store[input] = [:pending, now]
      Result.pending
    when :pending
      if Time.now.to_f - value > DELAY
        @store[input] = [:ready, input.upcase]
        Result.ready(input.upcase)
      else
        Result.pending
      end
    else
      Result.ready(value)
    end
  end
end

class RPCServer
  def initialize(socket_path, backend)
    @socket_path = socket_path
    cleanup
    @socket = UNIXServer.new(socket_path)
    @backend = backend
  end

  # Public: start the RPC server and listen for new requests.
  def run
    while s = @socket.accept do
      Thread.new do
        begin
          input = s.gets.strip
          puts "processing: #{input}"
          result = @backend.process(input)
          puts "got result #{result.inspect}"
          if result.ready?
            puts "OK: #{result.value}"
            s.puts "OK"
            s.puts result.value
          elsif result.error
            puts "error: #{result.error}"
            s.puts "ERROR"
            s.puts result.error.to_s
          else
            puts "pending"
            s.puts "PENDING"
          end
        rescue Errno::EPIPE
          puts "pipe closed"
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

  # store = UpcaseStore.new
  store = GraphQLProcessor.new(api_token)
  server = RPCServer.new(socket_path, store)

  trap("INT") {
    puts "exiting..."
    server.stop
  }

  trap("TERM") { server.stop }

  puts "started gh-shorthand RPC server at #{socket_path}"
  server.run

end

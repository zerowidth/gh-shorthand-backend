require "socket"
require "thread"
require "json"
require "yaml"

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
  def initialize(ready:, value: nil)
    @ready = ready
    @value = value
  end

  def ready?
    @ready
  end

  def value
    @value
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
      Result.new(ready: false, value: now)
    when :pending
      if Time.now.to_f - value > DELAY
        @store[input] = [:ready, input.upcase]
        Result.new(ready: true, value: input.upcase)
      else
        Result.new(ready: false, value: value)
      end
    else
      Result.new(ready: true, value: value)
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

  def run
    while s = @socket.accept do
      Thread.new do
        begin
          input = s.gets.strip
          result = @backend.process(input)
          if result.ready?
            s.puts "OK"
            s.puts result.value
          else
            s.puts "PENDING"
          end
        rescue Errno::EPIPE
          # client closed the socket early
        ensure
          s.close
        end
      end
    end
  rescue Errno::EBADF
    # socket got cleaned up, but we're done anyway
  end

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

config_file = File.expand_path("~/.gh-shorthand.yml")
if !File.exist?(config_file)
  abort "config file #{config_file} not found"
end
config = YAML.load(File.read(config_file))
unless socket_path = config["socket_path"]
  abort "no socket_path defined in config file"
end

store = UpcaseStore.new
server = RPCServer.new(socket_path, store)

trap("INT") {
  puts "exiting..."
  server.stop
}

trap("TERM") { server.stop }

puts "started gh-shorthand RPC server at #{socket_path}"
server.run

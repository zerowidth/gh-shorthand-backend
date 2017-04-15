require "socket"
require "thread"
require "json"
require "yaml"

config_file = File.expand_path("~/.gh-shorthand.yml")
if !File.exist?(config_file)
  abort "config file #{config_file} not found"
end
config = YAML.load(File.read(config_file))
unless socket_path = config["socket_path"]
  abort "no socket_path defined in config file"
end

DELAY = 10.0

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

class UpcaseStore
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

if File.exist?(socket_path)
  File.unlink socket_path
end

server = UNIXServer.new(socket_path)
store = UpcaseStore.new

trap("INT") {
  puts "exiting"
  server.close
  File.unlink(socket_path)
  exit
}
trap("TERM") {
  File.unlink(socket_path)
  exit
}

Thread.abort_on_exception = true

puts "server started on #{socket_path}"

while s = server.accept do
  Thread.new do
    begin
      input = s.gets.strip

      log = "processing #{input.inspect}: "
      result = store.process(input)
      if result.ready?
        log << "OK: #{result.value}"
        s.puts "OK"
        s.puts result.value
      else
        log << "PENDING for #{Time.now.to_f - result.value}"
        s.puts "PENDING"
      end

      puts log
    rescue Errno::EPIPE => e
      puts e.to_s
    ensure
      s.close
    end
  end
end
